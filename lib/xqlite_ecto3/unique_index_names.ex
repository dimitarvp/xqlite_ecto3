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

  This module reads back what the message left out, on the error path,
  where the failed statement still holds the connection.

  ## The `table.column` form

  1. `SELECT schema FROM pragma_table_list WHERE name = ?` — which
     database holds the violated table. No row means the name the
     message was split into is not a table at all; more than one row
     means an attached database or the temp schema holds a table of
     the same name, and an unqualified pragma could answer for the
     wrong one (`{:unavailable, {:ambiguous_schema, schemas}}`)
  2. `PRAGMA <schema>.index_list(<table>)` — every index on the table,
     with its unique flag and its origin: `"c"` for `CREATE INDEX`,
     `"u"` for a table-level `UNIQUE`, `"pk"` for the primary key
  3. `PRAGMA <schema>.index_info(<index>)` — the indexed columns, in
     index order

  A unique index whose columns match the violated columns exactly is
  a candidate, whatever its origin. `sqlite_autoindex_*` names — the
  backing indexes of table-level `UNIQUE` and `PRIMARY KEY` — are
  recorded like any other candidate (the `sqlite_` prefix is reserved
  by SQLite, so they are unmistakable), but they are never emitted as
  a constraint name: no changeset declares them, so a lone autoindex
  candidate falls back to the conventional derived name.

  ## The `index 'name'` form

  The name SQLite reported is the one emitted, but the message carries
  neither the table nor the columns, so both are read back: the index's
  table from `sqlite_schema`, its columns from `PRAGMA index_info` —
  every one of them `nil`, since an indexed expression has no column
  name — and the table's other unique indexes from `PRAGMA
  index_list`. Only the `main` schema is searched on this path.

  ## When the lookup will not name one index

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

  An expression index can be neither confirmed nor ruled out: its
  columns read back as `nil`, which equals no violated column list, so
  there is nothing to compare it against. A violation on a table that
  carries one, plus at least one other unique index, therefore reports
  `unique_index_lookup: {:ambiguous, names}` with every candidate —
  whichever of the two message forms it took. Which of the two you get
  is itself not a property of the schema: when an expression index and
  a plain one are both violated, SQLite names the later-created of the
  two. A changeset on such a table needs one `unique_constraint/3` per
  name it wants converted, the derived name included.

  ## Two ways a violation message can mislead

  SQLite writes the `table.column` form by joining the table and each
  column with `"."` and the columns with `", "`, and it quotes
  nothing, so a table or column name holding one of those separators
  comes apart somewhere else. The pieces can name a real, unrelated
  table whose index would then be reported as the violated one. The
  lookup counts the separators the parsed table and columns account
  for — one `"."` per column, one `", "` between each pair — and
  refuses to read anything when the count does not match, or when the
  parsed table exists in no schema: `{:unavailable,
  {:unparseable_violation_table, message}}`. This is conservative in
  both directions: a column name holding a `"."` degrades a parse that
  happened to be right. What it does not catch is a double
  coincidence — a garbled name that lands on another real table which
  also carries a unique index over exactly the garbled column list;
  that index's name would be emitted.

  ## Bounds

  The lookup runs on the caller's checked-out connection inside the
  caller's timeout, so its work is bounded four ways: one
  `pragma_table_list` read plus 1 + N index reads (one `index_list`,
  then one `index_info` per unique index on the table); refused
  outright past 24 of them
  (`{:unavailable, {:too_many_unique_indexes, n}}`); a wall-clock
  allowance, `:diagnostics_budget_ms` from the repo configuration
  (500 ms unless set), checked before every index read
  (`{:unavailable, {:lookup_budget_exceeded, elapsed_ms}}`); and the
  statement's own remaining timeout, which skips the lookup entirely
  when less of it is left than the allowance would spend
  (`{:unavailable, {:deadline_near, remaining_ms}}`). An allowance of
  `0` turns the lookup off: nothing is read and the result is
  `{:unavailable, :diagnostics_disabled}`.

  None of that bounds a single read: when another process holds a
  write lock on a rollback-journal database, one read can block for up
  to `busy_timeout` — the same worst case any statement pays under
  that contention, and nothing cancels it. WAL databases do not block
  these reads. Past the cap or the allowance the emitted name reverts
  to the conventional derived one, so a changeset that declares a
  custom index name on such a table must declare the derived name too.

  A lookup that reads reports the
  `[:xqlite_ecto3, :unique_index_names]` telemetry span, so its cost
  is measurable on its own instead of hidden inside the statement that
  failed.

  Every read is fallible. Any failure leaves the names empty and
  records `{:unavailable, reason}`; the conventional derived name
  then applies exactly as it did before. The names are read after the
  statement failed, so concurrent DDL (an index renamed, a table
  rebuilt) can make them reflect the schema as of the read rather
  than as of the violation.
  """

  import XqliteEcto3.Telemetry, only: [span_with_stop_metadata: 3]

  alias XqliteEcto3.Error
  alias XqliteEcto3.Error.Constraint
  alias XqliteNIF, as: NIF

  @max_candidate_lookups 24

  @no_candidates %{matched: [], expression: []}

  # sqlite_schema names indexes of the main database only, so the
  # reads that follow a name found there stay in main.
  @index_schema "main"

  @typedoc """
  What is left of the statement's own timeout when the lookup starts,
  in milliseconds. `:infinity` for a statement that had no timeout.
  """
  @type remaining_ms :: integer() | :infinity

  @doc """
  Fills in `unique_index_names` on a UNIQUE violation, and `table` and
  `columns` on the form that carries neither, spending at most
  `budget_ms` on the reads and skipping them when less than
  `budget_ms` of the statement's own deadline is left.

  Every other error passes through untouched.
  """
  @spec resolve(Error.t(), Xqlite.conn(), non_neg_integer(), remaining_ms()) :: Error.t()
  def resolve(error, conn, budget_ms, remaining_ms \\ :infinity)

  def resolve(%Error{details: %Constraint{} = details} = error, conn, budget_ms, remaining_ms) do
    %{error | details: resolve_details(details, conn, budget_ms, remaining_ms)}
  end

  def resolve(error, _conn, _budget_ms, _remaining_ms), do: error

  @doc false
  @spec within_budget?(integer(), non_neg_integer(), integer()) :: boolean()
  def within_budget?(started_at_ms, budget_ms, now_ms) do
    now_ms - started_at_ms <= budget_ms
  end

  defp resolve_details(
         %Constraint{
           subtype: :constraint_unique,
           index_name: nil,
           table: table,
           columns: [_ | _] = columns,
           message: message
         } = details,
         conn,
         budget_ms,
         remaining_ms
       )
       when is_binary(table) do
    case allowance(budget_ms, remaining_ms) do
      :run -> recorded(details, from_columns(conn, table, columns, message, budget_ms))
      {:skip, reason} -> %{details | unique_index_lookup: {:unavailable, reason}}
    end
  end

  defp resolve_details(
         %Constraint{subtype: :constraint_unique, index_name: index_name, table: nil} = details,
         conn,
         budget_ms,
         remaining_ms
       )
       when is_binary(index_name) do
    case allowance(budget_ms, remaining_ms) do
      :run -> recorded(details, from_index(conn, index_name, budget_ms))
      {:skip, reason} -> %{details | unique_index_lookup: {:unavailable, reason}}
    end
  end

  defp resolve_details(details, _conn, _budget_ms, _remaining_ms), do: details

  # The lookup bills its reads to the caller who is still waiting on
  # the statement that failed, so a deadline with less left than the
  # allowance would spend buys nothing and is not started.
  defp allowance(0, _remaining_ms), do: {:skip, :diagnostics_disabled}

  defp allowance(budget_ms, remaining_ms)
       when is_integer(remaining_ms) and remaining_ms < budget_ms do
    {:skip, {:deadline_near, remaining_ms}}
  end

  defp allowance(_budget_ms, _remaining_ms), do: :run

  defp recorded(details, {:ok, names}) do
    %{details | unique_index_names: names, unique_index_lookup: :ok}
  end

  defp recorded(details, {:ambiguous, names}) do
    %{details | unique_index_names: names, unique_index_lookup: {:ambiguous, names}}
  end

  defp recorded(details, {:indexed, table, columns, status}) do
    recorded(%{details | table: table, columns: columns}, status)
  end

  defp recorded(details, {:error, reason}) do
    %{details | unique_index_lookup: {:unavailable, reason}}
  end

  defp looked_up(start_md, work) do
    span_with_stop_metadata [:xqlite_ecto3, :unique_index_names], start_md do
      {result, index_reads} = work.()

      {result, Map.merge(start_md, stop_metadata(result, index_reads))}
    end
  end

  defp stop_metadata({:indexed, _table, _columns, status}, index_reads) do
    stop_metadata(status, index_reads)
  end

  defp stop_metadata({:ok, names}, index_reads) do
    %{lookup_status: :ok, candidate_count: length(names), index_reads: index_reads}
  end

  defp stop_metadata({:ambiguous, names}, index_reads) do
    %{lookup_status: :ambiguous, candidate_count: length(names), index_reads: index_reads}
  end

  defp stop_metadata({:error, _reason}, index_reads) do
    %{lookup_status: :unavailable, candidate_count: 0, index_reads: index_reads}
  end

  defp from_columns(conn, table, columns, message, budget_ms) do
    start_md = %{conn: conn, table: table, columns: columns}

    looked_up(start_md, fn -> candidates(conn, table, columns, message, budget_ms) end)
  end

  defp candidates(conn, table, columns, message, budget_ms) do
    started_at_ms = System.monotonic_time(:millisecond)

    case violated_schema(conn, table, columns, message) do
      {:ok, schema} ->
        read = %{conn: conn, schema: schema, columns: columns, budget_ms: budget_ms}
        listed_indexes(read, table, started_at_ms)

      {:error, _reason} = err ->
        {err, 0}
    end
  end

  defp violated_schema(conn, table, columns, message) do
    case parseable?(message, columns) do
      true -> table_schema(conn, table, message)
      false -> {:error, {:unparseable_violation_table, message}}
    end
  end

  # One "." joins the table to each column, one ", " sits between each
  # pair of columns. A different count means the message did not come
  # apart the way the parse that produced `columns` assumed.
  defp parseable?(message, columns) when is_binary(message) do
    count = length(columns)

    separators(message, ".") == count and separators(message, ", ") == count - 1
  end

  defp parseable?(_message, _columns), do: false

  defp separators(message, separator) do
    parts = String.split(message, separator)
    length(parts) - 1
  end

  defp table_schema(conn, table, message) do
    case NIF.query(conn, "SELECT schema FROM pragma_table_list WHERE name = ?", [table]) do
      {:ok, %{rows: rows}} -> one_schema(schema_names(rows), message)
      {:error, _reason} = err -> err
    end
  end

  defp schema_names(rows), do: Enum.flat_map(rows, &schema_name/1)

  defp schema_name([schema | _rest]) when is_binary(schema), do: [schema]
  defp schema_name(_row), do: []

  defp one_schema([schema], _message), do: {:ok, schema}
  defp one_schema([], message), do: {:error, {:unparseable_violation_table, message}}
  defp one_schema(schemas, _message), do: {:error, {:ambiguous_schema, schemas}}

  defp listed_indexes(read, table, started_at_ms) do
    case unique_indexes(read.conn, read.schema, table) do
      {:ok, names} -> capped_matching_indexes(names, read, started_at_ms)
      {:error, _reason} = err -> {err, 1}
    end
  end

  # The lookup bills its cost to the caller's checkout deadline, so the
  # per-index reads must stay bounded no matter what the schema holds.
  defp capped_matching_indexes(names, read, started_at_ms) do
    count = length(names)

    if count > @max_candidate_lookups do
      {{:error, {:too_many_unique_indexes, count}}, 1}
    else
      matching_indexes(names, read, started_at_ms)
    end
  end

  # The read tally rides along with the result so the span can report
  # how many index reads the lookup really made before it stopped; the
  # index_list read that produced these names is the first of them.
  defp matching_indexes(names, read, started_at_ms) do
    {result, index_reads} =
      Enum.reduce_while(names, {{:ok, @no_candidates}, 1}, fn name, acc ->
        collect_match(read, name, acc, started_at_ms)
      end)

    {status(result), index_reads}
  end

  defp collect_match(read, name, {{:ok, acc}, index_reads}, started_at_ms) do
    now_ms = System.monotonic_time(:millisecond)

    case within_budget?(started_at_ms, read.budget_ms, now_ms) do
      true ->
        counted_match(read, name, acc, index_reads)

      false ->
        {:halt, {{:error, {:lookup_budget_exceeded, now_ms - started_at_ms}}, index_reads}}
    end
  end

  defp counted_match(read, name, acc, index_reads) do
    case budgeted_match(read.conn, read.schema, read.columns, name, acc) do
      {:cont, result} -> {:cont, {result, index_reads + 1}}
      {:halt, result} -> {:halt, {result, index_reads + 1}}
    end
  end

  # Zero index_info rows means the index vanished between the two
  # pragma reads (concurrent DDL) — index_info on a missing name
  # returns empty, not an error. Silently subtracting it would change
  # the candidate count, which the emission rule keys on, flipping the
  # emitted name mid-race. Degrade to the derived name instead. (A
  # real index always has rows; an indexed expression's rows carry a
  # nil column name, not zero rows.)
  @doc false
  def budgeted_match(conn, schema, columns, name, acc) do
    case index_columns(conn, schema, name) do
      {:ok, ^columns} -> {:cont, {:ok, matched(acc, name)}}
      {:ok, []} -> {:halt, {:error, {:index_vanished, name}}}
      {:ok, other_columns} -> {:cont, {:ok, unmatched(acc, name, other_columns)}}
      {:error, _reason} = err -> {:halt, err}
    end
  end

  defp matched(acc, name), do: %{acc | matched: [name | acc.matched]}

  # An index carrying an indexed expression reports no name for it, so
  # it matches no violated column list and cannot be ruled out either.
  # Every other index covers columns that are not the violated ones and
  # provably did not fire.
  defp unmatched(acc, name, columns) do
    case Enum.any?(columns, &is_nil/1) do
      true -> %{acc | expression: [name | acc.expression]}
      false -> acc
    end
  end

  defp status({:ok, %{matched: matched, expression: []}}), do: {:ok, sorted(matched)}

  defp status({:ok, %{matched: matched, expression: expression}}) do
    {:ambiguous, sorted(matched ++ expression)}
  end

  defp status({:error, _reason} = err), do: err

  defp from_index(conn, index_name, budget_ms) do
    start_md = %{conn: conn, table: nil, columns: []}

    looked_up(start_md, fn -> named_index(conn, index_name, budget_ms) end)
  end

  defp named_index(conn, index_name, budget_ms) do
    started_at_ms = System.monotonic_time(:millisecond)

    case index_table(conn, index_name) do
      {:ok, table} -> named_index_columns(conn, index_name, table, started_at_ms, budget_ms)
      {:error, _reason} = err -> {err, 0}
    end
  end

  defp named_index_columns(conn, index_name, table, started_at_ms, budget_ms) do
    case budgeted_columns(conn, index_name, started_at_ms, budget_ms) do
      {:ok, columns} ->
        named_index_siblings(conn, index_name, table, columns, started_at_ms, budget_ms)

      {:error, _reason} = err ->
        {err, 1}
    end
  end

  defp named_index_siblings(conn, index_name, table, columns, started_at_ms, budget_ms) do
    case budgeted_siblings(conn, table, started_at_ms, budget_ms) do
      {:ok, names} -> {{:indexed, table, columns, index_status([index_name | names])}, 2}
      {:error, _reason} = err -> {err, 2}
    end
  end

  # Nothing on this path can be compared with anything: the reported
  # index covers an expression, and the message named no columns to
  # rule its siblings out with.
  defp index_status(names) do
    case sorted(names) do
      [only] -> {:ok, [only]}
      candidates -> {:ambiguous, candidates}
    end
  end

  defp index_table(conn, index_name) do
    sql = "SELECT tbl_name FROM sqlite_schema WHERE type = 'index' AND name = ?"

    case NIF.query(conn, sql, [index_name]) do
      {:ok, %{rows: [[table | _rest] | _more]}} when is_binary(table) -> {:ok, table}
      {:ok, %{rows: _rows}} -> {:error, {:unknown_index, index_name}}
      {:error, _reason} = err -> err
    end
  end

  defp budgeted_columns(conn, index_name, started_at_ms, budget_ms) do
    case budget_left(started_at_ms, budget_ms) do
      :ok -> present_columns(conn, index_name)
      {:error, _reason} = err -> err
    end
  end

  defp present_columns(conn, index_name) do
    case index_columns(conn, @index_schema, index_name) do
      {:ok, []} -> {:error, {:index_vanished, index_name}}
      {:ok, columns} -> {:ok, columns}
      {:error, _reason} = err -> err
    end
  end

  defp budgeted_siblings(conn, table, started_at_ms, budget_ms) do
    case budget_left(started_at_ms, budget_ms) do
      :ok -> unique_indexes(conn, @index_schema, table)
      {:error, _reason} = err -> err
    end
  end

  defp budget_left(started_at_ms, budget_ms) do
    now_ms = System.monotonic_time(:millisecond)

    case within_budget?(started_at_ms, budget_ms, now_ms) do
      true -> :ok
      false -> {:error, {:lookup_budget_exceeded, now_ms - started_at_ms}}
    end
  end

  defp unique_indexes(conn, schema, table) do
    sql = "PRAGMA #{quote_ident(schema)}.index_list(#{quote_ident(table)})"

    case NIF.query(conn, sql, []) do
      {:ok, %{rows: rows}} -> {:ok, Enum.flat_map(rows, &unique_index/1)}
      {:error, _reason} = err -> err
    end
  end

  # index_list columns: seq, name, unique, origin, partial. Autoindexes
  # (origin "u" and "pk") count as candidates so a named sibling cannot
  # be blamed for a violation the autoindex caused.
  defp unique_index([_seq, name, 1, origin | _])
       when is_binary(name) and origin in ["c", "u", "pk"], do: [name]

  defp unique_index(_row), do: []

  defp index_columns(conn, schema, index_name) do
    sql = "PRAGMA #{quote_ident(schema)}.index_info(#{quote_ident(index_name)})"

    case NIF.query(conn, sql, []) do
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

  # Sorted so the same schema always maps to the same constraint list.
  defp sorted(names) do
    names
    |> Enum.uniq()
    |> Enum.sort()
  end

  defp quote_ident(name) do
    "\"" <> String.replace(name, "\"", "\"\"") <> "\""
  end
end
