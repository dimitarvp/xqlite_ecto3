defmodule XqliteEcto3.DatetimeAddFormTest do
  use XqliteEcto3.AdapterCase, async: true

  alias XqliteEcto3.Connection

  defmodule Event do
    use Ecto.Schema

    schema "dt_add_events" do
      field(:at_usec, :naive_datetime_usec)
      field(:at_sec, :naive_datetime)
      field(:utc_usec, :utc_datetime_usec)
    end
  end

  @anchor ~N[2026-09-05 13:00:00]
  @anchor_utc ~U[2026-09-05 13:00:00Z]

  setup_all do
    create_table!(
      "dt_add_events",
      "id INTEGER PRIMARY KEY AUTOINCREMENT, at_usec TEXT, at_sec TEXT, utc_usec TEXT"
    )
  end

  setup do
    clear_table!("dt_add_events")

    %{id: id} =
      Repo.insert!(%Event{
        at_usec: ~N[2026-09-05 12:30:00.000000],
        at_sec: ~N[2026-09-05 12:30:00],
        utc_usec: ~U[2026-09-05 12:30:00.000000Z]
      })

    {:ok, id: id}
  end

  defp to_sql(query) do
    {query, _, _} = Ecto.Query.Planner.plan(query, :all, XqliteEcto3)
    {query, _} = Ecto.Query.Planner.normalize(query, :all, XqliteEcto3, 0)
    query |> Connection.all() |> IO.iodata_to_binary()
  end

  describe "emission" do
    test "datetime_add renders the stored text form: space separator, no designator" do
      sql =
        to_sql(
          from(e in Event, where: e.at_usec > datetime_add(^@anchor, -1, "hour"), select: e.id)
        )

      assert sql =~ "strftime('%Y-%m-%d %H:%M:%f000'"
      refute sql =~ "T%H"
      refute sql =~ "Z'"
    end
  end

  describe "rows" do
    test "a same-day interval finds a microsecond-precision row", %{id: id} do
      q = from(e in Event, where: e.at_usec > datetime_add(^@anchor, -1, "hour"), select: e.id)

      assert Repo.all(q) == [id]
    end

    test "a same-day interval finds a second-precision row", %{id: id} do
      q = from(e in Event, where: e.at_sec > datetime_add(^@anchor, -1, "hour"), select: e.id)

      assert Repo.all(q) == [id]
    end

    test "a same-day interval finds a utc microsecond row", %{id: id} do
      q =
        from(e in Event,
          where: e.utc_usec > datetime_add(^@anchor_utc, -1, "hour"),
          select: e.id
        )

      assert Repo.all(q) == [id]
    end

    test "SQLite's own datetime() agrees on the same rows", %{id: id} do
      sql = "SELECT id FROM dt_add_events WHERE at_usec > datetime(?, '-1 hour')"

      assert %{rows: [[^id]]} = Repo.query!(sql, ["2026-09-05 13:00:00"])
    end
  end
end
