ecto_sql = Mix.Project.deps_paths()[:ecto_sql]
Code.require_file("#{ecto_sql}/integration_test/support/repo.exs")

defmodule Ecto.Integration.TestRepo do
  use Ecto.Integration.Repo,
    otp_app: :xqlite_ecto3,
    adapter: XqliteEcto3

  def uuid, do: Ecto.UUID

  # Stubs for PostgreSQL-specific prefix operations referenced by shared migration tests.
  # SQLite has no schema/namespace concept; these are never executed (tests tagged :prefix).
  def create_prefix(_prefix), do: "SELECT 1"
  def drop_prefix(_prefix), do: "SELECT 1"
end

defmodule Ecto.Integration.PoolRepo do
  use Ecto.Integration.Repo,
    otp_app: :xqlite_ecto3,
    adapter: XqliteEcto3

  def uuid, do: Ecto.UUID
end
