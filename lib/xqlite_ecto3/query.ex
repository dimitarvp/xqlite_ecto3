defmodule XqliteEcto3.Query do
  @moduledoc false

  defstruct [:statement, :name, :ref, :command]

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
    defp encode_param(%NaiveDateTime{} = dt, _index), do: sqlite_datetime(dt)

    # to_naive/1 alone would keep a zoned value's LOCAL wall clock and
    # silently shift the instant; shifting to UTC first needs no tz
    # database (the offset arithmetic suffices for Etc/UTC), so the
    # refusal below is unreachable under any time zone database whose
    # Etc/UTC keeps its constant zero offset.
    defp encode_param(%DateTime{} = dt, index) do
      case DateTime.shift_zone(dt, "Etc/UTC") do
        {:ok, utc} ->
          utc |> DateTime.to_naive() |> sqlite_datetime()

        {:error, reason} ->
          raise XqliteEcto3.UnencodableParameterError, value: dt, index: index, reason: reason
      end
    end

    defp encode_param(%Date{} = d, _index), do: Date.to_iso8601(d)

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

    # The numeric guard applies at every depth: a nested decimal is
    # replaced by the number it binds as, where Jason would print it as a
    # quoted string. Any other struct is left for Jason to judge.
    defp json_form(%Decimal{} = d, index), do: encode_param(d, index)
    defp json_form(%{__struct__: _} = value, _index), do: value
    defp json_form(value, index) when is_map(value), do: Map.new(value, &json_pair(&1, index))
    defp json_form(value, index) when is_list(value), do: Enum.map(value, &json_form(&1, index))
    defp json_form(value, _index), do: value

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

  Plain maps and lists encode to JSON text. A struct is JSON only if it
  implements `Jason.Encoder`; the adapter attempts that encoding and
  refuses with this exception when it fails — Ecto does not validate what
  a custom type's `dump/1` returns, so a struct can reach the driver
  untouched (a `:duration` field's `%Duration{}` does).

  A `%Decimal{}` inside a map or a list never reaches the JSON encoder:
  it is replaced by the number it binds as first, and one that has no
  exact number raises `XqliteEcto3.DecimalPrecisionError` instead.

  Fields: `value` (the offending parameter), `index` (its 1-based
  position), `reason` (a `%Protocol.UndefinedError{}` for a missing
  `Jason.Encoder`, a `%Jason.EncodeError{}` for input JSON cannot
  represent, or the reason a `DateTime` could not be shifted to UTC).
  """

  defexception [:value, :index, :reason]

  @type t :: %__MODULE__{value: term(), index: pos_integer() | nil, reason: term()}

  @impl true
  def message(%__MODULE__{value: value, index: index}) do
    "parameter #{index} (#{inspect(value)}) cannot be encoded for SQLite: JSON " <>
      "encoding failed (a struct without a Jason.Encoder implementation, or a value " <>
      "JSON cannot represent). Bind a supported type — integer, float, binary, " <>
      "boolean, Date/Time/NaiveDateTime/DateTime, Decimal, plain map or list — or " <>
      "convert the value before binding."
  end
end
