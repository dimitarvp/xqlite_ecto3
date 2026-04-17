defmodule XqliteEcto3.ConnectionErrorWrappingTest do
  use ExUnit.Case, async: true

  alias Ecto.Integration.TestRepo

  describe "DBConnection.OwnershipError" do
    test "message is enriched with 'See Ecto.Adapters.SQL.Sandbox docs' when raised via Repo.query!" do
      error =
        assert_raise DBConnection.OwnershipError, fn ->
          TestRepo.query!("SELECT 1")
        end

      assert error.message =~ "See Ecto.Adapters.SQL.Sandbox docs for more information."
    end

    test "message is enriched when raised via Repo.all on a schema" do
      import Ecto.Query

      error =
        assert_raise DBConnection.OwnershipError, fn ->
          TestRepo.all(from(p in Ecto.Integration.Post, select: p.id))
        end

      assert error.message =~ "See Ecto.Adapters.SQL.Sandbox docs for more information."
    end

    test "message is enriched when raised via Repo.query! with parameters" do
      error =
        assert_raise DBConnection.OwnershipError, fn ->
          TestRepo.query!("SELECT ?1", [42])
        end

      assert error.message =~ "See Ecto.Adapters.SQL.Sandbox docs for more information."
    end
  end
end
