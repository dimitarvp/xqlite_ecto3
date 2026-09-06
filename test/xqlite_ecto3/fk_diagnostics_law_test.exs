defmodule XqliteEcto3.FkDiagnosticsLawTest do
  @moduledoc """
  The rule every `PRAGMA foreign_key_list` reader obeys: whatever shape
  the pragma's rows arrive in, grouping them either produces the grouped
  definitions or reports the offending row — it never raises.

  The diagnosis runs on a path that is already handling a constraint
  violation, so a crash there would replace a structured error with an
  exception. The property drives rows of every length from empty to eight
  columns, with `nil` allowed in any position, and the examples beside it
  pin the shapes the pragma really produces today.

  A second rule covers what the replay reports: `PRAGMA
  foreign_key_check` scans the whole database, so the replay subtracts
  a baseline scan taken before the statement runs again. A `WITHOUT
  ROWID` child reports a `nil` rowid for every violation of its, so its
  rows are byte-identical and only their number moves — the subtraction
  therefore counts rows per `{child table, fk id}` instead of matching
  them one by one. Whatever orphans the database already held, only the
  statement's own violation is reported.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias XqliteEcto3.Error.FkViolation
  alias XqliteEcto3.FkDiagnostics

  @law_runs 2000

  # Each baseline run creates its own database, seeds it and replays a
  # statement under a savepoint, so its runs cost real work; the domain
  # is small on purpose and the assertion is exact.
  @baseline_runs 2000
  @baseline_budget_ms 500

  # id, seq, parent table, from, to — plus the three columns
  # (on_update, on_delete, match) the grouping never reads.
  @full_row [0, 0, "p", "p_id", "id", "NO ACTION", "NO ACTION", "NONE"]

  property "a row of any shape groups or reports itself, never raises" do
    check all(rows <- StreamData.list_of(fk_row(), max_length: 4), max_runs: @law_runs) do
      case group(rows) do
        {:ok, grouped} ->
          assert is_map(grouped)
          assert Enum.all?(rows, fn row -> length(row) >= 5 end)

        {:error, {:unexpected_fk_row, row}} ->
          assert row in rows
          assert length(row) < 5

        other ->
          flunk("group_fk_rows/1 returned #{inspect(other)}")
      end
    end
  end

  test "rows of the pragma's own shape group by their fk id" do
    rows = [
      [0, 0, "p", "p_id", "id", "NO ACTION", "NO ACTION", "NONE"],
      [1, 0, "q", "q_id", "id", "NO ACTION", "NO ACTION", "NONE"]
    ]

    assert {:ok, grouped} = FkDiagnostics.group_fk_rows(rows)

    assert grouped == %{
             0 => %{parent_table: "p", child_columns: ["p_id"], parent_columns: ["id"]},
             1 => %{parent_table: "q", child_columns: ["q_id"], parent_columns: ["id"]}
           }
  end

  test "a compound key keeps its columns in the pragma's seq order" do
    rows = [
      [0, 1, "p", "b", "y", "NO ACTION", "NO ACTION", "NONE"],
      [0, 0, "p", "a", "x", "NO ACTION", "NO ACTION", "NONE"]
    ]

    assert {:ok, %{0 => definition}} = FkDiagnostics.group_fk_rows(rows)
    assert definition.child_columns == ["a", "b"]
    assert definition.parent_columns == ["x", "y"]
  end

  test "a column SQLite may add later is ignored, not refused" do
    assert {:ok, %{0 => definition}} = FkDiagnostics.group_fk_rows([@full_row ++ ["future"]])
    assert definition.parent_table == "p"
  end

  test "nil in every value position still groups" do
    assert {:ok, grouped} =
             FkDiagnostics.group_fk_rows([[nil, nil, nil, nil, nil, nil, nil, nil]])

    assert grouped == %{
             nil => %{parent_table: nil, child_columns: [nil], parent_columns: [nil]}
           }
  end

  test "no rows at all group to nothing" do
    assert FkDiagnostics.group_fk_rows([]) == {:ok, %{}}
  end

  test "a row with fewer columns than the grouping reads is reported" do
    assert FkDiagnostics.group_fk_rows([[0, 0, "p", "p_id"]]) ==
             {:error, {:unexpected_fk_row, [0, 0, "p", "p_id"]}}
  end

  test "an empty row is reported" do
    assert FkDiagnostics.group_fk_rows([[]]) == {:error, {:unexpected_fk_row, []}}
  end

  test "one short row among good ones refuses the whole group" do
    assert FkDiagnostics.group_fk_rows([@full_row, [0]]) ==
             {:error, {:unexpected_fk_row, [0]}}
  end

  # --- the baseline diff ------------------------------------------------------

  property "only the statement's own violation is reported, whatever the baseline holds" do
    check all(
            elsewhere <- integer(0..3),
            here <- integer(0..2),
            max_runs: @baseline_runs
          ) do
      conn = orphan_database(elsewhere, here)
      sql = "INSERT INTO wr(k, p_id) VALUES ('victim', 998)"
      {:error, reason} = XqliteNIF.query(conn, sql, [])

      error = FkDiagnostics.wrap_with_replay(reason, conn, sql, [], @baseline_budget_ms)

      assert error.details.fk_diagnostics == :ok

      assert [%FkViolation{child_table: "wr", child_rowid: nil, fk_id: 0}] =
               error.details.fk_violations

      :ok = XqliteNIF.close(conn)
    end
  end

  # A parent with one row, a WITHOUT ROWID child that reports a nil
  # rowid for every violation of its, and a rowid child holding the
  # orphans the statement is not answerable for.
  defp orphan_database(elsewhere, here) do
    {:ok, conn} = Xqlite.open_in_memory()

    Enum.each(
      [
        "PRAGMA foreign_keys = 0",
        "CREATE TABLE p(id INTEGER PRIMARY KEY)",
        "CREATE TABLE al(id INTEGER PRIMARY KEY, p_id INTEGER REFERENCES p(id))",
        "CREATE TABLE wr(k TEXT PRIMARY KEY, p_id INTEGER REFERENCES p(id)) WITHOUT ROWID",
        "INSERT INTO p(id) VALUES (1)"
      ],
      fn sql -> {:ok, _} = XqliteNIF.query(conn, sql, []) end
    )

    seed_orphans(conn, "INSERT INTO al(id, p_id) VALUES (?, 900)", Enum.to_list(1..elsewhere//1))

    seed_orphans(
      conn,
      "INSERT INTO wr(k, p_id) VALUES (?, 901)",
      Enum.map(1..here//1, fn n -> "orphan_#{n}" end)
    )

    {:ok, _} = XqliteNIF.query(conn, "PRAGMA foreign_keys = 1", [])

    conn
  end

  defp seed_orphans(conn, sql, keys) do
    Enum.each(keys, fn key -> {:ok, _} = XqliteNIF.query(conn, sql, [key]) end)
  end

  defp group(rows) do
    FkDiagnostics.group_fk_rows(rows)
  rescue
    e -> {:raised, e}
  end

  # Rows of 0 to 8 elements, each element a value the pragma can really
  # produce (an id, a sequence number, an identifier, a referential
  # action) or a nil in place of any of them.
  defp fk_row do
    StreamData.list_of(fk_value(), max_length: 8)
  end

  defp fk_value do
    StreamData.one_of([
      StreamData.constant(nil),
      StreamData.integer(0..3),
      StreamData.member_of(["p", "q", "id", "p_id", "NO ACTION", "CASCADE", "NONE", ""])
    ])
  end
end
