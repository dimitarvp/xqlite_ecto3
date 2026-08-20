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

    test "refuses a virtual table and the shadow tables behind it" do
      create("CREATE VIRTUAL TABLE rb_fts USING fts5(body)")
      TestRepo.query!("INSERT INTO rb_fts(body) VALUES ('alpha beta')")

      assert_raise ArgumentError, fn ->
        run_alter(:rb_fts, [{:modify, :body, :text, []}])
      end

      # The module's own storage tables are just as unrebuildable.
      assert_raise ArgumentError, fn ->
        run_alter(:rb_fts_data, [{:modify, :block, :binary, []}])
      end

      assert %{rows: [["virtual"]]} =
               TestRepo.query!(
                 "SELECT type FROM pragma_table_list WHERE schema = 'main' AND name = 'rb_fts'"
               )

      assert %{rows: [["alpha beta"]]} =
               TestRepo.query!("SELECT body FROM rb_fts WHERE rb_fts MATCH 'beta'")
    end

    test "the word CHECK inside a string default is not a declaration" do
      create(
        "CREATE TABLE rb_lit(id INTEGER PRIMARY KEY, " <>
          "status TEXT DEFAULT 'check pending', v REAL)"
      )

      TestRepo.query!("INSERT INTO rb_lit(id, v) VALUES (1, 1.0)")

      assert {:ok, []} = run_alter(:rb_lit, [{:modify, :v, :float, [null: false]}])

      assert %{rows: [["'check pending'"]]} =
               TestRepo.query!(
                 "SELECT dflt_value FROM pragma_table_xinfo('rb_lit') WHERE name = 'status'"
               )
    end

    test "PRIMARY KEY AUTOINCREMENT inside a string default is not a declaration" do
      create(
        "CREATE TABLE rb_ailit(id INTEGER PRIMARY KEY, " <>
          "hint TEXT DEFAULT 'PRIMARY KEY AUTOINCREMENT', body TEXT)"
      )

      TestRepo.query!("INSERT INTO rb_ailit(id, body) VALUES (1, 'first')")

      assert {:ok, []} = run_alter(:rb_ailit, [{:modify, :body, :text, [null: false]}])

      # Without AUTOINCREMENT SQLite hands the highest freed id out again;
      # with it, the rebuild would have made ids monotonic instead.
      TestRepo.query!("INSERT INTO rb_ailit(body) VALUES ('second')")
      TestRepo.query!("DELETE FROM rb_ailit WHERE body = 'second'")
      TestRepo.query!("INSERT INTO rb_ailit(body) VALUES ('third')")

      assert %{rows: [[2]]} = TestRepo.query!("SELECT id FROM rb_ailit WHERE body = 'third'")
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

    test "a view naming the table only as a column does not block the rebuild" do
      create("CREATE TABLE rb_state(id INTEGER PRIMARY KEY, v REAL)")
      create("CREATE TABLE rb_tickets(id INTEGER PRIMARY KEY, rb_state TEXT)")

      create("CREATE VIEW rb_open AS SELECT id, rb_state FROM rb_tickets WHERE rb_state = 'open'")

      TestRepo.query!("INSERT INTO rb_state(id, v) VALUES (1, 1.0)")

      assert {:ok, []} = run_alter(:rb_state, [{:modify, :v, :float, [null: false]}])

      assert %{rows: [["v", 1]]} =
               TestRepo.query!(
                 ~s|SELECT name, "notnull" FROM pragma_table_xinfo('rb_state') WHERE name = 'v'|
               )

      assert %{rows: [[0]]} = TestRepo.query!("SELECT count(*) FROM rb_open")
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

    test "removing a column a trigger on the table reads refuses" do
      create("CREATE TABLE rb_trg_col(id INTEGER PRIMARY KEY, a TEXT, v REAL)")
      create("CREATE TABLE rb_trg_col_log(note TEXT)")

      create(
        "CREATE TRIGGER rb_trg_col_ins AFTER INSERT ON rb_trg_col " <>
          "BEGIN INSERT INTO rb_trg_col_log(note) VALUES (NEW.a); END"
      )

      TestRepo.query!("INSERT INTO rb_trg_col(id, a, v) VALUES (1, 'x', 1.0)")

      assert_raise ArgumentError, fn ->
        run_alter(:rb_trg_col, [
          {:remove, :a, :string, []},
          {:modify, :v, :float, [null: false]}
        ])
      end

      # SQLite compiles a trigger body when the trigger fires, so a trigger
      # left reading a column that is gone only shows on the next write.
      TestRepo.query!("INSERT INTO rb_trg_col(id, a, v) VALUES (2, 'y', 2.0)")
      assert %{rows: [[2]]} = TestRepo.query!("SELECT count(*) FROM rb_trg_col")
    end

    test "removing a column a table-level UNIQUE covers refuses" do
      create(
        "CREATE TABLE rb_uq_gone(id INTEGER PRIMARY KEY, a TEXT, b TEXT, v REAL, UNIQUE (a, b))"
      )

      TestRepo.query!("INSERT INTO rb_uq_gone(id, a, b, v) VALUES (1, 'x', 'y', 1.0)")

      assert_raise ArgumentError, fn ->
        run_alter(:rb_uq_gone, [
          {:remove, :b, :string, []},
          {:modify, :v, :float, [null: false]}
        ])
      end

      assert %{rows: [["id"], ["a"], ["b"], ["v"]]} =
               TestRepo.query!("SELECT name FROM pragma_table_xinfo('rb_uq_gone') ORDER BY cid")

      assert %{rows: [["u"]]} =
               TestRepo.query!("SELECT origin FROM pragma_index_list('rb_uq_gone')")
    end

    test "removing a column a foreign key uses refuses" do
      create("CREATE TABLE rb_fk_parent(id INTEGER PRIMARY KEY)")

      create(
        "CREATE TABLE rb_fk_child(id INTEGER PRIMARY KEY, " <>
          "pid INTEGER REFERENCES rb_fk_parent(id), v REAL)"
      )

      TestRepo.query!("INSERT INTO rb_fk_parent(id) VALUES (1)")
      TestRepo.query!("INSERT INTO rb_fk_child(id, pid, v) VALUES (1, 1, 1.0)")

      assert_raise ArgumentError, fn ->
        run_alter(:rb_fk_child, [
          {:remove, :pid, :integer, []},
          {:modify, :v, :float, [null: false]}
        ])
      end

      assert %{rows: [["id"], ["pid"], ["v"]]} =
               TestRepo.query!("SELECT name FROM pragma_table_xinfo('rb_fk_child') ORDER BY cid")

      assert %{rows: [["rb_fk_parent", "pid", "id"]]} =
               TestRepo.query!(
                 ~s|SELECT "table", "from", "to" FROM pragma_foreign_key_list('rb_fk_child')|
               )
    end

    test "removing a column a standalone index covers refuses" do
      create("CREATE TABLE rb_ix_gone(id INTEGER PRIMARY KEY, a TEXT, v REAL)")
      create("CREATE INDEX rb_ix_gone_a ON rb_ix_gone(a)")
      TestRepo.query!("INSERT INTO rb_ix_gone(id, a, v) VALUES (1, 'x', 1.0)")

      assert_raise ArgumentError, fn ->
        run_alter(:rb_ix_gone, [
          {:remove, :a, :string, []},
          {:modify, :v, :float, [null: false]}
        ])
      end

      assert %{rows: [["id"], ["a"], ["v"]]} =
               TestRepo.query!("SELECT name FROM pragma_table_xinfo('rb_ix_gone') ORDER BY cid")

      assert %{rows: [["rb_ix_gone_a"]]} =
               TestRepo.query!(
                 "SELECT name FROM sqlite_schema WHERE type = 'index' AND " <>
                   "tbl_name = 'rb_ix_gone' AND sql IS NOT NULL"
               )
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

  describe "column names resolve the way SQLite resolves them" do
    test "a modify spelled in another case reaches the stored column" do
      create("CREATE TABLE rb_fold(id INTEGER PRIMARY KEY, name TEXT NOT NULL)")

      assert {:ok, []} = run_alter(:rb_fold, [{:modify, :NAME, :text, [null: true]}])

      assert %{rows: [["name", 0]]} =
               TestRepo.query!(
                 "SELECT name, \"notnull\" FROM pragma_table_xinfo('rb_fold') WHERE name = 'name'"
               )
    end

    test "a remove spelled in another case drops the stored column on the rebuild path" do
      create("CREATE TABLE rb_fold2(id INTEGER PRIMARY KEY, name TEXT, gone TEXT)")

      assert {:ok, []} =
               run_alter(:rb_fold2, [{:modify, :name, :text, [null: true]}, {:remove, :GONE}])

      assert %{rows: [["id"], ["name"]]} =
               TestRepo.query!("SELECT name FROM pragma_table_xinfo('rb_fold2') ORDER BY cid")
    end

    test "a conditional removal spelled in another case drops the stored column" do
      create(~s|CREATE TABLE rb_cond(id INTEGER PRIMARY KEY, "firstName" TEXT)|)

      assert {:ok, _logs} = run_alter(:rb_cond, [{:remove_if_exists, :firstname, :string}])

      assert %{rows: [["id"]]} =
               TestRepo.query!("SELECT name FROM pragma_table_xinfo('rb_cond') ORDER BY cid")
    end

    test "a conditional add spelled in another case leaves the column alone" do
      create(~s|CREATE TABLE rb_cond2(id INTEGER PRIMARY KEY, "displayName" TEXT)|)

      assert {:ok, _logs} =
               run_alter(:rb_cond2, [{:add_if_not_exists, :displayname, :string, []}])

      assert %{rows: [["id"], ["displayName"]]} =
               TestRepo.query!("SELECT name FROM pragma_table_xinfo('rb_cond2') ORDER BY cid")
    end

    test "a conditional removal reaches the same column with or without a modify" do
      create(~s|CREATE TABLE rb_cond3(id INTEGER PRIMARY KEY, "serialNo" TEXT, note TEXT)|)
      create(~s|CREATE TABLE rb_cond4(id INTEGER PRIMARY KEY, "serialNo" TEXT, note TEXT)|)

      assert {:ok, _logs} = run_alter(:rb_cond3, [{:remove_if_exists, :serialno, :string}])

      assert {:ok, []} =
               run_alter(:rb_cond4, [
                 {:modify, :note, :text, []},
                 {:remove_if_exists, :serialno, :string}
               ])

      %{rows: plain} =
        TestRepo.query!("SELECT name FROM pragma_table_xinfo('rb_cond3') ORDER BY cid")

      %{rows: rebuilt} =
        TestRepo.query!("SELECT name FROM pragma_table_xinfo('rb_cond4') ORDER BY cid")

      assert plain == [["id"], ["note"]]
      assert rebuilt == plain
    end

    test "a change naming a column the table does not have refuses loudly" do
      create("CREATE TABLE rb_fold3(id INTEGER PRIMARY KEY, name TEXT)")

      assert_raise ArgumentError, fn ->
        run_alter(:rb_fold3, [{:modify, :nope, :text, [null: true]}])
      end

      assert %{rows: [[2]]} =
               TestRepo.query!("SELECT count(*) FROM pragma_table_xinfo('rb_fold3')")
    end
  end

  describe "schema objects follow the table whatever spelling created them" do
    test "a trigger created with another table spelling survives the rebuild" do
      create("CREATE TABLE rb_trig(id INTEGER PRIMARY KEY, name TEXT, n INTEGER DEFAULT 0)")

      create(
        "CREATE TRIGGER rb_trig_ai AFTER INSERT ON \"RB_TRIG\" " <>
          "BEGIN UPDATE rb_trig SET n = 1 WHERE id = NEW.id; END"
      )

      assert {:ok, []} = run_alter(:rb_trig, [{:modify, :name, :text, [null: true]}])

      TestRepo.query!("INSERT INTO rb_trig(id, name) VALUES (1, 'a')")
      assert %{rows: [[1]]} = TestRepo.query!("SELECT n FROM rb_trig WHERE id = 1")
    end
  end

  describe "defaults carry through a rebuild" do
    test "an expression default survives untouched" do
      create(
        "CREATE TABLE rb_def(id INTEGER PRIMARY KEY, name TEXT, " <>
          "created_at TEXT DEFAULT (datetime('now')))"
      )

      assert {:ok, []} = run_alter(:rb_def, [{:modify, :name, :text, [null: true]}])

      assert %{rows: [["datetime('now')"]]} =
               TestRepo.query!(
                 "SELECT dflt_value FROM pragma_table_xinfo('rb_def') WHERE name = 'created_at'"
               )

      TestRepo.query!("INSERT INTO rb_def(id, name) VALUES (1, 'a')")

      assert %{rows: [[value]]} = TestRepo.query!("SELECT created_at FROM rb_def WHERE id = 1")
      assert is_binary(value) and value != ""
    end

    test "map, list and boolean defaults land the same on both paths" do
      create("CREATE TABLE rb_dflt_plain(id INTEGER PRIMARY KEY, v REAL)")
      create("CREATE TABLE rb_dflt_built(id INTEGER PRIMARY KEY, v REAL)")

      added = [
        {:add, :meta, :map, [default: %{"a" => 1}]},
        {:add, :tags, :map, [default: []]},
        {:add, :flag, :boolean, [default: true]}
      ]

      assert {:ok, _logs} = run_alter(:rb_dflt_plain, added)

      assert {:ok, []} =
               run_alter(:rb_dflt_built, [{:modify, :v, :float, [null: false]} | added])

      defaults = fn table ->
        %{rows: rows} =
          TestRepo.query!(
            "SELECT name, dflt_value FROM pragma_table_xinfo('#{table}') " <>
              "WHERE name IN ('meta', 'tags', 'flag') ORDER BY cid"
          )

        rows
      end

      assert defaults.("rb_dflt_plain") == [
               ["meta", ~s|'{"a":1}'|],
               ["tags", "'[]'"],
               ["flag", "true"]
             ]

      assert defaults.("rb_dflt_built") == defaults.("rb_dflt_plain")
    end

    test "a fragment default given to modify lands on the column" do
      create("CREATE TABLE rb_frag(id INTEGER PRIMARY KEY, seen_at TEXT)")

      assert {:ok, []} =
               run_alter(:rb_frag, [
                 {:modify, :seen_at, :text, [default: {:fragment, "(datetime('now'))"}]}
               ])

      TestRepo.query!("INSERT INTO rb_frag(id) VALUES (1)")

      assert %{rows: [[value]]} = TestRepo.query!("SELECT seen_at FROM rb_frag WHERE id = 1")
      assert is_binary(value) and value != ""
    end
  end

  describe "row identity survives a rebuild" do
    test "implicit rowids are preserved for a table without an integer primary key" do
      create("CREATE TABLE rb_rowid(v TEXT NOT NULL)")
      TestRepo.query!("INSERT INTO rb_rowid(v) VALUES ('a'), ('b'), ('c')")
      TestRepo.query!("DELETE FROM rb_rowid WHERE v = 'a'")

      assert {:ok, []} = run_alter(:rb_rowid, [{:modify, :v, :text, [null: true]}])

      assert %{rows: [[2, "b"], [3, "c"]]} =
               TestRepo.query!("SELECT rowid, v FROM rb_rowid ORDER BY rowid")
    end
  end

  describe "a primary key's sort order survives a rebuild" do
    test "a DESC single-column INTEGER key stays a key and keeps the table's row ids" do
      create("CREATE TABLE rb_desc_pk(x INTEGER PRIMARY KEY DESC, memo TEXT)")
      TestRepo.query!("INSERT INTO rb_desc_pk(x, memo) VALUES (10, 'ten')")
      TestRepo.query!("INSERT INTO rb_desc_pk(x, memo) VALUES (NULL, 'unkeyed')")

      assert {:ok, []} = run_alter(:rb_desc_pk, [{:modify, :memo, :text, [null: false]}])

      # An index of its own is what makes the column a key rather than
      # another name for the row id.
      assert %{rows: [["pk", 1]]} =
               TestRepo.query!(~s|SELECT origin, "unique" FROM pragma_index_list('rb_desc_pk')|)

      assert %{rows: [["x", 1]]} =
               TestRepo.query!(
                 ~s|SELECT xi.name, xi."desc" FROM pragma_index_list('rb_desc_pk') AS il, | <>
                   ~s|pragma_index_xinfo(il.name) AS xi WHERE il.origin = 'pk' AND xi.key = 1|
               )

      # A key that is not the row id takes NULL, and the copy carried the
      # row ids the rows already had.
      assert %{rows: [[1, 10, "ten"], [2, nil, "unkeyed"]]} =
               TestRepo.query!("SELECT rowid, x, memo FROM rb_desc_pk ORDER BY rowid")

      TestRepo.query!("INSERT INTO rb_desc_pk(x, memo) VALUES (NULL, 'also unkeyed')")

      assert %{rows: [[2]]} =
               TestRepo.query!("SELECT count(*) FROM rb_desc_pk WHERE x IS NULL")
    end

    test "a composite key keeps DESC on the member that declared it" do
      create("CREATE TABLE rb_desc_ck(a INTEGER, b TEXT, v REAL, PRIMARY KEY (a DESC, b))")
      TestRepo.query!("INSERT INTO rb_desc_ck(a, b, v) VALUES (1, 'x', 1.5)")

      assert {:ok, []} = run_alter(:rb_desc_ck, [{:modify, :v, :float, [null: false]}])

      assert %{rows: [["a", 1], ["b", 0]]} =
               TestRepo.query!(
                 ~s|SELECT xi.name, xi."desc" FROM pragma_index_list('rb_desc_ck') AS il, | <>
                   ~s|pragma_index_xinfo(il.name) AS xi | <>
                   "WHERE il.origin = 'pk' AND xi.key = 1 ORDER BY xi.seqno"
               )

      err =
        assert_raise XqliteEcto3.Error, fn ->
          TestRepo.query!("INSERT INTO rb_desc_ck(a, b, v) VALUES (1, 'x', 2.5)")
        end

      assert err.type == :constraint_violation

      assert %XqliteEcto3.Error.Constraint{subtype: :constraint_primary_key, columns: ["a", "b"]} =
               err.details
    end
  end

  describe "AUTOINCREMENT spellings" do
    test "PRIMARY KEY ASC AUTOINCREMENT keeps AUTOINCREMENT through a rebuild" do
      create("CREATE TABLE rb_asc(id INTEGER PRIMARY KEY ASC AUTOINCREMENT, name TEXT)")
      TestRepo.query!("INSERT INTO rb_asc(name) VALUES ('a'), ('b'), ('c')")
      TestRepo.query!("DELETE FROM rb_asc WHERE id = 3")

      assert {:ok, []} = run_alter(:rb_asc, [{:modify, :name, :text, [null: true]}])

      assert %{rows: [[4]]} =
               TestRepo.query!("INSERT INTO rb_asc(name) VALUES ('d') RETURNING id")
    end
  end

  describe "keys cannot vanish through modify" do
    test "de-keying the only primary key refuses" do
      create("CREATE TABLE rb_dekey(id INTEGER PRIMARY KEY, name TEXT)")

      assert_raise ArgumentError, fn ->
        run_alter(:rb_dekey, [{:modify, :id, :integer, [primary_key: false]}])
      end

      assert %{rows: [[1]]} =
               TestRepo.query!("SELECT pk FROM pragma_table_xinfo('rb_dekey') WHERE name = 'id'")
    end

    test "moving the key to another column is allowed" do
      create("CREATE TABLE rb_move(id INTEGER PRIMARY KEY, code INTEGER NOT NULL)")

      assert {:ok, []} =
               run_alter(:rb_move, [
                 {:modify, :id, :integer, [primary_key: false]},
                 {:modify, :code, :integer, [primary_key: true]}
               ])

      assert %{rows: [["code", 1], ["id", 0]]} =
               TestRepo.query!("SELECT name, pk FROM pragma_table_xinfo('rb_move') ORDER BY name")
    end

    test "granting the key to a column while a composite key stands refuses" do
      create("CREATE TABLE rb_ckey(a INTEGER, b TEXT, v REAL, PRIMARY KEY (a, b))")
      TestRepo.query!("INSERT INTO rb_ckey(a, b, v) VALUES (1, 'x', 1.0)")

      assert_raise ArgumentError, fn ->
        run_alter(:rb_ckey, [{:modify, :v, :float, [primary_key: true]}])
      end

      # A member of the key is no different: the key still stands either way.
      assert_raise ArgumentError, fn ->
        run_alter(:rb_ckey, [{:modify, :a, :integer, [primary_key: true]}])
      end

      # De-keying only part of the key leaves the rest of it standing.
      assert_raise ArgumentError, fn ->
        run_alter(:rb_ckey, [
          {:modify, :a, :integer, [primary_key: false]},
          {:modify, :v, :float, [primary_key: true]}
        ])
      end

      assert %{rows: [["a", 1], ["b", 2]]} =
               TestRepo.query!(
                 "SELECT name, pk FROM pragma_table_xinfo('rb_ckey') WHERE pk > 0 ORDER BY pk"
               )
    end

    test "granting the key to a column while a single-column key stands refuses" do
      create("CREATE TABLE rb_skey(id INTEGER PRIMARY KEY, v REAL)")
      TestRepo.query!("INSERT INTO rb_skey(id, v) VALUES (1, 1.0)")

      assert_raise ArgumentError, fn ->
        run_alter(:rb_skey, [{:modify, :v, :float, [primary_key: true]}])
      end

      # An added column asking for the key is the same ask.
      assert_raise ArgumentError, fn ->
        run_alter(:rb_skey, [
          {:modify, :v, :float, [null: false]},
          {:add, :k, :integer, [primary_key: true]}
        ])
      end

      assert %{rows: [["id", 1]]} =
               TestRepo.query!(
                 "SELECT name, pk FROM pragma_table_xinfo('rb_skey') WHERE pk > 0 ORDER BY pk"
               )
    end

    test "granting the key to the column that already has it keeps that one key" do
      create("CREATE TABLE rb_regrant(id INTEGER PRIMARY KEY, v REAL)")
      TestRepo.query!("INSERT INTO rb_regrant(id, v) VALUES (1, 1.0)")

      assert {:ok, []} =
               run_alter(:rb_regrant, [{:modify, :id, :integer, [primary_key: true]}])

      assert %{rows: [["id", 1]]} =
               TestRepo.query!(
                 "SELECT name, pk FROM pragma_table_xinfo('rb_regrant') WHERE pk > 0 ORDER BY pk"
               )
    end

    test "granting the key still works when the change set de-keys every member" do
      create("CREATE TABLE rb_ckey3(a INTEGER, b TEXT, v REAL, PRIMARY KEY (a, b))")
      TestRepo.query!("INSERT INTO rb_ckey3(a, b, v) VALUES (1, 'x', 1.0)")

      assert {:ok, []} =
               run_alter(:rb_ckey3, [
                 {:modify, :a, :integer, [primary_key: false]},
                 {:modify, :b, :string, [primary_key: false]},
                 {:modify, :v, :float, [primary_key: true]}
               ])

      assert %{rows: [["v", 1]]} =
               TestRepo.query!(
                 "SELECT name, pk FROM pragma_table_xinfo('rb_ckey3') WHERE pk > 0 ORDER BY pk"
               )

      assert %{rows: [[1, "x"]]} = TestRepo.query!("SELECT a, b FROM rb_ckey3")
    end

    test "de-keying every member without a grant refuses" do
      create("CREATE TABLE rb_ckey4(a INTEGER, b TEXT, v REAL, PRIMARY KEY (a, b))")
      TestRepo.query!("INSERT INTO rb_ckey4(a, b, v) VALUES (1, 'x', 1.0)")

      assert_raise ArgumentError, fn ->
        run_alter(:rb_ckey4, [
          {:modify, :a, :integer, [primary_key: false]},
          {:modify, :b, :string, [primary_key: false]}
        ])
      end

      assert %{rows: [["a", 1], ["b", 2]]} =
               TestRepo.query!(
                 "SELECT name, pk FROM pragma_table_xinfo('rb_ckey4') WHERE pk > 0 ORDER BY pk"
               )
    end

    test "de-keying one member narrows a composite key to the rest" do
      create("CREATE TABLE rb_narrow(a INTEGER, b TEXT, v REAL, PRIMARY KEY (a, b))")
      TestRepo.query!("INSERT INTO rb_narrow(a, b, v) VALUES (1, 'x', 1.0)")

      assert {:ok, []} =
               run_alter(:rb_narrow, [{:modify, :a, :integer, [primary_key: false]}])

      assert %{rows: [["b", 1]]} =
               TestRepo.query!(
                 "SELECT name, pk FROM pragma_table_xinfo('rb_narrow') WHERE pk > 0 ORDER BY pk"
               )

      assert %{rows: [[1, "x", 1.0]]} = TestRepo.query!("SELECT a, b, v FROM rb_narrow")
    end

    # A single-column INTEGER key written as a table-level clause is the
    # table's row id under another name, exactly like the inline spelling:
    # SQLite gives it no index of its own.
    test "narrowing to one INTEGER member leaves the row id under that name" do
      create("CREATE TABLE rb_narrow_i(a INTEGER, b TEXT, v REAL, PRIMARY KEY (a, b))")
      TestRepo.query!("INSERT INTO rb_narrow_i(a, b, v) VALUES (7, 'x', 1.0)")

      assert {:ok, []} =
               run_alter(:rb_narrow_i, [{:modify, :b, :string, [primary_key: false]}])

      assert %{rows: [["a", 1]]} =
               TestRepo.query!(
                 "SELECT name, pk FROM pragma_table_xinfo('rb_narrow_i') WHERE pk > 0 ORDER BY pk"
               )

      assert %{rows: []} = TestRepo.query!("SELECT name FROM pragma_index_list('rb_narrow_i')")
      assert %{rows: [[7, 7]]} = TestRepo.query!("SELECT rowid, a FROM rb_narrow_i")
    end

    test "granting the key still works when the change set removes every member" do
      create("CREATE TABLE rb_ckey2(a INTEGER, b TEXT, v REAL, PRIMARY KEY (a, b))")
      TestRepo.query!("INSERT INTO rb_ckey2(a, b, v) VALUES (1, 'x', 1.0)")

      assert {:ok, []} =
               run_alter(:rb_ckey2, [
                 {:remove, :a, :integer, []},
                 {:remove, :b, :string, []},
                 {:modify, :v, :float, [primary_key: true]}
               ])

      assert %{rows: [["v", 1]]} =
               TestRepo.query!(
                 "SELECT name, pk FROM pragma_table_xinfo('rb_ckey2') WHERE pk > 0 ORDER BY pk"
               )
    end
  end

  describe "references cannot slip into a rebuild" do
    test "modify with references refuses before anything destructive" do
      create("CREATE TABLE rb_refp(id INTEGER PRIMARY KEY)")

      create(
        "CREATE TABLE rb_refc(id INTEGER PRIMARY KEY, " <>
          "parent_id INTEGER REFERENCES rb_refp(id))"
      )

      assert_raise ArgumentError, fn ->
        run_alter(:rb_refc, [
          {:modify, :parent_id, %Ecto.Migration.Reference{table: "rb_refp2"}, []}
        ])
      end

      assert %{rows: [["rb_refp"]]} =
               TestRepo.query!("SELECT \"table\" FROM pragma_foreign_key_list('rb_refc')")
    end

    test "add with references inside a rebuild block refuses before anything destructive" do
      create("CREATE TABLE rb_refa(id INTEGER PRIMARY KEY, name TEXT)")

      assert_raise ArgumentError, fn ->
        run_alter(:rb_refa, [
          {:modify, :name, :text, [null: true]},
          {:add, :parent_id, %Ecto.Migration.Reference{table: "rb_refp"}, []}
        ])
      end

      assert %{rows: [[2]]} =
               TestRepo.query!("SELECT count(*) FROM pragma_table_xinfo('rb_refa')")
    end
  end
end
