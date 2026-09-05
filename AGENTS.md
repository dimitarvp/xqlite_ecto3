# xqlite_ecto3

Ecto 3.x adapter for SQLite on the `xqlite` NIF library (bundled SQLite,
no native install). The sibling repo `~/kod/xqlite` carries the shared
Elixir style rules in its `AGENTS.md`; this file carries only what is
adapter-specific. Each release pins one xqlite minor series at patch
level — xqlite is pre-1.0 — and `RELEASING.md` covers moving that pin.

## Build and test

```bash
mix verify                  # required before every commit
mix xqlite_ecto3.test.seq   # full suite, one OS process per test file
```

- `mix verify` (the alias in `mix.exs`) is the commit gate: format check,
  compile, `deps.audit`, sobelow, dialyzer, the suite, then a tree stamp.
- `scripts/tree_fingerprint.exs` writes that stamp over every file git
  tracks or does not ignore; `.claude/hooks/commit_tripwire.sh` denies a
  `git commit` whose tree no longer matches. Commit right after a green
  verify with no edits in between — Markdown counts.
- Backgrounding a long verify: write its exit code to a file and make the
  commit script's FIRST statement `[ "$(cat "$EXIT")" = 0 ] || exit 1`.
  Never pipe a gate through `tail`, `head` or `rg`.
- Full suite only; bare `mix test` is for one named file during focused
  work. Never skip a test on a supported platform. `async: false` is
  banned: make a test resilient to concurrency instead of serializing it.
- Warnings are errors everywhere — `elixirc_options` for `lib/`, the
  `test: "test --warnings-as-errors"` alias for `.exs`.
- `XQLITE_PATH` (in the gitignored `.envrc`) swaps the xqlite Hex
  dependency for a local checkout, hiding code that needs unreleased
  xqlite API. Run the suite with it unset before any push touching xqlite.

### The vendored integration suite

The shared ecto and ecto_sql suites run inside the full suite behind a
curated exclusion list. Anchor: 440 passed / 26 excluded, exit 0 — any
delta is accounted for, never patched to green.

- Exclusions live in `test/test_helper.exs` (tags and `{:location, {file,
  line}}` tuples, each with its reason beside it), mirrored for readers in
  `ECTO_INTEGRATION_TAGS.md`. Edit the two together.
- A location tuple names the `test ...` line, never a body line: an ExUnit
  line filter snaps to the nearest test at or before it, so a tuple on a
  `@tag` line silently runs the test before it.

## Property tests: laws, not pins

Every invariant gets a StreamData property in `*_law_test.exs`: text forms,
encodings, name derivations, parsers, type rules, error shapes, rewrites.

- `max_runs` at least 2000, and a property runs in seconds, not minutes.
- Cap size-driven generators with `StreamData.scale/2`: `float/0` costs
  time quadratic in the size parameter and size grows by one per run, so
  an uncapped property spends its budget generating.
- Build hostile domains on purpose (quotes, embedded NULs, case variants,
  Unicode, boundary integers); use SQLite as the oracle where you can.
- The example test stays beside the law as its red anchor, and golden SQL
  strings live only there. No environment-specific assertions: wide timing
  windows, structured error shapes over POSIX atoms, reasons on skips.

## Elixir

xqlite's `AGENTS.md` rules apply in full, including its comment doctrine
and its commit and PR style. The one adapter addition: Ecto and
DBConnection contracts require raising, and that is the only sanctioned
raise surface — `Ecto.QueryError` for a query SQLite has no grammar for,
`ArgumentError` for migration DDL it cannot express, and the typed error
structs in `data_type.ex`, `decimal_precision.ex`, `rebuild_verification.ex`.

## Structured errors

- Every error is one `%XqliteEcto3.Error{}`: a typed `:type` atom, a
  per-class struct in `:details`, the most specific information available.
  Classification never parses message text: `error.ex`, `fk_diagnostics.ex`
  and `unique_index_names.ex` read only xqlite's structured details, and a
  prose-only distinction needs more structure pushed up from xqlite.
- An `Error` with `type: nil` — `Error.wrap/1`'s fallback for a reason it
  does not recognize — must never reach a caller or a telemetry event:
  `Telemetry.OpenTelemetry.error_type/1` then reports the struct name.
  Fix the wrap site; never document around it.
- Invalid or out-of-range configuration is a structured rejection at
  connect, never a clamp and never a silent default.

## Settled decisions

- One pool, no reader/writer split, and `default_transaction_mode` is
  `:immediate` so a write takes its lock up front.
- Ecto's `:timeout` becomes a per-operation cancel token on SQLite's
  progress handler; never `sqlite3_interrupt`. `busy_timeout` bounds a
  wait on another connection's write lock — no progress handler runs there.
