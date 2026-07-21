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

---

## Run 5 — 2026-07-20 — dryness pass 1: X1 + B1 + X2

- Commit at scan: `5a411ee` (after adapter Run 4). Deps compiled at xqlite
  0.10.0 (`mix.lock` pin verified). Single Opus reviewer; direct `deps/`
  source audit + live SQL-shape / re-raise / surface-delta evidence, every
  runtime claim produced THIS session (scripts under scratchpad, driven via
  `mix run` / `mix test`).
- Scope: the SECOND covering pass over the three contract axes. Adversarial
  priority on the churn `6d571e5..5a411ee` (the Runs 1–4 fixes) and the
  FORWARD xqlite delta `v0.10.0..main` (7 commits: four maintainer-ruling
  implementations + S3 fix pass round 3 + doc). Authority read from
  `deps/xqlite/lib/xqlite.ex` `error_reason/0` @0.10.0 AS COMPILED,
  `deps/db_connection` source, and `../xqlite` at HEAD for the forward delta.

### X1 — API/error-shape contract (PRIMARY)

Re-audited the ENTIRE `error_reason/0` union (48 shapes: 7 bare atoms + 41
tuple variants) @0.10.0 against `wrap/1` + `to_constraints/2`. Standing
surface CLEAN — every hot-path shape classified, the 0.10.0 3-tuple migration
holds. Classification map re-derived: 7 bare atoms → atom clause; 8 tuple
variants → dedicated clauses (constraint/sqlite_failure/sql_input/busy-set
3-tuple/utf8); 17 binary-payload 2-tuples → generic `{tag, msg}` clause; and
the **14 non-binary-payload shapes** (`:cannot_convert_to_sqlite_value`,
`:cannot_execute_pragma`, `:cannot_open_database`, `:from_sql_conversion_failure`,
`:integral_value_out_of_range`, `:invalid_authorizer_action`,
`:invalid_column_index`, `:invalid_column_type`, `:invalid_on_error`,
`:invalid_open_option`, `:invalid_pages_per_step`, `:invalid_parameter_count`,
`:schema_parsing_error`, `:unsupported_data_type`) that fell to the inspect
catch-all with `type: nil` (F-X1-2). Findings / decisions:

- **F-X1-2 (S3, backlog) — DECIDED = FIXED (not ratified); RED→green.** The
  house doctrine is CLAUDE.md-level: "errors must always carry the most
  specific, structured information possible… no swallowing details into
  generic wrappers… callers need maximum diagnostic information." Dropping a
  KNOWN tag that lives right in `error_reason/0` to `type: nil` is exactly
  that anti-pattern, and the reachable members surface at real Ecto
  boundaries (`:cannot_open_database` at connect, `:integral_value_out_of_range`
  on a bignum insert, `:cannot_execute_pragma` at connect). Ratification would
  save a re-wet but lose machine-addressable classification — the doctrine
  wins. Fix: three arity-bounded tag-preserving clauses (`{tag, _}` /
  `{tag, _, _}` / `{tag, _, _, _}` with `is_atom(tag)`) inserted AFTER the
  binary-payload `{tag, msg}` clause and BEFORE the atom/inspect fallbacks —
  `type` = the tag, full shape preserved in the message via `inspect`,
  `details` nil (no dedicated struct; consistent with the tag-only-error
  convention). Bounded to arities 2–4 (the union's max) DELIBERATELY: a
  genuinely-unknown 6-tuple still inspects with `type: nil` (the existing
  catch-all test at `error_wrap_test.exs` holds). RED confirmed first (4 new
  tests failed, and the Elixir 1.20 type checker flagged the
  `dynamic(nil) == :cannot_open_database` disjointness — corroborating the
  drop); GREEN after the fix. Tests: `error_wrap_test.exs` (+4 —
  map-payload / atom-payload 2-tuple, int-payload 3-tuple, 4-tuple; each a
  structured `.type` assertion, not message text). `lib/xqlite_ecto3/error.ex`.

- **DecimalPrecisionError raise re-verified INDEPENDENTLY from db_connection
  source (not the Remedy ledger's word).** A raise out of
  `DBConnection.Query.encode/3` is caught by `encode/5`
  (`deps/db_connection/lib/db_connection.ex:1457-1468`, `catch kind, reason`)
  → `raised_close/7` (`:1570-1574`) runs `run_close` which calls
  `cleanup(conn, :handle_close, …)` — it closes the PREPARED QUERY, **not the
  connection** (no `disconnect` on this path) → returns the 4-tuple
  `{:error, %Err{}, stack, meter}` → `log/4` (`:1698`) → `log_result/1`
  (`:1732`) `:erlang.raise(:error, reason, stack)` — the SAME struct + original
  stacktrace, UNCHANGED. Only `DBConnection.EncodeError` is special-cased
  (`maybe_encode/4:1474` → re-prepare); `DecimalPrecisionError` is not, so both
  encode entry points re-raise it unchanged and keep the connection. RUNTIME
  confirmed end-to-end (`decimal_reraise_probe.exs`, minimal pool_size:1 repo +
  a `[:xqlite_ecto3, :disconnect]` watcher): `Repo.insert` of
  `Decimal.new("12345678901234567890.12345")` raised
  `XqliteEcto3.DecimalPrecisionError` with `.value` == the offending Decimal,
  `disconnect_fired = false`, and a subsequent `19.99` insert + `get!`
  round-trip succeeded on the same pool.

- **FORWARD blast check (xqlite v0.10.0..main) — CLEAN; the CI-break class did
  NOT recur.** `error_reason/0` changed **ADDITIVELY only**:
  +`:extension_loading_disabled` +`:invalid_conflict_strategy` (two BARE atoms).
  Both are classified correctly by `wrap/1`'s bare-atom clause (tag preserved),
  and both are UNREACHABLE from the adapter (no `load_extension` /
  `changeset_apply` in the consumption surface). `native/…/error.rs` has ZERO
  changes in the range. `nif.rs` = exactly 20 `#[rustler::nif]` →
  `#[rustler::nif(schedule = "DirtyIo")]` attribute flips (bodies byte-identical
  — scheduler-thread routing, invisible to the adapter). The one non-cosmetic
  Rust result-path change (`XqliteQueryResult`'s `columns` now encoded via the
  fallible `encode_column_names`/`encode_text` for graceful OOM, F-A12-3) keeps
  a **byte-identical success shape** (same `atoms::columns()` key, same list of
  binaries; only the OOM path degrades panic→`{:internal_encoding_error, …}`,
  an atom already in the 0.10.0 union). No `error_reason/0` tuple-arity,
  result-map key, or sentinel atom moved.

### B1 — behaviour conformance from source

The churn re-wet B1 (SQL.Connection override internals + DBConnection-facing
behavior). Re-verified the churn-touched overrides' SEMANTIC return shapes LIVE
(arity/`@impl` is compile-guaranteed by w-a-e — the value-add is shape):

- **Direct-call SQL census (`b1_sql_probe.exs`, no repo) 6/6 PASS:** `limit/2`
  `%{limit: nil, offset: nil}` → `[]` and `%{limit: nil, offset: present}` →
  `" LIMIT -1"` (valid iodata; `%Ecto.Query{}` always carries both fields);
  `quote_entity/1` doubles an embedded `"` in BOTH a table and a column
  identifier (`ev"il`/`a"b` → `"ev""il"`/`"a""b"`); `escape_string/1` keeps a
  backslash single (`C:\x` → `'C:\x'`, no `\\`); `reference_on_delete/1`
  `{:nilify, cols}` raises `ArgumentError` (loud refusal) while `:nilify_all`
  still emits `ON DELETE SET NULL`.
- **Churn-cluster test re-runs 171/171 PASS** (json_extract quoted-label,
  disconnect `reason`, cached-stmt `changes`-delta, decimal encode-raise, types
  round-trip, migration, query features).
- **disconnect/2**: returns `:ok`, now binds `err` and emits
  `%{conn, reason: err}` — conformant DBConnection callback shape (return `:ok`).
- **encode-raise path**: connection KEPT + exception UNCHANGED, confirmed from
  db_connection source (cited under X1 above) and runtime.
- **finish_cached_stmt**: returns `{:ok, %{columns, rows, num_rows, changes}}`
  with `changes` gated on the `total_changes` delta — verified via
  `driver_statement_cache_test.exs`.

Zero new findings. B1-1 (S3, `dump_cmd/3` unreachable-raise nit) UNCHANGED in
backlog.

### X2 — cross-repo blast radius

Re-enumerated the xqlite consumption surface at HEAD (reproducible `rg` over all
`lib/**/*.ex`, `XqliteNIF|NIF` unified + deduped): **38 XqliteNIF-family + 7
Xqlite.\*** distinct functions. (Run 1 reported 36+5 by a different count method;
the SAME method at Run 1's base `6d571e5` gives 37+7 — the count difference is
methodology, not surface drift.) **Churn-attributable surface delta = exactly one
new site: `XqliteNIF.total_changes/1`** (via `conn_total_changes/1`, the F-X2-1
fix — absent at `6d571e5`, present at `5a411ee`; 0 removed; Xqlite.\* unchanged).
Already covered by Run 1's blast-radius table (`changes`/`total_changes` row:
relies on `{:ok, non_neg_integer}`, LOUD-ish, falls to `0` on error — the new
`conn_total_changes` does exactly that).

**Forward-delta walk through the blast-radius table (v0.10.0..main), row by row:**

| blast-radius row | shape | touched by v0.10.0..main? |
|---|---|---|
| `query_with_changes[_cancellable]` `{columns,rows,num_rows,changes}` | result map | NO — nif.rs attribute-only; `columns` encoder graceful-OOM but success byte-identical |
| `stmt_multi_step_cancellable` `{rows, done}` | result map | NO |
| `stmt_prepare` `:multiple_statements` / `{:cannot_execute,_}` | sentinels | NO |
| `stream_fetch` `{rows}` \| `:done` | result/sentinel | NO |
| `transaction_status` / `txn_state` `{:ok,bool}` / `{:ok,:none\|:read\|:write}` | shapes | NO |
| `query` `{rows}` | result map | NO |
| `changes` / `total_changes` `{:ok,non_neg_integer}` | shape | NO |
| begin/commit/rollback/savepoint/… `:ok \| {:error,_}` | shape | NO |
| `set_pragma`/`open`/`open_readonly` `{:ok,_} \| {:error,_}` | shape | NO |
| all error reasons → `error_reason/0` | union | **YES, additive only** (+2 bare atoms, both unreachable from surface, both atom-clause-classified) |

Verdict: the only row that moved is "all error reasons," and only additively.
No result-map key, sentinel atom, or shape a `with`/`case` relies on changed.
Zero new findings.

### Verdict + dryness

- 1 S3 backlog item RESOLVED as FIXED (F-X1-2, RED→green). 0 new S0–S2. 0 new
  S3. X1 standing surface CLEAN, B1 CLEAN, X2 CLEAN. Forward blast CLEAN across
  all three (additive-only union growth; no shape regression). `mix verify`
  green at close.
- Dryness: NONE go DRY. **X1 NOT DRY** — the F-X1-2 resolution CHURNED `wrap/1`
  (a listed re-wetter), so a covering pass over the three new clauses is owed
  (the standing audit itself was clean). **B1 NOT DRY** — first clean covering
  run over the Runs-2–4 override/DBConnection churn (1 of 2), one more owed.
  **X2 NOT DRY** — first clean covering run over the F-X2-1 `total_changes`
  churn (1 of 2), one more owed. Re-wetters recorded in REVIEW_AXES.md.
- Completeness critic: the F-X1-2 fix keeps `details: nil` for the 14 shapes
  (tag + inspected message only) — a future pass could add dedicated structs
  for the reachable ones (`:cannot_open_database`, `:integral_value_out_of_range`)
  if a consumer needs field-level access, but that is enrichment, not a
  correctness gap. The forward delta was checked for SHAPE movement only; the
  four maintainer rulings (busy per-event elapsed, reader-NIF DirtyIo, TEXT-OOM
  graceful, changeset `:replace` keep-abort) are BEHAVIORAL and were confirmed
  not to touch any adapter-consumed contract — but their BEHAVIORAL effects
  (e.g. busy timing under the adapter's `busy_timeout`, DirtyIo pool occupancy
  under adapter read volume) are a B3/B8 concern, not re-audited here (out of
  X1/B1/X2 scope). `to_constraints/2` was re-read but not re-fuzzed against a
  new Ecto matcher version (no ecto_sql bump in the churn). The owed second
  covering pass on each axis remains for the next dryness lap.

---

## Run 6 — 2026-07-20 — dryness pass 2: B6 + B5 + B3

- Commit at scan: `dec4469` (after adapter Run 5). Deps compiled at xqlite
  0.10.0 (`mix.lock` pin + `deps/xqlite/mix.exs` both verified 0.10.0;
  `XQLITE_PATH` unset, `deps/xqlite` is a real dir not a path symlink — the
  probes characterize published 0.10.0, NOT `../xqlite` main). Single Opus
  reviewer; live queries through real repos/driver against the BUNDLED SQLite
  3.53.2, every runtime claim produced THIS session (scripts under scratchpad,
  driven via `MIX_ENV=test mix run` / `mix test`).
- Scope: the SECOND covering pass over B6 (query translation — the owed DEPTH
  pass on wrong-results semantics), B5 (constraint mapping — the owed
  reconnect-enforcement probe), B3 (sandbox + pooling — the owed storm probes).
  Contracts read from `deps/` source: Ecto `like/2` doc (`ecto/lib/ecto/query/
  api.ex:210-223`), `Ecto.Adapters.SQL.disconnect_all/3` + `DBConnection.
  disconnect_all/3`, the driver connect `with` chain (`driver.ex:56-85`).

### B6 — query translation (PRIMARY; the owed DEPTH pass)

Ran real queries through a live repo inspecting BOTH emitted SQL (`Ecto.Adapters.
SQL.to_sql/3`) and returned rows against bundled SQLite. Every wrong-results
class probed; ALL correct-by-translation or Ecto-contract-honest. Zero findings.

- **NULL semantics** (`b6_semantics.exs`, all input→expected=actual): `count(*)`
  posts → 4; `count(views)` skips NULL → 2; `sum(views)` over NULLs → 30;
  `avg(views)` → 15.0 (skips NULLs); `sum` over empty set → nil, `count` over
  empty set → 0; GROUP BY author_id → `[{nil,1},{1,2},{2,1}]` (NULL its own
  group); GROUP BY views → `[{nil,2},…]` (NULLs collapse to one group); DISTINCT
  views → `[nil,10,20]` (NULLs collapse); INNER JOIN drops the NULL-author orphan;
  LEFT JOIN keeps it `{4,nil}`; `author_id IN [1,nil,2]` → `[1,2,3]`; `author_id
  NOT IN [1,nil]` → `[]` (classic three-valued-logic trap — but IDENTICAL to
  Postgres, correct SQL not a divergence); `is_nil(views)` → `IS NULL` → `[2,4]`.
  `p.author_id == ^nil` is blocked by Ecto's own `not_nil!/2` builder guard
  UPSTREAM (raises `ArgumentError`), so the adapter never receives a `= NULL` to
  emit — the `is_nil`→`IS NULL` path is the only route and it is correct.
- **Case sensitivity**: `like(name, "zebra")` matched BOTH "ZEBRA" and "zebra"
  (SQLite LIKE is ASCII-case-insensitive); `like(name, "äpfel")` matched ONLY
  "äpfel" not "Äpfel" (ASCII-only, no Unicode fold). This diverges from Postgres
  (LIKE case-SENSITIVE) but is EXPLICITLY within Ecto's `like/2` contract:
  "PostgreSQL will do a case-sensitive operation, while the majority of other
  databases will be case-insensitive" (`ecto/lib/ecto/query/api.ex:214-217`) —
  correct-by-translation + Ecto-contract-honest. `ilike/2` raises loudly
  (`Ecto.QueryError` "ilike is not supported by SQLite", `connection.ex:1618`) —
  honest refusal, no silent LIKE substitution.
- **NOCASE collation** (`b6_windows_grammar.exs`): the adapter surfaces
  collations via a migration column's `collate:` option (`collate_expr/1`,
  `connection.ex:1987-1991`, upcased). `TEXT COLLATE NOCASE` emitted; live:
  `name == "abc"` → `[1,2]` (folds ASCII "ABC"=="abc"), `name == "ä"` → `[4]`
  ONLY (does NOT fold "Ä"). ASCII-only NOCASE is SQLite's documented behavior;
  the adapter emits exactly what the migration asks — correct-by-translation (no
  Postgres equivalent expectation being violated; `collate:` is DB-specific).
