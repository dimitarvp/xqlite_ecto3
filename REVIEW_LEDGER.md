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
| `PRAGMA busy_timeout` via `query` | the integer VALUE, reused as the unique-name lookup's wall-clock budget (0 = uncapped since Run 26) | `unique_index_names.ex` `busy_budget/1` | **SILENT** — any xqlite busy-slot change that alters the reported value shifts lookup budgeting (added Run 26, F-X2-2) |

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

---

## Run 10 — 2026-07-21 — dryness lap 2, batch 2: B6 + B5 + B3

- Commit at scan: `6539a14` (HEAD `76b0890` is docs-only above it — verified by
  diff). Deps at xqlite 0.10.0 (`XQLITE_PATH` unset, `mix.lock` pin verified).
  Single Opus reviewer; the orchestrator INDEPENDENTLY re-ran ALL 12 runtime
  probes (scratchpad `run10/`), ran the F-B5-2 deciding probe itself, and
  reviewed the two test-file diffs line by line.
- Scope: covering re-run over the churn `dec4469..6539a14` (13 commits; per-axis
  attribution by git log — `connection.ex` touched ONLY by `53599f4`;
  `to_constraints/2`/`fk_diagnostics.ex`/`driver.ex` all UNCHANGED in range).
- GATE NOTE (probe harness, not the adapter): the orchestrator re-run exposed
  two B5 probes as NON-IDEMPOTENT — `:erlang.unique_integer([:positive])`-based
  tmp DB names are near-deterministic across fresh VMs, so a re-run VM
  regenerated an EARLIER agent VM's "unique" filename, hit its already-applied
  migration, and died with `:already_up` (proven by dumping `schema_migrations`
  from the colliding files). Scripts patched to wall-clock-ns names +
  pre-clean; both re-run green (6/6, PASS). Probe VALIDITY unaffected — the
  agent's assertions ran on files its own VM had freshly created. Standing
  lesson for future probe prompts: tmp names must be wall-clock-unique.

### B6 — query translation (the JSON-escape churn, RESULTS lens)

Run 9 verified the emitted SQL shape; this pass owned RESULTS. Runtime keys via
`d.meta[d.label]` — dot, backslash, double-quote, single-quote, unicode (café,
naïve日本), digit-string "123" (object key, NOT array index — `typeof('text')`
routing), empty string — plus mixed literal+runtime paths in BOTH orders: 11/11
return the expected value, never silent nil; raw `json_extract` ground truth
confirms SQLite resolves `$.""`, `$."123"`, `$."it's"`. Escape-order crux: keys
containing BOTH backslash and quote (`a\"b`, `x\\y`, `q"\r`) all resolve — the
backslash-first `replace(replace(…))` order holds under composition (3/3).
Emission helpers `escape_string`/`limit`/`quote_entity` byte-unchanged in range,
so the Run-6 wrong-results seeds were re-anchored targeted (11/11: count(col)
skips NULL, sum over NULLs, `NOT IN [1,nil]` → [], LIKE ASCII-only fold
(zebra↔ZEBRA yes, äpfel≠Äpfel), `LIMIT -1` on bare offset, single-paren
`exists(SELECT`, ON CONFLICT expression-target dedup) + 85 committed anchors.
Durable coverage: `json_extract_path_test.exs` +5 (single-quote / digit-string /
empty-string runtime keys, both mixed orders). Zero new findings.

### B5 — constraint mapping (rebuilt-UNIQUE end-to-end + a new S3)

`to_constraints/2` (`connection.ex:102-162`) and `fk_diagnostics.ex` UNCHANGED
in range; the churn is the A4 engine reconstructing UNIQUE as table-level
clauses backed by `sqlite_autoindex_*`. Proven END-TO-END through real
`Ecto.Migrator` + changesets on a rebuilt table (the Remedies evidence had
stopped at `to_constraints/2` output): `unique_constraint(:sku)` converts to
`{:error, changeset}` with `constraint_name: "rp_uq_sku_index"`, and the
composite `unique_constraint(:name, name: "rp_uq_name_region_index")` converts
on `:name` — the autoindex name is transparent because SQLite's violation
message carries the table.column form and the adapter derives the conventional
`<table>_<cols>_index`. Column order: a reverse-declared `UNIQUE(region, name)`
derives `rp_uq2_region_name_index` (declaration order via `index_info` seqno,
not alphabetical). Standing subtypes re-anchored live (4/4): rowid PK +
WITHOUT ROWID PK derive; partial unique index → table.column form → derived
conventional name (matches Ecto's default `unique_constraint` name); expression
unique index → `index 'name'` message form → `index_name` direct path.
Reconnect-enforcement contract test green. Durable coverage:
`table_rebuild_preservation_test.exs` UNIQUE test extended with both changeset
conversions (structured assertions on `constraint: :unique` +
`constraint_name`).

- **F-B5-2 (S3, CONFIRMED, BACKLOG).** Surfaced by this run's subtype probes;
  settled by an ORCHESTRATOR deciding probe (`orch_b5_custom_name_probe.exs`):
  a CUSTOM-named plain (or partial) unique index cannot be matched by its
  declared name — the violation message carries table.column, the adapter
  derives the conventional name, so `unique_constraint(:v, name: :my_custom)`
  never matches and Ecto raises `Ecto.ConstraintError` (type `:unique`,
  violated `"items_v_index"`); the CONTROL with the derived name converts to a
  changeset error on the same table. Loud, not silent; expression indexes DO
  round-trip their real name. Remedy (document the naming contract vs
  synthesize the name from `index_list` over the violated columns — ambiguous
  when several unique indexes cover them) = maintainer call.

### B3 — sandbox + pooling (standing surface + the owed owner-death angle)

Connect with-chain (`driver.ex:54-88`) UNCHANGED in range (git log empty; the
F-B3-2 remedy was README-only). Five probes, all deterministic (exact counts,
monitors, bounded polling, ceilings ≥10×), all PASS on both the reviewer's and
the orchestrator's runs: cold-start PRAGMA storm (pool 12, fresh non-WAL file,
300 immediate inserts → 300/300, 0 errors, wal after); hot-row busy storm
(pool 10, 200 concurrent txns on ONE row → exactly 200, pool healthy); forced
busy (200 ms vs held lock → structured `{:database_busy_or_locked, …}`,
writable after); sandbox `{:shared, owner}` + `allow/3` bidirectional with
rollback isolation; NEW angle — mid-transaction owner `:kill` → uncommitted
write rolled back (count 0), pool healthy (60/60 after), no wedge. Zero new
findings. F-B3-1 unchanged (backlog, maintainer call).

### Verdict + dryness

- 1 new CONFIRMED S3 (F-B5-2 → BACKLOG, maintainer remedy). 0 new S0–S2. Two
  test files hardened (+5 JSON-path tests, +changeset conversions in the
  rebuild preservation suite). `mix verify` GREEN — the orchestrator's OWN run.
- Dryness: **B6 DRY (2 of 2)** — third DRY axis. **B5 resets to 0 of 2, NOT
  DRY** — a new confirmed finding surfaced (the reviewer's DRY proposal was
  OVERRULED at gate; same precedent as F-B3-2/F-B4-1: a finding-run is not a
  clean run, churn-origin notwithstanding). **B3 → 1 of 2, NOT DRY** — first
  clean covering run.
- Completeness critic: B6 window-frame semantics / NOCASE collation / typed
  `type(...)` extraction unchanged since Run 6 and not re-driven (committed
  tests cover; deep NULL-in-window remains an unlived Run 6 residual). B5
  origin-`c` unique-index recreation through rebuild rests on
  `table_rebuild_test.exs` (not re-driven here). B3 mini-lap seeds: DBConnection
  checkout-timeout × busy-storm interaction; sandbox ownership vs the rebuild
  engine's documented non-sandbox requirement (`defer_foreign_keys` never
  resets under an uncommitted sandbox txn). Probe-harness lesson recorded in
  the gate note above.

---

## Run 11 — 2026-07-21 — dryness lap 2, batch 3: B7 (PRIMARY) + B8 + B4

- Commit at scan: `d26097f` (code state == `6539a14`; the two tips above it are
  ledger docs + test-only, diff-verified). Deps at xqlite 0.10.0 (`XQLITE_PATH`
  unset, `mix.lock` pin verified). Single Opus reviewer; the orchestrator
  INDEPENDENTLY re-ran all 7 probe scripts (fresh VMs, scratchpad `run11/`),
  re-grepped the zero-churn claims for B8/B4 surfaces, reviewed the engine diff
  line by line, and reproduced the RED leg itself (`git stash` of only
  `lib/xqlite_ecto3.ex` under the new tests → **11/15 failed exactly the 4 new
  tests**; fix restored → **15/15**).
- Scope: churn `828bb95..6539a14`; B7 = the owed adversarial pass on the A4
  preservation engine (landed by maintainer ruling, never adversarially
  reviewed until now — the pass Remedies explicitly owed).

### B7 — migration ergonomics (PRIMARY): the engine BROKE three ways, all fixed

- **F-B7-3 (S1, CONFIRMED + FIXED, RED→green).** Composite PRIMARY KEY silently
  narrowed: `existing_to_column` emitted inline `PRIMARY KEY` only for the
  column with `table_xinfo.pk == 1`, so rebuilding a `PRIMARY KEY (a, b)` table
  produced a single-column key — an integrity constraint silently WEAKENED and
  legitimate composite rows rejected (probe: `(1, 99)` refused post-rebuild;
  reverse-declared `PRIMARY KEY (b, a)` came back `["b"]`). Fix:
  `plan_new_schema` computes pk members by position; more than one suppresses
  the inline PK and emits a table-level `composite_pk_clause` over the
  SURVIVING members in declared order; a single-column key stays inline
  (preserving the INTEGER-PK rowid alias + AUTOINCREMENT). Durable test asserts
  order `["b", "a"]`, composite inserts accepted, exact duplicates rejected.
- **F-B7-4 (S1, CONFIRMED + FIXED, RED→green).** `WITHOUT ROWID` and `STRICT`
  table options silently dropped: `create_rebuild_table_sql` emitted a bare
  CREATE with no option tail and no scan covered them (no structural pragma
  exposes either). Probes: a rebuilt WITHOUT ROWID table GAINED a rowid; a
  rebuilt STRICT table ACCEPTED `'not-an-int'` into an INTEGER column. Fix:
  `unpreservable_table_option/1` scans the tail after the FINAL `)` — table
  options carry no parentheses, so the boundary is unambiguous and a column
  merely NAMED `strict`/`rowid` cannot false-positive — refusing loudly before
  any destructive step. Durable tests assert the refusal AND the post-state
  (rowid still absent / strict still enforcing / rows intact).
- **F-B7-5 (S2, CONFIRMED + FIXED, RED→green).** Identifier and literal quoting
  in rebuild DDL did not escape embedded quotes: `quote_name` and several raw
  `"#{name}"` interpolations left an embedded `"` undoubled (malformed DDL —
  loud — on exotic names), and `restore_autoincrement_sql` inlined the table
  name into a `'…'` literal unescaped (a constructible SILENT widening of the
  sqlite_sequence DELETE for a crafted AUTOINCREMENT table name). Fix:
  `quote_name` doubles `"`; new `quote_string` doubles `'`; every rebuild DDL
  fragment (CREATE/INSERT-copy/DROP/RENAME/sequence restore) routed through
  them; transient name centralized in `transient_name/1`. Durable test
  round-trips a `we"ird` column with data.
- **F-B7-6 (S3, CONFIRMED, BACKLOG — filed, not fixed).** The `ON CONFLICT`
  refusal scan misses a comment interposed between the keywords: SQLite stores
  CREATE text verbatim, so `x INTEGER UNIQUE ON /* c */ CONFLICT REPLACE`
  defeats `\bON\s+CONFLICT\b` and the conflict algorithm would silently drop.
  Reachability ≈ nil (a comment BETWEEN the two keywords; the other scanned
  constructs are single-token and immune) and comment-stripping risks its own
  bugs — backlog, maintainer taste.
- Clean re-anchors: mid-dance failure atomicity — a post-drop failure rolls the
  whole migration txn back and fully restores a PRE-EXISTING table (the
  reviewer's first atomicity probe was mis-designed — table created inside the
  same migration, so full rollback correctly removes it; re-designed probe
  PASS); generated columns hidden 2 AND 3 both refused; FK `MATCH FULL`
  reported as `NONE` by `foreign_key_list` (MATCH is inert in SQLite — dropping
  it is semantics-preserving); composite-FK / self-ref / incoming-FK / UNIQUE
  preservation suites green. Docs (README both rebuild sections +
  `XqliteEcto3` / `Migration` moduledocs) updated: composite PK now listed as
  preserved, WITHOUT ROWID / STRICT added to the refusal list.

### B8 — timeout→cancel divergence

`driver.ex` / `query.ex`: ZERO commits in range (orchestrator-grepped). Core
re-driven live (`probe_b8_core.exs`, orchestrator re-run exit 0): baseline
~3465 ms query; cached-path timeout 100 ms → 101 ms structured
`%DBConnection.ConnectionError{}`; one-shot path (`statement_cache_size: 0`) →
101 ms; pool/conn reusable after both; in-txn timeout leaves
`txn_state {:ok, :write}`, rollback + reuse work; encode-raise creates no
canceller (process delta 0), no mailbox leak, cancel path works right after.
`cancellation_test.exs` 11 green. Zero new findings.

### B4 — type round-trips

`data_type.ex` / `decimal_precision.ex` / `query.ex` / loaders-dumpers: ZERO
commits in range (orchestrator-grepped). Matrix + guard table + one-way pins =
55 green; decimal `stream_data` property green across 10 fresh seeds; fresh
6-value guard cross-check (guard ⟺ repo round-trip ⟺ raw typeof) fully
consistent — incl. `1.2345678901234567` (17 sig digits, genuinely
float64-exact, correctly ACCEPTED — the guard is representability-exact, not a
digit counter), 2^52 / 2^-13 accepts, 18/19-sig rejects
(`probe_b4_guard.exs`, orchestrator re-run exit 0). Zero new findings.

### Verdict + dryness

- 3 new CONFIRMED fixed (2× S1 + 1× S2, all in the UNPUBLISHED rebuild engine)
  + 1 new S3 filed (F-B7-6). `mix verify` GREEN — the orchestrator's OWN run
  (VERIFY_EXIT=0, full `test.seq`).
- Dryness: **B8 DRY (2 of 2)** and **B4 DRY (2 of 2)** — five DRY axes total
  (B1, X2, B6, B8, B4). **B7 stays 0 of 2, NOT DRY** — three new confirmed;
  the fixes re-wet; the next covering pass reviews the composite-PK/options-
  scan/quoting fixes adversarially.
- Completeness critic (mini-lap seeds): (1) DESC or per-column COLLATE inside a
  table-level UNIQUE — `index_info` exposes neither; COLLATE is caught by the
  CREATE-text scan upstream, but a DESC-in-UNIQUE would silently flatten to ASC
  (uniqueness semantics unchanged, sort order lost — probe to conclusion). (2)
  Composite PK where a `:remove` drops a member — the fix emits the key over
  survivors (reasoned, not tested; a refusal might be the better semantics —
  maintainer taste). (3) Non-ASCII-case incoming-FK table matching (`lower()`
  is ASCII-only) unprobed. (4) A pre-existing `<name>__xqlite_new` collision
  should fail loudly at CREATE before any destructive step — unverified live.

---

## Run 12 — 2026-07-21 — dryness lap 2, batch 4: B2 + B9 + B10

- Commit at scan: `458dc0c` (clean at start). Deps at xqlite 0.10.0
  (`XQLITE_PATH` unset, `mix.lock` pin verified). Single Opus reviewer; the
  orchestrator INDEPENDENTLY re-ran the deciding probes and both post-fix
  suites, the full OFF/ON flag-bleed script, and the bench compile+smoke
  (scratchpad `run12/`, all exit 0), reviewed all three diffs line by line,
  and attempted its own RED for the telemetry flake (below).
- Scope: churn `811d544..458dc0c` (11 commits), attributed per axis; emission
  surfaces, bench methodology files, and `test_helper.exs` all have ZERO
  commits in range (git-confirmed).

### B2 — exclusion-list audit (a stale exclusion falsified empirically)

Drift reconciled (19 = 14 tags + 5 locations at scan; `test_helper.exs`
unchanged in range; tags-doc delta = Run 8's two corrections).
`type.exs:362` un-excluded fails ONLY at its documented boolean line (384);
all JSON-path SELECTs before it pass — the F-B2-1/F-B2-2 escapes hold under
this lens. Fresh spot-isolations: on_delete_nilify_column_list (loud
ArgumentError), map_type_schemaless (raw JSON TEXT, undecoded),
insert_cell_wise_defaults (uneven columns), assigns_id_type,
alter_primary_key, alter_foreign_key — all fail exactly as documented.

- **F-B2-3 (S2, CONFIRMED + FIXED).** `:like_match_blob` was excluded on the
  claim that the build carries `SQLITE_LIKE_DOESNT_MATCH_BLOBS` — the bundled
  3.53.2 does NOT (compile_options probe: absent, orchestrator re-run;
  `SELECT id WHERE b LIKE x'000102'` on a real BLOB column → `[[1]]`;
  `:binary` maps to BLOB). Both tagged `type.exs` tests pass un-excluded — a
  false "not supported" claim standing since Run 4, whose disposition method
  was "reasoned from source" (trusted the flag rationale, never verified the
  flag). Fix: exclusion removed (18 = 13 tags + 5 locations), tags-doc row →
  supported; the two tests now run in the suite (`mix verify` green includes
  them). Run-11 rebuild churn attribution: modify-only, un-staled no ALTER
  exclusion.

### B9 — telemetry (the owed flag-config pass + an async-safety fix)

Emission surface byte-unchanged in range. Flag-bleed disproven BOTH
directions (orchestrator re-ran the full script, exit 0): OFF
compile-force-w-a-e → OFF smoke (refute) → ON force-recompile → ON smoke
(assert_receive; emission RESTORED) → hardened cluster green (44 passed).
`config/test.exs` mechanism + the CI `telemetry_disabled` lane commands match
the locally proven pair; OTel mapping unchanged; `Application.compile_env`
gating means a stale flag raises rather than silently bleeding.

- **F-B9-2 (S3, CONFIRMED + FIXED — test-only).** `attach_capture` installs a
  process-global handler filtered by event name only; the two
  discriminator-free `:error` captures (handle_execute + connect) could grab
  a CONCURRENT test's `:ok` `:stop` first → `left: :ok, right: :error`
  (~25% flake when several telemetry files share one VM; ZERO impact on
  `test.seq`, one file per OS process; product classification correct —
  `classify_dbc` verified). Fixed by filtering each `:error` capture on its
  unique operation (its `sql` / its pinned `database`); these were the only
  two discriminator-free live-event `:error` captures (dedup by mechanism).
  RED evidence: the reviewer's recorded seed-999 cluster log shows the exact
  failure, and its deterministic foreign-`:ok`-injection probe reproduced it
  (temp test, deleted); the orchestrator's 3 stashed-cluster attempts did NOT
  flake (consistent with ~25%/run — P(miss all 3) ≈ 0.42) — accepted on the
  recorded log + mechanism code-read. GREEN: cluster 0/25 + file-alone 12/12
  under the orchestrator's own runs.

### B10 — benchmarks (the owed ecto_sql-3.14-stack pass)

Methodology files unchanged in range (bump touched only bench mix.exs+lock);
pragma parity / disclosed-not-equalized versions / cancellation-as-demo /
ledger-first all intact. Bench deps on disk match the bumped lock (ecto_sql
3.14.0, ecto 3.14.1, ecto_sqlite3 0.24.1, exqlite 0.39.0; no fetch needed).
Compile exit 0 + `BENCH_TIME=1` smoke exit 0 (orchestrator re-ran both) — all
8 scenarios + the cancellation demo produce output; NO figures recorded.
Rebuild fixes are migration-path only; bench scenarios touch no ALTER path.
Zero new findings.

### Verdict + dryness — LAP 2 COMPLETE

- 2 new CONFIRMED fixed this run (F-B2-3 S2, F-B9-2 S3-test-only). `mix
  verify` GREEN — the orchestrator's OWN run.
- Dryness: **B10 DRY (2 of 2)**. **B2 stays 0 of 2** (new confirmed + the
  exclusion-list change re-wets). **B9 RESETS to 0 of 2** — the reviewer
  proposed stays-at-1; overruled at gate (a finding-run breaks the
  consecutive-clean chain; same rule as B5/Run 10) — the flag-config pass
  itself was clean, so the owed re-cover is the hardened emission-test
  cluster plus the standing surface.
- **LAP 2 FINAL SCOREBOARD: 6/12 DRY — B1, X2, B6, B8, B4, B10.** Owed to
  the mini-lap: X1 (1 of 2), B3 (1 of 2), B9 (0 of 2), B2 (0 of 2), B5
  (0 of 2), B7 (0 of 2). Lap-2 yield: 6 new confirmed findings (2× S1 +
  2× S2 + 2× S3) — all S1/S2 fixed in-run — plus 2 S3s filed for maintainer
  taste (F-B5-2, F-B7-6) and one probe-harness defect caught at gate.
- Completeness critic (mini-lap seeds): (1) the two location-only exclusions
  (`alter.exs:44`, `logging.exs:74`) verified by code-read only — ExUnit 1.20
  crashes combining a CLI `location:` filter with configured tuple excludes;
  isolate via a transient test_helper edit. (2) The remaining
  "reasoned-from-source" tag exclusions are architectural type-absences
  (array/bitstring/duration/prefix/transaction_isolation/lock_for_migrations)
  — low-value to isolate but would fully close the reasoned-not-run gap
  F-B2-3 exposed. (3) F-B9-2 pattern breadth: `:ok`-asserting telemetry
  captures could latently mask foreign events (they pass regardless) — audit
  in B9's re-cover.

---

## Run 13 — 2026-07-21 — mini-lap batch 1: X1 + B3 + B9

- Commit at scan: `3c58c5c` (clean). Deps at xqlite 0.10.0 (`XQLITE_PATH`
  unset, `mix.lock` pin verified); reference `../xqlite` HEAD `80210b6`
  UNMOVED since Run 9 (orchestrator-confirmed). Single Opus reviewer; the
  orchestrator re-ran ALL 8 probe scripts fresh-VM (exit 0 each), reproduced
  the F-B3-3 RED/GREEN itself (below), and applied one gate ruling and one
  gate fix.

### X1 — API/error-shape contract (the owed second pass) → DRY

`error.ex` / `error_wrap_test.exs` / `to_constraints` untouched in range; the
46-shape map re-driven live 60/60 (tags preserved, zero `type: nil`, edges
degrade clean); rebuild ArgumentError paths = the sanctioned migration-DDL
exception; forward blast: xqlite HEAD unmoved, `error_reason/0`
byte-identical. Details-typespec looseness dispositioned ACCEPT (never
consumed; tightening = churn for zero gain). Zero findings. **DRY (2 of 2)** —
the program's seventh DRY axis.

### B3 — sandbox + pooling (the two owed seeds; one S2 found + fixed at gate)

`driver.ex` untouched; storms re-driven (300/300; exact-200). Seed (a)
checkout-timeout CLOSED CLEAN: 20/20 structured queue-wait
`%DBConnection.ConnectionError{}`, 0 crashes, pool recovers, holder commits,
no wedge.

- **F-B3-3 (S2, CONFIRMED + FIXED AT GATE, RED→green).** A rebuild migration
  under `Ecto.Adapters.SQL.Sandbox` succeeds but leaks
  `defer_foreign_keys = ON`: the rebuild sets the pragma
  (`lib/xqlite_ecto3.ex:715`) and relied on COMMIT's auto-reset, which never
  fires inside the sandbox's never-committing outer txn — a subsequent orphan
  FK insert is SILENTLY ACCEPTED (pre-rebuild control rejects; a non-sandbox
  control leaves the flag 0 and rejects — sandbox-specific; bounded to the
  session, a fresh checkout reads 0). The reviewer filed it for a maintainer
  remedy; the ORCHESTRATOR ruled at gate instead (the ratified bar does not
  let an S2 silent-enforcement-loss sit; the remedy space collapses to one
  bar-compliant option — doc-only violates the bar, refuse-under-sandbox
  detection is hackier for less): `rebuild_table` resets
  `PRAGMA defer_foreign_keys = OFF` after a clean `foreign_key_check` — a
  control-proven no-op on committing transactions (preservation suite 15/15
  unchanged) that also makes rebuilds VIABLE under the sandbox. RED→green
  entirely orchestrator-run: new `table_rebuild_test.exs` test on the
  sandboxed TestRepo RED at 11/12 (failing exactly on the leaked pragma) →
  fix → 12/12; the seed probe's verdict flips SILENT_WRONG_STATE → CLEAN.
  Maintainer may overrule (one-line revert).

### B9 — telemetry (hardened-cluster re-cover; one more capture hardened)

Emission surface byte-unchanged; cluster 86/86 × 8, file alone 12/12, fresh
event-surface probe 9/9, OTel path unchanged.

- **F-B9-3 (S3, CONFIRMED + FIXED, test-only).** The disconnect test asserted
  `reason == :normal` on an UNFILTERED process-global capture — a concurrent
  file's non-`:normal` disconnect false-fails it (deterministic injection
  probe CONFIRMED by orchestrator re-run; live 1/20 cluster flake observed by
  the reviewer). Same mechanism as F-B9-2, which had scoped only to the
  `:error` captures. Fixed by pinning `%{conn: ^conn}` in the receive
  pattern; 20/20 + 86/86×8 post-fix. The `:ok`-capture breadth audit
  dispositioned every other discriminator-free capture harmless
  (instance-invariant assertions only; begin/savepoint filter via `mode:`
  in-pattern) — written disposition, no churn.

