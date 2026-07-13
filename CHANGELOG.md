# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`DISTINCT ON` (expression DISTINCT) now works.** Ecto's
  `distinct: expr(s)` rewrites to a `ROW_NUMBER()` window subquery
  with PostgreSQL-parity semantics: one row per distinct-expression
  group (winner picked by `order_by`), results ordered by the
  distinct expressions then `order_by`. Whole-source schemaless
  selects and mixing with union/intersect/except raise
  `Ecto.QueryError`. The shared suite's `:subquery_in_distinct` tag
  is un-excluded.

### Changed

- **Query placeholders render as numbered `?N`.** Previously bare
  `?`; numbering pins each placeholder to its parameter-list
  position, so clause-reordering rewrites (DISTINCT ON) cannot skew
  bindings. Generated SQL text changes; binding behavior does not.
  The `insert` path already used `?N`; the `update`/`delete` DML
  builders keep bare `?` (their clause order is fixed).

- **`RETURNING` accepts `{:unsafe_fragment, iodata}`** in insert /
  update / delete returning clauses — ecto_sql 3.14's new escape
  hatch, mirroring the PostgreSQL adapter's behavior.
- **Table modifiers pass through in `CREATE TABLE`.** ecto_sql 3.14's
  `create table(..., modifiers: "...")` lands between `CREATE` and
  `TABLE` (SQLite's grammar accepts `TEMPORARY` there). Strings and
  nil only; anything else raises `ArgumentError`.
- **Dynamic JSON path segments.** `json_extract_path` (and the
  `o.meta[o.label][o.idx]` bracket syntax) now accepts runtime path
  segments — column references and expressions, not just literals.
  Built by SQL path concatenation with a runtime `typeof` dispatch:
  integers index arrays, anything else is a dot-safe quoted object
  key; a NULL segment yields NULL instead of an error. Un-excludes
  the shared suite's `:json_extract_path_with_field` tag, including
  its `parent_as`/subquery variants. Caveat: runtime keys containing
  a double quote are unsupported (path-grammar limitation, same as
  MySQL's CONCAT-built paths).
- **Documented boolean-extraction story.** Untyped
  `select: o.meta["enabled"]` returns SQLite's storage-faithful
  `1`/`0` — there is no boolean storage class and no JSON wire
  typing, and Ecto provides no load hook for untyped select
  expressions, so no SQLite adapter can return `true` there
  (PostgreSQL/MySQL pass via protocol-level typing). The sanctioned
  fix, `select: type(o.meta["enabled"], :boolean)`, routes through
  the adapter's `:boolean` loader and is covered by adapter-owned
  tests.

- **Rich FK diagnostics (opt-in).** `rich_fk_diagnostics: true` repo
  config. SQLite reports FK violations with no table, column, or
  constraint name; with the flag on, the adapter replays the failed
  statement under `defer_foreign_keys` inside a throwaway savepoint,
  reads `PRAGMA foreign_key_check` + `foreign_key_list`, and attaches
  sorted, deterministic `%XqliteEcto3.Error.FkViolation{}` entries
  (child table/rowid, parent table, exact columns, and a
  convention-synthesized constraint name) to the error. As a result
  `Ecto.Changeset.foreign_key_constraint/3` matches like on
  PostgreSQL, and the shared Ecto suite's `:foreign_key_constraint`
  exclusion is gone. Commit-time deferred violations are diagnosed
  in place (no replay). Zero happy-path cost; diagnostic failures
  degrade to the original error with
  `fk_diagnostics: {:unavailable, reason}`. Emits a
  `[:xqlite_ecto3, :fk_diagnostics]` telemetry span.

### Fixed

- **Connect-time pragmas accepted by the URL parser are now honored.**
  `auto_vacuum`, `wal_autocheckpoint`, and `mmap_size` — parsed and
  type-coerced since the URL feature shipped — were silently dropped
  by the driver; they now apply at connect (absent still means
  "SQLite's own default", not an adapter default). `auto_vacuum` is
  applied before any page is written so it takes effect on newly
  created databases; changing an existing database's mode still
  requires `VACUUM` (SQLite semantics). Two more params
  from the same allowlist stopped being overridden by hardcoded
  values: explicit `cache_size` and `foreign_keys` config now wins;
  the defaults are unchanged (`-64_000` pages, foreign keys ON).

- **ecto_sql 3.14 compatibility.** ecto_sql 3.14.0 widened the
  `Connection.insert` callback to `insert/8` (trailing options
  keyword); fresh installs resolving 3.14 crashed `Repo.insert_all`
  with `UndefinedFunctionError` (single-row `Repo.insert` still calls
  `insert/7`, which 3.14 itself retains). One defaulted head now
  serves both arities; the requirement stays `~> 3.12`. Ecto 3.14's
  schema-mapped fragment sources (`FROM` / `JOIN` on a fragment
  carrying a schema) also render now — previously the fragment tuple
  was quoted as a table name and SQL generation crashed. CI gained a
  fresh-resolve lane plus a weekly scheduled run so upstream drift
  surfaces between pushes.

### Breaking

- **`XqliteEcto3.Error` payload restructure.** The flat
  `constraint_type` / `constraint_details` fields are replaced by a
  single `details` field carrying a typed per-class struct — a Rust
  enum with data in the variants, expressed as structs:
  - `type: :constraint_violation` → `details:
    %XqliteEcto3.Error.Constraint{subtype, table, columns, index_name,
    constraint_name, source_type, target_type, message}`
  - `type: :sqlite_failure` → `details:
    %XqliteEcto3.Error.SqliteFailure{code, extended_code, message}` —
    the primary and extended result codes were previously flattened
    into the message string and lost; now preserved structurally.
  - `type: :sql_input_error` → `details:
    %XqliteEcto3.Error.Input{code, message, sql, offset}` — only the
    message survived before; the offending SQL and byte offset were
    lost; now preserved structurally.
  - Tag-only errors keep `details: nil`.
  Migration: `e.constraint_type` → `e.details.subtype`;
  `e.constraint_details.table` → `e.details.table`. The exception
  type itself is unchanged — `rescue e in XqliteEcto3.Error` still
  catches everything.

### Added

- **`XqliteEcto3.UUIDv7.generate/0`** — time-ordered UUID v7 generator
  per RFC 9562 §5.7. Wire into a schema via
  `@primary_key {:id, :binary_id, autogenerate: {XqliteEcto3.UUIDv7, :generate, []}}`.
- **`XqliteEcto3.parse_url/1`** and **`parse_url!/1`** — parse database
  URLs (`sqlite:///path?busy_timeout=10000&journal_mode=wal`) into
  keyword-list opts. Accepts `sqlite://`, `sqlite3://`, and `file://`
  schemes; rejects URLs with a host component. Query parameters are
  allowlisted and type-coerced; unknown keys produce a structured
  `XqliteEcto3.URLError` rather than being silently dropped. Accepted
  keys: SQLite pragmas (`journal_mode`, `synchronous`, `temp_store`,
  `auto_vacuum`, `foreign_keys`, `busy_timeout`, `cache_size`,
  `wal_autocheckpoint`, `mmap_size`) plus pool / DBConnection knobs
  (`pool_size`, `timeout`, `connect_timeout`, `queue_target`,
  `queue_interval`).

## [0.1.0] - YYYY-MM-DD

Initial public release. The adapter wraps [xqlite](https://hex.pm/packages/xqlite)
for Ecto 3.x, passes the shared `ecto` + `ecto_sql` integration suite with
documented exclusions, and ships a handful of SQLite-flavored opt-in
ergonomics that other adapters do not provide.

### Added

- Full `Ecto.Adapter`, `Ecto.Adapter.Queryable`, `Ecto.Adapter.Schema`,
  `Ecto.Adapter.Transaction`, `Ecto.Adapter.Storage`, `Ecto.Adapter.Migration`,
  `Ecto.Adapter.Structure` implementations.
- `DBConnection` driver with per-query cancel tokens wired to Ecto's
  `:timeout` option, named savepoint support, and sandbox compatibility.
- Structured constraint errors (`%XqliteEcto3.Error{}`) mapping SQLite's
  13 constraint subtypes to Ecto changeset errors without string parsing.
- Streaming cursor protocol (`handle_declare` / `handle_fetch` /
  `handle_deallocate`) for `Repo.stream/2`.
- Custom Ecto types: `XqliteEcto3.Types.UUID`,
  `XqliteEcto3.Types.TimestampTZ`, `XqliteEcto3.Types.Instant`,
  `XqliteEcto3.Types.Duration`, `XqliteEcto3.Types.Array`.
- Global config knob `:xqlite_ecto3, :binary_id_storage, :string | :binary`
  for UUIDs stored via `field :id, :binary_id`.
- Opt-in migration helpers:
  - `XqliteEcto3.Migration.enum_check/3` — CHECK constraint from an
    `Ecto.Enum` declaration.
  - `XqliteEcto3.Migration.array_check/2` — `json_type(col) = 'array'` CHECK.
- Opt-in migration feature (behind repo config
  `support_alter_via_table_rebuild: true`): `MODIFY COLUMN` via the full
  SQLite table-rebuild dance, batching all changes in one `alter`
  block into a single rebuild.
- `DELETE` with `JOIN` support via conservative rewrite to
  `DELETE FROM t WHERE pk IN (SELECT t0.pk FROM t AS t0 ... JOINs ... WHERE ...)`.
  Raises a structured `Ecto.QueryError` on query shapes it cannot safely
  transform — zero ambiguity.
- `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` and
  `DROP COLUMN IF EXISTS` via PRAGMA-based pre-check (SQLite grammar has
  no such syntax).
- Shared Ecto suite integration: 15/18 files loaded, ~588 tests passing,
  documented exclusions in `test/test_helper.exs` for every permanent
  SQLite limit and every tracked adapter gap.

[Unreleased]: https://github.com/dimitarvp/xqlite_ecto3/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/dimitarvp/xqlite_ecto3/releases/tag/v0.1.0
