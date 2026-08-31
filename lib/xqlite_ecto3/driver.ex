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
    hooks = Keyword.get(opts, :hooks, [])

    start_md = %{database: database}

    span_with_stop_metadata [:xqlite_ecto3, :connect], start_md do
      result =
        with {:ok, mode} <- validate_connection_mode(mode),
             {:ok, txn_mode} <- validate_transaction_mode(default_transaction_mode),
             {:ok, stmt_cache_size} <- validate_statement_cache_size(statement_cache_size),
             {:ok, busy_timeout_ms} <- validate_busy_timeout(busy_timeout),
             {:ok, journal_mode} <- validate_journal_mode(journal_mode),
             {:ok, synchronous} <- validate_synchronous(synchronous),
             {:ok, temp_store} <- validate_temp_store(temp_store),
             {:ok, foreign_keys} <- validate_foreign_keys(foreign_keys),
             {:ok, cache_size} <- validate_cache_size(cache_size),
             {:ok, auto_vacuum} <- validate_auto_vacuum(auto_vacuum),
             {:ok, wal_autocheckpoint} <- validate_wal_autocheckpoint(wal_autocheckpoint),
             {:ok, mmap_size} <- validate_mmap_size(mmap_size),
             {:ok, rich_fk_diagnostics} <- validate_rich_fk_diagnostics(rich_fk_diagnostics),
             {:ok, conn} <- open_database(database, mode),
             # auto_vacuum only sticks while the database file has no pages;
             # journal_mode=wal below writes the header, so this must go first
             # (existing databases additionally need VACUUM — SQLite semantics).
             {:ok, _} <- set_optional_pragma(conn, "auto_vacuum", writable(auto_vacuum, mode)),
             {:ok, _} <- NIF.set_pragma(conn, "busy_timeout", busy_timeout_ms),
             {:ok, _} <- set_journal_mode(conn, to_string(journal_mode), mode),
             {:ok, _} <- NIF.set_pragma(conn, "foreign_keys", foreign_keys),
             {:ok, _} <- NIF.set_pragma(conn, "cache_size", cache_size),
             {:ok, _} <- NIF.set_pragma(conn, "synchronous", to_string(synchronous)),
             {:ok, _} <- NIF.set_pragma(conn, "temp_store", to_string(temp_store)),
             {:ok, _} <-
               set_optional_pragma(conn, "wal_autocheckpoint", writable(wal_autocheckpoint, mode)),
             {:ok, _} <- set_optional_pragma(conn, "mmap_size", mmap_size),
             # user pragmas go last so explicit config wins over every default
             {:ok, _} <- apply_custom_pragmas(conn, custom_pragmas),
             :ok <- register_config_hooks(conn, hooks) do
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
        else
          # DBConnection's connect contract wants {:error, Exception.t()}: with a
          # bare reason, `raise err` in its retry machinery becomes ArgumentError
          # and the real cause is lost.
          {:error, reason} -> {:error, XqliteEcto3.Error.wrap(reason)}
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

  # SQLite stores busy_timeout as a C int: negatives and values past int32 max
  # are clamped to 0 at the PRAGMA level, silently disabling the busy handler.
  # Reject them (and :infinity, floats, strings) instead of letting the clamp
  # decide; 2_147_483_647 ms (~24.8 days) is the accepted "wait forever".
  # DBConnection spells the transaction mode with the same :mode key this
  # config slot uses for the connection mode; without the dedicated refusal
  # a transaction mode here fails every connect and the caller only ever
  # sees the pool's :queue_timeout.
  defp validate_connection_mode(mode) when mode in [:readwrite, :readonly], do: {:ok, mode}

  defp validate_connection_mode(mode)
       when mode in [:transaction, :savepoint, :deferred, :immediate, :exclusive] do
    {:error, {:transaction_mode_as_connection_mode, mode}}
  end

  defp validate_connection_mode(other), do: {:error, {:invalid_connection_mode, other}}

  defp validate_busy_timeout(ms) when is_integer(ms) and ms >= 0 and ms <= 2_147_483_647 do
    {:ok, ms}
  end

  defp validate_busy_timeout(other) do
    {:error, {:invalid_busy_timeout, other}}
  end

  # SQLite's pragma parser never errors on an unrecognized value — it picks a
  # default instead (`journal_mode: :walk` means DELETE mode,
  # `foreign_keys: :nonsense` means enforcement OFF, orphan rows accepted).
  # Every config value the adapter forwards to a pragma is validated here
  # first; this layer is the only loud one. The URL parser's allowlist
  # produces the same typed values, so both config paths pass. auto_vacuum,
  # wal_autocheckpoint, and mmap_size keep nil as "leave SQLite's default".
  @journal_modes [:delete, :truncate, :persist, :memory, :wal, :off]
  @synchronous_levels [:off, :normal, :full, :extra]
  @temp_stores [:default, :file, :memory]
  @auto_vacuum_modes [:none, :full, :incremental]

  defp validate_journal_mode(mode) when mode in @journal_modes, do: {:ok, mode}
  defp validate_journal_mode(other), do: {:error, {:invalid_journal_mode, other}}

  defp validate_synchronous(level) when level in @synchronous_levels, do: {:ok, level}
  defp validate_synchronous(other), do: {:error, {:invalid_synchronous, other}}

  defp validate_temp_store(store) when store in @temp_stores, do: {:ok, store}
  defp validate_temp_store(other), do: {:error, {:invalid_temp_store, other}}

  defp validate_foreign_keys(flag) when is_boolean(flag), do: {:ok, flag}
  defp validate_foreign_keys(other), do: {:error, {:invalid_foreign_keys, other}}

  # Negative cache_size is meaningful (-N = N KiB), so any integer passes.
  defp validate_cache_size(size) when is_integer(size), do: {:ok, size}
  defp validate_cache_size(other), do: {:error, {:invalid_cache_size, other}}

  defp validate_auto_vacuum(nil), do: {:ok, nil}
  defp validate_auto_vacuum(mode) when mode in @auto_vacuum_modes, do: {:ok, mode}
  defp validate_auto_vacuum(other), do: {:error, {:invalid_auto_vacuum, other}}

  defp validate_wal_autocheckpoint(nil), do: {:ok, nil}

  defp validate_wal_autocheckpoint(pages) when is_integer(pages) and pages >= 0 do
    {:ok, pages}
  end

  defp validate_wal_autocheckpoint(other), do: {:error, {:invalid_wal_autocheckpoint, other}}

  defp validate_mmap_size(nil), do: {:ok, nil}
  defp validate_mmap_size(bytes) when is_integer(bytes) and bytes >= 0, do: {:ok, bytes}
  defp validate_mmap_size(other), do: {:error, {:invalid_mmap_size, other}}

  # Not a pragma — a struct pattern match consumes it, so any value other
  # than the atom true silently disabled the feature.
  defp validate_rich_fk_diagnostics(flag) when is_boolean(flag), do: {:ok, flag}
  defp validate_rich_fk_diagnostics(other), do: {:error, {:invalid_rich_fk_diagnostics, other}}

  # Repo-config hook subscribers: registered NAMES (not pids — config
  # survives restarts, pids don't), resolved at connect time, installed
  # on every pooled connection. Handles are discarded — hooks live and
  # die with the connection.
  @config_hook_kinds [:update, :wal, :commit, :rollback]

  defp register_config_hooks(_conn, []), do: :ok

  defp register_config_hooks(conn, hooks) when is_list(hooks) do
    Enum.reduce_while(hooks, :ok, fn entry, :ok ->
      case register_config_hook(conn, entry) do
        :ok -> {:cont, :ok}
        {:error, _} = err -> {:halt, err}
      end
    end)
  end

  defp register_config_hooks(_conn, other), do: {:error, {:invalid_hooks_config, other}}

  defp register_config_hook(conn, {kind, name})
       when kind in @config_hook_kinds and is_atom(name) do
    with {:ok, pid} <- resolve_hook_subscriber(name),
         {:ok, _handle} <- register_hook_kind(conn, kind, pid) do
      :ok
    end
  end

  defp register_config_hook(conn, {:progress, name}) when is_atom(name) do
    register_config_hook(conn, {:progress, {name, []}})
  end

  defp register_config_hook(conn, {:progress, {name, opts}})
       when is_atom(name) and is_list(opts) do
    with :ok <- validate_progress_opts(opts),
         {:ok, pid} <- resolve_hook_subscriber(name),
         {:ok, _handle} <-
           NIF.register_progress_hook(
             conn,
             pid,
             Keyword.get(opts, :every_n, 1000),
             progress_tag(Keyword.get(opts, :tag))
           ) do
      :ok
    end
  end

  defp register_config_hook(_conn, entry), do: {:error, {:invalid_hook_config, entry}}

  defp resolve_hook_subscriber(name) do
    case Process.whereis(name) do
      nil -> {:error, {:hook_subscriber_not_registered, name}}
      pid -> {:ok, pid}
    end
  end

  defp register_hook_kind(conn, :update, pid), do: NIF.register_update_hook(conn, pid)
  defp register_hook_kind(conn, :wal, pid), do: NIF.register_wal_hook(conn, pid)
  defp register_hook_kind(conn, :commit, pid), do: NIF.register_commit_hook(conn, pid)
  defp register_hook_kind(conn, :rollback, pid), do: NIF.register_rollback_hook(conn, pid)

  # A raise out of connect/1 crashes the connection process instead of
  # returning the structured error DBConnection retries with backoff — a
  # misconfigured hook took a whole repo supervision tree down in
  # milliseconds. Every progress option is validated to a refusal in the
  # same tag-tuple family as the connect validators; unknown keys refuse
  # too (a typo would otherwise silently mean the default), and a
  # non-keyword opts list refuses instead of silently meaning defaults.
  defp validate_progress_opts(opts) do
    if Keyword.keyword?(opts) do
      Enum.reduce_while(opts, :ok, fn
        {:every_n, n}, :ok when is_integer(n) and n >= 1 -> {:cont, :ok}
        {:tag, t}, :ok when is_atom(t) -> {:cont, :ok}
        {key, value}, :ok -> {:halt, {:error, {:invalid_hook_option, {key, value}}}}
      end)
    else
      {:error, {:invalid_hook_config, {:progress, opts}}}
    end
  end

  defp progress_tag(nil), do: nil
  defp progress_tag(tag) when is_atom(tag), do: Atom.to_string(tag)

  defp validate_transaction_mode(mode) when mode in [:deferred, :immediate, :exclusive] do
    {:ok, mode}
  end

  defp validate_transaction_mode(other) do
    {:error, {:invalid_default_transaction_mode, other}}
  end

  defp open_database(database, :readwrite), do: NIF.open(database)
  defp open_database(database, :readonly), do: NIF.open_readonly(database)

  # Write-requiring pragmas are skipped on read-only connections: setting
  # journal_mode / auto_vacuum / wal_autocheckpoint needs write access, and
  # checkpointing cannot run on a read-only handle anyway.
  defp writable(value, :readwrite), do: value
  defp writable(_value, :readonly), do: nil

  # SQLite refuses a journal-mode conversion against a concurrently held
  # write lock in ~1 ms WITHOUT consulting the busy handler, so a fresh
  # pool racing itself to convert a new file lost a member on most first
  # boots and busy_timeout could not help (measured up to 120 s). The
  # loser succeeds ~1 ms later, so the driver does the waiting SQLite
  # refuses to — the cap is generous against a measured need of one
  # retry; a lock held longer than the cap still fails structurally.
  @journal_mode_attempts 10

  defp set_journal_mode(conn, value, mode) do
    set_journal_mode(conn, value, mode, @journal_mode_attempts)
  end

  defp set_journal_mode(_conn, _value, :readonly, _attempts_left), do: {:ok, :skipped}

  defp set_journal_mode(conn, value, :readwrite, attempts_left) do
    case NIF.set_pragma(conn, "journal_mode", value) do
      {:ok, _} = ok ->
        ok

      {:error, {:database_busy_or_locked, _code, _msg}} when attempts_left > 1 ->
        Process.sleep(2)
        set_journal_mode(conn, value, :readwrite, attempts_left - 1)

      {:error, _} = err ->
        err
    end
  end

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
  def disconnect(err, state) do
    # Finalize every cached statement before closing: sqlite3_close with
    # outstanding statements leaks the handle until process exit.
    Enum.each(state.stmt_cache, fn {_sql, stmt} -> NIF.stmt_finalize(stmt) end)

    NIF.close(state.conn)

    emit(
      [:xqlite_ecto3, :disconnect],
      %{monotonic_time: XqliteEcto3.Telemetry.monotonic_time()},
      %{conn: state.conn, reason: err}
    )

    :ok
  end

  # DBConnection calls this ONCE per connection, right after connect — not
  # once per pool checkout. So it is the first read of SQLite's transaction
  # state, not a repair pass that runs between clients: keeping the cached
  # flag truthful afterwards belongs to handle_begin/commit/rollback and, for
  # transaction control that arrives as ordinary SQL, to
  # sync_after_transaction_control/2. The savepoint counter starts at 0
  # because we only ever track our own managed savepoint stack.
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
        case {mode, state.transaction_status} do
          {:savepoint, :transaction} ->
            case NIF.savepoint(state.conn, savepoint_name(state, state.savepoint)) do
              :ok ->
                {:ok, nil, %{state | savepoint: state.savepoint + 1}}

              {:error, reason} ->
                {:disconnect, XqliteEcto3.Error.wrap(reason), state}
            end

          {:savepoint, _no_enclosing_transaction} ->
            # A lone SAVEPOINT opens the transaction DEFERRED, silently
            # discarding default_transaction_mode; under write contention the
            # deferred snapshot loses its write with an instant busy error
            # SQLite never routes through the busy handler. Refuse instead.
            {:disconnect,
             %DBConnection.ConnectionError{
               message:
                 "mode: :savepoint requires an enclosing transaction — a lone SAVEPOINT " <>
                   "runs the transaction :deferred, discarding default_transaction_mode. " <>
                   "Drop the mode: option for a top-level transaction."
             }, state}

          {_mode, _status} ->
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
                {:ok, nil, released_savepoint_state(state)}

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
              {:ok, nil, released_savepoint_state(state)}
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
            {:ok, query, %{result | num_rows: changes, rows: nil},
             sync_after_transaction_control(state, sql)}

          {:ok, result} ->
            {:ok, query, result, state}

          {:error, :operation_cancelled} ->
            disconnect_if_rolled_back(
              %DBConnection.ConnectionError{message: "query timed out"},
              state
            )

          {:error, reason} ->
            reason
            |> wrap_execute_error(sql, params, state)
            |> disconnect_if_rolled_back(state)
        end

      classify_dbc(result, start_md)
    end
  end

  # A statement error can take the whole transaction with it: a constraint
  # declared ON CONFLICT ROLLBACK, an OR ROLLBACK statement, or a CANCELLED
  # write (SQLite rolls back the whole transaction when it interrupts an
  # INSERT/UPDATE/DELETE) makes SQLite roll back and return to autocommit
  # while the driver still believes a transaction is open. Letting the body continue would run
  # its statements in autocommit — durably committing writes inside a
  # transaction that will report failure. Disconnect at the point of
  # damage instead, so DBConnection tears the transaction down and no
  # later statement can run. One cheap status read, on the error path
  # only, only while a transaction is supposed to be open. A failed status
  # read means the connection itself is unusable — disconnect, the same
  # disposition checkout/1 and ping/1 give that error.
  defp disconnect_if_rolled_back(wrapped, %__MODULE__{transaction_status: :transaction} = state) do
    case NIF.transaction_status(state.conn) do
      {:ok, true} -> {:error, wrapped, state}
      {:ok, false} -> {:disconnect, wrapped, state}
      {:error, _read_failed} -> {:disconnect, wrapped, state}
    end
  end

  defp disconnect_if_rolled_back(wrapped, state), do: {:error, wrapped, state}

  # BEGIN/COMMIT/ROLLBACK/SAVEPOINT/RELEASE run as ordinary SQL (Repo.query,
  # Ecto.Adapters.SQL.query) never reach handle_begin & friends, so without
  # this the cached flag the guard above reads would stay stale for the whole
  # life of the connection: checkout/1 syncs it once, right after connect, and
  # DBConnection never calls it again. Re-read SQLite's real state after any
  # columnless statement whose leading keyword is transaction control. A
  # statement that returns columns never gets here at all, and for the ones
  # that do, a statement not starting with one of these keywords' letters
  # costs a single leading-byte test; the status read runs only on the
  # handful of statements whose whole keyword matches.
  @transaction_control ["BEGIN", "COMMIT", "END", "ROLLBACK", "SAVEPOINT", "RELEASE"]
  @transaction_control_initials [?B, ?C, ?E, ?R, ?S, ?b, ?c, ?e, ?r, ?s]
  @longest_transaction_control 9

  defp sync_after_transaction_control(state, sql) do
    case leading_keyword(sql) do
      keyword when keyword in @transaction_control -> refresh_transaction_status(state)
      _other -> state
    end
  end

  # With top-level savepoints refused at handle_begin, the enclosing
  # transaction is still open when the outermost managed savepoint releases;
  # the status read is a cheap belt against drift a raw caller bypassing the
  # driver can cause. Nested releases stay read-free.
  defp released_savepoint_state(state) do
    state = %{state | savepoint: state.savepoint - 1}

    case state.savepoint do
      sp when sp <= 0 -> refresh_transaction_status(state)
      _nested -> state
    end
  end

  defp refresh_transaction_status(state) do
    case NIF.transaction_status(state.conn) do
      {:ok, true} -> %{state | transaction_status: :transaction}
      # autocommit means every savepoint is gone too — the managed counter
      # must follow the flag or the next outermost release is misread as
      # nested and skips its status read (the guard then over-disconnects)
      {:ok, false} -> %{state | transaction_status: :idle, savepoint: 0}
      {:error, _reason} -> state
    end
  end

  # SQLite skips comments before the first token: a line comment runs to the
  # next newline, a block comment to the first `*/` (never nested), and either
  # kind may instead run to end of input — in which case no statement executes,
  # so falling through to nil (no sync) is correct.
  defp leading_keyword(<<"--", rest::binary>>) do
    case :binary.match(rest, "\n") do
      {i, 1} -> leading_keyword(binary_part(rest, i + 1, byte_size(rest) - i - 1))
      :nomatch -> nil
    end
  end

  defp leading_keyword(<<"/*", rest::binary>>) do
    case :binary.match(rest, "*/") do
      {i, 2} -> leading_keyword(binary_part(rest, i + 2, byte_size(rest) - i - 2))
      :nomatch -> nil
    end
  end

  # A leading semicolon is an empty statement SQLite steps over, and a UTF-8
  # BOM (what Windows editors put at the start of a .sql file) is skipped by
  # SQLite's tokenizer — both must not hide the transaction keyword behind
  # them from this sync.
  defp leading_keyword(<<c, rest::binary>>) when c in [?\s, ?\t, ?\n, ?\r, ?\f, ?\v, ?;] do
    leading_keyword(rest)
  end

  defp leading_keyword(<<0xEF, 0xBB, 0xBF, rest::binary>>) do
    leading_keyword(rest)
  end

  defp leading_keyword(<<c, _rest::binary>> = sql) when c in @transaction_control_initials do
    length = keyword_length(sql, 0)

    sql
    |> binary_part(0, length)
    |> String.upcase()
  end

  defp leading_keyword(_sql), do: nil

  defp keyword_length(<<c, rest::binary>>, length)
       when length < @longest_transaction_control and (c in ?A..?Z or c in ?a..?z) do
    keyword_length(rest, length + 1)
  end

  defp keyword_length(_rest, length), do: length

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
      {:ok, stmt} ->
        emit(
          [:xqlite_ecto3, :statement_cache, :hit],
          %{
            monotonic_time: System.monotonic_time(:nanosecond),
            cached_count: map_size(state.stmt_cache)
          },
          %{conn: state.conn, sql: sql}
        )

        {:ok, stmt, touch_stmt(state, sql)}

      :error ->
        emit(
          [:xqlite_ecto3, :statement_cache, :miss],
          %{
            monotonic_time: System.monotonic_time(:nanosecond),
            cached_count: map_size(state.stmt_cache)
          },
          %{conn: state.conn, sql: sql}
        )

        prepare_and_cache(state, sql)
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

      emit(
        [:xqlite_ecto3, :statement_cache, :evicted],
        %{
          monotonic_time: System.monotonic_time(:nanosecond),
          cached_count: map_size(state.stmt_cache)
        },
        %{conn: state.conn, sql: evicted_key}
      )

      %{state | stmt_cache: cache, stmt_cache_keys: kept_keys}
    else
      state
    end
  end

  defp run_cached_stmt(conn, stmt, params, timeout) do
    case NIF.stmt_bind(stmt, params) do
      :ok ->
        total_before = conn_total_changes(conn)
        step_to_completion(conn, stmt, total_before, timeout)

      {:error, _} = err ->
        pristine_stmt(stmt)
        err
    end
  end

  defp step_to_completion(conn, stmt, total_before, :infinity) do
    collect_rows(conn, stmt, total_before, [], [])
  end

  defp step_to_completion(conn, stmt, total_before, timeout) when is_integer(timeout) do
    {:ok, token} = NIF.create_cancel_token()
    canceller = spawn_canceller(token, timeout)

    try do
      collect_rows(conn, stmt, total_before, [token], [])
    after
      send(canceller, :stop)
    end
  end

  defp collect_rows(conn, stmt, total_before, tokens, acc) do
    case NIF.stmt_multi_step_cancellable(stmt, @stmt_batch_size, tokens) do
      {:ok, %{rows: rows, done: false}} ->
        collect_rows(conn, stmt, total_before, tokens, [rows | acc])

      {:ok, %{rows: rows, done: true}} ->
        finish_cached_stmt(conn, stmt, total_before, Enum.reverse([rows | acc]))

      {:error, _} = err ->
        pristine_stmt(stmt)
        err
    end
  end

  defp finish_cached_stmt(conn, stmt, total_before, row_batches) do
    rows = Enum.concat(row_batches)
    {:ok, columns} = NIF.stmt_column_names(stmt)
    changes = changes_since(conn, total_before)
    pristine_stmt(stmt)

    {:ok, %{columns: columns, rows: rows, num_rows: length(rows), changes: changes}}
  end

  # sqlite3_changes() is sticky — it keeps the last DML's count across
  # intervening SELECT/DDL/PRAGMA statements. An empty-columns heuristic for
  # "did this change rows" is wrong twice: RETURNING DML has columns yet
  # changed rows, and DDL/PRAGMA has none yet must report 0, not the stale
  # count. Gate on sqlite3_total_changes() moving instead, mirroring
  # query_with_changes. Reading these counters here is safe because
  # DBConnection holds this connection exclusively for the whole
  # handle_execute call — nothing can interleave another write.
  defp changes_since(conn, total_before) do
    if conn_total_changes(conn) == total_before do
      0
    else
      conn_changes(conn)
    end
  end

  defp conn_total_changes(conn) do
    case NIF.total_changes(conn) do
      {:ok, n} -> n
      {:error, _} -> 0
    end
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

  # A UNIQUE violation names only the table and columns, so the real
  # index name is read back from the database here — bounded read-only
  # pragma lookups on a path that has already failed, always on.
  defp wrap_execute_error(reason, sql, params, %__MODULE__{rich_fk_diagnostics: true} = state) do
    reason
    |> XqliteEcto3.FkDiagnostics.wrap_with_replay(state.conn, sql, params)
    |> XqliteEcto3.UniqueIndexNames.resolve(state.conn)
    |> put_statement(sql)
  end

  defp wrap_execute_error(reason, sql, _params, state) do
    reason
    |> XqliteEcto3.Error.wrap()
    |> XqliteEcto3.UniqueIndexNames.resolve(state.conn)
    |> put_statement(sql)
  end

  defp put_statement(%XqliteEcto3.Error{} = err, sql), do: %{err | statement: sql}

  @impl DBConnection
  def handle_close(_query, _opts, state) do
    {:ok, nil, state}
  end

  @impl DBConnection
  def handle_declare(query, params, opts, state) do
    sql = IO.iodata_to_binary(query.statement)
    start_md = %{conn: state.conn, query: query, sql: sql}

    span_with_stop_metadata [:xqlite_ecto3, :handle_declare], start_md do
      # No unique-index name lookup on this path. Streamed DML (an
      # INSERT ... RETURNING through Ecto.Adapters.SQL.stream/4) CAN
      # violate UNIQUE here; its error stays correctly classified but
      # reports unique_index_lookup: :not_run — no changeset traverses
      # a stream, so the resolved names have no consumer on this path.
      result =
        case NIF.stream_open(state.conn, sql, params) do
          {:ok, handle} ->
            case NIF.stream_get_columns(handle) do
              {:ok, columns} ->
                batch_size = batch_size_from_opts(opts)

                {:ok, query, %{handle: handle, columns: columns, batch_size: batch_size}, state}

              {:error, reason} ->
                NIF.stream_close(handle)

                reason
                |> XqliteEcto3.Error.wrap()
                |> put_statement(sql)
                |> disconnect_if_rolled_back(state)
            end

          {:error, reason} ->
            reason
            |> XqliteEcto3.Error.wrap()
            |> put_statement(sql)
            |> disconnect_if_rolled_back(state)
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
            reason
            |> XqliteEcto3.Error.wrap()
            |> disconnect_if_rolled_back(state)
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
