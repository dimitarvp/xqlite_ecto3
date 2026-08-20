# Backlog — xqlite_ecto3 (review program)

Severity per the ratified bar in `xqlite/REVIEW_AXES.md`. Nothing
here is ever silently dropped; S3s get a committed closer-look pass
after the S0–S2 burn-down.

## Pre-publish gates (release-readiness, regardless of severity)

- [G1] 21 accidental-public SQL helpers in `Connection` → `defp`
  (verify the zero-external-caller claim per function first;
  includes the `insert_all/1,2` name-confusion hazard). (wave-1)
- [G2] DONE (Run 4 + Run 8). Run 4: header fixed (SQLite 3.53.2, 16/18)
  and the two vague rows thickened to "supported" after the two-tag probe
  (P1). Run 8: dropped the orphaned `:concurrent_poolrepo_transactions`
  row (not a real shared-suite tag anywhere in `deps/`); rewrote the
  `:foreign_key_constraint` row excluded→supported (un-excluded, `--only
  foreign_key_constraint` ⇒ 6 passed via rich FK diagnostics). (wave-1)
- [G3] DONE (2026-07-21, maintainer ruling: claim-what-you-test).
  Floor raised `~> 1.15` → `~> 1.17` in mix.exs + the README badge,
  matching the CI matrix floor exactly; the identical gap in xqlite
  closed the same way (mix.exs + CHANGELOG note + CLAUDE.md). No new
  lanes — 1.15/1.16 were never exercised and are no longer claimed.
  (wave-1)
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
- [B9] RESOLVED (Run 8). Added the `telemetry_disabled` CI lane
  (`.github/workflows/ci.yml`, free-tier ubuntu-latest): it compiles the
  adapter with the flag off under warnings-as-errors (`MIX_ENV=test mix
  compile --force --warnings-as-errors`) and smoke-runs the no-op path
  (`mix test test/xqlite_ecto3/telemetry_disabled_smoke_test.exs`). Config
  mechanism: `config/test.exs` reads `XQLITE_ECTO3_TELEMETRY` (`off` flips
  only the adapter flag; xqlite's own flag stays on). Both lane commands
  proven locally at exit 0. (Run 4 confirmed the gap; Run 8 closed it.)

## Open (S3 — tracked, never dropped)

- [F-B2-18-adjacent] (S3, B4 court, from Run 30) CLOSED at Run 31's
  gate: all THREE default renderers (plain `default_expr`, rebuild
  `default_spec`, model `rendered_default`) now end in a shared
  structured refusal — `XqliteEcto3.UnsupportedDefaultError` with
  value/reason/column/type (+ cause for encoder failures) — and the
  map clauses are struct-gated. The bitstring-default class, struct
  defaults, non-boolean atoms, non-fragment tuples, and printable
  charlists all refuse structurally now. (Run 30 filed → Run 31
  landed, with F-B4-7/F-B4-8.)
- [F-B8-8-handoff] (S3, B1/B2 court, from Run 32) CLOSED at Run 33's
  gate: adjudicated DOCUMENT. Live-probed — SQLite's ABORT default
  makes a per-statement savepoint a no-op, ON CONFLICT ROLLBACK
  destroys the transaction together with any open savepoint, and the
  one class the wrap would change (ON CONFLICT FAIL + multi-row
  insert_all) needs hand-written DDL; meanwhile the Sandbox injects
  `mode: :savepoint` into every out-of-transaction statement, so
  implementing would wrap essentially all sandboxed traffic for
  nothing. README Known-limitations bullet landed (+ STE draft
  mirror); B2's share verified — the lone upstream test touching the
  option (alter.exs:60) is already excluded for unrelated reasons and
  could not detect inertness anyway; no exclusion change owed.
- [F-B1-5] (S3, B9 court, from Run 33) `handle_deallocate/4` discards
  `NIF.stream_close/1` failures (`_ =`) and returns
  `{:ok, nil, state}` unconditionally, so a failed statement release
  reports success and telemetry records `result_class: :ok`.
  Conservative remedy (do NOT change the return shape — it feeds
  Stream.resource's after-fun): carry the close result into the stop
  event's metadata so failures are at least observable. Touches the
  locked telemetry surface — deliberate B9-court pass, not a
  gate-side edit. (Run 33, B1 → B9)
- [F-B1-menu-connect-error-details] (maintainer menu, from Run 33's
  gate) Connect config-error payloads (unregistered hook subscriber
  NAME, malformed pragma entry, invalid mode atom) now live only in
  the wrapped exception's message (inspect) — the tag-tuple family of
  `Error.wrap/1` is deliberately details-less (error_wrap_test pins
  `details: nil`). Giving that family a structured payload field is a
  designed-shape decision for the whole error surface, not a local
  patch; `cannot_open_database` already got its specific clause
  (path + code in details) as the Run-33 precedent. (Run 33, B1)
- [F-B8-9-docs] (S3, docs, from Run 32) The
  `[:xqlite_ecto3, :disconnect]` event cannot distinguish our cancel
  from DBConnection's own checkout-deadline recycle — both carry
  `reason: %DBConnection.ConnectionError{reason: :error}`
  (DBConnection permits no third reason value). The structured
  correlation path exists: match the `handle_execute` stop event's
  `error_reason: {:disconnect, _}` by `conn`. One line owed in the
  telemetry guide next to the disconnect row. (Run 32, B8 → B9 docs) `fk_diagnostics_test.exs`'s telemetry
  assertion fails under the `XQLITE_ECTO3_TELEMETRY=off` build
  (pre-existing; invisible in CI because the `telemetry_disabled`
  lane runs only the smoke file). Remedy: flag-guard that test the
  way the smoke file does (module-level compile-time check), or
  widen the OFF lane to the full suite minus telemetry-asserting
  files. Not fixed blind — the OFF build sits outside the local
  verify gate. (Run 29, B9)
- [F-B9-14] (S3, from Run 29) `group_fk_rows/1`'s
  `foreign_key_list` row destructures in `fk_diagnostics.ex` still
  lack fallthrough clauses — the same implicit-raise class the
  `foreign_key_check` reader got fixed for at Run 29's gate; an
  unexpected pragma row shape would raise through the diagnostics
  path instead of degrading to `{:unavailable, reason}`. One
  mechanical pass, same convention. (Run 29, B9)
- [F-B7-41-menu] (maintainer menu, from Run 28's gate) Every rebuild
  pre-flight refusal is a bare `ArgumentError` with no structured
  fields, so refusal tests can only assert the exception type plus
  observable state — and several older neighbors regex the message
  prose, against the no-text-assertion doctrine. Menu: a dedicated
  refusal exception struct carrying a reason atom (+ construct/column
  fields), then migrate the prose-matching tests. Until ruled, new
  refusal tests assert type + state only. (Run 28, B7)

- [F-B5-14-fork] (maintainer menu; the S2 itself is FIXED in-run with a
  fixed 500 ms budget when the pragma reports zero). The lookup budget's
  source of truth is still `PRAGMA busy_timeout`, which cannot tell a
  genuine zero timeout from a policy/observer-held slot. Larger designs
  the maintainer may prefer: budget from the caller's remaining checkout
  deadline (touches the cancel-token surface); a per-repo
  `:unique_index_lookup_budget_ms` option; an xqlite API exposing busy
  slot occupancy (cross-repo, same surface as the busy-slot pair). Fold
  in: the FK-diagnostics replay has NO budget at all (F-B5-16) and
  should take whatever lands here. (Run 27, B5)
- [F-B5-15] (S3) Streamed DML (`Ecto.Adapters.SQL.stream/4` with
  `INSERT … RETURNING`) skips unique-index-name resolution: the
  `handle_declare`/`handle_fetch` error branches call `Error.wrap/1`
  alone, so the same violation reports `unique_index_lookup: :ok` +
  the real name through `handle_execute` and `:not_run` + `[]` through
  the stream. Classification stays correct and no changeset traverses
  a stream, hence S3. The false path comment ("a declared query is a
  SELECT and cannot raise a UNIQUE violation") was corrected in-run;
  the behavior decision — pipe `UniqueIndexNames.resolve/2` onto those
  branches vs document the gap — is the maintainer's. (Run 27, B5)
- [F-B5-16] (S3) The rich-FK-diagnostics replay is a WRITE, so it
  contends for WAL's single write lock where the unique lookup's reads
  do not: measured a replay blocking 3,006 ms against a 3,000 ms
  `busy_timeout` on top of the failing statement's own 2,731 ms —
  the opt-in error path costs up to two full busy waits. Cost note
  added to the moduledoc in-run; a budget for the replay folds into
  [F-B5-14-fork]. Cleanup verified clean under contention (no open
  txn, `defer_foreign_keys` reset). (Run 27, B5)
- [F-B5-17] (S3) `wrap_execute_error/4` (FK replay + unique lookup)
  runs BEFORE `disconnect_if_rolled_back/2`, so enrichment work runs
  on a connection the driver may be about to destroy, and under
  `ON CONFLICT ROLLBACK` inside a transaction the recovered names
  never reach a changeset (`Repo.transaction` yields
  `{:error, :rollback}`). Remedy — decide the disconnect first, skip
  enrichment on a doomed connection — interacts with the Run 23/25
  disconnect-at-damage guard; sequence any change with that surface.
  (Run 27, B5)
- [F-B5-18] (S3, config footgun — public gotcha owed) `driver.ex`
  accepts `busy_timeout` unvalidated, and SQLite clamps negatives and
  anything past int32 to 0 at the PRAGMA level: `busy_timeout:
  3_000_000_000` ("wait basically forever") silently means NO busy
  handler at all — and, pre-Run-27, also "no lookup budget". Validate
  the range at connect (structured error) or document the clamp; the
  int32 ceiling belongs in a public gotcha line. `:infinity` and
  non-integer values still unprobed. (Run 27, B5)

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
  `options[:source]`. (Run 2, B5) Sharpened (Run 14): live-driven per
  match mode — `:exact` → `Ecto.ConstraintError` naming nil;
  `:suffix`/`:prefix` → `FunctionClauseError` in
  `String.ends_with?/starts_with?`.
- [F-B5-4] (S3) The unique-index name lookup runs `PRAGMA index_list`
  unqualified, so when the same table name exists in several schemas
  (ATTACH, TEMP) the reported index can belong to the wrong table —
  SQLite resolves temp, then main, then attached. Reachable only via
  raw SQL / with_xqlite (the schema API refuses prefixes). Probes: a
  violation on archive.t reported main's index; a violation on main.sh
  reported the TEMP index. Remedy direction: `SELECT schema FROM
  pragma_table_list WHERE name = ?` detects the ambiguity in one read;
  degrade to the derived name when more than one schema matches.
  (Run 14, B5)
- [F-B5-5] (S3) xqlite's violation-message parse (constraint_parse.rs
  splits columns on ", " and the table on the first ".") mis-parses a
  column name containing ", " — and the lookup then matches the
  mis-parsed column list against real indexes, emitting a
  wrong-but-real name (probe: violating an index over the column
  literally named "a, b" reported the index over (a, b); both
  "columns" are real columns of the table, so a table_xinfo
  cross-check would not catch it). A table name containing "."
  degrades instead (nonexistent-table lookup → derived name).
  Partially unfixable — SQLite's message grammar is ambiguous for such
  names. Crafted-schema reachability. (Run 14, B5)
  Sharpened (Run 18): the escape-law generator independently re-derived
  it (shrunk case: table `esc &, ` → parsed table `""` → `PRAGMA
  index_list("")` finds nothing → the changeset matcher receives a
  derived name built from a nonexistent table). Quoting held on every
  surface; the failure is purely the message split. A remedy sketch if
  ever wanted: when the parsed table does not exist in sqlite_schema,
  degrade the unique-name lookup to `{:unavailable,
  {:unparseable_violation_table, raw}}` instead of running the pragma
  on garbage — honest reporting without touching the parse.
  Sharpened (Run 21): the split is on the FIRST dot only, so table
  `x.y` with column `v` parses as `table: "x", columns: ["y.v"]` — and
  the DERIVED fallback is poisoned too: it emits `x_y.v_index` where
  Ecto's own default for that table is `x.y_v_index`, so even the
  degradation path yields a name no changeset can declare. Also
  re-anchored live on xqlite 0.11.0 (constraint_parse.rs byte-identical
  to 0.10.0).
- [F-B5-7] (S3) `unique_index_lookup: :ok` with `unique_index_names:
  []` cannot distinguish "no named unique index matched" from "the
  pragma saw no rows at all": a stale per-connection schema cache, a
  vanished table, and the CREATE-UNIQUE-INDEX DDL-failure path (the
  index being built does not exist yet) all collapse into the same
  silent derived-name fallback. Reporting gap only; refine the status
  shape when a consumer materializes. (Run 14, B5)
  Sharpened (Run 21): (a) `DROP TABLE` between violation and lookup
  yields `:ok`/`[]` on the FIRST pragma — `PRAGMA index_list` on a
  missing table returns zero rows, not an error — so "table vanished"
  is invisible even without reaching the second pragma; a systematic
  sweep of which pragma failures error vs return empty is seeded for
  the next pass. (b) A registered busy observer converts an F-B5-8
  contention block into a 0.05 ms structured busy failure with the
  same status — documented xqlite behavior, and the one existing
  mitigation for the lookup's residual single-read block.
- [F-B3-4-xqlite] (S2 adapter-facing; xqlite court, from Run 23) A busy
  OBSERVER (`Xqlite.register_busy_observer/2`) replaces the connection's
  one busy slot; with no policy installed the master callback answers
  "give up", so a previously configured `busy_timeout` silently stops
  applying — and UNregistering empties the slot WITHOUT restoring the
  timeout (`sqlite3_busy_handler(conn, None, ...)` leaves busyTimeout
  0). Adapter docs now warn on `with_xqlite/3`; owed on the xqlite
  side: (a) the slot-replacement warning on `register_busy_observer/2`
  itself (its siblings `set_busy_policy/2` and `busy_timeout/2` carry
  it), (b) consider remembering the prior `busy_timeout` at slot
  install and re-applying it when the slot empties, so unregister is a
  true undo. Same busy-slot surface as [F-B5-8-residual] — one
  adversarial lap should cover whichever lands. Knock-on (B5): under an
  observer, `busy_budget/1` reads 0 and the unique-name lookup budget
  collapses — emission turns timing-dependent on such connections.
  (Knock-on resolved by the fixed 500 ms budget; the observer's
  fail-fast behavior itself remains.)
  Addendum (Run 29): the extension-permission flag is the same
  no-restore pattern one facility over —
  `Xqlite.enable_load_extension(conn, true)` has no
  disable-on-scope-exit story upstream either, and the SQL-level
  `load_extension()` it opens stays callable for the connection's
  life. The adapter's `with_xqlite/3` docs now warn; an xqlite-side
  note on `enable_load_extension/2` belongs in the same court batch.
- [F-B9-4] (S3, from Run 23) The unique-index-name lookup runs 1+N
  pragma reads on the caller's connection inside the
  `handle_execute` span with no span of its own, while the sibling
  `fk_diagnostics` replay has one — and the lookup can bill up to a
  full `busy_timeout` (Run 21), invisible to dashboards. Proposed
  shape: `[:xqlite_ecto3, :unique_index_names, :start | :stop |
  :exception]`, start metadata `%{conn, table, columns}`, stop adds
  `%{candidate_count, lookup_status, index_reads}`, standard
  monotonic_time/duration ns. Add the guide row + moduledoc entry with
  it. Decide together with the bridge RawConn checkout's missing
  event.
- [F-B7-27] (S3) A table rebuild drops the table's `sqlite_stat1` rows
  (DROP TABLE deletes them; nothing restores them, and the re-created
  indexes start unanalyzed), so the query planner falls back to built-in
  guesses until the next ANALYZE. Silent; the structural post-check does
  not read statistics. Remedy: either capture and re-insert the rows
  under the re-created names, or document that a rebuild discards
  ANALYZE statistics and suggest re-running ANALYZE — the doc line is
  owed to the Gate-3 docs pass (the STE README drafts must gain it
  too). (Run 22, B7)
  Addendum (Run 28): `sqlite_stat4` rows are dropped too — STAT4 is
  compiled into the bundled SQLite (measured 1 stat1 + 8 stat4 rows
  before a rebuild, 0/0 after), and the stat4 histograms matter more
  for skewed columns. The STE draft's line now names both tables; the
  capture-and-reinsert remedy option must cover both if chosen.
- [F-B7-25-feature] (feature candidate, from Run 22) The rebuild engine
  already reconstructs foreign keys as table-level clauses from
  `foreign_key_list`; merging an added or modified
  `%Ecto.Migration.Reference{}` into that clause list would make
  `modify :col, references(...)` — Ecto's documented FK repoint — work
  on SQLite for the first time. Today it refuses loudly with guidance
  (`refuse_reference_changes!`). (Run 22, B7)
- [F-B5-8-residual] (S3, design fork — the full remedy for the Run 21
  S2) The shipped budget bound caps the lookup's contention cost at
  ~one `busy_timeout`; the residual single blocked read (rollback
  journal + cross-process writer) still bills the caller's checkout
  deadline uncancellably, exactly like a slow statement. Full-remedy
  options, each needing its own adversarial lap before landing:
  (a) keep the driver's cancel token alive across
  `wrap_execute_error/4` so the lookup cancels like the statement
  (touches the B8 token lifecycle); (b) install a short busy handler
  for the lookup's duration and restore after (touches the busy slot
  B3 owns — policy/observer clobber risk); (c) skip the lookup when
  the statement already consumed most of the caller's deadline.
  (Run 21, B5)
- [F-B5-10-structural] (S3) Expression-twin ambiguity: when the
  `index '<name>'` form reports an all-expression index and a plain
  unique index over the same table coexists, both may be violated and
  creation order picked the reported one (Postgres-parity; the
  declare-both-names contract is documented in the moduledoc). The
  structural upgrade — resolve the reported index's table via
  `sqlite_schema`, read `index_info`, and treat all-expression +
  coexisting plain unique as ambiguity → derived fallback with both
  names on the struct — shares its read with F-B5-11 and lands with
  it, if ever. (Run 21, B5)
- [F-B5-11] (S3) On the `index '<name>'` message form the Constraint
  struct carries `table: nil, columns: []` — the index name is the
  only handle and its schema relationship is not machine-readable,
  against the errors-carry-maximum-structure rule. Remedy: one bounded
  error-path read — `SELECT tbl_name FROM sqlite_schema WHERE
  type='index' AND name = ?` fills `table`; `PRAGMA index_info` fills
  the plain-column terms (expression terms stay out). Same cost
  profile as the existing lookup; the same read F-B5-10-structural
  needs. (Run 21, B5)
- [UUID-case] (maintainer menu, from Run 19) The three shipped UUID
  paths have three different case behaviors: `Types.UUID` normalizes
  an upper-case UUID to lower on the way IN (stored and read lower);
  `Ecto.UUID` keeps the stored text as written and lower-cases on the
  way OUT; `:binary_id` normalizes in NEITHER direction (upper in,
  upper stored, upper back — an undocumented pass-through, left
  unpinned in the law suite on purpose). Recommendation: document all
  three in the UUID docs and then pin `:binary_id`'s behavior as a
  law — or, while unpublished, unify on normalize-on-in everywhere.
  (Run 19, B4-adjacent)
- [F-B2-7-code] (maintainer menu) SUPERSEDED by [F-B7-25-feature]
  (Run 22): the failure moved — `refuse_reference_changes!` now
  refuses `modify references(...)` up front with guidance, so the
  `DataType.column_type/2` fallthrough this entry described is
  unreachable on the rebuild path. The prize is unchanged: an
  FK-merge in the rebuild engine collapses `:alter_foreign_key`,
  migration.exs:664, and half of `:alter_primary_key` — the largest
  single exclusion reduction available. (Run 16 → folded Run 24, B2)
- [F-B2-8] (S3) `:microsecond_precision` is over-broad by exactly one
  hidden PASSING test (interval.exs:194 "datetime_add with
  microsecond" — asserts the rounding SQLite actually does; confirmed
  again in Run 30). Narrowing costs 4 location tuples — recorded, not
  churned. The `:array_type` half of this entry was WRONG by five: the
  tag hid SIX passing tests, invisible because the shared migration
  only creates the array tables when the tag is not excluded (the
  isolate-run measured the missing table, not the adapter). CLOSED in
  Run 30 by F-B2-17's narrowing — the tag is gone, three location
  tuples remain, the suite gained six tests. (Run 16, B2; Run 24
  pointer sweep; Run 30 correction + closure.)
- [F-B2-14-adjacent] CLOSED by F-B4-4 (Run 25): adjudicated CONFIRMED
  S2 and fixed — `UnencodableParameterError` (value/index/reason) from
  attempt-then-structure JSON encoding; encoder-bearing structs keep
  working; parameter positions threaded; `DecimalPrecisionError`
  gained `index`. (Run 24 → Run 25, B4)
- [F-B8-5] (S3, docs, from Run 25) Under dirty-scheduler saturation a
  statement waiting for a dirty IO slot has not started, so a 100 ms
  `:timeout` returned in 11.3 s (113×) — the cancel NIFs stay on
  normal schedulers (correct), the structured error still arrives, and
  no pool deadline can rescue a caller suspended before its statement
  runs. Owed: one honest line next to the timeout→cancel docs — the
  timeout bounds how long the QUERY runs, not how long the CALLER
  waits, when long database work saturates the VM's dirty schedulers.
  Fold into the Gate-3 docs pass + the STE README drafts. (Run 25, B8)
- [B7 enhancement candidate, unranked] A structural before/after
  verification at the end of the rebuild — compare table_xinfo,
  foreign_key_list, index_list, and table_list.wr/strict against the
  pre-rebuild reads, raising on any difference the change set does not
  explain — would catch whole classes of silent-drop bugs in one
  check instead of per-construct fixes. Evaluate as one remedy at the
  next B7 churn. Related: making the rebuild recreate dependent VIEWS
  (currently a loud refusal) is a potential future feature. (Run 15)
- [B3 seed, ORCHESTRATOR-UNVERIFIED] (reviewer-driven; Run 14's ON
  CONFLICT ROLLBACK probe walked into it): `INSERT OR ROLLBACK` /
  `ON CONFLICT ROLLBACK` inside `Repo.transaction` leaves the adapter
  COMMITting a transaction SQLite already rolled back — the caller
  gets a loud "cannot commit - no transaction is active"
  `XqliteEcto3.Error` and the connection disconnects. Pre-existing,
  independent of the name synthesis. B3's next covering run:
  reproduce, classify, decide the remedy (txn_state check before
  COMMIT?). (Run 14, filed to B3)
- [B1-1] `dump_cmd/3` is a required `Ecto.Adapter.Structure` callback
  (no `@optional_callbacks`) but the adapter `raise`s. Unreachable via
  mix tasks (`mix ecto.dump` uses `structure_dump/2`), so harmless —
  but consider a structured `{:error, ...}` or a moduledoc note. Same
  entry: `storage_up/1` MatchErrors on `XqliteNIF.open` failure
  instead of returning `{:error, term}` (near-impossible path). (Run 1)
  Same class (Run 9): `fetch_existing_columns!` destructures
  `{:ok, %{rows: rows}} = Ecto.Adapters.SQL.query(...)`
  (`lib/xqlite_ecto3.ex:592`) — the rebuild's column-listing read
  MatchErrors instead of raising structured on a near-impossible
  failure; fold into any B1-1 remedy.
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

- 2026-08-20 [F-B7-16] (S3) RULED + IMPLEMENTED same day: removing
  every primary-key member now refuses loudly before any destructive
  step (`refuse_removed_primary_key!/3`, pinned identically in the
  rebuild-verification model, RED→green tests); narrowing to a
  non-empty survivor set stays allowed; tables created keyless are
  unaffected. README rebuild section documents it. Detail: ledger
  Run 17.
- 2026-08-20 [F-B5-2] (S3) IMPLEMENTED per the 2026-07-21 synthesis
  ruling: `XqliteEcto3.UniqueIndexNames` resolves the real unique
  index name(s) via `index_list`+`index_info` on the violation path
  (always-on, two read-only pragmas; failures degrade to the derived
  conventional name); `to_constraints/2` emits one `{:unique, name}`
  per candidate — resolved names win, derived is the fallback. Two
  Ecto-matcher-forced refinements (Ecto raises on ANY emitted-but-
  undeclared constraint, verified in deps source): ambiguity requires
  the changeset to declare EVERY candidate; and a bare
  `unique_constraint(:v)` against a CUSTOM-named index now raises
  instead of accidentally converting via the double-guess
  (Postgres-parity). 14 committed tests. Detail: ledger Remedies
  2026-08-20.
- 2026-07-21 [F-B7-6] (S3) ACCEPTED AS LIMITATION (maintainer ruling
  2026-07-21). The rebuild's `ON CONFLICT` refusal scan can be
  defeated by a comment interposed between the two keywords — SQLite
  stores CREATE TABLE text verbatim, so `ON /* c */ CONFLICT` evades
  the word-boundary regex and that construct-spelling would silently
  lose its conflict algorithm through an opt-in rebuild. Ruled
  accept-as-is over comment-stripping: reachability ≈ nil (the comment
  must sit BETWEEN the keywords in the user's own DDL, and the rebuild
  is opt-in), while a hand-rolled comment stripper risks parser bugs
  of exactly this class; the other scanned constructs are single-token
  and immune. Recorded in the announcement honesty ledger; surface a
  fine-print line in the rebuild docs with the next docs pass.
  (Run 11, B7)
  Widened (Run 22): the class covers every regex scan over stored
  CREATE text, not the ON CONFLICT refusal alone —
  `autoincrement_declared?/1` has the same shape (`PRIMARY /* c */ KEY
  ... AUTOINCREMENT` evades it, and the phrase inside a quoted
  identifier can spuriously match). Same ruling applies (reachability
  ≈ nil, stripper risk > benefit); the docs fine-print line should say
  "regex scans over stored CREATE text" generally.
  Addendum (Run 28): the STRING-LITERAL half of the class is CLOSED —
  the scans now blank quoted-literal contents (all four SQLite quoting
  forms) before matching, so a `DEFAULT 'check pending'` no longer
  false-positives and a literal AUTOINCREMENT no longer spuriously
  matches. The COMMENT half stays accepted-as-limitation, now with
  live consequence evidence on record (ledger Run 28): the comment
  evasion silently drops AUTOINCREMENT and re-hands a freed id.
- 2026-07-21 [F-B3-3] (S2) A rebuild migration under
  `Ecto.Adapters.SQL.Sandbox` leaked `defer_foreign_keys = ON`,
  silently disabling FK enforcement for the rest of the sandbox
  session: the rebuild set the pragma and relied on COMMIT's
  auto-reset, which never fires inside the sandbox's never-committing
  outer transaction — an orphan FK insert after a sandboxed rebuild
  was silently accepted (a non-sandbox control resets at commit and
  rejects; bounded to the session — a fresh checkout reads 0). Fixed
  at the orchestrator gate (ratified bar: S2 silent-enforcement-loss
  does not sit; the remedy space collapses to one bar-compliant
  option): `rebuild_table` resets `PRAGMA defer_foreign_keys = OFF`
  after a clean `foreign_key_check` — a no-op on committing
  transactions, and it makes rebuilds viable under the sandbox.
  RED→green in `table_rebuild_test.exs` (sandboxed TestRepo:
  post-rebuild pragma reads 0, orphan raises structured
  `XqliteEcto3.Error`). Maintainer may overrule (one-line revert).
  (Run 13, B3)
- 2026-07-21 [F-B9-3] (S3, test-only) The disconnect telemetry test
  asserted `reason == :normal` on an unfiltered process-global
  capture, so a concurrent file's non-`:normal` disconnect could be
  captured first and FALSE-FAIL it (deterministic injection probe +
  a live 1/20 cluster flake). Same mechanism as F-B9-2, which had
  scoped only to the `:error` captures. Fixed by pinning
  `%{conn: ^conn}` in the receive pattern; every other
  discriminator-free capture audited and dispositioned harmless
  (instance-invariant assertions only). (Run 13, B9)
- 2026-07-21 [F-B2-3] (S2) The `:like_match_blob` exclusion was STALE —
  a false "not supported" claim. Its rationale asserted the build
  carries `SQLITE_LIKE_DOESNT_MATCH_BLOBS`, but the bundled SQLite
  3.53.2 does not (compile_options probe: absent), so `LIKE` matches
  BLOB operands (`:binary` maps to BLOB) and both tagged `type.exs`
  tests pass un-excluded. Standing since Run 4, whose disposition was
  "reasoned from source" — trusted the flag rationale without
  verifying the flag; falsified empirically this run. Fixed: exclusion
  removed from `test_helper.exs` (now 18 = 13 tags + 5 locations),
  `ECTO_INTEGRATION_TAGS.md` row corrected to supported; the two tests
  now run in the suite. (Run 12, B2)
- 2026-07-21 [F-B9-2] (S3, test-only) The telemetry test cluster was
  async-unsafe: `attach_capture` installs a process-global handler
  filtered by event name only, and the two discriminator-free `:error`
  captures (handle_execute + connect) could grab a concurrent test's
  `:ok` `:stop` first (~25% flake when several telemetry files share
  one VM; zero impact on `test.seq`, which runs one file per OS
  process; product classification correct). Fixed by filtering each
  `:error` capture on its unique operation (its `sql` / its pinned
  `database`) — the only two discriminator-free live-event `:error`
  captures. Cluster 0/25 post-fix. (Run 12, B9)
- 2026-07-21 [F-B7-3] (S1) The rebuild silently NARROWED a composite
  PRIMARY KEY: `existing_to_column` emitted an inline `PRIMARY KEY`
  only for the `table_xinfo.pk == 1` column, so rebuilding a
  `PRIMARY KEY (a, b)` table produced a single-column key — the
  integrity constraint weakened without a word, legitimate composite
  rows rejected (probed live: `(1, 99)` refused after rebuild;
  reverse-declared `PRIMARY KEY (b, a)` reduced to `["b"]`). Fixed:
  `plan_new_schema` collects pk members by declared position; more
  than one suppresses the inline clause and emits a table-level
  `PRIMARY KEY (…)` over the surviving members in order; single-column
  keys stay inline to preserve the INTEGER-PK rowid alias and
  AUTOINCREMENT. RED→green in `table_rebuild_preservation_test.exs`
  (order asserted `["b", "a"]`, composite insert accepted, exact dup
  rejected); RED independently reproduced at gate by stashing only the
  engine (11/15 → 15/15). (Run 11, B7)
- 2026-07-21 [F-B7-4] (S1) The rebuild silently DROPPED the
  `WITHOUT ROWID` and `STRICT` table options: the generated CREATE had
  no option tail and no refusal scan covered them (no structural
  pragma exposes either). Probed live: a rebuilt WITHOUT ROWID table
  gained a rowid; a rebuilt STRICT table accepted `'not-an-int'` into
  an INTEGER column. Fixed: `unpreservable_table_option/1` scans the
  tail after the final `)` of the stored CREATE text (table options
  carry no parentheses, so the boundary is unambiguous and a column
  merely named `strict`/`rowid` cannot false-positive) and refuses
  loudly before any destructive step. RED→green (+2 tests asserting
  refusal AND post-state: rowid still absent / strict still
  enforcing / rows intact). (Run 11, B7)
- 2026-07-21 [F-B7-5] (S2) Rebuild DDL quoting did not escape embedded
  quotes: `quote_name` and raw `"#{name}"` interpolations left an
  embedded `"` undoubled (malformed DDL — loud — for exotic
  identifiers), and the sqlite_sequence restore inlined the table name
  into a `'…'` string literal unescaped (a constructible silent
  widening of its DELETE for a crafted AUTOINCREMENT table name).
  Fixed: `quote_name` doubles `"`, new `quote_string` doubles `'`,
  every rebuild DDL fragment (CREATE / INSERT-copy / DROP / RENAME /
  sequence restore) routed through them, transient name centralized.
  RED→green (a `we"ird` column round-trips with data). (Run 11, B7)
- 2026-07-21 [A4] Faithful table-rebuild constraint preservation — CLOSED
  (structural-preservation scope, maintainer ruling 2026-07-21). Replaced the
  blanket refusal with faithful reconstruction of everything SQLite exposes
  STRUCTURALLY: foreign keys via `PRAGMA foreign_key_list` (composite keys grouped
  by id/ordered by seq, `ON DELETE`/`ON UPDATE` actions, implicit-PK references
  when `to` is NULL, default NO ACTION/MATCH omitted) and UNIQUE constraints via
  `PRAGMA index_list` origin `u` + `index_info`, both emitted as table-level
  clauses in the rebuilt CREATE TABLE. A self-referencing FK is reconstructed
  against the transient `__xqlite_new` table so the drop cannot cascade into the
  freshly-copied rows (the rename fix-up restores the final target). The text-only
  residue STAYS refused by design — CHECK/COLLATE/generated columns keep their
  detections, and DEFERRABLE FKs + ON CONFLICT clauses were ADDED as refusal
  triggers (a word-boundary scan of the stored CREATE TABLE text) because the
  structural pragmas do not expose them; REFERENCES/UNIQUE were removed from the
  refusal scan. Incoming cascade/set-action hazard RESOLVED BY REFUSAL (orchestrator
  gate 2026-07-21, superseding the earlier doc-only disposition): a pre-flight
  `refuse_incoming_actions_on_populated!` scans INCOMING FKs and refuses loudly when a
  POPULATED other table references the rebuilt one with `ON DELETE CASCADE`/`SET
  NULL`/`SET DEFAULT` — the drop's implicit DELETE would otherwise silently fire that
  action on the referencing rows (`foreign_keys=OFF` is a no-op inside the migration
  transaction; `defer_foreign_keys` defers only the check, not the action). Empty
  referencing tables proceed (no-op on zero rows); self-refs excluded (transient-name
  trick); RESTRICT/NO ACTION incoming refs already fail loudly on the drop.
  RED→green: `table_rebuild_preservation_test.exs` (now 11 tests, real `Ecto.Migrator`
  migrations against PoolRepo) covers single/composite/implicit-PK/incoming/self-ref
  FKs, UNIQUE (single + composite, structured error + usable `to_constraints` name),
  the foreign_keys-unchanged + mutual-ref-copy invariant, and the two populated-
  referencing refusals (CASCADE + SET NULL — both RED "nothing was raised" against the
  pre-refusal engine, green after, rows/values intact); `table_rebuild_test.exs`
  refusal set updated (FK/UNIQUE removed, DEFERRABLE + ON CONFLICT added). Docs
  (README rebuild sections + `XqliteEcto3` / `XqliteEcto3.Migration` moduledocs)
  flipped to "FKs and UNIQUE survive; CHECK/COLLATE/generated/DEFERRABLE/ON CONFLICT
  refuse". `mix verify` green. (Remedies 2026-07-21, B7)
- 2026-07-21 [F-B8-3] (S3) Pooled-timeout connection recycling — CLOSED (doc
  remedy, maintainer ruling 2026-07-21). A pooled query `:timeout` ALSO trips
  DBConnection's own checkout deadline (same value), which disconnects+reconnects
  the connection, so connection-local state (temp tables, session PRAGMAs, the
  statement cache) does not survive a timeout and there is a reconnect cost —
  standard DBConnection behavior for every adapter, not an adapter defect. Added an
  honest line to the README timeout→cancel divergence section noting this and that
  the graceful cancel's value is the blocked query returning at the deadline instead
  of running to completion. No code change. (Remedies 2026-07-21, B8)
- 2026-07-21 [F-B3-2] (S3) Cold-start WAL-flip boot-log burst — CLOSED (doc
  remedy, maintainer ruling 2026-07-21). Skip-when-already-WAL changes nothing (the
  fresh-file first boot must flip regardless; later boots are already no-op clean),
  so the remedy is documentation only. Added a "First-boot WAL noise on a fresh
  database" section to the README: the symptom (transient `failed to connect:
  {:database_busy_or_locked, 5, …}` `[error]` burst when a boot migration holds the
  write lock while the pool flips `journal_mode=wal` on a fresh file), why it is
  harmless (self-healing, queries succeed, WAL persists so later boots are clean),
  and the three mitigations (run migrations before starting the app pool; pre-create
  the database with WAL set; raise the connect `busy_timeout`). No code change.
  (Remedies 2026-07-21, B3)
- 2026-07-21 [F-B2-2] (S2) The runtime JSON-path branch (`dynamic_json_path`)
  escaped nothing: it emitted `$."<raw value>"`, so a runtime JSON key value
  (a column/param, e.g. `d.meta[d.label]`) containing a backslash silently
  extracted nil — SQLite treats `\` as a JSON5 escape inside the quoted label
  (`$."back\slash"` → nil, vs the compile-time-escaped `$."back\\slash"` → the
  value). Same mechanism-class as F-B2-1 (Run 4 fixed the literal branches and
  believed the runtime branch already correct), a different code path Run 4's
  critic owed. A runtime double-quote key was also nil (that case had been
  documented-unsupported; the backslash case was undocumented + silently
  wrong). Fixed by escaping the runtime value for the JSON5 quoted-label
  grammar via nested `replace(replace(seg, '\', '\\'), '"', '\"')` (mirrors the
  compile-time `escape_json_key`) — dot/backslash/quote runtime keys now all
  resolve, and the fix closes the documented double-quote limitation (moduledoc
  caveat dropped). RED→green in `json_extract_path_test.exs` (+2). (Run 8, B2)
- 2026-07-21 [F-B10-1] (S3) The `bench/` project did not compile: `bench/mix.exs`
  pinned `ecto_sql ~> 3.13.0` while the adapter requires `~> 3.14` (uses
  `Ecto.Migration.Table.:modifiers`), so `mix compile` in `bench/` failed with
  "unknown key :modifiers for struct Ecto.Migration.Table." Bumped the bench to
  `ecto_sql ~> 3.14` + `ecto_sqlite3 ~> 0.24`, dropped the stale insert/8
  comments, refreshed `bench/mix.lock` via the sanctioned HEX_HOME (ecto_sql
  3.14.0 / ecto 3.14.1 / ecto_sqlite3 0.24.1 / exqlite 0.39.0 / decimal 3.1.1;
  local path deps kept; top-level mix.lock untouched). `mix compile` in bench/
  exit 0 (`xqlite_ecto3` compiles against ecto_sql 3.14) and a smoke run
  (`BENCH_TIME=1 BENCH_WARMUP=0 BENCH_MEMORY_TIME=0 mix run bench.exs`) exit 0,
  all scenarios + the cancellation demo producing output. Methodology honesty
  unchanged (edits touched only mix.exs+lock). No figures recorded (ledger-first).
  (Run 8, B10)
- 2026-07-21 [F-B7-2] (S1) The opt-in table rebuild (`support_alter_via_table_rebuild:
  true`) reconstructed the new table from `PRAGMA table_xinfo`, which exposes only
  name/type/notnull/default/pk. Foreign keys, CHECK constraints, and COLLATE /
  inline-UNIQUE clauses live only in the original CREATE TABLE text, so a `:modify`
  on a table declaring any of them SILENTLY DROPPED the constraint — a MODIFY became
  a silent loss of referential/domain integrity. Proven live through `Ecto.Migrator`
  with idiomatic `references/1` + `check:`: after `modify :name`, the FK
  `child_parent_id_fkey` and CHECK `qty_pos` were gone from the rebuilt schema, and
  a subsequent orphan insert (parent_id 999) and a CHECK-violating insert (qty -5)
  were both ACCEPTED; `PRAGMA foreign_key_check` was vacuously clean because the FK
  no longer existed. Fixed to REFUSE loudly (mirrors F-B7-1): `rebuild_table` now
  calls `refuse_unpreservable_constraints!/3`, which raises `ArgumentError` (before
  any destructive step, table left intact) when the table declares REFERENCES /
  CHECK / COLLATE / inline UNIQUE (scanned from the stored CREATE TABLE SQL) or has
  generated columns (`table_xinfo.hidden IN (2,3)` — the `col TYPE AS (expr)`
  shorthand has no scannable keyword, and a rebuild would drop a virtual generated
  column and freeze a stored one into a plain column — both confirmed live), and
  points the user at a manual `execute/1` rebuild. Detection over-approximates, so
  the only failure mode is a safe refusal, never a silent drop; standalone indexes/
  triggers/AUTOINCREMENT are still preserved (the existing rebuild tests stay
  green). Docs (README rebuild section + `Migration` moduledoc) corrected — they
  had claimed the dance preserved everything / recreated FKs. RED→green in
  `table_rebuild_test.exs` (+5). A richer remedy (faithful FK reconstruction via
  `pragma_foreign_key_list`, CHECK/COLLATE/generated via CREATE-TABLE rewrite) is a
  maintainer call — see Feature follow-ups. (Run 7, B7)
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