- **Window functions** (all emit valid SQL + compute correctly): inline `over(
  sum, partition_by:, order_by:)` running sum → `[{1,10},{2,15},{3,20},{4,27}]`;
  named window (`WINDOW "w" AS (…)`); `row_number() OVER (PARTITION BY … ORDER BY
  … DESC)`; and ALL THREE frame types via the Ecto-sanctioned `frame:
  fragment(…)` form — `ROWS`/`RANGE`/`GROUPS BETWEEN … EXCLUDE CURRENT ROW` all
  emit correctly and the GROUPS+EXCLUDE result was hand-verified row-by-row.
  Non-partition/order/frame window keys raise loudly (`connection.ex:1318`);
  frame accepts only a fragment (Ecto's own contract). No unsupported frame form
  emits silently.
- **Grammar-gap seeds** (`b6_onconflict_update.exs`, live-executed): EXISTS
  correlated subquery emits single-paren `exists(SELECT 1 …)` (valid SQLite, NOT
  a double-paren break) and returns `[3,4]` correctly; `UPDATE "posts" AS p0 SET
  … FROM "posts" AS p1 WHERE …` (SQLite 3.33+ UPDATE-FROM) threads aliases
  correctly — update_all changed 2 rows to the expected values; ON CONFLICT with
  a PARTIAL-INDEX target (`conflict_target: {:unsafe_fragment, "(k) WHERE active
  = 1"}`) upserted correctly; ON CONFLICT with an EXPRESSION target
  (`"(lower(email))"`, `on_conflict: :nothing`) deduplicated the case-variant
  insert correctly.
- **Churn re-verify (light, live)**: `escape_string/1` emits a literal backslash
  single (`= 'a\b'`, no `\\` — F-B6-1 holds); `limit/2` emits `LIMIT -1 OFFSET 2`
  for offset-without-limit → correct tail rows (F-B6-2 holds); `quote_entity/1`
  collapses the injection `identifier(^~s|x" FROM posts;--|)` to one inert
  identifier `"x"" FROM posts;--"` (F-B6-3 holds).

### B5 — constraint mapping (the owed reconnect-enforcement probe)

PRAGMA foreign_keys is per-connection and OFF by default; proved enforcement on
EVERY pool member AND across reconnects. Zero findings.

- **Every pool member** (`b5_every_member.exs`): pool_size 5, 200 concurrent
  FK-violating inserts (`INSERT INTO children … parent_id 999`, parent absent).
  Result: `%{fk_error: 200}` — ALL 200 returned the structured
  `%XqliteEcto3.Error{type: :constraint_violation, details: %Constraint{subtype:
  :constraint_foreign_key}}`; 5 distinct pool members observed serving (via
  `handle_execute` telemetry `%{conn}`); 0 orphan rows in `children` (no member
  let a violation through — a non-enforcing member would have inserted the orphan).
- **Reconnect enforcement PROVEN, not inferred** (`b5_reconnect.exs`): baseline
  FK violation on a fresh pool → structured FK error, 0 orphans; forced reconnect
  via `Ecto.Adapters.SQL.disconnect_all(repo, 0)` while driving traffic; BOTH
  `[:xqlite_ecto3, :disconnect]` AND `[:xqlite_ecto3, :connect, :stop]` telemetry
  observed (the reconnect witness) with a 10 s wait ceiling (≥10× the sub-second
  worst case); after reconnect the FK violation is STILL rejected structurally
  with 0 orphans; a SECOND disconnect_all cycle repeated the same result (not a
  one-off).
- **Committed contract test** (`driver_connect_pragmas_test.exs` +1, deterministic,
  async, no concurrency): the pool replaces a dropped connection by calling
  `Driver.disconnect/2` then `Driver.connect/1`; the test drives exactly that pair
  on a file DB — a fresh connection rejects an orphan insert structurally
  (`:constraint_foreign_key`) and reports `foreign_keys == 1`; after
  `Driver.disconnect/2` + a re-`connect/1`, the replacement connection STILL
  reports `foreign_keys == 1` AND rejects the orphan insert (an FK error, not a
  missing-table error, proves both schema persistence and live re-enforcement).
- **No pre-FK-ON serving window** (source + runtime): `foreign_keys` is set at
  `driver.ex:65` INSIDE the connect `with` chain; `connect/1` returns
  `{:ok, state}` only after the FULL chain succeeds, and DBConnection does not
  hand out a connection until `connect` returns `{:ok, …}` — so no query can run
  before `foreign_keys=ON`. Runtime-corroborated: the VERY FIRST query on a
  brand-new pool already enforces FK (b5_reconnect baseline).
- **Mapping surface re-cover** (no churn since Run 2): `to_constraints/2` re-read
  (`connection.ex:102-162`) — unique/PK → `<table>_<col>_index` convention,
  check → `constraint_name`, not_null → `<table>.<col>`, FK-with-rich-payload →
  synthesized `<table>_<col>_fkey` names; the existing `constraints_test.exs`
  (unique/FK/check/not_null through real changesets vs Ecto's `constraints_to_
  errors/3`) covers the end-to-end matcher — spot-confirmed the raw NIF FK shape
  is `{:constraint_violation, :constraint_foreign_key, %{…}}` wrapping to the
  `Constraint` struct. F-B5-1 (`[foreign_key: nil]` crashes Ecto's matcher under
  `match: :suffix`/`:prefix`) UNCHANGED — my probes used raw inserts, not the
  suffix-matcher path, so no new evidence sharpening its remedy (maintainer call).

### B3 — sandbox + pooling under a single writer (the owed storm probes)

- **Busy-policy API determination (maintainer-rulings behavioral check)**: the
  adapter does NOT call xqlite's busy-POLICY API (`rg 'set_busy_policy|
  busy_policy|max_retries|max_elapsed|register_busy' lib/` = ZERO) — it sets ONLY
  the `busy_timeout` PRAGMA (`driver.ex:63`). Therefore xqlite main's busy
  per-event-elapsed clock-reset change (unreleased, post-0.10.0) does NOT touch
  the adapter at 0.10.0. Question CLOSED.
- **Connect-time PRAGMA storm** (`b3_connect_storm.exs`): pool_size 15 on a fresh
  non-WAL file, 300 concurrent inserts fired immediately. Expected: contention
  on the concurrent `journal_mode=wal` flips. Actual: CLEAN — `%{ok: 300}`, 15
  connect_start / 15 connect_ok / 0 connect_err / 0 connect_exc, final
  journal_mode=wal, 300/300 rows, ~37 ms, pool healthy. The connect-time
  `busy_timeout` (set at `driver.ex:63` BEFORE the `journal_mode` write at :64)
  absorbs the brief WAL-header contention among pool members.
- **Cold-start racing a held write lock → F-B3-2 (S3, BACKLOG)**
  (`b3_connect_vs_lock.exs` / `b3_boot_noise.exs`): a fresh non-WAL file, one raw
  connection holding `BEGIN IMMEDIATE`, then a pool cold-start whose members must
  flip WAL. Expected vs actual: with `busy_timeout: 300` and the lock held 2000 ms,
  every member's connect FAILS the WAL flip and DBConnection logs `[error]
  XqliteEcto3.Driver (…) failed to connect: {:database_busy_or_locked, 5,
  "database is locked"}` (6 members + several retries observed), then retries with
  backoff; ALL queries still succeed once the lock releases (elapsed ≈ lock-hold
  time), pool ends healthy, WAL persists (later boots clean). SELF-HEALING, no
  query-path impact — but an `[error]` boot-log burst that is UNDOCUMENTED. This is
  the exact race `test/test_helper.exs:170-177` pre-sets WAL to avoid. Filed S3
  (ergonomics/docs; not S2 — correct structured classification, no wrong results,
  no crash, recovers). NOT committed as a test (inherently timing/concurrency —
  the async ban applies; scratchpad + this evidence instead).
- **Busy storm under concurrent writers** (`b3_busy_storm.exs`): pool_size 8, 200
  concurrent write transactions all on ONE hot row (WAL, busy_timeout 5000).
  Expected: busy contention. Actual: CLEAN — `%{ok: 200}`, final counter n=200
  (EXACTLY the successful-txn count → no lost updates, correctly serialized via
  WAL single-writer + busy_timeout), ~106 ms, pool healthy. And when busy_timeout
  IS exceeded (`b3_forced_busy.exs`, 200 ms timeout vs a 1500 ms held lock): the
  write surfaces a STRUCTURED `%XqliteEcto3.Error{type: :database_busy_or_locked,
  details: %{extended_code: 5}}` (SQLITE_BUSY), and the pool stays healthy and
  writable afterward — nothing uglier than a structured retryable error.
- **Sandbox shared mode across processes** (`b3_sandbox_shared.exs`): the suite
  runs manual mode; probed the unprobed shared path. `{:shared, self()}` — a
  spawned Task saw the parent's UNCOMMITTED row (`["from_parent"]`) and the parent
  saw the Task's row (both) on the shared connection, count 2 during the txn, and
  after `checkin` + a fresh checkout count 0 (rolled back — isolation held).
  `allow/3` explicit allowance — allowed child saw the owner's row, owner saw the
  child's row, and post-checkin count 0 (rolled back). Both cross-process paths
  correct with rollback isolation preserved.
- **Wedged-txn-state symmetry** (source): failed begin/commit/rollback all return
  `{:disconnect, …}` (`driver.ex` handle_begin/commit/rollback) → wedged txn torn
  down + reconnected, never reused. UNCHANGED from Run 2, re-confirmed.

### Verdict + dryness

- 0 new S0–S2. 1 new S3 → BACKLOG (F-B3-2, cold-start WAL-flip boot-log noise).
  1 deterministic committed test added (reconnect FK enforcement,
  `driver_connect_pragmas_test.exs` +1, GREEN). B6 CLEAN (depth pass, zero
  findings). B5 CLEAN (reconnect enforcement PROVEN on every member + across
  reconnects; mapping surface intact). B3 storm probes CLEAN except the S3 boot
  noise. `mix verify` green at close.
- Dryness: **B6 — first clean covering run (1 of 2), NOT DRY**, one more owed
  (Run 2 found three fixed bugs). **B5 — first clean covering run (1 of 2), NOT
  DRY**, one more owed (Run 2 found F-B5-1). **B3 — a new CONFIRMED S3 (F-B3-2)
  surfaced, so NOT a clean covering run — stays at 0 of 2, NOT DRY.** Re-wetters
  in REVIEW_AXES.md refreshed.
- Completeness critic: F-B3-2 is filed not fixed (S3; the doc-vs-code remedy is a
  maintainer call, and a deterministic committed test would fight the async ban).
  B6 depth was exhaustive on the wrong-results seed list, but window-frame probing
  used only the fragment form (Ecto's contract) — a future pass could confirm
  Ecto rejects a non-fragment frame upstream (believed so, not lived). NOCASE/LIKE
  ASCII-only is correct-by-translation but UNDOCUMENTED in the adapter's own docs
  — an ergonomics note (not a finding) a docs pass could add. B5's every-member
  proof used raw inserts (enforcement) not the `foreign_key_constraint/3` changeset
  path per member (mapping) — the mapping-per-member combination is covered
  transitively (all members share the same connect path) but not lived per member;
  F-B5-1's suffix-matcher remedy got no new evidence. B3 did not probe owner-process
  death mid-transaction under the sandbox (A7-adjacent, xqlite-side covered). The
  owed second covering pass on B6/B5 and the still-owed first clean run on B3 remain
  for the next dryness lap.

---

## Run 7 — 2026-07-21 — dryness pass 3: B8 + B4 + B7

- Commit at scan: `828bb95` (after adapter Run 6). Deps compiled at xqlite 0.10.0
  (`mix.lock` pin verified; `XQLITE_PATH` unset, `deps/xqlite` a real dir — the
  probes characterize published 0.10.0, its vendored `native/…/nif.rs` read for the
  DirtyIo determination, NOT `../xqlite` main). Single Opus reviewer; every runtime
  claim produced THIS session (scripts under scratchpad, driven via `mix run` /
  `mix test`). Added `{:stream_data, "~> 1.1", only: [:test]}` (fetched via the
  sanctioned HEX_HOME; the xqlite dep stays the published 0.10.0 hex package).
- Scope: the SECOND covering pass over B8 (timeout→cancel, flagship), B4 (type
  round-trips as properties), B7 (migration ergonomics). Re-covered the churn: the
  F-B7-1 fix, the decimal remedy (`DecimalPrecision` guard + `encode_param` raise),
  and driver churn (total_changes threading, disconnect reason). Contracts read from
  `deps/` source: `db_connection.ex` `handle_common_result` (`{:error,…}` keeps the
  connection; only `{:disconnect,…}` tears it down — `:1397-1416`), and the rebuild
  engine in `lib/xqlite_ecto3.ex`.

### B8 — timeout→cancel divergence (FLAGSHIP; CORE CLEAN, pool-deadline characterized)

- **Core re-verified live through the churn.** `cancellation_test.exs` green;
  cached-path AND one-shot-path timeouts cancel promptly (~101 ms for a 100 ms token
  on a ~3500 ms query), return `%DBConnection.ConnectionError{}`, pool reusable. The
  `total_changes` threading in `finish_cached_stmt` and the `disconnect` reason did
  not perturb cancel promptness or reuse.
- **Encode-raise × cancel machinery — CLEAN (my specific angle).**
  `b8_encode_raise_probe.exs`, real pool_size:1 repo: a beyond-precision
  `Decimal.new("12345678901234567890.12345")` insert raised `DecimalPrecisionError`
  (value on `.value`); process-count delta = **0** (no canceller spawned), mailbox =
  `:none` (no stray `{:cancel_query,_}`/`{ref,:ready}`), the subsequent valid insert
  round-tripped on the same pool, and a post-raise cancellable timeout still fired
  in 101 ms. The raise is in `DBConnection.Query.encode`, BEFORE `handle_execute`
  creates any token — so there is nothing to leak.
- **Owed pool-deadline item RESOLVED → F-B8-3 (S3, DOCS-only; not an adapter
  defect).** Through a REAL DBConnection pool (`b8_pool_telemetry_probe.exs`), a
  `:timeout` fires BOTH the graceful cancel (caller gets `{:error, ConnectionError
  "query timed out"}`) AND DBConnection's own checkout deadline (same value), which
  DISCONNECTS+reconnects the connection: a connection-local TEMP table created
  before the 100 ms-timeout query was GONE afterward, and `[:xqlite_ecto3,
  :disconnect]` (reason: "client … timed out because it queued and checked out the
  connection for longer than 100ms") + `[:xqlite_ecto3, :connect, :stop]` both
  fired. SAFE + self-healing + STANDARD DBConnection behavior (every adapter recycles
  on the operation deadline). The graceful cancel's pool-level value is freeing the
  blocked dirty NIF PROMPTLY (at the deadline, ~100 ms, vs ~3500 ms natural
  completion) so the recycle happens then. The direct-driver `cancellation_test`
  cannot observe this (bypasses the pool). Pinned the pool-level contract
  deterministically: `cancellation_test.exs` +1 ("timeout through a real
  DBConnection pool" — dedicated pool, structured error + prompt < 2000 ms +
  self-heal, `@tag capture_log`). Filed F-B8-3 → BACKLOG (a doc line: a pooled
  timeout recycles the connection / resets the statement cache).
- **DirtyIo determination.** At deps/xqlite 0.10.0 the adapter's hot paths are
  ALREADY predominantly DirtyIo (71/96 NIFs DirtyIo); only 7 adapter-called NIFs are
  on the normal scheduler: `stmt_column_names`, `total_changes`, `changes`,
  `txn_state`, `create_cancel_token`, `cancel_operation`, `register_progress_hook`.
  xqlite main's unreleased 20-NIF flip touches **5 of those 7** (all but the two
  cancel-token NIFs), flipping them normal→DirtyIo — verified ATTRIBUTE-ONLY per
  function (`git diff v0.10.0..HEAD`: only `#[rustler::nif]` →
  `#[rustler::nif(schedule = "DirtyIo")]`, bodies byte-identical), so
  correctness-transparent (result shapes unchanged; no adapter `with`/`case` depends
  on scheduler class). Unlike Run 6's clean busy-policy CLOSE (adapter never calls
  that API), the flip DOES touch adapter-called functions, so the disposition is:
  safe/non-breaking at 0.10.0 and at the bump; RE-PROBE dirty-IO-pool occupancy
  under high read concurrency WHEN the dep is bumped past 0.10.0.

