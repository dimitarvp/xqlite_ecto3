defmodule XqliteEcto3.Error do
  @moduledoc """
  Structured SQLite error as an Ecto-compatible exception.

  Preserves xqlite's constraint subtypes and parsed structural details
  (table, columns, index name, constraint name) so `to_constraints/2`
  and user-level handling can pattern-match structured fields directly.
  """

  defexception [:message, :statement, :type, :constraint_type, :constraint_details]

  @type constraint_details :: %{
          optional(:message) => String.t(),
          optional(:table) => String.t() | nil,
          optional(:columns) => [String.t()],
          optional(:index_name) => String.t() | nil,
          optional(:constraint_name) => String.t() | nil
        }

  @type t :: %__MODULE__{
          message: String.t(),
          statement: String.t() | nil,
          type: atom() | nil,
          constraint_type: atom() | nil,
          constraint_details: constraint_details() | nil
        }

  @doc """
  Wraps an error reason into an `XqliteEcto3.Error` exception.
  """
  def wrap({:constraint_violation, subtype, %{} = details}) do
    %__MODULE__{
      message: Map.get(details, :message, ""),
      type: :constraint_violation,
      constraint_type: subtype,
      constraint_details: details
    }
  end

  def wrap({:sqlite_failure, _code, _ext_code, msg}) when is_binary(msg) do
    %__MODULE__{message: "SQLite failure: " <> msg, type: :sqlite_failure}
  end

  def wrap({:sql_input_error, %{message: msg}}) do
    %__MODULE__{message: msg, type: :sql_input_error}
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
