defmodule XqliteEcto3.TableHelper do
  @moduledoc """
  Helpers for creating isolated test tables with Sandbox-compatible checkout.
  """

  alias Ecto.Integration.TestRepo

  @doc """
  Creates a table if it doesn't exist. Handles Sandbox checkout internally.
  Use in `setup_all` blocks.
  """
  def create_table!(name, columns) when is_binary(name) and is_binary(columns) do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo, sandbox: false)
    TestRepo.query!("CREATE TABLE IF NOT EXISTS #{name} (#{columns})")
    Ecto.Adapters.SQL.Sandbox.checkin(TestRepo)
    :ok
  end

  @doc """
  Creates a table with indexes. Handles Sandbox checkout internally.
  """
  def create_table!(name, columns, indexes) when is_list(indexes) do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo, sandbox: false)
    TestRepo.query!("CREATE TABLE IF NOT EXISTS #{name} (#{columns})")
    Enum.each(indexes, &TestRepo.query!/1)
    Ecto.Adapters.SQL.Sandbox.checkin(TestRepo)
    :ok
  end

  @doc """
  Deletes all rows from a table. Returns `:ok`.
  Use in `setup` blocks — expects Sandbox already checked out.
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

  def user_columns do
    "id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, email TEXT, age INTEGER, active INTEGER DEFAULT 1, inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL"
  end

  def post_columns(user_table \\ "users") do
    "id INTEGER PRIMARY KEY AUTOINCREMENT, title TEXT NOT NULL, body TEXT, user_id INTEGER REFERENCES #{user_table}(id), inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL"
  end
end
