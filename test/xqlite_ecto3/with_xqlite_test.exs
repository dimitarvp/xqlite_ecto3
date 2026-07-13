defmodule XqliteEcto3.WithXqliteTest do
  use XqliteEcto3.AdapterCase, async: true

  test "runs raw xqlite queries against the pool's connection" do
    result =
      XqliteEcto3.with_xqlite(Repo, fn conn ->
        Xqlite.query(conn, "SELECT 1 AS one")
      end)

    assert {:ok, %Xqlite.Result{columns: ["one"], rows: [[1]], num_rows: 1}} = result
  end

  test "sees the sandboxed repo's uncommitted writes" do
    Repo.query!("CREATE TABLE bridge_probe (x INTEGER)")
    Repo.query!("INSERT INTO bridge_probe (x) VALUES (41), (42)")

    {:ok, %Xqlite.Result{rows: [[count]]}} =
      XqliteEcto3.with_xqlite(Repo, fn conn ->
        Xqlite.query(conn, "SELECT count(*) FROM bridge_probe")
      end)

    assert count == 2
  end

  test "raw NIF schema introspection works through the bridge" do
    Repo.query!("CREATE TABLE bridge_schema (id INTEGER PRIMARY KEY, name TEXT)")

    {:ok, columns} =
      XqliteEcto3.with_xqlite(Repo, fn conn ->
        XqliteNIF.schema_columns(conn, "bridge_schema")
      end)

    assert Enum.map(columns, & &1.name) == ["id", "name"]
  end

  test "returns the callback's value verbatim" do
    assert XqliteEcto3.with_xqlite(Repo, fn _conn -> {:custom, :value} end) ==
             {:custom, :value}
  end

  test "an exception inside the callback propagates" do
    assert_raise RuntimeError, "boom", fn ->
      XqliteEcto3.with_xqlite(Repo, fn _conn -> raise "boom" end)
    end
  end
end
