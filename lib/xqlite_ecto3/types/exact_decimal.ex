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

  `dump/1` writes `Decimal.to_string(value, :normal)`: plain digits, never an
  exponent, and the scale you wrote is kept.

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
  digits, which is `Decimal.parse/1`'s default limit. This type parses with
  that limit lifted, so a value of many hundreds of digits goes in and comes
  back out.

  It is also quieter about non-finite values. Ecto's `:decimal` **raises**
  `ArgumentError` when handed NaN or an infinity as a `%Decimal{}`, an
  integer or a float; this type returns `:error` for those, the same answer
  it gives for the strings `"NaN"`, `"Infinity"` and `"-Infinity"`.

  `cast/1` accepts `nil`, a finite `%Decimal{}`, an integer, a float (through
  `Decimal.from_float/1`), and a string that `Decimal.parse/2` consumes whole,
  that is finite, and that is inside the width ceiling below. Leading zeros
  and a trailing dot normalize the way `Decimal.parse/2` normalizes them:
  `"007"` becomes `7` and `"5."` becomes `5`. Anything else is `:error`.

  ## The width ceiling

  The widening is on digits, not on zeros. `cast/1` and `dump/1` refuse a
  value whose written-out form would need more than **6178 digit
  characters** — at most 6180 bytes stored, counting a decimal point and a
  minus sign. That is `Decimal`'s own default print limit, and it is the
  widest written-out form any value `Decimal.parse/1` accepts at its
  defaults can have, so every value a plain `:decimal` field takes is still
  accepted here.

  The ceiling exists because the written-out form has no exponent:
  `"1E+8000000"` is ten characters that would write eight million. The
  width is computed from the coefficient's digit count and the exponent
  without writing anything out, so the refusal costs microseconds however
  large the exponent is.

  `cast/1` answers `:error`, which makes the changeset invalid. `dump/1`
  answers `:error`, and what Ecto raises depends on the path:
  `Ecto.ChangeError` from `Repo.insert`, `Repo.insert_all`, `Repo.update`
  and an `{:array, _}` field; `Ecto.Query.CastError` from `Repo.update_all`
  and from a query parameter; `ArgumentError` from inside an embedded
  schema. Nothing is written in any of them.

  `load/1` has no ceiling: a value already in a column keeps loading
  whatever its width, so a row wider than the ceiling — written by an
  earlier version or by another tool — still reads, and only writing it
  back is refused.

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
  trip uses, with the same parse limit lifted and the same width ceiling.
  The `:self` alternative would read the value back through `cast/1` and
  leave the writing to Jason. Either way the stored JSON holds a string,
  never a JSON number.
  """

  use Ecto.Type

  @max_digit_characters 6178

  @impl Ecto.Type
  def type, do: :string

  @impl Ecto.Type
  def embed_as(_format), do: :dump

  @impl Ecto.Type
  def cast(nil), do: {:ok, nil}
  def cast(%Decimal{} = value), do: value |> finite() |> within_ceiling()

  def cast(value) when is_integer(value),
    do: value |> Decimal.new() |> finite() |> within_ceiling()

  def cast(value) when is_float(value), do: value |> Decimal.from_float() |> finite()
  def cast(value) when is_binary(value), do: value |> parse() |> within_ceiling()
  def cast(_other), do: :error

  @impl Ecto.Type
  def dump(nil), do: {:ok, nil}

  def dump(%Decimal{} = value) do
    value
    |> finite()
    |> within_ceiling()
    |> case do
      {:ok, number} -> {:ok, Decimal.to_string(number, :normal)}
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

  # The same parse the `:decimal` loader reads stored text with, so one
  # column of numbers means the same thing under either field type.
  defp parse(value), do: XqliteEcto3.DecimalPrecision.parse_finite(value)

  defp finite(number), do: XqliteEcto3.DecimalPrecision.finite(number)

  # The written-out form of `1E+8000000` is eight million characters, and
  # nothing between the parse and the render looks at the exponent, so the
  # width is measured from the digit count and the exponent before anything
  # is written. Only the way in: a value already stored keeps loading.
  defp within_ceiling({:ok, number}) do
    case XqliteEcto3.DecimalPrecision.written_out_digits(number) do
      digits when digits <= @max_digit_characters -> {:ok, number}
      _wider -> :error
    end
  end

  defp within_ceiling(:error), do: :error
end
