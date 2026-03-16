defmodule XqliteEcto3.CrudTest do
  use ExUnit.Case, async: true

  alias XqliteEcto3.TestRepo, as: Repo
  import Ecto.Query

  defmodule CrudUser do
    use Ecto.Schema
    import Ecto.Changeset

    @table_name "crud_users"
    schema @table_name do
      field :name, :string
      field :email, :string
      field :age, :integer
      field :active, :boolean, default: true
      timestamps()
    end

    def changeset(user, attrs) do
      user
      |> cast(attrs, [:name, :email, :age, :active])
      |> validate_required([:name])
    end
  end

  setup_all do
    Repo.query!("CREATE TABLE IF NOT EXISTS crud_users (id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, email TEXT, age INTEGER, active INTEGER DEFAULT 1, inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL)")
    :ok
  end

  setup do
    Repo.query!("DELETE FROM crud_users")
    :ok
  end

  test "insert a user" do
    {:ok, user} = Repo.insert(CrudUser.changeset(%CrudUser{}, %{name: "Alice", email: "alice@example.com", age: 30}))

    assert user.id != nil
    assert user.name == "Alice"
    assert user.email == "alice@example.com"
    assert user.age == 30
    assert user.active == true
  end

  test "insert with defaults" do
    {:ok, user} = Repo.insert(CrudUser.changeset(%CrudUser{}, %{name: "Bob"}))

    assert user.active == true
    assert user.inserted_at != nil
    assert user.updated_at != nil
  end

  test "get by id" do
    {:ok, inserted} = Repo.insert(CrudUser.changeset(%CrudUser{}, %{name: "Carol", age: 25}))

    fetched = Repo.get(CrudUser, inserted.id)
    assert fetched.name == "Carol"
    assert fetched.age == 25
  end

  test "get returns nil for missing id" do
    assert Repo.get(CrudUser, 999_999) == nil
  end

  test "get_by field" do
    {:ok, _} = Repo.insert(CrudUser.changeset(%CrudUser{}, %{name: "Dave", email: "dave@example.com"}))

    found = Repo.get_by(CrudUser, email: "dave@example.com")
    assert found.name == "Dave"
  end

  test "all returns all rows" do
    {:ok, _} = Repo.insert(CrudUser.changeset(%CrudUser{}, %{name: "Eve"}))
    {:ok, _} = Repo.insert(CrudUser.changeset(%CrudUser{}, %{name: "Frank"}))

    assert length(Repo.all(CrudUser)) == 2
  end

  test "query with where clause" do
    {:ok, _} = Repo.insert(CrudUser.changeset(%CrudUser{}, %{name: "Grace", age: 40}))
    {:ok, _} = Repo.insert(CrudUser.changeset(%CrudUser{}, %{name: "Hank", age: 20}))

    older = Repo.all(from u in CrudUser, where: u.age > 30)
    assert length(older) == 1
    assert hd(older).name == "Grace"
  end

  test "query with order_by" do
    {:ok, _} = Repo.insert(CrudUser.changeset(%CrudUser{}, %{name: "Zara"}))
    {:ok, _} = Repo.insert(CrudUser.changeset(%CrudUser{}, %{name: "Amy"}))

    names = Repo.all(from u in CrudUser, select: u.name, order_by: u.name)
    assert names == ["Amy", "Zara"]
  end

  test "query with limit" do
    for i <- 1..10, do: {:ok, _} = Repo.insert(CrudUser.changeset(%CrudUser{}, %{name: "User #{i}"}))

    assert length(Repo.all(from u in CrudUser, limit: 3)) == 3
  end

  test "query with select" do
    {:ok, _} = Repo.insert(CrudUser.changeset(%CrudUser{}, %{name: "Ivy", age: 35}))

    assert Repo.all(from u in CrudUser, select: u.name) == ["Ivy"]
  end

  test "update a user" do
    {:ok, user} = Repo.insert(CrudUser.changeset(%CrudUser{}, %{name: "Jack", age: 50}))

    {:ok, updated} = Repo.update(Ecto.Changeset.change(user, age: 51))
    assert updated.age == 51
    assert updated.id == user.id
  end

  test "update only changed fields" do
    {:ok, user} = Repo.insert(CrudUser.changeset(%CrudUser{}, %{name: "Kate", email: "kate@old.com", age: 28}))

    {:ok, updated} = Repo.update(Ecto.Changeset.change(user, email: "kate@new.com"))
    assert updated.email == "kate@new.com"
    assert updated.name == "Kate"
    assert updated.age == 28
  end

  test "delete a user" do
    {:ok, user} = Repo.insert(CrudUser.changeset(%CrudUser{}, %{name: "Leo"}))

    {:ok, deleted} = Repo.delete(user)
    assert deleted.id == user.id
    assert Repo.get(CrudUser, user.id) == nil
  end

  test "count" do
    for n <- ["A", "B", "C"], do: {:ok, _} = Repo.insert(CrudUser.changeset(%CrudUser{}, %{name: n}))

    assert Repo.aggregate(CrudUser, :count) == 3
  end

  test "transaction commit" do
    {:ok, user} =
      Repo.transaction(fn ->
        {:ok, user} = Repo.insert(CrudUser.changeset(%CrudUser{}, %{name: "Mia"}))
        user
      end)

    assert user.name == "Mia"
    assert Repo.get(CrudUser, user.id) != nil
  end

  test "transaction rollback" do
    Repo.transaction(fn ->
      {:ok, _} = Repo.insert(CrudUser.changeset(%CrudUser{}, %{name: "Nina"}))
      Repo.rollback(:oops)
    end)

    assert Repo.all(from u in CrudUser, where: u.name == "Nina") == []
  end

  test "nested transaction commits inner" do
    {:ok, _} =
      Repo.transaction(fn ->
        {:ok, _} = Repo.insert(CrudUser.changeset(%CrudUser{}, %{name: "Outer"}))
        {:ok, _} = Repo.transaction(fn ->
          {:ok, _} = Repo.insert(CrudUser.changeset(%CrudUser{}, %{name: "Inner"}))
        end)
      end)

    names = Repo.all(from u in CrudUser, select: u.name, order_by: u.name)
    assert names == ["Inner", "Outer"]
  end

  test "nested transaction inner rollback fails outer" do
    result =
      Repo.transaction(fn ->
        {:ok, _} = Repo.insert(CrudUser.changeset(%CrudUser{}, %{name: "Gone"}))
        Repo.transaction(fn ->
          {:ok, _} = Repo.insert(CrudUser.changeset(%CrudUser{}, %{name: "Also gone"}))
          Repo.rollback(:inner_fail)
        end)
      end)

    assert {:error, :rollback} = result
    assert Repo.all(from u in CrudUser, select: u.name) == []
  end
end
