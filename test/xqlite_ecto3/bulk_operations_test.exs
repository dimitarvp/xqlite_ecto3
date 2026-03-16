defmodule XqliteEcto3.BulkOperationsTest do
  use ExUnit.Case

  alias XqliteEcto3.TestRepo, as: Repo
  alias XqliteEcto3.Test.User
  import Ecto.Query

  setup do
    Repo.query!("DROP TABLE IF EXISTS posts")
    Repo.query!("DROP TABLE IF EXISTS users")

    Repo.query!("""
    CREATE TABLE users (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      email TEXT,
      age INTEGER,
      active INTEGER DEFAULT 1,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)

    :ok
  end

  # ---------------------------------------------------------------------------
  # insert_all
  # ---------------------------------------------------------------------------

  test "insert_all with list of maps" do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    {count, nil} =
      Repo.insert_all(User, [
        %{name: "Alice", inserted_at: now, updated_at: now},
        %{name: "Bob", inserted_at: now, updated_at: now},
        %{name: "Carol", inserted_at: now, updated_at: now}
      ])

    assert count == 3
    assert length(Repo.all(User)) == 3
  end

  test "insert_all with keyword lists" do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    {count, nil} =
      Repo.insert_all(User, [
        [name: "Dave", inserted_at: now, updated_at: now],
        [name: "Eve", inserted_at: now, updated_at: now]
      ])

    assert count == 2
  end

  test "insert_all returns 0 for empty list" do
    {count, nil} = Repo.insert_all(User, [])
    assert count == 0
  end

  test "insert_all with returning" do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    {count, users} =
      Repo.insert_all(
        User,
        [
          %{name: "Fay", inserted_at: now, updated_at: now},
          %{name: "Gus", inserted_at: now, updated_at: now}
        ],
        returning: [:id, :name]
      )

    assert count == 2
    assert length(users) == 2
    names = Enum.map(users, & &1.name) |> Enum.sort()
    assert names == ["Fay", "Gus"]
  end

  # ---------------------------------------------------------------------------
  # update_all
  # ---------------------------------------------------------------------------

  test "update_all with set" do
    seed_users(3)

    {count, nil} =
      Repo.update_all(User, set: [active: false])

    assert count == 3

    users = Repo.all(from u in User, where: u.active == false)
    assert length(users) == 3
  end

  test "update_all with where clause" do
    seed_users(5)

    {count, nil} =
      Repo.update_all(
        from(u in User, where: u.age > 2),
        set: [name: "Updated"]
      )

    assert count == 3

    updated = Repo.all(from u in User, where: u.name == "Updated")
    assert length(updated) == 3
  end

  test "update_all with inc" do
    seed_users(3)

    {count, nil} =
      Repo.update_all(User, inc: [age: 10])

    assert count == 3

    ages = Repo.all(from u in User, select: u.age, order_by: u.age)
    assert ages == [11, 12, 13]
  end

  test "update_all returns 0 when no rows match" do
    seed_users(2)

    {count, nil} =
      Repo.update_all(
        from(u in User, where: u.age > 999),
        set: [name: "Nobody"]
      )

    assert count == 0
  end

  # ---------------------------------------------------------------------------
  # delete_all
  # ---------------------------------------------------------------------------

  test "delete_all removes all rows" do
    seed_users(5)

    {count, nil} = Repo.delete_all(User)

    assert count == 5
    assert Repo.all(User) == []
  end

  test "delete_all with where clause" do
    seed_users(5)

    {count, nil} =
      Repo.delete_all(from u in User, where: u.age <= 2)

    assert count == 2
    assert length(Repo.all(User)) == 3
  end

  test "delete_all returns 0 on empty table" do
    {count, nil} = Repo.delete_all(User)
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
          User.changeset(%User{}, %{name: "User #{i}", age: i})
          |> Ecto.Changeset.put_change(:inserted_at, now)
          |> Ecto.Changeset.put_change(:updated_at, now)
        )
    end
  end
end
