# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`XqliteEcto3.UUIDv7.generate/0`** — time-ordered UUID v7 generator
  per RFC 9562 §5.7. Wire into a schema via
  `@primary_key {:id, :binary_id, autogenerate: {XqliteEcto3.UUIDv7, :generate, []}}`.
- **`XqliteEcto3.parse_url/1`** and **`parse_url!/1`** — parse database
  URLs (`sqlite:///path?busy_timeout=10000&journal_mode=wal`) into
  keyword-list opts. Accepts `sqlite://`, `sqlite3://`, and `file://`
  schemes; rejects URLs with a host component. Query parameters are
  allowlisted and type-coerced; unknown keys produce a structured
  `XqliteEcto3.URLError` rather than being silently dropped.

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
