defmodule XqliteEcto3.QueryFeaturesTest do
  use ExUnit.Case

  alias XqliteEcto3.TestRepo, as: Repo
  alias XqliteEcto3.Test.{User, Post}
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

    {:ok, u1} = Repo.insert(User.changeset(%User{}, %{name: "Alice", age: 30, email: "a@b.com"}))
    {:ok, u2} = Repo.insert(User.changeset(%User{}, %{name: "Bob", age: 25, email: "b@b.com"}))
    {:ok, u3} = Repo.insert(User.changeset(%User{}, %{name: "Carol", age: 35}))

    {:ok, _} = Repo.insert(Post.changeset(%Post{}, %{title: "Alice post", user_id: u1.id}))
    {:ok, _} = Repo.insert(Post.changeset(%Post{}, %{title: "Bob post 1", user_id: u2.id}))
    {:ok, _} = Repo.insert(Post.changeset(%Post{}, %{title: "Bob post 2", user_id: u2.id}))

    {:ok, alice: u1, bob: u2, carol: u3}
  end

  # ---------------------------------------------------------------------------
  # where variants
  # ---------------------------------------------------------------------------

  test "where with equality" do
    users = Repo.all(from u in User, where: u.name == "Alice")
    assert [%{name: "Alice"}] = users
  end

  test "where with inequality" do
    users = Repo.all(from u in User, where: u.name != "Alice", order_by: u.name)
    names = Enum.map(users, & &1.name)
    assert names == ["Bob", "Carol"]
  end

  test "where with in" do
    users = Repo.all(from u in User, where: u.name in ["Alice", "Carol"], order_by: u.name)
    names = Enum.map(users, & &1.name)
    assert names == ["Alice", "Carol"]
  end

  test "where with is_nil" do
    users = Repo.all(from u in User, where: is_nil(u.email))
    assert [%{name: "Carol"}] = users
  end

  test "where with not" do
    users = Repo.all(from u in User, where: not is_nil(u.email), order_by: u.name)
    names = Enum.map(users, & &1.name)
    assert names == ["Alice", "Bob"]
  end

  test "where with like" do
    users = Repo.all(from u in User, where: like(u.name, "A%"))
    assert [%{name: "Alice"}] = users
  end

  test "where with pinned variable" do
    name = "Bob"
    users = Repo.all(from u in User, where: u.name == ^name)
    assert [%{name: "Bob"}] = users
  end

  test "where with and composition" do
    users = Repo.all(from u in User, where: u.age > 20 and u.age < 35)
    assert [%{name: "Alice"}, %{name: "Bob"}] = Enum.sort_by(users, & &1.name)
  end

  test "where with or composition" do
    users = Repo.all(from u in User, where: u.age == 25 or u.age == 35, order_by: u.age)
    names = Enum.map(users, & &1.name)
    assert names == ["Bob", "Carol"]
  end

  # ---------------------------------------------------------------------------
  # order_by
  # ---------------------------------------------------------------------------

  test "order_by descending" do
    names = Repo.all(from u in User, select: u.name, order_by: [desc: u.name])
    assert names == ["Carol", "Bob", "Alice"]
  end

  test "order_by multiple fields" do
    names = Repo.all(from u in User, select: u.name, order_by: [asc: u.active, asc: u.name])
    assert length(names) == 3
  end

  # ---------------------------------------------------------------------------
  # offset and pagination
  # ---------------------------------------------------------------------------

  test "limit with offset" do
    names = Repo.all(from u in User, select: u.name, order_by: u.name, limit: 2, offset: 1)
    assert names == ["Bob", "Carol"]
  end

  test "offset without limit requires LIMIT in SQLite" do
    # SQLite requires LIMIT when OFFSET is used. Use a large limit as workaround.
    names = Repo.all(from u in User, select: u.name, order_by: u.name, limit: 999, offset: 2)
    assert names == ["Carol"]
  end

  # ---------------------------------------------------------------------------
  # select variations
  # ---------------------------------------------------------------------------

  test "select multiple fields as tuple" do
    results = Repo.all(from u in User, select: {u.name, u.age}, order_by: u.name)
    assert results == [{"Alice", 30}, {"Bob", 25}, {"Carol", 35}]
  end

  test "select with map syntax" do
    results = Repo.all(from u in User, select: %{n: u.name, a: u.age}, order_by: u.name)
    assert [%{n: "Alice", a: 30} | _] = results
  end

  test "select with expression" do
    results = Repo.all(from u in User, select: u.age + 1, order_by: u.age)
    assert results == [26, 31, 36]
  end

  # ---------------------------------------------------------------------------
  # distinct
  # ---------------------------------------------------------------------------

  test "distinct true" do
    ages = Repo.all(from u in User, select: u.active, distinct: true)
    assert length(ages) == 1
  end

  # ---------------------------------------------------------------------------
  # group_by and having
  # ---------------------------------------------------------------------------

  test "group_by with count" do
    results =
      Repo.all(
        from p in Post,
          group_by: p.user_id,
          select: {p.user_id, count(p.id)},
          order_by: [desc: count(p.id)]
      )

    [{bob_id, 2}, {alice_id, 1}] = results
    assert bob_id != nil
    assert alice_id != nil
  end

  test "having filters groups" do
    results =
      Repo.all(
        from p in Post,
          group_by: p.user_id,
          having: count(p.id) > 1,
          select: p.user_id
      )

    assert length(results) == 1
  end

  # ---------------------------------------------------------------------------
  # subqueries
  # ---------------------------------------------------------------------------

  test "subquery in where with in" do
    active_user_ids = from u in User, where: u.age > 28, select: u.id

    posts =
      Repo.all(from p in Post, where: p.user_id in subquery(active_user_ids), select: p.title)

    assert "Alice post" in posts
  end

  # ---------------------------------------------------------------------------
  # fragments
  # ---------------------------------------------------------------------------

  test "fragment in select" do
    results =
      Repo.all(
        from u in User,
          select: fragment("upper(?)", u.name),
          order_by: u.name
      )

    assert results == ["ALICE", "BOB", "CAROL"]
  end

  test "fragment in where" do
    users =
      Repo.all(
        from u in User,
          where: fragment("length(?)", u.name) > 4,
          select: u.name
      )

    assert "Alice" in users
    assert "Carol" in users
    refute "Bob" in users
  end

  # ---------------------------------------------------------------------------
  # exists?
  # ---------------------------------------------------------------------------

  test "Repo.exists? returns true when matching" do
    assert Repo.exists?(from u in User, where: u.name == "Alice")
  end

  test "Repo.exists? returns false when not matching" do
    refute Repo.exists?(from u in User, where: u.name == "Nobody")
  end

  # ---------------------------------------------------------------------------
  # Repo.one / Repo.one!
  # ---------------------------------------------------------------------------

  test "Repo.one returns single result" do
    user = Repo.one(from u in User, where: u.name == "Alice")
    assert user.name == "Alice"
  end

  test "Repo.one returns nil for no results" do
    assert Repo.one(from u in User, where: u.name == "Nobody") == nil
  end

  test "Repo.one! raises for no results" do
    assert_raise Ecto.NoResultsError, fn ->
      Repo.one!(from u in User, where: u.name == "Nobody")
    end
  end

  # ---------------------------------------------------------------------------
  # Repo.get!
  # ---------------------------------------------------------------------------

  test "Repo.get! raises for missing id" do
    assert_raise Ecto.NoResultsError, fn ->
      Repo.get!(User, 999_999)
    end
  end

  # ---------------------------------------------------------------------------
  # Empty result set
  # ---------------------------------------------------------------------------

  test "all on empty result returns empty list" do
    Repo.delete_all(Post)
    Repo.delete_all(User)

    assert Repo.all(User) == []
  end
end
