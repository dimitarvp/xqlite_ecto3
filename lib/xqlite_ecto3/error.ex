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
    * A repo option refused at connect (`type: :invalid_journal_mode`,
      `:invalid_busy_timeout`, `:invalid_hook_option`, …) → `details` is
      `%{key: key, value: value}`: the configuration key as it was
      written and the value it was given.
    * An error naming one database object (`type: :no_such_table`,
      `:no_such_index`, `:table_exists`, `:index_exists`) → `details`
      is `%{name: name}`: the table or index name exactly as SQLite
      rendered it, which the message repeats inside SQLite's own
      sentence.
    * Tag-only errors (`:connection_closed`, `:cannot_execute`, …) →
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
    (violations populated), `{:truncated, total}` (populated but
    capped — `total` violations existed, the first 24 are carried), or
    `{:unavailable, reason}` (attempted but failed — the original
    error is surfaced regardless).

    For `subtype: :constraint_unique`, `unique_index_names` carries the
    real names of the unique indexes that could have fired —
    `sqlite_autoindex_*` backers of table-level UNIQUE and PRIMARY KEY
    included — read back from the database by
    `XqliteEcto3.UniqueIndexNames`, which also fills in `table` and
    `columns` on the one message form that carries neither (an index
    built over an expression, which SQLite names in `index_name`
    instead; its `columns` are `nil`, an indexed expression having no
    column name). `unique_index_lookup` reports how that read went:
    `:not_run` (a violation of another kind), `:ok`, `{:ambiguous,
    names}` (an expression index on the table matches no column list
    and rules nothing out), or `{:unavailable, reason}`. A single
    non-autoindex candidate is what the constraint mapping emits;
    anything else stays readable here while the mapping falls back to
    the index SQLite named, or to the conventional derived name
    (SQLite never says which index fired, and no changeset declares an
    autoindex).
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
      fk_diagnostics: :not_run,
      unique_index_names: [],
      unique_index_lookup: :not_run
    ]

    @type t :: %__MODULE__{
            subtype: atom(),
            message: String.t() | nil,
            table: String.t() | nil,
            index_name: String.t() | nil,
            constraint_name: String.t() | nil,
            source_type: atom() | nil,
            target_type: atom() | nil,
            columns: [String.t() | nil],
            fk_violations: [XqliteEcto3.Error.FkViolation.t()],
            fk_diagnostics: :not_run | :ok | {:truncated, pos_integer()} | {:unavailable, term()},
            unique_index_names: [String.t()],
            unique_index_lookup:
              :not_run | :ok | {:ambiguous, [String.t()]} | {:unavailable, term()}
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

  @type details ::
          Constraint.t()
          | SqliteFailure.t()
          | Input.t()
          | %{extended_code: integer()}
          | %{column: integer()}
          | %{path: String.t(), code: integer()}
          | %{key: atom(), value: term()}
          | %{name: String.t()}
          | nil

  @type t :: %__MODULE__{
          message: String.t(),
          statement: String.t() | nil,
          type: atom() | nil,
          details: details()
        }

  # Every refusal the connect validators produce. They all carry
  # `{key, value}` — the repo configuration key as the user wrote it and
  # the value it was given — so the exception can name both.
  @connect_refusal_tags [
    :transaction_mode_as_connection_mode,
    :invalid_connection_mode,
    :invalid_statement_cache_size,
    :invalid_busy_timeout,
    :invalid_journal_mode,
    :invalid_synchronous,
    :invalid_temp_store,
    :invalid_foreign_keys,
    :invalid_cache_size,
    :invalid_auto_vacuum,
    :invalid_wal_autocheckpoint,
    :invalid_mmap_size,
    :invalid_rich_fk_diagnostics,
    :invalid_diagnostics_budget_ms,
    :invalid_default_transaction_mode,
    :invalid_hooks_config,
    :invalid_hook_config,
    :invalid_hook_option,
    :hook_subscriber_not_registered,
    :invalid_custom_pragma,
    :invalid_custom_pragmas
  ]

  @name_tags [:no_such_table, :no_such_index, :table_exists, :index_exists]

  @doc """
  Wraps an error reason into an `XqliteEcto3.Error` exception.
  """
  @spec wrap(term()) :: t()
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

  def wrap({:cannot_open_database, path, code, msg})
      when is_binary(path) and is_integer(code) and is_binary(msg) do
    %__MODULE__{message: msg, type: :cannot_open_database, details: %{path: path, code: code}}
  end

  def wrap({tag, {key, value}}) when tag in @connect_refusal_tags do
    %__MODULE__{
      message: "config #{key} rejected: #{inspect(value)}",
      type: tag,
      details: %{key: key, value: value}
    }
  end

  # These four reasons carry the object name alone, so the message a
  # user reads is rebuilt around it — the sentence SQLite itself printed
  # for that failure — while the name stays available unparsed.
  def wrap({tag, name}) when tag in @name_tags and is_binary(name) do
    %__MODULE__{message: name_message(tag, name), type: tag, details: %{name: name}}
  end

  # The binary payload of a NIF reason is SQLite's own message. A refused
  # configuration value can be a binary too, and reading as a bare message
  # was how `journal_mode: "wal"` came out as the error `wal` — so the
  # family that carries a key is kept out of this clause.
  def wrap({tag, msg})
      when is_atom(tag) and is_binary(msg) and tag not in @connect_refusal_tags do
    %__MODULE__{message: msg, type: tag}
  end

  # A tagged reason whose payload is not a plain message (integers, atoms,
  # maps, nested tuples) still carries a meaningful tag — keep it as `type`
  # so callers can classify it, with the full shape preserved in the message.
  # Bounded to the arities the reason union actually uses (2–4 elements).
  def wrap({tag, _} = reason) when is_atom(tag) do
    %__MODULE__{message: inspect(reason), type: tag}
  end

  def wrap({tag, _, _} = reason) when is_atom(tag) do
    %__MODULE__{message: inspect(reason), type: tag}
  end

  def wrap({tag, _, _, _} = reason) when is_atom(tag) do
    %__MODULE__{message: inspect(reason), type: tag}
  end

  def wrap(reason) when is_atom(reason) do
    %__MODULE__{message: Atom.to_string(reason), type: reason}
  end

  def wrap(reason) do
    %__MODULE__{message: inspect(reason)}
  end

  defp sqlite_failure_message(nil), do: "SQLite failure"
  defp sqlite_failure_message(msg), do: "SQLite failure: " <> msg

  defp name_message(:no_such_table, name), do: "no such table: " <> name
  defp name_message(:no_such_index, name), do: "no such index: " <> name
  defp name_message(:table_exists, name), do: "table " <> name <> " already exists"
  defp name_message(:index_exists, name), do: "index " <> name <> " already exists"
end
