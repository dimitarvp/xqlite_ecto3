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

  # Zero renders below the smallest float64 magnitude, so it is decided
  # before the range check that would otherwise refuse it.
  defp float_bind_form(d) do
    cond do
      Decimal.equal?(d, 0) -> {:float, Decimal.to_float(d)}
      out_of_float_range?(d) -> :error
      true -> exact_float(d)
    end
  end

  defp int64_literal(d) do
    text = Decimal.to_string(d, :normal)

    case Integer.parse(text) do
      {int, ""} when int >= @int64_min and int <= @int64_max -> {:ok, int}
      _fractional_or_out_of_range -> :error
    end
  end

  defp out_of_float_range?(d) do
    abs = Decimal.abs(d)
    Decimal.gt?(abs, @dbl_max) or Decimal.lt?(abs, @dbl_min)
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

  @impl true
  def message(%__MODULE__{value: value}) do
    "decimal #{Decimal.to_string(value, :normal)} exceeds SQLite's exact numeric " <>
      "precision — a :decimal column has NUMERIC affinity and stores as float64 (REAL), " <>
      "exact only to ~15 significant digits, so storing this value would silently round " <>
      "it. To keep the exact digits, use a :string FIELD (with a :string column) and " <>
      "store the canonical string yourself — a :decimal field over a TEXT column does " <>
      "not help, the value still binds as a number. Or reduce the value's precision."
  end
end
