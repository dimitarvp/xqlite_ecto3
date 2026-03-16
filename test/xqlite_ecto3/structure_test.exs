defmodule XqliteEcto3.StructureTest do
  use ExUnit.Case, async: true

  @tmp_dir System.tmp_dir!()
  @sqlite3_available System.find_executable("sqlite3") != nil

  defp unique_path(prefix) do
    Path.join(@tmp_dir, "#{prefix}_#{:erlang.unique_integer([:positive])}")
  end

  # ---------------------------------------------------------------------------
  # structure_dump (requires sqlite3 CLI)
  # ---------------------------------------------------------------------------

  if @sqlite3_available do
    test "structure_dump creates SQL dump file" do
      db = unique_path("struct_dump") <> ".db"
      dump_path = unique_path("struct_dump") <> ".sql"

      on_exit(fn ->
        File.rm(db)
        File.rm(dump_path)
      end)

      {:ok, conn} = XqliteNIF.open(db)
      XqliteNIF.execute(conn, "CREATE TABLE things (id INTEGER PRIMARY KEY, name TEXT)")
      XqliteNIF.execute(conn, "INSERT INTO things VALUES (1, 'hello')")
      XqliteNIF.close(conn)

      config = [database: db, dump_path: dump_path]
      assert {:ok, ^dump_path} = XqliteEcto3.structure_dump("priv", config)
      assert File.exists?(dump_path)

      content = File.read!(dump_path)
      assert content =~ "CREATE TABLE"
      assert content =~ "things"
    end

    test "structure_dump creates parent directories" do
      db = unique_path("struct_dump_dir") <> ".db"
      nested_dir = unique_path("struct_dump_nested")
      dump_path = Path.join(nested_dir, "structure.sql")

      on_exit(fn ->
        File.rm(db)
        File.rm_rf(nested_dir)
      end)

      {:ok, conn} = XqliteNIF.open(db)
      XqliteNIF.execute(conn, "CREATE TABLE t (id INTEGER PRIMARY KEY)")
      XqliteNIF.close(conn)

      config = [database: db, dump_path: dump_path]
      assert {:ok, ^dump_path} = XqliteEcto3.structure_dump("priv", config)
      assert File.exists?(dump_path)
    end
  end

  # ---------------------------------------------------------------------------
  # structure_load
  # ---------------------------------------------------------------------------

  test "structure_load creates tables from SQL file" do
    db_target = unique_path("struct_tgt") <> ".db"
    dump_path = unique_path("struct_load") <> ".sql"

    on_exit(fn ->
      File.rm(db_target)
      File.rm(dump_path)
    end)

    sql = """
    CREATE TABLE IF NOT EXISTS items (id INTEGER PRIMARY KEY, label TEXT);
    INSERT INTO items VALUES (1, 'one');
    INSERT INTO items VALUES (2, 'two');
    """

    File.write!(dump_path, sql)

    config = [database: db_target, dump_path: dump_path]
    assert {:ok, ^dump_path} = XqliteEcto3.structure_load("priv", config)

    {:ok, conn} = XqliteNIF.open(db_target)

    {:ok, result} =
      XqliteNIF.query(
        conn,
        "SELECT name FROM sqlite_master WHERE type='table' AND name='items'",
        []
      )

    assert result.rows == [["items"]]

    {:ok, count} = XqliteNIF.query(conn, "SELECT count(*) FROM items", [])
    assert count.rows == [[2]]

    XqliteNIF.close(conn)
  end

  test "structure_load returns error for missing dump file" do
    db = unique_path("struct_nofile") <> ".db"
    dump_path = unique_path("struct_nofile") <> ".sql"

    config = [database: db, dump_path: dump_path]
    assert {:error, msg} = XqliteEcto3.structure_load("priv", config)
    assert msg == "Could not read #{dump_path}: :enoent"
  end

  # ---------------------------------------------------------------------------
  # Round-trip: dump then load (requires sqlite3 CLI)
  # ---------------------------------------------------------------------------

  if @sqlite3_available do
    test "structure_dump then structure_load round-trips schema" do
      db_source = unique_path("struct_rt_src") <> ".db"
      db_target = unique_path("struct_rt_tgt") <> ".db"
      dump_path = unique_path("struct_rt") <> ".sql"

      on_exit(fn ->
        File.rm(db_source)
        File.rm(db_target)
        File.rm(dump_path)
      end)

      {:ok, conn} = XqliteNIF.open(db_source)
      XqliteNIF.execute(conn, "CREATE TABLE widgets (id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
      XqliteNIF.close(conn)

      {:ok, _} = XqliteEcto3.structure_dump("priv", database: db_source, dump_path: dump_path)
      {:ok, _} = XqliteEcto3.structure_load("priv", database: db_target, dump_path: dump_path)

      {:ok, conn2} = XqliteNIF.open(db_target)

      {:ok, result} =
        XqliteNIF.query(
          conn2,
          "SELECT name FROM sqlite_master WHERE type='table' AND name='widgets'",
          []
        )

      assert result.rows == [["widgets"]]
      XqliteNIF.close(conn2)
    end
  end
end
