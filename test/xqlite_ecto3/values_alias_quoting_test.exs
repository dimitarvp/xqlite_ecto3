defmodule XqliteEcto3.ValuesAliasQuotingTest do
  use XqliteEcto3.AdapterCase, async: true

  alias XqliteEcto3.Connection

  defp to_sql(query) do
    {query, _, _} = Ecto.Query.Planner.plan(query, :all, XqliteEcto3)
    {query, _} = Ecto.Query.Planner.normalize(query, :all, XqliteEcto3, 0)
    query |> Connection.all() |> IO.iodata_to_binary()
  end

  test "a values/2 column named like an SQL keyword is quoted in its alias" do
    q = from(v in values([%{order: 1}], %{order: :integer}), select: v.order)

    assert to_sql(q) =~ ~s|AS "order"|
  end

  test "a values/2 column named like an SQL keyword selects" do
    q = from(v in values([%{order: 1}], %{order: :integer}), select: v.order)

    assert Repo.all(q) == [1]
  end
end
