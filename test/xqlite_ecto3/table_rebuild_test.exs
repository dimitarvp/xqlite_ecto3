defmodule XqliteEcto3.TableRebuildTest do
  use XqliteEcto3.AdapterCase, async: true

  alias Ecto.Migration.Table

  defp adapter_meta, do: Ecto.Adapter.lookup_meta(TestRepo)

  defp run_alter(table_name, changes) do
    XqliteEcto3.execute_ddl(adapter_meta(), {:alter, %Table{name: table_name}, changes}, [])
  end

  defp create(sql), do: TestRepo.query!(sql)

  describe "rebuild flag gating" do
    test "raises clearly when the flag is off" do
      repo_config = Application.get_env(:xqlite_ecto3, TestRepo)

      Application.put_env(
        :xqlite_ecto3,
        TestRepo,
        Keyword.delete(repo_config, :support_alter_via_table_rebuild)
      )

      on_exit(fn -> Application.put_env(:xqlite_ecto3, TestRepo, repo_config) end)

      create("CREATE TABLE rb_flag(id INTEGER PRIMARY KEY, name TEXT)")

      assert_raise ArgumentError, ~r/support_alter_via_table_rebuild/, fn ->
        run_alter(:rb_flag, [{:modify, :name, :integer, []}])
      end
    end
  end

  describe "modify column" do
    test "rebuilds table and preserves existing rows" do
      create("CREATE TABLE rb_preserve(id INTEGER PRIMARY KEY, name TEXT NOT NULL)")
      TestRepo.query!("INSERT INTO rb_preserve(name) VALUES ('alice'), ('bob')")

      assert {:ok, []} = run_alter(:rb_preserve, [{:modify, :name, :string, [null: true]}])

      %{rows: rows} = TestRepo.query!("SELECT id, name FROM rb_preserve ORDER BY id")
      assert rows == [[1, "alice"], [2, "bob"]]

      %{rows: col_info} =
        TestRepo.query!("SELECT name, \"notnull\" FROM pragma_table_info('rb_preserve')")

      notnull_map = Map.new(col_info, fn [n, nn] -> {n, nn} end)
      assert notnull_map["name"] == 0
    end

    test "batches modify + add + remove in one rebuild" do
      create("CREATE TABLE rb_batch(id INTEGER PRIMARY KEY, a TEXT, b INTEGER, c TEXT)")
      TestRepo.query!("INSERT INTO rb_batch(a, b, c) VALUES ('x', 1, 'keep')")

      assert {:ok, []} =
               run_alter(:rb_batch, [
                 {:modify, :a, :integer, []},
                 {:remove, :b, :integer, []},
                 {:add, :d, :string, []}
               ])

      %{rows: [[names]]} =
        TestRepo.query!(
          "SELECT group_concat(name, ',') FROM pragma_table_info('rb_batch') ORDER BY cid"
        )

      cols = String.split(names, ",")
      assert "id" in cols
      assert "a" in cols
      refute "b" in cols
      assert "c" in cols
      assert "d" in cols

      %{rows: [[c_val]]} = TestRepo.query!("SELECT c FROM rb_batch WHERE id = 1")
      assert c_val == "keep"
    end

    test "user index on the table is recreated" do
      create("CREATE TABLE rb_idx(id INTEGER PRIMARY KEY, name TEXT)")
      create("CREATE UNIQUE INDEX rb_idx_name ON rb_idx(name)")
      TestRepo.query!("INSERT INTO rb_idx(name) VALUES ('alice')")

      assert {:ok, []} = run_alter(:rb_idx, [{:modify, :name, :string, [null: false]}])

      %{rows: rows} =
        TestRepo.query!(
          "SELECT name FROM sqlite_schema WHERE type='index' AND name='rb_idx_name'"
        )

      assert rows == [["rb_idx_name"]]

      err =
        assert_raise XqliteEcto3.Error, fn ->
          TestRepo.query!("INSERT INTO rb_idx(name) VALUES ('alice')")
        end

      assert err.type == :constraint_violation
      assert %XqliteEcto3.Error.Constraint{subtype: :constraint_unique} = err.details
    end

    test "AUTOINCREMENT sequence is preserved" do
      create("CREATE TABLE rb_seq(id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT)")
      TestRepo.query!("INSERT INTO rb_seq(name) VALUES ('a'), ('b'), ('c')")
      TestRepo.query!("DELETE FROM rb_seq")

      assert {:ok, []} = run_alter(:rb_seq, [{:modify, :name, :string, [null: true]}])

      TestRepo.query!("INSERT INTO rb_seq(name) VALUES ('d')")
      %{rows: [[id]]} = TestRepo.query!("SELECT id FROM rb_seq WHERE name = 'd'")
      assert id == 4
    end

    test "trigger attached to the table is recreated" do
      create("""
      CREATE TABLE rb_trg(id INTEGER PRIMARY KEY, name TEXT, updated_at TEXT)
      """)

      create("""
      CREATE TRIGGER rb_trg_touch AFTER UPDATE ON rb_trg
      BEGIN UPDATE rb_trg SET updated_at = 'bumped' WHERE id = NEW.id; END
      """)

      assert {:ok, []} = run_alter(:rb_trg, [{:modify, :name, :string, [null: true]}])

      %{rows: rows} =
        TestRepo.query!(
          "SELECT name FROM sqlite_schema WHERE type='trigger' AND name='rb_trg_touch'"
        )

      assert rows == [["rb_trg_touch"]]
    end
  end
end
