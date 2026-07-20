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

---

## Run 3 — 2026-07-20 — third covering pass: B8 + B4 + B7

- Commit at scan: `6e0919c` (after adapter Run 2). Deps compiled at
  xqlite 0.10.0. Single Opus reviewer; direct source audit + live
  timed-operation / round-trip / generated-DDL evidence against bundled
  SQLite 3.53.2. All runtime claims below were produced THIS session
  (scripts under scratchpad, driven via `mix run` and `mix test`).
- Scope: timeout→cancel divergence (B8, flagship), type round-trips as
  properties (B4), migration ergonomics (B7). Contracts read from
  `deps/` source: DBConnection `handle_common_result` (`{:error,…}` keeps
  the connection, `{:disconnect,…}` tears it down — `db_connection.ex`
  1397-1416), `Holder.holder_apply`/`start_deadline` (callback runs in
  the client process; the pool arms a `now+timeout` deadline —
  `holder.ex` 377-457), and Ecto's `check_on_delete!`/`check_on_update!`
  valid shapes (`ecto_sql/lib/ecto/migration.ex` 1589-1612).

### B8 — timeout→cancel divergence (FLAGSHIP; core CLEAN)

Exercised the FULL path through both the direct driver and a real
`DBConnection.start_link` pool. The query-path (`handle_execute`) design
is correct and robust:

- Real-pool evidence: `DBConnection.execute(pool, slow_recursive_cte, [],
  timeout: 150)` → `{:error, %DBConnection.ConnectionError{message:
  "query timed out"}}` in **159 ms** (prompt cancel — the query would run
  ~3500 ms uncancelled), then 3 successive `SELECT` on the same pool all
  returned rows. So (a) race: prompt, no torn state; (c) connection stays
  usable; (d) structured `ConnectionError` Ecto surfaces as a timeout.
- (b) Fresh cancel token per operation — `create_cancel_token()` is
  called inline in `execute_with_cancel/4` and `step_to_completion/4`,
  never stored. Proved the EFFECT: after a cached-path AND a one-shot-path
  timeout, a generous-timeout `SELECT 1` completes (a spent token cannot
  bleed into the next op); the cached slow statement is `pristine_stmt`'d
  and re-runs cleanly.
- (e) Transaction interaction: `handle_begin` → in-txn timeout →
  `txn_state` stays `{:ok, :write}` and `transaction_status: :transaction`
  (cancel aborts the statement, not the transaction) → `handle_rollback`
  `:ok` → connection reusable. A real write updated inside the txn
  (`v→999`) was correctly undone by rollback after the timeout (`v` back
  to `100`). No stray mailbox messages post-cancel.
- Codified as the owed post-cancel state matrix in `cancellation_test.exs`
  (+4 deterministic tests). Two DIVERGENCES found — both bounded, neither
  memory-unsafe/corrupting, both rooted in xqlite/SQLite mechanics the
  adapter layer can't fix alone → BACKLOG (S3):
  - **F-B8-1 (S3).** Operation `:timeout` does NOT interrupt a
    lock-contended write — `busy_timeout` dominates. Two handles on one
    file: handle A holds `BEGIN IMMEDIATE`; handle B (`busy_timeout:
    3000`) INSERTs with a 300 ms cancel token → returned
    `{:error, {:database_busy_or_locked, 5, "database is locked"}}` after
    **3005 ms**, not 300 ms. SQLite's progress handler (which polls the
    token) is not invoked while blocked in the busy-wait, so the cancel
    fires only once stepping resumes. Bounded by `busy_timeout` (adapter
    default 5000 ms) — the promptness guarantee covers CPU-bound execution
    but not lock waits. Could be argued S2 (headline-behaviour divergence);
    filed S3 as bounded + doc-remedy. → BACKLOG + doc.
  - **F-B8-2 (S3).** The streaming path ignores `:timeout`.
    `handle_declare`/`handle_fetch` create no cancel token, and xqlite
    0.10.0 exposes no cancellable `stream_fetch` (only `stream_fetch/2`).
    `Repo.stream(slow_cte, …)` under `run(timeout: 200)` ran the whole CTE
    to completion (**3503 ms**, returned `[[10000000]]`); DBConnection's
    deadline logged a disconnect at 200 ms but could not interrupt the
    blocked dirty NIF. Cross-repo: a fix needs an xqlite
    `stream_fetch_cancellable` first (X2 blast-radius note). → BACKLOG + doc.

### B4 — type round-trips as properties (CLEAN except decimal)

