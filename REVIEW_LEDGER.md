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

## Run 34 — 2026-08-20 — lap 5, batch 3: B6 solo (translation re-anchor over the Runs-28/31 churn)

Single Opus reviewer at `80257e4`; xqlite 0.11.0 (hex), SQLite 3.53.2
probe-confirmed. Gate: all eight probes re-driven by the orchestrator
(rc=0 each, load-bearing outputs read line-by-line); fixes implemented
BY THE ORCHESTRATOR; stash-RED 4 red (exactly the predicted four) →
66/66 green.

- **F-B6-4 (S2, CONFIRMED, FIXED, RED→green).** Run 31's "the adapter
  now emits no REAL-affinity columns at all" closure was incomplete:
  `column_type/2`'s upcase passthrough still turned `:float8`,
  `:float4`, and `:"double precision"` into REAL-affinity DDL, so a
  `:decimal` written into such a column was silently converted to
  float64 — the exact F-B4-5 consequence through the enumeration gap,
  contradicting both the data_type moduledoc and the README claim.
  Reachability is ordinary: Ecto's own Postgres adapter passes
  unknown type atoms through, so `add :price, :float8` is the
  sanctioned way to write a DB-specific float type, and a
  Postgres-schema port carries them verbatim. Probed end-to-end
  (migration → Repo.insert! → Repo.get!): `12345678901234567` came
  back `…568` from FLOAT8/FLOAT4/DOUBLE PRECISION columns with no
  error anywhere; clean-column RED controls exact. FIX (the TOTAL
  variant — the reviewer's option 2, chosen over enumerating three
  more clauses because enumeration was the original failure mode):
  the passthrough now applies SQLite's own affinity determination —
  a spelling containing REAL/FLOA/DOUB with none of
  INT/CHAR/CLOB/TEXT/BLOB (which win first in SQLite's rule order)
  is rewritten to NUMERIC; everything else passes through unchanged.
  This makes the moduledoc and README claims TRUE for every spelling,
  enumerated or not. Committed pins (data_type_test +4): the named
  family, the three PG spellings, the rule itself (`:floatish`,
  `:big_real`), and earlier-rule passthrough controls (`:smallint`,
  `:varchar`); the live truncation proof stays in the probe manifest.
- **F-B6-5 (S3, CONFIRMED, FIXED).** `UnsupportedDefaultError.column`
  was an atom on the plain and rebuild-ADD paths but a STRING on the
  rebuild-MODIFY path (the name comes from pragma_table_xinfo there),
  so one matcher could not cover the one error. Normalized to string
  in `unsupported_default!/3` (atom→string is safe; the reverse would
  mean String.to_atom on schema text), typespec narrowed to
  `String.t() | nil`, and FOUR committed atom pins flipped — the
  reviewer's "only committed pins are migration_test:234/:288" claim
  was incomplete: the first gate verify ran RED on two more `:tag`
  pins (table_rebuild_test:757, rebuild_verification_test:719),
  sitting twenty lines from already-string pins ("v", "price") in
  the same files — the F-B6-5 drift frozen into the suite itself.
  The gate's own verify caught it; re-verified green on the
  corrected tree before commit.
- **F-B6-6 (S3, CONFIRMED, docs-fixed + menu).** `alter table … add`
  with a non-constant `default:` fragment follows SQLite's own ADD
  COLUMN rule: OK on an empty table, "Cannot add a column with
  non-constant default" on a populated one — so a migration passes in
  dev/CI against a fresh database and fails in production. The
  adapter renders it without comment and `add` never reaches the
  rebuild engine (`requires_rebuild?/1` is :modify-only). Probed pure
  (empty vs populated × CURRENT_TIMESTAMP / (1+1) / parenthesized
  JSON constant — the Run-31 JSON defaults are constants and SAFE).
  README Known-limitations bullet landed (+ STE draft mirror in its
  voice); the implement-option (route such adds through the rebuild
  engine) filed as a maintainer menu — B7 court.
- **Clean census (controls named):** churned path 1 — the
  `expr(%Decimal{})` guard: 11 samples through both doors with ZERO
  accept/refuse disagreements; storage agreement proven by real
  inserts (9 samples, same storage class, same value, SQLite `=`
  agrees; the `1E+30` 31-digit-integer-literal → REAL 1.0e30 case
  matches the param path exactly); row-level agreement on a live
  WHERE; 14 ordinary construction routes ALL parameterize (the raise
  is unreachable from normal queries — hand-built AST RED inlines).
  Churned path 2 — float family: NUMERIC declared by real
  migrations, 12-value float round-trip exact (the lone `-0.0 → 0.0`
  sign loss reproduces on a raw REAL column, so it predates Run 31
  and lives at the driver/BEAM boundary; `-0.0 == 0.0` so nothing
  user-visible turns on it); 34-spelling walk + 15-type live
  round-trip clean. Churned path 3 — defaults: 36 live refusals (9
  classes × 4 entry points) all structured; 15 supported defaults
  render AND read back, and survive a rebuild byte-identically
  (post-rebuild DDL drops the JSON parens cosmetically — carried
  text, proven equivalent by read-back); renderer 3's refusal tail is
  unreachable by construction (stated so the next cover skips it).
  Standing anchors: 376 committed tests over 13 files green.
  Run-31-S1 neighborhood: HAVING/fragment/coalesce decimal
  comparisons agree with SQLite arithmetic through both doors at
  every threshold; the TEXT-literal RED differs where truth says it
  must; honest null result on record — SQLite's `+` coerces TEXT
  operands numerically, so ARITHMETIC is not the vulnerable shape,
  comparison is.
- **Churn-scan handoff (B5/B2 court, seeded):** the range's fifth
  churn item — `to_constraints/2` now routes through
  `unique_constraints/1` (live index-name pick when it is the single
  non-autoindex candidate) — emits no SQL; it is error-mapping
  surface and was deliberately NOT probed here. The next B5 (or B2)
  cover owns it.
- Dryness: an S2 — **B6 stays 0 of 2, NOT DRY**; the fix re-wets
  `column_type/2` (the affinity rewrite) and the default-refusal
  column field. Completeness critic (next B6 pass): the passthrough's
  NUMERIC-affinity leftovers (`:jsonb` → JSONB lands on NUMERIC
  affinity — a bare-number JSON document stored in such a column
  coerces to INTEGER; unprobed); `references(type: :float8)` live;
  the `:decimal` loader breadth items from Run 31's critic (BLOB
  decimals, decimals in :map fields, {:array, :decimal}, insert_all
  placeholders, on_conflict set: read-back); non-constant defaults
  beyond CURRENT_TIMESTAMP/(1+1); atom-vs-string drift in the OTHER
  structured errors (UnsupportedTypeError.type, constraint structs)
  now that UnsupportedDefaultError.column is normalized;
  escape_string/limit/quote_entity stay anchor-only until touched.

FOURTEEN straight finding runs.

## Run 35 — 2026-08-20 — lap 5, batch 4: B5 solo (the Run-34 routing handoff + the Run-27 seeds)

Single Opus reviewer at `0a5386a`; xqlite 0.11.0 (hex), SQLite 3.53.2
probe-confirmed. Gate: twelve probes re-driven by the orchestrator
(p00/p01/p01_red/p02/p04/p06b/p06/p07/p07b/p08/p10/p12 — rc matched
the manifest on each, load-bearing outputs read line-by-line); fixes
implemented BY THE ORCHESTRATOR; stash-RED 1 red (exactly the
predicted one: the rejection pin, red because connect succeeded on
every bad value) → 15/15 green.

- **F-B5-20 (S2, CONFIRMED, FIXED, RED→green).** `busy_timeout` repo
  config went to `PRAGMA busy_timeout` unvalidated, and SQLite stores
  it as a C int, clamping negatives and past-int32 values to 0 —
  so `busy_timeout: :infinity` (the idiomatic "wait forever")
  connected fine and then never waited on a single lock: probed
  1 ms give-up vs the control's 3003 ms wait under an EXCLUSIVE
  holder. Strings and floats were silently coerced. This settles the
  two values F-B5-18 left unprobed, and worse than its clamp. FIX:
  `validate_busy_timeout/1` at connect beside the two existing
  validators — integers 0..2_147_483_647 accepted, everything else a
  structured `{:invalid_busy_timeout, value}` through the same
  tag-tuple wrap family (`type: :invalid_busy_timeout`); int32 max
  (~24.8 days, probe-proven to survive the pragma exactly) is the
  accepted "wait forever" spelling. Silent mapping of `:infinity`
  was rejected on principle: silent coercion is the class being
  eliminated. **CLOSES F-B5-18** (its remedy was exactly this
  validation; entry removed, ceiling documented in the CHANGELOG
  bullet + code comment). Committed pins (connect_pragmas +2): the
  boundary values 0 and 2_147_483_647 connect AND read back exactly;
  `:infinity`/-1/2_147_483_648/"3000"/1500.5 all reject structurally.
- **F-B5-19 (S2, CONFIRMED, docs-fixed).** The migration guide
  promised "the changeset mapping works identically — you likely
  don't touch anything"; against a custom-named unique index a
  by-the-book `unique_constraint(:col)` raises `Ecto.ConstraintError`
  here and converts on ecto_sqlite3 (whose `constraint_name_hack/1`
  always derives, never reading the schema). Probe: the same bare
  declaration raises on the single-candidate table and converts on
  the multi-candidate one — the raise IS the emission rule. The
  behavior is the ruled F-B5-2 remedy (Postgres parity), so the
  divergence is docs: the guide paragraph now states the one
  difference, the `name:` remedy, which shapes keep matching bare
  declarations, and points at the `UniqueIndexNames` moduledoc.
- **F-B5-21 (S3, CONFIRMED, docs-fixed).** No user-facing doc
  mentioned unique-index-name resolution (README documents the FK
  sibling in full; CHANGELOG had only the budget bugfix). The
  Run-10 owed docs pass, now paid: README "Real unique index names"
  section (contract, both parity directions, degradation fields,
  stream skip) + a CHANGELOG Added entry for the feature itself.
- **F-B5-22 (S3, CONFIRMED, filed → F-B5-15 extended).** The
  `handle_declare`/`handle_fetch` error branches skip the ENTIRE
  enrichment step, so streamed DML skips the rich-FK replay too, not
  only the unique lookup: same violation reports recovered
  `fk_violations` through execute and `[]` + `:not_run` through the
  stream (truthful degradation). Check/not-null/unique
  classification survives the stream path (parsed in Rust). Filed
  into F-B5-15's entry; README rich-FK caveats now say it.
- **F-B5-23 (S3, CONFIRMED, docs-fixed).** The FK replay leaves
  `last_insert_rowid()` pointing at the rolled-back phantom row
  (probe: 5000 → 1 with replay on, 5000 → 5000 with it off; cleanup
  otherwise clean). SQLite offers no restore; the adapter never
  reads it (inserts use RETURNING) — raw-SQL/`with_xqlite/3` readers
  are the exposed population. Caveat added to the FkDiagnostics
  moduledoc + README caveats.
- **F-B5-24 (S3, CONFIRMED, docs-fixed).** The UniqueIndexNames
  moduledoc + `@zero_slot_budget_ms` comment said an observer-held
  slot makes "reads wait for policy-governed durations" — under an
  observer alone contended reads fail in 0 ms (probe: 2003-2004 ms
  plain-timeout control vs 0 ms observer arm, observer fired). Both
  spots now state the three-way zero ambiguity correctly;
  `with_xqlite/3`'s moduledoc already had it right.