### B4 — type round-trips as properties (CLEAN; stream_data shipped)

- **Guard boundary fuzzed (stream_data).** `types_roundtrip_matrix_test.exs` +1
  property: for arbitrary finite Decimals (sign × coefficient[1..25 digits] ×
  10^[-20..20], straddling the ~15–17-significant-digit threshold), an insert
  through a REAL DECIMAL column either round-trips exactly (guard accept) or raises
  `DecimalPrecisionError` (guard reject) — never a silent mismatch. GREEN across 10
  seeds (~1000 distinct values vs bundled C SQLite 3.53.2); no guard false-accept.
- **Guard-vs-SQLite cross-check re-verified BY MY OWN runs** (`b4_crosscheck_
  probe.exs`; subagent history inadmissible): accept `19.99` / `9999999999999.99` /
  `3.141592653589793` and reject `12345678901234567890.12345` /
  `0.12345678901234567` / `18446744073709551615` — each cross-checked guard verdict
  ⟺ repo round-trip ⟺ raw-SQL SQLite `typeof`/value; all CONSISTENT (accept ⟺ stored
  exactly; reject ⟺ repo raises ⟺ SQLite would round, e.g. `0.12345678901234567` →
  `0.12345678901234566`).
- **One-way pins re-confirmed** (Instant ns-truncation, TimestampTZ zone-collapse to
  Etc/UTC, atom-keys→string — the custom-type + matrix suites green). Zero findings.

