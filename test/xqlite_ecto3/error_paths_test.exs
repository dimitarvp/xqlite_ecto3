defmodule XqliteEcto3.ErrorPathsTest do
  use XqliteEcto3.AdapterCase, async: true

  defmodule EU do
    use XqliteEcto3.TestSchemas.StandardUser, table: "err_users"
  end

  setup_all do
    create_table!(
      "err_users",
      user_columns(),
      ["CREATE UNIQUE INDEX IF NOT EXISTS err_users_email_index ON err_users(email)"]
    )
  end

  setup do
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
    assert error.details == %{name: "nonexistent_table_xyz"}
    assert Exception.message(error) == "no such table: nonexistent_table_xyz"
  end

  test "a missing index names itself in the error and in the message" do
    error =
      assert_raise XqliteEcto3.Error, fn ->
        Repo.query!("DROP INDEX nonexistent_index_xyz")
      end

    assert error.type == :no_such_index
    assert error.details == %{name: "nonexistent_index_xyz"}
    assert Exception.message(error) == "no such index: nonexistent_index_xyz"
  end

  test "a table that is already there names itself in the error and in the message" do
    error =
      assert_raise XqliteEcto3.Error, fn ->
        Repo.query!("CREATE TABLE err_users (id INTEGER)")
      end

    assert error.type == :table_exists
    assert error.details == %{name: "err_users"}
    assert Exception.message(error) == "table err_users already exists"
  end

  test "an index that is already there names itself in the error and in the message" do
    error =
      assert_raise XqliteEcto3.Error, fn ->
        Repo.query!("CREATE INDEX err_users_email_index ON err_users(email)")
      end

    assert error.type == :index_exists
    assert error.details == %{name: "err_users_email_index"}
    assert Exception.message(error) == "index err_users_email_index already exists"
  end

  test "SQL with no statement is reported as such, not as API misuse" do
    assert {:error, %XqliteEcto3.Error{type: :no_statement}} = Repo.query("-- nothing to do\n")
    assert {:error, %XqliteEcto3.Error{type: :no_statement}} = Repo.query("   ")
  end

  # ---------------------------------------------------------------------------
  # Refused parameters
  # ---------------------------------------------------------------------------

  test "a parameter count mismatch reports both counts" do
    assert {:error, error} = Repo.query("SELECT ?1, ?2", [1])

    assert error.type == :invalid_parameter_count
    assert error.details == %{expected: 2, provided: 1}
  end

  test "an atom no storage class can hold names the atom" do
    assert {:error, error} = Repo.query("SELECT ?1", [{:a, :b}])

    assert error.type == :unsupported_atom
    assert error.details == %{token: "b"}
  end

  test "a parameter name the statement never declared names the name" do
    assert {:error, error} = Repo.query("SELECT :nope", [{:foo, 1}])

    assert error.type == :invalid_parameter_name
    assert error.details == %{token: ":foo"}
  end

  defmodule LimitRepo do
    use Ecto.Repo, otp_app: :xqlite_ecto3, adapter: XqliteEcto3
  end

  test "each parameter and length error carries its payload in details" do
    start_supervised!({LimitRepo, database: ":memory:", pool_size: 1})
    {:ok, 100} = XqliteEcto3.with_xqlite(LimitRepo, &Xqlite.put_limit(&1, :length, 100))
    names = Enum.map(1..2049, &{:"p#{&1}", &1})
    in_list = Enum.map_join(1..2049, ", ", &":p#{&1}")

    for {sql, params, type, details} <- [
          {"SELECT zeroblob(500)", [], :too_big, %{extended_code: 18}},
          {"SELECT ?", [String.duplicate("a", 200)], :value_too_large,
           %{byte_size: 200, limit: 100}},
          {"SELECT :a, :b", [a: 1], :missing_parameter, %{index: 2, name: ":b"}},
          {"SELECT :a", [a: 1, a: 2], :duplicate_parameter_name, %{token: ":a"}},
          {"SELECT 1 WHERE 1 IN (#{in_list})", names, :too_many_named_parameters,
           %{count: 2049, limit: 2048}},
          {"SELECT ?", [2 ** 64], :integer_out_of_range, %{position: 1}}
        ] do
      assert {:error, %XqliteEcto3.Error{type: ^type, details: ^details}} =
               LimitRepo.query(sql, params)
    end
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

  test "NOT NULL violation raises the structured error" do
    error =
      assert_raise XqliteEcto3.Error, fn ->
        Repo.insert(%EU{name: nil})
      end

    assert %XqliteEcto3.Error.Constraint{
             subtype: :constraint_not_null,
             table: "err_users",
             columns: ["name"]
           } = error.details
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
