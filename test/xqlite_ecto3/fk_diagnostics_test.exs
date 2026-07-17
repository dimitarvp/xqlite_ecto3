defmodule XqliteEcto3.FkDiagnosticsTest do
  @moduledoc """
  Rich FK diagnostics: the reactive replay must be deterministic and
  stable — repeated diagnoses of the same state produce identical
  output, violations arrive in a guaranteed sort order, concurrent
  writers cannot disturb a diagnosis, and every failure degrades to
  the original blind error.
  """

  use ExUnit.Case, async: true

  alias XqliteEcto3.Connection, as: Conn
  alias XqliteEcto3.Error
  alias XqliteEcto3.Error.{Constraint, FkViolation}

  defp tmp_db(tag) do
    Path.join(
      System.tmp_dir!(),
      "xqlite_fk_diag_#{tag}_#{:erlang.unique_integer([:positive])}.db"
    )
  end

  defp start_conn(path, opts \\ []) do
    {:ok, pid} =
      DBConnection.start_link(
        XqliteEcto3.Driver,
        Keyword.merge(
          [database: path, pool_size: 1, show_sensitive_data_on_connection_error: true],
          opts
        )
      )

    pid
  end

  defp exec!(pid, sql, params \\ []) do
    {:ok, result} = Conn.query(pid, sql, params, [])
    result
  end

  defp exec(pid, sql, params \\ []) do
    Conn.query(pid, sql, params, [])
  end

  setup context do
    path = context.test |> Atom.to_string() |> String.replace(~r/[^A-Za-z0-9]/, "") |> tmp_db()

    on_exit(fn ->
      for ext <- ["", "-wal", "-shm"], do: File.rm(path <> ext)
    end)

    pid = start_conn(path, rich_fk_diagnostics: true)

    exec!(pid, "CREATE TABLE p(id INTEGER PRIMARY KEY)")
    exec!(pid, "CREATE TABLE ch(id INTEGER PRIMARY KEY, p_id INTEGER REFERENCES p(id))")

    {:ok, pid: pid, path: path}
  end

  test "execute-path violation is enriched with the exact FK details", %{pid: pid} do
    {:error, %Error{} = err} = exec(pid, "INSERT INTO ch VALUES (1, 999)")

    assert %Constraint{
             subtype: :constraint_foreign_key,
             fk_diagnostics: :ok,
             fk_violations: [
               %FkViolation{
                 child_table: "ch",
                 child_rowid: 1,
                 parent_table: "p",
                 child_columns: ["p_id"],
                 parent_columns: ["id"],
                 constraint_name: "ch_p_id_fkey"
               }
             ]
           } = err.details
  end

  test "repeated replay of the same violation is byte-identical", %{pid: pid} do
    results =
      for _ <- 1..10 do
        {:error, %Error{details: %Constraint{} = d}} = exec(pid, "INSERT INTO ch VALUES (1, 999)")
        {d.fk_diagnostics, d.fk_violations}
      end

    assert [{:ok, [%FkViolation{}]}] = Enum.uniq(results)
  end

  test "multiple violations in one statement arrive in sorted, stable order", %{pid: pid} do
    {:error, %Error{details: %Constraint{} = d}} =
      exec(pid, "INSERT INTO ch VALUES (3, 903), (1, 901), (2, 902)")

    assert d.fk_diagnostics == :ok
    assert Enum.map(d.fk_violations, & &1.child_rowid) == [1, 2, 3]
    assert Enum.map(d.fk_violations, & &1.constraint_name) |> Enum.uniq() == ["ch_p_id_fkey"]
  end

  test "two FKs on one table resolve to the violated one", %{pid: pid} do
    exec!(pid, "CREATE TABLE a(id INTEGER PRIMARY KEY)")
    exec!(pid, "CREATE TABLE b(id INTEGER PRIMARY KEY)")

    exec!(pid, """
    CREATE TABLE ch2(
      id INTEGER PRIMARY KEY,
      a_id INTEGER REFERENCES a(id),
      b_id INTEGER REFERENCES b(id)
    )
    """)

    exec!(pid, "INSERT INTO a VALUES (1)")

    {:error, %Error{details: %Constraint{} = d}} =
      exec(pid, "INSERT INTO ch2 VALUES (1, 1, 777)")

    assert d.fk_diagnostics == :ok

    assert [
             %FkViolation{
               child_table: "ch2",
               parent_table: "b",
               child_columns: ["b_id"],
               parent_columns: ["id"],
               constraint_name: "ch2_b_id_fkey"
             }
           ] = d.fk_violations
  end

  test "compound FK reports both columns and a joined name", %{pid: pid} do
    exec!(pid, "CREATE TABLE p2(x INTEGER, y INTEGER, PRIMARY KEY (x, y))")

    exec!(pid, """
    CREATE TABLE ch3(
      id INTEGER PRIMARY KEY,
      x1 INTEGER,
      y1 INTEGER,
      FOREIGN KEY (x1, y1) REFERENCES p2(x, y)
    )
    """)

    {:error, %Error{details: %Constraint{} = d}} =
      exec(pid, "INSERT INTO ch3 VALUES (1, 5, 6)")

    assert d.fk_diagnostics == :ok

    assert [
             %FkViolation{
               child_table: "ch3",
               parent_table: "p2",
               child_columns: ["x1", "y1"],
               parent_columns: ["x", "y"],
               constraint_name: "ch3_x1_y1_fkey"
             }
           ] = d.fk_violations
  end

  test "WITHOUT ROWID child table reports child_rowid as nil", %{pid: pid} do
    exec!(pid, """
    CREATE TABLE ch4(
      code TEXT PRIMARY KEY,
      p_id INTEGER REFERENCES p(id)
    ) WITHOUT ROWID
    """)

    {:error, %Error{details: %Constraint{} = d}} =
      exec(pid, "INSERT INTO ch4 VALUES ('k', 999)")

    assert d.fk_diagnostics == :ok
    assert [%FkViolation{child_table: "ch4", child_rowid: nil}] = d.fk_violations
  end

  test "flag off keeps today's blind error", %{path: path} do
    pid = start_conn(path <> ".off")

    on_exit(fn ->
      for ext <- ["", "-wal", "-shm"], do: File.rm(path <> ".off" <> ext)
    end)

    exec!(pid, "CREATE TABLE p(id INTEGER PRIMARY KEY)")
    exec!(pid, "CREATE TABLE ch(id INTEGER PRIMARY KEY, p_id INTEGER REFERENCES p(id))")

    {:error, %Error{details: %Constraint{} = d}} = exec(pid, "INSERT INTO ch VALUES (1, 999)")

    assert d.subtype == :constraint_foreign_key
    assert d.fk_diagnostics == :not_run
    assert d.fk_violations == []
  end

  test "commit-time deferred violation is enriched without replay", %{pid: pid} do
    err =
      try do
        DBConnection.transaction(pid, fn conn ->
          {:ok, _} = Conn.query(conn, "PRAGMA defer_foreign_keys = ON", [], [])
          {:ok, _} = Conn.query(conn, "INSERT INTO ch VALUES (1, 999)", [], [])
          :will_fail_at_commit
        end)

        :no_error
      rescue
        e in Error -> e
      end

    assert %Error{details: %Constraint{} = d} = err
    assert d.subtype == :constraint_foreign_key
    assert d.fk_diagnostics == :ok

    assert [%FkViolation{child_table: "ch", child_rowid: 1, constraint_name: "ch_p_id_fkey"}] =
             d.fk_violations
  end

  test "inside a transaction the write lock excludes concurrent writers from the diagnosis",
       %{pid: pid, path: path} do
    # busy_timeout 0: a blocked writer fails immediately instead of
    # waiting out the default 5s.
    writer = start_conn(path, busy_timeout: 0)

    err =
      try do
        DBConnection.transaction(pid, fn conn ->
          # BEGIN IMMEDIATE (the driver's transaction mode) holds the
          # write lock: the concurrent writer cannot commit anything
          # between our failure and the replay.
          {:error, %Error{type: :database_busy_or_locked}} =
            exec(writer, "INSERT INTO p VALUES (999)")

          case Conn.query(conn, "INSERT INTO ch VALUES (1, 999)", [], []) do
            {:error, e} -> DBConnection.rollback(conn, e)
            other -> other
          end
        end)
      rescue
        e in Error -> {:raised, e}
      end

    assert {:error, %Error{details: %Constraint{} = d}} = err
    assert d.fk_diagnostics == :ok

    assert [%FkViolation{child_table: "ch", parent_table: "p", constraint_name: "ch_p_id_fkey"}] =
             d.fk_violations
  end

  test "violation fixed before the replay yields :ok with no violations", %{pid: pid} do
    # Outside a transaction there is a window between the original
    # failure and the replay; if a concurrent writer fixes the
    # violation in that window, the replay honestly reports that the
    # violation is no longer reproducible — never an invented one.
    # Staged deterministically by diagnosing a statement that does not
    # violate at replay time.
    exec!(pid, "INSERT INTO p VALUES (42)")

    reason = {:constraint_violation, :constraint_foreign_key, %{message: "FK failed"}}

    {:ok, raw} = XqliteNIF.open(db_path(pid))
    on_exit(fn -> XqliteNIF.close(raw) end)
    {:ok, _} = XqliteNIF.set_pragma(raw, "foreign_keys", true)

    enriched =
      XqliteEcto3.FkDiagnostics.wrap_with_replay(
        reason,
        raw,
        "INSERT INTO ch VALUES (7, 42)",
        []
      )

    assert %Error{details: %Constraint{fk_diagnostics: :ok, fk_violations: []}} = enriched
  end

  defp db_path(pid) do
    {:ok, %{rows: [[_seq, _name, path] | _]}} = Conn.query(pid, "PRAGMA database_list", [], [])
    path
  end

  test "diagnostics failure degrades to the original blind error" do
    path = tmp_db("degrade")

    on_exit(fn ->
      for ext <- ["", "-wal", "-shm"], do: File.rm(path <> ext)
    end)

    {:ok, conn} = XqliteNIF.open(path)
    :ok = XqliteNIF.close(conn)

    reason = {:constraint_violation, :constraint_foreign_key, %{message: "FK failed"}}

    err = XqliteEcto3.FkDiagnostics.wrap_with_replay(reason, conn, "INSERT INTO x VALUES (1)", [])

    assert %Error{details: %Constraint{} = d} = err
    assert d.subtype == :constraint_foreign_key
    assert {:unavailable, _structured_reason} = d.fk_diagnostics
    assert d.fk_violations == []
    # The original error is intact.
    assert err.type == :constraint_violation
    assert err.message == "FK failed"
  end

  test "defer_foreign_keys is reset after a diagnosis inside an open transaction",
       %{pid: pid} do
    err =
      try do
        DBConnection.transaction(pid, fn conn ->
          case Conn.query(conn, "INSERT INTO ch VALUES (1, 999)", [], []) do
            {:error, e} -> DBConnection.rollback(conn, e)
            other -> other
          end
        end)
      rescue
        e in Error -> {:raised, e}
      end

    assert {:error, %Error{details: %Constraint{fk_diagnostics: :ok}}} = err

    # If the replay leaked defer_foreign_keys = ON, this immediate
    # violation would NOT fire (enforcement deferred to commit).
    {:error, %Error{details: %Constraint{subtype: :constraint_foreign_key}}} =
      exec(pid, "INSERT INTO ch VALUES (2, 998)")
  end

  test "fk_diagnostics telemetry span fires with violations_count", %{pid: pid} do
    handler_id = "fk-diag-#{:erlang.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach_many(
      handler_id,
      [[:xqlite_ecto3, :fk_diagnostics, :start], [:xqlite_ecto3, :fk_diagnostics, :stop]],
      fn name, measurements, metadata, _ ->
        send(test_pid, {:telemetry_event, name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    {:error, _} = exec(pid, "INSERT INTO ch VALUES (1, 999)")

    assert_receive {:telemetry_event, [:xqlite_ecto3, :fk_diagnostics, :start], _,
                    %{mode: :replay}}

    assert_receive {:telemetry_event, [:xqlite_ecto3, :fk_diagnostics, :stop], measurements,
                    metadata}

    assert is_integer(measurements.duration)
    assert metadata.violations_count == 1
    assert metadata.diagnostics_status == :ok
  end
end