### B7 — migration ergonomics (living the rebuild dance; one CONFIRMED S1 fixed)

- **F-B7-2 (S1, CONFIRMED + FIXED, RED→green).** The opt-in rebuild
  (`support_alter_via_table_rebuild: true`) reconstructs the new table from `PRAGMA
  table_xinfo` (name/type/notnull/default/pk only), so a `:modify` SILENTLY DROPPED
  foreign keys, CHECK constraints, COLLATE / inline-UNIQUE clauses, and generated
  columns. Proven live through `Ecto.Migrator` with idiomatic `references/1` +
  `check:` (`b7_migrator_probe.exs`): after `modify :name`, the rebuilt schema was
  `("id" …, "name" …, "parent_id" INTEGER, "qty" INTEGER)` — FK `child_parent_id_
  fkey` and CHECK `qty_pos` GONE; a subsequent orphan insert (parent_id 999) and a
  CHECK-violating insert (qty -5) were both ACCEPTED; `foreign_key_check` was
  vacuously clean because the FK no longer existed. Generated columns also broke
  (`b7_generated_probe.exs`): a STORED generated column froze into a plain column,
  a VIRTUAL one vanished (`no such column`). Consequence-class S0 (wrong-results/
  integrity loss); mechanism = silent schema transformation (S1). Fixed to REFUSE
  loudly BEFORE any destructive step (mirrors F-B7-1): `rebuild_table` now calls
  `refuse_unpreservable_constraints!/3`, which raises `ArgumentError` (table left
  intact) when the table declares REFERENCES/CHECK/COLLATE/UNIQUE (scanned from the
  stored CREATE TABLE SQL) or has generated columns (`table_xinfo.hidden IN (2,3)`).
  Detection over-approximates, so the only failure mode is a safe refusal, never a
  silent drop; standalone indexes/triggers/AUTOINCREMENT stay preserved. Docs (README
  rebuild section + `Migration` moduledoc — both had claimed the dance preserved
  everything / recreated FKs) corrected. RED→green in `table_rebuild_test.exs` (+5).
  Richer remedy (faithful reconstruction) → BACKLOG A4.
- **The REST of the dance is CORRECT — all lived** (`b7_rebuild_probe.exs`): rows
  preserved (count + spot values), standalone index preserved + FUNCTIONAL (unique
  violation still raised), trigger preserved + FIRING (note bumped), AUTOINCREMENT
  sequence not reset (post-rebuild insert got a higher rowid than the pre-rebuild
  max). Downgrade (`b7_downgrade_probe.exs`): explicit up/down rebuilds both
  directions (rows preserved, types restored); `change/0` with `from:` auto-reverses;
  `change/0` without `from:` refuses loudly (`Ecto.MigrationError`). Inbound-FK
  parent rebuild works inside a migration transaction (defer_foreign_keys persists);
  outside a transaction the DROP loudly fails (autocommit resets the pragma) — real
  migrations always wrap, so no silent path.
- **Owed refusals lived** (`b7_refusals_probe.exs`): `modifiers_expr` non-string
  (`[:temporary]`, `:temporary`) → loud `ArgumentError`. ADD-COLUMN-with-REFERENCES:
  nullable SUCCEEDS with the FK genuinely enforced (schema carries the CONSTRAINT,
  orphan rejected, valid accepted) — Run 3's "runtime rejection" anticipation was
  WRONG; NOT NULL → loud structured `XqliteEcto3.Error` ("Cannot add a NOT NULL
  column with default value NULL"). F-B7-1 fix re-covered (`migration_test.exs`
  green).

