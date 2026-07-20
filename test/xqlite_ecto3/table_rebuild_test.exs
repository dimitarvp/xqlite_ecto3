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

  describe "refuses to silently drop constraints it cannot reconstruct" do
    # The rebuild reconstructs columns from PRAGMA table_xinfo, which exposes
    # only name/type/notnull/default/pk. Foreign keys, CHECK constraints, and
    # COLLATE/inline-UNIQUE clauses live only in the original CREATE TABLE text,
    # so a column-info rebuild would silently drop them — turning a MODIFY into
    # a silent loss of referential/domain integrity. The rebuild must refuse
    # loudly and leave the table untouched, never quietly strip the constraint.

    test "refuses when the table has a foreign key, leaving it intact" do
      create("CREATE TABLE rb_fk_parent(id INTEGER PRIMARY KEY, tag TEXT)")

      create(
        "CREATE TABLE rb_fk_child(id INTEGER PRIMARY KEY, name TEXT, " <>
          "parent_id INTEGER REFERENCES rb_fk_parent(id))"
      )

      TestRepo.query!("INSERT INTO rb_fk_parent(id, tag) VALUES (1, 'p')")
      TestRepo.query!("INSERT INTO rb_fk_child(name, parent_id) VALUES ('a', 1)")

      assert_raise ArgumentError, ~r/foreign-key/, fn ->
        run_alter(:rb_fk_child, [{:modify, :name, :string, [null: true]}])
      end

      # The FK must still be present and enforced — the refusal happened before
      # any destructive rebuild step.
      %{rows: fk_list} = TestRepo.query!("PRAGMA foreign_key_list('rb_fk_child')")
      refute fk_list == []

      orphan =
        assert_raise XqliteEcto3.Error, fn ->
          TestRepo.query!("INSERT INTO rb_fk_child(name, parent_id) VALUES ('orphan', 999)")
        end

      assert orphan.type == :constraint_violation
    end

    test "refuses when the table has a CHECK constraint, leaving it intact" do
      create("CREATE TABLE rb_chk(id INTEGER PRIMARY KEY, qty INTEGER CHECK (qty >= 0))")
      TestRepo.query!("INSERT INTO rb_chk(qty) VALUES (5)")

      assert_raise ArgumentError, ~r/CHECK/, fn ->
        run_alter(:rb_chk, [{:modify, :qty, :integer, [null: true]}])
      end

      # CHECK still enforced.
      assert_raise XqliteEcto3.Error, fn ->
        TestRepo.query!("INSERT INTO rb_chk(qty) VALUES (-5)")
      end
    end

    test "refuses when the table has a COLLATE clause" do
      create("CREATE TABLE rb_coll(id INTEGER PRIMARY KEY, code TEXT COLLATE NOCASE)")
      TestRepo.query!("INSERT INTO rb_coll(code) VALUES ('ABC')")

      assert_raise ArgumentError, ~r/COLLATE/, fn ->
        run_alter(:rb_coll, [{:modify, :code, :string, [null: true]}])
      end

      # NOCASE still folds case.
      %{rows: rows} = TestRepo.query!("SELECT id FROM rb_coll WHERE code = 'abc'")
      assert rows == [[1]]
    end

    test "refuses when the table has an inline UNIQUE constraint" do
      create("CREATE TABLE rb_uniq(id INTEGER PRIMARY KEY, sku TEXT UNIQUE)")

      assert_raise ArgumentError, ~r/UNIQUE/, fn ->
        run_alter(:rb_uniq, [{:modify, :sku, :string, [null: true]}])
      end
    end

    test "refuses when the table has generated columns, leaving them intact" do
      create("""
      CREATE TABLE rb_gen(
        id INTEGER PRIMARY KEY, base INTEGER, plain TEXT,
        doubled INTEGER GENERATED ALWAYS AS (base * 2) STORED,
        tripled INTEGER GENERATED ALWAYS AS (base * 3) VIRTUAL
      )
      """)

      TestRepo.query!("INSERT INTO rb_gen(id, base, plain) VALUES (1, 10, 'x')")

      assert_raise ArgumentError, ~r/generated/, fn ->
        run_alter(:rb_gen, [{:modify, :plain, :string, [null: true]}])
      end

      # Both generated columns are still present and still computing.
      %{rows: [[doubled, tripled]]} =
        TestRepo.query!("SELECT doubled, tripled FROM rb_gen WHERE id = 1")

      assert doubled == 20
      assert tripled == 30
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
