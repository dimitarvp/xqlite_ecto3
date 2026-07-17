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

    test "an invalid statement_cache_size is a structured connect error" do
      assert {:error, {:invalid_statement_cache_size, :lots}} =
               Driver.connect(database: ":memory:", statement_cache_size: :lots)
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
