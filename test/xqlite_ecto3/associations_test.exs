defmodule XqliteEcto3.AssociationsTest do
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

    :ok
  end

  # ---------------------------------------------------------------------------
  # belongs_to
  # ---------------------------------------------------------------------------

  test "belongs_to: preload user from post" do
    {:ok, user} = Repo.insert(User.changeset(%User{}, %{name: "Alice"}))
    {:ok, post} = Repo.insert(Post.changeset(%Post{}, %{title: "Hello", user_id: user.id}))

    loaded = Repo.get(Post, post.id) |> Repo.preload(:user)
    assert loaded.user.id == user.id
    assert loaded.user.name == "Alice"
  end

  test "belongs_to: preload nil when no user" do
    {:ok, post} = Repo.insert(Post.changeset(%Post{}, %{title: "Orphan"}))

    loaded = Repo.get(Post, post.id) |> Repo.preload(:user)
    assert loaded.user == nil
  end

  # ---------------------------------------------------------------------------
  # has_many
  # ---------------------------------------------------------------------------

  test "has_many: preload posts from user" do
    {:ok, user} = Repo.insert(User.changeset(%User{}, %{name: "Bob"}))
    {:ok, _} = Repo.insert(Post.changeset(%Post{}, %{title: "Post 1", user_id: user.id}))
    {:ok, _} = Repo.insert(Post.changeset(%Post{}, %{title: "Post 2", user_id: user.id}))

    loaded = Repo.get(User, user.id) |> Repo.preload(:posts)
    assert length(loaded.posts) == 2
    titles = Enum.map(loaded.posts, & &1.title) |> Enum.sort()
    assert titles == ["Post 1", "Post 2"]
  end

  test "has_many: preload returns empty list when no posts" do
    {:ok, user} = Repo.insert(User.changeset(%User{}, %{name: "Carol"}))

    loaded = Repo.get(User, user.id) |> Repo.preload(:posts)
    assert loaded.posts == []
  end

  # ---------------------------------------------------------------------------
  # Batched preload
  # ---------------------------------------------------------------------------

  test "preload on list of structs" do
    {:ok, u1} = Repo.insert(User.changeset(%User{}, %{name: "Dave"}))
    {:ok, u2} = Repo.insert(User.changeset(%User{}, %{name: "Eve"}))
    {:ok, _} = Repo.insert(Post.changeset(%Post{}, %{title: "Dave post", user_id: u1.id}))
    {:ok, _} = Repo.insert(Post.changeset(%Post{}, %{title: "Eve post 1", user_id: u2.id}))
    {:ok, _} = Repo.insert(Post.changeset(%Post{}, %{title: "Eve post 2", user_id: u2.id}))

    users = Repo.all(from u in User, order_by: u.name) |> Repo.preload(:posts)

    assert length(users) == 2
    [dave, eve] = users
    assert length(dave.posts) == 1
    assert length(eve.posts) == 2
  end

  # ---------------------------------------------------------------------------
  # Preload with custom query
  # ---------------------------------------------------------------------------

  test "preload with custom query filters associated records" do
    {:ok, user} = Repo.insert(User.changeset(%User{}, %{name: "Frank"}))
    {:ok, _} = Repo.insert(Post.changeset(%Post{}, %{title: "AAA", user_id: user.id}))
    {:ok, _} = Repo.insert(Post.changeset(%Post{}, %{title: "BBB", user_id: user.id}))
    {:ok, _} = Repo.insert(Post.changeset(%Post{}, %{title: "CCC", user_id: user.id}))

    posts_query = from p in Post, where: p.title > "B", order_by: p.title
    loaded = Repo.get(User, user.id) |> Repo.preload(posts: posts_query)

    titles = Enum.map(loaded.posts, & &1.title)
    assert titles == ["BBB", "CCC"]
  end

  # ---------------------------------------------------------------------------
  # Ecto.assoc
  # ---------------------------------------------------------------------------

  test "Ecto.assoc builds association query" do
    {:ok, user} = Repo.insert(User.changeset(%User{}, %{name: "Grace"}))
    {:ok, _} = Repo.insert(Post.changeset(%Post{}, %{title: "Grace post", user_id: user.id}))

    posts = Repo.all(Ecto.assoc(user, :posts))
    assert length(posts) == 1
    assert hd(posts).title == "Grace post"
  end

  # ---------------------------------------------------------------------------
  # build_assoc
  # ---------------------------------------------------------------------------

  test "build_assoc sets foreign key" do
    {:ok, user} = Repo.insert(User.changeset(%User{}, %{name: "Hank"}))

    post = Ecto.build_assoc(user, :posts, title: "Built post")
    assert post.user_id == user.id
    assert post.title == "Built post"

    {:ok, saved} = Repo.insert(Post.changeset(post, %{}))
    assert saved.user_id == user.id
  end

  # ---------------------------------------------------------------------------
  # Join query
  # ---------------------------------------------------------------------------

  test "inner join returns matching records" do
    {:ok, user} = Repo.insert(User.changeset(%User{}, %{name: "Ivy"}))
    {:ok, _} = Repo.insert(Post.changeset(%Post{}, %{title: "Ivy post", user_id: user.id}))
    {:ok, _} = Repo.insert(User.changeset(%User{}, %{name: "NoPostUser"}))

    results =
      Repo.all(
        from u in User,
          join: p in Post,
          on: p.user_id == u.id,
          select: {u.name, p.title}
      )

    assert results == [{"Ivy", "Ivy post"}]
  end

  test "left join includes users without posts" do
    {:ok, _} = Repo.insert(User.changeset(%User{}, %{name: "Jack"}))
    {:ok, user2} = Repo.insert(User.changeset(%User{}, %{name: "Kate"}))
    {:ok, _} = Repo.insert(Post.changeset(%Post{}, %{title: "Kate post", user_id: user2.id}))

    results =
      Repo.all(
        from u in User,
          left_join: p in Post,
          on: p.user_id == u.id,
          select: {u.name, p.title},
          order_by: u.name
      )

    assert results == [{"Jack", nil}, {"Kate", "Kate post"}]
  end
end
