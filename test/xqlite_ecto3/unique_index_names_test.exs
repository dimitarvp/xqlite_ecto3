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
  end

  setup do
    clear_tables!(["uix_items", "uix_parts", "uix_dupes", "uix_exprs", "uix_pairs"])
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

  test "every unique index covering the violated columns is reported" do
    {:ok, _} = Repo.insert(Dupe.changeset(%Dupe{}, %{v: "both"}))

    assert {:error, %Error{} = err} = Repo.query("INSERT INTO uix_dupes(v) VALUES ('both')", [])

    assert %Constraint{unique_index_names: ["dupe_left_unique", "dupe_right_unique"]} =
             err.details

    assert Conn.to_constraints(err, []) == [
             unique: "dupe_left_unique",
             unique: "dupe_right_unique"
           ]
  end

  test "a changeset declaring every candidate converts" do
    {:ok, _} = Repo.insert(Dupe.changeset(%Dupe{}, %{v: "both"}))

    result =
      %Dupe{}
      |> Dupe.changeset(%{v: "both"})
      |> unique_constraint(:v, name: "dupe_left_unique")
      |> unique_constraint(:v, name: "dupe_right_unique")
      |> Repo.insert()

    assert {:error, changeset} = result
    names = for {:v, {_msg, opts}} <- changeset.errors, do: opts[:constraint_name]
    assert Enum.sort(names) == ["dupe_left_unique", "dupe_right_unique"]
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

    # The backing sqlite_autoindex_* name is never offered as a candidate.
    assert %Constraint{unique_index_names: [], unique_index_lookup: :ok} = err.details
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
end
