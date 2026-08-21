defmodule XqliteEcto3.TransactionAtomicityTest do
  @moduledoc """
  A constraint declared ON CONFLICT ROLLBACK makes SQLite roll back the
  whole transaction and return to autocommit the moment it fires. The
  driver must stop the transaction body right there: any later statement
  would run in autocommit and durably commit inside a transaction that
  reports failure.

  This holds whether the transaction was opened by `Repo.transaction/2` or
  by a raw `BEGIN`, and whether the damaging statement ran through the plain
  or the streaming path. A failure with no transaction open must NOT stop
  the connection — there is nothing to protect.
  """
  use ExUnit.Case, async: true

  alias Ecto.Integration.PoolRepo

  test "no body write after the violation survives a failed transaction" do
    PoolRepo.query!("DROP TABLE IF EXISTS ta_ocr")
    PoolRepo.query!("DROP TABLE IF EXISTS ta_ocr_log")

    PoolRepo.query!(
      "CREATE TABLE ta_ocr(id INTEGER PRIMARY KEY, email TEXT UNIQUE ON CONFLICT ROLLBACK)"
    )

    PoolRepo.query!("CREATE TABLE ta_ocr_log(note TEXT)")
    PoolRepo.query!("INSERT INTO ta_ocr(email) VALUES ('a@x')")

    outcome =
      try do
        PoolRepo.transaction(fn ->
          {:ok, _} = PoolRepo.query("INSERT INTO ta_ocr_log(note) VALUES ('pre')")
          {:error, _violation} = PoolRepo.query("INSERT INTO ta_ocr(email) VALUES ('a@x')")
          _post = PoolRepo.query("INSERT INTO ta_ocr_log(note) VALUES ('post')")
          :carried_on
        end)
      rescue
        e in [DBConnection.ConnectionError, XqliteEcto3.Error] -> {:raised, e.__struct__}
      end

    refute outcome == {:ok, :carried_on}
    assert %{rows: [[0]]} = PoolRepo.query!("SELECT count(*) FROM ta_ocr_log")
  end

  test "no body write after a cancelled write survives a failed transaction" do
    PoolRepo.query!("DROP TABLE IF EXISTS ta_canc")
    PoolRepo.query!("DROP TABLE IF EXISTS ta_canc_log")
    PoolRepo.query!("CREATE TABLE ta_canc(x INTEGER)")
    PoolRepo.query!("CREATE TABLE ta_canc_log(note TEXT)")

    slow =
      "INSERT INTO ta_canc SELECT x FROM (WITH RECURSIVE c(x) AS " <>
        "(SELECT 1 UNION ALL SELECT x + 1 FROM c LIMIT 30000000) SELECT x FROM c)"

    outcome =
      try do
        PoolRepo.transaction(fn ->
          {:ok, _} = PoolRepo.query("INSERT INTO ta_canc_log(note) VALUES ('pre')")
          {:error, _cancelled} = PoolRepo.query(slow, [], timeout: 50)
          _post = PoolRepo.query("INSERT INTO ta_canc_log(note) VALUES ('post')")
          :carried_on
        end)
      rescue
        e in [DBConnection.ConnectionError, XqliteEcto3.Error] -> {:raised, e.__struct__}
      end

    refute outcome == {:ok, :carried_on}
    assert %{rows: [[0]]} = PoolRepo.query!("SELECT count(*) FROM ta_canc_log")
  end

  test "no write after a violation survives a transaction opened with raw SQL" do
    PoolRepo.query!("DROP TABLE IF EXISTS ta_raw")
    PoolRepo.query!("DROP TABLE IF EXISTS ta_raw_log")

    PoolRepo.query!(
      "CREATE TABLE ta_raw(id INTEGER PRIMARY KEY, email TEXT UNIQUE ON CONFLICT ROLLBACK)"
    )

    PoolRepo.query!("CREATE TABLE ta_raw_log(note TEXT)")
    PoolRepo.query!("INSERT INTO ta_raw(email) VALUES ('a@x')")

    post =
      PoolRepo.checkout(fn ->
        {:ok, _} = PoolRepo.query("BEGIN IMMEDIATE")
        {:ok, _} = PoolRepo.query("INSERT INTO ta_raw_log(note) VALUES ('pre')")

        {:error, %XqliteEcto3.Error{type: :constraint_violation}} =
          PoolRepo.query("INSERT INTO ta_raw(email) VALUES ('a@x')")

        PoolRepo.query("INSERT INTO ta_raw_log(note) VALUES ('post')")
      end)

    assert {:error, %DBConnection.ConnectionError{}} = post
    assert %{rows: [[0]]} = PoolRepo.query!("SELECT count(*) FROM ta_raw_log")
  end

  test "no write after a cancelled write survives a transaction opened with raw SQL" do
    PoolRepo.query!("DROP TABLE IF EXISTS ta_rawc")
    PoolRepo.query!("DROP TABLE IF EXISTS ta_rawc_log")
    PoolRepo.query!("CREATE TABLE ta_rawc(x INTEGER)")
    PoolRepo.query!("CREATE TABLE ta_rawc_log(note TEXT)")

    slow =
      "INSERT INTO ta_rawc SELECT x FROM (WITH RECURSIVE c(x) AS " <>
        "(SELECT 1 UNION ALL SELECT x + 1 FROM c LIMIT 30000000) SELECT x FROM c)"

    post =
      PoolRepo.checkout(fn ->
        {:ok, _} = PoolRepo.query("BEGIN IMMEDIATE")
        {:ok, _} = PoolRepo.query("INSERT INTO ta_rawc_log(note) VALUES ('pre')")
        {:error, %DBConnection.ConnectionError{}} = PoolRepo.query(slow, [], timeout: 50)
        PoolRepo.query("INSERT INTO ta_rawc_log(note) VALUES ('post')")
      end)

    assert {:error, %DBConnection.ConnectionError{}} = post
    assert %{rows: [[0]]} = PoolRepo.query!("SELECT count(*) FROM ta_rawc_log")
  end

  test "a failed statement outside any transaction keeps the connection alive" do
    PoolRepo.query!("DROP TABLE IF EXISTS ta_auto")

    PoolRepo.query!(
      "CREATE TABLE ta_auto(id INTEGER PRIMARY KEY, email TEXT UNIQUE ON CONFLICT ROLLBACK)"
    )

    PoolRepo.query!("INSERT INTO ta_auto(email) VALUES ('a@x')")

    post =
      PoolRepo.checkout(fn ->
        {:error, %XqliteEcto3.Error{type: :constraint_violation}} =
          PoolRepo.query("INSERT INTO ta_auto(email) VALUES ('a@x')")

        PoolRepo.query("INSERT INTO ta_auto(email) VALUES ('b@x')")
      end)

    assert {:ok, %{num_rows: 1}} = post
    assert %{rows: [[2]]} = PoolRepo.query!("SELECT count(*) FROM ta_auto")
  end

  test "no body write after a streamed statement's violation survives a failed transaction" do
    PoolRepo.query!("DROP TABLE IF EXISTS ta_str")
    PoolRepo.query!("DROP TABLE IF EXISTS ta_str_log")

    PoolRepo.query!(
      "CREATE TABLE ta_str(id INTEGER PRIMARY KEY, email TEXT UNIQUE ON CONFLICT ROLLBACK)"
    )

    PoolRepo.query!("CREATE TABLE ta_str_log(note TEXT)")
    PoolRepo.query!("INSERT INTO ta_str(email) VALUES ('a@x')")

    outcome =
      try do
        PoolRepo.transaction(fn ->
          {:ok, _} = PoolRepo.query("INSERT INTO ta_str_log(note) VALUES ('pre')")
          _swallowed = stream_violation(PoolRepo)
          _post = PoolRepo.query("INSERT INTO ta_str_log(note) VALUES ('post')")
          :carried_on
        end)
      rescue
        e in [DBConnection.ConnectionError, XqliteEcto3.Error] -> {:raised, e.__struct__}
      end

    refute outcome == {:ok, :carried_on}
    assert %{rows: [[0]]} = PoolRepo.query!("SELECT count(*) FROM ta_str_log")
  end

  defp stream_violation(repo) do
    repo
    |> Ecto.Adapters.SQL.stream("INSERT INTO ta_str(email) VALUES ('a@x') RETURNING id", [])
    |> Enum.to_list()
  rescue
    e in [DBConnection.ConnectionError, XqliteEcto3.Error] -> {:rescued, e.__struct__}
  end

  # SQLite rolls the WHOLE transaction back when it interrupts a write, and
  # that takes every savepoint with it — so a cancelled write inside a nested
  # `Repo.transaction` cannot be contained by the inner one. The outer
  # transaction has to fail as a whole and leave nothing behind.
  test "no write survives a cancelled write inside a nested transaction" do
    PoolRepo.query!("DROP TABLE IF EXISTS ta_nest")
    PoolRepo.query!("CREATE TABLE ta_nest(id INTEGER PRIMARY KEY, v INTEGER)")

    outcome =
      try do
        PoolRepo.transaction(fn ->
          {:ok, _} = PoolRepo.query("INSERT INTO ta_nest(id, v) VALUES (1, 111)")

          inner =
            try do
              PoolRepo.transaction(fn ->
                case PoolRepo.query(slow_insert("ta_nest"), [], timeout: 50) do
                  {:ok, _} -> :completed
                  {:error, _cancelled} -> PoolRepo.rollback(:cancelled)
                end
              end)
            rescue
              e in [DBConnection.ConnectionError, XqliteEcto3.Error] -> {:raised, e.__struct__}
            end

          _later = PoolRepo.query("INSERT INTO ta_nest(id, v) VALUES (2, 222)")
          {:carried_on, inner}
        end)
      rescue
        e in [DBConnection.ConnectionError, XqliteEcto3.Error] -> {:raised, e.__struct__}
      end

    refute match?({:ok, {:carried_on, _}}, outcome)
    assert %{rows: [[0]]} = PoolRepo.query!("SELECT count(*) FROM ta_nest")
    assert %{rows: [[1]]} = PoolRepo.query!("SELECT 1")
  end

  # The control for the rule above: a cancelled READ rolls nothing back, so
  # its transaction must survive intact. The driver may only tear a
  # transaction down when SQLite already did.
  test "a cancelled read leaves its transaction intact" do
    PoolRepo.query!("DROP TABLE IF EXISTS ta_ro")
    PoolRepo.query!("CREATE TABLE ta_ro(id INTEGER PRIMARY KEY, v INTEGER)")

    outcome =
      PoolRepo.transaction(fn ->
        {:ok, _} = PoolRepo.query("INSERT INTO ta_ro(id, v) VALUES (1, 111)")
        {:error, _cancelled} = PoolRepo.query(slow_select(), [], timeout: 50)
        {:ok, _} = PoolRepo.query("INSERT INTO ta_ro(id, v) VALUES (2, 222)")
        :carried_on
      end)

    assert outcome == {:ok, :carried_on}
    assert %{rows: [[2]]} = PoolRepo.query!("SELECT count(*) FROM ta_ro")
  end

  test "no row survives a cancelled write while a stream is mid-flight" do
    PoolRepo.query!("DROP TABLE IF EXISTS ta_stx")
    PoolRepo.query!("DROP TABLE IF EXISTS ta_stx_seed")
    PoolRepo.query!("CREATE TABLE ta_stx(id INTEGER PRIMARY KEY, v INTEGER)")
    PoolRepo.query!("CREATE TABLE ta_stx_seed(id INTEGER PRIMARY KEY)")
    for i <- 1..20, do: PoolRepo.query!("INSERT INTO ta_stx_seed(id) VALUES (?)", [i])

    outcome =
      try do
        PoolRepo.transaction(fn ->
          {:ok, _} = PoolRepo.query("INSERT INTO ta_stx(id, v) VALUES (1, 111)")

          PoolRepo
          |> Ecto.Adapters.SQL.stream("SELECT id FROM ta_stx_seed ORDER BY id", [], max_rows: 1)
          |> Stream.transform(0, &cancel_on_third(&1, &2, "ta_stx"))
          |> Enum.take(6)
        end)
      rescue
        e in [DBConnection.ConnectionError, XqliteEcto3.Error] -> {:raised, e.__struct__}
      end

    refute match?({:ok, _}, outcome)
    assert %{rows: [[0]]} = PoolRepo.query!("SELECT count(*) FROM ta_stx")
  end

  test "no row survives a stream declared after a cancelled write" do
    PoolRepo.query!("DROP TABLE IF EXISTS ta_xts")
    PoolRepo.query!("DROP TABLE IF EXISTS ta_xts_seed")
    PoolRepo.query!("CREATE TABLE ta_xts(id INTEGER PRIMARY KEY, v INTEGER)")
    PoolRepo.query!("CREATE TABLE ta_xts_seed(id INTEGER PRIMARY KEY)")
    for i <- 1..20, do: PoolRepo.query!("INSERT INTO ta_xts_seed(id) VALUES (?)", [i])

    outcome =
      try do
        PoolRepo.transaction(fn ->
          {:ok, _} = PoolRepo.query("INSERT INTO ta_xts(id, v) VALUES (1, 111)")
          {:error, _cancelled} = PoolRepo.query(slow_insert("ta_xts"), [], timeout: 50)

          PoolRepo
          |> Ecto.Adapters.SQL.stream("SELECT id FROM ta_xts_seed ORDER BY id", [], max_rows: 2)
          |> Enum.take(2)
        end)
      rescue
        e in [DBConnection.ConnectionError, XqliteEcto3.Error] -> {:raised, e.__struct__}
      end

    refute match?({:ok, [_ | _]}, outcome)
    assert %{rows: [[0]]} = PoolRepo.query!("SELECT count(*) FROM ta_xts")
  end

  test "a stream in a transaction nothing cancelled runs to completion" do
    PoolRepo.query!("DROP TABLE IF EXISTS ta_stok_seed")
    PoolRepo.query!("CREATE TABLE ta_stok_seed(id INTEGER PRIMARY KEY)")
    for i <- 1..5, do: PoolRepo.query!("INSERT INTO ta_stok_seed(id) VALUES (?)", [i])

    outcome =
      PoolRepo.transaction(fn ->
        PoolRepo
        |> Ecto.Adapters.SQL.stream("SELECT id FROM ta_stok_seed ORDER BY id", [], max_rows: 2)
        |> Enum.flat_map(& &1.rows)
      end)

    assert outcome == {:ok, [[1], [2], [3], [4], [5]]}
  end

  defp cancel_on_third(row, 2, table) do
    {:error, _cancelled} = PoolRepo.query(slow_insert(table), [], timeout: 50)
    {[row], 3}
  end

  defp cancel_on_third(row, n, _table), do: {[row], n + 1}

  describe "top-level savepoint mode" do
    # A lone SAVEPOINT would run the transaction :deferred, silently
    # discarding default_transaction_mode — and a deferred write that loses
    # the lock race fails instantly (SQLite skips the busy handler on a
    # stale-snapshot upgrade), losing the update. Refused since Run 42;
    # nested savepoints (an enclosing transaction open) work as before and
    # are covered by the driver-level lifecycle tests and the sandbox suite.
    test "is refused: a lone SAVEPOINT would run the transaction :deferred" do
      assert_raise DBConnection.ConnectionError, fn ->
        PoolRepo.transaction(fn -> :never_runs end, mode: :savepoint)
      end

      # the refusal costs that one connection; the pool serves the next call
      assert %{rows: [[1]]} = PoolRepo.query!("SELECT 1")
    end
  end

  defp slow_insert(table) do
    "INSERT INTO #{table} SELECT x + 1000000, x FROM (WITH RECURSIVE c(x) AS " <>
      "(SELECT 1 UNION ALL SELECT x + 1 FROM c LIMIT 30000000) SELECT x FROM c)"
  end

  defp slow_select do
    "WITH RECURSIVE c(x) AS (SELECT 1 UNION ALL SELECT x + 1 FROM c LIMIT 30000000) " <>
      "SELECT count(*) FROM c"
  end
end
