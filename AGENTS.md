# xqlite_ecto3

Ecto 3.x adapter for SQLite, built on the `xqlite` NIF library
(bundled SQLite, no native install). Pre-v0.1.0, not yet on Hex.
Sibling repo: `~/kod/xqlite` — its `AGENTS.md` carries the shared
Elixir/Rust style rules and the release mechanics; this file carries
what is adapter-specific. Dependency pairing: each adapter release
pins exactly one xqlite minor series (`~> 0.11.0` — patch-level
bound; xqlite is pre-1.0 and its minor is the break slot).

## Build & Test

**NON-NEGOTIABLE: run `mix verify` before every commit.** It runs all
CI checks locally (formatting, warnings-as-errors compilation, deps
audit, sobelow, dialyzer, the full test suite) and stops on the first
failure. For long runs, background it and gate the commit on the
recorded exit code — never on memory of a green run.

```bash
mix deps.get
mix verify                  # required before every commit
mix xqlite_ecto3.test.seq   # full suite, sequential, one file per OS process
```

- Full suite only: `mix xqlite_ecto3.test.seq`, no arguments. Bare
  `mix test` is allowed only for a single named file during focused
  work; the commit gate is always `mix verify`.
- **Local xqlite source builds** ride `XQLITE_PATH` (set in the
  gitignored `.envrc`). A path override masks hex-dep breakage:
  before any push that touches the xqlite surface, run the suite with
  `XQLITE_PATH` UNSET so it compiles against the released hex dep.
  Never push code depending on unreleased xqlite API.
- Warnings-as-errors everywhere: `elixirc_options` for `lib/`, the
  `:test` alias for `.exs`. The compiler always wins — satisfy it,
  never suppress or argue.
- `async: false` is banned; a grep for it must return zero results.
  Tests touching global state are designed concurrency-resilient.
- Never skip tests on supported platforms — fix for the platform.
- Property tests: at least 2000 runs each; size-driven generators
  capped with `StreamData.scale/2` (uncapped float generators go
  quadratic in the size parameter and eat the timeout inside the
  generator).

### The vendored integration suite

The shared ecto/ecto_sql integration suites run as part of the full
suite with a curated exclusion list. Standing anchor: **440 passed /
26 excluded, exit 0** — any delta must be accounted for, never
patched to green.

- Exclusions live in `test/test_helper.exs` (tags + `{:location,
  {file, line}}` tuples, each with its rationale as a comment); the
  public mirror is `ECTO_INTEGRATION_TAGS.md`. **The two artifacts
  must be edited together** — rationale drift between them is the
  suite's recurring defect class; when a rationale's subject churns,
  sweep both.
- Every location tuple names the `test ...` line itself, never a body
  line.
- Audit instruments: a full-suite `--trace` run yields a per-test
  exclusion census; `--include "test:test <exact name>"` re-enables
  excluded tests inside full-suite context (an excluded test that
  passes when included is a finding). The two migration-conditional
  tags (`:bitstring_type`, `:duration_type`) cannot be checked that
  way — the shared migration reads the exclusion config, so drive the
  migration directly with the tag lifted.
- Full-suite isolation runs need `--no-warnings-as-errors` (upstream
  Tds files carry warnings).

## Architecture — settled decisions

- **Single pool.** No reader/writer split. Default transaction mode
  is `:immediate`, deliberately (write transactions take their lock
  up front instead of deadlock-prone mid-transaction upgrades; this
  diverges from ecto_sqlite3's `:deferred` on purpose).
- **Cancellation over interrupt.** Ecto's `:timeout` threads a
  per-operation cancel token to SQLite's progress handler; the query
  actually dies. Never `sqlite3_interrupt`. Lock waits are the
  exception: `busy_timeout` dominates a blocked write (the progress
  handler is not called inside the busy wait). Ecto's migrator drives
  DDL at `timeout: :infinity`.
- **Structured errors, no regex — anywhere.** `XqliteEcto3.Error`
  with typed atoms and per-class detail structs. Error classification
  never parses message text; tests never assert on message prose —
  if there is no structured field to match, that is a bug in the
  error struct, fix the struct first. Errors carry the most specific
  structured information possible; this is a library, callers need
  maximum diagnostics.
- **Config is validated at connect.** SQLite's pragma parser silently
  falls back to a default on any unrecognized value, so the adapter
  is the only loud layer: every pragma-bound repo-config value has a
  connect validator with a structured rejection. `custom_pragmas` is
  the one deliberate unvalidated escape hatch (documented as such).
  Posture for config/pragma surfaces: validate-or-refuse at our
  boundary plus documentation — do not chase value combinations or
  SQLite-internal semantics.
- **Schema namespaces.** Catalog reads that matter cover
  `sqlite_schema` AND `sqlite_temp_schema`; ATTACHed schemas are out
  of scope by decision — the posture is refuse-or-degrade on
  ambiguity plus documentation, never cross-schema resolution.
- **Types live at the adapter layer.** `Types.UUID`, `Instant`,
  `Duration`, `TimestampTZ`, `Array` (arrays = JSON TEXT; membership
  translates via `JSON_EACH`). Decimals store NUMERIC with a loud
  exactness guard: values float64 cannot represent exactly raise
  `DecimalPrecisionError` instead of silently truncating; decimal
  params bind as the guard-proven numeric form, never TEXT.
- **The table-rebuild engine is opt-in**
  (`support_alter_via_table_rebuild: true`) and refuses loudly
  anything it cannot faithfully preserve — a silent drop of any
  construct is the cardinal sin. Its scans over stored `CREATE TABLE`
  text lex comments and all four quoting forms the way SQLite's
  tokenizer does. A post-rebuild structural check
  (`RebuildVerification`) compares an independent model against the
  rebuilt reality; helpers shared between the engine and the verifier
  are a blind-spot class — keep the shared set minimal and prefer
  independent reads.
- **Transaction-state sync.** The driver re-syncs its cached
  transaction flag on raw transaction-control statements, skipping
  everything SQLite's tokenizer skips (whitespace, both comment
  forms, semicolons, the UTF-8 BOM). Raw `BEGIN` through a pool is
  inherently unsafe above pool size 1 and stays documented as such.
