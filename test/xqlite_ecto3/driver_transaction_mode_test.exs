defmodule XqliteEcto3.DriverTransactionModeTest do
  use ExUnit.Case, async: true

  alias XqliteEcto3.Driver
  alias XqliteNIF, as: NIF

  defp connect!(opts) do
    assert {:ok, state} = Driver.connect(Keyword.put_new(opts, :database, ":memory:"))
    on_exit(fn -> NIF.close(state.conn) end)
    state
  end

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

  test "an invalid per-transaction mode disconnects with ConnectionError" do
    state = connect!([])

    assert {:disconnect, %DBConnection.ConnectionError{}, _state} =
             Driver.handle_begin([mode: :bogus], state)
  end

  test "an invalid default_transaction_mode is a structured connect error" do
    assert {:error, {:invalid_default_transaction_mode, :often}} =
             Driver.connect(database: ":memory:", default_transaction_mode: :often)
  end
end
