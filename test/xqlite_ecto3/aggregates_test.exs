defmodule XqliteEcto3.AggregatesTest do
  use XqliteEcto3.AdapterCase, async: true

  defmodule AG do
    use XqliteEcto3.TestSchemas.StandardUser, table: "agg_users"
  end

  setup_all do
    create_table!("agg_users", user_columns())
  end

  setup do
    clear_table!("agg_users")

    for {name, age} <- [{"Alice", 30}, {"Bob", 25}, {"Carol", 35}, {"Dave", 25}, {"Eve", 40}] do
      {:ok, _} = Repo.insert(AG.changeset(%AG{}, %{name: name, age: age}))
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Repo.aggregate
  # ---------------------------------------------------------------------------

  test "aggregate :count" do
    assert Repo.aggregate(AG, :count) == 5
  end

  test "aggregate :count on field" do
    assert Repo.aggregate(AG, :count, :age) == 5
  end

  test "aggregate :sum" do
    assert Repo.aggregate(AG, :sum, :age) == 155
  end

  test "aggregate :avg" do
    avg = Repo.aggregate(AG, :avg, :age)
    assert_in_delta avg, 31.0, 0.01
  end

  test "aggregate :min" do
    assert Repo.aggregate(AG, :min, :age) == 25
  end

  test "aggregate :max" do
    assert Repo.aggregate(AG, :max, :age) == 40
  end

  test "aggregate on empty table returns nil for sum/avg/min/max" do
    Repo.delete_all(AG)

    assert Repo.aggregate(AG, :count) == 0
    assert Repo.aggregate(AG, :sum, :age) == nil
    assert Repo.aggregate(AG, :avg, :age) == nil
    assert Repo.aggregate(AG, :min, :age) == nil
    assert Repo.aggregate(AG, :max, :age) == nil
  end

  # ---------------------------------------------------------------------------
  # Aggregate with query filters
  # ---------------------------------------------------------------------------

  test "aggregate with where clause" do
    query = from(u in AG, where: u.age > 28)
    assert Repo.aggregate(query, :count) == 3
    assert Repo.aggregate(query, :sum, :age) == 105
  end

  # ---------------------------------------------------------------------------
  # Inline aggregates via select
  # ---------------------------------------------------------------------------

  test "count in select" do
    [result] = Repo.all(from(u in AG, select: count(u.id)))
    assert result == 5
  end

  test "sum in select" do
    [result] = Repo.all(from(u in AG, select: sum(u.age)))
    assert result == 155
  end

  test "avg in select" do
    [result] = Repo.all(from(u in AG, select: avg(u.age)))
    assert_in_delta result, 31.0, 0.01
  end

  test "min/max in select" do
    [result] = Repo.all(from(u in AG, select: {min(u.age), max(u.age)}))
    assert result == {25, 40}
  end

  # ---------------------------------------------------------------------------
  # Group by with aggregates
  # ---------------------------------------------------------------------------

  test "group_by with count" do
    results =
      Repo.all(
        from(u in AG,
          group_by: u.age,
          select: {u.age, count(u.id)},
          order_by: u.age
        )
      )

    assert results == [{25, 2}, {30, 1}, {35, 1}, {40, 1}]
  end

  test "group_by with sum" do
    results =
      Repo.all(
        from(u in AG,
          group_by: u.age,
          select: {u.age, sum(u.age)},
          order_by: u.age
        )
      )

    assert results == [{25, 50}, {30, 30}, {35, 35}, {40, 40}]
  end

  test "group_by with having and aggregate" do
    results =
      Repo.all(
        from(u in AG,
          group_by: u.age,
          having: count(u.id) > 1,
          select: {u.age, count(u.id)}
        )
      )

    assert results == [{25, 2}]
  end
end
