defmodule XqliteEcto3.QueryFeaturesTest do
  use ExUnit.Case, async: true

  alias Ecto.Integration.TestRepo, as: Repo
  import Ecto.Query
  import XqliteEcto3.TableHelper

  defmodule QU do
    use Ecto.Schema
    import Ecto.Changeset

    schema "qf_users" do
      field(:name, :string)
      field(:email, :string)
      field(:age, :integer)
      field(:active, :boolean, default: true)
      timestamps()
    end

    def changeset(user, attrs \\ %{}),
      do: user |> cast(attrs, [:name, :email, :age, :active]) |> validate_required([:name])
  end

  defmodule QP do
    use Ecto.Schema
    import Ecto.Changeset

    schema "qf_posts" do
      field(:title, :string)
      field(:body, :string)
      belongs_to(:user, XqliteEcto3.QueryFeaturesTest.QU)
      timestamps()
    end

    def changeset(post, attrs \\ %{}),
      do: post |> cast(attrs, [:title, :body, :user_id]) |> validate_required([:title])
  end

  setup_all do
    create_table!("qf_users", user_columns())
    create_table!("qf_posts", post_columns("qf_users"))
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Ecto.Integration.TestRepo)
    clear_tables!(["qf_posts", "qf_users"])

    {:ok, u1} = Repo.insert(QU.changeset(%QU{}, %{name: "Alice", age: 30, email: "a@b.com"}))
    {:ok, u2} = Repo.insert(QU.changeset(%QU{}, %{name: "Bob", age: 25, email: "b@b.com"}))
    {:ok, u3} = Repo.insert(QU.changeset(%QU{}, %{name: "Carol", age: 35}))

    {:ok, _} = Repo.insert(QP.changeset(%QP{}, %{title: "Alice post", user_id: u1.id}))
    {:ok, _} = Repo.insert(QP.changeset(%QP{}, %{title: "Bob post 1", user_id: u2.id}))
    {:ok, _} = Repo.insert(QP.changeset(%QP{}, %{title: "Bob post 2", user_id: u2.id}))

    {:ok, alice: u1, bob: u2, carol: u3}
  end

  # ---------------------------------------------------------------------------
  # where variants
  # ---------------------------------------------------------------------------

  test "where with equality" do
    users = Repo.all(from(u in QU, where: u.name == "Alice"))
    assert [%{name: "Alice"}] = users
  end

  test "where with inequality" do
    users = Repo.all(from(u in QU, where: u.name != "Alice", order_by: u.name))
    names = Enum.map(users, & &1.name)
    assert names == ["Bob", "Carol"]
  end

  test "where with in" do
    users = Repo.all(from(u in QU, where: u.name in ["Alice", "Carol"], order_by: u.name))
    names = Enum.map(users, & &1.name)
    assert names == ["Alice", "Carol"]
  end

  test "where with is_nil" do
    users = Repo.all(from(u in QU, where: is_nil(u.email)))
    assert [%{name: "Carol"}] = users
  end

  test "where with not" do
    users = Repo.all(from(u in QU, where: not is_nil(u.email), order_by: u.name))
    names = Enum.map(users, & &1.name)
    assert names == ["Alice", "Bob"]
  end

  test "where with like" do
    users = Repo.all(from(u in QU, where: like(u.name, "A%")))
    assert [%{name: "Alice"}] = users
  end

  test "where with pinned variable" do
    name = "Bob"
    users = Repo.all(from(u in QU, where: u.name == ^name))
    assert [%{name: "Bob"}] = users
  end

  test "where with and composition" do
    users = Repo.all(from(u in QU, where: u.age > 20 and u.age < 35))
    assert [%{name: "Alice"}, %{name: "Bob"}] = Enum.sort_by(users, & &1.name)
  end

  test "where with or composition" do
    users = Repo.all(from(u in QU, where: u.age == 25 or u.age == 35, order_by: u.age))
    names = Enum.map(users, & &1.name)
    assert names == ["Bob", "Carol"]
  end

  # ---------------------------------------------------------------------------
  # order_by
  # ---------------------------------------------------------------------------

  test "order_by descending" do
    names = Repo.all(from(u in QU, select: u.name, order_by: [desc: u.name]))
    assert names == ["Carol", "Bob", "Alice"]
  end

  test "order_by multiple fields" do
    names = Repo.all(from(u in QU, select: u.name, order_by: [asc: u.active, asc: u.name]))
    assert names == ["Alice", "Bob", "Carol"]
  end

  # ---------------------------------------------------------------------------
  # offset and pagination
  # ---------------------------------------------------------------------------

  test "limit with offset" do
    names = Repo.all(from(u in QU, select: u.name, order_by: u.name, limit: 2, offset: 1))
    assert names == ["Bob", "Carol"]
  end

  test "offset without limit requires LIMIT in SQLite" do
    names = Repo.all(from(u in QU, select: u.name, order_by: u.name, limit: 999, offset: 2))
    assert names == ["Carol"]
  end

  # ---------------------------------------------------------------------------
  # select variations
  # ---------------------------------------------------------------------------

  test "select multiple fields as tuple" do
    results = Repo.all(from(u in QU, select: {u.name, u.age}, order_by: u.name))
    assert results == [{"Alice", 30}, {"Bob", 25}, {"Carol", 35}]
  end

  test "select with map syntax" do
    results = Repo.all(from(u in QU, select: %{n: u.name, a: u.age}, order_by: u.name))
    assert results == [%{n: "Alice", a: 30}, %{n: "Bob", a: 25}, %{n: "Carol", a: 35}]
  end

  test "select with expression" do
    results = Repo.all(from(u in QU, select: u.age + 1, order_by: u.age))
    assert results == [26, 31, 36]
  end

  # ---------------------------------------------------------------------------
  # distinct
  # ---------------------------------------------------------------------------

  test "distinct true" do
    active_values = Repo.all(from(u in QU, select: u.active, distinct: true))
    assert active_values == [true]
  end

  # ---------------------------------------------------------------------------
  # group_by and having
  # ---------------------------------------------------------------------------

  test "group_by with count" do
    results =
      Repo.all(
        from(p in QP,
          group_by: p.user_id,
          select: {p.user_id, count(p.id)},
          order_by: [desc: count(p.id)]
        )
      )

    [{bob_id, 2}, {alice_id, 1}] = results
    assert is_integer(bob_id)
    assert is_integer(alice_id)
  end

  test "having filters groups" do
    results =
      Repo.all(
        from(p in QP,
          group_by: p.user_id,
          having: count(p.id) > 1,
          select: p.user_id
        )
      )

    assert [_bob_id] = results
  end

  # ---------------------------------------------------------------------------
  # subqueries
  # ---------------------------------------------------------------------------

  test "subquery in where with in" do
    active_user_ids = from(u in QU, where: u.age > 28, select: u.id)

    posts =
      Repo.all(from(p in QP, where: p.user_id in subquery(active_user_ids), select: p.title))

    assert "Alice post" in posts
  end

  # ---------------------------------------------------------------------------
  # fragments
  # ---------------------------------------------------------------------------

  test "fragment in select" do
    results =
      Repo.all(
        from(u in QU,
          select: fragment("upper(?)", u.name),
          order_by: u.name
        )
      )

    assert results == ["ALICE", "BOB", "CAROL"]
  end

  test "fragment in where" do
    users =
      Repo.all(
        from(u in QU,
          where: fragment("length(?)", u.name) > 4,
          select: u.name
        )
      )

    assert "Alice" in users
    assert "Carol" in users
    refute "Bob" in users
  end

  # ---------------------------------------------------------------------------
  # exists?
  # ---------------------------------------------------------------------------

  test "Repo.exists? returns true when matching" do
    assert Repo.exists?(from(u in QU, where: u.name == "Alice"))
  end

  test "Repo.exists? returns false when not matching" do
    refute Repo.exists?(from(u in QU, where: u.name == "Nobody"))
  end

  # ---------------------------------------------------------------------------
  # Repo.one / Repo.one!
  # ---------------------------------------------------------------------------

  test "Repo.one returns single result" do
    user = Repo.one(from(u in QU, where: u.name == "Alice"))
    assert user.name == "Alice"
  end

  test "Repo.one returns nil for no results" do
    assert Repo.one(from(u in QU, where: u.name == "Nobody")) == nil
  end

  test "Repo.one! raises for no results" do
    assert_raise Ecto.NoResultsError, fn ->
      Repo.one!(from(u in QU, where: u.name == "Nobody"))
    end
  end

  # ---------------------------------------------------------------------------
  # Repo.get!
  # ---------------------------------------------------------------------------

  test "Repo.get! raises for missing id" do
    assert_raise Ecto.NoResultsError, fn ->
      Repo.get!(QU, 999_999)
    end
  end

  # ---------------------------------------------------------------------------
  # Empty result set
  # ---------------------------------------------------------------------------

  test "all on empty result returns empty list" do
    Repo.delete_all(QP)
    Repo.delete_all(QU)

    assert Repo.all(QU) == []
  end
end
