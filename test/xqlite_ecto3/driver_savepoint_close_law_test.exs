defmodule XqliteEcto3.DriverSavepointCloseLawTest do
  @moduledoc """
  The rule `handle_commit/2` and `handle_rollback/2` obey in
  `mode: :savepoint`, where the savepoint they close is named from a
  counter the driver keeps rather than from anything SQLite tells it.

  The counter and the connection can disagree. Raw transaction control
  in the caller's own SQL — a `COMMIT`, `ROLLBACK`, `RELEASE` or
  `ROLLBACK TO` run as an ordinary query — ends savepoints the driver
  opened, and under `Ecto.Adapters.SQL.Sandbox` that is an ordinary
  `Repo.query!` away. Two answers follow from it:

    * no transaction open at all — the savepoint is gone with the
      transaction that held it, so the close is refused with
      `:savepoint_without_transaction`;
    * a transaction open with the counter at `0` — a close would name
      index `-1`, a savepoint that never existed, so it is refused with
      `:savepoint_counter_underflow`.

  Both are disconnects: the connection's savepoint state is gone
  underneath the driver, so nothing further can run on it and
  DBConnection replaces it. A status answer (`{:idle, state}`) would
  reach the caller as a bare `{:error, :rollback}` naming nothing.

  What the rule does not cover is a counter above `0` whose savepoints
  a raw `RELEASE` or `ROLLBACK TO` removed. No side-effect-free read
  reveals whether a savepoint exists, and SQLite answers "no such
  savepoint" with the same code and extended code as every other plain
  error, so telling that case apart would mean reading message text.
  It keeps the disconnect it has, carrying the generic
  `:sqlite_failure`.

  The generated domain is the four states a close can meet crossed
  with counters `0..3` and both callbacks. That the pool then replaces
  the connection and serves the next query costs a pool per case, so
  it is one example instead, in `sandbox_savepoint_close_test.exs`,
  which reaches this state through ordinary Ecto calls.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias XqliteEcto3.Driver
  alias XqliteEcto3.Query
  alias XqliteNIF, as: NIF

  @law_runs 2000

  @kinds [:no_transaction, :savepoints_intact, :reopened, :savepoints_removed]

  setup do
    db_path =
      Path.join(
        System.tmp_dir!(),
        "xqlite_ecto3_sp_close_#{:erlang.unique_integer([:positive])}.db"
      )

    {:ok, state} = Driver.connect(database: db_path, journal_mode: :memory, busy_timeout: 1_000)

    on_exit(fn ->
      Driver.disconnect(:normal, state)
      Enum.each(["", "-wal", "-shm"], fn suffix -> File.rm(db_path <> suffix) end)
    end)

    {:ok, state: state, db_path: db_path}
  end

  property "a savepoint close answers :ok with the counter decremented, or a typed error",
           %{state: state} do
    check all(
            kind <- StreamData.member_of(@kinds),
            counter <- integer(0..3),
            close <- StreamData.member_of([:commit, :rollback]),
            max_runs: @law_runs
          ) do
      built = build(state, kind, counter)

      assert_close(close(built, close), kind, counter)
    end
  end

  # --- helpers ----------------------------------------------------------------

  defp close(state, :commit), do: Driver.handle_commit([mode: :savepoint], state)
  defp close(state, :rollback), do: Driver.handle_rollback([mode: :savepoint], state)

  defp assert_close(result, :no_transaction, counter) do
    assert {:disconnect, %XqliteEcto3.Error{} = error, _state} = result
    assert error.type == :savepoint_without_transaction
    assert error.details == %{mode: :savepoint, transaction_status: :idle, savepoint: counter}
  end

  defp assert_close(result, _kind, 0) do
    assert {:disconnect, %XqliteEcto3.Error{} = error, _state} = result
    assert error.type == :savepoint_counter_underflow
    assert error.details == %{mode: :savepoint, savepoint: 0}
  end

  defp assert_close(result, :savepoints_intact, counter) do
    assert {:ok, nil, state} = result
    assert state.savepoint == counter - 1
  end

  defp assert_close(result, _gone, _counter) do
    assert {:disconnect, %XqliteEcto3.Error{type: :sqlite_failure}, _state} = result
  end

  # Each state is built on the one connection: the SQLite side first,
  # then the counter, which is what a raw statement leaves behind.
  defp build(state, kind, counter) do
    built =
      state
      |> reset_to_autocommit()
      |> sqlite_side(kind, counter)

    %{built | savepoint: counter, transaction_status: :transaction}
  end

  defp sqlite_side(state, :no_transaction, _counter), do: state

  defp sqlite_side(state, :savepoints_intact, counter) do
    state
    |> execute!("BEGIN")
    |> open_savepoints(counter)
  end

  defp sqlite_side(state, :reopened, counter) do
    state
    |> execute!("BEGIN")
    |> open_savepoints(counter)
    |> execute!("COMMIT")
    |> execute!("BEGIN")
  end

  defp sqlite_side(state, :savepoints_removed, counter) do
    opened =
      state
      |> execute!("BEGIN")
      |> open_savepoints(counter)

    release_outermost(opened, counter)
  end

  defp open_savepoints(state, counter) do
    Enum.reduce(1..counter//1, state, fn n, acc ->
      :ok = NIF.savepoint(acc.conn, "xqlite_sp_#{acc.savepoint_prefix}_#{n - 1}")
      %{acc | savepoint: n}
    end)
  end

  defp release_outermost(state, 0), do: state

  defp release_outermost(state, _counter) do
    :ok = NIF.release_savepoint(state.conn, "xqlite_sp_#{state.savepoint_prefix}_0")
    state
  end

  defp execute!(state, sql) do
    {:ok, _query, _result, state} = Driver.handle_execute(%Query{statement: sql}, [], [], state)
    state
  end

  defp reset_to_autocommit(state) do
    case NIF.transaction_status(state.conn) do
      {:ok, true} -> execute!(state, "ROLLBACK")
      {:ok, false} -> state
    end
  end
end
