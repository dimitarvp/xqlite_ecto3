defmodule Bench.XqliteRepo do
  use Ecto.Repo, otp_app: :xqlite_bench, adapter: XqliteEcto3
end

defmodule Bench.Sqlite3Repo do
  use Ecto.Repo, otp_app: :xqlite_bench, adapter: Ecto.Adapters.SQLite3
end

defmodule Bench.User do
  use Ecto.Schema

  schema "bench_users" do
    field(:name, :string)
    field(:email, :string)
    field(:age, :integer)
    field(:active, :boolean, default: true)
    timestamps()
  end
end

defmodule Bench.UserW do
  @moduledoc "Write-scenario table: starts empty, grows during the run."
  use Ecto.Schema

  schema "bench_users_w" do
    field(:name, :string)
    field(:email, :string)
    field(:age, :integer)
    field(:active, :boolean, default: true)
    timestamps()
  end
end

defmodule Bench.UserU do
  @moduledoc "Upsert-scenario table: seeded once; upserts mutate rows, not cardinality."
  use Ecto.Schema

  schema "bench_users_u" do
    field(:name, :string)
    field(:email, :string)
    field(:age, :integer)
    field(:active, :boolean, default: true)
    timestamps()
  end
end

defmodule Bench.Post do
  use Ecto.Schema

  schema "bench_posts" do
    field(:title, :string)
    field(:body, :string)
    belongs_to(:user, Bench.User)
    timestamps()
  end
end

defmodule Bench.Setup do
  @moduledoc """
  Repo lifecycle + identical-schema/identical-pragma setup for both
  adapters. Methodology guard: default configs differ between the
  adapters, so every pragma that matters is pinned EXPLICITLY and
  identically — WAL, synchronous NORMAL, 64 MB cache, 5 s busy
  timeout, autocheckpoint 1000.
  """

  import Ecto.Query, only: [from: 2]

  @pragmas [
    journal_mode: :wal,
    cache_size: -64_000,
    busy_timeout: 5_000
  ]

  @ddl [
    """
    CREATE TABLE IF NOT EXISTS bench_users (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      email TEXT,
      age INTEGER,
      active INTEGER DEFAULT 1,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """,
    "CREATE UNIQUE INDEX IF NOT EXISTS bench_users_email_index ON bench_users(email)",
    """
    CREATE TABLE IF NOT EXISTS bench_users_w (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      email TEXT,
      age INTEGER,
      active INTEGER DEFAULT 1,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """,
    "CREATE UNIQUE INDEX IF NOT EXISTS bench_users_w_email_index ON bench_users_w(email)",
    """
    CREATE TABLE IF NOT EXISTS bench_users_u (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      name TEXT NOT NULL,
      email TEXT,
      age INTEGER,
      active INTEGER DEFAULT 1,
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """,
    "CREATE UNIQUE INDEX IF NOT EXISTS bench_users_u_email_index ON bench_users_u(email)",
    """
    CREATE TABLE IF NOT EXISTS bench_posts (
      id INTEGER PRIMARY KEY AUTOINCREMENT,
      title TEXT NOT NULL,
      body TEXT,
      user_id INTEGER REFERENCES bench_users(id),
      inserted_at TEXT NOT NULL,
      updated_at TEXT NOT NULL
    )
    """,
    "CREATE INDEX IF NOT EXISTS bench_posts_user_id_index ON bench_posts(user_id)"
  ]

  def start_all!(dir) do
    File.mkdir_p!(dir)

    for {repo, file} <- [
          {Bench.XqliteRepo, Path.join(dir, "xqlite.db")},
          {Bench.Sqlite3Repo, Path.join(dir, "sqlite3.db")}
        ] do
      for ext <- ["", "-wal", "-shm"], do: File.rm(file <> ext)

      Application.put_env(
        :xqlite_bench,
        repo,
        [database: file, pool_size: 1, log: false] ++ @pragmas
      )

      {:ok, _} = repo.start_link()
      apply_pragma_parity!(repo)
      for ddl <- @ddl, do: repo.query!(ddl)
    end

    :ok
  end

  # Both adapters accept journal_mode/cache_size/busy_timeout in repo
  # config but their other defaults differ — pin the remainder by
  # PRAGMA so the engines run identically.
  defp apply_pragma_parity!(repo) do
    repo.query!("PRAGMA synchronous = NORMAL")
    repo.query!("PRAGMA wal_autocheckpoint = 1000")
    :ok
  end

  def seed_users!(repo, schema, n) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

    rows =
      for i <- 1..n do
        %{
          name: "user #{i}",
          email: "user#{i}@bench.local",
          age: rem(i, 80),
          active: rem(i, 2) == 0,
          inserted_at: now,
          updated_at: now
        }
      end

    rows
    |> Enum.chunk_every(500)
    |> Enum.each(fn chunk -> repo.insert_all(schema, chunk) end)

    :ok
  end

  def seed_posts!(repo, posts_per_user) do
    now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)
    user_ids = repo.all(from(u in Bench.User, select: u.id))

    rows =
      for uid <- user_ids, p <- 1..posts_per_user do
        %{
          title: "post #{p} of #{uid}",
          body: "body",
          user_id: uid,
          inserted_at: now,
          updated_at: now
        }
      end

    rows
    |> Enum.chunk_every(500)
    |> Enum.each(fn chunk -> repo.insert_all(Bench.Post, chunk) end)

    :ok
  end

  def versions do
    %{
      elixir: System.version(),
      otp: System.otp_release(),
      xqlite_sqlite: Bench.XqliteRepo.query!("SELECT sqlite_version()").rows |> hd() |> hd(),
      exqlite_sqlite: Bench.Sqlite3Repo.query!("SELECT sqlite_version()").rows |> hd() |> hd()
    }
  end
end
