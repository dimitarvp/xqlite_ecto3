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

  describe "reference ON DELETE" do
    defp ref_ddl(on_delete) do
      Connection.execute_ddl(
        {:create, %Ecto.Migration.Table{name: :comments},
         [
           {:add, :post_id,
            %Ecto.Migration.Reference{
              table: :posts,
              column: :id,
              type: :id,
              on_delete: on_delete
            }, []}
         ]}
      )
      |> List.first()
      |> IO.iodata_to_binary()
    end

    test "whole-key :nilify_all emits ON DELETE SET NULL" do
      assert ref_ddl(:nilify_all) =~ "ON DELETE SET NULL"
    end

    test "whole-key :default_all emits ON DELETE SET DEFAULT" do
      assert ref_ddl(:default_all) =~ "ON DELETE SET DEFAULT"
    end

    # SQLite has no column-list ON DELETE syntax; the action always covers the
    # whole key. Silently dropping the clause would ignore what the migration
    # asked for, so the adapter must refuse loudly rather than miscompile.
    test "column-list {:nilify, cols} refuses loudly instead of dropping the clause" do
      assert_raise ArgumentError, fn -> ref_ddl({:nilify, [:post_id]}) end
    end

    test "column-list {:default, cols} refuses loudly instead of dropping the clause" do
      assert_raise ArgumentError, fn -> ref_ddl({:default, [:post_id]}) end
    end
  end

  # A column default is written into the table's own DDL, so it has to be a
  # value SQLite can hold as a literal. A struct used to be JSON-encoded and
  # stored complete with its quotes (`DEFAULT ('"1.5"')`), which then failed
  # to load; the other shapes had no clause at all and crashed on the
  # missing match. All of them are refused with the column named.
  describe "unsupported column defaults" do
    test "a Decimal default is refused rather than stored as JSON text" do
      err =
        assert_raise XqliteEcto3.UnsupportedDefaultError, fn ->
          default_ddl(Decimal.new("1.5"))
        end

      assert err.reason == :unsupported_shape
      assert Decimal.equal?(err.value, Decimal.new("1.5"))
      assert err.column == "c"
      assert err.type == :string
    end

    test "a Date default is refused rather than stored as JSON text" do
      err =
        assert_raise XqliteEcto3.UnsupportedDefaultError, fn -> default_ddl(~D[2020-01-01]) end

      assert err.reason == :unsupported_shape
      assert err.value == ~D[2020-01-01]
    end

    test "an atom default is refused" do
      err = assert_raise XqliteEcto3.UnsupportedDefaultError, fn -> default_ddl(:active) end

      assert err.reason == :unsupported_shape
      assert err.value == :active
    end

    test "a tuple that is not a fragment is refused" do
      err = assert_raise XqliteEcto3.UnsupportedDefaultError, fn -> default_ddl({1, 2}) end

      assert err.reason == :unsupported_shape
      assert err.value == {1, 2}
    end

    # `~c"abc"` and `[97, 98, 99]` are the same term, so JSON-encoding it
    # would store an array of numbers for a caller who meant text.
    test "a printable charlist is refused instead of storing character codes" do
      err = assert_raise XqliteEcto3.UnsupportedDefaultError, fn -> default_ddl(~c"abc") end

      assert err.reason == :unsupported_shape
      assert err.value == ~c"abc"
    end

    test "a plain map holding a value with no JSON form is refused as unencodable" do
      value = %{"d" => Duration.new!(second: 5)}
      err = assert_raise XqliteEcto3.UnsupportedDefaultError, fn -> default_ddl(value) end

      assert err.reason == :unencodable
      assert err.value == value
      assert %Protocol.UndefinedError{} = err.cause
    end

    # The shape the shared migration suite builds for its bitstring column.
    test "a bitstring that is not a whole number of bytes is refused" do
      err =
        assert_raise XqliteEcto3.UnsupportedDefaultError, fn ->
          Connection.execute_ddl(
            {:create, %Ecto.Migration.Table{name: :mig_bs},
             [{:add, :bs_with_default, :bitstring, [default: <<42::6>>]}]}
          )
        end

      assert err.reason == :unsupported_shape
      assert err.value == <<42::6>>
      assert err.column == "bs_with_default"
    end

    test "plain maps, lists and the other literal shapes still render" do
      assert default_ddl(%{"a" => 1}) =~ ~s|DEFAULT ('{"a":1}')|
      assert default_ddl([1, 2]) =~ ~s|DEFAULT ('[1,2]')|
      assert default_ddl([]) =~ ~s|DEFAULT ('[]')|
      assert default_ddl("hi") =~ ~s|DEFAULT 'hi'|
      assert default_ddl(1.5) =~ "DEFAULT 1.5"
      assert default_ddl(true) =~ "DEFAULT true"
      assert default_ddl(nil) =~ "DEFAULT NULL"
      assert default_ddl({:fragment, "CURRENT_TIMESTAMP"}) =~ "DEFAULT CURRENT_TIMESTAMP"
    end
  end

  # SQLite gives a REAL-affinity column its float64 form on the way in, which
  # would round a whole-number decimal past 2^53. Every float-flavored type
  # the adapter accepts therefore declares NUMERIC.
  describe "float-flavored column types" do
    for type <- [:float, :real, :double, :double_precision] do
      test "#{type} declares a NUMERIC column" do
        assert XqliteEcto3.DataType.column_type(unquote(type), []) == "NUMERIC"
      end
    end

    test "a migrated :real column keeps every digit of a whole-number decimal" do
      Connection.execute_ddl(
        {:create, %Ecto.Migration.Table{name: :mig_real},
         [{:add, :id, :integer, [primary_key: true]}, {:add, :v, :real, []}]}
      )
      |> Enum.each(&TestRepo.query!(IO.iodata_to_binary(&1)))

      assert %{rows: [["NUMERIC"]]} =
               TestRepo.query!("SELECT type FROM pragma_table_xinfo('mig_real') WHERE name = 'v'")

      dec = Decimal.new("12345678901234567")
      TestRepo.query!("INSERT INTO mig_real(id, v) VALUES (1, ?)", encode([dec]))

      assert %{rows: [["integer", 12_345_678_901_234_567]]} =
               TestRepo.query!("SELECT typeof(v), v FROM mig_real WHERE id = 1")
    end
  end

  defp default_ddl(value) do
    {:create, %Ecto.Migration.Table{name: :mig_defaults}, [{:add, :c, :string, [default: value]}]}
    |> Connection.execute_ddl()
    |> List.first()
    |> IO.iodata_to_binary()
  end

  defp encode(params) do
    DBConnection.Query.encode(%XqliteEcto3.Query{statement: "?"}, params, [])
  end
end