### Verdict + dryness

- 1 S2 (fixed at gate) + 1 S3 (fixed) + zero on X1. `mix verify` GREEN — the
  orchestrator's OWN run.
- Dryness: **X1 DRY (2 of 2) → scoreboard 7/12 DRY (B1, X2, B6, B8, B4, B10,
  X1).** **B3 RESETS to 0 of 2** (finding-run; reviewer's stays-at-1 proposal
  overruled — chain rule as B5/B9). **B9 stays 0 of 2** (finding-run). Owed:
  B3, B9, B2, B5, B7 — all at 0 of 2, each needing two consecutive clean
  covering runs.
- Completeness critic: the F-B3-3 fix's pragma reset is per-rebuild — a
  multi-`alter` migration running several rebuilds resets after each clean
  check (correct but unprobed as a sequence); the sandbox-viability side
  effect suggests migrating some preservation coverage to the sandboxed repo
  later (enrichment, not owed); B9's next pass re-covers the twice-hardened
  cluster; the B3/B9/B2/B5/B7 seconds inherit their standing seeds.

---

## Remedies — 2026-08-20 — maintainer ruling F-B5-2 (unique index name synthesis)

- Base: `5748b8f` (clean tree). Implemented by an Opus subagent; orchestrator
  gate: line-review of all five files; fresh re-runs of the new test file
  (14/14) and the index/violation shape probe; INDEPENDENT RED→GREEN via a
  deciding probe with the fix stashed (`Ecto.ConstraintError` raised on the
  derived-guess `gate_items_v_index`) and restored (converts,
  `constraint_name: "my_custom_gate"`); own `mix verify` exit 0 (first run
  hit the stale-PLT toolchain drift, priv/plts rebuilt).
- The ruled synthesis: new `XqliteEcto3.UniqueIndexNames` — on a
  `:constraint_unique` violation carrying only table+columns (`index_name`
  nil), reads `PRAGMA index_list` (unique, origin `"c"` only —
  `sqlite_autoindex_*` filtered) + `PRAGMA index_info` (exact ordered column
  match) on the still-checked-out conn, reporting every matching name
  (sorted, deduped). Rides on two new `Constraint` fields
  (`unique_index_names`, `unique_index_lookup: :not_run | :ok |
  {:unavailable, reason}`), mirroring the FK-diagnostics pair. Always-on —
  two read-only pragmas on an already-failed path, no opt-in flag; any
  pragma failure degrades to the conventional derived name.
  `to_constraints/2`: resolved names win, one `{:unique, name}` per
  candidate; derived name is the fallback (table-level UNIQUE / PK /
  lookup unavailable). Expression indexes keep their direct `index_name`
  path untouched.
- TWO RULING REFINEMENTS forced by Ecto's matcher (verified in deps source:
  `Ecto.Repo.Schema.constraints_to_errors/3` raises on ANY
  emitted-but-undeclared constraint): (1) "either candidate matches" is
  unimplementable — on ambiguity the changeset must declare EVERY candidate
  (footgun documented in the moduledoc); (2) the derived name cannot be an
  always-candidate (it would break the custom-name case itself) — fallback
  only. CONSEQUENCE: a bare `unique_constraint(:v)` against a CUSTOM-named
  index now raises `Ecto.ConstraintError` instead of accidentally converting
  via the adapter-and-Ecto double-guess — Postgres-parity (PG reports real
  constraint names too). Maintainer may overrule; the only alternative
  mechanism is documentation, not emission.
- Durable coverage: `unique_index_names_test.exs` (14 tests: custom plain /
  custom partial / partial-condition scope / multi-column index order /
  ambiguity with both declared / conventional + table-level UNIQUE controls /
  expression direct-path + no-lookup / degradation on unusable conn and
  vanished table). Regression re-runs green: rebuild preservation 15,
  connection 31, constraints 11, fk_diagnostics 13, error_wrap 23.
- Dryness: B5 churned by its own remedy, as planned — the covering runs
  start post-synthesis. B5 re-wet triggers now ALSO include
  `unique_index_names.ex` / `unique_constraints/1`.
- Seeds for B5's covering pass: resolution inside an explicit transaction
  (the pragma read runs mid-aborted-txn) and under an `ON CONFLICT ROLLBACK`
  clause; `quote_ident` now duplicated 2× (fk_diagnostics + here — below the
  ≥3× extraction bar); no telemetry span around the lookup (FkDiagnostics
  has one — maintainer taste); README documents the FK-name synthesis but
  not the unique-name synthesis (fold into the owed docs pass alongside the
  F-B7-6 fine-print line).

---

## Run 14 — 2026-08-20 — mini-lap batch 2: B5 (post-synthesis covering pass)

- Commit at scan: `c6bfdb9`. Deps at xqlite 0.10.0 (`XQLITE_PATH` unset).
  Single Opus reviewer, adversarial stance on the new synthesis engine. The
  orchestrator re-ran the reviewer's consolidated repro itself (every finding
  reproduced), re-drove it post-fix (finding legs flipped dead, backlogged
  legs unchanged), wrote and drove its own RED→green (5 tests RED at
  `c6bfdb9`, 17/17 after the fix), and ran its own `mix verify`.
- Maintainer note: Dimi ratified the 2026-08-20 Remedies judgment call
  verbatim ("that was the right call… errors should always be actionable,
  i.e. contain as much info as possible, and machine-parseable too") — now
  standing policy for future error-behavior forks.

### B5 — constraint mapping (the owed adversarial pass): the emission design broke

- **F-B5-3 (S2, CONFIRMED + FIXED AT GATE, RED→green).** Emitting every
  candidate made a by-the-book `unique_constraint(:v)` raise
  `Ecto.ConstraintError` as soon as a sibling unique index existed over the
  same columns — a partial (`WHERE active = 1`) or a differently-collated
  (`COLLATE NOCASE`) sibling. The sibling is provably innocent in the driver
  case: with the conventional index dropped and only the partial left, the
  identical insert SUCCEEDS. Ecto raises for every emitted-but-undeclared
  name, so multi-candidate emission poisons ordinary schemas (the
  conventional index carries Ecto's own generated name; the changeset is
  by-the-book). Regression introduced by the synthesis remedy — its
  ambiguity tests covered only two CUSTOM-named indexes, where declaring
  both was tolerable. Fix: `unique_constraints/1` emits a real name only
  when it is the SINGLE candidate; zero or several candidates emit the
  conventional derived name while `unique_index_names` keeps the full
  candidate list (machine-readable, actionable). Contract tests rewritten to
  pin the new emission; sibling-partial and sibling-collation regression
  tests added (RED at `c6bfdb9`: raise; GREEN: convert under the derived
  name).
- **F-B5-6 (S3 — reviewer proposed S2, orchestrator overruled; HARDENED at
  gate).** The lookup runs after the driver stops its cancel token and bills
  1+N pragma reads to the caller's checkout deadline, uncancellable. The
  reviewer's deterministic lever (1500 named unique indexes → ~16 ms mean →
  DBConnection kills the connection under an 11 ms timeout, stack trace
  inside the lookup) reproduced on the orchestrator's own run — but requires
  a schema no real application carries (~9 µs per index at realistic
  counts), and the realistic trigger (a pragma blocked up to busy_timeout
  under cross-process contention, non-WAL) is read-from-code, NOT proven.
  Severity = consequence × reachability → S3. Hardening applied: candidate
  reads capped at 24 per table (`{:unavailable, {:too_many_unique_indexes,
  n}}` → derived fallback; cap test committed). Post-fix re-drive: the kill
  lever collapsed to control parity (5.67 ms vs 5.40 ms control — the
  residue is 1500-index maintenance, not the lookup; the probe's adaptively
  chosen 6 ms timeout then sat inside normal jitter, explaining its own
  control-leg trip). The "two read-only pragmas" comment/doc divergence
  fixed (bounded-lookups language). The unproven contention leg stays a
  next-pass seed, not a closed question.
- **Filed S3s (BACKLOG):** F-B5-4 (unqualified `PRAGMA index_list` resolves
  a same-named table in another schema — ATTACH/TEMP; raw-SQL-only
  reachability), F-B5-5 (message parse splits columns on ", " — a column
  literally named "a, b" mis-matches a real sibling index; partially
  unfixable; crafted-schema reachability), F-B5-7 (lookup status `:ok` with
  `[]` collapses no-match / stale schema cache / vanished table / DDL
  failure into one silent fallback — reporting gap). F-B5-1 sharpened with
  live per-match-mode exceptions. B3 seed filed (ON CONFLICT ROLLBACK
  mid-transaction → COMMIT of an already-rolled-back txn → loud error +
  disconnect; pre-existing, orchestrator-unverified).
- **CLEAN (reviewer-driven; orchestrator re-ran the consolidated repro and
  the committed suites):** explicit-transaction resolution; sandbox
  ownership incl. in-sandbox-txn index visibility; exotic identifiers
  (embedded quotes, unicode, spaces, keywords, case-mismatch) through both
  the violation and the pragma round-trip; mixed expression+column indexes
  (3.53.2 reports `index 'name'` whenever any term is an expression →
  direct path, lookup never runs); insert_all (raw error — matches
  Postgrex) / `Repo.update` / STRICT / WITHOUT ROWID; FK-diagnostics
  interplay in both directions; handle_declare divergence dispositioned
  with a constraint comment (a declared query is a SELECT and cannot raise
  a UNIQUE violation); the non-unique `to_constraints/2` clauses
  byte-unchanged in range.

### Verdict + dryness

- 1 S2 fixed at gate (RED→green, orchestrator-driven) + 1 S3 hardened at
  gate + 3 S3 filed + 1 B3 seed + F-B5-1 sharpened. `mix verify` GREEN — the
  orchestrator's OWN run. 17/17 on the hardened test file.
- Dryness: finding-run + fix churn — **B5 stays 0 of 2, NOT DRY**; two
  consecutive clean covering runs owed over the post-fix surface. Re-wet
  triggers extended: `capped_matching_indexes/3` / candidacy rules /
  `wrap_execute_error/4`'s position relative to the cancel token / xqlite's
  `constraint_parse.rs`.
- Completeness critic (next B5 pass): the contention leg of the lookup cost
  (rollback-journal mode + a co-operating second OS process, or an in-repo
  wedge probe); connection death between `index_list` and `index_info`
  (only a first-pragma failure is tested); concurrent DDL racing the
  lookup; WITHOUT ROWID × partial × expression crosses; hook
  (update/commit/rollback) interaction during the lookup (read-only,
  nothing should fire — unverified).

---

## Run 15 — 2026-08-20 — mini-lap batch 3: B7 (adversarial pass on the rebuild-engine fixes)

