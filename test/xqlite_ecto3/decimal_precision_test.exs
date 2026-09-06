defmodule XqliteEcto3.DecimalPrecisionTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias XqliteEcto3.DecimalPrecision
  alias XqliteEcto3.DecimalPrecisionError

  @int64_min -9_223_372_036_854_775_808
  @int64_max 9_223_372_036_854_775_807

  # Wide enough that only a bind walking the coefficient digit by digit
  # can miss it.
  @bind_budget_ms 1_000

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
    test "a 17-digit integral decimal with a fraction dot binds as a float that stores exactly" do
      d = Decimal.new("18271353451913432.0")

      assert {:float, f} = DecimalPrecision.bind_form(d)

      {:ok, conn} = Xqlite.open_in_memory()
      {:ok, _} = XqliteNIF.query(conn, "CREATE TABLE bf (v NUMERIC)", [])
      {:ok, _} = XqliteNIF.query(conn, "INSERT INTO bf VALUES (?1)", [f])

      assert {:ok, %{rows: [["integer", 18_271_353_451_913_432]]}} =
               XqliteNIF.query(conn, "SELECT typeof(v), v FROM bf", [])

      assert Decimal.equal?(d, DecimalPrecision.stored_decimal(f))
    end

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

  # A Decimal is three words wide however many digits it stands for, so its
  # written-out form can be gigabytes: 1E+7000 is 7001 characters, and an
  # exponent of a billion is a billion. The guard has to answer from the
  # struct, because building that text is neither possible nor needed.
  describe "bind_form/1 answers without writing the value out" do
    test "an exponent too wide to write out is refused, not rendered" do
      assert DecimalPrecision.bind_form(Decimal.new(1, 1, 7000)) == :error
      assert DecimalPrecision.bind_form(Decimal.new(1, 1, -7000)) == :error
      assert DecimalPrecision.bind_form(Decimal.new(1, 1, 1_000_000_000)) == :error
      assert DecimalPrecision.bind_form(Decimal.new(1, 1, -1_000_000_000)) == :error
    end

    test "a coefficient of trailing zeros binds as the small number it stands for" do
      assert DecimalPrecision.bind_form(Decimal.new(1, Integer.pow(10, 7000), -6999)) ==
               {:float, 10.0}
    end

    # A zero coefficient is decided before the exponent cutoff can refuse
    # it; exponent 18 is the last power of ten inside int64.
    test "the exponent cutoff and the zero coefficient meet at their edges" do
      assert DecimalPrecision.bind_form(Decimal.new(1, 0, 25)) == {:integer, 0}

      assert DecimalPrecision.bind_form(Decimal.new("1E+18")) ==
               {:integer, 1_000_000_000_000_000_000}

      assert DecimalPrecision.bind_form(Decimal.new("1E+19")) == {:float, 1.0e19}
    end

    test "a zero binds whatever its exponent" do
      assert DecimalPrecision.bind_form(Decimal.new(1, 0, -100_000)) == {:float, 0.0}
      assert DecimalPrecision.bind_form(Decimal.new(1, 0, -1_000_000_000)) == {:float, 0.0}
      assert DecimalPrecision.bind_form(Decimal.new("0.000")) == {:float, 0.0}
      assert DecimalPrecision.bind_form(Decimal.new("0E+3")) == {:integer, 0}
      assert DecimalPrecision.bind_form(Decimal.new("-0")) == {:integer, 0}
    end

    property "every finite decimal gets an integer form, a float form, or a refusal that reads" do
      check all(dec <- wide_decimal(), max_runs: 2000) do
        oracle = int64_oracle(dec)

        # The converse of the arms below: they read the oracle from a
        # form, this reads the form from the oracle.
        assert integer_arm?(oracle, DecimalPrecision.bind_form(dec))

        case DecimalPrecision.bind_form(dec) do
          {:integer, int} ->
            assert oracle == {:ok, int}

          {:float, float} ->
            assert oracle == :error

            assert Decimal.equal?(
                     Decimal.normalize(dec),
                     Decimal.normalize(DecimalPrecision.stored_decimal(float))
                   )

          :error ->
            assert oracle == :error
            err = %DecimalPrecisionError{value: dec, index: 1}
            assert is_binary(DecimalPrecisionError.message(err))
        end
      end
    end

    # Padding a coefficient with trailing zeros changes nothing about the
    # value, and the time is the harder half: stripping them a group at a
    # time costs more than the digit count grows.
    property "trailing zeros change neither the bind form nor the time it takes" do
      check all(
              sign <- StreamData.member_of([1, -1]),
              coefficient <- StreamData.integer(1..999_999),
              exponent <- StreamData.integer(-30..-1),
              zeros <- StreamData.integer(0..100_000),
              max_runs: 2000
            ) do
        bare = Decimal.new(sign, coefficient, exponent)
        padded = Decimal.new(sign, coefficient * Integer.pow(10, zeros), exponent - zeros)

        {elapsed_us, form} = :timer.tc(fn -> DecimalPrecision.bind_form(padded) end)

        assert form == DecimalPrecision.bind_form(bare)
        assert elapsed_us < @bind_budget_ms * 1_000
      end
    end

    test "half a million trailing zeros still bind inside the budget" do
      padded = Decimal.new(1, 3 * Integer.pow(10, 500_000), -499_999)

      {elapsed_us, form} = :timer.tc(fn -> DecimalPrecision.bind_form(padded) end)

      assert form == {:float, 30.0}
      assert elapsed_us < @bind_budget_ms * 1_000
    end
  end

  defp integer_arm?({:ok, int}, form), do: form == {:integer, int}
  defp integer_arm?(:error, _form), do: true

  # The judge the integer arm must agree with: the value's own written-out
  # form, with the print limit lifted so even the widest case renders.
  defp int64_oracle(dec) do
    dec
    |> Decimal.to_string(:normal, max_digits: :infinity)
    |> Integer.parse()
    |> case do
      {int, ""} when int >= @int64_min and int <= @int64_max -> {:ok, int}
      _fractional_or_out_of_range -> :error
    end
  end

  # sign * coefficient * 10^exponent, the coefficient up to 300 digits and the
  # exponent landing on the interesting edges as often as anywhere else:
  # float64's range, int64's width, and Decimal's own parse and print limits.
  defp wide_decimal do
    gen all(
          sign <- StreamData.member_of([1, -1]),
          ndigits <- StreamData.integer(1..300),
          coefficient <-
            StreamData.integer(Integer.pow(10, ndigits - 1)..(Integer.pow(10, ndigits) - 1)),
          exponent <-
            StreamData.one_of([
              StreamData.integer(-10_000..10_000),
              StreamData.member_of([
                -6178,
                -6177,
                -6144,
                -324,
                -308,
                -1,
                0,
                18,
                19,
                308,
                309,
                6144,
                6145,
                6177,
                6178
              ])
            ])
        ) do
      Decimal.new(sign, coefficient, exponent)
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

    # Called through Exception.message/1 a raising message/1 comes back as
    # Elixir's "got ArgumentError ... while retrieving" text, which is a
    # binary too — so the refused value's own message has to be asked for
    # directly to see whether it renders at all.
    test "renders a message for a value too wide to write out" do
      err = %DecimalPrecisionError{value: Decimal.new(1, 1, 7000), index: 1}
      assert is_binary(DecimalPrecisionError.message(err))

      wider = %DecimalPrecisionError{value: Decimal.new(1, 1, 1_000_000_000), index: 1}
      assert is_binary(DecimalPrecisionError.message(wider))
    end
  end
end
