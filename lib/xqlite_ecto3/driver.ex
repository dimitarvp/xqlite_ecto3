defmodule XqliteEcto3.Driver do
  @moduledoc false

  @behaviour DBConnection

  import XqliteEcto3.Telemetry, only: [emit: 3, span_with_stop_metadata: 3]

  alias XqliteNIF, as: NIF

  defstruct [
    :conn,
    :transaction_status,
    :path,
    :savepoint_prefix,
    savepoint: 0,
    default_transaction_mode: :immediate,
    rich_fk_diagnostics: false,
    stmt_cache: %{},
    stmt_cache_keys: [],
    stmt_cache_size: 50
  ]

  @stmt_batch_size 500

  @default_stream_batch_size 500

  @savepoint_prefix_byte_count 4

  # connect_timeout is enforced by DBConnection around this call. NIF.open is a
  # blocking dirty-NIF call that cannot be interrupted mid-syscall, so the
  # practical effect is limited to slow filesystems (NFS, network mounts).
  # For local files, sqlite3_open returns near-instantly.
  @impl DBConnection
  def connect(opts) do
    database = Keyword.fetch!(opts, :database)
    mode = Keyword.get(opts, :mode, :readwrite)
    busy_timeout = Keyword.get(opts, :busy_timeout, 5_000)
    journal_mode = Keyword.get(opts, :journal_mode, :wal)
    synchronous = Keyword.get(opts, :synchronous, :normal)
    temp_store = Keyword.get(opts, :temp_store, :memory)
    foreign_keys = Keyword.get(opts, :foreign_keys, true)
    cache_size = Keyword.get(opts, :cache_size, -64_000)
    auto_vacuum = Keyword.get(opts, :auto_vacuum)
    wal_autocheckpoint = Keyword.get(opts, :wal_autocheckpoint)
    mmap_size = Keyword.get(opts, :mmap_size)
    custom_pragmas = Keyword.get(opts, :custom_pragmas, [])
    default_transaction_mode = Keyword.get(opts, :default_transaction_mode, :immediate)
    statement_cache_size = Keyword.get(opts, :statement_cache_size, 50)
    rich_fk_diagnostics = Keyword.get(opts, :rich_fk_diagnostics, false)

    start_md = %{database: database}

    span_with_stop_metadata [:xqlite_ecto3, :connect], start_md do
      result =
        with {:ok, txn_mode} <- validate_transaction_mode(default_transaction_mode),
             {:ok, stmt_cache_size} <- validate_statement_cache_size(statement_cache_size),
             {:ok, conn} <- open_database(database, mode),
             # auto_vacuum only sticks while the database file has no pages;
             # journal_mode=wal below writes the header, so this must go first
             # (existing databases additionally need VACUUM — SQLite semantics).
             {:ok, _} <- set_optional_pragma(conn, "auto_vacuum", writable(auto_vacuum, mode)),
             {:ok, _} <- NIF.set_pragma(conn, "busy_timeout", busy_timeout),
             {:ok, _} <- set_writable_pragma(conn, "journal_mode", to_string(journal_mode), mode),
             {:ok, _} <- NIF.set_pragma(conn, "foreign_keys", foreign_keys),
             {:ok, _} <- NIF.set_pragma(conn, "cache_size", cache_size),
             {:ok, _} <- NIF.set_pragma(conn, "synchronous", to_string(synchronous)),
             {:ok, _} <- NIF.set_pragma(conn, "temp_store", to_string(temp_store)),
             {:ok, _} <-
               set_optional_pragma(conn, "wal_autocheckpoint", writable(wal_autocheckpoint, mode)),
             {:ok, _} <- set_optional_pragma(conn, "mmap_size", mmap_size),
             # user pragmas go last so explicit config wins over every default
             {:ok, _} <- apply_custom_pragmas(conn, custom_pragmas) do
          {:ok,
           %__MODULE__{
             conn: conn,
             transaction_status: :idle,
             path: database,
             savepoint_prefix: random_savepoint_prefix(),
             default_transaction_mode: txn_mode,
             rich_fk_diagnostics: rich_fk_diagnostics,
             stmt_cache_size: stmt_cache_size
           }}
        end

      classify(result, start_md)
    end
  end

  defp validate_statement_cache_size(size) when is_integer(size) and size >= 0 do
    {:ok, size}
  end

  defp validate_statement_cache_size(other) do
    {:error, {:invalid_statement_cache_size, other}}
  end

  defp validate_transaction_mode(mode) when mode in [:deferred, :immediate, :exclusive] do
    {:ok, mode}
  end

  defp validate_transaction_mode(other) do
    {:error, {:invalid_default_transaction_mode, other}}
  end

  defp open_database(database, :readwrite), do: NIF.open(database)
  defp open_database(database, :readonly), do: NIF.open_readonly(database)
  defp open_database(_database, other), do: {:error, {:invalid_connection_mode, other}}

  # Write-requiring pragmas are skipped on read-only connections: setting
  # journal_mode / auto_vacuum / wal_autocheckpoint needs write access, and
  # checkpointing cannot run on a read-only handle anyway.
  defp writable(value, :readwrite), do: value
  defp writable(_value, :readonly), do: nil

  defp set_writable_pragma(_conn, _name, _value, :readonly), do: {:ok, :skipped}
  defp set_writable_pragma(conn, name, value, :readwrite), do: NIF.set_pragma(conn, name, value)

  defp apply_custom_pragmas(_conn, []), do: {:ok, :done}

  defp apply_custom_pragmas(conn, [{name, value} | rest]) when is_atom(name) or is_binary(name) do
    case NIF.set_pragma(conn, to_string(name), value) do
      {:ok, _} -> apply_custom_pragmas(conn, rest)
      {:error, _} = err -> err
    end
  end

  defp apply_custom_pragmas(_conn, [entry | _rest]), do: {:error, {:invalid_custom_pragma, entry}}
  defp apply_custom_pragmas(_conn, other), do: {:error, {:invalid_custom_pragmas, other}}

  # Config-optional pragmas: absent means "leave SQLite's default alone",
  # not "apply our own default" — so nil skips the write entirely.
  defp set_optional_pragma(_conn, _name, nil), do: {:ok, :skipped}

  defp set_optional_pragma(conn, name, value) when is_atom(value) and not is_boolean(value) do
    NIF.set_pragma(conn, name, to_string(value))
  end

  defp set_optional_pragma(conn, name, value), do: NIF.set_pragma(conn, name, value)

  defp random_savepoint_prefix do
    @savepoint_prefix_byte_count
    |> :crypto.strong_rand_bytes()
    |> Base.encode16(case: :lower)
  end

  @impl DBConnection
  def disconnect(_err, state) do
    # Reset transient fields for debug-consistency. The struct is local to
    # this call but anything that captured it earlier (telemetry, traces)
    # reads post-close values instead of stale mid-transaction cache.
    _ = %{state | transaction_status: :idle, savepoint: 0}

    # Finalize every cached statement before closing: sqlite3_close with
    # outstanding statements leaks the handle until process exit.
    Enum.each(state.stmt_cache, fn {_sql, stmt} -> NIF.stmt_finalize(stmt) end)

    NIF.close(state.conn)

    emit(
      [:xqlite_ecto3, :disconnect],
      %{monotonic_time: XqliteEcto3.Telemetry.monotonic_time()},
      %{conn: state.conn}
    )

    :ok
  end

  # Checkout can receive a connection whose state cache drifted: user code
  # may have run raw BEGIN/COMMIT/ROLLBACK, or a prior checkout crashed.
  # Sync transaction_status from SQLite and clear the savepoint counter —
  # we only ever track our own managed savepoint stack, which is empty at
  # every checkout boundary by construction.
  @impl DBConnection
  def checkout(state) do
    result =
      case NIF.transaction_status(state.conn) do
        {:ok, true} ->
          {:ok, %{state | transaction_status: :transaction, savepoint: 0}}

        {:ok, false} ->
          {:ok, %{state | transaction_status: :idle, savepoint: 0}}

        {:error, reason} ->
          {:disconnect, XqliteEcto3.Error.wrap(reason), state}
      end

    emit(
      [:xqlite_ecto3, :checkout],
      %{monotonic_time: XqliteEcto3.Telemetry.monotonic_time()},
      %{conn: state.conn}
    )

    result
  end

  @impl DBConnection
  def ping(state) do
    case NIF.query(state.conn, "SELECT 1", []) do
      {:ok, _} -> {:ok, state}
      {:error, reason} -> {:disconnect, XqliteEcto3.Error.wrap(reason), state}
    end
  end

  # Raw BEGIN/COMMIT/ROLLBACK via query bypass handle_begin/commit/rollback,
  # so state.transaction_status drifts. Ask SQLite directly.
  @impl DBConnection
  def handle_status(_opts, state) do
    case NIF.transaction_status(state.conn) do
      {:ok, true} ->
        {:transaction, %{state | transaction_status: :transaction}}

      {:ok, false} ->
        {:idle, %{state | transaction_status: :idle}}

      {:error, _reason} ->
        {:error, state}
    end
  end

  @impl DBConnection
  def handle_begin(opts, state) do
    mode = Keyword.get(opts, :mode, :transaction)
    start_md = %{conn: state.conn, mode: mode}

    span_with_stop_metadata [:xqlite_ecto3, :handle_begin], start_md do
      result =
        case mode do
          :savepoint ->
            case NIF.savepoint(state.conn, savepoint_name(state, state.savepoint)) do
              :ok ->
                {:ok, nil, %{state | savepoint: state.savepoint + 1}}

              {:error, reason} ->
                {:disconnect, XqliteEcto3.Error.wrap(reason), state}
            end

          _mode ->
            case begin_mode(mode, state) do
              {:ok, resolved} ->
                case NIF.begin(state.conn, resolved) do
                  :ok ->
                    {:ok, nil, %{state | transaction_status: :transaction}}

                  {:error, reason} ->
                    {:disconnect, XqliteEcto3.Error.wrap(reason), state}
                end

              :invalid ->
                {:disconnect,
                 %DBConnection.ConnectionError{
                   message: "invalid transaction mode: #{inspect(mode)}"
                 }, state}
            end
        end

      classify_dbc(result, start_md)
    end
  end

  # `:transaction` is DBConnection's own default marker (no explicit mode
  # given) — it resolves to the connection's configured default. Explicit
  # SQLite modes pass through; `:savepoint` never reaches here.
  defp begin_mode(:transaction, state), do: {:ok, state.default_transaction_mode}

  defp begin_mode(mode, _state) when mode in [:deferred, :immediate, :exclusive] do
    {:ok, mode}
  end

  defp begin_mode(_other, _state), do: :invalid

  @impl DBConnection
  def handle_commit(opts, state) do
    mode = Keyword.get(opts, :mode, :transaction)
    start_md = %{conn: state.conn, mode: mode}

    span_with_stop_metadata [:xqlite_ecto3, :handle_commit], start_md do
      result =
        case mode do
          :savepoint ->
            case NIF.release_savepoint(state.conn, savepoint_name(state, state.savepoint - 1)) do
              :ok ->
                {:ok, nil, %{state | savepoint: state.savepoint - 1}}

              {:error, reason} ->
                {:disconnect, wrap_commit_error(reason, state), state}
            end

          _mode ->
            case NIF.commit(state.conn) do
              :ok ->
                {:ok, nil, %{state | transaction_status: :idle, savepoint: 0}}

              {:error, reason} ->
                {:disconnect, wrap_commit_error(reason, state), state}
            end
        end

      classify_dbc(result, start_md)
    end
  end

  # A COMMIT (or outermost-savepoint RELEASE) that fails on a deferred
  # FK violation leaves the transaction open with the violating rows
  # still present — diagnose by reading them directly, no replay.
  defp wrap_commit_error(reason, %__MODULE__{rich_fk_diagnostics: true} = state) do
    XqliteEcto3.FkDiagnostics.wrap_at_commit(reason, state.conn)
  end

  defp wrap_commit_error(reason, _state), do: XqliteEcto3.Error.wrap(reason)

  @impl DBConnection
  def handle_rollback(opts, state) do
    mode = Keyword.get(opts, :mode, :transaction)
    start_md = %{conn: state.conn, mode: mode}

    span_with_stop_metadata [:xqlite_ecto3, :handle_rollback], start_md do
      result =
        case mode do
          :savepoint ->
            name = savepoint_name(state, state.savepoint - 1)

            with :ok <- NIF.rollback_to_savepoint(state.conn, name),
                 :ok <- NIF.release_savepoint(state.conn, name) do
              {:ok, nil, %{state | savepoint: state.savepoint - 1}}
            else
              {:error, reason} -> {:disconnect, XqliteEcto3.Error.wrap(reason), state}
            end

          _mode ->
            case NIF.rollback(state.conn) do
              :ok ->
                {:ok, nil, %{state | transaction_status: :idle, savepoint: 0}}

              {:error, reason} ->
                {:disconnect, XqliteEcto3.Error.wrap(reason), state}
            end
        end

      classify_dbc(result, start_md)
    end
  end

  # Prefix keeps our managed savepoint stack distinct from any raw
  # SAVEPOINT a user might run themselves, so a stray user savepoint
  # cannot collide with xqlite_sp_0, xqlite_sp_1, ...
  defp savepoint_name(%__MODULE__{savepoint_prefix: prefix}, n) when is_integer(n) do
    "xqlite_sp_#{prefix}_#{n}"
  end

  @impl DBConnection
  def handle_prepare(%XqliteEcto3.Query{} = query, _opts, state) do
    {:ok, %{query | ref: make_ref()}, state}
  end

  # Meta-operation, not a statement: hands `XqliteEcto3.with_xqlite/3` the
  # raw NIF connection. Deliberately outside the handle_execute telemetry
  # span — nothing runs against the database here.
  @impl DBConnection
  def handle_execute(%XqliteEcto3.RawConn{} = query, _params, _opts, state) do
    {:ok, query, state.conn, state}
  end

  def handle_execute(query, params, opts, state) do
    timeout = Keyword.get(opts, :timeout, 15_000)
    sql = IO.iodata_to_binary(query.statement)
    start_md = %{conn: state.conn, query: query, sql: sql}

    span_with_stop_metadata [:xqlite_ecto3, :handle_execute], start_md do
      {exec_result, state} = run_statement(state, sql, params, timeout)

      result =
        case exec_result do
          {:ok, %{columns: [], changes: changes} = result} ->
            {:ok, query, %{result | num_rows: changes, rows: nil}, state}

          {:ok, result} ->
            {:ok, query, result, state}

          {:error, :operation_cancelled} ->
            {:error, %DBConnection.ConnectionError{message: "query timed out"}, state}

          {:error, reason} ->
            {:error, wrap_execute_error(reason, sql, params, state), state}
        end

      classify_dbc(result, start_md)
    end
  end

  # Statement cache: prepared statements live per connection, keyed by SQL
  # text, LRU-evicted beyond :statement_cache_size (0 disables). SQL that
  # stmt_prepare rejects by design (multiple statements, whitespace-only)
  # falls back to the uncached one-shot path.
  defp run_statement(%{stmt_cache_size: 0} = state, sql, params, timeout) do
    {execute_with_cancel(state.conn, sql, params, timeout), state}
  end

  defp run_statement(state, sql, params, timeout) do
    case checkout_stmt(state, sql) do
      {:ok, stmt, state} ->
        {run_cached_stmt(state.conn, stmt, params, timeout), state}

      {:fallback, state} ->
        {execute_with_cancel(state.conn, sql, params, timeout), state}

      {:error, reason, state} ->
        {{:error, reason}, state}
    end
  end

  defp checkout_stmt(state, sql) do
    case Map.fetch(state.stmt_cache, sql) do
      {:ok, stmt} -> {:ok, stmt, touch_stmt(state, sql)}
      :error -> prepare_and_cache(state, sql)
    end
  end

  defp prepare_and_cache(state, sql) do
    case NIF.stmt_prepare(state.conn, sql) do
      {:ok, stmt} -> {:ok, stmt, insert_stmt(state, sql, stmt)}
      {:error, :multiple_statements} -> {:fallback, state}
      {:error, {:cannot_execute, _}} -> {:fallback, state}
      {:error, reason} -> {:error, reason, state}
    end
  end

  defp touch_stmt(state, sql) do
    %{state | stmt_cache_keys: [sql | List.delete(state.stmt_cache_keys, sql)]}
  end

  defp insert_stmt(state, sql, stmt) do
    state = %{
      state
      | stmt_cache: Map.put(state.stmt_cache, sql, stmt),
        stmt_cache_keys: [sql | state.stmt_cache_keys]
    }

    evict_over_capacity(state)
  end

  defp evict_over_capacity(state) do
    if map_size(state.stmt_cache) > state.stmt_cache_size do
      {evicted_key, kept_keys} = List.pop_at(state.stmt_cache_keys, -1)
      {stmt, cache} = Map.pop(state.stmt_cache, evicted_key)
      _ = NIF.stmt_finalize(stmt)
      %{state | stmt_cache: cache, stmt_cache_keys: kept_keys}
    else
      state
    end
  end

  defp run_cached_stmt(conn, stmt, params, timeout) do
    case NIF.stmt_bind(stmt, params) do
      :ok ->
        step_to_completion(conn, stmt, timeout)

      {:error, _} = err ->
        pristine_stmt(stmt)
        err
    end
  end

  defp step_to_completion(conn, stmt, :infinity) do
    collect_rows(conn, stmt, [], [])
  end

  defp step_to_completion(conn, stmt, timeout) when is_integer(timeout) do
    {:ok, token} = NIF.create_cancel_token()
    canceller = spawn_canceller(token, timeout)

    try do
      collect_rows(conn, stmt, [token], [])
    after
      send(canceller, :stop)
    end
  end

  defp collect_rows(conn, stmt, tokens, acc) do
    case NIF.stmt_multi_step_cancellable(stmt, @stmt_batch_size, tokens) do
      {:ok, %{rows: rows, done: false}} ->
        collect_rows(conn, stmt, tokens, [rows | acc])

      {:ok, %{rows: rows, done: true}} ->
        finish_cached_stmt(conn, stmt, Enum.reverse([rows | acc]))

      {:error, _} = err ->
        pristine_stmt(stmt)
        err
    end
  end

  defp finish_cached_stmt(conn, stmt, row_batches) do
    rows = Enum.concat(row_batches)
    {:ok, columns} = NIF.stmt_column_names(stmt)
    # Mirrors query_with_changes semantics: only statements without result
    # columns (DML) report changes. Reading sqlite3_changes here is safe
    # because DBConnection holds this connection exclusively for the whole
    # handle_execute call — nothing can interleave another write.
    changes = if columns == [], do: conn_changes(conn), else: 0
    pristine_stmt(stmt)

    {:ok, %{columns: columns, rows: rows, num_rows: length(rows), changes: changes}}
  end

  defp conn_changes(conn) do
    case NIF.changes(conn) do
      {:ok, n} -> n
      {:error, _} -> 0
    end
  end

  # Back to a reusable state: reset the program, drop the bindings. Runs on
  # both completion and error paths so a cached statement never carries
  # stale execution state into its next use.
  defp pristine_stmt(stmt) do
    _ = NIF.stmt_reset(stmt)
    _ = NIF.stmt_clear_bindings(stmt)
    :ok
  end

  defp wrap_execute_error(reason, sql, params, %__MODULE__{rich_fk_diagnostics: true} = state) do
    XqliteEcto3.FkDiagnostics.wrap_with_replay(reason, state.conn, sql, params)
  end

  defp wrap_execute_error(reason, _sql, _params, _state), do: XqliteEcto3.Error.wrap(reason)

  @impl DBConnection
  def handle_close(_query, _opts, state) do
    {:ok, nil, state}
  end

  @impl DBConnection
  def handle_declare(query, params, opts, state) do
    sql = IO.iodata_to_binary(query.statement)
    start_md = %{conn: state.conn, query: query, sql: sql}

    span_with_stop_metadata [:xqlite_ecto3, :handle_declare], start_md do
      result =
        case NIF.stream_open(state.conn, sql, params) do
          {:ok, handle} ->
            case NIF.stream_get_columns(handle) do
              {:ok, columns} ->
                batch_size = batch_size_from_opts(opts)

                {:ok, query, %{handle: handle, columns: columns, batch_size: batch_size}, state}

              {:error, reason} ->
                NIF.stream_close(handle)
                {:error, XqliteEcto3.Error.wrap(reason), state}
            end

          {:error, reason} ->
            {:error, XqliteEcto3.Error.wrap(reason), state}
        end

      classify_dbc(result, start_md)
    end
  end

  @impl DBConnection
  def handle_fetch(_query, cursor, _opts, state) do
    start_md = %{conn: state.conn, cursor: cursor}

    span_with_stop_metadata [:xqlite_ecto3, :handle_fetch], start_md do
      result =
        case NIF.stream_fetch(cursor.handle, cursor.batch_size) do
          {:ok, %{rows: rows}} ->
            r = %{
              columns: cursor.columns,
              rows: rows,
              num_rows: length(rows)
            }

            {:cont, r, state}

          :done ->
            {:halt, %{columns: cursor.columns, rows: [], num_rows: 0}, state}

          {:error, reason} ->
            {:error, XqliteEcto3.Error.wrap(reason), state}
        end

      classify_dbc(result, start_md)
    end
  end

  @impl DBConnection
  def handle_deallocate(_query, cursor, _opts, state) do
    start_md = %{conn: state.conn, cursor: cursor}

    span_with_stop_metadata [:xqlite_ecto3, :handle_deallocate], start_md do
      _ = NIF.stream_close(cursor.handle)
      result = {:ok, nil, state}
      classify_dbc(result, start_md)
    end
  end

  defp batch_size_from_opts(opts) do
    case Keyword.get(opts, :max_rows, @default_stream_batch_size) do
      n when is_integer(n) and n > 0 -> n
      _ -> @default_stream_batch_size
    end
  end

  defp execute_with_cancel(conn, sql, params, :infinity) do
    NIF.query_with_changes(conn, sql, params)
  end

  defp execute_with_cancel(conn, sql, params, timeout) when is_integer(timeout) do
    {:ok, token} = NIF.create_cancel_token()
    canceller = spawn_canceller(token, timeout)

    try do
      NIF.query_with_changes_cancellable(conn, sql, params, [token])
    after
      send(canceller, :stop)
    end
  end

  # The dirty NIF blocks this process, so Process.send_after(self(), ...)
  # would never deliver. A separate process is required.
  defp spawn_canceller(token, timeout) do
    parent = self()
    ref = make_ref()

    spawn(fn ->
      send(parent, {ref, :ready})

      receive do
        :stop -> :ok
      after
        timeout ->
          _ = NIF.cancel_operation(token)
      end
    end)
    |> tap(fn _pid ->
      receive do
        {^ref, :ready} -> :ok
      after
        1_000 -> :ok
      end
    end)
  end

  # ---------------------------------------------------------------------------
  # Telemetry classification helpers
  # ---------------------------------------------------------------------------

  # connect/1 returns {:ok, state} | {:error, reason}.
  defp classify({:ok, _state} = result, start_md) do
    {result, Map.merge(start_md, %{result_class: :ok, error_reason: nil})}
  end

  defp classify({:error, reason} = result, start_md) do
    {result, Map.merge(start_md, %{result_class: :error, error_reason: reason})}
  end

  # DBConnection callback returns:
  #   {:ok, ..., state}
  #   {:cont, ..., state}
  #   {:halt, ..., state}
  #   {:error, error, state}
  #   {:disconnect, error, state}
  defp classify_dbc(result, start_md) do
    case result do
      {:ok, _, _} ->
        {result, Map.merge(start_md, %{result_class: :ok, error_reason: nil})}

      {:ok, _, _, _} ->
        {result, Map.merge(start_md, %{result_class: :ok, error_reason: nil})}

      {:cont, _, _} ->
        {result, Map.merge(start_md, %{result_class: :ok, error_reason: nil})}

      {:halt, _, _} ->
        {result, Map.merge(start_md, %{result_class: :ok, error_reason: nil})}

      {:error, error, _state} ->
        {result, Map.merge(start_md, %{result_class: :error, error_reason: error})}

      {:disconnect, error, _state} ->
        {result, Map.merge(start_md, %{result_class: :error, error_reason: {:disconnect, error}})}
    end
  end
end