- Every pragma-bound config value is validated at connect: SQLite's pragma
  parser silently substitutes a default for an unrecognized value.
  `custom_pragmas` is the one deliberate escape hatch.
- ATTACHed schemas are out of scope: refuse or degrade on ambiguity. The
  rebuild's reads of dependent objects, triggers and rewritten dependents
  union `sqlite_schema` with `sqlite_temp_schema` so TEMP objects survive
  it; every other catalog read is `sqlite_schema` alone, on purpose.
- Types live at the adapter layer: `Types.UUID`, `Instant`, `Duration`,
  `TimestampTZ`, `Array` (JSON TEXT, membership via `JSON_EACH`).
- `DataType.column_type/2` renders `:decimal` as `DECIMAL` or
  `DECIMAL(p,s)`, and the float family (`:float`, `:real`, `:double`,
  `:double_precision`) as the keyword `NUMERIC` — a REAL-affinity column
  would round an integer-exact value. A `Decimal` binds as an exact int64
  or float64, never text, raising `DecimalPrecisionError` when it cannot.
- The table rebuild is opt-in (`support_alter_via_table_rebuild: true`)
  and refuses loudly whatever it cannot preserve; a silent drop is the
  cardinal sin. `RebuildVerification` re-reads the table independently
  before COMMIT. Rich FK diagnostics need `rich_fk_diagnostics: true`.
- The driver re-syncs its cached transaction flag on transaction control
  arriving as raw SQL, skipping what SQLite's tokenizer skips; a raw
  `BEGIN` through a pool stays unsafe above pool size 1.
- `with_xqlite/3` opens its own checkout, so it, `txn_state/2` and
  `connection_stats/1` never nest in a transaction, checkout, or each other.
- Telemetry is compile-time gated by `config :xqlite_ecto3,
  :telemetry_enabled`; emit through `:telemetry` only, with
  `Telemetry.OpenTelemetry` a downstream mapping. Every event after
  connect carries `:conn`; the `connect` span cannot — no connection yet.

## Gotchas

- The unique-index naming contract matches Postgres: the adapter emits the
  real index name on the violation path, so a custom-named index needs
  `unique_constraint(:field, name: ...)`; a bare one raises. FK names are
  `<table>_<col>_fkey`; Ecto matches them on `constraint: :foreign`.
- The rebuild under `Ecto.Adapters.SQL.Sandbox`: `on_one_connection/4`
  pins a connection only when no transaction is open, and under the
  Sandbox one always is, so the rebuild runs on the caller's. It resets
  `defer_foreign_keys` itself — SQLite clears that flag only at COMMIT.
- `PRAGMA wal_autocheckpoint` read through SQL always reports 0 (xqlite's
  WAL hook holds the slot and emulates it) — read it via `with_xqlite/3`.
- Telemetry handlers are process-global and every test file is async, so a
  telemetry-asserting test needs a discriminator. Several of those files
  fail in the telemetry-off build, which CI only smoke-tests: check both.
- The DELETE-with-JOIN rewrite has no opt-in flag: `Connection.delete_all/1`
  routes any query carrying joins into `delete_all_with_joins/1`.
- Dependency bumps follow `UPGRADE_PLAYBOOK.md` in the xqlite repo,
  including its vendored-suite census re-check and exclusion-reason sweep.

## Project structure

- `lib/xqlite_ecto3.ex` — adapter entry, DDL, rebuild engine, `with_xqlite/3`
- `lib/xqlite_ecto3/driver.ex` — DBConnection callbacks, connect validators
- `lib/xqlite_ecto3/connection.ex` — SQL and DDL generation, constraints
- `data_type.ex`, `query.ex`, `decimal_precision.ex` — types and parameters
- `error.ex`, `fk_diagnostics.ex`, `unique_index_names.ex` — error paths
- `rebuild_verification.ex`, `types/`, `migration.ex`, `uuid_v7.ex`, `url.ex`
- `telemetry.ex`, `telemetry/open_telemetry.ex`, `lib/mix/tasks/test_seq.ex`
- Unprefixed names above are under `lib/xqlite_ecto3/`.

## Pointers

- `ARCHITECTURE.md` — the module map, call paths, state machines, and the
  facts more than one file depends on.
- `RELEASING.md` — the xqlite pin, version bump, tag, publish;
  `UPGRADE_PLAYBOOK.md` in the xqlite repo — dependency bumps; `guides/` —
  the hexdoc guides; `ECTO_INTEGRATION_TAGS.md` — the exclusion mirror.
- The review program's records live outside this repo in
  `~/kod/xqlite-review-ledgers/xqlite_ecto3/`; that nomenclature never
  enters code or public docs. `CLAUDE.md` points here and is never edited.
