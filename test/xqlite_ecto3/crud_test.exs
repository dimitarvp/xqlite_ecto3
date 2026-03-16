defmodule XqliteEcto3.CrudTest do
  use ExUnit.Case, async: true

  alias XqliteEcto3.TestRepo, as: Repo
  import Ecto.Query
  import XqliteEcto3.TableHelper

  defmodule U do
    use Ecto.Schema
    import Ecto.Changeset

    schema "crud_users" do
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
    create_table!("crud_users", user_columns())
  end

  setup do
    clear_table!("crud_users")
  end

  test "insert" do
    {:ok, user} = Repo.insert(U.changeset(%U{}, %{name: "Alice", email: "a@b.com", age: 30}))
    assert is_integer(user.id)
    assert user.name == "Alice"
    assert user.age == 30
    assert user.active == true
  end

  test "insert with defaults" do
    {:ok, user} = Repo.insert(U.changeset(%U{}, %{name: "Bob"}))
    assert user.active == true
    assert %NaiveDateTime{} = user.inserted_at
  end

  test "get by id" do
    {:ok, u} = Repo.insert(U.changeset(%U{}, %{name: "Carol", age: 25}))
    assert Repo.get(U, u.id).name == "Carol"
  end

  test "get returns nil for missing id" do
    assert Repo.get(U, 999_999) == nil
  end

  test "get! raises for missing id" do
    assert_raise Ecto.NoResultsError, fn -> Repo.get!(U, 999_999) end
  end

  test "get_by" do
    {:ok, _} = Repo.insert(U.changeset(%U{}, %{name: "Dave", email: "d@b.com"}))
    assert Repo.get_by(U, email: "d@b.com").name == "Dave"
  end

  test "one returns single result" do
    {:ok, _} = Repo.insert(U.changeset(%U{}, %{name: "Eve"}))
    assert Repo.one(from(u in U, where: u.name == "Eve")).name == "Eve"
  end

  test "one returns nil for no results" do
    assert Repo.one(from(u in U, where: u.name == "Nobody")) == nil
  end

  test "one! raises for no results" do
    assert_raise Ecto.NoResultsError, fn ->
      Repo.one!(from(u in U, where: u.name == "Nobody"))
    end
  end

  test "all" do
    for n <- ~w(A B C), do: {:ok, _} = Repo.insert(U.changeset(%U{}, %{name: n}))
    names = Repo.all(from(u in U, select: u.name, order_by: u.name))
    assert names == ["A", "B", "C"]
  end

  test "where + order_by + limit + offset" do
    for i <- 1..10,
        do:
          {:ok, _} =
            Repo.insert(
              U.changeset(%U{}, %{name: "U#{String.pad_leading("#{i}", 2, "0")}", age: i})
            )

    users = Repo.all(from(u in U, where: u.age > 3, order_by: u.name, limit: 3, offset: 1))
    names = Enum.map(users, & &1.name)
    assert names == ["U05", "U06", "U07"]
  end

  test "select expression" do
    {:ok, _} = Repo.insert(U.changeset(%U{}, %{name: "Ivy", age: 35}))
    assert Repo.all(from(u in U, select: u.age + 1)) == [36]
  end

  test "select tuple" do
    {:ok, _} = Repo.insert(U.changeset(%U{}, %{name: "Jay", age: 40}))
    assert Repo.all(from(u in U, select: {u.name, u.age})) == [{"Jay", 40}]
  end

  test "update" do
    {:ok, user} = Repo.insert(U.changeset(%U{}, %{name: "Kate", age: 50}))
    {:ok, updated} = Repo.update(Ecto.Changeset.change(user, age: 51))
    assert updated.age == 51
  end

  test "delete" do
    {:ok, user} = Repo.insert(U.changeset(%U{}, %{name: "Leo"}))
    {:ok, _} = Repo.delete(user)
    assert Repo.get(U, user.id) == nil
  end

  test "count" do
    for n <- ~w(A B C), do: {:ok, _} = Repo.insert(U.changeset(%U{}, %{name: n}))
    assert Repo.aggregate(U, :count) == 3
  end

  test "exists?" do
    {:ok, _} = Repo.insert(U.changeset(%U{}, %{name: "Exists"}))
    assert Repo.exists?(from(u in U, where: u.name == "Exists"))
    refute Repo.exists?(from(u in U, where: u.name == "Nope"))
  end

  test "transaction commit" do
    {:ok, user} =
      Repo.transaction(fn ->
        {:ok, u} = Repo.insert(U.changeset(%U{}, %{name: "Mia"}))
        u
      end)

    assert %U{name: "Mia"} = Repo.get(U, user.id)
  end

  test "transaction rollback" do
    Repo.transaction(fn ->
      {:ok, _} = Repo.insert(U.changeset(%U{}, %{name: "Nina"}))
      Repo.rollback(:oops)
    end)

    assert Repo.all(from(u in U, where: u.name == "Nina")) == []
  end

  test "nested transaction commits inner" do
    {:ok, _} =
      Repo.transaction(fn ->
        {:ok, _} = Repo.insert(U.changeset(%U{}, %{name: "Outer"}))

        {:ok, _} =
          Repo.transaction(fn ->
            {:ok, _} = Repo.insert(U.changeset(%U{}, %{name: "Inner"}))
          end)
      end)

    assert Repo.all(from(u in U, select: u.name, order_by: u.name)) == ["Inner", "Outer"]
  end

  test "nested rollback fails outer" do
    result =
      Repo.transaction(fn ->
        {:ok, _} = Repo.insert(U.changeset(%U{}, %{name: "Gone"}))
        Repo.transaction(fn -> Repo.rollback(:fail) end)
      end)

    assert {:error, :rollback} = result
    assert Repo.all(U) == []
  end
end
