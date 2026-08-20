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

  describe "connection state after a rebuild" do
    test "defer_foreign_keys is reset even when the transaction never commits" do
      create("CREATE TABLE rb_dfk_parent(id INTEGER PRIMARY KEY)")

      create(
        "CREATE TABLE rb_dfk(id INTEGER PRIMARY KEY, name TEXT, " <>
          "pid INTEGER NOT NULL REFERENCES rb_dfk_parent(id))"
      )

      TestRepo.query!("INSERT INTO rb_dfk_parent(id) VALUES (1)")
      TestRepo.query!("INSERT INTO rb_dfk(id, name, pid) VALUES (1, 'a', 1)")

      assert {:ok, []} = run_alter(:rb_dfk, [{:modify, :name, :string, [null: true]}])

      # SQLite auto-resets defer_foreign_keys only at COMMIT. Inside a
      # transaction that never commits (the SQL Sandbox), the rebuild must
      # reset the pragma itself or FK enforcement silently stays deferred
      # for the rest of the session.
      assert %{rows: [[0]]} = TestRepo.query!("PRAGMA defer_foreign_keys")

      assert_raise XqliteEcto3.Error, fn ->
        TestRepo.query!("INSERT INTO rb_dfk(id, name, pid) VALUES (2, 'b', 999)")
      end
    end
  end

  describe "refuses to silently drop constructs it cannot reconstruct" do
    # Foreign keys and UNIQUE constraints are reconstructed from the structural
    # pragmas, so they survive the rebuild (see table_rebuild_preservation_test).
    # The rest — CHECK, COLLATE, generated columns, DEFERRABLE foreign keys, and
    # ON CONFLICT clauses — live only in the original CREATE TABLE text or carry
    # detail the pragmas do not expose, so a rebuild would silently drop them.
    # The rebuild must refuse loudly and leave the table untouched.

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

    test "refuses a DEFERRABLE foreign key (pragmas do not expose deferral)" do
      create("CREATE TABLE rb_def_parent(id INTEGER PRIMARY KEY)")

      create(
        "CREATE TABLE rb_def(id INTEGER PRIMARY KEY, name TEXT, " <>
          "pid INTEGER REFERENCES rb_def_parent(id) DEFERRABLE INITIALLY DEFERRED)"
      )

      assert_raise ArgumentError, ~r/DEFERRABLE/, fn ->
        run_alter(:rb_def, [{:modify, :name, :string, [null: true]}])
      end

      # The table is untouched — the deferrable FK is still declared.
      %{rows: fk_list} = TestRepo.query!("PRAGMA foreign_key_list('rb_def')")
      refute fk_list == []
    end

    test "refuses a UNIQUE ... ON CONFLICT clause (pragmas do not expose it)" do
      create(
        "CREATE TABLE rb_oc(id INTEGER PRIMARY KEY, name TEXT, sku TEXT, " <>
          "UNIQUE (sku) ON CONFLICT REPLACE)"
      )

      TestRepo.query!("INSERT INTO rb_oc(id, name, sku) VALUES (1, 'a', 's1')")

      assert_raise ArgumentError, ~r/ON CONFLICT/, fn ->
        run_alter(:rb_oc, [{:modify, :name, :string, [null: true]}])
      end

      # ON CONFLICT REPLACE still active — a duplicate sku replaces, does not error.
      TestRepo.query!("INSERT INTO rb_oc(id, name, sku) VALUES (2, 'b', 's1')")
      %{rows: [[count]]} = TestRepo.query!("SELECT count(*) FROM rb_oc")
      assert count == 1
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

  describe "rebuild guards" do
    test "naming the table in a different case still sees its constructs" do
      create(~s|CREATE TABLE "RbCase"(id INTEGER PRIMARY KEY, v TEXT, CHECK (v <> 'bad'))|)

      assert_raise ArgumentError, ~r/CHECK/, fn ->
        run_alter(:rbcase, [{:modify, :v, :text, []}])
      end
    end

    test "STRICT behind a trailing comment still refuses" do
      create(
        "CREATE TABLE rb_strict_c(id INTEGER PRIMARY KEY, v TEXT, n INTEGER) " <>
          "STRICT -- keyed on (id)"
      )

      assert_raise ArgumentError, ~r/STRICT/, fn ->
        run_alter(:rb_strict_c, [{:modify, :v, :text, []}])
      end

      create("INSERT INTO rb_strict_c(id, v, n) VALUES (1, 'x', 1)")

      assert_raise XqliteEcto3.Error, fn ->
        TestRepo.query!("INSERT INTO rb_strict_c(id, v, n) VALUES (2, 'y', 'not-an-int')")
      end
    end

    test "WITHOUT ROWID behind a trailing comment still refuses" do
      create("CREATE TABLE rb_wr_c(k TEXT PRIMARY KEY, v TEXT) WITHOUT ROWID -- keyed by (k)")

      assert_raise ArgumentError, ~r/WITHOUT ROWID/, fn ->
        run_alter(:rb_wr_c, [{:modify, :v, :text, []}])
      end
    end

    test "a view over the table refuses the rebuild up front" do
      create("CREATE TABLE rb_viewed(id INTEGER PRIMARY KEY, v TEXT)")
      create("INSERT INTO rb_viewed(id, v) VALUES (1, 'x')")
      create("CREATE VIEW rb_v AS SELECT id FROM rb_viewed")

      assert_raise ArgumentError, ~r/rb_v/, fn ->
        run_alter(:rb_viewed, [{:modify, :v, :string, [null: true]}])
      end

      assert %{rows: [[1]]} = TestRepo.query!("SELECT count(*) FROM rb_viewed")

      TestRepo.query!("DROP VIEW rb_v")
      assert {:ok, []} = run_alter(:rb_viewed, [{:modify, :v, :string, [null: true]}])
    end

    test "a trigger on another table naming this one refuses the rebuild" do
      create("CREATE TABLE rb_trg_target(id INTEGER PRIMARY KEY, v TEXT)")
      create("CREATE TABLE rb_trg_other(id INTEGER PRIMARY KEY)")

      create(
        "CREATE TRIGGER rb_trg_foreign AFTER INSERT ON rb_trg_other " <>
          "BEGIN INSERT INTO rb_trg_target(v) VALUES ('x'); END"
      )

      assert_raise ArgumentError, ~r/rb_trg_foreign/, fn ->
        run_alter(:rb_trg_target, [{:modify, :v, :string, [null: true]}])
      end
    end

    test "removing every primary-key column refuses, leaving the table intact" do
      create(
        "CREATE TABLE rb_pk_all(tenant INTEGER, code TEXT, label TEXT, PRIMARY KEY (tenant, code))"
      )

      TestRepo.query!("INSERT INTO rb_pk_all(tenant, code, label) VALUES (1, 'x', 'a')")

      assert_raise ArgumentError, fn ->
        run_alter(:rb_pk_all, [
          {:modify, :label, :string, [null: true]},
          {:remove, :tenant, :integer, []},
          {:remove, :code, :string, []}
        ])
      end

      assert %{rows: [[1, "x", "a"]]} =
               TestRepo.query!("SELECT tenant, code, label FROM rb_pk_all")

      %{rows: key} =
        TestRepo.query!("SELECT name, pk FROM pragma_table_xinfo('rb_pk_all') WHERE pk > 0")

      assert Enum.sort_by(key, fn [_name, position] -> position end) ==
               [["tenant", 1], ["code", 2]]
    end

    test "removing the only column of a single-column key refuses" do
      create("CREATE TABLE rb_pk_one(id INTEGER PRIMARY KEY, name TEXT)")
      TestRepo.query!("INSERT INTO rb_pk_one(id, name) VALUES (1, 'a')")

      assert_raise ArgumentError, fn ->
        run_alter(:rb_pk_one, [
          {:modify, :name, :string, [null: true]},
          {:remove, :id, :integer, []}
        ])
      end

      assert %{rows: [[1, "a"]]} = TestRepo.query!("SELECT id, name FROM rb_pk_one")
    end

    test "removing one member of a composite key narrows it to the survivor" do
      create(
        "CREATE TABLE rb_pk_some(tenant INTEGER, code TEXT, label TEXT, PRIMARY KEY (tenant, code))"
      )

      TestRepo.query!("INSERT INTO rb_pk_some(tenant, code, label) VALUES (1, 'x', 'a')")

      assert {:ok, []} =
               run_alter(:rb_pk_some, [
                 {:modify, :label, :string, [null: true]},
                 {:remove, :tenant, :integer, []}
               ])

      %{rows: key} =
        TestRepo.query!("SELECT name, pk FROM pragma_table_xinfo('rb_pk_some') WHERE pk > 0")

      assert key == [["code", 1]]
    end

    test "defer_foreign_keys is restored when the rebuild fails mid-dance" do
      create("CREATE TABLE rb_dfr_parent(id INTEGER PRIMARY KEY)")

      create(
        "CREATE TABLE rb_dfr(id INTEGER PRIMARY KEY, name TEXT, " <>
          "pid INTEGER NOT NULL REFERENCES rb_dfr_parent(id))"
      )

      TestRepo.query!("INSERT INTO rb_dfr_parent(id) VALUES (1)")
      TestRepo.query!("INSERT INTO rb_dfr(id, name, pid) VALUES (1, 'a', 1)")
      create("CREATE TABLE rb_dfr__xqlite_new(x INTEGER)")

      assert_raise XqliteEcto3.Error, fn ->
        run_alter(:rb_dfr, [{:modify, :name, :string, [null: true]}])
      end

      assert %{rows: [[0]]} = TestRepo.query!("PRAGMA defer_foreign_keys")

      assert_raise XqliteEcto3.Error, fn ->
        TestRepo.query!("INSERT INTO rb_dfr(id, name, pid) VALUES (2, 'b', 999)")
      end
    end

    test "a defer_foreign_keys the caller set survives a rebuild" do
      create("CREATE TABLE rb_dfu(id INTEGER PRIMARY KEY, name TEXT)")
      TestRepo.query!("PRAGMA defer_foreign_keys = ON")

      assert {:ok, []} = run_alter(:rb_dfu, [{:modify, :name, :string, [null: true]}])

      assert %{rows: [[1]]} = TestRepo.query!("PRAGMA defer_foreign_keys")
      TestRepo.query!("PRAGMA defer_foreign_keys = OFF")
    end
  end
end
