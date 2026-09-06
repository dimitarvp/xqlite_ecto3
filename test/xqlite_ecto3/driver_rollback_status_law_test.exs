defmodule XqliteEcto3.DriverRollbackStatusLawTest do
  @moduledoc """
  The rule `handle_rollback/2` has to obey when the transaction it is
  asked to roll back is already gone.

  Transaction control that runs as ordinary SQL — `COMMIT`, `END`,
  `ROLLBACK`, in any spelling SQLite's tokenizer accepts — ends the
  transaction underneath the driver. DBConnection's callback contract
  covers exactly that case: a `handle_rollback/2` that knows, without a
  side effect, that the transaction status forbids the statement
  answers `{status, state}` instead of issuing it. The status is read
  from SQLite itself, never from the driver's cached flag, which a
  `BEGIN` that bypassed `handle_execute/4` leaves stale.

  What the answer buys is the name of the cause. `Ecto.Adapters.SQL`'s
  test sandbox turns `{:idle, state}` into its own "the sandbox
  transaction was already committed or rolled back" diagnostic, and
  DBConnection turns it into a `DBConnection.TransactionError` carrying
  the status. Either beats SQLite's "cannot rollback - no transaction
  is active", which names neither the sandbox nor the leaked writes.
  What it does not buy is the writes back: a raw `COMMIT` has already
  committed them, and the connection is torn down either way.

  The generated domain is every transaction-control statement that ends
  a transaction, in the forms SQLite skips over: upper and lower case,
  leading whitespace, a line comment, a block comment, a leading and a
  trailing semicolon.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias XqliteEcto3.Driver
  alias XqliteEcto3.Query
  alias XqliteNIF, as: NIF

  @law_runs 2000

  @ends_transaction ["COMMIT", "END", "ROLLBACK", "COMMIT TRANSACTION"]

  @keeps_transaction ["SELECT 1", "SELECT 1 WHERE 0"]

  setup do
    db_path =
      Path.join(
        System.tmp_dir!(),
        "xqlite_ecto3_rollback_status_#{:erlang.unique_integer([:positive])}.db"
      )

    {:ok, state} = Driver.connect(database: db_path, journal_mode: :memory, busy_timeout: 1_000)

    on_exit(fn ->
      Driver.disconnect(:normal, state)
      Enum.each(["", "-wal", "-shm"], fn suffix -> File.rm(db_path <> suffix) end)
    end)

    {:ok, state: state, db_path: db_path}
  end

  describe "a rollback the transaction status forbids" do
    property "answers the status instead of issuing a statement", %{state: state} do
      check all(
              statement <- StreamData.member_of(@ends_transaction),
              spelling <- spelling(),
              max_runs: @law_runs
            ) do
        idle = reset_to_autocommit(state)
        {:ok, nil, open} = Driver.handle_begin([], idle)
        ended = execute!(open, spelling.(statement))

        assert real_status(ended) == :idle
        assert {:idle, answered} = Driver.handle_rollback([], ended)
        assert answered.transaction_status == :idle
        assert answered.savepoint == 0

        # Nothing was issued, so the connection is intact and the next
        # statement runs on it.
        assert {:ok, _query, %{rows: [[1]]}, _state} =
                 Driver.handle_execute(%Query{statement: "SELECT 1"}, [], [], answered)
      end
    end

    property "an open transaction is still rolled back", %{state: state} do
      check all(
              statement <- StreamData.member_of(@keeps_transaction),
              spelling <- spelling(),
              max_runs: @law_runs
            ) do
        idle = reset_to_autocommit(state)
        {:ok, nil, open} = Driver.handle_begin([], idle)
        still_open = execute!(open, spelling.(statement))

        assert real_status(still_open) == :transaction
        assert {:ok, nil, rolled_back} = Driver.handle_rollback([], still_open)
        assert rolled_back.transaction_status == :idle
        assert real_status(rolled_back) == :idle
      end
    end
  end

  # The cached flag is stale-:idle after a BEGIN that never passed
  # through handle_execute/4, so an answer read from it would skip a
  # rollback SQLite needs.
  test "a transaction opened behind the driver's back is still rolled back", %{state: state} do
    idle = reset_to_autocommit(state)
    {:ok, _} = NIF.query(idle.conn, "BEGIN", [])

    assert idle.transaction_status == :idle
    assert {:ok, nil, rolled_back} = Driver.handle_rollback([], idle)
    assert real_status(rolled_back) == :idle
  end

  test "a savepoint rollback with no enclosing transaction keeps today's answer", %{state: state} do
    idle = reset_to_autocommit(state)

    assert {:disconnect, %XqliteEcto3.Error{}, _state} =
             Driver.handle_rollback([mode: :savepoint], idle)
  end

  # The disconnect is DBConnection's, not SQLite's: it builds the error
  # from the status the driver answered, so the reason names the
  # transaction state rather than a refused statement.
  if XqliteEcto3.Telemetry.enabled?() do
    test "the disconnect that follows carries the transaction status", %{db_path: db_path} do
      handler_id = "rollback-status-#{:erlang.unique_integer([:positive])}"
      test_pid = self()

      :telemetry.attach(
        handler_id,
        [:xqlite_ecto3, :disconnect],
        &__MODULE__.forward_disconnect/4,
        %{pid: test_pid}
      )

      on_exit(fn -> :telemetry.detach(handler_id) end)

      {:ok, pool} =
        DBConnection.start_link(Driver,
          database: db_path <> "_pool",
          pool_size: 1,
          journal_mode: :memory
        )

      on_exit(fn -> Enum.each(["", "-wal", "-shm"], &File.rm(db_path <> "_pool" <> &1)) end)

      assert {:error, :done} =
               DBConnection.transaction(pool, fn conn ->
                 {:ok, _} = XqliteEcto3.Connection.query(conn, "COMMIT", [], [])
                 DBConnection.rollback(conn, :done)
               end)

      assert_receive {:disconnected, %DBConnection.TransactionError{status: :idle}}
    end

    @doc false
    def forward_disconnect(_name, _measurements, %{reason: reason}, config) do
      send(config.pid, {:disconnected, reason})
    end
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

  defp real_status(state) do
    case NIF.transaction_status(state.conn) do
      {:ok, true} -> :transaction
      {:ok, false} -> :idle
    end
  end

  defp spelling do
    StreamData.member_of([
      &Function.identity/1,
      &String.downcase/1,
      &("   " <> &1),
      &("-- a comment\n" <> &1),
      &("/* a comment */ " <> &1),
      &("\n\t" <> &1),
      &(&1 <> " ;"),
      &(";" <> &1)
    ])
  end
end
