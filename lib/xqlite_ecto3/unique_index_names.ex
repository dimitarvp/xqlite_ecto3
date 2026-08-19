defmodule XqliteEcto3.UniqueIndexNames do
  @moduledoc """
  Recovers the real name of the unique index behind a UNIQUE
  violation.

  SQLite names the index in its violation message only for indexes
  built over expressions (`index 'name'`). Every plain or partial
  unique index reports the `table.column` form instead, which leaves
  the adapter guessing Ecto's default `"<table>_<column>_index"` — so
  an index created under any other name could never be matched by
  `Ecto.Changeset.unique_constraint/3`.

  This module reads the names back from the database on the error
  path, where the failed statement still holds the connection:

  1. `PRAGMA index_list(<table>)` — every index on the table, with
     its unique flag and its origin: `"c"` for `CREATE INDEX`, `"u"`
     for a table-level `UNIQUE`, `"pk"` for the primary key
  2. `PRAGMA index_info(<index>)` — the indexed columns, in index
     order

  A unique index whose columns match the violated columns exactly is
  a candidate. Only `CREATE INDEX` carries a name somebody chose;
  table-level `UNIQUE` and `PRIMARY KEY` are backed by
  `sqlite_autoindex_*` names that no changeset would declare, so
  those keep using the conventional derived name.

  Several unique indexes can cover the same columns and SQLite never
  says which one it hit, so every candidate is reported. Ecto turns a
  reported constraint into a changeset error only when the changeset
  declares that exact name, and raises `Ecto.ConstraintError` for
  every name it does not — so a column covered by two unique indexes
  needs one `Ecto.Changeset.unique_constraint/3` call per name.

  Both pragmas are fallible. Any failure leaves the names empty and
  records `{:unavailable, reason}`; the conventional derived name
  then applies exactly as it did before.
  """

  alias XqliteEcto3.Error
  alias XqliteEcto3.Error.Constraint
  alias XqliteNIF, as: NIF

  @doc """
  Fills in `unique_index_names` on a UNIQUE violation that names only
  a table and columns.

  Every other error — including the expression-index form, which
  already carries `index_name` — passes through untouched.
  """
  @spec resolve(Error.t(), Xqlite.conn()) :: Error.t()
  def resolve(%Error{details: %Constraint{} = details} = error, conn) do
    %{error | details: resolve_details(details, conn)}
  end

  def resolve(error, _conn), do: error

  defp resolve_details(
         %Constraint{
           subtype: :constraint_unique,
           index_name: nil,
           table: table,
           columns: [_ | _] = columns
         } = details,
         conn
       )
       when is_binary(table) do
    case candidates(conn, table, columns) do
      {:ok, names} -> %{details | unique_index_names: names, unique_index_lookup: :ok}
      {:error, reason} -> %{details | unique_index_lookup: {:unavailable, reason}}
    end
  end

  defp resolve_details(details, _conn), do: details

  defp candidates(conn, table, columns) do
    case NIF.query(conn, "PRAGMA index_list(#{quote_ident(table)})", []) do
      {:ok, %{rows: rows}} ->
        rows
        |> Enum.flat_map(&named_unique_index/1)
        |> matching_indexes(conn, columns)

      {:error, _reason} = err ->
        err
    end
  end

  # index_list columns: seq, name, unique, origin, partial.
  defp named_unique_index([_seq, name, 1, "c" | _]) when is_binary(name), do: [name]
  defp named_unique_index(_row), do: []

  defp matching_indexes(names, conn, columns) do
    names
    |> Enum.reduce_while({:ok, []}, fn name, acc -> collect_match(conn, columns, name, acc) end)
    |> deduplicate()
  end

  defp collect_match(conn, columns, name, {:ok, acc}) do
    case index_columns(conn, name) do
      {:ok, ^columns} -> {:cont, {:ok, [name | acc]}}
      {:ok, _other_columns} -> {:cont, {:ok, acc}}
      {:error, _reason} = err -> {:halt, err}
    end
  end

  # Sorted so the same schema always maps to the same constraint list.
  defp deduplicate({:ok, names}) do
    sorted =
      names
      |> Enum.uniq()
      |> Enum.sort()

    {:ok, sorted}
  end

  defp deduplicate({:error, _reason} = err), do: err

  defp index_columns(conn, index_name) do
    case NIF.query(conn, "PRAGMA index_info(#{quote_ident(index_name)})", []) do
      {:ok, %{rows: rows}} -> {:ok, ordered_columns(rows)}
      {:error, _reason} = err -> err
    end
  end

  # index_info columns: seqno, cid, name. An indexed expression has no
  # column name, and nil never equals a column from the violation.
  defp ordered_columns(rows) do
    rows
    |> Enum.sort_by(&index_info_position/1)
    |> Enum.map(&index_info_column/1)
  end

  defp index_info_position([seqno | _]) when is_integer(seqno), do: seqno
  defp index_info_position(_row), do: 0

  defp index_info_column([_seqno, _cid, name | _]), do: name
  defp index_info_column(_row), do: nil

  defp quote_ident(name) do
    "\"" <> String.replace(name, "\"", "\"\"") <> "\""
  end
end
