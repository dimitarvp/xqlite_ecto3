defmodule XqliteEcto3.ConstraintsTest do
  use ExUnit.Case

  alias XqliteEcto3.TestRepo, as: Repo
  alias XqliteEcto3.Test.User
  import Ecto.Changeset

  setup do
    Repo.query!("DROP TABLE IF EXISTS posts")
    Repo.query!("DROP TABLE IF EXISTS users")
    Repo.query!("DROP TABLE IF EXISTS constrained")

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

    Repo.query!("""
    CREATE TABLE posts (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      title TEXT NOT NULL,
      body TEXT,
      user_id INTEGER REFERENCES users(id) ON DELETE RESTRICT,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """)

    Repo.query!("""
    CREATE TABLE constrained (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      value INTEGER CHECK(value > 0),
      label TEXT NOT NULL
    )
    """)

    :ok
  end

  # ---------------------------------------------------------------------------
  # Unique constraint
  # ---------------------------------------------------------------------------

  test "unique_constraint on changeset catches duplicate email" do
    {:ok, _} = Repo.insert(User.changeset(%User{}, %{name: "Alice", email: "a@b.com"}))

    result =
      %User{}
      |> User.changeset(%{name: "Bob", email: "a@b.com"})
      |> unique_constraint(:email)
      |> Repo.insert()

    assert {:error, changeset} = result
    assert changeset.errors[:email] != nil
    {msg, opts} = changeset.errors[:email]
    assert msg =~ "already been taken"
    assert opts[:constraint] == :unique
  end

  test "unique_constraint with custom name option" do
    {:ok, _} = Repo.insert(User.changeset(%User{}, %{name: "Alice", email: "a@b.com"}))

    result =
      %User{}
      |> User.changeset(%{name: "Bob", email: "a@b.com"})
      |> unique_constraint(:email, name: "users_email_index")
      |> Repo.insert()

    assert {:error, changeset} = result
    assert changeset.errors[:email] != nil
  end

  test "unique_constraint does not fire when value is unique" do
    result =
      %User{}
      |> User.changeset(%{name: "Alice", email: "unique@b.com"})
      |> unique_constraint(:email)
      |> Repo.insert()

    assert {:ok, _} = result
  end

  test "unique_constraint on update catches duplicate" do
    {:ok, _} = Repo.insert(User.changeset(%User{}, %{name: "Alice", email: "taken@b.com"}))
    {:ok, bob} = Repo.insert(User.changeset(%User{}, %{name: "Bob", email: "bob@b.com"}))

    result =
      bob
      |> User.changeset(%{email: "taken@b.com"})
      |> unique_constraint(:email)
      |> Repo.update()

    assert {:error, changeset} = result
    assert changeset.errors[:email] != nil
  end

  # ---------------------------------------------------------------------------
  # Foreign key constraint
  #
  # SQLite does not report which FK was violated — it only says
  # "FOREIGN KEY constraint failed" with no table/column info.
  # This means foreign_key_constraint/3 on changesets cannot match
  # by name. This is a known SQLite limitation shared with ecto_sqlite3.
  # ---------------------------------------------------------------------------

  test "FK violation raises ConstraintError without matching changeset constraint" do
    alias XqliteEcto3.Test.Post

    assert_raise Ecto.ConstraintError, ~r/foreign_key_constraint/, fn ->
      %Post{}
      |> Post.changeset(%{title: "Orphan", user_id: 999_999})
      |> Repo.insert()
    end
  end

  test "FK allows valid reference" do
    alias XqliteEcto3.Test.Post

    {:ok, user} = Repo.insert(User.changeset(%User{}, %{name: "Owner"}))

    result =
      %Post{}
      |> Post.changeset(%{title: "Valid post", user_id: user.id})
      |> Repo.insert()

    assert {:ok, post} = result
    assert post.user_id == user.id
  end

  # ---------------------------------------------------------------------------
  # Check constraint
  #
  # SQLite reports the check expression, not a named constraint.
  # The name in to_constraints is the expression text (e.g., "value > 0").
  # ---------------------------------------------------------------------------

  defmodule Constrained do
    use Ecto.Schema
    import Ecto.Changeset

    schema "constrained" do
      field :value, :integer
      field :label, :string
    end

    def changeset(struct, attrs) do
      struct
      |> cast(attrs, [:value, :label])
      |> validate_required([:label])
    end
  end

  test "check_constraint on changeset catches violation" do
    result =
      %Constrained{}
      |> Constrained.changeset(%{value: -5, label: "negative"})
      |> check_constraint(:value, name: "value > 0")
      |> Repo.insert()

    assert {:error, changeset} = result
    assert changeset.errors[:value] != nil
    {_msg, opts} = changeset.errors[:value]
    assert opts[:constraint] == :check
  end

  test "check_constraint allows valid values" do
    result =
      %Constrained{}
      |> Constrained.changeset(%{value: 10, label: "positive"})
      |> check_constraint(:value, name: "value > 0")
      |> Repo.insert()

    assert {:ok, _} = result
  end

  # ---------------------------------------------------------------------------
  # NOT NULL — raises ConstraintError without changeset constraint
  # ---------------------------------------------------------------------------

  test "NOT NULL violation raises ConstraintError" do
    assert_raise Ecto.ConstraintError, ~r/not_null_constraint/, fn ->
      Repo.insert(%User{name: nil})
    end
  end

  test "NOT NULL caught by changeset validate_required" do
    result =
      %User{}
      |> User.changeset(%{})
      |> Repo.insert()

    assert {:error, changeset} = result
    assert changeset.errors[:name] != nil
  end
end
