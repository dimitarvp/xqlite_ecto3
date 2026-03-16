defmodule XqliteEcto3.UpsertTest do
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

    Repo.query!("CREATE UNIQUE INDEX users_email_index ON users(email)")

    :ok
  end

  test "on_conflict: :nothing ignores duplicate" do
    {:ok, original} =
      Repo.insert(User.changeset(%User{}, %{name: "Alice", email: "a@b.com"}))

    {:ok, _} =
      Repo.insert(
        User.changeset(%User{}, %{name: "Alice2", email: "a@b.com"}),
        on_conflict: :nothing,
        conflict_target: [:email]
      )

    user = Repo.get(User, original.id)
    assert user.name == "Alice"
  end

  test "on_conflict: :replace_all replaces all fields" do
    {:ok, original} =
      Repo.insert(User.changeset(%User{}, %{name: "Bob", email: "b@b.com", age: 20}))

    {:ok, _} =
      Repo.insert(
        User.changeset(%User{}, %{name: "Bobby", email: "b@b.com", age: 30}),
        on_conflict: :replace_all,
        conflict_target: [:email]
      )

    user = Repo.get_by(User, email: "b@b.com")
    assert user.name == "Bobby"
    assert user.age == 30
  end

  test "on_conflict with specific fields replaces only those" do
    {:ok, original} =
      Repo.insert(User.changeset(%User{}, %{name: "Carol", email: "c@b.com", age: 25}))

    {:ok, _} =
      Repo.insert(
        User.changeset(%User{}, %{name: "Carolina", email: "c@b.com", age: 99}),
        on_conflict: {:replace, [:name]},
        conflict_target: [:email]
      )

    user = Repo.get(User, original.id)
    assert user.name == "Carolina"
    assert user.age == 25
  end

  test "on_conflict: :nothing with no conflict succeeds normally" do
    {:ok, user} =
      Repo.insert(
        User.changeset(%User{}, %{name: "Dave", email: "d@b.com"}),
        on_conflict: :nothing,
        conflict_target: [:email]
      )

    assert user.name == "Dave"
    assert Repo.get(User, user.id).email == "d@b.com"
  end

  test "insert_all with on_conflict: :nothing" do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    {:ok, _} = Repo.insert(User.changeset(%User{}, %{name: "Eve", email: "e@b.com"}))

    {count, nil} =
      Repo.insert_all(
        User,
        [
          %{name: "Eve2", email: "e@b.com", inserted_at: now, updated_at: now},
          %{name: "Fay", email: "f@b.com", inserted_at: now, updated_at: now}
        ],
        on_conflict: :nothing,
        conflict_target: [:email]
      )

    # SQLite returns the number of actually inserted rows (skipped = not counted)
    assert count == 1

    assert Repo.all(from u in User, select: u.name, order_by: u.name) == ["Eve", "Fay"]
  end
end
