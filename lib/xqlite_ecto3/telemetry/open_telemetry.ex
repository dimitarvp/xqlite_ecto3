defmodule XqliteEcto3.Telemetry.OpenTelemetry do
  @moduledoc """
  A pure translation table from the adapter's telemetry events to
  OpenTelemetry's stable database semantic-convention attributes.

  The adapter has NO OpenTelemetry dependency — you own the handler and
  the SDK. Feed any `[:xqlite_ecto3, ...]` event through `attributes/3`
  inside your own `:telemetry` handler and attach the returned map to
  the span you create. The xqlite library events have their own mirror:
  `Xqlite.Telemetry.OpenTelemetry`.

  Targets the STABLE database conventions: `db.system.name`,
  `db.query.text`, `db.operation.name`, `db.namespace`, `error.type`.

  ## Sources

  Every mapped name traces to the OpenTelemetry specification:

  * Database client spans (attribute set, span-name priority chain,
    and the `sqlite` value for `db.system.name`):
    <https://opentelemetry.io/docs/specs/semconv/database/database-spans/>
  * The `db.*` attribute registry:
    <https://opentelemetry.io/docs/specs/semconv/registry/attributes/db/>
  * The `error.type` attribute (general registry):
    <https://opentelemetry.io/docs/specs/semconv/registry/attributes/error/>

  Verified against the stable revision of the database conventions on
  2026-07-17; the pre-stabilization names (`db.system`,
  `db.statement`) are deliberately NOT emitted.
  """

  @doc """
  Maps one adapter telemetry event to semantic-convention attributes.

  Always includes `db.system.name => "sqlite"`. Adds
  `db.operation.name` derived from the event, `db.query.text` from the
  event's `:sql` (statement-cache events) or its `:query` struct's
  statement (DBConnection callback events), `db.namespace` from
  `:database` (connect events), and `error.type` for error results and
  exceptions.
  """
  @spec attributes([atom()], map(), map()) :: %{String.t() => String.t()}
  def attributes([:xqlite_ecto3 | _] = event, _measurements, metadata) when is_map(metadata) do
    %{"db.system.name" => "sqlite"}
    |> put_present("db.operation.name", operation_name(event))
    |> put_present("db.query.text", query_text(metadata))
    |> put_present("db.namespace", metadata[:database])
    |> put_error(metadata)
  end

  @doc """
  Suggested span name per the conventions' priority chain:
  `"{operation} {database}"` when both are known, the operation alone
  otherwise, `"sqlite"` as the last resort.
  """
  @spec span_name([atom()], map()) :: String.t()
  def span_name(event, metadata \\ %{}) do
    case {operation_name(event), metadata[:database]} do
      {nil, _database} -> "sqlite"
      {op, nil} -> op
      {op, database} -> "#{op} #{database}"
    end
  end

  defp operation_name([:xqlite_ecto3, op, stage]) when stage in [:start, :stop, :exception],
    do: Atom.to_string(op)

  defp operation_name([:xqlite_ecto3, group, sub | _rest]), do: "#{group}.#{sub}"
  defp operation_name(_event), do: nil

  defp query_text(%{sql: sql}) when is_binary(sql), do: sql
  defp query_text(%{query: %{statement: statement}}), do: statement_text(statement)
  defp query_text(_metadata), do: nil

  defp statement_text(statement) when is_binary(statement), do: statement
  defp statement_text(statement) when is_list(statement), do: IO.iodata_to_binary(statement)
  defp statement_text(_statement), do: nil

  defp put_present(attrs, _key, nil), do: attrs
  defp put_present(attrs, key, value) when is_binary(value), do: Map.put(attrs, key, value)
  defp put_present(attrs, _key, _value), do: attrs

  defp put_error(attrs, %{result_class: :error, error_reason: reason}),
    do: Map.put(attrs, "error.type", error_type(reason))

  defp put_error(attrs, %{kind: _kind, reason: reason}),
    do: Map.put(attrs, "error.type", error_type(reason))

  defp put_error(attrs, _metadata), do: attrs

  defp error_type(reason) when is_atom(reason), do: Atom.to_string(reason)
  defp error_type({tag, _}) when is_atom(tag), do: Atom.to_string(tag)
  defp error_type({tag, _, _}) when is_atom(tag), do: Atom.to_string(tag)
  defp error_type({tag, _, _, _}) when is_atom(tag), do: Atom.to_string(tag)
  defp error_type(%struct{}), do: inspect(struct)
  defp error_type(_reason), do: "error"
end
