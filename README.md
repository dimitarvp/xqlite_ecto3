# XqliteEcto3

<!-- Uncomment at first Hex publish:
[![Hex version](https://img.shields.io/hexpm/v/xqlite_ecto3.svg?style=flat)](https://hex.pm/packages/xqlite_ecto3)
[![Hexdocs](https://img.shields.io/badge/hex-docs-blue.svg)](https://hexdocs.pm/xqlite_ecto3)
[![Downloads](https://img.shields.io/hexpm/dt/xqlite_ecto3.svg)](https://hex.pm/packages/xqlite_ecto3)
-->
[![SQLite](https://img.shields.io/badge/SQLite-3.53.2-003B57?logo=sqlite&logoColor=white)](https://sqlite.org/releaselog/3_53_2.html)
[![Ecto](https://img.shields.io/badge/Ecto-~%3E%203.14-6e4a7e)](https://hexdocs.pm/ecto_sql)
[![Elixir](https://img.shields.io/badge/Elixir-~%3E%201.15-4B275F?logo=elixir&logoColor=white)](https://elixir-lang.org)
[![Coverage](https://coveralls.io/repos/github/dimitarvp/xqlite_ecto3/badge.svg?branch=main)](https://coveralls.io/github/dimitarvp/xqlite_ecto3?branch=main)
[![Build Status](https://github.com/dimitarvp/xqlite_ecto3/actions/workflows/ci.yml/badge.svg)](https://github.com/dimitarvp/xqlite_ecto3/actions)
[![License: MIT](https://img.shields.io/badge/License-MIT-yellow.svg)](https://opensource.org/licenses/MIT)

An Ecto 3.x adapter for SQLite, built on top of [xqlite](https://hex.pm/packages/xqlite). Per-operation cancel tokens wired to Ecto's `:timeout`, structured constraint errors without regex, opt-in compile-time `:telemetry` instrumentation at the DBConnection layer, and opt-in SQLite-flavored migration ergonomics that other adapters do not provide.

> This library is pre-v0.1.0. The public API is stable enough to use but may shift before 1.0.

## Acknowledgements

XqliteEcto3 is inspired by [ecto_sqlite3](https://github.com/elixir-sqlite/ecto_sqlite3), which I treated as the reference implementation for "what an Ecto SQLite adapter should feel like". Its SQL generator and its test-exclusion list are starting points that this adapter diverges from deliberately. If ecto_sqlite3 is working well for your needs today, it is a solid choice — continue using it. XqliteEcto3 exists because I wanted the observability, cancellation, and structured-error surface that xqlite makes possible and that the existing adapters do not expose.

## Why XqliteEcto3?

- **Cancel tokens threaded through `:timeout`.** Ecto's `:timeout` option produces a real cancellation signal on the SQLite progress handler, not a fire-and-forget `sqlite3_interrupt` that lets slow operations run to completion. A runaway query actually dies when you give up on it.
- **Structured constraint errors end-to-end.** All 13 SQLite constraint subtypes map to typed atoms (`:constraint_unique`, `:constraint_foreign_key`, `:constraint_check`, …) with structured details (`table`, `columns`, `index_name`, `constraint_name`) attached. No regex-matching error messages, locale-sensitive or otherwise.
- **Conservative by default, opt-in where it counts.** Loose schemas stay loose. `CHECK` constraints, `MODIFY COLUMN` via table rebuild, rich FK diagnostics, and structured `DELETE … JOIN` rewrite are all off until you ask for them. Migrations that can be safely performed with plain SQL are. Anything that needs the 12-step SQLite rebuild dance is behind `support_alter_via_table_rebuild: true` in your repo config.
- **Custom types live at the adapter layer.** `XqliteEcto3.Types.UUID`, `Instant`, `Duration`, `TimestampTZ`, `Array`. Each is an `Ecto.Type` or `Ecto.ParameterizedType` module — no magic around how SQLite stores them.
- **Bundled SQLite 3.53.2.** Inherited from xqlite. No system install, no version drift between dev/CI/prod.
- **Shared Ecto suite integration.** The shared `ecto` + `ecto_sql` integration suites run green; every exclusion is documented as either a permanent SQLite limitation or a tracked adapter gap.

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

Then configure your repo:

```elixir
# config/config.exs
config :my_app, MyApp.Repo,
  adapter: XqliteEcto3,
  database: "priv/repo/my_app.db",
  pool_size: 5

# config/runtime.exs
config :my_app, ecto_repos: [MyApp.Repo]
```

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

Beyond the URL-expressible parameters, repo config also accepts: `custom_pragmas: [{name, value}]` — arbitrary PRAGMAs applied after the adapter's defaults, so explicit config always wins (deliberately config-only, not URL-exposed); `mode: :readonly` — a read-only pool (write-requiring default pragmas are skipped; writes fail with structured `{:read_only_database, _}` errors; a second read-only repo pointed at the same database file is the composable read-scaling pattern); and `default_transaction_mode: :deferred | :immediate | :exclusive` — default `:immediate`, deliberately: write transactions take their lock up front instead of hitting deadlock-prone mid-transaction lock upgrades (this diverges from ecto_sqlite3's `:deferred` default on purpose). Pass `mode:` to `Repo.transaction/2` for a per-transaction override. Finally, `hooks: [update: MyListener, wal: MyListener, progress: {MyListener, every_n: 500}]` installs xqlite's connection hooks (update / wal / commit / rollback / progress) on **every pooled connection** at connect time — subscribers are registered process *names* (config survives restarts; the name must be alive when connections open, or connect fails with a structured `{:hook_subscriber_not_registered, name}`), and messages arrive in xqlite's shapes (`{:xqlite_update, action, db, table, rowid}` etc.), so one listener hears every write the pool makes.

Define the repo:

```elixir
defmodule MyApp.Repo do
  use Ecto.Repo, otp_app: :my_app, adapter: XqliteEcto3
end
```

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

And a migration:

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
codes preserved), `Error.Input` (offending SQL + byte offset), or
`nil` for tag-only errors. Think Rust enum variants carrying data,
expressed as structs.

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
`foreign_key_constraint(:user_id)` converts the violation into a
changeset error exactly like PostgreSQL does. Zero cost on the happy
path — the replay runs only after a violation, and any diagnostic
failure degrades to the original error
(`fk_diagnostics: {:unavailable, reason}`), never masking it.
Caveat: explicitly named FK constraints still need
`foreign_key_constraint(:field, name: ...)` with the synthesized
name — SQLite does not store FK constraint names.

### Streaming

```elixir
MyApp.Repo.transaction(fn ->
  MyApp.Repo.stream(MyApp.User, max_rows: 500)
  |> Stream.each(&process/1)
  |> Stream.run()
end)
```

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

All changes in one `alter` block batch into a single rebuild — not N rebuilds for N columns. Indexes, triggers, and AUTOINCREMENT sequences are preserved through the dance. The rebuild reconstructs columns from `PRAGMA table_xinfo`, which cannot carry foreign keys, `CHECK` constraints, `COLLATE`/inline-`UNIQUE` clauses, or generated columns; rather than silently drop them, a rebuild of a table that declares any of those **refuses loudly** — do that column change by hand with `execute/1`, recreating the full table so nothing is lost.

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
- **Retry with backoff.** For bursty writes, let `busy_timeout` absorb short waits (repo config or URL parameter), and treat `{:database_busy_or_locked, _}` errors as retryable — the shape is structured and stable, no message parsing needed.
- **Queue writes in the caller.** Under sustained pressure, funnel writes through a single process (GenServer, queue) per database and let the pool serve reads. WAL readers are parallel, so reads scale in the pool; a second read-only repo on the same file (`mode: :readonly`) makes the read/write split explicit.
- **Measure instead of guessing.** `Xqlite.set_busy_handler/3` forwards a `{:xqlite_busy, retries, elapsed_ms}` message per contention event; `XqliteNIF.txn_state/2` answers "does this connection hold a write transaction right now"; `Xqlite.wal_checkpoint/3` and the WAL hook expose checkpoint pressure. All of it bridges into `:telemetry` if you want dashboards.

Shutdown needs no ceremony: when the pool drains, cached statements are finalized eagerly on each disconnect, and the last connection to close checkpoints the WAL and removes the sidecar files (test-pinned behavior).

If sustained write volume outgrows all of this, that is SQLite's honest ceiling — reach for a client/server database.

### Migration rebuild is opt-in

SQLite cannot `ALTER TABLE MODIFY COLUMN`. The canonical workaround is a 12-step rebuild: `PRAGMA defer_foreign_keys`, create new table, `INSERT ... SELECT`, drop old, rename, re-create every index/trigger/view, restore `AUTOINCREMENT` sequence, `PRAGMA foreign_key_check`. This is expensive on large tables (full rewrite + re-index). We do not do it unless you explicitly set `support_alter_via_table_rebuild: true`. If the flag is off and your migration contains a `:modify`, we raise with a clear pointer to the flag — no silent "can't do that, skipping". Our rebuild reconstructs columns from `PRAGMA table_xinfo` and re-creates standalone indexes and triggers, but that column-info cannot carry foreign keys, `CHECK` constraints, `COLLATE`/inline-`UNIQUE` clauses, or generated columns. So with the flag ON, a `:modify` on a table that declares any of those also raises loudly rather than silently dropping the constraint — recreate that table by hand with `execute/1` where you control the full schema.

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
