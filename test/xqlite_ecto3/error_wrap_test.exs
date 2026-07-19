defmodule XqliteEcto3.ErrorWrapTest do
  use ExUnit.Case, async: true

  alias XqliteEcto3.Error

  describe "wrap/1 on {:constraint_violation, subtype, details_map}" do
    test "builds a Constraint payload with subtype, type, and fields" do
      details = %{message: "UNIQUE failed", table: "users", columns: ["email"]}
      e = Error.wrap({:constraint_violation, :constraint_unique, details})
      assert e.type == :constraint_violation
      assert e.message == "UNIQUE failed"

      assert %Error.Constraint{
               subtype: :constraint_unique,
               message: "UNIQUE failed",
               table: "users",
               columns: ["email"],
               index_name: nil,
               constraint_name: nil
             } = e.details
    end

    test "carries source_type / target_type storage classes" do
      details = %{message: "DATATYPE", source_type: :text, target_type: :integer}
      e = Error.wrap({:constraint_violation, :constraint_datatype, details})

      assert %Error.Constraint{
               subtype: :constraint_datatype,
               source_type: :text,
               target_type: :integer
             } = e.details
    end

    test "handles every constraint subtype atom" do
      for subtype <- [
            :constraint_check,
            :constraint_commit_hook,
            :constraint_datatype,
            :constraint_foreign_key,
            :constraint_function,
            :constraint_not_null,
            :constraint_pinned,
            :constraint_primary_key,
            :constraint_rowid,
            :constraint_trigger,
            :constraint_unique,
            :constraint_vtab
          ] do
        e = Error.wrap({:constraint_violation, subtype, %{message: "m"}})
        assert e.type == :constraint_violation
        assert %Error.Constraint{subtype: ^subtype} = e.details
      end
    end

    test "empty details map still wraps cleanly" do
      e = Error.wrap({:constraint_violation, :constraint_foreign_key, %{}})
      assert e.type == :constraint_violation
      assert e.message == ""

      assert %Error.Constraint{
               subtype: :constraint_foreign_key,
               table: nil,
               columns: [],
               constraint_name: nil
             } = e.details
    end
  end

  describe "wrap/1 on {:sqlite_failure, code, ext_code, msg}" do
    test "adds 'SQLite failure:' prefix and preserves both result codes" do
      e = Error.wrap({:sqlite_failure, 1, 787, "cannot start a transaction within a transaction"})
      assert e.type == :sqlite_failure
      assert e.message == "SQLite failure: cannot start a transaction within a transaction"

      assert %Error.SqliteFailure{
               code: 1,
               extended_code: 787,
               message: "cannot start a transaction within a transaction"
             } = e.details
    end
  end

  describe "wrap/1 on {:sql_input_error, details_map}" do
    test "preserves code, message, sql, and offset" do
      input_err = %{
        message: "near \"SELCT\": syntax error",
        code: 1,
        sql: "SELCT 1",
        offset: 0
      }

      e = Error.wrap({:sql_input_error, input_err})
      assert e.type == :sql_input_error
      assert e.message == "near \"SELCT\": syntax error"

      assert %Error.Input{
               code: 1,
               message: "near \"SELCT\": syntax error",
               sql: "SELCT 1",
               offset: 0
             } = e.details
    end

    test "missing keys default to nil" do
      e = Error.wrap({:sql_input_error, %{message: "boom"}})
      assert %Error.Input{message: "boom", code: nil, sql: nil, offset: nil} = e.details
    end
  end

  describe "wrap/1 on generic {tag, msg}" do
    test "preserves tag as type with nil details" do
      e = Error.wrap({:no_such_table, "no such table: foo"})
      assert e.type == :no_such_table
      assert e.message == "no such table: foo"
      assert e.details == nil
    end

    test "works for any atom tag" do
      e = Error.wrap({:database_busy_or_locked, "database is locked"})
      assert e.type == :database_busy_or_locked
      assert e.message == "database is locked"
      assert e.details == nil
    end
  end

  describe "wrap/1 on code-carrying {tag, extended_code, msg}" do
    test "preserves tag as type and carries the extended code" do
      e = Error.wrap({:database_busy_or_locked, 5, "database is locked"})
      assert e.type == :database_busy_or_locked
      assert e.message == "database is locked"
      assert e.details == %{extended_code: 5}
    end

    test "handles every code-carrying tag" do
      for tag <- [
            :database_busy_or_locked,
            :read_only_database,
            :schema_changed,
            :authorization_denied
          ] do
        e = Error.wrap({tag, 8, "m"})
        assert e.type == tag
        assert e.details == %{extended_code: 8}
      end
    end
  end

  describe "wrap/1 on {:utf8_error, column, msg}" do
    test "preserves the type and carries the column" do
      e = Error.wrap({:utf8_error, 0, "invalid utf-8 sequence"})
      assert e.type == :utf8_error
      assert e.message == "invalid utf-8 sequence"
      assert e.details == %{column: 0}
    end
  end

  describe "wrap/1 on atom reason" do
    test "uses atom as both type and message" do
      e = Error.wrap(:connection_closed)
      assert e.type == :connection_closed
      assert e.message == "connection_closed"
      assert e.details == nil
    end

    test "handles :operation_cancelled" do
      e = Error.wrap(:operation_cancelled)
      assert e.type == :operation_cancelled
      assert e.message == "operation_cancelled"
    end
  end

  describe "wrap/1 catch-all" do
    test "inspects arbitrary reasons without crashing" do
      e = Error.wrap(%{some: "weird shape"})
      assert %XqliteEcto3.Error{} = e
      assert is_binary(e.message)
      assert e.type == nil
      assert e.details == nil
    end

    test "inspects raw tuples of unknown shape" do
      e = Error.wrap({:unexpected, 1, 2, 3, 4, 5})
      assert is_binary(e.message)
      assert e.type == nil
    end
  end

  describe "as exception" do
    test "raises as a proper Exception" do
      e = Error.wrap({:no_such_table, "no such table: foo"})

      assert_raise XqliteEcto3.Error, fn ->
        raise e
      end
    end

    test "Exception.message/1 returns the message field" do
      e = Error.wrap({:no_such_table, "no such table: foo"})
      assert Exception.message(e) == "no such table: foo"
    end
  end
end
