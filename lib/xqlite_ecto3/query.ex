defmodule XqliteEcto3.Query do
  @moduledoc false

  defstruct [:statement, :name, :ref, :command]

  @min_year -9999
  @max_year 9999

  @doc false
  @spec year_range() :: {integer(), integer()}
  def year_range, do: {@min_year, @max_year}

  @doc false
  @spec year_in_range?(Date.t() | NaiveDateTime.t() | DateTime.t()) :: boolean()
  def year_in_range?(%{year: year}), do: year >= @min_year and year <= @max_year

  defimpl DBConnection.Query do
    def parse(query, _opts), do: query
    def describe(query, _opts), do: query

    def encode(_query, params, _opts) do
      params
      |> Enum.with_index(1)
      |> Enum.map(fn {value, index} -> encode_param(value, index) end)
    end

    def decode(_query, result, _opts) do
      result
    end

    defp encode_param(true, _index), do: 1
    defp encode_param(false, _index), do: 0
    # SQLite's own datetime form — "YYYY-MM-DD HH:MM:SS[.ffffff]", no T,
    # no Z. The T/Z form byte-sorts against SQLite-written values (a
    # CURRENT_TIMESTAMP default, datetime()) at the separator, and the
    # trailing Z makes a sub-second value sort BEFORE its own whole
    # second. UTC datetimes arrive normalized from Ecto, so dropping the
    # designator loses nothing.
    defp encode_param(%NaiveDateTime{} = dt, index) do
      dt |> in_year_range(index) |> sqlite_datetime()
    end

    # to_naive/1 alone would keep a zoned value's LOCAL wall clock and
    # silently shift the instant; shifting to UTC first needs no tz
    # database (the offset arithmetic suffices for Etc/UTC), so the
    # refusal below is unreachable under any time zone database whose
    # Etc/UTC keeps its constant zero offset.
    defp encode_param(%DateTime{} = dt, index) do
      case DateTime.shift_zone(dt, "Etc/UTC") do
        {:ok, utc} ->
          utc |> in_year_range(index) |> DateTime.to_naive() |> sqlite_datetime()

        {:error, reason} ->
          raise XqliteEcto3.UnencodableParameterError, value: dt, index: index, reason: reason
      end
    end

    defp encode_param(%Date{} = d, index) do
      d |> in_year_range(index) |> Date.to_iso8601()
    end

    defp encode_param(%Time{} = t, _index), do: Time.to_iso8601(t)

    # A decimal binds as a NUMBER, never as text: SQLite compares by storage
    # class when the other operand has no column affinity to coerce with (an
    # aggregate, an arithmetic expression, a `coalesce`), and every number
    # sorts below every text, so a text bind answers those comparisons by
    # type instead of by value. The guard picks whichever numeric form is
    # exact for the value and refuses the values that have none.
    defp encode_param(%Decimal{} = d, index) do
      case XqliteEcto3.DecimalPrecision.bind_form(d) do
        {:integer, int} -> int
        {:float, float} -> float
        :error -> raise XqliteEcto3.DecimalPrecisionError, value: d, index: index
      end
    end

    defp encode_param(value, index) when is_map(value), do: encode_json(value, index)

    defp encode_param(value, index) when is_list(value), do: encode_json(value, index)
    defp encode_param(value, _index), do: value

    defp sqlite_datetime(%NaiveDateTime{} = dt) do
      dt |> NaiveDateTime.to_iso8601() |> String.replace("T", " ")
    end

    # The stored text carries a four-digit year, and every loader parses it
    # back with `from_iso8601/1`, which needs exactly four. A wider year is
    # written unpadded, so one such row makes every later read of the table
    # raise. Refusing here is the only place the value can still be seen.
    defp in_year_range(value, index) do
      case XqliteEcto3.Query.year_in_range?(value) do
        true ->
          value

        false ->
          raise XqliteEcto3.UnencodableParameterError,
            value: value,
            index: index,
            reason: :year_out_of_range
      end
    end

    # The numeric guard applies at every depth: a nested decimal is
    # replaced by the number it binds as, where Jason would print it as a
    # quoted string. A nested datetime gets the same year check the column
    # path gets, because an embedded schema hands the driver a map of raw
    # structs that never reaches `encode_param/2`. Any other struct is left
    # for Jason to judge.
    defp json_form(%Decimal{} = d, index), do: encode_param(d, index)
    defp json_form(%Date{} = d, index), do: in_year_range(d, index)
    defp json_form(%NaiveDateTime{} = dt, index), do: in_year_range(dt, index)
    defp json_form(%DateTime{} = dt, index), do: in_year_range(dt, index)
    defp json_form(%{__struct__: _} = value, _index), do: value

    # A UUID dumped for `:binary` storage arrives as sixteen raw bytes, which
    # JSON cannot carry — an embedded `:binary_id` field was refused outright
    # before this clause existed. Written out as the dashed text it is the
    # same value the column path stores, and every UUID loader reads it back.
    # Bytes that are valid UTF-8 are left alone: JSON already carries them,
    # and the loaders expand sixteen stored bytes anyway.
    defp json_form(<<_::128>> = raw, _index) do
      case String.valid?(raw) do
        true -> raw
        false -> uuid_text(raw)
      end
    end

    defp json_form(value, index) when is_map(value), do: Map.new(value, &json_pair(&1, index))
    defp json_form(value, index) when is_list(value), do: Enum.map(value, &json_form(&1, index))
    defp json_form(value, _index), do: value

    defp uuid_text(raw) do
      case Ecto.UUID.cast(raw) do
        {:ok, text} -> text
        :error -> raw
      end
    end

    defp json_pair({key, value}, index), do: {key, json_form(value, index)}

    # Ecto does not validate what a custom type's dump/1 returns, so a
    # struct can reach this boundary untouched (a :duration field's
    # %Duration{} does). Jason reports invalid input as an error tuple,
    # but a missing Jason.Encoder implementation raises through protocol
    # dispatch instead — the rescue turns that raise into the same
    # structured refusal, naming the parameter instead of the protocol.
    defp encode_json(value, index) do
      value
      |> json_form(index)
      |> Jason.encode()
      |> case do
        {:ok, json} ->
          json

        {:error, reason} ->
          raise XqliteEcto3.UnencodableParameterError,
            value: value,
            index: index,
            reason: reason
      end
    rescue
      e in [Protocol.UndefinedError, ArgumentError] ->
        reraise XqliteEcto3.UnencodableParameterError.exception(
                  value: value,
                  index: index,
                  reason: e
                ),
                __STACKTRACE__
    end
  end

  defimpl String.Chars do
    def to_string(%{statement: statement}) do
      IO.iodata_to_binary(statement)
    end
  end
