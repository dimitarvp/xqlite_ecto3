defmodule XqliteEcto3.AssociationsTest do
  use ExUnit.Case, async: true

  alias XqliteEcto3.TestRepo, as: Repo
  import Ecto.Query
  import XqliteEcto3.TableHelper

  defmodule AU do
    use Ecto.Schema
    import Ecto.Changeset

    schema "assoc_users" do
      field(:name, :string)
      field(:email, :string)
      field(:age, :integer)
      field(:active, :boolean, default: true)

      has_many(:posts, XqliteEcto3.AssociationsTest.AP, foreign_key: :user_id)

      timestamps()
    end

    def changeset(user, attrs \\ %{}),
      do: user |> cast(attrs, [:name, :email, :age, :active]) |> validate_required([:name])
  end

  defmodule AP do
    use Ecto.Schema
    import Ecto.Changeset

    schema "assoc_posts" do
      field(:title, :string)
      field(:body, :string)
      belongs_to(:user, XqliteEcto3.AssociationsTest.AU)

      timestamps()
    end

    def changeset(post, attrs \\ %{}),
      do: post |> cast(attrs, [:title, :body, :user_id]) |> validate_required([:title])
  end

  setup_all do
    create_table!("assoc_users", user_columns())
    create_table!("assoc_posts", post_columns("assoc_users"))
  end

  setup do
    clear_tables!(["assoc_posts", "assoc_users"])
  end

  # ---------------------------------------------------------------------------
  # belongs_to
  # ---------------------------------------------------------------------------

  test "belongs_to: preload user from post" do
    {:ok, user} = Repo.insert(AU.changeset(%AU{}, %{name: "Alice"}))
    {:ok, post} = Repo.insert(AP.changeset(%AP{}, %{title: "Hello", user_id: user.id}))

    loaded = Repo.get(AP, post.id) |> Repo.preload(:user)
    assert loaded.user.id == user.id
    assert loaded.user.name == "Alice"
  end

  test "belongs_to: preload nil when no user" do
    {:ok, post} = Repo.insert(AP.changeset(%AP{}, %{title: "Orphan"}))

    loaded = Repo.get(AP, post.id) |> Repo.preload(:user)
    assert loaded.user == nil
  end

  # ---------------------------------------------------------------------------
  # has_many
  # ---------------------------------------------------------------------------

  test "has_many: preload posts from user" do
    {:ok, user} = Repo.insert(AU.changeset(%AU{}, %{name: "Bob"}))
    {:ok, _} = Repo.insert(AP.changeset(%AP{}, %{title: "Post 1", user_id: user.id}))
    {:ok, _} = Repo.insert(AP.changeset(%AP{}, %{title: "Post 2", user_id: user.id}))

    loaded = Repo.get(AU, user.id) |> Repo.preload(:posts)
    titles = Enum.map(loaded.posts, & &1.title) |> Enum.sort()
    assert titles == ["Post 1", "Post 2"]
  end

  test "has_many: preload returns empty list when no posts" do
    {:ok, user} = Repo.insert(AU.changeset(%AU{}, %{name: "Carol"}))

    loaded = Repo.get(AU, user.id) |> Repo.preload(:posts)
    assert loaded.posts == []
  end

  # ---------------------------------------------------------------------------
  # Batched preload
  # ---------------------------------------------------------------------------

  test "preload on list of structs" do
    {:ok, u1} = Repo.insert(AU.changeset(%AU{}, %{name: "Dave"}))
    {:ok, u2} = Repo.insert(AU.changeset(%AU{}, %{name: "Eve"}))
    {:ok, _} = Repo.insert(AP.changeset(%AP{}, %{title: "Dave post", user_id: u1.id}))
    {:ok, _} = Repo.insert(AP.changeset(%AP{}, %{title: "Eve post 1", user_id: u2.id}))
    {:ok, _} = Repo.insert(AP.changeset(%AP{}, %{title: "Eve post 2", user_id: u2.id}))

    [dave, eve] = Repo.all(from(u in AU, order_by: u.name)) |> Repo.preload(:posts)

    assert [%{title: "Dave post"}] = dave.posts

    eve_titles = Enum.map(eve.posts, & &1.title) |> Enum.sort()
    assert eve_titles == ["Eve post 1", "Eve post 2"]
  end

  # ---------------------------------------------------------------------------
  # Preload with custom query
  # ---------------------------------------------------------------------------

  test "preload with custom query filters associated records" do
    {:ok, user} = Repo.insert(AU.changeset(%AU{}, %{name: "Frank"}))
    {:ok, _} = Repo.insert(AP.changeset(%AP{}, %{title: "AAA", user_id: user.id}))
    {:ok, _} = Repo.insert(AP.changeset(%AP{}, %{title: "BBB", user_id: user.id}))
    {:ok, _} = Repo.insert(AP.changeset(%AP{}, %{title: "CCC", user_id: user.id}))

    posts_query = from(p in AP, where: p.title > "B", order_by: p.title)
    loaded = Repo.get(AU, user.id) |> Repo.preload(posts: posts_query)

    titles = Enum.map(loaded.posts, & &1.title)
    assert titles == ["BBB", "CCC"]
  end

  # ---------------------------------------------------------------------------
  # Ecto.assoc
  # ---------------------------------------------------------------------------

  test "Ecto.assoc builds association query" do
    {:ok, user} = Repo.insert(AU.changeset(%AU{}, %{name: "Grace"}))
    {:ok, _} = Repo.insert(AP.changeset(%AP{}, %{title: "Grace post", user_id: user.id}))

    assert [%{title: "Grace post"}] = Repo.all(Ecto.assoc(user, :posts))
  end

  # ---------------------------------------------------------------------------
  # build_assoc
  # ---------------------------------------------------------------------------

  test "build_assoc sets foreign key" do
    {:ok, user} = Repo.insert(AU.changeset(%AU{}, %{name: "Hank"}))

    post = Ecto.build_assoc(user, :posts, title: "Built post")
    assert post.user_id == user.id
    assert post.title == "Built post"

    {:ok, saved} = Repo.insert(AP.changeset(post, %{}))
    assert saved.user_id == user.id
  end

  # ---------------------------------------------------------------------------
  # Join query
  # ---------------------------------------------------------------------------

  test "inner join returns matching records" do
    {:ok, user} = Repo.insert(AU.changeset(%AU{}, %{name: "Ivy"}))
    {:ok, _} = Repo.insert(AP.changeset(%AP{}, %{title: "Ivy post", user_id: user.id}))
    {:ok, _} = Repo.insert(AU.changeset(%AU{}, %{name: "NoPostUser"}))

    results =
      Repo.all(
        from(u in AU,
          join: p in AP,
          on: p.user_id == u.id,
          select: {u.name, p.title}
        )
      )

    assert results == [{"Ivy", "Ivy post"}]
  end

  test "left join includes users without posts" do
    {:ok, _} = Repo.insert(AU.changeset(%AU{}, %{name: "Jack"}))
    {:ok, user2} = Repo.insert(AU.changeset(%AU{}, %{name: "Kate"}))
    {:ok, _} = Repo.insert(AP.changeset(%AP{}, %{title: "Kate post", user_id: user2.id}))

    results =
      Repo.all(
        from(u in AU,
          left_join: p in AP,
          on: p.user_id == u.id,
          select: {u.name, p.title},
          order_by: u.name
        )
      )

    assert results == [{"Jack", nil}, {"Kate", "Kate post"}]
  end
end
