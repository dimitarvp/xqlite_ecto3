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
          "1E308"
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
          "1E-320"
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
