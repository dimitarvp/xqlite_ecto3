defmodule XqliteEcto3.ConnectionErrorWrappingTest do
  use ExUnit.Case, async: true

  alias Ecto.Integration.TestRepo

  # We assert only on the exception TYPE — that's the structural guarantee
  # we're responsible for. Ecto's own test suite verifies that ecto_sql
  # enriches OwnershipError's message with the Sandbox docs pointer; we
  # don't re-check that text here. If Ecto ever changes the enrichment
  # wording, our tests stay green.

  describe "DBConnection.OwnershipError" do
    test "Repo.query! without sandbox checkout raises OwnershipError" do
      assert_raise DBConnection.OwnershipError, fn ->
        TestRepo.query!("SELECT 1")
      end
    end

    test "Repo.all on a schema without sandbox checkout raises OwnershipError" do
      import Ecto.Query

      assert_raise DBConnection.OwnershipError, fn ->
        TestRepo.all(from(p in Ecto.Integration.Post, select: p.id))
      end
    end

    test "Repo.query! with parameters raises OwnershipError" do
      assert_raise DBConnection.OwnershipError, fn ->
        TestRepo.query!("SELECT ?1", [42])
      end
    end
  end
end
