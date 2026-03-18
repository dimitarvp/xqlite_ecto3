ecto_sql = Mix.Project.deps_paths()[:ecto_sql]
Code.require_file("#{ecto_sql}/integration_test/support/repo.exs")

defmodule Ecto.Integration.TestRepo do
  use Ecto.Integration.Repo,
    otp_app: :xqlite_ecto3,
    adapter: XqliteEcto3

  def uuid, do: Ecto.UUID
end

defmodule Ecto.Integration.PoolRepo do
  use Ecto.Integration.Repo,
    otp_app: :xqlite_ecto3,
    adapter: XqliteEcto3

  def uuid, do: Ecto.UUID
end
