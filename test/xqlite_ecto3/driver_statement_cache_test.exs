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
      assert {:error, {:invalid_statement_cache_size, :lots}} =
               Driver.connect(database: ":memory:", statement_cache_size: :lots)
    end
  end

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
                      %{sql: "SELECT x FROM t WHERE x = ?1"}}

      assert m1.cached_count == 0
      assert is_integer(m1.monotonic_time)

      {_r, state} = execute!(state, "SELECT x FROM t WHERE x = ?1", [2])
      assert_receive {:cache_tel, [:xqlite_ecto3, :statement_cache, :hit], m2, _}
      assert m2.cached_count == 1

      {_r, _state} = execute!(state, "SELECT x FROM t ORDER BY x", [])
      assert_receive {:cache_tel, [:xqlite_ecto3, :statement_cache, :miss], _m3, _}

      assert_receive {:cache_tel, [:xqlite_ecto3, :statement_cache, :evicted], m4,
                      %{sql: "SELECT x FROM t WHERE x = ?1"}}

      assert m4.cached_count == 2
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

  describe "fallbacks and resilience" do
    test "multi-statement SQL errors identically on both paths and is never cached" do
      state = seeded!()
      query = %Query{statement: "UPDATE t SET x = x; UPDATE t SET x = x"}

      # handle_execute has never supported multi-statement SQL — the one-shot
      # NIF rejects it too. The cache must fall back and preserve that exact
      # structured error, and must not retain anything.
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

    test "a query timeout still cancels through the cached path" do
      state = connect!([])

      slow =
        "WITH RECURSIVE n(x) AS (VALUES(0) UNION ALL SELECT x+1 FROM n WHERE x<100000000) SELECT count(*) FROM n"

      query = %Query{statement: slow}

      assert {:error, %DBConnection.ConnectionError{}, _state} =
               Driver.handle_execute(query, [], [timeout: 30], state)
    end
  end
end
