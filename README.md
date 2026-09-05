# XqliteEcto3

<!-- Uncomment at first Hex publish:
[![Hex version](https://img.shields.io/hexpm/v/xqlite_ecto3.svg?style=flat)](https://hex.pm/packages/xqlite_ecto3)
[![Hexdocs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/xqlite_ecto3)
[![Downloads](https://img.shields.io/hexpm/dt/xqlite_ecto3.svg)](https://hex.pm/packages/xqlite_ecto3)
-->
[![SQLite](https://img.shields.io/badge/SQLite-3.53.2-003B57?logo=sqlite&logoColor=white)](https://sqlite.org/releaselog/3_53_2.html)
[![Ecto](https://img.shields.io/badge/Ecto-~%3E%203.14-6e4a7e)](https://hexdocs.pm/ecto_sql)
[![Elixir](https://img.shields.io/badge/Elixir-~%3E%201.17-4B275F?logo=elixir&logoColor=white)](https://elixir-lang.org)
[![Coverage](https://coveralls.io/repos/github/dimitarvp/xqlite_ecto3/badge.svg?branch=main)](https://coveralls.io/github/dimitarvp/xqlite_ecto3?branch=main)
[![Build Status](https://github.com/dimitarvp/xqlite_ecto3/actions/workflows/ci.yml/badge.svg)](https://github.com/dimitarvp/xqlite_ecto3/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

An Ecto 3.x adapter for SQLite, built on top of [xqlite](https://hex.pm/packages/xqlite). Per-operation cancel tokens wired to Ecto's `:timeout`, structured constraint errors without regex, opt-in compile-time `:telemetry` instrumentation at the DBConnection layer, and opt-in SQLite-flavored migration ergonomics that other adapters do not provide.

> This library is pre-v0.1.0. The public API is stable enough to use but may shift before 1.0.

## Acknowledgements

XqliteEcto3 is inspired by [ecto_sqlite3](https://github.com/elixir-sqlite/ecto_sqlite3), which I treated as the reference implementation for "what an Ecto SQLite adapter should feel like". Its SQL generator and its test-exclusion list are starting points that this adapter diverges from deliberately. If ecto_sqlite3 is working well for your needs today, it is a solid choice — continue using it. XqliteEcto3 exists because I wanted the observability, cancellation, and structured-error surface that xqlite makes possible and that the existing adapters do not expose.

## Why XqliteEcto3?

- **Cancel tokens threaded through `:timeout`.** Ecto's `:timeout` option produces a real cancellation signal on the SQLite progress handler, not a fire-and-forget `sqlite3_interrupt` that lets slow operations run to completion. A runaway query actually dies when you give up on it — with one carve-out: a write waiting on another connection's lock returns on `busy_timeout`, not your deadline (see the timeout section).
- **Structured constraint errors end-to-end.** All 13 SQLite constraint subtypes map to typed atoms (`:constraint_unique`, `:constraint_foreign_key`, `:constraint_check`, …) with structured details (`table`, `columns`, `index_name`, `constraint_name`) attached. No regex-matching error messages, locale-sensitive or otherwise.
- **Conservative by default, opt-in where it counts.** Loose schemas stay loose. `CHECK` constraints, `MODIFY COLUMN` via table rebuild, rich FK diagnostics, and structured `DELETE … JOIN` rewrite are all off until you ask for them. Migrations that can be safely performed with plain SQL are. Anything that needs the 12-step SQLite rebuild dance is behind `support_alter_via_table_rebuild: true` in your repo config.
- **Custom types live at the adapter layer.** `XqliteEcto3.Types.UUID`, `Instant`, `Duration`, `TimestampTZ`, `Array`. Each is an `Ecto.Type` or `Ecto.ParameterizedType` module — no magic around how SQLite stores them.
- **Bundled SQLite 3.53.2.** Inherited from xqlite. No system install, no version drift between dev/CI/prod.
- **Shared Ecto suite integration.** The shared `ecto` + `ecto_sql` integration suites run green; every exclusion — tags, single tests, and two whole files — is documented with its reason: a permanent SQLite limitation, a tracked adapter gap, or a deliberate adapter/suite decision (`ECTO_INTEGRATION_TAGS.md` + `test/test_helper.exs` carry the full list).

## Installation

Not on Hex yet — first release is coming. Until then, add the git dep
to your `mix.exs`:

```elixir
def deps do
  [
    {:xqlite_ecto3, github: "dimitarvp/xqlite_ecto3"}
  ]
end
```

Compatibility: each xqlite_ecto3 release pins exactly one xqlite minor
series, because xqlite is pre-1.0 and its minor is the break slot. The
current pairing is xqlite `~> 0.11.0` (pulled in automatically).

Then configure your repo:

```elixir
# config/config.exs
config :my_app, ecto_repos: [MyApp.Repo]

config :my_app, MyApp.Repo,
  adapter: XqliteEcto3,
  database: "priv/repo/my_app.db",
  pool_size: 5
```

Keep `ecto_repos` in `config/config.exs`: the `mix ecto.*` tasks read it at compile time, and when it only exists in `config/runtime.exs` they print a warning and silently do nothing.

…or, 12-factor-style, drive it from a URL — the adapter parses `sqlite://` URLs natively, so the standard Phoenix pattern just works:

```elixir
# config/runtime.exs
config :my_app, MyApp.Repo,
  url: System.fetch_env!("DATABASE_URL"),
  pool_size: 5
```

Accepts `sqlite:///absolute/path.db?busy_timeout=10000&journal_mode=wal` and similar. See `XqliteEcto3.URL` for the full query-parameter allowlist and error cases. (Ecto's own generic URL parsing would reject these URLs; the adapter injects a default `init/2` into repos that don't define one, translating `:url` before Ecto sees it.) If your repo defines its own `init/2`, put these two lines in it:

```elixir
{url, config} = Keyword.pop(config, :url)
{:ok, Keyword.merge(config, XqliteEcto3.parse_url!(url))}
```

Every pooled connection caches prepared statements in an LRU keyed by SQL text (`statement_cache_size`, default 50; `0` disables) — repeated queries skip SQLite's parse/plan step, and timeouts still cancel through the cached path. Cache behavior is observable via `[:xqlite_ecto3, :statement_cache, :hit | :miss | :evicted]` telemetry.

Repo-level observability rounds this out: `XqliteEcto3.txn_state(repo)` and `XqliteEcto3.connection_stats(repo)` observe a pooled connection's transaction state and SQLite's per-connection counters through the pool, and the `hooks:` config above streams per-connection update/WAL/commit/rollback/progress events to a named process — the building blocks for caller-side concurrency strategies.

The adapter validates every configuration value it forwards to a PRAGMA at connect time. An unrecognized value (`journal_mode: :walk`, `foreign_keys: :nonsense`) is a structured connect error — never SQLite's silent fallback to a default. One read-back caveat: `PRAGMA wal_autocheckpoint` queried through SQL always reports 0, because xqlite's WAL hook occupies SQLite's single slot and emulates the autocheckpoint. Read the effective value with `XqliteEcto3.with_xqlite(repo, &XqliteNIF.get_pragma(&1, "wal_autocheckpoint"))`.

Beyond the URL-expressible parameters, the repo configuration also accepts these options:

- `custom_pragmas: [{name, value}]` — arbitrary PRAGMAs applied after the adapter's defaults, so explicit configuration always wins. This option is deliberately configuration-only, not URL-exposed. These pragmas are NOT validated: SQLite silently ignores an unknown pragma name and leniently parses values, so typos are yours to catch.
- `mode: :readonly` — a read-only pool. The adapter skips its default pragmas that need writes, and writes fail with structured `{:read_only_database, _}` errors. For composable read scaling, point a second read-only repo at the same database file.
- `default_transaction_mode: :deferred | :immediate | :exclusive` — the default is `:immediate`, deliberately: write transactions take their lock up front instead of deadlock-prone mid-transaction lock upgrades. This diverges from ecto_sqlite3's `:deferred` default on purpose. Pass `mode:` to `Repo.transaction/2` for a per-transaction override. `mode: :savepoint` works only inside an open transaction. At top level the adapter refuses it: a lone SAVEPOINT runs the transaction `:deferred` and silently discards `default_transaction_mode`. Do not put a transaction mode in the repo configuration key `mode:` — that key only sets the connection mode. The adapter refuses a transaction mode there at connect, with a structured `{:transaction_mode_as_connection_mode, _}` error. The configuration key for transactions stays `default_transaction_mode:`.
- `hooks: [update: MyListener, wal: MyListener, progress: {MyListener, every_n: 500}]` — installs xqlite's connection hooks (update, wal, commit, rollback, progress) on every pooled connection at connect time. One listener then hears every write the pool makes. Subscribers are registered process _names_, so the configuration survives restarts. If a name is not alive when a connection opens, connect fails with a structured `{:hook_subscriber_not_registered, name}` error. Messages arrive in xqlite's shapes, for example `{:xqlite_update, action, db, table, rowid}`.

Define the repo:

```elixir
defmodule MyApp.Repo do
  use Ecto.Repo, otp_app: :my_app, adapter: XqliteEcto3
end
```

Start it under your application's supervisor — add `MyApp.Repo` to the `children` list in `lib/my_app/application.ex`.

Create the database and run migrations:

```bash
mix ecto.create
mix ecto.migrate
```

### Migrating from ecto_sqlite3

Drop-in for most schemas and queries. The differences that matter:

- Constraint errors arrive as `%XqliteEcto3.Error{}` with structured fields, not exception messages parsed downstream.
- `Repo.insert_all(..., on_conflict: ..., conflict_target: ...)` and `RETURNING` work identically.
- `:binary_id` storage is configurable globally (`config :xqlite_ecto3, :binary_id_storage, :string | :binary`). Default is `:string` (TEXT, 36-char UUIDs) — matches ecto_sqlite3.
- `ALTER TABLE ... MODIFY COLUMN` is an opt-in table rebuild behind `support_alter_via_table_rebuild: true`. ecto_sqlite3 has no equivalent.

See [`guides/migrating_from_ecto_sqlite3.md`](guides/migrating_from_ecto_sqlite3.md) for the full walk-through.

## Quickstart

Given a schema:

```elixir
defmodule MyApp.User do
  use Ecto.Schema
  import Ecto.Changeset

  schema "users" do
    field :name, :string
    field :email, :string
    timestamps()
  end

  def changeset(user, attrs) do
    user
    |> cast(attrs, [:name, :email])
    |> validate_required([:name])
    |> unique_constraint(:email)
  end
end
```

And a migration (`mix ecto.gen.migration create_users` creates the file; replace its body with this):

```elixir
defmodule MyApp.Repo.Migrations.CreateUsers do
  use Ecto.Migration

  def change do
    create table(:users) do
      add :name, :string, null: false
      add :email, :string
      timestamps()
    end

    create unique_index(:users, [:email])
  end
end
```

Insert with structured error handling:

```elixir
{:ok, alice} =
  %MyApp.User{}
  |> MyApp.User.changeset(%{name: "Alice", email: "alice@example.com"})
  |> MyApp.Repo.insert()

# Unique constraint violations become typed changeset errors automatically —
# no regex on error messages anywhere in the chain.
{:error, changeset} =
  %MyApp.User{}
  |> MyApp.User.changeset(%{name: "Other", email: "alice@example.com"})
  |> MyApp.Repo.insert()

changeset.errors
# => [email: {"has already been taken", [constraint: :unique, constraint_name: "users_email_index"]}]
```

## Features

### Adapter surface

Standard Ecto behaviours: `Ecto.Adapter`, `Ecto.Adapter.Queryable`, `Ecto.Adapter.Schema`, `Ecto.Adapter.Transaction`, `Ecto.Adapter.Storage`, `Ecto.Adapter.Migration`, `Ecto.Adapter.Structure`. All the `mix ecto.*` tasks work; all the `Repo.*` functions you'd expect from a PostgreSQL setup work with the same shape.

### Cancel tokens wired to `:timeout`

```elixir
MyApp.Repo.all(slow_query, timeout: 5_000)
# => after 5s, the SQLite progress handler fires, the in-flight query aborts,
#    and an %DBConnection.ConnectionError{} surfaces — no zombie queries.
```

Through a pool, that same `:timeout` also trips DBConnection's own checkout deadline (the same value), which disconnects and reconnects that connection — standard DBConnection behavior for every adapter, not specific to this one. So connection-local state does not survive a pooled query timeout: temp tables, session `PRAGMA`s, and the prepared-statement cache on that connection are gone, and there is a reconnect cost. What the graceful cancel adds on top is that the blocked query *returns at the deadline* instead of running to completion first — the connection recycles promptly rather than after the runaway query finishes.

`:timeout` bounds how long the **query** runs, not how long your **call** waits. Every SQLite call runs on one of the BEAM's dirty schedulers — the fixed set of OS threads reserved for long native calls — and the cancelled query's reply has to get back to you through them. When those threads are all busy, the wait can run orders of magnitude past the deadline. Raising `pool_size` does not help: the queue is on the schedulers, not on the pool.

Pool exhaustion is a separate case, and it is the one a bigger pool does fix: every connection is busy, so the call never reaches SQLite at all. DBConnection's `:queue_target` and `:queue_interval` govern that wait. Both cases raise the same exception and are told apart by its `reason` field, no message parsing:

| what happened | error |
| --- | --- |
| the query was cancelled at its deadline | `%DBConnection.ConnectionError{reason: :error}` |
| no connection came free in time | `%DBConnection.ConnectionError{reason: :queue_timeout}` |

Scheduler saturation shows up as the first shape, only later than you asked for.

One wait `:timeout` does not bound at all: another connection's write lock. A blocked write sits inside SQLite's busy handler, where the progress handler — the thing a cancel signals — never runs, so the call returns when `busy_timeout` expires (default 5000 ms), however small `:timeout` is, with a structured `%XqliteEcto3.Error{type: :database_busy_or_locked}`. When lock waits must respect your deadline, set `busy_timeout` at or below it. Transaction start waits the same way: with the default `:immediate` mode, `BEGIN` takes the write lock inside the busy handler, so `Repo.transaction/2` can wait a full `busy_timeout` before failing with that error — and the failure keeps the connection rather than recycling it.

Inside an `Ecto.Adapters.SQL.Sandbox` test, a cancelled **write** also destroys that test's sandbox transaction: SQLite rolls the whole thing back when it interrupts the write, and the driver tears the connection down. What follows depends on pool state — the test either loses ownership outright (later queries report `DBConnection.OwnershipError`, `Sandbox.checkin/1` returns `:not_found`) or continues on a replacement connection whose sandbox transaction is **empty**, so everything the test wrote before the cancel is gone. Either way nothing reaches the database file and the next test checks out normally — but the errors you see after the cancel are about missing state or ownership, not about the timeout that caused them.

### Structured constraint errors

```elixir
try do
  MyApp.Repo.insert_all(MyApp.User, [%{name: "bob", email: "alice@example.com"}])
rescue
  e in XqliteEcto3.Error ->
    e.type                  # :constraint_violation
    e.details.subtype       # :constraint_unique
    e.details.table         # "users"
    e.details.columns       # ["email"]
end
```

One exception type, a typed payload per error class in `details` —
`Error.Constraint`, `Error.SqliteFailure` (primary + extended result
codes preserved), `Error.Input` (offending SQL + byte offset), `nil`
for plain tag-and-message errors, or a small map for a few named
tags: the extended result code for busy, read-only, schema-changed,
and authorization errors; the column number for a UTF-8 error; the
path and result code for a failed database open. Think Rust enum
variants carrying data, expressed as structs.

A NOT NULL violation raises this structured error too (table and
column intact) rather than an `Ecto.ConstraintError`: Ecto has no
`not_null_constraint/3` to declare, so no changeset could ever match
one. Catch it before the database with `validate_required/2`.

### Rich FK diagnostics (opt-in)

SQLite reports every foreign-key violation as a bare
`FOREIGN KEY constraint failed` — no table, no column, no constraint
name — so `foreign_key_constraint/3` changeset matching is impossible
on a stock SQLite adapter. With

```elixir
config :my_app, MyApp.Repo, rich_fk_diagnostics: true
```

the adapter replays the failed statement under deferred FK
enforcement inside a throwaway savepoint, reads
`PRAGMA foreign_key_check` + `foreign_key_list`, and attaches the
exact violations to the error:

```elixir
e.details.fk_violations
# => [%XqliteEcto3.Error.FkViolation{
#      child_table: "posts", child_rowid: 7,
#      parent_table: "users", child_columns: ["user_id"],
#      parent_columns: ["id"], constraint_name: "posts_user_id_fkey"}]
```

The synthesized name follows Ecto's default convention, so
`foreign_key_constraint(:user_id)` — and `no_assoc_constraint/3` on
a `Repo.delete` of a still-referenced parent — converts the violation
into a changeset error exactly like PostgreSQL does. (Without the
flag, neither converts: SQLite names no FK constraint, so the
structured error is raised instead.) The replay diffs
`foreign_key_check` against a baseline taken inside the savepoint, so
rows that already violated before the statement — orphans written
under `foreign_keys: false` or by another tool — are not blamed on
it; when the statement's own violations cannot be told apart from
such rows (every violation in a `WITHOUT ROWID` child table reports
a `nil` rowid; a reused rowid reproduces the orphan's row) the
diagnosis reports `fk_diagnostics: {:unavailable, :masked_by_baseline}`
rather than an empty list; at most 24 violations are attached, more
setting `fk_diagnostics: {:truncated, total}`. A deferred violation
surfacing at a raw `COMMIT` is diagnosed in place, without a replay. Zero cost on the happy path —
the replay runs only after a violation, and any diagnostic failure
degrades to the original error
(`fk_diagnostics: {:unavailable, reason}`), never masking it.
Caveat: explicitly named FK constraints still need
`foreign_key_constraint(:field, name: ...)` with the synthesized
name — SQLite does not store FK constraint names.
Three more caveats: the replay is a write, so under lock contention
it can wait up to one extra `busy_timeout` on top of the failed
statement's own wait; SQLite does not undo `last_insert_rowid()` on
rollback, so after a replay the connection reports the rowid of the
rolled-back phantom row until the next successful insert; and
streamed DML (`Ecto.Adapters.SQL.stream/4`) skips the replay — the
error still classifies as `:constraint_foreign_key`, with
`fk_diagnostics: :not_run`.

### Real unique index names

On a unique violation the adapter reads the table's unique index
names back (`PRAGMA index_list` + `index_info`) and reports the real
name when exactly one index covers the violated columns — so
`unique_constraint(:email, name: :users_email_uniq)` converts against
a custom-named index, exactly like PostgreSQL. Indexes with Ecto's
default `<table>_<columns>_index` names and `UNIQUE` column
constraints keep matching a bare `unique_constraint(:email)`; with
several candidate indexes the derived name is reported and every
candidate lands in `e.details.unique_index_names`. Postgres parity
cuts both ways: a bare `unique_constraint/1` against a custom-named
index raises `Ecto.ConstraintError` — declare the real name (this is
the one changeset difference from ecto_sqlite3, which always derives
the conventional name). The lookup runs only on the error path, is
time-budgeted, and degrades to the derived name when its reads fail
or the budget is exceeded — `e.details.unique_index_lookup` says
which happened. Streamed DML skips the lookup the same way
(`unique_index_lookup: :not_run`). Full contract in the
`XqliteEcto3.UniqueIndexNames` moduledoc.

### Streaming

```elixir
MyApp.Repo.transaction(fn ->
  MyApp.Repo.stream(MyApp.User, max_rows: 500)
  |> Stream.each(&process/1)
  |> Stream.run()
end)
```

`Repo.stream/2` is the one path `:timeout` does not cancel yet. Each
fetch runs xqlite's stream NIF, which takes no cancel token today, so a
slow batch runs to completion and `:timeout` only bounds the checkout
wait around each fetch. The wiring lands with the xqlite release that
adds cancellable stream fetches.

### Telemetry (opt-in, compile-time)

```elixir
# config/config.exs
config :xqlite, :telemetry_enabled, true
config :xqlite_ecto3, :telemetry_enabled, true
```

The adapter emits `[:xqlite_ecto3, ...]` events at the `DBConnection`
callback layer (connect / disconnect / checkout, begin / commit /
rollback, execute, and the streaming declare / fetch / deallocate) —
spans with integer-nanosecond timings. Together with Ecto's own
`[:my_app, :repo, :query]` and xqlite's `[:xqlite, ...]` events you
get a three-layer view: pool → adapter → driver. With the flags off
(the default) no telemetry call exists in the compiled bytecode.
OpenTelemetry plugs in downstream via `opentelemetry_telemetry` — no
adapter-side OTel dependency. See
[`guides/wiring_telemetry.md`](guides/wiring_telemetry.md).

### Opt-in migration helpers

Enum-backed CHECK constraints:

```elixir
import XqliteEcto3.Migration

create table(:users) do
  add :status, :string,
    check: enum_check(:status, [:active, :archived, :suspended])
end
```

Array-shape CHECK for JSON-TEXT arrays (paired with `XqliteEcto3.Types.Array`):

```elixir
import XqliteEcto3.Migration

create table(:posts) do
  add :tags, :string, check: array_check(:tags)
end
```

`MODIFY COLUMN` via table rebuild (opt-in, at-your-own-cost for large tables):

```elixir
# config/config.exs
config :my_app, MyApp.Repo, support_alter_via_table_rebuild: true

# migration
alter table(:users) do
  modify :name, :text, null: true
  add :locale, :string, default: "en"
  remove :legacy_id, :integer
end
```

All changes in one `alter` block batch into a single rebuild — not N rebuilds for N columns. The primary key (single-column and composite), foreign keys, and UNIQUE constraints are reconstructed from SQLite's structural pragmas, so they survive the rebuild (with their `ON DELETE`/`ON UPDATE` actions), alongside indexes, triggers, and AUTOINCREMENT sequences. What a structural rebuild cannot carry — `CHECK` constraints, `COLLATE` clauses, generated columns, `DEFERRABLE` foreign keys, `ON CONFLICT` clauses, and the `WITHOUT ROWID` / `STRICT` table options — makes the rebuild **refuse loudly** rather than silently drop it; do that column change by hand with `execute/1`, recreating the full table so nothing is lost. One caveat: if another, *populated* table references the rebuilt table with an `ON DELETE CASCADE`/`SET NULL`/`SET DEFAULT` action, the rebuild **refuses loudly** — dropping the old table would fire that action on the referencing rows, silently deleting or mutating them. Empty those referencing rows first, or make the change by hand. Empty referencing tables are fine. A `NO ACTION`/`RESTRICT` reference does not stop the rebuild: the dance defers foreign-key checks, and the rebuilt table satisfies them at the end. A view over the rebuilt table — or a trigger on *another* table that names it — also refuses up front (the dance's final RENAME would otherwise fail mid-way); drop the dependents, migrate, recreate them. Leaving the table with no primary key at all — removing every member of it in one `alter`, or taking the key off every member with `modify ..., primary_key: false` — refuses too; a rebuild never silently strips a table's key. Narrowing a composite key to the members the block leaves keyed is allowed (it only tightens uniqueness), whichever of the two ways the others go. Moving the key works the same way: de-key or remove every current member in that same block and grant `primary_key: true` to another column. Granting `primary_key: true` while any current key member is still keyed refuses — SQLite gives a table one primary key, and the two keys cannot both be written. Tables *created* without a primary key (`primary_key: false`) are unaffected; a deliberately keyless conversion belongs in `execute/1`. The dance needs a transaction: a normal migration provides one, and under `@disable_ddl_transaction true` (or any caller without an open transaction) the rebuild opens its own and rolls it back on any mid-dance failure.

### DELETE with JOIN

```elixir
from(c in Comment, join: u in User, on: u.id == c.author_id, where: is_nil(c.post_id))
|> MyApp.Repo.delete_all()
```

Generates `DELETE FROM comments WHERE id IN (SELECT c0.id FROM comments AS c0 INNER JOIN users AS u1 ON u1.id = c0.author_id WHERE c0.post_id IS NULL)`. Conservative: any query shape we cannot safely rewrite raises a structured `Ecto.QueryError` — no best-effort guessing.

### Custom types

All live under `XqliteEcto3.Types.*`:

- **`UUID`** — parameterized `:storage` (`:string` TEXT | `:binary` BLOB). Global default via `config :xqlite_ecto3, :binary_id_storage`.
- **`Instant`** — point-in-time as int64 ns from Unix epoch. Round-trips `DateTime`. Range 1677-09-21 to 2262-04-11.
- **`Duration`** — absolute span as int64 ns. Rejects calendar-`Duration` with non-zero year/month/week.
- **`TimestampTZ`** — timezone-aware `DateTime`.
- **`Array`** — JSON-TEXT list with optional `:element` typing (`:any`, `:string`, `:integer`, `:float`, `:boolean`).

### SQLite-specific extras via xqlite

Features like the session extension, incremental blob I/O, online backup with progress, `sqlite3_serialize`/`deserialize`, extension loading, and structured schema introspection live at the xqlite layer — none have Ecto-level equivalents. `XqliteEcto3.with_xqlite/3` bridges the two worlds: it checks a connection out of your repo's pool and hands your callback the raw `XqliteNIF` handle, so the whole xqlite toolbox runs against the same database with no out-of-band second connection:

```elixir
XqliteEcto3.with_xqlite(MyApp.Repo, fn conn ->
  Xqlite.backup(conn, "/backups/app.db")
end)
```

The handle is valid only inside the callback — see the function docs for the exact contract.

Built on the same bridge: `XqliteEcto3.explain_analyze(Repo, queryable)` runs a queryable under SQLite's real execution counters and returns the structured per-scan report (loops, rows visited, statement counters, wall time) — pass `wrap_in_transaction: true` to roll write operations back afterwards.

## FAQ

**Is it production-ready?**
I use it in my own projects. The test coverage is extensive — the shared Ecto integration suites plus the adapter's own suites. That said, it's pre-v0.1.0; the public API may shift. Report anything surprising on GitHub or ElixirForum.

**What SQLite version ships?**
Whatever xqlite ships (currently 3.53.2). `Xqlite.sqlite_version/0` if you need to check at runtime.

**Does it support Phoenix?**
Yes, as any Ecto adapter does. There is no `--database xqlite_ecto3` shortcut in `mix phx.new` yet — add the dep manually and configure the repo per the install steps above.

**Concurrency?**
SQLite is single-writer per database file. The adapter runs a standard DBConnection pool (default `pool_size: 5`) against a single file in WAL mode. Readers are parallel; writers serialize. For high sustained writes, SQLite is the wrong tool and no adapter can change that. Working patterns are in "Living with a single writer" under Design notes.

**Can I use both xqlite_ecto3 and ecto_sqlite3 in the same app?**
Technically yes — they target different Repo modules with different `:adapter`. But don't. Pick one. Mixing is a footgun for schema migrations and types.

## Known limitations

Permanent SQLite constraints (not adapter choices):

- Single-writer per database file — WAL mode relaxes this for readers only
- No schemas/namespaces (`@schema_prefix` is excluded; `ATTACH DATABASE` workaround not wired up)
- No `FOR UPDATE` row-level locks
- No user/role/GRANT system — file permissions are the only access gate
- Foreign-key violation errors do not carry the FK name (`SQLITE_CONSTRAINT_FOREIGNKEY` has no name field) — the opt-in `rich_fk_diagnostics: true` recovers table/columns/rowid and a convention-synthesized name (see Features)
- `ON DELETE SET NULL` / `SET DEFAULT` always apply to every column of the foreign key — there is no PostgreSQL-15-style per-column list (`ON DELETE SET NULL (col)`). Workarounds: split the relationship into separate single-column foreign keys, or create an `AFTER DELETE` trigger on the parent (via `execute/2` in a migration) that nulls exactly the columns you need
- `ALTER TABLE` cannot modify primary keys or foreign keys in-place (rebuild required)
- SQLite's `strftime %f` is millisecond-precision; microsecond-exact datetime arithmetic rounds
- No materialized views. `CREATE VIEW` is always virtual. You should materialize by hand into a real table, manually e.g. `CREATE TABLE ... AS SELECT`.
- No table partitioning. Heavy SQLite users emulate this by multiple database files (tenants, time windows) with separate repos or via `ATTACH`.
- No built-in network access or replication — SQLite is embedded by design; the ecosystem uses Litestream (streaming backup), LiteFS (read replicas), and libSQL/Turso (server-mode SQLite), all of which sit below or beside the adapter and need nothing from it

- A `:decimal` field over a column that was declared `REAL` (or `FLOAT`/`DOUBLE`) by something other than this adapter loses digits past 2^53: SQLite converts the value to a float64 on the way in, and the adapter's precision guard checks the value, not the column. The adapter's own migrations never create such a column — `:decimal` becomes `DECIMAL` and every float-flavored type becomes `NUMERIC`, both of which keep a whole number exact. This bites only on a legacy database or a hand-written `CREATE TABLE`; declare the column `NUMERIC` (or `DECIMAL`) to fix it.

- Datetimes are stored in SQLite's own text form — `YYYY-MM-DD HH:MM:SS[.ffffff]`, space separator, no trailing `Z` — so values written by `CURRENT_TIMESTAMP`/`datetime()` and values written by the adapter order and range-filter correctly in one column, and both load. A non-UTC `DateTime` handed to the raw-SQL path is shifted to UTC before storage (typed fields already arrive normalized from Ecto). `datetime_add`, `ago`, and `from_now` compute their comparand in the same form with six fractional digits, so strict comparisons are exact against either precision; an exact-equality boundary against a second-precision column is not (its stored text has no fractional digits), and the custom `TimestampTZ` type keeps its own offset-carrying ISO-8601 form, which interval arithmetic does not target. Databases written by versions before this form (or by tools writing ISO-8601 `T`/`Z` text) still load; to restore instant ordering against such rows, normalize once per column: `UPDATE t SET at = replace(replace(at, 'T', ' '), 'Z', '')` (skip `TimestampTZ` columns — their stored offset is their contract, though the rewrite is value-preserving there too).

- The TEXT-affinity mirror image of the same trap: a `:decimal` field over a `:string`/`TEXT` column silently stores SQLite's float-to-text rendering of the value — roughly one accepted decimal in ten comes back as a slightly different number, with no error anywhere. If you need exact arbitrary-precision digits, use a `:string` field and store the canonical string yourself; a `:decimal` field cannot be made exact by changing only the column. Three related facts about `:decimal`: the `precision:`/`scale:` migration options are carried into the DDL for documentation value only — SQLite ignores them and the exactness guard's limit is float64's, not the declared one; SQLite's `sum`/`avg` silently treat non-numeric stored values (a foreign writer's BLOB or text) as 0; and a non-numeric stored value under a `:decimal` field fails the load with Ecto's typed error naming the field and value rather than loading garbage.

- A migration type the adapter does not recognize passes through to SQLite as written, and SQLite gives any spelling with no recognizable type marker (none of `INT`/`CHAR`/`CLOB`/`TEXT`/`BLOB`/`REAL`/`FLOA`/`DOUB` in it) NUMERIC affinity — which rewrites numeric-looking text on the way in: `"007"` written into a `MONEY` or `BIT` column is stored as the integer `7`, leading zeros gone, with no error. Spellings whose meaning the adapter knows are exempt: `:json`/`:jsonb`/`:xml`/`:inet`/`:cidr`/`:macaddr`/`:tsvector` become `TEXT`, `:bytea` becomes `BLOB`, and every float-flavored spelling becomes `NUMERIC` per the rule above. For any other DB-specific spelling (`:money`, `:bit`, `:enum`, `:year`, ...), either accept the NUMERIC coercion or declare the column with a type SQLite understands.

- `mode: :savepoint` on a single operation — `Repo.insert(changeset, mode: :savepoint)` — is accepted and ignored. Ecto documents it as a way to keep one failed statement from poisoning an open transaction, which is a PostgreSQL-specific problem: after a constraint error PostgreSQL refuses every further statement until rollback. SQLite has no such state — a failed statement undoes only itself and the transaction stays usable, so the wrap would change nothing; and on a column declared `UNIQUE ON CONFLICT ROLLBACK` SQLite discards the whole transaction, open savepoints included, so a savepoint cannot help there either. `Repo.transaction(fun, mode: :savepoint)` (a real nested transaction) is honoured when an enclosing transaction is open; at top level it is refused, because a lone SAVEPOINT would run the transaction `:deferred` and silently discard `default_transaction_mode`. One genuinely different case: a multi-row `Repo.insert_all` into a table declared `ON CONFLICT FAIL` keeps the rows written before the conflict — wrap the call in a plain `Repo.transaction/2` and let the failure roll it back if you need those undone.

- `alter table ... add` with a non-constant `default:` fragment (`CURRENT_TIMESTAMP`, `(1+1)`) follows SQLite's own `ADD COLUMN` rule: it succeeds on an **empty** table and fails on a **populated** one ("Cannot add a column with non-constant default"). A migration can therefore pass in dev/CI against a fresh database and fail in production. Constant defaults — numbers, strings, booleans, and the adapter's JSON text defaults for maps/lists — are unaffected. Workaround: add the column without the non-constant default, backfill with `execute/1`, then set the default via `modify` if you need it for future rows.

- `mix ecto.dump` shells out to the `sqlite3` command-line program (its `.dump` command); the bundled SQLite library does not include that program, so install it separately where you run the task. Without it the task stops with a structured `{:missing_executable, "sqlite3"}` error. `mix ecto.load` needs nothing extra — it reads the dump file and runs it in-process.

Currently tracked gaps (see `test/test_helper.exs` for the exact exclusion list):

- Untyped boolean JSON extraction — `select: o.meta["enabled"]` returns SQLite's storage-faithful `1`/`0`, not `true`/`false` (no boolean storage class, no JSON wire typing; PostgreSQL/MySQL pass via protocol-level typing). Sanctioned fix: `select: type(o.meta["enabled"], :boolean)`. WHERE comparisons and dynamic path segments (`o.meta[o.label][o.idx]`) work fully.

## Design notes

### Loose schemas, tight guardrails — by request

Ecto users migrating from PostgreSQL expect `:not_null`, `CHECK`, UNIQUE indexes, and well-typed columns to work. They do. But SQLite's flexibility lets you do things PostgreSQL wouldn't — and some of those things are traps. XqliteEcto3's stance: do not auto-add CHECK constraints for `Ecto.Enum` fields, do not auto-reject non-matching types, do not silently rebuild tables. Every "help the user avoid this foot-gun" option exists as a function call in a migration or a flag in the repo config — never an ambient behavior.

### Structured errors over regex

SQLite's error messages are the canonical string-based format. Most Ecto adapters grep those strings to classify constraint failures. This adapter never does. Extended error codes (SQLITE_CONSTRAINT_UNIQUE etc.) + PRAGMA cross-references produce structured atoms and details in Rust at the xqlite layer; xqlite_ecto3 consumes those and maps to `Ecto.Changeset.*_constraint/3` calls without string work.

The one exception is named CHECK constraints, where the name is only present in SQLite's error text and no PRAGMA exposes it. Parsing happens once, in Rust, at the NIF boundary — never in Elixir.

### Living with a single writer

SQLite serializes writers per database file; a pool cannot change that — it only decides where the contention shows up. Patterns that work, in the order to try them:

- **Batch writes.** One transaction carrying 500 inserts beats 500 transactions each holding the write lock for one insert — `Repo.insert_all/3`, or `Repo.transaction/2` around a loop. `default_transaction_mode: :immediate` (the default) takes the write lock up front, so queued batches wait cleanly instead of deadlocking on a mid-transaction lock upgrade.
- **Retry with backoff.** For bursty writes, let `busy_timeout` absorb short waits (repo config or URL parameter), and treat `{:database_busy_or_locked, _}` errors as retryable — the shape is structured and stable, no message parsing needed, and a busy transaction start keeps its pooled connection, so a retry costs no reconnect.
- **Queue writes in the caller.** Under sustained pressure, funnel writes through a single process (GenServer, queue) per database and let the pool serve reads. WAL readers are parallel, so reads scale in the pool; a second read-only repo on the same file (`mode: :readonly`) makes the read/write split explicit.
- **Measure instead of guessing.** `Xqlite.register_busy_observer/2` forwards a `{:xqlite_busy, retries, elapsed_ms}` message per contention event; `XqliteNIF.txn_state/2` answers "does this connection hold a write transaction right now"; `Xqlite.wal_checkpoint/3` and the WAL hook expose checkpoint pressure. All of it bridges into `:telemetry` if you want dashboards.

Shutdown needs no ceremony: when the pool drains, cached statements are finalized eagerly on each disconnect, and the last connection to close checkpoints the WAL and removes the sidecar files (test-pinned behavior).

If sustained write volume outgrows all of this, that is SQLite's honest ceiling — reach for a client/server database.

### First-boot WAL noise on a fresh database

The adapter opens every pooled connection in WAL mode, so on a database file that is not yet in WAL mode — a brand-new file, or an existing one in a rollback-journal mode — the first connections each run `PRAGMA journal_mode = wal`, a write that needs a brief exclusive lock. No other writer is needed for those flips to collide: two pool members racing each other is enough, and SQLite refuses the losing flip immediately **without consulting the busy handler**, so a large `busy_timeout` does not help (measured up to 120 s — the refusal still lands in about a millisecond). The adapter absorbs the race itself: on a busy-refused journal-mode write the connect retries the flip a bounded number of times, a few milliseconds apart — the loser succeeds on the first retry in practice, and every later boot finds WAL already in the file and never writes it. A lock genuinely held for longer (another process converting the same file, say) still fails the connect with the structured `{:database_busy_or_locked, ...}` and DBConnection's own backoff takes over. If you want the flip to never happen at boot at all, run migrations before starting the pool, or pre-create the database with WAL already set (what the test suite does).

### Migration rebuild is opt-in

SQLite cannot `ALTER TABLE MODIFY COLUMN`. The canonical workaround is a 12-step rebuild: `PRAGMA defer_foreign_keys`, create new table, `INSERT ... SELECT`, drop old, rename, re-create every index/trigger/view, restore `AUTOINCREMENT` sequence, `PRAGMA foreign_key_check`. This is expensive on large tables (full rewrite + re-index). We do not do it unless you explicitly set `support_alter_via_table_rebuild: true`. If the flag is off and your migration contains a `:modify`, we raise with a clear pointer to the flag — no silent "can't do that, skipping".

The rebuild reconstructs everything SQLite exposes structurally: columns, the primary key (via `PRAGMA table_info` — single-column keys stay inline, composite keys become a table-level clause in declared order), foreign keys (via `PRAGMA foreign_key_list` — composite keys, `ON DELETE`/`ON UPDATE` actions, and implicit-primary-key references all reproduced), UNIQUE constraints (via `PRAGMA index_list`), standalone indexes, and triggers — TEMP triggers on the table included, re-created into the temp schema they came from. A self-referencing foreign key is reconstructed against the transient rebuild table so the drop cannot cascade into the freshly-copied rows; the rename then restores the final name. What lives only in the original `CREATE TABLE` text or carries detail no pragma exposes — `CHECK` constraints, `COLLATE` clauses, generated columns, `DEFERRABLE` foreign keys, `ON CONFLICT` clauses, and the `WITHOUT ROWID` / `STRICT` table options — makes a `:modify` raise loudly rather than silently dropping it. The same loud refusal covers a view over the table — TEMP views included — or a trigger on *another* table that names it: since SQLite 3.25 the dance's final rename re-parses every view and trigger, and one still naming the just-dropped table would kill the rebuild mid-way. Drop the dependents first, migrate, then recreate them. Recreate the refused tables by hand with `execute/1` where you control the full schema. `modify` itself merges the options you pass over the column's existing declaration — an aspect you don't mention (`NOT NULL`, a `DEFAULT`, `PRIMARY KEY`, `AUTOINCREMENT`) is preserved, matching Ecto's documented `modify/3` contract. Three type-rendering details: a column you `modify` (or `add`) is re-rendered through the adapter's type mapping, so a no-op-looking `modify :x, :real` changes that column's declared type to `NUMERIC` (per the float-family rule above) while untouched columns carry their stored type text verbatim (a stored spelling SQLite could not re-read bare — a reserved word, a hyphen — is re-emitted as a quoted identifier, same affinity); a column declared with no type at all comes back declared `BLOB` — same affinity, stored values untouched, only the schema text changes; and when a `modify` would move a **populated** column to a different affinity, the rebuild refuses before touching anything if the copy would rewrite any stored value — toward a numeric affinity that rewrite loses bytes (`'007'` becomes the integer `7`, a 20-digit decimal rounds through float64), toward `TEXT` it stringifies numeric storage classes and silently changes `ORDER BY` and range filters. Values that convert exactly migrate freely; for the rest, convert the data first with `execute/1`. One pre-flight hole is deliberate, matching SQLite's own `DROP COLUMN`: a trigger that depends on a removed column *without naming it* (`SELECT *`, late-bound column lists) passes the scan on both engines and leaves later writes failing loudly — name columns explicitly in trigger bodies.

One structural limitation shapes how a *referenced* table rebuilds: the dance runs inside the migration transaction, where SQLite makes `PRAGMA foreign_keys=OFF` a no-op, and `defer_foreign_keys` defers only the enforcement check, not the referential *actions*. So dropping the old table fires the `ON DELETE` action of any other table that references it. Rather than let that happen silently, the rebuild **refuses loudly** when a *populated* table references the rebuilt one with an `ON DELETE CASCADE`/`SET NULL`/`SET DEFAULT` action — naming the referencing table so you can empty its rows first or do the change by hand. Empty referencing tables rebuild fine (the action is a no-op on zero rows), and a `NO ACTION`/`RESTRICT` reference makes the rebuild fail loudly and roll back by SQLite's own rules. Rebuilding the table that *holds* a foreign key (including self-references) is always safe. The dance itself always runs under a transaction: the migration's own when one is open, or — under `@disable_ddl_transaction true` or any other non-transactional caller — one the rebuild opens itself and rolls back on any mid-dance failure, so a half-finished rebuild can never leave the table dropped.

### DELETE with JOIN refuses best-effort

Most adapters that handle DELETE+JOIN quietly guess at composite PKs, schemaless source tables, or subquery-in-FROM cases. This one raises `Ecto.QueryError` with a structured reason the moment a shape is ambiguous. If your application structure requires a shape we don't handle, opening an issue gets the shape covered explicitly — not approximated.

## Roadmap

Prioritized. Anything not listed is deferred.

Deferred until demand materializes:

- `--database xqlite_ecto3` support in `mix phx.new` (upstream Phoenix PR)
- Mirroring the custom type modules at the xqlite core layer (currently Ecto3-only)

## Contributing

Contributions welcome. Please run `mix verify` locally before submitting — it chains format check, compile `--warnings-as-errors`, Dialyzer, and the full sequential test suite. For dev loops against an unreleased xqlite checkout, export `XQLITE_PATH=../xqlite` (or wherever your xqlite working copy lives). One caveat that mode hides: CI resolves xqlite from Hex, so if your change relies on unreleased xqlite API, verify once with `XQLITE_PATH` unset before pushing — green against your local checkout does not imply green against the released package.

## License

MIT — see [`LICENSE.md`](LICENSE.md).
