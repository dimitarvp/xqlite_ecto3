defmodule XqliteEcto3.BusySlotLawTest do
  @moduledoc """
  xqlite holds a connection's one busy slot from the open on, and a busy
  observer registered through `XqliteEcto3.with_xqlite/3` only listens
  to it. What that leaves of the wait the repo configured is what
  `with_xqlite/3`'s own documentation promises, and this file is where
  those promises are checked.

  Three rules, all of them about a pool of one whose single connection
  is trying to write while a second connection holds the write lock:

  1. Every registered observer hears the write's wait, each getting a
     `{:xqlite_busy, 0, _}` message as it starts, and a connection with
     none receives nothing.
  2. Neither observers nor an authorizer that denies `PRAGMA` change the
     wait: the write waits until `busy_timeout` gives up and comes back
     `%XqliteEcto3.Error{type: :database_busy}` with `retry: :call`, and
     `Xqlite.get_busy_timeout/1` reads the configured wait.
  3. `PRAGMA busy_timeout` read through SQL answers 0, and written
     through `Repo.query/3` it sets the wait.

  Nothing here measures how long anything took: every rule is a
  structured outcome, a message count, or a reading. The run count is
  small on purpose — each run sits through a real lock wait, which no
  amount of generated variety makes cheaper.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias XqliteEcto3.Error

  # Small enough that a run is cheap, large enough that the wait sleeps
  # several times before it gives up.
  @busy_timeout 600

  @observer_runs 24

  @moduletag timeout: 300_000

  defmodule BusySlotRepo do
    use Ecto.Repo, otp_app: :xqlite_ecto3, adapter: XqliteEcto3
  end

  defmodule BusySlotEdgeRepo do
    use Ecto.Repo, otp_app: :xqlite_ecto3, adapter: XqliteEcto3
  end

  setup_all do
    path = database_path("shared")
    seed!(path)
    start_supervised!({BusySlotRepo, repo_config(path)})
    on_exit(fn -> remove_database(path) end)

    {:ok, path: path}
  end

  defp database_path(label) do
    Path.join(
      System.tmp_dir!(),
      "xqlite_ecto3_busy_slot_#{label}_#{:erlang.unique_integer([:positive])}.db"
    )
  end

  defp repo_config(path) do
    [
      adapter: XqliteEcto3,
      database: path,
      pool_size: 1,
      busy_timeout: @busy_timeout,
      synchronous: :off
    ]
  end

  defp seed!(path) do
    remove_database(path)
    {:ok, conn} = Xqlite.open(path)
    {:ok, _} = Xqlite.query(conn, "PRAGMA journal_mode = wal", [])

    {:ok, _} =
      Xqlite.query(conn, "CREATE TABLE busy_rows (id INTEGER PRIMARY KEY, v INTEGER)", [])

    {:ok, _} = Xqlite.query(conn, "INSERT INTO busy_rows (id, v) VALUES (1, 0)", [])
    :ok = Xqlite.close(conn)
  end

  defp remove_database(path) do
    Enum.each(["", "-wal", "-shm"], fn suffix -> File.rm(path <> suffix) end)
  end

  # A second connection that takes the write lock and keeps it. It waits
  # for nothing itself, so a test never queues behind its own fixture.
  defp hold_write_lock(path) do
    {:ok, conn} = Xqlite.open(path)
    :ok = XqliteNIF.begin(conn, :immediate)
    {:ok, _} = Xqlite.query(conn, "UPDATE busy_rows SET v = v + 1", [])
    conn
  end

  defp release_write_lock(conn) do
    :ok = XqliteNIF.rollback(conn)
    :ok = Xqlite.close(conn)
  end

  # Runs one write against a locked database and reports what came back
  # together with the `retries` of every observer message it produced.
  # The write runs outside any `with_xqlite/3` callback and takes its own
  # checkout, so a run never holds a pooled connection across the wait.
  defp contended_write(repo, path) do
    holder = hold_write_lock(path)
    _ = drain_busy_messages()
    result = repo.query("UPDATE busy_rows SET v = v + 1", [])
    heard = drain_busy_messages()
    release_write_lock(holder)

    {result, heard}
  end

  defp drain_busy_messages(heard \\ []) do
    receive do
      {:xqlite_busy, retries, _elapsed_ms} -> drain_busy_messages([retries | heard])
    after
      0 -> heard
    end
  end

  defp register_observers(repo, count, deny_pragma? \\ false) do
    XqliteEcto3.with_xqlite(repo, fn conn ->
      if deny_pragma?, do: :ok = Xqlite.set_authorizer(conn, [:pragma])

      Enum.map(1..count//1, fn _ ->
        {:ok, handle} = Xqlite.register_busy_observer(conn, self())
        handle
      end)
    end)
  end

  defp unregister_observers(repo, handles) do
    XqliteEcto3.with_xqlite(repo, fn conn ->
      :ok = Xqlite.remove_authorizer(conn)
      Enum.each(handles, &(:ok = Xqlite.unregister_busy_observer(conn, &1)))
    end)
  end

  # --- the law ---------------------------------------------------------------

  property "observers hear every wait and change none of it", context do
    check all(
            observers <- integer(0..3),
            deny_pragma? <- boolean(),
            max_runs: @observer_runs
          ) do
      handles = register_observers(BusySlotRepo, observers, deny_pragma?)

      {result, heard} = contended_write(BusySlotRepo, context.path)

      wait = XqliteEcto3.with_xqlite(BusySlotRepo, &Xqlite.get_busy_timeout/1)
      unregister_observers(BusySlotRepo, handles)

      assert {:error, %Error{type: :database_busy, details: %{retry: :call, retries: retries}}} =
               result

      assert retries >= 1
      assert Enum.count(heard, &(&1 == 0)) == observers
      assert observers > 0 or heard == []
      assert wait == {:ok, @busy_timeout}
      assert BusySlotRepo.query!("PRAGMA busy_timeout").rows == [[0]]
    end
  end

  # --- the anchors the law generalises ---------------------------------------

  test "one observer sees the wait it does not change", context do
    handles = register_observers(BusySlotRepo, 1)

    {result, heard} = contended_write(BusySlotRepo, context.path)

    assert {:error, %Error{type: :database_busy, details: %{retry: :call}}} = result
    assert Enum.count(heard, &(&1 == 0)) == 1

    assert XqliteEcto3.with_xqlite(BusySlotRepo, &Xqlite.get_busy_timeout/1) ==
             {:ok, @busy_timeout}

    unregister_observers(BusySlotRepo, handles)
  end

  test "PRAGMA busy_timeout = 1500 through Repo.query/3 sets the wait" do
    path = database_path("raw_pragma")
    seed!(path)
    start_supervised!({BusySlotEdgeRepo, repo_config(path)})
    on_exit(fn -> remove_database(path) end)

    handles = register_observers(BusySlotEdgeRepo, 1)

    assert {:ok, _} = BusySlotEdgeRepo.query("PRAGMA busy_timeout = 1500", [])
    assert XqliteEcto3.with_xqlite(BusySlotEdgeRepo, &Xqlite.get_busy_timeout/1) == {:ok, 1500}
    assert BusySlotEdgeRepo.query!("PRAGMA busy_timeout").rows == [[0]]

    unregister_observers(BusySlotEdgeRepo, handles)
  end
end
