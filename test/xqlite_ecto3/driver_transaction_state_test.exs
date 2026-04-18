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

  describe "checkout/1 syncs state from SQLite" do
    test "fresh connection reports :idle after checkout", %{state: state} do
      {:ok, state2} = Driver.checkout(state)
      assert state2.transaction_status == :idle
      assert state2.savepoint == 0
    end

    test "stale :idle cache is corrected to :transaction after raw BEGIN", %{state: state} do
      {:ok, _} = NIF.query(state.conn, "BEGIN", [])
      drifted = %{state | transaction_status: :idle}
      {:ok, state2} = Driver.checkout(drifted)
      assert state2.transaction_status == :transaction
    end

    test "stale :transaction cache is corrected to :idle after raw COMMIT", %{state: state} do
      drifted = %{state | transaction_status: :transaction, savepoint: 7}
      {:ok, state2} = Driver.checkout(drifted)
      assert state2.transaction_status == :idle
      assert state2.savepoint == 0
    end

    test "savepoint counter is always zeroed on checkout", %{state: state} do
      drifted = %{state | savepoint: 42}
      {:ok, state2} = Driver.checkout(drifted)
      assert state2.savepoint == 0
    end
  end

  describe "disconnect/2 resets transient state fields" do
    test "returns :ok after closing", %{state: state} do
      assert :ok = Driver.disconnect(nil, state)
    end

    test "closes the underlying connection (subsequent query fails)", %{state: state} do
      :ok = Driver.disconnect(nil, state)
      assert {:error, :connection_closed} = NIF.query(state.conn, "SELECT 1", [])
    end
  end

  describe "savepoint names include per-connection random prefix" do
    test "connect generates a hex prefix of expected length", %{state: state} do
      assert is_binary(state.savepoint_prefix)
      # 4 random bytes → 8 lowercase hex characters. Round-trip through
      # Base.decode16 to assert both the length and the hex-lowercase shape
      # without reaching for a regex.
      assert {:ok, raw} = Base.decode16(state.savepoint_prefix, case: :lower)
      assert byte_size(raw) == 4
    end

    test "two independent connections get different prefixes", %{db_path: _} do
      paths =
        for _ <- 1..2 do
          Path.join(
            System.tmp_dir!(),
            "xqlite_ecto3_drv_txn_prefix_#{:erlang.unique_integer([:positive])}.db"
          )
        end

      states =
        Enum.map(paths, fn p ->
          {:ok, s} = Driver.connect(database: p, journal_mode: :memory, busy_timeout: 1_000)
          s
        end)

      on_exit(fn -> Enum.each(paths, &File.rm/1) end)

      [a, b] = states
      assert a.savepoint_prefix != b.savepoint_prefix
    end

    test "managed savepoint creates an entry named xqlite_sp_<prefix>_0", %{state: state} do
      {:ok, _result, state} = Driver.handle_begin([], state)
      {:ok, _result, state} = Driver.handle_begin([mode: :savepoint], state)

      # sqlite_schema doesn't expose savepoints; verify by rolling back to the
      # known name and confirming SQLite accepts it without ERROR.
      name = "xqlite_sp_#{state.savepoint_prefix}_0"
      assert {:ok, _} = NIF.query(state.conn, "ROLLBACK TO SAVEPOINT #{name}", [])
      assert {:ok, _} = NIF.query(state.conn, "RELEASE SAVEPOINT #{name}", [])
      {:ok, _result, _state} = Driver.handle_rollback([], state)
    end

    test "raw SAVEPOINT xqlite_sp_0 by user does not collide with managed stack", %{
      state: state
    } do
      {:ok, _result, state} = Driver.handle_begin([], state)

      # User runs a raw SAVEPOINT using the old naming scheme.
      {:ok, _} = NIF.query(state.conn, "SAVEPOINT xqlite_sp_0", [])

      # Managed savepoint on top gets a distinct name due to the prefix.
      {:ok, _result, state} = Driver.handle_begin([mode: :savepoint], state)
      managed_name = "xqlite_sp_#{state.savepoint_prefix}_0"
      refute managed_name == "xqlite_sp_0"

      # Release the managed savepoint via our API.
      {:ok, _result, state} = Driver.handle_commit([mode: :savepoint], state)

      # User's raw savepoint is still on SQLite's stack; release it.
      {:ok, _} = NIF.query(state.conn, "RELEASE SAVEPOINT xqlite_sp_0", [])

      {:ok, _result, _state} = Driver.handle_commit([], state)
    end
  end
end
