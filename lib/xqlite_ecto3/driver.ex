defmodule XqliteEcto3.Driver do
  @moduledoc false

  @behaviour DBConnection

  alias XqliteNIF, as: NIF

  defstruct [:conn, :transaction_status, :path, savepoint: 0]

  # connect_timeout is enforced by DBConnection around this call. NIF.open is a
  # blocking dirty-NIF call that cannot be interrupted mid-syscall, so the
  # practical effect is limited to slow filesystems (NFS, network mounts).
  # For local files, sqlite3_open returns near-instantly.
  @impl DBConnection
  def connect(opts) do
    database = Keyword.fetch!(opts, :database)
    busy_timeout = Keyword.get(opts, :busy_timeout, 5_000)
    journal_mode = Keyword.get(opts, :journal_mode, :wal)
    synchronous = Keyword.get(opts, :synchronous, :normal)
    temp_store = Keyword.get(opts, :temp_store, :memory)

    with {:ok, conn} <- NIF.open(database),
         {:ok, _} <- NIF.set_pragma(conn, "busy_timeout", busy_timeout),
         {:ok, _} <- NIF.set_pragma(conn, "journal_mode", to_string(journal_mode)),
         {:ok, _} <- NIF.set_pragma(conn, "foreign_keys", true),
         {:ok, _} <- NIF.set_pragma(conn, "cache_size", -64_000),
         {:ok, _} <- NIF.set_pragma(conn, "synchronous", to_string(synchronous)),
         {:ok, _} <- NIF.set_pragma(conn, "temp_store", to_string(temp_store)) do
      {:ok,
       %__MODULE__{
         conn: conn,
         transaction_status: :idle,
         path: database
       }}
    else
      {:error, reason} -> {:error, reason}
    end
  end

  @impl DBConnection
  def disconnect(_err, state) do
    NIF.close(state.conn)
    :ok
  end

  @impl DBConnection
  def checkout(state) do
    {:ok, state}
  end

  @impl DBConnection
  def ping(state) do
    case NIF.query(state.conn, "SELECT 1", []) do
      {:ok, _} -> {:ok, state}
      {:error, reason} -> {:disconnect, XqliteEcto3.Error.wrap(reason), state}
    end
  end

  @impl DBConnection
  def handle_status(_opts, state) do
    # Query SQLite's actual autocommit state. Users can run raw "BEGIN" /
    # "COMMIT" / "ROLLBACK" via query/execute that bypass handle_begin /
    # handle_commit / handle_rollback, so state.transaction_status alone
    # would drift out of sync. xqlite exposes sqlite3_get_autocommit via
    # transaction_status/1 ({:ok, true} if in a transaction).
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
    case Keyword.get(opts, :mode, :transaction) do
      :savepoint ->
        name = "xqlite_sp_#{state.savepoint}"

        case NIF.savepoint(state.conn, name) do
          :ok ->
            {:ok, nil, %{state | savepoint: state.savepoint + 1}}

          {:error, reason} ->
            {:disconnect, XqliteEcto3.Error.wrap(reason), state}
        end

      _mode ->
        case NIF.begin(state.conn, :immediate) do
          :ok ->
            {:ok, nil, %{state | transaction_status: :transaction}}

          {:error, reason} ->
            {:disconnect, XqliteEcto3.Error.wrap(reason), state}
        end
    end
  end

  @impl DBConnection
  def handle_commit(opts, state) do
    case Keyword.get(opts, :mode, :transaction) do
      :savepoint ->
        name = "xqlite_sp_#{state.savepoint - 1}"

        case NIF.release_savepoint(state.conn, name) do
          :ok ->
            {:ok, nil, %{state | savepoint: state.savepoint - 1}}

          {:error, reason} ->
            {:disconnect, XqliteEcto3.Error.wrap(reason), state}
        end

      _mode ->
        case NIF.commit(state.conn) do
          :ok ->
            # COMMIT ends the outer transaction and implicitly releases all
            # active savepoints. Reset the counter so a fresh transaction
            # starts savepoint naming from 0.
            {:ok, nil, %{state | transaction_status: :idle, savepoint: 0}}

          {:error, reason} ->
            {:disconnect, XqliteEcto3.Error.wrap(reason), state}
        end
    end
  end

  @impl DBConnection
  def handle_rollback(opts, state) do
    case Keyword.get(opts, :mode, :transaction) do
      :savepoint ->
        name = "xqlite_sp_#{state.savepoint - 1}"

        with :ok <- NIF.rollback_to_savepoint(state.conn, name),
             :ok <- NIF.release_savepoint(state.conn, name) do
          {:ok, nil, %{state | savepoint: state.savepoint - 1}}
        else
          {:error, reason} -> {:disconnect, XqliteEcto3.Error.wrap(reason), state}
        end

      _mode ->
        case NIF.rollback(state.conn) do
          :ok ->
            # ROLLBACK ends the outer transaction and implicitly discards all
            # active savepoints. Reset the counter so a fresh transaction
            # starts savepoint naming from 0.
            {:ok, nil, %{state | transaction_status: :idle, savepoint: 0}}

          {:error, reason} ->
            {:disconnect, XqliteEcto3.Error.wrap(reason), state}
        end
    end
  end

  @impl DBConnection
  def handle_prepare(%XqliteEcto3.Query{} = query, _opts, state) do
    {:ok, %{query | ref: make_ref()}, state}
  end

  @impl DBConnection
  def handle_execute(query, params, opts, state) do
    timeout = Keyword.get(opts, :timeout, 15_000)
    sql = IO.iodata_to_binary(query.statement)

    case execute_with_cancel(state.conn, sql, params, timeout) do
      {:ok, %{columns: [], changes: changes} = result} ->
        {:ok, query, %{result | num_rows: changes, rows: nil}, state}

      {:ok, result} ->
        {:ok, query, result, state}

      {:error, :operation_cancelled} ->
        {:error, %DBConnection.ConnectionError{message: "query timed out"}, state}

      {:error, reason} ->
        {:error, XqliteEcto3.Error.wrap(reason), state}
    end
  end

  @impl DBConnection
  def handle_close(_query, _opts, state) do
    {:ok, nil, state}
  end

  # Default number of rows fetched per handle_fetch call when streaming.
  # Users can override via `Repo.stream(query, max_rows: N)` or the equivalent
  # opts passed to DBConnection.stream.
  @default_stream_batch_size 500

  @impl DBConnection
  def handle_declare(query, params, opts, state) do
    sql = IO.iodata_to_binary(query.statement)

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
  end

  @impl DBConnection
  def handle_fetch(_query, cursor, _opts, state) do
    case NIF.stream_fetch(cursor.handle, cursor.batch_size) do
      {:ok, %{rows: rows}} ->
        result = %{
          columns: cursor.columns,
          rows: rows,
          num_rows: length(rows)
        }

        {:cont, result, state}

      :done ->
        {:halt, %{columns: cursor.columns, rows: [], num_rows: 0}, state}

      {:error, reason} ->
        {:error, XqliteEcto3.Error.wrap(reason), state}
    end
  end

  @impl DBConnection
  def handle_deallocate(_query, cursor, _opts, state) do
    NIF.stream_close(cursor.handle)
    {:ok, nil, state}
  end

  # Ecto.Repo.stream/2 uses the `:max_rows` option. DBConnection passes it
  # through to the driver. Respect it, fall back to our default otherwise.
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
      NIF.query_with_changes_cancellable(conn, sql, params, token)
    after
      # Either the query finished before the timer (stop the canceller) or
      # the canceller fired (already exited). Ensure no stray process remains.
      send(canceller, :stop)
    end
  end

  # The query runs synchronously on the caller process via the dirty NIF,
  # so a Process.send_after to self() would never be delivered in time.
  # We need a separate process that actually fires NIF.cancel_operation/1
  # after the timeout elapses. The canceller exits immediately when told
  # to stop (happy path) or after cancelling (timeout path).
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
      # Wait for the canceller to be ready so there's no window where the
      # query could complete before the canceller's `receive` is armed.
      receive do
        {^ref, :ready} -> :ok
      after
        1_000 -> :ok
      end
    end)
  end
end
