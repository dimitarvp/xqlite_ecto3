defmodule XqliteEcto3.DriverTransactionModeTest do
  use ExUnit.Case, async: true

  import XqliteEcto3.DriverHelper, only: [connect!: 1]

  alias XqliteEcto3.Driver
  alias XqliteNIF, as: NIF

  # sqlite3_txn_state: BEGIN DEFERRED acquires no lock until the first
  # statement (:none), while IMMEDIATE/EXCLUSIVE take the write lock at
  # BEGIN (:write) — the structural way to observe which mode ran.
  defp txn_state!(conn) do
    assert {:ok, txn_state} = NIF.txn_state(conn)
    txn_state
  end

  test "the default mode is BEGIN IMMEDIATE" do
    state = connect!([])

    assert {:ok, nil, state} = Driver.handle_begin([], state)
    assert txn_state!(state.conn) == :write
    assert {:ok, nil, _state} = Driver.handle_rollback([], state)
  end

  test "default_transaction_mode: :deferred acquires no lock at begin" do
    state = connect!(default_transaction_mode: :deferred)

    assert {:ok, nil, state} = Driver.handle_begin([], state)
    assert txn_state!(state.conn) == :none
    assert {:ok, nil, _state} = Driver.handle_rollback([], state)
  end

  test "a per-transaction mode overrides the connect-time default" do
    state = connect!(default_transaction_mode: :deferred)

    assert {:ok, nil, state} = Driver.handle_begin([mode: :exclusive], state)
    assert txn_state!(state.conn) == :write
    assert {:ok, nil, _state} = Driver.handle_rollback([], state)
  end

  test "an invalid per-transaction mode disconnects with a typed error" do
    state = connect!([])

    assert {:disconnect,
            %XqliteEcto3.Error{type: :invalid_transaction_mode, details: %{mode: :bogus}}, _state} =
             Driver.handle_begin([mode: :bogus], state)
  end

  test "a lock-contended BEGIN keeps the connection" do
    db_path =
      Path.join(
        System.tmp_dir!(),
        "xqlite_ecto3_busy_begin_#{:erlang.unique_integer([:positive])}.db"
      )

    on_exit(fn -> File.rm(db_path) end)

    holder = connect!(database: db_path, busy_timeout: 200)
    assert {:ok, nil, holder} = Driver.handle_begin([], holder)

    state = connect!(database: db_path, busy_timeout: 200)

    assert {:error, %XqliteEcto3.Error{type: :database_busy_or_locked}, state} =
             Driver.handle_begin([], state)

    probe = %XqliteEcto3.Query{statement: "SELECT 1", ref: make_ref()}
    assert {:ok, _query, %{rows: [[1]]}, _state} = Driver.handle_execute(probe, [], [], state)
    assert {:ok, nil, _holder} = Driver.handle_rollback([], holder)
  end

  test "an invalid default_transaction_mode is a structured connect error" do
    assert {:error, %XqliteEcto3.Error{type: :invalid_default_transaction_mode}} =
             Driver.connect(database: ":memory:", default_transaction_mode: :often)
  end
end
