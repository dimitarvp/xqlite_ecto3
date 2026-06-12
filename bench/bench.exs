# Comparative benchmarks: xqlite_ecto3 vs ecto_sqlite3.
#
# Methodology: identical schemas, identical pragmas (see Bench.Setup),
# file-backed DBs under bench/tmp/, pool_size 1, logging off, stock
# adapter defaults otherwise (telemetry compiled out, no FK
# diagnostics). Each adapter gets its own database file. Bundled
# SQLite versions are printed — they differ between the libraries and
# cannot be equalized, only disclosed.
#
# Run:  cd bench && mix deps.get && MIX_ENV=prod mix run bench.exs
# (prod is REQUIRED for honest numbers: dev builds the Rust NIF
# unoptimized while exqlite always compiles its C at -O2)
# Knobs: BENCH_TIME / BENCH_WARMUP / BENCH_MEMORY_TIME (seconds).

import Ecto.Query

alias Bench.{Post, Setup, Sqlite3Repo, User, UserU, UserW, XqliteRepo}

dir = Path.join(__DIR__, "tmp")
:ok = Setup.start_all!(dir)

IO.inspect(Setup.versions(), label: "environment")

# ---------------------------------------------------------------------------
# Seed read-path data: 10_000 users, 5 posts each, in BOTH databases.
# ---------------------------------------------------------------------------
for repo <- [XqliteRepo, Sqlite3Repo] do
  :ok = Setup.seed_users!(repo, User, 10_000)
  :ok = Setup.seed_users!(repo, UserU, 10_000)
  :ok = Setup.seed_posts!(repo, 5)
end

time = String.to_integer(System.get_env("BENCH_TIME", "5"))
warmup = String.to_integer(System.get_env("BENCH_WARMUP", "2"))
memory_time = String.to_integer(System.get_env("BENCH_MEMORY_TIME", "1"))

bench = fn name, scenarios ->
  IO.puts("\n=== #{name} ===")

  Benchee.run(scenarios,
    time: time,
    warmup: warmup,
    memory_time: memory_time,
    print: [configuration: false]
  )
end

uniq = :erlang.unique_integer([:positive])
now = NaiveDateTime.utc_now() |> NaiveDateTime.truncate(:second)

insert_one = fn repo ->
  i = :erlang.unique_integer([:positive])
  repo.insert!(%UserW{name: "n#{i}", email: "i#{uniq}_#{i}@x.local", age: 30})
end

bulk_rows = fn n ->
  base = :erlang.unique_integer([:positive])

  for i <- 1..n do
    %{
      name: "bulk #{i}",
      email: "bulk#{base}_#{i}@x.local",
      age: rem(i, 80),
      active: true,
      inserted_at: now,
      updated_at: now
    }
  end
end

# ---------------------------------------------------------------------------
bench.("single insert", %{
  "xqlite_ecto3" => fn -> insert_one.(XqliteRepo) end,
  "ecto_sqlite3" => fn -> insert_one.(Sqlite3Repo) end
})

bench.("bulk insert_all 1000 rows", %{
  "xqlite_ecto3" => fn -> XqliteRepo.insert_all(UserW, bulk_rows.(1000)) end,
  "ecto_sqlite3" => fn -> Sqlite3Repo.insert_all(UserW, bulk_rows.(1000)) end
})

upsert = fn repo ->
  i = rem(:erlang.unique_integer([:positive]), 10_000) + 1

  repo.insert!(
    %UserU{name: "upserted", email: "user#{i}@bench.local", age: 1},
    on_conflict: [set: [age: 1, updated_at: now]],
    conflict_target: :email
  )
end

bench.("upsert on existing email", %{
  "xqlite_ecto3" => fn -> upsert.(XqliteRepo) end,
  "ecto_sqlite3" => fn -> upsert.(Sqlite3Repo) end
})

# ---------------------------------------------------------------------------
point = fn repo -> repo.get!(User, rem(:erlang.unique_integer([:positive]), 9000) + 1) end

bench.("point read by primary key", %{
  "xqlite_ecto3" => fn -> point.(XqliteRepo) end,
  "ecto_sqlite3" => fn -> point.(Sqlite3Repo) end
})

range = fn repo ->
  repo.all(from(u in User, where: u.age > 40 and u.active == true, order_by: u.age, limit: 100))
end

bench.("range scan, where + order + limit 100", %{
  "xqlite_ecto3" => fn -> range.(XqliteRepo) end,
  "ecto_sqlite3" => fn -> range.(Sqlite3Repo) end
})

join = fn repo ->
  repo.all(
    from(p in Post,
      join: u in assoc(p, :user),
      where: u.age > 60,
      select: {p.title, u.name},
      limit: 200
    )
  )
end

bench.("join posts->users, limit 200", %{
  "xqlite_ecto3" => fn -> join.(XqliteRepo) end,
  "ecto_sqlite3" => fn -> join.(Sqlite3Repo) end
})

aggregate = fn repo ->
  repo.one(from(u in User, where: u.active == true, select: {count(u.id), avg(u.age)}))
end

bench.("aggregate count+avg over 10k", %{
  "xqlite_ecto3" => fn -> aggregate.(XqliteRepo) end,
  "ecto_sqlite3" => fn -> aggregate.(Sqlite3Repo) end
})

stream = fn repo ->
  repo.transaction(fn ->
    repo.stream(from(u in User), max_rows: 500)
    |> Stream.map(& &1.id)
    |> Enum.reduce(0, fn _, acc -> acc + 1 end)
  end)
end

bench.("stream 10k rows (max_rows 500)", %{
  "xqlite_ecto3" => fn -> stream.(XqliteRepo) end,
  "ecto_sqlite3" => fn -> stream.(Sqlite3Repo) end
})

# ---------------------------------------------------------------------------
# Cancellation: capability DEMO, not a comparison — ecto_sqlite3 has no
# equivalent. Measures wall time from issuing a doomed query with a
# short :timeout until control returns with the query dead.
# ---------------------------------------------------------------------------
IO.puts("\n=== cancellation demo (xqlite_ecto3 only) ===")

slow_sql = """
WITH RECURSIVE n(x) AS (VALUES(0) UNION ALL SELECT x+1 FROM n WHERE x < 200000000)
SELECT count(*) FROM n
"""

timings =
  for _ <- 1..10 do
    t0 = System.monotonic_time(:microsecond)

    try do
      XqliteRepo.query!(slow_sql, [], timeout: 100)
    rescue
      _ -> :ok
    catch
      :exit, _ -> :ok
    end

    System.monotonic_time(:microsecond) - t0
  end

avg = div(Enum.sum(timings), length(timings))

IO.puts(
  "10 runs with timeout: 100ms — control returned in avg #{div(avg, 1000)}ms " <>
    "(min #{div(Enum.min(timings), 1000)}ms, max #{div(Enum.max(timings), 1000)}ms); " <>
    "the same query uncancelled runs for many seconds."
)
