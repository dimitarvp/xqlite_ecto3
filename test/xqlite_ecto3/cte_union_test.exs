defmodule XqliteEcto3.CteUnionTest do
  use XqliteEcto3.AdapterCase, async: true

  defmodule CU do
    use XqliteEcto3.TestSchemas.StandardUser, table: "cte_users"
  end

  setup_all do
    create_table!("cte_users", user_columns())
  end

  setup do
    clear_table!("cte_users")

    for {name, age} <- [{"Alice", 30}, {"Bob", 25}, {"Carol", 35}] do
      {:ok, _} = Repo.insert(CU.changeset(%CU{}, %{name: name, age: age}))
    end

    :ok
  end

  # ---------------------------------------------------------------------------
  # Union
  # ---------------------------------------------------------------------------

  test "union combines two queries without duplicates" do
    young = from(u in CU, where: u.age < 30, select: u.name)
    old = from(u in CU, where: u.age > 28, select: u.name)

    results = Repo.all(union(young, ^old)) |> Enum.sort()
    assert results == ["Alice", "Bob", "Carol"]
  end

  test "union_all includes duplicates" do
    low = from(u in CU, where: u.age <= 30, select: u.name)
    high = from(u in CU, where: u.age >= 30, select: u.name)

    results = Repo.all(union_all(low, ^high)) |> Enum.sort()
    # Alice (30) appears in both
    assert results == ["Alice", "Alice", "Bob", "Carol"]
  end

  # ---------------------------------------------------------------------------
  # Intersect
  # ---------------------------------------------------------------------------

  test "intersect returns common rows" do
    low = from(u in CU, where: u.age <= 30, select: u.name)
    high = from(u in CU, where: u.age >= 30, select: u.name)

    results = Repo.all(intersect(low, ^high))
    assert results == ["Alice"]
  end

  # ---------------------------------------------------------------------------
  # Except
  # ---------------------------------------------------------------------------

  test "except removes matching rows" do
    all_users = from(u in CU, select: u.name)
    old = from(u in CU, where: u.age >= 30, select: u.name)

    results = Repo.all(except(all_users, ^old))
    assert results == ["Bob"]
  end

  # ---------------------------------------------------------------------------
  # CTE (Common Table Expression)
  # ---------------------------------------------------------------------------

  test "CTE with named query" do
    young_cte = from(u in CU, where: u.age < 35, select: %{name: u.name, age: u.age})

    query =
      CU
      |> with_cte("young", as: ^young_cte)
      |> join(:inner, [u], y in "young", on: u.name == y.name)
      |> select([u, y], {u.name, u.age})
      |> order_by([u], u.name)

    results = Repo.all(query)
    assert results == [{"Alice", 30}, {"Bob", 25}]
  end

  test "CTE referenced in from" do
    young_cte = from(u in CU, where: u.age < 35, select: %{name: u.name, age: u.age})

    query =
      "young"
      |> with_cte("young", as: ^young_cte)
      |> select([y], y.name)
      |> order_by([y], y.name)

    results = Repo.all(query)
    assert results == ["Alice", "Bob"]
  end
end
