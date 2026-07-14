defmodule XqliteEcto3.ExplainAnalyzeTest do
  use XqliteEcto3.AdapterCase, async: true

  defmodule EU do
    use XqliteEcto3.TestSchemas.StandardUser, table: "explain_users"
  end

  setup_all do
    create_table!("explain_users", user_columns())
  end

  setup do
    clear_table!("explain_users")

    Repo.insert!(%EU{name: "ada", email: "a@x", age: 30})
    Repo.insert!(%EU{name: "bob", email: "b@x", age: 20})
    Repo.insert!(%EU{name: "cyd", email: "c@x", age: 40})
    :ok
  end

  describe "select queries" do
    test "returns the structured report with real execution stats" do
      q = from(u in EU, where: u.age > ^25, select: u.name)

      assert {:ok, %Xqlite.ExplainAnalyze{} = report} = XqliteEcto3.explain_analyze(Repo, q)

      assert report.rows_produced == 2
      assert is_integer(report.wall_time_ns) and report.wall_time_ns >= 0
      assert is_map(report.stmt_counters)
      assert is_list(report.scans) and report.scans != []
      assert is_binary(report.query_plan) or is_list(report.query_plan)
    end

    test "binds parameters through the production encoding path" do
      q = from(u in EU, where: u.name == ^"ada" and u.age >= ^1, select: u.email)

      assert {:ok, %Xqlite.ExplainAnalyze{rows_produced: 1}} =
               XqliteEcto3.explain_analyze(Repo, q)
    end

    test "a schema module is a valid queryable" do
      assert {:ok, %Xqlite.ExplainAnalyze{rows_produced: 3}} =
               XqliteEcto3.explain_analyze(Repo, EU)
    end
  end

  describe "write operations" do
    test "update_all executes for real without wrap_in_transaction (the documented footgun)" do
      q = from(u in EU, where: u.age > ^25, update: [set: [age: 99]])

      assert {:ok, %Xqlite.ExplainAnalyze{}} =
               XqliteEcto3.explain_analyze(Repo, q, operation: :update_all)

      assert Repo.aggregate(from(u in EU, where: u.age == 99), :count) == 2
    end

    test "wrap_in_transaction: true rolls the execution back" do
      q = from(u in EU, where: u.age > ^25, update: [set: [age: 99]])

      assert {:ok, %Xqlite.ExplainAnalyze{}} =
               XqliteEcto3.explain_analyze(Repo, q,
                 operation: :update_all,
                 wrap_in_transaction: true
               )

      assert Repo.aggregate(from(u in EU, where: u.age == 99), :count) == 0
    end

    test "delete_all with wrap_in_transaction leaves the rows in place" do
      q = from(u in EU, where: u.age > ^0)

      assert {:ok, %Xqlite.ExplainAnalyze{}} =
               XqliteEcto3.explain_analyze(Repo, q,
                 operation: :delete_all,
                 wrap_in_transaction: true
               )

      assert Repo.aggregate(EU, :count) == 3
    end
  end
end
