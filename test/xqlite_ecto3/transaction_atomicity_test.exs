defmodule XqliteEcto3.TransactionAtomicityTest do
  @moduledoc """
  A constraint declared ON CONFLICT ROLLBACK makes SQLite roll back the
  whole transaction and return to autocommit the moment it fires. The
  driver must stop the transaction body right there: any later statement
  would run in autocommit and durably commit inside a transaction that
  reports failure.
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
end
