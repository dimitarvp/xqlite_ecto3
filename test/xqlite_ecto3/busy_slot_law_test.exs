defmodule XqliteEcto3.BusySlotLawTest do
  @moduledoc """
  SQLite gives a connection one busy callback, and a busy observer
  registered through `XqliteEcto3.with_xqlite/3` takes it. What that
  does to the wait the repo configured is what `with_xqlite/3`'s own
  documentation promises, and this file is where those promises are
  checked.

  Four rules, all of them about a pool of one whose single connection
  is trying to write while a second connection holds the write lock:

  1. The refusal is the same whatever the busy callback holds — a
     contended write always comes back
     `%XqliteEcto3.Error{type: :database_busy_or_locked}`.
  2. A registered observer receives at least one `{:xqlite_busy, _, _}`
     message per contended write, and a connection with none receives
     nothing.
  3. While an observer holds the callback, `PRAGMA busy_timeout` reads
     0 although the connection still waits; unregistering the last
     observer puts the configured value back, and unregistering any
     other one does not.
  4. Two ways to lose the wait: an authorizer that denies `PRAGMA`
     leaves the library nothing to remember when it takes the callback,
     and a raw `PRAGMA busy_timeout = N` replaces the callback, so
     observers stop receiving messages while their handles still look
     registered.

  Nothing here measures how long anything took: every rule is a
  structured outcome, a message count, or a `PRAGMA` reading. The run
  count is small on purpose — each run sits through a real lock wait,
  which no amount of generated variety makes cheaper — and the
  generated domain is the number of observers registered for the run,
  which is what rule 3 is about.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias XqliteEcto3.Error

  # Small enough that a run is cheap, large enough that SQLite's retry
  # schedule calls the busy callback several times before giving up.
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
  # together with how many observer messages it produced. The write runs
  # outside any `with_xqlite/3` callback and takes its own checkout, so a
  # run never holds a pooled connection across the wait.
  defp contended_write(repo, path) do
    holder = hold_write_lock(path)
    _ = drain_busy_messages()
    result = repo.query("UPDATE busy_rows SET v = v + 1", [])
    messages = drain_busy_messages()
    release_write_lock(holder)

    {result, messages}
  end

  defp drain_busy_messages(seen \\ 0) do
    receive do
      {:xqlite_busy, _retries, _elapsed_ms} -> drain_busy_messages(seen + 1)
    after
      0 -> seen
    end
  end

  defp read_busy_timeout(conn) do
    {:ok, %{rows: [[value]]}} = XqliteNIF.query(conn, "PRAGMA busy_timeout", [])
    value
  end

  defp register_observers(repo, count) do
    XqliteEcto3.with_xqlite(repo, fn conn ->
      Enum.map(1..count//1, fn _ ->
        {:ok, handle} = Xqlite.register_busy_observer(conn, self())
        handle
      end)
    end)
  end

  # Unregisters one handle per checkout and reports what `PRAGMA
  # busy_timeout` read right after each one.
  defp unregister_observers(repo, handles) do
    Enum.map(handles, fn handle ->
      XqliteEcto3.with_xqlite(repo, fn conn ->
        :ok = Xqlite.unregister_busy_observer(conn, handle)
        read_busy_timeout(conn)
      end)
    end)
  end

  # --- the law ---------------------------------------------------------------

  property "observers change what is reported, never whether the write waits",
           context do
    check all(observers <- integer(0..3), max_runs: @observer_runs) do
      handles = register_observers(BusySlotRepo, observers)
      held = XqliteEcto3.with_xqlite(BusySlotRepo, &read_busy_timeout/1)

      {result, messages} = contended_write(BusySlotRepo, context.path)

      readings = unregister_observers(BusySlotRepo, handles)

      assert {:error, %Error{type: :database_busy_or_locked}} = result

      assert held == expected_held_reading(observers)
      assert observers == 0 or messages >= 1
      assert observers > 0 or messages == 0

      assert readings |> Enum.drop(-1) |> Enum.all?(&(&1 == 0))
      assert readings == [] or List.last(readings) == @busy_timeout
    end
  end

  defp expected_held_reading(0), do: @busy_timeout
  defp expected_held_reading(_observers), do: 0

  # --- the anchors the law generalises ---------------------------------------

  test "a contended write on a connection with no observer is refused and waits",
       context do
    {result, messages} = contended_write(BusySlotRepo, context.path)

    assert {:error, %Error{type: :database_busy_or_locked}} = result
    assert messages == 0

    assert XqliteEcto3.with_xqlite(BusySlotRepo, &read_busy_timeout/1) == @busy_timeout
  end

  test "one observer sees the wait it does not change", context do
    [handle] = register_observers(BusySlotRepo, 1)

    assert XqliteEcto3.with_xqlite(BusySlotRepo, &read_busy_timeout/1) == 0

    {result, messages} = contended_write(BusySlotRepo, context.path)

    assert {:error, %Error{type: :database_busy_or_locked}} = result
    assert messages >= 1

    assert unregister_observers(BusySlotRepo, [handle]) == [@busy_timeout]
  end

  # --- the two ways the wait is lost -----------------------------------------

  test "an authorizer that denies PRAGMA leaves nothing to put back" do
    path = database_path("authorizer")
    seed!(path)
    start_supervised!({BusySlotEdgeRepo, repo_config(path)})
    on_exit(fn -> remove_database(path) end)

    handle =
      XqliteEcto3.with_xqlite(BusySlotEdgeRepo, fn conn ->
        :ok = Xqlite.set_authorizer(conn, [:pragma])
        {:ok, handle} = Xqlite.register_busy_observer(conn, self())
        :ok = Xqlite.remove_authorizer(conn)
        handle
      end)

    {result, _messages} = contended_write(BusySlotEdgeRepo, path)

    assert {:error, %Error{type: :database_busy_or_locked}} = result
    assert unregister_observers(BusySlotEdgeRepo, [handle]) == [0]
  end

  test "a raw PRAGMA busy_timeout silences the observers it does not unregister" do
    path = database_path("raw_pragma")
    seed!(path)
    start_supervised!({BusySlotEdgeRepo, repo_config(path)})
    on_exit(fn -> remove_database(path) end)

    [handle] = register_observers(BusySlotEdgeRepo, 1)

    {:ok, _} = BusySlotEdgeRepo.query("PRAGMA busy_timeout = 1500", [])

    {result, messages} = contended_write(BusySlotEdgeRepo, path)

    assert {:error, %Error{type: :database_busy_or_locked}} = result
    assert messages == 0

    # The handle still looks registered, and giving it back reverts the
    # value the raw PRAGMA wrote.
    assert unregister_observers(BusySlotEdgeRepo, [handle]) == [@busy_timeout]
  end
end