### Verdict + dryness

- 1 S1 CONFIRMED+FIXED (F-B7-2, RED→green), 1 S3 → BACKLOG (F-B8-3, docs-only). B8
  core CLEAN + encode-raise CLEAN + pool-deadline safe-standard-behavior; B4 CLEAN;
  B7 CLEAN bar the one silent rebuild miscompile now fixed. `mix verify` green at
  close.
- Dryness: **B8 — first clean covering run (1 of 2), NOT DRY** (Run 3 found F-B8-1/2;
  F-B8-3 is docs-only-standard-behavior, not an adapter defect — does not reset).
  **B4 — first clean covering run over the remedy churn (1 of 2), NOT DRY** (Run 3
  found F-B4-1). **B7 — a NEW confirmed (F-B7-2) surfaced, so NOT a clean covering
  run — stays at 0 of 2, NOT DRY**; the rebuild-guard fix re-wets. Re-wetters in
  REVIEW_AXES.md refreshed (B8 also re-wets on an xqlite scheduler-class change to an
  adapter-called NIF; B7 also on any `rebuild_table`/`refuse_unpreservable_
  constraints!`/`plan_new_schema` change).
- Completeness critic: F-B7-2's fix is the SAFE loud refusal, not faithful
  preservation — a table with an FK/CHECK/COLLATE/UNIQUE/generated column can no
  longer be `:modify`-rebuilt at all (must go through `execute/1`), which limits the
  feature; faithful reconstruction (BACKLOG A4) is the maintainer's richer-remedy
  call. The refusal detection over-approximates the SQL scan (a stray "CHECK"/
  "UNIQUE"/"REFERENCES"/"COLLATE" word in a string default or comment triggers a
  safe-but-spurious refusal) — deliberate (safety over precision). B8's pool-deadline
  reconnect was characterized but NOT turned into a "connection preserved" assertion
  (it is NOT preserved — the committed test pins the pool-level contract, not
  connection identity); the F-B8-3 doc line is unwritten (maintainer's docs call).
  The DirtyIo re-probe is owed WHEN the xqlite dep is bumped past 0.10.0 (5
  adapter-called reads flip to DirtyIo). B4's property fuzzes finite Decimals only
  (NaN/Inf/subnormal covered by the example table, not the generator). The owed
  SECOND clean covering pass on B8/B4 and the still-owed first clean run on B7 remain
  for the next dryness lap.

---

## Run 8 — 2026-07-21 — dryness pass 4: B2 + B9 + B10

- Commit at scan: `811d544` (after adapter Run 7). Deps compiled at xqlite 0.10.0
  (`mix.lock` pin; `XQLITE_PATH` unset, top-level xqlite dep = published 0.10.0 hex).
  Single Opus reviewer; every runtime claim produced THIS session (scripts under
  scratchpad, driven via `mix run` / `mix test`). Two sanctioned gap-closures this
  run (a telemetry-OFF CI lane + the bench dep bump) recorded below as WORK with
  evidence, not findings.
- Scope: the SECOND covering pass over B2 (exclusion-list audit), B9 (telemetry),
  B10 (benchmarks). Re-covered the churn: the Run-4 JSON-path quoted-label fix
  (`escape_json_key`/`json_extract_path`/`dynamic_json_path`), the Run-4 disconnect
  `reason` fix, and the standing F-B10-1 (bench did not compile).

### B2 — exclusion-list audit (one NEW CONFIRMED S2 fixed; drift clean; G2 closed)

- **F-B2-2 (S2, CONFIRMED + FIXED — RED→green). The `dynamic_json_path` runtime-value
  branch escaped nothing, so a runtime JSON key containing a `\` silently extracted
  nil.** Run 4's critic owed a characterization of the runtime `.\"` || seg || `\"`
  concatenation path (Run 4 fixed only the compile-time literal branches and BELIEVED
  the runtime branch correct because it wraps in `."…"`). SQLite ground truth
  (`b2_json_runtime.exs`, bundled 3.53.2): the runtime branch emits `$."<raw value>"`
  with NO escaping — for the stored key `back\slash` (one backslash) the path
  `$."back\slash"` returns **nil** (SQLite treats `\` as a JSON5 escape inside the
  quoted label), while the compile-time branch (which doubles the backslash →
  `$."back\\slash"`) returns the value `"bv"`. A runtime double-quote key was also
  nil (that case was DOCUMENTED-unsupported in the moduledoc; the backslash case was
  UNDOCUMENTED + silently wrong — same mechanism-class as F-B2-1, different code
  path). Proven end-to-end through the real adapter/repo (`json_extract_path_test.exs`
  +2: set `label` to `back\slash` / `quo"ted`, `select: d.meta[d.label]`) — RED both
  nil. Fix: escape the runtime value for the JSON5 quoted-label grammar via nested
  `replace(replace(<seg>, '\', '\\'), '"', '\"')` (double backslash first, then escape
  the quote), mirroring the compile-time `escape_json_key`. `b2_json_fix.exs`
  confirmed the escaped path resolves dot/backslash/quote/plain all correctly (the
  fix also CLOSES the previously-documented double-quote limitation — moduledoc
  comment updated to drop that caveat). GREEN: `json_extract_path_test.exs` 15/17 →
  17 passed. Consequence class silent-wrong-results; reachability narrower than F-B2-1
  (needs a runtime key segment AND a backslash in the value), rated S2 to match its
  sibling.
- **Exclusion drift — CLEAN.** `git log 5b32d11..HEAD -- test/test_helper.exs
  ECTO_INTEGRATION_TAGS.md` shows ONLY Run 4's own fix commit (`1d775ef`), nothing
  since — Runs 5–7 added tests but ZERO exclusions. Count re-confirmed: 14 tag
  exclusions + 5 `{:location,…}` = **19** (matches Run 4). 16/18 shared files loaded
  (all_test.exs: 7 ecto cases + 9 ecto_sql sql; lock.exs/query_many.exs skipped) —
  matches the header. The two previously-stale rows re-isolated LIVE:
  `--only values_list` ⇒ **5 passed**, `--only transaction_checkout_raises` ⇒ **1
  passed** (identical to Run 4) — rows still accurate.
- **Reconnect-time exclusion re-check — no exclusion rationale is connection-
  lifecycle-sensitive.** Every exclusion rests on a SQLite grammar / storage-class /
  architecture invariant (no native array/bitstring/duration type, no isolation
  levels, no advisory locks, no schema/namespace, no ALTER COLUMN, no column-list ON
  DELETE, `LIKE_DOESNT_MATCH_BLOBS`, ms-precision `strftime %f`, JSON-as-TEXT
  schemaless, multi-row VALUES column uniformity) — none depends on per-connection
  mutable state a reconnect could change. The one genuinely per-connection setting
  (`foreign_keys` PRAGMA) backs NO exclusion (that tag is un-excluded) and is
  re-proven per-connection incl. reconnects under B5 (Run 6). Determination recorded:
  the reconnect re-check is a no-op for B2.
- **G2 remainder CLOSED (mechanical doc).** `:concurrent_poolrepo_transactions`
  confirmed orphaned (`rg` in `deps/` finds no such tag anywhere) → row DROPPED.
  `:foreign_key_constraint` is a real tag (6 `@tag` sites in `repo.exs`), un-excluded,
  and `--only foreign_key_constraint` ⇒ **6 passed** (rich FK diagnostics synthesize
  the `<table>_<col>_fkey` name) → row rewritten `excluded`→`supported`. Closes
  BACKLOG G2.

### B9 — telemetry (event surface re-driven CLEAN; CI-OFF gap CLOSED)

- **Churn re-verified live.** `disconnect/2` emits `%{conn, reason}` with
  `reason == :normal` (Run 4's fix — `telemetry_test.exs` green). Run 7 added no
  events: `git log 5b32d11..HEAD -- driver.ex fk_diagnostics.ex` = only `1d775ef`
  (Run 4's disconnect fix); the `fk_diagnostics` span predates everything
  (`794c121`, T3.4).
- **Documented event surface re-driven under the ON build** (spot-verify, my own
  runs): `telemetry_test.exs` 12 passed (connect start/stop + database/result_class,
  disconnect+reason, checkout, txn trio begin/commit/rollback with `mode`
  transaction+savepoint, handle_execute with sql + ok/error, declare/fetch/deallocate
  with the documented `query`-vs-`cursor` split); `driver_statement_cache_test.exs`
  14 passed (statement_cache miss/hit/miss/evicted with `cached_count` + `sql`);
  `fk_diagnostics_test.exs` 13 passed (the `[:xqlite_ecto3, :fk_diagnostics, :*]` span
  start `mode` + stop `violations_count`/`diagnostics_status`);
  `telemetry_open_telemetry_test.exs` 5 passed. OTel mapping
  (`telemetry/open_telemetry.ex`) BYTE-UNCHANGED since Run 4 (`git log 5b32d11..HEAD`
  empty on its path) — spot-confirmed + green.
- **[B9] CI gap CLOSED — new `telemetry_disabled` lane.** Config mechanism: the
  adapter's compile-time flag in `config/test.exs` is now env-driven —
  `config :xqlite_ecto3, :telemetry_enabled, System.get_env("XQLITE_ECTO3_TELEMETRY")
  != "off"` (xqlite's own flag left ON, so no hex-dep `compile_env` mismatch; only the
  adapter no-op path is exercised). New build-agnostic smoke file
  `telemetry_disabled_smoke_test.exs` runs a `SELECT 1` through `Driver.handle_execute`
  and asserts, per the compile-time flag (module-level `if @telemetry_enabled` — the
  Telemetry module's own sanctioned pattern, so no type-checker "always true" warning
  under warnings-as-errors): result `%{rows: [[1]]}` flows through the no-op span
  (proving the disabled `span_with_stop_metadata` still unwraps `{value, metadata}`),
  and `refute_received` on the adapter events (no-op `emit` fires nothing). New CI job
  `telemetry_disabled` (free-tier ubuntu-latest, `needs: format_and_lint`, distinct
  `v0-elixir-teloff-…` cache key, job-env `XQLITE_ECTO3_TELEMETRY: off`): step (a)
  `MIX_ENV=test mix compile --force --warnings-as-errors`, step (b) `mix test
  test/xqlite_ecto3/telemetry_disabled_smoke_test.exs`. **Both commands proven locally
  from a warm ON `_build`**: compile exit 0 ("Generated xqlite_ecto3 app", no
  warnings), smoke exit 0 (1 passed via the `refute` branch — confirming the adapter
  recompiled OFF and no events fired); the same file also passes in the normal ON
  suite (asserts the event fires). YAML validated (`yaml.safe_load`). Updated BACKLOG
  [B9] → closed with the lane name.

### B10 — benchmarks (F-B10-1 CLOSED; harness compiles + smoke-runs; methodology honest)

- **F-B10-1 CLOSED — bench compiles + runs after the dep bump.** `bench/mix.exs`
  bumped `ecto_sql "~> 3.13.0"`→`"~> 3.14"` and `ecto_sqlite3 "~> 0.22.0"`→`"~> 0.24"`;
  the stale insert/8 comment blocks dropped; the local path deps (`xqlite_ecto3`,
  `xqlite`) and the standalone-lock module comment kept. Lock refreshed via the
  sanctioned HEX_HOME (unlocked ecto/ecto_sql/ecto_sqlite3/exqlite + decimal — 3.14
  requires decimal ~> 3.0): ecto_sql 3.13.5→**3.14.0**, ecto 3.13.6→**3.14.1**,
  ecto_sqlite3 0.22.0→**0.24.1**, exqlite 0.37.0→**0.39.0**, decimal 2.4.1→**3.1.1**;
  rest unchanged. **Top-level `mix.lock` NOT touched** (`git status` clean on it);
  bench/ diff = only mix.exs + mix.lock.
- **Compile exit 0** (`MIX_ENV=prod MIX_OS_DEPS_COMPILE_PARTITION_COUNT=1
  XQLITE_BUILD=true mix compile` in `bench/`): `xqlite_ecto3` (21 files) compiled
  against ecto_sql 3.14 — the exact prior failure point (`connection.ex:2112` unknown
  `:modifiers` key) is gone — plus exqlite 0.39.0 + ecto_sqlite3 0.24.1 + the xqlite
  NIF (release). **Smoke run exit 0** at the smallest integer budget
  (`BENCH_TIME=1 BENCH_WARMUP=0 BENCH_MEMORY_TIME=0 mix run bench.exs`): environment
  printed (xqlite 3.53.2 / exqlite 3.53.3, disclosed-not-equalized), all 8 scenarios
  produced benchee output, and the cancellation demo returned control in ~102 ms for a
  100 ms timeout. Per ledger-first protocol NO figures recorded here (numbers only go
  to the internal bench ledger from dedicated machines).
- **Methodology honesty re-verified** (edits touched only mix.exs+lock, not
  bench.exs/bench.ex): pragma-parity block intact (`@pragmas` journal_mode wal /
  cache_size -64_000 / busy_timeout 5_000 applied to BOTH repos + `apply_pragma_
  parity!` synchronous NORMAL + wal_autocheckpoint 1000), versions disclosed via
  `versions/0`, cancellation labeled a capability demo, ledger-first note in
  README/bench.exs. Closed BACKLOG [F-B10-1].

### Verdict + dryness

- 1 NEW S2 CONFIRMED+FIXED (F-B2-2, RED→green); 2 sanctioned gap-closures with
  evidence ([B9] CI-OFF lane, [F-B10-1] bench dep bump); G2 doc remainder closed.
  Zero new findings on B9 and B10. `mix verify` green at close (top-level).
- Dryness: **B2 — a NEW confirmed (F-B2-2) surfaced, so NOT a clean covering run —
  stays at 0 of 2, NOT DRY**; the runtime-escape fix re-wets B2 (re-wet list already
  includes any `escape_json_key`/`json_extract_path`/`dynamic_json_path` change).
  **B9 — event-surface re-drive CLEAN (0 new findings), first clean covering run over
  the Run-4 churn (1 of 2), NOT DRY**; this run's OWN CI-lane + `config/test.exs`
  env-var mechanism + smoke-test edits RE-WET the flag-config surface, so the owed
  second pass must re-cover the OFF/ON compile path + smoke. **B10 — methodology
  re-verified CLEAN (0 new findings), F-B10-1 CLOSED, first clean covering run (1 of
  2), NOT DRY**; the dep bump (its own re-wet trigger) re-wets B10 → the owed second
  pass re-covers the new ecto_sql-3.14 / ecto_sqlite3-0.24 stack.
- Completeness critic: (1) F-B2-2's fix is a strict improvement (dot/backslash/quote
  runtime keys now all resolve; the documented double-quote caveat is gone) — the only
  residual JSON-path limitation is a runtime key value that is itself a control char
  outside `\`/`"`, none observed problematic. (2) B9 residual: the `XqliteEcto3.
  Telemetry` moduledoc "Event surface" list omits the `fk_diagnostics` span, but that
  event IS fully documented (trigger + `mode`/`violations_count`/`diagnostics_status`
  metadata) in the canonical `guides/wiring_telemetry.md` table and mapped generically
  by the OTel translator — an opt-in feature event; a moduledoc/guide asymmetry, not a
  contract gap, so NOT filed (minimal-diff; the user-facing guide is complete). (3)
  The telemetry-OFF lane proves the no-op path COMPILES + a query flows through +
  no adapter event fires; it does not exhaustively drive every OFF emission site (one
  representative `handle_execute` span) — adequate for a smoke, deeper OFF coverage is
  unwarranted (the macro no-op is uniform). (4) B10's smoke used the smallest integer
  budget (BENCH_TIME=1; the knob is `String.to_integer`, so sub-second is impossible
  without editing the harness) and did NOT record figures — reproducibility of any
  published number still depends on a dedicated quiet machine per the bench README.
  The owed SECOND clean covering pass on B9/B10 and the still-owed first clean run on
  B2 remain for the next dryness lap.

---

## Remedies — 2026-07-21 — maintainer rulings (F-B3-2 doc, F-B8-3 doc, A4 structural preservation)

Three open backlog items ruled on by the maintainer (Dimi) and implemented in one
pass. Single Opus implementer; every runtime claim below produced THIS session
(scripts under scratchpad, driven via `mix test` / `mix run`; RED demonstrated by
`git stash`-ing only the engine change and re-running the committed suite). Base
commit `2efbaa1`; deps at xqlite 0.10.0 (`XQLITE_PATH` unset).

### F-B3-2 — cold-start WAL-flip boot-log burst (DOC-ONLY, ruled)

Ruling: documentation remedy, no code change. Skip-when-already-WAL changes nothing
— a fresh, never-WAL file must flip `journal_mode=wal` on first boot regardless, and
later boots are already no-op clean. Implemented: a README "First-boot WAL noise on a
fresh database" section (under Design notes, after "Living with a single writer")
stating the symptom (`[error] … failed to connect: {:database_busy_or_locked, 5,
"database is locked"}` burst when a boot migration holds the write lock while the pool
flips WAL on a fresh file), why it is harmless (self-healing, queries succeed, WAL
persists so later boots are clean, no query caller sees an error), and the three
mitigations (run migrations before starting the app pool; pre-create the database with
WAL set; raise the connect `busy_timeout`). BACKLOG [F-B3-2] → Closed.

### F-B8-3 — pooled-timeout connection recycling (DOC-ONLY, ruled)

Ruling: one honest doc line, no code change (standard DBConnection behavior, not an
adapter defect). Added to the README timeout→cancel divergence section ("Cancel tokens
wired to `:timeout`"): a pooled query `:timeout` ALSO trips DBConnection's own checkout
deadline (same value), which disconnects+reconnects that connection, so
connection-local state — temp tables, session PRAGMAs, the prepared-statement cache —
does not survive a timeout and there is a reconnect cost; this is how every
DBConnection adapter behaves on the operation deadline; the graceful cancel's value is
that the blocked query returns AT the deadline instead of running to completion first.
BACKLOG [F-B8-3] → Closed.

### A4 — faithful rebuild preservation, STRUCTURAL scope (ruled)

Ruling: replace the blanket refusal with faithful preservation of everything SQLite
exposes STRUCTURALLY, keeping the loud refusal only for text-only constructs; NO
hand-rolled parsing of CREATE TABLE text beyond the existing word-boundary scans.

Implemented in `lib/xqlite_ecto3.ex`:

- `fetch_foreign_keys!/3` reads `PRAGMA foreign_key_list`, groups rows by `id` and
  orders by `seq`, and emits table-level `FOREIGN KEY (cols) REFERENCES target[(cols)]
  [ON DELETE …] [ON UPDATE …]` clauses via `foreign_key_clause/2`. Default `NO ACTION`
  and `NONE` MATCH are omitted; a NULL `to` emits `REFERENCES target` with no column
  list (implicit-PK reference). `fk_target/2` rewrites a SELF-reference to the transient
  `<table>__xqlite_new` name so dropping the original cannot cascade (or restrict) into
  the freshly-copied rows — `ALTER TABLE … RENAME` then rewrites the target back to the
  final name.
- `fetch_unique_constraints!/3` reads `PRAGMA index_list` origin `u` rows, gets their
  columns from `PRAGMA index_info` ordered by seqno, and emits `UNIQUE (cols)` clauses.
  Origin `pk` skipped (carried by column info); origin `c` skipped (re-created as a
  standalone index already).
- `create_rebuild_table_sql/3` appends the reconstructed table-level constraints after
  the column defs.
- `unpreservable_constraint/1` DROPPED the `REFERENCES` and `UNIQUE` scans (now
  preserved) and ADDED `\bDEFERRABLE\b` → "DEFERRABLE foreign keys" and
  `\bON\s+CONFLICT\b` → "ON CONFLICT clauses" (the structural pragmas expose neither the
  deferral timing nor the conflict algorithm, so those would silently drop). CHECK,
  COLLATE, and generated-column detections unchanged; refusal message updated to name
  only the still-unsupported constructs and still points at `execute/1`.

Dance-mechanics discovery (my own probes; recorded because they drove the design):
- `defer_foreign_keys=ON` defers only the enforcement CHECK, NOT referential ACTIONS —
  a deferred `DELETE FROM parent` still cascades to children immediately (probed).
- `PRAGMA foreign_keys=OFF` is a NO-OP inside a transaction (value stayed 1; child
  cascaded); it takes effect only OUTSIDE the txn. Ecto runs each migration inside a
  transaction that itself runs in a spawned `Task` (`migrator.ex` `Task.async |>
  Task.await`), so the adapter cannot toggle `foreign_keys` on that connection via
  `lock_for_migrations` (different process/connection). `legacy_alter_table=ON` is
  likewise a no-op inside the txn (the rename still rewrote an external child's FK).
- Consequence: the transient-name self-reference trick is the fix that works WITHOUT
  disabling foreign keys — verified: self-ref CASCADE rebuild preserves all 3 rows,
  fk_check clean, target correctly restored to the final name, orphan rejected, cascade
  fires on root delete; mutual NO-ACTION rebuild preserves both rows.

A4 preservation evidence — the 9-point matrix, each expected-vs-actual (live via real
`Ecto.Migrator` migrations against the non-sandboxed `PoolRepo`; the sandbox is
unusable here because the rebuild's `defer_foreign_keys` never resets under an
uncommitted sandbox txn, so FK enforcement would stay deferred):

1. Single FK `ON DELETE CASCADE` — rows survive (1), FK present targeting parent with
   CASCADE, fk_check clean, orphan REJECTED (`:constraint_violation` /
   `%Error.Constraint{subtype: :constraint_foreign_key}`), parent delete cascades child
   to 0. Also `SET NULL` (parent delete → child.parent_id NULL) and `ON UPDATE CASCADE`
   (parent PK update → child FK column follows) each preserved + behaviorally verified.
2. Composite two-column FK — both rows (seq 0/1, from (pa,pb) → to (a,b)) preserved in
   order, fk_check clean, orphan rejected, composite cascade fires.
3. Implicit-PK reference (`REFERENCES parent`, `to`=NULL) — preserved as `REFERENCES
   parent` (no column list), fk_check clean, orphan rejected.
4. Incoming FK (child references the rebuilt PARENT) — after the parent's drop+rename
   dance the child's FK still targets `parent` (name restored), full `foreign_key_check`
   clean, a post-rebuild child insert enforces, orphan rejected, a working cascade fires
   from the rebuilt parent. (Limitation, below: pre-existing child ROWS are affected by
   the drop.)
5. Self-referencing FK — all 3 rows survive (temp-name trick), FK present targeting the
   table, fk_check clean, orphan rejected, root delete cascades the chain to 0.
6. Table-level UNIQUE (single `sku` + composite `(name,region)`) — both origin-`u`
   auto-indexes present on the rebuilt table; duplicate rejected with
   `%Error.Constraint{subtype: :constraint_unique, table: "rp_uq"}`, and
   `XqliteEcto3.Connection.to_constraints/2` still yields `[unique: "<table>_<col>_index"]`
   (a name usable by `unique_constraint/3`).
7. Still-refused set — CHECK, COLLATE, generated columns (existing) plus the two NEW
   triggers DEFERRABLE FK and `UNIQUE … ON CONFLICT REPLACE` each raise the loud
   `ArgumentError` before any destructive step; verified table left intact (CHECK still
   rejects, NOCASE still folds, generated columns still compute, deferrable FK still in
   `foreign_key_list`, `ON CONFLICT REPLACE` still replaces on duplicate).
8. Full existing rebuild-invariant suite green — `table_rebuild_test.exs` 11 passed
   (rows, batched changes, standalone index recreated + enforcing, AUTOINCREMENT
   sequence preserved, trigger recreated, flag-off refusal).
9. FK enforcement state — the dance leaves `PRAGMA foreign_keys` exactly as found
   (1 before, 1 after); a rebuild of a table whose rows reference each other (mutual
   1↔2) copies both without violating (fk_check clean, count 2), proving the copy order
   under `defer_foreign_keys` cannot violate.

Residual limitation (documented, not silently shipped): rebuilding a table that OTHER
tables reference with `ON DELETE`/`ON UPDATE CASCADE`/`SET NULL`/`SET DEFAULT` fires
those actions on the referencing rows when the old table is dropped (probed: incoming
CASCADE + pre-existing child row → child silently emptied); a `NO ACTION`/`RESTRICT`
incoming reference makes the rebuild FAIL LOUDLY and roll back (probed: raises "FOREIGN
KEY constraint failed", child rows intact). This is a hard SQLite constraint —
`foreign_keys=OFF` cannot be reached from inside the migration transaction, and the
referencing table is not part of the rebuild so its FK cannot be repointed. Rebuilding
the table that HOLDS a foreign key (including self-references) is always safe. Recorded
in README + moduledoc rebuild caveats and the BACKLOG closure.

RED→green: new `table_rebuild_preservation_test.exs` (+9, `async: true`, real
`Ecto.Migrator` migrations against `PoolRepo`, structured assertions). Against the
engine reverted to the old blanket refusal (`git stash` of only `lib/xqlite_ecto3.ex`)
the suite was **1 of 9 passed** — the 8 preservation scenarios all failed on
`ArgumentError "… declares foreign-key constraints …"`; with the engine restored, **9
of 9 passed**. `table_rebuild_test.exs` refusal describe updated (FK + inline-UNIQUE
refusal tests removed — those now preserve; DEFERRABLE FK + `ON CONFLICT` refusal tests
added), 11 passed.

Docs flipped from "refusal is absolute" to structural preservation: README (Features
rebuild paragraph + Design-notes "Migration rebuild is opt-in") and the `XqliteEcto3` +
`XqliteEcto3.Migration` moduledocs now state FKs and UNIQUE survive (with actions /
implicit-PK / composite), while CHECK/COLLATE/generated/DEFERRABLE/ON-CONFLICT refuse
with `execute/1` as the escape hatch; the referenced-table cascade caveat is documented.

`mix verify` GREEN at close (format, warnings-as-errors compile, deps.audit, sobelow,
dialyzer, full `test.seq` suite). BACKLOG [A4] → Closed (structural-preservation scope;
text-only residue stays refused by design). REVIEW_AXES B7 re-wet (rebuild engine
churned, stays 0-of-2, next covering pass reviews the preservation engine
adversarially); B3/B8 doc-only, re-wetter lists unchanged.

### A4 — orchestrator-gate correction (incoming cascade/set-action → loud refusal)

The orchestrator REJECTED the A4 disposition that DOCUMENTED the incoming-FK
action hazard as a residual foot-gun. That violated the ratified bar (silent data
loss never ships; unsupported cases refuse LOUDLY — the same principle behind the
two earlier rebuild findings). The hazard is now a loud PRE-FLIGHT refusal, not a
doc line: the "Residual limitation (documented…)" paragraph above is superseded —
the cascade/set-action case is refused, only the physics (why the drop would fire
the action inside the migration txn) remains true.

Fix (`lib/xqlite_ecto3.ex`, new `refuse_incoming_actions_on_populated!/3` called
in `rebuild_table` right after `refuse_unpreservable_constraints!`, BEFORE any
destructive step): a correlated table-valued pragma enumerates INCOMING FKs —
`SELECT m.name, fk."on_delete" FROM sqlite_schema AS m, pragma_foreign_key_list(
m.name) AS fk WHERE m.type = 'table' AND lower(fk."table") = lower(?1) AND
lower(m.name) <> lower(?1) AND fk."on_delete" IN ('CASCADE','SET NULL','SET
DEFAULT')`. The `lower(...)` match honors SQLite's case-insensitive table names;
`m.name <> ?1` drops self-references (already safe via the transient-name trick).
For each distinct hit, `table_has_rows?/3` runs `SELECT 1 FROM "<ref>" LIMIT 1`
(inside the migration txn → consistent snapshot); any populated referencing table
raises `ArgumentError` naming the rebuilt table, the referencing table(s), and the
action, pointing at the escape hatch (empty/drop the referencing rows, or
`execute/1`). ON UPDATE is intentionally NOT scanned — the drop's implicit DELETE
fires only ON DELETE actions. Empty referencing tables proceed (action is a no-op
on zero rows), keeping fresh-schema / populate-after flows working; RESTRICT/NO
ACTION incoming refs get no new logic (they already fail loudly on the drop).
`table_has_rows?/3` carries `# sobelow_skip ["SQL.Query"]` (unavoidable table-name
interpolation; the name is an existing `sqlite_schema` row); the enumerate query is
fully parameterized. Detection idiom pre-verified against the bundled SQLite 3.53.2
(CASCADE detected, case-insensitive match confirmed, self-ref + NO ACTION excluded).

RED→green (`table_rebuild_preservation_test.exs`, +2 tests, real `Ecto.Migrator`
alter migrations against the non-sandboxed `PoolRepo`, raw-query setup so the
refusal's rollback leaves the setup rows intact): against the CURRENT working-tree
engine (before this fix) both new tests were RED — `assert_raise ArgumentError`
reported **"Expected exception ArgumentError but nothing was raised"** (9/11 file
total), proving the drop silently cascaded/nullified the populated child; after the
fix **11/11**. (1) populated child `ON DELETE CASCADE` → parent rebuild REFUSES
naming `rp_pc_child`, both parent+child rows intact (count 1/1), FK still enforced
(orphan rejected, fk_check clean). (2) populated child `ON DELETE SET NULL` →
REFUSES naming `rp_ps_child`, child `pid` unchanged (still 1), parent intact. The
EMPTY-child incoming-FK scenario (existing `IncomingFkMigration`, child populated
only AFTER the rebuild) stays green — the rebuild PROCEEDS, proving empty
referencing tables are fine. `table_rebuild_test.exs` unchanged, still 11/11.

Docs flipped from "documented cascade caveat" to "populated-referencing-table
refusal": README both rebuild sections (also corrected the earlier `ON UPDATE`
over-claim — only `ON DELETE` fires on drop) + `XqliteEcto3` / `XqliteEcto3.Migration`
moduledocs. BACKLOG [A4] closure amended (incoming-FK limitation → resolved-by-refusal);
REVIEW_AXES B7 re-wet note extended (pre-flight now also scans incoming FKs).
`mix verify` GREEN at close.

---

## Run 9 — 2026-07-21 — dryness lap 2, batch 1: X1 + B1 + X2

- Commit at scan: `6539a14` (clean tree; the remedies CI run GREEN incl. the
  telemetry-OFF lane, re-confirmed at session start). Deps at xqlite 0.10.0
  (`mix.lock` pin + `deps/xqlite` verified 0.10.0; `XQLITE_PATH` unset). Single
  Opus reviewer; the orchestrator INDEPENDENTLY re-ran all three runtime probes
  (scratchpad `run9/`: classification, edge, JSON-SQL census — all exit 0) and
  re-checked the call-site-churn grep, the forward-commit diffs, and the
  `error.ex` clause order against source (subagent runtime claims inadmissible
  until re-run).
- Scope: covering re-run over the adapter churn `5a411ee..6539a14` (15 commits:
  Runs 6–8 fixes + the three maintainer remedies), adversarial priority on the
  churn, plus a fresh forward xqlite walk `v0.10.0..80210b6` (7 commits — two
  newer than Run 5's walk).

### X1 — API/error-shape contract (PRIMARY; the owed pass over the new wrap/1 clauses)

The three tag-preserving `wrap/1` clauses (`2a9089a`, `error.ex:212-222`)
adversarially covered. Clause-ordering shadowing traced across all 11 clauses:
every dedicated clause (constraint `:152`, sqlite_failure `:169`, sql_input
`:177`, busy-set 3-tuple `:190`, utf8 `:200`, binary-payload 2-tuple `:204`)
precedes the generic 2/3/4-tuple clauses; the binary-payload and tag-preserving
2-tuple clauses are mutually exclusive via `is_binary`; the only dedicated
map-payload 2-tuple (`:sql_input_error`) matches first by source order — no
shadowing. Classification map re-derived against `error_reason/0` @0.10.0 AS
COMPILED: 7 bare atoms / 8 dedicated / 17 binary-payload / 14 tag-preserved =
46 distinct shapes (Run 5's "48" counted probe invocations, not shapes), and
driven LIVE — every tag preserved, zero `type: nil`, `to_constraints/2`
spot-checks correct (unique → `[unique: "t_c_index"]`, busy → `[]`). Edge probe:
non-atom heads / 5-tuple / 1-tuple / empty tuple / bare string all degrade to
`type: nil` without crash; the 2–4 arity bound is exactly the union's span, atom
heads throughout, `is_atom` adequate. Rebuild-engine raises through the X1 lens:
the pre-flight refusals (`lib/xqlite_ecto3.ex:687/:762/:792`) are `ArgumentError`
inside migration DDL — the sanctioned exception, correctly NOT `Error.wrap`
paths; a rebuild statement failing at RUNTIME surfaces a structured
`%XqliteEcto3.Error{}` via `query!` — doctrine honored. DecimalPrecisionError
encode-raise byte-identical (churn diff empty on `query.ex` /
`decimal_precision.ex` / `driver.ex`). FORWARD blast (all 7 commits):
`error_reason/0` grew ADDITIVELY only (+`:extension_loading_disabled`
+`:invalid_conflict_strategy` in `dd7c9f9`, both bare atoms, atom-clause-
classified, both adapter-unreachable — grep-confirmed no `load_extension`/
session call sites); `error.rs` + `constraint_parse.rs` zero change; `nif.rs` =
the known 20 DirtyIo attribute-only flips; `util.rs`/`pragma.rs` `encode_val`→
Result threading keeps the success shape byte-identical (OOM path degrades to
`:internal_encoding_error`, already in the union); `8715270` = SAFETY comments
only; `0f81e75`/`80210b6` diff-verified ledger+probe-script only (no
lib//native/). Zero new findings.

### B1 — behaviour conformance from source

The runtime JSON-path escape fix (`53599f4`, `connection.ex:2269-2293`) verified
as a SQL.Connection product via live `to_sql` census: the runtime branch emits
`'."' || replace(replace(seg, '\', '\\'), '"', '\"') || '"'` —
backslash-before-quote, mirroring `escape_json_key` (`connection.ex:2248-2253`)
— and mixed literal+runtime paths escape each segment INDEPENDENTLY under `||`
in both compose orders (literal-then-runtime and runtime-then-literal probed;
no double-escape). `driver.ex` (finish_cached_stmt / disconnect) untouched in
the churn — Run 5's shape verification stands. Rebuild-engine Migration
conformance from deps/ecto_sql SOURCE: `execute_ddl` returns `{:ok, []}`
(migration.ex:61 contract), `lock_for_migrations` returns `fun.()`; both
pre-flight refusals run only READ queries before the destructive statement
list (`lib/xqlite_ecto3.ex:697-698` vs `:710-725`). `config/test.exs`
telemetry flag (`81d02ae`) defaults ON when the env var is unset —
behaviour-neutral (gates emission only, no callback contract touched). Live:
JSON/rebuild/migration test clusters green (24 + 40). Zero new findings.

### X2 — cross-repo blast radius

Surface re-enumerated at `6539a14` (Run 5 method, reproducible rg over
`lib/**/*.ex`): **38 XqliteNIF-family + 7 Xqlite.\*** — identical to the
`5a411ee` baseline; `git diff 5a411ee..6539a14 -- lib/` contains ZERO added or
removed `XqliteNIF.`/`Xqlite.` lines (orchestrator re-grepped). The rebuild/
preservation engine's 13 raw-SQL sites (e.g. `lib/xqlite_ecto3.ex:725/:729/
:803/:896/:917`) all route through `Ecto.Adapters.SQL.query!/4` (or `query`) →
the adapter's own `handle_execute` → the already-mapped `query_with_changes`
blast-radius row; no new XqliteNIF/Xqlite site, no new row needed. Forward-delta
walk through the Run 1 table row by row: only the "all error reasons" row moved,
additively (+2 adapter-unreachable bare atoms); every result-map row
(query_with_changes/stmt_multi_step/query/stream_fetch/txn_state), every
sentinel (`:done`/`:multiple_statements`/`:cannot_execute`), and every
txn/pragma/open row UNTOUCHED. Zero new findings.

### Verdict + dryness

- 0 new findings at any severity; zero repo edits from the review (working tree
  stayed at `6539a14`). `mix verify` GREEN — the orchestrator's OWN run
  (VERIFY_EXIT=0, full `test.seq` "All tests passed!").
- Dryness: **B1 DRY (2 of 2)** and **X2 DRY (2 of 2)** — the program's first two
  DRY axes. **X1 NOT DRY (1 of 2)** — first clean covering run over its own
  lap-1 `wrap/1` churn; the owed second pass goes to the mini-lap. Re-wetters
  unchanged on all three.
- Completeness critic: (1) pre-existing typespec looseness — the busy-set
  (`error.ex:197`) and utf8 (`:201`) clauses put bare maps in `details`, outside
  `@type details` (`:140`); `wrap/1` has no `@spec` so dialyzer is silent; the
  `type` field is correct and `to_constraints/2` unaffected, so not a
  misclassification — candidate tighten for the X1 mini-lap pass. (2)
  pre-existing destructuring match `{:ok, %{rows: rows}} =
  Ecto.Adapters.SQL.query(...)` in `fetch_existing_columns!`
  (`lib/xqlite_ecto3.ex:592`, commit `2124dba`) — same class as backlog B1-1;
  appended there. (3) the forward busy `max_elapsed_ms` change (`c24383b`) is
  BEHAVIORAL and unreachable at the pinned 0.10.0 dep — the dep-bump re-probe
  disposition from Run 7 stands. (4) rebuild-dance deep semantics, JSON
  behavioral fidelity, and telemetry event behavior deliberately untouched —
  owed to B7 (batch 3) and B2/B9 (batch 4) lenses.
