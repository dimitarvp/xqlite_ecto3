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
    defp encode_param(%NaiveDateTime{} = dt, _index), do: NaiveDateTime.to_iso8601(dt)
    defp encode_param(%DateTime{} = dt, _index), do: DateTime.to_iso8601(dt)
    defp encode_param(%Date{} = d, _index), do: Date.to_iso8601(d)
    defp encode_param(%Time{} = t, _index), do: Time.to_iso8601(t)

    defp encode_param(%Decimal{} = d, index) do
      if XqliteEcto3.DecimalPrecision.representable?(d) do
        Decimal.to_string(d, :normal)
      else
        raise XqliteEcto3.DecimalPrecisionError, value: d, index: index
      end
    end

    defp encode_param(value, index) when is_map(value), do: encode_json(value, index)
    defp encode_param(value, index) when is_list(value), do: encode_json(value, index)
    defp encode_param(value, _index), do: value

    # Ecto does not validate what a custom type's dump/1 returns, so a
    # struct can reach this boundary untouched (a :duration field's
    # %Duration{} does). Jason reports invalid input as an error tuple,
    # but a missing Jason.Encoder implementation raises through protocol
    # dispatch instead — the rescue converts that raise into the same
    # structured refusal, naming the parameter instead of the protocol.
    defp encode_json(value, index) do
      case Jason.encode(value) do
        {:ok, json} ->
          json

        {:error, reason} ->
          raise XqliteEcto3.UnencodableParameterError,
            value: value,
            index: index,
            reason: reason
      end
    rescue
      e in Protocol.UndefinedError ->
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

  Fields: `value` (the offending parameter), `index` (its 1-based
  position), `reason` (a `%Protocol.UndefinedError{}` for a missing
  `Jason.Encoder`, or a `%Jason.EncodeError{}` for input JSON cannot
  represent).
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