end

defmodule XqliteEcto3.UnencodableParameterError do
  @moduledoc """
  Raised when a query parameter has no encodable form.

  Three causes, told apart by `reason`:

    * **A year the stored form cannot carry.** A `Date`, `NaiveDateTime`
      or `DateTime` outside years -9999 to 9999 writes an unpadded year
      that no loader can parse back, so every later read of the table
      would raise. `reason` is `:year_out_of_range`.

    * **A `DateTime` that could not be shifted to UTC.** `reason` is
      whatever `DateTime.shift_zone/2` answered — an atom naming the
      time-zone database problem.

    * **JSON that could not be encoded.** Plain maps and lists encode to
      JSON text. A struct is JSON only if it implements `Jason.Encoder`;
      Ecto does not validate what a custom type's `dump/1` returns, so a
      struct can reach the driver untouched (a `:duration` field's
      `%Duration{}` does). `reason` is a `%Protocol.UndefinedError{}` for
      a missing `Jason.Encoder` or a `%Jason.EncodeError{}` for input JSON
      cannot represent.

  A `%Decimal{}` inside a map or a list never reaches the JSON encoder:
  it is replaced by the number it binds as first, and one that has no
  exact number raises `XqliteEcto3.DecimalPrecisionError` instead.

  Fields: `value` (the offending parameter), `index` (its 1-based
  position), `reason` (one of the three above).
  """

  defexception [:value, :index, :reason]

  @type t :: %__MODULE__{value: term(), index: pos_integer() | nil, reason: term()}

  @impl true
  def message(%__MODULE__{value: %{year: year} = value, index: index, reason: :year_out_of_range}) do
    {first, last} = XqliteEcto3.Query.year_range()

    "parameter #{index} (#{inspect(value)}) cannot be encoded for SQLite: its year " <>
      "#{year} is outside #{first}..#{last}. SQLite's date functions and this " <>
      "adapter's loaders both read a four-digit year, so a wider one would be " <>
      "written as text nothing can read back. Store the value in a column of your " <>
      "own choosing — an integer count, or text you format yourself."
  end

  def message(%__MODULE__{value: value, index: index, reason: reason})
      when is_atom(reason) and not is_nil(reason) do
    "parameter #{index} (#{inspect(value)}) cannot be encoded for SQLite: its " <>
      "DateTime could not be shifted to UTC (#{inspect(reason)}). The adapter stores " <>
      "every datetime in UTC, so a value carrying a zone needs a time-zone database " <>
      "that can resolve it."
  end

  def message(%__MODULE__{value: value, index: index}) do
    "parameter #{index} (#{inspect(value)}) cannot be encoded for SQLite: JSON " <>
      "encoding failed (a struct without a Jason.Encoder implementation, or a value " <>
      "JSON cannot represent). Bind a supported type — integer, float, binary, " <>
      "boolean, Date/Time/NaiveDateTime/DateTime, Decimal, plain map or list — or " <>
      "convert the value before binding."
  end
end
