defmodule XqliteEcto3.Error do
  @moduledoc """
  Structured SQLite error as an Ecto-compatible exception.

  One exception type — `rescue e in XqliteEcto3.Error` always works —
  with a per-class payload in `details`, in the spirit of a Rust enum
  carrying data in its variants:

    * `type: :constraint_violation` → `details` is
      `XqliteEcto3.Error.Constraint` (subtype atom + parsed structural
      fields: table, columns, index name, constraint name, storage
      classes).
    * `type: :sqlite_failure` → `details` is
      `XqliteEcto3.Error.SqliteFailure` (primary + extended result
      codes, raw message).
    * `type: :sql_input_error` → `details` is
      `XqliteEcto3.Error.Input` (code, message, offending SQL, byte
      offset).
    * Tag-only errors (`:no_such_table`, `:connection_closed`, …) →
      `details` is `nil`; the tag lives in `type`.

  `to_constraints/2` and user-level handling pattern-match the
  `details` struct directly — never the message text.
  """

  defexception [:message, :statement, :type, :details]

  defmodule FkViolation do
    @moduledoc """
    One row of `PRAGMA foreign_key_check`, resolved against
    `PRAGMA foreign_key_list` — produced by the opt-in rich FK
    diagnostics (`rich_fk_diagnostics: true` repo config).

    `constraint_name` is synthesized from the child table and columns
    using Ecto's default convention (`"<table>_<column>_fkey"`) so
    `Ecto.Changeset.foreign_key_constraint/3` matches out of the box.
    SQLite does not store FK constraint names, so explicitly named
    constraints still need `foreign_key_constraint(:field, name: ...)`
    with the synthesized name.

    `child_rowid` is `nil` for `WITHOUT ROWID` child tables.
    `parent_columns` may contain `nil` when the FK references the
    parent's primary key implicitly (`REFERENCES parent` without a
    column list).
    """

    defstruct [
      :child_table,
      :child_rowid,
      :parent_table,
      :fk_id,
      :constraint_name,
      child_columns: [],
      parent_columns: []
    ]

    @type t :: %__MODULE__{
            child_table: String.t(),
            child_rowid: integer() | nil,
            parent_table: String.t(),
            fk_id: integer(),
            constraint_name: String.t(),
            child_columns: [String.t()],
            parent_columns: [String.t() | nil]
          }
  end

  defmodule Constraint do
    @moduledoc """
    Payload for `type: :constraint_violation` — one of SQLite's 13
    constraint subtypes plus the structural details xqlite parsed at
    the NIF boundary.

    For `subtype: :constraint_foreign_key` with the opt-in
    `rich_fk_diagnostics: true` repo config, `fk_violations` carries
    the exact violating rows and `fk_diagnostics` reports whether the
    diagnosis ran: `:not_run` (flag off or non-FK error), `:ok`
    (violations populated), or `{:unavailable, reason}` (attempted but
    failed — the original error is surfaced regardless).
    """

    defstruct [
      :subtype,
      :message,
      :table,
      :index_name,
      :constraint_name,
      :source_type,
      :target_type,
      columns: [],
      fk_violations: [],
      fk_diagnostics: :not_run
    ]

    @type t :: %__MODULE__{
            subtype: atom(),
            message: String.t() | nil,
            table: String.t() | nil,
            index_name: String.t() | nil,
            constraint_name: String.t() | nil,
            source_type: atom() | nil,
            target_type: atom() | nil,
            columns: [String.t()],
            fk_violations: [XqliteEcto3.Error.FkViolation.t()],
            fk_diagnostics: :not_run | :ok | {:unavailable, term()}
          }
  end

  defmodule SqliteFailure do
    @moduledoc """
    Payload for `type: :sqlite_failure` — the catch-all SQLite error
    with its primary and extended result codes preserved.
    """

    defstruct [:code, :extended_code, :message]

    @type t :: %__MODULE__{
            code: integer() | nil,
            extended_code: integer() | nil,
            message: String.t() | nil
          }
  end

  defmodule Input do
    @moduledoc """
    Payload for `type: :sql_input_error` — malformed SQL rejected at
    prepare time, with the offending statement and byte offset.
    """

    defstruct [:code, :message, :sql, :offset]

    @type t :: %__MODULE__{
            code: integer() | nil,
            message: String.t() | nil,
            sql: String.t() | nil,
            offset: integer() | nil
          }
  end

  @type details :: Constraint.t() | SqliteFailure.t() | Input.t() | nil

  @type t :: %__MODULE__{
          message: String.t(),
          statement: String.t() | nil,
          type: atom() | nil,
          details: details()
        }

  @doc """
  Wraps an error reason into an `XqliteEcto3.Error` exception.
  """
  def wrap({:constraint_violation, subtype, %{} = d}) do
    %__MODULE__{
      message: Map.get(d, :message, ""),
      type: :constraint_violation,
      details: %Constraint{
        subtype: subtype,
        message: Map.get(d, :message),
        table: Map.get(d, :table),
        columns: Map.get(d, :columns, []),
        index_name: Map.get(d, :index_name),
        constraint_name: Map.get(d, :constraint_name),
        source_type: Map.get(d, :source_type),
        target_type: Map.get(d, :target_type)
      }
    }
  end

  def wrap({:sqlite_failure, code, extended_code, msg}) when is_binary(msg) or is_nil(msg) do
    %__MODULE__{
      message: sqlite_failure_message(msg),
      type: :sqlite_failure,
      details: %SqliteFailure{code: code, extended_code: extended_code, message: msg}
    }
  end

  def wrap({:sql_input_error, %{} = d}) do
    %__MODULE__{
      message: Map.get(d, :message, ""),
      type: :sql_input_error,
      details: %Input{
        code: Map.get(d, :code),
        message: Map.get(d, :message),
        sql: Map.get(d, :sql),
        offset: Map.get(d, :offset)
      }
    }
  end

  def wrap({tag, extended_code, msg})
      when tag in [
             :database_busy_or_locked,
             :read_only_database,
             :schema_changed,
             :authorization_denied
           ] and is_integer(extended_code) and is_binary(msg) do
    %__MODULE__{message: msg, type: tag, details: %{extended_code: extended_code}}
  end

  def wrap({:utf8_error, column, msg}) when is_integer(column) and is_binary(msg) do
    %__MODULE__{message: msg, type: :utf8_error, details: %{column: column}}
  end

  def wrap({tag, msg}) when is_atom(tag) and is_binary(msg) do
    %__MODULE__{message: msg, type: tag}
  end

  def wrap(reason) when is_atom(reason) do
    %__MODULE__{message: Atom.to_string(reason), type: reason}
  end

  def wrap(reason) do
    %__MODULE__{message: inspect(reason)}
  end

  defp sqlite_failure_message(nil), do: "SQLite failure"
  defp sqlite_failure_message(msg), do: "SQLite failure: " <> msg
end
