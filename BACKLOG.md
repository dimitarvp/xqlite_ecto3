# Backlog — xqlite_ecto3 (review program)

Severity per the ratified bar in `xqlite/REVIEW_AXES.md`. Nothing
here is ever silently dropped; S3s get a committed closer-look pass
after the S0–S2 burn-down.

## Pre-publish gates (release-readiness, regardless of severity)

- [G1] DONE (2026-09-05, Gate 3 prep). Zero-external-caller claim
  verified per function (lib + test, alias-aware): 18 helpers →
  `defp`; `build_explain_query/2`, `quote_name/1`, `quote_table/1`
  stay public under `@doc false` because tests drive them directly.
  The `defp` flip exposed four dead clauses, deleted: `insert_all/1`,
  the `%Ecto.Query{}` clause of `insert_all/2` (`rows_sql/3` renders
  query-shaped rows itself), `lock/2` (the second, unreachable lock
  refusal — settles F-B2-36-seed's reachability question), and
  `create_names/1`. hexdocs now lists zero undocumented functions on
  `Connection`; the three custom types no longer show the inherited
  `embed_as/1`. (wave-1)
- [G3-1] (S3 seed, B3 court, from the Gate 3 prep audit) The
  transaction-control keyword sync (`sync_after_transaction_control`)
  runs only on the ordinary execute path (`driver.ex`, the
  `handle_execute` columnless-success branch). A `BEGIN`/`COMMIT`/
  `ROLLBACK` issued through the streaming path (`handle_declare` +
  `handle_fetch`) is not seen, so the cached transaction flag goes
  stale — the rollback-disconnect guard's fifth door, reachable only
  by streaming raw transaction control (nobody does; reachability ≈
  nil). Remedy candidates: route the declare/fetch success paths
  through the same sync, or refuse transaction control on the stream
  path. CHANGELOG wording corrected to the true scope.
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
- [F-B1-menu-connect-error-details] (maintainer menu, from Run 33's
  gate) Connect config-error payloads (unregistered hook subscriber
  NAME, malformed pragma entry, invalid mode atom) now live only in
  the wrapped exception's message (inspect) — the tag-tuple family of
  `Error.wrap/1` is deliberately details-less (error_wrap_test pins
  `details: nil`). Giving that family a structured payload field is a
  designed-shape decision for the whole error surface, not a local
  patch; `cannot_open_database` already got its specific clause
  (path + code in details) as the Run-33 precedent. (Run 33, B1)
  Telemetry consequence (Run 37 = F-B9-18): the connect stop event's
  error_reason is now the wrapped exception with details: nil, so a
  consumer wanting the REJECTED VALUE (which config key, what was
  passed) can only parse message prose — against doctrine. The
  Run-37 validators grew this family by nine more tags; whatever
  payload shape lands here should carry {key, value}. (Run 37, B9)
  Widened again (Run 46): the hooks validators add
  {:invalid_hook_option, {key, value}} and the progress-shape
  refusals — the {key, value} payload is already the tag's second
  element there, the designed shape's natural precedent. (Run 46,
  B3)
  Message consequence (Run 42 = F-B1-9, S3, MERGED here): a
  STRING-valued config (`journal_mode: "wal"`, env-var-driven
  spellings) hits `wrap/1`'s `{tag, binary}` clause — meant for NIF
  reasons where the binary IS the SQLite message — so the connect
  log reads `failed to connect: ** (XqliteEcto3.Error) wal`, naming
  neither key nor problem; the `type` field stays correct. Atom
  values read fine (inspect of the whole tuple). Probed across all
  32 config shapes (b1_cover_r42/p05). Whatever shape lands here
  must ALSO fix the message for string values — e.g. validators
  emitting {tag, key, value} 3-tuples, or guarding the binary-
  message clause to NIF tags. (Run 42, B1)
- [F-B6-6-menu] (maintainer menu, B7 court, from Run 34) `alter
  table … add` with a non-constant `default:` fragment is row-count
  dependent by SQLite's own ADD COLUMN rule (empty table OK,
  populated table errors) — documented in the README at Run 34's
  gate. The implement option: route such adds through the existing
  rebuild engine (which recreates the table and is unaffected), or
  refuse them loudly pre-flight so dev and prod fail the same way.
  Feature-taste call. (Run 34, B6 → B7)
  Evidence (Run 36): routing works TODAY with zero engine changes —
  bundling the add with any modify already rebuilds a populated
  table correctly; only `requires_rebuild?/1` (:modify-only) stands
  between the outcomes. But the rebuild materializes the fragment
  ONCE at migration time (probe: every pre-existing row got the
  identical `datetime('now')` timestamp), where the empty-table
  path evaluates per-insert — routing turns a loud failure into a
  quiet semantic surprise, plus O(table) cost and every rebuild
  refusal inherited. Recommendation: refuse pre-flight, naming the
  fragment default and both honest workarounds (constant default +
  `execute` UPDATE, or deliberately bundle with a modify — probed
  working). (Run 36, B7)
