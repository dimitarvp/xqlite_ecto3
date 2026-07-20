defmodule XqliteEcto3.Migration do
  @moduledoc """
  SQLite-specific migration helpers.

  These helpers are SQLite-specific. Importing them couples your migrations
  to `xqlite_ecto3`. If portability between adapters matters more than
  ergonomics, you can inline the equivalent data structures yourself — each
  helper documents the inline form in its docstring.

  ## Opt-in philosophy

  Nothing in this module activates automatically. Default migration behavior
  is unchanged: loose schemas stay loose until you ask for a guardrail. The
  common case — `Ecto.Enum` fields where you later want the DB layer to
  reject out-of-set values — gets an ergonomic shortcut via `enum_check/3`.

  ## SQLite limitation to be aware of

  CHECK constraints can only be attached at `CREATE TABLE` time in SQLite.
  Adding a CHECK to an existing column requires a full table rebuild
  (create temp, copy rows, drop, rename, recreate indexes / triggers).
  `xqlite_ecto3` ships an opt-in rebuild behind `support_alter_via_table_rebuild:
  true`, but it reconstructs columns from `PRAGMA table_xinfo`, which does not
  carry foreign keys, CHECK constraints, or COLLATE clauses — so a rebuild of a
  table declaring any of those refuses loudly rather than dropping them. Adding a
  CHECK to an existing column therefore still goes through `execute/1` with raw
  SQL.
  """

  @doc """
  Builds a `:check` option value that restricts a column to a fixed set of
  values, matching an `Ecto.Enum`'s declared set.

  Does nothing on its own — it just shapes a map that the existing `:check`
  option on `add/3` and `modify/3` accepts.

  ## Parameters

    * `column` — atom column name.
    * `values` — one of:
      * **list of atoms** (e.g. `[:active, :archived]`), matching the
        string-backed form of `Ecto.Enum`. Emits `col IN ('active', 'archived')`.
      * **keyword list** (e.g. `[active: 1, archived: 2]`), matching the
        integer-backed form of `Ecto.Enum`. Emits `col IN (1, 2)` in declared
        order.
    * `opts` — optional keyword list:
      * `:name` — constraint name. Defaults to `"\#{column}_enum_check"`.

  ## With the helper (ergonomic, SQLite-coupled)

      import XqliteEcto3.Migration

      create table(:users) do
        add :status, :string,
          check: enum_check(:status, [:active, :archived])
      end

  ## Without the helper (portable across adapters that support `:check`)

      create table(:users) do
        add :status, :string,
          check: %{
            name: "status_enum_check",
            expr: "status IN ('active', 'archived')"
          }
      end

  Users make an informed choice per migration.

  ## Examples

      iex> XqliteEcto3.Migration.enum_check(:status, [:active, :archived])
      %{name: "status_enum_check", expr: "status IN ('active', 'archived')"}

      iex> XqliteEcto3.Migration.enum_check(:priority, low: 1, med: 2, high: 3)
      %{name: "priority_enum_check", expr: "priority IN (1, 2, 3)"}

      iex> XqliteEcto3.Migration.enum_check(:role, [:admin], name: "admin_only")
      %{name: "admin_only", expr: "role IN ('admin')"}

  Raises `ArgumentError` unless `column` is an atom and `values` is a
  non-empty list.
  """
  @spec enum_check(atom(), [atom()] | keyword(), keyword()) :: %{
          name: String.t(),
          expr: String.t()
        }
  def enum_check(column, values, opts \\ [])

  def enum_check(column, values, opts)
      when is_atom(column) and is_list(values) and values != [] do
    %{
      name: Keyword.get(opts, :name, "#{column}_enum_check"),
      expr: "#{column} IN (#{format_values(values)})"
    }
  end

  def enum_check(column, values, _opts) do
    raise ArgumentError,
          "enum_check expects an atom column and a non-empty values list, " <>
            "got: #{inspect(column)} and #{inspect(values)}"
  end

  # Keyword list with atom keys = integer-backed Ecto.Enum form.
  # `Keyword.values/1` preserves declared order.
  defp format_values([{key, _v} | _] = kv) when is_atom(key) do
    kv |> Keyword.values() |> Enum.map_join(", ", &to_string/1)
  end

  # Plain list of atoms = string-backed Ecto.Enum form.
  defp format_values(atoms) when is_list(atoms) do
    Enum.map_join(atoms, ", ", &"'#{&1}'")
  end

  @doc """
  Builds a `:check` option value that restricts a column to hold a JSON
  array (any non-array JSON — including objects, scalars, and `null` —
  is rejected).

  Pair with `XqliteEcto3.Types.Array` (which stores as JSON TEXT) when
  you want the DB to refuse malformed writes from non-Ecto paths
  (raw SQL, external tools writing to the same file). Opt-in; nothing
  auto-applies.

  ## Parameters

    * `column` — atom column name.
    * `opts` — optional keyword list:
      * `:name` — constraint name. Defaults to `"\#{column}_array_check"`.

  ## With the helper (ergonomic, SQLite-coupled)

      import XqliteEcto3.Migration

      create table(:posts) do
        add :tags, :string, check: array_check(:tags)
      end

  ## Without the helper (portable across adapters supporting `:check`)

      add :tags, :string,
        check: %{
          name: "tags_array_check",
          expr: "json_type(tags) = 'array'"
        }

  ## Examples

      iex> XqliteEcto3.Migration.array_check(:tags)
      %{name: "tags_array_check", expr: "json_type(tags) = 'array'"}

      iex> XqliteEcto3.Migration.array_check(:scores, name: "scores_is_array")
      %{name: "scores_is_array", expr: "json_type(scores) = 'array'"}
  """
  @spec array_check(atom(), keyword()) :: %{name: String.t(), expr: String.t()}
  def array_check(column, opts \\ []) when is_atom(column) do
    %{
      name: Keyword.get(opts, :name, "#{column}_array_check"),
      expr: "json_type(#{column}) = 'array'"
    }
  end
end
