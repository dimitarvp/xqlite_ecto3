defmodule XqliteEcto3.DiagnosticsBudgetLawTest do
  @moduledoc """
  Both error-path diagnoses — the unique-index-name lookup and the
  foreign-key replay — read the database back on a statement that has
  already failed, and both bill that work to the caller who is still
  waiting. `:diagnostics_budget_ms` is the wall-clock allowance for
  each of them, taken from the repo configuration at connect and
  carried on the connection.

  Three rules: what sets the allowance, what bounds a diagnosis that
  has started, and what the caller's own deadline leaves for it.

  ## 1. The allowance is the configured number

  It is no longer read back from `PRAGMA busy_timeout`, which cannot
  tell a deliberate `busy_timeout: 0` from a busy policy or observer
  holding the connection's busy slot. So the outcome of a diagnosis
  must not move when `busy_timeout` moves: a zero allowance skips the
  diagnosis whatever the timeout says, and a generous one runs it.

  ## 2. Neither diagnosis outstays its allowance

  A diagnosis is a chain of reads, and each read can block on another
  connection's write lock. The allowance is checked before each read,
  so a diagnosis can overrun by at most the one read that was already
  in flight — never by one read per candidate.

  ## 3. The statement's own deadline caps what a diagnosis may spend

  Both diagnoses bill their reads to a caller who is still waiting on
  the statement that failed, so what is left of that statement's
  timeout caps the allowance: each spends the smaller of the
  configured allowance and what the deadline leaves once a fixed
  reserve is set aside for the error path that follows. Only a
  deadline already inside that reserve skips a diagnosis whole. A
  configured allowance of `0` still means off, deadline or no
  deadline.

  ## 4. A read the allowance outlives is cancelled

  The foreign-key replay's reads run under a cancel token fired at the
  allowance, so a `PRAGMA foreign_key_check` that scans a large
  database stops where it is and the diagnosis reports
  `{:unavailable, :operation_cancelled}`. The one wait the token does
  not shorten is another connection's write lock: SQLite's busy
  handler never runs the progress handler a cancel signals, so the
  read waits the lock out and only then reports the cancel.

  The contended properties run a real second connection that takes
  `BEGIN EXCLUSIVE` on the same rollback-journal database, holds it
  for a fixed span, and commits. Their run counts are small on
  purpose: each run has to sit through that real lock wait, which no
  amount of generated variety makes cheaper. The assertions are not
  weakened for it — each run still pins the structured outcome and a
  wall-clock ceiling.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias XqliteEcto3.Error
  alias XqliteEcto3.Error.Constraint
  alias XqliteEcto3.FkDiagnostics
  alias XqliteEcto3.UniqueIndexNames

  # How long the second connection keeps the write lock, and how much
  # wall-clock noise a ceiling tolerates: a slow CI runner adds hundreds
  # of milliseconds of scheduling, and the ceiling only has to stay far
  # below the 5 s busy_timeout the connections run under.
  @hold_ms 60
  @slack_ms 2_000

  @moduletag timeout: 300_000

  @uncontended_runs 2000
  @contended_runs 30

  # How many child rows make one PRAGMA foreign_key_check scan outlive a
  # few milliseconds, and how many runs the property that needs a real
  # partial scan gets: every run pays a slice of that scan, which no
  # amount of generated variety makes cheaper.
  @scan_rows 500_000
  @scan_runs 30

  # What the lookup leaves of the statement's deadline for the error
  # path that follows it.
  @reserve_ms 20

  # An allowance this size is never spent by uncontended pragma reads,
  # so a property asserting that the lookup resolves stays about the
  # rule rather than about the machine it runs on.
  @ample_ms 200

  setup do
    path =
      Path.join(
        System.tmp_dir!(),
        "xqlite_ecto3_budget_#{:erlang.unique_integer([:positive])}.db"
      )

    remove_database(path)

    {:ok, writer} = XqliteNIF.open(path)
    {:ok, conn} = XqliteNIF.open(path)

    on_exit(fn ->
      XqliteNIF.close(writer)
      XqliteNIF.close(conn)
      remove_database(path)
    end)

    {:ok, _} = XqliteNIF.set_pragma(writer, "busy_timeout", 5_000)
    {:ok, _} = XqliteNIF.set_pragma(conn, "busy_timeout", 5_000)
    {:ok, _} = XqliteNIF.set_pragma(conn, "foreign_keys", true)
    # Durability is not under test and a slow disk made two thousand
    # savepoint replays outlive a runner's limit; the rollback journal
    # stays, since the contended properties wait on its write lock.
    {:ok, _} = XqliteNIF.set_pragma(writer, "journal_mode", :memory)
    {:ok, _} = XqliteNIF.set_pragma(writer, "synchronous", :off)
    {:ok, _} = XqliteNIF.set_pragma(conn, "synchronous", :off)

    {:ok, _} =
      XqliteNIF.query(writer, "CREATE TABLE bud_items (id INTEGER PRIMARY KEY, v TEXT)", [])

    {:ok, _} = XqliteNIF.query(writer, "CREATE UNIQUE INDEX bud_items_v_uq ON bud_items (v)", [])
    {:ok, _} = XqliteNIF.query(writer, "CREATE TABLE bud_parents (id INTEGER PRIMARY KEY)", [])

    {:ok, _} =
      XqliteNIF.query(
        writer,
        "CREATE TABLE bud_children (id INTEGER PRIMARY KEY, p_id INTEGER REFERENCES bud_parents(id))",
        []
      )

    {:ok, _} = XqliteNIF.query(writer, "INSERT INTO bud_parents (id) VALUES (1)", [])

    {:ok, conn: conn, writer: writer}
  end

  # --- 1. the allowance is the configured number ------------------------------

  property "a zero allowance skips the index lookup whatever busy_timeout says", context do
    check all(busy_timeout <- integer(0..5_000), max_runs: @uncontended_runs) do
      {:ok, _} = XqliteNIF.set_pragma(context.conn, "busy_timeout", busy_timeout)

      resolved = UniqueIndexNames.resolve(unique_error(), context.conn, 0)

      assert %Constraint{
               unique_index_names: [],
               unique_index_lookup: {:unavailable, :diagnostics_disabled}
             } = resolved.details
    end
  end

  property "an allowance to spare performs the index lookup whatever busy_timeout says",
           context do
    check all(
            busy_timeout <- integer(0..5_000),
            budget <- integer(200..5_000),
            max_runs: @uncontended_runs
          ) do
      {:ok, _} = XqliteNIF.set_pragma(context.conn, "busy_timeout", busy_timeout)

      resolved = UniqueIndexNames.resolve(unique_error(), context.conn, budget)

      assert %Constraint{unique_index_names: names, unique_index_lookup: status} =
               resolved.details

      assert performed?(status)
      assert status != :ok or names == ["bud_items_v_uq"]
    end
  end

  property "a zero allowance skips the foreign-key replay whatever busy_timeout says",
           context do
    check all(busy_timeout <- integer(0..5_000), max_runs: @uncontended_runs) do
      {:ok, _} = XqliteNIF.set_pragma(context.conn, "busy_timeout", busy_timeout)

      error = replay(context.conn, 0)

      assert %Constraint{
               fk_violations: [],
               fk_diagnostics: {:unavailable, :diagnostics_disabled}
             } = error.details
    end
  end

  # --- 2. neither diagnosis outstays its allowance ----------------------------

  property "a contended index lookup stops at its allowance plus the read in flight",
           context do
    check all(budget <- integer(1..15), max_runs: @contended_runs) do
      {resolved, elapsed_ms} =
        under_write_lock(context.writer, fn ->
          UniqueIndexNames.resolve(unique_error(), context.conn, budget)
        end)

      assert %Constraint{
               unique_index_names: [],
               unique_index_lookup: {:unavailable, {:lookup_budget_exceeded, spent_ms}}
             } = resolved.details

      assert spent_ms > budget
      assert elapsed_ms <= budget + @hold_ms + @slack_ms

      # The diagnosis degrades; it never replaces the error it diagnoses.
      assert resolved.type == :constraint_violation
      assert resolved.details.subtype == :constraint_unique
    end
  end

  # The allowance is generous enough here that the clock reading before
  # the first read always passes and the read really starts; what it
  # meets is another connection's write lock. The token fires while the
  # read sits in SQLite's busy handler, where the progress handler a
  # cancel signals never runs, so the read still waits the lock out —
  # and then reports the cancel rather than a spent allowance.
  property "a contended foreign-key replay ends inside the lock hold plus its allowance",
           context do
    check all(budget <- integer(25..45), max_runs: @contended_runs) do
      {error, elapsed_ms} =
        under_write_lock(context.writer, fn -> replay(context.conn, budget) end)

      # Whether the lock bites the reader at all is the platform's
      # business (a Windows runner let the read through and the replay
      # simply succeeded); what the driver owes is the bound and a
      # connection that keeps working.
      assert %Constraint{fk_diagnostics: diagnostics} = error.details
      assert diagnostics == :ok or stopped_inside_the_allowance?(diagnostics)

      assert elapsed_ms <= budget + @hold_ms + @slack_ms

      assert error.type == :constraint_violation
      assert error.details.subtype == :constraint_foreign_key
    end
  end

  # --- 3. the deadline caps what the lookup may spend -------------------------

  property "a zero allowance skips the index lookup whatever the deadline leaves", context do
    check all(remaining_ms <- integer(1..2_000), max_runs: @uncontended_runs) do
      resolved = UniqueIndexNames.resolve(unique_error(), context.conn, 0, remaining_ms)

      assert %Constraint{
               unique_index_names: [],
               unique_index_lookup: {:unavailable, :diagnostics_disabled}
             } = resolved.details
    end
  end

  property "a deadline inside the reserve skips the index lookup whatever the allowance",
           context do
    check all(
            budget <- integer(1..1_000),
            remaining_ms <- integer(1..@reserve_ms),
            max_runs: @uncontended_runs
          ) do
      resolved = UniqueIndexNames.resolve(unique_error(), context.conn, budget, remaining_ms)

      assert %Constraint{
               unique_index_names: [],
               unique_index_lookup: {:unavailable, {:deadline_near, ^remaining_ms}}
             } = resolved.details
    end
  end

  property "a deadline past the reserve does not skip the index lookup", context do
    check all(
            budget <- integer(@ample_ms..1_000),
            remaining_ms <- integer((@ample_ms + @reserve_ms)..2_000),
            max_runs: @uncontended_runs
          ) do
      resolved = UniqueIndexNames.resolve(unique_error(), context.conn, budget, remaining_ms)

      assert %Constraint{unique_index_names: names, unique_index_lookup: status} =
               resolved.details

      assert performed?(status)
      assert status != :ok or names == ["bud_items_v_uq"]
    end
  end

  # The deadline is the smaller of the two here: a lookup that spent the
  # configured 500 ms instead would sit through the whole lock hold and
  # report a resolved name, and the caller's timeout would be long gone.
  property "a contended lookup stops at what the deadline left, not at the configured allowance",
           context do
    check all(
            remaining_ms <- integer((@reserve_ms + 1)..(@reserve_ms + 15)),
            max_runs: @contended_runs
          ) do
      {resolved, elapsed_ms} =
        under_write_lock(context.writer, fn ->
          UniqueIndexNames.resolve(unique_error(), context.conn, 500, remaining_ms)
        end)

      assert %Constraint{
               unique_index_names: [],
               unique_index_lookup: {:unavailable, {:lookup_budget_exceeded, spent_ms}}
             } = resolved.details

      assert spent_ms > remaining_ms - @reserve_ms
      assert elapsed_ms <= remaining_ms + @hold_ms + @slack_ms
    end
  end

  property "a zero allowance skips the foreign-key replay whatever the deadline leaves",
           context do
    check all(remaining_ms <- integer(1..2_000), max_runs: @uncontended_runs) do
      error = replay(context.conn, 0, remaining_ms)

      assert %Constraint{
               fk_violations: [],
               fk_diagnostics: {:unavailable, :diagnostics_disabled}
             } = error.details
    end
  end

  property "a deadline inside the reserve skips the foreign-key replay whatever the allowance",
           context do
    check all(
            budget <- integer(1..1_000),
            remaining_ms <- integer(1..@reserve_ms),
            max_runs: @uncontended_runs
          ) do
      error = replay(context.conn, budget, remaining_ms)

      assert %Constraint{
               fk_violations: [],
               fk_diagnostics: {:unavailable, {:deadline_near, ^remaining_ms}}
             } = error.details
    end
  end

  property "a deadline past the reserve does not skip the foreign-key replay", context do
    check all(
            budget <- integer(@ample_ms..1_000),
            remaining_ms <- integer((@ample_ms + @reserve_ms)..2_000),
            max_runs: @uncontended_runs
          ) do
      error = replay(context.conn, budget, remaining_ms)

      assert %Constraint{fk_diagnostics: status, fk_violations: violations} = error.details
      assert performed?(status)

      assert status != :ok or
               match?([%{child_table: "bud_children", parent_table: "bud_parents"}], violations)
    end
  end

  # --- 4. a read the allowance outlives is cancelled --------------------------

  # A database big enough that one PRAGMA foreign_key_check outlives a
  # small allowance. Nothing in the chain is waiting on another
  # connection here, so the cancel token — not the clock reading taken
  # before each read — is what stops the scan.
  describe "a replay whose scan outlives its allowance" do
    setup do
      path =
        Path.join(
          System.tmp_dir!(),
          "xqlite_ecto3_budget_scan_#{:erlang.unique_integer([:positive])}.db"
        )

      remove_database(path)
      {:ok, conn} = XqliteNIF.open(path)

      on_exit(fn ->
        XqliteNIF.close(conn)
        remove_database(path)
      end)

      {:ok, _} = XqliteNIF.set_pragma(conn, "foreign_keys", true)
      {:ok, _} = XqliteNIF.query(conn, "CREATE TABLE bud_parents (id INTEGER PRIMARY KEY)", [])

      {:ok, _} =
        XqliteNIF.query(
          conn,
          "CREATE TABLE bud_children (id INTEGER PRIMARY KEY, p_id INTEGER REFERENCES bud_parents(id))",
          []
        )

      {:ok, _} = XqliteNIF.query(conn, "INSERT INTO bud_parents (id) VALUES (1)", [])

      {:ok, _} =
        XqliteNIF.query(
          conn,
          "INSERT INTO bud_children(id, p_id) SELECT x + 1000000, 1 FROM (WITH RECURSIVE " <>
            "c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c LIMIT #{@scan_rows}) SELECT x FROM c)",
          []
        )

      {:ok, scan_conn: conn, scan_path: path}
    end

    property "the cancel ends the replay and the connection answers the next query",
             context do
      check all(budget <- integer(1..5), max_runs: @scan_runs) do
        started_at_ms = System.monotonic_time(:millisecond)
        error = replay(context.scan_conn, budget)
        elapsed_ms = System.monotonic_time(:millisecond) - started_at_ms

        assert %Constraint{fk_violations: [], fk_diagnostics: diagnostics} = error.details
        assert stopped_inside_the_allowance?(diagnostics)
        assert elapsed_ms <= budget + @slack_ms
        assert {:ok, %{rows: [[1]]}} = XqliteNIF.query(context.scan_conn, "SELECT 1", [])
        assert {:ok, false} = XqliteNIF.transaction_status(context.scan_conn)
      end
    end

    # Through a pool the caller's own deadline is also DBConnection's
    # checkout deadline: a diagnosis that outstayed it would cost the
    # connection and report nothing about the violation. A small budget
    # is what makes the scan outlive its allowance here; the deadline
    # stays wide so the slowest runner's checkout gap never decides.
    test "the caller gets the violation's error, not the pool's deadline", context do
      {:ok, pid} =
        DBConnection.start_link(
          XqliteEcto3.Driver,
          database: context.scan_path,
          pool_size: 1,
          rich_fk_diagnostics: true,
          diagnostics_budget_ms: 5,
          show_sensitive_data_on_connection_error: true
        )

      insert = "INSERT INTO bud_children (id, p_id) VALUES (7, 999)"

      assert {:error, %Error{details: %Constraint{} = details}} =
               XqliteEcto3.Connection.query(pid, insert, [], timeout: 2_000)

      assert details.subtype == :constraint_foreign_key
      assert stopped_inside_the_allowance?(details.fk_diagnostics)

      assert {:ok, %{rows: [[1]]}} =
               XqliteEcto3.Connection.query(pid, "SELECT 1", [], [])
    end
  end

  # --- helpers ----------------------------------------------------------------

  # Runs `fun` while a second connection holds an exclusive write lock on
  # the same database, so the diagnosis's first read really blocks. The
  # lock is taken before `fun` starts and released while it runs.
  defp under_write_lock(writer, fun) do
    test_pid = self()

    spawn(fn ->
      {:ok, _} = XqliteNIF.query(writer, "BEGIN EXCLUSIVE", [])
      send(test_pid, :locked)
      Process.sleep(@hold_ms)
      {:ok, _} = XqliteNIF.query(writer, "COMMIT", [])
      send(test_pid, :released)
    end)

    assert_receive :locked, 5_000

    started_at_ms = System.monotonic_time(:millisecond)
    result = fun.()
    elapsed_ms = System.monotonic_time(:millisecond) - started_at_ms

    assert_receive :released, 5_000

    {result, elapsed_ms}
  end

  defp replay(conn, budget, remaining_ms \\ :infinity) do
    FkDiagnostics.wrap_with_replay(
      {:constraint_violation, :constraint_foreign_key,
       %{message: "FOREIGN KEY constraint failed"}},
      conn,
      "INSERT INTO bud_children (id, p_id) VALUES (7, 999)",
      [],
      budget,
      remaining_ms
    )
  end

  defp unique_error do
    Error.wrap(
      {:constraint_violation, :constraint_unique,
       %{message: "UNIQUE constraint failed: bud_items.v", table: "bud_items", columns: ["v"]}}
    )
  end

  defp remove_database(path) do
    Enum.each(["", "-wal", "-shm"], fn suffix -> File.rm(path <> suffix) end)
  end

  # Two mechanisms bound a replay that outlives its allowance and either
  # may win: the cancel token ends a read mid-scan, and the wall-clock
  # check between reads ends the chain when a read finished just past
  # it — on a machine that schedules the canceller late, the second.
  # The deadline rule decides whether a diagnosis runs; how long it then
  # takes is the machine's. Past the reserve it must never be skipped:
  # it either completes or the wall-clock budget stops it under way.
  defp performed?(:ok), do: true
  defp performed?({:unavailable, {:diagnostics_budget_exceeded, _}}), do: true
  defp performed?(_other), do: false

  defp stopped_inside_the_allowance?({:unavailable, :operation_cancelled}), do: true
  defp stopped_inside_the_allowance?({:unavailable, {:diagnostics_budget_exceeded, _}}), do: true
  defp stopped_inside_the_allowance?(_other), do: false
end
