defmodule XqliteEcto3.DataTypeTest do
  use ExUnit.Case, async: true

  alias XqliteEcto3.DataType

  describe "INTEGER family" do
    test ":id maps to INTEGER" do
      assert DataType.column_type(:id, []) == "INTEGER"
    end

    test ":serial maps to INTEGER" do
      assert DataType.column_type(:serial, []) == "INTEGER"
    end

    test ":bigserial maps to INTEGER" do
      assert DataType.column_type(:bigserial, []) == "INTEGER"
    end

    test ":boolean maps to INTEGER (SQLite stores bool as 0/1)" do
      assert DataType.column_type(:boolean, []) == "INTEGER"
    end

    test ":integer maps to INTEGER" do
      assert DataType.column_type(:integer, []) == "INTEGER"
    end

    test ":bigint maps to INTEGER (SQLite integers are 64-bit)" do
      assert DataType.column_type(:bigint, []) == "INTEGER"
    end
  end

  describe "TEXT family" do
    test ":string maps to TEXT" do
      assert DataType.column_type(:string, []) == "TEXT"
    end

    test ":date maps to TEXT (ISO 8601 storage)" do
      assert DataType.column_type(:date, []) == "TEXT"
    end

    test ":time maps to TEXT" do
      assert DataType.column_type(:time, []) == "TEXT"
    end

    test ":time_usec maps to TEXT" do
      assert DataType.column_type(:time_usec, []) == "TEXT"
    end

    test ":naive_datetime maps to TEXT" do
      assert DataType.column_type(:naive_datetime, []) == "TEXT"
    end

    test ":naive_datetime_usec maps to TEXT" do
      assert DataType.column_type(:naive_datetime_usec, []) == "TEXT"
    end

    test ":utc_datetime maps to TEXT" do
      assert DataType.column_type(:utc_datetime, []) == "TEXT"
    end

    test ":utc_datetime_usec maps to TEXT" do
      assert DataType.column_type(:utc_datetime_usec, []) == "TEXT"
    end

    test ":timestamp maps to TEXT" do
      assert DataType.column_type(:timestamp, []) == "TEXT"
    end

    test ":uuid maps to TEXT (stored as string, not raw bytes)" do
      assert DataType.column_type(:uuid, []) == "TEXT"
    end

    test ":binary_id maps to TEXT" do
      assert DataType.column_type(:binary_id, []) == "TEXT"
    end

    test ":map maps to TEXT (JSON storage)" do
      assert DataType.column_type(:map, []) == "TEXT"
    end

    test "{:map, _} maps to TEXT" do
      assert DataType.column_type({:map, :string}, []) == "TEXT"
    end

    test ":array maps to TEXT (JSON storage)" do
      assert DataType.column_type(:array, []) == "TEXT"
    end

    test "{:array, _} maps to TEXT" do
      assert DataType.column_type({:array, :integer}, []) == "TEXT"
    end
  end

  describe "BLOB and NUMERIC" do
    test ":binary maps to BLOB" do
      assert DataType.column_type(:binary, []) == "BLOB"
    end

    test ":float maps to NUMERIC (SQLite lacks a distinct FLOAT type)" do
      assert DataType.column_type(:float, []) == "NUMERIC"
    end
  end

  describe ":decimal" do
    test "bare :decimal (no opts) maps to DECIMAL" do
      assert DataType.column_type(:decimal, nil) == "DECIMAL"
    end

    test "empty opts maps to DECIMAL without precision" do
      assert DataType.column_type(:decimal, []) == "DECIMAL"
    end

    test "precision and scale both present" do
      assert DataType.column_type(:decimal, precision: 10, scale: 2) == "DECIMAL(10,2)"
    end

    test "precision without scale defaults scale to 0" do
      assert DataType.column_type(:decimal, precision: 10) == "DECIMAL(10,0)"
    end

    test "scale alone (no precision) produces bare DECIMAL" do
      assert DataType.column_type(:decimal, scale: 2) == "DECIMAL"
    end
  end

  describe "unknown atoms" do
    test "pass through upcased" do
      assert DataType.column_type(:custom_type, []) == "CUSTOM_TYPE"
    end

    test "multi-word and sized spellings pass through" do
      assert DataType.column_type(:"native character", []) == "NATIVE CHARACTER"
      assert DataType.column_type(:"varchar(255)", []) == "VARCHAR(255)"
      assert DataType.column_type(:"numeric(10,2)", []) == "NUMERIC(10,2)"
    end
  end

  describe "known text and blob spellings are aliased to their affinity" do
    test "text-carrying DB-specific spellings become TEXT" do
      for type <- [:json, :jsonb, :xml, :inet, :cidr, :macaddr, :tsvector] do
        assert DataType.column_type(type, []) == "TEXT"
      end
    end

    test ":bytea becomes BLOB" do
      assert DataType.column_type(:bytea, []) == "BLOB"
    end
  end

  describe "spellings outside SQLite's typename grammar are refused" do
    test "a spelling that would splice extra column definitions" do
      err =
        assert_raise XqliteEcto3.UnsupportedTypeError, fn ->
          DataType.column_type(:"text, oops INTEGER", [])
        end

      assert err.type == :"text, oops INTEGER"
    end

    test "quotes, semicolons, and empty spellings" do
      for type <- [:"text\"", :"text; DROP TABLE x", :""] do
        assert_raise XqliteEcto3.UnsupportedTypeError, fn ->
          DataType.column_type(type, [])
        end
      end
    end
  end

  describe "REAL-affinity spellings are rewritten to NUMERIC" do
    test "the named float family" do
      assert DataType.column_type(:real, []) == "NUMERIC"
      assert DataType.column_type(:double, []) == "NUMERIC"
      assert DataType.column_type(:double_precision, []) == "NUMERIC"
    end

    test "PostgreSQL float spellings that previously passed through" do
      assert DataType.column_type(:float8, []) == "NUMERIC"
      assert DataType.column_type(:float4, []) == "NUMERIC"
      assert DataType.column_type(:"double precision", []) == "NUMERIC"
    end

    test "any unrecognized spelling SQLite would give REAL affinity" do
      assert DataType.column_type(:floatish, []) == "NUMERIC"
      assert DataType.column_type(:big_real, []) == "NUMERIC"
    end

    test "spellings an earlier SQLite affinity rule claims pass through" do
      assert DataType.column_type(:smallint, []) == "SMALLINT"
      assert DataType.column_type(:varchar, []) == "VARCHAR"
    end
  end

  describe "unsupported types" do
    test "non-atom, non-tuple types raise UnsupportedTypeError carrying the offender" do
      err =
        assert_raise XqliteEcto3.UnsupportedTypeError, fn ->
          DataType.column_type(123, [])
        end

      assert err.type == 123
    end

    test "unknown tuple types raise UnsupportedTypeError carrying the offender" do
      err =
        assert_raise XqliteEcto3.UnsupportedTypeError, fn ->
          DataType.column_type({:unknown, :foo}, [])
        end

      assert err.type == {:unknown, :foo}
    end
  end
end