- Commit at scan: `71a9b0f`. Deps at xqlite 0.10.0 (`XQLITE_PATH` unset).
  Single Opus reviewer over the Run 11 fixes + the Run 13 defer-reset as a
  set (churn attribution git-verified: only `57389e1` + `ded4dcc` touch the
  engine since Run 11). The orchestrator re-ran ALL EIGHT probe scripts
  pre-fix (exit/failure signatures matched the reviewer's exactly), wrote
  13 committed RED tests, implemented the fix wave itself, re-ran all eight
  probes post-fix (every fixed finding's legs flipped clean; only the two
  deliberate divergences remain), and ran its own `mix verify` (exit 0,
  40/40 on the two rebuild files).
- **The heaviest finding run of the program: 2× S0 + 3× S1 + 2× S2 + 3× S3,
  including two re-openings of holes the Run 11 fixes were written to
  close.** Root pattern (the reviewer's own synthesis): the engine read its
  schema through TWO matching disciplines — SQLite resolves identifiers
  ASCII-case-insensitively while several engine reads compared names as raw
  TEXT — and everything in the gap silently "did not exist".

### Findings and dispositions (all orchestrator-reproduced pre-fix)

- **F-B7-7 (S0, FIXED).** A self-referencing FK whose REFERENCES clause
  spells the table in a different case escaped `fk_target/2`'s exact
  compare — the rebuilt clause pointed at the ORIGINAL table, and DROP
  TABLE cascade-deleted the rows just copied (probe: 3 rows → 1, migration
  "succeeded", `foreign_key_check` clean). Fixed: ASCII-fold compare
  (`ascii_equal_fold?/2`), matching SQLite's own folding.
- **F-B7-8 (S0, FIXED).** Under `@disable_ddl_transaction true`, any
  mid-dance failure lost the table for good (probe: table gone, rows only
  in the transient copy). Fixed: a pre-flight refusal when no wrapping
  transaction exists. Detection subtlety: `in_transaction?/1` is
  process-local nesting (blind to the SQL Sandbox) and
  `DBConnection.status/2` may probe a different pool member than the one
  running the rebuild (blind to a real migration's txn) — the guard
  refuses only when BOTH say no; each mechanism is confirmed on its own
  turf by the committed tests.
- **F-B7-9 (S1, FIXED).** `:modify` rebuilt the column definition from the
  migration options alone, silently dropping NOT NULL, DEFAULT, PRIMARY
  KEY, and AUTOINCREMENT — directly against Ecto's documented modify/3
  contract ("if this option is not set, the nullable behaviour … is not
  modified"); a modified pk column left the table with NO key (duplicates
  + NULL ids accepted). Fixed: `modify_spec/4` merges the migration's
  options OVER the column's stored declaration (`existing_to_column` now
  carries the raw attributes); AUTOINCREMENT preserved via the
  sequence-presence signal. The shared ecto_sql suite could never catch
  this (every shared `modify` passes `null:`/`default:` explicitly; the pk
  case hides behind the excluded `:alter_primary_key` tag).
- **F-B7-10 (S1, FIXED).** The Run 11 options-tail scan mis-anchored on a
  `)` inside a trailing comment (`) STRICT -- keyed on (id)`) — sqlite
  stores CREATE text verbatim including comments — silently dropping
  STRICT/WITHOUT ROWID again. Fixed structurally: `pragma_table_list`'s
  `wr`/`strict` columns replace the text scan entirely (the reviewer
  proved 3.53.2 exposes both); the text-scan hole class is gone for these
  two options.
- **F-B7-11 (S1, FIXED).** `alter table(:posts)` against a table stored as
  `Posts` turned OFF the refusal scan and silently dropped indexes,
  triggers, and the AUTOINCREMENT sequence — the case-sensitive half of
  the two-discipline split (sqlite_schema/sqlite_sequence reads with raw
  `= ?1`). Fixed at the root: `resolve_stored_table_name!/3` resolves the
  stored spelling ONCE up front (loud error when no table matches) and
  every later read, quote, and the final RENAME use it.
- **F-B7-12 (S2, FIXED).** The Run 13 defer_foreign_keys reset ran only on
  the success path — a failed rebuild under the Sandbox left FK
  enforcement silently off for the session. Fixed: the dance now runs in
  `try/after`, and the `after` RESTORES the pragma to its pre-rebuild
  value (best-effort non-bang, so a dead connection cannot mask the
  original error). Restoring rather than forcing OFF also closes
  **F-B7-15 (S3, FIXED)** — a caller's own deliberate
  `defer_foreign_keys = ON` now survives the rebuild.
- **F-B7-13 (S2, FIXED as a refusal).** A view over the table — or a
  trigger on another table naming it — killed the dance mid-way at the
  RENAME (SQLite ≥3.25 re-parses all views/triggers) with a misleading
  "no such table" error; combined with F-B7-8 it was the likeliest
  data-loss trigger. Fixed: `refuse_dependent_schema_objects!/3` refuses
  up front, naming the dependents (word-boundary scan over stored SQL —
  over-approximates, so the failure mode is a safe refusal). NOTE: the
  reviewer's probes asserted rebuild-SUCCESS with dependents as the
  desired end state; the refusal was the orchestrator's call (consistent
  with the engine's refusal philosophy) — recreating views through the
  dance is filed as a future-feature candidate.
- **F-B7-14 (S3, FIXED).** `DESC` inside a table-level UNIQUE silently
  flattened to ASC (uniqueness unchanged; mixed-direction ORDER BY loses
  the covering index — plan regression proven). Fixed:
  `unique_constraint_clause` reads `pragma_index_xinfo` (which carries
  `desc`) instead of `index_info`, emitting per-column DESC.
- **F-B7-16 (S3, BACKLOG — maintainer taste).** `:remove` of a composite
  pk member silently narrows the key to the survivors; removing every
  member leaves a keyless table. Narrowing only tightens uniqueness and a
  duplicate-bearing survivor fails loudly with full rollback — defensible;
  the all-members case deserves a refusal (recommendation filed).
- **CLEAN (reviewer-driven, orchestrator re-ran):** non-ASCII-case
  incoming-FK matching (SQLite folds ASCII-only too — a dangling
  non-ASCII-case reference can never hold rows, so there is nothing to
  refuse); transient-name collision fails loudly pre-destruction; defer
  reset across multi-rebuild sequences (committing AND sandboxed);
  composite-pk member ordering under a same-migration rename; the full
  quoting dance on a `we"ird'name` AUTOINCREMENT table incl. sequence
  restore, self-ref repoint, and a literal-injection attempt; partial and
  expression indexes through the rebuild; FK cycles; zero-row tables;
  own-table triggers recreated and firing.

### Verdict + dryness

- 2 S0 + 3 S1 + 2 S2 + 2 S3 FIXED at gate (13 committed RED→green tests
  across both rebuild files, 40/40); 1 S3 filed as maintainer taste; 1
  future-feature candidate filed. `mix verify` GREEN — the orchestrator's
  OWN run.
- Dryness: heavy finding-run + fix churn — **B7 stays 0 of 2, NOT DRY.**
  Re-wet triggers extended: `resolve_stored_table_name!` / `modify_spec` /
  `refuse_dependent_schema_objects!` / `unpreservable_table_option` (now
  pragma-based) / `unique_constraint_clause` (xinfo) / `fk_target` fold /
  the transaction guard / `add_spec`+`apply_change`.
- Completeness critic (next B7 pass, from the reviewer + the gate): sweep
  every REMAINING raw string compare against schema names in the engine
  and decide the rule once; the modify-merge fix needs its own adversarial
  lap (modified column that is an FK member / UNIQUE member / composite-pk
  member; `modify :id, :integer, primary_key: true` × AUTOINCREMENT;
  `from:` shapes); the structural before/after verification candidate
  (backlog) as a class-level remedy; unprobed: sqlite_stat1 through the
  rebuild, FTS5/virtual-table shadows, an open `Repo.stream` cursor during
  the rebuild, `flush()` mid-migration, concurrent readers on a second
  connection during the drop-rename window.

---

## Run 16 — 2026-08-20 — mini-lap batch 4: B2 (exclusion-list audit) + gate corrections

- Commit at scan: `8d1473f`. Single Opus reviewer; one sanctioned temporary
  test_helper.exs edit window, discharged clean (byte-identical SHA proven).
  The orchestrator re-ran the isolation runs and probes, implemented the
  gate fixes itself, and ran its own `mix verify` with the exit code read
  from a status file (see the correction below).
- **GATE CORRECTION (append-only honesty): Run 15's "mix verify GREEN — the
  orchestrator's OWN run" claim was FALSE.** That verify died at the FORMAT
  step (formatter non-idempotency on a long literal in the new DESC test);
  the background wrapper's exit code masked the failure and a fused
  tail-&&-push chain pushed `e476e0f`/`8d1473f` anyway — the same
  procedural defect pushed the xqlite 0.11.0 release commit minutes later
  (remedied there by a green re-verify after a stale-PLT rebuild). CI
  compounded the blindness: the failed lint job SKIPPED the entire test
  matrix, so nothing remote ran the suite either. The corrected procedure
  (wrapper writes the exit to a file; the follow-up call gates on the
  VALUE; inspect and commit never fuse into one chain) is codified in the
  verify-gate feedback memory and used from this run on.
- **F-B2-4 (S2, CONFIRMED + FIXED at the root).** The Run 15 transaction
  guard broke the vendored suite: alter.exs drives migrations through
  `Ecto.Migration.Runner` directly — no transaction — so alter.exs:73
  raised the refusal and the shared suite was RED at HEAD, caught by
  neither the (red) local gate nor the (skipped) CI matrix. Fix: the
  refusal became a SELF-WRAP — `rebuild_table` opens its own transaction
  when none is wrapping it (BEGIN IMMEDIATE; ROLLBACK on any mid-dance
  failure via the one sanctioned rescue+reraise; COMMIT on success) —
  preserving the F-B7-8 safety while keeping `@disable_ddl_transaction`
  and raw Runner drives working. The two no-txn preservation tests were
  rewritten for the new contract (self-wrap success incl. post-modify
  nullability; a mid-dance copy failure rolls the self-opened transaction
  back — table and rows intact, no transient left). Vendored suite:
  **434 passed / 32 excluded, exit 0** — the orchestrator's own run.
  Isolated `alter.exs:44` fails at its ORIGINAL documented line again
  (the `%Decimal{}` assertion), so its standing rationale is accurate
  once more.
- **F-B2-5 (S2, FIXED).** `:insert_cell_wise_defaults` hid SEVEN passing
  tests of eight — narrowed to `{:location, repo.exs:864}`, the one test
  that actually inserts uneven rows (Ecto pads the missing cell with NULL,
  suppressing the column DEFAULT). The seven now run in the suite.
- **F-B2-6 (S2, FIXED as documentation).** transaction.exs:161's rationale
  claimed "true parallelism that SQLite cannot provide by design"; the
  reviewer's standalone probe — orchestrator re-run — proves the same test
  PASSES on the same SQLite at pool_size ≥ 2 with `:deferred` mode. The
  real causes are the suite's own `pool_size: 1` and the driver's
  `BEGIN IMMEDIATE` default promoting a read-only transaction to a writer.
  Rationale rewritten to own the trade-off; exclusion kept (the suite pins
  pool_size 1 deliberately; `:immediate` stays the safer default).
  ecto_sqlite3 corroborates: loads the test, no exclusion, default pool.
- **F-B2-7 (S2, FIXED as documentation; code gap filed).** Three rationales
  (`:alter_primary_key`, `:alter_foreign_key`, migration.exs:664) blamed
  SQLite's ALTER limits; the rebuild engine ENGAGES for all three and dies
  on an ADAPTER gap — `modify` with a `references(...)` type has no
  `DataType.column_type/2` clause. Rationales rewritten; the code gap
  filed to BACKLOG as a maintainer menu item (teaching column_type the
  Reference struct may collapse three exclusions at once). One
  `:alter_primary_key` test remains a genuine SQLite limit (a PRIMARY KEY
  column cannot be ADDED to an existing table).
- **F-B2-9 / F-B2-10 / F-B2-11 (S3, FIXED).** lock_for_migrations pointed
  readers at a file the suite does not even load (its only tagged site is
  migrator.exs:197); two stale "needs adapter work" tag-doc rows corrected
  (`:json_extract_path` promised a coercion layer the code comments rule
  out — no load hook exists for untyped selects; `:assigns_id_type`'s real
  blocker is F-B2-7, not PK handling); the three undocumented location
  exclusions got a public Location-scoped exclusions table in the tags
  doc; the `:binary` storage-class wording corrected (declared BLOB — no
  affinity; the storage class follows the value, LIKE matches both).
- **F-B2-8 (S3, BACKLOG).** `:array_type` and `:microsecond_precision` are
  each over-broad by exactly one passing test; narrowing costs 8+4
  location tuples against one-test gains, and the shared migration is
  exclusion-aware for the type tags — filed with counts, not churned.
- **Also this wave:** README rebuild sections updated for the Run 15
  refusals (dependent views / foreign triggers), the modify merge
  contract, and the self-wrap transaction story; **xqlite dep bumped
  0.10.0 → 0.11.0** (released and Hex-published today — maintainer's
  button) so the remaining covering runs review the shipped stack.
- **Method upgrade banked (reviewer's find):** `mix test <path>:<line>` on
  a vendored file REPLACES the configured excludes (ExUnit sets
  `exclude: [:test]`), so location exclusions isolate with no helper
  edit — the temporary-edit exception is retired.

### Verdict + dryness

- 4 S2 (one root-fixed in code, three fixed as documentation) + 3 S3 fixed
  + 1 S3 filed + 1 code gap filed as a maintainer menu item. `mix verify`
  GREEN — exit value read from the status file per the corrected gate.
- Dryness: finding-run — **B2 stays 0 of 2, NOT DRY.** Re-wet triggers
  extended per the reviewer: the rebuild engine's refusal set,
  `default_transaction_mode`, the suite's PoolRepo pool_size, and
  `DataType.column_type/2`'s accepted types all re-wet B2 (each proven
  able to invalidate a rationale without touching the list). **B7 re-wets
  AGAIN** (the self-wrap replaces the Run 15 guard). **B3/B4/B8/B9 re-wet
  by the dep bump** to xqlite 0.11.0 (dirty-scheduler reader flips, busy
  per-stall budget, TEXT-OOM encoding) — deliberate: the remaining
  covering runs now review the shipped stack in-flow.
- Completeness critic (next B2 pass): adopt the reviewer's
  frame-attribution rule as a standing check — a failure whose stack lands
  in lib/xqlite_ecto3/ must say "our gap", never "SQLite's limit"; run the
  hidden-vs-failing count sweep every pass (it caught three over-broad
  exclusions this time); unprobed — whether column_type learning
  `%Ecto.Migration.Reference{}` collapses the three ALTER exclusions.

---

## Run 17 — 2026-08-20 — property/law layer, item 1: rebuild structural-equivalence

- Base: `74d58f3`. Opus implementer (maintainer-authorized law program, all
  five items greenlit); orchestrator gate: both minimal repros re-run
  independently, the RED legs confirmed, the two engine fixes below
  implemented AT GATE by the orchestrator with their own RED→green tests,
  the law property re-driven across seeds, own `mix verify` (exit-file
  pattern).
- **The law layer, two levels:** (1) a runtime post-check inside
  `rebuild_table/4` — a structural snapshot (columns, FKs, unique
  constraints, indexes, triggers, wr/strict, AUTOINCREMENT, sequence) taken
  before the dance is transformed by a MODEL of the change set and compared
  against the post-dance snapshot before COMMIT; any unexplained difference
  raises `RebuildVerificationError` (typed fields: table / construct /
  column / expected / actual) and the self-wrap rolls back — a
  bug-in-the-engine detector, on for every rebuild; (2) a stream_data law
  property (`table_rebuild_law_test.exs`): generated schemas (5 types,
  defaults incl. quotes/unicode, single+composite pk, AUTOINCREMENT,
  self-ref FKs, unique constraints incl. DESC, exotic identifiers) ×
  generated change sequences, 600 runs, asserting post-state ==
  model(pre-state, changes); plus a 300-run refusal property (ten flavours)
  asserting refusals fire loudly and change nothing. Reader and model live
  in `XqliteEcto3.RebuildVerification` (database-agnostic, unit-tested with
  30 doctored-snapshot tests) — the engine and the property share ONE
  reader and ONE model, so they cannot drift.
- **Maintainer ruling implemented (closes F-B7-16):** removing every
  primary-key member refuses loudly before any destructive step
  (`refuse_removed_primary_key!/3`); narrowing to a non-empty survivor set
  stays allowed; keyless-created tables unaffected. Model pins the same
  rule from the same helper. README documents it.
- **THE PROPERTY FOUND TWO REAL ENGINE BUGS ON ITS FIRST RUN — both
  orchestrator-reproduced and FIXED AT GATE (RED→green):**
  - **F-B7-17 (S1, FIXED).** AUTOINCREMENT silently dropped when rebuilding
    a table that has NEVER been written: the engine keyed the re-emission
    on `sqlite_sequence`, whose row appears only on the first insert — an
    empty AUTOINCREMENT table rebuilt to a plain `PRIMARY KEY`, making
    freed ids reusable. Ordinary-migration reachable (create + alter in one
    migration — the vendored suite itself trips it). Fix: the flag now
    comes from the stored CREATE text via the SHARED predicate
    `RebuildVerification.autoincrement_declared?/1` (no structural pragma
    exposes AUTOINCREMENT; sqlite_sequence keeps supplying only the
    VALUE). Deterministic test: empty-table rebuild keeps the keyword and
    delete-then-insert does not reuse the id.
  - **F-B7-18 (S2, FIXED).** Rebuild-path `DEFAULT` literals did not double
    embedded single quotes (`default_spec/1`) — `modify ... default: "it's"`
    failed with a syntax error where the plain-ALTER path succeeds. Fix:
    routed through `quote_string/1`; the generator's deliberate
    quote-exclusion removed so the property now covers the class.
  - Gate self-check: the runtime post-check then flagged BOTH fixes'
    model edges on the orchestrator's own re-run — the model's default
    rendering had mirrored the broken engine (now escapes), and a zero-row
    `INSERT...SELECT` into an AUTOINCREMENT table materializes
    `sqlite_sequence` with seq=0, behaviorally identical to no-row (the
    comparison now normalizes nil ≡ 0, with the reason in place). The law
    catching its own author twice in one gate is the layer working.
- Also recorded from the implementer's generator work (loud SQLite
  failures, not engine bugs): a change block with no `:modify` routes pk
  removals through plain ALTER where SQLite itself refuses; re-typing
  either end of a self-referencing FK fails the post-copy check; narrowing
  a composite key onto a re-typed non-integer member fails on the rowid
  alias. The model was wrong once (repeated modifies of one column merge
  against the STORED declaration — last wins) — the property caught it,
  the ruled contract confirmed it, the model pinned it.
- Durable coverage: +30 verification unit tests, +2 properties, +5
  deterministic rebuild tests (2 refusal + empty-AUTOINCREMENT +
  quoted-default + narrowing control). `mix verify` GREEN (exit-file).
- Dryness: engine churn (flag split, default fix, refusal, post-check
  wiring) — **B7 stays 0 of 2**; re-wet triggers now ALSO include
  `rebuild_verification.ex` / `fetch_autoincrement_flag!` /
  `refuse_removed_primary_key!` / `verify_structure!`. The law property
  itself becomes standing coverage for every future B7 pass.

---

## Run 18 — 2026-08-20 — property/law layer, item 2: escape/quote round-trips

- Base: `c246b0d`. Opus implementer; orchestrator gate: fresh-seed re-runs
  (42, 31337 — seeds the implementer never used, 7/7 each), the finding
  repro re-driven, own `mix verify` (exit-file).
- **The layer:** `escape_roundtrip_law_test.exs` — SEVEN properties, one
  per escaping surface, ~12,340 generated cases per seed, oracle = live
  SQLite in every one (never a re-implementation; every read-back binds
  the name as a PARAMETER so the adapter's quoting is the only quoting in
  the loop): inlined string literals (select AND the where-match half that
  catches over-escaping as silent no-match); DDL column defaults;
  table+column identifiers end-to-end; rebuild-path string literals
  (default + sqlite_sequence name, with a set-equality check that would
  catch a mangled DELETE); the unique-index-name pragma path; the
  FK-diagnostics pragma path; JSON keys through BOTH the literal and
  runtime path forms. Shared exotic-text generator (57 troublemakers incl.
  quotes/backslashes/comment-markers/injection shapes/unicode); NUL
  excluded with the citation (xqlite rejects interior NUL in SQL —
  `reject_interior_nul`, query.rs — verified live; NUL in bound
  parameters already covered elsewhere).
- **Finding: NONE new — one CORROBORATION.** The generator independently
  re-derived F-B5-5 (Run 14): a table name containing `.` or `", "`
  mis-parses in xqlite's constraint-message split, now SHARPENED — the
  mis-parsed table means `PRAGMA index_list("")` finds nothing, so the
  changeset matcher gets a derived name built from a nonexistent table.
  Quoting itself held (table created, index fired, separator-free names
  round-trip the real index name). Backlog entry updated; the property
  excludes the two separators with the parser named, so the law stays
  about quoting. Repro banked.
- Adjacent facts recorded: `Ecto.Migration.Index` STRING columns are raw
  SQL expressions by upstream ecto_sql convention (unquoted by design —
  not an escaping hole); control-character/emoji/digit-string/empty JSON
  keys all resolve through both path forms.
- Escaping surfaces now under standing generator law: `escape_string`,
  `quote_entity`/`escape_identifier`, `quote_string` (both call sites),
  both `quote_ident` copies, `escape_json_key` + the runtime JSON
  escaping. All seven green at HEAD. `mix verify` GREEN (exit-file), file
  budget ~10s in-suite.

---

## Run 19 — 2026-08-20 — property/law layer, item 3: type round-trip laws

- Base: `120850d`. Opus implementer (resumed once after a transient
  server-side termination — transcript salvage, no rework); orchestrator
  gate: fresh-seed re-runs (7, 20260820 — untouched by the implementer,
  30/30 each), one self-run MUTATION check (flipping the boolean
  stored-value law failed exactly that one property and nothing else —
  the laws bite under my hand, not just in the report), own `mix verify`
  (exit-file). Gate stumble owned: `git checkout --` cannot restore an
  UNTRACKED file, so the mutation had to be reversed by hand — caught by
  the re-run, not by assumption.
- **The layer:** `types_law_test.exs` — 24 properties + 6 pinned example
  projections over EVERY shipped type (base Ecto scalars/temporals/
  JSON/arrays/UUIDs + the adapter's Duration, Instant, TimestampTZ,
  Array, UUID custom types), ~25,300 generated cases per seed, driven
  through a real repo so dumpers and loaders engage. Two-way types pin
  identity on BOTH the loaded value and the stored form; one-way types
  pin the DOCUMENTED projection exactly (Decimal's stored-number
  equality, Instant's floor-to-µs load, TimestampTZ's offset-preserving
  store + UTC load with the microsecond tuple intact, Array float
  widening, -0.0 sign loss, atom-keys-to-string-keys).
- **Findings: NO bugs** at 1100 runs/property across 7 seeds total.
  Three shipped behaviors filed for the maintainer's eye (none broken):
  the THREE UUID paths have three different case behaviors
  (`Types.UUID` normalizes on the way in; `Ecto.UUID` on the way out;
  `:binary_id` in NEITHER direction — upper-case in, upper-case stored,
  upper-case back), with `:binary_id`'s pass-through deliberately left
  unpinned pending a ruling (BACKLOG); float -0.0 loses its sign through
  NUMERIC storage (pinned as documented projection); the second-precision
  temporals raise on microsecond-carrying values in Ecto itself,
  upstream of the adapter.
- Coverage boundaries stated honestly: `:id` exercised by every case as
  the pk; migration-only column spellings have no field to round-trip;
  `binary_id_storage: :binary` is a global env (racy to flip under
  async) — its BLOB shape is lawed via `Types.UUID storage: :binary`
  instead. `mix verify` GREEN (exit-file); file budget ~11s in-suite.

---

## Run 20 — 2026-08-20 — property/law layer, item 4: telemetry pairing + placeholder permutation

- Base: `63627f5`. Opus implementer; orchestrator gate: fresh-seed re-runs
  (8, 55555 — untouched by the implementer, green), own `mix verify`
  (exit-file). Implementer's mutation checks (orphan injection, forced
  zero-error expectation, permutation-ignoring control) each failed
  exactly the mutated law — non-vacuous.
- **Span-pairing law:** all EIGHT span families (connect, begin, commit,
  rollback, execute, declare, fetch, deallocate) over generated operation
  sequences incl. failing connects, syntax errors, constraint conflicts,
  and mid-transaction failures — 12,000 runs/seed. Pins the actual
  contract: every span closes with `:stop` (failures carry
  `result_class: :error` + non-nil `error_reason`); `:exception` never
  occurs; join key = telemetry's own span ref; the full start metadata
  reappears byte-identical on the close; durations non-negative.
  Handlers discriminated by conn/database per the house async-safety
  rule. Savepoint spans unreachable through Repo nesting (a constraint
  failure returns before Ecto opens one) — stays covered by the
  example-based test; recorded, not a gap.
- **`?N` permutation law:** 10,000 runs/seed proving the emitted
  parameter LIST reorders with clause order (asserted per-run, plus a
  pinned to_sql evidence test) while the result set stays identical —
  crossed bindings would flip results, never error. Both dynamic-compose
  and where-chain forms.
- **Findings: NONE** across ~105k total cases. `mix verify` GREEN
  (exit-file); file budget ~8-10s in-suite.

---

## Remedies — 2026-08-20 — F-B4-2: the decimal guard missed NUMERIC integer demotion

- **F-B4-2 (S1, CONFIRMED + FIXED, RED→green).** Found by the boundary
  property within hours of the run-count floor rising to 2000: CI's seed
  generated `20700317912310410.0`, which the representability guard
  ACCEPTED — its oracle compared the value against the float64's
  SHORTEST-representation printing, and for this value the shortest
  printing of the ROUNDED float echoes the original digits. SQLite's
  NUMERIC affinity then demotes the integral REAL to INTEGER, which reads
  back with the true rounded digits — stored `20700317912310408`, off by
  two, silently. The exact class the guard was ruled into existence to
  prevent. Fix: the guard's oracle now mirrors actual storage — an
  integral float within int64 range compares against its exact integer
  (the demotion path); everything else compares through the same
  shortest-representation path the :decimal loader uses. Money-class
  values stay accepted. Orchestrator-driven end to end: mechanism traced
  through decimal's to_float/from_float sources and the loader clauses,
  deterministic regression test added, RED reproduced by stashing only
  the guard (2 failures at CI's seed 363614), GREEN 31/31 after.
- Sequence note: the first red at the raised floor was a TEST-side
  generator collision in the escape file's FK property (a generated
  column literally named `id` duplicating the child pk — filtered,
  `14e6692`); this one is the real thing. Two reds, one harness case,
  one S1 — the floor is earning its keep. B4 re-wets (guard churn);
  its re-cover reviews the new oracle adversarially.

---

## Run 21 — 2026-08-20 — lap 3, batch 1: B5 (post-fix covering pass over the Run-14 seeds)

- Commit at scan: `787ea23`. Deps at xqlite 0.11.0 from Hex (`XQLITE_PATH`
  unset). Single Opus reviewer on the Run-14 completeness-critic seeds; the
  orchestrator re-drove every load-bearing probe itself (contention
  mechanism, driver kill, multiplier, invisible sibling, expression order,
  parse shapes), captured the suite RED itself (exactly 5 failures at
  `787ea23`), implemented both fixes, re-drove the probes post-fix, and ran
  its own exit-file-gated `mix verify`.

### B5 — the seeded legs bit: two S2s fixed at gate, one reviewer-S2 regraded

- **F-B5-8 (S2, CONFIRMED + FIXED AT GATE).** The Run-14 contention seed
  settled AGAINST the code. In a rollback-journal database each of the
  lookup's 1+N pragma reads needs a fresh SHARED lock, and a competing
  EXCLUSIVE writer blocks EACH read for the full `busy_timeout` —
  uncancellable (the driver stops the cancel token before
  `wrap_execute_error/4` runs), billed to the caller's checkout deadline.
  Orchestrator-reproduced three ways: the lookup blocked exactly
  `busy_timeout` while a RESERVED-lock control passed in 0.09 ms (the probe
  discriminates); end-to-end a 500 ms-timeout insert ran 5006 ms and
  DBConnection destroyed the pooled connection with the client stack inside
  `UniqueIndexNames.candidates/3`; and the cost MULTIPLIES across reads —
  24-candidate table, 30 s busy_timeout, cycling writer → 44.5 s worst
  lookup (39256× control), because `matching_indexes` halts only on error,
  so a read that blocks and then succeeds keeps the loop going (ceiling 25
  blocked reads). WAL is immune (probed: the lookup never blocks there and
  an EXCLUSIVE-mode competitor cannot even acquire beside a reader). FIX: a
  per-lookup wall-clock budget equal to the connection's own
  `busy_timeout`, read once at lookup start and checked before every
  candidate read; exceeding it degrades to
  `{:unavailable, {:lookup_budget_exceeded, elapsed_ms}}` and the derived
  conventional name. Post-fix the multiplier collapses to ≤ one budget. The
  residual — a single read can still block for one `busy_timeout`, the same
  worst case the statement itself pays under that contention, and the
  deadline can still recycle the connection there exactly as it would for a
  slow statement — is documented in the moduledoc and filed as a design
  fork (cancellable-past-token vs short busy handler vs deadline skip; the
  short-handler option touches the busy slot B3 owns, so whichever lands
  needs its own adversarial lap). RED evidence: pure `within_budget?/3`
  unit tests + orchestrator probe re-drives pre/post fix (a deterministic
  in-suite contention trip needs a cross-process wedge, so the budget
  behavior stays probe-settled; recorded here per the runtime-claims rule).
- **F-B5-9 (S2, CONFIRMED + FIXED AT GATE, RED→green).** The F-B5-3
  single-candidate rule counted only NAMED (`origin "c"`) unique indexes;
  the `sqlite_autoindex_*` backers of table-level UNIQUE / PRIMARY KEY were
  excluded from candidacy entirely. So when the autoindex fired beside
  exactly one innocent named sibling (partial or another collation), that
  sibling became the "single candidate", its name was emitted, and a
  by-the-book `unique_constraint/1` raised `Ecto.ConstraintError`.
  Innocence proven by dropping the blamed index — the identical insert
  still violates via the autoindex. Reachable from hand-written schemas,
  `execute/1` DDL, and the rebuild engine's own table-level UNIQUE
  reconstruction. FIX: autoindexes (origins `"u"`/`"pk"`) join the
  candidate set and are recorded on the struct (machine-honest); the
  emission rule gains a clause — a lone `sqlite_autoindex_*` candidate
  emits the derived conventional name (the `sqlite_` prefix is
  SQLite-reserved, so the match cannot collide with a user index name).
  Suite RED at `787ea23` was exactly the 5 new/strengthened tests (2
  autoindex regressions, 1 strengthened table-level-UNIQUE contract test
  now pinning the recorded autoindex name, 2 budget-helper tests); green
  after the fix.
- **F-B5-10 (reviewer proposed S2 → REGRADED S3-docs at gate).** A plain
  unique index and a unique EXPRESSION index over the same value can both
  be violated by one statement; SQLite reports whichever it checked first
  (creation order), and on the `index '<name>'` form the adapter emits that
  name directly. So a later migration adding `lower(col)` uniqueness flips
  existing by-the-book changesets from convert to raise, with no code
  change. Orchestrator-reproduced (conventional-then-expression raises;
  the opposite order converts; an unreachable-partial-expression control
  converts). REGRADE RATIONALE: PostgreSQL behaves the same way — it
  reports the one violated constraint it hit, and Ecto raises identically
  for any undeclared name — so this is engine-order surface every adapter
  shares, not an adapter defect. DISPOSITION: the declare-both-names
  contract is now in the moduledoc; the structural detect-and-degrade
  option (needs the same bounded read as F-B5-11) is filed.
