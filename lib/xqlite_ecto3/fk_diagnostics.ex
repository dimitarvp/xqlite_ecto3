defmodule XqliteEcto3.FkDiagnostics do
  @moduledoc """
  Opt-in rich foreign-key diagnostics (`rich_fk_diagnostics: true`
  repo config).

  SQLite reports FK violations as a bare "FOREIGN KEY constraint
  failed" with no table, column, or constraint name — and
  `PRAGMA foreign_key_check` cannot see an immediately-rejected row
  because it was never inserted. This module recovers the details by
  replaying the failed statement under deferred enforcement inside a
  throwaway savepoint:

  1. `SAVEPOINT` (reserved name, distinct from the driver's managed
     stack)
  2. `PRAGMA defer_foreign_keys = ON` — the replayed statement now
     succeeds, so its violating rows exist inside the savepoint
  3. `PRAGMA foreign_key_check` — the BASELINE: rows already
     violating before the statement (orphans written under
     `foreign_keys: false`, or by any tool with enforcement off —
     SQLite's own default). `foreign_key_check` scans the whole
     database, so without this the statement would be blamed for
     every pre-existing orphan anywhere in the file
  4. Replay the statement, then `PRAGMA foreign_key_check` again —
     the statement's own violations are what the second scan holds
     beyond the first, counted per `{child table, fk id}`. A
     `WITHOUT ROWID` child reports a `nil` rowid for every violation
     of its, so its rows are byte-identical and only their number
     moves: counting recovers the new one that matching the rows one
     by one would hide. When no group grew — a rowid reused after its
     orphan was replaced reproduces the orphan's row exactly — the
     diagnosis is `{:unavailable, :masked_by_baseline}`, never an
     empty result. At most 24 violations are materialized; more sets
     `fk_diagnostics: {:truncated, total}` with the first 24 kept
  5. `PRAGMA foreign_key_list(child)` — resolves each FK index to
     the exact child/parent columns
  6. Roll the savepoint back and explicitly reset
     `defer_foreign_keys` — inside a long-lived outer transaction
     (e.g. `Ecto.Adapters.SQL.Sandbox`) it would otherwise stay on
     until that transaction ends

  Commit-time FK failures (a transaction the caller deferred
  themselves) skip the replay: the violating rows still exist while
  the transaction is open, so the check and resolve steps run
  directly — with NO baseline: there is no pre-transaction snapshot
  to diff against, so pre-existing orphans anywhere in the database
  will appear among the reported violations on this path.

  Every step is preceded by a clock reading against
  `:diagnostics_budget_ms` from the repo configuration (500 ms unless
  set), so the whole chain costs at most that allowance plus the one
  step already in flight; a spent allowance degrades the diagnosis to
  `{:unavailable, {:diagnostics_budget_exceeded, elapsed_ms}}`. An
  allowance of `0` skips the replay altogether
  (`{:unavailable, :diagnostics_disabled}`), and so does a statement
  whose own timeout has less left than the allowance would spend
  (`{:unavailable, {:deadline_near, remaining_ms}}`) — the caller is
  waiting on that timeout, and nothing cancels a step once it blocks.

  Cost under write contention: the replay is a WRITE, so unlike the
  read-only unique-index-name lookup it contends for WAL's single
  write lock. With another writer holding the database, one step of
  the replay can block for up to a full `busy_timeout` on top of the
  failing statement's own busy wait before degrading — the allowance
  does not bound a step that has already started, so the operation can
  outstay its own `:timeout`, and through a pool DBConnection's
  checkout deadline then drops the connection with nothing said to the
  caller. Cost in table size:
  `foreign_key_check` scans every FK-bearing table in the database,
  and the replay runs it twice (the baseline and the post-statement
  read), so the diagnosed error path is linear in total rows —
  measured ~36 ms at 200k child rows against ~0.1 ms with the flag
  off. This runs only after a violation and only under
  `rich_fk_diagnostics: true`.

  One side effect survives the replay: SQLite does not undo
  `last_insert_rowid()` on rollback, so after a replay the connection
  reports the rowid of the rolled-back phantom row until the next
  successful insert. The adapter itself never reads it (inserts use
  `RETURNING`), but raw SQL or `with_xqlite/3` callers checking it
  after a failed insert will see the phantom value.

  Every step is fallible; any failure degrades to the original blind
  error with `fk_diagnostics: {:unavailable, reason}` — the diagnosis
  never masks or replaces the error it is diagnosing.

  Violations are sorted by `{child_table, fk_id, child_rowid}` so the
  output is deterministic for a given database state.
  """

  import XqliteEcto3.Telemetry, only: [span_with_stop_metadata: 3]

  alias XqliteEcto3.Error
  alias XqliteEcto3.Error.{Constraint, FkViolation}
  alias XqliteNIF, as: NIF

  # Reserved name, never collides with the driver's managed stack
  # ("xqlite_sp_<random prefix>_<n>") or plausible user savepoints.
  @diag_savepoint "xqlite_fk_diag"

  @doc """
  Wraps `reason` into an `XqliteEcto3.Error`, enriching FK constraint
  violations by replaying `sql`/`params` under deferred enforcement.

  Non-FK reasons wrap exactly as `XqliteEcto3.Error.wrap/1` would.
  """
  @spec wrap_with_replay(
          term(),
          Xqlite.conn(),
          String.t(),
          list(),
          non_neg_integer(),
          integer() | :infinity
        ) :: Error.t()
  def wrap_with_replay(reason, conn, sql, params, budget_ms, remaining_ms \\ :infinity)

  def wrap_with_replay(
        {:constraint_violation, :constraint_foreign_key, _} = reason,
        conn,
        sql,
        params,
        budget_ms,
        remaining_ms
      ) do
    collect_fun = fn deadline -> replay(conn, sql, params, deadline) end

    enrich(Error.wrap(reason), collect_fun, conn, :replay, {budget_ms, remaining_ms})
  end

  def wrap_with_replay(reason, _conn, _sql, _params, _budget_ms, _remaining_ms) do
    Error.wrap(reason)
  end

  @doc """
  Wraps a commit-time `reason`, enriching FK constraint violations by
  reading the still-open transaction's state directly — the violating
  rows exist until the rollback, so no replay is needed.

  This path reports more than the transaction's own violations. The
  replay path diffs two `PRAGMA foreign_key_check` scans, so it can
  subtract what the database already held; a commit has no
  pre-transaction scan to subtract. Every FK violation anywhere in the
  database is therefore reported here — orphans of any table, written
  by anything that had `foreign_keys` off, SQLite's own default
  included — beside the ones the committing transaction really
  deferred. A baseline taken when the transaction opened would not fix
  it either: `PRAGMA defer_foreign_keys = ON` is a raw statement the
  caller runs mid-transaction, so at `BEGIN` there is nothing yet to
  say a baseline will be needed.

  `remaining_ms` defaults to `:infinity`, and the driver passes it only
  for a `COMMIT` the caller ran as raw SQL. The commit DBConnection
  itself issues at the end of `Repo.transaction/2` has no statement
  deadline to pass, so this diagnosis runs there with the configured
  allowance alone.
  """
  @spec wrap_at_commit(term(), Xqlite.conn(), non_neg_integer(), integer() | :infinity) ::
          Error.t()
  def wrap_at_commit(reason, conn, budget_ms, remaining_ms \\ :infinity)

  def wrap_at_commit(
        {:constraint_violation, :constraint_foreign_key, _} = reason,
        conn,
        budget_ms,
        remaining_ms
      ) do
    collect_fun = fn deadline -> collect_violations(conn, deadline) end

    enrich(Error.wrap(reason), collect_fun, conn, :in_transaction, {budget_ms, remaining_ms})
  end

  def wrap_at_commit(reason, _conn, _budget_ms, _remaining_ms), do: Error.wrap(reason)

  defp enrich(%Error{details: %Constraint{} = details} = error, collect_fun, conn, mode, budget) do
    %{error | details: diagnose(details, collect_fun, conn, mode, budget)}
  end

  defp diagnose(details, collect_fun, conn, mode, allowance) do
    case runnable(allowance) do
      {:run, budget_ms} -> spanned(details, collect_fun, conn, mode, budget_ms)
      {:skip, reason} -> %{details | fk_diagnostics: {:unavailable, reason}}
    end
  end

  # The diagnosis bills its reads and its replay write to the caller
  # who is still waiting on the statement that failed, so a deadline
  # with less left than the allowance would spend buys nothing.
  defp runnable({0, _remaining_ms}), do: {:skip, :diagnostics_disabled}

  defp runnable({budget_ms, remaining_ms})
       when is_integer(remaining_ms) and remaining_ms < budget_ms do
    {:skip, {:deadline_near, remaining_ms}}
  end

  defp runnable({budget_ms, _remaining_ms}), do: {:run, budget_ms}

  defp spanned(details, collect_fun, conn, mode, budget_ms) do
    start_md = %{conn: conn, mode: mode}
    deadline = {System.monotonic_time(:millisecond), budget_ms}

    {status, violations} =
      span_with_stop_metadata [:xqlite_ecto3, :fk_diagnostics], start_md do
        {status, violations} = run_collect(collect_fun, deadline)

        stop_md =
          Map.merge(start_md, %{
            violations_count: length(violations),
            violations_total: violations_total(status, violations),
            diagnostics_status: diag_tag(status)
          })

        {{status, violations}, stop_md}
      end

    %{details | fk_violations: violations, fk_diagnostics: status}
  end

  defp run_collect(collect_fun, deadline) do
    case collect_fun.(deadline) do
      {:error, reason} -> {{:unavailable, reason}, []}
      {status, violations} -> {status, violations}
    end
  end

  # The diagnosis is a chain of reads and each one can block on another
  # connection's write lock, so the clock is read before every step: the
  # whole chain then costs at most the allowance plus the one read that
  # was already in flight.
  defp within_budget({started_at_ms, budget_ms}) do
    elapsed_ms = System.monotonic_time(:millisecond) - started_at_ms

    case elapsed_ms <= budget_ms do
      true -> :ok
      false -> {:error, {:diagnostics_budget_exceeded, elapsed_ms}}
    end
  end

  defp diag_tag(:ok), do: :ok
  defp diag_tag({:truncated, _}), do: :truncated
  defp diag_tag({:unavailable, _}), do: :unavailable

  # The stop event's honest count: how many violations really existed,
  # not how many the cap let through — a consumer summing
  # violations_count would otherwise undercount with no way to recover
  # the total the error struct carries.
  defp violations_total({:truncated, total}, _violations), do: total
  defp violations_total(_status, violations), do: length(violations)

  defp replay(conn, sql, params, deadline) do
    result =
      with :ok <- NIF.savepoint(conn, @diag_savepoint),
           {:ok, _} <- NIF.set_pragma(conn, "defer_foreign_keys", true),
           :ok <- within_budget(deadline),
           {:ok, %{rows: baseline}} <- NIF.query(conn, "PRAGMA foreign_key_check", []),
           :ok <- within_budget(deadline),
           {:ok, _} <- NIF.query_with_changes(conn, sql, params) do
        collect_violations(conn, deadline, baseline)
      end

    cleanup(conn)
    result
  end

  # Best-effort: every step may fail (e.g. the savepoint was never
  # created because that first step failed) and that is fine — the
  # original error is already in hand. The explicit defer reset is
  # load-bearing inside a long-lived outer transaction.
  defp cleanup(conn) do
    _ = NIF.rollback_to_savepoint(conn, @diag_savepoint)
    _ = NIF.release_savepoint(conn, @diag_savepoint)
    _ = NIF.set_pragma(conn, "defer_foreign_keys", false)
    :ok
  end

  @violation_cap 24

  defp collect_violations(conn, deadline, baseline \\ []) do
    with :ok <- within_budget(deadline),
         {:ok, %{rows: check_rows}} <- NIF.query(conn, "PRAGMA foreign_key_check", []),
         fresh = fresh_rows(check_rows, baseline),
         :ok <- unmasked(fresh, check_rows),
         {kept, status} = cap_rows(fresh),
         {:ok, fk_defs} <- fk_definitions(conn, deadline, kept) do
      violations =
        kept
        |> Enum.map(fn row -> build_violation(row, fk_defs) end)
        |> Enum.sort_by(fn v -> {v.child_table, v.fk_id, v.child_rowid} end)

      {status, violations}
    end
  end

  # What the second scan holds beyond the first, counted per {child
  # table, fk id}. A WITHOUT ROWID child reports a nil rowid for every
  # violation of its, so its rows are byte-identical and only their
  # number moves — matching rows one by one would find nothing new and
  # hide the statement's own violation. Rows the baseline never held are
  # taken first, so a rowid reused after its orphan was replaced fills
  # its group's quota with the pre-existing row and reports nothing.
  defp fresh_rows(check_rows, baseline) do
    quotas = surplus_quotas(check_rows, baseline)
    unseen = MapSet.difference(MapSet.new(check_rows), MapSet.new(baseline))
    {novel, repeated} = Enum.split_with(check_rows, fn row -> MapSet.member?(unseen, row) end)
    {rows, _left} = Enum.reduce(novel ++ repeated, {[], quotas}, &take_within_quota/2)

    Enum.reverse(rows)
  end

  defp surplus_quotas(check_rows, baseline) do
    baseline_counts = Enum.frequencies_by(baseline, &violation_group/1)
    check_counts = Enum.frequencies_by(check_rows, &violation_group/1)

    Enum.reduce(check_counts, %{}, fn pair, acc -> put_surplus(pair, baseline_counts, acc) end)
  end

  defp put_surplus({group, count}, baseline_counts, acc) do
    Map.put(acc, group, max(count - Map.get(baseline_counts, group, 0), 0))
  end

  defp take_within_quota(row, {kept, quotas}) do
    group = violation_group(row)

    case Map.get(quotas, group, 0) do
      0 -> {kept, quotas}
      left -> {[row | kept], Map.put(quotas, group, left - 1)}
    end
  end

  # foreign_key_check columns: table (child), rowid, parent, fkid. A row
  # of any other shape is its own group; the reader below reports it.
  defp violation_group([child_table, _rowid, _parent, fk_id | _]), do: {child_table, fk_id}
  defp violation_group(row), do: row

  # An empty surplus over a non-empty check means every group the replay
  # found already held as many violations before the statement ran, so
  # the statement's own violation cannot be told apart from them.
  defp unmasked([], [_ | _]), do: {:error, :masked_by_baseline}
  defp unmasked(_fresh, _check_rows), do: :ok

  defp cap_rows(fresh) do
    total = length(fresh)

    if total > @violation_cap do
      {Enum.take(fresh, @violation_cap), {:truncated, total}}
    else
      {fresh, :ok}
    end
  end

  # One foreign_key_list call per distinct child table; fkid maps to
  # that pragma's `id` column. Multi-column FKs span several rows that
  # share an id and are ordered by seq.
  defp fk_definitions(conn, deadline, check_rows) do
    with {:ok, child_tables} <- child_tables(check_rows) do
      Enum.reduce_while(child_tables, {:ok, %{}}, fn child_table, {:ok, acc} ->
        case fk_definitions_of(conn, deadline, child_table) do
          {:ok, grouped} -> {:cont, {:ok, Map.put(acc, child_table, grouped)}}
          {:error, reason} -> {:halt, {:error, reason}}
        end
      end)
    end
  end

  defp fk_definitions_of(conn, deadline, child_table) do
    sql = "PRAGMA foreign_key_list(#{quote_ident(child_table)})"

    with :ok <- within_budget(deadline),
         {:ok, %{rows: rows}} <- NIF.query(conn, sql, []) do
      group_fk_rows(rows)
    end
  end

  # foreign_key_check columns: table (child), rowid, parent, fkid. A row of
  # any other shape means the pragma is not what this code was written
  # against — report it as an unavailable diagnosis instead of crashing the
  # error path that is already handling a violation.
  defp child_tables(check_rows) do
    result =
      Enum.reduce_while(check_rows, {:ok, []}, fn
        [child_table, _rowid, _parent, _fkid], {:ok, acc} -> {:cont, {:ok, [child_table | acc]}}
        row, {:ok, _acc} -> {:halt, {:error, {:unexpected_check_row, row}}}
      end)

    with {:ok, tables} <- result do
      {:ok, tables |> Enum.reverse() |> Enum.uniq()}
    end
  end

  # foreign_key_list columns: id, seq, table (parent), from, to,
  # on_update, on_delete, match. A row that does not carry the five this
  # reads means the pragma is not what the code was written against —
  # report it the way the foreign_key_check reader does, rather than
  # raising out of an error path that is already handling a violation.
  @doc false
  @spec group_fk_rows([term()]) :: {:ok, map()} | {:error, {:unexpected_fk_row, term()}}
  def group_fk_rows(rows) do
    with {:ok, parsed} <- parse_fk_rows(rows) do
      {:ok, group_parsed_fk_rows(parsed)}
    end
  end

  defp parse_fk_rows(rows) do
    result =
      Enum.reduce_while(rows, {:ok, []}, fn
        [id, seq, parent_table, from, to | _rest], {:ok, acc} ->
          {:cont, {:ok, [{id, seq, parent_table, from, to} | acc]}}

        row, {:ok, _acc} ->
          {:halt, {:error, {:unexpected_fk_row, row}}}
      end)

    with {:ok, parsed} <- result do
      {:ok, Enum.reverse(parsed)}
    end
  end

  defp group_parsed_fk_rows(parsed) do
    parsed
    |> Enum.group_by(fn {id, _seq, _parent_table, _from, _to} -> id end)
    |> Map.new(fn {id, fk_rows} -> {id, fk_definition(fk_rows)} end)
  end

  # Multi-column FKs span several rows sharing an id, ordered by seq.
  defp fk_definition(fk_rows) do
    sorted = Enum.sort_by(fk_rows, fn {_id, seq, _parent_table, _from, _to} -> seq end)

    %{
      parent_table: parent_table(sorted),
      child_columns: Enum.map(sorted, fn {_id, _seq, _parent_table, from, _to} -> from end),
      parent_columns: Enum.map(sorted, fn {_id, _seq, _parent_table, _from, to} -> to end)
    }
  end

  defp parent_table([{_id, _seq, parent_table, _from, _to} | _rest]), do: parent_table

  defp build_violation([child_table, child_rowid, parent_table, fk_id], fk_defs) do
    case get_in(fk_defs, [child_table, fk_id]) do
      %{child_columns: child_cols, parent_columns: parent_cols} ->
        %FkViolation{
          child_table: child_table,
          child_rowid: child_rowid,
          parent_table: parent_table,
          fk_id: fk_id,
          child_columns: child_cols,
          parent_columns: parent_cols,
          constraint_name: synthesize_name(child_table, child_cols)
        }

      nil ->
        # The FK definition vanished between check and list (schema
        # change mid-diagnosis) — report what foreign_key_check gave us.
        %FkViolation{
          child_table: child_table,
          child_rowid: child_rowid,
          parent_table: parent_table,
          fk_id: fk_id,
          child_columns: [],
          parent_columns: [],
          constraint_name: synthesize_name(child_table, [])
        }
    end
  end

  # Ecto's default :name for references/3 is "<table>_<column>_fkey".
  # Mirror it so foreign_key_constraint/3 matches without options.
  defp synthesize_name(child_table, []), do: "#{child_table}_fkey"

  defp synthesize_name(child_table, child_columns) do
    Enum.join([child_table | child_columns] ++ ["fkey"], "_")
  end

  defp quote_ident(name) do
    "\"" <> String.replace(name, "\"", "\"\"") <> "\""
  end
end
