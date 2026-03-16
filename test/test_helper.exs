db_path = Path.join(System.tmp_dir!(), "xqlite_ecto3_test_#{:erlang.unique_integer([:positive])}.db")

Application.put_env(:xqlite_ecto3, XqliteEcto3.TestRepo,
  database: db_path,
  pool: Ecto.Adapters.SQL.Sandbox
)

{:ok, _} = XqliteEcto3.TestRepo.start_link()

ExUnit.start()
