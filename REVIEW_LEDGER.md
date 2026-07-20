# Review ledger — xqlite_ecto3 (append-only)

One entry per fleet run: date, commit, scope, fleet composition,
findings with verdicts + severity + fix commit or backlog ref,
per-axis dryness state. Nothing found is ever silently dropped.

---

## Run 0 — 2026-07-17 — Phase-1 recon (wave 1)

- Commit at scan: `f419016`. Fleet: shared with xqlite's Run 0
  (4 sonnet read-only agents + orchestrator synthesis); raw
  transcripts + distillates in `~/kod/fleet_review_staging/recon/`.
- Outcomes:
  - **21 accidental-public SQL helpers** in
    `XqliteEcto3.Connection` (zero docs/specs/external callers per
    agent rg) → BACKLOG G1, pre-publish gate. Spot-check callers
    before converting.
  - **Exclusion-ledger drift**: ECTO_INTEGRATION_TAGS.md carries an
    orphaned tag, a stale-contradicted row (`:foreign_key_constraint`
    — rich FK diagnostics solved it), two statically-unverifiable
    rows (`:transaction_checkout_raises`, `:values_list`) and stale
    header numbers → BACKLOG G2 + the two-tag probe (B2).
  - erl_crash.dump: dev-noise (May 2, init/stdio shutdown race),
    closed.
  - CI floor gap (Elixir ~> 1.15 claimed, 1.17 tested) → BACKLOG G3.
  - CLAUDE.md absent; bootstrap content inventoried → BACKLOG G5.
  - 23 + 15 failure classes harvested and mapped onto B1–B10/X1–X2
    seed probes (distillates hold the map).
- Post-run action same day: xqlite dep lock bumped 0.8.0 → 0.9.0
  (hex-mode; kills the 1.20 dep-compile warnings; first consumer
  validation of the published 0.9.0 precompiled artifacts).
- Dryness: all axes WET (no adversarial pass has run yet).

---

## Run 1 — 2026-07-20 — first covering pass: X1 + B1 + X2

- Commit at scan: `6d571e5` (adapter now requires xqlite `~> 0.10`,
  3-tuple error shapes adopted). Deps compiled at xqlite 0.10.0.
  Single Opus reviewer; direct source audit, no fleet.
- Scope: the three contract axes. Authority read from `deps/` source
  (never memory) and `../xqlite/lib/xqlite.ex` `error_reason/0` @0.10.0.

### X1 — API/error-shape contract (PRIMARY; the class that broke CI)

Audited the ENTIRE `error_reason/0` union (48 shapes: 9 bare atoms +
39 tuple variants) against `XqliteEcto3.Error.wrap/1`. Every HOT-PATH
shape is correctly
classified — the 0.10.0 3-tuple migration (`a5b94e5` + `6d571e5`)
covered busy/readonly/schema/auth/utf8/constraint/sql_input/
sqlite_failure. Constraint→Ecto translation (`to_constraints/2`)
verified against `unique`/`primary_key`/`foreign_key`/`check`/
`not_null` — all map to valid `Keyword.t()`. Findings:

