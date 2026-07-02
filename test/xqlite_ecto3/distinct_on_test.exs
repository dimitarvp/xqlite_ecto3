defmodule XqliteEcto3.DistinctOnTest do
  use XqliteEcto3.AdapterCase, async: true

  alias XqliteEcto3.Connection

  import Ecto.Query

  defmodule DU do
    use XqliteEcto3.TestSchemas.StandardUser, table: "distinct_users"
  end

  setup_all do
    create_table!("distinct_users", user_columns())
  end

  setup do
    clear_table!("distinct_users")
  end

  defp to_sql(query) do
    {query, _, _} = Ecto.Query.Planner.plan(query, :all, XqliteEcto3)
    {query, _} = Ecto.Query.Planner.normalize(query, :all, XqliteEcto3, 0)
    query |> Connection.all() |> IO.iodata_to_binary()
  end

  defp seed! do
    Repo.insert!(%DU{name: "hello1", email: "1@x", age: 10})
    Repo.insert!(%DU{name: "hello2", email: "2@x", age: 10})
    Repo.insert!(%DU{name: "hello", email: "3@x", age: 11})
  end

  describe "rewrite shape" do
    test "single distinct column with order_by" do
      q = from(u in DU, distinct: u.age, order_by: [asc: u.name], select: {u.name, u.age})

      assert to_sql(q) ==
               ~s|SELECT xq0."__xq_c0", xq0."__xq_c1" FROM (| <>
                 ~s|SELECT d0."name" AS "__xq_c0", d0."age" AS "__xq_c1", | <>
                 ~s|d0."age" AS "__xq_d0", d0."name" AS "__xq_o0", | <>
                 ~s|ROW_NUMBER() OVER (PARTITION BY d0."age" ORDER BY d0."name") AS "__xq_rn" | <>
                 ~s|FROM "distinct_users" AS d0) AS xq0 WHERE xq0."__xq_rn" = 1 | <>
                 ~s|ORDER BY xq0."__xq_d0", xq0."__xq_o0"|
    end

    test "multiple distinct columns carry directions to the outer order" do
      q = from(u in DU, distinct: [asc: u.age, desc: u.name], select: u.email)

      assert to_sql(q) ==
               ~s|SELECT xq0."__xq_c0" FROM (| <>
                 ~s|SELECT d0."email" AS "__xq_c0", | <>
                 ~s|d0."age" AS "__xq_d0", d0."name" AS "__xq_d1", | <>
                 ~s|ROW_NUMBER() OVER (PARTITION BY d0."age", d0."name") AS "__xq_rn" | <>
                 ~s|FROM "distinct_users" AS d0) AS xq0 WHERE xq0."__xq_rn" = 1 | <>
                 ~s|ORDER BY xq0."__xq_d0", xq0."__xq_d1" DESC|
    end

    test "numbered placeholders keep binding order across the rewrite" do
      q =
        from(u in DU,
          distinct: u.age,
          where: u.age > ^18,
          order_by: [asc: u.name],
          limit: ^5,
          select: u.name
        )

      assert to_sql(q) ==
               ~s|SELECT xq0."__xq_c0" FROM (| <>
                 ~s|SELECT d0."name" AS "__xq_c0", | <>
                 ~s|d0."age" AS "__xq_d0", d0."name" AS "__xq_o0", | <>
                 ~s|ROW_NUMBER() OVER (PARTITION BY d0."age" ORDER BY d0."name") AS "__xq_rn" | <>
                 ~s|FROM "distinct_users" AS d0 WHERE (d0."age" > ?1)) AS xq0 | <>
                 ~s|WHERE xq0."__xq_rn" = 1 ORDER BY xq0."__xq_d0", xq0."__xq_o0" LIMIT ?2|
    end

    test "top-level map select maps positionally, without outer aliases" do
      q = from(u in DU, distinct: u.age, select: %{n: u.name})

      assert to_sql(q) ==
               ~s|SELECT xq0."__xq_c0" FROM (| <>
                 ~s|SELECT d0."name" AS "__xq_c0", d0."age" AS "__xq_d0", | <>
                 ~s|ROW_NUMBER() OVER (PARTITION BY d0."age") AS "__xq_rn" | <>
                 ~s|FROM "distinct_users" AS d0) AS xq0 WHERE xq0."__xq_rn" = 1 | <>
                 ~s|ORDER BY xq0."__xq_d0"|
    end

    test "set operations combined with expression DISTINCT are refused" do
      q = from(u in DU, distinct: u.age, select: u.name) |> union(^from(u in DU, select: u.name))

      assert_raise Ecto.QueryError, fn -> to_sql(q) end
    end

    test "schemaless whole-source select is refused" do
      q = from(u in "distinct_users", distinct: u.age, select: u)

      assert_raise Ecto.QueryError, fn -> to_sql(q) end
    end
  end

  describe "live semantics" do
    test "keeps the first row per group by order_by, result ordered by distinct then order" do
      seed!()

      q = from(u in DU, distinct: u.age, order_by: [asc: u.name], select: u.name)
      assert Repo.all(q) == ["hello1", "hello"]
    end

    test "descending distinct direction orders groups descending" do
      seed!()

      q = from(u in DU, distinct: [desc: u.age], order_by: [asc: u.name], select: u.name)
      assert Repo.all(q) == ["hello", "hello1"]
    end

    test "window order picks the group winner" do
      seed!()

      q = from(u in DU, distinct: u.age, order_by: [desc: u.name], select: u.name)
      assert Repo.all(q) == ["hello2", "hello"]
    end

    test "no order_by yields one arbitrary row per group" do
      seed!()

      q = from(u in DU, distinct: u.age, select: u.age)
      assert Repo.all(q) == [10, 11]
    end

    test "subquery in distinct (shared-suite shape)" do
      seed!()

      q =
        from(u in DU,
          as: :u,
          distinct: exists(from(o in DU, where: o.age > parent_as(:u).age)),
          order_by: [asc: u.name],
          select: u.name
        )

      assert Repo.all(q) == ["hello", "hello1"]
    end

    test "distinct-on inside a subquery preserves named fields" do
      seed!()

      sub = from(u in DU, distinct: u.age, select: %{n: u.name})
      q = from(s in subquery(sub), select: s.n)

      assert q |> Repo.all() |> Enum.sort() == ["hello", "hello1"]
    end

    test "full struct select round-trips through the rewrite" do
      seed!()

      q = from(u in DU, distinct: u.age, order_by: [asc: u.name])
      assert [%DU{name: "hello1", age: 10}, %DU{name: "hello", age: 11}] = Repo.all(q)
    end
  end
end
