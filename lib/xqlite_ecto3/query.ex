defmodule XqliteEcto3.Query do
  @moduledoc false

  defstruct [:statement, :name, :ref, :command]

  defimpl DBConnection.Query do
    def parse(query, _opts), do: query
    def describe(query, _opts), do: query

    def encode(_query, params, _opts) do
      Enum.map(params, &encode_param/1)
    end

    def decode(_query, result, _opts) do
      result
    end

    defp encode_param(true), do: 1
    defp encode_param(false), do: 0
    defp encode_param(%NaiveDateTime{} = dt), do: NaiveDateTime.to_iso8601(dt)
    defp encode_param(%DateTime{} = dt), do: DateTime.to_iso8601(dt)
    defp encode_param(%Date{} = d), do: Date.to_iso8601(d)
    defp encode_param(%Time{} = t), do: Time.to_iso8601(t)
    defp encode_param(%Decimal{} = d), do: Decimal.to_string(d, :normal)
    defp encode_param(value) when is_map(value), do: Jason.encode!(value)
    defp encode_param(value) when is_list(value), do: Jason.encode!(value)
    defp encode_param(value), do: value
  end

  defimpl String.Chars do
    def to_string(%{statement: statement}) do
      IO.iodata_to_binary(statement)
    end
  end
end
