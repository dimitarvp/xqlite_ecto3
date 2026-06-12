defmodule XqliteEcto3.NullHandlingTest do
  use XqliteEcto3.AdapterCase, async: true

  defmodule NU do
    use Ecto.Schema
    import Ecto.Changeset

    schema "null_records" do
      field(:str, :string)
      field(:num, :integer)
      field(:flag, :boolean)
      field(:dec, :decimal)
      field(:map_field, :map)
      field(:arr_field, {:array, :string})
      field(:date_field, :date)
      field(:time_field, :time)
      field(:ndt_field, :naive_datetime)
      field(:udt_field, :utc_datetime)
      timestamps()
    end

    def changeset(record, attrs \\ %{}),
      do:
        record
        |> cast(attrs, [
          :str,
          :num,
          :flag,
          :dec,
          :map_field,
          :arr_field,
          :date_field,
          :time_field,
          :ndt_field,
          :udt_field
        ])
  end

  setup_all do
    create_table!(
      "null_records",
      "id INTEGER PRIMARY KEY AUTOINCREMENT, str TEXT, num INTEGER, flag INTEGER, dec TEXT, map_field TEXT, arr_field TEXT, date_field TEXT, time_field TEXT, ndt_field TEXT, udt_field TEXT, inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL"
    )
  end

  setup do
    clear_table!("null_records")
  end

  # ---------------------------------------------------------------------------
  # All-nil insert round-trips
  # ---------------------------------------------------------------------------

  test "insert with all nullable fields nil" do
    {:ok, record} = Repo.insert(NU.changeset(%NU{}, %{}))
    fetched = Repo.get(NU, record.id)

    assert fetched.str == nil
    assert fetched.num == nil
    assert fetched.flag == nil
    assert fetched.dec == nil
    assert fetched.map_field == nil
    assert fetched.arr_field == nil
    assert fetched.date_field == nil
    assert fetched.time_field == nil
    assert fetched.ndt_field == nil
    assert fetched.udt_field == nil
  end

  # ---------------------------------------------------------------------------
  # NULL in where clauses
  # ---------------------------------------------------------------------------

  test "is_nil in where finds null rows" do
    {:ok, _} = Repo.insert(NU.changeset(%NU{}, %{str: nil}))
    {:ok, _} = Repo.insert(NU.changeset(%NU{}, %{str: "hello"}))

    assert [%{str: nil}] = Repo.all(from(n in NU, where: is_nil(n.str)))
    assert [%{str: "hello"}] = Repo.all(from(n in NU, where: not is_nil(n.str)))
  end

  test "NULL != comparison semantics (NULL != value is NULL, not true)" do
    {:ok, _} = Repo.insert(NU.changeset(%NU{}, %{num: nil}))
    {:ok, _} = Repo.insert(NU.changeset(%NU{}, %{num: 42}))

    # In SQL, NULL != 42 is NULL (falsy), so only the row with 42 != 42 = false is excluded
    results = Repo.all(from(n in NU, where: n.num != 42))
    assert results == []
  end

  # ---------------------------------------------------------------------------
  # Update to/from NULL
  # ---------------------------------------------------------------------------

  test "update field from value to nil" do
    {:ok, record} = Repo.insert(NU.changeset(%NU{}, %{str: "hello", num: 42}))

    {:ok, updated} = Repo.update(Ecto.Changeset.change(record, str: nil, num: nil))
    assert updated.str == nil
    assert updated.num == nil

    fetched = Repo.get(NU, record.id)
    assert fetched.str == nil
    assert fetched.num == nil
  end

  test "update field from nil to value" do
    {:ok, record} = Repo.insert(NU.changeset(%NU{}, %{}))

    {:ok, updated} = Repo.update(Ecto.Changeset.change(record, str: "world", num: 99))
    assert updated.str == "world"
    assert updated.num == 99
  end

  # ---------------------------------------------------------------------------
  # NULL in aggregates
  # ---------------------------------------------------------------------------

  test "count excludes nulls when counting a field" do
    {:ok, _} = Repo.insert(NU.changeset(%NU{}, %{num: 1}))
    {:ok, _} = Repo.insert(NU.changeset(%NU{}, %{num: nil}))
    {:ok, _} = Repo.insert(NU.changeset(%NU{}, %{num: 3}))

    assert Repo.aggregate(NU, :count) == 3
    assert Repo.aggregate(NU, :count, :num) == 2
  end

  test "sum ignores nulls" do
    {:ok, _} = Repo.insert(NU.changeset(%NU{}, %{num: 10}))
    {:ok, _} = Repo.insert(NU.changeset(%NU{}, %{num: nil}))
    {:ok, _} = Repo.insert(NU.changeset(%NU{}, %{num: 20}))

    assert Repo.aggregate(NU, :sum, :num) == 30
  end

  # ---------------------------------------------------------------------------
  # NULL ordering
  # ---------------------------------------------------------------------------

  test "nulls sort after non-nulls in ascending order" do
    {:ok, _} = Repo.insert(NU.changeset(%NU{}, %{num: 2}))
    {:ok, _} = Repo.insert(NU.changeset(%NU{}, %{num: nil}))
    {:ok, _} = Repo.insert(NU.changeset(%NU{}, %{num: 1}))

    results = Repo.all(from(n in NU, select: n.num, order_by: [asc: n.num]))
    # SQLite sorts NULLs first in ASC order
    assert results == [nil, 1, 2]
  end

  # ---------------------------------------------------------------------------
  # coalesce via fragment
  # ---------------------------------------------------------------------------

  test "coalesce replaces null with default" do
    {:ok, _} = Repo.insert(NU.changeset(%NU{}, %{str: nil}))
    {:ok, _} = Repo.insert(NU.changeset(%NU{}, %{str: "hello"}))

    results =
      Repo.all(
        from(n in NU,
          select: fragment("coalesce(?, ?)", n.str, "default"),
          order_by: [asc: n.id]
        )
      )

    assert results == ["default", "hello"]
  end
end