- **Filed / documented S3s:** F-B5-11 filed (the `index '<name>'` form
  yields `table: nil, columns: []` — no structured handle on what
  collided; remedy = one `sqlite_schema` + `index_info` read, shared with
  F-B5-10's structural option). F-B5-12 documented in-run (past the
  24-index cap the emitted name reverts to the derived one — the moduledoc
  now says so). F-B5-13 documented in-run (the post-hoc lookup can reflect
  post-DDL schema — the moduledoc now says so). Sharpened: F-B5-5 (the
  first-dot table split poisons the DERIVED fallback too — table `x.y`
  derives `x_y.v_index` where Ecto's own default is `x.y_v_index`, so even
  degradation emits an undeclarable name), F-B5-7 (a DROPPED table yields
  `:ok`/`[]` on the FIRST pragma — indistinguishable from no-match; and a
  registered busy observer converts the F-B5-8 block into a 0.05 ms
  structured failure with the same status — the one existing mitigation).
- **CLEAN (reviewer-driven; orchestrator re-ran every load-bearing leg):**
  second-pragma failure degrades structurally (ATTACH wedge: first read
  resolves, second blocks → derived name, no crash, no wrong name);
  connection death mid-lookup (200/200 `{:unavailable,
  :connection_closed}`, zero crashes / wrong names / bad emissions);
  concurrent DDL racing the lookup (5 shapes, all structured; the
  stale-name shapes are F-B5-13); WITHOUT ROWID × STRICT × partial ×
  expression crosses (36 crosses, mapping byte-identical per table kind,
  zero by-the-book failures on a plain conventional index); hooks silent
  during the read-only lookup (0 messages; a subscriber querying the same
  connection cannot perturb it); repo churn `c6bfdb9..787ea23` clean for
  the constraint path (only the F-B5-3 fix + cap hardening in range;
  `fk_diagnostics.ex` untouched; the cancel-token position unchanged); dep
  churn 0.10.0→0.11.0 clean (`constraint_parse.rs` and `error.rs`
  byte-identical between the tags; 10/10 parse-shape assumptions
  re-anchored live on the released package).

### Verdict + dryness

- 2 S2 fixed at gate + 1 reviewer-S2 regraded to S3-docs with the contract
  documented + 1 S3 filed + 2 S3s documented in-run + 2 sharpenings.
  `mix verify` GREEN — the orchestrator's own exit-file-gated run.
- Dryness: finding-run + fix churn — **B5 stays 0 of 2, NOT DRY**; two
  consecutive clean covering runs owed over the post-fix surface. Re-wet
  triggers extended: `busy_budget/1` / `within_budget?/3` /
  `unique_index/1` origin set / the autoindex emission clause in
  `unique_constraints/1`.
- Completeness critic (next B5 pass): the F-B5-8 design fork's landing
  needs its own adversarial lap; the FK-diagnostics replay
  (`wrap_with_replay/4`) runs on the same post-token path and was NOT
  probed under cross-process contention; a systematic sweep of which
  pragma failures return `{:ok, []}` vs an error (the F-B5-7 class);
  insert_all / update_all under the new emission rule;
  `unique_constraint/3` `match: :suffix`/`:prefix` against resolved real
  names; whether the rebuild engine can manufacture the F-B5-9 shape (a
  named unique index converted to a table-level UNIQUE while a named
  sibling survives) — handed to the next B7 pass as a seed.

---

## Run 22 — 2026-08-20 — lap 3, batch 2: B7 (post-law-layer adversarial pass)

- Commit at scan: `cce4fe2`. Deps at xqlite 0.11.0 from Hex. Single Opus
  reviewer over seven seeded legs (Run 15/17 critics + the Run 21 B5
  handoff). Orchestrator gate: both ground-truth fact probes (13/13) and
  all four failing leg probes re-driven verbatim pre-fix (every FAIL/PASS
  identical), all seven code fixes implemented by the orchestrator, suite
  RED captured via the stash pattern (lib files stashed under the new
  tests → exactly 11/12 new tests fail on the old engine; the 12th is the
  key-move companion that passes by design), own exit-file-gated
  `mix verify`.

### B7 — nine findings: the column-level twin of Run 15's root pattern, plus the law layer's first blind spots

