defmodule XqliteEcto3.Types.ExactDecimal do
  @moduledoc """
  Arbitrary-precision decimal stored as text, with every digit kept.

  SQLite has no exact-decimal storage class. An ordinary `:decimal` field
  binds the number as an int64 or a float64, so a value past float64's ~15
  significant digits either raises `XqliteEcto3.DecimalPrecisionError` (on a
  `DECIMAL` column) or comes back slightly changed (on a TEXT column, where
  SQLite renders the bound float back to text). This type avoids both: it
  writes the number as text and reads it back from text, so no float is ever
  on the path and no digit is lost.

  ## Usage

      schema "invoices" do
        field :amount, XqliteEcto3.Types.ExactDecimal
      end

  Migration:

      add :amount, :string

  (`:text` gives the same TEXT column and works just as well.)

  ## The stored form

  `dump/1` writes `Decimal.to_string(value, :normal, max_digits: :infinity)`:
  plain digits, never an exponent, and the scale you wrote is kept.

      Decimal.new("1.50")          #=> "1.50"
      Decimal.new("1E+3")          #=> "1000"
      Decimal.new("0.000001E-20")  #=> "0.00000000000000000000000001"
      Decimal.new("-0")            #=> "-0"
      Decimal.new("-0E+3")         #=> "-0000"

  A positive exponent is expanded into digits, so `1E+3` reads back as the
  coefficient 1000 at exponent 0: the same number, a different `Decimal`
  struct. A value at exponent zero or below reads back struct-identical.
  Negative zero keeps its sign.

  ## How it differs from Ecto's `:decimal`

  It is wider. Ecto's `:decimal` cast refuses a string past 34 significant
  digits, which is `Decimal.parse/1`'s default limit. This type parses and
  prints with that limit lifted, so a value of any number of digits goes in
  and comes back out.

  It is also quieter about non-finite values. Ecto's `:decimal` **raises**
  `ArgumentError` when handed NaN or an infinity as a `%Decimal{}`, an
  integer or a float; this type returns `:error` for those, the same answer
  it gives for the strings `"NaN"`, `"Infinity"` and `"-Infinity"`.

  `cast/1` accepts `nil`, a finite `%Decimal{}`, an integer, a float (through
  `Decimal.from_float/1`), and a string that `Decimal.parse/2` consumes whole
  and that is finite. Leading zeros and a trailing dot normalize the way
  `Decimal.parse/2` normalizes them: `"007"` becomes `7` and `"5."` becomes
  `5`. Anything else is `:error`.

  ## What a failure looks like

  `Ecto.Changeset.change/2` does not cast, so a non-finite `%Decimal{}` can
  reach `dump/1` without passing `cast/1` first. `dump/1` rejects it on its
  own, and Ecto reports that as `Ecto.ChangeError`, naming the value and the
  type.

  A stored value this type cannot read — a BLOB, or text that is not a number
  — makes `load/1` return `:error`, and Ecto raises `ArgumentError` naming
  the value and the type. That error does not name the field.

  ## Comparisons in SQL are textual

  The column holds text, so SQLite compares it as text. `equal?/2` here calls
  `9.5` and `9.50` one number, following `Decimal.equal?/2`, but they are two
  different strings and therefore two different rows to SQL: `WHERE amount =
  '9.5'` finds only one of them, and `ORDER BY amount` puts `"10"` before
  `"9.5"`. If you order, range-filter or compare the column in SQL, store
  every value at one scale, or keep a second numeric column for the
  comparison.

  Two more query notes:

    * `type(^value, XqliteEcto3.Types.ExactDecimal)` emits
      `CAST(?1 AS TEXT)`. The parameter is already text, so the cast changes
      nothing.
    * Comparing a `%Decimal{}` against a plain `:string` field —
      `where: i.amount == ^Decimal.new("9.5")` where `:amount` is declared
      `:string` — raises `Ecto.Query.CastError` while the query is built,
      before any SQL exists. That is the wall you hit when you keep the
      canonical string in a `:string` field by hand. Declaring the field as
      this type is the way past it.

  ## Embedded schemas

  `embed_as/1` is `:dump`, so a value inside an embedded schema goes through
  this module's own `dump/1` and `load/1` — the same pair the column round
  trip uses, with the same digit limits lifted. The `:self` alternative would
  read the value back through `cast/1` and leave the writing to Jason, whose
  own 6178-digit print limit is not lifted. Either way the stored JSON holds
  a string, never a JSON number.
  """

  use Ecto.Type

  @parse_limits [max_digits: :infinity, max_exponent: :infinity]
  @print_limits [max_digits: :infinity]

  @impl Ecto.Type
  def type, do: :string

  @impl Ecto.Type
  def embed_as(_format), do: :dump

  @impl Ecto.Type
  def cast(nil), do: {:ok, nil}
  def cast(%Decimal{} = value), do: finite(value)
  def cast(value) when is_integer(value), do: value |> Decimal.new() |> finite()
  def cast(value) when is_float(value), do: value |> Decimal.from_float() |> finite()
  def cast(value) when is_binary(value), do: parse(value)
  def cast(_other), do: :error

  @impl Ecto.Type
  def dump(nil), do: {:ok, nil}

  def dump(%Decimal{} = value) do
    case finite(value) do
      {:ok, number} -> {:ok, Decimal.to_string(number, :normal, @print_limits)}
      :error -> :error
    end
  end

  def dump(_other), do: :error

  @impl Ecto.Type
  def load(nil), do: {:ok, nil}
  def load(value) when is_binary(value), do: parse(value)
  def load(_other), do: :error

  @impl Ecto.Type
  def equal?(%Decimal{} = a, %Decimal{} = b), do: Decimal.equal?(a, b)
  def equal?(nil, nil), do: true
  def equal?(_a, _b), do: false

  # Decimal's defaults stop a parse at 34 significant digits and a printed
  # value at 6178 characters. Left in place they would let this type write
  # values it cannot read back, so both are lifted on both sides.
  defp parse(value) do
    case Decimal.parse(value, @parse_limits) do
      {%Decimal{} = number, ""} -> finite(number)
      _partial_or_error -> :error
    end
  end

  # Decimal.parse/2 accepts "NaN" and "Infinity", and Decimal arithmetic
  # produces both. Neither is a number with digits to store.
  defp finite(number) do
    if Decimal.nan?(number) or Decimal.inf?(number) do
      :error
    else
      {:ok, number}
    end
  end
end
