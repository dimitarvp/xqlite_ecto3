defmodule XqliteEcto3.DecimalPrecision do
  @moduledoc false

  # SQLite has no exact-decimal storage class: a `:decimal` column carries
  # NUMERIC affinity, which holds a value one of two ways — an integer that
  # fits in int64 stays an exact INTEGER (no float64 anywhere in the path);
  # everything else is a float64 (REAL). Keeping numeric storage is
  # deliberate — ordering and range queries depend on it — but a value that
  # does not survive its storage path would come back quietly changed.
  # `bind_form/1` answers both questions at once: whether a decimal
  # survives, and which of the two numeric forms is the exact one to bind.
  # `representable?/1` is the yes/no view of the same answer, so the binding
  # boundary can refuse the values that would not survive instead of writing
  # a silently-wrong number.

  # float64 (IEEE-754 double) finite magnitude bounds. Outside them a value
  # has no clean float64 form — these value-equal the limits `Decimal.to_float/1`
  # itself enforces, so the pre-check refuses out-of-range values rather than
  # letting the conversion raise.
  @dbl_max Decimal.new("1.7976931348623158E308")
  @dbl_min Decimal.new("2.2250738585072014E-308")

  @int64_min -9_223_372_036_854_775_808
  @int64_max 9_223_372_036_854_775_807

  @doc """
  Whether a `Decimal` survives storage under NUMERIC affinity unchanged.

  The yes/no view of `bind_form/1`: true for every value that has an exact
  numeric form to bind, false for the values whose stored form would differ
  from the original. This accepts typical money and anything exact within
  ~15 significant digits (including large float-exact integers).
  """
  @spec representable?(Decimal.t()) :: boolean()
  def representable?(%Decimal{} = d), do: bind_form(d) != :error

  @doc """
  The numeric term to bind for a `Decimal`, or `:error` when no form of it
  survives storage.

  Binding a number rather than its text matters beyond storage: SQLite
  compares by storage class whenever an operand carries no column affinity
  to coerce the other side with (an aggregate, an arithmetic expression, a
  `coalesce`), and every number sorts below every text — so a decimal bound
  as text answers those comparisons by type instead of by value.

  Two forms are exact. A value whose rendered digits are a plain integer
  inside int64 range binds as that integer: NUMERIC affinity keeps it as an
  exact INTEGER, with no float64 anywhere in the path, so it round-trips
  digit-for-digit past float64's 53-bit limit. Everything else binds as a
  float64, which is exact only when the value survives the round-trip
  modelled below.

  The integer check keys on the RENDERED form, not the mathematical value:
  the same digits written "…0.0" render with a decimal point, so the
  float64 model stays the judge for them.

  One value loses information here and cannot be kept: a negative zero
  binds as the integer 0, and an INTEGER has no negative zero, so it
  loads back positive. Binding it as the float -0.0 instead would keep
  the sign at the price of moving that single value to a different
  storage class, which ordering and range queries would then see.
  """
  @spec bind_form(Decimal.t()) :: {:integer, integer()} | {:float, float()} | :error
  def bind_form(%Decimal{} = d) do
    cond do
      Decimal.nan?(d) -> :error
      Decimal.inf?(d) -> :error
      true -> finite_bind_form(d)
    end
  end

  defp finite_bind_form(d) do
    case int64_literal(d) do
      {:ok, int} -> {:integer, int}
      :error -> float_bind_form(d)
    end
  end

  # Zero sits below the smallest float64 magnitude, so it is decided before
  # the range check that would otherwise refuse it, and it answers with the
  # literal: `Decimal.to_float/1` builds 10^-exp before it looks at the
  # coefficient, a billion-digit number for a value that is 0.0.
  defp float_bind_form(d) do
    if Decimal.equal?(d, 0) do
      {:float, 0.0}
    else
      narrowed_bind_form(d)
    end
  end

  defp narrowed_bind_form(d) do
    case drop_trailing_zeros(d) do
      {:ok, narrowed} -> in_range_bind_form(narrowed)
      :error -> :error
    end
  end

  defp in_range_bind_form(d) do
    if out_of_float_range?(d) do
      :error
    else
      exact_float(d)
    end
  end

  # Whether the value's written-out form is a plain integer inside int64,
  # decided from the struct: that form carries a decimal point exactly when
  # the exponent is negative, and writing it out to find out would build 7001
  # characters for `1E+7000` and a billion for an exponent of a billion. From
  # exponent 19 up, a non-zero coefficient already stands for 10^19 or more,
  # past int64's 9.22E18, so the power of ten is never built.
  defp int64_literal(%Decimal{sign: sign, coef: coef, exp: exp}) do
    cond do
      exp < 0 -> :error
      coef == 0 -> {:ok, 0}
      exp >= 19 -> :error
      true -> int64_or_error(sign * coef * Integer.pow(10, exp))
    end
  end

  defp int64_or_error(int) when int >= @int64_min and int <= @int64_max, do: {:ok, int}
  defp int64_or_error(_out_of_range), do: :error

  defp out_of_float_range?(d) do
    abs = Decimal.abs(d)
    Decimal.gt?(abs, @dbl_max) or Decimal.lt?(abs, @dbl_min)
  end

  # A float64 reads back with at most 19 significant digits — 17 from the
  # shortest printing that round-trips, 19 from an integral value SQLite
  # demotes to INTEGER — so a coefficient wider than that once its
  # trailing zeros are gone has nothing exact to equal, and is refused
  # before the rest of the path reads it. Those zeros go in one division:
  # `Decimal.normalize/1` walks them sixteen at a time, a third of a
  # second for 100_000 of them.
  @exact_digits 19

  defp drop_trailing_zeros(%Decimal{sign: sign, coef: coef, exp: exp} = d) do
    case digit_count(coef) - @exact_digits do
      drop when drop <= 0 -> {:ok, d}
      drop -> divide_out(sign, coef, exp, drop, Integer.pow(10, drop))
    end
  end

  defp divide_out(sign, coef, exp, drop, power) do
    case rem(coef, power) do
      0 -> {:ok, Decimal.new(sign, div(coef, power), exp + drop)}
      _too_wide -> :error
    end
  end

  defp exact_float(d) do
    float = Decimal.to_float(d)
    back = stored_decimal(float)

    if Decimal.equal?(Decimal.normalize(d), Decimal.normalize(back)) do
      {:float, float}
    else
      :error
    end
  end

  # log10(2) over 2^48. A bignum carries no digit count and writing
  # 100_000 digits out to count them costs more than the whole bind, so
  # the count starts from the bit length — byte-rounded, and the fraction
  # rounds down, so the first guess is only ever too high.
  @log10_2_num 84_732_411_018_728
  @log10_2_den 281_474_976_710_656

  defp digit_count(coef) do
    bits = coef |> :binary.encode_unsigned() |> bit_size()
    guess = div(bits * @log10_2_num, @log10_2_den) + 1

    settle_digits(coef, guess, Integer.pow(10, guess - 1))
  end

  defp settle_digits(coef, guess, power) when coef < power do
    settle_digits(coef, guess - 1, div(power, 10))
  end

  defp settle_digits(_coef, guess, _power), do: guess

  # Decimal's defaults stop a parse at 34 significant digits and an exponent
  # of 6144. A number someone stored is data, so both are lifted here and a
  # width ceiling on a load, if one is ever needed, returns to this one
  # place. "NaN" and "Infinity" parse cleanly and are not numbers with digits
  # to store, so they leave as `:error` like any other unreadable text.
  @doc false
  @spec parse_finite(binary()) :: {:ok, Decimal.t()} | :error
  def parse_finite(text) do
    case Decimal.parse(text, max_digits: :infinity, max_exponent: :infinity) do
      {%Decimal{} = number, ""} -> finite(number)
      _partial_or_error -> :error
    end
  end

  @doc false
  @spec finite(Decimal.t()) :: {:ok, Decimal.t()} | :error
  def finite(%Decimal{} = number) do
    if Decimal.nan?(number) or Decimal.inf?(number) do
      :error
    else
      {:ok, number}
    end
  end

  # What a SELECT returns after NUMERIC affinity stores the bound float.
  # SQLite demotes an integral REAL within int64 range to an INTEGER, which
  # reads back with its exact digits; everything else stays REAL and reads
  # back through the same shortest-representation printing the :decimal
  # loader uses. Comparing against the shortest printing alone is not enough:
  # it can echo the original digits even after the float rounded, while the
  # integer demotion surfaces the true rounded value.
  @doc false
  @spec stored_decimal(float()) :: Decimal.t()
  def stored_decimal(f) do
    t = trunc(f)

    if t + 0.0 == f and t >= @int64_min and t <= @int64_max do
      Decimal.new(t)
    else
      Decimal.from_float(f)
    end
  end
