defmodule XqliteEcto3.CancellationTest do
  use ExUnit.Case, async: true

  alias XqliteEcto3.Driver
  alias XqliteNIF, as: NIF

  setup do
    db_path =
      Path.join(
        System.tmp_dir!(),
        "xqlite_ecto3_cancel_#{:erlang.unique_integer([:positive])}.db"
      )

    {:ok, state} =
      Driver.connect(
        database: db_path,
        journal_mode: :memory,
        busy_timeout: 1_000
      )

    slow_sql = """
    WITH RECURSIVE cnt(x) AS (
      SELECT 1 UNION ALL SELECT x + 1 FROM cnt WHERE x < 10000000
    )
    SELECT COUNT(*) FROM cnt
    """

    on_exit(fn -> File.rm(db_path) end)

    {:ok, state: state, slow_sql: slow_sql}
  end

  describe ":timeout in opts is honored" do
    test "sub-second timeout cancels a long-running query", %{state: state, slow_sql: sql} do
      query = %XqliteEcto3.Query{statement: sql, ref: make_ref()}
      started = System.monotonic_time(:millisecond)
      result = Driver.handle_execute(query, [], [timeout: 100], state)
      elapsed = System.monotonic_time(:millisecond) - started

      assert {:error, %DBConnection.ConnectionError{message: "query timed out"}, _} = result
      assert elapsed < 2_000, "cancellation took #{elapsed}ms, expected under 2s"
    end

    test "fast query with short timeout still completes", %{state: state} do
      query = %XqliteEcto3.Query{statement: "SELECT 1", ref: make_ref()}

      assert {:ok, _query, result, _state} =
               Driver.handle_execute(query, [], [timeout: 100], state)

      assert result.rows == [[1]]
    end

    test ":infinity timeout skips cancel token entirely", %{state: state} do
      query = %XqliteEcto3.Query{statement: "SELECT 1", ref: make_ref()}

      assert {:ok, _query, result, _state} =
               Driver.handle_execute(query, [], [timeout: :infinity], state)

      assert result.rows == [[1]]
    end

    test "default 15s timeout is applied when :timeout absent", %{state: state} do
      query = %XqliteEcto3.Query{statement: "SELECT 1", ref: make_ref()}
      assert {:ok, _query, result, _state} = Driver.handle_execute(query, [], [], state)
      assert result.rows == [[1]]
    end

    test "cancel does not leak cancel_query messages into mailbox", %{state: state, slow_sql: sql} do
      receive do
        _ -> :drained
      after
        0 -> :ok
      end

      query = %XqliteEcto3.Query{statement: sql, ref: make_ref()}
      {:error, _, _} = Driver.handle_execute(query, [], [timeout: 50], state)

      refute_received {:cancel_query, _}
    end
  end

  describe "post-cancel connection state" do
    defp exec(state, sql, timeout) do
      query = %XqliteEcto3.Query{statement: sql, ref: make_ref()}
      Driver.handle_execute(query, [], [timeout: timeout], state)
    end

    test "connection is reusable after a cached-path timeout", %{state: state, slow_sql: sql} do
      {:error, %DBConnection.ConnectionError{}, state} = exec(state, sql, 100)

      # A fresh token is created per operation, so the spent one cannot bleed
      # into the next op — a generous-timeout query must complete, not cancel.
      assert {:ok, _q, %{rows: [[1]]}, state} = exec(state, "SELECT 1", 5_000)
      # The cached slow statement is reset after cancel and remains usable.
      assert {:error, %DBConnection.ConnectionError{}, state} = exec(state, sql, 100)
      assert {:ok, _q, %{rows: [[7]]}, _state} = exec(state, "SELECT 7", 5_000)
    end

    test "connection is reusable after a one-shot-path timeout", %{slow_sql: sql} do
      db =
        Path.join(
          System.tmp_dir!(),
          "xqlite_ecto3_cancel_os_#{:erlang.unique_integer([:positive])}.db"
        )

      on_exit(fn -> File.rm(db) end)

      {:ok, state} =
        Driver.connect(database: db, journal_mode: :memory, statement_cache_size: 0)

      {:error, %DBConnection.ConnectionError{}, state} = exec(state, sql, 100)
      assert {:ok, _q, %{rows: [[1]]}, _state} = exec(state, "SELECT 1", 5_000)
    end

    test "timeout inside a transaction leaves it open and rollback-able", %{
      state: state,
      slow_sql: sql
    } do
      {:ok, nil, state} = Driver.handle_begin([], state)
      {:error, %DBConnection.ConnectionError{}, state} = exec(state, sql, 100)

      # Cancellation aborts the statement but not the surrounding transaction.
      assert NIF.txn_state(state.conn, "main") == {:ok, :write}
      assert state.transaction_status == :transaction

      assert {:ok, nil, state} = Driver.handle_rollback([], state)
      assert {:ok, _q, %{rows: [[1]]}, _state} = exec(state, "SELECT 1", 5_000)
    end

    test "rollback after an in-transaction timeout undoes the write", %{
      state: state,
      slow_sql: sql
    } do
      {:ok, _, _, state} =
        exec(state, "CREATE TABLE cancel_txn(id INTEGER PRIMARY KEY, v INTEGER)", 5_000)

      {:ok, _, _, state} = exec(state, "INSERT INTO cancel_txn(id, v) VALUES (1, 100)", 5_000)
      {:ok, nil, state} = Driver.handle_begin([], state)
      {:ok, _, _, state} = exec(state, "UPDATE cancel_txn SET v = 999 WHERE id = 1", 5_000)

      {:error, %DBConnection.ConnectionError{}, state} = exec(state, sql, 100)
      {:ok, nil, state} = Driver.handle_rollback([], state)

      assert {:ok, _q, %{rows: [[100]]}, _state} =
               exec(state, "SELECT v FROM cancel_txn WHERE id = 1", 5_000)
    end
  end

  describe "direct NIF cancellation" do
    test "NIF supports cancel tokens and reports :operation_cancelled", %{
      state: state,
      slow_sql: sql
    } do
      {:ok, token} = NIF.create_cancel_token()
      parent = self()

      spawn_link(fn ->
        Process.sleep(30)
        :ok = NIF.cancel_operation(token)
        send(parent, :cancelled)
      end)

      result = NIF.query_with_changes_cancellable(state.conn, sql, [], [token])
      assert result == {:error, :operation_cancelled}
      assert_received :cancelled
    end
  end
end
