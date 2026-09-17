defmodule XqliteEcto3.DriverStatementCacheTest do
  use ExUnit.Case, async: true

  import XqliteEcto3.DriverHelper, only: [connect!: 1]

  alias XqliteEcto3.Driver
  alias XqliteEcto3.Query
  alias XqliteNIF, as: NIF

  defp seeded!(opts \\ []) do
    state = connect!(opts)
    {:ok, _} = NIF.execute(state.conn, "CREATE TABLE t (x INTEGER, s TEXT)", [])
    {:ok, 1} = NIF.execute(state.conn, "INSERT INTO t VALUES (1, 'one')", [])
    {:ok, 1} = NIF.execute(state.conn, "INSERT INTO t VALUES (2, 'two')", [])
    state
  end

  defp execute!(state, sql, params, opts \\ []) do
    query = %Query{statement: sql}

    assert {:ok, _query, result, new_state} =
             Driver.handle_execute(query, params, opts, state)

    {result, new_state}
  end

  describe "caching behavior" do
    test "a repeated statement is cached once and stays correct" do
      state = seeded!()

      {r1, state} = execute!(state, "SELECT x FROM t ORDER BY x", [])
      assert %{rows: [[1], [2]], num_rows: 2} = r1
      assert map_size(state.stmt_cache) == 1

      {r2, state} = execute!(state, "SELECT x FROM t ORDER BY x", [])
      assert %{rows: [[1], [2]], num_rows: 2} = r2
      assert map_size(state.stmt_cache) == 1
    end

    test "rebinding across reuses respects new params" do
      state = seeded!()

      {r1, state} = execute!(state, "SELECT s FROM t WHERE x = ?1", [1])
      assert %{rows: [["one"]]} = r1

      {r2, _state} = execute!(state, "SELECT s FROM t WHERE x = ?1", [2])
      assert %{rows: [["two"]]} = r2
    end

    test "DML through the cache reports changes as num_rows" do
      state = seeded!()

      {r1, state} = execute!(state, "UPDATE t SET s = 'both'", [])
      assert %{num_rows: 2, rows: nil, changes: 2} = r1

      {r2, _state} = execute!(state, "SELECT count(*) FROM t WHERE s = 'both'", [])
      assert %{rows: [[2]]} = r2
    end

    test "statement_cache_size: 0 disables caching entirely" do
      state = seeded!(statement_cache_size: 0)

      {r1, state} = execute!(state, "SELECT x FROM t ORDER BY x", [])
      assert %{rows: [[1], [2]]} = r1
      assert map_size(state.stmt_cache) == 0
    end

    test "DDL after a DML through the cache reports zero, not the stale change count" do
      state = seeded!()

      {dml, state} = execute!(state, "UPDATE t SET s = 'x'", [])
      assert %{num_rows: 2, changes: 2} = dml

      # CREATE INDEX changes no rows, but sqlite3_changes() is sticky at 2.
      # num_rows must be gated on total_changes moving, not on empty columns.
      {ddl, state} = execute!(state, "CREATE INDEX idx_t_x ON t (x)", [])
      assert %{num_rows: 0, rows: nil, changes: 0} = ddl

      {dml2, _state} = execute!(state, "UPDATE t SET s = 'y' WHERE x = 1", [])
      assert %{num_rows: 1, changes: 1} = dml2
    end

    test "a PRAGMA set after a DML through the cache reports zero" do
      state = seeded!()

      {dml, state} = execute!(state, "UPDATE t SET s = 'x'", [])
      assert %{num_rows: 2} = dml

      {pragma, _state} = execute!(state, "PRAGMA user_version = 7", [])
      assert %{num_rows: 0, changes: 0} = pragma
    end

    test "cached and one-shot paths agree on a columnless statement's num_rows" do
      cached = seeded!()
      oneshot = seeded!(statement_cache_size: 0)

      {_c, cached} = execute!(cached, "UPDATE t SET s = 'x'", [])
      {_o, oneshot} = execute!(oneshot, "UPDATE t SET s = 'x'", [])

      {c_ddl, _cached} = execute!(cached, "CREATE INDEX idx_c ON t (x)", [])
      {o_ddl, _oneshot} = execute!(oneshot, "CREATE INDEX idx_o ON t (x)", [])

      assert c_ddl.num_rows == 0
      assert c_ddl.num_rows == o_ddl.num_rows
    end

    test "an invalid statement_cache_size is a structured connect error" do
      assert {:error, %XqliteEcto3.Error{type: :invalid_statement_cache_size}} =
               Driver.connect(database: ":memory:", statement_cache_size: :lots)
    end
  end

  # The no-op build emits nothing to assert on, so this does not compile
  # into it; that build's own coverage is the smoke file.
  if XqliteEcto3.Telemetry.enabled?() do
    describe "cache telemetry" do
      test "miss, hit, and eviction events fire with counts" do
        handler_id = "cache-telemetry-#{System.unique_integer([:positive])}"
        me = self()

        :ok =
          :telemetry.attach_many(
            handler_id,
            [
              [:xqlite_ecto3, :statement_cache, :hit],
              [:xqlite_ecto3, :statement_cache, :miss],
              [:xqlite_ecto3, :statement_cache, :evicted]
            ],
            fn event, measurements, metadata, _ ->
              send(me, {:cache_tel, event, measurements, metadata})
            end,
            nil
          )

        on_exit(fn -> :telemetry.detach(handler_id) end)

        state = seeded!(statement_cache_size: 1)

        {_r, state} = execute!(state, "SELECT x FROM t WHERE x = ?1", [1])

        assert_receive {:cache_tel, [:xqlite_ecto3, :statement_cache, :miss], m1,
                        %{conn: miss_conn, sql: "SELECT x FROM t WHERE x = ?1"}}

        # The cache is per connection; :conn is the discriminator.
        assert miss_conn == state.conn
        assert m1.cached_count == 0
        assert is_integer(m1.monotonic_time)

        {_r, state} = execute!(state, "SELECT x FROM t WHERE x = ?1", [2])

        # Handlers are process-global: filter to this cache's own events by SQL,
        # else a concurrent connection's hit is measured instead of this one's.
        assert_receive {:cache_tel, [:xqlite_ecto3, :statement_cache, :hit], m2,
                        %{sql: "SELECT x FROM t WHERE x = ?1"}}

        assert m2.cached_count == 1

        {_r, _state} = execute!(state, "SELECT x FROM t ORDER BY x", [])

        assert_receive {:cache_tel, [:xqlite_ecto3, :statement_cache, :miss], _m3,
                        %{sql: "SELECT x FROM t ORDER BY x"}}

        assert_receive {:cache_tel, [:xqlite_ecto3, :statement_cache, :evicted], m4,
                        %{sql: "SELECT x FROM t WHERE x = ?1"}}

        assert m4.cached_count == 2
      end
    end
  end

  describe "LRU eviction" do
    test "exceeding capacity evicts the least recently used statement" do
      state = seeded!(statement_cache_size: 2)

      {_r, state} = execute!(state, "SELECT 1", [])
      {_r, state} = execute!(state, "SELECT 2", [])
      {_r, state} = execute!(state, "SELECT 3", [])

      assert map_size(state.stmt_cache) == 2
      refute Map.has_key?(state.stmt_cache, "SELECT 1")
      assert Map.has_key?(state.stmt_cache, "SELECT 2")
      assert Map.has_key?(state.stmt_cache, "SELECT 3")
    end

    test "a cache hit refreshes recency" do
      state = seeded!(statement_cache_size: 2)

      {_r, state} = execute!(state, "SELECT 1", [])
      {_r, state} = execute!(state, "SELECT 2", [])
      # touch "SELECT 1" so "SELECT 2" becomes the eviction candidate
      {_r, state} = execute!(state, "SELECT 1", [])
      {_r, state} = execute!(state, "SELECT 3", [])

      assert Map.has_key?(state.stmt_cache, "SELECT 1")
      refute Map.has_key?(state.stmt_cache, "SELECT 2")
      assert Map.has_key?(state.stmt_cache, "SELECT 3")
    end
  end

  describe "refusals and resilience" do
    test "multi-statement SQL errors identically on both paths and is never cached" do
      state = seeded!()
      query = %Query{statement: "UPDATE t SET x = x; UPDATE t SET x = x"}

      # handle_execute has never supported multi-statement SQL — the one-shot
      # NIF refuses it too. The cached path must report that same structured
      # error, and must not retain anything.
      assert {:error, %XqliteEcto3.Error{type: :multiple_statements}, state} =
               Driver.handle_execute(query, [], [], state)

      assert map_size(state.stmt_cache) == 0
    end

    test "schema changes between reuses do not poison the cached statement" do
      state = seeded!()

      {r1, state} = execute!(state, "SELECT * FROM t ORDER BY x", [])
      assert %{columns: ["x", "s"]} = r1

      {:ok, _} = NIF.execute(state.conn, "ALTER TABLE t ADD COLUMN y INTEGER", [])

      {r2, _state} = execute!(state, "SELECT * FROM t ORDER BY x", [])
      assert %{columns: ["x", "s", "y"]} = r2
    end

    test "two statements run neither of them, whatever the cache size" do
      state = seeded!()
      {:ok, _} = NIF.execute(state.conn, "CREATE TABLE pair (n INTEGER)", [])

      query = %Query{statement: "INSERT INTO pair VALUES (1); INSERT INTO pair VALUES (2)"}

      assert {:error, %XqliteEcto3.Error{type: :multiple_statements}, state} =
               Driver.handle_execute(query, [], [], state)

      assert {:ok, %{rows: [[0]]}} = NIF.query(state.conn, "SELECT count(*) FROM pair", [])
      assert map_size(state.stmt_cache) == 0

      oneshot = seeded!(statement_cache_size: 0)
      {:ok, _} = NIF.execute(oneshot.conn, "CREATE TABLE pair (n INTEGER)", [])

      assert {:error, %XqliteEcto3.Error{type: :multiple_statements}, oneshot} =
               Driver.handle_execute(query, [], [], oneshot)

      assert {:ok, %{rows: [[0]]}} = NIF.query(oneshot.conn, "SELECT count(*) FROM pair", [])
    end

    test "a query timeout still cancels through the cached path" do
      state = connect!([])

      slow =
        "WITH RECURSIVE n(x) AS (VALUES(0) UNION ALL SELECT x+1 FROM n WHERE x<100000000) SELECT count(*) FROM n"

      query = %Query{statement: slow}

      assert {:error, %DBConnection.ConnectionError{}, _state} =
               Driver.handle_execute(query, [], [timeout: 30], state)
    end
  end

  defmodule CachingRepo do
    use Ecto.Repo, otp_app: :xqlite_ecto3, adapter: XqliteEcto3
  end

  defmodule UncachedRepo do
    use Ecto.Repo, otp_app: :xqlite_ecto3, adapter: XqliteEcto3
  end

  defmodule PairMigration do
    use Ecto.Migration

    def up do
      execute("INSERT INTO ms_rows VALUES (1); INSERT INTO ms_rows VALUES (2)")
    end

    def down, do: :ok
  end

  # One call runs one statement, and the refusal is the same whichever
  # path the SQL took to reach SQLite. The pair is two INSERTs into an
  # empty table, so a partial run would leave a row behind to find.
  describe "two statements in one call, through a repo" do
    @pair "INSERT INTO ms_rows VALUES (1); INSERT INTO ms_rows VALUES (2)"

    setup do
      start_repo!(CachingRepo, 50)
      start_repo!(UncachedRepo, 0)
      :ok
    end

    test "Repo.query refuses it and runs neither statement, cache on and off" do
      for repo <- [CachingRepo, UncachedRepo] do
        assert {:error, %XqliteEcto3.Error{type: :multiple_statements}} = repo.query(@pair)
        assert %{rows: [[0]]} = repo.query!("SELECT count(*) FROM ms_rows")
      end
    end

    test "a migration's execute refuses it and runs neither statement, cache on and off" do
      for {repo, version} <- [{CachingRepo, 20_260_917_001}, {UncachedRepo, 20_260_917_002}] do
        error =
          assert_raise XqliteEcto3.Error, fn ->
            Ecto.Migrator.up(repo, version, PairMigration, log: false)
          end

        assert error.type == :multiple_statements
        assert %{rows: [[0]]} = repo.query!("SELECT count(*) FROM ms_rows")
      end
    end

    # The cache reports the miss it took to find out the statement cannot
    # be prepared. With `statement_cache_size: 0` no cache runs at all, so
    # no cache event fires for any statement — that half is not this rule.
    if XqliteEcto3.Telemetry.enabled?() do
      test "the cache still reports the miss that found out" do
        handler_id = "stmt-cache-multi-#{:erlang.unique_integer([:positive])}"
        test_pid = self()

        :telemetry.attach(
          handler_id,
          [:xqlite_ecto3, :statement_cache, :miss],
          fn name, measurements, metadata, _ ->
            send(test_pid, {:telemetry_event, name, measurements, metadata})
          end,
          nil
        )

        on_exit(fn -> :telemetry.detach(handler_id) end)

        assert {:error, %XqliteEcto3.Error{type: :multiple_statements}} = CachingRepo.query(@pair)

        assert_receive {:telemetry_event, [:xqlite_ecto3, :statement_cache, :miss], _m,
                        %{sql: @pair}}
      end
    end
  end

  defp start_repo!(repo, cache_size) do
    db =
      Path.join(
        System.tmp_dir!(),
        "xqlite_ecto3_stmt_cache_#{:erlang.unique_integer([:positive])}.db"
      )

    start_supervised!({repo, database: db, pool_size: 1, statement_cache_size: cache_size})
    repo.query!("CREATE TABLE ms_rows (n INTEGER)")

    on_exit(fn ->
      for ext <- ["", "-wal", "-shm", "-journal"], do: File.rm(db <> ext)
    end)

    repo
  end
end
