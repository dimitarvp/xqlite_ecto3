defmodule XqliteEcto3.SandboxCancelTest do
  @moduledoc """
  The SQL Sandbox runs each test inside a transaction that is never
  committed, so nothing a test writes reaches the database file. A cancelled
  write destroys that transaction — SQLite rolls the whole thing back when it
  interrupts a write — so the driver ends the checkout with it. The test that
  cancelled loses its connection (later queries report an ownership error,
  and its check-in finds nothing to return), but nothing it wrote is durable
  and the next test checks out normally.
  """
  use ExUnit.Case, async: true

  alias Ecto.Adapters.SQL.Sandbox
  alias Ecto.Integration.TestRepo

  @slow_write "INSERT INTO sbx_cancel SELECT x + 1000000, x FROM (WITH RECURSIVE c(x) AS " <>
                "(SELECT 1 UNION ALL SELECT x + 1 FROM c LIMIT 30000000) SELECT x FROM c)"

  @tag capture_log: true
  test "a cancelled write ends the checkout and leaves nothing in the database" do
    :ok = Sandbox.checkout(TestRepo)

    TestRepo.query!("CREATE TABLE sbx_cancel(id INTEGER PRIMARY KEY, v INTEGER)")
    TestRepo.query!("INSERT INTO sbx_cancel(id, v) VALUES (1, 111)")

    assert {:error, %DBConnection.ConnectionError{}} =
             TestRepo.query(@slow_write, [], timeout: 50)

    # The sandbox transaction is gone, so this test no longer owns a
    # connection — a later write cannot quietly land in the real database.
    assert {:error, %DBConnection.OwnershipError{}} =
             TestRepo.query("INSERT INTO sbx_cancel(id, v) VALUES (2, 222)")

    assert Sandbox.checkin(TestRepo) == :not_found

    # The next checkout works, and sees a database with no trace of the
    # cancelled test: the rollback took the table with it.
    :ok = Sandbox.checkout(TestRepo)

    assert %{rows: [[0]]} =
             TestRepo.query!("SELECT count(*) FROM sqlite_schema WHERE name = 'sbx_cancel'")

    assert %{rows: [[1]]} = TestRepo.query!("SELECT 1")
    :ok = Sandbox.checkin(TestRepo)
  end
end