end

defmodule XqliteEcto3.DecimalPrecisionError do
  @moduledoc """
  Raised when a `Decimal` cannot be stored without silent rounding.

  SQLite has no exact-decimal storage class: a `:decimal` column carries
  NUMERIC affinity, so the value is coerced to a float64 (REAL) at write
  time, which is exact only to ~15 significant digits. Rather than store a
  quietly-rounded number, the adapter refuses a `Decimal` whose value does
  not survive the float64 round-trip. `value` carries the offending
  `Decimal` and `index` its 1-based parameter position, so callers
  pattern-match on them instead of parsing the message.
  """

  defexception [:value, :index]

  @type t :: %__MODULE__{value: Decimal.t(), index: pos_integer() | nil}

  # The refused values include the ones no written-out form can hold — an
  # exponent of a billion is a billion characters — so the message prints the
  # coefficient and the exponent, which is as wide as the struct the caller
  # already has. For an exponent of zero or below with an adjusted exponent
  # of -6 or more, that is the same text the written-out form gives.
  @impl true
  def message(%__MODULE__{value: value}) do
    "decimal #{Decimal.to_string(value, :scientific, max_digits: :infinity)} exceeds SQLite's exact numeric " <>
      "precision — a :decimal column has NUMERIC affinity and stores as float64 (REAL), " <>
      "exact only to ~15 significant digits, so storing this value would silently round " <>
      "it. To keep the exact digits, declare the field XqliteEcto3.Types.ExactDecimal " <>
      "over a :string column — it stores the number as text, every digit kept. A " <>
      ":decimal field over a TEXT column does not help, the value still binds as a " <>
      "number. Or reduce the value's precision."
  end
end
