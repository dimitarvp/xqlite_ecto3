# Backlog — xqlite_ecto3 (review program)

Severity per the ratified bar in `xqlite/REVIEW_AXES.md`. Nothing
here is ever silently dropped; S3s get a committed closer-look pass
after the S0–S2 burn-down.

## Pre-publish gates (release-readiness, regardless of severity)

- [G1] 21 accidental-public SQL helpers in `Connection` → `defp`
  (verify the zero-external-caller claim per function first;
  includes the `insert_all/1,2` name-confusion hazard). (wave-1)
- [G2] ECTO_INTEGRATION_TAGS.md reconciliation. DONE in Run 4: header
  fixed (SQLite 3.53.2, 16/18) and the two vague rows thickened to
  "supported" after the two-tag probe (P1). REMAINING: drop the orphaned
  `:concurrent_poolrepo_transactions` row; rewrite the stale
  `:foreign_key_constraint` row (rich FK diagnostics shipped, tag
  un-excluded). (wave-1)
- [G3] Elixir floor: `~> 1.15` claimed, CI floor 1.17 — add lanes
  or raise the floor (floor-raise = Dimi values call; identical gap
  in xqlite). (wave-1)
- [G5] CLAUDE.md bootstrap (content list inventoried in
  `~/kod/fleet_review_staging/recon/recon_adapter_distilled.md`).

## Probes (orchestrator-run)

- [P1] RESOLVED (Run 4). Isolated both tags: `:values_list` ⇒ 5 passed
  (incl. `delete_all`), `:transaction_checkout_raises` ⇒ 1 passed. Neither
  is excluded; both quietly pass, so the README "suites run green" claim
  holds and the two `ECTO_INTEGRATION_TAGS.md` rows were STALE — corrected
  to "supported" + header refreshed (3.53.2, 16/18). (B2)
- [B3] RESOLVED (Run 6). Connect-time PRAGMA storm characterized: the PURE
  storm (pool cold-start with no competing lock) is CLEAN — 15 members on a
  fresh non-WAL file all connect and flip `journal_mode=wal` concurrently, 300
  concurrent inserts 300/300 ok, 0 connect errors, ~37 ms, pool healthy (the
  connect-time `busy_timeout` set before the `journal_mode` write absorbs the
  brief WAL-header contention). The sharp edge is a cold-start racing an
  EXTERNALLY held write lock (migrations mid-flight on a fresh non-WAL file) →
  transient `[error]` connect-failure logs, self-healing — see F-B3-2 below.
  Wedged-txn-state symmetry re-confirmed from source: failed begin/commit/
  rollback all return `{:disconnect, …}`, so a wedged transaction is torn down
  and reconnected, never reused (driver.ex handle_begin/commit/rollback). The
  `:memory:` + pool_size guard probe RAN in Run 2 and confirmed a defect — see
  F-B3-1 below.
- [B9] CONFIRMED gap (Run 4): no CI lane flips `:telemetry_enabled`, so
  CI builds/tests only the telemetry-ON config (`config/test.exs` pins it
  ON); the OFF path (production default) is untested in CI — it compiles
  clean locally. FIX: add a CI lane (or a `MIX_ENV=dev mix compile
  --warnings-as-errors` + a small OFF-flag test run) covering the OFF
  build.

## Open (S3 — tracked, never dropped)

- [F-B10-1] (S3) The `bench/` project does not compile/run. `bench/mix.exs`
  pins `ecto_sql ~> 3.13.0` (stale lock 3.13.5) while the adapter now
  requires `~> 3.14` and uses `Ecto.Migration.Table.:modifiers` (a 3.14
  struct field), so `MIX_ENV=prod mix compile` in `bench/` fails at
  `connection.ex:2112` — "unknown key :modifiers for struct
  Ecto.Migration.Table." The mix.exs comment blaming ecto_sql 3.14's
  `insert/8` is stale (the adapter migrated to `~> 3.14`). Methodology is
  otherwise honest (pinned-identical pragmas, disclosed SQLite versions,
  cancellation-as-demo, ledger-first, write+read scenarios) but NO figure
  is reproducible from a clean checkout until this is fixed. FIX: bump the
  bench to `ecto_sql ~> 3.14` + `ecto_sqlite3 ~> 0.24` and refresh
  `bench/mix.lock` (needs Hex); drop the stale insert/8 comment. Blocks any
  announcement perf claim. (Run 4, B10)
