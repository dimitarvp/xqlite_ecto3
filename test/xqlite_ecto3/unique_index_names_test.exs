defmodule XqliteEcto3.UniqueIndexNamesTest do
  @moduledoc """
  A UNIQUE violation on a plain or partial unique index tells SQLite
  only which table and columns collided, never which index. The
  adapter reads the real index names back from the database on the
  error path, so a changeset can declare the name the index was
  actually created with.
  """

  use XqliteEcto3.AdapterCase, async: true

  import Ecto.Changeset

  alias XqliteEcto3.Connection, as: Conn
  alias XqliteEcto3.Error
  alias XqliteEcto3.Error.Constraint

  defmodule Item do
    use Ecto.Schema

    import Ecto.Changeset

    schema "uix_items" do
      field(:v, :string)
      field(:w, :string)
      field(:sku, :string)
    end

    def changeset(struct, attrs), do: cast(struct, attrs, [:v, :w, :sku])
  end

  defmodule Part do
    use Ecto.Schema

    import Ecto.Changeset

    schema "uix_parts" do
      field(:v, :string)
      field(:active, :integer)
    end

    def changeset(struct, attrs), do: cast(struct, attrs, [:v, :active])
  end

  defmodule Dupe do
    use Ecto.Schema

    import Ecto.Changeset

    schema "uix_dupes" do
      field(:v, :string)
    end

    def changeset(struct, attrs), do: cast(struct, attrs, [:v])
  end

  defmodule Sib do
    use Ecto.Schema

    import Ecto.Changeset

    schema "uix_sibs" do
      field(:v, :string)
      field(:active, :integer)
    end

    def changeset(struct, attrs), do: cast(struct, attrs, [:v, :active])
  end

  defmodule Coll do
    use Ecto.Schema

    import Ecto.Changeset

    schema "uix_colls" do
      field(:v, :string)
    end

    def changeset(struct, attrs), do: cast(struct, attrs, [:v])
  end

  defmodule Auto do
    use Ecto.Schema

    import Ecto.Changeset

    schema "uix_autos" do
      field(:v, :string)
      field(:active, :integer)
    end

    def changeset(struct, attrs), do: cast(struct, attrs, [:v, :active])
  end

  defmodule AutoColl do
    use Ecto.Schema

    import Ecto.Changeset

    schema "uix_autocolls" do
      field(:v, :string)
    end

    def changeset(struct, attrs), do: cast(struct, attrs, [:v])
  end

  defmodule Expr do
    use Ecto.Schema

    import Ecto.Changeset

    schema "uix_exprs" do
      field(:v, :string)
    end

    def changeset(struct, attrs), do: cast(struct, attrs, [:v])
  end

  defmodule Pair do
    use Ecto.Schema

    import Ecto.Changeset

    schema "uix_pairs" do
      field(:a, :string)
      field(:b, :string)
    end

    def changeset(struct, attrs), do: cast(struct, attrs, [:a, :b])
  end

  setup_all do
    create_table!(
      "uix_items",
      "id INTEGER PRIMARY KEY AUTOINCREMENT, v TEXT, w TEXT, sku TEXT, UNIQUE(sku)",
      [
        "CREATE UNIQUE INDEX IF NOT EXISTS items_v_unique ON uix_items(v)",
        "CREATE UNIQUE INDEX IF NOT EXISTS uix_items_w_index ON uix_items(w)"
      ]
    )

    create_table!(
      "uix_parts",
      "id INTEGER PRIMARY KEY AUTOINCREMENT, v TEXT, active INTEGER",
      ["CREATE UNIQUE INDEX IF NOT EXISTS live_part_unique ON uix_parts(v) WHERE active = 1"]
    )

    create_table!(
      "uix_dupes",
      "id INTEGER PRIMARY KEY AUTOINCREMENT, v TEXT",
      [
        "CREATE UNIQUE INDEX IF NOT EXISTS dupe_left_unique ON uix_dupes(v)",
        "CREATE UNIQUE INDEX IF NOT EXISTS dupe_right_unique ON uix_dupes(v)"
      ]
    )

    create_table!(
      "uix_exprs",
      "id INTEGER PRIMARY KEY AUTOINCREMENT, v TEXT",
      ["CREATE UNIQUE INDEX IF NOT EXISTS expr_lower_unique ON uix_exprs(lower(v))"]
    )

    create_table!(
      "uix_pairs",
      "id INTEGER PRIMARY KEY AUTOINCREMENT, a TEXT, b TEXT",
      ["CREATE UNIQUE INDEX IF NOT EXISTS pair_unique ON uix_pairs(b, a)"]
    )

    create_table!(
      "uix_sibs",
      "id INTEGER PRIMARY KEY AUTOINCREMENT, v TEXT, active INTEGER",
      [
        "CREATE UNIQUE INDEX IF NOT EXISTS uix_sibs_v_index ON uix_sibs(v)",
        "CREATE UNIQUE INDEX IF NOT EXISTS sib_live ON uix_sibs(v) WHERE active = 1"
      ]
    )

    create_table!(
      "uix_colls",
      "id INTEGER PRIMARY KEY AUTOINCREMENT, v TEXT",
      [
        "CREATE UNIQUE INDEX IF NOT EXISTS uix_colls_v_index ON uix_colls(v)",
        "CREATE UNIQUE INDEX IF NOT EXISTS coll_nocase ON uix_colls(v COLLATE NOCASE)"
      ]
    )

    create_table!(
      "uix_autos",
      "id INTEGER PRIMARY KEY AUTOINCREMENT, v TEXT, active INTEGER, UNIQUE(v)",
      ["CREATE UNIQUE INDEX IF NOT EXISTS auto_live ON uix_autos(v) WHERE active = 1"]
    )

    create_table!(
      "uix_autocolls",
      "id INTEGER PRIMARY KEY AUTOINCREMENT, v TEXT, UNIQUE(v)",
      ["CREATE UNIQUE INDEX IF NOT EXISTS autocoll_nocase ON uix_autocolls(v COLLATE NOCASE)"]
    )

    cap_columns = Enum.map_join(0..24, ", ", fn i -> "c#{i} TEXT" end)

    create_table!(
      "uix_caps",
      "id INTEGER PRIMARY KEY AUTOINCREMENT, " <> cap_columns,
      for(i <- 0..24, do: "CREATE UNIQUE INDEX IF NOT EXISTS cap_uq_#{i} ON uix_caps(c#{i})")
    )
  end

  setup do
    clear_tables!([
      "uix_items",
      "uix_parts",
      "uix_dupes",
      "uix_exprs",
      "uix_pairs",
      "uix_sibs",
      "uix_colls",
      "uix_autos",
      "uix_autocolls",
      "uix_caps"
    ])
  end

  # ---------------------------------------------------------------------------
  # Custom-named indexes
  # ---------------------------------------------------------------------------

  test "a custom-named unique index converts under its declared name" do
    {:ok, _} = Repo.insert(Item.changeset(%Item{}, %{v: "dup"}))

    result =
      %Item{}
      |> Item.changeset(%{v: "dup"})
      |> unique_constraint(:v, name: "items_v_unique")
      |> Repo.insert()

    assert {:error, changeset} = result
    assert {_msg, opts} = changeset.errors[:v]
    assert opts[:constraint] == :unique
    assert opts[:constraint_name] == "items_v_unique"
  end

  test "a custom-named unique index is the only mapped constraint" do
    {:ok, _} = Repo.insert(Item.changeset(%Item{}, %{v: "shape"}))

    assert {:error, %Error{} = err} = Repo.query("INSERT INTO uix_items(v) VALUES ('shape')", [])

    assert %Constraint{
             subtype: :constraint_unique,
             table: "uix_items",
             columns: ["v"],
             unique_index_names: ["items_v_unique"],
             unique_index_lookup: :ok
           } = err.details

    assert Conn.to_constraints(err, []) == [unique: "items_v_unique"]
  end

  test "a custom-named partial unique index converts under its declared name" do
    {:ok, _} = Repo.insert(Part.changeset(%Part{}, %{v: "dup", active: 1}))

    result =
      %Part{}
      |> Part.changeset(%{v: "dup", active: 1})
      |> unique_constraint(:v, name: "live_part_unique")
      |> Repo.insert()

    assert {:error, changeset} = result
    assert {_msg, opts} = changeset.errors[:v]
    assert opts[:constraint] == :unique
    assert opts[:constraint_name] == "live_part_unique"
  end

  test "a partial unique index only fires for rows its condition covers" do
    {:ok, _} = Repo.insert(Part.changeset(%Part{}, %{v: "dup", active: 1}))
    assert {:ok, _} = Repo.insert(Part.changeset(%Part{}, %{v: "dup", active: 0}))
  end

  test "a custom-named index over several columns matches in index order" do
    {:ok, _} = Repo.insert(Pair.changeset(%Pair{}, %{a: "a1", b: "b1"}))

    assert {:error, %Error{} = err} =
             Repo.query("INSERT INTO uix_pairs(a, b) VALUES ('a1', 'b1')", [])

    assert %Constraint{columns: ["b", "a"], unique_index_names: ["pair_unique"]} = err.details

    result =
      %Pair{}
      |> Pair.changeset(%{a: "a1", b: "b1"})
      |> unique_constraint(:a, name: "pair_unique")
      |> Repo.insert()

    assert {:error, changeset} = result
    assert {_msg, opts} = changeset.errors[:a]
    assert opts[:constraint] == :unique
    assert opts[:constraint_name] == "pair_unique"
  end

  # ---------------------------------------------------------------------------
  # Several unique indexes over the same columns
  # ---------------------------------------------------------------------------

  test "ambiguous candidates are recorded but the derived name is emitted" do
    {:ok, _} = Repo.insert(Dupe.changeset(%Dupe{}, %{v: "both"}))

    assert {:error, %Error{} = err} = Repo.query("INSERT INTO uix_dupes(v) VALUES ('both')", [])

    assert %Constraint{unique_index_names: ["dupe_left_unique", "dupe_right_unique"]} =
             err.details

    assert Conn.to_constraints(err, []) == [unique: "uix_dupes_v_index"]
  end

  test "a bare unique_constraint converts when the candidates are ambiguous" do
    {:ok, _} = Repo.insert(Dupe.changeset(%Dupe{}, %{v: "both"}))

    result =
      %Dupe{}
      |> Dupe.changeset(%{v: "both"})
      |> unique_constraint(:v)
      |> Repo.insert()

    assert {:error, changeset} = result
    assert [{:v, {_msg, opts}}] = changeset.errors
    assert opts[:constraint_name] == "uix_dupes_v_index"
  end

  test "a sibling partial index does not break a by-the-book changeset" do
    {:ok, _} = Repo.insert(Sib.changeset(%Sib{}, %{v: "p", active: 0}))

    assert {:error, %Error{} = err} =
             Repo.query("INSERT INTO uix_sibs(v, active) VALUES ('p', 0)", [])

    assert %Constraint{unique_index_names: ["sib_live", "uix_sibs_v_index"]} = err.details
    assert Conn.to_constraints(err, []) == [unique: "uix_sibs_v_index"]

    result =
      %Sib{}
      |> Sib.changeset(%{v: "p", active: 0})
      |> unique_constraint(:v)
      |> Repo.insert()

    assert {:error, changeset} = result
    assert [{:v, {_msg, opts}}] = changeset.errors
    assert opts[:constraint_name] == "uix_sibs_v_index"
  end

  test "a sibling index under another collation does not break a by-the-book changeset" do
    {:ok, _} = Repo.insert(Coll.changeset(%Coll{}, %{v: "c"}))

    assert {:error, %Error{} = err} = Repo.query("INSERT INTO uix_colls(v) VALUES ('c')", [])

    assert %Constraint{unique_index_names: ["coll_nocase", "uix_colls_v_index"]} = err.details
    assert Conn.to_constraints(err, []) == [unique: "uix_colls_v_index"]

    result =
      %Coll{}
      |> Coll.changeset(%{v: "c"})
      |> unique_constraint(:v)
      |> Repo.insert()

    assert {:error, changeset} = result
    assert [{:v, {_msg, opts}}] = changeset.errors
    assert opts[:constraint_name] == "uix_colls_v_index"
  end

  test "an autoindex firing beside an innocent named partial sibling stays ambiguous" do
    {:ok, _} = Repo.insert(Auto.changeset(%Auto{}, %{v: "p", active: 0}))

    assert {:error, %Error{} = err} =
             Repo.query("INSERT INTO uix_autos(v, active) VALUES ('p', 0)", [])

    assert %Constraint{unique_index_names: ["auto_live", "sqlite_autoindex_uix_autos_1"]} =
             err.details

    assert Conn.to_constraints(err, []) == [unique: "uix_autos_v_index"]

    result =
      %Auto{}
      |> Auto.changeset(%{v: "p", active: 0})
      |> unique_constraint(:v)
      |> Repo.insert()

    assert {:error, changeset} = result
    assert [{:v, {_msg, opts}}] = changeset.errors
    assert opts[:constraint_name] == "uix_autos_v_index"
  end

  test "an autoindex firing beside a named collation sibling stays ambiguous" do
    {:ok, _} = Repo.insert(AutoColl.changeset(%AutoColl{}, %{v: "c"}))

    assert {:error, %Error{} = err} =
             Repo.query("INSERT INTO uix_autocolls(v) VALUES ('c')", [])

    assert %Constraint{
             unique_index_names: ["autocoll_nocase", "sqlite_autoindex_uix_autocolls_1"]
           } = err.details

    assert Conn.to_constraints(err, []) == [unique: "uix_autocolls_v_index"]

    result =
      %AutoColl{}
      |> AutoColl.changeset(%{v: "c"})
      |> unique_constraint(:v)
      |> Repo.insert()

    assert {:error, changeset} = result
    assert [{:v, {_msg, opts}}] = changeset.errors
    assert opts[:constraint_name] == "uix_autocolls_v_index"
  end

  test "more named unique indexes than the lookup cap degrade to the derived name" do
    {:ok, _} = Repo.query("INSERT INTO uix_caps(c0) VALUES ('x')", [])

    assert {:error, %Error{} = err} = Repo.query("INSERT INTO uix_caps(c0) VALUES ('x')", [])

    assert %Constraint{
             unique_index_names: [],
             unique_index_lookup: {:unavailable, {:too_many_unique_indexes, 25}}
           } = err.details

    assert Conn.to_constraints(err, []) == [unique: "uix_caps_c0_index"]
  end

  # ---------------------------------------------------------------------------
  # Controls — the conventional derived name must keep working
  # ---------------------------------------------------------------------------

  test "a conventionally named unique index still converts without a :name" do
    {:ok, _} = Repo.insert(Item.changeset(%Item{}, %{w: "dup"}))

    result =
      %Item{}
      |> Item.changeset(%{w: "dup"})
      |> unique_constraint(:w)
      |> Repo.insert()

    assert {:error, changeset} = result
    assert {_msg, opts} = changeset.errors[:w]
    assert opts[:constraint] == :unique
    assert opts[:constraint_name] == "uix_items_w_index"
  end

  test "a table-level UNIQUE clause still converts under the derived name" do
    {:ok, _} = Repo.insert(Item.changeset(%Item{}, %{sku: "dup"}))

    result =
      %Item{}
      |> Item.changeset(%{sku: "dup"})
      |> unique_constraint(:sku)
      |> Repo.insert()

    assert {:error, changeset} = result
    assert {_msg, opts} = changeset.errors[:sku]
    assert opts[:constraint] == :unique
    assert opts[:constraint_name] == "uix_items_sku_index"
  end

  test "a table-level UNIQUE clause maps to exactly one constraint" do
    {:ok, _} = Repo.insert(Item.changeset(%Item{}, %{sku: "shape"}))

    assert {:error, %Error{} = err} =
             Repo.query("INSERT INTO uix_items(sku) VALUES ('shape')", [])

    # The backing sqlite_autoindex_* is recorded as the matching index,
    # but no changeset can declare it, so the derived name is emitted.
    assert %Constraint{
             unique_index_names: ["sqlite_autoindex_uix_items_1"],
             unique_index_lookup: :ok
           } = err.details

    assert Conn.to_constraints(err, []) == [unique: "uix_items_sku_index"]
  end

  test "an expression unique index keeps converting under the name SQLite reports" do
    {:ok, _} = Repo.insert(Expr.changeset(%Expr{}, %{v: "DUP"}))

    result =
      %Expr{}
      |> Expr.changeset(%{v: "dup"})
      |> unique_constraint(:v, name: "expr_lower_unique")
      |> Repo.insert()

    assert {:error, changeset} = result
    assert {_msg, opts} = changeset.errors[:v]
    assert opts[:constraint] == :unique
    assert opts[:constraint_name] == "expr_lower_unique"
  end

  test "an expression unique index needs no lookup" do
    {:ok, _} = Repo.insert(Expr.changeset(%Expr{}, %{v: "SHAPE"}))

    assert {:error, %Error{} = err} = Repo.query("INSERT INTO uix_exprs(v) VALUES ('shape')", [])

    assert %Constraint{
             index_name: "expr_lower_unique",
             unique_index_names: [],
             unique_index_lookup: :not_run
           } = err.details

    assert Conn.to_constraints(err, []) == [unique: "expr_lower_unique"]
  end

  # ---------------------------------------------------------------------------
  # Lookup budget
  # ---------------------------------------------------------------------------

  test "elapsed time at or under the budget stays within it" do
    assert XqliteEcto3.UniqueIndexNames.within_budget?(1_000, 50, 1_050)
    assert XqliteEcto3.UniqueIndexNames.within_budget?(1_000, 50, 1_000)
    assert XqliteEcto3.UniqueIndexNames.within_budget?(1_000, 0, 1_000)
  end

  test "elapsed time over the budget is out" do
    refute XqliteEcto3.UniqueIndexNames.within_budget?(1_000, 50, 1_051)
  end

  test "a zero-reported busy timeout gets the fixed budget, not zero and not unlimited" do
    assert XqliteEcto3.UniqueIndexNames.lookup_budget_ms(0) == 500
    assert XqliteEcto3.UniqueIndexNames.lookup_budget_ms(2_000) == 2_000
  end

  # ---------------------------------------------------------------------------
  # Degradation
  # ---------------------------------------------------------------------------

  test "an unusable connection degrades to the conventional derived name" do
    conn = closed_conn("degrade")

    resolved = XqliteEcto3.UniqueIndexNames.resolve(vanished_table_error(), conn)

    assert %Constraint{
             subtype: :constraint_unique,
             unique_index_names: [],
             unique_index_lookup: {:unavailable, _reason}
           } = resolved.details

    assert resolved.message == "UNIQUE constraint failed: gone.v"
    assert Conn.to_constraints(resolved, []) == [unique: "gone_v_index"]
  end

  test "a table that no longer exists degrades to the conventional derived name" do
    conn = open_conn("vanished")

    resolved = XqliteEcto3.UniqueIndexNames.resolve(vanished_table_error(), conn)

    assert %Constraint{unique_index_names: []} = resolved.details
    assert Conn.to_constraints(resolved, []) == [unique: "gone_v_index"]
  end

  test "busy_timeout 0 never degrades the lookup, across many candidates" do
    conn = open_conn("zero_budget")

    decoy_cols = Enum.map_join(0..11, ", ", fn i -> "d#{i} TEXT" end)

    {:ok, _} =
      XqliteNIF.query(
        conn,
        "CREATE TABLE zb_items (id INTEGER PRIMARY KEY, v TEXT, #{decoy_cols})",
        []
      )

    {:ok, _} = XqliteNIF.query(conn, "CREATE UNIQUE INDEX zb_items_real ON zb_items (v)", [])

    for i <- 0..11 do
      {:ok, _} =
        XqliteNIF.query(conn, "CREATE UNIQUE INDEX zb_items_d#{i}_uq ON zb_items (d#{i})", [])
    end

    {:ok, _} = XqliteNIF.set_pragma(conn, "busy_timeout", 0)

    for _ <- 1..30 do
      resolved = XqliteEcto3.UniqueIndexNames.resolve(zero_budget_error(), conn)

      assert %Constraint{unique_index_lookup: :ok, unique_index_names: ["zb_items_real"]} =
               resolved.details
    end
  end

  defp zero_budget_error do
    Error.wrap(
      {:constraint_violation, :constraint_unique,
       %{message: "UNIQUE constraint failed: zb_items.v", table: "zb_items", columns: ["v"]}}
    )
  end

  defp vanished_table_error do
    Error.wrap(
      {:constraint_violation, :constraint_unique,
       %{message: "UNIQUE constraint failed: gone.v", table: "gone", columns: ["v"]}}
    )
  end

  defp open_conn(tag) do
    path = Path.join(System.tmp_dir!(), "xqlite_uix_#{tag}_#{System.os_time(:nanosecond)}.db")

    for ext <- ["", "-wal", "-shm"], do: File.rm(path <> ext)

    {:ok, conn} = XqliteNIF.open(path)

    on_exit(fn ->
      XqliteNIF.close(conn)
      for ext <- ["", "-wal", "-shm"], do: File.rm(path <> ext)
    end)

    conn
  end

  defp closed_conn(tag) do
    conn = open_conn(tag)
    :ok = XqliteNIF.close(conn)
    conn
  end

  test "an index that vanishes between the pragma reads degrades instead of shrinking the count" do
    conn = open_conn("vanish")

    {:ok, _} = XqliteNIF.query(conn, "CREATE TABLE vt(v TEXT)", [])
    {:ok, _} = XqliteNIF.query(conn, "CREATE UNIQUE INDEX vanish_ix ON vt(v)", [])

    assert {:cont, {:ok, ["vanish_ix"]}} =
             XqliteEcto3.UniqueIndexNames.budgeted_match(conn, ["v"], "vanish_ix", [])

    {:ok, _} = XqliteNIF.query(conn, "DROP INDEX vanish_ix", [])

    assert {:halt, {:error, {:index_vanished, "vanish_ix"}}} =
             XqliteEcto3.UniqueIndexNames.budgeted_match(conn, ["v"], "vanish_ix", [])
  end
end
