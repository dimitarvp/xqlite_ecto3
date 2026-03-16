defmodule XqliteEcto3.Error do
  @moduledoc """
  Structured SQLite error as an Ecto-compatible exception.

  Preserves xqlite's constraint subtypes so `to_constraints/2` can pattern
  match directly — no string parsing for constraint classification.
  """

  defexception [:message, :statement, :constraint_type]

  @type t :: %__MODULE__{
          message: String.t(),
          statement: String.t() | nil,
          constraint_type: atom() | nil
        }

  @doc """
  Wraps an error reason into an `XqliteEcto3.Error` exception.
  """
  def wrap({:constraint_violation, subtype, msg}) do
    %__MODULE__{message: msg, constraint_type: subtype}
  end

  def wrap({:sql_input_error, %{message: msg}}) do
    %__MODULE__{message: msg}
  end

  def wrap({tag, msg}) when is_atom(tag) and is_binary(msg) do
    %__MODULE__{message: msg}
  end

  def wrap(reason) when is_atom(reason) do
    %__MODULE__{message: Atom.to_string(reason)}
  end

  def wrap(reason) do
    %__MODULE__{message: inspect(reason)}
  end
end
