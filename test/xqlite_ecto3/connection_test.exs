defmodule XqliteEcto3.ConnectionTest do
  use ExUnit.Case, async: true

  alias XqliteEcto3.Connection, as: SQL

  defp to_sql(iodata), do: IO.iodata_to_binary(iodata)

  # ---------------------------------------------------------------------------
  # insert
  # ---------------------------------------------------------------------------

  test "insert single row" do
    result = SQL.insert(nil, "users", [:name, :age], [[:name, :age]], {:raise, [], []}, [], [])
    assert to_sql(result) == ~s|INSERT INTO "users" ("name","age") VALUES (?1,?2)|
  end

  test "insert with returning" do
    result = SQL.insert(nil, "users", [:name], [[:name]], {:raise, [], []}, [:id], [])
    assert to_sql(result) == ~s|INSERT INTO "users" ("name") VALUES (?1) RETURNING "id"|
  end

  test "insert default values" do
    result = SQL.insert(nil, "users", [], [[]], {:raise, [], []}, [], [])
    assert to_sql(result) == ~s|INSERT INTO "users" DEFAULT VALUES|
  end

  # ---------------------------------------------------------------------------
  # update
  # ---------------------------------------------------------------------------

  test "update with filters" do
    result = SQL.update(nil, "users", [:name], [{:id, 1}], [])
    assert to_sql(result) == ~s|UPDATE "users" SET "name" = ? WHERE "id" = ?|
  end

  test "update with returning" do
    result = SQL.update(nil, "users", [:name], [{:id, 1}], [:id, :name])

    assert to_sql(result) ==
             ~s|UPDATE "users" SET "name" = ? WHERE "id" = ? RETURNING "id","name"|
  end

  test "update with nil filter" do
    result = SQL.update(nil, "users", [:name], [{:archived_at, nil}], [])
    assert to_sql(result) == ~s|UPDATE "users" SET "name" = ? WHERE "archived_at" IS NULL|
  end

  # ---------------------------------------------------------------------------
  # delete
  # ---------------------------------------------------------------------------

  test "delete with filters" do
    result = SQL.delete(nil, "users", [{:id, 1}], [])
    assert to_sql(result) == ~s|DELETE FROM "users" WHERE "id" = ?|
  end

  test "delete with returning" do
    result = SQL.delete(nil, "users", [{:id, 1}], [:id])
    assert to_sql(result) == ~s|DELETE FROM "users" WHERE "id" = ? RETURNING "id"|
  end

  test "delete with nil filter" do
    result = SQL.delete(nil, "users", [{:deleted_at, nil}], [])
    assert to_sql(result) == ~s|DELETE FROM "users" WHERE "deleted_at" IS NULL|
  end

  # ---------------------------------------------------------------------------
  # table_exists_query
  # ---------------------------------------------------------------------------

  test "table_exists_query" do
    {sql, params} = SQL.table_exists_query("users")
    assert sql == "SELECT name FROM sqlite_master WHERE type='table' AND name=? LIMIT 1"
    assert params == ["users"]
  end

  # ---------------------------------------------------------------------------
  # to_constraints
  # ---------------------------------------------------------------------------

  test "to_constraints maps unique constraint from structured details" do
    error = %XqliteEcto3.Error{
      constraint_type: :constraint_unique,
      constraint_details: %{table: "users", columns: ["email"]}
    }

    assert SQL.to_constraints(error, []) == [unique: "users_email_index"]
  end

  test "to_constraints maps composite unique constraint" do
    error = %XqliteEcto3.Error{
      constraint_type: :constraint_unique,
      constraint_details: %{table: "users", columns: ["tenant_id", "email"]}
    }

    assert SQL.to_constraints(error, []) == [unique: "users_tenant_id_email_index"]
  end

  test "to_constraints maps foreign key constraint" do
    error = %XqliteEcto3.Error{
      constraint_type: :constraint_foreign_key,
      constraint_details: %{}
    }

    assert SQL.to_constraints(error, []) == [foreign_key: nil]
  end

  test "to_constraints maps check constraint" do
    error = %XqliteEcto3.Error{
      constraint_type: :constraint_check,
      constraint_details: %{constraint_name: "positive_balance"}
    }

    assert SQL.to_constraints(error, []) == [check: "positive_balance"]
  end

  test "to_constraints maps not null constraint" do
    error = %XqliteEcto3.Error{
      constraint_type: :constraint_not_null,
      constraint_details: %{table: "users", columns: ["name"]}
    }

    assert SQL.to_constraints(error, []) == [not_null: "users.name"]
  end

  test "to_constraints maps primary key as unique" do
    error = %XqliteEcto3.Error{
      constraint_type: :constraint_primary_key,
      constraint_details: %{table: "users", columns: ["id"]}
    }

    assert SQL.to_constraints(error, []) == [unique: "users_id_index"]
  end

  test "to_constraints maps named index unique constraint" do
    error = %XqliteEcto3.Error{
      constraint_type: :constraint_unique,
      constraint_details: %{index_name: "idx_users_email"}
    }

    assert SQL.to_constraints(error, []) == [unique: "idx_users_email"]
  end

  test "to_constraints returns empty for unknown errors" do
    assert SQL.to_constraints(%XqliteEcto3.Error{message: "something"}, []) == []
    assert SQL.to_constraints(%RuntimeError{message: "oops"}, []) == []
  end

  # ---------------------------------------------------------------------------
  # Error.wrap
  # ---------------------------------------------------------------------------

  test "Error.wrap preserves constraint_type, type and details" do
    details = %{message: "UNIQUE failed", table: "users", columns: ["email"]}
    error = XqliteEcto3.Error.wrap({:constraint_violation, :constraint_unique, details})
    assert error.type == :constraint_violation
    assert error.constraint_type == :constraint_unique
    assert error.message == "UNIQUE failed"
    assert error.constraint_details == details
  end

  test "Error.wrap preserves type for generic tuple errors" do
    error = XqliteEcto3.Error.wrap({:no_such_table, "no such table: foo"})
    assert error.type == :no_such_table
    assert error.message == "no such table: foo"
    assert error.constraint_type == nil
  end

  test "Error.wrap preserves type for atom errors" do
    error = XqliteEcto3.Error.wrap(:connection_closed)
    assert error.type == :connection_closed
    assert error.message == "connection_closed"
  end
end
