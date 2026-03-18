defmodule XqliteEcto3.Error do
  @moduledoc """
  Structured SQLite error as an Ecto-compatible exception.

  Preserves xqlite's constraint subtypes so `to_constraints/2` can pattern
  match directly. When the constraint fires during `sqlite3_step` (the query
  path), xqlite wraps it as `{:cannot_fetch_row, msg}` — we recover the
  constraint type by parsing the message prefix.
  """

  defexception [:message, :statement, :type, :constraint_type]

  @type t :: %__MODULE__{
          message: String.t(),
          statement: String.t() | nil,
          type: atom() | nil,
          constraint_type: atom() | nil
        }

  @doc """
  Wraps an error reason into an `XqliteEcto3.Error` exception.
  """
  def wrap({:constraint_violation, subtype, msg}) do
    %__MODULE__{message: msg, type: :constraint_violation, constraint_type: subtype}
  end

  def wrap({:cannot_fetch_row, msg}) when is_binary(msg) do
    {constraint_type, clean_msg} = classify_constraint_from_message(msg)
    %__MODULE__{message: clean_msg, type: :cannot_fetch_row, constraint_type: constraint_type}
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

  # The query NIF path (prepare→step→collect) wraps constraint violations
  # inside {:cannot_fetch_row, "Error advancing row iterator: <original msg>"}.
  # We strip the wrapper prefix and classify from the SQLite error message.
  defp classify_constraint_from_message(msg) do
    clean = strip_wrapper(msg)

    cond do
      String.starts_with?(clean, "UNIQUE constraint failed:") ->
        {:constraint_unique, clean}

      String.starts_with?(clean, "PRIMARY KEY constraint failed:") ->
        {:constraint_primary_key, clean}

      String.starts_with?(clean, "FOREIGN KEY constraint failed") ->
        {:constraint_foreign_key, clean}

      String.starts_with?(clean, "CHECK constraint failed:") ->
        {:constraint_check, clean}

      String.starts_with?(clean, "NOT NULL constraint failed:") ->
        {:constraint_not_null, clean}

      true ->
        {nil, msg}
    end
  end

  defp strip_wrapper("Error advancing row iterator: " <> rest), do: rest
  defp strip_wrapper(msg), do: msg
end
