defmodule XqliteEcto3.ErrorPathsTest do
  use ExUnit.Case, async: true

  alias Ecto.Integration.TestRepo, as: Repo
  import Ecto.Query
  import XqliteEcto3.TableHelper

  defmodule EU do
    use Ecto.Schema
    import Ecto.Changeset

    schema "err_users" do
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
      "err_users",
      user_columns(),
      ["CREATE UNIQUE INDEX IF NOT EXISTS err_users_email_index ON err_users(email)"]
    )
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Ecto.Integration.TestRepo)
    clear_table!("err_users")
  end

  # ---------------------------------------------------------------------------
  # Invalid SQL
  # ---------------------------------------------------------------------------

  test "raw invalid SQL raises with structured type" do
    error =
      assert_raise XqliteEcto3.Error, fn ->
        Repo.all(from(u in "nonexistent_table_xyz", select: u.id))
      end

    assert error.type == :no_such_table
  end

  # ---------------------------------------------------------------------------
  # Changeset validation errors (not DB errors)
  # ---------------------------------------------------------------------------

  test "changeset validation failure returns error tuple" do
    result = Repo.insert(EU.changeset(%EU{}, %{}))
    assert {:error, changeset} = result
    assert changeset.valid? == false
    assert {msg, opts} = changeset.errors[:name]
    assert msg == "can't be blank"
    assert opts[:validation] == :required
  end

  # ---------------------------------------------------------------------------
  # Constraint violations
  # ---------------------------------------------------------------------------

  test "duplicate unique key without changeset constraint raises ConstraintError" do
    {:ok, _} = Repo.insert(EU.changeset(%EU{}, %{name: "Alice", email: "a@b.com"}))

    error =
      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert(EU.changeset(%EU{}, %{name: "Bob", email: "a@b.com"}))
      end

    assert error.type == :unique
  end

  test "NOT NULL violation without changeset constraint raises ConstraintError" do
    error =
      assert_raise Ecto.ConstraintError, fn ->
        Repo.insert(%EU{name: nil})
      end

    assert error.type == :not_null
  end

  # ---------------------------------------------------------------------------
  # Stale entry
  # ---------------------------------------------------------------------------

  test "update deleted record raises StaleEntryError" do
    {:ok, user} = Repo.insert(EU.changeset(%EU{}, %{name: "Carol"}))
    {:ok, _} = Repo.delete(user)

    assert_raise Ecto.StaleEntryError, fn ->
      Repo.update(Ecto.Changeset.change(user, name: "Ghost"))
    end
  end

  test "delete already-deleted record raises StaleEntryError" do
    {:ok, user} = Repo.insert(EU.changeset(%EU{}, %{name: "Dave"}))
    {:ok, _} = Repo.delete(user)

    assert_raise Ecto.StaleEntryError, fn ->
      Repo.delete(user)
    end
  end

  # ---------------------------------------------------------------------------
  # NoResultsError
  # ---------------------------------------------------------------------------

  test "get! with nonexistent id raises NoResultsError" do
    assert_raise Ecto.NoResultsError, fn ->
      Repo.get!(EU, 999_999)
    end
  end

  test "one! with no matching rows raises NoResultsError" do
    assert_raise Ecto.NoResultsError, fn ->
      Repo.one!(from(u in EU, where: u.name == "Nobody"))
    end
  end

  # ---------------------------------------------------------------------------
  # MultipleResultsError
  # ---------------------------------------------------------------------------

  test "one! with multiple rows raises MultipleResultsError" do
    {:ok, _} = Repo.insert(EU.changeset(%EU{}, %{name: "Eve"}))
    {:ok, _} = Repo.insert(EU.changeset(%EU{}, %{name: "Eve"}))

    assert_raise Ecto.MultipleResultsError, fn ->
      Repo.one!(from(u in EU, where: u.name == "Eve"))
    end
  end

  # ---------------------------------------------------------------------------
  # Transaction errors
  # ---------------------------------------------------------------------------

  test "transaction rollback returns error" do
    result =
      Repo.transaction(fn ->
        Repo.rollback(:oops)
      end)

    assert {:error, :oops} = result
  end

  test "transaction rollback undoes inserts" do
    Repo.transaction(fn ->
      {:ok, _} = Repo.insert(EU.changeset(%EU{}, %{name: "Rolled"}))
      Repo.rollback(:undo)
    end)

    assert Repo.all(from(u in EU, where: u.name == "Rolled")) == []
  end

  # ---------------------------------------------------------------------------
  # Invalid changeset operations
  # ---------------------------------------------------------------------------

  test "insert with invalid changeset returns error tuple" do
    changeset = EU.changeset(%EU{}, %{}) |> Ecto.Changeset.add_error(:name, "custom error")
    assert {:error, cs} = Repo.insert(changeset)
    assert {"custom error", []} = cs.errors[:name]
  end
end
