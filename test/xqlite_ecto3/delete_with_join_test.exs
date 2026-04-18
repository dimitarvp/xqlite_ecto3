defmodule XqliteEcto3.DeleteWithJoinTest do
  use ExUnit.Case, async: true

  alias XqliteEcto3.Connection
  alias Ecto.Integration.Comment
  alias Ecto.Integration.User

  import Ecto.Query

  defp to_sql(query) do
    {query, _, _} = Ecto.Query.Planner.plan(query, :delete_all, XqliteEcto3)
    {query, _} = Ecto.Query.Planner.normalize(query, :delete_all, XqliteEcto3, 0)
    query |> Connection.delete_all() |> IO.iodata_to_binary()
  end

  describe "rewrite shape" do
    test "simple single-join DELETE is rewritten as DELETE FROM t WHERE pk IN (SELECT …)" do
      q =
        from(c in Comment,
          join: u in User,
          on: u.id == c.author_id,
          where: is_nil(c.post_id)
        )

      sql = to_sql(q)

      assert sql =~ ~r/\ADELETE FROM "comments" WHERE "id" IN \(SELECT c0\."id" FROM /
      assert sql =~ ~s|INNER JOIN "users" AS u1 ON u1."id" = c0."author_id"|
      assert sql =~ ~s|WHERE (c0."post_id" IS NULL)|
      assert String.ends_with?(sql, ")")
    end

    test "multi-join DELETE threads every join into the subquery" do
      q =
        from(c in Comment,
          join: u in assoc(c, :author),
          join: p in assoc(c, :post),
          where: p.id == ^1
        )

      sql = to_sql(q)

      assert sql =~ ~s|INNER JOIN "users"|
      assert sql =~ ~s|INNER JOIN "posts"|
      assert sql =~ ~r/SELECT c0\."id"/
    end
  end

  describe "conservative error paths" do
    test "composite primary key raises a clear Ecto.QueryError" do
      defmodule CompositeSchema do
        use Ecto.Schema

        @primary_key false
        schema "composite" do
          field(:a, :integer, primary_key: true)
          field(:b, :integer, primary_key: true)
          field(:label, :string)
        end
      end

      q = from(c in CompositeSchema, join: s in "sidecar", on: s.id == c.a)

      assert_raise Ecto.QueryError, fn -> to_sql(q) end
    end

    test "schemaless main source raises a clear Ecto.QueryError" do
      q = from(c in "raw_comments", join: u in "users", on: u.id == c.author_id)

      assert_raise Ecto.QueryError, fn -> to_sql(q) end
    end
  end
end
