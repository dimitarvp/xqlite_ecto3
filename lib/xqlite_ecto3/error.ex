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

  defmodule Constraint do
    @moduledoc """
    Payload for `type: :constraint_violation` — one of SQLite's 13
    constraint subtypes plus the structural details xqlite parsed at
    the NIF boundary.
    """

    defstruct [
      :subtype,
      :message,
      :table,
      :index_name,
      :constraint_name,
      :source_type,
      :target_type,
      columns: []
    ]

    @type t :: %__MODULE__{
            subtype: atom(),
            message: String.t() | nil,
            table: String.t() | nil,
            index_name: String.t() | nil,
            constraint_name: String.t() | nil,
            source_type: atom() | nil,
            target_type: atom() | nil,
            columns: [String.t()]
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

  def wrap({:sqlite_failure, code, extended_code, msg}) when is_binary(msg) do
    %__MODULE__{
      message: "SQLite failure: " <> msg,
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

  def wrap({tag, msg}) when is_atom(tag) and is_binary(msg) do
    %__MODULE__{message: msg, type: tag}
  end

  def wrap(reason) when is_atom(reason) do
    %__MODULE__{message: Atom.to_string(reason), type: reason}
  end

  def wrap(reason) do
    %__MODULE__{message: inspect(reason)}
  end
end
