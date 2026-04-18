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
  (create temp, copy rows, drop, rename, recreate indexes / FKs / triggers).
  `xqlite_ecto3` plans a behind-a-flag rebuild implementation (see task #65);
  until that ships, post-create CHECK addition has to go through `execute/1`
  with raw SQL.
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
  """
  @spec enum_check(atom(), [atom()] | keyword(), keyword()) :: %{
          name: String.t(),
          expr: String.t()
        }
  def enum_check(column, values, opts \\ [])
      when is_atom(column) and is_list(values) and values != [] do
    %{
      name: Keyword.get(opts, :name, "#{column}_enum_check"),
      expr: "#{column} IN (#{format_values(values)})"
    }
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
end
