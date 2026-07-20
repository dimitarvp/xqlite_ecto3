defmodule XqliteEcto3.DataType do
  @moduledoc false

  # SQLite column type mapping. SQLite has no exact-decimal storage class:
  # a DECIMAL column carries NUMERIC affinity, so numeric values are coerced
  # to INTEGER or REAL (float64) at write time. Decimals beyond float64's
  # exact precision (~15 significant digits) are refused at the binding
  # boundary rather than silently rounded (see the adapter moduledoc).
  # Declared sizes/precision are otherwise ignored, so most types map to
  # simple keywords.

  @spec column_type(atom() | {:array, term()} | {:map, term()}, term()) :: String.t()
  def column_type(:id, _opts), do: "INTEGER"
  def column_type(:serial, _opts), do: "INTEGER"
  def column_type(:bigserial, _opts), do: "INTEGER"
  def column_type(:boolean, _opts), do: "INTEGER"
  def column_type(:integer, _opts), do: "INTEGER"
  def column_type(:bigint, _opts), do: "INTEGER"
  def column_type(:string, _opts), do: "TEXT"
  def column_type(:float, _opts), do: "NUMERIC"
  def column_type(:binary, _opts), do: "BLOB"
  def column_type(:date, _opts), do: "TEXT"
  def column_type(:utc_datetime, _opts), do: "TEXT"
  def column_type(:utc_datetime_usec, _opts), do: "TEXT"
  def column_type(:naive_datetime, _opts), do: "TEXT"
  def column_type(:naive_datetime_usec, _opts), do: "TEXT"
  def column_type(:time, _opts), do: "TEXT"
  def column_type(:time_usec, _opts), do: "TEXT"
  def column_type(:timestamp, _opts), do: "TEXT"
  def column_type(:decimal, nil), do: "DECIMAL"

  def column_type(:decimal, opts) do
    precision = Keyword.get(opts, :precision)
    scale = Keyword.get(opts, :scale, 0)

    if precision do
      "DECIMAL(#{precision},#{scale})"
    else
      "DECIMAL"
    end
  end

  def column_type(:array, _opts), do: "TEXT"
  def column_type({:array, _}, _opts), do: "TEXT"
  def column_type(:binary_id, _opts), do: binary_id_column_type()
  def column_type(:map, _opts), do: "TEXT"
  def column_type({:map, _}, _opts), do: "TEXT"
  def column_type(:uuid, _opts), do: binary_id_column_type()

  def column_type(type, _) when is_atom(type) do
    type
    |> Atom.to_string()
    |> String.upcase()
  end

  def column_type(type, _) do
    raise XqliteEcto3.UnsupportedTypeError, type: type
  end

  # Reads `config :xqlite_ecto3, :binary_id_storage` (default `:string`) and
  # picks the corresponding SQLite column type for `:binary_id` / `:uuid`
  # fields in migrations. `:string` → TEXT, `:binary` → BLOB. Governs both
  # uniformly. `XqliteEcto3.Types.UUID` is a per-field escape hatch.
  defp binary_id_column_type do
    case Application.get_env(:xqlite_ecto3, :binary_id_storage, :string) do
      :string -> "TEXT"
      :binary -> "BLOB"
    end
  end
end

defmodule XqliteEcto3.UnsupportedTypeError do
  @moduledoc """
  Raised when a migration references a type that the adapter cannot
  render as a SQLite column type — non-atom, non-tuple, or a tuple shape
  with no matching clause. Structured so callers can pattern-match on
  the `type` field instead of parsing the message.
  """

  defexception [:type]

  @impl true
  def message(%__MODULE__{type: type}) do
    "unsupported type `#{inspect(type)}`"
  end
end
