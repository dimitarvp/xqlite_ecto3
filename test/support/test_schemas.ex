defmodule XqliteEcto3.TestSchemas do
  @moduledoc """
  Canonical test schemas, parameterized by table name.

  Adapter test files each own their tables (async isolation), so a
  single shared schema module cannot work — the table name is baked
  into `schema/2`. These `__using__` macros generate the canonical
  shape bound to the caller's table instead:

      defmodule AU do
        use XqliteEcto3.TestSchemas.StandardUser, table: "agg_users"
      end

  Only byte-identical clones were consolidated; any schema with a
  divergent field or changeset stays inline in its test file —
  partial dedup is net pain.
  """

  defmodule StandardUser do
    @moduledoc """
    The canonical test user: `name`/`email` strings, `age` integer,
    `active` boolean defaulting to `true`, timestamps, and the
    standard changeset (cast all four, require `name`). Override
    `changeset/2` in the using module if a test needs a variant.
    """

    defmacro __using__(opts) do
      table = Keyword.fetch!(opts, :table)

      quote do
        use Ecto.Schema
        import Ecto.Changeset

        schema unquote(table) do
          field(:name, :string)
          field(:email, :string)
          field(:age, :integer)
          field(:active, :boolean, default: true)
          timestamps()
        end

        def changeset(user, attrs \\ %{}) do
          user
          |> cast(attrs, [:name, :email, :age, :active])
          |> validate_required([:name])
        end

        defoverridable changeset: 1, changeset: 2
      end
    end
  end
end
