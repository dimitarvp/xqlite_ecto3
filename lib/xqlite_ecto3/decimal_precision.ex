defmodule XqliteEcto3.DecimalPrecision do
  @moduledoc false

  # SQLite has no exact-decimal storage class: a `:decimal` column carries
  # NUMERIC affinity and the adapter binds the decimal as TEXT. NUMERIC
  # affinity then stores that text one of two ways: a plain integer literal
  # that fits in int64 becomes an exact INTEGER (no float64 anywhere in the
  # path); every other numeric text is coerced to a float64 (REAL). Keeping
  # numeric storage is deliberate — ordering and range queries depend on
  # it — but a value that does not survive its storage path would come back
  # quietly changed. `representable?/1` answers whether a decimal survives,
  # so the binding boundary can refuse the ones that would not, instead of
  # writing a silently-wrong value.

  # float64 (IEEE-754 double) finite magnitude bounds. Outside them a value
  # has no clean float64 form — these value-equal the limits `Decimal.to_float/1`
  # itself enforces, so the pre-check refuses out-of-range values rather than
  # letting the conversion raise.
  @dbl_max Decimal.new("1.7976931348623158E308")
  @dbl_min Decimal.new("2.2250738585072014E-308")

  @int64_min -9_223_372_036_854_775_808
  @int64_max 9_223_372_036_854_775_807

  @doc """
  Whether a `Decimal` survives storage under NUMERIC affinity unchanged —
  float64 conversion at bind time, then SQLite's own storage rules.

  The check mirrors what a SELECT actually returns: the value is converted
  to float64, then compared as SQLite would hand it back — an integral
  float within int64 range demotes to INTEGER and reads back with exact
  digits, anything else stays REAL and reads back through shortest-
  representation printing. This accepts typical money and anything exact
  within ~15 significant digits (including large float-exact integers) and
  rejects any value whose stored form would differ from the original.
  """
  @spec representable?(Decimal.t()) :: boolean()
  def representable?(%Decimal{} = d) do
    cond do
      Decimal.nan?(d) -> false
      Decimal.inf?(d) -> false
      Decimal.equal?(d, 0) -> true
      integer_literal_in_int64?(d) -> true
      out_of_float_range?(d) -> false
      true -> round_trips?(d)
    end
  end

  # The bind path sends `Decimal.to_string(d, :normal)`. When that text is
  # a plain integer literal that fits in int64, NUMERIC affinity stores it
  # as an exact INTEGER — no float64 in the path — so the value round-trips
  # digit-for-digit past float64's 53-bit limit. The check keys on the
  # RENDERED form, not the mathematical value: the same digits written
  # "…0.0" render with a decimal point, SQLite parses that text as a REAL,
  # and the float64 model below stays the judge for it.
  defp integer_literal_in_int64?(d) do
    text = Decimal.to_string(d, :normal)

    case Integer.parse(text) do
      {int, ""} -> int >= @int64_min and int <= @int64_max
      _fractional_or_exponent -> false
    end
  end

  defp out_of_float_range?(d) do
    abs = Decimal.abs(d)
    Decimal.gt?(abs, @dbl_max) or Decimal.lt?(abs, @dbl_min)
  end

  defp round_trips?(d) do
    back =
      d
      |> Decimal.to_float()
      |> stored_decimal()

    Decimal.equal?(Decimal.normalize(d), Decimal.normalize(back))
  end

  # What a SELECT returns after NUMERIC affinity stores the bound float.
  # SQLite demotes an integral REAL within int64 range to an INTEGER, which
  # reads back with its exact digits; everything else stays REAL and reads
  # back through the same shortest-representation printing the :decimal
  # loader uses. The old check compared against the shortest printing alone,
  # which can echo the original digits even after the float rounded — the
  # integer demotion then surfaced the true rounded value (a 17-digit
  # integer stored as its float64 neighbor was accepted and came back off
  # by two).
  defp stored_decimal(f) do
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

  @impl true
  def message(%__MODULE__{value: value}) do
    "decimal #{Decimal.to_string(value, :normal)} exceeds SQLite's exact numeric " <>
      "precision — a :decimal column has NUMERIC affinity and stores as float64 (REAL), " <>
      "exact only to ~15 significant digits, so storing this value would silently round " <>
      "it. Use a :string column to keep the exact digits, or reduce the value's precision."
  end
end
