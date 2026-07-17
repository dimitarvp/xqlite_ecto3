defmodule XqliteEcto3.ObservabilityTest do
  use ExUnit.Case, async: true

  import XqliteEcto3.DriverHelper, only: [connect!: 1]

  alias XqliteEcto3.Driver
  alias XqliteNIF, as: NIF

  defmodule ObsRepo do
    use Ecto.Repo, otp_app: :xqlite_ecto3_obs_test, adapter: XqliteEcto3
  end

  describe "repo-level txn_state and connection_stats" do
    setup do
      start_supervised!({ObsRepo, database: ":memory:", pool_size: 1})
      :ok
    end

    test "txn_state on an idle plain pool reports :none" do
      assert {:ok, :none} = XqliteEcto3.txn_state(ObsRepo)
    end

    test "connection_stats returns integer counters" do
      assert {:ok, stats} = XqliteEcto3.connection_stats(ObsRepo)
      assert is_map(stats)
      assert map_size(stats) > 0
      assert Enum.all?(stats, fn {_k, v} -> is_integer(v) end)
    end
  end

  describe "connect-time hook subscribers" do
    test "config-registered update hook delivers messages from the connection" do
      Process.register(self(), :xq_obs_update_listener)

      state = connect!(hooks: [update: :xq_obs_update_listener])
      {:ok, 0} = NIF.execute(state.conn, "CREATE TABLE t (id INTEGER PRIMARY KEY)", [])
      {:ok, 1} = NIF.execute(state.conn, "INSERT INTO t VALUES (7)", [])

      assert_receive {:xqlite_update, :insert, "main", "t", 7}
    end

    test "progress hook accepts every_n and delivers ticks" do
      Process.register(self(), :xq_obs_progress_listener)

      state = connect!(hooks: [progress: {:xq_obs_progress_listener, every_n: 1}])

      {:ok, _} =
        NIF.query(
          state.conn,
          "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c WHERE x < 200) " <>
            "SELECT count(*) FROM c",
          []
        )

      assert_receive {:xqlite_progress, _count, _elapsed_ms}
    end

    test "unregistered subscriber name is a structured connect error" do
      assert {:error, {:hook_subscriber_not_registered, :xq_obs_no_such_proc}} =
               Driver.connect(database: ":memory:", hooks: [update: :xq_obs_no_such_proc])
    end

    test "unknown hook kind is a structured connect error" do
      Process.register(self(), :xq_obs_bad_kind_listener)

      assert {:error, {:invalid_hook_config, {:frobnicate, :xq_obs_bad_kind_listener}}} =
               Driver.connect(
                 database: ":memory:",
                 hooks: [frobnicate: :xq_obs_bad_kind_listener]
               )
    end

    test "hooks config reaches connections opened through a repo" do
      Process.register(self(), :xq_obs_repo_listener)

      start_supervised!(
        {ObsRepo, database: ":memory:", pool_size: 1, hooks: [update: :xq_obs_repo_listener]}
      )

      ObsRepo.query!("CREATE TABLE t (id INTEGER PRIMARY KEY)")
      ObsRepo.query!("INSERT INTO t VALUES (42)")

      assert_receive {:xqlite_update, :insert, "main", "t", 42}
    end
  end
end

defmodule XqliteEcto3.ObservabilitySandboxTest do
  use XqliteEcto3.AdapterCase, async: true

  test "under Sandbox, txn_state observes the sandboxed connection" do
    assert {:ok, :write} = XqliteEcto3.txn_state(Repo)
  end
end
