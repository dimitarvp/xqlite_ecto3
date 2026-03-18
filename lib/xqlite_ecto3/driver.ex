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
  def handle_status(_, state) do
    {state.transaction_status, state}
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
            {:ok, nil, %{state | transaction_status: :idle}}

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
            {:ok, nil, %{state | transaction_status: :idle}}

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

  @impl DBConnection
  def handle_declare(query, params, _opts, state) do
    sql = IO.iodata_to_binary(query.statement)

    case NIF.stream_open(state.conn, sql, params) do
      {:ok, handle} ->
        case NIF.stream_get_columns(handle) do
          {:ok, columns} ->
            {:ok, query, %{handle: handle, columns: columns}, state}

          {:error, reason} ->
            NIF.stream_close(handle)
            {:error, XqliteEcto3.Error.wrap(reason), state}
        end

      {:error, reason} ->
        {:error, XqliteEcto3.Error.wrap(reason), state}
    end
  end

  @stream_batch_size 500

  @impl DBConnection
  def handle_fetch(_query, cursor, _opts, state) do
    case NIF.stream_fetch(cursor.handle, @stream_batch_size) do
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

  defp execute_with_cancel(conn, sql, params, :infinity) do
    NIF.query_with_changes(conn, sql, params)
  end

  defp execute_with_cancel(conn, sql, params, timeout) do
    {:ok, token} = NIF.create_cancel_token()
    timer_ref = Process.send_after(self(), {:cancel_query, token}, timeout)

    result = NIF.query_with_changes_cancellable(conn, sql, params, token)

    Process.cancel_timer(timer_ref)

    receive do
      {:cancel_query, ^token} -> :ok
    after
      0 -> :ok
    end

    result
  end
end
