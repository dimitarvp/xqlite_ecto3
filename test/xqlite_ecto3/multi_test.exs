defmodule XqliteEcto3.MultiTest do
  use ExUnit.Case, async: true

  alias Ecto.Integration.TestRepo, as: Repo
  import Ecto.Query
  import XqliteEcto3.TableHelper

  defmodule MU do
    use Ecto.Schema
    import Ecto.Changeset

    schema "multi_users" do
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
    create_table!("multi_users", user_columns())
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Ecto.Integration.TestRepo)
    clear_table!("multi_users")
  end

  # ---------------------------------------------------------------------------
  # Basic Multi operations
  # ---------------------------------------------------------------------------

  test "Multi with multiple inserts commits all" do
    result =
      Ecto.Multi.new()
      |> Ecto.Multi.insert(:alice, MU.changeset(%MU{}, %{name: "Alice"}))
      |> Ecto.Multi.insert(:bob, MU.changeset(%MU{}, %{name: "Bob"}))
      |> Repo.transaction()

    assert {:ok, %{alice: alice, bob: bob}} = result
    assert alice.name == "Alice"
    assert bob.name == "Bob"
    names = Repo.all(from(u in MU, select: u.name, order_by: u.name))
    assert names == ["Alice", "Bob"]
  end

  test "Multi rolls back all on failure" do
    result =
      Ecto.Multi.new()
      |> Ecto.Multi.insert(:alice, MU.changeset(%MU{}, %{name: "Alice"}))
      |> Ecto.Multi.insert(:bad, MU.changeset(%MU{}, %{}))
      |> Repo.transaction()

    assert {:error, :bad, _changeset, _changes} = result
    assert Repo.all(MU) == []
  end

  # ---------------------------------------------------------------------------
  # Multi with update and delete
  # ---------------------------------------------------------------------------

  test "Multi insert then update" do
    result =
      Ecto.Multi.new()
      |> Ecto.Multi.insert(:user, MU.changeset(%MU{}, %{name: "Carol", age: 30}))
      |> Ecto.Multi.update(:updated, fn %{user: user} ->
        Ecto.Changeset.change(user, age: 31)
      end)
      |> Repo.transaction()

    assert {:ok, %{updated: updated}} = result
    assert updated.age == 31
    assert Repo.get(MU, updated.id).age == 31
  end

  test "Multi insert then delete" do
    result =
      Ecto.Multi.new()
      |> Ecto.Multi.insert(:user, MU.changeset(%MU{}, %{name: "Dave"}))
      |> Ecto.Multi.delete(:deleted, fn %{user: user} -> user end)
      |> Repo.transaction()

    assert {:ok, %{deleted: deleted}} = result
    assert Repo.get(MU, deleted.id) == nil
  end

  # ---------------------------------------------------------------------------
  # Multi with run
  # ---------------------------------------------------------------------------

  test "Multi.run executes custom function" do
    result =
      Ecto.Multi.new()
      |> Ecto.Multi.insert(:user, MU.changeset(%MU{}, %{name: "Eve"}))
      |> Ecto.Multi.run(:count, fn repo, _changes ->
        {:ok, repo.aggregate(MU, :count)}
      end)
      |> Repo.transaction()

    assert {:ok, %{count: 1}} = result
  end

  test "Multi.run failure rolls back" do
    result =
      Ecto.Multi.new()
      |> Ecto.Multi.insert(:user, MU.changeset(%MU{}, %{name: "Frank"}))
      |> Ecto.Multi.run(:fail, fn _repo, _changes ->
        {:error, :intentional}
      end)
      |> Repo.transaction()

    assert {:error, :fail, :intentional, _changes} = result
    assert Repo.all(MU) == []
  end

  # ---------------------------------------------------------------------------
  # Multi with update_all / delete_all / insert_all
  # ---------------------------------------------------------------------------

  test "Multi with update_all" do
    {:ok, _} = Repo.insert(MU.changeset(%MU{}, %{name: "Gina", age: 20}))
    {:ok, _} = Repo.insert(MU.changeset(%MU{}, %{name: "Hank", age: 30}))

    result =
      Ecto.Multi.new()
      |> Ecto.Multi.update_all(:bump, MU, inc: [age: 5])
      |> Repo.transaction()

    assert {:ok, %{bump: {2, nil}}} = result

    ages = Repo.all(from(u in MU, select: u.age, order_by: u.age))
    assert ages == [25, 35]
  end

  test "Multi with delete_all" do
    {:ok, _} = Repo.insert(MU.changeset(%MU{}, %{name: "Iris"}))
    {:ok, _} = Repo.insert(MU.changeset(%MU{}, %{name: "Jack"}))

    result =
      Ecto.Multi.new()
      |> Ecto.Multi.delete_all(:purge, MU)
      |> Repo.transaction()

    assert {:ok, %{purge: {2, nil}}} = result
    assert Repo.all(MU) == []
  end

  test "Multi with insert_all" do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    result =
      Ecto.Multi.new()
      |> Ecto.Multi.insert_all(:batch, MU, [
        %{name: "Kate", inserted_at: now, updated_at: now},
        %{name: "Leo", inserted_at: now, updated_at: now}
      ])
      |> Repo.transaction()

    assert {:ok, %{batch: {2, nil}}} = result
    names = Repo.all(from(u in MU, select: u.name, order_by: u.name))
    assert names == ["Kate", "Leo"]
  end

  # ---------------------------------------------------------------------------
  # Multi ordering
  # ---------------------------------------------------------------------------

  test "Multi operations execute in order" do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    result =
      Ecto.Multi.new()
      |> Ecto.Multi.insert_all(:seed, MU, [
        %{name: "Mia", age: 10, inserted_at: now, updated_at: now},
        %{name: "Ned", age: 20, inserted_at: now, updated_at: now}
      ])
      |> Ecto.Multi.update_all(:bump, MU, inc: [age: 100])
      |> Ecto.Multi.run(:verify, fn repo, _changes ->
        ages = repo.all(from(u in MU, select: u.age, order_by: u.age))
        {:ok, ages}
      end)
      |> Repo.transaction()

    assert {:ok, %{verify: [110, 120]}} = result
  end
end
