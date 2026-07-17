defmodule XqliteEcto3.Types.Array do
  @moduledoc """
  Array type for SQLite, stored as JSON TEXT.

  SQLite has no native array column type (storage classes are frozen:
  NULL, INTEGER, REAL, TEXT, BLOB). This type uses the community
  convention: store as JSON text. A list in Elixir round-trips as a
  JSON array in the DB.

  ## Usage

      schema "posts" do
        # Any element type (no per-element casting)
        field :tags, XqliteEcto3.Types.Array

        # Element-typed (each item cast via Ecto's type system)
        field :scores, XqliteEcto3.Types.Array, element: :integer
      end

  Migration:

      create table(:posts) do
        add :tags, :string
        add :scores, :string
      end

  (TEXT column; SQLite stores the JSON string.)

  ## `:element` parameter

    * `:any` (default) — list items are cast through Jason only; any
      JSON-representable value passes.
    * `:string`, `:integer`, `:float`, `:boolean` — each item is cast
      via the corresponding Ecto primitive type. Non-matching items
      cause `:error` on cast.

  Nested arrays and maps are allowed when `:element` is `:any`.

  ## Opt-in DB-level enforcement

  `XqliteEcto3.Migration.array_check/2` generates a
  `CHECK (json_type(col) = 'array')` constraint that rejects non-array
  JSON (including `null`, scalars, objects) at insert/update time:

      add :tags, :string,
        check: XqliteEcto3.Migration.array_check(:tags)

  Opt-in; matches our `enum_check/3` philosophy. Loose schema until
  you ask for a guardrail.

  ## Indexing list elements

  For index-backed queries on specific array positions, add a generated
  column pulling out the element:

      add :first_tag, :string,
        generated: "GENERATED ALWAYS AS (json_extract(tags, '$[0]')) STORED"

  Then index `:first_tag` normally.

  ## Limitation: `:array_type` shared tests stay excluded

  Ecto's `:array_type` integration tests exercise operators like `ANY`,
  `IN`-on-array, `push`/`pull`, which require native array semantics
  that SQLite doesn't provide. This type covers the storage + round-trip
  use case; SQL-level array manipulation is out of scope.
  """

  use Ecto.ParameterizedType

  @impl Ecto.ParameterizedType
  def init(opts) do
    element = Keyword.get(opts, :element, :any)

    if element not in [:any, :string, :integer, :float, :boolean] do
      raise ArgumentError,
            "XqliteEcto3.Types.Array :element must be one of " <>
              ":any, :string, :integer, :float, :boolean — got: #{inspect(element)}"
    end

    %{element: element}
  end

  @impl Ecto.ParameterizedType
  def type(_params), do: :string

  @impl Ecto.ParameterizedType
  def cast(nil, _params), do: {:ok, nil}

  def cast(list, %{element: element}) when is_list(list) do
    cast_elements(list, element, [])
  end

  def cast(_, _), do: :error

  @impl Ecto.ParameterizedType
  def dump(nil, _dumper, _params), do: {:ok, nil}

  def dump(list, _dumper, _params) when is_list(list) do
    case Jason.encode(list) do
      {:ok, json} -> {:ok, json}
      _ -> :error
    end
  end

  def dump(_, _, _), do: :error

  @impl Ecto.ParameterizedType
  def load(nil, _loader, _params), do: {:ok, nil}

  def load(json, _loader, params) when is_binary(json) do
    case Jason.decode(json) do
      {:ok, decoded} when is_list(decoded) -> cast_elements(decoded, params.element, [])
      _ -> :error
    end
  end

  def load(_, _, _), do: :error

  @impl Ecto.ParameterizedType
  def equal?(a, b, _params), do: a == b

  # ---

  defp cast_elements([], _element, acc), do: {:ok, Enum.reverse(acc)}

  defp cast_elements([head | tail], element, acc) do
    case cast_element(head, element) do
      {:ok, casted} -> cast_elements(tail, element, [casted | acc])
      :error -> :error
    end
  end

  defp cast_element(value, :any), do: {:ok, value}
  defp cast_element(nil, _element), do: {:ok, nil}

  defp cast_element(value, :string) when is_binary(value), do: {:ok, value}
  defp cast_element(value, :integer) when is_integer(value), do: {:ok, value}
  defp cast_element(value, :float) when is_float(value), do: {:ok, value * 1.0}
  defp cast_element(value, :float) when is_integer(value), do: {:ok, value * 1.0}
  defp cast_element(value, :boolean) when is_boolean(value), do: {:ok, value}

  defp cast_element(_value, _element), do: :error
end
