defmodule XqliteEcto3.TypedBinaryParamTest do
  use XqliteEcto3.AdapterCase, async: true

  alias XqliteEcto3.Connection

  defmodule Row do
    use Ecto.Schema

    schema "typed_binary_rows" do
      field(:payload, :binary)
    end
  end

  @utf8 "hello"
  @raw <<0, 255, 1>>

  setup_all do
    create_table!("typed_binary_rows", "id INTEGER PRIMARY KEY AUTOINCREMENT, payload BLOB")
  end

  setup do
    clear_table!("typed_binary_rows")
    %{id: utf8_id} = Repo.insert!(%Row{payload: @utf8})
    %{id: raw_id} = Repo.insert!(%Row{payload: @raw})
    {:ok, utf8_id: utf8_id, raw_id: raw_id}
  end

  defp to_sql(query) do
    {query, _, _} = Ecto.Query.Planner.plan(query, :all, XqliteEcto3)
    {query, _} = Ecto.Query.Planner.normalize(query, :all, XqliteEcto3, 0)
    query |> Connection.all() |> IO.iodata_to_binary()
  end

  test "a type/2-tagged :binary parameter is bound bare, not cast to BLOB" do
    sql = to_sql(from(r in Row, where: r.payload == type(^@utf8, :binary), select: r.id))

    refute sql =~ "AS BLOB"
  end

  test "a UTF-8 binary is found through a type/2-tagged where", %{utf8_id: id} do
    q = from(r in Row, where: r.payload == type(^@utf8, :binary), select: r.id)

    assert Repo.all(q) == [id]
  end

  test "raw bytes are found through a type/2-tagged where", %{raw_id: id} do
    q = from(r in Row, where: r.payload == type(^@raw, :binary), select: r.id)

    assert Repo.all(q) == [id]
  end
end
