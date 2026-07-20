defmodule XqliteEcto3.DecimalPrecision do
  @moduledoc false

  # SQLite has no exact-decimal storage class: a `:decimal` column carries
  # NUMERIC affinity, so a bound decimal is coerced to a float64 (REAL) at
  # write time. Keeping numeric storage is deliberate — ordering and range
  # queries depend on it — but a value that does not survive the float64
  # round-trip would be stored as a quietly-rounded number. `representable?/1`
  # answers whether a decimal survives that round-trip so the binding boundary
  # can refuse the ones that would not, instead of writing a silently-wrong
  # value.

  # float64 (IEEE-754 double) finite magnitude bounds. Outside them a value
  # has no clean float64 form — these value-equal the limits `Decimal.to_float/1`
  # itself enforces, so the pre-check refuses out-of-range values rather than
  # letting the conversion raise.
  @dbl_max Decimal.new("1.7976931348623158E308")
  @dbl_min Decimal.new("2.2250738585072014E-308")

  @doc """
  Whether a `Decimal` survives a float64 round-trip unchanged, i.e. whether
  SQLite's NUMERIC affinity can store it as REAL without rounding it.

  The check is `Decimal -> float64 -> shortest round-trip string -> Decimal`,
  compared to the original normalized value. This accepts typical money and
  anything exact within ~15 significant digits (including large float-exact
  integers) and rejects only values whose magnitude changes through float64.
  """
  @spec representable?(Decimal.t()) :: boolean()
  def representable?(%Decimal{} = d) do
    cond do
      Decimal.nan?(d) -> false
      Decimal.inf?(d) -> false
      Decimal.equal?(d, 0) -> true
      out_of_float_range?(d) -> false
      true -> round_trips?(d)
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
      |> Float.to_string()
      |> Decimal.new()

    Decimal.equal?(Decimal.normalize(d), Decimal.normalize(back))
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
  `Decimal` so callers pattern-match on it instead of parsing the message.
  """

  defexception [:value]

  @type t :: %__MODULE__{value: Decimal.t()}

  @impl true
  def message(%__MODULE__{value: value}) do
    "decimal #{Decimal.to_string(value, :normal)} exceeds SQLite's exact numeric " <>
      "precision — a :decimal column has NUMERIC affinity and stores as float64 (REAL), " <>
      "exact only to ~15 significant digits, so storing this value would silently round " <>
      "it. Use a :string column to keep the exact digits, or reduce the value's precision."
  end
end
