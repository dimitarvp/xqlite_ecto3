defmodule XqliteEcto3.TestRepo do
  use Ecto.Repo,
    otp_app: :xqlite_ecto3,
    adapter: XqliteEcto3
end
