defmodule XqliteEcto3.MigrationHelpersTest do
  use ExUnit.Case, async: true

  alias XqliteEcto3.Migration

  doctest XqliteEcto3.Migration

  describe "enum_check/3 with string-backed values" do
    test "emits IN clause with quoted string values" do
      check = Migration.enum_check(:status, [:active, :archived])
      assert check.name == "status_enum_check"
      assert check.expr == "status IN ('active', 'archived')"
    end

    test "handles single-value enum" do
      check = Migration.enum_check(:role, [:admin])
      assert check.expr == "role IN ('admin')"
    end

    test "preserves declared order" do
      check = Migration.enum_check(:color, [:red, :green, :blue])
      assert check.expr == "color IN ('red', 'green', 'blue')"
    end

    test "allows custom :name option" do
      check = Migration.enum_check(:status, [:active], name: "custom_check")
      assert check.name == "custom_check"
      assert check.expr == "status IN ('active')"
    end
  end

  describe "enum_check/3 with integer-backed keyword values" do
    test "emits IN clause with integer values" do
      check = Migration.enum_check(:priority, low: 1, med: 2, high: 3)
      assert check.name == "priority_enum_check"
      assert check.expr == "priority IN (1, 2, 3)"
    end

    test "preserves declared order of values, not alphabetical" do
      check = Migration.enum_check(:priority, high: 3, low: 1, med: 2)
      assert check.expr == "priority IN (3, 1, 2)"
    end

    test "handles single-pair enum" do
      check = Migration.enum_check(:flag, only: 1)
      assert check.expr == "flag IN (1)"
    end

    test "allows custom :name option" do
      check = Migration.enum_check(:priority, [low: 1], name: "priority_enum_constraint")
      assert check.name == "priority_enum_constraint"
      assert check.expr == "priority IN (1)"
    end
  end

  describe "enum_check/3 argument validation" do
    test "refuses empty values list" do
      assert_raise FunctionClauseError, fn ->
        Migration.enum_check(:status, [])
      end
    end

    test "refuses non-atom column" do
      assert_raise FunctionClauseError, fn ->
        Migration.enum_check("status", [:active])
      end
    end
  end

  describe "integration with XqliteEcto3.Connection.execute_ddl/1" do
    test "shape fed into :check option generates a valid CREATE TABLE statement" do
      check = Migration.enum_check(:status, [:active, :archived])

      [ddl] =
        XqliteEcto3.Connection.execute_ddl(
          {:create, %Ecto.Migration.Table{name: "users"},
           [
             {:add, :id, :serial, [primary_key: true]},
             {:add, :status, :string, [check: check]}
           ]}
        )

      sql = IO.iodata_to_binary(ddl)

      assert sql =~
               ~s|"status" TEXT CONSTRAINT status_enum_check CHECK (status IN ('active', 'archived'))|
    end

    test "integer-backed shape feeds the :check option too" do
      check = Migration.enum_check(:priority, low: 1, med: 2, high: 3)

      [ddl] =
        XqliteEcto3.Connection.execute_ddl(
          {:create, %Ecto.Migration.Table{name: "tasks"},
           [
             {:add, :id, :serial, [primary_key: true]},
             {:add, :priority, :integer, [check: check]}
           ]}
        )

      sql = IO.iodata_to_binary(ddl)
      assert sql =~ "CHECK (priority IN (1, 2, 3))"
      assert sql =~ "CONSTRAINT priority_enum_check"
    end
  end
end