- **F-B5-25 (S3, CONFIRMED, filed → F-B5-4 sharpened).** Since the
  single-candidate emission rule, F-B5-4's wrong-schema name is
  EMITTED: an aux-table violation blames main's index, and a TEMP
  table shadowing a real name poisons violations on the MAIN table
  too (all three of temp/aux/main emitted temp's index). Remedy
  feasibility probe-confirmed (`pragma_table_list` returns all
  schemas for the name in one read). Stays S3 — crafted schema, the
  F-B5-5 calibration class.
- **Filed-status sweep:** F-B5-14-fork REPRODUCES (no menu item
  landed; `lookup_budget_ms`/`@zero_slot_budget_ms` unchurned since
  Run 27's own `c80a762` — git-verified; live values re-anchored).
  F-B5-15 REPRODUCES + extended (above). F-B5-16 mechanism
  REPRODUCES (three unbudgeted writes, no budget code), the
  two-full-waits timing NOT re-hit a second time — 30/30 policy-leg
  recoveries median 313 µs max 10.5 ms, 8/8 long-hold recoveries max
  1531 ms (one wait: the statement absorbed the window), cleanup
  clean in all 76 iterations. F-B5-17 REPRODUCES at HEAD
  (`wrap_execute_error |> disconnect_if_rolled_back`, driver.ex:458-459
  — the Runs-29/32/33 guard churn did not reorder it; in-txn
  ON-CONFLICT-ROLLBACK still yields `{:error, :rollback}`, names
  never reach a changeset, plain ABORT in-txn still converts).
  F-B5-18 REPRODUCED then CLOSED by the F-B5-20 fix.
- **Clean census (controls named):** the Run-34 handoff VERIFIED
  end-to-end — 9-shape emission matrix (single-named → real name;
  two-named / autoindex+named → derived with candidates kept; lone
  and composite autoindex → derived; innocent other-columns sibling
  never a candidate; expression form unchanged incl. F-B5-11's
  `table: nil, columns: []`; WITHOUT-ROWID PK never reaches the
  lookup; dotted-name zero-candidate degrade) with a 3/3-flip RED
  control mutating only candidate counts; changeset matrix 13/13
  (`:exact`/`:suffix`/`:prefix`/regex against resolved names,
  declare-both, derived-name conversions, the five raise arms as
  structural controls); adversarial legs — `sqlite_autoindex_*`
  spoof refused by SQLite itself, `we"ird` quoted identifier
  resolves intact, two-autoindex tables pick by column match, and
  the mainstream `create unique_index` conventional name resolves
  to itself so bare `unique_constraint/1` converts. Observer-only
  degradation measured end-to-end (150 iterations: median 118-149 µs
  fail-fast vs 2.0 s control median; judgment: fail-fast-and-degrade
  is the right trade, already documented on `with_xqlite/3` — the
  only defect was F-B5-24's wording). Sandbox replay 7/7 (owner-txn
  recovery, defer reset, no savepoint leak, checkin still rolls
  back). 24-cap counts autoindexes (24 resolves; both 25-index
  shapes refuse `{:unavailable, {:too_many_unique_indexes, 25}}` →
  derived). Budget degradation structured on the derived name
  (21/21 + 16/16 contended). Committed B5 tests 47/47 at review;
  connect_pragmas 15/15 post-fix. Observed-not-proven (named
  honestly): the wall-clock budget halt itself not re-hit in 80
  contended iterations (two shapes, both misses explained:
  blocked-then-failed reads short-circuit before the budget check;
  block-and-succeed reads fit the writer's gap) — the halt's
  OUTCOME (derived fallback) is proven via the read-failure branch;
  F-B5-16's exact timing; p10's statistical control-resolution leg.
- **Churn-scan handoff (B3/B8 court, seeded):** `driver.ex` reads a
  dozen repo-config values (`cache_size`, `mmap_size`,
  `wal_autocheckpoint`, …) and only three are validated now — the
  same silent-coercion class F-B5-20 fixed likely sits under the
  rest. B5 found the door; the sweep is B3/B8's. Filed
  [R35-handoff-config-validation].
- Dryness: two S2s — **B5 stays 0 of 2, NOT DRY**; the fix re-wets
  `validate_busy_timeout/1` and the busy_timeout config surface, the
  docs re-wet on any emission-rule change. Completeness critic (next
  B5 pass): build the budget halt deterministically (policy sleep_ms
  ≥ budget across retries) instead of statistically; F-B5-16's
  interleaving deliberately or downgrade its text to
  mechanism+ceiling; F-B5-17's OTHER half — what enrichment does TO
  a doomed connection (pragma reads/savepoint writes on a
  rolled-back conn); insert_all/update_all/on_conflict crosses under
  the new emission rule; equal index names across schemas (the
  invisible F-B5-25 residual); DDL racing the candidate COUNT
  (two→one mid-flight changes the emitted name); `Ecto.Multi` as
  the F-B5-19 population's real shape.

FIFTEEN straight finding runs.

## Run 36 — 2026-08-21 — lap 5, batch 5: B7 solo (the Run-28 re-anchor + its nine seeds)

Single Opus reviewer at `23d9524`; xqlite 0.11.0 (hex), SQLite 3.53.2
probe-confirmed. Engine churn since Run 28's `a2239cb` established
git-file-by-file: only the F-B6-5 default-refusal threading touched
engine files; the dance, refusal sites, snapshot reader, and
post-check comparison were byte-identical when the cover began. Gate:
six probes re-driven by the orchestrator (p02/p03/p05/p10/p09/p07 —
rc matched the manifest, outputs read line-by-line); fixes implemented
BY THE ORCHESTRATOR; the temp-trigger fix was caught HALF-WIRED by
the post-check itself mid-gate (see F-B7-43); stash-RED 7 red
(exactly the predicted seven) → 151/151 green.

- **F-B7-42 (S1, CONFIRMED, FIXED, RED→green).** An apostrophe inside
  a `--` or `/* */` comment desynchronized the Run-28 literal-blanking
  pass: SQLite's lexer opens no literal inside a comment, but the
  blanking regex knew only the four quote forms, so a comment
  apostrophe paired with the NEXT real literal's opening quote and
  erased everything between them from the scan — silently dropping a
  CHECK constraint (probed: `-- don't allow` + CHECK + `DEFAULT 'x'`
  rebuilt green, then accepted the violating insert) and
  AUTOINCREMENT (freed id re-handed, F-B7-17's exact class through a
  door F-B7-35 opened; `autoincrement_declared?` is the SHARED
  predicate, so the post-check was blind by design — Run 28's seed-4
  shared blind spot, realized). Reachability: `execute/1` DDL or an
  externally-created database with an English contraction in a schema
  comment — the exact population the opt-in rebuild serves. FIX: the
  one-pass alternation now recognizes both comment forms (leftmost
  match keeps a comment inside a literal literal, an apostrophe
  inside a comment commented; unterminated block comment runs to end
  of text per SQLite's lexer), each blanked to ONE SPACE — which is
  what SQLite treats a comment as, so comment-INTERLEAVED keywords
  (`ON /* c */ CONFLICT`, `PRIMARY /* c */ KEY AUTOINCREMENT`)
  became VISIBLE to every scan. That CLOSES F-B7-6's comment half
  outright (its "comment must sit BETWEEN the keywords" ruling bound
  had stopped describing the class; the accepted-limitation entry is
  superseded, honesty-ledger item 11 struck, the STE draft's
  fine-print line removed). Unit-checked over nine shapes pre-repo;
  committed pins (table_rebuild +4): apostrophe-comment CHECK
  refusal, comment-interleaved ON CONFLICT refusal, apostrophe-
  comment AUTOINCREMENT preservation, comment-interleaved
  PRIMARY-KEY-AUTOINCREMENT preservation.
- **F-B7-43 (S1, CONFIRMED, FIXED, RED→green).** Every schema-object
  read queried `sqlite_schema` only; a TEMP trigger on the target
  (same connection — `after_connect`, sandbox, or pool_size 1) was
  invisible to `fetch_table_triggers!`, died with the dropped table,
  and the migration reported success (probed: audit log stopped
  growing; main-schema twin survives). FIX in three parts, the third
  forced by the gate: (1) the trigger fetch unions
  `sqlite_temp_schema`; (2) re-creation reinstates the TEMP keyword —
  probed fact: SQLite canonicalizes stored temp-trigger SQL to a bare
  `CREATE TRIGGER` prefix across the TEMP/TEMPORARY/temp.-qualified
  spellings, so verbatim replay would land the trigger in MAIN (the
  post-check caught exactly that on the first committed pin run —
  "expected [], got [rb_ttrig_ai]" — the defense-in-depth layer
  catching the gate's own half-fix); an unexpected stored prefix
  refuses loudly rather than guessing; (3) the verifier's trigger
  snapshot is now schema-tagged (`{schema, name}` from a union read),
  so a trigger MIGRATING between schemas is a structure mismatch —
  the F-B7-46 blind-spot class shrunk by one shared fact. TEMP
  indexes need no union (SQLite refuses a TEMP index on a non-TEMP
  table). Committed pins: temp trigger survives INTO temp schema and
  fires (+ the verifier-side migration mismatch pin).
- **F-B7-44 (S2, CONFIRMED, FIXED, same union).** A TEMP view naming
  the target slipped past `refuse_dependent_schema_objects!` (main-
  schema read) and killed the dance mid-way with raw SQLite prose
  ("error in view ts_view: no such table" — the F-B7-13 misleading-
  error class; rollback clean, no data loss). The dependents read
  now unions both schemas with a schema marker, and
  `rewritten_dependents` re-reads both keyed `{schema, name}` (name
  collisions across schemas would otherwise collapse the map).
  Probed post-fix: the TEMP view now gets the same named pre-flight
  refusal as the main-schema control. Committed pin: temp view →
  ArgumentError + table intact.
- **F-B7-45 (S2, CONFIRMED, FIXED).** `encode_default/2`'s rescue
  built `UnsupportedDefaultError` with the raw context column, so
  the `:unencodable` path carried an ATOM on plain ADD where Run 34
  normalized every other door to string — one matcher could not
  cover the one error, the exact F-B6-5 contract re-broken on the
  fourth door. Fixed via `normalize_column/1` (the same one-word
  remedy); committed pin extends the unencodable test with the
  string assertion.
- **F-B7-46 (S3, CONFIRMED, FILED + docs).** `existing_to_column/4`
  and the model's `rebuilt_type/1` BOTH substitute "BLOB" for a
  nil/empty stored type, so the post-check compares two agreeing
  wrong readings and a typeless column comes back declared BLOB
  (affinity identical, storage classes probed unharmed; the RED
  control — a comma-spliced type the halves read DIFFERENTLY —
  aborted `{:post_check_abort, :columns}` and rolled back byte-
  identical, proving the verification fires when the halves
  disagree). Filed with the carry-empty-type remedy direction +
  README caveat line landed; the shared-helper enumeration (every
  function both halves call) seeded to the next pass.
- **Menu evidence gathered (maintainer court, NOT implemented):**
  [F-B7-41-menu] — 13 bare ArgumentError sites + 13 prose-matching
  tests + a post-dance bare RuntimeError carrying violations only as
  inspect-in-string; refuse-before-touch verified over seven
  flavours; recommendation: implement the struct,
  RebuildVerificationError as precedent, fold the RuntimeError in.
  [F-B6-6-menu] — routing add-with-fragment-default through the
  rebuild works TODAY (only `requires_rebuild?/1` gates it) but
  materializes the fragment ONCE for all existing rows (probed:
  identical timestamps), inherits every rebuild refusal, and costs
  O(table); recommendation: refuse pre-flight naming both honest
  workarounds (both probed working). Both entries enriched in
  BACKLOG.
- **Filed sweep:** F-B7-27 HOLDS (1 stat1 + 9 stat4 → 0/0; doc line
  still owed to Gate 3). F-B7-6 comment half HELD, then CLOSED by
  the F-B7-42 fix (its three by-design probe legs flipped green
  post-fix). F-B7-25-feature HOLDS. F-B7-29/30/31/32/36 all hold
  live (DESC+NULL-key with rowid RED control; fts5 refusal;
  checkout-pinning at pool_size 3 with clean pool; trigger-word-scan
  with kept-column control; savepointed confirm). F-B6-5 held on 3
  of 4 doors (the fourth = F-B7-45). F-B6-4's rebuild reach
  ESTABLISHED as fact: untouched columns carry stored type text
  verbatim, modified/added columns re-render through `column_type/2`
  (a no-op-looking `modify :x, :real` changes the declared type to
  NUMERIC) — README caveat landed.
- **Clean census (controls named; reviewer's, re-driven
  selectively):** cancel-mid-dance CLEAN 13/13 (cancel at 125 ms on
  both transaction shapes: 400k rows intact, no transient table, no
  savepoint/defer leakage, pool writable; reachability bound
  established — `Ecto.Migration.Runner`/`Migrator` drive DDL at
  `timeout: :infinity` so only a direct `execute_ddl/3` with a
  finite timeout reaches it); external-content fts5 CLEAN 7/7
  (MATCH + fts5 integrity-check post-rebuild, rowids carried;
  dropping an fts5-indexed column matches plain SQLite's own
  verdict); composite-PK raw-name compare LATENT-clean 18/18 (both
  sides carry stored spellings on every reachable path);
  savepoint-confirm adversarial lap CLEAN (transient-name collision
  loud on both doors, no savepoint leakage on three exits × both
  transaction shapes); `grants_own_key?` case-variance CLEAN
  (`same_column?/2` folds both sides). Observed-not-proven: the 7B
  refusal names the view, not the also-standing transient-name
  collision (true-but-incomplete message; safe).
- Dryness: two S1 + two S2 — **B7 stays 0 of 2, NOT DRY**; the fixes
  re-wet `without_string_literals/1`/`@quoted_text`/`blanked/1`, the
  trigger fetch + `recreate_trigger_sql/3`, the dependents
  read + `rewritten_dependents/3`, the verifier's `read_triggers/2`
  + snapshot trigger shape, and the `:unencodable` rescue.
  Completeness critic (next B7 pass): property test the blanking
  over generated texts mixing all six token kinds (BLOB literals,
  unbalanced quotes in identifiers, comments inside defaults, nested
  block-comment attempts, odd apostrophe counts); ATTACHed schemas —
  the THIRD namespace all four reads still miss (aux view = the
  F-B7-44 shape one door out; `resolve_stored_table_name!` under
  main-vs-aux name clashes); cancel landing on chosen dance
  statements (the DROP→RENAME window especially) via a deterministic
  hook; the Sandbox × ownership × confirm-savepoint three-way; the
  systematic shared-helper enumeration for F-B7-46's class
  (`strip_outer_parens`, `carried_default`, `word_pattern`,
  `primary_key_members`); `down`/rollback migrations through the
  rebuild; COLLATE/DEFERRABLE live-consequence legs for the comment
  door (severity was argued from CHECK/AUTOINCREMENT alone).

SIXTEEN straight finding runs.

## Run 37 — 2026-08-21 — lap 5, batch 6: B3 + B9 paired cover (the config sweep + the sync's remaining doors)

Single Opus reviewer at `df10b37`; xqlite 0.11.0 (hex), SQLite 3.53.2
probe-confirmed. Emission-churn verdict: telemetry.ex /
open_telemetry.ex / the guide byte-identical since Run 29's own fix
commit; fk_diagnostics.ex moduledoc-only; the one emission-CONTENT
change (connect stop error_reason now a wrapped exception, from Run
33) re-anchored live. Env fact on record: the adapter telemetry flag
is false in :dev, so telemetry probes must run MIX_ENV=test or they
silently measure a no-op build. Gate: thirteen probes re-driven by
the orchestrator (p01/p02/p03/p05/p06/p07/p08/p09/p10/p11/p14/p17/
p18 — rc 0 each, decisive lines read; p04's 14-spelling sweep, p15's
4-minute OFF matrix, p12/p13/p16/p19 accepted from the reviewer's
logs, p16 superseded by p17 per its own correction note); fixes
implemented BY THE ORCHESTRATOR; stash-RED 7 red (exactly the
predicted seven) → 88/88 green.

- **F-B3-11 (S2, CONFIRMED, FIXED, RED→green).** Eight repo-config
  values went to `NIF.set_pragma` unvalidated, and SQLite's pragma
  parser never errors on an unrecognized value — it picks a default:
  `journal_mode: :walk` meant DELETE mode, `synchronous: :ful` meant
  NORMAL, `temp_store: :mem` meant DEFAULT, and `foreign_keys:
  :nonsense` meant enforcement OFF — a real repo started cleanly and
  ACCEPTED an orphan FK row (probed end-to-end; the `true` control
  rejects). 84-case sweep table in the report; verdict per value.
  FIX: nine validators at connect beside the existing three —
  atom-enum for journal_mode/synchronous/temp_store/auto_vacuum
  (supersets of the URL parser's own allowlists, which already
  produce typed values, so both config paths pass), is_boolean for
  foreign_keys, is_integer for cache_size (negative = KiB is
  meaningful), non-negative integers for wal_autocheckpoint/
  mmap_size, and is_boolean for rich_fk_diagnostics — **F-B3-12 (S3,
  CONFIRMED, FIXED)**: the feature guard is a struct match on the
  atom true, so `rich_fk_diagnostics: "true"` silently disabled the
  whole feature. All nine reject through the same tag-tuple wrap
  family. DELIBERATE SCOPE CUT, documented: `custom_pragmas`
  keys/values stay unvalidated (the escape hatch; SQLite ignores
  unknown pragma names entirely) — README + STE now say so.
  Committed pins (connect_pragmas +2): a 14-shape rejection matrix,
  and the config-only enum values (`:persist`, `auto_vacuum: :none`)
  still connecting. DISCHARGES [R35-handoff-config-validation].
- **F-B3-13 (S2, CONFIRMED, FIXED, RED→green).** Run 33's comment-
  skip closed the comment door; a UTF-8 BOM (what Windows editors
  write at the top of a .sql file — reachability probed by literally
  reading such a file and running it) and a leading semicolon are
  also skipped by SQLite's tokenizer but were not skipped by
  `leading_keyword/1` — both F-B3-7 failure modes reopened for those
  spellings: `<BOM>BEGIN` leaked a durable post-failure write (probe:
  three-way discriminator, five spellings, both controls), `;COMMIT`
  left a stale flag that destroyed a healthy pooled connection on
  the next ordinary error. The rebuild engine's own raw
  BEGIN/COMMIT/ROLLBACK make this sync load-bearing for adapter code
  too. FIX: `?;` joined the whitespace-skip set and a BOM clause
  skips `EF BB BF` — the reviewer's 14-spelling sweep (nested
  comments, NBSP, vertical tab, unterminated forms, CRLF) puts BOM +
  semicolon as the complete remaining set on this runtime. Committed
  pins (transaction_state +3): BOM-BEGIN flag sync, semicolon-COMMIT
  flag sync, BOM-BEGIN → rollback-class violation disconnects.
- **F-B3-14 (S2, CONFIRMED, docs-fixed + menu).** `with_xqlite/3`
  always starts its own checkout — the moduledoc's "under the
  Sandbox the caller's sandboxed connection is reused, so nesting is
  fine" was FALSE for everything but a bare call: inside
  Repo.transaction/checkout it queue-timeout-raises at pool_size 1
  (on the plain pool inside Repo.transaction the enclosing
  transaction ROLLS BACK), and at pool > 1 the callback silently
  runs on a DIFFERENT pooled connection (probed via a
  connection-scoped marker), so every connection-scoped install
  lands on the wrong connection — `txn_state/2` and
  `connection_stats/1` route through it and hit the same wall.
  Moduledoc rewritten (never nest; the exact failure shapes; bare-
  call-only sandbox reuse); the implement option (reuse the caller's
  checkout — needs a discovery mechanism DBConnection does not
  expose) filed [F-B3-14-menu].
- **F-B9-15 (S2, CONFIRMED, FIXED, RED→green).** OTel `error.type`
  fell through to the generic struct clause for `%XqliteEcto3.Error{}`,
  so since Run 33 every adapter error mapped to the ONE value
  "XqliteEcto3.Error" — grouping by error class impossible, both
  docs surfaces claiming the opposite (F-B9-10's collapse had moved,
  not died). FIX: a clause emits the struct's typed :type atom
  (nil-type falls back to the struct name); moduledoc + guide
  corrected. Committed pins (otel +3, one flipped): wrapped error →
  "constraint_violation", disconnect-wrapped kept, nil-type + foreign
  struct fallbacks.
- **F-B9-16 (S3, CONFIRMED, FIXED).** The three statement_cache
  events carried `[:sql]` alone while every sibling carries :conn —
  and the cache is PER CONNECTION, so a pool-wide hit-rate is
  depressed by pool_size misses per distinct statement and
  cached_count interleaves independent counters
  (pool-size-controlled measurement). FIX: :conn added to all three
  emissions; per-connection sentence in both docs surfaces; the
  conn-discriminator pinned. Also makes the F-B8-9 :conn-join
  correlation story uniform.
- **F-B3-15 (S3, CONFIRMED, docs-fixed).** `PRAGMA
  wal_autocheckpoint` through SQL always reports 0 (xqlite's master
  WAL callback owns SQLite's single slot and emulates the
  autocheckpoint) while `NIF.get_pragma` reports the effective
  value — probed same-connection 321 vs 0. README + STE now carry
  the honest-read line.
- **F-B3-16 (S3, CONFIRMED, docs-fixed).** A session-extension
  recorder obtained through the bridge keeps recording OTHER
  callers' pool traffic after check-in (probe: 64 changeset bytes
  written by ordinary Repo.query! calls post-callback; scoped
  control clean) — it now leads the moduledoc's persistent-state
  list. The F-B3-10 amplification sentence sharpened with the
  measured curve: ONE poisoned connection of eight absorbed 41/48
  contended writes, and poisoning more barely moves it (43, 46;
  0-poisoned control 48/48 ok) — flat, near-total, from one.
- **F-B9-17 (S3, CONFIRMED, filed → F-B9-13 WIDENED).** The
  telemetry-OFF build breaks FOUR files (17 tests: telemetry_test
  0/14, fk_diagnostics 12/13 at the line-334 :start assert_receive,
  statement_cache 13/14, telemetry law 2/3), not the one F-B9-13
  filed; entry rewritten with the settled remedy trade-off
  (flag-guards keep the mixed files' non-telemetry coverage;
  whole-file guard for telemetry_test). Reviewer verified OFF → ON
  restoration; not fixed blind, per the standing rule.
- **F-B9-18 (S3, CONFIRMED, filed → menu extended).** The connect
  stop event's error_reason (a details-less wrapped exception since
  Run 33) carries the rejected config value only as message prose —
  folded into [F-B1-menu-connect-error-details] as its telemetry
  consequence; the Run-37 validators grew that family by nine tags.
- **F-B8-9-docs CLOSED.** The owed correlation line landed in the
  guide with probe-backed content: join disconnect ↔ handle_execute
  :stop on :conn (same reference, probed); reason shapes for
  operation-error vs cancel on record; the cancel-vs-deadline-recycle
  ambiguity resolved via the :stop event's error_reason.
- **Filed sweep (rest):** F-B9-14 HOLDS (moduledoc-only churn
  confirmed; crash shapes per malformed row on record; LATENT — the
  pragma returns exactly 8 columns on 3.53.2; build_violation/2
  protected by child_tables/1's validation). F-B1-5 HOLDS with the
  Run-37 caveat (a failing stream_close could NOT be constructed —
  exposure unproven without NIF fault injection; entry annotated).
  F-B3-4-xqlite HOLDS (observer/policy drop busy_timeout 4567→0,
  unregister does not restore, documented remedy works). F-B3-1
  HOLDS (`:memory:` + pool: 7/24 inserts on the table's connection).
  F-B9-4 HOLDS (lookup still span-less). The Run-14
  orchestrator-unverified B3 seed SUPERSEDED (absorbed by Run 23's
  F-B3-5; re-confirmed on every door-A arm).
- **Clean census (controls named):** the Run-33 comment-prefix
  re-anchor CLEAN — five spellings through BOTH F-B3-7 doors
  (disconnect-at-damage + no-false-destroy), leak-detector and
  no-txn controls; F-B3-8 declare/fetch routing CLEAN at HEAD
  (streamed ROLLBACK-class DML inside Ecto.Multi disconnects at
  damage; deliberate-commit control); multi-statement SQL is NOT a
  route into the sync (structured :multiple_statements rejection
  both paths); `{:shared, owner}` sandbox under ROLLBACK-class
  violation CLEAN — settled by an INDEPENDENT second SQLite
  connection (0 committed rows mid/after; deliberate-commit
  control); backup/serialize handles across check-in CLEAN (no
  outliving handle; smuggled-ref behavior as documented);
  set_busy_policy form as documented; both span pairs re-anchored
  (start-metadata merge rule intact); :checkout under the SANDBOX
  ownership pool CLEAN — 0 events over 20 ownership cycles + 20
  queries + 50 plain-pool queries, fresh-pool control fires 2
  (F-B9-7's corrected docs hold in the risky configuration);
  statement_cache :miss fallback premise CORRECTED (fallback SQL
  fails anyway — no succeeds-via-fallback case; trailing single
  semicolon does NOT defeat the cache — an earlier pool-size
  artifact, corrected by the controlled measurement). Deferrals,
  explicit: NIF fault injection for a pool-reachable :exception (not
  attempted — carried forward); native-vs-ns on non-Linux (not
  probeable here). Observed-not-proven: the bare RuntimeError shape
  escaping Repo.transaction(multi) on a mid-Multi disconnect (one
  observation).
- Dryness: four S2 across the pair — **B3 stays 0 of 2, B9 stays
  0 of 2, NOT DRY**; the fixes re-wet the nine validators + the
  connect chain, `leading_keyword/1`'s skip set, the OTel
  `error_type` clauses, and the statement_cache emission metadata.
  Completeness critic (next passes): config-value COMBINATIONS
  (journal_mode × wal_autocheckpoint; mode: :readonly × the
  coerced set — writable/2 nils two values, different silent
  profile); the `hooks` config value (never swept — four clauses,
  unregistered names, malformed entries); the BOM/semicolon fix's
  own covering pass hunting beyond ASCII (read SQLite's tokenizer
  skip set in C rather than inferring from behavior); with_xqlite
  under Sandbox at pool > 1 from an ALLOWED (non-owner) process —
  the configuration test suites actually run; F-B1-5 needs NIF
  fault injection or a re-grade to discard-unreachable; the
  :exception construction still owed; a second lock-hold duration
  for the amplification curve; the Multi RuntimeError shape.

SEVENTEEN straight finding runs.

## Run 38 — 2026-08-21 — lap 5, batch 7: B2 solo (the corrected list re-covered in-suite)

Single Opus reviewer at `649de25`; xqlite 0.11.0 (hex), SQLite 3.53.2
probe-confirmed; vendored ecto 3.14.1 / ecto_sql 3.14.0 unchanged
since Run 30 (mix.lock untouched). Census at HEAD: **440 passed / 26
excluded, exit 0 — zero delta from Run 30 across 25 commits**
(test_helper's one commit since was comment-only). INSTRUMENT UPGRADE
banked: `--trace` full-suite runs give a per-test exclusion census,
and `--include "test:test <name>"` re-enables excluded tests INSIDE
full-suite context — feeding all 26 names in one run yields ground
truth at once (441/466, exactly 25 failures, the 26→0 excluded drop
as built-in control). The old `--only <tag>` isolate-runs are retired
(strictly weaker; blind to the migration-conditional class, which
keeps its own adapter-owned probes). Gate: seven probes re-driven by
the orchestrator (01/02/06/08×3-legs/09/10/14 — the 08/09/10 first
attempt failed on MY invocation, missing MIX_ENV=test + the leg
argument; correct-form re-drives rc 0 with outputs matching);
fixes implemented BY THE ORCHESTRATOR. Stash-RED: N/A this gate —
every fix is rationale/message prose, nothing pinnable under the
no-text-assertion doctrine (recorded honestly, not skipped silently).

- **F-B2-21 (S2, CONFIRMED, docs-fixed).** The tags doc's
  `:bitstring_type` rationale was false at HEAD: it named
  `default_expr/1` (the function is arity 3) raising "a bare
  FunctionClauseError" — at HEAD the shared migration's
  `bs_with_default` raises structured `XqliteEcto3.UnsupportedDefaultError`
  (re-driven live; the whole migration rolls back, so un-excluding
  still crashes all 440 tests — the exclusion itself stands). Run 31
  fixed the test_helper paragraph and left the public doc — the
  F-B2-20 class (a listed re-wetter fired without a sweep) one lap
  later. Doc row now mirrors the helper wording.
- **F-B2-22 (S2, CONFIRMED, docs-fixed).** The `sql.exs:30`
  exclusion blamed "Postgres `$1::text[]` cast syntax" — SQLite
  ACCEPTS that statement (re-driven: `accepted: true`, empty-string
  column name, the bound list back as JSON text; `$1::text` parses
  as a TCL-style parameter name, `[]` as a bracket-quoted alias).
  The real cause is the untyped-raw-result gap: no load hook decodes
  the JSON-stored list — the same argument as `type.exs:359`. All
  three references reworded; the sibling `sql.exs:38` verified as a
  genuine grammar rejection and left as-is. Critic seed accepted:
  every grammar-blaming rationale gets a bare-`Repo.query` check
  next pass.
- **F-B2-23 (S3, CONFIRMED, fixed).** The comment two lines above
  the F-B2-19-corrected tuple still said `type.exs:362`; now 359.
- **F-B2-24 (S3, CONFIRMED, docs-fixed).** The `:placeholders` row's
  past-tense `repo.exs:1092` pointer named the wrong test (the
  both-tags test sits at :1106 at HEAD); reworded to the current
  line. Nothing could self-fulfil — record-keeping only.
- **F-B2-25 (S3, CONFIRMED, docs-fixed).** Neither artifact
  disclosed that `:microsecond_precision` excludes one PASSING test
  — conspicuous against the doc's own n/m convention. Both artifacts
  now carry the 4/5 disclosure pointing at the recorded F-B2-8
  trade. The narrowing itself stays deliberately not-churned.
- **F-B2-26 (S3, CONFIRMED, message-fixed).** `update_op(:push|:pull)`
  raised "Arrays are not supported for SQLite" — false since
  F-B2-17 shipped arrays; only the two operators are unsupported.
  Both messages now say exactly that (arrays themselves stored as
  JSON text). Grep-verified: `push:`/`pull:` are exercised only
  inside the excluded `type.exs:234`, so no committed behavior
  moves. The implement option (push/pull via SQLite JSON functions)
  filed as a menu line.
- **F-B2-27 (S3, CONFIRMED, docs-fixed).** The `:duration_type`
  rationale fused three separable facts and omitted the one a
  maintainer needs: (a) the migration builds the durations table
  WITHOUT complaint (re-driven — the table is absent only because
  the tag is excluded; all four columns plain DURATION, the default
  stored as literal text '10 MONTH'); (b) with the table present
  the upstream body still dies at OUR encoder
  (`UnencodableParameterError`, the strongest form, first shown
  with the table there); (c) even an encode+load path could not
  satisfy the Postgres fields:/precision: truncation asserts — the
  schema carries nothing to truncate by. Row rewritten three-way.
- **Filed sweep:** F-B2-8 CONFIRMED as the ONLY over-broad
  exclusion — the 26-include run leaves exactly one non-failing
  name, `interval.exs:194` (its four siblings RED in the same run =
  the built-in control); disclosure landed (above), narrowing stays
  a recorded trade. F-B2-7-code stays superseded; the three ALTER
  pointers survive Run 37's churn (`refuse_reference_changes!`
  fires first on all three, live stacks). F-B2-14/18-adjacent stay
  closed — their structured errors are the two this pass observed.
  macOS-flake bookkeeping CORRECTED: the LEDGER records one
  occurrence (Run 32's addendum); the second lives in the Run-33
  board stanza (re-run green) — count stands at TWO, disposition
  unchanged (a third = exclusion-with-rationale through this
  axis's court; the test passed in all three of this pass's suite
  runs).
- **Clean census (controls named):** census 440/26 exit 0 (the
  26-include run is the RED twin: 25 failures, exit 2); the six
  ex-`:array_type` tests run and pass IN-SUITE (type.exs:234 shows
  `(excluded)` in the same trace — Priority 1 discharged, Run 30's
  gate ruling satisfied); all 11 tags + 9 location tuples measured
  against claims — every count exact, bijection doc↔helper exact
  both directions (the comm/unmatched branches printed empty; the
  SNAP_MISMATCH branch that caught F-B2-19 fired zero times);
  transaction.exs:161 re-proven jointly-caused (2×2 matrix: only
  pool 2 + :deferred passes); logging.exs:74 mechanism pinned
  (handler fires; the in-handler params assert raises first);
  `:like_match_blob` re-anchored (LIKE_DOESNT_MATCH_BLOBS absent
  from 54 compile options); `x in t.ints` → JSON_EACH live; the
  header's 16/18 file count true. Observed-not-proven: Run 37's
  nine validators break no rationale (green suite is the positive
  evidence; the negative direction is unreachable from the vendored
  surface); the ~12 plain "supported" mechanism sentences
  dispositioned structural-only.
- **MAINTAINER SCOPE DIRECTIVE (Dimi, 2026-08-21, recorded at this
  gate):** no interest in hunting valid+invalid pragma-value
  COMBINATIONS or schema-resolution-order edge cases. Applied:
  B3's combinations seed and B7's ATTACH deep-probe seed are
  reframed — the standing posture for those surfaces is
  validate-or-refuse at our boundary plus documentation, not
  resolution probing (annotations in the axes seed lists).
- Dryness: two S2 — **B2 stays 0 of 2, NOT DRY**; the fixes re-wet
  the tags doc + helper rationale prose and the push/pull messages.
  Completeness critic (next B2 pass): start by DIFFING every helper
  rationale paragraph against its doc row (the F-B2-20/21 class is
  the axis's recurring leak — two laps running); sweep the
  adapter's refusal messages against the doc's feature claims
  (F-B2-26 was found by accident); run every remaining
  grammar-blaming rationale through bare `Repo.query`; the
  migration-conditional pair (bitstring/duration) keeps its
  adapter-owned probes each pass; upstream-bump watch still owed
  (mix.lock unmoved since before Run 24).

EIGHTEEN straight finding runs.

## Run 39 — 2026-08-21 — lap 5, batch 8: B4 solo (the affinity-rewrite round-trips + the loader side)

Single Opus reviewer at `c854993`; xqlite 0.11.0 (hex).
`bind_form/1`/`encode_param/2` git-verified UNTOUCHED since Run 31's
own fixes — one anchor re-drive of the bind-exactness property covered
them; the weight went to the Run-34 affinity rewrite, defaults, and
the loader. Gate: seven probes re-driven (p1/p2/p3/p4/p5@2000/p6/p10,
rc 0 each, decisive lines read); fixes BY THE ORCHESTRATOR; stash-RED
1 red (exactly the predicted one — the typed-load-error pin; the two
characterization pins are green by nature, recorded) → 34/34.

- **F-B4-10 (S1, CONFIRMED; message+docs remedied in-run, code fix =
  maintainer menu).** A `:decimal` field over a TEXT-affinity column
  silently stores SQLite's float-to-text rendering — ~10% of accepted
  values drift (2/12 full-route; 130-150/~1280 across three 2000-run
  property sweeps; `CAST` attribution to SQLite's rendering; the
  pre-fix text-bind control exact 12/12). A regression consequence of
  Run 31's bind-as-number fix (which stays right — it killed the
  wrong-results class); unfixable at the bind boundary (column-blind).
  Worst part: `DecimalPrecisionError`'s own message said "use a
  :string column", steering users EXACTLY into the drift. Remedied:
  the message now prescribes a :string FIELD and says a :decimal
  field over TEXT does not help; README gained the TEXT-affinity twin
  of the REAL caveat (+ STE mirror); a characterization pin asserts
  the drift and the string-field exactness. The opt-in exact type
  filed [F-B4-10-menu].
- **F-B4-11 (S2, CONFIRMED, FIXED, RED→green).** `decimal_decode/1`
  called `Decimal.new/1` unguarded, so a BLOB or non-numeric TEXT
  under a :decimal field (NUMERIC affinity preserves both; legacy
  writers produce both) raised a bare `Decimal.Error` — no message
  field, no table/column — killing the whole query incl. good rows.
  Fixed: full-clean `Decimal.parse/1` or `:error` (routing into
  Ecto's typed load failure naming field+value, the same path
  inf/nan already took) + the missing catch-all clause. Pins: blob +
  non-numeric text raise Ecto's ArgumentError, the same rows load
  via :string, a clean numeric row loads. Sub-facts recorded:
  sum/avg coerce non-numeric to 0 (SQLite semantics, README line
  landed); digit-bytes BLOBs still parse (bytes are valid text).
- **F-B4-12 (S3, CONFIRMED, FIXED).** The undocumented
  `:json_library` knob was honored on ONE of four JSON paths and its
  rescue named Jason's exception, so a configured library's encode
  error escaped bare — and a DDL default written by it could be
  unreadable by the Jason-hardcoded loader. Pre-1.0 ruling applied:
  knob DELETED, Jason hardcoded (zero references anywhere public).
- **F-B4-13 (S3, CONFIRMED, docs-fixed).** `precision:`/`scale:`
  render into the DDL but SQLite ignores them and the guard's limit
  is float64's — stated only in a private moduledoc; README line
  landed (declared precision is documentation value only).
- **F-B4-14 (S3, CONFIRMED, pinned).** JSON-carried decimals bypass
  the guard entirely: `{:array, :decimal}` round-trips
  beyond-precision values EXACTLY (Jason encodes decimals as
  strings), `:map` loads them back as Strings — undefended until
  now; three characterization pins landed with the plain-field guard
  refusal as the RED.
- **Filed sweep:** F-B4-1's remedy record HOLDS on all four claims
  (numeric storage classes, ORDER BY/range vs the TEXT control,
  HAVING/coalesce agreement); F-B4-4's positions HOLD (incl. nested
  structs); the bitstring refusal class HOLDS on four doors;
  [UUID-case] holds exactly as filed; the F-B6-5/F-B7-45 column
  contract HOLDS (44 refusals, zero atom columns). The
  migration-helper `default:` seed DOES NOT EXIST at HEAD (recorded).
- **Clean census:** the affinity rewrite is CLEAN with the strongest
  RED of the lap — 13 spellings (incl. three invented REAL-affinity
  ones) all land NUMERIC and round-trip exactly, while a raw REAL
  control truncates every witness value; guard verdicts
  column-independent; three 2000-run property sweeps: NUMERIC legs
  zero drift/zero unexpected raises. The wrong-results class stays
  dead on exotic columns with a true pre-fix RED (text-bind returns
  empty on all three shapes). Run 34's census note CORRECTED on
  record: arithmetic IS vulnerable when the decimal sits on the
  comparison side of the operator (`f8 + 0 > text` empty) — the
  shipped fix covers it; the note's "comparison, not arithmetic"
  wording was too narrow. Defaults: 44 structured refusals / 0
  accepted across 11 classes × 4 doors; refused rebuilds leave no
  debris (5 rounds). Seeds insert_all-placeholders / on_conflict-set
  / update_all-set CLEAN with positions. Anchors 172 committed tests
  green. Observed-not-proven: the DateTime legs (untouched by churn,
  anchors only); F-B4-10's Ecto-route pre-fix RED is inference from
  the shared bind path (repo read-only for the reviewer).
- Dryness: an S1 + an S2 — **B4 resets to 0 of 2, NOT DRY**; the
  fixes re-wet `decimal_decode/1`, `encode_default/2`, the
  `DecimalPrecisionError` message + README decimal section.
  Completeness critic (next B4 pass): drive F-B4-10 through
  insert_all/update_all/on_conflict on a TEXT column; the full
  migrator route for exotic-spelling DDL; a systematic
  two-competing-markers spelling sweep; `references(type: :float8)`;
  the rebuild re-rendering an exotic spelling under the rewrite;
  `expr(%Decimal{})` full matrix (spot-checked here); a genuinely
  external foreign writer for the loader legs.

NINETEEN straight finding runs.

## Run 40 — 2026-08-21 — lap 5, batch 9 (the closer): X1 + X2 paired cover

Single Opus reviewer began at `13ebcd3`, HEAD moved mid-run to
`a58b356` (changelog-only; verified, no code re-review owed); xqlite
0.11.0 hex tarball hash-verified. Drift verdict: tarball ≡ v0.11.0
tag on all six native sources; repo worktree differs from the tag
only in the clippy rewrite (schema.rs, no behavior) and the two
UNSHIPPED doc fixes (below). Correction on record: the hex package
DOES ship the full Rust source tree. Gate: four probes re-driven
(p7/p11/p2/p3 — census 48/48 CLEAN, arity CLEAN, doc-parity CLEAN
against the code's rule, p11 DIRTY = the two S3s); fixes BY THE
ORCHESTRATOR; stash-RED predicted 1 (the statement pin) — verified
in the gate log.

- **F-X2-3 (S2, CONFIRMED; staged for release — publish is the
  maintainer's).** Run 26's two xqlite doc fixes (the
  query_with_changes rule correction + the README compatibility
  statement) were committed to main AFTER the v0.11.0 tag and never
  released: hex/hexdocs still teach the abandoned empty-columns rule
  that produced the adapter's own cached-path bug once already
  (probe: the shipped doc's model predicts 0 for all three RETURNING
  shapes; the shipped code reports the real count). Remedy staged:
  xqlite CHANGELOG gained an Unreleased section recording exactly
  what a 0.11.1 patch delivers (docs + the clippy rewrite, no
  behavior); the release itself (version bump, tag, publish) is
  queued for the maintainer — a patch stays inside the adapter's
  `~> 0.11.0` bound, so no adapter change is owed. Re-wets on the
  next xqlite release.
- **F-X1-5 (S3, CONFIRMED, FIXED, RED→green).** `Error.statement`
  was declared in the struct and the public typespec and never
  written by any path — a dead promise. Fixed: the failing SQL is
  stamped at both `wrap_execute_error/4` clauses and both
  `handle_declare` error branches (`put_statement/2`);
  `handle_fetch` stays nil truthfully (the cursor does not carry the
  SQL). Pin: a failing `Repo.query` carries its statement.
- **F-X1-6 (S3, CONFIRMED, FIXED).** `@type details` omitted the
  three plain-map payloads real wrap clauses build (busy family /
  utf8 / cannot_open_database — six of 48 shapes outside their own
  declared type, and the set had grown by one since the original
  ACCEPT disposition with nothing pinning the count). Fixed by
  widening the union with the three map shapes; no runtime change.
- **Census + filed sweep:** the 48-member union is IDENTICAL to Run
  26 with one fully-attributed class move (cannot_open_database →
  dedicated clause, the Run-33 churn); zero fallthrough, zero nil
  types. The 18 connect tags verified end-to-end (wrap, Exception.t,
  telemetry stop, OTel type) — [F-B1-menu-connect-error-details]
  HOLDS and now covers 18 sites. [F-B8-2] holds (no cancellable
  stream fetch exported at 0.11.0). X1-2 / F-X1-1 / F-X2-1 stay
  closed (F-X2-1 re-verified through the adapter's CACHED path — a
  first). F-X1-4 holds on the adapter side across eight consistent
  pairing sites; noted: the STE drafts live outside version control,
  and bench/mix.exs's lockfile comment is stale (path deps). The new
  loader `:error` path recorded CLEAN by Ecto's contract with two
  honest limitations on record (prose-only diagnostic; the adapter
  span reads success because Ecto loads after it closes). Doc parity
  on cancellation and the WAL read-back story CLEAN across the pair.
  NIF call surface: 41 distinct name+arity calls, all exported at
  0.11.0 exactly (AST-walk census; the prose/doc-block miscounts of
  earlier name-grep censuses explained on record). Passed along:
  bare RuntimeErrors at xqlite_ecto3.ex:572/:846 belong to the
  rebuild court ([F-B7-41-menu] already carries the :846 class).
- Dryness: an S2 + two S3 — **X1 and X2 both stay 0 of 2, NOT
  DRY**; TWENTY straight finding runs; **LAP 5 COMPLETE** (all nine
  planned batches; B10 stays DRY-as-recorded from lap 2, its
  re-cover rides the bench work). Re-wets ALSO on: any new wrap/1
  clause (the details union + the statement field), the next xqlite
  release (F-X2-3). Completeness critic (next X pass): the
  full-48 emission question (session/blob/backup shapes never
  provoked); the busy-slot claims through a pooled checkout;
  hexdocs rendering read directly; the two census facts worth
  pinning (:invalid_pragma_name fires only on malformed names;
  :invalid_stream_handle constructible only via stream_close).

TWENTY straight finding runs. LAP 5 COMPLETE.

## Run 41 — 2026-08-21 — lap 6, batch 1 (the opener): B8 solo

Lap-6 step-0 (orchestrator, git-verified): five driver.ex commits
since B8's Run-32 gate at `91415ff` — its own fix `6bc7d00`, TWO
keyword-sync churns (`36e7a5b`, `72e4407` — named B8 re-wet
triggers), busy_timeout validation (`3d96665`), the Run-40 statement
stamping (`9d11c17`). Single Opus reviewer at `08ea3cb`; xqlite dep
0.11.0 from hex (XQLITE_PATH confirmed unset). Gate: all four
finding probes + the F-B8-1 re-drive re-driven by the orchestrator
(p1/p10/p4/p11 all exit 1, reproduced; p3 at 3007/3005/301 ms);
every code claim spot-checked at HEAD; fixes BY THE ORCHESTRATOR;
stash-RED PREDICTED 5 red — got exactly 5 (105/110 stashed →
110/110 restored).

- **F-B8-8 (S2, CONFIRMED, FIXED, RED→green).** The keyword sync
  (`sync_after_transaction_control/2`) refreshed the transaction
  FLAG but never the savepoint COUNTER — its two siblings
  (`handle_commit/2`, `handle_rollback/2` non-savepoint arms) reset
  both. A raw `COMMIT`/`ROLLBACK` run as ordinary SQL amid a managed
  savepoint left the counter stale-high forever; the next outermost
  RELEASE decremented to non-zero, took `released_savepoint_state/1`'s
  read-free `_nested` arm, and the cached flag then lied
  (`:transaction` vs real autocommit) — over-disconnecting the next
  failed autocommit statement. Falsified BOTH the rebuild comment's
  raw-dance safety claim (xqlite_ecto3.ex) and Run 32's
  no-over-disconnect pin. Blast radius capped at S2: through pure
  Repo/Sandbox flows the drift self-heals behind an unrelated
  "no such savepoint" disconnect (probed both routes). Fix:
  `refresh_transaction_status/1` zeroes the counter when landing
  `:idle` (autocommit means every savepoint is gone);
  `released_savepoint_state/1` treats non-positive as outermost
  (belt). Committed pins: counter zeroed after raw ROLLBACK +
  end-to-end truthful top-level-savepoint scope afterwards
  (`driver_transaction_state_test.exs` +2). NB: this F-B8-8
  (finding) ≠ Run 32's [F-B8-8-handoff] (closed Run 33) — the
  handoff id predates the finding id sequence.
- **F-B8-9 (S2, CONFIRMED, FIXED, RED→green).** A transaction-mode
  atom in repo config's `:mode` key — DBConnection's own spelling
  for transaction mode, and the README used both meanings one
  sentence apart — failed EVERY connect via `open_database/2`'s
  refusal, bricking the pool; callers saw only
  `%DBConnection.ConnectionError{reason: :queue_timeout}`, the error
  the README's table says a bigger pool fixes. `mode: :immediate` is
  the plausible-mistake spelling (the adapter's own
  default_transaction_mode value). Fix: `validate_connection_mode/1`
  heads the connect chain — the five transaction-mode atoms get a
  dedicated `{:transaction_mode_as_connection_mode, _}` refusal
  (generic wrap, no new wrap clause; type union is open), garbage
  keeps `{:invalid_connection_mode, _}`; `open_database/2` dropped
  its now-unreachable catch-all; README disambiguates. Mirror
  direction probed CLEAN (config `:readonly` does not leak into
  `handle_begin`). Seed-6 correction on record: ecto_sql's
  @pool_opts forwards only timeout/pool keys from repo config into
  operations — `:mode` never reaches `handle_begin/2` from config,
  so the seed's premise (config mode applies per-transaction) was
  false; the connect-time collision is the real bite. Committed pin:
  all five transaction modes refused with the dedicated type
  (`driver_connect_pragmas_test.exs` +1).
- **F-B8-10 (S2, CONFIRMED, FIXED, RED→green).** `XqliteEcto3.URL`
  documented AND parsed `busy_timeout=infinity` (spec typed
  `:timeout`) while Run 35's `validate_busy_timeout/1` deliberately
  refuses `:infinity` — the documented URL could not open a single
  connection (`{:connect_failed, %Error{type: :invalid_busy_timeout}}`,
  control `busy_timeout=10000` connects). Ruling: refuse at the
  parser rather than translate (silent infinity→int32-max is a
  silent config transformation; the driver's refusal was a gated
  Run-35 decision). Fix: busy_timeout's spec is `:non_neg_integer`;
  moduledoc dropped `| infinity`; `timeout`/`connect_timeout` keep
  `:infinity` (existing controls green). The old
  accepts-infinity test REWRITTEN into the refusal pin
  (`url_test.exs`, deliberate contract change, gated here). Filed
  cross-court note: the drift was created by B5's `3d96665`
  validation landing without the URL surface sweep.
- **F-B8-11 (S3, CONFIRMED, FIXED, RED→green).** The rollback
  guard's `_open_or_unknown` arm folded status-READ ERRORS into
  fail-open while `checkout/1` and `ping/1` disconnect on the
  identical error (`{:error, :connection_closed}` live-probed) — a
  dead connection stayed checked into the pool. Reachability low
  (needs an already-closed handle: `disconnect/2` or the
  `with_xqlite/3` escape hatch), hence S3; fixed in-run anyway
  (three-arm split, read error ⇒ disconnect with the original
  wrapped error, matching the siblings' disposition). Committed pin:
  closed-conn guard path disconnects
  (`driver_transaction_state_test.exs` +1).
- **F-B8-1 re-driven at 0.11.0: REPRODUCES** — 3007 ms return for a
  300 ms token on a lock-contended write; the `:infinity` control at
  3005 ms proves the token contributed nothing; the uncontended
  control cancels at 301 ms proving the token works when the
  progress handler ticks. Its DOCS half CLOSED: README pitch bullet
  + timeout section now state the busy-wait carve-out (the busy
  handler blocks the progress handler; `busy_timeout` bounds the
  wait; structured `:database_busy_or_locked` distinguishes it; set
  `busy_timeout` at or below the deadline when lock waits must
  respect it). STE drafts mirrored. Backlog entry updated —
  behavior half stays open, options unchanged.
- **CLEAN (controls named):** declare/fetch error routing inside a
  top-level savepoint asserted against a live `transaction_status`
  read; streamed rollback-class DML under a top-level savepoint
  disconnects at the point of damage (plain-BEGIN control — the
  savepoint arm is not weaker); commit/rollback hooks × cancelled
  write coherent across four instruments (cancelled-read fires no
  hook and keeps its transaction; normal-commit control); a
  multi-statement string cannot slip transaction control past the
  `columns: []` gate (`:multiple_statements` both directions, single
  COMMIT control syncs); an abandoned stream across a disconnect
  retains no read lock (`wal_checkpoint(TRUNCATE)` `{0,0,0}`;
  deallocate + GC controls); non-integer `:timeout` unreachable
  through Repo (DBConnection's deadline arithmetic raises
  ArgumentError first; driver-direct FunctionClauseError noted,
  shielded); the cancelled branch still skips `wrap_execute_error/4`
  — consistent with Run 40's stamping (ConnectionError carries no
  statement field).
- **HANDOFFS FILED:** [F-X1-7] `handle_fetch/4` error-branch
  statement stamping — Run 40's truthful-nil rationale CORRECTED
  (the QUERY param carries the SQL; the driver ignores it);
  [F-B8-12-handoff] top-level `mode: :savepoint` runs DEFERRED,
  silently discarding the `default_transaction_mode: :immediate`
  promise (B1/B2 court, txn_state leg unmeasured — the probe died
  on F-B8-9's brick first).
- Dryness: three S2 + one S3 — **B8 stays 0 of 2, NOT DRY**;
  TWENTY-ONE straight finding runs. Re-wets ALSO on:
  `validate_connection_mode/1`, the URL busy_timeout spec, the
  guard's read-error arm, `refresh_transaction_status/1`'s counter
  reset. Completeness critic (next B8 pass): the `{:fallback, state}`
  partly-dead path (`{:error, {:cannot_execute, _}}` half unprobed);
  `stmt_prepare` before any cancel token exists (the F-B8-1 shape
  may cover preparation — measure); repo-config `timeout:` sweep
  (`:infinity`/`0`/sandbox — the one B8-relevant key ecto_sql DOES
  forward per-operation); FK-replay × guard fault injection (a
  failed `release_savepoint` cleanup hands the guard a
  diagnostics-started transaction — the F-B8-4 shape); the
  negative-counter impossibility (belt-guarded, probe-unpinned);
  rebuild's `in_wrapping_transaction?` DBConnection.status
  half-blindness (shared with B7).

## Run 42 — 2026-08-21 — lap 6, batch 2: B1 solo (conformance re-audit + the seed-8 court)

Single Opus reviewer at `a566b54`; db_connection 2.10.2, ecto
3.14.1, ecto_sql 3.14.0, xqlite 0.11.0 (mix.lock-verified); postgrex
not vendored — its behavior derived from vendored ecto_sql source
where cited. Step-0: behaviour-surface byte movement since `80257e4`
= xqlite_ecto3.ex + connection.ex only (diffs read in full);
migration.ex correction on record (helpers only, no behaviour — the
Migration callbacks live in xqlite_ecto3.ex). Gate: all load-bearing
probes re-driven by the orchestrator (p11/p07/p08/p04/p03/p13 —
every finding + the seed-8 race reproduce); fixes BY THE
ORCHESTRATOR; stash-RED PREDICTED 9 — got exactly 9 by identity
(167/176 stashed → 176/176 restored, which also verified the
Repo-level refusal surfaces as DBConnection.ConnectionError).
Gate honesty note: the first full verify came back RED — a
SEVENTH-file unit pin (adapter_callbacks_test) still froze
bool_decode's old error-tuple shape, outside the predicted set;
flipped to pin the contract's `:error` (same
pin-of-the-bug pattern as the connection_test nil pin), green
re-verify on the final tree before commit.

- **F-B1-6 (S1, CONFIRMED, FIXED, RED→green).** `bool_decode/1`
  returned `{:error, map}` where Ecto's loader contract is
  `{:ok, v} | :error` — `Ecto.Type.process_loaders/3` has no
  `{:error, _}` clause (source-cited), so ANY stored value outside
  0/1/NULL under a `:boolean` field (legacy writers, raw-SQL
  backfills — column types are advisory in SQLite) crashed
  `Repo.all` with a FunctionClauseError. The Run-39 decimal loader
  is the in-file control showing the owed typed ArgumentError;
  `bool_decode` was the lone outlier among the nine decode helpers.
  Fixed to `:error`; pinned in the roundtrip matrix (stored 2 and
  'true').
- **F-B1-7 (S1, CONFIRMED, FIXED, RED→green; absorbs and CLOSES
  [F-B5-1], graded up from its S3).** With the SHIPPED default
  `rich_fk_diagnostics: false`, `to_constraints/2` emitted
  `[foreign_key: nil]`: a declared `foreign_key_constraint/3` never
  matched — `Ecto.ConstraintError` rendering `* nil` and advising
  the very call the user already made — and `match: :suffix` /
  `:prefix` / regex crashed with FunctionClauseError inside
  `String.ends_with?/starts_with?`/`Regex.match?` (six changeset
  spellings probed). Reference adapters (postgres/myxql/tds, from
  vendored source) emit `[]` when they cannot name a constraint —
  ecto_sql then re-raises the adapter's structured error
  (`subtype: :constraint_foreign_key`, full details). Why twenty-one
  prior runs missed it: BOTH suite repos set
  `rich_fk_diagnostics: true` (test_helper), and connection_test
  pinned the nil shape in isolation without its consequence. Fixed
  to `[]`; [F-B5-1]'s synthesize-the-name option ruled OUT (the
  generic FK error does not name the violated field). New
  `fk_constraint_default_config_test.exs` boots its own
  plain-config repo (structured-error + match: :suffix pins); the
  unit pin flipped.
- **F-B1-8 (S2, CONFIRMED, FIXED, RED→green).** URL `:database` was
  never percent-decoded — Ecto's own `Repo.Supervisor.parse_url/1`
  decodes every component — so `sqlite:///var/lib/my%20app/db.sqlite`
  opened AND silently created a file literally named `my%20app`
  (probed against a seeded real file: `{:error, :no_such_table}`,
  both files on disk after). Percent-encoding is the only
  expressible spelling (URI.new rejects a literal space), and
  URI.new has already validated escapes so `URI.decode/1` cannot
  raise. Fixed at `extract_database/1`; second leg: the parser
  accepted `busy_timeout` past int32 max that connect then refuses —
  now `:int32_ms` with a structured `:out_of_range`. Both pinned in
  url_test.
- **F-B1-9 (S3, CONFIRMED, FILED — merged into
  [F-B1-menu-connect-error-details]).** A STRING-valued config
  (`journal_mode: "wal"`, the env-var spelling) hits `wrap/1`'s
  `{tag, binary}` clause — built for NIF reasons where the binary IS
  the SQLite message — so the operator's only diagnostic reads
  `failed to connect: ** (XqliteEcto3.Error) wal`, naming neither
  key nor problem (32 config shapes probed; `type` stays correct;
  atom values render fine). The message fix rides the menu's
  designed-shape decision (validators emitting {tag, key, value}, or
  guarding the binary clause to NIF tags) — deliberately not a
  gate-side patch on the audited wrap surface.
- **F-B1-10 (S3, CONFIRMED, FIXED).** `Repo.explain(:all, q,
  type: :analyze)` (the obvious guess, given explain_analyze/3
  exists) raised FunctionClauseError naming the private
  `build_explain_query/2`. Now a named ArgumentError listing
  `:query_plan`/`:instructions` and pointing at
  `XqliteEcto3.explain_analyze/3`; unit pin committed.
- **SEED-8 ADJUDICATED — REFUSE, implemented at the gate
  ([F-B8-12-handoff] CLOSED).** Measured (orchestrator re-driven):
  a top-level `Repo.transaction(fun, mode: :savepoint)` is
  byte-for-byte `:deferred` (independent-connection lock instrument:
  lock at first write, not at entry, matching the :deferred control
  and not the :immediate one); under a verified-concurrent
  two-writer race the deferred snapshot's write fails INSTANTLY —
  SQLite does not consult the busy handler for a stale-snapshot
  lock upgrade, so `busy_timeout` buys nothing — and one update is
  LOST where the `:immediate` default serializes both (final value
  2 vs 1, `b1_cover_r42/p03`). Sandbox NOT affected, two ways
  (sandbox.ex:659 begins the outer transaction `mode: :transaction`;
  runtime lock held across sandboxed savepoint begins, released at
  checkin — leak-free control p10). Disposition REFUSE over
  document (silent data-affecting footgun with no top-level upside)
  and over translate (would need a savepoint-owns-an-implicit-BEGIN
  state flag for a construct with no legitimate top-level use):
  `handle_begin/2`'s savepoint arm is nested-only now — with no
  enclosing transaction it disconnects with a ConnectionError
  naming the rule (the same contract-forced price the bogus-mode
  arm always paid; handle_begin has no `{:error, _}` return). The
  arm's now-redundant flag-set dropped (guaranteed by the clause
  pattern). Test churn handled honestly: Run-32's three top-level
  PoolRepo pins REWORKED to the refusal pin (their nested coverage
  stands in the driver lifecycle tests + the sandbox suite; the
  OCR×savepoint guard mechanism stays pinned by the plain-BEGIN
  atomicity tests), Run-41's recovery pin reworked to the nested
  spelling (green-by-nature, recorded as such). Vendored-suite
  sweep: the only savepoint-mode site is alter.exs:60 — single-op
  `mode:` (inert per Run 33's adjudication, never reaches
  handle_begin) and excluded anyway; B2's share = no exclusion
  change. CHANGELOG (Changed) + README (config paragraph +
  known-limitations bullet, incl. correcting the insert_all advice
  the refusal invalidated) + STE drafts. Revert = drop the
  `{:savepoint, _}` refusal clause.
- **CLEAN (controls named):** the guard's three call sites
  (execute/declare/fetch) all contract-permit both `:error` and
  `:disconnect` (db_connection source cites; closed-conn + OCR
  probes); the keyword sync's ERROR branch clean across all ten
  inducible transaction-control failures (cached flag agrees with
  handle_status every time, six success controls; the un-inducible
  COMMIT-fails-AND-ends-transaction class is covered by the guard,
  which runs first on that same branch); `handle_begin(:transaction)`
  stale-counter divergence unreachable (every zeroing path
  enumerated; a negative counter needs a successful RELEASE of an
  impossible random-prefix name); `:disconnect_and_retry` never
  produced and would `bad_return!` through `handle_common_result`
  (source); the 14-callback return census legal on happy + error
  paths with exception payloads everywhere; `wrap/1` total across
  all 32 connect-config shapes incl. the five new refusal atoms;
  `open_database/2` single-caller post-validation (catch-all
  deletion safe); URL↔validator round-trips green on all nine
  pragma keys at enum values + integer bounds (URL's narrower
  journal_mode enum is self-documented, noted not filed); RawConn
  cannot reach the EncodeError re-prepare path; `leading_keyword/1`
  doors still shut across 11 spellings (the Run-33 vertical-tab
  adjudication now resolves stronger: SQLite rejects the statement
  itself); sandbox checkin releases the write lock (plain-pool
  control). Seeds 1-3 verified as consumed per the Run-41 record
  (@pool_opts source-confirmed).
- Dryness: two S1 + one S2 + two S3 — **B1 stays 0 of 2, NOT DRY**;
  TWENTY-TWO straight finding runs. Re-wets ALSO on:
  loaders/dumpers lists, `to_constraints/2` clauses, the URL
  extract/coerce path, `build_explain_query/2`, the handle_begin
  savepoint arms. Completeness critic (next B1 pass):
  [F-B1-11-docs] (unnamed CHECK constraints — expression-as-name,
  filed); `unique_index_name/1` / `not_null_column/1` `-> nil`
  catch-alls (probe expression indexes, WITHOUT ROWID composite
  PKs, empty xqlite parses — the F-B1-7 mechanism if reachable);
  `query_many/4` raising where the callback spec declares a tuple;
  dumper catch-alls reached without the Ecto type ahead
  (fragments, insert_all placeholders); handle_fetch mid-stream
  `{:disconnect, _}` × `stream_deallocate` after-fun against a dead
  pool_ref (stream handle finalization); `handle_status/2`
  `{:error, state}` on a NIF read failure — driver means
  read-failed, DBConnection reads transaction-aborted (no consumer
  divergence found, unpinned).

## Run 43 — 2026-09-01 — lap 6, batch 3: B6 solo (translation cover over the Runs-35-42 churn)

Single Opus reviewer at `32e9841`; ecto 3.14.1, ecto_sql 3.14.0,
db_connection 2.10.2, xqlite 0.11.0 (hex) probe-verified; SQLite
3.53.2 probe-confirmed. Toolchain note: mise had bumped to Elixir
1.20.4/OTP 29 since the pause, orphaning hex — reinstalled, deps
refetched, verify green pre-run. Gate: all eight probes re-driven by
the orchestrator (p01-p08, rc 0 each, decisive outputs read
line-by-line); fixes BY THE ORCHESTRATOR; stash-RED PREDICTED 8 —
first run showed 9, the ninth being an orchestrator test-typo (the
float emission control asserted alias `o0` from the probe's table
name where the pin table gives `t0`; fixed in the pin, not the lib),
corrected run exactly 8 by identity → 45/45 green restored.

- **F-B6-7 (S1, CONFIRMED, FIXED, RED→green).** `type(expr,
  :decimal)` emitted `CAST(… AS REAL)` — float64 — so the query side
  forced the exact rounding Runs 31/34 eliminated from DDL: an
  integer-exact decimal past 2^53 came back a DIFFERENT number from
  `select: type(o.amount, :decimal)` (…567 → …568, probed live), and
  an equality filter `where: o.amount == type(^dec, :decimal)`
  matched NO rows for a row that exists (p07 legs A/B/D; leg E raw
  ground truth `int = CAST(int AS REAL)` → 0). Reachability
  ordinary: `type/2` is Ecto's sanctioned expression-typing API,
  `type(sum(x), :decimal)` is in Ecto's own shared suite, and the
  README recommends the construct. `Repo.aggregate/3` untagged —
  unaffected (leg C control). FIX: split the shared clause —
  `:decimal` now casts NUMERIC (the affinity `column_type(:decimal,
  _)` already declares), `:float` keeps REAL (leg I proved the
  clause was shared). Fix validated pre-implementation by the
  reviewer (legs H/J/K: nine value shapes REAL-vs-NUMERIC, live
  loader round-trip, Ecto's shared decimal-aggregation test
  Decimal.equal?-green). Pins: emission both ways + live tagged
  select round-trip + live tagged WHERE (typed_decimal_cast_test,
  new file).
- **F-B6-8 (S2, CONFIRMED, FIXED, RED→green).** The Run-34 affinity
  rewrite's rule-5 residue: every text/blob-meaning DB-specific
  spelling with no SQLite type marker — :jsonb :json :xml :inet
  :cidr :macaddr :tsvector :bytea — landed NUMERIC affinity, which
  rewrites numeric-looking text on write: `"007"` stored as integer
  7, leading zeros destroyed silently, then a DELAYED ArgumentError
  at load time (p02 30-spelling sweep + p03 live end-to-end).
  Reachability plausible by Run 34's own F-B6-4 argument (Postgres
  passthrough spellings carried by ported schemas); the 95% case
  `:jsonb` + `:map` field is SAFE (JSON text always starts `{`/`[`
  — p03 legs A/F controls) — the bite is `:string`/`:binary` fields
  over such columns. FIX: a bounded semantic alias table ahead of
  the unchanged TOTAL affinity rule (seven spellings → TEXT, :bytea
  → BLOB) — NOT more affinity enumeration (the original failure
  mode); :money/:bit/:varbit/:enum/:year/:interval/:point stay on
  the affinity rule (genuinely ambiguous intent) with the residual
  named in a README Known-limitations bullet + STE mirror (same
  gate). :citext dropped from the reviewer's alias list — its TEXT
  marker already lands TEXT affinity (p02 control). Pins: alias
  mapping unit cases + live "007" boundary — jsonb column stores
  text intact, money column still coerces (passthrough_affinity_
  test, new file); the old `:jsonb == "JSONB"` passthrough pin
  reworked (pin-of-the-bug).
- **F-B6-10 (S3, CONFIRMED, FIXED).** The passthrough rendered
  atoms verbatim into DDL: `:"text, oops INTEGER"` spliced a second
  column definition into CREATE TABLE (p02 leg D — the F-B6-3
  injection pattern in the one identifier position Run 2 never
  covered; author-written migration code, hence S3). FIX: the
  spelling must fit SQLite's own typename grammar — identifier
  words + optional (N)/(N,M) suffix — else UnsupportedTypeError
  carrying the offending atom. Incidental closure: non-ASCII
  spellings (Run-34 critic item, String.upcase Unicode vs SQLite
  ASCII divergence) are now refused by the same grammar. Pins:
  splice refusal + quotes/semicolon/empty refusals + multi-word and
  sized spellings pass (`:"native character"`, `:"varchar(255)"`,
  `:"numeric(10,2)"`).
- **F-B6-9 (S3, CONFIRMED, FILED).** A keyword-shaped spelling
  (`add :x, :set` — the MySQL type) fits the typename grammar,
  renders bare, and fails the migration as raw SqliteFailure
  ("near SET") instead of UnsupportedTypeError (p02 leg C). Loud,
  no data risk; a structured refusal needs a keyword-list decision
  (SQLite accepts many non-reserved keywords in type position;
  quoting instead would flip the loud failure into a silent
  NUMERIC-affinity column — rejected on principle). BACKLOG entry
  filed.
- **Step-0 corrections on record:** the range held 28 commits (27
  claimed in the brief); migration.ex had ZERO in-range bytes (the
  brief listed it as a churn target — the 764cab0/059dec bytes
  live in data_type.ex/xqlite_ecto3.ex); data_type.ex's only churn
  was encode_default (the :json_library knob drop + the F-B6-5
  column normalization residue 059d9ec — closed at HEAD,
  re-anchored GREEN p06 A/B across all renderers × both reasons).
- **Clean census (controls named):** seed 2 — references(type:
  :float8) + the full float family: 18 FK columns across
  create-table AND alter-add match column_type/2 exactly, live
  truncation control exact through both paths, pragma_foreign_key_
  list 18/18, modify-references unreachable by construction
  (ArgumentError before rendering), Ecto default reference type
  INTEGER (p04). Seed 3 — the F-B6-6 boundary sharpened across 20
  fragment shapes: 11 row-count-dependent (bare/parenthesized
  CURRENT_*, (1+1), EVERY function call incl. datetime/random/
  unixepoch/strftime/json), 9 true constants always fine, ZERO
  unconditional failures, CREATE TABLE never restricted; README
  workaround re-proven live (modify on populated table rebuilds);
  adapter JSON map/list defaults constant-safe on populated tables
  (p05 leg G — a user-written `fragment("(json('…'))")` would NOT
  be, the adapter's parenthesized-literal rendering is what keeps
  it safe). Seed 4 — UnsupportedDefaultError total (4 renderers ×
  both reasons, column always string, cause carries the encoder
  exception on :unencodable); UnsupportedTypeError.type carries the
  raw term on all 5 paths; Error.Constraint shapes uniform for B6's
  purposes — two observations handed to B5's court (CHECK: table
  nil + constraint_name carries the expression; unique: index_name
  nil while unique_index_names populated). Seed 5 — escape_string/
  limit/quote_entity byte-unchanged (range diff + git log -S each),
  anchor-only held. Churn — build_explain_query catch-all
  re-anchored through the ordinary Repo.explain door (5 unsupported
  types ArgumentError, both supported prefixes byte-exact);
  push/pull refusal renaming re-anchored (Ecto.QueryError both,
  set:/inc: still emit and run; the refusal carries no structured
  field — message-text only, noted); values/2 $N::TYPE placeholders
  live-correct standalone AND joined (the known grammar-accident
  naming). BLOBs immune to NUMERIC/INTEGER affinity across all 24
  mutating spellings (p02 leg B).
- Dryness: an S1 + an S2 + two S3 — **B6 stays 0 of 2, NOT DRY**;
  TWENTY-THREE straight finding runs. Re-wet triggers GROW: the
  Tagged :decimal/:float CAST clauses (connection.ex) + the
  semantic alias clauses and @typename_grammar (data_type.ex), plus
  the standing list. Completeness critic (next B6 pass): the rest
  of the Tagged clause family — the :binary clause's CAST-vs-bare
  TEXT/BLOB decision against real stored values, interacting with
  F-B6-8's columns; type/2 in the remaining query positions
  (having/order_by/group_by/on_conflict/insert_all placeholders/
  select_merge — same clause, different receiving loaders, only
  select/where proven); the CAST AS NUMERIC neighborhood post-fix
  (TEXT/BLOB-affinity columns, sum() over mixed storage classes —
  the fix-creates-the-next-finding pattern has fired three times);
  values/2 aliasing under shared-type fields and missing row-map
  keys; the json_default renderer split (escape_string vs
  quote_string on adversarial content — byte-comparison never
  done).


## Run 44 — 2026-09-01 — lap 6, batch 4: B5 solo (constraint mapping over the Runs-36-43 churn)

Single Opus reviewer at `3bfa1c9`; ecto 3.14.1, ecto_sql 3.14.0,
db_connection 2.10.2, xqlite 0.11.0 (hex) live-verified; SQLite
3.53.2 probe-confirmed. Gate: ALL FOURTEEN probes re-driven by the
orchestrator (p01-p14 — rc matched the manifest on each: eleven 0s +
the three intended REDs p03/p13/p14 at rc 1; decisive outputs read
line-by-line); fixes BY THE ORCHESTRATOR; stash-RED PREDICTED 8 —
observed exactly 8 by identity (7 in the four assert-flip files + the
vanish pin red in its own file; prediction honesty: that eighth was
predicted as a warnings-as-errors COMPILE abort on the pre-fix
private function, it actually surfaced as a runtime
UndefinedFunctionError — same pin, same cause, failure mode
mispredicted). The widened pre-prediction sweep caught a THIRD
not_null pin (error_paths_test:61) beyond the two the reviewer named
— the Run-42 seventh-file lesson executed. Post-fix 100/100 across
the six pin files.

- **F-B5-26 (S2, CONFIRMED, FIXED, RED→green).** The `[unique: nil]`
  shape Run 42 removed from the FK clause was alive on the
  unique/primary-key/check clauses, with a LIVE producer: an FTS5
  virtual table reports a duplicate rowid as
  SQLITE_CONSTRAINT_PRIMARYKEY with the bare message "constraint
  failed" — xqlite's parse has no arm for it, details arrive empty,
  and the mapping emitted `[unique: nil]`: FunctionClauseError deep
  in Ecto under match: :suffix/:prefix/regex, `* nil` advice under
  :exact (p13 RED, 4/4 ordinary-table control converts; p12 leg H
  swept eight further shapes — fts5 is the only all-nil producer).
  Grade held at S2 vs Run 42's S1 on the same mechanism: the trigger
  needs a virtual table (plausible — SQLite's documented
  rowid-aligned FTS5 pattern — not ordinary). FIX: no nil name ever
  leaves `to_constraints/2` — a shared `named_or_empty/2` on the
  PK, autoindex-unique, fallback-unique, and check emissions; empty
  re-raises the structured error (the F-B1-7 shape). The xqlite
  half (a parse arm for bare "constraint failed") rides [F-B5-31]'s
  queue note. Pins: nil-totality unit sweep (three subtypes,
  detail-less structs → []) + the live FTS5 duplicate-rowid RED→
  green (constraints_test).
- **F-B5-27 (S2, CONFIRMED, FIXED, RED→green).** The rich-FK replay
  ran `PRAGMA foreign_key_check` with no table argument — a
  DATABASE-WIDE scan — so any pre-existing orphan anywhere was
  reported as a violation of the failing statement: sorted first,
  Ecto's matcher raised on the stranger before ever reaching the
  declared constraint (p03 RED: `[foreign_key:
  "audit_log_owner_id_fkey", foreign_key: "fk_child_parent_id_fkey"]`
  for a violation of the latter; by-the-book
  foreign_key_constraint(:parent_id) raised ConstraintError naming
  the stranger). Reachability CORRECTED on record: raw xqlite
  connections enforce FK by default (`XqliteNIF.open` sets it), but
  the adapter's own supported `foreign_keys: false` repo option
  writes orphans, and SQLite's own default is OFF for every other
  tool (p14 RED, three legs). One bad row anywhere permanently broke
  FK conversion for the whole database under rich diagnostics. FIX:
  baseline diff — the replay scans once BEFORE the replayed
  statement (inside the savepoint, after defer), again after, and
  reports only rows absent from the baseline (raw check-row
  identity; a statement re-breaking an already-broken row folds into
  the baseline — the row was broken either way, edge recorded in
  the moduledoc). The update-hook tracking variant was REJECTED
  (clobbers the connection's single update-hook slot — user-visible
  surface). Scope honesty: the fix covers the REPLAY path only;
  `wrap_at_commit/2` has no pre-transaction snapshot to diff — the
  commit-path residue is documented in the moduledoc and FILED
  [F-B5-27-commit] (probe-first: the commit path was never probed
  end-to-end, critic item 3). Pin: plant an orphan with
  `PRAGMA foreign_keys = 0` on the same conn, violate elsewhere,
  exactly one violation naming the failing table
  (fk_diagnostics_test).
- **F-B5-28 (S2, CONFIRMED, FIXED, RED→green).** `[not_null:
  "table.column"]` pointed users at `not_null_constraint/3` — a
  function Ecto does not have (source-cited: ConstraintError's
  advice is built as "call #{type}_constraint/3"), so the only
  outcome was an unmatchable Ecto.ConstraintError AND the structured
  error (table+columns intact) was discarded. postgres/myxql/tds all
  emit nothing for NOT NULL (source-verified). FIX: the clause
  dropped, falls to `[]` — the structured error reaches the caller;
  CHANGELOG Changed entry, README + guide + STE note
  (validate_required/2 is the Ecto-side answer). THREE
  pin-of-the-bug flips (connection_test [not_null:] pin,
  constraints_test + error_paths_test ConstraintError pins → the
  structured shape; the sweep-found third was outside the reviewer's
  list).
- **F-B5-29 (S3, CONFIRMED, FIXED).** The replay materialized one
  FkViolation struct per violating row, unbounded (p08 leg C:
  100k children → 100k structs, 187 ms, the whole list into
  logs/telemetry). FIX: capped at 24 (mirrors the unique lookup's
  candidate cap), `fk_diagnostics: {:truncated, total}` past it —
  the typespec + docs widened; `diag_tag` gains :truncated for
  telemetry. Pin: 30-child delete → exactly 24 violations +
  `{:truncated, 30}` (fk_diagnostics_test).
- **F-B5-30 (S3, CONFIRMED, docs-FIXED).** The migration guide's
  "changeset mapping works the same way with one deliberate
  difference" undersold two more: under the SHIPPED default no FK
  declaration converts (foreign_key_constraint/3 AND
  no_assoc_constraint/3 raise the structured error — p02 leg C 5/5,
  p08 leg B; correct per F-B1-7, undocumented), and NOT NULL now
  (F-B5-28) raises structured. Guide rewritten to three named
  differences; README rich-FK section gains no_assoc_constraint/3
  (converts under rich — p08 leg A) + the without-flag sentence;
  STE mirrors same gate. Pin: a no_assoc arm in
  fk_constraint_default_config_test (raises structured under the
  default; the converts-under-rich half stays probe-proven, p08 A).
- **F-B5-31 (S3, CONFIRMED, FILED).** `:constraint_rowid` maps to
  nothing though its message is fully parseable ("UNIQUE constraint
  failed: t.rowid") — xqlite's parse has no arm for the extended
  code, details arrive empty, `[]` (the SAFE half of the F-B5-26
  family). Split-court entry filed: xqlite parse arm (queued for the
  release AFTER the frozen 0.11.1) + adapter mapping. The remaining
  six unmapped codes verified correctly `[]` (p04).
- **F-B5-32 (S3, CONFIRMED, FIXED).** `PRAGMA index_info` on a
  vanished index returns EMPTY, not an error, so an index dropped
  between the two pragma reads was silently subtracted from the
  candidate count — the emission rule keys on that count, so a
  concurrent index rebuild flipped the emitted name ~50/50 (p09:
  verified-concurrent race, 1500 violations × 1779-2628 DDL cycles,
  both runs ~50/50) and a stable changeset raised intermittently.
  FIX: zero index_info rows for a name index_list just returned →
  halt `{:unavailable, {:index_vanished, name}}` → derived-name
  degrade (an indexed expression yields rows with nil column names,
  never zero rows — no collision). `budgeted_match/4` promoted to
  @doc false public (the within_budget?/lookup_budget_ms
  testability precedent). F-B5-13's planned promotion is SUPERSEDED
  by this fix; its residual (names reflect schema as of the read)
  stays moduledoc prose. Pin: real index → match, DROP INDEX →
  index_vanished halt (unique_index_names_test, deterministic).
- **Filed sweep (all open B5 items at HEAD):** F-B5-1 stays closed
  (p02: [] + 5/5 structured, zero crashes); F-B5-4/25 unchanged,
  unprobed per the cross-schema directive; F-B5-5 reproduces (p11:
  the "a, b" column-name split matches the wrong real index);
  F-B5-7 reproduces WIDENED (both pragma reads collapse empty —
  the index_info half now FIXED as F-B5-32); F-B5-8-residual
  reproduces (1202 ms rollback-journal block vs 981 µs control; WAL
  immune); F-B5-10-structural/11 reproduce (creation order decides;
  expression form still table-nil); F-B5-14-fork reproduces
  (budgets unchanged, no repo option); F-B5-15/22 reproduce with a
  SHARPER consequence — the execute and stream paths emit DIFFERENT
  names for one violation (custom vs derived, p11) — BACKLOG entry
  sharpened (any remedy must equalize the name, not the status);
  F-B5-16 mechanism + ceiling now proven DETERMINISTICALLY (p10:
  isolated replay blocks a full busy_timeout 1502/1500 ms and
  degrades busy; the unique lookup under the same lock: 1 ms; the
  two-full-waits sum did not recur over 12 staggered iterations) —
  BACKLOG text downgraded from the one-off Run-27 sum to the proven
  ceiling; F-B5-17 reproduces (ordering byte-stable through the
  guard churn; live: in-txn ROLLBACK conversion still yields
  {:error, :rollback} + disconnect at the point of damage).
- **Clean census (controls named):** seed 8 (the e166c5f re-wet) —
  rich ON emits the full named tuple + all five match modes
  convert, rich OFF `[]` + 5/5 structured no-crash, two-FK
  statement emits both/declares both, replay interplay green (p02);
  seed 1 CLOSED — the budget halt is now DETERMINISTIC (p05: 10/10
  `{:lookup_budget_exceeded, 3..4}` at budget 1 ms vs 10/10 :ok at
  5000 ms, single-variable control, twice; structural insight
  recorded: budget = busy_timeout with elapsed <= budget means a
  single blocked-then-successful read can never exceed it — a
  contention halt needs two blocked reads + a third candidate);
  seed 3 CLEAN — enrichment on a rolled-back-to-autocommit
  connection leaves no residue, the guard is not fooled (the
  replay's savepoint balances), and BOTH steering hypotheses
  refuted (a trigger RAISE fires before the FK check; UNIQUE
  outranks FK on a double violation) (p07); seed 4 CLEAN — the
  emission rule identical across plain/multi-row/UPDATE/
  INSERT-SELECT; insert_all/update_all re-raise structured
  (reference-adapter behavior); ON CONFLICT targets match by
  column, custom index names irrelevant (p06); seed 6 CLEAN —
  Ecto.Multi carries the same names as bare Repo calls, rollback
  verified, repo usable (p06); seed 7 ADJUDICATED — CHECK
  table-nil + expression-as-name is FAITHFUL to SQLite's message
  (check_constraint/3 has no derived default name at all — raises
  ArgumentError without name:; passing the expression verbatim
  converts) → the docs half IS [F-B1-11-docs] (stays open, B1/docs
  court, enum_check/array_check half still owed); unique
  index_name-nil-vs-unique_index_names-populated is the designed
  split, moduledoc states it, no change owed (p04); driver
  re-wetters — wrap_execute_error gained only put_statement
  (cancel-token position byte-stable: git log -S empty for
  spawn_canceller/step_to_completion; ordering vs the guard
  unchanged at driver.ex:548-549), the connect chain's
  foreign_keys ordering intact and re-proven LIVE (p01: 200/200
  structured over 5 members, 0 orphans, witnessed reconnect cycle,
  40/40 after, foreign_keys=1 across 20 checkouts); error.ex churn
  = the details-union widening only, statement field rides the
  constraint path correctly (plain unique, FK-with-replay,
  busy-degraded FK all carry the failing SQL; the stream-path nil
  is [F-X1-7], X1's court, cross-referenced not re-filed) (p12
  leg S, p10 leg E). Cross-court incidental (not B5's):
  two-connection journal_mode=wal connect race on a fresh file at
  pool_size 2 — B3/B8's court, test_helper already documents the
  dodge.
- Dryness: three S2 + four S3 — **B5 stays 0 of 2, NOT DRY**;
  TWENTY-FOUR straight finding runs. Re-wets ADD: `named_or_empty/2`
  and the nil-totality contract, `collect_violations/2` + the
  baseline diff + `cap_rows/2`, `budgeted_match/4`'s empty-info
  clause, the guide's three-differences paragraph. Completeness
  critic (next B5 pass): the unmapped-extended-code surface
  enumerated (13 subtypes × message shapes, virtual-table modules
  as generators — the nil class bit twice in three runs);
  fix-creates-the-next-finding on the baseline diff (its cost, a
  failing baseline scan's status, rowid reuse in the diff key —
  probe before trusting); the handle_commit FK path end-to-end
  (inherits the contamination residue + the cap; raw "COMMIT" via
  Repo.query replays the string "COMMIT" — worth its own look);
  insert_all + on_conflict against partial/expression unique
  indexes (conflict_target renders columns alone, SQLite needs the
  WHERE clause for partial); the stream path's different-name half
  (F-B5-15's hard half); the status shapes as a machine-readable
  contract (seven now exist across two fields, no closed-set test —
  F-B5-7's want since Run 14); Ecto.Multi × the disconnect guard
  (ON CONFLICT ROLLBACK inside a Multi step unmeasured).


## Run 45 — 2026-09-01 — lap 6, batch 5: B7 solo (migration ergonomics over the Run-43 churn)

Single Opus reviewer at `d7fbf80`; ecto 3.14.1, ecto_sql 3.14.0,
db_connection 2.10.2, xqlite 0.11.0 (hex) live-verified; SQLite
3.53.2 probe-confirmed. Gate: ALL THIRTEEN probes re-driven by the
orchestrator (rc 0 each, decisive outputs read); the five finding
probes re-run POST-fix — every flip for the designed reason (refusals
fire pre-flight with rows intact, six false refusals now `:rebuilt`,
paren defaults survive, carried types quote); fixes BY THE
ORCHESTRATOR; stash-RED PREDICTED 6 — first run 5 (the fragment-
default pin exercised the WRONG DOOR: an alter with only an :add
never reaches the rebuild, `requires_rebuild?` is :modify-only; a
same-block :modify added to the pin), corrected run exactly 6 by
identity. Fix-red sweep of the standing suite BEFORE stash-RED: the
2000-run law property was taught the refusal branch (a refused
rebuild must leave the table byte-identical — the law's own second
property, now asserted inside the first on random shapes); 128/128
green including both properties. Gate honesty: the FULL verify then
caught one more file the name-pattern sweep missed
(table_rebuild_test's batching fixture — modify :a, :integer over
stored TEXT 'x', which the old rebuild silently rewrote to 0 with
NOTHING asserting a's value; the new guard refused it). The fixture
now seeds an exact-converting '7' AND asserts the converted value —
the guard's first live save, and the sweep lesson upgraded: sweep by
BEHAVIOR (rg the touched change-shapes over all of test/), not by
file-name pattern. Step-0: the rebuild engine
byte-identical since Run 36 (rebuild_verification.ex empty diff;
xqlite_ecto3.ex five hunks all outside lines 598-2050; migration.ex
zero bytes; every Run-36 re-wet trigger byte-stable by git log -S) —
all findings come from the one on-axis churn commit (0c09d01's
data_type.ex reaching the rebuild through the shared column_type/2)
plus three never-swept code paths.

- **F-B7-47 (S1, CONFIRMED, FIXED, RED→green).** A `modify` to a
  numeric-affinity type on a populated column silently REWROTE
  stored values through the rebuild's INSERT…SELECT — the one door
  the parameter-binding guards never see: `modify :code, :decimal`
  turned TEXT `'12345678901234567890'` into REAL …7000 (the exact
  value insert_all REFUSES with DecimalPrecisionError — the
  moduledoc's "rather than silently round" promise broken), `'007'`
  into 7, `' 42 '` into 42, all silent, migration reports success,
  rollback does NOT restore (p13 leg A, p03 leg C, p11 leg F).
  Reachability ordinary (`modify :code, :decimal` on a :string
  column is the textbook widen-this-column migration), S0 avoided
  only by the opt-in flag. FIX: `refuse_affinity_rewrites_on_
  populated!` pre-flight — per-modified-column, when the stored
  declared affinity differs from the re-rendered one, count the
  stored values the copy would rewrite and refuse (ArgumentError in
  the engine's refusal family, naming column + both affinities +
  execute/1) before any destructive step. The count is per-value so
  an all-clean column migrates freely (the green control: '42'/'1.5'
  → DECIMAL converts exactly and proceeds).
- **F-B7-49 (S2, CONFIRMED, FIXED, RED→green).** Run 43's alias
  table turned `modify :payload, :jsonb, null: false` on a
  pre-Run-43 JSONB column (NUMERIC affinity) into an affinity flip
  to TEXT that stringified every numeric storage class — ORDER BY
  and range WHEREs changed results silently and permanently, a
  rollback does not undo it, and the post-check is blind by
  construction (both halves share column_type/2 — the F-B7-46
  class realized on the churn's own surface) (p02 legs A-E, p11
  leg G; :money single-variable control). SAME FIX, the to-TEXT
  direction: any numeric storage class present → refuse. GATE
  ADJUDICATION on record — the reviewer's two fix proposals
  disagreed on one cell (valuewise, '42' text→integer converts
  "exactly"; affinity-wise every flip refuses): resolved
  ASYMMETRICALLY by each finding's harm — toward numeric affinities
  refuse BYTE LOSS only (the requested numeric semantics are the
  migration's point), toward TEXT refuse any numeric storage class
  (the flip is what the finding shows users do not intend). A
  deliberate int-column → :string conversion now needs execute/1
  first — loud, documented, conservative. README's "Two
  type-rendering details" paragraph → three, claim narrowed + the
  refusal documented; STE mirrored.
- **F-B7-48 (S2, CONFIRMED, FIXED, RED→green).** A column NAMED
  `check` (or collate/deferrable/on — six spellings across all
  three identifier quote forms) made its table PERMANENTLY
  un-rebuildable with a false explanation: `blanked/1` deliberately
  preserves quoted identifiers for the name-hungry scans, and the
  four `unpreservable_constraint/1` keyword scans read the same
  product, so `add :check, :boolean` — ordinary Ecto — read as a
  CHECK constraint (p06 half 1; plainly-named control rebuilds).
  FIX: the blanking split — `without_string_literals_or_names/1`
  empties the three quoted-identifier forms too; the construct
  scans and `autoincrement_declared?/1` (engine + verifier, shared)
  moved onto it; the name-hungry scans keep the name-preserving
  product. Real-CHECK/COLLATE/DEFERRABLE refusals unchanged
  (p06 half 2 controls).
- **F-B7-50 (S3, CONFIRMED, FIXED, RED→green).** The carried stored
  type text spliced UNQUOTED into the transient CREATE — four legal
  declarations (`"foo-bar"`, `"select"`, `"a.b"`, embedded-quote)
  bricked every rebuild with a syntax error blaming nothing
  actionable; rows always intact, first destructive statement
  (p04 4/15 red). FIX: `carried_type/1` — verbatim only when the
  text passes `DataType.bare_typename?/1` (grammar + NO SQLite
  keyword) or is already one complete quoted token; otherwise
  `quote_name/1`. The stored text is STABLE across rebuilds
  (pragma strips identifier quotes on read-back — the pin's own
  first expectation was wrong and corrected). The eleven
  passing shapes stay bare (`VARCHAR (255)`, `NUMERIC(10, 2)`
  included — the grammar tolerates their whitespace).
  **CLOSES [F-B6-9]:** the keyword-list decision it waited on is
  made — the full lang_keywords.html list in DataType, shared by
  the passthrough (REFUSES `add :x, :set` with
  UnsupportedTypeError — a migration atom is a request) and the
  carried-type emission (QUOTES — an existing column's spelling is
  data). Backlog entry moved to Closed.
- **F-B7-51 (S3, CONFIRMED, FIXED, RED→green).** `balanced?/1`
  counted parentheses inside string literals, so three legal
  fragment defaults (`('a)b')` class) aborted a correct rebuild at
  the post-check with a library-bug-shaped error — while the PLAIN
  ALTER path accepted the identical option (p07 leg A, p08 control
  B: the default_spec "same option, same result, either way"
  contract broken). FIX: count over `without_string_literals/1`
  (same module, already handles all six token kinds). Pathological
  slicings still fail LOUD (an unterminated literal's parens count
  — the never-silent property holds).
- **F-B7-52 (S3, CONFIRMED, docs-FIXED).** A trigger depending on a
  removed column WITHOUT naming it (`SELECT *`, late-bound column
  lists) passes the word-boundary pre-flight and every later write
  fails — but SQLite's own `ALTER TABLE DROP COLUMN` accepts the
  identical shape and bricks identically, and refuses the named
  shape identically (p07 leg C, p08 control A). ADJUDICATED
  docs-only on the parity control (the Run-36 fts5 precedent): the
  over-approximating refusal (any `*` in a trigger) rejected.
  README + STE line landed ("name columns explicitly in trigger
  bodies"); parity CANARY pinned (rebuild accepts + later write
  fails structurally — so a future tightening is a deliberate act,
  not an accident).
- **Filed sweep (p12 + p13 leg C):** F-B7-27 reproduces (doc line
  still Gate-3-owed); F-B7-46 reproduces unchanged (typeless→BLOB;
  its CLASS got the systematic sweep this run); F-B7-25-feature
  reproduces (clean refusal + guidance); F-B7-41-menu reproduces
  (14 ArgumentError sites + 1 RuntimeError; Run-36's 13 was a
  counting-method delta, engine byte-identical; NOT re-adjudicated
  — noted that F-B7-48's wrong-reason refusal argues for the menu);
  F-B6-6-menu reproduces (rebuild-batched add materializes ONE
  timestamp for all rows; NOT re-adjudicated). Run-28/36 fixes all
  hold (F-B7-29/30/31/32/36/42 — DESC+NULL key, fts5, checkout
  pinning 0/12, trigger-names-column, savepointed confirm,
  comment door over 640 generated cases).
- **Clean census (controls named):** the blanking PROPERTY (p05):
  640 generated CREATEs × 9 token kinds × 18 junk payloads, ground
  truth from SQLite itself — 320 refused = 320 real CHECKs exactly,
  0 false passes, 0 false refusals, 0 row damage; COLLATE/
  DEFERRABLE live-consequence legs close Run 36's seed 7 (NOCASE
  matches case-folded, DEFERRABLE moves the refusal to COMMIT;
  comment-interleaved spellings refuse; literal-only control
  rebuilds). carried_default 15/15 stored-DEFAULT forms
  byte-identical through a rebuild. Deterministic dance-window
  failures via the AUTHORIZER (p09 — deny :alter_table lands in
  the DROP→RENAME window; every landing: table present, 0
  transient, rows exact, defer reset, pool writable; the
  deny-:insert legs honestly recorded as blocked by Ecto's own
  bootstrap). Real cancel mid-dance 6/6 at 1-400 ms on 120k rows
  (Run-36 reachability bound honored). Sandbox × ownership ×
  confirm-savepoint 5 legs clean (checkin rolls the whole rebuild
  away; allow-ed and shared modes clean; mid-dance failure inside
  the sandbox clean). down/rollback structurally clean (change/0
  with from: reverses; without from: refuses; declared-type
  non-restoration recorded as F-B6-4's documented reach). Grammar
  refusal pre-destructive on both rebuild doors (p02 F/G). UNIQUE
  collisions during a value-rewriting copy fail LOUD and roll back
  byte-identically (p13 leg B — why F-B7-47's silent collapse
  where no constraint exists deserved S1). Cross-court incidental:
  the pool_size-5 fresh-file journal-mode connect race
  (B3/B8-court, already cross-referenced at Run 44).
- Dryness: an S1 + two S2 + three S3 — **B7 stays 0 of 2, NOT
  DRY**; TWENTY-FIVE straight finding runs. Re-wets ADD:
  `refuse_affinity_rewrites_on_populated!`/`rewritten_count/6`/
  `count_rows!`, `carried_type/1` + `@quoted_typename`,
  `DataType.bare_typename?/1` + `@sqlite_keywords` +
  `sqlite_affinity/1`, `without_string_literals_or_names/1`,
  `balanced?/1`'s blanked counting, the README three-details
  paragraph. Completeness critic (next B7 pass): the
  affinity-change class beyond `modify` (an `add` whose default
  materializes into existing rows through the copy — same shared
  blindness one door over); `column_type(:decimal, opts)` as a
  shared fact (the last unprobed branch — stored DECIMAL(10,2) vs
  mismatched precision options); the copy under a same-block NOT
  NULL with existing NULLs; widen the p05 property to COLLATE/
  DEFERRABLE (would have caught F-B7-48 mechanically); the
  fix-creates-the-next-finding sweep over the NEW pre-flight
  (affinity guard vs generated columns, vs WITHOUT ROWID, vs a
  modify whose column_type RAISES, count_rows! under contention);
  `refuse_incoming_actions_on_populated!`/`fetch_incoming_action_
  fks` under quoted/case-varied names; `restore_autoincrement_sql`
  beside a case-varied sibling sequence row; concurrent
  readers/writers during the dance at pool_size > 1 under WAL; the
  refusal-message-vs-reality audit (fourteen refusal flavors, no
  test asserts the REASON is right — F-B7-48 was one instance).


## Run 46 — 2026-09-01 — lap 6, batch 6: B3 + B9 paired cover (the hooks sweep + the boot race + the tokenizer settled)

Single Opus reviewer at `511b229`; ecto 3.14.1, ecto_sql 3.14.0,
db_connection 2.10.2, xqlite 0.11.0 (hex) live-verified; SQLite
3.53.2 probe-confirmed; telemetry flag ON under MIX_ENV=test
re-confirmed. Gate: ALL SEVENTEEN probes re-driven by the
orchestrator at rc matching the manifest — with a GATE PROCEDURE
ERROR recorded honestly: the first re-drive was launched
run_in_background and lib edits began before it finished, so
p10-p17 compiled a mid-edit tree (rc 1); repaired by stashing the
fixes and re-driving those eight on the pre-fix tree (all rc 0).
Lesson codified: NEVER edit lib/ while a re-drive is in flight —
re-drive fully first, or stash while editing. Fixes BY THE
ORCHESTRATOR; stash-RED PREDICTED 5 — observed exactly 5 by
identity; one unused-function warnings-as-errors catch post-pop
(set_writable_pragma lost its only caller to the retry wrapper —
deleted); 88/88 green.

- **F-B3-17 (S2, CONFIRMED, FIXED, RED→green).** A `hooks:`
  progress option outside the two shapes `progress_tag/1` and the
  NIF guard accept RAISED inside `connect/1` — and a raising
  connect crashes the connection process instead of returning the
  structured error DBConnection retries with backoff, so restart
  intensity blew and THE WHOLE REPO SUPERVISION TREE DIED within
  5-30 ms of boot, no error naming the config key (p02 27-value
  sweep: 5 raising shapes; p03/p04 end-to-end: tree dead, parent
  supervisor dead, controls alive). Reachability ordinary:
  `every_n: "500"` is what System.get_env returns in runtime.exs;
  the README's own hooks example is the shape. FIX:
  `validate_progress_opts/1` ahead of registration — every_n an
  integer >= 1, tag an atom, unknown keys refused, a non-keyword
  opts list refused (it silently meant defaults — the S3 sub-note)
  — all `{:invalid_hook_option, {key, value}}` /
  `{:invalid_hook_config, _}` through the standard wrap. The
  {key, value} payload noted on [F-B1-menu-connect-error-details]
  as the designed shape's precedent. Pins: a 7-shape hook
  rejection matrix + a valid-progress green control
  (driver_connect_pragmas_test).
- **F-B3-18 (S2, CONFIRMED, FIXED, RED→green).** The first-boot
  WAL noise: the README blamed an external writer and recommended
  raising busy_timeout — BOTH wrong. No other writer needed (two
  pool members racing each other hit ~90% of fresh-file boots at
  pool_size 2; an existing DELETE-mode file races too), and SQLite
  refuses the losing `journal_mode = wal` flip in ~1 ms WITHOUT
  consulting the busy handler (measured at 5 s/30 s/120 s
  busy_timeout — 120 s was marginally WORSE; p07/p08, controls
  0/125 + 0/50). Run 6's recorded busy-timeout-absorbs explanation
  is corrected on the ledger by this entry. FIX (p09 settled the
  candidates): re-read not viable (all 16 losers read back
  "delete"); bounded retry — every loser succeeded on attempt 1 —
  so `set_journal_mode/3` retries the flip up to 10 times at 2 ms
  on `{:database_busy_or_locked, _, _}`, and a genuinely held lock
  still fails structurally. README section rewritten (three
  corrections) + STE mirror. Pin: 8 rounds × 2 concurrent connects
  on fresh files, all must succeed (driver_connect_pragmas_test).
- **F-B3-19 (S2, CONFIRMED, FIXED, RED→green).** The vertical tab:
  settled from the BUNDLED TOKENIZER SOURCE (libsqlite3-sys 0.38.2
  sqlite3.c — aiClass line 185484 marks 0x0B CC_ILLEGAL, but the
  CC_SPACE run-consumer uses sqlite3Isspace whose ctype map
  INCLUDES 0x0B), so SQLite skips a VT inside a whitespace run and
  rejects it only statement-leading — an asymmetry Run 37's
  behavioral sweep (leading-position spellings) could not see, and
  why its "BOM + semicolon complete" conclusion was honest but
  wrong. `" \vBEGIN"` reopened BOTH F-B3-7 doors (p11: leak
  through the unseen open transaction; a healthy pooled connection
  destroyed by the stale flag through `" \vCOMMIT"`). FIX: `?\v`
  joined the skip set — safe unconditionally: statement-leading VT
  is a syntax error SQLite never executes, and the sync runs only
  after successful execution. The source-derived skip-set table is
  RECORDED HERE for the next pass: SQLite whitespace bytes =
  0x09 0x0A 0x0B(run-interior) 0x0C 0x0D 0x20; BOM = EF BB BF;
  `;` = an accepted empty statement. Pins: transaction_state +2
  (space-VT BEGIN flag sync; space-VT COMMIT no-destroy).
- **F-B9-19 (S3, CONFIRMED, FIXED).** `violations_count` saturates
  at the Run-44 cap while the real total was discarded by
  `diag_tag` (p05: 40 orphans → count 24, status :truncated, total
  recoverable from the event: NO). FIX: `violations_total` on the
  stop metadata (count stays "rows materialized");
  `diagnostics_status` values (:ok/:truncated/:unavailable)
  enumerated in the telemetry moduledoc AND the guide's event
  table — :truncated had been an unannounced value on a locked
  surface. Pin: the Run-44 truncation test extended with a handler
  capture asserting status/count/total (24/30).
- **F-B9-20 (S3, CONFIRMED, docs-FIXED).** The span :exception leg
  became pool-reachable through F-B3-17 (p03: full shape captured —
  kind :error, reason :function_clause, no result_class; OTel
  error.type "function_clause"), falsifying F-B9-9's
  "pool-unreachable today". Both doc surfaces now say the phase is
  not theoretical — anything raising inside a span's body emits it
  — without naming a specific route (the F-B3-17 fix closes the
  known one). The VM-wide handler-detachment warning stands with
  teeth.
- **F-B9-21 (S3, CONFIRMED, docs-FIXED).** The fk_diagnostics span
  cost is linear in EVERY FK-bearing table's rows and Run 44
  doubled the scans: measured ~36 ms at 200k child rows vs
  ~0.11 ms flag-off (~325× amplification, linear; p06). The
  moduledoc's cost paragraph now names the two whole-database
  scans and the measured curve. No code change — the baseline is
  what makes the diagnosis correct; no pin (timing) — numbers
  ledger-recorded here.
- **F-B1-5 CLOSED as discard-unreachable.** Settled at the SOURCE:
  xqlite's take_and_finalize_raw deliberately discards
  sqlite3_finalize's evaluation-error echo (stream.rs:66, commented
  as such), so the only returnable failures are a poisoned Mutex or
  an impossible-from-here invalid handle. Four constructions across
  Runs 37+46 (double-close, closed-conn, mid-step "malformed JSON"
  runtime error, schema change under an open stream) all :ok — the
  adapter's `_ =` has nothing reachable to swallow and the :ok stop
  event is truthful. REOPEN TRIGGER recorded in the Closed entry:
  xqlite ever propagating the finalize code. (p14/p17.)
- **Filed sweep (rest):** F-B3-1 reproduces (`:memory:` + pool 10:
  22 no_such_table / 2 empty of 24 reads); F-B3-4-xqlite reproduces
  (observer empties the busy slot 4567→0, unregister does not
  restore, remedy works); F-B3-14-menu reproduces in the NEW
  configuration (allowed process, pool 5 — "never nest" holds);
  F-B9-4 reproduces (lookup span-less: 12 candidates resolve with
  zero events of their own); F-B9-13/17 reproduces STATICALLY (the
  OFF lane still runs one smoke file; zero flag-guards in the four
  broken files; not run-verified under the no-mix-test rule — the
  next fixer MUST drive both builds); F-B9-14 reproduces (five
  bare destructures, still LATENT, and now flagged as the likely
  first real fk_diagnostics :exception).
- **Clean census (controls named):** with_xqlite under the Sandbox
  from an ALLOWED process lands on the OWNER'S sandboxed connection
  (marker read, nothing escapes checkin; genuine-stranger control
  OwnershipError — after clearing $callers, which a naive Task
  control inherits and silently passes by); the F-B3-10
  amplification curve is FLAT in hold time (300 ms vs 1500 ms:
  41-42/48 absorbed either way, 0-poisoned controls 48/48 ok —
  reproducing Run 37's 41/48 exactly; the reviewer's own first
  dirty control diagnosed as its key-shape bug via p16, corrected
  on record); the bare-RuntimeError Multi shape does NOT reproduce
  through three constructed doors (all escapes structured, the
  statement field riding Multi's error value; the process-kill door
  remains unconstructed — observed-not-reproduced stands); the
  Run-37 BOM/semicolon pins hold live; the nine validators hold
  11/11 around the new validate_connection_mode head; the
  savepoint-mode refusal is telemetry-clean (ConnectionError as
  {:disconnect, _} error_reason, OTel "DBConnection.ConnectionError",
  pool healthy after, nested-savepoint control commits); telemetry
  emission modules byte-identical since Run 29 (git-verified);
  Run 45's count_rows! pre-flight reads classified benign
  (caller's own checkout, no pool interaction). Brief correction
  on record: e166c5f never touched driver.ex (the Run-46 brief
  listed it there).
- Dryness: three S2 (B3) + three S3 (B9) — **B3 stays 0 of 2, B9
  stays 0 of 2, NOT DRY**; TWENTY-SIX straight finding runs.
  Re-wets ADD: `validate_progress_opts/1` + the hooks refusal
  family, `set_journal_mode/3` + `@journal_mode_attempts`,
  `leading_keyword/1`'s skip set (again), the fk_diagnostics stop
  metadata (violations_total) + the enumerated status values on
  both doc surfaces, the README first-boot section. Completeness
  critic (next pass): connect/1's remaining raise-capable surface
  (apply_custom_pragmas over an arbitrary user list is the
  candidate — any raise = crash + :exception); the hooks value at
  scale (a subscriber dying between connects — half the pool
  hooked; message volume at pool > 1); the journal-mode retry's
  own covering pass (cap exhausted under a genuinely held lock);
  `refresh_transaction_status/1`'s new savepoint zeroing (drive
  the counter negative / autocommit with outstanding savepoints);
  the OFF build ACTUALLY RUN (three runs static now); the
  :exception phase on the other seven spans (fk_diagnostics's
  F-B9-14 destructures are the live candidate); the mid-Multi
  connection kill via DBConnection's own registry; with_xqlite
  under :shared mode at pool > 1.


## Run 47 — 2026-09-01 — lap 6, batch 7: B2 solo (exclusion-list audit re-covered)

Single Opus reviewer at `8be11ac`; deps mix.lock-verified; UPSTREAM
WATCH NEGATIVE (mix.lock's last touch = the 2026-08-20 xqlite line;
the ecto pair unmoved since before Run 24); SQLite 3.53.2. Gate: all
SIX probes re-driven by the orchestrator (p00 census 440/26 rc 0;
p01 RED twin 441/466 exactly 25 failures; p02-p05 rc 0, decisive
lines matching); fixes BY THE ORCHESTRATOR; stash-RED: the doc-class
precedent (Run 38) applies to the prose, recorded honestly — the ONE
fix-coupled pin predicted and observed exactly 1 red (the
whole-file-rows check against the stashed tags doc); the message fix
is prose-only, not assertable. Post-fix 5/5.

- **Census: 440/26 exit 0, ZERO delta across Runs 39-46's 28
  commits**; bijection exact both ways (11 tags → 17 tests + 9
  location tuples = 26); snap check 9/9; the RED twin's one
  non-failing name is still interval.exs:194 (= F-B2-8, the only
  over-broad exclusion, disclosure intact after c854993's
  internal-reference scrub).
- **F-B2-28 (S2, CONFIRMED, docs-FIXED).** The hex-shipped
  README:30 claimed every exclusion is "a permanent SQLite
  limitation or a tracked adapter gap" — missing the third and
  largest-in-spirit bucket (deliberate adapter/suite decisions:
  transaction.exs:161, alter.exs:44, logging.exs:74,
  :lock_for_migrations) AND under-reporting by two whole files
  (lock.exs, query_many.exs — skipped in all_test.exs with
  comment-only rationales, no doc rows). FIXED: README rewritten to
  the three buckets + pointer; the tags doc gains a "Whole-file
  skips" section with both rows; grade held S2 (broken documented
  promise on the public surface, the F-B2-21/22 precedent). PIN
  (the mechanical half): exclusion_artifacts_test.exs — parses the
  helper's excludes, the doc's tables, and all_test's skip
  comments; asserts the bijection both directions, the test-line
  snap rule, and the whole-file rows, on every suite run (p05
  promoted).
- **F-B2-29 (S3, CONFIRMED, docs-FIXED).** The lock.exs skip
  rationale described ADVISORY locks; the file tests row-level
  SELECT…FOR UPDATE (live: :lock_for_update unset would raise
  first; a lock: query hits all/1's ArgumentError refusal; the
  FOR UPDATE syntax is SQLite-rejected; the lock_counters table
  IS built). Comment rewritten to the real feature + both
  refusals. PIN: a lock:-set query refuses up front
  (exclusion_artifacts_test).
- **F-B2-30 (S3, CONFIRMED, message+docs-FIXED).** "query_many is
  not supported by SQLite" blamed the engine for an adapter
  decision (one prepare call hands back the statement tail —
  looping it is exactly how sqlite3_exec works; our own
  :multiple_statements classification fires before SQLite ever
  sees the string). Message now says "not supported by this
  adapter" + the why; the skip rationale drops "Permanent API
  gap" and owns the choice. The F-B2-26 frame-attribution class,
  third instance.
- **F-B2-31 (S3, CONFIRMED, docs-FIXED).** The :lock_for_migrations
  doc row blamed "no advisory lock mechanism" where the helper
  correctly owns the deliberate no-op passthrough (live: the
  un-excluded test fails on "Expected Ecto.MigrationError but
  nothing was raised" — OUR decline, not SQLite). Row mirrors the
  helper + gains the migrator.exs:198 pointer (the one row that
  lacked one).
- **F-B2-32 (S3, CONFIRMED, docs-FIXED).** The :duration_type
  HELPER paragraph was a lap behind its own doc row (Run 38 fixed
  the row; the helper never got fact (a): the durations table
  builds WITHOUT complaint — live re-proven, default stored as
  literal '10 MONTH', the %Duration{} insert dies at OUR encoder).
  Third consecutive lap for the helper↔doc leak, and the direction
  REVERSED (doc-correct/helper-stale this time). Paragraph carries
  fact (a) now. PIN: the durations-migration probe promoted into
  exclusion_artifacts_test (the only instrument that can catch this
  pair drifting — the suite can never run these tests).
- **F-B2-33 (S3, CONFIRMED, docs-FIXED).** test_helper's WAL
  comment still told the migration-holds-the-lock story Run 46
  refuted and deleted from the README — doubly wrong here (the
  helper's migrations run AFTER the pools start). Re-truthed to
  the pool-members-racing account + belt-and-braces-over-the-retry
  status.
- **F-B2-34 (S3, CONFIRMED, docs-FIXED).** Two sibling rationales
  three lines apart contradicted each other about square brackets:
  the sql.exs:38 half claimed "a genuine grammar rejection" while
  the :30 half (F-B2-22's fix) explains the bracket-alias
  accident — and the :38 statement dies by the SAME accident, one
  token later (live: `SELECT array[1,2,3]` → "no such column:
  array"; the upstream form dies at the `=` because an alias
  cannot be an operand). Half rewritten.
- **F-B2-35 (S3, CONFIRMED, docs-FIXED).** The :modify_column row's
  notes over-claimed after Run 45's affinity guard (live: the
  textbook widen-to-decimal on a populated column now refuses,
  value intact; the vendored :modify_column tests pass because
  integer→numeric converts EXACTLY — the reason no vendored test
  crosses the guard, settled). Row gains the refusal clause +
  README pointer.
- **Cross-court seed FILED [F-B2-36-seed → B6]:**
  Connection.lock/2's second differently-worded refusal, made
  unreachable from Repo.all by the all/1 guard; update_all/
  delete_all reachability unprobed — B6's next pass owns it.
- **Filed sweep:** F-B2-8 reconfirmed the only over-broad
  exclusion (disclosure intact); F-B2-26-menu message correction
  verbatim at HEAD, still excluded-only upstream; F-B2-7-code
  stays superseded (the three reference-refusal pointers live
  through refuse_reference_changes!); the slow-macOS flake pair
  tally STANDS AT THREE — both tests passed every run this pass,
  disposition unchanged; F-B8-13 out of scope, class tally 1.
- **Clean census (controls named):** every n/m count exact (incl.
  the :values_list describetag subtlety); every grammar-blaming
  rationale re-driven through bare Repo.query (ON DELETE column
  lists, ADD PRIMARY KEY, schema-qualified names, isolation
  levels — with the read_uncommitted nuance the doc's "SQL-standard"
  wording already survives, %f milliseconds, NUMERIC coercion,
  JSON-as-text) — one failed and was filed (F-B2-34); the eight
  supported grammar rows accepted; :like_match_blob re-anchored
  over 54 compile options; every excluded test's live failure
  mechanism matched to its rationale (logging.exs:74's
  handler-fires claim re-proven via the detach error — right
  sentence, downstream symptom); the migration-conditional pair's
  adapter-owned probes green (bitstring: refusal + rollback +
  structured param error; duration: see F-B2-32); the
  create_prefix/drop_prefix never-executed comment true (both
  call sites excluded); alter.exs:60's savepoint-mode site
  re-proven doubly inert (inside an enclosing transaction + the
  test dies nine lines earlier); R42's rich:true masking
  disclosure still truthful; R43's keyword refusal consistent
  with F-B6-9's closure. Observed-not-proven: the ~12 structural
  "supported" mechanism sentences, dispositioned as Run 38 did.
- Dryness: one S2 + seven S3, all documentation-class — **B2 stays
  0 of 2, NOT DRY**; TWENTY-SEVEN straight finding runs. Re-wets
  ADD: the all_test.exs skip comments + the README taxonomy
  sentence (newly in scope), test_helper's WAL block, the
  :modify_column row vs any affinity-guard change; the new
  exclusion_artifacts_test is the standing instrument.
  Completeness critic (next B2 pass): read the helper+doc
  PARAGRAPH PAIRS side by side for all 20 exclusions (the leak
  runs both directions now — three laps, three findings);
  enumerate ALL prose surfaces first (all_test comments, helper
  non-exclusion comments, README suite/gaps sections,
  test_repo.ex stubs) then audit each; run the frame-attribution
  rule mechanically (grep "SQLite does not/has no/cannot", pair
  each with the live refusal's stack, check who it names); audit
  lib/'s refusal messages as claims (blame the right entity —
  three findings in that class now); re-check alter.exs:44 on any
  affinity-guard change (its exclusion survives only because
  integer→numeric converts exactly); the upstream-bump watch
  stands.


### Run 47 addendum — the push's CI red (Windows CRLF), fixed same session

`24c1c96`'s CI came back RED on ALL TEN Windows jobs (every
Elixir/OTP cell; Linux/macOS green): exclusion_artifacts_test's
anchor regex (`excludes = \[(.*?)\n\]\n`) returned nil on CRLF
checkouts — Git for Windows checks out with \r\n, the gotcha-15
line-ending sibling. Red-proven locally against a CRLF copy of the
helper (raw: no match; normalized: match), fixed by normalizing
\r\n → \n in the test's three file readers, 5/5 locally, full
verify green, pushed as a rider commit. The away log briefly
recorded this push GREEN before the verdict was read — corrected
in place; lesson: read the verdict file BEFORE writing the log
line.


## Run 48 — 2026-09-01 — lap 6, batch 8: B4 solo (type round-trips over the Runs-40-47 churn)

Single Opus reviewer at `24c1c96` (HEAD moved mid-run to `f3f9b05` —
md+test-only, zero lib churn, no re-review owed); deps
mix.lock-verified; SQLite 3.53.2. Gate: ALL TEN probes re-driven at
manifest rc (p05's rc 1 intended — its two crashes ARE the S2);
fixes BY THE ORCHESTRATOR; the five finding probes re-run post-fix —
loads/order/refusals flip correctly, and the two probe legs that
stayed red were shown to be the probes' own HAND-BUILT legacy-form
literals (the documented one-time-normalize case), settled by an
orchestrator DECISIVE probe (p10_orch_decisive: fresh insert +
insert_all store the space form; a bound-param range returns exactly
the right row). Stash-RED PREDICTED 8 — first run 6: TWO pins had
lost their teeth to my own redesigns (a far-past base pushed the
T/Z skew off the deciding byte; routing all rows through the usec
field erased the mixed precision) — rebuilt deterministically
(fixed SQLite-literal instant; two schemas at different precisions
over one column), second run exactly 8 by identity; the behavior
sweep then caught query_encoding_test's three encode-form pins
(flipped) before verify could. 46/46 + 86/86 green post-fix.

- **F-B4-15 (S1, CONFIRMED, FIXED, RED→green).** A `:utc_datetime`
  row written by SQLite ITSELF — a CURRENT_TIMESTAMP default,
  datetime() — was unreadable (DateTime.from_iso8601 →
  :missing_offset → Ecto's raise; ONE such row killed every read of
  the table) and mis-ordered against adapter rows (space 0x20 vs T
  0x54 at index 10: 748/2000 same-day pairs wrong, single-form
  controls 0). TWO fixes: (a) the loader retries an offset-less
  text as naive + Etc/UTC (`:utc_datetime` columns ARE UTC); (b)
  the STORED FORM is now SQLite's own — space separator, no
  designator — for :utc_datetime/:naive_datetime + _usec twins
  (naive changed too: same separator byte-order argument).
  TimestampTZ DELIBERATELY unchanged (offset storage is its
  documented purpose — scope decision on record). Pre-1.0
  stored-format break: CHANGELOG Changed + README normalize
  snippet + STE + honesty-ledger item 17. Pins: stored form,
  SQLite-written loads (datetime/date/time), deterministic
  mixed-writer order+range (fixed-literal db row), types_law ×4
  re-pinned via sqlite_form/1, query_encoding ×3 flipped.
- **F-B4-16 (S2, CONFIRMED, FIXED, RED→green).** The trailing Z
  made a sub-second value sort BEFORE its own whole second ('.'
  0x2E < 'Z' 0x5A): 1009/2000 within-a-second mixed-precision pairs
  wrong, naive-text control 0/2000. Fix (b) covers it (no
  designator ⇒ shorter is a prefix ⇒ length decides, correctly).
  Pin: two schemas at different precisions over one column,
  stored-text asserted, order [1,2,3].
- **F-B4-17 (S2, CONFIRMED, FIXED, RED→green).** Decimal.parse/1
  clean-parses NaN/±Infinity (8 spellings), so the Run-39 gate
  passed them to Ecto's :decimal which raises an exception naming
  NO field/row/value — one such row killed Repo.all. Run 39's
  ledger claim that inf/NaN "already took the typed-load-failure
  path" is CORRECTED BY THIS ENTRY — false at that HEAD and this
  one. FIX: finite_or_error/1 on both the parse and %Decimal{}
  passthrough clauses. Reachable without an external writer (a
  :string sibling schema writes the text; NUMERIC affinity keeps
  it TEXT). Write side already refused (Ecto dump, 3/3). Pins: 8
  spellings → typed load failure naming the field (assert_raise on
  Ecto's "for field" phrasing — a deliberate, recorded exception
  to the no-text rule: the distinguisher IS the message source,
  and the exception is Ecto's, not ours to structure); finite
  control green.
- **F-B4-18 (S3, CONFIRMED, FIXED — B7-court fix landed at this
  gate).** The R45 affinity pre-flight's CAST predicate over-refused
  (CAST converts junk to 0; the copy's affinity coercion carries
  non-literal text byte-exact): 'abc'/'' blocked a byte-exact
  modify. No false accept found. FIX: the copy itself is the oracle
  — pour the column through a NUMERIC scratch TEMP table (rowid-
  paired) and count values whose RENDERED TEXT the pour changed
  (the IS NOT first draft counted exact-converting class changes
  and would have broken R45's green-control rule — corrected to
  rendered-text compare, preserving the asymmetric R45 adjudication
  exactly). WITHOUT ROWID tables keep the conservative CAST
  predicate (no rowid to pair; over-refusal-at-worst, commented).
  Pin: 'abc'/''/'42'/'1.5' pass with exact post-copy classes; the
  R45 '007'/big-decimal refusals still hold (existing pins).
- **Filed sweep:** [F-B4-10-menu] HOLDS at five doors with no sixth
  (14 witnesses each; the same two 16-digit floats drift at every
  door; NUMERIC control drifts on none; characterization refined:
  the drift is SQLite RENDERING the bound float back with MORE
  digits — ≤15 significant digits do not drift). Menu not
  re-adjudicated.
- **Clean census (controls named):** the CAST-AS-NUMERIC
  neighborhood CLEAN — 12 TEXT + 5 BLOB witnesses under both casts,
  NUMERIC exactly-or-better everywhere, the sole divergence IS the
  R43 fix's witness; mixed-storage sum correct; tagged equality
  past 2^53 finds the row while the float twin doesn't.
  sqlite_affinity/1 agrees with live SQLite 35/35 spellings (12
  two-marker cases across all three precedence rules; Ecto.Migrator
  oracle with typeof read-back). The R43 aliases do their job
  (nested JSON exact, inet keeps leading zeros, bytea BLOB; :money
  control coerces). A rebuild over four exotic-spelling columns
  preserves values, classes, AND type texts. The foreign-writer
  matrix: 55 hostile values over 13 types → 40 typed refusals + 14
  correct loads + the 2 that were F-B4-17; :boolean breadth fully
  covered (2/-1/int64max/3.14/'true'/blobs all refuse typed).
  expr(%Decimal{}) is DEAD CODE on a 20-route matrix
  (DecimalPrecisionError.index oracle: every route parameterizes).
  DateTime identity holds on 12 boundary instants × 7 types.
  Observed-not-proven: ecto_sqlite3's stored form (offline —
  CRITIC ITEM 1 for the next pass: if it stores the space form,
  F-B4-15 widens to every migrated database and the migration
  guide needs a hard note); p03's RED-3 true-answer was
  probe-internal arithmetic (superseded by the decisive probe's
  independent check).
- Dryness: an S1 + two S2 + an S3 — **B4 stays 0 of 2, NOT DRY**;
  TWENTY-EIGHT straight finding runs. Re-wets ADD:
  encode_param's datetime clauses + sqlite_datetime/1,
  utc_datetime_decode/1 + utc_from_naive/1, finite_or_error/1,
  copy_rewritten_count!/5 + the scratch-table oracle, the
  stored-form pins family (types_law sqlite_form, query_encoding,
  stored_value_interop). Completeness critic (next B4 pass):
  ecto_sqlite3's stored form (item 1 above); re-sweep the datetime
  surface post-form-change (Instant type, comparisons of bound
  params vs legacy stored strings, the fragment("datetime(?)")
  composition family); :date/:time population sweeps vs SQLite's
  writers (spot-checked only); Decimal.parse's accepted surface
  beyond inf/NaN (underscores, unicode digits, absurd exponents);
  sum() overflowing to infinity end-to-end; the scratch-oracle's
  own neighborhood (huge tables' pre-flight cost, the TEMP-table
  name under concurrent modifies on one connection, rendered-text
  compare vs trailing-zero decimals); DECIMAL(p,s) option splice
  round-trips.


## Run 49 — 2026-09-01 — lap 6, batch 9 (THE CLOSER): X1 + X2 paired cover

Single Opus reviewer at `3e4eef6` (xqlite checkout `1f1c8de` read for
the forward blast); deps verified; SQLite 3.53.2; the error_reason
union = 48 members, unchanged since Run 26. Gate: ALL FOURTEEN
probes re-driven at manifest rc (p07's rc 1 intended); the re-drive
completed on the pre-fix tree PROVEN by p14's pre-fix output — but a
NEAR-MISS recorded honestly: the fixes were being written while the
re-drive was still in flight (the Run-46 rule broken a second time;
saved by timing alone — the rule needs to be mechanical: launch
re-drive, then ONLY reads until its notification). Fixes BY THE
ORCHESTRATOR; post-fix probes verified the right flips (p02's fetch
error now carries its SQL; p14's "HEAD encoder" line is that probe's
own inline reconstruction of the old formula — the pin is the real
proof, decisive via shift_zone spot-check). Stash-RED PREDICTED 2 —
observed exactly 2 by identity; 15/15 restored. A stray empty file
`dead` (a probe shell artifact) caught untracked and removed before
commit.

- **F-X1-8 (S2, CONFIRMED, FIXED, RED→green) — a REGRESSION my own
  Run-48 gate introduced.** The datetime-form change dropped the
  offset via DateTime.to_naive/1 (the LOCAL wall clock), so a
  non-UTC DateTime on the raw-SQL path stored its wall time as if
  UTC — off by its offset, silently (p05/p14: +02:00 noon stored as
  12:00 where 10:00 is the instant; p06 route table: Ecto's typed
  surface fully protected — dump/insert/typed pins all refuse or
  normalize — the exposure is exactly raw Repo.query params and
  untyped fragment pins). The Run-48 trade was wrong-ordering →
  wrong-value on this path; now neither: shift_zone to Etc/UTC
  (works with the UTC-only tz database — p07 proved it, and
  DateTime.add does NOT) before dropping the designator; the
  {:error, _} arm degrades to the offset-carrying ISO form (correct
  instant, legacy ordering caveat). Pins: zoned raw param stores
  the UTC wall time; the UTC control byte-stable. README's datetime
  bullet gains the raw-path sentence + the TimestampTZ note on the
  normalize snippet.
- **F-X1-7 (S3, CONFIRMED, FIXED, RED→green — the standing item
  CLOSED).** handle_fetch's error branch was the one of five error
  sites without put_statement; an ordinary streamed RETURNING DML
  violating UNIQUE past the first row surfaced with statement nil
  (p02) while declare/execute stamp theirs. The fix direction was
  TRACE-PROVEN before implementation (p03: erlang.trace_pattern on
  handle_fetch/4 — the first argument IS a %Query{} carrying the
  declared SQL on every call including the failing one; DBConnection
  hands it over at db_connection.ex:1964; Run 40's cursor-carries-
  no-SQL rationale true but irrelevant). Fixed by binding the query
  + stamping. Pin: a failing streamed statement carries its SQL
  (stream_test). BACKLOG entry moved to Closed.
- **F-X2-4 (S3, CONFIRMED, FILED — xqlite court).** The staged
  0.11.1's clippy rewrite (9f2e278, as_chunks) raises the
  source-build Rust floor to 1.88 with nothing declaring it (no
  rust-version, stable-only CI, no README line) while
  XQLITE_BUILD=true is documented. Precompiled users unaffected.
  Filed with the two-line fix for xqlite's court.
- **Step-0 (the lap's X1 contract deltas enumerated):** the connect
  refusal family grew 18 → 21 tags (all 21 wrap with type = tag,
  zero nil types, all messages non-empty — p12); the details union
  unchanged (6 members); fk_diagnostics {:truncated, pos_integer()}
  exact; the savepoint refusal's bare DBConnection.ConnectionError
  divergence RECORDED for the next pass's adjudication (critic 2);
  the datetime storage form logged as an API-visible contract
  change; the F-B1-9 {tag, binary} message collision re-verified
  and WIDENED by one (:invalid_connection_mode accepts binaries) —
  stays merged in the connect-error-details menu (21 sites now).
- **Filed sweep:** [F-X2-3]/[xqlite-0.11.1-release] HOLDS —
  unreleased; the checkout-vs-hex diff is EXACTLY two files (the
  doc correction + the lint), diff -rq-proven; the adapter's
  ~> 0.11.0 pin admits the patch automatically, no adapter change
  owed. The xqlite-court queue IS REAL (constraint_parse.rs at
  1f1c8de has no SQLITE_CONSTRAINT_ROWID arm and no bare-
  "constraint failed" handling — neither F-B5-31's nor F-B5-26's
  xqlite half ships in the staged 0.11.1). [F-B8-2] holds (no
  cancellable stream fetch at 0.11.0). F-X1-1/2/5/6, F-X2-1/2 stay
  closed; F-X1-4's pin + compat rows hold across all four doc
  surfaces.
- **Clean census (controls named):** the NIF call surface = 41
  name+arity calls / 73 occurrences, ALL exported at 0.11.0
  (AST-walk with @spec pruning; the un-pruned control explains the
  old miscounts); the forward blast = ZERO product surface (the
  "pending" 20-NIF DirtyIo flip ALREADY SHIPPED inside 0.11.0 — 91
  DirtyIo attributes in BOTH trees — the standing note was stale
  and dies with this entry); the busy-slot claims hold through a
  REAL pooled checkout 4/4 with timing (2004 ms baseline / 0 ms
  observer / 0 ms after unregister / 2003 ms restored — discharges
  Run 40's critic; API note: unregister takes the returned integer
  handle, not a pid — doc line owed xqlite-side someday); the
  full-48 emission question ANSWERED (19/33 shapes provoked through
  one pooled checkout, every one wraps + classifies correctly, zero
  drift; the rest are reachable but surface as the caller's own
  tuples with Error.wrap/1 public — the structural answer; seven
  decode-boundary ArgumentErrors recorded as my guessed shapes, not
  findings); census pins: :invalid_pragma_name CONFIRMED
  (malformed-only; unknown-but-well-formed → {:ok, :no_value});
  **Run 40's :invalid_stream_handle pin proposal REFUTED — every
  post-close operation degrades gracefully (double close :ok, fetch
  :done, get_columns {:ok, cols}); the shape is not constructible
  from the adapter's surface and the proposed pin would have
  encoded a false fact.** Doc parity: the live README absorbed all
  five of the lap's contract changes (no stale claim by the Run-40
  method); STE drafts in sync on content, two cosmetic drift items
  (section order; dash style) noted for a docs pass, not mirrored
  at this gate.
- Dryness: an S2 (lap-introduced regression, fixed) + two S3 —
  **X1 and X2 each stay 0 of 2, NOT DRY**; TWENTY-NINE straight
  finding runs. **LAP 6 COMPLETE — all nine batches, tally 5 S1 +
  16 S2 + 23 S3 = 44 findings in Runs 41-48, plus this run's 3.
  Every axis that ran stayed 0 of 2; DRY = B10 alone (its re-cover
  rides the bench work).** Re-wets ADD: the four temporal
  encode_param clauses (now a storage contract), handle_fetch's
  stamp, the next xqlite release (F-X2-3 + F-X2-4). Completeness
  critic (next X pass): the Date/Time encoder siblings as one
  family (+ NaiveDateTime {0,0} vs {0,6} precision vs
  SQLite-written values); the savepoint refusal's shape
  adjudication; the seven decode-boundary rows re-driven with real
  @spec shapes; Xqlite.explain_analyze/3 + Telemetry.* driven at
  0.11.0 (standing since Run 26); hexdocs read directly (standing);
  re-cover BOTH axes immediately after the 0.11.1 release.


## Gate 3 RC prep — 2026-09-05 — the release-readiness checklist, both repos

Not a review run: the Gate 3 checklist from the publish-readiness
plan, worked item by item with evidence. Scoping and gating by the
orchestrator; two Opus implementers (one per repo), one read-only
Opus CHANGELOG auditor, one Opus cold-run of the README. Both
implementers were cut off by a rate limit after their own green
`mix verify`; their edits were salvaged from the working trees and
re-gated here.

**Evidence gathered first (orchestrator):** hexdocs built for both
repos (adapter: two "Illegal attributes … ignored in IAL" warnings at
README.md:83 — the rendered README was DROPPING
`{:hook_subscriber_not_registered, name}` and
`{:xqlite_update, action, db, table, rowid}`; plus two
"undefined or private" warnings for `Xqlite.set_busy_handler/3`);
a public-function doc census over every module of both apps
(`Code.fetch_docs` + `Code.Typespec.fetch_specs`); precompiled
honesty (8 release assets ≡ 8 checksum entries, NIF 2.17 only ⇒ OTP
26 floor, undeclared); the Rust floor measured empirically (Rust
1.90.0 refuses the crate — "rustler@0.38.0 requires rustc 1.91" —
and 1.91.0 builds it; spike toolchains removed afterwards);
dependency licenses of the resolved NIF graph (all permissive: MIT /
Apache-2.0 / BSD-3 / ISC / Zlib / Unicode-3.0); both Hex packages
found to ship `lib/mix/tasks/` (xqlite: `mix verify` under a generic
name in every dependent project); the 21 accidental-public
`Connection` helpers re-verified caller-free outside the module
(lib + test, alias-aware), three of them driven by tests.

**Landed, adapter (this commit):** [G1] closed — 18 helpers `defp`
via one ast-grep rule (36 clause heads), three test-driven helpers
kept public under `@doc false`, `all/2` hidden; the flip exposed
four dead clauses, deleted (`insert_all/1`, the `%Ecto.Query{}`
clause of `insert_all/2` — `rows_sql/3` renders query sources
itself — `lock/2`, `create_names/1`). `embed_as/1` overridden with
`@impl` in Duration/Instant/TimestampTZ (the inherited default was
rendering as an undocumented function). `@spec` on `Error.wrap/1`.
`exclude_patterns: [~r"^lib/mix/tasks/"]` in the package. README:
the configuration paragraph replaced by the STE draft's bullet list
(zero docs warnings; both tuples render); `Xqlite.set_busy_handler/3`
→ `register_busy_observer/2`; `ecto_repos` moved into the
`config.exs` block with the compile-time explanation; the
supervision-tree and `mix ecto.gen.migration` steps added; the
`details: nil` claim corrected. CHANGELOG: seven claims corrected
(see the audit) and the streaming carve-out (`fk_diagnostics: :not_run`
/ `unique_index_lookup: :not_run`) added to the two bullets that
promised more than the stream path delivers. The STE draft mirrors
every README change. Census after: `Connection` lists zero
undocumented functions; the three types show none.

**Landed, xqlite (separate commit):** `rust-version = "1.91"` in
Cargo.toml; the README toolchain paragraph now states the platform
list, the OTP 26 floor (NIF API 2.17) and the Rust 1.91 floor, STE
draft mirrored; CHANGELOG Changed entries for both; the same
`exclude_patterns`; UPGRADE_PLAYBOOK step 2 re-derives the floor on
every rustler/rusqlite bump. F-X2-4's diagnosis corrected in the
backlog (the floor was 1.91 since 0.11.0; as_chunks changed nothing).

**CHANGELOG honesty audit (Opus, static only, every claim
orchestrator-spot-checked before editing):** 168 claims — 148 true,
6 false, 1 stale, 13 unverifiable by reading. Corrected: WITHOUT
ROWID "keeps the conservative predicate" (unreachable branch —
refused earlier at `unpreservable_table_option/1`); `on` in the
column-name list (the scan matches `ON CONFLICT` only); "custom_pragmas
stays unvalidated" (the option's shape is refused:
`{:invalid_custom_pragma(s), _}`); "re-reads after ANY
transaction-control statement" (execute path only — the stream path
is not synced; filed [G3-1], S3, B3 court); `-64_000` "pages" (KiB);
"tag-only errors keep details: nil" (six tags carry a map — README
corrected too); the stale double-quote caveat on runtime JSON keys
(escaped since `53599f4`). Refuted auditor item: `RebuildVerification`
and `DecimalPrecision` "have real moduledocs" — both are
`@moduledoc false`; the docstrings it saw belong to the exception
modules sharing the files. The thirteen unverifiable claims are
third-party comparisons (first adapter to cache statements,
ecto_sqlite3's `:deferred` default, PostgreSQL parity claims), two
measurements (120 s busy wait, first-retry success), upstream
dispatch (Ecto raising `ConstraintError`, `mode:` forwarding,
boolean-loader routing), and SQLite fidelity claims — listed for the
maintainer's Gate 4 read; none contradicted by code.

**README cold-run (Opus, fresh `mix new --sup`, the GitHub dep as
written, precompiled NIF downloaded from the release — no Rust):**
every asserted behavior held, including byte-exact
`changeset.errors` under both config styles and the URL parameters
taking effect. One defect (fixed): `ecto_repos` under
`config/runtime.exs` made `mix ecto.gen.migration`/`create`/`migrate`
no-op with a warning and exit 0. Two gaps closed (supervision tree,
`gen.migration`). Two left to the Gate 4 README review: the snippets
lack `import Config`, and a plain `mix new` has no `config/` dir.

**Gate 3 status after this entry:** every checklist item has
evidence — hexdocs completeness + typespecs + dialyzer (one
justified ignore), accidental-public audit, precompiled/dep honesty,
CI-matrix honesty (floors match the matrices; Windows is
CI-tested), MSRV, license, CHANGELOG honesty, quickstart cold-run,
`~>` sanity (`~> 0.11.0` since F-X1-4). Remaining before the gate
is called green: CI on both pushes, and the maintainer's read of
the unverifiable-claims list.

### Gate 3 addendum — "guides execute", both repos (same day)

Two Opus cold-runs executed every fenced snippet and every testable
prose claim: xqlite's five guides against the Hex 0.11.0 package (31
snippets), the adapter's two guides against the pushed main (13
snippets plus the README scaffolding). Every runtime claim below was
re-driven by the orchestrator before an edit was made.

**xqlite (fixed in `f984414`):** the security guide and the README
feature list still showed `{:authorization_denied, message}` — the
real term is `{:authorization_denied, 23, "not authorized"}` (S2
doc-behavior divergence, present since the 3-tuple change); the
authorizer example deleted from a table it never created; the
telemetry guide's Honeycomb section called
`:opentelemetry_telemetry.attach/2`, which does not exist
(opentelemetry_telemetry 1.1.2 ships `:otel_telemetry` with
`start_telemetry_span/4`, `end_telemetry_span/2` and friends — no
attach); the Logger sample lacked `require Logger`; the gotchas
`:emit_error` sample piped the `{:error, reason}` that
`Xqlite.stream/4` returns on a setup failure into `Enum`; two
placeholders labelled. SpatiaLite's five snippets NOT RUN — the system
library is absent here; the guide's apt line verified correct.

**Adapter, product defect (S2, fixed in this commit, RED→green):**
`config :xqlite_ecto3, :binary_id_storage, :binary` flipped the DDL to
BLOB but a `:binary_id` field still wrote the 36-char string: Ecto's
`:binary_id` primitive passes binaries through, so `binary_id_dump/1`
only ever saw raw bytes from `Ecto.UUID`-typed fields — the shape the
existing pins tested — and the documented shape
(`@primary_key {:id, :binary_id, autogenerate: true}`) fell to the
pass-through clause. No `:binary_id` loader existed either, so a
correctly stored BLOB would have loaded as 16 raw bytes. Fix: the
dumper compacts a UUID-shaped string to its 16 bytes under `:binary`
(non-UUID strings pass through — `:binary_id` is not necessarily a
UUID in Ecto), and a storage-aware loader expands 16 bytes to the
string under `:binary` only (a 16-byte value under `:string` storage
is an opaque id). Pins: the dumper and loader chains through
`Ecto.Type.adapter_dump/3` and `adapter_load/3`, plus a schema round
trip asserting `typeof(id) = 'blob'`, `length(id) = 16`, and
`Repo.get!` by the string id. RED 3/3 before the fix. `Types.UUID`
with `storage: :binary` was never affected.

**Adapter, docs (fixed in this commit):** the migration guide's
headline rescue example read `e.constraint_type` /
`e.constraint_details` (removed in the payload restructure →
`KeyError`); its sanity table carried the same stale shape; the
escape-hatch example collided with the default primary key; Step 5
sent `explain_analyze` through `Repo.checkout` (which hands the caller
no connection) instead of `XqliteEcto3.explain_analyze/3`; four
fragments could not compile as printed. The telemetry guide claimed
three composing layers — the adapter drives the NIF layer directly,
so `[:xqlite, …]` spans never fire for Repo traffic (33 attached, none
fired; statically: the driver calls `XqliteNIF.*`, the only `Xqlite.*`
wrapper call in lib is `explain_analyze`); its "adapter vs driver"
sample subtracted a span that cannot exist; two samples called
`Telemetry.Metrics.Counter.inc/1` and `Distribution.observe/2`, which
that library does not have (its metrics are declarations consumed by
reporters); the OpenTelemetry section was the same fabricated
`attach/2`. Every other claim held — the four-case unique-index
contract, FK and NOT NULL shapes, in-flight `:timeout` cancellation
(407 ms observed against a 400 ms budget), MODIFY batching into one
rebuild, DELETE with JOIN, every event's metadata keys,
statement-cache counts, disconnect correlation by `conn`, the OTel
attribute mapping, and a reader following only the guide does get
events flowing.

## Run 50 — 2026-09-05 — lap 7, batch 1: B8 solo (timeout → cancel over the Runs 42-49 + Gate-3 churn)

- Commit at scan: `35d6033` (HEAD, clean, verify + CI green). Scope: B8 solo, the
  lap-7 opener, on Dimi's full-autonomy grant of the same day. Churn attacked:
  `a566b54..35d6033` (34 commits; 17 lib files): the top-level `mode: :savepoint`
  refusal + `released_savepoint_state` rewrite (R42), the FK-replay baseline
  savepoint (R44), the bounded journal-mode retry + hook validators + vertical-tab
  skip (R46), `handle_fetch` stamping (R49), the datetime form + zoned-param shift
  (R48/49), the `Connection` visibility flip and the `:binary_id` storage fix
  (Gate 3). Composition: one Opus reviewer (15 probes, `b8_cover_r50/`), every
  probe re-driven by the orchestrator on the untouched tree BEFORE any edit
  (all reproduce; the two non-zero exits are the reviewer's deliberately refuted
  trigger hypothesis and a predicted shape flip); fixes, pins, docs, and the gate
  by the orchestrator. F-B8-1 re-driven as mandated: 3006 / 3004 / 301 ms —
  reproduces unchanged, not re-filed.

### CONFIRMED

- **F-B8-14 (S2, FIXED, RED→green).** `spawn_canceller/2` passed a negative
  `:timeout` straight into `receive … after`, which raises `:timeout_value` in the
  unlinked canceller: no cancel ever fired, the dirty NIF ran to completion
  (3475 ms for the ~3.5 s probe query vs 301 ms at `timeout: 300`), and
  DBConnection's already-expired deadline disconnected the connection
  asynchronously — the NEXT caller on that pooled connection got
  `%XqliteEcto3.Error{type: :connection_closed}` (p05: the two shapes alternate
  run to run). Reachable via repo config and per-call opts (p04); the plausible
  producer is a computed remaining budget going negative. FIX: `max(timeout, 0)`
  — the semantics of `timeout: 0` (cancel at once, measured 0-1 ms). PIN:
  cancellation_test "a negative timeout cancels at once" (`{:error,
  %DBConnection.ConnectionError{}, _}` under 1 s). Predicted RED = the `{:ok, …}`
  match failure after ~3.5 s — observed exactly.
- **F-B8-15 (S2, FIXED, RED→green).** `handle_begin/2` mapped every `NIF.begin/2`
  error to `{:disconnect, …}`. With the default `:immediate` mode a held write lock
  makes `BEGIN` fail with `:database_busy_or_locked` after `busy_timeout`, so every
  contended transaction start destroyed a healthy connection (p08: 502 ms then
  `{:disconnect, …}`; the `:deferred` control: `BEGIN` 0 ms `:ok`, its contended
  write `{:error, …}` with the connection kept; p09 through a real pool of 2 with
  `busy_timeout: 200`: 8 contended begins = 8 disconnect events + 8 reconnects,
  the `:deferred` control 0/0). The README's retry advice ("treat
  `:database_busy_or_locked` as retryable") made every retry burn another
  connection. SQLite starts no transaction when `BEGIN` loses the lock race, so the
  busy shape now returns `{:error, wrapped, state}` and keeps the connection; every
  other begin failure still disconnects. `{:error, exception, state}` is not in
  DBConnection's documented `handle_begin` return union but is consumed by its
  shared `handle_common_result/3` (db_connection 2.10.2 `db_connection.ex:1397-1416`,
  reached from `run_begin/3`'s fall-through at :1859) — dialyzer accepted it
  (verify below). Second half: `:timeout` does not bound `BEGIN` (no cancel token
  on `NIF.begin/2`; 3004 ms for a 100 ms token vs `busy_timeout` 3000) — the F-B8-1
  family, DOCS: README timeout section + retry bullet, STE draft mirrored. PIN:
  driver_transaction_mode_test "a lock-contended BEGIN keeps the connection"
  (holder handle in `BEGIN IMMEDIATE`, second handle's begin → `{:error,
  %Error{type: :database_busy_or_locked}, state}`, then `SELECT 1` succeeds on
  that state). Predicted RED = `{:disconnect, …}` — observed exactly.
- **F-B8-16 (S3, FIXED adapter half, RED→green).** `stmt_prepare` refuses
  whitespace/comment-only SQL precisely (`{:cannot_execute, "SQL contains no
  statement"}`, nif.rs:744) but `prepare_and_cache/2` treated any
  `{:cannot_execute, _}` as a fallback trigger, so the one-shot path stepped a
  null statement into API_ARMOR and `Repo.query` returned `SQLITE_MISUSE` (21)
  for empty / whitespace / line-comment / block-comment input (p12; the syntax
  control gives code 1). Graded S3 (diagnostic consequence only) with the
  reviewer's S2 argument on record (wrong classification, public API). FIX: the
  fallback clause is deleted; the refusal surfaces as `%Error{type:
  :cannot_execute}` (the other prepare-time `cannot_execute`, an over-`c_int`
  SQL length, follows it — the one-shot path would fail identically). The
  `statement_cache_size: 0` path still answers MISUSE — xqlite half filed. PIN:
  error_paths_test "SQL with no statement is reported as such". Predicted RED =
  `:sqlite_failure` code 21 — observed exactly.
- **F-B8-17 (S3, FIXED, RED→green).** The two `handle_begin` refusals were bare
  `%DBConnection.ConnectionError{}`s — the only untyped refusals in the driver,
  unpinnable without message matching — and the savepoint text told the caller
  to "drop the mode: option" although `Ecto.Adapters.SQL.Sandbox` forces
  `mode: :savepoint` on every begin it forwards (sandbox.ex:360-361): after a raw
  COMMIT inside a sandboxed connection, a plain `Repo.transaction` hit that advice
  (p14). FIX: `%XqliteEcto3.Error{type: :savepoint_without_transaction, details:
  %{mode, transaction_status}}` and `%XqliteEcto3.Error{type:
  :invalid_transaction_mode, details: %{mode}}`, message reworded to the state
  found. PINS: driver_transaction_state_test (new describe) +
  driver_transaction_mode_test (the existing invalid-mode pin flipped to the
  typed shape). Predicted RED = the `ConnectionError` struct — observed.

### CLEAN legs (controls named)

- F-B8-1 at HEAD (`:infinity` control 3004 ms; uncontended control 301 ms).
- `stmt_prepare` inherits the busy wait: cold prepare 3004 ms vs warm 0 ms —
  answers Run 41's open measurement; F-B8-1's family, not a new finding.
- The `{:cannot_execute, _}` fallback half smuggles nothing: six no-statement
  spellings identical on the cached and one-shot paths, the cached flag stays
  `:idle`, a preceding INSERT's count does not leak (classification = F-B8-16).
- The savepoint counter cannot go negative (commit/rollback at 0 disconnect on
  the NIF's "no such savepoint"; F-B8-8's raw ROLLBACK zeroes 1→0; F-B8-4's guard
  re-confirmed under the R42 rewrite).
- G3-1's cancel side: a cancelled write inside a stream-opened transaction lands
  on the state the stale flag already claims (`real_after={:ok, false}`);
  control: a driver-begun cancel disconnects.
- FK replay cannot escalate a violation into transaction loss (trigger route
  refuted: SQLite fires the AFTER trigger before the immediate FK check, so the
  `rich_fk_diagnostics: false` control took the identical disconnect); the
  `defer_foreign_keys` clobber in `cleanup/1` is unreachable by construction.
- `checkout/1`'s post-connect-only comment verified in db_connection source
  (connection.ex:246/268).
- The pool closing a handle under a client callback is a structured
  `:connection_closed`, not UB (the F-B8-13 mechanism re-derived).
- The journal-mode retry does not compound reconnects (8/8 reconnects succeeded
  under a held write lock — `journal_mode = wal` on a WAL file needs no lock).

### Handoffs

- **F-B8-18 (S3, B5 court + xqlite half):** the default cached path can never
  produce `:sql_input_error` — `stmt_prepare` builds a plain `SqliteFailure` for a
  syntax error while the one-shot path yields `%Error.Input{sql, offset}` (p13).
- **G3-1 → B3:** measured — a later successful INSERT inside a stream-opened
  transaction is lost when the connection recycles (`rows_surviving_recycle = 0`).
- **F-B8-13 tally:** stays at 1; p05's deterministic `:connection_closed` via
  non-positive timeouts strengthens the "normalize into the ConnectionError
  surface" option.
- **Adapter side of F-B5-31 landed in this gate:** `to_constraints/2` maps
  `:constraint_rowid` beside `:constraint_primary_key` (stash-RED 1/1 on the
  synthetic pin; the live pin accepts both the empty 0.11.0 shape and the parsed
  one, so the dep bump past 0.11.0 flips nothing).

### Gate honesty

- Stash-RED (driver.ex stashed, the four touched test files run): predicted 5
  reds by identity → 5/5 (the invalid-mode flip, no-statement, contended BEGIN,
  savepoint refusal, negative timeout). The GREEN run then caught a SIXTH flip the
  behavior sweep missed — an existing pin of the old savepoint-refusal shape in
  the "savepoint counter lifecycle" describe (`driver_transaction_state_test`) —
  flipped to the typed shape; the sweep pattern matched comments in another file
  and not this test's title. Recorded as a sweep miss, same class as Run 45's.
- Rowid mapping: connection.ex stashed → constraints_test 1/1 red on the
  synthetic pin, green after pop (69 passed across the two files).

### Run 50 addendum — the push went out on a RED gate (procedure error), fixed by a rider

- `mix verify` for the Run 50 tree was RED (exit 1): a SEVENTH pin of the old
  savepoint-refusal shape — `transaction_atomicity_test.exs:310`, "top-level
  savepoint mode is refused …", `assert_raise DBConnection.ConnectionError` —
  which the behavior sweep missed twice (its title carries neither search
  phrase; the file's hits were comments). The orchestrator's commit command
  guarded ONLY the ledger append with `[ "$(cat exit)" = 0 ] && cat >> … <<EOF`
  and then ran `git add`/`git commit`/`git push` as separate, unguarded lines —
  the fused-chain class Run 16 already recorded. Result: `25b0b0d`..`b19c04d`
  pushed on a red gate; CI run 33939813688 red on 12 jobs (every test lane +
  coverage + latest-ecto_sql), all on that one test; the ledger's verify line
  was correctly blocked by the guard, so no false GREEN was recorded.
- Rider: the pin flipped to `assert_raise XqliteEcto3.Error` +
  `type == :savepoint_without_transaction`; re-verified (line below);
  committed with an abort-first guard (`[ "$(cat exit)" = 0 ] || exit 1` as the
  script's first statement — codified in the verify-gate memory).
- Rider `mix verify` GREEN (exit file 0 — the flipped pin's file first, then
  format, compile, deps.audit, sobelow, dialyzer, the full sequential suite).

---

## Run 51 — 2026-09-05 — lap 7, batch 2: B1 solo (conformance re-audit over the Runs 42-50 + Gate-3 churn)

- Commit at scan: `88e6d91` (HEAD, clean, verify + CI green). Scope: B1 solo.
  Churn attacked: `db4d860..88e6d91` (34 commits; 17 lib files, +642/−265): the
  Run-50 `handle_begin` `{:error, exc, state}` arm + typed refusals, the Run-49
  `handle_fetch` stamping, the Run-43/48/49 + Gate-3 loader/dumper rework
  (datetime form, zoned params, `:binary_id` storage, decimal casts), the Gate-3
  `defp` flip + four deletions, the Run-44..47 rebuild-engine and connect-path
  churn. Composition: one Opus reviewer (6 probes, `b1_cover_r51/`), every probe
  re-driven by the orchestrator on the untouched tree BEFORE any edit (all six
  reproduce: p01-p04 verdicts identical, p05 aborts with `ErlangError :enoent`,
  p06 `defect=true`); fix, pins, docs, and the gate by the orchestrator. Deps:
  db_connection 2.10.2, ecto 3.14.1, ecto_sql 3.14.0, xqlite 0.11.0 (Hex —
  `env -u XQLITE_PATH` on every command, the sibling tree was being edited).

### CONFIRMED

- **F-B1-12 (S2, FIXED, RED→green).** `structure_dump/2` (`lib/xqlite_ecto3.ex`)
  called `System.cmd("sqlite3", …)` with no executable check, so on a machine
  without the `sqlite3` command-line program — the very thing a bundled-SQLite
  library's users do not have — the callback raised a bare `ErlangError :enoent`.
  `Ecto.Adapter.Structure` declares `{:ok, String.t()} | {:error, term}`
  (`deps/ecto_sql/lib/ecto/adapter/structure.ex:21-22`) and `mix ecto.dump`
  (`ecto.dump.ex:91-107`) matches only those arms, so the task died with a
  `System.cmd/3` stack trace that never named `sqlite3`. The reference SQLite
  adapter guards the same shell-out with `System.find_executable/1`
  (`ecto_sqlite3.ex:562-571`), as do ecto_sql's own adapters. Why eleven runs
  missed it: `structure_test.exs` computes `@sqlite3_available` at compile time
  and compiles the dump tests out where the program is absent. Graded S2
  (doc/spec-behaviour divergence with a broken consumer; the reviewer's S1
  argument — "public-API panic" — on record; the damage is a lost diagnosis at a
  development-time task, no write misreported). FIX: `with` over four
  tuple-returning helpers — create the dump directory (`{:error,
  {:cannot_write_dump, path, posix}}`), look the executable up
  (`{:error, {:missing_executable, "sqlite3"}}`), run the literal `sqlite3`
  command (a non-zero exit stays `{:error, output}`), write the file (the same
  `cannot_write_dump` shape). The directory is created before the lookup, so
  the unwritable-path branch is deterministic on every machine. PINS
  (structure_test, outside the CLI-gated block): the missing executable asserted
  per machine (`{:error, {:missing_executable, "sqlite3"}}` where absent,
  `{:ok, path}` where present) and an unwritable dump path
  (`{:error, {:cannot_write_dump, path, :enotdir}}`). Predicted RED = both raise
  `ErlangError :enoent` on this machine — observed exactly. DOCS: README known
  limitations + STE draft (`mix ecto.dump` needs the program; `mix ecto.load`
  does not); CHANGELOG Fixed.

### CLEAN legs (controls named)

- `handle_begin`'s `{:error, exc, state}` arm is consumed by all four consumers
  (db_connection `run_begin` fall-through → `handle_common_result`;
  `transaction/3` raises the exception and KEEPS the connection; the Sandbox
  proxy's generic `{kind, err, state}` clause; `post_checkout/3` maps it to a
  disconnect — inside the sandbox a busy BEGIN at checkout still disconnects,
  ecto_sql's own choice). Control: the same walk found the `{:transaction, _}`
  status form ecto_sql DOES branch on and this driver never produces.
- `Error.wrap/1` total over the Run-46 hook tags (`{:invalid_hook_option, {k, v}}`,
  `{:invalid_hook_config, …}` land on the 2-tuple clause with `type` kept).
- Loaders total: 22 types × 19 hostile stored values = 418 cases, 0 contract
  violations (p02); the two dump failures are Ecto's own usec-precision raise.
  Control: six known-good pairs read legal.
- The Gate-3 `defp` flip and the four deletions touch none of the 18
  `Ecto.Adapters.SQL.Connection` callbacks ecto_sql calls by name. Control: the
  same grep found `insert` at two arities (7 and 8), both covered.
- Constraint names: expression index, WITHOUT ROWID composite PK, rowid PK,
  unnamed CHECK all emit a binary (p03; `named_or_empty/2` makes nil impossible).
  Control: a named unique index emitted its name.
- Raw params without an Ecto type ahead: 19 terms + an `insert_all` placeholder
  all `{:ok, _}` / `%XqliteEcto3.Error{}` / a named exception (p04). Two
  behaviours noted, not defects: a charlist binds as JSON text (list = array);
  a `Decimal` binds as a number under the precision guard.
- `:binary_id` insert-vs-reload consistent under both storages (p01; the legs
  differ in `typeof(id)`, so the probe distinguishes them).
- `query_many/4` raising = the reference adapter's behaviour (not filed);
  `handle_status` `{:error, state}` is inside the spec and no consumer diverges;
  a mid-stream disconnect never reaches the driver's `handle_deallocate` on a
  dead pool_ref (Holder source; live reproduction not reached);
  `enum_check/3` / `array_check/2` emit NAMED constraints; the 11-command DDL
  census returns legal `{:ok, log}` shapes (the MODIFY refusal is a designed
  pre-flight raise naming the alternative).

### Handoffs

- **[B1-1] widened:** `structure_load/2`'s `{:ok, conn} = XqliteNIF.open` and
  its prose-string errors (pinned by text in structure_test.exs:106).
- **[F-B1-13-seed] (S3):** the Sandbox's unreachable `{:transaction, _}`
  diagnostic — maintainer's call.
- **[F-B1-11-docs] addendum:** the observed value `[check: "v > 0"]`.
- **Re-wet list grows:** a db_connection bump (the begin arm rides an
  undocumented fall-through); `structure_dump/2`/`structure_load/2`;
  `DataType.column_type/2` (raises `UnsupportedTypeError`, reached from two
  query sites — next-pass seed).
- **Announcement honesty:** `mix ecto.dump` depends on the `sqlite3` program —
  recorded in the honesty ledger; README states it.

### Gate honesty

- Stash-RED (lib/xqlite_ecto3.ex stashed, structure_test run): predicted 2 reds
  by identity → 2/2 (missing executable, unwritable path); green 4/4 after pop.
  Behaviour sweep over test/ (titles included): the only other
  `structure_dump` sites are the CLI-gated content tests and the round-trip,
  unchanged. sobelow: the shell-out keeps the literal command; the file
  traversal skips moved onto the two helpers that do the file work.
- Dryness: **B1 stays 0 of 2, NOT DRY**; THIRTY-ONE straight finding runs;
  DRY = B10 alone.
- `mix verify` GREEN (exit file 0 — format, compile, deps.audit, sobelow,
  dialyzer, the full sequential suite; `env -u XQLITE_PATH`, Hex xqlite 0.11.0).

---

## Run 52 — 2026-09-05 — lap 7, batch 3: B6 solo (translation cover over the Runs 44-51 + Gate-3 churn)

- Commit at scan: `4afde08` (HEAD, clean, verify + CI green). Scope: B6 solo.
  Churn attacked: `3bfa1c9..4afde08` (33 commits): the Run-48/49 datetime storage
  form + zoned-param shift (query.ex), the Run-44 constraint moves, the Run-45
  typename-gate rewrite (data_type.ex), the Run-47 refusals, the Gate-3 `defp`
  flip + four deletions and the comment scrub (connection.ex). Composition: one
  Opus reviewer (14 probes, `b6_cover_r52/`); every probe re-driven by the
  orchestrator on the untouched tree BEFORE any edit (12 of 12 runnable probes
  reproduce; p05 aborts by design on Ecto's own uneven-rows ArgumentError); fixes,
  pins, docs, and the gate by the orchestrator. Deps: ecto 3.14.1, ecto_sql
  3.14.0, db_connection 2.10.2, xqlite 0.11.0 (Hex).

### CONFIRMED

- **F-B6-11 (S1, FIXED, RED→green).** `expr({:datetime_add, …})` (connection.ex)
  still rendered `strftime('%Y-%m-%dT%H:%M:%f000Z', …)` after `0c94064` moved
  datetime storage to SQLite's own space-separated, designator-less text. SQLite
  compares text byte-wise and offset 10 holds `T` (0x54) in the computed value and
  a space (0x20) in every stored one, so every stored datetime sorted BELOW any
  same-day interval result: `where: e.at > datetime_add(^t, -1, "hour")` returned
  `[]` against a 12:30 row for a 12:00 bound on usec, second-precision, and utc
  columns (p02/p03), while the plain-parameter sibling and SQLite's own
  `datetime(?, '-1 hour')` both found it. `ago/2` and `from_now/2` share the
  clause. The reviewer graded it S0-by-the-letter with an S1 floor; graded S1
  here (silent wrong rows on a read path; no write misreported). Why CI was
  green: the shared suite's `interval.exs` `datetime_add` tests sit behind the
  over-broad `:microsecond_precision` exclusion ([F-B2-8]). FIX: the format is
  `%Y-%m-%d %H:%M:%f000` (six fractional digits — exact for `_usec` columns and
  for every strict comparison on second-precision columns; the exact-equality
  boundary on a second-precision column is the documented residual
  [F-B6-11-residual], p14's fix-shape table on record); the undocumented
  `:datetime_type` application-environment branch (one reference, no test, no
  doc, itself wrong post-churn) deleted. DOCS: README datetime bullet + STE
  (interval arithmetic targets the built-in types' form; `TimestampTZ` keeps its
  own offset-carrying form and is not targeted). PINS: datetime_add_form_test —
  emission (`%Y-%m-%d %H:%M:%f000`, no `T%H`, no `Z'`) + rows on the three column
  kinds + SQLite's own `datetime()` as the in-file control. Predicted RED = the
  emission assertion and the three `[]` row results — observed exactly.
- **F-B6-12 (S1, FIXED, RED→green).** The generic `Tagged` clause rendered
  `type(^v, :binary)` as `CAST(?1 AS BLOB)`; xqlite binds a valid-UTF-8 binary as
  TEXT and SQLite never equates TEXT with BLOB, so the predicate matched nothing
  (p08: plain parameter `[1]`, tagged `[]`; raw `CAST(? AS BLOB)` `[]` vs bare
  `[[1],[2]]`), across BLOB-declared, TEXT, and `:jsonb`-aliased columns (p06);
  the inline-literal clause beside it casts the OTHER way on purpose. Refutation
  ("the user asked for a BLOB cast") failed: `type/2` is Ecto's well-typing API,
  not a storage-class request, and `insert_all` placeholders store the same value
  as TEXT. FIX: a bare-parameter clause for tagged `:binary` (the parameter's
  bound storage class already matches both stored forms). PINS:
  typed_binary_param_test — emission refutes `AS BLOB`; the UTF-8 row and the
  raw-bytes row both found. Predicted RED = the emission assertion + the UTF-8
  `[]` — observed exactly.
- **F-B6-13 (S3, FIXED, RED→green).** `values_list/3` spliced the field atom
  unquoted into `column1 AS <atom>`: `:order` raised a raw `%Error{type:
  :sqlite_failure}` ("near \"order\"") and an injection-shaped atom reached the
  statement body (p07; the reference adapter has the identical splice; Postgres
  emits no alias names at all). FIX: `quote_name/1` on the alias. One existing
  emission pin flipped (delete_with_join_test: `column1 AS "visits"`). PINS:
  values_alias_quoting_test — emission contains `AS "order"`; the row selects.
  Predicted RED = the unquoted alias + the raised error — observed exactly.

### CLEAN legs (controls named)

- Storage-form census: typed path, raw path, `CURRENT_TIMESTAMP` all agree on the
  space form (p01/p03/p13); the raw-path `Etc/UTC` shift is correct
  (Europe/Sofia 14:30+03 → 11:30 stored, p13).
- `type/2` in where / order_by / group_by / having / select_merge and
  `insert_all` placeholders (p04, p08 leg E); `type(^big, :decimal)` finds the
  2^53+1 row via `CAST(? AS NUMERIC)`.
- The `CAST AS NUMERIC` neighbourhood matches SQLite exactly (`sum` over TEXT →
  REAL 9.0; over the NUMERIC column integer-exact) — raw ground truth (p04).
- json_default writer bytes = rebuild-predictor bytes on 8 adversarial shapes;
  rebuild `:ok`, values unchanged (p11).
- The 79edea9 typename gate vs live SQLite over 46 spellings: never accepts what
  SQLite refuses; its 22 refusals are the closed F-B6-9 conservatism (p09). The
  semantic alias table + `:float` NUMERIC round-trip hold (p09/p10; documented).
- The Gate-3 deletions genuinely dead: `insert_all` from a query, upsert, CTE and
  subquery aliases, subquery LIMIT, windows, RETURNING all translate; the `lock:`
  refusal byte-stable since before the gate — [F-B2-36-seed] stays settled (p12).
- Custom types (`TimestampTZ`/`Instant`/`Duration`) through `type/2` and
  comparisons; `fragment("datetime(?)", …)` matches (p13). The comment scrub is
  comment-only in lib/ (census).

### Handoffs

- **[F-B4-seed-dead-shift-fallback] (S3, B4):** the `{:error, _} ->
  DateTime.to_iso8601(dt)` branch in `encode_param(%DateTime{})` is unreachable
  (shifting to `Etc/UTC` needs no tz database — measured) and would store a THIRD
  text form if it ever fired.
- **[F-B2-8] addendum:** the over-broad tag is how an S1 shipped past CI.
- **[F-B6-11-residual] (S3):** the second-precision equality boundary; remedy
  candidates on record (operand-precision format; `.000000` trim).
- Re-wet list grows: `datetime_add`/`date_add`/`interval/3`, the Tagged `:binary`
  clauses, `values_list/3`, the storage form in query.ex.

### Gate honesty

- Stash-RED (connection.ex stashed; the three new files run): predicted 8 reds by
  identity → 8/8 (4 + 2 + 2); green 10/10 after pop. Behaviour sweep over test/,
  lib/, README, guides for the old format, `AS BLOB`, the unquoted alias, and the
  dead env key: ONE pin flipped (delete_with_join's emission string) — predicted
  and observed 1/1. The first emission pin needed a `select:` (the planner's
  `select/2` has no clause for a bare struct select through the test's `to_sql`
  helper) — a test-shape fix, not a behaviour change.
- Dryness: two S1 + one S3 — **B6 stays 0 of 2, NOT DRY**; THIRTY-TWO straight
  finding runs; DRY = B10 alone.
- `mix verify` GREEN (exit file 0 — format, compile, deps.audit, sobelow,
  dialyzer, the full sequential suite; `env -u XQLITE_PATH`, Hex xqlite 0.11.0).

---

## Run 53 — 2026-09-05 — lap 7, batch 4: B5 solo (constraint mapping over the Runs 45-52 churn)

- Commit at scan: `8a3ec75` (HEAD, clean, verify + CI green). Scope: B5 solo.
  Step-0 over `d7fbf80..8a3ec75` (34 commits): `unique_index_names.ex` byte-
  identical; `fk_diagnostics.ex` +23/−12 with no logic (a moduledoc cost
  paragraph, one telemetry key); the one on-axis clause = `25b0b0d`'s
  `:constraint_rowid` → unique-name mapping; the Gate-3 `defp` flip and the
  comment scrub touch nothing on the constraint path (every test-driven public
  still exported). Composition: one Opus reviewer (9 probes, `b5_cover_r53/`,
  every probe under BOTH `rich_fk_diagnostics` configs); the five finding and
  control probes re-driven by the orchestrator on the untouched tree BEFORE any
  edit (all reproduce); fixes, pins, docs, and the gate by the orchestrator.

### CONFIRMED

- **F-B5-33 (S2, FIXED, RED→green).** Run 44's baseline diff (`cap_rows/2`
  rejecting post-replay `foreign_key_check` rows present before the replay)
  identifies a row by `[child_table, child_rowid, parent_table, fk_id]`. A
  `WITHOUT ROWID` child table reports EVERY violation with `child_rowid: nil`,
  so one pre-existing orphan there masks all later violations of that table
  for good; `INSERT OR REPLACE` at an orphan's rowid reproduces the orphan's
  row exactly. Both diagnoses came back `fk_diagnostics: :ok` with
  `fk_violations: []` — a confident empty answer for a statement that had just
  raised `SQLITE_CONSTRAINT_FOREIGNKEY` — so `to_constraints/2` emitted `[]` and
  a declared `foreign_key_constraint/3` raised instead of converting (p02:
  `wr_control_n=1 wr_masked_n=0 rowid_control_n=1 rowid_reuse_n=0`, both
  statuses `:ok`; the single-variable controls are the same statements against
  an empty baseline / a different rowid). Reachability = F-B5-27's (orphans
  from `foreign_keys: false`, foreign writers, a raw pragma). S2: the error is
  still raised, but misclassified for the changeset layer and contrary to the
  flag's documented promise — the mirror image of F-B5-27 (over-reporting),
  which this fix created. FIX (the honest degrade): when the diff is empty but
  the post-replay check is not, the replay reports `{:unavailable,
  :masked_by_baseline}`; a genuinely empty post-replay check (the violation
  fixed before the replay) stays `:ok, []`. The fuller remedy (diff by
  `{child_table, fk_id}` group counts, which recovers the WITHOUT ROWID case
  but not rowid reuse) is filed as the follow-up. Moduledoc step 4 rewritten.
  PINS (fk_diagnostics_test): the WITHOUT ROWID mask and the reused rowid, both
  asserting the structured status. Predicted RED = `:ok` on both — observed.
- **F-B5-34 (S2, FIXED, RED→green).** A `COMMIT` issued through `Repo.query`
  never reaches `handle_commit/2`; it goes through `handle_execute/4`, so a
  deferred violation surfacing there was wrapped by `wrap_with_replay/4` —
  which replayed the literal `"COMMIT"` under a savepoint (it fails again, so
  the diagnosis is `{:unavailable, …}` with no names) and whose `cleanup/1`
  then ran `PRAGMA defer_foreign_keys = false` on the caller's STILL-OPEN
  transaction (SQLite keeps it open after a failed commit), changing the
  semantics of every later statement in it (p04: `defer_before [[1]] →
  defer_after [[0]]` under rich diagnostics; `[[1]]` under the default and
  after a successful commit; `txn_open: true`; the caller's row intact). The
  managed path (`Repo.transaction` → `handle_commit`) diagnoses the same
  violation in place with the name (p03 leg A vs D). S2: doc-behaviour
  divergence ("never masks or replaces the error it is diagnosing"; the reset
  documented as protecting an OUTER transaction, not as overwriting the
  caller's setting) on a path the driver deliberately supports (raw transaction
  control has its own keyword sync). FIX: `wrap_execute_error/4` routes
  transaction-control statements (`leading_keyword/1` ∈ COMMIT / END / RELEASE)
  to `wrap_at_commit/2` — the violating rows are still present, no replay, no
  pragma touched. PIN (fk_diagnostics_test): raw `BEGIN` → `PRAGMA
  defer_foreign_keys = 1` → deferred violation → raw `COMMIT` asserts
  `fk_diagnostics: :ok` + the child's `FkViolation` + the pragma still `1`.
  Predicted RED = `{:unavailable, …}` and `[[0]]` — observed.

### CLEAN legs (controls named)

- The `:constraint_rowid` clause's inputs at HEAD under the 0.11.0 dep: an
  explicit duplicate rowid (empty details) degrades to `[]`; IPK-named-`id`
  and WITHOUT ROWID collisions derive their names; FTS5's bare "constraint
  failed" still `[]` — `named_or_empty/2` nil-total (p05, both configs).
- `insert_all` + `on_conflict` against partial and expression unique indexes:
  SQLite's own "ON CONFLICT clause does not match any PRIMARY KEY or UNIQUE
  constraint" — engine parity (an ordinary unique index succeeds; Ecto's
  `{:unsafe_fragment, "(a) WHERE b IS NULL"}` succeeds; raw SQL fails and
  succeeds identically) (p01). Docs candidate noted: nothing points partial-
  index upserts at the fragment form.
- The commit path's cap (30 deferred violations → 24 + `{:truncated, 30}`) and
  name resolution (p03).
- A dangling FK definition elsewhere does not break the diagnosis (p08 —
  refuted as a "one broken schema disables diagnostics" candidate).
- `Ecto.Multi` under `ON CONFLICT ROLLBACK`: the changeset with
  `constraint: :unique` returns, the earlier step is not committed, the
  connection disconnects at the point of damage, the repo stays usable (p06/
  p09); sharpens [F-B5-17] (names DO reach a changeset through Multi and
  outside a transaction; only the bare-function body loses them).
- The moduledoc's cost claim honest: 17.6-21.2 ms vs 0.05-0.12 ms at 100k child
  rows on the error path only, behind the opt-in flag (p07).

### Handoffs

- **[F-B5-33-followup] (S3):** the group-count diff as the fuller remedy;
  probe the documented re-break case after the degrade (now `:masked_by_baseline`).
- **[F-B5-15]** reproduces unchanged (two names for one violation across
  execute/stream); the streamed error now carries `statement` (Run 49's
  stamping reached it — the [F-X1-7] nil is gone for this shape).
- **[F-B5-27-commit]** reproduces exactly (contamination at commit); NEW
  cross-court: the commit path leaves `statement: nil` (`wrap_commit_error/2`
  never stamps) — X1's court.
- **[F-B5-17]** sharpened (Multi + outside-transaction carry the names).
- `unique_index_lookup` stays `:not_run` for PK/rowid subtypes — designed.
- Status-shape contract (seed 6): the outer sets are typespec-pinned; the six
  adapter-produced `{:unavailable, reason}` literals are not — a closed-set pin
  is now cheap ([F-B5-7]'s want).

### Gate honesty

- Stash-RED (fk_diagnostics.ex + driver.ex stashed): predicted 3 reds by
  identity → see the line below; green after pop. Behaviour sweep over test/
  (titles included) for the empty-diff / re-break / raw-commit shapes: none
  pinned the old behaviour (the "violation fixed before the replay" test keeps
  `:ok` by design). The failing-baseline-scan status is the one source-derived
  claim in the run (the reviewer could not construct it live).
- Dryness: two S2 — **B5 stays 0 of 2, NOT DRY**; THIRTY-THREE straight
  finding runs; DRY = B10 alone.
- Stash-RED result: 3/3 by identity (the two masked-baseline pins and the raw
  COMMIT pin); green 18/18 after pop. `mix verify` GREEN (exit file 0 — format,
  compile, deps.audit, sobelow, dialyzer, the full sequential suite;
  `env -u XQLITE_PATH`, Hex xqlite 0.11.0). README + STE state the masked status
  and the in-place commit diagnosis.

---

## Run 54 — 2026-09-05 — lap 7, batch 5: B7 solo (migration ergonomics over the Runs 46-53 + Gate-3 churn)

- Commit at scan: `8a6a4c1` (HEAD, clean, verify + CI green). Scope: B7 solo.
  **Orchestrator error on record:** the brief told the reviewer the rebuild
  engine was "byte-identical except comments" since Run 45 — read off a per-file
  diffstat, not the diff. `0c94064` (Run 48's datetime commit, +118 lines in
  `lib/xqlite_ecto3.ex`) rewrote the affinity pre-flight's numeric half: a
  rowid-paired TEMP-table "pour" replacing the CAST predicate, plus a new
  `copy_rewritten_count!`. The reviewer caught it at step 0; three of four
  findings live in that helper. Lesson folded into the consequence probe: a
  fix's churn is read as a diff, never as a stat. Composition: one Opus reviewer
  (14 probes, `b7_cover_r54/`, report also on disk); the six finding and control
  probes re-driven by the orchestrator on the untouched tree BEFORE any edit (all
  reproduce); fix note written before implementation; an Opus implementer with a
  RED-first brief; the consequence probe executed (callers, hits, every rebuild
  test file, the Sandbox-backed suites); gate by the orchestrator.

### CONFIRMED

- **F-B7-53 (S1, FIXED, RED→green).** The pour paired scratch rows to the source
  table on `rowid` (`INSERT … SELECT rowid, col` / `JOIN … ON t.rowid = p.r`). A
  user column named `rowid` shadows the row id in both statements; with NULLs in
  it the join matched nothing, the count was 0, and the migration reported
  success while the copy rewrote '007' → 7 and '0012' → 12 (p05; `ROWID` too,
  p09; `_rowid_`/`oid` refuse). Controls: the same table with the column named
  `rid`, and the same column with distinct non-NULL values, both refuse.
  `rowid_copy_needed?/3` and `rebuild_verification.ex`'s `shadowed_rowid?/2`
  already guarded the identical hazard. S1 by the axis's own precedent (a
  rebuild that silently changes stored values). FIX: the join-free scratch
  table below. PIN: rebuild_affinity_guard_test "a column named rowid does not
  blind the guard" (rows `[["text","007"],["text","0012"]]` and declared `TEXT`
  after the refusal; `ROWID` spelling; the `rid` control). Predicted RED = the
  alter returns `{:ok, []}` and the rows read integers — observed.
- **F-B7-55 (S2, FIXED, RED→green).** The pour's four statements ran as
  separate `Ecto.Adapters.SQL.query!` calls before `on_one_connection/4`; TEMP
  tables are per connection, so with pool_size 3, WAL, no wrapping transaction
  and another process holding a connection, 10/10 rebuilds failed with
  `%XqliteEcto3.Error{}` "no such table: xqlite_affinity_probe_…" and each left
  an empty scratch table on a pool member (p12: five leaked across the pool;
  p13: pool_size 1 clean; p03: a single process cannot force the hop — another
  process holding a connection is what forces it). S2: the un-wrapped rebuild is
  a documented, supported path, the failure is loud, typed, pre-destructive, and
  blames an internal table; the leak is connection-scoped. FIX: the probe runs
  inside `on_one_connection(meta, true, …)` (a `checkout`, re-entrant under a
  transaction and under the Sandbox — confirmed from ecto_sql source and by the
  Sandbox-backed suites), the DROP in an `after`. PIN: "under a pool of several
  connections refuses on one connection and strands no scratch table" (pool 3,
  WAL, a DEFERRED parked transaction — an immediate one would hold the write
  lock; ArgumentError not XqliteEcto3.Error; `sqlite_temp_schema` count 0 on the
  current connection, on both other pool members checked out concurrently, and
  on the parked one; a clean table rebuilds `{:ok, []}`). Predicted RED = the
  XqliteEcto3.Error — observed. Re-run at three seeds, stable.
- **F-B7-54 (S3, FIXED).** The `%{without_rowid: true}` clause was dead
  (`refuse_unpreservable_constraints!` refuses WITHOUT ROWID first, p08 07b) and
  its comment documented a never-exercised safety. Deleted with the rewrite;
  `storage` dropped from `refuse_affinity_rewrites_on_populated!`,
  `refuse_affinity_rewrite!`, `rewritten_count` (now carries `type` +
  `modify_opts` instead). PIN: the WITHOUT ROWID refusal ordering.
- **The rewrite:** `CREATE TEMP TABLE <probe> (raw, v <target>)` where `target`
  is `column_type(type, modify_opts)` — the exact type text the rebuild's CREATE
  will use, not a fixed NUMERIC; `INSERT INTO <probe> SELECT col, col`; count the
  pairs whose rendered text differs and that are not two numbers of equal value
  (typeof on both sides). `raw` has no declared type, so BLOB affinity keeps
  every value as stored. Boundary pins: an empty table passes, an all-NULL
  column passes, a column needing quoting refuses on '007' and passes on '7'.
- **F-B7-56 (S3, FILED).** Same-block `null: false` over existing NULLs fails
  mid-dance naming `holes__xqlite_new` (p01; SQLite's own copy fails
  identically; the table byte-identical after). Design choice filed (map
  transient names back vs a per-value pre-flight — one decision for the
  mid-dance failure family).

### CLEAN legs (controls named)

- The blanking property widened (seed 4): 180 generated CREATEs × COLLATE /
  DEFERRABLE / ON CONFLICT tokens × 5 casings × 9 placements — 20 real
  constructs refused naming their own family, 160 data-only cases rebuilt with
  the new NOT NULL present and the row intact; 0/0/0 (p10). The F-B7-48
  regression: columns named check/collate rebuild (p09).
- Datetimes byte-exact through the copy on all three text forms (p07);
  `:binary_id` under both storages incl. a self-referencing FK and no phantom
  `sqlite_sequence` row; flipping to `:binary` re-declares BLOB without
  transforming stored TEXT (p06); a raising `column_type/2` is pre-destructive
  with no transient table left (p07); quoted/case-varied/spaced parent names
  refuse with the child named and pass once emptied (p04); `sqlite_sequence`
  beside a sibling intact — seed 7's literal premise is void, SQLite forbids
  case-only twins (p04); a concurrent reader and writer during a 24 ms dance at
  pool_size 3 under WAL: reader never partial, the writer's row survives (p11);
  rebuild-batched `add` with a default = SQLite's own ADD COLUMN materialization
  (p09); the opt-in flag refuses (p09, after a harness bug in p08's row 01 was
  corrected); the 14 refusal flavours name the right reason (p08/p14; flavour
  14, the TEMP-trigger branch, not reachable by ordinary input — not observed).

### Handoffs

- [F-B7-57-docs] (S3): two message warts (`refuse_unknown_column!` omits the
  table; "them" without antecedent) + the guide line on `modify` restating the
  declared width + down restoring `NUMERIC` for a raw `REAL` (F-B6-4's reach).
- `structure_dump`/`structure_load` of a rebuilt table: not reached (needs the
  `sqlite3` program). Next-pass seeds recorded in the axis block.

### Gate honesty

- Consequence probe (the new step): callers of the four changed functions — nine
  hits, all in `lib/xqlite_ecto3.ex`, all updated, none in tests;
  `xqlite_affinity_probe`/`without_rowid` hits enumerated and each still holds
  (`storage` stays live for `refuse_virtual_table!` and the unpreservable
  refusal); every test file naming the rebuild flag run individually (25 / 2 /
  64 / 7 / 15 passed); the Sandbox-backed suites green — the pre-flight's new
  checkout is re-entrant under the Sandbox in practice.
- Stash-RED (lib/xqlite_ecto3.ex stashed): predicted 2 reds by identity (the
  rowid pin, the pool pin) → 2/2; the three unchanged-behaviour pins green
  either way; green 15/15 after pop. Docs sweep: no README or guide text
  describes the probe mechanism. Comment lines in lib: −14/+6.
- Dryness: an S1 + an S2 + two S3 — **B7 stays 0 of 2, NOT DRY**; THIRTY-FOUR
  straight finding runs; DRY = B10 alone.
- `mix verify` GREEN (exit file 0 — format, compile, deps.audit, sobelow,
  dialyzer, the full sequential suite; `env -u XQLITE_PATH`, Hex xqlite 0.11.0).

### Run 54 addendum — the push's CI red (macOS timing), fixed same session

`3f1126f`'s CI came back RED on one cell (macos-latest, 1.19, OTP 28;
run 33964676176, job 101302619926): the vendored sandbox.exs:174 test
AND migrator.exs:118 ("broken link migration"), both "no matching
message after 100ms" — the slow-macOS class, FOURTH event
(sandbox.exs:174 in every one; the migrator test new). Unrelated to
Run 54's change: the other eleven macOS cells green, neither test
touches the rebuild. The Run-47 rule said exclude-with-rationale at
the fourth event; DISPOSITION REVISED at execution — test_helper now
sets `assert_receive_timeout: 2_000` suite-wide instead. Reasons: our
own tests carry explicit windows (27 sites, zero on the default), so
only the vendored suite feels it; both tests keep running on every
platform; the next member of the class (any default-window
`assert_receive` in the 16 vendored files) is covered without another
exclusion; a green test never waits. The upstream report (explicit
windows on both tests, as sandbox.exs:188 already does) is WRITTEN in
the review-ledgers workdir (`xqlite_ecto3/upstream_reports/`), NOT
filed. B2's exclusion census unchanged (440/26).

---
