defmodule XqliteEcto3.DecimalPrecisionTest do
  use ExUnit.Case, async: true

  alias XqliteEcto3.DecimalPrecision

  # Values that survive a float64 round-trip and so store losslessly through
  # a NUMERIC-affinity column: typical money, small magnitudes, and large
  # float-exact integers.
  describe "representable?/1 accepts values that survive a float64 round-trip" do
    for str <- [
          "0",
          "0.1",
          "99.99",
          "-99.99",
          "12345.67",
          "100.00",
          "1.5",
          "19.99",
          "9999999999999.99",
          "0.000000000000000001",
          "1E-30",
          "3.141592653589793",
          "9007199254740992",
          "10000000000000000000",
          "1E308",
          "9007199254740993",
          "123456789012345678",
          "1234567890123456789",
          "9223372036854775807",
          "-9223372036854775808",
          "20700317912310409"
        ] do
      test "accepts #{str}" do
        assert DecimalPrecision.representable?(Decimal.new(unquote(str)))
      end
    end
  end

  # Values whose magnitude changes through float64 — the ones a NUMERIC column
  # would silently round. Includes out-of-range magnitudes and non-finite
  # decimals, which the guard must classify without raising.
  describe "representable?/1 refuses values that change through float64" do
    for str <- [
          "12345678901234567890",
          "12345678901234567890.12345",
          "-12345678901234567890.12345",
          "18446744073709551615",
          "0.12345678901234567",
          "1E400",
          "1E-320",
          "20700317912310410.0"
        ] do
      test "refuses #{str}" do
        refute DecimalPrecision.representable?(Decimal.new(unquote(str)))
      end
    end

    test "refuses non-finite decimals" do
      refute DecimalPrecision.representable?(Decimal.new("Inf"))
      refute DecimalPrecision.representable?(Decimal.new("-Inf"))
      refute DecimalPrecision.representable?(Decimal.new("NaN"))
    end
  end

  # A decimal whose rendered digits are a plain int64 integer binds as that
  # integer — no float64 in the path — which is why whole numbers past 2^53
  # are accepted. The same digits rendered with a decimal point are judged
  # by the float64 model instead.
  describe "bind_form/1 picks the exact numeric form" do
    for {str, expected} <- [
          {"123456789012345678", {:integer, 123_456_789_012_345_678}},
          {"9223372036854775807", {:integer, 9_223_372_036_854_775_807}},
          {"-9223372036854775808", {:integer, -9_223_372_036_854_775_808}},
          {"0", {:integer, 0}},
          {"19.99", {:float, 19.99}},
          {"1.0e10", {:integer, 10_000_000_000}}
        ] do
      test "#{str} binds as #{inspect(expected)}" do
        assert DecimalPrecision.bind_form(Decimal.new(unquote(str))) == unquote(expected)
      end
    end

    test "a value beyond float64's exact precision has no bind form" do
      assert DecimalPrecision.bind_form(Decimal.new("12345678901234567890.12345")) == :error
    end

    test "an int64 whole number stores as an exact INTEGER" do
      {:ok, conn} = Xqlite.open_in_memory()
      {:ok, _} = XqliteNIF.execute(conn, "CREATE TABLE t(d NUMERIC)", [])

      {:integer, int} = DecimalPrecision.bind_form(Decimal.new("123456789012345678"))
      {:ok, 1} = XqliteNIF.execute(conn, "INSERT INTO t(d) VALUES (?1)", [int])

      assert {:ok, %{rows: [["integer", 123_456_789_012_345_678]]}} =
               XqliteNIF.query(conn, "SELECT typeof(d), d FROM t", [])

      :ok = XqliteNIF.close(conn)
    end
  end

  describe "DecimalPrecisionError" do
    test "carries the offending decimal on the :value field" do
      dec = Decimal.new("12345678901234567890.12345")
      err = %XqliteEcto3.DecimalPrecisionError{value: dec}
      assert Decimal.equal?(err.value, dec)
    end

    test "renders a message" do
      err = %XqliteEcto3.DecimalPrecisionError{value: Decimal.new("12345678901234567890.12345")}
      assert is_binary(Exception.message(err))
    end
  end
end
