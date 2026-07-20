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
