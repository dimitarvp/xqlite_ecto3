defmodule XqliteEcto3.ErrorWrapTest do
  use ExUnit.Case, async: true

  alias XqliteEcto3.Error

  describe "wrap/1 on {:constraint_violation, subtype, details_map}" do
    test "preserves subtype, type, message, and details" do
      details = %{message: "UNIQUE failed", table: "users", columns: ["email"]}
      e = Error.wrap({:constraint_violation, :constraint_unique, details})
      assert e.type == :constraint_violation
      assert e.constraint_type == :constraint_unique
      assert e.message == "UNIQUE failed"
      assert e.constraint_details == details
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
        assert e.constraint_type == subtype
        assert e.type == :constraint_violation
      end
    end

    test "empty details map still wraps cleanly" do
      e = Error.wrap({:constraint_violation, :constraint_foreign_key, %{}})
      assert e.type == :constraint_violation
      assert e.constraint_type == :constraint_foreign_key
      assert e.constraint_details == %{}
      assert e.message == ""
    end
  end

  describe "wrap/1 on {:sqlite_failure, code, ext_code, msg}" do
    test "adds 'SQLite failure:' prefix" do
      e = Error.wrap({:sqlite_failure, 1, 1, "cannot start a transaction within a transaction"})
      assert e.type == :sqlite_failure
      assert e.message == "SQLite failure: cannot start a transaction within a transaction"
    end
  end

  describe "wrap/1 on {:sql_input_error, %{message: msg}}" do
    test "extracts message from struct-like map" do
      input_err = %{message: "near \"SELCT\": syntax error", code: 1}
      e = Error.wrap({:sql_input_error, input_err})
      assert e.type == :sql_input_error
      assert e.message == "near \"SELCT\": syntax error"
    end
  end

  describe "wrap/1 on generic {tag, msg}" do
    test "preserves tag as type" do
      e = Error.wrap({:no_such_table, "no such table: foo"})
      assert e.type == :no_such_table
      assert e.message == "no such table: foo"
      assert e.constraint_type == nil
    end

    test "works for any atom tag" do
      e = Error.wrap({:database_busy_or_locked, "database is locked"})
      assert e.type == :database_busy_or_locked
      assert e.message == "database is locked"
    end
  end

  describe "wrap/1 on atom reason" do
    test "uses atom as both type and message" do
      e = Error.wrap(:connection_closed)
      assert e.type == :connection_closed
      assert e.message == "connection_closed"
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
      assert is_binary(e.message)
      assert e.message =~ "some"
      assert e.type == nil
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