- [F-B8-1] (S3) Operation `:timeout` does not interrupt a lock-contended
  write — `busy_timeout` dominates. Two handles on one file: A holds
  `BEGIN IMMEDIATE`, B (`busy_timeout: 3000`) INSERTs with a 300 ms cancel
  token → `{:error, {:database_busy_or_locked, 5, …}}` after **3005 ms**,
  not 300 ms. SQLite's progress handler (which polls the cancel token) is
  not called while blocked in the busy-wait, so the token fires only once
  stepping resumes. Bounded by `busy_timeout` (adapter default 5000 ms) —
  the flagship promptness guarantee covers CPU-bound execution, not lock
  waits. Could be argued S2 (headline-behaviour divergence); filed S3 as
  bounded + doc-remedy. Options: document prominently; lower the default
  `busy_timeout`; or (xqlite change) a busy handler that polls the token.
  (Run 3, B8)
- [F-B8-2] (S3) The streaming path ignores `:timeout`.
  `handle_declare`/`handle_fetch` create no cancel token, and xqlite 0.10.0
  exposes no cancellable `stream_fetch` (only `stream_fetch/2`). A
  `Repo.stream(slow_query, …)` under `run(timeout: 200)` ran the whole
  recursive CTE to completion (**3503 ms**, returned `[[10000000]]`);
  DBConnection's deadline logged a disconnect at 200 ms but could not
  interrupt the blocked dirty NIF. Cross-repo (X2): a fix needs an xqlite
  `stream_fetch_cancellable` first, then wire a per-fetch token like
  `execute_with_cancel`. Interim: document that stream batches are
  uncancellable and to keep `max_rows` modest. (Run 3, B8)

