defmodule XqliteEcto3.TableRebuildPreservationTest do
  @moduledoc """
  The opt-in table rebuild reconstructs foreign keys and UNIQUE constraints
  from the structural pragmas (`foreign_key_list`, `index_list`), so a
  `:modify` on a table declaring them preserves and keeps enforcing them
  instead of refusing. Every scenario runs through a real `Ecto.Migrator`
  migration against a non-sandboxed repo so the rebuild executes in the same
  transactional path production migrations use.
  """
  use ExUnit.Case, async: true

  alias Ecto.Integration.PoolRepo

  # --- migrations (one per scenario, unique versions) ------------------------

  defmodule FkCascadeMigration do
    use Ecto.Migration

    def up do
      execute("DROP TABLE IF EXISTS rp_c_child")
      execute("DROP TABLE IF EXISTS rp_c_parent")

      create table(:rp_c_parent) do
        add(:name, :string)
      end

      create table(:rp_c_child) do
        add(:name, :string)
        add(:parent_id, references(:rp_c_parent, on_delete: :delete_all))
      end

      execute("INSERT INTO rp_c_parent(id, name) VALUES (1, 'p')")
      execute("INSERT INTO rp_c_child(id, name, parent_id) VALUES (1, 'a', 1)")

      alter table(:rp_c_child) do
        modify(:name, :text, null: true)
      end
    end
  end

  defmodule FkSetNullMigration do
    use Ecto.Migration

    def up do
      execute("DROP TABLE IF EXISTS rp_sn_child")
      execute("DROP TABLE IF EXISTS rp_sn_parent")

      create table(:rp_sn_parent) do
        add(:name, :string)
      end

      create table(:rp_sn_child) do
        add(:name, :string)
        add(:parent_id, references(:rp_sn_parent, on_delete: :nilify_all))
      end

      execute("INSERT INTO rp_sn_parent(id, name) VALUES (1, 'p')")
      execute("INSERT INTO rp_sn_child(id, name, parent_id) VALUES (1, 'a', 1)")

      alter table(:rp_sn_child) do
        modify(:name, :text, null: true)
      end
    end
  end

  defmodule FkOnUpdateMigration do
    use Ecto.Migration

    def up do
      execute("DROP TABLE IF EXISTS rp_ou_child")
      execute("DROP TABLE IF EXISTS rp_ou_parent")

      execute("CREATE TABLE rp_ou_parent(code TEXT PRIMARY KEY, name TEXT)")

      execute(
        "CREATE TABLE rp_ou_child(id INTEGER PRIMARY KEY, name TEXT, pcode TEXT " <>
          "REFERENCES rp_ou_parent(code) ON UPDATE CASCADE)"
      )

      execute("INSERT INTO rp_ou_parent(code, name) VALUES ('x', 'p')")
      execute("INSERT INTO rp_ou_child(id, name, pcode) VALUES (1, 'a', 'x')")

      alter table(:rp_ou_child) do
        modify(:name, :text, null: true)
      end
    end
  end

  defmodule CompositeFkMigration do
    use Ecto.Migration

    def up do
      execute("DROP TABLE IF EXISTS rp_cp_child")
      execute("DROP TABLE IF EXISTS rp_cp_parent")
      execute("CREATE TABLE rp_cp_parent(a INTEGER, b INTEGER, tag TEXT, PRIMARY KEY (a, b))")

      execute(
        "CREATE TABLE rp_cp_child(id INTEGER PRIMARY KEY, name TEXT, pa INTEGER, pb INTEGER, " <>
          "FOREIGN KEY (pa, pb) REFERENCES rp_cp_parent(a, b) ON DELETE CASCADE)"
      )

      execute("INSERT INTO rp_cp_parent(a, b, tag) VALUES (1, 2, 'p')")
      execute("INSERT INTO rp_cp_child(id, name, pa, pb) VALUES (1, 'a', 1, 2)")

      alter table(:rp_cp_child) do
        modify(:name, :text, null: true)
      end
    end
  end

  defmodule ImplicitPkFkMigration do
    use Ecto.Migration

    def up do
      execute("DROP TABLE IF EXISTS rp_ip_child")
      execute("DROP TABLE IF EXISTS rp_ip_parent")
      execute("CREATE TABLE rp_ip_parent(id INTEGER PRIMARY KEY, tag TEXT)")

      # REFERENCES with no column list — targets the parent's implicit PK.
      execute(
        "CREATE TABLE rp_ip_child(id INTEGER PRIMARY KEY, name TEXT, pid INTEGER " <>
          "REFERENCES rp_ip_parent)"
      )

      execute("INSERT INTO rp_ip_parent(id, tag) VALUES (1, 'p')")
      execute("INSERT INTO rp_ip_child(id, name, pid) VALUES (1, 'a', 1)")

      alter table(:rp_ip_child) do
        modify(:name, :text, null: true)
      end
    end
  end

  defmodule IncomingFkMigration do
    use Ecto.Migration

    def up do
      execute("DROP TABLE IF EXISTS rp_in_child")
      execute("DROP TABLE IF EXISTS rp_in_parent")
      execute("CREATE TABLE rp_in_parent(id INTEGER PRIMARY KEY, name TEXT)")

      execute(
        "CREATE TABLE rp_in_child(id INTEGER PRIMARY KEY, pid INTEGER " <>
          "REFERENCES rp_in_parent(id) ON DELETE CASCADE)"
      )

      execute("INSERT INTO rp_in_parent(id, name) VALUES (1, 'p')")

      # Rebuild the PARENT (the drop+rename dance) while a child references it.
      alter table(:rp_in_parent) do
        modify(:name, :text, null: true)
      end
    end
  end

  defmodule SelfRefFkMigration do
    use Ecto.Migration

    def up do
      execute("DROP TABLE IF EXISTS rp_self")

      execute(
        "CREATE TABLE rp_self(id INTEGER PRIMARY KEY, label TEXT, parent_id INTEGER " <>
          "REFERENCES rp_self(id) ON DELETE CASCADE)"
      )

      execute("INSERT INTO rp_self VALUES (1, 'root', NULL), (2, 'a', 1), (3, 'b', 2)")

      alter table(:rp_self) do
        modify(:label, :text, null: true)
      end
    end
  end

  defmodule UniqueMigration do
    use Ecto.Migration

    def up do
      execute("DROP TABLE IF EXISTS rp_uq")

      execute(
        "CREATE TABLE rp_uq(id INTEGER PRIMARY KEY, name TEXT, sku TEXT, region TEXT, " <>
          "UNIQUE (sku), UNIQUE (name, region))"
      )

      execute("INSERT INTO rp_uq(id, name, sku, region) VALUES (1, 'a', 's1', 'eu')")

      alter table(:rp_uq) do
        modify(:name, :text, null: true)
      end
    end
  end

  defmodule RpUq do
    use Ecto.Schema

    import Ecto.Changeset

    schema "rp_uq" do
      field(:name, :string)
      field(:sku, :string)
      field(:region, :string)
    end

    def changeset(struct, attrs), do: cast(struct, attrs, [:name, :sku, :region])
  end

  defmodule MutualRefMigration do
    use Ecto.Migration

    def up do
      execute("DROP TABLE IF EXISTS rp_mut")

      execute(
        "CREATE TABLE rp_mut(id INTEGER PRIMARY KEY, label TEXT, next_id INTEGER " <>
          "REFERENCES rp_mut(id))"
      )

      # Two rows that reference each other (1 -> 2 -> 1).
      execute("INSERT INTO rp_mut VALUES (1, 'a', NULL), (2, 'b', 1)")
      execute("UPDATE rp_mut SET next_id = 2 WHERE id = 1")

      alter table(:rp_mut) do
        modify(:label, :text, null: true)
      end
    end
  end

  defmodule PopulatedCascadeAlterMigration do
    use Ecto.Migration

    def up do
      alter table(:rp_pc_parent) do
        modify(:name, :text, null: true)
      end
    end
  end

  defmodule PopulatedSetNullAlterMigration do
    use Ecto.Migration

    def up do
      alter table(:rp_ps_parent) do
        modify(:name, :text, null: true)
      end
    end
  end

  # --- helpers ---------------------------------------------------------------

  defp migrate!(module, version), do: Ecto.Migrator.up(PoolRepo, version, module, log: false)

  defp fk_rows(table), do: PoolRepo.query!("PRAGMA foreign_key_list('#{table}')").rows

  defp fk_check_clean?(table),
    do: PoolRepo.query!("PRAGMA foreign_key_check('#{table}')").rows == []

  defp count(table), do: PoolRepo.query!("SELECT count(*) FROM #{table}").rows |> hd() |> hd()

  defp insert_rejected(sql) do
    assert_raise XqliteEcto3.Error, fn -> PoolRepo.query!(sql) end
  end

  # --- scenarios -------------------------------------------------------------

  test "single-column FK with ON DELETE CASCADE is preserved and enforced" do
    migrate!(FkCascadeMigration, 20_260_721_100_001)

    # Rows survived the child rebuild.
    assert count("rp_c_child") == 1

    # FK present, targets the parent, carries the cascade action.
    assert [[_id, _seq, "rp_c_parent", "parent_id", "id", "NO ACTION", "CASCADE", _match]] =
             fk_rows("rp_c_child")

    assert fk_check_clean?("rp_c_child")

    orphan =
      insert_rejected("INSERT INTO rp_c_child(id, name, parent_id) VALUES (2, 'x', 999)")

    assert orphan.type == :constraint_violation
    assert %XqliteEcto3.Error.Constraint{subtype: :constraint_foreign_key} = orphan.details

    # Cascade actually fires on parent delete.
    PoolRepo.query!("DELETE FROM rp_c_parent WHERE id = 1")
    assert count("rp_c_child") == 0
  end

  test "single-column FK with ON DELETE SET NULL is preserved and nullifies on delete" do
    migrate!(FkSetNullMigration, 20_260_721_100_002)

    assert [[_id, _seq, "rp_sn_parent", "parent_id", "id", "NO ACTION", "SET NULL", _m]] =
             fk_rows("rp_sn_child")

    PoolRepo.query!("DELETE FROM rp_sn_parent WHERE id = 1")

    assert [[nil]] = PoolRepo.query!("SELECT parent_id FROM rp_sn_child WHERE id = 1").rows
  end

  test "FK with ON UPDATE CASCADE keeps its update action and cascades key changes" do
    migrate!(FkOnUpdateMigration, 20_260_721_100_003)

    assert [[_id, _seq, "rp_ou_parent", "pcode", "code", "CASCADE", "NO ACTION", _m]] =
             fk_rows("rp_ou_child")

    PoolRepo.query!("UPDATE rp_ou_parent SET code = 'y' WHERE code = 'x'")

    assert [["y"]] = PoolRepo.query!("SELECT pcode FROM rp_ou_child WHERE id = 1").rows
  end

  test "composite two-column FK is preserved with column order intact and enforced" do
    migrate!(CompositeFkMigration, 20_260_721_100_004)

    assert count("rp_cp_child") == 1

    # Two rows, seq 0/1, from (pa, pb) -> to (a, b) in order.
    assert [
             [id, 0, "rp_cp_parent", "pa", "a", _u0, "CASCADE", _m0],
             [id, 1, "rp_cp_parent", "pb", "b", _u1, "CASCADE", _m1]
           ] = fk_rows("rp_cp_child")

    assert fk_check_clean?("rp_cp_child")

    insert_rejected("INSERT INTO rp_cp_child(id, name, pa, pb) VALUES (2, 'y', 9, 9)")

    PoolRepo.query!("DELETE FROM rp_cp_parent WHERE a = 1 AND b = 2")
    assert count("rp_cp_child") == 0
  end

  test "implicit-PK reference (no column list) is preserved and enforced" do
    migrate!(ImplicitPkFkMigration, 20_260_721_100_005)

    assert count("rp_ip_child") == 1

    # `to` is NULL — the FK targets the parent's implicit primary key.
    assert [[_id, _seq, "rp_ip_parent", "pid", nil, _u, _d, _m]] = fk_rows("rp_ip_child")

    assert fk_check_clean?("rp_ip_child")

    insert_rejected("INSERT INTO rp_ip_child(id, name, pid) VALUES (2, 'x', 999)")
  end

  test "an incoming FK still points at the parent after the parent's drop+rename dance" do
    migrate!(IncomingFkMigration, 20_260_721_100_006)

    # The child's FK survived the parent rebuild and still targets the parent.
    assert [[_id, _seq, "rp_in_parent", "pid", "id", _u, "CASCADE", _m]] = fk_rows("rp_in_child")

    assert PoolRepo.query!("PRAGMA foreign_key_check").rows == []

    # Enforcement holds against the rebuilt parent.
    PoolRepo.query!("INSERT INTO rp_in_child(id, pid) VALUES (1, 1)")
    insert_rejected("INSERT INTO rp_in_child(id, pid) VALUES (2, 999)")

    # Cascade from the rebuilt parent still fires.
    PoolRepo.query!("DELETE FROM rp_in_parent WHERE id = 1")
    assert count("rp_in_child") == 0
  end

  test "self-referencing FK is preserved and enforced, rows intact" do
    migrate!(SelfRefFkMigration, 20_260_721_100_007)

    # All three self-referencing rows survived the dance.
    assert count("rp_self") == 3

    assert [[_id, _seq, "rp_self", "parent_id", "id", "NO ACTION", "CASCADE", _m]] =
             fk_rows("rp_self")

    assert fk_check_clean?("rp_self")

    insert_rejected("INSERT INTO rp_self(id, label, parent_id) VALUES (9, 'z', 999)")

    # Deleting the root cascades through the chain.
    PoolRepo.query!("DELETE FROM rp_self WHERE id = 1")
    assert count("rp_self") == 0
  end

  test "table-level UNIQUE constraints (single and composite) are preserved and enforced" do
    import Ecto.Changeset

    migrate!(UniqueMigration, 20_260_721_100_008)

    # Both UNIQUE constraints backed by origin-'u' auto-indexes on the new table.
    unique_origins =
      PoolRepo.query!("SELECT origin FROM pragma_index_list('rp_uq') WHERE origin = 'u'").rows

    assert length(unique_origins) == 2

    dup_sku =
      insert_rejected("INSERT INTO rp_uq(id, name, sku, region) VALUES (2, 'b', 's1', 'us')")

    assert dup_sku.type == :constraint_violation

    assert %XqliteEcto3.Error.Constraint{subtype: :constraint_unique, table: "rp_uq"} =
             dup_sku.details

    # The mapping still yields a name usable by Ecto.Changeset.unique_constraint/3.
    assert [unique: name] = XqliteEcto3.Connection.to_constraints(dup_sku, [])
    assert is_binary(name)

    insert_rejected("INSERT INTO rp_uq(id, name, sku, region) VALUES (3, 'a', 's3', 'eu')")

    # End to end: a real changeset actually converts to a changeset error — the
    # auto-index (sqlite_autoindex_*) name is transparent because SQLite reports
    # the table.column form and the mapping derives the conventional index name.
    single =
      %RpUq{}
      |> RpUq.changeset(%{name: "b", sku: "s1", region: "us"})
      |> unique_constraint(:sku)
      |> PoolRepo.insert()

    assert {:error, single_cs} = single
    assert {_msg, single_opts} = single_cs.errors[:sku]
    assert single_opts[:constraint] == :unique
    assert single_opts[:constraint_name] == "rp_uq_sku_index"

    # The composite form needs the explicit conventional name; column order intact.
    composite =
      %RpUq{}
      |> RpUq.changeset(%{name: "a", sku: "s_fresh", region: "eu"})
      |> unique_constraint(:name, name: "rp_uq_name_region_index")
      |> PoolRepo.insert()

    assert {:error, composite_cs} = composite
    assert {_msg, composite_opts} = composite_cs.errors[:name]
    assert composite_opts[:constraint] == :unique
    assert composite_opts[:constraint_name] == "rp_uq_name_region_index"
  end

  test "the dance leaves PRAGMA foreign_keys unchanged and copies mutually-referencing rows" do
    before = PoolRepo.query!("PRAGMA foreign_keys").rows

    migrate!(MutualRefMigration, 20_260_721_100_009)

    # foreign_keys enforcement state is untouched by the dance.
    assert PoolRepo.query!("PRAGMA foreign_keys").rows == before

    # Both rows that reference each other survived the copy without violating.
    assert count("rp_mut") == 2
    assert fk_check_clean?("rp_mut")
    assert [[_id, _seq, "rp_mut", "next_id", "id", _u, _d, _m]] = fk_rows("rp_mut")
  end

  test "rebuild of a table a populated child references with ON DELETE CASCADE refuses" do
    PoolRepo.query!("DROP TABLE IF EXISTS rp_pc_child")
    PoolRepo.query!("DROP TABLE IF EXISTS rp_pc_parent")
    PoolRepo.query!("CREATE TABLE rp_pc_parent(id INTEGER PRIMARY KEY, name TEXT)")

    PoolRepo.query!(
      "CREATE TABLE rp_pc_child(id INTEGER PRIMARY KEY, pid INTEGER " <>
        "REFERENCES rp_pc_parent(id) ON DELETE CASCADE)"
    )

    PoolRepo.query!("INSERT INTO rp_pc_parent(id, name) VALUES (1, 'p')")
    PoolRepo.query!("INSERT INTO rp_pc_child(id, pid) VALUES (1, 1)")

    # Dropping the parent in the rebuild would cascade-delete the child's rows.
    assert_raise ArgumentError, ~r/rp_pc_child/, fn ->
      migrate!(PopulatedCascadeAlterMigration, 20_260_721_100_010)
    end

    # The refusal fired before any destructive step — both tables are intact.
    assert count("rp_pc_parent") == 1
    assert count("rp_pc_child") == 1

    # The foreign key is still enforced against the un-rebuilt parent.
    assert fk_check_clean?("rp_pc_child")
    insert_rejected("INSERT INTO rp_pc_child(id, pid) VALUES (2, 999)")
  end

  test "rebuild of a table a populated child references with ON DELETE SET NULL refuses" do
    PoolRepo.query!("DROP TABLE IF EXISTS rp_ps_child")
    PoolRepo.query!("DROP TABLE IF EXISTS rp_ps_parent")
    PoolRepo.query!("CREATE TABLE rp_ps_parent(id INTEGER PRIMARY KEY, name TEXT)")

    PoolRepo.query!(
      "CREATE TABLE rp_ps_child(id INTEGER PRIMARY KEY, pid INTEGER " <>
        "REFERENCES rp_ps_parent(id) ON DELETE SET NULL)"
    )

    PoolRepo.query!("INSERT INTO rp_ps_parent(id, name) VALUES (1, 'p')")
    PoolRepo.query!("INSERT INTO rp_ps_child(id, pid) VALUES (1, 1)")

    # Dropping the parent in the rebuild would nullify the child's FK column.
    assert_raise ArgumentError, ~r/rp_ps_child/, fn ->
      migrate!(PopulatedSetNullAlterMigration, 20_260_721_100_011)
    end

    # SET NULL never fired — the child's FK value is unchanged, parent intact.
    assert [[1]] = PoolRepo.query!("SELECT pid FROM rp_ps_child WHERE id = 1").rows
    assert count("rp_ps_parent") == 1
  end
end
