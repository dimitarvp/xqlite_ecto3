defmodule XqliteEcto3.UpsertTest do
  use ExUnit.Case, async: true

  alias Ecto.Integration.TestRepo, as: Repo
  import Ecto.Query
  import XqliteEcto3.TableHelper

  defmodule UU do
    use Ecto.Schema
    import Ecto.Changeset

    schema "upsert_users" do
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
    create_table!(
      "upsert_users",
      user_columns(),
      ["CREATE UNIQUE INDEX IF NOT EXISTS upsert_users_email_index ON upsert_users(email)"]
    )
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Ecto.Integration.TestRepo)
    clear_table!("upsert_users")
  end

  test "on_conflict: :nothing ignores duplicate" do
    {:ok, original} =
      Repo.insert(UU.changeset(%UU{}, %{name: "Alice", email: "a@b.com"}))

    {:ok, _} =
      Repo.insert(
        UU.changeset(%UU{}, %{name: "Alice2", email: "a@b.com"}),
        on_conflict: :nothing,
        conflict_target: [:email]
      )

    user = Repo.get(UU, original.id)
    assert user.name == "Alice"
  end

  test "on_conflict: :replace_all replaces all fields" do
    {:ok, _original} =
      Repo.insert(UU.changeset(%UU{}, %{name: "Bob", email: "b@b.com", age: 20}))

    {:ok, _} =
      Repo.insert(
        UU.changeset(%UU{}, %{name: "Bobby", email: "b@b.com", age: 30}),
        on_conflict: :replace_all,
        conflict_target: [:email]
      )

    user = Repo.get_by(UU, email: "b@b.com")
    assert user.name == "Bobby"
    assert user.age == 30
  end

  test "on_conflict with specific fields replaces only those" do
    {:ok, original} =
      Repo.insert(UU.changeset(%UU{}, %{name: "Carol", email: "c@b.com", age: 25}))

    {:ok, _} =
      Repo.insert(
        UU.changeset(%UU{}, %{name: "Carolina", email: "c@b.com", age: 99}),
        on_conflict: {:replace, [:name]},
        conflict_target: [:email]
      )

    user = Repo.get(UU, original.id)
    assert user.name == "Carolina"
    assert user.age == 25
  end

  test "on_conflict: :nothing with no conflict succeeds normally" do
    {:ok, user} =
      Repo.insert(
        UU.changeset(%UU{}, %{name: "Dave", email: "d@b.com"}),
        on_conflict: :nothing,
        conflict_target: [:email]
      )

    assert user.name == "Dave"
    assert Repo.get(UU, user.id).email == "d@b.com"
  end

  test "insert_all with on_conflict: :nothing" do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    {:ok, _} = Repo.insert(UU.changeset(%UU{}, %{name: "Eve", email: "e@b.com"}))

    {count, nil} =
      Repo.insert_all(
        UU,
        [
          %{name: "Eve2", email: "e@b.com", inserted_at: now, updated_at: now},
          %{name: "Fay", email: "f@b.com", inserted_at: now, updated_at: now}
        ],
        on_conflict: :nothing,
        conflict_target: [:email]
      )

    assert count == 1

    assert Repo.all(from(u in UU, select: u.name, order_by: u.name)) == ["Eve", "Fay"]
  end
end
