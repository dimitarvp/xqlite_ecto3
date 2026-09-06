defmodule XqliteEcto3.StreamCancelLawTest do
  @moduledoc """
  `Repo.stream/2` fetches one batch of rows per call, and the `:timeout`
  given to `Repo.stream/2` — or, with none given, the repo's configured
  one — is the deadline for each of those batches. A batch that is still
  running when its deadline passes is cancelled on SQLite's progress
  handler, the same signal a whole statement gets on the execute path,
  and the caller is handed `%DBConnection.ConnectionError{reason:
  :error}`.

  ## The law

  Whatever the batch size and whatever the finite deadline, a batch that
  costs more than the deadline ends in that error, promptly, and the
  connection keeps working afterwards.

  The generated query has to be one that really outlives a deadline of a
  few milliseconds. A recursive query that only counts hands back its
  first batch in a hundredth of a millisecond however long the count runs
  for, and SQLite only looks for a cancel signal every eight steps of its
  virtual machine, so such a batch finishes before anything can stop it.
  Sorting is what makes the first batch expensive: `ORDER BY x DESC` has
  to see all two hundred thousand rows before it can hand back the first
  one, which takes about a tenth of a second — far longer than any
  deadline this file generates.

  The deadline is what a run costs, so the generated range is small on
  purpose; the number of runs is not what shrinks if the property gets
  slow.

  ## The boundaries beside it

  `:infinity` asks for no deadline and drains the same slow query to the
  end. A deadline of zero or less cancels the first batch at once, which
  is again only observable on a batch that does real work. A fast query
  under a short deadline drains completely, because every batch gets its
  own deadline rather than sharing one that the earlier batches spent.
  And the error travels the way `DBConnection` raises it: left alone it
  takes the surrounding `Repo.transaction/1` down with it, caught inside
  the transaction function it leaves the transaction usable.
  """

  use XqliteEcto3.AdapterCase, async: true
  use ExUnitProperties

  @moduletag timeout: 300_000

  @law_runs 2000

  # Wide on purpose: the point is that the fetch comes back at all, not
  # how close to its deadline it lands. Other work on the same machine
  # moves that by hundreds of milliseconds.
  @window_ms 5_000

  @slow_sql """
  WITH RECURSIVE q(x) AS (
    SELECT 1 UNION ALL SELECT x + 1 FROM q WHERE x < 200000
  )
  SELECT x FROM q ORDER BY x DESC
  """

  @fast_sql "SELECT n FROM stream_cancel_rows ORDER BY n"

  setup_all do
    create_table!("stream_cancel_rows", "n INTEGER NOT NULL")
  end

  setup do
    clear_table!("stream_cancel_rows")

    for n <- 1..20 do
      Repo.query!("INSERT INTO stream_cancel_rows (n) VALUES (?)", [n])
    end

    :ok
  end

  describe "the deadline on a batch" do
    property "a batch that outlives its :timeout ends in the deadline error" do
      check all(
              batch_size <- integer(1..20),
              timeout <- integer(-5..20),
              max_runs: @law_runs
            ) do
        started = System.monotonic_time(:millisecond)

        error =
          assert_raise DBConnection.ConnectionError, fn ->
            Repo.transaction(fn -> drain(@slow_sql, max_rows: batch_size, timeout: timeout) end)
          end

        elapsed = System.monotonic_time(:millisecond) - started

        assert error.reason == :error
        assert elapsed < @window_ms, "the fetch came back after #{elapsed}ms"
        assert Repo.query!("SELECT 1").rows == [[1]]
        refute_received {:cancel_query, _}
      end
    end

    test "a slow stream under a 50 ms timeout raises instead of draining" do
      error =
        assert_raise DBConnection.ConnectionError, fn ->
          Repo.transaction(fn -> drain(@slow_sql, max_rows: 500, timeout: 50) end)
        end

      assert error.reason == :error
      assert Repo.query!("SELECT 1").rows == [[1]]
    end
  end

  describe "the boundaries of the deadline" do
    test "a zero timeout cancels the first batch" do
      error =
        assert_raise DBConnection.ConnectionError, fn ->
          Repo.transaction(fn -> drain(@slow_sql, max_rows: 500, timeout: 0) end)
        end

      assert error.reason == :error
    end

    test "a negative timeout cancels the first batch" do
      error =
        assert_raise DBConnection.ConnectionError, fn ->
          Repo.transaction(fn -> drain(@slow_sql, max_rows: 500, timeout: -1) end)
        end

      assert error.reason == :error
    end

    test ":infinity drains the slow query to the end" do
      assert {:ok, 200_000} =
               Repo.transaction(fn ->
                 drain(@slow_sql, max_rows: 500, timeout: :infinity)
               end)
    end

    test "a fast stream under a short timeout drains every batch in order" do
      assert {:ok, rows} =
               Repo.transaction(fn ->
                 Repo
                 |> Ecto.Adapters.SQL.stream(@fast_sql, [], max_rows: 3, timeout: 50)
                 |> Enum.flat_map(fn result -> result.rows end)
               end)

      assert rows == Enum.map(1..20, fn n -> [n] end)
    end
  end

  describe "the deadline inside a transaction" do
    test "left alone it rolls the transaction back and comes out of it" do
      error =
        assert_raise DBConnection.ConnectionError, fn ->
          Repo.transaction(fn ->
            Repo.query!("INSERT INTO stream_cancel_rows (n) VALUES (99)")
            drain(@slow_sql, max_rows: 500, timeout: 20)
          end)
        end

      assert error.reason == :error
      assert Repo.query!("SELECT count(*) FROM stream_cancel_rows WHERE n = 99").rows == [[0]]
      assert Repo.query!("SELECT 1").rows == [[1]]
    end

    test "caught inside the transaction it leaves the transaction usable" do
      assert {:ok, {reason, rows}} =
               Repo.transaction(fn ->
                 error =
                   assert_raise DBConnection.ConnectionError, fn ->
                     drain(@slow_sql, max_rows: 500, timeout: 20)
                   end

                 Repo.query!("INSERT INTO stream_cancel_rows (n) VALUES (98)")
                 {error.reason, Repo.query!("SELECT n FROM stream_cancel_rows WHERE n = 98").rows}
               end)

      assert reason == :error
      assert rows == [[98]]
      assert Repo.query!("SELECT count(*) FROM stream_cancel_rows WHERE n = 98").rows == [[1]]
    end
  end

  defp drain(sql, opts) do
    Repo
    |> Ecto.Adapters.SQL.stream(sql, [], opts)
    |> Enum.reduce(0, fn result, acc -> acc + result.num_rows end)
  end
end
