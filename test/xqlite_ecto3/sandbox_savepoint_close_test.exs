defmodule XqliteEcto3.SandboxSavepointCloseTest do
  @moduledoc """
  `Ecto.Adapters.SQL.Sandbox` runs each test inside a transaction and
  turns every `Repo.transaction/2` in the test body into a savepoint
  inside it. A raw `COMMIT` in that body ends the sandbox's transaction
  and every savepoint with it, so the savepoint the driver is about to
  close is gone before it closes it.

  The caller gets that named: the close is refused with the typed
  `:savepoint_without_transaction` error rather than SQLite's "no such
  savepoint", and the connection — whose savepoint state is gone
  underneath the driver — leaves the pool, which then serves the next
  query on a replacement.
  """
  use ExUnit.Case, async: true

  alias Ecto.Adapters.SQL.Sandbox

  defmodule SandboxSavepointRepo do
    use Ecto.Repo, otp_app: :xqlite_ecto3, adapter: XqliteEcto3
  end

  setup do
    database =
      Path.join(
        System.tmp_dir!(),
        "xqlite_sbx_savepoint_#{System.unique_integer([:positive])}.db"
      )

    config = [
      database: database,
      pool: Ecto.Adapters.SQL.Sandbox,
      pool_size: 2,
      show_sensitive_data_on_connection_error: true
    ]

    Application.put_env(:xqlite_ecto3, SandboxSavepointRepo, config)
    :ok = XqliteEcto3.storage_up(config)
    start_supervised!({SandboxSavepointRepo, config})

    on_exit(fn ->
      Enum.each(["", "-wal", "-shm"], fn suffix -> File.rm(database <> suffix) end)
    end)

    :ok = Sandbox.checkout(SandboxSavepointRepo)
    SandboxSavepointRepo.query!("CREATE TABLE sbx_sp(id INTEGER PRIMARY KEY)")

    {:ok, repo: SandboxSavepointRepo}
  end

  @tag capture_log: true
  test "a raw COMMIT in the body names the transaction the close cannot find", %{repo: repo} do
    raised =
      assert_raise XqliteEcto3.Error, fn ->
        repo.transaction(fn ->
          repo.query!("INSERT INTO sbx_sp(id) VALUES (1)")
          repo.query!("COMMIT")
          :body_done
        end)
      end

    assert raised.type == :savepoint_without_transaction

    # The refused connection is gone; the pool hands out another one and
    # the next checkout works.
    assert Sandbox.checkin(repo) in [:ok, :not_found]
    :ok = Sandbox.checkout(repo)
    assert %{rows: [[1]]} = repo.query!("SELECT 1")
    :ok = Sandbox.checkin(repo)
  end

  @tag capture_log: true
  test "the rollback half of the close is refused the same way", %{repo: repo} do
    raised =
      assert_raise XqliteEcto3.Error, fn ->
        repo.transaction(fn ->
          repo.query!("INSERT INTO sbx_sp(id) VALUES (1)")
          repo.query!("COMMIT")
          repo.rollback(:asked)
        end)
      end

    assert raised.type == :savepoint_without_transaction

    assert Sandbox.checkin(repo) in [:ok, :not_found]
    :ok = Sandbox.checkout(repo)
    assert %{rows: [[1]]} = repo.query!("SELECT 1")
    :ok = Sandbox.checkin(repo)
  end

  @tag capture_log: true
  test "a raw COMMIT and BEGIN leave the counter with no savepoint to close", %{repo: repo} do
    raised =
      assert_raise XqliteEcto3.Error, fn ->
        repo.transaction(fn ->
          repo.query!("INSERT INTO sbx_sp(id) VALUES (1)")
          repo.query!("COMMIT")
          repo.query!("BEGIN")
          :body_done
        end)
      end

    assert raised.type == :savepoint_counter_underflow

    assert Sandbox.checkin(repo) in [:ok, :not_found]
    :ok = Sandbox.checkout(repo)
    assert %{rows: [[1]]} = repo.query!("SELECT 1")
    :ok = Sandbox.checkin(repo)
  end
end
