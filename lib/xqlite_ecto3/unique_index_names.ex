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
  a candidate, whatever its origin. `sqlite_autoindex_*` names — the
  backing indexes of table-level `UNIQUE` and `PRIMARY KEY` — are
  recorded like any other candidate (the `sqlite_` prefix is reserved
  by SQLite, so they are unmistakable), but they are never emitted as
  a constraint name: no changeset declares them, so a lone autoindex
  candidate falls back to the conventional derived name.

  Several unique indexes can cover the same columns — including ones
  that provably did not fire, such as a partial index whose condition
  excludes the row, an autoindex beside a named sibling, or a sibling
  under another collation — and SQLite never says which one it hit.
  Every candidate is recorded on the error struct, but the constraint
  mapping emits a real name only when exactly one candidate exists
  and it is not an autoindex: Ecto raises `Ecto.ConstraintError` for
  every emitted name a changeset did not declare, so emitting several
  would break by-the-book changesets the moment a sibling index
  appears. With zero or several candidates the conventional derived
  `"<table>_<cols>_index"` name is emitted instead, exactly as before
  the lookup existed.

  An expression unique index is the one case SQLite names directly in
  its message, and that name is emitted as reported — the lookup
  never runs. A table that carries both an expression unique index
  and a plain unique index over the same value can violate both in
  one statement, and SQLite reports whichever it checked first. A
  changeset on such a table must declare both names (one
  `unique_constraint/3` per name) to convert either outcome.

  The lookup runs on the caller's checked-out connection inside the
  caller's timeout, so its work is bounded three ways: one
  `index_info` read per unique index on the table; refused outright
  past 24 of them (`{:unavailable, {:too_many_unique_indexes, n}}`);
  and a wall-clock budget equal to the connection's `busy_timeout`,
  checked before every read
  (`{:unavailable, {:lookup_budget_exceeded, elapsed_ms}}`). A zero
  `busy_timeout` disables the wall-clock budget rather than allotting
  no time: reads that cannot block need no time cap, and the 24-index
  cap alone bounds the work. A single
  read can still block for up to `busy_timeout` when another process
  holds a write lock on a rollback-journal database — the same worst
  case any statement pays under that contention; WAL databases do not
  block these reads. Past the cap or the budget the emitted name
  reverts to the conventional derived one, so a changeset that
  declares a custom index name on such a table must declare the
  derived name too.

  Both pragmas are fallible. Any failure leaves the names empty and
  records `{:unavailable, reason}`; the conventional derived name
  then applies exactly as it did before. The names are read after the
  statement failed, so concurrent DDL (an index renamed, a table
  rebuilt) can make them reflect the schema as of the read rather
  than as of the violation.
  """

  alias XqliteEcto3.Error
  alias XqliteEcto3.Error.Constraint
  alias XqliteNIF, as: NIF

  @max_candidate_lookups 24

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

  @doc false
  @spec within_budget?(integer(), non_neg_integer(), integer()) :: boolean()
  def within_budget?(_started_at_ms, 0, _now_ms), do: true

  def within_budget?(started_at_ms, budget_ms, now_ms) do
    now_ms - started_at_ms <= budget_ms
  end

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
    case busy_budget(conn) do
      {:ok, budget_ms} -> listed_candidates(conn, table, columns, budget_ms)
      {:error, _reason} = err -> err
    end
  end

  defp listed_candidates(conn, table, columns, budget_ms) do
    started_at_ms = System.monotonic_time(:millisecond)

    case NIF.query(conn, "PRAGMA index_list(#{quote_ident(table)})", []) do
      {:ok, %{rows: rows}} ->
        rows
        |> Enum.flat_map(&unique_index/1)
        |> capped_matching_indexes(conn, columns, started_at_ms, budget_ms)

      {:error, _reason} = err ->
        err
    end
  end

  # The budget equals the connection's busy timeout: one blocked read
  # already costs that much, so the budget stops further reads from
  # multiplying the price across every candidate. A zero timeout means
  # reads cannot block, so there is no price to multiply — zero disables
  # the wall-clock check entirely (it must not mean "no time at all");
  # the candidate cap alone bounds the work.
  defp busy_budget(conn) do
    case NIF.query(conn, "PRAGMA busy_timeout", []) do
      {:ok, %{rows: [[ms] | _]}} when is_integer(ms) and ms >= 0 -> {:ok, ms}
      {:ok, _unexpected_shape} -> {:ok, 0}
      {:error, _reason} = err -> err
    end
  end

  # The lookup bills its cost to the caller's checkout deadline, so the
  # per-index reads must stay bounded no matter what the schema holds.
  defp capped_matching_indexes(names, conn, columns, started_at_ms, budget_ms) do
    count = length(names)

    if count > @max_candidate_lookups do
      {:error, {:too_many_unique_indexes, count}}
    else
      matching_indexes(names, conn, columns, started_at_ms, budget_ms)
    end
  end

  # index_list columns: seq, name, unique, origin, partial. Autoindexes
  # (origin "u" and "pk") count as candidates so a named sibling cannot
  # be blamed for a violation the autoindex caused.
  defp unique_index([_seq, name, 1, origin | _])
       when is_binary(name) and origin in ["c", "u", "pk"], do: [name]

  defp unique_index(_row), do: []

  defp matching_indexes(names, conn, columns, started_at_ms, budget_ms) do
    names
    |> Enum.reduce_while({:ok, []}, fn name, acc ->
      collect_match(conn, columns, name, acc, started_at_ms, budget_ms)
    end)
    |> deduplicate()
  end

  defp collect_match(conn, columns, name, {:ok, acc}, started_at_ms, budget_ms) do
    now_ms = System.monotonic_time(:millisecond)

    case within_budget?(started_at_ms, budget_ms, now_ms) do
      true -> budgeted_match(conn, columns, name, acc)
      false -> {:halt, {:error, {:lookup_budget_exceeded, now_ms - started_at_ms}}}
    end
  end

  defp budgeted_match(conn, columns, name, acc) do
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
