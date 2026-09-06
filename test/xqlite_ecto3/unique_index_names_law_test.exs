defmodule XqliteEcto3.UniqueIndexNamesLawTest do
  @moduledoc """
  Two rules the unique-index-name lookup obeys, with SQLite itself as
  the oracle: every table, index and violation below is created and
  provoked for real, and the names the lookup reports are checked
  against the names the database holds.

  ## 1. An expression index can never be ruled out

  SQLite reports a violation either as `table.column` or as
  `index 'name'`, and which of the two you get depends on the order the
  indexes were created in, not on the schema — the later-created of two
  conflicting unique indexes is the one it names. `PRAGMA index_info`
  gives an indexed expression no column name, so an expression index
  can be compared with nothing: when one sits on the violated table the
  lookup cannot say which index fired. It records every candidate and
  reports the ambiguity instead of naming one.

  ## 2. A name that garbles the violation message names no index

  SQLite writes the message as `<table>.<column>`, joining several
  columns with `", "`, and xqlite splits it back on those two
  separators. A table or column name holding one of them comes apart
  somewhere else, and the pieces can name a real, unrelated table whose
  index would then be reported as the violated one. Counting the
  separators the parsed table and columns account for catches every
  such split, and the lookup degrades instead of naming an index. Names
  that hold no separator — quotes, spaces, upper case, non-ASCII —
  resolve exactly as they did before.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias XqliteEcto3.Connection, as: Conn
  alias XqliteEcto3.Error
  alias XqliteEcto3.Error.Constraint
  alias XqliteEcto3.UniqueIndexNames

  @law_runs 2000
  @budget_ms 500

  # Names SQLite accepts as quoted identifiers and that hold neither of
  # the message's two separators, so the message still comes apart the
  # way the parse assumes.
  @safe_names ["v", "a b", "Q\"t", "UPPER", "ünïcode", "x-y", "select"]

  @separators [".", ", "]

  # --- 1. an expression index can never be ruled out ---------------------------

  property "a plain and an expression unique index over one column stay ambiguous" do
    check all(
            column <- member_of(@safe_names),
            expression_first <- boolean(),
            max_runs: @law_runs
          ) do
      conn = memory_conn()
      create_table!(conn, "law_t", [column])
      create_both_indexes!(conn, "law_t", column, expression_first)
      insert!(conn, "law_t", [column], "dup")

      details = violated(conn, "law_t", [column], "dup").details
      candidates = ["law_expression", "law_plain"]

      assert details.table == "law_t"
      assert details.unique_index_names == candidates
      assert details.unique_index_lookup == {:ambiguous, candidates}
      assert details.index_name == reported_index(expression_first)
      assert details.columns == reported_columns(expression_first, column)

      close(conn)
    end
  end

  test "the expression form recovers the table and the expression column" do
    conn = memory_conn()
    create_table!(conn, "anchor_e", ["v"])
    create_both_indexes!(conn, "anchor_e", "v", false)
    insert!(conn, "anchor_e", ["v"], "dup")

    resolved = violated(conn, "anchor_e", ["v"], "dup")

    assert %Constraint{index_name: "law_expression", table: "anchor_e", columns: [nil]} =
             resolved.details

    assert resolved.details.unique_index_lookup ==
             {:ambiguous, ["law_expression", "law_plain"]}

    assert Conn.to_constraints(resolved, []) == [unique: "law_expression"]
  end

  test "the plain form keeps its own columns and falls back to the derived name" do
    conn = memory_conn()
    create_table!(conn, "anchor_p", ["v"])
    create_both_indexes!(conn, "anchor_p", "v", true)
    insert!(conn, "anchor_p", ["v"], "dup")

    resolved = violated(conn, "anchor_p", ["v"], "dup")

    assert %Constraint{index_name: nil, table: "anchor_p", columns: ["v"]} = resolved.details

    assert resolved.details.unique_index_lookup ==
             {:ambiguous, ["law_expression", "law_plain"]}

    assert Conn.to_constraints(resolved, []) == [unique: "anchor_p_v_index"]
  end

  test "a lone expression index is unambiguous and keeps the name SQLite reported" do
    conn = memory_conn()
    create_table!(conn, "lone_e", ["v"])
    query!(conn, ~s{CREATE UNIQUE INDEX "lone_expr" ON "lone_e"(lower("v"))})
    insert!(conn, "lone_e", ["v"], "dup")

    resolved = violated(conn, "lone_e", ["v"], "dup")

    assert %Constraint{
             index_name: "lone_expr",
             table: "lone_e",
             columns: [nil],
             unique_index_names: ["lone_expr"],
             unique_index_lookup: :ok
           } = resolved.details

    assert Conn.to_constraints(resolved, []) == [unique: "lone_expr"]
  end

  # --- 2. a name that garbles the message names no index -----------------------

  property "a name holding a message separator degrades instead of naming an index" do
    check all(
            separator <- member_of(@separators),
            in_column <- boolean(),
            left <- member_of(@safe_names),
            right <- member_of(@safe_names),
            max_runs: @law_runs
          ) do
      conn = memory_conn()
      {table, column} = garbled_names(separator, in_column, left, right)

      create_table!(conn, table, [column])
      query!(conn, "CREATE UNIQUE INDEX \"garbled\" ON #{ident(table)}(#{ident(column)})")
      create_decoy!(conn, table, column, separator)
      insert!(conn, table, [column], "dup")

      details = violated(conn, table, [column], "dup").details

      assert details.unique_index_names == []

      assert details.unique_index_lookup ==
               {:unavailable, {:unparseable_violation_table, details.message}}

      close(conn)
    end
  end

  property "a name holding no message separator resolves to its own index" do
    check all(
            suffix <- member_of(@safe_names),
            column <- member_of(@safe_names),
            max_runs: @law_runs
          ) do
      conn = memory_conn()
      table = "safe " <> suffix

      create_table!(conn, table, [column])
      query!(conn, "CREATE UNIQUE INDEX \"safe_idx\" ON #{ident(table)}(#{ident(column)})")
      insert!(conn, table, [column], "dup")

      details = violated(conn, table, [column], "dup").details

      assert details.table == table
      assert details.unique_index_names == ["safe_idx"]
      assert details.unique_index_lookup == :ok

      close(conn)
    end
  end

  test "a garbled parse that lands on a real table still names no index" do
    conn = memory_conn()

    create_table!(conn, "dotted.name", ["col1"])
    query!(conn, ~s{CREATE UNIQUE INDEX "right_idx" ON "dotted.name"("col1")})
    create_table!(conn, "dotted", ["name.col1"])
    query!(conn, ~s{CREATE UNIQUE INDEX "wrong_idx" ON "dotted"("name.col1")})
    insert!(conn, "dotted.name", ["col1"], "dup")

    details = violated(conn, "dotted.name", ["col1"], "dup").details

    assert details.table == "dotted"
    assert details.unique_index_names == []

    assert details.unique_index_lookup ==
             {:unavailable, {:unparseable_violation_table, details.message}}
  end

  test "a comma in a column name degrades even though the table is real" do
    conn = memory_conn()

    create_table!(conn, "commas", ["a, b"])
    query!(conn, ~s{CREATE UNIQUE INDEX "commas_idx" ON "commas"("a, b")})
    insert!(conn, "commas", ["a, b"], "dup")

    details = violated(conn, "commas", ["a, b"], "dup").details

    assert details.unique_index_names == []

    assert details.unique_index_lookup ==
             {:unavailable, {:unparseable_violation_table, details.message}}
  end

  test "a two-column index keeps resolving, both separators present" do
    conn = memory_conn()

    create_table!(conn, "pairs", ["a", "b"])
    query!(conn, ~s{CREATE UNIQUE INDEX "pairs_idx" ON "pairs"("a", "b")})
    insert!(conn, "pairs", ["a", "b"], "dup")

    details = violated(conn, "pairs", ["a", "b"], "dup").details

    assert %Constraint{
             columns: ["a", "b"],
             unique_index_names: ["pairs_idx"],
             unique_index_lookup: :ok
           } = details
  end

  # --- helpers ----------------------------------------------------------------

  defp memory_conn do
    {:ok, conn} = Xqlite.open_in_memory()
    conn
  end

  defp close(conn) do
    :ok = XqliteNIF.close(conn)
  end

  defp create_table!(conn, table, columns) do
    declared = Enum.map_join(columns, ", ", fn column -> "#{ident(column)} TEXT" end)
    query!(conn, "CREATE TABLE #{ident(table)} (#{declared})")
  end

  # SQLite names the later-created of two conflicting unique indexes, so
  # the creation order decides which message form the violation takes.
  defp create_both_indexes!(conn, table, column, expression_first) do
    plain = "CREATE UNIQUE INDEX \"law_plain\" ON #{ident(table)}(#{ident(column)})"

    expression =
      "CREATE UNIQUE INDEX \"law_expression\" ON #{ident(table)}(lower(#{ident(column)}))"

    statements = ordered(plain, expression, expression_first)
    Enum.each(statements, fn sql -> query!(conn, sql) end)
  end

  defp ordered(plain, expression, true), do: [expression, plain]
  defp ordered(plain, expression, false), do: [plain, expression]

  defp reported_index(true), do: nil
  defp reported_index(false), do: "law_expression"

  defp reported_columns(true, column), do: [column]
  defp reported_columns(false, _column), do: [nil]

  # The garbled parse's target: a table named after the message's first
  # piece, holding a column named after the rest, with a unique index of
  # its own — the wrong-but-real name the lookup must never emit. Skipped
  # when the pieces name the violated table itself.
  defp create_decoy!(conn, table, column, separator) do
    joined = table <> "." <> column

    case String.split(joined, separator, parts: 2) do
      [^table, _right] -> :ok
      [left, right] -> decoy_table!(conn, left, right)
      _single -> :ok
    end
  end

  defp decoy_table!(conn, table, column) do
    create_table!(conn, table, [column])
    query!(conn, "CREATE UNIQUE INDEX \"decoy_idx\" ON #{ident(table)}(#{ident(column)})")
  end

  defp garbled_names(separator, true, left, right), do: {left, right <> separator <> "z"}
  defp garbled_names(separator, false, left, right), do: {left <> separator <> right, "z"}

  defp insert!(conn, table, columns, value) do
    query!(conn, insert_sql(table, columns, value))
  end

  defp violated(conn, table, columns, value) do
    {:error, reason} = XqliteNIF.query(conn, insert_sql(table, columns, value), [])

    UniqueIndexNames.resolve(Error.wrap(reason), conn, @budget_ms)
  end

  defp insert_sql(table, columns, value) do
    names = Enum.map_join(columns, ", ", &ident/1)
    values = Enum.map_join(columns, ", ", fn _column -> "'#{value}'" end)

    "INSERT INTO #{ident(table)}(#{names}) VALUES (#{values})"
  end

  defp query!(conn, sql) do
    {:ok, result} = XqliteNIF.query(conn, sql, [])
    result
  end

  defp ident(name), do: "\"" <> String.replace(name, "\"", "\"\"") <> "\""
end
