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
  3. `PRAGMA foreign_key_check` — names each violation: child table,
     rowid, parent table, FK index
  4. `PRAGMA foreign_key_list(child)` — resolves the FK index to the
     exact child/parent columns
  5. Roll the savepoint back and explicitly reset
     `defer_foreign_keys` — inside a long-lived outer transaction
     (e.g. `Ecto.Adapters.SQL.Sandbox`) it would otherwise stay on
     until that transaction ends

  Commit-time FK failures (a transaction the caller deferred
  themselves) skip the replay: the violating rows still exist while
  the transaction is open, so steps 3–4 run directly.

  Cost under write contention: the replay is a WRITE, so unlike the
  read-only unique-index-name lookup it contends for WAL's single
  write lock. With another writer holding the database, the replay
  can block for up to a full `busy_timeout` on top of the failing
  statement's own busy wait before degrading — the diagnosed error
  path then costs roughly two busy waits. This runs only after a
  violation and only under `rich_fk_diagnostics: true`.

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
  @spec wrap_with_replay(term(), Xqlite.conn(), String.t(), list()) :: Error.t()
  def wrap_with_replay(
        {:constraint_violation, :constraint_foreign_key, _} = reason,
        conn,
        sql,
        params
      ) do
    enrich(Error.wrap(reason), fn -> replay(conn, sql, params) end, conn, :replay)
  end

  def wrap_with_replay(reason, _conn, _sql, _params), do: Error.wrap(reason)

  @doc """
  Wraps a commit-time `reason`, enriching FK constraint violations by
  reading the still-open transaction's state directly — the violating
  rows exist until the rollback, so no replay is needed.
  """
  @spec wrap_at_commit(term(), Xqlite.conn()) :: Error.t()
  def wrap_at_commit({:constraint_violation, :constraint_foreign_key, _} = reason, conn) do
    enrich(Error.wrap(reason), fn -> collect_violations(conn) end, conn, :in_transaction)
  end

  def wrap_at_commit(reason, _conn), do: Error.wrap(reason)

  defp enrich(%Error{details: %Constraint{} = details} = error, collect_fun, conn, mode) do
    start_md = %{conn: conn, mode: mode}

    {status, violations} =
      span_with_stop_metadata [:xqlite_ecto3, :fk_diagnostics], start_md do
        {status, violations} = run_collect(collect_fun)

        stop_md =
          Map.merge(start_md, %{
            violations_count: length(violations),
            diagnostics_status: diag_tag(status)
          })

        {{status, violations}, stop_md}
      end

    %{error | details: %{details | fk_violations: violations, fk_diagnostics: status}}
  end

  defp run_collect(collect_fun) do
    case collect_fun.() do
      {:ok, violations} -> {:ok, violations}
      {:error, reason} -> {{:unavailable, reason}, []}
    end
  end

  defp diag_tag(:ok), do: :ok
  defp diag_tag({:unavailable, _}), do: :unavailable

  # ---------------------------------------------------------------------------
  # Replay under deferred enforcement
  # ---------------------------------------------------------------------------

  defp replay(conn, sql, params) do
    result =
      with :ok <- NIF.savepoint(conn, @diag_savepoint),
           {:ok, _} <- NIF.set_pragma(conn, "defer_foreign_keys", true),
           {:ok, _} <- NIF.query_with_changes(conn, sql, params) do
        collect_violations(conn)
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

  # ---------------------------------------------------------------------------
  # Violation collection: foreign_key_check + foreign_key_list
  # ---------------------------------------------------------------------------

  defp collect_violations(conn) do
    with {:ok, %{rows: check_rows}} <- NIF.query(conn, "PRAGMA foreign_key_check", []),
         {:ok, fk_defs} <- fk_definitions(conn, check_rows) do
      violations =
        check_rows
        |> Enum.map(fn row -> build_violation(row, fk_defs) end)
        |> Enum.sort_by(fn v -> {v.child_table, v.fk_id, v.child_rowid} end)

      {:ok, violations}
    end
  end

  # One foreign_key_list call per distinct child table; fkid maps to
  # that pragma's `id` column. Multi-column FKs span several rows that
  # share an id and are ordered by seq.
  defp fk_definitions(conn, check_rows) do
    with {:ok, child_tables} <- child_tables(check_rows) do
      Enum.reduce_while(child_tables, {:ok, %{}}, fn child_table, {:ok, acc} ->
        case NIF.query(conn, "PRAGMA foreign_key_list(#{quote_ident(child_table)})", []) do
          {:ok, %{rows: rows}} ->
            {:cont, {:ok, Map.put(acc, child_table, group_fk_rows(rows))}}

          {:error, reason} ->
            {:halt, {:error, reason}}
        end
      end)
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
  # on_update, on_delete, match.
  defp group_fk_rows(rows) do
    rows
    |> Enum.group_by(fn [id | _] -> id end)
    |> Map.new(fn {id, fk_rows} ->
      sorted = Enum.sort_by(fk_rows, fn [_id, seq | _] -> seq end)
      [_, _, parent_table | _] = hd(sorted)
      child_columns = Enum.map(sorted, fn [_, _, _, from | _] -> from end)
      parent_columns = Enum.map(sorted, fn [_, _, _, _, to | _] -> to end)

      {id,
       %{parent_table: parent_table, child_columns: child_columns, parent_columns: parent_columns}}
    end)
  end

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