- **F-X1-1 (S3, FIXED this run — RED→green).** `wrap/1`'s
  `:sqlite_failure` clause guarded `when is_binary(msg)`, but
  xqlite's published type is `{:sqlite_failure, int, int, String.t()
  | nil}` and the adapter's own `Error.SqliteFailure` struct types
  `message: String.t() | nil`. A nil message dropped the shape — and
  its primary+extended result codes — to the `inspect` catch-all
  (`type: nil`), i.e. the one error whose entire job is to preserve
  codes lost them. A direct sibling of the morning CI break
  (2-vs-3-tuple). Latent today (all xqlite construction sites pass
  `Some(_)`; re-verified in `error.rs`), so S3 not S2 — fixed anyway
  because trivial + squarely in-axis. Fix: guard `is_binary or is_nil`
  + `sqlite_failure_message/1`. The Elixir 1.20 type checker itself
  flagged the pre-fix disjointness (`e.type == :sqlite_failure`
  "always false"). Test: `error_wrap_test.exs`.
- **F-X1-2 (S3, BACKLOG).** The generic `{tag, msg}` clause requires
  `is_binary(msg)`, so ~14 documented union shapes whose payload is a
  map/int/atom/tuple fall to the `inspect` catch-all and lose their
  `type` tag (e.g. `{:integral_value_out_of_range, i, i}`,
  `{:cannot_convert_to_sqlite_value, s, s}`,
  `{:invalid_parameter_count, map}`, `{:from_sql_conversion_failure,
  i, atom, s}`, `{:cannot_open_database, s, i, s}`). Still valid
  exceptions (message via inspect), never misclassified — only
  unclassified. Mostly cold/exotic; a couple reachable via bignum
  insert / unsupported param. Completeness, not correctness. → BACKLOG.

### B1 — behaviour conformance from source

Enumerated every behaviour the adapter carries: `Ecto.Adapter` (+
`__before_compile__` override, `loaders/2`, `dumpers/2`),
`.Schema` (`autogenerate/1`), `.Queryable`, `.Transaction`,
`.Storage` (3 cbs), `.Structure` (3 cbs), `.Migration` (3 cbs), and
the 17 `Ecto.Adapters.SQL.Connection` callbacks. All present with
correct arity — largely *guaranteed* by the clean warnings-as-errors
compile (a bad `@impl`/arity would already be a build error).
Semantic checks on the OVERRIDES: `execute_ddl/3` short-circuits
return `{:ok, []}` (matches `{:ok, [log_tuples]}`); `storage_*`,
`structure_dump/2`, `structure_load/2`, `loaders/dumpers`,
`autogenerate/1`, `to_constraints/2`, `ddl_logs/1` (`[]`),
`table_exists_query/1` (`{iodata, [term]}`), `explain_query/4`,
`lock_for_migrations/3` (no-op is CORRECT for single-writer SQLite) —
all conformant. Finding:

- **B1-1 (S3, BACKLOG).** `dump_cmd/3` is a required Structure
  callback (no `@optional_callbacks` in the behaviour) yet the adapter
  `raise`s "not supported". `mix ecto.dump` calls `structure_dump/2`,
  NOT `dump_cmd/3` (verified in `deps/ecto_sql/lib/mix/tasks/
  ecto.dump.ex`), and no mix task invokes `dump_cmd` — so it's an
  unreachable required callback; the raise is a deliberate redirect.
  Informational; consider a structured `{:error, ...}` return or a
  moduledoc note. VERDICT: B1 CLEAN (this is a nit).
- Minor: `storage_up/1` does `{:ok, conn} = XqliteNIF.open(db)` —
  MatchErrors on open failure instead of returning `{:error, term}`
  (contract permits it). Near-impossible path (dir just mkdir_p!'d).
  Folded into BACKLOG B1-1 note.

### X2 — cross-repo blast radius (the durable map)

Enumerated the FULL xqlite consumption surface (36 distinct
`XqliteNIF.*` + 5 `Xqlite.*` calls). While mapping the changes/
num_rows contract, found a CONFIRMED reachable bug:

- **F-X2-1 (S2, CONFIRMED + FIXED — RED→green).** The statement-cache
  execution path (`Driver.finish_cached_stmt`) computed `changes = if
  columns == [], do: conn_changes(conn), else: 0` — the exact
  empty-columns heuristic xqlite's `core_query_with_changes` comment
  calls "wrong twice." `sqlite3_changes()` is sticky, so a columnless
  NON-DML statement (DDL, `PRAGMA x = y`) run through the cache after
  a DML leaked the prior DML's change count as `num_rows`. The
  one-shot path (`query_with_changes`, used when
  `statement_cache_size: 0`) does it right, so the two paths DIVERGED
  — path-dependent wrong `num_rows`, contradicting the documented
  `total_changes`-delta discipline. Empirically reproduced (CREATE
  INDEX / PRAGMA after UPDATE → `num_rows=2`, should be 0; one-shot →
  0). Fix: thread `total_changes`-before through the cached path and
  gate on the delta, mirroring xqlite. `changes` is only consumed by
  handle_execute's `columns: []` branch, so RETURNING/SELECT
  unaffected. Tests: `driver_statement_cache_test.exs` (+3).

**Blast-radius table** — adapter sites that break SILENTLY (wrong
result/behavior, NOT a compile error) if xqlite changes a shape.
Consult before any xqlite public-surface change:

| xqlite call | shape adapter relies on | site | break mode if xqlite changes it |
|---|---|---|---|
| `query_with_changes[_cancellable]` | `{:ok, %{columns, rows, num_rows, changes}}`; `columns:[]`⇒DML | driver `handle_execute`/`execute_with_cancel` | **SILENT** — drop/rename `:changes` or `:columns` ⇒ DML counts drift (this axis's F-X2-1 class) |
| `stmt_multi_step_cancellable` | `{:ok, %{rows, done: bool}}` | driver `collect_rows` | **SILENT** — `:done` semantics change ⇒ wrong batching / early halt |
| `stmt_prepare` | `{:error, :multiple_statements}` / `{:error, {:cannot_execute,_}}` sentinels | driver `prepare_and_cache` | **SILENT** — rename ⇒ fallback stops firing; statements hard-error instead of one-shot |
| `stream_fetch` | `{:ok, %{rows}}` \| `:done` | driver `handle_fetch` | SEMI — `:done` atom change ⇒ crash/loop (loud-ish) |
| `transaction_status` vs `txn_state` | `{:ok, bool}` vs `{:ok, :none\|:read\|:write}` — DIFFERENT shapes | driver checkout/status vs `XqliteEcto3.txn_state` | SEMI — swapping them ⇒ CaseClauseError |
| `query` | `{:ok, %{rows}}` | fk_diagnostics, conditional-column DDL | LOUD — MatchError if `:rows` renamed |
| `changes` / `total_changes` | `{:ok, non_neg_integer}` | driver changes helpers | LOUD-ish — falls to `0` on error |
| `begin/commit/rollback/savepoint/release_savepoint/rollback_to_savepoint` | `:ok \| {:error, reason}` | driver txn callbacks | LOUD — `:ok` match fails ⇒ disconnect/crash |
| `set_pragma` / `open` / `open_readonly` | `{:ok, _} \| {:error, _}` | driver connect | LOUD — `with` chain aborts |
| all error reasons | `error_reason/0` union → `Error.wrap/1` | everywhere | see X1 (silent classification loss on unhandled shapes) |

### Verdict + dryness

- 1 S2 CONFIRMED+FIXED (F-X2-1), 1 S3 fixed opportunistically
  (F-X1-1), 2 S3 → BACKLOG (F-X1-2, B1-1). B1 CLEAN, X1 hot-path
  CLEAN. `mix verify` green at close.
- Dryness: X1/B1/X2 now each have ONE covering pass — NOT DRY, one
  more owed each (per constitution). A confirmed finding surfaced
  (F-X2-1), so none can be marked dry this run. Re-wetters recorded
  in REVIEW_AXES.md.
- Completeness critic: the wrap/1 tail (F-X1-2) was filed not fixed —
  a second X1 pass should decide whether to close it or ratify the
  inspect-fallback as intended for exotic shapes. B7 loud-refusal
  sweep (migration DDL) and B-axis semantic depth remain untouched
  (out of scope this run). No runtime perf claims made.

---

## Run 2 — 2026-07-20 — second covering pass: B6 + B5 + B3

- Commit at scan: `835f6e5` (after adapter Run 1). Deps compiled at
  xqlite 0.10.0. Single Opus reviewer; direct source audit + live
  generated-SQL inspection and execution against bundled SQLite 3.53.2.
- Scope: query translation (B6, prioritized), constraint mapping (B5),
  sandbox/pooling under a single writer (B3). Callback contracts read
  from `deps/` source: `Ecto.Adapters.SQL.Connection` overrides,
  `to_constraints/2` (`Keyword.t()`), and `constraints_to_errors/3` in
  `deps/ecto/lib/ecto/repo/schema.ex` (the matcher this feeds).

### B6 — query translation (PRIMARY; richest surface)

Audited every SQL-generation override against the stock behaviour and,
crucially, built + ran real queries to inspect the emitted SQL. Three
CONFIRMED bugs, all fixed RED→green this run:

- **F-B6-1 (S1, CONFIRMED + FIXED).** `escape_string/1` doubled
  backslashes. SQLite string literals escape ONLY `'` (by doubling);
  backslash is ordinary. Probe: `SELECT 'a\b', length('a\b')` ⇒
  `["a\b", 3]` but `'a\\b'` ⇒ `["a\\b", 4]` — different values. The
  adapter emitted `WHERE (p0."title" = 'a\\b')` for a literal `"a\b"`;
  end-to-end, a row stored (via param) as `a\b` was NOT found by the
  inlined literal (`rows: []`, should be `[[1]]`) — silent wrong
  results. Reachable via any inlined string literal in WHERE/LIKE and
  via DDL string defaults. Fix: escape only `'`; `escape_json_key/1`
  now does its own backslash+quote escaping (JSON-path output verified
  byte-identical: `'$.a\"b\\c'` before and after). Tests: literal
  round-trip in `query_features_test.exs`, string default in
  `connection_test.exs`.
