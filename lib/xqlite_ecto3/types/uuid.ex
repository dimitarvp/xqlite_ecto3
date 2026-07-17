defmodule XqliteEcto3.Types.UUID do
  @moduledoc """
  **Per-field escape hatch for UUID storage mode.** Most schemas should use
  the standard `:binary_id` type and set the storage mode globally via
  `config :xqlite_ecto3, :binary_id_storage, :string | :binary`. Use this
  type only when you genuinely need different modes for different fields
  in the same schema.

  ## Primary path (recommended for almost all users)

      # config/config.exs
      config :xqlite_ecto3, :binary_id_storage, :binary

      # schema — standard Ecto, no custom type
      schema "users" do
        @primary_key {:id, :binary_id, autogenerate: true}
        field :name, :string
      end

  This governs the adapter's dumper, loader, column-type mapping in
  migrations, and query-param CAST generation uniformly.

  ## Escape hatch (this type)

  Use when different fields in the same schema need different storage
  modes — e.g. a legacy string-UUID column alongside new BLOB-UUID ones:

      schema "events" do
        @primary_key {:id, :binary_id, autogenerate: true}  # global config
        field :trace_id, XqliteEcto3.Types.UUID, storage: :binary  # explicit override
      end

  ## Storage modes

    * `:string` (default) — 36-character ASCII form stored in a TEXT column.
      Human-readable in the SQLite CLI, portable, easy to export. 36 bytes
      per row.

    * `:binary` — raw 16-byte binary stored in a BLOB column. 55% smaller
      per row, not human-readable, meaningful at millions-of-rows scale.

  The Elixir-side representation is **always the 36-character string**
  regardless of storage mode.

  ## Migration

  The migration's column type must match the storage mode. The adapter
  does not auto-map Ecto field types to migration column types.

      # For :string storage
      add :trace_id, :string

      # For :binary storage
      add :trace_id, :binary

  ## UUID version

  `autogenerate/1` produces `Ecto.UUID.generate/0` output (v4, random).
  """

  use Ecto.ParameterizedType

  @impl Ecto.ParameterizedType
  def init(opts) do
    storage = Keyword.get(opts, :storage, :string)

    if storage not in [:string, :binary] do
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
    with {:ok, string_form} <- Ecto.UUID.cast(value) do
      Ecto.UUID.dump(string_form)
    end
  end

  @impl Ecto.ParameterizedType
  def autogenerate(_params), do: Ecto.UUID.generate()

  @impl Ecto.ParameterizedType
  def equal?(a, b, _params), do: a == b
end
