defmodule XqliteEcto3.MigrationTest do
  use ExUnit.Case

  alias XqliteEcto3.TestRepo

  test "create and drop table via raw SQL" do
    TestRepo.query!("CREATE TABLE IF NOT EXISTS mig_test (id INTEGER PRIMARY KEY, name TEXT)")
    TestRepo.query!("INSERT INTO mig_test VALUES (1, 'alice')")

    result = TestRepo.query!("SELECT * FROM mig_test")
    assert result.num_rows == 1
    assert result.rows == [[1, "alice"]]

    TestRepo.query!("DROP TABLE mig_test")
  end

  test "execute_ddl generates correct CREATE TABLE SQL" do
    alias XqliteEcto3.Connection

    ddl =
      Connection.execute_ddl(
        {:create, %Ecto.Migration.Table{name: :users},
         [
           {:add, :id, :bigserial, [primary_key: true]},
           {:add, :name, :string, [null: false]},
           {:add, :email, :string, []},
           {:add, :age, :integer, [default: 0]}
         ]}
      )

    sql = ddl |> List.first() |> IO.iodata_to_binary()

    assert sql =~ "CREATE TABLE"
    assert sql =~ ~s|"users"|
    assert sql =~ ~s|"id" INTEGER PRIMARY KEY AUTOINCREMENT|
    assert sql =~ ~s|"name" TEXT NOT NULL|
    assert sql =~ ~s|"email" TEXT|
    assert sql =~ ~s|"age" INTEGER DEFAULT 0|
  end

  test "execute_ddl generates CREATE INDEX SQL" do
    alias XqliteEcto3.Connection

    ddl =
      Connection.execute_ddl(
        {:create,
         %Ecto.Migration.Index{
           name: :users_email_index,
           table: :users,
           columns: [:email],
           unique: true
         }}
      )

    sql = ddl |> List.first() |> IO.iodata_to_binary()

    assert sql =~ "CREATE UNIQUE INDEX"
    assert sql =~ ~s|"users_email_index"|
    assert sql =~ ~s|"users"|
    assert sql =~ ~s|"email"|
  end

  test "execute_ddl generates ALTER TABLE ADD COLUMN SQL" do
    alias XqliteEcto3.Connection

    ddl =
      Connection.execute_ddl(
        {:alter, %Ecto.Migration.Table{name: :users},
         [
           {:add, :bio, :text, []}
         ]}
      )

    sql = ddl |> List.first() |> IO.iodata_to_binary()

    assert sql =~ "ALTER TABLE"
    assert sql =~ ~s|"users"|
    assert sql =~ "ADD COLUMN"
    assert sql =~ ~s|"bio" TEXT|
  end

  test "execute_ddl generates DROP TABLE SQL" do
    alias XqliteEcto3.Connection

    ddl = Connection.execute_ddl({:drop, %Ecto.Migration.Table{name: :users}})
    sql = ddl |> List.first() |> IO.iodata_to_binary()

    assert sql == ~s|DROP TABLE "users"|
  end

  test "execute_ddl generates RENAME TABLE SQL" do
    alias XqliteEcto3.Connection

    ddl =
      Connection.execute_ddl(
        {:rename, %Ecto.Migration.Table{name: :users},
         %Ecto.Migration.Table{name: :people}}
      )

    sql = ddl |> List.first() |> IO.iodata_to_binary()

    assert sql =~ "ALTER TABLE"
    assert sql =~ "RENAME TO"
  end

  test "execute_ddl generates RENAME COLUMN SQL" do
    alias XqliteEcto3.Connection

    ddl =
      Connection.execute_ddl(
        {:rename, %Ecto.Migration.Table{name: :users}, :name, :full_name}
      )

    sql = ddl |> List.first() |> IO.iodata_to_binary()

    assert sql =~ "RENAME COLUMN"
    assert sql =~ ~s|"name"|
    assert sql =~ ~s|"full_name"|
  end

  test "supports_ddl_transaction? returns true" do
    assert XqliteEcto3.supports_ddl_transaction?() == true
  end

  test "table_exists_query returns correct SQL and params" do
    {sql, params} = XqliteEcto3.Connection.table_exists_query("users")
    assert sql =~ "sqlite_master"
    assert params == ["users"]
  end
end