- **F-B6-2 (S2, CONFIRMED + FIXED).** Offset without limit emitted a
  bare `OFFSET n`. SQLite's grammar has no bare OFFSET (`SELECT x FROM t
  OFFSET 1` ⇒ `near "OFFSET": syntax error`). `from(x, offset: 2)` (a
  legitimate paginating query, valid in Postgres/MySQL) failed to
  compile. Fix: `limit/2` emits `LIMIT -1` when limit is nil and offset
  present ⇒ `... LIMIT -1 OFFSET 1` (verified: returns the correct tail
  rows). The pre-existing test `"offset without limit requires LIMIT in
  SQLite"` masked the bug with `limit: 999`; rewritten to the genuine
  case. Also fixes DISTINCT ON + offset-no-limit (shared limit/offset
  path). Test: `query_features_test.exs`.
- **F-B6-3 (S2, CONFIRMED + FIXED).** `quote_entity/1` did not escape an
  embedded `"` in identifiers. Probe: `identifier(^~s|x" FROM
  secrets;--|)` in a fragment generated `SELECT "x" FROM secrets;--"
  FROM "posts" AS p0` — a live SQL-injection through Ecto's public
  `identifier/1` API (and broken SQL for any identifier containing `"`).
  The same repo's `FkDiagnostics.quote_ident/1` already doubles quotes,
  proving intent. Fix: double `"` → `""` in `quote_entity/1`; the evil
  input now collapses to one inert identifier `"x"" FROM secrets;--"`.
  Test: `connection_test.exs`.

