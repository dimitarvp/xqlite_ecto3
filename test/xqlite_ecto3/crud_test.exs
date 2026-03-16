defmodule XqliteEcto3.CrudTest do
  use ExUnit.Case

  alias XqliteEcto3.TestRepo, as: Repo
  alias XqliteEcto3.Test.User

  setup do
    Repo.query!("DROP TABLE IF EXISTS users")
    Repo.query!("DROP TABLE IF EXISTS posts")

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

    Repo.query!("""
    CREATE TABLE posts (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      title TEXT NOT NULL,
      body TEXT,
      user_id INTEGER REFERENCES users(id),
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Insert
  # ---------------------------------------------------------------------------

  test "insert a user" do
    {:ok, user} =
      Repo.insert(%User{name: "Alice", email: "alice@example.com", age: 30})

    assert user.id != nil
    assert user.name == "Alice"
    assert user.email == "alice@example.com"
    assert user.age == 30
    assert user.active == true
  end

  test "insert with defaults" do
    {:ok, user} = Repo.insert(%User{name: "Bob"})

    assert user.active == true
    assert user.inserted_at != nil
    assert user.updated_at != nil
  end

  # ---------------------------------------------------------------------------
  # Get / Fetch
  # ---------------------------------------------------------------------------

  test "get by id" do
    {:ok, inserted} = Repo.insert(%User{name: "Carol", age: 25})

    fetched = Repo.get(User, inserted.id)
    assert fetched.name == "Carol"
    assert fetched.age == 25
  end

  test "get returns nil for missing id" do
    assert Repo.get(User, 999_999) == nil
  end

  test "get_by field" do
    {:ok, _} = Repo.insert(%User{name: "Dave", email: "dave@example.com"})

    found = Repo.get_by(User, email: "dave@example.com")
    assert found.name == "Dave"
  end

  # ---------------------------------------------------------------------------
  # Query
  # ---------------------------------------------------------------------------

  test "all returns all rows" do
    {:ok, _} = Repo.insert(%User{name: "Eve"})
    {:ok, _} = Repo.insert(%User{name: "Frank"})

    users = Repo.all(User)
    assert length(users) == 2
  end

  test "query with where clause" do
    {:ok, _} = Repo.insert(%User{name: "Grace", age: 40})
    {:ok, _} = Repo.insert(%User{name: "Hank", age: 20})

    import Ecto.Query

    older = Repo.all(from u in User, where: u.age > 30)
    assert length(older) == 1
    assert hd(older).name == "Grace"
  end

  test "query with order_by" do
    {:ok, _} = Repo.insert(%User{name: "Zara"})
    {:ok, _} = Repo.insert(%User{name: "Amy"})

    import Ecto.Query

    sorted = Repo.all(from u in User, order_by: u.name)
    names = Enum.map(sorted, & &1.name)
    assert names == ["Amy", "Zara"]
  end

  test "query with limit" do
    for i <- 1..10 do
      {:ok, _} = Repo.insert(%User{name: "User #{i}"})
    end

    import Ecto.Query

    limited = Repo.all(from u in User, limit: 3)
    assert length(limited) == 3
  end

  test "query with select" do
    {:ok, _} = Repo.insert(%User{name: "Ivy", age: 35})

    import Ecto.Query

    names = Repo.all(from u in User, select: u.name)
    assert names == ["Ivy"]
  end

  # ---------------------------------------------------------------------------
  # Update
  # ---------------------------------------------------------------------------

  test "update a user" do
    {:ok, user} = Repo.insert(%User{name: "Jack", age: 50})

    changeset = Ecto.Changeset.change(user, age: 51)
    {:ok, updated} = Repo.update(changeset)

    assert updated.age == 51
    assert updated.id == user.id
  end

  test "update only changed fields" do
    {:ok, user} = Repo.insert(%User{name: "Kate", email: "kate@old.com", age: 28})

    changeset = Ecto.Changeset.change(user, email: "kate@new.com")
    {:ok, updated} = Repo.update(changeset)

    assert updated.email == "kate@new.com"
    assert updated.name == "Kate"
    assert updated.age == 28
  end

  # ---------------------------------------------------------------------------
  # Delete
  # ---------------------------------------------------------------------------

  test "delete a user" do
    {:ok, user} = Repo.insert(%User{name: "Leo"})

    {:ok, deleted} = Repo.delete(user)
    assert deleted.id == user.id

    assert Repo.get(User, user.id) == nil
  end

  # ---------------------------------------------------------------------------
  # Aggregate
  # ---------------------------------------------------------------------------

  test "count" do
    {:ok, _} = Repo.insert(%User{name: "A"})
    {:ok, _} = Repo.insert(%User{name: "B"})
    {:ok, _} = Repo.insert(%User{name: "C"})

    assert Repo.aggregate(User, :count) == 3
  end

  # ---------------------------------------------------------------------------
  # Transactions
  # ---------------------------------------------------------------------------

  test "transaction commit" do
    {:ok, user} =
      Repo.transaction(fn ->
        {:ok, user} = Repo.insert(%User{name: "Mia"})
        user
      end)

    assert user.name == "Mia"
    assert Repo.get(User, user.id) != nil
  end

  test "transaction rollback" do
    Repo.transaction(fn ->
      {:ok, _} = Repo.insert(%User{name: "Nina"})
      Repo.rollback(:oops)
    end)

    import Ecto.Query

    assert Repo.all(from u in User, where: u.name == "Nina") == []
  end
end
