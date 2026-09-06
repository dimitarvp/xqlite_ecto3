defmodule XqliteEcto3.RebuildRefusedError do
  @moduledoc """
  Raised when the opt-in table rebuild refuses to run.

  SQLite has no `ALTER TABLE ... MODIFY COLUMN`, so `:modify` is carried out
  by rebuilding the table: create a replacement, copy the rows, drop the
  original, rename. Anything the replacement cannot be given back — a
  construct no pragma reports, a dependent object that still names the table,
  a change set that would leave the table without a primary key — would
  disappear without a trace, so the rebuild refuses before it touches
  anything and raises this.

  The refusal always happens before the first destructive statement, so the
  table is exactly as it was.

  Fields:

    * `reason` — which check refused, as an atom. One of
      `:rebuild_not_enabled`, `:table_not_found`, `:virtual_table`,
      `:shadow_table`, `:unpreservable_construct`, `:dependents_exist`,
      `:incoming_action_on_populated`, `:reference_change`,
      `:primary_key_removed`, `:key_already_granted`, `:affinity_rewrite`,
      `:trigger_reads_removed_column`, `:stranded_constraint`,
      `:unknown_column`, `:trigger_sql_unrecognized` or
      `:foreign_key_violations`.
    * `table` — the table the migration asked to alter.
    * `construct` — the part of the table's declaration that refused, where
      one construct is to blame: `:check`, `:collate`, `:deferrable`,
      `:on_conflict`, `:generated_columns`, `:without_rowid`, `:strict`,
      `:primary_key`, `:unique`, `:foreign_key` or `:index`. `nil` otherwise.
    * `column` — the column involved, or `nil`.
    * `violations` — the `PRAGMA foreign_key_check` rows left behind, for
      `:foreign_key_violations`. `[]` for every other reason.
    * `details` — the facts that do not fit a single-value field, per reason:
      `:dependents` (`{type, name}` pairs) for `:dependents_exist`,
      `:referencing` (`{table, on-delete action}` pairs) for
      `:incoming_action_on_populated`, `:removed` (the columns that lost key
      membership) for `:primary_key_removed`, `:kept` and `:granted` for
      `:key_already_granted`, `:old_affinity` / `:new_affinity` /
      `:rewritten` for `:affinity_rewrite`, `:trigger` for
      `:trigger_reads_removed_column` and `:trigger_sql_unrecognized`,
      `:change` for `:reference_change` and `:unknown_column`. `%{}` where
      the named fields say everything.
    * `message` — the full explanation, including how to make the change by
      hand.
  """

  defexception reason: nil,
               table: nil,
               construct: nil,
               column: nil,
               violations: [],
               details: %{},
               message: nil

  @type t :: %__MODULE__{
          reason: atom() | nil,
          table: String.t() | nil,
          construct: atom() | nil,
          column: String.t() | nil,
          violations: [term()],
          details: map(),
          message: String.t() | nil
        }

  @impl true
  def message(%__MODULE__{message: nil} = error) do
    "cannot rebuild #{inspect(error.table)} for ALTER ... MODIFY: #{error.reason}"
  end

  def message(%__MODULE__{message: message}), do: message
end