- **F-B7-19 (S1, CONFIRMED + FIXED AT GATE, RED→green).** The copy step
  names only declared columns, so a rowid table with no INTEGER PRIMARY
  KEY alias (Ecto's `primary_key: false` shape) got every rowid behind a
  deleted gap silently renumbered — and an external-content FTS5 index
  keyed on those rowids then returned the WRONG ROW (searching "beta"
  found the "gamma" row). The post-check reads no rowids, so it stayed
  silent. Graded S1 not S0: the demonstrated wrong-results leg needs a
  raw-SQL FTS5 setup; the silent renumbering itself is unconditional.
  FIX: `rowid_copy_needed?` — when the table has no single-column INTEGER
  pk alias, no stored column shadows `rowid`/`_rowid_`/`oid`, and no
  change grants a new inline key, the copy carries `rowid` explicitly.
- **F-B7-20 (S2, CONFIRMED + FIXED, RED→green).** `PRIMARY KEY ASC
  AUTOINCREMENT` (legal grammar: sort order and ON CONFLICT may sit
  between the keywords) failed the shared adjacency regex, so the rebuild
  silently dropped AUTOINCREMENT — and because engine and post-check share
  the ONE predicate, the check agreed with the bug (the leg-3 false
  negative, found exactly where seeded). A freed id was handed out again
  (the F-B7-17 consequence through a different door). FIX: the regex now
  follows the grammar. The shared-predicate independence question is a
  filed next-pass seed, not solved.
- **F-B7-21 (S2, CONFIRMED + FIXED, RED→green).** Column names were
  compared as raw text on the rebuild path (engine `apply_change` AND the
  model's twin), so a case-mismatched `:modify`/`:remove` was a silent
  no-op the post-check confirmed as correct — while the same `:remove`
  alone (plain-ALTER path) really dropped the column. The column-level
  twin of Run 15's table-name root pattern. FIX: `same_column?` ASCII-folds
  in both engine and model; the emitted definition keeps the stored
  spelling; and a change naming a column the table does not have now
  REFUSES loudly (`refuse_unknown_column!`) instead of silently doing
  nothing.
- **F-B7-22 (S2, CONFIRMED + FIXED, RED→green).** For triggers,
  `sqlite_schema.tbl_name` stores the spelling the CREATE TRIGGER used —
  not the table's stored spelling — so `fetch_table_triggers!` missed a
  differently-spelled trigger and the rebuild dropped it. The Run 17
  post-check (which folds) caught the drop and aborted with an error
  blaming the library, making the migration impossible; without the check
  it is a silent trigger loss. FIX: `lower(tbl_name) = lower(?1)` in the
  trigger fetch AND the index fetch (indexes happen to be normalized by
  SQLite; the rule is now one rule).
- **F-B7-23 (S2, CONFIRMED + FIXED, RED→green).** `pragma table_xinfo`
  strips the parentheses SQLite's grammar REQUIRES around an expression
  DEFAULT, and the engine re-emitted the bare inside text — so any table
  carrying `DEFAULT (datetime('now'))` (the standard timestamp idiom)
  could never be rebuilt: every `:modify` died on `near "(": syntax
  error` pointing at nothing. FIX: `carried_default` re-wraps a
  carried-over default that is not a plain literal
  (`@literal_default_pattern`: numbers, quoted strings, blob literals,
  NULL/TRUE/FALSE, CURRENT_*).
- **F-B7-24 (S2, CONFIRMED + FIXED, RED→green).** The model rendered a
  `{:fragment, "(...)"}` default WITH its parentheses while SQLite stores
  it stripped — so a correct, idiomatic `modify ..., default:
  fragment("(datetime('now'))")` was aborted by the post-check as an
  engine bug (a false ALARM, blocking the migration outright). FIX:
  `strip_outer_parens` (one balanced outer pair; a miscount leaves the
  text unstripped and fails loudly, never silently). The law generator's
  literals-only default coverage — the reason neither default bug
  surfaced in Run 17 — is a filed generator-widening seed.
- **F-B7-25 (S2, CONFIRMED + FIXED, RED→green).** `references(...)` in a
  rebuild block raised `UnsupportedTypeError` inspecting the whole
  `%Reference{}` struct at the user — wrong classification (it is not a
  type) and zero guidance, for two idiomatic shapes: `add ...,
  references(...)` beside a `:modify` (the add alone works on the plain
  path), and `modify :col, references(...)` (Ecto's documented way to
  repoint an FK, which SQLite can only do via rebuild). FIX:
  `refuse_reference_changes!` pre-flight (before the model can trip over
  the struct) raising an ArgumentError that says what to do instead. The
  natural follow-up — merging an added/modified reference into the
  reconstructed FK clause list, making `modify references` actually work —
  is filed as a feature candidate.
- **F-B7-26 (S3, CONFIRMED + IMPLEMENTED under the F-B7-16 ruling).**
  `modify :id, ..., primary_key: false` reached the keyless end state
  through a different door than `:remove` and met no refusal ("a rebuild
  never silently strips a table's key" is the ratified rule). FIX: the
  shared `surviving_primary_key_members` now tracks de-keying
  (`pk_removed`, last-wins per the pinned repeated-modify contract), and
  the engine refusal covers both doors — while a change set that GRANTS
  another column `primary_key: true` (a key MOVE) stays allowed, with a
  companion test pinning it.
- **F-B7-27 (S3, FILED).** A rebuild drops the table's `sqlite_stat1`
  rows (DROP TABLE deletes them; nothing restores them), so the query
  planner falls back to built-in guesses until the next ANALYZE. Silent,
  invisible to the post-check. BACKLOG with the doc remedy owed to the
  Gate-3 docs pass (the STE README drafts must gain the line too).
- **CLEAN (reviewer-driven; orchestrator re-drove the failing legs and the
  fact probes; clean-leg probes accepted on the reviewer's RED controls):**
  table-name reads (`fetch_user_indexes!` normalization, the
  populated-referencing refusal incl. `table_has_rows?` +
  `fetch_incoming_action_fks`, case-mismatched `alter table(:UPPER)`
  end-to-end); modify-merge controls (FK/UNIQUE/composite-member modifies,
  `primary_key: true` × AUTOINCREMENT, `from:` inertness); the adjacent
  AUTOINCREMENT spelling + the F-B7-17 empty-table anchor; stranded
  constraints refuse loudly pre-destruction (table-level UNIQUE / FK over
  a removed column); `flush()` mid-migration; a rebuild racing an open
  read transaction fails loudly with a consistent reader snapshot +
  integrity_check ok; the Run 21 B5 handoff CLOSED CLEAN (a custom-named
  standalone unique index survives a rebuild AS a named index — origin
  "u" only feeds table-level clauses — and post-rebuild
  `unique_constraint(:col, name:)` still converts, with the B5 emission
  rule interacting correctly); churn review (B5's Run 21 commits touch
  zero engine files; the Run 17 delta's wiring is correct: post-check
  before COMMIT, sanctioned rescue, defer restore — its two new-code bugs
  are F-B7-20/24 above); four refusal flavours OUTSIDE the law
  property's ten (foreign trigger, populated SET DEFAULT, transient-name
  collision, missing table) all loud and mutation-free.

- **Gate self-check (the law layer catching the gate's own fixes, the
  Run 17 dynamic again):** the first gate verify came back RED twice-over
  on the orchestrator's own changes. (1) The key-move allowance was
  implemented engine-side only — the model's `predict` still refused
  `survivors == []`, so the post-check aborted the new key-move companion
  test as an engine bug; the allowance is now mirrored in `predict`
  (same grants rule), and `key_position`'s inline-key clause moved first
  so a granted key predicts `pk = 1` even after a composite de-key.
  (2) The law property found a GENERATOR case within 31 runs: it emitted
  `remove :col` followed by `modify :col` — previously a silent no-op on
  both sides, now loudly refused by `refuse_unknown_column!`. Triaged
  per the harness-vs-lib rule (the `14e6692` precedent): refusing a
  change that names a dropped column is the intended new contract, so
  the generator's `normalize_change`/`normalize_removal` now drop
  changes naming already-removed columns (a modify of one, and the
  keep-a-double-removal branch flipped to drop). Second verify GREEN.

### Verdict + dryness

- 1 S1 + 5 S2 fixed at gate + 1 S2 fixed as loud pre-flight
  reclassification + 1 S3 implemented under a standing ruling + 1 S3
  filed. 12 committed tests (11 RED on the old engine via the stash
  pattern + 1 key-move companion). `mix verify` GREEN — the
  orchestrator's own exit-file-gated run (second attempt; the first was
  the RED self-check above).
- Dryness: heavy finding-run + fix churn — **B7 stays 0 of 2, NOT DRY**.
  Re-wet triggers extended: `same_column?`/`refuse_unknown_column!` /
  `carried_default`/`@literal_default_pattern` / `rowid_copy_needed?` /
  `grants_inline_key?` / `refuse_reference_changes!` /
  `strip_outer_parens` / the widened `autoincrement_declared?` / the
  `pk_removed` tracking in `surviving_primary_key_members`.
- Completeness critic (next B7 pass, from the reviewer + the gate): finish
  the COLUMN-name sweep beyond `apply_change` (`fetch_existing_columns!`'s
  raw MapSet on the plain conditional path; copy-pair matching); enumerate
  every engine↔model SHARED helper and decide per case whether shared
  answers are agreement or a shared blind spot (F-B7-20's class);
  widen the law generators (fragment/expression defaults, references,
  `primary_key: false` merges, case-varied change names, the ASC
  AUTOINCREMENT spelling, the four ungenerated refusal flavours); put
  rowid (presence + min/max) into the structural snapshot; the
  comment-interposed-keyword class is wider than F-B7-6's entry (the
  autoincrement predicate shares the shape — reworded in BACKLOG);
  `read_sequence`'s bang-read asymmetry (post-check raises a bare
  no-such-table on a spurious predicate match in an AUTOINCREMENT-free
  database — reachable only through that door); error-quality pass on
  the loud-but-bare paths (stranded-constraint removals surface raw
  SQLite text a pre-flight check could name in domain terms).

---

## Run 23 — 2026-08-20 — lap 3, batch 3: B3 + B9 (0.11.0 delta absorption)

- Commit at scan: `d646d97`. Deps at xqlite 0.11.0 from Hex. Single Opus
  reviewer over both axes; orchestrator re-drove every finding probe
  (atomicity ×2, idiomatic-reach, busy-observer, disconnect-gap,
  lookup-span asymmetry, storms) — all verdicts identical — implemented
  the S1 fix + all doc fixes, captured suite RED via the stash pattern
  (driver.ex stashed under the new tests → exactly the 2 designed
  failures), own exit-file-gated `mix verify`.

### B3 — the ON-CONFLICT-ROLLBACK seed settled against the code, plus the with_xqlite busy footgun

- **F-B3-5 (S1, CONFIRMED + FIXED AT GATE, RED→green).** The Run-14 seed,
  worse than filed: a constraint declared `ON CONFLICT ROLLBACK` (or an
  `INSERT OR ROLLBACK`) violated inside `Repo.transaction/2` makes SQLite
  roll back the WHOLE transaction and return to autocommit — while the
  driver's bookkeeping still says a transaction is open. Every later body
  statement then ran in autocommit and COMMITTED DURABLY; at the end the
  COMMIT failed ("cannot commit - no transaction is active"), the
  connection recycled, and the caller was told the transaction failed
  with part of its work on disk. Reachable from textbook Ecto (a
  by-the-book `unique_constraint/1` changeset whose error the body
  handles and carries on — probed end-to-end: pre-violation write gone,
  post-violation write durable, transaction reports failure). The ABORT
  control is clean, the pool recovers (40/40), the failure is loud —
  the S1 is for the durable partial write. FIX: `handle_execute/4`'s
  error path now asks SQLite whether the transaction still exists
  (`NIF.transaction_status/1` — the same read `handle_status/2` makes; a
  dirty-scheduler ~0.85 µs call, error-path only, only while a
  transaction is supposed to be open) and returns
  `{:disconnect, wrapped, state}` when it is gone — DBConnection tears
  the transaction down at the point of damage and no later body
  statement can run. The caller now receives the ORIGINAL constraint
  violation, not the trailing commit failure — which also absorbs
  **F-B3-6 (S3)**: the "cannot commit" error carried no structured
  discriminator (generic code 1/1) and stops being the caller's view;
  its residual (classifying no-active-transaction commit failures
  structurally, for other causes) is noted here, not filed. Tests: a
  driver-callback pair (disconnect at damage + an ordinary in-txn error
  stays `{:error, ...}` with the transaction open — the
  over-disconnect control) + a PoolRepo atomicity test (no body write
  after the violation survives; RED on the old driver = the leaked
  write, count 1).
- **F-B3-4 (S2, CONFIRMED; adapter side FIXED as docs, xqlite side
  FILED).** A busy OBSERVER installed through `with_xqlite`
  (`Xqlite.register_busy_observer/2` — the composition the README
  advertises for busy observability) replaces the connection's ONE busy
  slot: with no retry policy the master callback answers "give up", so
  the pooled connection stops honoring the configured `busy_timeout`
  entirely (403 ms → 0 ms on the probe) — and UNregistering empties the
  slot without restoring the timeout (still 0 after; only
  `PRAGMA busy_timeout` / `Xqlite.busy_timeout/2` repairs it). The
  poisoning outlives the callback for the life of that pooled
  connection. Adapter fix in-run: `with_xqlite/3` moduledoc gains a
  "connection-scoped state persists" section naming the busy slot
  hazard and `Xqlite.busy_timeout/2` as the restore path. Xqlite-side
  fork FILED in BACKLOG (xqlite court): doc the slot replacement on
  `register_busy_observer/2` (the warning exists on its siblings), and
  consider remembering + restoring `busy_timeout` when the slot
  empties, so unregister is a true undo — same busy-slot surface as the
  F-B5-8 design fork, one adversarial lap should cover both. Knock-on
  handed to B5: `busy_budget/1` reads 0 under an observer → the
  unique-name lookup budget collapses and emission turns
  timing-dependent on such connections.
- **CLEAN (orchestrator re-drove storms; leg evidence reviewer-run):**
  busy-API determination re-confirmed at 0.11.0 (driver.ex churn since
  `3c58c5c` = the Run-21 wrap_execute_error resolution hunks only; no
  policy API anywhere; forced busy 202 ms vs 200 ms timeout, structured,
  writable after); dirty-reader flip neutral (8000/8000 flipped reads +
  2000/2000 writes overlapped, baseline-derived 10× ceiling honored,
  pool healthy); standing storms (cold-start 300/300 with wal after;
  hot-row exact-200; F-B3-2 first-boot noise present and self-healing as
  documented).
- Dryness: an S1 + an S2 — **B3 stays 0 of 2, NOT DRY**. Re-wet triggers
  ALSO: `disconnect_if_rolled_back/2` / any `handle_execute` error-path
  change / `with_xqlite/3` checkout semantics.
- Completeness critic (next B3 pass): F-B3-5 under the SQL Sandbox (the
  sandbox's isolation IS a never-committing outer transaction; if an ON
  CONFLICT ROLLBACK violation destroys it, later test writes autocommit
  into the real test database — same shape as F-B3-3 with worse blast
  radius; now partially mitigated by the disconnect guard, but the
  sandbox interaction is unprobed); the connection-scoped-state FAMILY
  through with_xqlite (authorizer, extensions, session pragmas, hooks —
  only the busy slot was probed); F-B3-4 at pool_size > 1 (intermittent
  poisoning); a cancelled DML inside an explicit transaction (SQLite
  auto-rolls-back the whole transaction on interrupt of
  INSERT/UPDATE/DELETE — does the timeout path leak the same F-B3-5
  shape? belongs with the B8 re-cover); a cross-process contention
  wedge (this pass used a second in-VM connection).

### B9 — the disconnect event's documented trigger was never true, and the lookup is invisible

- **F-B9-5 (S2 doc-behavior divergence, CONFIRMED + FIXED as docs).**
  `[:xqlite_ecto3, :disconnect]`'s documented trigger ("pool closes a
  connection") never fires on a graceful pool or application shutdown —
  DBConnection's connection process does not trap exits, so terminate
  never runs; the event fires only on error-driven teardowns
  (orchestrator-re-driven: 0 events on `Supervisor.stop` and
  `Repo.stop`, 1 on the error control). Anyone following the guide's
  connect-vs-disconnect counter pattern gets permanently unbalanced
  counters. FIX (docs — trap_exit is not the adapter's to set): the
  guide row and the moduledoc now state the real trigger and say
  plainly that connect/disconnect counts are not a balanced pair.
- **F-B9-4 (S3, CONFIRMED, FILED).** The unique-index-name lookup runs
  1+N pragma reads inside the `handle_execute` span with no span of its
  own, while `fk_diagnostics` (the sibling error-path replay) has one —
  and Run 21 proved the lookup can bill a full `busy_timeout`, invisible
  to dashboards. FILED with the proposed span shape
  (`[:xqlite_ecto3, :unique_index_names, :*]`, start `%{conn, table,
  columns}`, stop `%{candidate_count, lookup_status, index_reads}`);
  the guide's "glue" sentence no longer implies the gap is
  microseconds (updated in-run).
- **F-B9-6 (S3, CONFIRMED + FIXED as docs).** The documented surface
  omitted keys every consumer sees (`system_time` on `:start`,
  `telemetry_span_context` on every span event), grouped measurements
  so `:start` read as carrying `duration`, omitted the
  `fk_diagnostics` event from the moduledoc entirely, and the guide's
  disconnect row omitted `:reason`. All four corrected in-run
  (moduledoc span-contract preamble + error-path-diagnostics section;
  guide row + pairing note).
- **CLEAN:** emission churn `458dc0c..d646d97` = the two Run-21
  driver.ex hunks only, zero new emission sites (fk_diagnostics.ex /
  telemetry.ex / open_telemetry.ex byte-identical by blob hash); flag
  bleed disproven both directions (compiled flag VALUE checked, not
  exit codes); event-surface spot-drive 20/21 documented checks pass
  (the 21st is F-B9-5; the fabricated-event control proves absence is
  reportable); dirty-flip neutrality (1200/1200 spans paired, integer
  nanoseconds, synthetic-unpaired control caught); OTel mapping
  byte-unchanged.
- Dryness: finding-run (one S2 + two S3s) — **B9 stays 0 of 2, NOT
  DRY**. Re-wet triggers ALSO: any `disconnect_if_rolled_back` /
  telemetry moduledoc surface edit / `guides/wiring_telemetry.md`
  event-table edit.
- Completeness critic (next B9 pass): drive an `:exception` phase on at
  least one span (all failures produce `:stop` + `result_class:
  :error` today); re-drive the OFF-build smoke (this pass checked the
  compiled flag value only); verify `cached_count`'s
  before-the-action semantics numerically; decide whether the
  `with_xqlite` bridge checkout (RawConn clause, no span — all bridge
  work invisible to adapter telemetry) deserves an event, together
  with the F-B9-4 span; count `:checkout` events against actual
  checkouts; after the docs remedies, re-read both doc surfaces
  against a fresh live capture.

---

## Run 24 — 2026-08-20 — lap 3, batch 4: B2 second cover (post-refusal-churn audit)

- Commit at scan: `3eb465e`. Single Opus reviewer; orchestrator re-drove
  the four load-bearing isolate-runs (migration.exs:640 → the reference
  refusal at `refuse_reference_changes!/2`; :705 → SQLite's own "Cannot
  add a PRIMARY KEY column", no adapter frame; type.exs:85 → Jason
  `Protocol.UndefinedError` on `%Duration{}`; migrator.exs:197 vs :198 →
  the line-filter snap), implemented every doc fix, own exit-file-gated
  `mix verify`. The Run-16-banked vendored-file isolation method was the
  instrument throughout (26 tag sites + 6 locations, all isolate-run).
- **F-B2-12 (S2 doc divergence, CONFIRMED + FIXED as docs).** The three
  ALTER rationales (`:alter_primary_key`/`:alter_foreign_key` block, the
  migration.exs:664 block, four tags-doc rows) still blamed the missing
  `DataType.column_type/2` clause — a code path Run 22's
  `refuse_reference_changes!` made UNREACHABLE (the refusal now fires
  first with guidance). A maintainer following them was sent to the
  wrong fix. All reworded to name the refusal and point at
  F-B7-25-feature; F-B2-7-code folded into that entry as superseded.
- **F-B2-13 (S3, FIXED as docs).** "The rebuild engages for these" was
  false for migration.exs:705 — `add :id, :serial, primary_key: true`
  contains no `modify`, never enters the rebuild, and dies on SQLite's
  own ALTER refusal. The two `:alter_primary_key` tests fail for two
  separate causes; the block now says which is which.
- **F-B2-14 (S2 doc divergence, CONFIRMED + FIXED as docs; code seed
  filed).** `:duration_type`'s "SQLite has no native duration/interval
  type" misattributed OUR gap: Ecto's `:duration` dumps a `%Duration{}`,
  `encode_param/1`'s `is_map` catch-all feeds it to `Jason.encode!`, and
  the raise lands in lib/xqlite_ecto3/ (frame-attribution rule).
  Reworded to own it. ADJACENT filed ([F-B2-14-adjacent], B4 court,
  orchestrator-unverified): ANY struct param without a Jason.Encoder
  surfaces as a raw Protocol.UndefinedError instead of a structured
  adapter error — the B4 re-cover adjudicates.
- **F-B2-15 (S3, FIXED as docs).** The `:lock_for_migrations` rationale
  pointed at migrator.exs:197 — the `@tag` line; an ExUnit line filter
  snaps to the nearest test AT OR BEFORE the line, so the codified
  isolation method silently ran the PRECEDING (passing) test — a false
  all-clear generator. Pointer fixed to :198; F-B2-8's two citations
  corrected the same way (type.exs:523, interval.exs:194); the
  snap-behavior rule is now written into both the helper comment and
  the tags doc's Location section as a standing discipline.
- **F-B2-16 (S3, FIXED as docs).** The `:array_type` row read as
  "arrays unsupported" while the adapter ships `{:array,_}`→TEXT plus
  `Types.Array` with round-trips; what cannot work is the Postgres
  array OPERATOR surface (`x in t.ints`, `push:`/`pull:`) and
  untyped/fragment decoding. Row now says so. Method caveat recorded:
  `:array_type`/`:bitstring_type`/`:duration_type` isolate-runs are
  SELF-FULFILLING (the shared migration skips their tables under the
  exclusion), so their ground truth comes from test-body reading or an
  adapter-owned probe — seeded.
- **CLEAN:** every other audited rationale tells the truth at HEAD —
  six permanent-limit tags correctly attributed (no adapter frame),
  `:lock_for_migrations`' substance, `:alter_primary_key`'s :705 half,
  all six location exclusions re-verified against their documented
  mechanisms (transaction.exs:161's pool story intact; alter.exs:44
  NOT unlocked by Run 22's default fixes). Run 23's disconnect guard
  is a genuine no-op for the vendored surface (zero OR-ROLLBACK
  shapes). Count sweep: 32 exclusions, exactly the two known
  over-broad singles (F-B2-8 counts unchanged), no new over-breadth.
  Exclusion list + shared-suite versions drift-free since Run 16.
  Full-suite anchor: exit 0, vendored `434 passed / 32 excluded` —
  zero delta across four commits of engine and driver churn.
- Dryness: finding-run (2 S2 + 3 S3, all doc-class) — **B2 stays 0 of
  2, NOT DRY**; the next B2 pass covers the reworded surface. Re-wet
  triggers ALSO: `Query.encode_param/1`'s clause list and the
  exclusion-awareness list in the shared support migration.
- Completeness critic (next B2 pass): adapter-owned probes that break
  the three self-fulfilling exclusions; sweep the "supported (n/m)"
  rows' counts at HEAD (`:json_extract_path` 4/5,
  `:insert_cell_wise_defaults` 7/8, `:assigns_id_type` 3/4 — nobody
  re-checked them); line-pointer discipline as a standing check;
  whether `refuse_unknown_column!`/the `pk_removed` door could hide a
  future upstream test on the next ecto/ecto_sql bump.

---

## Run 25 — 2026-08-20 — lap 3, batch 5: B4 + B8 re-covers (0.11.0 + law-aftermath absorption)

- Commit at scan: `195713a`. Single Opus reviewer over both axes;
  orchestrator re-drove all four load-bearing probes (driver-level and
  repo-level cancelled-DML leaks with their read-only controls; the
  26-case decimal edge harness; the parameter-error shapes) — every
  verdict identical — implemented all three fixes, captured suite RED via
  the stash pattern (three lib files stashed under the new tests →
  exactly the 12 designed failures, every control green on the old code),
  own exit-file-gated `mix verify`.

### B8 — the flagship's sharpest question settled against the code

- **F-B8-4 (S1, CONFIRMED + FIXED AT GATE, RED→green).** The Run-23
  handoff seed: SQLite rolls back the ENTIRE transaction when it
  interrupts an INSERT/UPDATE/DELETE (`sqlite3VdbeHalt` →
  `sqlite3RollbackAll`, autocommit restored) — and the adapter's timeout
  IS that interrupt. The `{:error, :operation_cancelled}` branch returned
  a plain error tuple that DBConnection does not disconnect on, so after
  a cancelled write inside `Repo.transaction` every later body statement
  ran in autocommit and COMMITTED DURABLY while the transaction reported
  failure — the F-B3-5 atomicity break through the timeout door, on BOTH
  statement paths (cached and one-shot), proven at driver level (leaked
  ids visible to an independent connection before any commit) and through
  a real pool (`rows_surviving_a_FAILED_transaction = [30]`; read-only
  cancel control atomic). Why Run 11 missed it: both in-transaction
  cancellation pins cancel a SELECT, and read-only interrupts roll
  nothing back (re-confirmed at 0.11.0 — the Run 11 result stands, it
  just never generalized to writes). FIX: the cancelled branch now routes
  through the same `disconnect_if_rolled_back/2` guard Run 23 added —
  correct in all three situations (cancelled write in txn → disconnect at
  the point of damage; cancelled read in txn → error with the transaction
  open; cancelled statement outside a txn → error, connection reusable),
  at the cost of one status read on the cancelled path only. Tests: a
  driver-callback pair (cancelled write disconnects; cancelled read stays
  an error with the transaction open — the over-disconnect control) + a
  pooled atomicity test (no body write after a cancelled write survives a
  failed transaction; RED on the old driver = one leaked row). Post-fix
  probe disposition: the repo-level probe flips to PASS (both failed
  transactions atomic); the driver-level probe still prints FAIL by
  design — its `slow_return` now reads `{:disconnect, …}` (the fix
  signaling) and the probe then keeps driving the same state by hand,
  which DBConnection never does after a disconnect verdict; the
  raw-callback layer cannot stop a caller that ignores the verdict.
- **F-B8-5 (S3, CONFIRMED, FILED).** Timeout precision under
  dirty-scheduler saturation: the cancel token/cancel_operation NIFs stay
  on normal schedulers (correct — the canceller always runs), but a
  statement waiting for a dirty IO slot has not started, so the caller
  waited 11.3 s against a 100 ms deadline (113×) with 12 long queries
  saturating 10 dirty schedulers. Structured error and healthy connection
  throughout — only the timing promise breaks, and no pool-side deadline
  can rescue a caller suspended before its statement runs. Not a 0.11.0
  regression (`stmt_multi_step_cancellable` was already dirty). FILED as
  a docs line (the timeout bounds how long the QUERY runs, not how long
  the CALLER waits, under dirty saturation) — owed to the Gate-3 docs
  pass + the STE README drafts.
- **Ledger correction (append-only honesty), Run 7:** the DirtyIo
  flip census said five adapter-called NIFs flip at the dep bump; the
  driver actually calls `transaction_status/1` (already DirtyIo at
  0.10.0), not `txn_state`. The true hot-path flip count at `c24383b` is
  THREE (`stmt_column_names`, `changes`, `total_changes`), plus
  `register_progress_hook` off-path; `create_cancel_token` and
  `cancel_operation` remain normal-scheduler — the right arrangement.
- **CLEAN (orchestrator re-drove the leak probes; leg evidence
  reviewer-run with controls):** core timeout at 0.11.0 — 100 ms deadline
  honored at 101 ms on BOTH the cached and the one-shot path, structured
  `%DBConnection.ConnectionError{}`, connection reusable, `:infinity`
  control runs 4.6 s (the probe measures cancellation, not a fast
  query); encode-raise hygiene re-anchored (no canceller spawned, zero
  process/mailbox delta, cancel path immediately functional);
  `handle_status/2` accurate mid-cancellation (reports `:idle` right
  after a cancelled in-txn write, matching SQLite — the oracle the fix
  now consults).
- Dryness: an S1 — **B8 stays 0 of 2, NOT DRY**. Re-wet triggers ALSO:
  the cancelled branch of `handle_execute` / `disconnect_if_rolled_back`.
- Completeness critic (next B8 pass): SAVEPOINTS (rollback-on-interrupt
  destroys them too — a cancelled write inside a nested Repo.transaction
  is the same shape through `handle_rollback(:savepoint)`); the SQL
  Sandbox × cancelled write (the sandbox's never-committing transaction
  destroyed → later test writes autocommit into the real test database —
  now partially mitigated by the guard, unprobed); a stream running in a
  transaction a sibling cancelled write rolled back; F-B8-5 through a
  multi-connection pool; the guard's own status read queuing under dirty
  saturation.

### B4 — the guard was over-refusing what SQLite stores exactly, and the encoder gap adjudicated

- **F-B4-3 (S2, CONFIRMED + FIXED AT GATE, RED→green).** The decimal
  guard converted EVERY value through float64 before modeling storage —
  but the bind path sends TEXT, and NUMERIC affinity stores a plain
  integer literal that fits int64 as an EXACT INTEGER with no float64
  anywhere. So every whole number past 2^53 was refused
  (`DecimalPrecisionError` claiming it "would silently round" — false
  for these) while the identical digits round-trip exactly: 26-case
  harness → 6 over-refusals (2^53+1, i64 max, 17-19-digit integrals),
  ZERO false accepts, and the asymmetry that i64 MIN was accepted (it is
  float64-exact) while i64 MAX was refused. FIX: a fast-accept keyed on
  the RENDERED form — `Decimal.to_string(d, :normal)` parsing as a plain
  integer literal within int64 — which is strictly more faithful than
  the reviewer's value-based sketch: the same VALUE written "…0.0"
  renders with a decimal point, SQLite parses that text as REAL, and the
  float64 model stays its judge (pinned by a new refuse test for exactly
  that form; the F-B4-2 class remains refused). Module premise comment
  corrected (bound as TEXT; two storage paths); 6 accept pins + 1
  render-form refuse pin + a NIF-level storage ground-truth test
  (typeof = integer, exact digits) committed.
- **F-B4-4 (S2, CONFIRMED + FIXED AT GATE, RED→green) — closes
  [F-B2-14-adjacent].** `encode_param`'s map/list clauses called
  `Jason.encode!`, so any struct without a `Jason.Encoder` (a
  `:duration` field's `%Duration{}` — Ecto does not validate what
  `dump/1` returns), any nested such struct, and any JSON-unrepresentable
  value surfaced as a raw `Protocol.UndefinedError`/`Jason.EncodeError`
  naming Jason, not the adapter. FIX: new
  `XqliteEcto3.UnencodableParameterError` (fields `value`, `index`,
  `reason`) raised from an attempt-then-structure `encode_json/2` — a
  deliberate refinement over the refuse-all-structs sketch: a struct that
  DOES implement `Jason.Encoder` keeps encoding (no behavior narrowing);
  only failures are converted, including the protocol raise (one
  narrow rescue+reraise at the documented raise boundary, same class as
  the rebuild's sanctioned rescue). Parameter positions are now threaded
  through `encode/3`, and `DecimalPrecisionError` gains the same `index`
  field. 5 committed tests (struct / nested struct / invalid-UTF8 map /
  plain-map control / decimal index).
- **CLEAN (reviewer-driven with controls; orchestrator re-drove the
  finding probes):** zero silent transformations across the full 26-case
  edge harness (the guard's core job intact; RED control = a real
  mismatch detected through the bypass path); `representable?/1` never
  raises across the float-range boundary (control: a real
  `Decimal.Error` is catchable; decimal 3.1.1 caps parsing at 34 digits
  before the guard is reached); non-finite decimals refused by Ecto
  before the adapter AND by the guard directly; the 0.11.0
  `internal_encoding_error` atom is CLASSIFIED (`type:
  :internal_encoding_error` via the `{tag, msg}` wrap clause — matchable,
  consistent with `:nif_panicked`); UUID/binary byte-stability at 0.11.0
  (11/11, all-256-bytes blob identity, 16-byte UUID storage, canonical
  text forms); churn `458dc0c..195713a` — types/ query.ex data_type.ex
  untouched, decimal_precision.ex = the F-B4-2 fix, error.ex = B5's
  Constraint fields only, `wrap/1` clause list unchanged.
- Dryness: two S2 — **B4 stays 0 of 2, NOT DRY**. Re-wet triggers ALSO:
  `integer_literal_in_int64?/1` / `encode_json/2` /
  `UnencodableParameterError` / the `encode/3` index threading.
- Completeness critic (next B4 pass): the fast-accept's rendered-form
  predicate and the bind path's `Decimal.to_string(d, :normal)` must
  never drift — a property pinning predicate-text == bound-text (and
  loader output == `stored_decimal/1` model) would make drift loud;
  `connection.ex` `expr(%Decimal{}, …)` inlines a decimal into SQL text
  with NO precision check and could not be reached from ordinary Ecto —
  settle dead-code vs second door; decimal query COMPARISONS against
  INTEGER-stored whole numbers (mixed storage classes in WHERE); `-0`
  decimal sign loss (numerically equal, sign gone — the float `-0.0`
  law-projection sibling, unpinned); `{:array, :duration}` and
  collections of unencodable structs (mechanism covered, coverage not);
  adversarial pass on the int64-boundary fast-accept itself.

---

## Run 26 — 2026-08-20 — X1 + X2 forward-blast confirmations vs published 0.11.0

Single Opus reviewer, paired confirmation cover (read-only; fixes by the
orchestrator at gate). Adapter `cf2cc62`, xqlite `1dd5c2b`; deps = the hex
TARBALL of xqlite 0.11.0, verified in-probe (`Application.spec(:xqlite,
:vsn) == "0.11.0"`, `.hex` marker present, no `.git`) — the dep channel
switched from path checkout to hex this lap, so the tarball itself is in
scope for the first time. Both axes were DRY at 0.10.0 (X1 at Run 13, X2
at Run 9); the 0.11.0 bump re-wet both. Gate: the orchestrator re-drove
ALL nine probes plus every RED control BEFORE any edit (finding probes
exit-verified; `error_wrap_test.exs` 23/23), then implemented the three
fixes with stash-proven RED.

### X1 — API/error-shape contract

- **CLEAN (standing surface):** `error_reason/0` at 0.11.0 = **48
  distinct members (9 bare atoms + 39 tuple shapes), derived from the
  compiled beam** — exactly Run 13's 46 plus the two atoms `dd7c9f9`
  added (`:extension_loading_disabled`, `:invalid_conflict_strategy`;
  the whole `v0.10.0..v0.11.0` diff of `lib/xqlite.ex` is those two
  lines plus docs). All 48 driven live through `wrap/1` +
  `to_constraints/2`: every tag preserved, zero `type: nil`, six
  constraint kinds + two negatives correct, eight adversarial edges
  degrade without raising — 78/78. RED control: the probe builds its
  cases FROM the compiled union, so `X1_RED=1` (hide one member) trips
  the drift alarm. `{:internal_encoding_error, msg}` routes to the
  binary-payload 2-tuple clause (`error.ex:222-224` — message == the
  payload, `details: nil`), NOT the tag-preserving stringifier — the
  clause-level confirmation Run 25's B4 leg was owed; five sibling
  discriminators prove no dedicated clause is shadowed.
  `changeset_apply/3`'s spec is unchanged at 0.11.0; the doc now
  promises `:replace` aborts + rolls back the WHOLE apply on a
  conflict it cannot replace (never degrades to `:omit`) — recorded;
  both new atoms adapter-unreachable (zero `changeset_apply` /
  `session_*` / `load_extension` sites in `lib/` + `test/`). Forward
  blast `v0.11.0..1dd5c2b` = one commit, CLAUDE.md + two test files,
  zero `lib//native//priv/`.
- **F-X1-3 (S2, CONFIRMED, FIXED in xqlite as docs).** xqlite 0.11.0
  SHIPS documentation stating the abandoned empty-columns rule for
  `query_with_changes/3` (`xqlitenif.ex:193` "For SELECT statements
  (non-empty columns), `changes` is 0"; `README.md:299` "detected by
  empty result columns") while the code (`query.rs:95-102`) gates on
  the `sqlite3_total_changes()` delta and its own comment calls the
  columns rule "wrong twice". Measured against the real build: three
  RETURNING-DML statements contradict the doc outright (doc predicts
  0, code reports the real count) and DDL/read-PRAGMA fall outside its
  SELECT/DML split entirely. This is the exact document that taught
  the model behind Run 1's F-X2-1 (the adapter's cached-path
  re-derivation bug) — the code was fixed on both sides long ago; the
  public teaching text never was. FIX (xqlite): both sites rewritten
  to the delta rule (DML real count with or without RETURNING;
  SELECT/DDL/PRAGMA report 0; columns play no part).
  `CHANGELOG.md:514` deliberately left — history stays. RED: the
  probe's `DOC_RED=1` mode asserts the documented model and fails
  5/5, exit 1 (orchestrator-verified both modes).
- **F-X1-4 (S2, CONFIRMED, FIXED).** `{:xqlite, "~> 0.11"}`
  (`mix.exs`) resolves `>= 0.11.0 and < 1.0.0` — probe-measured to
  admit 0.12.0/0.13.0/0.99.0 — while xqlite's README reserves the
  right to break in any pre-1.0 minor, and the `0.9 → 0.10` minor
  ALREADY forced an adapter code change once (`6d571e5`, the CI break
  this axis exists for). `mix.lock` does not travel with a published
  package, so the bound is what downstream resolves; reachability
  turns on at the first Hex publish (imminent by program design —
  graded on that basis). Neither README carried a compatibility
  statement (charter requirement). FIX: bound tightened to
  `{:xqlite, "~> 0.11.0"}` with the pin-one-minor rationale as a
  comment; compatibility rows added to BOTH live READMEs and folded
  into BOTH STE drafts (swap-safe). xqlite's own install snippet
  (`~> 0.11` for end applications) deliberately untouched — apps own
  their lock files; the lockstep constraint is library-to-library.
- Dryness: two S2 — **X1 stays 0 of 2, NOT DRY**. Re-wet triggers
  ALSO: the compatibility rows (every future bound change owes them a
  sync) and xqlite's `query_with_changes` doc surface.

### X2 — cross-repo blast radius

- **CLEAN (standing surface):** call-site census at `cf2cc62` — the
  Run 5/9 method first re-validated at both prior baselines (37+7 at
  `6d571e5`, 38+7 at `6539a14`, matching what those runs recorded) —
  reads **38 + 10 by name, 38 + 7 code-only** (a new counter: name
  followed by an open paren). The 3 extra `Xqlite.*` names are PROSE
  in the `with_xqlite/3` busy-slot doc block (`lib/xqlite_ecto3.ex:
  336-345`, from `268261a`), not calls; the executable surface is
  UNCHANGED from Run 9. Raw occurrences 63 → 67, all four attributed:
  +1 `NIF.transaction_status` (`driver.ex`, `268261a`, existing row —
  relies on `{:ok, bool}`, holds) and +3 `NIF.query`
  (`unique_index_names.ex`, `badcbcb`, existing `query` row for shape
  — plus the NEW row below for the value coupling). The durable table
  driven LIVE against the realized tarball for the first time (prior
  runs verified rows by source diff): every result-map, sentinel,
  txn/pragma/open row intact, 25/25, RED control via `ROWS_RED=1`.
  The adapter's four busy-slot doc claims all hold at 0.11.0 (802 ms
  wait → 0 ms under an observer → 0 ms after unregister →
  801 ms after `Xqlite.busy_timeout/2`; 8/8). `max_elapsed_ms`
  per-contention reset confirmed live (807 ms on BOTH the first and
  second contention under one installed policy) — discharges Run 9's
  deferred dep-bump re-probe. Channel switch byte-clean: tarball vs
  `git show v0.11.0` = 30/30 `lib/` + 25/25 `native/src/` identical,
  zero missing, every `hex_metadata.config` entry present;
  `native/xqlitenif/.cargo/config.toml` (the `STMT_SCANSTATUS` flag
  `explain_analyze` needs on a force-build) SHIPS — RED control:
  `TAG=v0.10.0` reports 16 differing files, exit 1. Forward delta
  `80210b6..1dd5c2b` per commit: `eb4e55f` = Elixir floor `~> 1.17`
  (matches the adapter's own floor), `7374ff0` = version strings +
  rusqlite 0.40.1→0.40.2 + README snippet, `1dd5c2b` = tests only;
  zero product surface; no table row moved.
- **F-X2-2 (S2, CONFIRMED, FIXED, RED→green).**
  `unique_index_names.ex` read `PRAGMA busy_timeout` and reused the
  VALUE as the lookup's wall-clock budget; `within_budget?/3` was a
  plain `<=`, so a zero budget rejected the first elapsed
  millisecond. Zero arrives two ordinary ways: `busy_timeout: 0` in
  repo config (legitimate fail-fast; accepted unvalidated at
  `driver.ex:37`) and any busy policy/observer installed through
  `with_xqlite/3` (the PRAGMA then reports 0; unregister does not
  restore it). Measured: at 23 candidate indexes the halt fired
  **10-11/50 trials at zero budget vs 0/50 at the default 5000** —
  `unique_index_lookup` becomes `{:unavailable,
  {:lookup_budget_exceeded, _}}`, the names stay empty, and a
  changeset declaring the REAL index name intermittently raises
  `Ecto.ConstraintError` instead of converting — same input,
  different outcome run to run. (Reviewer's negative honesty: at ONE
  candidate it never reproduces; recorded so the next pass does not
  chase the narrow case.) FIX: a zero budget now DISABLES the
  wall-clock check instead of allotting no time — the budget exists
  to stop lock-wait multiplication and a zero timeout means reads
  cannot block, so there is no price to multiply; the 24-candidate
  cap alone bounds the work. Moduledoc + comment now state both
  meanings. Tests: zero-semantics unit pin + a 13-candidate 30-trial
  integration pin (`unique_index_names_test.exs`; the pre-existing
  over-budget test's zero line pinned the BUG and was updated).
  Stash-RED at gate: fix stashed → 21/23 with the zero unit test
  failing; restored → 23/23. Probe disposition: `1330`'s checks 6 and
  8 pin the PRE-fix behavior and print FAIL BY DESIGN post-fix (same
  class as Run 25's cancel-leak probe).
- **Durable map: one row ADDED** (Run 1 table): `PRAGMA busy_timeout`
  via `query` — the adapter relies on the VALUE, not just the shape;
  silent break mode if any xqlite busy-slot change alters what it
  reports.
- Method note (recorded): census numbers are code-only from now on
  (name followed by an open paren); the name census stays reported
  for cross-run comparability.
- Dryness: one S2 — **X2 stays 0 of 2, NOT DRY**. Re-wet triggers
  ALSO: `busy_budget/1` / `within_budget?/3` (this run's own fix owes
  the re-cover) and the `with_xqlite` busy-slot doc block.

### Completeness critic (seeds for the next X1/X2 pass)

`Xqlite.ExplainAnalyze` + `Xqlite.Telemetry[.OpenTelemetry]` result
shapes: called by the adapter, absent from the durable table, never
driven at 0.11.0 — and `explain_analyze` depends on the shipped
`.cargo/config.toml` flag on any force-build (file present, function
undriven against the tarball build). Production-side union check:
classification is proven, but nothing verifies xqlite can still EMIT
each of the 48 shapes (a silently retired shape looks healthy).
F-X2-2 timing on slow/contended storage and at candidate counts
between 1 and 23; the post-fix zero-budget surface itself (the owed
re-cover). Busy-slot doc claims through a REAL pool (a checked-in
connection whose slot a previous `with_xqlite` emptied, handed to the
next checkout — the exact case the doc block warns about; this run
probed a bare connection). `Xqlite.backup` / `Xqlite.conn` /
`Xqlite.error` have no table rows and were not driven.
`driver.ex:37` accepts `busy_timeout` unvalidated (negative,
non-integer, `:infinity` unprobed). Probe scripts under the session
scratchpad `x1x2_cover/` (wall-clock-named, listed per finding);
ledger describes every probe + verdict, so loss to tmp cleanup is
acceptable.

---

## Run 27 — 2026-08-20 — dryness lap 4, batch 1: B5 (post-budget-fix adversarial pass)

Single Opus reviewer, read-only; fixes by the orchestrator at gate.
Adapter `f472315`, xqlite `2700446`; deps = hex tarball 0.11.0,
`XQLITE_PATH` unset throughout. Reviewer numbering self-corrected to
start at F-B5-14 (F-B5-11..13 already taken — verified at gate). Gate:
orchestrator re-drove the deciding probes personally (busy-slot facts
7/7; the budget-hole RED; the stream divergence; the emission matrix
9/9 + RED; the invisible-enforcer probe + RED; the failure sweep 8/8;
FK-replay default mix with clean cleanup legs; the positive-halt live
probe), implemented the fix, stash-RED 22/23 → 23/23.

### B5 — the Run 26 fix's own hole, found by its seeded question

- **F-B5-14 (S2, CONFIRMED, FIXED, RED→green).** Run 26 made a
  zero-reported `busy_timeout` DISABLE the lookup's wall-clock budget
  on the justification "reads that cannot block need no time cap" —
  but `PRAGMA busy_timeout` reports 0 in THREE states, and the
  justification holds in only one: a genuine zero timeout. A busy
  POLICY or OBSERVER holding the slot also zeroes the pragma
  (measured 7/7: neither removal nor unregister restores it), and
  under a policy the pragma reads DO wait, for policy-governed
  durations — with the budget gone, the wait multiplies across up to
  25 candidate reads, the exact multiplication the budget was built
  to stop. Measured pre-fix: 88/200 lookups blocked on ≥2 reads under
  rollback-journal contention (max 6 blocks, 10,841 ms total read
  time against a 2,000 ms per-read cap); a single lookup burned
  11,313 ms under a patient policy; the deciding RED's policy leg ran
  unbounded (orchestrator re-drive: max 9,811 ms, 0/20 budget halts,
  vs a plain-timeout control that stays bounded). Reachable via the
  adapter's own documented composition (`with_xqlite/3` +
  `Xqlite.set_busy_policy/2`, which persists on the pooled
  connection); needs a rollback-journal `journal_mode` (supported
  option, not default) + cross-process write contention; structural
  ceiling 25 × `max_elapsed_ms`. FIX: a zero-reported timeout now
  gets a FIXED 500 ms budget (`lookup_budget_ms/1` +
  `@zero_slot_budget_ms`) — a healthy 24-candidate lookup measures
  ~409 µs uncontended (1000× headroom), and the unexpected-pragma-
  shape branch takes the same fixed budget (it had silently flipped
  from fail-closed to fail-open in Run 26 — now neither extreme).
  Run 26's `within_budget?/3` zero clause removed (dead);
  CHANGELOG'S Run-26 entry amended to the final rule. POST-FIX
  verification (orchestrator): the policy leg's budget halts went
  0/20 → 12/20 and the blocked-read multiplication is gone; the
  residual worst case is 500 ms + ONE policy-governed read the budget
  cannot preempt — the same single-lock-wait class as filed F-B8-1
  (a caller's own policy choice for any statement; the ceiling drops
  from 25 × `max_elapsed_ms` to 500 ms + 1 ×). The probe's strict
  "bounded under policy" check therefore prints FAIL BY DESIGN
  post-fix, same disposition class as Run 25/26's inverted probes;
  the halt-fires check on the plain-timeout leg is timing-window
  dependent (0/20 on the gate machine) — the halt itself is proven
  live by the contention probe (`{:unavailable,
  {:lookup_budget_exceeded, 402}}` at a 400 ms timeout). Stash-RED:
  22/23 (the budget pin fails on the old lib) → 23/23 restored.
  The larger design fork (deadline-derived budget / per-repo option /
  xqlite slot-occupancy API; plus a budget for the FK replay) is
  FILED as [F-B5-14-fork], maintainer menu.
- **F-B5-15 (S3, FILED; comment falsehood FIXED in-run).** Streamed
  DML (`Ecto.Adapters.SQL.stream/4` with `INSERT … RETURNING`) skips
  unique-name resolution — `handle_declare`/`handle_fetch` error
  branches call `Error.wrap/1` alone; the identical violation reports
  `:ok` + the real name through `handle_execute` and `:not_run` + `[]`
  through the stream (orchestrator re-drove the divergence probe,
  exit 1). Classification stays correct, no changeset traverses a
  stream — S3. The path comment claiming "a declared query is a
  SELECT and cannot raise a UNIQUE violation" was FALSE; corrected
  in-run to state the real contract. The behavior decision (enrich
  those branches vs keep the documented gap) is the maintainer's.
- **F-B5-16 (S3, FILED; cost note FIXED in-run).** The
  rich-FK-diagnostics replay is a WRITE — it contends for WAL's
  single write lock where the unique lookup's reads do not: measured
  up to 3,006 ms replay block against a 3,000 ms `busy_timeout` ON
  TOP of the failing statement's own 2,731 ms wait (two busy waits on
  one error path). The moduledoc now states the cost; a replay budget
  folds into [F-B5-14-fork]. Cleanup CLEAN under contention on the
  orchestrator's re-drive (no open txn, `defer_foreign_keys` reset).
- **F-B5-17 (S3, FILED).** `wrap_execute_error/4` runs BEFORE
  `disconnect_if_rolled_back/2` (code-verified at gate), so both
  enrichment reads run on a connection the driver may destroy;
  under `ON CONFLICT ROLLBACK` inside a transaction the resolved
  names never reach a changeset. Remedy interacts with the Run 23/25
  disconnect guard — filed with that sequencing note.
- **F-B5-18 (S3, FILED — config footgun, public gotcha owed).**
  SQLite clamps `busy_timeout` settings past int32 (and negatives) to
  0 at the PRAGMA level, and `driver.ex` passes repo config through
  unvalidated: `busy_timeout: 3_000_000_000` ("wait forever")
  silently means NO busy handler. Discharges part of Run 26's
  `driver.ex:37` seed; `:infinity`/non-integer still unprobed.
- **F-B5-7 sweep DONE (the enumeration Run 21 owed):** every way a
  pragma read comes back empty collapses to `{:ok, []}` + derived
  name — dropped/absent table, VIEW target, no covering index,
  first-dot-split table name (the F-B5-5 shape), and an index
  vanishing between `index_list` and `index_info` (dropped silently);
  only a failing connection yields a status
  (`{:unavailable, :connection_closed}`). Exhaustive, no new class.
- **CLEAN (RED-controlled; orchestrator re-drove each):** the
  positive-budget halt survives end to end (live 402 ms halt); zero
  budget at candidate counts 2-24 × 20 trials = 0 degradations
  (Run 26's seed 6 moot and stays moot); Ecto match modes `:exact` /
  `:suffix` / `:prefix` / `%Regex{}` all convert against resolved
  real names, derived-name declarations correctly raise, 9/9 + RED;
  `insert_all`/`update_all` raise `XqliteEcto3.Error` (no changeset
  to convert) — unchanged by emission; resolution inside an explicit
  transaction converts and the repo answers after; the
  invisible-enforcer shape is CLOSED (rowid-PK duplicates classify
  `:constraint_primary_key`, the lookup never runs, innocence of the
  named sibling proven by dropping it); `unique_index_names_test.exs`
  23/23 at gate.
- Dryness: an S2 — **B5 stays 0 of 2, NOT DRY**; the fix re-wets its
  own surface again. Re-wet triggers ALSO: `lookup_budget_ms/1` /
  `@zero_slot_budget_ms`, the `handle_declare`/`handle_fetch` error
  branches, `FkDiagnostics.replay/3`, and the
  `wrap_execute_error/4`-vs-`disconnect_if_rolled_back/2` ordering.
- Completeness critic (next B5 pass): whatever lands for
  [F-B5-14-fork] needs its own lap (a deadline-derived budget touches
  the cancel-token surface); the OBSERVER-only case post-fix was
  reasoned, not measured (slot answers "give up" → reads fail fast →
  every contended violation degrades to the derived name — measure
  it, and judge against the pre-Run-26 behavior); the FK replay under
  a busy POLICY and inside a long-lived outer transaction (the
  sandbox case) under contention; streamed DML for the FK / CHECK /
  NOT NULL subtypes + `handle_declare`'s own error branch;
  `sqlite3_last_insert_rowid()` surviving the replay's savepoint
  rollback (adapter never reads it — a `with_xqlite` caller would;
  lead only); ATTACH-schema resolution under the post-fix budget;
  the 24-cap boundary with autoindexes counted (24 named + 1
  autoindex = refusal where 24 named alone resolves);
  `busy_timeout` validation (`:infinity`, non-integer).

---

## Run 28 — 2026-08-20 — dryness lap 4, batch 2: B7 (the heaviest cover of the program)

Single Opus reviewer over the rebuild engine at `f437279` (engine code
byte-unchanged since Run 22's `702429a` — `268261a`'s touch is
docs-only), xqlite `2700446`, deps = hex 0.11.0. **THIRTEEN confirmed
findings fixed in-run: 4 S1 + 7 S2 from the review (F-B7-28..38, one
S3 among them) plus TWO more S2s the gate's own generator widenings
exposed (F-B7-39, F-B7-40).** Reviewer numbering self-corrected to
start at F-B7-28 (27 taken). Gate ran as three serialized Opus
implementation batches (S1s; S2s+generators; the gate-exposed pair),
each line-reviewed, each probe-verified by the orchestrator; pre-fix
RED evidence orchestrator-re-driven on the untouched tree FIRST (all
eight finding probes exit 1; facts 17/17; cleans 15/15); final tree
re-driven across the FULL matrix; stash-RED over the combined lib
diff = **79/108 → 108/108**.

### The findings (all FIXED; statements compressed — probes carry the detail)

- **F-B7-29 (S1).** PK sort order invisible: `INTEGER PRIMARY KEY
  DESC` is NOT a rowid alias (takes NULLs, keeps real rowids) — the
  rebuild flattened it into one and a NULL key value came back as 11,
  silently, post-check green. FIX: read the key's backing index
  (origin `'pk'` via `index_xinfo`, mirroring the UNIQUE read),
  re-emit per-member `ASC`/`DESC` inline + in `modify` + in the
  composite clause; `rowid_copy_needed?` treats a single INTEGER key
  as alias only with NO backing index. Snapshot gains
  `primary_key_order` + `rowid` facts (presence via `table_list.wr`;
  count/min/max — one statement; claims gated by `key_untouched?`
  since a moved key legitimately renumbers; DESC claim
  one-directional since a key may become the rowid). Ground truth
  pinned first (probe 1344): inline DESC ≠ alias; `PRIMARY KEY DESC
  AUTOINCREMENT` rejected by SQLite; TABLE-LEVEL single INTEGER key
  IS an alias even with DESC.
- **F-B7-30 (S1; S0 weighed at gate, graded S1).** An fts5 table
  passes every pre-flight check (`sqlite_schema` types it `'table'`)
  and the rebuild silently replaces it with a plain table — shadows
  dropped, `MATCH` dead. Row text survives in the replacement (why
  not S0; the external-content variant, where text would NOT survive,
  is unprobed → seeded, and the fix forecloses it). FIX:
  `pragma_table_list.type` read in the existing storage query;
  `'virtual'` and `'shadow'` refuse pre-flight.
- **F-B7-31 (S1).** The self-wrapped dance (no caller transaction =
  `@disable_ddl_transaction`; ecto_sql runs those with NO checkout)
  split `BEGIN IMMEDIATE`/statements/`COMMIT` across pooled
  connections: non-deterministic failure above pool_size 1, and in
  ~1/3 of probe runs a pooled connection stranded INSIDE an open
  write transaction, locking the database for every writer until
  reuse. The unclosed half of F-B7-8's remedy. FIX:
  `on_one_connection/4` — `Ecto.Adapters.SQL.checkout` pins one
  connection for the whole dance; the connection-scoped
  `defer_foreign_keys` read/restore moved inside (same defect); the
  wrapped path untouched.
- **F-B7-32 (S1).** Trigger bodies compile lazily, so a rebuild
  re-created a trigger reading a column the same change set removed —
  migration green, EVERY later write dead (`no such column: NEW.a`);
  the plain-ALTER path refuses the same removal via SQLite's own
  DROP COLUMN guard. FIX: pre-flight word-scan of each trigger's
  stored SQL for removed columns (the dependent-scan's own
  over-approximation, shared `word_pattern/1` — which the gate also
  hardened for names carrying a double quote, stored doubled).
- **F-B7-28 (S2).** `add_if_not_exists`/`remove_if_exists` compared
  names as raw text while SQLite and the rebuild path fold ASCII
  case: `remove_if_exists :firstname` vs stored `"firstName"` =
  silent no-op; the guard `add_if_not_exists` exists for defeated
  loudly; the two paths disagreed on the same migration text. FIX:
  fold both sides, emit the STORED spelling.
- **F-B7-33 (S2).** Stranded-constraint removals (table-level UNIQUE
  member, FK member, indexed column) died mid-dance with raw SQLite
  text — one message actively wrong ("expressions prohibited…" from
  the double-quoted-string fallback). FIX: one pre-flight pass over
  reconstructed constraints + index SQL against surviving columns,
  named domain refusals (FK/UNIQUE structural; index by word-scan —
  an index may cover an expression no pragma names).
- **F-B7-34 (S2).** Map/list defaults: plain path JSON-encodes,
  rebuild + model had no clause → `FunctionClauseError` from
  pre-flight. FIX: one shared `DataType.json_default/1` behind all
  THREE renderers; boolean defaults now `true`/`false` on every path.
- **F-B7-35 (S2).** The unpreservable keyword scan read `CHECK` etc.
  inside string literals: `DEFAULT 'check pending'` blocked that
  table's every future rebuild. FIX: literal contents blanked in one
  left-to-right pass over all four quoting forms (`'…'`, `"…"`,
  `` `…` ``, `[…]` — the naive literal-only regex was WRONG and the
  law property caught it in 50 runs: a column named `it's_v` opened a
  bogus literal). Same blanking behind `autoincrement_declared?`
  (shared engine+model), closing F-B7-6's string-literal half; the
  comment half stays ruled.
- **F-B7-36 (S2).** The dependent-object scan refused a rebuild when
  a VIEW merely selected a column named like the table. FIX: the
  word-scan is now a pre-filter; each hit is CONFIRMED against SQLite
  by a savepointed test-rename to the dance's transient name —
  ground truth probed first: RENAME rewrites the stored SQL of true
  dependents and leaves coincidences untouched; a failed rename
  degrades to refuse-all; cleanup in `after`; runs under
  `on_one_connection`.
- **F-B7-37 (S2).** `primary_key: true` grant beside a surviving
  COMPOSITE key emitted two primary keys (`has more than one primary
  key`, mid-dance, including via the engine's own
  removed-key guidance). Fixed in batch B composite-scoped, then
  SUPERSEDED by the unified rule (F-B7-39/40 below).
- **F-B7-38 (S3).** The post-check bang-read `sqlite_sequence` where
  the engine tolerates its absence — an AUTOINCREMENT text-scan false
  match on a sequence-less database aborted before the first
  statement. FIX: same tolerance, both halves.
- **F-B7-39 (S2, GATE-EXPOSED by the widened generators).** The same
  two-keys crash beside a surviving SINGLE-column key (grant via
  `add` or `modify`). FIX (unified rule, supersedes the composite
  scoping): a grant refuses iff ANY current key member survives still
  keyed — present, not removed, not de-keyed; the one exception is
  granting a single-column key to its own column (asks for the key it
  has). Engine and model now SHARE the computation
  (`surviving_primary_key_members/2`), not mirror it.
- **F-B7-40 (S2, GATE-EXPOSED).** `modify ..., primary_key: false` on
  a composite member was silently ignored (clause re-emitted over
  every PRESENT member; post-check aborted blaming the library). FIX:
  the clause emits over members still KEYED — a de-key narrows like a
  removal; de-key-all + grant = a legal key move (single AND
  composite); de-key-all with no grant = the existing keyless refusal
  (already counted de-keys — verified, not assumed). The
  batch-B-refused composite-move shape became LEGAL; no committed
  test had pinned the refusal (grep-verified), only code + comments —
  updated, with a positive test for the move.

### Ruled/filed items — consequence updates (rulings untouched)

- **F-B7-6:** live evidence both directions — comment evasion
  silently drops AUTOINCREMENT and re-hands freed id 2; literal
  false-positive aborts blaming the library. The LITERAL half is now
  CLOSED by F-B7-35's blanking; the comment half stays
  accepted-as-limitation (probe 1444 leg 3 remains failing BY
  DESIGN).
- **F-B7-27:** the rebuild also drops `sqlite_stat4` (STAT4 compiled
  in; 1 stat1 + 8 stat4 rows → 0/0 measured). Docs line updated in
  the STE draft to name both. Probe 1530 leg 4 remains failing BY
  DESIGN (it pins the filed remedy).
- **Doc correction (live README + draft):** a populated `NO ACTION`/
  `RESTRICT` child does NOT stop the rebuild — `defer_foreign_keys`
  defers RESTRICT too (probed, fact F3); both READMEs claimed it
  fails loudly. Engine comment fix follows the same fact.

### Shared-helper audit (seed 2, graded) + generators (seed 3)

`autoincrement_declared?` and `primary_key_members` = shared blind
spots proven live (both wrong together, post-check blind);
`surviving_primary_key_members` = engine decisions computed with
model semantics (safe by luck pre-fix, now the DELIBERATE shared
rule); `default_spec`/`rendered_default`/`default_expr` had already
drifted (F-B7-34) — now one function; key placement had drifted
(F-B7-37/40) — now shared. Law generators widened: case-varied
change names; inline/table-level `ASC`/`DESC` keys + composite
per-member direction; fragment/stored-expression/map/list/boolean
defaults; `primary_key:` grants and de-keys (single + composite
moves, narrowing-by-de-key); the conditional family; ten refusal
flavors added (virtual, trigger-reads-removed, three stranded
shapes, grants beside kept keys, de-keyed-keyless pair,
partial-de-key grant). Arm-fire measured: 166 narrowing + 84
composite-move hits per 2000; law + refusal properties GREEN at
2000 runs each. Rowid facts in the snapshot would have caught
F-B7-19 (Run 22's S1) — now they exist.

### CLEAN legs (RED-controlled, orchestrator-re-driven)

Mid-dance failure atomicity on wrapped AND self-wrapped paths
(table/rows/index/`defer_foreign_keys`/pool intact); the Run 21 B5
handoff re-anchored (custom-named unique indexes survive as named,
origin `'c'` — the rebuild cannot manufacture the F-B5-9 shape);
populated CASCADE still refused; populated RESTRICT correctly NOT
refused (see doc correction); probes 1344 (17 SQLite ground-truth
facts) and 1552 (15 controls) green before AND after all three
batches; full final matrix green except the two by-design legs.

### Dryness + re-wets

Thirteen findings — **B7 stays 0 of 2, NOT DRY**, and the gate's own
fixes re-wet the axis wholesale. Re-wet triggers ALSO:
`fetch_existing_columns!`/`resolve_change`, `fetch_table_storage!`/
`refuse_virtual_table!`, `on_one_connection/4`,
`refuse_triggers_reading_removed_columns!`/`word_pattern/1`,
`refuse_stranded_constraints!`, `DataType.json_default/1`,
`without_string_literals/1`/`blanked/1`, `confirm_dependents/4`
(the savepoint rename), `refuse_key_grant_beside_kept_key!`/
`surviving_primary_key_members` as shared rule, `read_sequence`
tolerance, the snapshot's `primary_key_order`+`rowid` facts, and the
widened law generators.

### Completeness critic (next B7 pass)

Cancel mid-dance (a `:timeout` during the rebuild → the disconnect
guard fires while the rescue wants ROLLBACK and the after wants the
defer restore — reads as safe, never run). External-content fts5
OVER a rebuilt table (`content='t'` — the dependent scan sees views
and triggers only; this is also F-B7-30's true-data-loss variant).
TEMP views/triggers (`sqlite_temp_schema` invisible to both scans).
The shared-predicate decision (which facts must be read by
INDEPENDENT code — the post-check can only catch what the halves
disagree on; now partially deliberate via the shared key rule, still
undecided for autoincrement). Second loud-but-bare pass once the
stranded pre-flight exists (`foreign_key_check` violations,
deferred-FK COMMIT failures, transient-name collision).
`composite_pk_clause`'s remaining raw-name compare (`&1.name ==
name` — safe only while survivors keep stored spellings; latent
Run 15/22 root-pattern instance). The savepoint-confirm itself needs
an adversarial lap (transient-name collision path, nested-savepoint
interplay, a candidate whose stored SQL the rename rewrites
SPURIOUSLY). The literal-blanking's four quoting forms vs SQLite's
lexer corner cases. The refusal-exception design: every pre-flight
refusal is a bare `ArgumentError` with NO structured fields —
neighbors regex message prose in tests (violating the
no-text-assertion doctrine); a refusal struct with a reason atom is
FILED as a maintainer menu. The single-key
grant-to-own-column exception edge (`grants_own_key?`) under
case-varied spellings.

---

## Run 29 — 2026-08-20 — dryness lap 4, batch 3: B3 + B9 paired cover

Single Opus reviewer at `8618fbd`, xqlite `2700446`, deps hex 0.11.0.
Reviewer numbering self-corrected to F-B3-7 / F-B9-7 (6 taken on both,
verified at gate). Churn verified by blob hash in `3eb465e..8618fbd`:
telemetry emission surfaces byte-identical since Run 23; `driver.ex`'s
only substantive hunk = Run 25's cancelled-branch routing; Run 28
touched migration code only. Gate: all eight RED probes + both
load-bearing cleans re-driven by the orchestrator pre-fix; one Opus
implementation batch (nine fixes); decisive probes re-driven post-fix;
stash-RED 16/20 → 20/20; 94 targeted tests green at gate.

### B3 — the guard the last two runs made load-bearing had two doors it did not cover

- **F-B3-7 (S2, CONFIRMED, FIXED, RED→green).**
  `disconnect_if_rolled_back/2` pattern-matched the CACHED
  `transaction_status: :transaction`, which a raw-SQL `BEGIN`
  (`Repo.query`) never sets — and DBConnection calls `checkout/1`
  exactly once per connection at connect (source-verified + measured:
  55 queries, 0 further checkouts), so the flag never re-syncs. Both
  doors leaked durable post-failure writes inside a transaction the
  caller was told failed: an ON-CONFLICT-ROLLBACK violation and an
  ORDINARY TIMEOUT (probes: after-write durable, `ROLLBACK` → "cannot
  rollback - no transaction is active"). Reachability discount from
  S1: raw-SQL transactions are non-idiomatic — but the adapter's OWN
  rebuild engine uses the pattern, and its "cannot drift" comment was
  false. FIX: after any successful COLUMNLESS statement whose leading
  keyword is transaction control (whitespace skip → first-byte guard
  on B/C/E/R/S both cases → ≤9-letter word-boundary slice → membership
  in BEGIN/COMMIT/END/ROLLBACK/SAVEPOINT/RELEASE), one
  `NIF.transaction_status` read updates the cached flag. Measured
  cost: ~9 ns for non-matching DML, ~181 ns for CREATE-class
  first-byte collisions, ~150 ns + one status read for actual
  transaction control — noise against any statement. `ROLLBACK TO`
  cannot false-idle the flag (the read asks SQLite, never infers);
  the managed savepoint counter is untouched; a NIF error leaves the
  flag alone. Both stale comments rewritten. Gate re-drive: the
  checkout-pinned raw arms now DISCONNECT AT DAMAGE (after-write and
  rollback both report the closed connection; zero durable leaks);
  plain failed autocommit queries do NOT disconnect (control).
  RESIDUALS (recorded, not defects of the fix): (a) probe 1615's arm
  D — a raw `BEGIN` with NO `Repo.checkout` on a pool_size>1 pool —
  still leaks ONE durable row and keeps the probe exit 1 BY DESIGN:
  its statements are not tied to any single connection, which no
  pooled adapter can protect (the guard now disconnects at the
  violation, an improvement; the next write simply lands on a fresh
  autocommit connection). Pre-existing, inherent, identical on every
  pooled database adapter. (b) COMMENT-PREFIXED transaction control
  (`/* c */ BEGIN`) evades the leading-keyword check — the F-B7-6
  comment-class sibling; costs only the pre-fix staleness for that
  spelling.
- **F-B3-8 (S2, CONFIRMED, FIXED, RED→green).** `handle_declare` and
  `handle_fetch` error paths returned plain errors — streamed
  `INSERT … RETURNING` hitting a ROLLBACK-class constraint (with the
  raise swallowed) leaked a durable post-error write; now both route
  through the guard. Probe exit 1 → 0.
- **F-B3-9 (S2, CONFIRMED, FIXED as docs).**
  `Xqlite.enable_load_extension(conn, true)` through the bridge
  leaves SQL-LEVEL `load_extension()` callable on that pooled
  connection for its lifetime (probed: "not authorized" → SQLite
  attempts the dlopen), reachable from any later statement including
  injected SQL — the moduledoc named loaded extensions but not the
  standing PERMISSION. The connection-scoped-state section now names
  it with the restore call. (Escalation needs injectable SQL — the
  S2 discount.) Probe stays exit 1 BY DESIGN (pins the live hazard
  the docs now warn about). xqlite-court addendum filed with the
  busy-slot pair (no restore-on-disable story upstream either).
- **F-B3-10 (S3, CONFIRMED, FIXED as docs).** A poisoned (fail-fast
  busy slot) connection is handed back instantly and preferentially
  reused: 2 poisoned of 4 absorbed 23/24 contended writes at 0-1 ms.
  Post-Runs-26/27 chain re-derived: the lookup budget HOLDS (500 vs
  400 ms per connection), no collapse — the residual is the
  fail-fast itself plus per-connection budget variance. One
  amplification sentence added to the moduledoc.
- **CLEAN (controls named):** the FLAGSHIP seed — ON CONFLICT
  ROLLBACK under the SQL Sandbox — is CLEAN BECAUSE the guard fires:
  ecto_sql's `post_checkout` re-begins the sandbox transaction on the
  replacement connection; later writes roll back at checkin;
  ownership survives (leak-detector control: a deliberately committed
  row IS seen). The guard is load-bearing — F-B3-7/8 were exactly its
  two missing doors. Connection-scoped-state family (pool_size 1):
  session PRAGMA persists (documented; quietest member — silent
  orphan acceptance); authorizer persists and `remove_authorizer` is
  a TRUE undo with no statement-cache desync (SQLite expires prepared
  statements on authorizer change); update hook persists + delivers
  post-check-in, dead subscriber harmless; a bridge progress hook
  does NOT clobber cancellation (300 ms timeout honored at 303 ms
  under 23.9k progress messages — xqlite multiplexes the single
  progress slot; control: 1500 ms → 1505 ms). Cross-process wedge
  (REAL second OS process): 26 ok + 14 structured busy during a
  1200 ms `BEGIN IMMEDIATE` hold, 40/40 after release, final counter
  EXACTLY 66 = 40 + 26. Seed 5 (cancelled DML in explicit txn)
  discharged by Run 25, not redone.

### B9 — the documented contract diverged in five places; two detached handlers

- **F-B9-7 (S2, CONFIRMED, FIXED as docs+test).**
  `[:xqlite_ecto3, :checkout]` fires ONCE PER CONNECTION right after
  connect (db_connection source: the only two `checkout/1` call
  sites), not "per-call" as the guide said — 55 queries, 0 events,
  four repeats; a checkout-rate metric built from it reads a
  constant. Guide + moduledoc corrected; pool-level test added (the
  existing test called the callback directly — why the gap survived
  Runs 4/8). Probe pins the OLD claim → stays exit 1 BY DESIGN.
- **F-B9-8 (S2, CONFIRMED, FIXED, RED→green).** The
  `fk_diagnostics` span returned ONLY its counters map, which
  `:telemetry.span/3` uses AS the stop metadata — `conn`/`mode`
  dropped (both doc surfaces promised them), and `:telemetry`
  DETACHES a raising handler: a `%{mode: _}` binding died VM-wide on
  the first diagnosed violation (control: the same handler on
  `handle_begin` survives). Fixed by merging start metadata into the
  stop map, matching every sibling span.
- **F-B9-9 (S3, CONFIRMED, FIXED as docs).** First live `:exception`
  phase (via a float `:timeout` reaching the driver directly):
  metadata is `kind/reason/stacktrace/…` with NO
  `result_class`/`error_reason`; handler detachment proven; no
  pool-reachable trigger found (DBConnection raises before the
  callback on bad timeouts; `connect` clean against bad
  `custom_pragmas`). Both surfaces now document the real shape;
  guide samples gained catch-alls.
- **F-B9-10 (S3, CONFIRMED, FIXED).** `classify_dbc`'s disconnect
  clause writes `error_reason: {:disconnect, error}` — and OTel's
  `error_type/1` matched the wrapper, so ROLLBACK-class violations,
  timeouts, and connect failures all reported
  `error.type = "disconnect"`. The mapper now unwraps (inner class
  reported); the TWO SHAPES of `error_reason` are kept and
  documented (the wrapper carries real signal). Probe's OTel leg
  green; its single-shape leg stays exit 1 BY DESIGN (the remedy
  deliberately keeps the wrapper).
- **F-B9-11 (S3, CONFIRMED, FIXED as docs).** The guide's event
  table omitted the three `statement_cache` events (moduledoc had
  them since Run 23's F-B9-6); the "all measurements in nanoseconds"
  claim is false for span events (`:telemetry.span/3` uses NATIVE
  units — identical on this runtime, said precisely now).
- **F-B9-12 (S3, test-only, CONFIRMED pre-existing, FIXED).**
  `driver_statement_cache_test.exs`'s `:hit` capture was
  discriminator-free — the F-B9-2/3 async-unsafety class, ~1-in-3
  flake under one multi-file VM (never under `test.seq`); now
  SQL-filtered.
- **F-B9-13 (S3, FILED).** `fk_diagnostics_test.exs`'s telemetry
  assertion fails under the OFF build (pre-existing at HEAD; the
  `telemetry_disabled` CI lane runs only the smoke file, so CI is
  green). Flag-guard the test or widen the lane — filed, not fixed
  blind (the OFF build is outside the verify gate).
- **CLEAN:** `cached_count` before-the-action semantics confirmed
  numerically (exact expected sequence; RED evidence: the warm-cache
  first attempt FAILED the same assertion); OFF/ON flag round trip
  re-driven live both directions with one forced recompile each, ON
  restored and emission proven back; the `with_xqlite` bridge is
  FULLY invisible to adapter telemetry (three statements, zero
  events — the F-B9-4 evidence; ruling stays the maintainer's).

### Dryness

Both axes: finding runs — **B3 stays 0 of 2, B9 stays 0 of 2, NOT
DRY**. B3 re-wets ALSO on: `sync_after_transaction_control/2` +
`leading_keyword/1`, the `handle_declare`/`handle_fetch` guard
routing, the `with_xqlite` connection-scoped-state section. B9
re-wets ALSO on: `classify_dbc`'s disconnect clause, the
`fk_diagnostics` span return shape, the guide's event table, the
OTel `error_type` unwrap.

### Completeness critic (next passes)

B3: the `with_xqlite` family probe covered five facilities — not
backup/serialize/session handles left open across check-in, nor
`set_busy_policy` (observer form only); F-B3-7's fix needs its
covering pass (the keyword-sync surface + comment-prefixed control);
F-B3-8 with `Repo.stream` inside `Ecto.Multi` (continues by design —
same leak without an explicit rescue?); the sandbox arm in
`{:shared, owner}` mode with a concurrent process during a
ROLLBACK-class violation; the poisoned-pool amplification curve vs
pool size and fraction. B9: a deliberate NIF fault injection to
settle whether `:exception` is truly pool-unreachable; `:checkout`
under the SANDBOX ownership pool (may fire per ownership checkout —
"true in tests, false in production" risk for the corrected doc);
the `disconnect` event's `reason` under the NEW disconnect paths
(Runs 23/25 made them common, nobody captured the richer reasons);
`statement_cache` `:miss` on the multi-statement fallback path;
native-vs-nanosecond on a non-Linux runtime; `group_fk_rows/1`'s
`foreign_key_list` destructures still lack fallthroughs (the fix-7
class, flagged not widened — filed).

---

## Run 30 — 2026-08-20 — dryness lap 4, batch 4: B2 (the self-fulfilling exclusions finally probed)

Single Opus reviewer at `efc6a72`, xqlite `2700446`. Exclusion
artifacts drift-free since Run 24; the full vendored census at HEAD
matched Run 24's anchor EXACTLY (434/32, exit 0) across 12 commits
including a 673-line engine change. Method correction BANKED: the
full-suite isolation run needs `--no-warnings-as-errors` (four
upstream Tds-adapter warnings in vendored `logging.exs`/`repo.exs`
otherwise force exit 1 on a green suite; the repo's own runner already
special-cases it at `test_seq.ex:63`). Gate: key probes re-driven
(hidden-pass builders exit 0; the pointer snap to :359 visible);
fixes implemented BY THE ORCHESTRATOR directly (list + doc edits);
the narrowed list verified by the census flipping to **440 passed /
26 excluded, exit 0** — the exact predicted arithmetic (+6 passing,
−9 tag +3 locations).

### B2 — both S2s came from the blind spot Run 24 named and seeded

- **F-B2-17 (S2, CONFIRMED, FIXED).** `:array_type` hid SIX passing
  upstream tests, not the one on file — invisible to every isolate-run
  since Run 4 because the shared support migration creates the array
  tables ONLY when the tag is absent from the exclusion list, and
  `ExUnit.configure/1` runs before command-line filters, so
  `--only array_type` structurally cannot produce ground truth (six
  of its eight failures were bare `no such table`). The tags-doc row
  even named `x in t.ints` as unsupported — it is a SHIPPED, WORKING
  translation (`1 IN (SELECT value FROM JSON_EACH(t0."ints"))`).
  Adapter-owned probes built the tables and ran the verbatim upstream
  bodies: type.exs 269/282/491/515/523 + logging.exs:840 all PASS;
  only type.exs:234 (array literals + `update_all push:/pull:`),
  sql.exs:30 (`$1::text[]`), sql.exs:38 (`array[1,2,3]`) genuinely
  fail. FIX: tag exclusion dropped (un-blocking the migration), three
  location tuples added (test lines rg-verified at gate — the
  reviewer's numbers were exact), tags-doc row rewritten to
  "supported (6/9)", F-B2-8's array half corrected (wrong by five)
  and closed. Census: 440/26 green.
- **F-B2-18 (S2, CONFIRMED, FIXED as docs).** `:bitstring_type`'s
  rationale ("SQLite has no native bitstring type") named the wrong
  first cause: `Connection.default_expr/1` has NO clause for a
  non-byte-aligned bitstring default (`is_binary(<<42::6>>)` is
  false) and raises a bare `FunctionClauseError` INSIDE the shared
  migration — so un-excluding the tag crashes `test_helper.exs` and
  all 434 tests, not one. Plain `:bitstring` and `size:` columns
  build fine; a bitstring PARAMETER fails structured. The exclusion
  stays (a non-byte-aligned bitstring has no SQLite storage form —
  the test can never pass); the rationale now owns the sequence in
  both artifacts. The hole survived Run 28's refactor of that very
  function (the map/list clause rewrite touched the clause list
  around it). Adjacent seed FILED to the B4 court
  ([F-B2-18-adjacent]): `default_expr/1` must end in a structured
  refusal, the F-B2-14-adjacent pattern.
- **F-B2-19 (S3, CONFIRMED, FIXED).** The `type.exs:362` location
  tuple named a BODY line (the test line is 359) — the only violation
  among the six, sitting three lines below the comment codifying the
  rule; the F-B2-15 sweep missed it. Corrected in the list + both doc
  references. (It excluded the right test today via the snap — the
  defect was bump-fragility.)
- **F-B2-20 (S3, CONFIRMED, FIXED).** The `:duration_type` rationale
  cited `encode_param/1` — the function has been `encode_param/2`
  since Run 25, and the raise is now a structured
  `UnencodableParameterError`. A LISTED re-wet trigger fired without
  a rationale sweep; corrected.
- **CLEAN (controls named):** all three "supported (n/m)" counts hold
  exactly (4/5, 7/8, 3/4; exit-code control: `--only values_list` →
  5 passed exit 0); no excluded tag or location passes at HEAD (12
  tags + 6 locations swept; `:microsecond_precision`'s single hidden
  pass confirmed as interval.exs:194, exactly as F-B2-8 records); the
  four ALTER pointers survived Run 28's four new refusals
  (`refuse_reference_changes!` still fires first — the F-B2-12 class
  did not recur); the named re-wet triggers did not fire
  (`:immediate` default, pool_size 1, `binary_id_storage`,
  `column_type/2`, `lock_for_migrations/3` all unchanged); tag list ↔
  tags doc in exact bijection (now re-verified POST-fix: 11 tags + 9
  locations). Seed 4 ANSWERED: `refuse_unknown_column!` and the
  removed-key door are live (RED controls fire) and unreachable from
  the current vendored surface — on an upstream bump they fail LOUDLY;
  no exclusion absorbs them.
- Ledger-claim correction (Run 24): its "six permanent-limit tags
  correctly attributed (no adapter frame)" is loose — `:prefix` and
  the two `on_delete` column-list tags raise from adapter frames
  (honest rationales, SQLite genuinely the blocker; the sentence just
  must not be reused as no-adapter-frame evidence).
- Dryness: finding run — **B2 stays 0 of 2, NOT DRY** — with a RULING
  adopted at gate: clean-run counting starts only now that the
  F-B2-17/18 corrections landed, and the next pass must re-cover the
  CORRECTED surface with the adapter-owned probes as standing
  instruments (three exclusions were untestable by the old method —
  a clean run scored on it would have measured the blind spot).
  Re-wet triggers ALSO: the shared support migration's
  exclusion-awareness list (any tag it names is untestable by
  isolate-run — currently `:bitstring_type`, `:duration_type`),
  `Connection.default_expr/1`'s clause list, and this run's own list
  narrowing (the three new location tuples + the 440/26 anchor).
- Completeness critic (next B2 pass): re-cover the narrowed surface
  inside the suite (done once at gate — keep it standing); whether
  the three array location tuples survive an `ecto`/`ecto_sql` bump
  (six formerly-hidden tests now run unguarded — deliberate); sweep
  OTHER vendored files for migration-conditional tables beyond the
  three flagged tags; `:duration_type`'s subtlety split (its rationale
  IS verified — the encoder raises before the missing table; it stays
  untestable only in that fixing the encoder would not make the tests
  pass); make the line-pointer sweep mechanical (one loop comparing
  requested vs reported lines — it found F-B2-19 in seconds).

---

## Run 31 — 2026-08-20 — dryness lap 4, batch 5 (the lap closer): B4 + B8 paired

Single Opus reviewer at `c0c6fea`, xqlite `2700446`. Churn
git-confirmed: B4's covering range held ONE commit (Run 28's
renderer touch); `types/`, `query.ex`, `decimal_precision.ex` had
NEVER been covered since Run 25's own fixes — and two of the three
findings sit exactly there. B8's range = the Run 27 budget + Run 29
guard commits. Gate: finding probes re-driven pre-fix (one
tmp-name-collision harness artifact on the unification probe,
re-run clean, disposition-noted); one Opus implementation batch;
final matrix re-driven; stash-RED 53/69 → 69/69; verify green.

### B4 — Run 25's uncovered fixes held the lap's last two S1s

- **F-B4-6 (S1, CONFIRMED, FIXED, RED→green).** Decimal parameters
  bound as TEXT (`Decimal.to_string(:normal)`): a direct column
  comparison is rescued by column affinity, but affinity-LESS
  operands — `HAVING sum(col) > ^decimal`, arithmetic fragments,
  `coalesce` — compare storage classes, and every number sorts below
  every text: wrong rows, silently (float controls correct in the
  identical queries; raw-SQL pair pins it at the SQLite level). FIX:
  new `DecimalPrecision.bind_form/1` (`{:integer, i} | {:float, f} |
  :error`; `representable?/1` is now `bind_form != :error`, so
  accept/refuse verdicts unchanged BY CONSTRUCTION); `encode_param/2`
  binds the proven-exact numeric form; rejects raise unchanged.
  BLOB-affinity consequence probed: decimals there stored TEXT
  before, numbers now — round-trips stay exact, comparisons improve;
  no shipped type targets BLOB with decimals. Four TEXT-bind test
  pins re-pinned to the numeric contract; bind-exactness property
  added (2000 runs). Probe dispositions: the text==bind drift probe
  is SUPERSEDED (FAIL BY DESIGN post-fix); signed-zero pins
  unchanged (3/3 signs still lost, numerically equal).
- **F-B4-7 (S1, CONFIRMED, FIXED) + F-B4-8 (S3, court item
  ADJUDICATED + landed).** `default_expr/1`'s `is_map` clause
  matched every struct: `default: Decimal.new("1.5")` persisted
  `DEFAULT ('"1.5"')` and ordinary reads then RAISED
  `Decimal.Error`; postgres type-gates and refuses loudly (contract
  divergence, not inheritance). The sweep found five bare-crash
  classes across ALL THREE renderers (plain / rebuild `default_spec`
  / model `rendered_default`): non-boolean atoms, non-fragment
  tuples, 3-tuples, non-byte-aligned bitstrings (the filed
  [F-B2-18-adjacent] class CONFIRMED), Jason-less structs — and
  charlists silently rendered as int arrays. FIX (one design closes
  F-B4-7 + F-B4-8 + [F-B2-18-adjacent]): new
  `XqliteEcto3.UnsupportedDefaultError` (value, reason
  `:unsupported_shape | :unencodable`, column, type, + cause
  carrying the encoder's exception); map clauses gated
  `not is_struct`; catch-all tails in all three renderers through
  one shared `DataType.unsupported_default!/3`; printable charlists
  refused; plain map/list rendering byte-identical on every path
  (unification probe still green). The B2 exclusion note updated:
  `bs_with_default` now raises the structured error.
- **F-B4-5 (S2, CONFIRMED, FIXED).** Run 25's rendered-form
  fast-accept assumes NUMERIC affinity but is column-blind: on
  REAL-affinity columns (reachable via `column_type/2`'s atom
  passthrough — `add :v, :real` — and via adopted legacy files)
  int64-exact decimals silently truncated past 2^53, where the
  PRE-fix float64 model refused LOUDLY — the fix had traded a loud
  refusal for silent truncation on that column shape (the third
  fix-creates-the-next-finding instance after Runs 26→27). FIX:
  `:real`/`:double`/`:double_precision` map to `NUMERIC` (as
  `:float` already did) — the adapter now emits no REAL-affinity
  columns at all; README Known-limitations line for legacy REAL
  columns (drafts folded). The fast-accept itself untouched
  (correct for every affinity the adapter emits); the raw-SQL REAL
  probe legs remain red BY DESIGN (SQLite's affinity, not our bind).
- **F-B4-9 (S3, SETTLED + FIXED).** `expr(%Decimal{}, ...)`
  unreachable from every ordinary Ecto construction (five routes
  probed — all parameterize); a hand-built AST reached it and
  inlined an unguarded decimal. Now routed through the guard;
  rejects raise `DecimalPrecisionError` with `index: nil`.
- **CLEAN (controls):** zero predicate/bind drift pre-fix over 16
  samples read from the encoder itself; unencodable collections
  fully structured with exact positions (11 cases, 2 controls);
  Run 28's `json_default/1` unification byte-identical (11 classes,
  RED control); signed-zero pinned; int64 boundary exact both sides.

### B8 — the flagship's sharp questions all came back clean; one docs S3

- **F-B8-6 (S3, docs, CONFIRMED, FIXED as docs).** A pool does NOT
  bound the F-B8-5 overshoot (141× at pool 3, 285× at pool 5 —
  saturation lives on the dirty schedulers, not the pool), and the
  overshot cancel is indistinguishable from a prompt one; pool
  EXHAUSTION is a third case (46×), governed by
  `queue_target`/`queue_interval` and DISTINGUISHABLE by
  `reason: :queue_timeout` vs `:error`. README cancel section +
  drafts now say all three; plus the sandbox DX pin (below).
- **CLEAN (controls; the flagship earns its 0-of-2 honestly):** core
  cancel at 151 ms/150 ms; savepoint-nested cancelled write atomic
  (outer `{:error, :rollback}`, no survivor row —
  `handle_begin(:savepoint)` never sets the flag; the OUTER flag is
  what the guard reads); SQL Sandbox × cancelled write leaks NOTHING
  (RED leak-detector control) with the DX fact pinned: ownership is
  gone for the rest of that test (`OwnershipError`, `checkin` →
  `:not_found`) — coherent, deliberate, now documented; streams ×
  cancelled sibling clean BOTH orders; the guard's verdict identical
  under dirty saturation; a cancelled `BEGIN`/`COMMIT` effectively
  unreachable (400k-row COMMIT = 8 ms) and safe by construction; the
  cancelled branch SKIPS `wrap_execute_error/4`, so the
  enrichment-on-doomed-connection concern never reaches it. SEED 14
  ANSWERED: cancellation is NOT worse than the plain-error path —
  identical damage both branches for both `BEGIN` spellings; the
  sync's blind spot is WIDER than filed (a leading `--` line comment
  defeats `leading_keyword/1` like `/* */` does) — HANDED to B3's
  owed keyword-sync pass with the six-line comment-skip remedy
  sketch, not filed here.
- New committed tests: comparison matrix + bind-exactness property +
  refusal sweep + `:real`→NUMERIC proof + nested-cancel /
  sandbox-cancel (new file) / stream×cancel / queue_timeout-shape
  tests (deterministic, no timing asserts; one DBConnection
  holder-retirement flake tamed with a dedicated pool).

### Dryness (lap 4 closes)

**B4: an S1 pair + S2 — resets to 0 of 2, NOT DRY.** Re-wets ALSO:
`bind_form/1`/`encode_param/2`, `column_type/2`'s float family,
`UnsupportedDefaultError` + the three renderer tails,
`expr(%Decimal{})`. **B8: 0 of 2, NOT DRY — gate ruling:** the
reviewer proposed 1-of-2 (S3-docs-only run, the old F-B8-3/Run-7
precedent); OVERRULED for consistency with the hardened rule every
run since Run 12 has applied (any finding-run breaks the chain —
B9/Run 12, B3/B9 Run 29); the F-B8-3 case predates the rule and was
a ruled not-a-defect. Honest note: B8's finding is docs-class and
every S0-S2 question was clean — it is the closest axis to dry.
- Completeness critic (next passes): B4 — the `:decimal` LOADER side
  (BLOB-affinity + NULL-in-aggregate results); `precision:/scale:`
  options vs SQLite's ignored scale; decimals inside `:map` fields /
  `insert_all placeholders` / `on_conflict set:`; `{:array,
  :decimal}`; `json_default` under a non-Jason `:json_library`; the
  migration-helper `default:` entry points directly. B8 —
  `Repo.transaction(mode: :savepoint)` at top level (savepoint with
  no enclosing transaction — the guard's clause cannot match);
  `{:shared, owner}` sandbox × cancelled write; ATTACH/TEMP targets;
  `Ecto.Multi` with a cancelled step; the `disconnect` telemetry
  `reason` on the cancelled branch (B9 wants the same); the guard's
  DirtyIo status read under adversarial queuing; F-B8-2's stream
  cancellation (still blocked on an xqlite `stream_fetch_cancellable`).

### Post-push addendum (same day): CI red → test hardening + a mode correction

`59cff45` went RED on every macOS/Windows test job (+ one ubuntu):
the new `sandbox_cancel_test.exs` rode the SHARED sandboxed TestRepo,
and on slow runners the cancelled write legitimately held its
connection past DBConnection's default 50 ms queue deadline while
parallel async tests queued — the holder was evicted mid-statement
(the same eviction machinery the pool-exhaustion test was already
hardened against). FIX: dedicated `SandboxCancelRepo` (sandbox pool,
own tmp db, `queue_target/queue_interval` 5 s, `ownership_timeout`
120 s), the banked in-test dedicated-repo pattern. The hardening also
CORRECTED the finding's DX pin: on a clean pool the cancelled write's
disconnect leads ecto_sql to RE-BEGIN the sandbox on a replacement
connection — the test then CONTINUES with an EMPTY sandbox
transaction (prior writes gone, `no such table` for a table the test
created) instead of losing ownership; the OwnershipError mode is what
shared-pool queue pressure produces. BOTH modes keep the invariants
(nothing durable ever; pre-cancel sandbox writes gone; next test
clean). The test now asserts the invariants and branches on the mode
structurally (`OwnershipError` + `:not_found`, or
`%XqliteEcto3.Error{type: :no_such_table}` + normal checkin); README
and draft state both modes. Verify green before the fix commit.

SECOND red (same test, macOS/Windows): the mode-branch still PROBED
during the teardown window — the pooled `timeout: 50` also arms
DBConnection's checkout deadline (the documented recycle), and a
query issued while that teardown is in flight can see a THIRD shape
(an exit from the dying holder) — the race has no stable loser on
slow runners. Final form: the test asserts INVARIANTS ONLY (cancel
returns `ConnectionError`; `checkin` tolerated as `:ok | :not_found`;
a fresh checkout sees zero trace of the cancelled test and a usable
database), 5/5 local; the mode taxonomy stays recorded HERE and in
the docs, not in assertions. Lesson banked into the axis: post-cancel
DX shapes are timing-mode-dependent — pin invariants, describe modes.

THIRD red (fresh CI seed 653856, two jobs): CI-as-fuzzer found a REAL
counterexample in the new bind-exactness property —
`Decimal.new("18271353451913432.0")` — and adjudication flipped the
suspect: the BIND is correct (the float is exactly that integer;
live-SQLite proof: NUMERIC demotion stores INTEGER
18271353451913432, the original digits); the property's COMPARATOR
was the bug — `Decimal.from_float/1` is shortest-round-trip
printing, which renders a 17-digit integral float as 16 digits. The
comparator now reads bound floats through the guard's own storage
model (`stored_decimal/1`, made @doc false public — exactly the
"loader output == stored_decimal model" pin the B4 critic wanted),
and the counterexample value is pinned end-to-end against live
SQLite in `decimal_precision_test.exs`. Seed 653856 replays green;
both files 76/76. Class lesson banked: float comparisons in tests go
through the storage model, never through shortest-print conversions.

FOURTH red (three jobs) — see below; Run 32 follows after this
addendum block.

## Run 32 — 2026-08-20 — lap 5, batch 1: B8 solo (the flagship's third door)

Preceded by the LAP-5 STEP-0 ruling (orchestrator, git-verified):
**B1 RE-WET** (the audited callback return-shape inventory changed —
Runs 25/29 gave execute/declare/fetch a `{:disconnect, _, _}` return
they never produced; contract-valid, facts moved) and **B6 RE-WET**
(`expr(%Decimal{})` guard-routes, `column_type` float family →
NUMERIC, default rendering refuses — Runs 28/31); **B10 STAYS DRY**
(no trigger fired: no bench/ dep change, no ecto_sql floor bump, no
new scenario; the hot-path perf churn only stales recorded FIGURES —
the parked native-bench items' concern). Scoreboard: DRY = B10
alone; eleven axes wet.

Single Opus reviewer at `91415ff`, xqlite `2700446`; `driver.ex`
byte-unchanged since `04e8363` (git-verified — the cover hunted
unreached seeds). Gate: F-B8-7's RED + mechanism + remedy-safety +
blast-radius probes re-driven pre-fix; fix implemented BY THE
ORCHESTRATOR; probes re-flipped post-fix; stash-RED 13/14 → 14/14.

- **F-B8-7 (S2, CONFIRMED, FIXED, RED→green).** `handle_begin/2`'s
  savepoint branch never set `transaction_status`, so a TOP-LEVEL
  `Repo.transaction(fun, mode: :savepoint)` (SQLite: a lone SAVEPOINT
  starts an implicit transaction) left the rollback guard BLIND — the
  F-B8-4 durable-leak shape through the guard's THIRD uncovered door
  (after F-B3-7 raw BEGIN, F-B3-8 streams), and NOT timeout-specific:
  an ON-CONFLICT-ROLLBACK violation leaked identically with no
  cancellation involved (post-failure write durable inside a
  transaction reported failed; also reachable through `Ecto.Multi`).
  Mechanism proof: the RAW-SQL spelling of the identical construct is
  protected by Run 29's keyword sync — the cached flag, not SQLite,
  decides the verdict. Reachability discount from S1: `mode:` is a
  documented Ecto option but nothing idiomatic passes `:savepoint` at
  top level. FIX (the read-free variant): a successful savepoint
  begin sets `transaction_status: :transaction` (always true
  after SAVEPOINT — nested it was open already); releasing (or
  rolling back) the OUTERMOST managed savepoint refreshes the flag
  from SQLite via one status read (`released_savepoint_state/1`) —
  the may-end-an-implicit-transaction boundary; nested releases stay
  read-free. The remedy-safety pin held: after RELEASE a failed
  autocommit statement does NOT disconnect. Committed tests
  (deterministic, no timing): rollback-class violation cannot leak +
  happy path commits + post-release no over-disconnect
  (`transaction_atomicity_test.exs` +3). Probe dispositions:
  the leak-asserting probes (blast-radius, multi-door) INVERT
  post-fix — FAIL BY DESIGN.
- **CLEAN (controls named; the strongest saturation window yet):**
  `{:shared, owner}` sandbox × cancelled write with a queued sibling
  (sibling exits with the holder; owner + fresh-sibling post-cancel
  writes refused with `OwnershipError`; the FILE byte-identical);
  ATTACHed + TEMP targets (rollback-on-interrupt spans EVERY schema;
  cancelled-READ control keeps its transaction); `Ecto.Multi`
  natural + swallowed shapes; the guard's DirtyIo status read under
  a SELF-POLICING saturation window (read 1 µs → 2.13 s median —
  2.1-million-fold — verdict unmoved, cost bounded by exactly one
  read; a 50 ms deadline returned in 8.97 s = an independent live
  re-measurement of the F-B8-5/6 class); core cancel 151 ms vs a
  9,999 ms `:infinity` control; F-B8-2's upstream blocker holds at
  0.11.0 (`stream_fetch_cancellable` absent).
- **Captured for B9 (owed docs line, not filed — F-B8-7 already
  breaks the chain, stated to show no under-filing incentive):** the
  `[:xqlite_ecto3, :disconnect]` `reason` taxonomy on four paths —
  all structured; our cancel and DBConnection's recycle share
  `reason: :error` and are distinguished only by correlating with
  the `handle_execute` stop event's `error_reason: {:disconnect, _}`
  (DBConnection permits no third reason value).
- **HANDOFF (B1/B2 court, FILED in backlog):**
  `Repo.insert(changeset, mode: :savepoint)` — documented by Ecto,
  implemented by Postgrex inside `handle_execute` — is silently
  INERT on this adapter (`handle_execute` reads only `:timeout`).
  Mostly harmless on SQLite (a failed statement does not poison a
  transaction), but an unclaimed contract divergence.
- Dryness: an S2 — **B8 stays 0 of 2, NOT DRY**; the fix re-wets the
  savepoint branches (`handle_begin/commit/rollback` savepoint arms +
  `released_savepoint_state/1`). Completeness critic (next B8 pass):
  declare/fetch under a top-level savepoint (same state, unprobed);
  the managed counter vs a caller's raw SAVEPOINT names; the guard's
  fail-open `_open_or_unknown` fallback (unpinned); F-B8-1's
  lock-contended write not re-driven at 0.11.0; rollback/commit
  hooks under a cancelled write; `mode: :savepoint` via repo CONFIG
  (applies to every transaction — unprobed).

FOURTH red (three jobs): the queue_timeout-shape test's own HOLDER
lost the 1 ms queue race against the pool's ASYNC CONNECT on slow
runners — the aggressive queue params built to drop the victim
dropped the first arrivals too, and the warm-up's failure was
silently discarded (`_warm_up`). Fix: the warm-up retries until the
pool actually serves, the holder retry-wraps its checkout (the only
assertion of interest is the VICTIM's error shape, guaranteed once
the holder holds), receive window widened. 5/5 local. Same lesson
as the sandbox saga, sharpened: a test that configures the pool to
fail fast must retry ITS OWN setup traffic through that same pool.


## Run 33 — 2026-08-20 — lap 5, batch 2: B1 solo (return-shape re-audit + the F-B8-8 court)

Single Opus reviewer at `df30885`; xqlite 0.11.0 (hex), db_connection
2.10.2, ecto 3.14.1, ecto_sql 3.14.0. postgrex NOT vendored — the
`:mode` contract was derived from ecto/ecto_sql source only, stated
where it matters. Gate: all twelve probes re-driven by the
orchestrator pre-fix (rc=0 each, outputs read line-by-line); fixes
implemented BY THE ORCHESTRATOR; stash-RED 9 red (fixes stashed,
exactly the predicted nine) → 108/108 green (fixes applied).

- **F-B1-2 (S2, CONFIRMED, FIXED, RED→green).** A leading SQL comment
  made raw transaction control invisible to the Run-29 keyword sync:
  `leading_keyword/1` skipped only whitespace, so `-- x\nBEGIN` /
  `/* x */ COMMIT` never re-synced the cached flag, which then lied
  in BOTH directions. Stale `:idle` under an open transaction = the
  rollback guard blind = the F-B8-7 durable-leak shape through a
  FOURTH door (after raw BEGIN F-B3-7, streams F-B3-8, top-level
  savepoints F-B8-7) — probed to disk: post-failure write durable,
  rollback answered `{:error, …}` where the plain-BEGIN control
  answered `{:disconnect, …}`. Stale `:transaction` after a
  comment-prefixed COMMIT = over-disconnect: a plain autocommit
  UNIQUE violation destroyed the pooled connection (db_connection's
  own connection_listeners saw [:disconnected, :connected]; the RED
  control on plain COMMIT saw []). Reachability: any raw SQL with a
  leading comment — sqlcommenter-style tags, SQL kept in files. FIX:
  two clauses ahead of the whitespace skip — line comment to the next
  newline, block comment to the FIRST `*/` (SQLite's own rule, never
  nested); either kind may instead run to end of input, where no
  statement executes and nil/no-sync is correct. Remedy validated
  standalone 18/18 (vs 15/18 for the old rule) BEFORE touching the
  repo. Committed tests (driver_transaction_state_test +4): both
  flag-sync directions + both consequence directions (rollback-class
  violation still disconnects; autocommit violation stays an error).
  Shut doors recorded so the next cover skips them: a vertical tab
  before the keyword is rejected by SQLite itself; multi-statement
  strings are refused (`:multiple_statements`) so no hidden tail
  COMMIT; keyword-prefix false positives cost one truthful status
  read and nothing else.
- **F-B1-3 (S3, CONFIRMED, FIXED in-run anyway, RED→green).**
  `connect/1` returned bare reason tuples in the `{:error, _}` slot;
  the DBConnection contract is `{:error, Exception.t()}`
  (db_connection.ex:175). Probed consequence: default backoff logs
  the reason inside an ErlangError wrapper; `backoff_type: :stop`
  crashes `raise err` at connection.ex:121 with ArgumentError and the
  real reason survives nowhere but the log line. Six of eight connect
  failure shapes affected — `cannot_open_database` (errno 14, the
  most ordinary operator failure) included. Grade kept S3
  (diagnostics-only) but fixed at the gate: one `else` arm routes the
  with-chain's failure through `XqliteEcto3.Error.wrap/1` (total,
  type-preserving), and `wrap/1` grew ONE specific clause —
  `{:cannot_open_database, path, code, msg}` → message: msg,
  details: %{path, code} — because an existing test pins the path and
  the doctrine says the struct carries what tests match. Nine
  pre-existing bare-tuple assertions across six test files flipped to
  struct pins (four found by grep pre-fix, five surfaced as post-fix
  reds — the same demonstration from the other side).
- **F-B1-4 (S3, CONFIRMED, FIXED).** disconnect/2 built and discarded
  `%{state | transaction_status: :idle, savepoint: 0}` under a
  comment claiming earlier captors would "read post-close values" —
  nothing can observe a discarded map. Line + comment deleted; the
  test file's stale describe title renamed.
- **F-B1-5 (S3, FILED → backlog).** handle_deallocate/4 discards
  `NIF.stream_close/1` failures (`_ =`) and returns `{:ok, nil,
  state}` unconditionally — telemetry records result_class: :ok even
  when the close failed. Remedy deliberately NOT applied at the gate:
  the conservative fix (carry the close result into stop metadata,
  keep the return shape) touches the LOCKED telemetry surface — B9
  court.
- **Clean census (controls named):** all 14 DBConnection callbacks'
  produced return shapes verified branch-by-branch against
  db_connection 2.10.2 source cites; every minted err is a real
  exception (wrap/1 total; ConnectionError struct literals carry the
  :severity/:reason defaults connection.ex:146 reads). Bare-term RED
  control: a non-exception err is tolerated on the execute path but
  ArgumentErrors on declare/fetch — ours satisfy it everywhere
  post-F-B1-3. The new `{:disconnect, err, state}` returns from
  execute/declare/fetch traced through source + a live probe driver:
  teardown order right, no double stream close (declare's error arm
  closes its own handle; the fetch-disconnect path SKIPS
  handle_deallocate via holder.ex:157's status short-circuit —
  Stream.resource's after-fun still runs, the second
  Holder.disconnect is absorbed) — and disconnect/2 with an orphan
  open stream is benign at 0.11.0 (structured refusals, clean
  reopen). Run-32 savepoint arms: four lifecycles truthful
  step-by-step (flag = handle_status = SQLite truth), the RED control
  (hand-corrupted flag) detected; released_savepoint_state keeps the
  old value only when the status read itself errors — conservative in
  the leak direction. sync_after_transaction_control sits only in the
  zero-column SUCCESS branch: transaction control that ERRORS never
  syncs — argued harmless today, unpinned (critic seed).
  handle_prepare's single %Query{} clause is safe on today's call
  graph (RawConn reaches the driver only via execute; its encode
  returns [] and cannot raise, so the EncodeError re-prepare path
  cannot route RawConn there). Ecto-side behaviour surface
  byte-unmoved since Run 9 (git-verified: def/@impl/@behaviour lines
  of xqlite_ecto3.ex / connection.ex / migration.ex).
- **F-B8-8 ADJUDICATED — DOCUMENT, S3 (reviewer verdict accepted).**
  (a) `:mode` documented at ecto repo.ex:2495 for single ops, opaque
  to ecto_sql and db_connection — the wrap is the driver's job; the
  Sandbox proxy INJECTS `mode: :savepoint` into every statement
  outside an explicit transaction (sandbox.ex:404-410, live-traced
  into our handle_execute opts, with the ABSENT control inside
  Repo.transaction). (b) Live SQLite matrix
  (ABORT/ROLLBACK/FAIL/IGNORE/REPLACE × a faithful wrap): ABORT — the
  default — makes the wrap a no-op (statement-level undo, transaction
  stays usable; the Ecto doc's premise is Postgres-only); ON CONFLICT
  ROLLBACK destroys the transaction WITH any open savepoint — the
  wrap provably cannot help; ON CONFLICT FAIL + multi-row insert_all
  is the ONE class where the wrap changes outcomes (pre-conflict rows
  kept vs undone) and needs hand-written DDL to reach. (c) Exactly
  one upstream test passes the option on a single op
  (ecto_sql alter.exs:60) — already excluded for an unrelated Decimal
  reason, and its try/rescue/else asserts a correct result on EITHER
  branch, so it could not detect inertness even unexcluded. B2's
  share: NO exclusion-list change owed. Implementing would wrap
  roughly every sandboxed statement in SAVEPOINT/RELEASE for a
  semantic SQLite makes moot — rejected. DOCUMENTED: README
  Known-limitations bullet (STE draft mirrored in its voice);
  honesty-ledger line appended; backlog handoff closed.
- **Run-32 CI addendum:** `df30885`'s run came back RED on one cell
  (macos-latest, 1.19, OTP 28) — the VENDORED ecto_sql sandbox test
  (sandbox.exs:174, hardcoded 100 ms assert_receive) at second one of
  the suite on the 3-core runner. Triaged before disposition: the
  test's trace never touches the savepoint arms 6bc7d00 changed
  (checkout → plain BEGIN → insert → three SELECTs in a Task; no
  Repo.transaction), our three new savepoint tests were green on that
  same runner in that same red run, and the same cell was green an
  hour earlier. Re-run: GREEN. Cold-start flake of an upstream test
  we cannot edit — the Run-31 slow-runner class; nothing owed.
- Dryness: an S2 — **B1 stays 0 of 2, NOT DRY**; the fix re-wets the
  keyword-sync surface (leading_keyword's comment clauses) and the
  connect error path (the wrap arm + wrap/1's new clause).
  Completeness critic (next B1 pass): the guard's `_open_or_unknown`
  fail-open fallback (now the only thing between a stale flag and a
  leak — unpinned); declare/fetch under a top-level savepoint;
  `mode: :savepoint` via repo CONFIG; the sync's failure branch
  (unpinned); a caller's raw ROLLBACK leaving the managed counter
  non-zero (next managed RELEASE disconnects — arguably correct,
  unprobed); handle_begin(:transaction) not resetting state.savepoint
  (asymmetry vs commit/rollback; no reachable divergence found);
  `:disconnect_and_retry` never produced (and a bad return through
  declare/fetch's handle_common_result if ever added). MENU (filed):
  connect config-error payloads (hook names, pragma entries) live
  only in the wrap message — a details field for the tag-tuple family
  is a designed-shape decision (error_wrap_test pins details: nil).

THIRTEEN straight finding runs.
