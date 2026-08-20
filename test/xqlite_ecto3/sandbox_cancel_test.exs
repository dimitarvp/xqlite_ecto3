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

  defmodule SandboxCancelRepo do
    use Ecto.Repo, otp_app: :xqlite_ecto3, adapter: XqliteEcto3
  end

  @slow_write "INSERT INTO sbx_cancel SELECT x + 1000000, x FROM (WITH RECURSIVE c(x) AS " <>
                "(SELECT 1 UNION ALL SELECT x + 1 FROM c LIMIT 30000000) SELECT x FROM c)"

  @tag capture_log: true
  test "a cancelled write ends the checkout and leaves nothing in the database" do
    database =
      Path.join(
        System.tmp_dir!(),
        "xqlite_sbx_cancel_#{System.unique_integer([:positive])}.db"
      )

    # A dedicated repo: the cancelled statement legitimately holds its
    # connection past DBConnection's default 50 ms queue deadline, and on a
    # shared pool a queued sibling test then gets this holder evicted
    # mid-statement. Generous deadlines keep the eviction machinery out of
    # what this test measures.
    config = [
      database: database,
      pool: Ecto.Adapters.SQL.Sandbox,
      pool_size: 2,
      queue_target: 5_000,
      queue_interval: 5_000,
      ownership_timeout: 120_000,
      show_sensitive_data_on_connection_error: true
    ]

    Application.put_env(:xqlite_ecto3, SandboxCancelRepo, config)
    :ok = XqliteEcto3.storage_up(config)
    start_supervised!({SandboxCancelRepo, config})

    on_exit(fn ->
      Enum.each(["", "-wal", "-shm"], fn suffix -> File.rm(database <> suffix) end)
    end)

    :ok = Sandbox.checkout(SandboxCancelRepo)

    SandboxCancelRepo.query!("CREATE TABLE sbx_cancel(id INTEGER PRIMARY KEY, v INTEGER)")
    SandboxCancelRepo.query!("INSERT INTO sbx_cancel(id, v) VALUES (1, 111)")

    assert {:error, %DBConnection.ConnectionError{}} =
             SandboxCancelRepo.query(@slow_write, [], timeout: 50)

    # The cancelled write destroyed the sandbox transaction, and the pooled
    # timeout also trips DBConnection's checkout deadline, which tears the
    # connection down. Which error a query issued DURING that teardown sees
    # is a timing race (ownership lost, a fresh empty sandbox, or an exit
    # from the dying holder), so the test asserts only the invariants: the
    # check-in below tolerates both outcomes, and a fresh checkout must see
    # a database with no trace of the cancelled test.
    assert Sandbox.checkin(SandboxCancelRepo) in [:ok, :not_found]

    :ok = Sandbox.checkout(SandboxCancelRepo)

    assert %{rows: [[0]]} =
             SandboxCancelRepo.query!(
               "SELECT count(*) FROM sqlite_schema WHERE name = 'sbx_cancel'"
             )

    assert %{rows: [[1]]} = SandboxCancelRepo.query!("SELECT 1")
    :ok = Sandbox.checkin(SandboxCancelRepo)
  end
end