- [xqlite-0.11.1-release] (MAINTAINER ACTION, from Run 40) The two
  xqlite doc fixes recorded as landed at Run 26 (the
  query_with_changes rule correction; the README compatibility
  statement) sit on xqlite main, unreleased — hex/hexdocs 0.11.0
  still teach the abandoned empty-columns rule that already caused
  one adapter bug. The CHANGELOG Unreleased section is staged; owed:
  version bump + tag + publish per the xqlite release checklist
  (publish auth is the maintainer's). A patch stays inside the
  adapter's `~> 0.11.0` bound. (Run 40, X2)
- [F-B4-10-menu] (maintainer menu, from Run 39; the docs/message
  half landed at the gate) A `:decimal` field over a TEXT-affinity
  column silently stores SQLite's float-to-text rendering of the
  bound number (~10% of accepted values drift) — unfixable at the
  bind boundary, which cannot see the column. The implement option:
  an opt-in exact Ecto type (dump `Decimal` → canonical string,
  load string → `Decimal`) for users who want arbitrary-precision
  text storage with a `:decimal`-shaped field; would forfeit
  numeric ORDER BY/range semantics on that column, which the docs
  would state. Until ruled, the README caveat + corrected
  `DecimalPrecisionError` message are the contract. (Run 39, B4)
- [F-B2-26-menu] (maintainer menu, from Run 38) `update_all`'s
  `push:`/`pull:` array operators refuse (message corrected at Run
  38's gate — arrays themselves ARE supported as JSON text). The
  implement option: translate them via SQLite JSON functions —
  `push:` ≈ `json_insert(col, '$[#]', ?)`, `pull:` ≈ a
  `json_group_array` filter rewrite. Both exercised upstream only
  inside the excluded `type.exs:234`, so landing this un-excludes
  nothing by itself; feature-taste call. (Run 38, B2 → translation
  court)
- [F-B3-14-menu] (maintainer menu, from Run 37) `with_xqlite/3`
  always starts its own checkout, so nested calls (inside
  `Repo.transaction`/`Repo.checkout`/another bridge call) queue
  behind the pool: at pool_size 1 a queue-timeout raise (or a rolled-
  back enclosing transaction), at larger sizes the callback silently
  runs on a DIFFERENT pooled connection — every connection-scoped
  install lands on the wrong one. The moduledoc's false sandbox-
  nesting promise was corrected at Run 37's gate (docs are the ruled
  remedy). Implement option: detect the calling process's existing
  checkout and run on it — needs a caller-conn discovery mechanism
  DBConnection does not expose today. Feature call. (Run 37, B3)
- [F-B9-13] (S3, from Run 29; WIDENED by Run 37 = F-B9-17) The
  `XQLITE_ECTO3_TELEMETRY=off` build breaks FOUR test files, not
  one: `telemetry_test.exs` 0/14, `fk_diagnostics_test.exs` 12/13
  (the filed assertion — line 334's `:start` assert_receive, empty
  mailbox), `driver_statement_cache_test.exs` 13/14,
  `telemetry_and_placeholder_law_test.exs` 2/3 — 17 failing
  tests/properties total; invisible in CI because the
  `telemetry_disabled` lane runs only the smoke file. The widened
  facts settle the remedy trade-off: widening the lane would exclude
  four files and forfeit the mixed files' non-telemetry coverage;
  compile-time flag-guards cost ~17 guarded tests and keep it —
  whole-file guard natural for `telemetry_test.exs` alone. Not fixed
  blind — verify under BOTH builds when it lands. (Run 29 + Run 37,
  B9)
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
  Evidence (Run 36): 13 bare `ArgumentError` sites in
  `lib/xqlite_ecto3.ex` (+1 more since Run 36's fix), 13 committed
  tests regex the prose, PLUS a plain `RuntimeError` at the
  `foreign_key_check` failure (post-dance, carries the violations
  only as `inspect` inside a string — the worst of the set).
  Refuse-before-touch verified across seven refusal flavours (stored
  SQL and rows byte-identical, no transient table); the struct is a
  diagnostics/testability call, not a safety one.
  `RebuildVerificationError` already sets the in-tree precedent.
  Recommendation: implement, with a `reason` atom + table/construct/
  column fields, and fold the `RuntimeError` in with the violation
  rows as a field.

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
  Extended (Run 35, F-B5-22): the same branches skip the ENTIRE
  enrichment step, so the rich-FK replay is skipped too — the
  advertised `fk_violations` list arrives empty with
  `fk_diagnostics: :not_run` (truthful, and now documented in the
  README's rich-FK caveats). Check/not-null/unique classification
  itself survives the stream path (parsed in Rust). Whatever lands
  here covers both enrichments. (Run 35, B5)
  Sharpened (Run 44): the gap is not merely a poorer status — the two
  paths emit DIFFERENT constraint names for one violation
  (execute: the resolved custom name; stream: the derived
  conventional name, b5_cover_r44 p11), so a changeset correct on one
  path raises on the other. Any remedy must equalize the emitted
  name, not just the status. (Run 44, B5)
- [F-B5-16] (S3) The rich-FK-diagnostics replay is a WRITE, so it
  contends for WAL's single write lock where the unique lookup's reads
  do not. Proven deterministically at Run 44 (b5_cover_r44 p10): with
  another connection holding the write lock, an isolated replay blocks
  a full `busy_timeout` (1502 ms against 1500) and degrades
  `{:unavailable, {:database_busy_or_locked, 5, _}}`, while the
  read-only unique lookup under the same lock completes in 1 ms — the
  ceiling is one extra full busy wait on top of the failing
  statement's own. Both waits landing in one statement was observed
  once (Run 27) and did not recur over 12 staggered-holder iterations;
  the ceiling, not the sum, is the documented cost. Cost note in the
  moduledoc; a budget for the replay folds into [F-B5-14-fork].
  Cleanup verified clean under contention (no open txn,
  `defer_foreign_keys` reset). (Run 27, B5; re-measured Run 44)
- [F-B5-17] (S3) `wrap_execute_error/4` (FK replay + unique lookup)
  runs BEFORE `disconnect_if_rolled_back/2`, so enrichment work runs
  on a connection the driver may be about to destroy, and under
  `ON CONFLICT ROLLBACK` inside a transaction the recovered names
  never reach a changeset (`Repo.transaction` yields
  `{:error, :rollback}`). Remedy — decide the disconnect first, skip
  enrichment on a doomed connection — interacts with the Run 23/25
  disconnect-at-damage guard; sequence any change with that surface.
  (Run 27, B5)

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
  Run 41: re-driven at 0.11.0 — reproduces (3007 ms for a 300 ms token
  vs an `:infinity` control at 3005 ms; uncontended control cancels at
  301 ms). The docs half LANDED: README's timeout section and the pitch
  bullet now state the busy-wait carve-out (+ STE mirror). The behavior
  half stays open, options unchanged. Adjacent unmeasured (Run 41
  critic): `stmt_prepare` also runs before any cancel token exists, so
  the same busy-wait shape may cover statement preparation.
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
  CLOSED at Run 42 (absorbed by F-B1-6/F-B1-7's court, graded S1
  there): the nameless FK clause returns `[]` now — ecto_sql
  re-raises the structured error — and the synthesize option was
  ruled out (the generic FK error does not name the violated field,
  so `<source>_<field>_fkey` is not derivable). Pinned by
  `fk_constraint_default_config_test.exs` + the connection_test unit
  flip.
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
  Sharpened (Run 35, F-B5-25): since the single-candidate emission
  rule, the wrong-schema name is EMITTED as the constraint name, so a
  changeset declaring the correct name misses and a bare
  `unique_constraint/1` raises — and a TEMP table shadowing a real
  table's name poisons violations on the MAIN table too, not only on
  the shadowed one (probe: all three of temp.t/aux.t/main.t emitted
  temp's index name). The sketched remedy is probe-confirmed
  feasible: `pragma_table_list` for the table name returned all
  schemas in one read. Invisible residual: equal index names across
  schemas make the mis-resolution undetectable and harmless-looking —
  worth pinning if the remedy lands. Severity stays S3 (crafted
  schema, same class as F-B5-5).
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
- [F-B7-46] (S3) A rebuild silently rewrites a typeless column's
  declared type to `BLOB`: `existing_to_column/4` substitutes "BLOB"
  when the stored type is nil/empty, the verification model's
  `rebuilt_type/1` makes the SAME substitution, so the post-check
  compares two agreeing wrong readings and is blind to it. Affinity
  is identical (typeless = BLOB affinity) and stored values keep
  their storage classes (probed) — the cost is that a rebuild
  advertised as structure-preserving changes the schema text every
  diff/dump/introspection tool reads. Remedy direction: carry the
  empty type through both halves and emit the column with no type
  token; or document the rewrite. The blind-spot CLASS is wider —
  every helper both halves share is a candidate; the next B7 pass
  owns the systematic enumeration. (Run 36, B7)
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
  again in Run 30, and again in Run 38 as the ONLY non-failing name
  in the all-26-include ground-truth run). Narrowing costs 4 location
  tuples — recorded, not churned; the 4/5 DISCLOSURE now lives in
  both artifacts (Run 38, F-B2-25), so the trade is public. The `:array_type` half of this entry was WRONG by five: the
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

- [F-B8-12-handoff] (S3, B1/B2 court, from Run 41) A top-level
  `Repo.transaction(fun, mode: :savepoint)` runs DEFERRED — a lone
  SAVEPOINT behaves as BEGIN DEFERRED — silently discarding the
  `default_transaction_mode: :immediate` promise the README sells
  (write transactions take their lock up front). The savepoint arm of
  `handle_begin/2` never consults `default_transaction_mode`. The
  `txn_state` measurement leg was written (b8_cover_r41
  p7_repo_config_mode.exs L4) but never reached — the probe died on
  F-B8-9's pool brick first; measure when adjudicating. Candidate
  dispositions: document the carve-out next to the mode: docs, or
  refuse `mode: :savepoint` with no enclosing transaction.
  (Run 41, B8 → B1/B2)
  ADJUDICATED at Run 42 — REFUSED (implemented, gated). Measured:
  top-level savepoint is byte-for-byte :deferred (lock taken only at
  first write), and under a verified-concurrent two-writer race the
  deferred snapshot's write fails INSTANTLY (SQLite skips the busy
  handler on a stale-snapshot upgrade) — one update lost where
  :immediate serializes both (b1_cover_r42 p02/p03, orchestrator
  re-driven). Sandbox unaffected (source: sandbox.ex:659 outer
  mode: :transaction; runtime: lock held across sandboxed savepoint
  begins, released at checkin). handle_begin now refuses the
  savepoint mode with no enclosing transaction
  (DBConnection.ConnectionError naming the rule); translate was
  rejected (a savepoint-owns-an-implicit-BEGIN state flag for a
  construct with no legitimate top-level use). CHANGELOG Changed +
  README + STE drafts updated. B2's share (exclusion-list impact):
  none — the vendored suites' only savepoint-mode site is
  alter.exs:60, a SINGLE-OP `mode:` (inert per the Run-33 F-B8-8
  adjudication, never reaches handle_begin) and excluded for
  unrelated reasons besides. Revert = drop the {:savepoint, _}
  refusal clause in handle_begin/2.

- [F-B1-11-docs] (S3, docs owed, from Run 42's critic) An UNNAMED
  SQLite CHECK constraint's "name" is its expression text
  (`"v > 0"`), so `check_constraint/3` with Ecto's derived
  `<table>_<field>_check` name can never match —
  `Ecto.ConstraintError` under both diagnostic configs. Known
  in-repo (constraints_test.exs:170 works around it by passing
  `name: "value > 0"`) but absent from README/gotchas — owed a
  public entry per the footgun rule; the advice is to NAME check
  constraints in migrations. Also confirm `Migration.enum_check/3`
  and `array_check/2` emit named constraints; if not they inherit
  this. (Run 42, B1 → docs/B6)

- [F-B8-13] (S3, B8 court, from CI watch 2026-08-31) A pooled
  checkout deadline that expires while the client is still inside
  `prepare_and_cache/2` (driver.ex:720 frame) surfaces to the
  caller as the driver's own `%XqliteEcto3.Error{type:
  :connection_closed}` instead of the
  `%DBConnection.ConnectionError{reason: :error}` the cancel
  surface promises (cancellation_test.exs:206's comment pins:
  deadline-cancelled queries report `:error`). Observed once, on a
  scheduled macOS run (GHA run 33384417033, macos-latest/1.18/OTP
  26, sha db4d860 — same sha green at push 08-21 and on the 08-24
  schedule): the 100 ms deadline burned in queue+prepare on the
  slow runner, the pool disconnected and closed the handle, the
  client's next NIF call returned `connection_closed`, and the
  wrap passed straight through — a THIRD caller-visible shape for
  the same user-facing event (query timed out), decided by which
  process notices the deadline first. Both pool-timeout tests
  (cancellation_test.exs:184 + :206) assert the ConnectionError
  shape and are equally exposed. New flake class member — NOT the
  sandbox.exs:174/:188 slow-macOS pair (that tally stays at 3;
  this one starts its own count at 1). Candidate dispositions for
  B8's court: widen the two asserts to accept the raced shape and
  document the race as behavior, or normalize — map a
  deadline-raced `:connection_closed` into the ConnectionError
  surface (needs DBConnection-internals adjudication: whether the
  driver can even tell the deadline expired). Not design-free;
  filed, not fixed in-run.

- [F-B5-31] (S3, B5 court + xqlite half, from Run 44) A duplicate
  explicit-rowid write on a table with no INTEGER PRIMARY KEY fails
  with extended code SQLITE_CONSTRAINT_ROWID and the fully
  parseable message "UNIQUE constraint failed: t.rowid", but
  xqlite's `parse_details` has no arm for that code, so the details
  arrive empty (`table: nil, columns: []`) and `to_constraints/2`
  falls to `[]` (b5_cover_r44 p04). The safe half of the F-B5-26
  family — empty, not nil. Fix is split-court: xqlite adds
  `SQLITE_CONSTRAINT_ROWID => parse_unique(message)` in
  `constraint_parse.rs` (queue for the next xqlite release AFTER the
  staged 0.11.1 — its notes are frozen); the adapter then maps
  `:constraint_rowid` beside `:constraint_primary_key`. The
  remaining unmapped codes (trigger/datatype/function/vtab/pinned/
  commit_hook) verified correctly `[]` at Run 44. (Run 44, B5)

- [F-B5-27-commit] (S3, B5 court, from Run 44) Run 44's baseline
  diff fixed pre-existing-orphan contamination on the REPLAY path
  only. `wrap_at_commit/2` (commit-time deferred-FK failures) still
  runs `PRAGMA foreign_key_check` database-wide with no baseline —
  there is no pre-transaction snapshot to diff against — so orphans
  written under `foreign_keys: false` anywhere in the file appear
  among a committing transaction's reported violations. Documented
  in the FkDiagnostics moduledoc at Run 44. Remedy needs a design:
  a baseline captured at BEGIN (cost on every transaction under
  rich diagnostics — likely wrong), or an accepted documented gap.
  The commit path was also never probed end-to-end (Run 44 critic
  item 3 — user-deferred FKs, raw "COMMIT" via Repo.query replaying
  the string "COMMIT"); probe before designing. (Run 44, B5)

- [F-B2-36-seed] (S3 seed, B6 court, from Run 47) `Connection.lock/2`
  raises `Ecto.QueryError` "SQLite does not support locks" — a second,
  differently-worded refusal for the thing `all/1`'s up-front
  `lock != nil` ArgumentError already refuses, and the `all/1` guard
  makes it unreachable through `Repo.all`. Whether `update_all`/
  `delete_all` can reach `lock/2` was not probed (out of B2's scope) —
  B6's next pass owns the reachability question and the
  two-refusals-one-thing cleanup. (Run 47, B2 → B6)

- [F-X2-4] (S3, xqlite court, from Run 49) The staged 0.11.1's
  clippy rewrite (`9f2e278`, as_chunks in schema.rs) raises the
  SOURCE-BUILD Rust floor to 1.88 with nothing declaring it: no
  rust-version in Cargo.toml, CI pins only "stable", no README
  line — while XQLITE_BUILD=true source builds are a documented
  path. Fix in xqlite's court: rust-version = "1.88" + one release-
  notes line, or revert the lint rewrite. Precompiled-NIF users
  unaffected. (Run 49, X2)
  ADDENDUM 2026-09-05 (Gate 3 prep): the diagnosis was off by one
  floor. The source-build floor has been 1.91 since 0.11.0 — rustler
  0.38.0 (commit 11796ff) declares `rust-version = "1.91"` and cargo
  enforces it (Rust 1.90.0 refuses the crate naming rustler; 1.91.0
  builds it) — so the as_chunks rewrite (1.88) changed nothing. FIX
  LANDED in xqlite main for 0.11.1: `rust-version = "1.91"` in
  Cargo.toml, the README's toolchain paragraph (also states the OTP
  26 floor the NIF-2.17-only precompiled binaries imply) mirrored in
  the STE draft, a CHANGELOG entry, and an UPGRADE_PLAYBOOK step to
  re-derive the floor on every rustler/rusqlite bump. CI still pins
  `stable` only — an MSRV lane was deliberately not added (maintainer
  works at latest Rust; declare, do not test-pin). CLOSED.

- [F-B8-14] (S2, FIXED, from Run 50) A negative `:timeout` reached
  `spawn_canceller/2`'s `receive … after`, which raises
  `:timeout_value` in the spawned (unlinked) canceller: the token was
  never fired, the statement ran to completion, and DBConnection's
  already-expired deadline recycled the connection underneath the
  next caller (`:connection_closed`). Reachable through repo config
  and per-call opts; the cold-adopter route is a computed remaining
  budget going negative. FIX: `max(timeout, 0)` — identical semantics
  to `timeout: 0` (cancel at once). Pinned (cancellation_test).
- [F-B8-15] (S2, FIXED, from Run 50) `handle_begin/2` mapped EVERY
  `NIF.begin/2` error to `{:disconnect, …}`; with the default
  `:immediate` mode a held write lock makes `BEGIN` fail with
  `:database_busy_or_locked` after `busy_timeout`, so every contended
  transaction start recycled a healthy connection (p09: 8 contended
  begins = 8 disconnects + 8 reconnects on a pool of 2; the
  `:deferred` control: 0). SQLite starts no transaction when BEGIN
  loses the lock race, so the busy shape now returns `{:error, …}`
  and keeps the connection; other begin failures still disconnect.
  `{:error, exception, state}` is absent from DBConnection's
  documented `handle_begin` return spec but handled by its shared
  `handle_common_result/3` (db_connection 2.10.2:1397-1416, reached
  from `run_begin/3`'s fall-through) — dialyzer accepted it at the
  gate. The second half (`:timeout` does not bound `BEGIN`; the wait
  is the F-B8-1 busy-handler shape, measured 3004 ms for a 100 ms
  token) is docs: README timeout section + retry bullet, STE
  mirrored. Pinned (driver_transaction_mode_test).
- [F-B8-16] (S3, FIXED adapter half, from Run 50) Whitespace- or
  comment-only SQL: `stmt_prepare` refuses it precisely
  (`{:cannot_execute, "SQL contains no statement"}`) but
  `prepare_and_cache/2` treated `{:cannot_execute, _}` as a fallback
  trigger, so the one-shot path stepped a null statement into
  API_ARMOR and the caller got `SQLITE_MISUSE` (21) — the code that
  means an adapter bug. FIX: the fallback clause is gone; the
  prepare refusal surfaces as `%Error{type: :cannot_execute}`.
  Pinned (error_paths_test). XQLITE HALF (owed, xqlite court): make
  `query`/`query_with_changes` refuse no-statement SQL like
  `stmt_prepare` does, so the `statement_cache_size: 0` path stops
  answering MISUSE and both paths agree.
- [F-B8-17] (S3, FIXED, from Run 50) `handle_begin/2`'s two refusals
  (savepoint with no enclosing transaction; unknown mode) were bare
  `%DBConnection.ConnectionError{}`s — the only untyped refusals in
  the driver, unpinnable without message matching, and the savepoint
  text told the caller to "drop the mode: option" although
  `Ecto.Adapters.SQL.Sandbox` forces `mode: :savepoint` itself
  (p14: after a raw COMMIT inside a sandboxed connection, a plain
  `Repo.transaction` hit that message). FIX: `%XqliteEcto3.Error{type:
  :savepoint_without_transaction | :invalid_transaction_mode}` with
  the mode and transaction status in `details`; message reworded.
  Pinned (driver_transaction_state_test, driver_transaction_mode_test).
- [F-B8-18-handoff] (S3, B5 court + xqlite half, from Run 50) The
  default cached statement path can never produce
  `:sql_input_error`: xqlite's `stmt_prepare` builds a plain
  `SqliteFailure` for a syntax error (nif.rs:785-787) where the
  one-shot path yields the documented `%Error.Input{sql, offset}`
  (p13: `"SELCT 1"` → cached `:sqlite_failure` code 1 vs one-shot
  `:sql_input_error` offset 0). Two paths, two classifications for
  the same SQL. xqlite half: build `SqlInputError` in `stmt_prepare`
  like the query path does.
- [G3-1 addendum, Run 50] Measured consequence of the unsynced
  stream path: after a stream-opened `BEGIN`, a later successful
  `INSERT` lands inside the invisible transaction and recycling the
  connection loses it (`rows_surviving_recycle = 0`). The CANCEL side
  opens no durable-write door: a cancelled write inside that
  transaction returns `{:error, ConnectionError}` with the real
  status already back to autocommit, matching the stale flag.
  Reachability unchanged (≈ nil).
- [F-B8-13 tally, Run 50] Class tally stays at 1 (no recurrence since
  `db4d860`; the one red in between was the CRLF artifact test). New
  input for its menu: p05 reproduces the same caller-visible
  `:connection_closed` DETERMINISTICALLY via a non-positive
  `:timeout` (F-B8-14's aftermath), so the shape is not race-only —
  strengthens "normalize the deadline-raced `:connection_closed` into
  the ConnectionError surface" over "widen the asserts".
- [F-B5-31 addendum, 2026-09-05] Both halves landed: xqlite
  `019388a` adds the `SQLITE_CONSTRAINT_ROWID => parse_unique` arm
  (ships after 0.11.0); the adapter maps `:constraint_rowid` beside
  `:constraint_primary_key` (unique name, derived or real). The live
  pin accepts both the empty 0.11.0 shape and the parsed one, so the
  dep bump past 0.11.0 flips nothing.

- [F-B1-12] (S2, FIXED, from Run 51) `structure_dump/2` raised a
  bare `ErlangError :enoent` out of `System.cmd/3` when the `sqlite3`
  command-line program is not installed — the bundled library never
  ships it, and nothing documented the requirement — where
  `Ecto.Adapter.Structure` promises `{:ok, path} | {:error, term}`
  and `mix ecto.dump` matches only those (a raise skipped its
  "couldn't be dumped" arms and printed a stack trace that never
  named `sqlite3`). The CLI-dependent tests are compiled out on a
  machine without the program (structure_test.exs), so the branch was
  never exercised. FIX: the executable is looked up first
  (`{:error, {:missing_executable, "sqlite3"}}`), the dump directory
  is created and the file written through their tuple-returning
  forms (`{:error, {:cannot_write_dump, path, posix}}`), the shell-out
  keeps the literal command. Pinned (structure_test: the missing
  executable asserted per machine — the tuple where the program is
  absent, `{:ok, path}` where present — and the unwritable path,
  deterministic everywhere). README + STE: `mix ecto.dump` needs the
  `sqlite3` program; `mix ecto.load` does not. Residual: the
  CLI-dependent content tests stay compiled out where the program is
  absent (an environment dependence, not a platform skip; the
  contract pins now run everywhere).
- [B1-1 addendum, Run 51] Fourth member of the destructuring class:
  `structure_load/2`'s `{:ok, conn} = XqliteNIF.open(database)`
  (lib/xqlite_ecto3.ex, after the dump helpers); its error terms are
  prose strings (`{:error, inspect(reason)}`, `"Could not read …"`),
  pinned by text in structure_test.exs:106 — against doctrine, fold
  into the B1-1 remedy as structured tuples.
- [F-B1-13-seed] (S3 seed, B1 court, from Run 51) ecto_sql's Sandbox
  branches on a `{:transaction, conn_state}` return from
  `handle_begin` (sandbox.ex:661-668 — "a connection was not
  appropriately rolled back after use"); reference adapters return
  that 2-tuple status form, this driver never does (no such clause),
  so that diagnostic is unreachable and the same situation ends in a
  disconnect carrying SQLite's raw message. A lost diagnostic, not a
  wrong outcome; maintainer's call whether to add the arm.
- [F-B1-11-docs addendum, Run 51] Observed verbatim (b1_cover_r51/p03):
  an unnamed column CHECK reports `constraints=[check: "v > 0"]` — the
  "name" Ecto is handed is the expression text; `enum_check/3` and
  `array_check/2` emit NAMED constraints (`<column>_enum_check`,
  `<column>_array_check`) and do not inherit it.
- [F-B3-4-xqlite addendum, 2026-09-05] FIXED in xqlite (main, after
  0.11.0): the busy slot remembers the `busy_timeout` in effect when
  it is taken, emulates SQLite's own retry schedule while observers
  are installed without a policy, restores it when the slot empties,
  and emptying an already-empty slot no longer touches the C handler
  (`remove_busy_policy/1` on a fresh connection used to zero
  rusqlite's 5000 ms default). Adapter follow-up [A2] is unblocked
  once the adapter's xqlite dep moves past 0.11.0.

- [F-B6-11] (S1, FIXED, from Run 52) `datetime_add`/`ago`/`from_now`
  emitted the pre-Run-48 `T…Z` text form while storage moved to
  SQLite's space form; byte-wise text comparison put every stored
  datetime below any same-day interval result, so "rows in the last
  hour" filters silently returned nothing. A regression from
  `0c94064` that CI missed because the shared suite's `datetime_add`
  tests sit behind the over-broad `:microsecond_precision` exclusion
  ([F-B2-8]). FIX: `%Y-%m-%d %H:%M:%f000`; the undocumented
  `:datetime_type` env key deleted. Pinned (datetime_add_form_test:
  emission + rows on usec, second-precision, and utc columns, raw
  `datetime()` control). README + STE state the form.
- [F-B6-11-residual] (S3, B6 court) With one emitted form (six
  fractional digits) an exact-equality boundary against a
  second-precision column misses (`>=` at the exact stored second:
  p14 `ge_sec=[]`), because that column's text has no fractional
  digits. Documented in the README. Remedy candidates: pick the
  format from the operand's precision (a Tagged param's type or the
  field's schema type — `sources` carries the schema), or trim a
  `.000000` suffix in SQL. `datetime_add` over a `TimestampTZ`
  column is not targeted (its own offset-carrying form; documented).
- [F-B6-12] (S1, FIXED, from Run 52) `type(^v, :binary)` rendered
  `CAST(?1 AS BLOB)`; a valid-UTF-8 binary is bound as TEXT and
  SQLite never equates TEXT with BLOB, so the predicate matched no
  row (the write side and the select position were correct). FIX: a
  bare-parameter clause for tagged `:binary` (the inline-literal
  clause already cast the other way on purpose). Pinned
  (typed_binary_param_test: emission refutes `AS BLOB`; UTF-8 and
  raw-byte rows both found).
- [F-B6-13] (S3, FIXED, from Run 52) `values/2` spliced the field
  atom unquoted into `column1 AS <atom>` — `:order` failed as a raw
  `sqlite_failure`, an injection-shaped atom reached the statement
  body; the reference adapter has the identical splice. FIX:
  `quote_name/1` on the alias; the delete_with_join emission pin
  flipped. Pinned (values_alias_quoting_test).
- [F-B4-seed-dead-shift-fallback] (S3, B4 court, from Run 52)
  `query.ex` `encode_param(%DateTime{})`'s `{:error, _} ->
  DateTime.to_iso8601(dt)` branch is unreachable — shifting to
  `Etc/UTC` needs no time zone database (measured under
  `Calendar.UTCOnlyTimeZoneDatabase` with a hand-built Europe/Sofia
  struct: `{:ok, ~U[… 11:30:00Z]}`) — and if it ever fired it would
  store a THIRD text form (offset-carrying ISO-8601) that compares
  against nothing. Delete it or turn it into a refusal; never a
  silent third form.
- [F-B2-8 addendum, Run 52] The over-broad `:microsecond_precision`
  tag excludes the shared suite's `interval.exs` `datetime_add`
  tests wholesale — that is how F-B6-11 (S1) shipped past CI.
  Narrowing the tag is now worth more than the four location tuples
  it costs.
- [F-B8-16 / F-B8-18 xqlite halves, 2026-09-05] Both landed in xqlite
  main (`c85d0ae`, ships after 0.11.0): `query`/`execute` (and the
  `_with_changes`/`_cancellable` variants) refuse whitespace- or
  comment-only SQL with `{:cannot_execute, "SQL contains no
  statement"}` like `prepare/2`, so the `statement_cache_size: 0`
  path stops answering SQLITE_MISUSE once the dep moves; and
  `stmt_prepare`, `stream_open`, `explain_analyze` classify a syntax
  error through one shared builder that applies rusqlite's byte-offset
  rule, so the cached path yields `:sql_input_error` exactly like the
  one-shot path. The adapter's pins on the 0.11.0 shapes are
  unaffected until the dep bump; re-pin both when it happens.

- [F-B5-33] (S2, FIXED, from Run 53) Run 44's baseline diff masked
  any violation whose `foreign_key_check` row equals a pre-existing
  one: a WITHOUT ROWID child reports every violation with a `nil`
  rowid (one orphan there masked all later violations of that table),
  and `INSERT OR REPLACE` at an orphan's rowid reproduces the orphan's
  row. The diagnosis came back `:ok` + `[]`, so `to_constraints/2`
  emitted `[]` and a declared `foreign_key_constraint/3` raised. FIX:
  an empty diff over a non-empty check reports `{:unavailable,
  :masked_by_baseline}` (`unmasked/2`); a genuinely empty post-replay
  check stays `:ok`. Pinned (fk_diagnostics_test: WITHOUT ROWID mask,
  reused rowid). Moduledoc step 4 rewritten.
- [F-B5-33-followup] (S3, B5 court) The fuller remedy: diff the two
  `foreign_key_check` scans by `{child_table, fk_id}` group COUNTS
  (post − baseline = the statement's own), which recovers the WITHOUT
  ROWID case exactly; rowid reuse still needs the degrade underneath.
  Probe the documented re-break case after landing either.
- [F-B5-34] (S2, FIXED, from Run 53) A `COMMIT` issued through
  `Repo.query` reaches `handle_execute/4`, so a deferred violation
  surfacing there was replayed as a statement by `wrap_with_replay/4`
  (no names, `{:unavailable, …}`) and `cleanup/1` then reset
  `defer_foreign_keys` on the caller's still-open transaction (SQLite
  keeps it open after a failed commit) — every later statement in it
  enforced immediately, under the diagnostics flag only. FIX:
  `wrap_execute_error/4` routes COMMIT/END/RELEASE to
  `wrap_at_commit/2` (rows still present, no replay, no pragma).
  Pinned (fk_diagnostics_test: raw BEGIN → defer → violation → COMMIT
  → `:ok` + the child's violation + the pragma still 1).
- [F-B5-17 addendum, Run 53] Sharpened: the recovered names DO reach
  a changeset through `Ecto.Multi` (`{:error, step, changeset, _}`
  with `constraint: :unique`) and outside a transaction; only the
  bare-function `Repo.transaction(fn -> Repo.insert(cs) end)` body
  loses them to `{:error, :rollback}` (p09).
- [F-B5-27-commit addendum, Run 53] Reproduces exactly (an unrelated
  pre-existing orphan appears in a committing transaction's
  violations, p03 leg B). NEW cross-court: the commit path leaves
  `statement: nil` on the error (`wrap_commit_error/2` never calls
  `put_statement/2`) — X1's stamping work, not re-filed here.
- [F-B5-7 addendum, Run 53] The closed-set pin is now cheap: outer
  sets `unique_index_lookup :: :not_run | :ok | {:unavailable, term}`
  and `fk_diagnostics :: :not_run | :ok | {:truncated, n} |
  {:unavailable, term}` are typespec-pinned; the adapter-produced
  reasons are `{:too_many_unique_indexes, n}`,
  `{:lookup_budget_exceeded, ms}`, `{:index_vanished, name}`,
  `{:unexpected_check_row, row}`, `:masked_by_baseline`, plus raw NIF
  terms passed through. One pattern test per field + narrowed
  typespecs; no new code.
- [B6-docs-seed] (S3 docs, from Run 53) `insert_all` + `on_conflict`
  against a partial or expression unique index fails with SQLite's
  "ON CONFLICT clause does not match any PRIMARY KEY or UNIQUE
  constraint" (engine parity — `conflict_target` renders columns
  alone); Ecto's `conflict_target: {:unsafe_fragment, "(a) WHERE b IS
  NULL"}` works and nothing in the README or migration guide says so.

## Feature follow-ups (owed, not review findings)

- [A2] hooks config `:busy` kind + busy-aware concurrency docs —
  unlocked by xqlite 0.9.0's busy split.
- [A3] Optionally migrate raw `XqliteNIF.txn_state/connection_stats`
  doc references to the new `Xqlite` wrappers (additive, optional).
- [A5] (Dimi, 2026-09-05: "why not `Repo.transact` instead? … maybe
  for later") Adopt `Repo.transact/2` (Ecto ≥ 3.13; the `~> 3.14`
  pin has it) as the transaction idiom in the README, the guides,
  and the adapter's own tests where `Repo.transaction/2` is used for
  its result — `transact` rolls back on an `{:error, _}` return
  instead of `Repo.rollback/1`, and forwards the same `mode:` opts,
  so it exercises the identical `handle_begin` path (the top-level
  `mode: :savepoint` refusal and the busy-begin behavior are
  unchanged by it). Keep `transaction/2` where its raise/rollback
  semantics are the point. Not a driver change; do it as one docs +
  tests pass after lap 7, never mid-run.

## Closed

- 2026-09-01 [F-X1-7] (S3, from Run 41) CLOSED at Run 49's gate:
  `handle_fetch/4` now binds the query DBConnection passes and
  stamps the failing SQL onto the error — a mid-stream constraint
  violation names its statement like declare- and execute-time
  failures (trace-proven that the query arrives; pinned in
  stream_test). Run 40's "the cursor does not carry the SQL"
  rationale was true and irrelevant — the query does.

- 2026-09-01 [F-B1-5] (S3, from Run 33) CLOSED as
  discard-unreachable at Run 46's gate: xqlite's
  `take_and_finalize_raw` (stream.rs:66) deliberately discards
  `sqlite3_finalize`'s echo of the last evaluation error — commented
  as such in the Rust — so the only returnable failures are a
  poisoned Mutex (a panic already happened) or an invalid handle
  (impossible from handle_deallocate, which passes cursor.handle).
  Four constructions across Runs 37+46 (double-close, closed-conn,
  mid-step runtime error, schema change under an open stream) all
  return :ok — the adapter's `_ =` has nothing reachable to swallow,
  and the :ok stop event is truthful (the close genuinely
  succeeded). REOPEN TRIGGER: xqlite ever propagating the finalize
  code from take_and_finalize_raw. (Runs 33/37/46)

- 2026-09-01 [F-B6-9] (S3, from Run 43) CLOSED at Run 45's gate: the
  keyword-list decision it waited on was made by F-B7-50's fix — the
  full www.sqlite.org/lang_keywords.html list as
  `DataType.@sqlite_keywords`, shared by `bare_typename?/1`. A
  passthrough spelling containing any SQLite keyword now raises
  `UnsupportedTypeError` (`add :x, :set` included); the rebuild's
  carried stored types QUOTE instead (an existing column's spelling
  is data, a migration atom is a request). Pinned in data_type_test.

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
  CLOSED ENTIRELY (Run 36): the Run-28 blanking pass had itself
  opened a worse door — an apostrophe inside a comment paired with
  the next literal's opening quote and erased real DDL from the scan
  (F-B7-42, S1: silent CHECK and AUTOINCREMENT loss on tables with
  an English contraction in a schema comment). The fix teaches the
  same one-pass alternation the two comment forms, blanking each to
  one space — which simultaneously makes comment-interleaved
  keywords (`ON /* c */ CONFLICT`, `PRIMARY /* c */ KEY`) visible to
  the scans, closing this entry's comment half: the ruling's
  "comment must sit BETWEEN the keywords" bound had stopped
  describing the class anyway. No fine-print docs line owed anymore;
  the honesty-ledger entry is superseded.
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
