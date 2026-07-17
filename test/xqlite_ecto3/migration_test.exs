defmodule XqliteEcto3.MigrationTest do
  use XqliteEcto3.AdapterCase, async: true

  alias XqliteEcto3.Connection

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

    assert sql ==
             ~s|CREATE TABLE "users" ("id" INTEGER PRIMARY KEY AUTOINCREMENT, "name" TEXT NOT NULL, "email" TEXT, "age" INTEGER DEFAULT 0)|
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

    assert sql == ~s|CREATE UNIQUE INDEX "users_email_index" ON "users" ("email")|
  end

  test "execute_ddl generates expression-based index" do
    alias XqliteEcto3.Connection

    ddl =
      Connection.execute_ddl(
        {:create,
         %Ecto.Migration.Index{
           name: :users_lower_email_index,
           table: :users,
           columns: ["lower(email)"],
           unique: false
         }}
      )

    sql = ddl |> List.first() |> IO.iodata_to_binary()

    assert sql == ~s|CREATE INDEX "users_lower_email_index" ON "users" (lower(email))|
  end

  test "execute_ddl generates partial index with WHERE" do
    alias XqliteEcto3.Connection

    ddl =
      Connection.execute_ddl(
        {:create,
         %Ecto.Migration.Index{
           name: :users_active_email_index,
           table: :users,
           columns: [:email],
           unique: true,
           where: "active = 1"
         }}
      )

    sql = ddl |> List.first() |> IO.iodata_to_binary()

    assert sql ==
             ~s|CREATE UNIQUE INDEX "users_active_email_index" ON "users" ("email") WHERE active = 1|
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

    assert sql == ~s|ALTER TABLE "users" ADD COLUMN "bio" TEXT|
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
        {:rename, %Ecto.Migration.Table{name: :users}, %Ecto.Migration.Table{name: :people}}
      )

    sql = ddl |> List.first() |> IO.iodata_to_binary()

    assert sql == ~s|ALTER TABLE "users" RENAME TO "people"|
  end

  test "execute_ddl generates RENAME COLUMN SQL" do
    alias XqliteEcto3.Connection

    ddl =
      Connection.execute_ddl({:rename, %Ecto.Migration.Table{name: :users}, :name, :full_name})

    sql = ddl |> List.first() |> IO.iodata_to_binary()

    assert sql == ~s|ALTER TABLE "users" RENAME COLUMN "name" TO "full_name"|
  end

  test "supports_ddl_transaction? returns true" do
    assert XqliteEcto3.supports_ddl_transaction?() == true
  end

  test "execute_ddl passes raw SQL strings through unchanged" do
    sql =
      "CREATE TRIGGER t_update BEFORE UPDATE ON users BEGIN UPDATE users SET updated_at = CURRENT_TIMESTAMP WHERE id = OLD.id; END"

    assert Connection.execute_ddl(sql) == [sql]
  end

  test "execute_ddl accepts arbitrary SQLite-specific DDL strings" do
    assert Connection.execute_ddl("VACUUM") == ["VACUUM"]
    assert Connection.execute_ddl("PRAGMA foreign_keys = ON") == ["PRAGMA foreign_keys = ON"]
  end

  test "execute_ddl with a keyword list raises with an explanatory message" do
    error =
      assert_raise ArgumentError, fn ->
        Connection.execute_ddl(postgres: "CREATE EXTENSION ...", mysql: "CREATE EVENT ...")
      end

    assert error.message == "SQLite adapter does not support keyword lists in execute"
  end

  test "execute_ddl raw string actually executes through Repo.query!" do
    TestRepo.query!("""
    CREATE TABLE IF NOT EXISTS raw_ddl_test (id INTEGER PRIMARY KEY, n INTEGER)
    """)

    TestRepo.query!("INSERT INTO raw_ddl_test VALUES (1, 42)")
    result = TestRepo.query!("SELECT n FROM raw_ddl_test WHERE id = 1")
    assert result.rows == [[42]]

    TestRepo.query!("DROP TABLE raw_ddl_test")
  end
end