Also inspected and found CORRECT: single-quote escaping (`O''Brien`),
`?N` positional placeholders, `$N::TYPE` values-list grammar, empty
`IN []` ⇒ `0`, DELETE+JOIN rewrite guards, on_conflict/upsert
disambiguator, RETURNING, subquery/CTE parent-alias threading, the
`INSERT ... SELECT ... ON CONFLICT` trivial-WHERE workaround.

### B5 — constraint mapping

Triggered every constraint subtype live and inspected the wrapped
`Error.Constraint` + `to_constraints/2` output. UNIQUE ⇒ `[unique:
"users_email_index"]`, composite ⇒ `[unique:
"users_tenant_id_email_index"]`, PRIMARY KEY ⇒ `[unique:
"users_id_index"]`, CHECK (named) ⇒ `[check: name]` / (unnamed) ⇒
`[check: "<expr>"]` (SQLite reports the expression — best available),
NOT NULL ⇒ `[not_null: "users.email"]`, named unique index ⇒ the index
name. All derive Ecto's default `<table>_<col>_index` convention, so
`unique_constraint/3` matches out of the box. One finding:

- **F-B5-1 (S3, BACKLOG).** FK violation without a rich-diagnostics
  payload (default `rich_fk_diagnostics: false`, or a diagnosis that
  finds no rows) ⇒ `[foreign_key: nil]`. `nil` is not a valid
  constraint name: with `match: :exact` it never matches (raises
  `Ecto.ConstraintError` with a nil name), and with `match:
  :suffix`/`:prefix` Ecto's `constraints_to_errors/3` calls
  `String.ends_with?(nil, cc)` and crashes with `FunctionClauseError`
  (verified `String.ends_with?(nil, "x")` raises). Latent, narrow
  trigger. → BACKLOG.

### B3 — sandbox + pooling under a single writer

Resolved the standing `:memory:`-guard probe and relied on the passing
async suite for baseline sandbox correctness.

- **F-B3-1 (S3, BACKLOG).** No guard against private-`:memory:` + a
  multi-connection pool. `database: ":memory:"` with no `pool_size`
  starts cleanly at Ecto's default pool of 10, but each private
  in-memory connection is a separate database. Probe: 10 reads of a
  just-inserted row ⇒ 9× `{:error, :no_such_table}` + 1× `{:ok, []}` +
  0× the row. Default-reachable, wholly broken repo — but fails loudly
  and the remedy (raise / force pool 1 / document shared-cache) is a
  maintainer design call. `ecto_sqlite3` raises. Sub-note: the
  advertised `@default_opts pool_size: 5` is dead (Ecto sizes the pool
  before `child_spec` merges defaults; default 10 wins). → BACKLOG.
- Baseline sandbox checkout/checkin/rollback isolation and concurrent
  checkouts are exercised by the entire `async: true` AdapterCase suite
  (manual mode, per-test checkout) — passing. Failed begin/commit/
  rollback all return `{:disconnect, …}`, so a wedged transaction is
  torn down + reconnected, not reused (conservative, correct). The
  hard single-writer concurrent-transaction limit is known + excluded
  (transaction.exs:161). Storm probes (connect-time PRAGMA storm, busy
  storms) NOT run — owed.

### Verdict + dryness

- 1 S1 + 2 S2 CONFIRMED+FIXED (F-B6-1/2/3, RED→green), 2 S3 → BACKLOG
  (F-B5-1, F-B3-1). B6 had the richest surface and yielded all three
  fixed bugs. `mix verify` green at close.
- Dryness: B6/B5/B3 now each have ONE covering pass — NOT DRY, one more
  owed each. Confirmed findings surfaced on every axis, so none can be
  marked dry. Re-wetters recorded in REVIEW_AXES.md.
- Completeness critic: B6 fixes are correctness/injection wins but the
  audit was breadth-first over overrides — a second B6 pass should go
  deep on NULL-in-join/aggregate/DISTINCT semantics, NOCASE/LIKE ASCII
  limits, and window-frame edge cases (axis seed probes not yet pinned).
  B3 storm probes and the sandbox shared-mode-across-processes allowance
  remain unrun. F-B5-1 and F-B3-1 were filed not fixed — both are
  genuine maintainer design calls (return shape / guard shape), not
  oversights.
