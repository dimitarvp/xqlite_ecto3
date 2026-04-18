defmodule XqliteEcto3.Types.UUID do
  @moduledoc """
  UUID type for SQLite with explicit per-field storage mode.

  ## Storage modes

    * `:string` (default) — 36-character ASCII form `"550e8400-e29b-41d4-a716-446655440000"`
      stored in a TEXT column. Human-readable in the SQLite CLI, portable across
      tools, easy to export to CSV. 36 bytes per row.

    * `:binary` — raw 16-byte binary stored in a BLOB column. 55% smaller per row,
      not human-readable, meaningful when a table has millions+ rows.

  The Elixir-side representation is **always the 36-character string** regardless
  of storage mode. Changing a field's storage mode in a migration does not
  require changes to calling code.

  ## Usage

      schema "users" do
        # Default :string storage
        field :id, XqliteEcto3.Types.UUID, autogenerate: true, primary_key: true

        # Explicit :binary storage
        field :trace_id, XqliteEcto3.Types.UUID, storage: :binary
      end

  ## Migration

  The migration's column type must match the storage mode. The adapter does not
  auto-map Ecto field types to migration column types — schemas and migrations
  are separate sources of truth.

      # For :string storage
      add :id, :string, primary_key: true

      # For :binary storage
      add :trace_id, :binary

  ## Why per-field instead of application-wide

  Older versions of this adapter used `config :xqlite_ecto3, :uuid_type, :binary`
  as a global switch. That knob still exists for `Ecto.Query.Tagged{type: :uuid}`
  query-param handling (not recommended for new code). This type replaces it for
  schema fields: different columns in the same repo can now use different
  storage modes.

  ## UUID version

  `autogenerate/1` produces `Ecto.UUID.generate/0` output (v4, random). If UUID v7
  (time-ordered) is wanted in the future, add a `:version` option.
  """

  use Ecto.ParameterizedType

  @impl Ecto.ParameterizedType
  def init(opts) do
    storage = Keyword.get(opts, :storage, :string)

    unless storage in [:string, :binary] do
      raise ArgumentError,
            "XqliteEcto3.Types.UUID :storage must be :string or :binary, got: " <>
              inspect(storage)
    end

    %{storage: storage}
  end

  @impl Ecto.ParameterizedType
  def type(%{storage: :string}), do: :string
  def type(%{storage: :binary}), do: :binary

  @impl Ecto.ParameterizedType
  def cast(nil, _params), do: {:ok, nil}
  def cast(value, _params), do: Ecto.UUID.cast(value)

  @impl Ecto.ParameterizedType
  def load(nil, _loader, _params), do: {:ok, nil}

  def load(value, _loader, %{storage: :string}) when is_binary(value) do
    # DB returned the 36-char string form. Re-cast validates shape.
    Ecto.UUID.cast(value)
  end

  def load(<<_::128>> = raw, _loader, %{storage: :binary}) do
    # DB returned raw 16 bytes; Ecto.UUID.load/1 renders it as the string form.
    Ecto.UUID.load(raw)
  end

  def load(_value, _loader, _params), do: :error

  @impl Ecto.ParameterizedType
  def dump(nil, _dumper, _params), do: {:ok, nil}

  def dump(value, _dumper, %{storage: :string}) do
    # Normalize any accepted input to the 36-char string for TEXT storage.
    Ecto.UUID.cast(value)
  end

  def dump(value, _dumper, %{storage: :binary}) do
    # Normalize to string first (handles both raw and string input), then convert
    # to raw 16 bytes for BLOB storage.
    with {:ok, string_form} <- Ecto.UUID.cast(value),
         {:ok, raw} <- Ecto.UUID.dump(string_form) do
      {:ok, raw}
    end
  end

  @impl Ecto.ParameterizedType
  def autogenerate(_params), do: Ecto.UUID.generate()

  @impl Ecto.ParameterizedType
  def equal?(a, b, _params), do: a == b
end
