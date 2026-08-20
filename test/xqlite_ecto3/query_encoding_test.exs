defmodule XqliteEcto3.QueryEncodingTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias XqliteEcto3.Query

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

  # A decimal binds as a number, never as text. SQLite compares by storage
  # class whenever the other operand has no column affinity to coerce with,
  # and every number sorts below every text, so a text bind answers those
  # comparisons by type instead of by value.
  describe "encode Decimal" do
    test "a value with a fractional part encodes as a float" do
      assert encode([Decimal.new("123.456")]) == [123.456]
    end

    test "preserves high-precision values" do
      assert encode([Decimal.new("0.00000000001")]) == [1.0e-11]
    end

    test "whole numbers encode as integers, not floats" do
      assert encode([Decimal.new("1.0e10")]) == [10_000_000_000]
    end

    test "a whole number past float64's exact range keeps every digit" do
      assert encode([Decimal.new("9223372036854775807")]) == [9_223_372_036_854_775_807]
    end

    test "large money within 15 significant digits still encodes" do
      assert encode([Decimal.new("9999999999999.99")]) == [9_999_999_999_999.99]
    end

    test "refuses a value beyond float64 precision instead of silently rounding" do
      dec = Decimal.new("12345678901234567890.12345")

      err =
        assert_raise XqliteEcto3.DecimalPrecisionError, fn ->
          encode([dec])
        end

      assert Decimal.equal?(err.value, dec)
    end

    # Whatever the guard accepts must bind as a number of the same value: an
    # integer or a float, never text, and never a different number.
    property "an accepted decimal binds as a numerically equal number" do
      check all(dec <- finite_decimal(), max_runs: 2000) do
        if XqliteEcto3.DecimalPrecision.representable?(dec) do
          [bound] = encode([dec])

          assert is_integer(bound) or is_float(bound)
          assert Decimal.equal?(dec, decimal_of(bound))
        else
          assert_raise XqliteEcto3.DecimalPrecisionError, fn -> encode([dec]) end
        end
      end
    end
  end

  defp decimal_of(bound) when is_integer(bound), do: Decimal.new(bound)

  # A bound float must equal the value SQLite STORES for it, and the storage
  # model is the guard's own: NUMERIC affinity demotes an integral float in
  # int64 range to an INTEGER with its exact digits. Decimal.from_float/1 is
  # the wrong lens here — it renders the shortest string that round-trips,
  # which can drop digits a demoted INTEGER keeps (a 17-digit integral float
  # prints as 16).
  defp decimal_of(bound) when is_float(bound),
    do: XqliteEcto3.DecimalPrecision.stored_decimal(bound)

  # sign * coefficient * 10^exponent, with the coefficient's digit count swept
  # across 1..25 so the stream straddles float64's ~15-17 significant-digit
  # exactness threshold in both directions.
  defp finite_decimal do
    gen all(
          sign <- StreamData.member_of([1, -1]),
          ndigits <- StreamData.integer(1..25),
          coefficient <-
            StreamData.integer(Integer.pow(10, ndigits - 1)..(Integer.pow(10, ndigits) - 1)),
          exponent <- StreamData.integer(-20..20)
        ) do
      Decimal.new(sign, coefficient, exponent)
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

  describe "unencodable parameters refuse with structure" do
    test "a struct without a JSON form raises with value, position, and cause" do
      err =
        assert_raise XqliteEcto3.UnencodableParameterError, fn ->
          encode([1, %Version{major: 1, minor: 2, patch: 3}])
        end

      assert %Version{} = err.value
      assert err.index == 2
      assert %Protocol.UndefinedError{} = err.reason
    end

    test "a map that JSON cannot represent raises with the failure attached" do
      err =
        assert_raise XqliteEcto3.UnencodableParameterError, fn ->
          encode([%{a: <<0xFF, 0xFE>>}])
        end

      assert err.index == 1
      assert %Jason.EncodeError{} = err.reason
    end

    test "a struct nested inside a plain map raises structured, not a protocol error" do
      err =
        assert_raise XqliteEcto3.UnencodableParameterError, fn ->
          encode([%{v: %Version{major: 1, minor: 0, patch: 0}}])
        end

      assert err.index == 1
      assert %Protocol.UndefinedError{} = err.reason
    end

    test "a plain map still encodes to JSON" do
      assert encode([%{a: 1}]) == [~s({"a":1})]
    end

    test "the decimal refusal carries its parameter position" do
      err =
        assert_raise XqliteEcto3.DecimalPrecisionError, fn ->
          encode([Decimal.new("1"), Decimal.new("0.12345678901234567")])
        end

      assert err.index == 2
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
