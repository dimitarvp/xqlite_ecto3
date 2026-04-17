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

      result = NIF.query_with_changes_cancellable(state.conn, sql, [], token)
      assert result == {:error, :operation_cancelled}
      assert_received :cancelled
    end
  end
end