Built dump→store→load matrices (scratchpad `b4_*.exs`) plus a real-repo
deliverable (`types_roundtrip_matrix_test.exs`, +29 assertions).
Verified identity for: `:integer` (i64 min/max/0/neg/nil), `:string`
(empty/unicode/quotes+backslash/newlines/nil), `:binary`
(empty/raw/invalid-utf8/nul), `:boolean` (true/false/nil), `:map`
(string-keyed/empty/float+nil), `{:array, :integer}`, and every custom
type — `Instant` (usec DateTime exact; int-ns loads usec-truncated by
design), `Duration` (int exact), `Types.Array` (`:integer`/`:float`/`:any`
nested), `TimestampTZ` (instant preserved, zone collapses to UTC as
documented), `Types.UUID` (string + 16-byte binary both → 36-char string).
`:float` NUMERIC affinity stores `1.0` as INTEGER `1`, but Ecto's `:float`
loader coerces `load(:float, 1) == {:ok, 1.0}` — round-trips. Atom-keyed
maps come back string-keyed (JSON/Ecto contract) — PINNED, not a bug. One
finding:

- **F-B4-1 (S1-severity, silent data transformation; BACKLOG + doc
  shipped).** A `:decimal` migration column maps to `DECIMAL` (NUMERIC
  affinity). The dumper binds `Decimal.to_string(d, :normal)` as TEXT, and
  NUMERIC affinity coerces it to float64 at write — decimals beyond ~15
  significant digits are SILENTLY truncated. Live:
  `12345678901234567890.12345` → stored REAL `1.2345678901234567e19` →
  loads `1.2345678901234568e19` (`typeof=real`, NOT equal);
  `123456789.123456789` → `…5679` (last digits changed);
  `99999999999999999999` → `1e20`. Common money round-trips exactly
  (`19.99`, `9999999999999.99`, `0.000000000000000001` all `ok`). NO clean
  code fix exists — proven: a TEXT-affinity column preserves precision but
  makes bare range queries LEXICAL (`WHERE price > '100'` returned all of
  `["150.00","99.99","9.99","1000.00","5.00"]` — `"99.99" > "100"` is true
  lexically), trading silent precision-loss for silent wrong-results.
  SQLite has no exact-decimal type; the remedy (keep+document, opt-in TEXT
  storage à la `binary_id_storage`, or loud-reject at encode) is a
  maintainer design call, mirroring F-B3-1/F-B5-1's disposition. The
  pre-existing `types_test.exs` MASKED this by hand-creating a `TEXT`
  decimal column, not the `DECIMAL` a real migration emits. Shipped now:
  a loud "Decimal precision" moduledoc section + corrected the misleading
  `data_type.ex` "(except DECIMAL)" comment + a pin test
  (`types_roundtrip_matrix_test.exs`). → BACKLOG (maintainer ruling owed;
  surface in the announcement-honesty ledger).

### B7 — migration ergonomics (loud-refusal sweep; one silent miscompile)

Generated DDL for the full construct set via
`XqliteEcto3.Connection.execute_ddl/1` (scratchpad `b7_ddl.exs`).
CORRECT SQLite emitted for: FK references with `ON DELETE/ON UPDATE`
(whole-key actions), `:check` constraints, `DROP COLUMN`, partial/unique
indexes, composite PK/FK. Every genuinely-unsupported construct refuses
LOUDLY (`ArgumentError`, clear message): ADD/DROP CONSTRAINT, index
`concurrently`/`using`/`include`/`nulls_distinct`/`only`, keyword
`:options`/`execute`, and `ALTER COLUMN` (`:modify` routes to the rebuild
engine when `support_alter_via_table_rebuild: true`, else a clear raise).
One CONFIRMED bug, fixed RED→green this run:

