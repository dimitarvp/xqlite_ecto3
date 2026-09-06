defmodule XqliteEcto3.PooledMemoryDatabaseTest do
  @moduledoc """
  A private in-memory SQLite database belongs to the single connection
  that opened it. Pointing a pool of several connections at one is
  therefore a set of separate empty databases: a write lands on
  whichever connection served it and later reads scatter across the
  others, most of them failing with "no such table" and the rest
  reading nothing. The adapter refuses that combination while the pool
  is being built, so the repo never starts and no write is ever lost.

  Three spellings open a private database: `":memory:"`, the empty
  string, and any `file:` URI naming `:memory:` without
  `cache=shared`. The shared-cache form is the one in-memory spelling
  several connections really do share, so it stays allowed at every
  pool size — and the last test proves it end to end: a row written on
  one pooled connection is read back through the pool afterwards.

  The pool size itself is Ecto's business. Ecto merges its own default
  into the repo configuration before the adapter ever sees it, so a
  default the adapter puts in could never win; one property pins that
  the adapter contributes none.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias XqliteEcto3.Connection, as: Conn

  # Every spelling each pooled connection would open privately.
  @private_spellings [
    ":memory:",
    "",
    "file::memory:",
    "file::memory:?mode=rw",
    "file::memory:?cache=private",
    "file:named_db?mode=memory",
    "file:named_db?mode=memory&cache=private"
  ]

  @shared_spellings [
    "file::memory:?cache=shared",
    "file::memory:?mode=rw&cache=shared",
    "file:named_db?mode=memory&cache=shared"
  ]

  @shared_database "file::memory:?cache=shared"

  @runs 2000

  defmodule SharedRepo do
    use Ecto.Repo, otp_app: :xqlite_ecto3, adapter: XqliteEcto3
  end

  property "a private in-memory database is refused for every pool wider than one" do
    check all(
            database <- member_of(@private_spellings),
            pool_size <- integer(2..64),
            max_runs: @runs
          ) do
      assert_raise ArgumentError, fn ->
        Conn.child_spec(database: database, pool_size: pool_size)
      end
    end
  end

  property "a single connection over a private in-memory database is built" do
    check all(database <- member_of(@private_spellings), max_runs: @runs) do
      assert driver_opts(database: database, pool_size: 1)[:database] == database
    end
  end

  property "a shared-cache in-memory database is built at every pool size" do
    check all(
            database <- member_of(@shared_spellings),
            pool_size <- integer(1..64),
            max_runs: @runs
          ) do
      assert driver_opts(database: database, pool_size: pool_size)[:database] == database
    end
  end

  property "a file database is built at every pool size" do
    check all(
            name <- string(:alphanumeric, min_length: 1, max_length: 12),
            pool_size <- integer(1..64),
            max_runs: @runs
          ) do
      opts = driver_opts(database: "/tmp/#{name}.db", pool_size: pool_size)

      assert opts[:pool_size] == pool_size
    end
  end

  property "the adapter contributes no pool size of its own" do
    check all(name <- string(:alphanumeric, min_length: 1, max_length: 12), max_runs: @runs) do
      refute Keyword.has_key?(driver_opts(database: "/tmp/#{name}.db"), :pool_size)
    end
  end

  test "a named in-memory database is refused for a pool" do
    assert_raise ArgumentError, fn ->
      Conn.child_spec(database: "file:named_db?mode=memory", pool_size: 2)
    end
  end

  test "a named in-memory database with a shared cache is built for a pool" do
    opts = driver_opts(database: "file:named_db?mode=memory&cache=shared", pool_size: 2)

    assert opts[:database] == "file:named_db?mode=memory&cache=shared"
  end

  test "a shared-cache in-memory pool reads back what one of its connections wrote" do
    config = [adapter: XqliteEcto3, database: @shared_database, pool_size: 2]

    Application.put_env(:xqlite_ecto3, SharedRepo, config)
    start_supervised!({SharedRepo, config})

    SharedRepo.checkout(fn ->
      SharedRepo.query!("CREATE TABLE shared_rows (id INTEGER PRIMARY KEY)", [])
      SharedRepo.query!("INSERT INTO shared_rows (id) VALUES (1)", [])
    end)

    tally =
      1..20
      |> Enum.map(fn _run -> read_count() end)
      |> Enum.frequencies()

    assert tally == %{{:ok, 1} => 20}
  end

  defp read_count do
    case SharedRepo.query("SELECT COUNT(*) FROM shared_rows", []) do
      {:ok, %{rows: [[n]]}} -> {:ok, n}
      {:error, %XqliteEcto3.Error{type: type}} -> {:error, type}
      other -> {:unexpected, other}
    end
  end

  defp driver_opts(opts) do
    %{start: {_pool, :start_link, [{XqliteEcto3.Driver, driver_opts}]}} = Conn.child_spec(opts)

    driver_opts
  end
end
