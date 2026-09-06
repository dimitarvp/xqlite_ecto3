defmodule XqliteEcto3.StreamTransactionControlLawTest do
  @moduledoc """
  The rule the streaming path has to obey: after a statement has run
  through `handle_declare` and `handle_fetch`, the transaction flag the
  driver keeps in its own state says what SQLite says.

  `Ecto.Adapters.SQL.stream/4` can carry any SQL, transaction control
  included, and a declared cursor executes nothing until its first fetch
  — so the flag has to be re-read there, the way the ordinary execute
  path re-reads it. A stale flag is not cosmetic: the next
  `Repo.transaction` sees `:idle`, issues a real `BEGIN` on a connection
  that is already inside a transaction, and SQLite refuses it. The
  driver then drops the connection, and everything written since the
  streamed `BEGIN` rolls back with it.

  The generated domain is every transaction-control keyword the driver
  recognises, in the state where that keyword is legal, spelled in the
  forms SQLite's tokenizer skips over: upper and lower case, leading
  whitespace, a line comment, a block comment. Ordinary statements are
  in the domain too — they must leave the flag alone.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias XqliteEcto3.Driver
  alias XqliteEcto3.Query
  alias XqliteNIF, as: NIF

  @law_runs 2000

  @from_idle ["BEGIN", "BEGIN IMMEDIATE", "BEGIN DEFERRED", "BEGIN EXCLUSIVE", "SAVEPOINT sp_law"]

  @from_open ["COMMIT", "END", "ROLLBACK", "SAVEPOINT sp_law"]

  @ordinary ["SELECT 1", "SELECT 1 WHERE 0"]

  setup do
    db_path =
      Path.join(
        System.tmp_dir!(),
        "xqlite_ecto3_stream_txn_#{:erlang.unique_integer([:positive])}.db"
      )

    {:ok, state} = Driver.connect(database: db_path, journal_mode: :memory, busy_timeout: 1_000)

    on_exit(fn ->
      Driver.disconnect(:normal, state)
      Enum.each(["", "-wal", "-shm"], fn suffix -> File.rm(db_path <> suffix) end)
    end)

    {:ok, state: state, db_path: db_path}
  end

  describe "the cached transaction flag after a statement ran through the stream path" do
    property "equals what SQLite reports", %{state: state} do
      check all(
              {prelude, statement} <- streamed_statement(),
              spelling <- spelling(),
              max_runs: @law_runs
            ) do
        rolled_back = reset_to_autocommit(state)
        opened = open_prelude(rolled_back, prelude)
        streamed = stream_to_completion(opened, spelling.(statement))

        assert streamed.transaction_status == real_status(streamed)
      end
    end

    test "a row written after a streamed BEGIN survives the next begin", %{
      state: state,
      db_path: db_path
    } do
      created = execute!(state, "CREATE TABLE t(x INTEGER)")
      begun = stream_to_completion(created, "BEGIN")
      inserted = execute!(begun, "INSERT INTO t(x) VALUES (1)")

      assert {:transaction, ^inserted} = Driver.handle_begin([], inserted)
      assert {:ok, nil, committed} = Driver.handle_commit([], inserted)

      Driver.disconnect(:normal, committed)

      {:ok, reader} = Driver.connect(database: db_path, journal_mode: :memory)
      on_exit(fn -> Driver.disconnect(:normal, reader) end)

      assert {:ok, _query, %{rows: [[1]]}, _state} =
               Driver.handle_execute(
                 %Query{statement: "SELECT count(*) FROM t"},
                 [],
                 [],
                 reader
               )
    end
  end

  defp execute!(state, sql) do
    {:ok, _query, _result, state} =
      Driver.handle_execute(%Query{statement: sql}, [], [], state)

    state
  end

  defp stream_to_completion(state, sql) do
    query = %Query{statement: sql}
    {:ok, _query, cursor, state} = Driver.handle_declare(query, [], [], state)
    state = fetch_until_done(query, cursor, state)
    {:ok, _result, state} = Driver.handle_deallocate(query, cursor, [], state)
    state
  end

  defp fetch_until_done(query, cursor, state) do
    case Driver.handle_fetch(query, cursor, [], state) do
      {:cont, _result, state} -> fetch_until_done(query, cursor, state)
      {:halt, _result, state} -> state
    end
  end

  defp open_prelude(state, :idle), do: state

  defp open_prelude(state, :open) do
    {:ok, nil, state} = Driver.handle_begin([], state)
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

  defp streamed_statement do
    StreamData.one_of([
      StreamData.map(StreamData.member_of(@from_idle ++ @ordinary), fn sql -> {:idle, sql} end),
      StreamData.map(StreamData.member_of(@from_open ++ @ordinary), fn sql -> {:open, sql} end)
    ])
  end

  defp spelling do
    StreamData.member_of([
      &Function.identity/1,
      &String.downcase/1,
      &("   " <> &1),
      &("-- a comment\n" <> &1),
      &("/* a comment */ " <> &1),
      &("\n\t" <> &1)
    ])
  end
end
