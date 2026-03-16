defmodule XqliteEcto3.BulkOperationsTest do
  use ExUnit.Case, async: true

  alias XqliteEcto3.TestRepo, as: Repo
  import Ecto.Query
  import XqliteEcto3.TableHelper

  defmodule BU do
    use Ecto.Schema
    import Ecto.Changeset

    schema "bulk_users" do
      field(:name, :string)
      field(:email, :string)
      field(:age, :integer)
      field(:active, :boolean, default: true)
      timestamps()
    end

    def changeset(user, attrs \\ %{}),
      do: user |> cast(attrs, [:name, :email, :age, :active]) |> validate_required([:name])
  end

  setup_all do
    create_table!("bulk_users", user_columns())
  end

  setup do
    clear_table!("bulk_users")
  end

  # ---------------------------------------------------------------------------
  # insert_all
  # ---------------------------------------------------------------------------

  test "insert_all with list of maps" do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    {count, nil} =
      Repo.insert_all(BU, [
        %{name: "Alice", inserted_at: now, updated_at: now},
        %{name: "Bob", inserted_at: now, updated_at: now},
        %{name: "Carol", inserted_at: now, updated_at: now}
      ])

    assert count == 3
    names = Repo.all(from(u in BU, select: u.name, order_by: u.name))
    assert names == ["Alice", "Bob", "Carol"]
  end

  test "insert_all with keyword lists" do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    {count, nil} =
      Repo.insert_all(BU, [
        [name: "Dave", inserted_at: now, updated_at: now],
        [name: "Eve", inserted_at: now, updated_at: now]
      ])

    assert count == 2
  end

  test "insert_all returns 0 for empty list" do
    {count, nil} = Repo.insert_all(BU, [])
    assert count == 0
  end

  test "insert_all with returning" do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    {count, users} =
      Repo.insert_all(
        BU,
        [
          %{name: "Fay", inserted_at: now, updated_at: now},
          %{name: "Gus", inserted_at: now, updated_at: now}
        ],
        returning: [:id, :name]
      )

    assert count == 2
    names = Enum.map(users, & &1.name) |> Enum.sort()
    assert names == ["Fay", "Gus"]
  end

  # ---------------------------------------------------------------------------
  # update_all
  # ---------------------------------------------------------------------------

  test "update_all with set" do
    seed_users(3)

    {count, nil} =
      Repo.update_all(BU, set: [active: false])

    assert count == 3

    assert Repo.all(from(u in BU, where: u.active == true)) == []
  end

  test "update_all with where clause" do
    seed_users(5)

    {count, nil} =
      Repo.update_all(
        from(u in BU, where: u.age > 2),
        set: [name: "Updated"]
      )

    assert count == 3

    names = Repo.all(from(u in BU, select: u.name, order_by: u.age))
    assert names == ["User 1", "User 2", "Updated", "Updated", "Updated"]
  end

  test "update_all with inc" do
    seed_users(3)

    {count, nil} =
      Repo.update_all(BU, inc: [age: 10])

    assert count == 3

    ages = Repo.all(from(u in BU, select: u.age, order_by: u.age))
    assert ages == [11, 12, 13]
  end

  test "update_all returns 0 when no rows match" do
    seed_users(2)

    {count, nil} =
      Repo.update_all(
        from(u in BU, where: u.age > 999),
        set: [name: "Nobody"]
      )

    assert count == 0
  end

  # ---------------------------------------------------------------------------
  # delete_all
  # ---------------------------------------------------------------------------

  test "delete_all removes all rows" do
    seed_users(5)

    {count, nil} = Repo.delete_all(BU)

    assert count == 5
    assert Repo.all(BU) == []
  end

  test "delete_all with where clause" do
    seed_users(5)

    {count, nil} =
      Repo.delete_all(from(u in BU, where: u.age <= 2))

    assert count == 2
    names = Repo.all(from(u in BU, select: u.name, order_by: u.age))
    assert names == ["User 3", "User 4", "User 5"]
  end

  test "delete_all returns 0 on empty table" do
    {count, nil} = Repo.delete_all(BU)
    assert count == 0
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp seed_users(n) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    for i <- 1..n do
      {:ok, _} =
        Repo.insert(
          BU.changeset(%BU{}, %{name: "User #{i}", age: i})
          |> Ecto.Changeset.put_change(:inserted_at, now)
          |> Ecto.Changeset.put_change(:updated_at, now)
        )
    end
  end
end
