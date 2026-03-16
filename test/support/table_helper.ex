defmodule XqliteEcto3.TableHelper do
  @moduledoc """
  Helpers for creating isolated test tables.

  Each test module gets its own uniquely-named tables via `setup_all`
  + `setup`. All test modules can run `async: true` without conflicts.

  ## Usage in test modules

      defmodule MyTest do
        use ExUnit.Case, async: true
        import XqliteEcto3.TableHelper

        # Define your inline schema pointing to the unique table name
        @users_table "my_test_users"

        defmodule MyUser do
          use Ecto.Schema
          schema "my_test_users" do
            field :name, :string
            timestamps()
          end
        end

        # Create the table once per module, clear rows per test
        setup_all do
          create_table!("my_test_users", "id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL")
        end

        setup do
          clear_table!("my_test_users")
        end
      end
  """

  alias XqliteEcto3.TestRepo

  @doc """
  Creates a table if it doesn't exist. Returns `:ok`.
  Use in `setup_all` blocks.
  """
  def create_table!(name, columns) when is_binary(name) and is_binary(columns) do
    TestRepo.query!("CREATE TABLE IF NOT EXISTS #{name} (#{columns})")
    :ok
  end

  @doc """
  Creates a table with an index. Returns `:ok`.
  """
  def create_table!(name, columns, indexes) when is_list(indexes) do
    create_table!(name, columns)

    Enum.each(indexes, fn index_sql ->
      TestRepo.query!(index_sql)
    end)

    :ok
  end

  @doc """
  Deletes all rows from a table. Returns `:ok`.
  Use in `setup` blocks for per-test isolation.
  """
  def clear_table!(name) when is_binary(name) do
    TestRepo.query!("DELETE FROM #{name}")
    :ok
  end

  @doc """
  Clears multiple tables. Returns `:ok`.
  """
  def clear_tables!(names) when is_list(names) do
    Enum.each(names, &clear_table!/1)
    :ok
  end

  @doc """
  Standard user-like columns for test tables.
  """
  def user_columns do
    "id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, email TEXT, age INTEGER, active INTEGER DEFAULT 1, inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL"
  end

  @doc """
  Standard post-like columns for test tables. Takes the FK table name.
  """
  def post_columns(user_table \\ "users") do
    "id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, body TEXT, user_id INTEGER REFERENCES #{user_table}(id), inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL"
  end
end
