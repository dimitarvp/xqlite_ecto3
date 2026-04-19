# Migrating from ecto_sqlite3

XqliteEcto3 is a drop-in adapter for most Phoenix / Ecto applications that
use [ecto_sqlite3](https://github.com/elixir-sqlite/ecto_sqlite3) today.
Schemas, changesets, most queries, and most migrations port unchanged.
The differences that matter fall into three buckets:

1. **Constraint errors** change shape — from opaque strings to structured
   `%XqliteEcto3.Error{}` with typed atoms.
2. **Cancellation semantics** change — Ecto's `:timeout` option now
   actually cancels in-flight queries instead of letting them run out.
3. **A handful of migration shapes** gain opt-in guardrails — `MODIFY
   COLUMN` becomes possible behind a config flag; `CHECK` helpers
   ship as explicit function calls.

Nothing in this guide is "you must rewrite your code". Most apps flip
the adapter, run their test suite, and move on. Read below for the
spots where the test suite might flag a change.

## Step 1 — swap the dependency

In `mix.exs`:

```diff
 defp deps do
   [
-    {:ecto_sqlite3, "~> 0.x"}
+    {:xqlite_ecto3, "~> 0.1.0"}
   ]
 end
```

Run `mix deps.get` and `mix deps.unlock --unused`.

## Step 2 — swap the adapter in config

```diff
 # config/config.exs
 config :my_app, MyApp.Repo,
-  adapter: Ecto.Adapters.SQLite3,
+  adapter: XqliteEcto3,
   database: "priv/repo/my_app.db"
```

```diff
 # lib/my_app/repo.ex
 defmodule MyApp.Repo do
-  use Ecto.Repo, otp_app: :my_app, adapter: Ecto.Adapters.SQLite3
+  use Ecto.Repo, otp_app: :my_app, adapter: XqliteEcto3
 end
```

No other touchpoints. `mix ecto.create`, `mix ecto.migrate`, `Repo.all`,
`Repo.insert_all`, `Repo.transaction`, `Repo.stream` — all work with the
same shape.

## Step 3 — run your test suite

Most suites pass unchanged. When they don't, it's one of the following.

### 3a. Constraint errors are structured

If your code has anything like:

```elixir
rescue
  e in RuntimeError ->
    if String.contains?(e.message, "UNIQUE"), do: :duplicate, else: reraise(e, __STACKTRACE__)
end
```

…remove the string match. XqliteEcto3 raises `%XqliteEcto3.Error{}` with
typed atoms and structured details:

```elixir
rescue
  e in XqliteEcto3.Error ->
    case e.constraint_type do
      :constraint_unique -> handle_duplicate(e.constraint_details)
      :constraint_foreign_key -> handle_missing_parent(e.constraint_details)
      :constraint_check -> handle_check_violation(e.constraint_details)
      _ -> reraise(e, __STACKTRACE__)
    end
end
```

The changeset mapping (`Ecto.Changeset.unique_constraint/3`,
`foreign_key_constraint/3`, `check_constraint/3`) works identically — if
your code uses the changeset machinery, you likely don't touch anything.

### 3b. `:timeout` actually cancels

ecto_sqlite3 honors `:timeout` at the DBConnection layer only — if a
slow query is already running inside SQLite, the timeout fires but the
query keeps running until it finishes on its own. XqliteEcto3's
cancel-token wiring aborts the in-flight query at the SQLite level.

For most apps this is a bug fix; for some apps that were relying on
"timeout-but-actually-finish" semantics (rare) it's a behavioural
change. Test queries that exercise long-running operations (`SELECT`
over large tables, recursive CTEs, unindexed `UPDATE`) if you want to
verify.

### 3c. Returned-row ordering in `insert_all`

Both adapters use `INSERT ... RETURNING` for SQLite 3.35+. The returned
row order is implementation-dependent in SQL-land and in practice
matches insertion order for both adapters. If your code depends on a
specific order, add an explicit `ORDER BY` or a `returning:` column set
that includes your ordering key and re-sort in Elixir.

## Step 4 — migration shapes that change

### `:binary_id` storage

ecto_sqlite3 stores `field :id, :binary_id` as a 36-char TEXT string
(the `Ecto.UUID` default form). XqliteEcto3 defaults to the same, but
exposes a global knob:

```elixir
config :xqlite_ecto3, :binary_id_storage, :string  # default, matches ecto_sqlite3
# or
config :xqlite_ecto3, :binary_id_storage, :binary  # 16-byte BLOB storage
```

Flipping to `:binary` after rows exist in `:string` form is **not
transparent** — `Ecto.UUID.load/1` raises on strings. Leave the default
unless you're starting fresh or willing to migrate existing rows.

For per-field control (mixed storage across fields), use the escape
hatch:

```elixir
schema "tokens" do
  field :id, XqliteEcto3.Types.UUID, storage: :binary
  # ...
end
```

### `MODIFY COLUMN` in migrations

ecto_sqlite3 raises on `alter table(:foo) do modify :col, ... end` —
SQLite has no `ALTER TABLE MODIFY COLUMN`. XqliteEcto3 can implement it
via the canonical 12-step rebuild dance (create new, copy, drop, rename,
recreate indexes/triggers, restore AUTOINCREMENT), behind a flag:

```elixir
config :my_app, MyApp.Repo, support_alter_via_table_rebuild: true
```

With the flag off, `modify` still raises — same behaviour as
ecto_sqlite3. Turning the flag on is an explicit opt-in; the cost on
large tables is a full rewrite + re-index.

All changes in one `alter` block batch into a single rebuild — not N
rebuilds for N columns.

### `CHECK` constraints via migration helpers

The rebuild-vs-CHECK story around `Ecto.Enum`: if you want the DB to
reject out-of-set values for an `Ecto.Enum` field, ecto_sqlite3 doesn't
give you a shortcut; you write the CHECK manually. XqliteEcto3 ships a
helper that emits the same shape but keyed off the Enum's value list:

```elixir
import XqliteEcto3.Migration

create table(:users) do
  add :status, :string,
    check: enum_check(:status, [:active, :archived, :suspended])
end
```

The equivalent without the helper (identical SQL, portable across
adapters):

```elixir
add :status, :string,
  check: %{
    name: "status_enum_check",
    expr: "status IN ('active', 'archived', 'suspended')"
  }
```

Same story for `array_check/2` paired with `XqliteEcto3.Types.Array`.

### `DELETE` with `JOIN`

ecto_sqlite3 raises on `from(... join ...) |> Repo.delete_all()`.
XqliteEcto3 rewrites it as `DELETE FROM t WHERE pk IN (SELECT t0.pk
FROM t AS t0 ...joins... WHERE ...)`.

The rewrite is **conservative**. It raises a structured
`Ecto.QueryError` when the query shape is something it cannot safely
transform — schemaless main source, composite primary key, subquery as
main source. If your tests hit such a shape, you'll see the error at
test time, not runtime.

## Step 5 — features ecto_sqlite3 doesn't have

None of these are required; they exist if you want them:

- **`Xqlite.explain_analyze/3`** via `Repo.checkout(fn -> ... end)` —
  structured runtime stats per scan node (rows visited, loops, estimated
  rows) plus statement-level counters (vm_step, memused, sort) plus
  wall-clock. The closest SQLite has to Postgres's `EXPLAIN (ANALYZE)`.
- **Instant / Duration / TimestampTZ / Array** custom types under
  `XqliteEcto3.Types.*`.
- **Per-query cancellation from any process** — the `:timeout` option
  routes through a progress handler. A supervision tree can abort
  stuck queries without needing the connection handle.

## Step 6 — SQLite features both adapters inherit from xqlite

These are xqlite-layer features. Access them by checking a connection
out of the pool and calling xqlite's NIFs directly. Not unique to
XqliteEcto3, but worth knowing:

- Session extension (changeset capture / apply)
- Online backup with progress + cancellation
- Incremental blob I/O
- `sqlite3_serialize` / `deserialize` for in-memory snapshots
- Extension loading (FTS5, JSON1, sqlean functions, SpatiaLite)

## What does NOT change

- Every `mix ecto.*` task works the same.
- `Repo.transaction`, nested transactions via savepoints, `Ecto.Multi`.
- Sandbox mode for concurrent tests (`Ecto.Adapters.SQL.Sandbox`) —
  works identically; set `pool: Ecto.Adapters.SQL.Sandbox` in test
  config.
- `Repo.stream/2` via the cursor protocol.
- All the preload / query / subquery / CTE / window function surface.
- Parameter binding, RETURNING, upsert via `on_conflict`.

## Sanity-check table

| Area | ecto_sqlite3 | XqliteEcto3 |
|---|---|---|
| Adapter module | `Ecto.Adapters.SQLite3` | `XqliteEcto3` |
| Constraint errors | strings in exception messages | `%XqliteEcto3.Error{type, constraint_type, constraint_details}` |
| `:timeout` semantics | DBConnection-layer only | DBConnection-layer AND in-flight SQLite cancellation |
| `:binary_id` default storage | TEXT (36-char) | TEXT (36-char) — configurable |
| `ALTER ... MODIFY COLUMN` | raises | opt-in table rebuild |
| `DELETE` with `JOIN` | raises | conservative rewrite |
| `EXPLAIN ANALYZE` | N/A | `Xqlite.explain_analyze/3` |
| Custom types | `:integer` for booleans, etc. | ditto + optional `XqliteEcto3.Types.*` |
| Shared Ecto suite coverage | comparable | ~588 tests; documented exclusions |
| `mix ecto.*` tasks | work | work |
| `Ecto.Adapters.SQL.Sandbox` | works | works |
| Streaming (`Repo.stream/2`) | works | works |

## If something goes wrong

Open an issue at
<https://github.com/dimitarvp/xqlite_ecto3/issues> with the query, the
schema, and the error. The adapter errs on the side of loud structured
errors rather than silent best-effort — if a query shape isn't covered,
you'll see it, and adding coverage is usually a small targeted change.

The [ElixirForum thread](https://elixirforum.com/t/xqlite-low-level-sqlite-nif-library/)
for xqlite is also a fine place for questions.