- **`with_xqlite/3` always starts its own checkout** — never call it
  (or `txn_state/2`, `connection_stats/1`) inside `Repo.transaction`,
  `Repo.checkout`, or itself. Connection-scoped state installed
  through the bridge outlives the callback for that pooled
  connection's life.
- **Telemetry** is compile-time gated (`XQLITE_ECTO3_TELEMETRY`).
  Emit via `:telemetry` only — OpenTelemetry is a downstream mapping
  (`Telemetry.OpenTelemetry`), never a direct dependency. Every
  event carries `:conn`; the statement cache (and its events) are
  per connection; OTel `error.type` is the error's typed atom, never
  a struct name. Telemetry-asserting tests need discriminators
  (conn-pinned or SQL-filtered handlers) — handlers are process-
  global and every test file runs async.
- **Ecto/DBConnection contract exceptions are the one sanctioned
  raise surface** (`Ecto.QueryError` for untranslatable queries,
  `ArgumentError` refusals in migration DDL, the typed error
  structs). Everything else is `:ok`/`:error` tuples, per the shared
  style rules.
- **ecto_sqlite3 is the reference for look-and-feel, not gospel** —
  its SQL generator and exclusion list are starting points this
  adapter diverges from deliberately; divergences are documented
  (README, the migration guide).

## Project structure

- `lib/xqlite_ecto3.ex` — adapter entry: `execute_ddl`, the rebuild
  engine, `with_xqlite/3`, observability helpers, URL init injection
- `lib/xqlite_ecto3/driver.ex` — DBConnection callbacks: connect (+
  config validators), the transaction-state sync, statement cache,
  cancel wiring, disconnect guard
- `lib/xqlite_ecto3/connection.ex` — SQL generation, DDL rendering,
  `to_constraints/2`
- `lib/xqlite_ecto3/query.ex`, `decimal_precision.ex` — param
  encoding, the decimal exactness guard
- `lib/xqlite_ecto3/error.ex`, `fk_diagnostics.ex`,
  `unique_index_names.ex` — error wrap + the two opt-in/violation-
  path enrichments (FK replay, real unique index names)
- `lib/xqlite_ecto3/data_type.ex` — Ecto type → SQLite column type
  (incl. the REAL-affinity → NUMERIC rewrite), default-value
  rendering + refusal
- `lib/xqlite_ecto3/rebuild_verification.ex` — the post-rebuild
  structural check + the shared DDL text scans
- `lib/xqlite_ecto3/types/` — custom Ecto types
- `lib/xqlite_ecto3/telemetry*` — events, OTel mapping
- `lib/xqlite_ecto3/url.ex` — `sqlite://` URL parsing (typed
  allowlist)
- `guides/` — hexdoc guides (telemetry wiring, migrating from
  ecto_sqlite3)
- The review program's records (ledger, axes, backlog) live outside
  this repo in `~/kod/xqlite-review-ledgers/xqlite_ecto3/`; their
  nomenclature (finding IDs, run numbers, axes) lives ONLY there,
  never in code or public docs

## Style

The shared Elixir style rules in xqlite's `AGENTS.md` apply in full —
notably: minimal diff; no early returns; pipes discipline; the
comment doctrine (every comment fiercely justifies its existence or
dies; never backlog/finding-ID references in code; comment-line count
trends down, measured with `tokei`); commit style (50-char lowercase
subject, 72-char body wrap, what/why never how, no trailers).

## Gotchas

- **The changeset naming contract for unique indexes is Postgres
  parity**: the adapter resolves the real unique index name on the
  violation path, so a custom-named index requires
  `unique_constraint(:field, name: ...)` — a bare declaration raises.
  Ecto matches FKs via `constraint: :foreign`; FK names are
  convention-synthesized (`<table>_<col>_fkey`).
- **The rebuild + SQL Sandbox**: the dance explicitly resets
  `defer_foreign_keys` (SQLite auto-resets only at COMMIT, which the
  sandbox never reaches) and is checkout-pinned to one connection.
- **`PRAGMA wal_autocheckpoint` read via SQL always reports 0**
  (xqlite's WAL hook occupies the slot and emulates it) — read the
  effective value through the bridge.
- **The telemetry-OFF build fails several telemetry-asserting test
  files** — the OFF CI lane runs a smoke subset; any fix must be
  verified under BOTH builds.
- **Dependency bumps** (SQLite/rusqlite via xqlite, or ecto/ecto_sql)
  follow `UPGRADE_PLAYBOOK.md` in the xqlite repo — including the
  vendored-census re-check and the exclusion-rationale sweep here.
