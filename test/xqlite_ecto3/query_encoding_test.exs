defmodule XqliteEcto3.QueryEncodingTest do
  use ExUnit.Case, async: true

  alias XqliteEcto3.Query

  # DBConnection.Query.encode/3 must produce a list of primitives that the
  # xqlite NIF can bind. Our implementation in Query module converts Ecto /
  # Elixir types to NIF-safe values. Tests verify every clause.

  defp encode(params), do: DBConnection.Query.encode(%Query{statement: "?"}, params, [])

  describe "encode booleans" do
    test "true encodes to 1" do
      assert encode([true]) == [1]
    end

    test "false encodes to 0" do
      assert encode([false]) == [0]
    end
  end

  describe "encode date/time types" do
    test "NaiveDateTime encodes to ISO 8601" do
      ndt = ~N[2024-06-15 14:30:45]
      assert encode([ndt]) == ["2024-06-15T14:30:45"]
    end

    test "NaiveDateTime with microseconds preserves them" do
      ndt = ~N[2024-06-15 14:30:45.123456]
      assert encode([ndt]) == ["2024-06-15T14:30:45.123456"]
    end

    test "DateTime encodes to ISO 8601 with timezone" do
      dt = ~U[2024-06-15 14:30:45Z]
      assert encode([dt]) == ["2024-06-15T14:30:45Z"]
    end

    test "Date encodes to ISO 8601" do
      assert encode([~D[2024-06-15]]) == ["2024-06-15"]
    end

    test "Time encodes to ISO 8601" do
      assert encode([~T[14:30:45]]) == ["14:30:45"]
    end
  end

  describe "encode Decimal" do
    test "encodes to canonical decimal string" do
      assert encode([Decimal.new("123.456")]) == ["123.456"]
    end

    test "preserves high-precision values" do
      assert encode([Decimal.new("0.00000000001")]) == ["0.00000000001"]
    end

    test "non-scientific notation via :normal" do
      assert encode([Decimal.new("1.0e10")]) == ["10000000000"]
    end
  end

  describe "encode map and list as JSON" do
    test "map encodes to JSON" do
      assert encode([%{"k" => "v", "n" => 1}]) == [~s|{"k":"v","n":1}|]
    end

    test "empty map encodes to {}" do
      assert encode([%{}]) == ["{}"]
    end

    test "list encodes to JSON array" do
      assert encode([[1, 2, 3]]) == ["[1,2,3]"]
    end

    test "empty list encodes to []" do
      assert encode([[]]) == ["[]"]
    end

    test "nested map encodes via Jason" do
      value = %{"outer" => %{"inner" => [1, "two", true]}}
      [encoded] = encode([value])
      assert Jason.decode!(encoded) == value
    end
  end

  describe "encode passes through primitives" do
    test "integer unchanged" do
      assert encode([42]) == [42]
    end

    test "float unchanged" do
      assert encode([3.14]) == [3.14]
    end

    test "binary string unchanged" do
      assert encode(["hello"]) == ["hello"]
    end

    test "nil unchanged" do
      assert encode([nil]) == [nil]
    end

    test "atom unchanged (will fail at NIF, but encoder doesn't block)" do
      # We intentionally do not filter atoms here — the NIF either accepts or
      # raises. The Query encode step is transport-only.
      assert encode([:foo]) == [:foo]
    end
  end

  describe "encode mixed params" do
    test "encodes each element independently" do
      params = [true, ~D[2024-01-01], "str", 42, %{"k" => "v"}]
      assert encode(params) == [1, "2024-01-01", "str", 42, ~s|{"k":"v"}|]
    end
  end

  describe "DBConnection.Query protocol contract" do
    test "parse/2 is identity" do
      q = %Query{statement: "SELECT 1"}
      assert DBConnection.Query.parse(q, []) == q
    end

    test "describe/2 is identity" do
      q = %Query{statement: "SELECT 1"}
      assert DBConnection.Query.describe(q, []) == q
    end

    test "decode/3 is identity" do
      q = %Query{statement: "SELECT 1"}
      result = %{columns: ["n"], rows: [[1]], num_rows: 1}
      assert DBConnection.Query.decode(q, result, []) == result
    end
  end

  describe "String.Chars protocol" do
    test "to_string returns the SQL statement" do
      q = %Query{statement: "SELECT 1"}
      assert to_string(q) == "SELECT 1"
    end

    test "flattens iodata statements" do
      q = %Query{statement: ["SELECT ", "1"]}
      assert to_string(q) == "SELECT 1"
    end
  end
end