- [F-B3-2] (S3) Cold-start WAL-flip race emits `[error]`-level connect-failure
  logs. On the FIRST cold-start of a fresh, never-WAL database, every pool
  member's connect sequence runs `PRAGMA journal_mode = wal` (a write needing an
  exclusive lock). If a write lock is concurrently held longer than the
  connect-time `busy_timeout` (a migration running at app boot, common), each
  member's flip fails and DBConnection logs `[error] XqliteEcto3.Driver (…)
  failed to connect: {:database_busy_or_locked, 5, "database is locked"}`, then
  retries with backoff. Repro (Run 6): fresh non-WAL file, one raw connection
  holds `BEGIN IMMEDIATE` for 2000 ms, pool_size 6, `busy_timeout: 300` → a burst
  of 6+ `[error]` connect-failure lines at boot; ALL queries still succeed once
  the lock releases; pool ends healthy; WAL persists so later boots are clean.
  SELF-HEALING and no query-path impact (query callers never see an error), but
  the `[error]` burst can alarm operators / trip error-rate alerts and is
  UNDOCUMENTED. The pure storm (no competing lock) does NOT reproduce it (15
  members flip WAL concurrently with 0 errors). The test suite already pre-sets
  WAL for exactly this reason (`test/test_helper.exs` comment). Options (maintainer
  call): (a) document — run migrations before starting the app pool, or pre-set
  `journal_mode=wal` once, or raise the connect `busy_timeout`; note the transient
  connect noise is harmless; (b) skip the `journal_mode` write when the file is
  already WAL (helps reconnects, not the first cold-start). Evidence:
  scratchpad `b3_connect_storm.exs` / `b3_connect_vs_lock.exs` / `b3_boot_noise.exs`.
  (Run 6, B3)
- [F-B3-1] No guard on private-`:memory:` + a multi-connection pool.
  `database: ":memory:"` with NO `pool_size` (Ecto default 10) starts
  cleanly, but each private in-memory connection is a SEPARATE database:
  a `CREATE`/`INSERT` lands on one pooled connection while reads scatter
  across the others. Probe (Run 2): 10 reads of a just-inserted row gave
  9× `{:error, :no_such_table}` + 1× `{:ok, []}` (empty table) + 0× the
  row. Default-reachable and produces a wholly broken repo, but fails
  LOUDLY (`:no_such_table`), and the remedy is a maintainer design call —
  `ecto_sqlite3` raises here; options are (a) raise at `child_spec` when
  the database is `":memory:"`/`""` and `pool_size > 1`, (b) auto-force
  `pool_size: 1`, or (c) document `file::memory:?cache=shared` as the
  shared-pool form. Related: the adapter's advertised `@default_opts`
  `pool_size: 5` is dead — pool sizing is consumed by Ecto before
  `child_spec` merges defaults, so Ecto's default 10 wins. (Run 2, B3)
- [F-B5-1] `to_constraints/2` returns `[foreign_key: nil]` when an FK
  violation has no rich-diagnostics payload (default `rich_fk_diagnostics:
  false`, or a diagnosis that finds no rows). `nil` is not a valid
  constraint name: with the default `match: :exact` it never matches a
  user `foreign_key_constraint/3` (→ `Ecto.ConstraintError` with a `nil`
  name — confusing but tolerable), but with `match: :suffix`/`:prefix`
  Ecto's `constraints_to_errors` runs `String.ends_with?(nil, cc)` and
  crashes with a `FunctionClauseError` (verified: `String.ends_with?(nil,
  "x")` raises). Latent (narrow trigger); consider returning `[]` (raw
  error) or synthesizing the `<source>_<field>_fkey` name from
  `options[:source]`. (Run 2, B5)
- [B1-1] `dump_cmd/3` is a required `Ecto.Adapter.Structure` callback
  (no `@optional_callbacks`) but the adapter `raise`s. Unreachable via
  mix tasks (`mix ecto.dump` uses `structure_dump/2`), so harmless —
  but consider a structured `{:error, ...}` or a moduledoc note. Same
  entry: `storage_up/1` MatchErrors on `XqliteNIF.open` failure
  instead of returning `{:error, term}` (near-impossible path). (Run 1)
- [S3] docs `groups_for_modules` lists 3 `@moduledoc false` modules
  (dead config). (wave-1)
- [S3] Untracked `.expert/` root clutter — gitignore or remove
  (Dimi's call). (wave-1)
- [S3] test_helper's `logging.exs:74` exclusion rationale is thin —
  state permanent-vs-trackable. (wave-1)
- [S3] `async: false` ban is honored (0/52) but written down
  nowhere in this repo — codify in the CLAUDE.md bootstrap. (wave-1)

## Feature follow-ups (owed, not review findings)

- [A2] hooks config `:busy` kind + busy-aware concurrency docs —
  unlocked by xqlite 0.9.0's busy split.
- [A3] Optionally migrate raw `XqliteNIF.txn_state/connection_stats`
  doc references to the new `Xqlite` wrappers (additive, optional).

## Closed

- 2026-07-20 [X1-2] (S3) `Error.wrap/1`'s generic `{tag, msg}` clause required
  `is_binary(msg)`, so ~14 `error_reason/0` shapes with a map/int/atom/tuple
  payload fell to the `inspect` catch-all and lost their `type` tag (e.g.
  `{:integral_value_out_of_range, i, i}`, `{:invalid_parameter_count, map}`,
  `{:cannot_open_database, s, i, s}`). RESOLVED by the dryness-pass ruling: FIXED,
  not ratified. House doctrine (CLAUDE.md-level) — "errors must always carry the
  most specific, structured information possible; no swallowing details into
  generic wrappers" — tilts against dropping a KNOWN tag that lives right in the
  union. Added three arity-bounded tag-preserving clauses (2-/3-/4-tuple with an
  atom head) before the atom/inspect fallbacks: `type` is set to the tag, the full
  shape is preserved in the message via `inspect`, `details` stays nil (no
  dedicated struct — consistent with the tag-only-error convention). Bounded to
  arities 2–4 (the union's max) so a genuinely-unknown 6-tuple still inspects with
  `type: nil` (existing catch-all test holds). RED→green in `error_wrap_test.exs`
  (+4: map/atom 2-tuple, int 3-tuple, 4-tuple — structured `.type` assertions).
  The reachable members (`:cannot_open_database` at connect,
  `:integral_value_out_of_range` on bignum insert, `:cannot_execute_pragma` at
  connect) now surface a machine-addressable tag. (Run 5, X1)
- 2026-07-20 [F-B4-1] (S1) A `:decimal` column maps to `DECIMAL` (NUMERIC
  affinity); the encode boundary bound `Decimal.to_string(d, :normal)` as
  TEXT and SQLite coerced it to float64 at write, silently rounding decimals
  beyond float64's exact precision (`12345678901234567890.12345` → REAL
  `1.2345678901234567e19`, loads back unequal). Maintainer ruling (Dimi,
  2026-07-20): LOUD REJECT beyond precision, keep numeric storage so
  ordering/range queries still work. Added
  `XqliteEcto3.DecimalPrecision.representable?/1` (Decimal → float64 →
  shortest round-trip string → Decimal, compared normalized) guarding
  `encode_param/1`; a non-round-tripping Decimal now raises structured
  `XqliteEcto3.DecimalPrecisionError` (carries `:value`) instead of storing a
  rounded number. Typical money (≤15 sig digits, incl. `9999999999999.99`)
  and float-exact large ints still store fine — the guard's accept/reject
  verdict was cross-checked against a real SQLite DECIMAL round-trip and
  agreed for every probed value. Docs flipped from "silently truncated" to
  loud-reject in the moduledoc + `data_type.ex`; the pin test flipped from
  `refute Decimal.equal?` to `assert_raise`. RED→green in
  `types_roundtrip_matrix_test.exs` + `query_encoding_test.exs`; guard table
  in `decimal_precision_test.exs`. (Run 3, B4)
- 2026-07-20 [F-B7-1] (S2) `reference_on_delete/1` handled only the
  whole-key atoms and fell through to `[]` for Ecto's valid column-list
  forms `on_delete: {:nilify, cols}` / `{:default, cols}`, SILENTLY
  dropping the entire `ON DELETE` clause (`CONSTRAINT … REFERENCES
  "parents"("id")` with no action). SQLite has no column-list ON DELETE
  syntax; fixed to raise a loud `ArgumentError` pointing at `:nilify_all`
  / `:default_all`. (`on_update` tuples are Ecto-rejected upstream.)
  RED→green in `migration_test.exs` "reference ON DELETE". (Run 3, B7)
- 2026-07-20 [F-B6-1] (S1) `escape_string/1` doubled backslashes for
  inline SQL string literals (`WHERE`/`LIKE` literals, DDL string
  defaults). SQLite treats `\` as an ordinary character, so `'a\\b'` is a
  4-char value — an inlined `x == "a\b"` silently matched nothing. Fixed
  to escape only the single quote; `escape_json_key/1` keeps its
  backslash+quote escaping locally (JSON-path output byte-identical).
  RED→green in `query_features_test.exs` + `connection_test.exs`. (Run 2, B6)
- 2026-07-20 [F-B6-2] (S2) offset without limit emitted a bare `OFFSET n`,
  which is a SQLite syntax error (`near "OFFSET"`). A legitimate paginating
  query (`from x, offset: 2`) failed to compile. Fixed: `limit/2` emits
  `LIMIT -1` when limit is nil but offset is present. The pre-existing
  "offset without limit" test masked this with `limit: 999`; rewritten to
  the genuine case. RED→green in `query_features_test.exs`. (Run 2, B6)
- 2026-07-20 [F-B6-3] (S2) `quote_entity/1` did not escape an embedded `"`
  in identifiers, so a runtime `fragment("?", identifier(^value))` with a
  crafted value broke out of the quotes and injected SQL
  (`SELECT "x" FROM secrets;--"`). Fixed by doubling `"` → `""` (mirroring
  `FkDiagnostics.quote_ident/1`, which was already correct). RED→green in
  `connection_test.exs`. (Run 2, B6)
- 2026-07-20 [F-X2-1] (S2) statement-cache path leaked sticky
  `sqlite3_changes()` as `num_rows` for columnless non-DML (DDL/
  PRAGMA) statements — fixed via `total_changes`-delta gating in the
  driver, RED→green in `driver_statement_cache_test.exs`. (Run 1)
- 2026-07-20 [F-X1-1] (S3) `wrap/1` `:sqlite_failure` clause dropped
  the type-permitted nil-message variant — fixed, RED→green in
  `error_wrap_test.exs`. (Run 1)
- 2026-07-17 xqlite dep 0.8.0 → 0.9.0 (lock bump, hex-mode verify).
- 2026-07-17 erl_crash.dump: autopsied, dev-noise, stays gitignored.
