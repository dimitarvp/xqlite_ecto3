defmodule XqliteEcto3.DriverTransactionStateTest do
  use ExUnit.Case, async: true

  alias XqliteEcto3.Driver
  alias XqliteNIF, as: NIF

  setup do
    db_path =
      Path.join(
        System.tmp_dir!(),
        "xqlite_ecto3_drv_txn_#{:erlang.unique_integer([:positive])}.db"
      )

    {:ok, state} =
      Driver.connect(
        database: db_path,
        journal_mode: :memory,
        busy_timeout: 1_000
      )

    on_exit(fn ->
      File.rm(db_path)
    end)

    {:ok, state: state, db_path: db_path}
  end

  describe "handle_status/2 reflects real SQLite transaction state" do
    test "fresh connection reports :idle", %{state: state} do
      assert {:idle, _state} = Driver.handle_status([], state)
    end

    test "after handle_begin reports :transaction", %{state: state} do
      {:ok, _result, state} = Driver.handle_begin([], state)
      assert {:transaction, _state} = Driver.handle_status([], state)
    end

    test "after handle_commit reports :idle", %{state: state} do
      {:ok, _result, state} = Driver.handle_begin([], state)
      {:ok, _result, state} = Driver.handle_commit([], state)
      assert {:idle, _state} = Driver.handle_status([], state)
    end

    test "after handle_rollback reports :idle", %{state: state} do
      {:ok, _result, state} = Driver.handle_begin([], state)
      {:ok, _result, state} = Driver.handle_rollback([], state)
      assert {:idle, _state} = Driver.handle_status([], state)
    end

    test "after raw BEGIN via direct NIF reports :transaction", %{state: state} do
      {:ok, _} = NIF.query(state.conn, "BEGIN", [])
      assert {:transaction, _state} = Driver.handle_status([], state)
    end

    test "after raw COMMIT via direct NIF reports :idle", %{state: state} do
      {:ok, _} = NIF.query(state.conn, "BEGIN", [])
      {:ok, _} = NIF.query(state.conn, "COMMIT", [])
      assert {:idle, _state} = Driver.handle_status([], state)
    end

    test "after raw ROLLBACK via direct NIF reports :idle", %{state: state} do
      {:ok, _} = NIF.query(state.conn, "BEGIN", [])
      {:ok, _} = NIF.query(state.conn, "ROLLBACK", [])
      assert {:idle, _state} = Driver.handle_status([], state)
    end

    test "mixed: raw BEGIN then handle_commit does not crash", %{state: state} do
      {:ok, _} = NIF.query(state.conn, "BEGIN", [])
      {:ok, _result, state} = Driver.handle_commit([], state)
      assert {:idle, _state} = Driver.handle_status([], state)
    end

    test "mixed: handle_begin then raw COMMIT leaves status :idle", %{state: state} do
      {:ok, _result, state} = Driver.handle_begin([], state)
      {:ok, _} = NIF.query(state.conn, "COMMIT", [])
      assert {:idle, _state} = Driver.handle_status([], state)
    end
  end

  describe "savepoint counter lifecycle" do
    test "fresh connection has savepoint counter 0", %{state: state} do
      assert state.savepoint == 0
    end

    test "savepoint begin increments counter", %{state: state} do
      {:ok, _result, state} = Driver.handle_begin([], state)
      {:ok, _result, state} = Driver.handle_begin([mode: :savepoint], state)
      assert state.savepoint == 1
      {:ok, _result, state} = Driver.handle_begin([mode: :savepoint], state)
      assert state.savepoint == 2
    end

    test "savepoint commit decrements counter", %{state: state} do
      {:ok, _result, state} = Driver.handle_begin([], state)
      {:ok, _result, state} = Driver.handle_begin([mode: :savepoint], state)
      {:ok, _result, state} = Driver.handle_begin([mode: :savepoint], state)
      assert state.savepoint == 2
      {:ok, _result, state} = Driver.handle_commit([mode: :savepoint], state)
      assert state.savepoint == 1
      {:ok, _result, state} = Driver.handle_commit([mode: :savepoint], state)
      assert state.savepoint == 0
    end

    test "full COMMIT resets savepoint counter even if savepoints were active", %{state: state} do
      {:ok, _result, state} = Driver.handle_begin([], state)
      {:ok, _result, state} = Driver.handle_begin([mode: :savepoint], state)
      {:ok, _result, state} = Driver.handle_commit([mode: :savepoint], state)
      assert state.savepoint == 0

      drifted_state = %{state | savepoint: 42, transaction_status: :transaction}
      {:ok, _result, state} = Driver.handle_commit([], drifted_state)
      assert state.savepoint == 0
      assert state.transaction_status == :idle
    end

    test "full ROLLBACK resets savepoint counter", %{state: state} do
      {:ok, _result, state} = Driver.handle_begin([], state)
      drifted_state = %{state | savepoint: 42}
      {:ok, _result, state} = Driver.handle_rollback([], drifted_state)
      assert state.savepoint == 0
      assert state.transaction_status == :idle
    end

    test "sequential transactions do not leak savepoint counter", %{state: state} do
      {:ok, _result, state} = Driver.handle_begin([], state)
      {:ok, _result, state} = Driver.handle_begin([mode: :savepoint], state)
      {:ok, _result, state} = Driver.handle_begin([mode: :savepoint], state)
      {:ok, _result, state} = Driver.handle_rollback([], state)
      assert state.savepoint == 0

      {:ok, _result, state} = Driver.handle_begin([], state)
      {:ok, _result, state} = Driver.handle_begin([mode: :savepoint], state)
      assert state.savepoint == 1
    end
  end

  describe "handle_status/2 caches the state field" do
    test "fresh connection cache stays :idle", %{state: state} do
      {:idle, state2} = Driver.handle_status([], state)
      assert state2.transaction_status == :idle
    end

    test "handle_status updates stale cache from :idle to :transaction", %{state: state} do
      {:ok, _} = NIF.query(state.conn, "BEGIN", [])
      assert state.transaction_status == :idle
      {:transaction, state2} = Driver.handle_status([], state)
      assert state2.transaction_status == :transaction
    end

    test "handle_status updates stale cache from :transaction to :idle", %{state: state} do
      {:ok, _result, state} = Driver.handle_begin([], state)
      assert state.transaction_status == :transaction
      {:ok, _} = NIF.query(state.conn, "ROLLBACK", [])
      {:idle, state2} = Driver.handle_status([], state)
      assert state2.transaction_status == :idle
    end
  end
end
