defmodule XqliteEcto3.ConstraintsTest do
  use XqliteEcto3.AdapterCase, async: true

  import Ecto.Changeset

  defmodule CU do
    use XqliteEcto3.TestSchemas.StandardUser, table: "constr_users"
  end

  defmodule CP do
    use Ecto.Schema

    import Ecto.Changeset

    schema "constr_posts" do
      field(:title, :string)
      field(:body, :string)
      belongs_to(:user, XqliteEcto3.ConstraintsTest.CU)
      timestamps()
    end

    def changeset(post, attrs \\ %{}),
      do: post |> cast(attrs, [:title, :body, :user_id]) |> validate_required([:title])
  end

  defmodule CC do
    use Ecto.Schema

    import Ecto.Changeset

    schema "constr_constrained" do
      field(:value, :integer)
      field(:label, :string)
    end

    def changeset(struct, attrs \\ %{}),
      do: struct |> cast(attrs, [:value, :label]) |> validate_required([:label])
  end

  setup_all do
    create_table!(
      "constr_users",
      user_columns(),
      ["CREATE UNIQUE INDEX IF NOT EXISTS constr_users_email_index ON constr_users(email)"]
    )

    create_table!("constr_posts", post_columns("constr_users"))

    create_table!(
      "constr_constrained",
      "id INTEGER PRIMARY KEY AUTOINCREMENT, value INTEGER CHECK(value > 0), label TEXT NOT NULL"
    )
  end

  setup do
    clear_tables!(["constr_posts", "constr_users", "constr_constrained"])
  end

  # ---------------------------------------------------------------------------
  # Unique constraint
  # ---------------------------------------------------------------------------

  test "unique_constraint on changeset catches duplicate email" do
    {:ok, _} = Repo.insert(CU.changeset(%CU{}, %{name: "Alice", email: "a@b.com"}))

    result =
      %CU{}
      |> CU.changeset(%{name: "Bob", email: "a@b.com"})
      |> unique_constraint(:email)
      |> Repo.insert()

    assert {:error, changeset} = result
    assert {msg, opts} = changeset.errors[:email]
    assert msg == "has already been taken"
    assert opts[:constraint] == :unique
  end

  test "unique_constraint with custom name option" do
    {:ok, _} = Repo.insert(CU.changeset(%CU{}, %{name: "Alice", email: "a@b.com"}))

    result =
      %CU{}
      |> CU.changeset(%{name: "Bob", email: "a@b.com"})
      |> unique_constraint(:email, name: "constr_users_email_index")
      |> Repo.insert()

    assert {:error, changeset} = result
    assert {msg, opts} = changeset.errors[:email]
    assert msg == "has already been taken"
    assert opts[:constraint] == :unique
    assert opts[:constraint_name] == "constr_users_email_index"
  end

  test "unique_constraint does not fire when value is unique" do
    result =
      %CU{}
      |> CU.changeset(%{name: "Alice", email: "unique@b.com"})
      |> unique_constraint(:email)
      |> Repo.insert()

    assert {:ok, _} = result
  end

  test "unique_constraint on update catches duplicate" do
    {:ok, _} = Repo.insert(CU.changeset(%CU{}, %{name: "Alice", email: "taken@b.com"}))
    {:ok, bob} = Repo.insert(CU.changeset(%CU{}, %{name: "Bob", email: "bob@b.com"}))

    result =
      bob
      |> CU.changeset(%{email: "taken@b.com"})
      |> unique_constraint(:email)
      |> Repo.update()

    assert {:error, changeset} = result
    assert {msg, opts} = changeset.errors[:email]
    assert msg == "has already been taken"
    assert opts[:constraint] == :unique
  end

  # ---------------------------------------------------------------------------
  # Foreign key constraint
  #
  # SQLite itself only says "FOREIGN KEY constraint failed" with no
  # table/column info. The TestRepo runs with rich_fk_diagnostics: true,
  # so the adapter replays the failure under deferred enforcement and
  # synthesizes the Ecto-convention constraint name —
  # foreign_key_constraint/3 matches like it does on PostgreSQL.
  # ---------------------------------------------------------------------------

  test "FK violation raises ConstraintError when the changeset declares no constraint" do
    error =
      assert_raise Ecto.ConstraintError, fn ->
        %CP{}
        |> CP.changeset(%{title: "Orphan", user_id: 999_999})
        |> Repo.insert()
      end

    assert error.type == :foreign_key
    assert error.constraint == "constr_posts_user_id_fkey"
  end

  test "FK violation converts to a changeset error via foreign_key_constraint/2" do
    result =
      %CP{}
      |> CP.changeset(%{title: "Orphan", user_id: 999_999})
      |> foreign_key_constraint(:user_id)
      |> Repo.insert()

    assert {:error, changeset} = result
    assert {msg, opts} = changeset.errors[:user_id]
    assert msg == "does not exist"
    assert opts[:constraint] == :foreign
    assert opts[:constraint_name] == "constr_posts_user_id_fkey"
  end

  test "FK allows valid reference" do
    {:ok, user} = Repo.insert(CU.changeset(%CU{}, %{name: "Owner"}))

    result =
      %CP{}
      |> CP.changeset(%{title: "Valid post", user_id: user.id})
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

  test "check_constraint on changeset catches violation" do
    result =
      %CC{}
      |> CC.changeset(%{value: -5, label: "negative"})
      |> check_constraint(:value, name: "value > 0")
      |> Repo.insert()

    assert {:error, changeset} = result
    assert {_msg, opts} = changeset.errors[:value]
    assert opts[:constraint] == :check
  end

  test "check_constraint allows valid values" do
    result =
      %CC{}
      |> CC.changeset(%{value: 10, label: "positive"})
      |> check_constraint(:value, name: "value > 0")
      |> Repo.insert()

    assert {:ok, _} = result
  end

  # ---------------------------------------------------------------------------
  # NOT NULL — surfaces the structured error; Ecto has nothing to match
  # ---------------------------------------------------------------------------

  test "NOT NULL violation raises the structured error with table and column" do
    error =
      assert_raise XqliteEcto3.Error, fn ->
        Repo.insert(%CU{name: nil})
      end

    assert %XqliteEcto3.Error.Constraint{
             subtype: :constraint_not_null,
             table: "constr_users",
             columns: ["name"]
           } = error.details
  end

  test "a detail-less virtual-table violation maps to no constraint, not a nil name" do
    Repo.query!("CREATE VIRTUAL TABLE cfts USING fts5(body)")
    Repo.query!("INSERT INTO cfts(rowid, body) VALUES (1, 'a')")

    error =
      assert_raise XqliteEcto3.Error, fn ->
        Repo.query!("INSERT INTO cfts(rowid, body) VALUES (1, 'b')")
      end

    assert error.details.subtype == :constraint_primary_key
    assert XqliteEcto3.Connection.to_constraints(error, []) == []
  end

  test "NOT NULL caught by changeset validate_required" do
    result =
      %CU{}
      |> CU.changeset(%{})
      |> Repo.insert()

    assert {:error, changeset} = result
    assert {msg, opts} = changeset.errors[:name]
    assert msg == "can't be blank"
    assert opts[:validation] == :required
  end

  describe "error statement field" do
    test "a failing statement is carried on the error" do
      sql = "INSERT INTO cs_no_such_table_anywhere VALUES (1)"

      assert {:error, %XqliteEcto3.Error{type: :no_such_table, statement: ^sql}} =
               Repo.query(sql)
    end
  end
end
