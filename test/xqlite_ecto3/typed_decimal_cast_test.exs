defmodule XqliteEcto3.TypedDecimalCastTest do
  use XqliteEcto3.AdapterCase, async: true

  alias XqliteEcto3.Connection

  defmodule Order do
    use Ecto.Schema

    schema "typed_cast_orders" do
      field(:amount, :decimal)
    end
  end

  @big Decimal.new("12345678901234567")

  setup_all do
    create_table!("typed_cast_orders", "id INTEGER PRIMARY KEY AUTOINCREMENT, amount DECIMAL")
  end

  setup do
    clear_table!("typed_cast_orders")
  end

  defp to_sql(query) do
    {query, _, _} = Ecto.Query.Planner.plan(query, :all, XqliteEcto3)
    {query, _} = Ecto.Query.Planner.normalize(query, :all, XqliteEcto3, 0)
    query |> Connection.all() |> IO.iodata_to_binary()
  end

  describe "emission" do
    test "type/2 with :decimal casts to NUMERIC" do
      q = from(o in Order, select: type(o.amount, :decimal))

      assert to_sql(q) == ~s|SELECT CAST(t0."amount" AS NUMERIC) FROM "typed_cast_orders" AS t0|
    end

    test "type/2 with :float keeps casting to REAL" do
      q = from(o in Order, select: type(o.amount, :float))

      assert to_sql(q) == ~s|SELECT CAST(t0."amount" AS REAL) FROM "typed_cast_orders" AS t0|
    end
  end

  describe "an integer-exact decimal past 2^53" do
    test "survives a type/2-tagged select exactly" do
      %{id: id} = Repo.insert!(%Order{amount: @big})

      tagged = Repo.one!(from(o in Order, where: o.id == ^id, select: type(o.amount, :decimal)))
      plain = Repo.one!(from(o in Order, where: o.id == ^id, select: o.amount))

      assert Decimal.equal?(plain, @big)
      assert Decimal.equal?(tagged, @big)
    end

    test "is found by a type/2-tagged where" do
      %{id: id} = Repo.insert!(%Order{amount: @big})

      found = Repo.all(from(o in Order, where: o.amount == type(^@big, :decimal), select: o.id))

      assert found == [id]
    end
  end
end
