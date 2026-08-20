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
end