- **F-B7-1 (S2, CONFIRMED + FIXED).** `reference_on_delete/1` handled only
  the whole-key atoms and fell through to `[]` for everything else — so
  Ecto's valid column-list forms `on_delete: {:nilify, cols}` and
  `{:default, cols}` (validated in Ecto's `check_on_delete!`) SILENTLY
  DROPPED the entire `ON DELETE` clause: `CONSTRAINT … REFERENCES
  "parents"("id")` with no action, discarding the referential behaviour
  the migration asked for. SQLite has no column-list `ON DELETE` syntax
  (the action always covers the whole key), so the correct move is to
  refuse loudly. Fix: a guard clause raising `ArgumentError` pointing at
  `:nilify_all` / `:default_all`. (`on_update` tuples are rejected upstream
  by Ecto's `check_on_update!`, so only `on_delete` was reachable.) Tests:
  `migration_test.exs` "reference ON DELETE" (+4: whole-key controls pass,
  both column-list forms now raise). The shared suite already excludes
  `:on_delete_nilify_column_list`/`:on_delete_default_column_list`.

### Verdict + dryness

- 1 S2 CONFIRMED+FIXED (F-B7-1, RED→green), 1 S1-severity documented +
  filed with a maintainer ruling owed (F-B4-1), 2 S3 → BACKLOG (F-B8-1,
  F-B8-2). B8 flagship CORE CLEAN, B4 CLEAN bar decimal, B7 CLEAN bar the
  one silent miscompile. `mix verify` green at close.
- Dryness: B8/B4/B7 now each have ONE covering pass — NOT DRY, one more
  owed each. A confirmed finding surfaced on B7 and B4, so none can be
  marked dry. Re-wetters recorded in REVIEW_AXES.md.
- Completeness critic: **F-B4-1 needs a maintainer ruling** — doc-only
  may be acceptable (it is a universal SQLite limitation now clearly
  documented and matching the adapter's other documented type caveats),
  or the maintainer may want opt-in TEXT storage / loud-reject; that call
  gates whether it clears the S0–S2 first-publish bar. `stream_data` was
  NOT a dependency (task assumption wrong) — the B4 matrix is exhaustive
  example-based, not generative; a future pass could add the dep and
  fuzz. B8 owes: the pool-deadline-vs-graceful-cancel interaction was
  characterized (pool stays healthy) but not turned into a test (timing);
  the two divergences (F-B8-1/2) are documented not fixed. B7 owes a
  sweep of `modifiers_expr` and ADD-COLUMN-with-REFERENCES runtime
  rejection (both raise/error loudly on inspection, not yet lived).

## Remedy — 2026-07-20 — F-B4-1 loud-reject (maintainer ruling)

Ruling (Dimi, 2026-07-20): LOUD REJECT beyond precision. Keep numeric
storage so ordering/range queries still work, but when a `:decimal` value
would NOT survive the float64 round-trip, refuse it with a structured error
at the boundary rather than silently rounding it.

Implemented:

- `XqliteEcto3.DecimalPrecision.representable?/1` — the guard. Rule:
  `Decimal → float64 (Decimal.to_float) → shortest round-trip string
  (Float.to_string) → Decimal`, compared with the original via
  `Decimal.equal?(normalize, normalize)`. Non-finite (`inf`/`NaN`) and
  out-of-float64-range magnitudes are refused up front (comparing against
  the same DBL_MAX/DBL_MIN bounds `to_float` enforces), so the guard never
  raises — no `rescue`.
- Guard wired into `XqliteEcto3.Query`'s `encode_param/1` (the universal
  parameter-binding boundary — every bound `%Decimal{}` passes through it,
  regardless of the field's declared type). A non-representable value raises
  `XqliteEcto3.DecimalPrecisionError` (dedicated exception carrying the
  offending `:value`, mirroring `UnsupportedTypeError`). Raising is forced
  by the boundary: `DBConnection.Query.encode/3`'s contract returns the
  encoded list — it cannot return `{:error, …}`; DBConnection re-raises the
  exception unchanged (verified: `db_connection.ex` `raised_close` preserves
  `kind/reason/stack`; only `DBConnection.EncodeError` is special-cased).
- Docs flipped from "silently truncated" limitation to loud-reject in the
  `XqliteEcto3` moduledoc + the `DataType` comment.

Precision-guard verification (each value: guard verdict cross-checked
against a REAL SQLite `DECIMAL`-column round-trip via the xqlite NIF — the
two agreed for every value):

| input                          | float64 → shortest str     | guard  | SQLite exact? |
|--------------------------------|----------------------------|--------|---------------|
| `0`                            | `0.0`                      | ACCEPT | yes           |
| `0.1`                          | `0.1`                      | ACCEPT | yes           |
| `99.99` / `-99.99`             | `99.99` / `-99.99`         | ACCEPT | yes           |
| `12345.67`                     | `12345.67`                 | ACCEPT | yes           |
| `100.00`                       | `100.0`                    | ACCEPT | yes           |
| `9999999999999.99` (15 sig)    | `9999999999999.99`         | ACCEPT | yes           |
| `0.000000000000000001` (1e-18) | `1.0e-18`                  | ACCEPT | yes           |
| `1E-30`                        | `1.0e-30`                  | ACCEPT | yes           |
| `3.141592653589793` (16 sig)   | `3.141592653589793`        | ACCEPT | yes           |
| `9007199254740992` (2^53)      | `9.007199254740992e15`     | ACCEPT | yes           |
| `10000000000000000000` (1e19)  | `1.0e19`                   | ACCEPT | yes           |
| `1E308`                        | `1.0e308`                  | ACCEPT | yes           |
| `12345678901234567890` (20d)   | `1.2345678901234567e19`    | REJECT | no (rounds)   |
| `12345678901234567890.12345`   | `1.2345678901234567e19`    | REJECT | no (rounds)   |
| `-12345678901234567890.12345`  | `-1.2345678901234567e19`   | REJECT | no (rounds)   |
| `18446744073709551615` (u64)   | `1.8446744073709552e19`    | REJECT | no (rounds)   |
| `0.12345678901234567` (17 sig) | `0.12345678901234566`      | REJECT | no (rounds)   |
| `1E400` (overflow)             | (bound pre-check)          | REJECT | n/a           |
| `1E-320` (subnormal)           | (bound pre-check)          | REJECT | n/a           |
| `Inf` / `-Inf` / `NaN`         | (non-finite pre-check)     | REJECT | n/a           |

Note the `0.1` trap: a naive bit-exact float comparison would wrongly
reject it; the shortest-round-trip-string comparison accepts it correctly.

RED→green (via real `Repo.insert`, not just the encode helper):
- `types_roundtrip_matrix_test.exs` — the pin flipped from `refute
  Decimal.equal?(loaded, dec)` (which PINNED the silent rounding) to
  `assert_raise XqliteEcto3.DecimalPrecisionError` + `err.value` structured
  assertion; money/normal round-trips stay green. (29 passed)
- `query_encoding_test.exs` — encode boundary refuses beyond-precision,
  large money still encodes. (28 passed)
- `decimal_precision_test.exs` (new) — the full guard table above +
  structured-field assertions. (25 passed)

`mix verify` green (format, compile w-a-e, deps.audit, sobelow, dialyzer,
full seq suite — "All tests passed!"). B4 re-wet by this change (see
REVIEW_AXES.md); the doc-vs-behaviour claim that decimals "silently lose
precision" is now false — they are refused.

---

## Run 4 — 2026-07-20 — first-pass completion: B2 + B9 + B10

- Commit at scan: `5b32d11` (after the F-B4-1 remedy). Deps compiled at
  xqlite 0.10.0. Single Opus reviewer; direct source audit + live
  un-excluded-test RED→green, live telemetry-event capture, and a bench
  compile smoke — every runtime claim below was produced THIS session
  (scripts under scratchpad, driven via `mix test` / `MIX_ENV=test mix run`).
- Scope: exclusion-list audit (B2, prioritized), telemetry (B9),
  benchmarks (B10). This run COMPLETES first-pass coverage of all 12
  adapter axes (B1–B10 + X1–X2).

### B2 — exclusion-list audit (PRIMARY)

Enumerated every `test_helper.exs` exclusion (14 tags + 5 `{:location,…}`
= 19 entries) and the two undocumented-but-unexcluded probe tags. Ran the
suspect entries un-excluded to classify by ground truth, not source
reasoning alone.

**Two-tag status probe (BACKLOG P1 — RESOLVED).** Both tags have NO
exclusion, so they run in the green suite; verified they PASS:
- `:values_list` — `mix test all_test.exs --only values_list` ⇒ **5 passed**
  (incl. `delete_all`, which the DELETE+JOIN rewrite now handles).
- `:transaction_checkout_raises` — `--only transaction_checkout_raises`
  ⇒ **1 passed**.
  `ECTO_INTEGRATION_TAGS.md`'s rows (`:values_list` "partial / delete_all
  fails"; `:transaction_checkout_raises` "needs adapter work") are STALE —
  both quietly pass. README "suites run green" holds. Rows corrected +
  header refreshed (SQLite 3.51.3→3.53.2, 15/18→16/18 files) — closes P1
  and the drift half of BACKLOG G2.

**Exclusion disposition (ran each suspect un-excluded — all FAILED as a
legit limitation, confirming the exclusion; two carried a defect behind
them):**

| exclusion | un-excluded result | class | note |
|---|---|---|---|
| `:insert_cell_wise_defaults` | repo.exs:864 FAIL | legit | multi-row VALUES pads omitted cols with NULL, not the schema default — SQLite can't per-row DEFAULT |
| `:map_type_schemaless` | type.exs:468 FAIL | legit | schemaless read returns raw JSON TEXT (no decoder) |
| alter.exs:44 | FAIL | legit | schemaless read of NUMERIC returns INTEGER, not `%Decimal{}` |
| type.exs:362 | FAIL | legit + **masked bug** | documented boolean-typing limit is real (line 384), but the test failed EARLIER at line 383 on a JSON key with embedded quotes → uncovered F-B2-1 (below) |
| logging.exs:74 | FAIL | legit + **wrong rationale** | see below |
| array_type, transaction_isolation, like_match_blob, lock_for_migrations, prefix, alter_primary_key, alter_foreign_key, on_delete_*_column_list, bitstring_type, duration_type, microsecond_precision, transaction.exs:161, migration.exs:664 | (reasoned from source) | legit | genuine SQLite/architecture limits, rationales accurate |

Tally: **all 19 exclusions are legit-limitation** (each stays; every
un-excluded one failed exactly as its rationale claims). Of those, ONE
(type.exs:362) additionally masked a fixable defect → **masked-bug-fixed
1** (F-B2-1; the exclusion stays, rationale now accurate) and ONE
(logging.exs:74) carried a **wrong rationale** (corrected).
**stale-reenabled 0** — no *exclusion* was stale; the two stale items were
*doc rows* (`:values_list`, `:transaction_checkout_raises`), now fixed. No
exclusion hid a crash.

- **logging.exs:74 "cast params" — rationale was FACTUALLY WRONG (fixed).**
  Documented as "telemetry handler uses Process.put which doesn't cross the
  sandbox proxy boundary." Un-excluded and observed: the handler DID fire
  (the in-handler assertion at line 86 ran and failed). Real cause: the
  adapter stores UUIDs as TEXT by default (`binary_id_storage: :string`),
  so a `Ecto.UUID` field binds the 36-char string; the test asserts
  `metadata.params == Ecto.UUID.dump!/1` (the 16-byte binary, Postgres's
  storage). Legit-by-design exclusion, but the rationale mislead — rewrote
  it to the true reason. `metadata.params` faithfully reports the bound
  string, so this is honest telemetry, not a bug.

- **F-B2-1 (S2, CONFIRMED + FIXED — RED→green).** The compile-time
  `json_extract_path` builder emitted the BARE path `$.<key>` instead of
  the quoted-label form `$."<key>"`. SQLite treats `.` and `"` as
  structural in a bare label, so a JSON object key containing a **dot**
  (common: `"foo.bar"`, `"user.email"`), a **double quote**, or a
  **backslash** silently extracted as `nil` even though the key exists —
  silent wrong results (same class as F-B6-1/F-B6-3). Proven live: the
  adapter emitted `json_extract(j0."meta", '$.foo.bar')` for
  `d.meta["foo.bar"]` ⇒ SQLite reads two nested steps ⇒ `nil`; the correct
  `$."foo.bar"` ⇒ the value. The escaping helper (`escape_json_key/1`,
  backslash+quote) was already right — only the outer `"…"` wrapper was
  missing, and the runtime *expression* branch already used it (`.\"` ||
  seg || `\"`), so the literal branches were simply inconsistent. Fix:
  wrap the escaped key in `"…"` at both literal sites (`expr/3`
  compile-time path + `dynamic_json_path/3` literal segment). Verified a
  strict improvement across key shapes (dot/quote/backslash all extract;
  plain/dotted/nested/absent unchanged). After the fix the shared
  type.exs:362 test fails ONLY at line 384 (the documented boolean-typing
  limit), so that exclusion's rationale is now accurate too. Tests:
  `json_extract_path_test.exs` (+5, RED→green: dotted, double-quote,
  backslash, nested-dotted, WHERE-position).

### B9 — telemetry (S2 contract mismatch fixed + doc alignment)

Drove EVERY documented event through the driver under the telemetry-ON
build (test env) and captured the actual measurements + metadata keys
(`MIX_ENV=test mix run`). All documented events fire. Statement-cache
hit/miss/evicted verified (`%{monotonic_time, cached_count}` / `%{sql}` —
matches docs). OTel mapping (`OpenTelemetry.attributes/3`) audited:
correct + traceable (reads sql/query/database/result_class/error_reason);
unaffected by the fixes. Observed-vs-documented mismatches, all resolved:

- **disconnect dropped `reason` (CODE fix, RED→green).** Docs promise
  `%{conn, reason}`; the callback `disconnect(_err, state)` ignored `_err`
  and emitted only `%{conn}`. Now binds `err` and emits `reason: err` (the
  arg was right there). Test: `telemetry_test.exs` asserts
  `metadata.reason == :normal`.
- **moduledoc over-promised keys that never fire (DOC fix to match the
  observed emission — authoritative = what fires; changing emitted shapes
  risks existing subscribers):**
  - connect metadata listed `repo` — never emitted (start_md is
    `%{database}`).
  - `num_rows (on :stop)` listed as a MEASUREMENT for
    execute/declare/fetch/deallocate — impossible via `:telemetry.span`
    (stop measurements are fixed to `monotonic_time`+`duration`); it is
    emitted nowhere.
  - declare metadata listed `cursor` (declare emits `query`+`sql`, no
    cursor); fetch/deallocate listed `query` (they emit only `cursor`) —
    split into two accurate groups.
  - `mode (begin only)` — `mode` is on begin/commit/rollback alike.
  - `sql` (emitted, useful) was undocumented — added.
  Tests pin the corrected cursor contract (`fetch_md.cursor`,
  `refute Map.has_key?(fetch_md, :query)`).
- **Both-configs-in-CI (BACKLOG [B9] probe — CONFIRMED gap).** No CI lane
  flips `:telemetry_enabled`; `config/test.exs` pins it ON, so CI never
  builds/tests the telemetry-OFF path (the production default). Verified
  the OFF path compiles clean locally (`MIX_ENV=dev mix compile --force
  --warnings-as-errors` ⇒ exit 0, my `err` binding is used by the no-op
  macro). → BACKLOG (add a CI lane or a compile smoke with the flag off).

### B10 — benchmarks (exist; methodology honest; DO NOT RUN — finding)

`bench/` is a standalone benchee project vs `ecto_sqlite3`. Methodology is
HONEST: identical schema + pinned-identical pragmas (WAL, synchronous
NORMAL, 64 MB cache, 5 s busy timeout, autocheckpoint 1000), file-backed,
`pool_size: 1`, logging off, both SQLite versions printed
(disclosed-not-equalized), cancellation labeled a capability demo (not a
comparison), ledger-first (no public figures committed), and scenarios
cover writes AND reads (single/bulk insert, upsert, point/range/join/
aggregate/stream). BUT:

- **F-B10-1 (S3, BACKLOG). The bench does not compile/run.** `bench/mix.exs`
  pins `ecto_sql ~> 3.13.0` (stale lock 3.13.5) while the adapter now
  requires `~> 3.14` and uses `Ecto.Migration.Table.:modifiers` (a 3.14
  struct field). `MIX_ENV=prod mix compile` in `bench/` fails at
  `connection.ex:2112` — "unknown key :modifiers for struct
  Ecto.Migration.Table." The mix.exs comment blaming ecto_sql 3.14's
  `insert/8` is stale (the adapter migrated to `~> 3.14`). Any perf number
  is currently UNREPRODUCIBLE from a clean checkout. Fix = bump the bench
  to `ecto_sql ~> 3.14` + `ecto_sqlite3 ~> 0.24` and refresh the lock
  (needs Hex). → BACKLOG.

### Verdict + dryness

- 1 S2 CONFIRMED+FIXED (F-B2-1, RED→green), 1 S2-class observability
  contract mismatch FIXED (B9: disconnect `reason` code fix + moduledoc
  aligned to observed emission), 1 rationale corrected (logging.exs:74),
  P1 resolved + doc rows/header reconciled, 1 S3 → BACKLOG (F-B10-1), 1 CI
  gap confirmed → BACKLOG ([B9]). `mix verify` green at close.
- Dryness: B2/B9/B10 now each have ONE covering pass — NOT DRY, one more
  owed each. Confirmed findings surfaced on B2 and B9, so none can be
  marked dry. Re-wetters recorded in REVIEW_AXES.md.
- **Completeness critic — first-pass coverage of ALL 12 adapter axes is
  COMPLETE**: X1/B1/X2 (Run 1), B6/B5/B3 (Run 2), B8/B4/B7 (Run 3),
  B2/B9/B10 (Run 4). Every axis has ≥1 covering pass; none is DRY (each
  owes a second pass per the constitution). Owed depth for the covered
  three: B2 could add reconnect-time exclusion re-checks + a
  `dynamic_json_path` expression-branch double-quote characterization; B9
  could add num_rows/`repo` enrichment (feature, not correctness) and the
  telemetry-OFF CI lane; B10 needs the dep bump before any figure is
  published.
