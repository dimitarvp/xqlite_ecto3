defmodule XqliteEcto3.WithXqliteStatusLawTest do
  @moduledoc """
  `XqliteEcto3.with_xqlite/3` hands the raw SQLite connection to a
  callback, and a callback can run transaction control on it: `BEGIN`,
  `SAVEPOINT`, `COMMIT`, `ROLLBACK`. None of that passes the adapter's
  statement path, which is where the driver otherwise notices
  transaction control and re-reads SQLite's real state — so without a
  read of its own the driver would go on believing no transaction was
  open while one was, and the next `Repo.transaction/1` on that
  connection would issue a `BEGIN` SQLite refuses.

  ## The law

  Over sequences of raw transaction control run on the handle the
  bridge gives out, the transaction status the driver has cached once
  the callback is over is what `XqliteNIF.transaction_status/1` answers
  on that same connection.

  An order SQLite refuses — a `COMMIT` with nothing open, a `RELEASE`
  naming a savepoint that never existed — is part of the generated
  domain on purpose: a refused statement changes nothing, and the cache
  has to agree with SQLite there too.

  ## Why the raising path is the one that shows it

  `DBConnection.run/3`, which the bridge is built on, reads the status
  itself before and after the callback and refuses the call when the two
  differ, dropping the connection. So a callback that opens a
  transaction and returns normally is caught there whatever the driver
  caches. A callback that raises is not: `DBConnection` checks the
  connection back in without that comparison, and what the next
  transaction on that connection is told is decided by the cached status
  alone.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Ecto.Integration.PoolRepo
  alias XqliteEcto3.Driver
  alias XqliteEcto3.RawConn
  alias XqliteNIF, as: NIF

  @law_runs 2000

  @control [
    "BEGIN",
    "BEGIN DEFERRED",
    "BEGIN IMMEDIATE",
    "BEGIN EXCLUSIVE",
    "SAVEPOINT sp",
    "RELEASE sp",
    "ROLLBACK TO sp",
    "COMMIT",
    "END",
    "ROLLBACK"
  ]

  setup_all do
    PoolRepo.query!("CREATE TABLE IF NOT EXISTS bridge_status_rows (n INTEGER NOT NULL)")
    :ok
  end

  describe "the status the bridge leaves cached" do
    property "is what SQLite answers, whatever the callback ran" do
      state = XqliteEcto3.DriverHelper.connect!()

      check all(sequence <- control_sequence(), max_runs: @law_runs) do
        _ = NIF.query(state.conn, "ROLLBACK", [])

        Enum.each(sequence, fn sql -> _ = NIF.query(state.conn, sql, []) end)

        assert {:ok, open?} = NIF.transaction_status(state.conn)
        assert {:ok, _query, _conn, synced} = Driver.handle_execute(%RawConn{}, [], [], state)
        assert synced.transaction_status == cached_for(open?)
      end
    end

    test "is :transaction after a raw BEGIN the callback ran" do
      state = XqliteEcto3.DriverHelper.connect!()

      assert {:ok, _} = NIF.query(state.conn, "BEGIN", [])

      assert {:ok, _query, _conn, synced} = Driver.handle_execute(%RawConn{}, [], [], state)
      assert synced.transaction_status == :transaction
    end

    test "is :idle after a raw BEGIN the callback closed again" do
      state = XqliteEcto3.DriverHelper.connect!()

      assert {:ok, _} = NIF.query(state.conn, "BEGIN", [])
      assert {:ok, _} = NIF.query(state.conn, "COMMIT", [])

      assert {:ok, _query, _conn, synced} = Driver.handle_execute(%RawConn{}, [], [], state)
      assert synced.transaction_status == :idle
    end
  end

  describe "a transaction the callback opened and did not close" do
    test "is what the next transaction on that pooled connection is told" do
      assert_raise RuntimeError, fn ->
        XqliteEcto3.with_xqlite(PoolRepo, fn conn ->
          assert {:ok, _} = NIF.query(conn, "BEGIN", [])
          assert {:ok, _} = NIF.query(conn, "INSERT INTO bridge_status_rows (n) VALUES (7)", [])
          raise "the callback gave up with the transaction open"
        end)
      end

      assert PoolRepo.transaction(fn -> :ok end) == {:error, :rollback}
      assert PoolRepo.query!("SELECT count(*) FROM bridge_status_rows WHERE n = 7").rows == [[0]]
      assert PoolRepo.transaction(fn -> :ok end) == {:ok, :ok}
    end

    # The returning path never reaches the driver's cached status:
    # DBConnection compares its own two reads first and refuses.
    test "returning instead of raising is refused by the checkout's own status check" do
      assert_raise DBConnection.ConnectionError, fn ->
        XqliteEcto3.with_xqlite(PoolRepo, fn conn ->
          assert {:ok, _} = NIF.query(conn, "BEGIN", [])
          assert {:ok, _} = NIF.query(conn, "INSERT INTO bridge_status_rows (n) VALUES (8)", [])
        end)
      end

      assert PoolRepo.query!("SELECT count(*) FROM bridge_status_rows WHERE n = 8").rows == [[0]]
      assert PoolRepo.transaction(fn -> :ok end) == {:ok, :ok}
    end

    test "closed again inside the callback leaves the next transaction free to open" do
      XqliteEcto3.with_xqlite(PoolRepo, fn conn ->
        assert {:ok, _} = NIF.query(conn, "BEGIN", [])
        assert {:ok, _} = NIF.query(conn, "COMMIT", [])
      end)

      assert PoolRepo.transaction(fn -> :done end) == {:ok, :done}
    end
  end

  defp control_sequence do
    StreamData.list_of(StreamData.member_of(@control), min_length: 1, max_length: 6)
  end

  defp cached_for(true), do: :transaction
  defp cached_for(false), do: :idle
end
