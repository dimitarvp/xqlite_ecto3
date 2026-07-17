defmodule XqliteEcto3.RepoUrlConfigTest do
  use ExUnit.Case, async: true

  alias XqliteNIF, as: NIF

  defmodule UrlRepo do
    use Ecto.Repo, otp_app: :xqlite_ecto3_url_test, adapter: XqliteEcto3
  end

  defmodule CustomInitRepo do
    use Ecto.Repo, otp_app: :xqlite_ecto3_url_test, adapter: XqliteEcto3

    def init(_type, config) do
      {url, config} = Keyword.pop(config, :url)
      {:ok, Keyword.merge(config, XqliteEcto3.parse_url!(url))}
    end
  end

  test "a repo without init/2 accepts :url config directly" do
    start_supervised!({UrlRepo, url: "sqlite::memory:?busy_timeout=7500", pool_size: 1})

    assert %{rows: [[1]]} = UrlRepo.query!("SELECT 1")

    assert {:ok, 7500} =
             XqliteEcto3.with_xqlite(UrlRepo, fn conn ->
               NIF.get_pragma(conn, "busy_timeout")
             end)
  end

  test "nil and empty :url are tolerated (env var not set)" do
    start_supervised!({UrlRepo, url: nil, database: ":memory:", pool_size: 1})

    assert %{rows: [[1]]} = UrlRepo.query!("SELECT 1")
  end

  test "a repo defining its own init/2 keeps it — nothing is injected" do
    # CustomInitRepo compiling at all proves the adapter did not inject a
    # clashing init/2; the assertion proves the user's own url handling ran.
    start_supervised!({CustomInitRepo, url: "sqlite::memory:?busy_timeout=6000", pool_size: 1})

    assert {:ok, 6000} =
             XqliteEcto3.with_xqlite(CustomInitRepo, fn conn ->
               NIF.get_pragma(conn, "busy_timeout")
             end)
  end
end
