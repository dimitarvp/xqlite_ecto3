defmodule XqliteEcto3.ColumnNullRenderingLawTest do
  @moduledoc """
  The rule every rendered column obeys: `NOT NULL` is in the DDL exactly
  when the migration asked for `null: false`, whatever the column's type
  and whatever default it carries.

  The property crosses every type the adapter renders with the three states
  of the `:null` option and with defaults of every shape a migration can
  give — none, `nil`, text, numbers, booleans, the map and list forms stored
  as JSON, and expression defaults. It checks `CREATE TABLE` and
  `ALTER TABLE ... ADD COLUMN` on the same request, so the two paths cannot
  drift apart.

  Two details keep the check honest. Quoted literals are blanked out of the
  DDL before the token search, so a default whose own text reads `NOT NULL`
  cannot pass for the constraint. And the assertion is an equality against
  what the options asked for, which covers `null: true` and an absent
  `:null` with the same line rather than with a weaker second test.

  `check:` and `collate:` stay outside the law on purpose: their text comes
  from the caller unquoted and may hold the token itself.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Ecto.Migration.Table
  alias XqliteEcto3.Connection

  @law_runs 2000

  # Every fixed clause of `XqliteEcto3.DataType.column_type/2`, both
  # container shapes, and one spelling that reaches its passthrough clause.
  @types [
    :id,
    :serial,
    :bigserial,
    :boolean,
    :integer,
    :bigint,
    :string,
    :float,
    :real,
    :double,
    :double_precision,
    :binary,
    :date,
    :utc_datetime,
    :utc_datetime_usec,
    :naive_datetime,
    :naive_datetime_usec,
    :time,
    :time_usec,
    :timestamp,
    :decimal,
    :array,
    :binary_id,
    :map,
    :uuid,
    :json,
    :jsonb,
    :xml,
    :inet,
    :cidr,
    :macaddr,
    :tsvector,
    :bytea,
    :money,
    {:array, :integer},
    {:map, :string}
  ]

  # Text that would fake the token if the search read the whole statement,
  # and text that exercises the quote doubling around it.
  @hostile_text ["NOT NULL", "not null", "it's NOT NULL", "", "2000-01-01 00:00:00"]

  @fragments [{:fragment, "CURRENT_TIMESTAMP"}, {:fragment, "(1 + 1)"}]

  property "NOT NULL renders exactly when the column asks for it" do
    table = %Table{name: "t", primary_key: true}

    check all(
            type <- StreamData.member_of(@types),
            null <- StreamData.member_of([:absent, true, false]),
            default <- default_kind(),
            max_runs: @law_runs
          ) do
      opts = build_opts(null, default)
      want = Keyword.get(opts, :null) == false

      assert renders_not_null?({:alter, table, [{:add, :c, type, opts}]}) == want
      assert renders_not_null?({:create, table, [{:add, :c, type, opts}]}) == want
    end
  end

  defp default_kind do
    StreamData.one_of([
      StreamData.constant(:none),
      StreamData.map(default_value(), &{:default, &1})
    ])
  end

  defp default_value do
    StreamData.one_of([
      StreamData.constant(nil),
      StreamData.member_of(@hostile_text),
      StreamData.string(:alphanumeric, max_length: 12),
      StreamData.integer(),
      StreamData.boolean(),
      StreamData.constant(%{"a" => 1}),
      StreamData.constant([1, 2]),
      StreamData.member_of(@fragments)
    ])
  end

  defp build_opts(null, default) do
    []
    |> put_null(null)
    |> put_default(default)
  end

  defp put_null(opts, :absent), do: opts
  defp put_null(opts, null), do: Keyword.put(opts, :null, null)

  defp put_default(opts, :none), do: opts
  defp put_default(opts, {:default, value}), do: Keyword.put(opts, :default, value)

  defp renders_not_null?(command) do
    command
    |> Connection.execute_ddl()
    |> IO.iodata_to_binary()
    |> String.replace(~r/'(?:[^']|'')*'/, "''")
    |> String.contains?("NOT NULL")
  end
end
