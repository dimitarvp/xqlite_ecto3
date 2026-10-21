defmodule XqliteEcto3.LockWaitLawTest do
  @moduledoc """
  A pooled call that meets another connection's lock waits as `busy_timeout`
  says and then goes through. A raw control connection holds each run's lock
  and reads the rows back; the moment a call is waiting is the first
  `{:xqlite_busy, 0, _}` from a busy observer on its connection, never a timer.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  import Ecto.Query, only: [from: 2]
  import XqliteEcto3.DriverHelper, only: [connect!: 1]

  alias XqliteEcto3.Driver
  alias XqliteEcto3.Error
  alias XqliteEcto3.Query

  @law_runs 2000
  @moduletag timeout: 300_000
  @pool [pool_size: 1, synchronous: :off, busy_timeout: 60_000, name: nil]
  @writes [:insert, :insert_all, :update_all, :query, :transaction, :exclusive]

  defmodule LockRepo do
    use Ecto.Repo, otp_app: :xqlite_ecto3, adapter: XqliteEcto3
  end

  defmodule LockRow do
    use Ecto.Schema

    schema("lock_rows", do: field(:v, :integer))
  end

  setup_all do
    paths = Map.new([:wal, :delete], &{&1, seed!(&1)})
    on_exit(fn -> for {_, p} <- paths, ext <- ["", "-wal", "-shm"], do: File.rm(p <> ext) end)

    pools =
      for mode <- [:wal, :delete], cache <- [50, 0], into: %{} do
        config = [database: paths[mode], journal_mode: mode, statement_cache_size: cache] ++ @pool
        {{mode, cache}, start_supervised!(Supervisor.child_spec({LockRepo, config}, id: config))}
      end

    {:ok, paths: paths, pools: pools}
  end

  setup ctx do
    for pool <- Map.values(ctx.pools),
        do: {:ok, _} = XqliteEcto3.with_xqlite(pool, &Xqlite.register_busy_observer(&1, self()))

    controls =
      Map.new(ctx.paths, fn {mode, path} ->
        {:ok, conn} = Xqlite.open(path, journal_mode: mode)
        on_exit(fn -> Xqlite.close(conn) end)
        {mode, conn}
      end)

    {:ok, controls: controls}
  end

  defp seed!(mode) do
    path = Path.join(System.tmp_dir!(), "lock_wait_#{System.unique_integer([:positive])}.db")
    {:ok, conn} = Xqlite.open(path, journal_mode: mode)

    for sql <- [
          "CREATE TABLE lock_rows (id INTEGER PRIMARY KEY, v INTEGER)",
          "INSERT INTO lock_rows (id, v) VALUES (1, 0)",
          "CREATE TABLE two_rows AS SELECT 1 AS id UNION ALL SELECT 2"
        ],
        do: {:ok, _} = Xqlite.query(conn, sql, [])

    # Open for the module's life, so no pool connect has to rebuild the WAL index.
    on_exit(fn -> Xqlite.close(conn) end)
    path
  end

  # The SELECT gives a deferred hold its read lock; the other modes lock at BEGIN.
  defp hold!(control, mode) do
    :ok = XqliteNIF.begin(control, mode)
    {:ok, _} = Xqlite.query(control, "SELECT count(*) FROM lock_rows", [])
  end

  defp release!(control), do: :ok = XqliteNIF.rollback(control)

  defp rows_with(control, id) do
    {:ok, %{num_rows: n}} = Xqlite.query(control, "SELECT v FROM lock_rows WHERE v = ?1", [id])
    n
  end

  # The lock goes before anything is asserted, so a failed run leaves none.
  defp hold_and_call(ctx, {mode, holder, call}, cache, opts) do
    id = System.unique_integer([:positive])
    pool = ctx.pools[{mode, cache}]
    hold!(ctx.controls[mode], holder)

    task =
      Task.async(fn ->
        LockRepo.put_dynamic_repo(pool)
        run_call(call, id, opts)
      end)

    first =
      receive do
        {:xqlite_busy, 0, _elapsed_ms} -> :waiting
        {ref, answer} when is_reference(ref) -> {:answered, answer}
      end

    release!(ctx.controls[mode])
    {first, task, id}
  end

  defp run_call(txn, id, opts) when txn in [:transaction, :exclusive],
    do: LockRepo.transaction(fn -> write(:insert, id, opts) end, [mode: txn] ++ opts)

  defp run_call(reader, _id, opts) when reader in [:all, :stream],
    do: LockRepo.transaction(fn -> read(reader, opts) end, mode: :deferred)

  defp run_call(writer, id, opts), do: {:ok, write(writer, id, opts)}

  defp row_one, do: from(r in LockRow, where: r.id == 1)

  defp read(:all, opts), do: LockRepo.all(row_one(), opts)
  defp read(:stream, opts), do: row_one() |> LockRepo.stream(opts) |> Enum.to_list()
  defp read(:aggregate, opts), do: LockRepo.aggregate(LockRow, :count, opts)
  defp read(:query, opts), do: LockRepo.query!("SELECT count(*) FROM lock_rows", [], opts)

  defp write(:insert, id, opts), do: LockRepo.insert!(%LockRow{v: id}, opts)
  defp write(:insert_all, id, opts), do: LockRepo.insert_all(LockRow, [[v: id]], opts)
  defp write(:update_all, id, opts), do: LockRepo.update_all(row_one(), [set: [v: id]], opts)

  defp write(:query, id, opts),
    do: LockRepo.query!("INSERT INTO lock_rows (v) VALUES (?1)", [id], opts)

  # A write lock stops writers in both modes; in rollback-journal mode an
  # exclusive lock stops readers too, and a reader stops a commit.
  defp lock_meeting do
    one_of([
      tuple({member_of([:wal, :delete]), constant(:immediate), member_of(@writes)}),
      tuple({constant(:delete), constant(:exclusive), member_of([:all, :stream | @writes])}),
      tuple({constant(:delete), constant(:deferred), member_of([:insert, :transaction])})
    ])
  end

  property "a pooled call that meets another connection's lock waits and then goes through",
           ctx do
    check all(
            {mode, _holder, call} = pair <- lock_meeting(),
            cache <- member_of([50, 0]),
            opts <- member_of([[], [timeout: :infinity]]),
            max_runs: @law_runs
          ) do
      {first, task, id} = hold_and_call(ctx, pair, cache, opts)

      assert first == :waiting
      assert {:ok, _} = Task.await(task, 60_000)
      assert rows_with(ctx.controls[mode], id) == if(call in [:all, :stream], do: 0, else: 1)
    end
  end

  test "a Repo insert against a held write lock waits and goes through once the lock is released",
       ctx do
    {first, task, id} = hold_and_call(ctx, {:wal, :immediate, :insert}, 50, [])
    assert first == :waiting
    assert {:ok, %LockRow{v: ^id}} = Task.await(task, 60_000)
    assert rows_with(ctx.controls.wal, id) == 1
  end

  property "a transaction start that cannot take the lock keeps the connection", ctx do
    states =
      Map.new(ctx.paths, fn {mode, path} ->
        {mode, connect!(database: path, journal_mode: mode, busy_timeout: 0)}
      end)

    select_one = %Query{statement: "SELECT 1", ref: make_ref()}

    check all(
            mode <- member_of([:wal, :delete]),
            holder <- member_of([:immediate, :exclusive]),
            begin <- member_of([[], [mode: :immediate], [mode: :exclusive]]),
            max_runs: @law_runs
          ) do
      hold!(ctx.controls[mode], holder)
      answer = Driver.handle_begin(begin, states[mode])
      release!(ctx.controls[mode])

      assert {:error, %Error{type: :database_busy, details: %{retry: :call}}, state} = answer
      assert {:ok, false} = XqliteNIF.transaction_status(state.conn)
      assert {:ok, _, %{rows: [[1]]}, _} = Driver.handle_execute(select_one, [], [], state)
    end
  end

  property "both busy shapes wrap with SQLite's message and xqlite's map" do
    txt = string([0, ?', ?", ?\\, ?a..?z, 0xE9, 0x4E2D, 0x1F600])
    u64 = integer(0..(2 ** 64 - 1))
    retry = member_of([:call, :transaction, :none])
    busy = %{code: integer(), message: txt, retry: retry, retries: u64, elapsed_ms: u64, sql: txt}

    reasons =
      one_of([
        tuple({constant(:database_busy), optional_map(busy, [:sql])}),
        tuple({constant(:database_locked), fixed_map(%{code: integer(), message: txt})})
      ])

    check all({tag, %{message: message} = details} = reason <- reasons, max_runs: @law_runs) do
      assert %Error{type: ^tag, message: ^message, details: ^details} = Error.wrap(reason)
    end
  end

  test "a busy answer keeps SQLite's message and xqlite's map" do
    busy = %{code: 5, message: "database is locked", retry: :call, retries: 3, elapsed_ms: 12}

    assert %Error{type: :database_busy, message: "database is locked", details: ^busy} =
             Error.wrap({:database_busy, busy})
  end

  property "a write that must restart its transaction answers at once and ends it", ctx do
    check all(
            {mode, _cache} = pool <- member_of(Map.keys(ctx.pools)),
            reader <- member_of([:all, :aggregate, :query]),
            writer <- member_of([:insert, :update_all, :query]),
            max_runs: @law_runs
          ) do
      LockRepo.put_dynamic_repo(ctx.pools[pool])
      id = System.unique_integer([:positive])
      hold!(ctx.controls[mode], :immediate)
      outcome = read_then_write(reader, writer, id)
      release!(ctx.controls[mode])

      assert %Error{type: :database_busy, details: %{retry: :transaction}} = outcome
      refute_received {:xqlite_busy, _, _}
      assert {:ok, %{rows: [[1]]}} = LockRepo.query("SELECT 1")
      assert rows_with(ctx.controls[mode], id) == 0
    end
  end

  defp read_then_write(reader, writer, id) do
    LockRepo.transaction(fn -> {read(reader, []), write(writer, id, [])} end, mode: :deferred)
  rescue
    error in Error -> error
  end

  test "a table lock answers database_locked and keeps the connection", ctx do
    LockRepo.put_dynamic_repo(ctx.pools[{:wal, 50}])
    drop = fn _id -> LockRepo.query("DROP TABLE two_rows") end
    rows = from(r in "two_rows", select: r.id)

    assert {:ok, [{:error, %Error{type: :database_locked, details: details} = error}]} =
             LockRepo.transaction(fn ->
               rows |> LockRepo.stream(max_rows: 1) |> Stream.map(drop) |> Enum.take(1)
             end)

    assert error.message == details.message
    assert Bitwise.band(details.code, 0xFF) == 6
    assert {:ok, %{rows: [[2]]}} = LockRepo.query("SELECT count(*) FROM two_rows")
  end

  test "a statement's :timeout ends its lock wait", ctx do
    insert = %Query{statement: "INSERT INTO lock_rows (v) VALUES (0)", ref: make_ref()}

    for size <- [50, 0] do
      state = connect!(database: ctx.paths.wal, busy_timeout: 120_000, statement_cache_size: size)
      hold!(ctx.controls.wal, :immediate)
      answer = Driver.handle_execute(insert, [], [timeout: 50], state)
      release!(ctx.controls.wal)

      assert {:error, %DBConnection.ConnectionError{}, state} = answer
      assert {:ok, _query, _result, _state} = Driver.handle_execute(insert, [], [], state)
    end
  end
end
