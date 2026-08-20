# Review axes — xqlite_ecto3 (+ cross-repo)

Adapter axis list for the adversarial review program. The program
constitution (waves, hard rules, ratified S0–S2 blocker bar,
tiering, dryness) lives in `xqlite/REVIEW_AXES.md` — it governs this
file too. Charter: `~/kod/FLEET_REVIEW_BOOT.md`.

## Axes

Fields: why it bites here · authoritative sources · seed probes ·
coverage state.

### B1. Behaviour conformance from source
Ecto.Adapter / .Queryable / .Schema / .Transaction / .Migration /
.Structure + DBConnection callbacks verified against `deps/` SOURCE,
never docs-from-memory. Coverage: Run 1 covered the full behaviour
diff (Adapter/Schema/Queryable/Transaction/Storage/Structure/
Migration + the 17 SQL.Connection cbs) — arity guaranteed by the
warnings-as-errors compile, override return-shapes checked, CLEAN
bar one nit (B1-1: `dump_cmd/3` raises but is unreachable). NOT DRY
(one covering pass). Re-wets on: any new `@behaviour`, any override
of a SQL-adapter default, an Ecto/ecto_sql minor bump, a DBConnection
callback-contract change.
COVERING RE-RUN (Run 5, 2026-07-20 — dryness pass 1): the churn (Runs 2–4 fixes)
re-wet B1 — it changed SQL.Connection override internals (limit/2, quote_entity/1,
escape_string/1, json_extract_path) and DBConnection-facing behavior (disconnect/2
now emits reason; encode_param can raise DecimalPrecisionError inside
`DBConnection.Query.encode/3`; finish_cached_stmt result shaping). Re-verified the
churn-touched overrides' SEMANTIC return shapes LIVE this run: direct-call SQL
census 6/6 (limit nil+offset→`" LIMIT -1"`, plain→`[]`; quote_entity doubles `"`;
escape_string keeps `\` single; reference_on_delete `{:nilify,cols}` raises loud,
`:nilify_all` still emits the clause) + churn-cluster test re-runs 171/171
(json_extract quoted-label, disconnect `reason`, cached-stmt `changes`-delta,
decimal encode-raise). The encode-raise path re-confirmed from db_connection
SOURCE: a raise out of `Query.encode` is caught in `encode/5` (`db_connection.ex:1457`),
the connection is KEPT (`raised_close`→`run_close` closes only the query via
`:handle_close`; only `DBConnection.EncodeError` diverts to re-prepare), and the
exception surfaces UNCHANGED via `:erlang.raise` at `log_result` (`:1732`). Zero
new findings. DRYNESS: **NOT DRY** — first clean covering run over the Runs-2–4
churn (1 of 2), one more owed. Re-wet triggers UNCHANGED.
COVERING RE-RUN (Run 9, 2026-07-21 — dryness lap 2, batch 1): covering pass over
the post-Run-5 churn. The runtime JSON-path escape fix (`53599f4`) verified as a
SQL.Connection product via live `to_sql` census (orchestrator re-ran, exit 0): the
runtime branch emits `replace(replace(seg, '\', '\\'), '"', '\"')` —
backslash-before-quote, mirroring `escape_json_key` — and mixed literal+runtime
paths escape each segment independently under `||` in BOTH compose orders (no
double-escape). `driver.ex` (finish_cached_stmt / disconnect) untouched in the
churn (`git diff 5a411ee..6539a14` empty on its path) — Run 5's shape verification
stands. Rebuild-engine Migration conformance from deps/ecto_sql source:
`execute_ddl` returns `{:ok, []}` (the migration.ex:61 contract),
`lock_for_migrations` returns `fun.()`; both pre-flight refusals run only READ
queries before the destructive statement list. `config/test.exs` telemetry flag
defaults ON when the env var is unset — behaviour-neutral (gates emission only).
Zero new findings. DRYNESS: **DRY (2 of 2)** — second consecutive clean covering
run. Re-wet triggers UNCHANGED.

### B2. Exclusion-list audit
Every excluded integration test is a standing "not supported" claim.
Sources: test_helper.exs excludes (19 entries, 18 well-documented),
ECTO_INTEGRATION_TAGS.md, vendored suites in deps/, ecto_sqlite3's
own exclusion list (each divergence = verify or justify). Seed
probes: **the two-tag status probe** (`:transaction_checkout_raises`,
`:values_list` — ledger says "needs work", no exclusion exists;
either quietly passing or the suite isn't green); ledger
reconciliation (orphaned `:concurrent_poolrepo_transactions`; stale
`:foreign_key_constraint` row — feature shipped; stale headers).
Coverage: Run 4 did the full disposition — enumerated all 19 exclusions,
ran every non-obvious one un-excluded to classify by ground truth
(18/19 legit-limitation, all failing exactly as claimed; 0 stale
exclusions). The two-tag probe RESOLVED: `:values_list` (5 passed, incl.
`delete_all`) and `:transaction_checkout_raises` (1 passed) both quietly
pass — their `ECTO_INTEGRATION_TAGS.md` rows were STALE (corrected +
header refreshed). Found F-B2-1 (S2, FIXED) behind the type.exs:362
exclusion — compile-time `json_extract_path` emitted bare `$.<key>` not
quoted-label `$."<key>"`, so keys with `.`/`"`/`\` silently returned nil;
after the fix that exclusion fails only at its documented boolean line.
Corrected logging.exs:74's factually-wrong rationale (handler DOES fire;
real cause is TEXT UUID storage). NOT DRY (one covering pass). Re-wets on:
any new exclusion, any `escape_json_key`/`json_extract_path`/
`dynamic_json_path` change, an Ecto/ecto_sql minor bump that adds/renames
shared cases, a `binary_id_storage` default change.
COVERING RE-RUN (Run 8, 2026-07-21 — dryness pass 4): the owed characterization of the
runtime-expression branch surfaced a NEW CONFIRMED finding. **F-B2-2 (S2, CONFIRMED +
FIXED, RED→green).** Run 4 fixed the compile-time literal branches and believed the
runtime `dynamic_json_path` branch already correct (it wraps in `."…"`), but that branch
escapes NOTHING: it emits `$."<raw value>"`, so a runtime JSON key value containing a `\`
silently extracts nil — SQLite treats `\` as a JSON5 escape inside the quoted label
(bundled 3.53.2: `$."back\slash"` → nil vs the compile-time-escaped `$."back\\slash"` →
"bv"). A runtime double-quote key was nil too (that case was DOCUMENTED-unsupported; the
backslash case was UNDOCUMENTED + silently wrong — same mechanism-class as F-B2-1, a
different code path). Proven end-to-end via the real adapter/repo
(`json_extract_path_test.exs` +2). Fixed by escaping the runtime value for the JSON5
quoted-label grammar with nested `replace(replace(seg,'\','\\'),'"','\"')`, mirroring
`escape_json_key` — dot/backslash/quote runtime keys all resolve now (the fix also closes
the previously-documented double-quote limitation; moduledoc caveat dropped). Exclusion
drift CLEAN (19 exclusions = 14 tags + 5 locations, `git log 5b32d11..HEAD` on
test_helper.exs/ECTO_INTEGRATION_TAGS.md shows only Run 4's own fix; the two stale-row
tags re-isolated `values_list` 5 / `transaction_checkout_raises` 1, matching Run 4). No
exclusion rationale is connection-lifecycle-sensitive (all rest on SQLite grammar/
storage-class/architecture invariants; the one per-connection setting, `foreign_keys`,
backs no exclusion) — reconnect re-check is a B2 no-op, recorded. G2 remainder CLOSED
(dropped orphaned `:concurrent_poolrepo_transactions`, rewrote `:foreign_key_constraint`
excluded→supported after `--only foreign_key_constraint` ⇒ 6 passed). DRYNESS: a NEW
confirmed (F-B2-2) surfaced, so NOT a clean covering run — **B2 stays at 0 of 2 clean
covering runs, NOT DRY**; the runtime-escape fix re-wets. Re-wet triggers UNCHANGED.
COVERING RE-RUN (Run 12, 2026-07-21 — dryness lap 2, batch 4; the exclusion lens —
Runs 9/10 covered the F-B2-2 escape via the contract/translation lenses). Drift
reconciled: `test_helper.exs` unchanged in `811d544..458dc0c`; the tags-doc delta =
exactly Run 8's two corrections; count re-enumerated 19 (14 tags + 5 locations).
`type.exs:362` un-excluded fails ONLY at its documented boolean line (384:
`o.metadata["enabled"] == true` → `1`); every JSON-path SELECT before it passes,
incl. single-/double-quoted keys — the escape fixes hold under the exclusion lens.
**F-B2-3 (S2, CONFIRMED + FIXED): the `:like_match_blob` exclusion was STALE** —
its rationale claims the build carries `SQLITE_LIKE_DOESNT_MATCH_BLOBS`, but the
bundled 3.53.2 does NOT (compile_options probe: absent; `LIKE x'000102'` on a BLOB
column MATCHES; `:binary` maps to BLOB), so both tagged tests pass un-excluded — a
false "not supported" claim. Root of the miss: Run 4 dispositioned it "legit
(reasoned from source)" without verifying the flag; this run falsified it
empirically. Fix: exclusion removed (now 18 = 13 tags + 5 locations), tags-doc row
→ supported. Fresh legit re-confirmations (5): on_delete_nilify_column_list (loud
ArgumentError), map_type_schemaless (raw JSON TEXT), insert_cell_wise_defaults,
assigns_id_type, alter_primary_key + alter_foreign_key (loud). Run-11 rebuild
churn is modify-only — un-staled no ALTER exclusion. DRYNESS: a NEW confirmed +
an exclusion-list change (a listed re-wetter) → NOT a clean covering run — **B2
stays 0 of 2, NOT DRY**. Re-wet triggers UNCHANGED.
COVERING RE-RUN (Run 16, 2026-08-20 — the full-disposition pass; every tag run
in isolation, every location isolated via the banked `mix test path:line`
method): SEVEN findings. **F-B2-4 (S2, root-FIXED):** the Run 15 transaction
guard broke the vendored alter.exs suite (drives Runner directly, no txn) —
suite RED at HEAD behind a red-then-skipped gate; fixed by the SELF-WRAP
(rebuild opens its own transaction when none wraps it) — suite 434/434 green,
alter.exs:44 back on its original documented mechanism. **F-B2-5 (S2, FIXED):**
`:insert_cell_wise_defaults` hid 7 passing tests of 8 → narrowed to
repo.exs:864. **F-B2-6 (S2, doc-FIXED):** transaction.exs:161 fails from the
suite's pool_size 1 + BEGIN IMMEDIATE default, not SQLite (passes at pool ≥ 2
with :deferred; ecto_sqlite3 corroborates) — rationale now owns the trade-off.
**F-B2-7 (S2, doc-FIXED + code gap filed):** the three ALTER rationales blamed
SQLite; the real blocker is `modify` with `references(...)` having no
`DataType.column_type` clause (maintainer menu — may collapse three exclusions).
**F-B2-9/10/11 (S3, FIXED):** wrong lock_for_migrations file pointer; two stale
"needs adapter work" doc rows; the location exclusions got a public table; the
`:binary` storage-class wording corrected. **F-B2-8 (S3, BACKLOG):**
:array_type / :microsecond_precision over-broad by one each (counts filed, not
churned). Exclusion list now 18 = 12 tags + 6 locations. DRYNESS: finding-run —
**B2 stays 0 of 2, NOT DRY**. Re-wet triggers EXTENDED: the rebuild engine's
refusal set, `default_transaction_mode`, the suite's pool_size, and
`DataType.column_type/2`'s accepted types. Next-pass seeds: the
frame-attribution rule (stack in lib/xqlite_ecto3/ ⇒ "our gap", never
"SQLite's limit") as a standing check; the hidden-vs-failing count sweep each
pass; whether column_type learning `%Ecto.Migration.Reference{}` collapses the
ALTER exclusions.
COVERING RE-RUN (Run 24, 2026-08-20 — lap 3, the second cover; the fired
re-wetters audited): the refusal-set churn (Run 22) invalidated three
rationales exactly as Run 16 predicted. FIXED as docs: **F-B2-12 (S2)** the
ALTER trio + four doc rows blamed the now-UNREACHABLE `column_type` gap
(the up-front reference refusal fires first) — reworded to name
`refuse_reference_changes!` + F-B7-25-feature, F-B2-7-code folded as
superseded; **F-B2-14 (S2)** `:duration_type` blamed SQLite while the
raiser is OUR `encode_param/1` is_map→Jason catch-all on `%Duration{}` —
reworded; adjacent struct-param classification gap filed to the B4 court
([F-B2-14-adjacent]); **F-B2-13 (S3)** the :705 half never enters the
rebuild (plain-ALTER SQLite refusal) — block now separates the two causes;
**F-B2-15 (S3)** the migrator pointer named the `@tag` line and the line
filter SNAPS to the preceding (passing) test — false all-clear generator;
pointer fixed, F-B2-8 citations corrected, snap rule codified in helper +
tags doc; **F-B2-16 (S3)** the `:array_type` row understated shipped
support — now names the real gap (Postgres operator surface + untyped
decoding); the three self-fulfilling isolate-runs (shared migration skips
their tables) recorded as a method caveat. CLEAN: all other rationales
truthful at HEAD; six locations re-verified; Run 23's guard a no-op for
the vendored surface; count sweep = exactly the two known singles; anchor
`434 passed / 32 excluded`, zero delta. DRYNESS: finding-run (doc-class)
— **B2 stays 0 of 2, NOT DRY**. Re-wets ALSO on: `Query.encode_param/1`
clauses / the shared support migration's exclusion-awareness list.
Next-pass seeds: adapter-owned probes breaking the self-fulfilling three;
the "supported (n/m)" row counts re-check; line-pointer discipline
standing; upstream-bump watch on the new refusals.

### B3. Sandbox + pooling under a single writer
The week-one adopter surface. Probes: `:memory:` pooling trap (do we
guard pool_size > 1 like ecto_sqlite3 raises? UNKNOWN — probe);
connect-time PRAGMA storms under pool cold-start (file-level
serialization class); wedged-txn-state symmetry after failed ops
(commit vs rollback status reset); busy storms under `async: true`
app suites; Sandbox ownership semantics. Coverage: Run 2 ran the
`:memory:`-guard probe → F-B3-1 (S3, BACKLOG): no guard on
private-`:memory:` + a multi-conn pool, default-reachable (Ecto pool
10; the adapter's `@default_opts pool_size: 5` is dead), yielding a
scattered per-connection database. Baseline sandbox checkout/rollback
isolation + concurrent checkouts covered by the passing async
AdapterCase suite; failed txn ops disconnect-and-reconnect (no wedged
reuse). Storm probes (PRAGMA storm, busy storms) + shared-mode-across-
processes still owed. NOT DRY. Re-wets on: any `child_spec`/pool-option
change, a `connect/1` pragma-sequence change, a DBConnection bump.
COVERING RE-RUN (Run 6, 2026-07-20 — dryness pass 2, the owed storm probes): ran
the owed storm + shared-mode probes live. Connect-time PRAGMA storm — pool_size
15 on a fresh non-WAL file, 300 concurrent inserts fired immediately → CLEAN
(300/300 ok, 15/15 connect ok, 0 errors, ~37 ms; the connect-time `busy_timeout`
set before the `journal_mode` write absorbs the WAL-header contention). Busy
storm — pool_size 8, 200 concurrent write txns on ONE hot row → 200/200 ok, final
counter EXACTLY 200 (no lost updates, serialized via WAL+busy_timeout), pool
healthy; and a forced busy (200 ms timeout vs 1500 ms held lock) surfaces a
STRUCTURED `{:database_busy_or_locked, ext 5}` with the pool still healthy/writable
— nothing uglier. Sandbox shared mode across processes — `{:shared, self()}` AND
`allow/3` both let a spawned Task share the owner's sandbox connection
bidirectionally, with rollback isolation preserved (post-checkin count 0). Busy
-POLICY API determination: adapter uses ONLY the `busy_timeout` PRAGMA
(`driver.ex:63`), never `set_busy_policy`/`max_retries`/`max_elapsed_ms` — so
xqlite main's busy per-event-elapsed change does NOT touch the adapter at 0.10.0
(CLOSED). ONE new S3 → BACKLOG: **F-B3-2** — cold-start racing an externally-held
write lock (migrations at boot on a fresh non-WAL file) emits `[error]`-level
connect-failure logs (`{:database_busy_or_locked, 5, …}`), self-healing (queries
succeed, WAL persists, later boots clean) but UNDOCUMENTED; the test suite already
pre-sets WAL for exactly this. Wedged-txn-state symmetry re-confirmed from source
(failed begin/commit/rollback → `{:disconnect,…}`, never reused). DRYNESS: a new
CONFIRMED S3 surfaced, so NOT a clean covering run — **stays at 0 of 2, NOT DRY**.
Re-wets ALSO on: any connect-time `journal_mode`/`busy_timeout` ordering change.
REMEDY (2026-07-21 — maintainer ruling F-B3-2): DOC-ONLY (skip-when-already-WAL
changes nothing; the fresh-file first boot must flip regardless). Added a README
"First-boot WAL noise on a fresh database" section (symptom + harmless/self-healing
rationale + three mitigations). NO code change, so B3 is NOT re-wet — its re-wetter
list is UNCHANGED.
COVERING RE-RUN (Run 10, 2026-07-21 — dryness lap 2, batch 2): connect with-chain
(`driver.ex:54-88`: busy_timeout before journal_mode before foreign_keys)
verified UNCHANGED in range (git log empty on driver.ex; the F-B3-2 remedy was
README-only). Standing storm surface re-driven deterministically (exact-count
invariants, monitors, bounded polling, ceilings ≥10×): cold-start PRAGMA storm
(pool 12, fresh non-WAL file, 300 immediate concurrent inserts → 300/300 ok,
0 errors, journal_mode=wal after); hot-row busy storm (pool 10, 200 concurrent
write txns on ONE row → final counter exactly 200, pool healthy after); forced
busy (200 ms timeout vs a held write lock → structured
`{:database_busy_or_locked, …}`, writable after release); sandbox
`{:shared, owner}` AND `allow/3` bidirectional with rollback isolation (fresh
checkout sees 0). NEW angle (Run 6's unprobed owner-death): a task killed
`:kill` MID-TRANSACTION → the uncommitted write rolls back (count 0), the pool
stays healthy (60/60 subsequent writes), no wedged connection. All probes
re-run by the orchestrator (exit 0). Zero new findings. DRYNESS: **first clean
covering run — 1 of 2, NOT DRY**, one more owed. Re-wet triggers UNCHANGED.
COVERING RE-RUN (Run 13, 2026-07-21 — mini-lap batch 1, the two owed critic
seeds): `driver.ex` UNCHANGED through `3c58c5c`. Storm subset re-driven
deterministically (300/300 cold-start; exact-200 hot-row; orchestrator re-ran,
exit 0). Seed (a) CLOSED CLEAN: a saturated pool sheds 20/20 excess callers as
structured `%DBConnection.ConnectionError{}` queue-wait timeouts, 0 crashes,
the pool recovers, the holder's txn commits on release, no wedge. **F-B3-3
(S2, CONFIRMED + FIXED AT GATE, RED→green):** seed (b) — a rebuild migration
under `Ecto.Adapters.SQL.Sandbox` succeeded but leaked
`defer_foreign_keys = ON` (the sandbox's outer txn never commits, so SQLite's
commit-time auto-reset never fires), after which an orphan FK insert was
SILENTLY ACCEPTED (pre-rebuild control rejected; a non-sandbox control leaves
the flag 0 and rejects — sandbox-specific; bounded to the session, a fresh
checkout reads 0). Ruled at the ORCHESTRATOR GATE (ratified bar: an S2
silent-enforcement-loss does not sit unfixed; same posture as the A4 gate
correction; the remedy is one line with a control-proven no-op on committing
transactions): `rebuild_table` now resets `PRAGMA defer_foreign_keys = OFF`
after a clean `foreign_key_check`. Side effect: rebuilds are now VIABLE under
the sandbox (the A4-era "sandbox unusable for rebuild tests" note is
obsolete). RED→green: `table_rebuild_test.exs` +1 on the sandboxed TestRepo
(post-rebuild pragma reads 0 + an orphan raises structured
`XqliteEcto3.Error`; RED = 11/12 failing exactly on the leaked pragma; GREEN =
12/12; the seed probe's verdict flips SILENT_WRONG_STATE → CLEAN — all
orchestrator-run; preservation suite 15/15 unchanged). Maintainer may overrule
(one-line revert). DRYNESS: a NEW confirmed surfaced → NOT a clean covering
run — **B3 RESETS to 0 of 2, NOT DRY** (the reviewer's stays-at-1 proposal was
overruled at gate; the chain rule as B5/B9). Re-wets ALSO on: any
`defer_foreign_keys` handling change in `rebuild_table`.
COVERING RE-RUN (Run 23, 2026-08-20 — lap 3, 0.11.0 delta absorption):
**F-B3-5 (S1, FIXED, RED→green)** — the ON-CONFLICT-ROLLBACK seed settled
AGAINST the code: the violated constraint rolls back the whole SQLite
transaction while the driver's bookkeeping keeps going, so later body
statements ran in autocommit and COMMITTED DURABLY inside a transaction
that reported failure (idiomatic-changeset reachable). Fix:
`handle_execute`'s error path asks `NIF.transaction_status/1` while a
transaction is supposed to be open and disconnects at the point of damage
(absorbs F-B3-6, the discriminator-less commit error). **F-B3-4 (S2)** —
a busy observer via `with_xqlite` replaces the busy slot and permanently
disables the configured `busy_timeout` on that pooled connection
(unregister does NOT restore); adapter docs fixed (`with_xqlite`
connection-scoped-state warning naming `Xqlite.busy_timeout/2` as
restore), xqlite-side fork filed (BACKLOG, xqlite court). CLEAN: busy-API
determination re-confirmed at 0.11.0 (no policy API; only the Run-21
budget READ is new), dirty-reader flip neutral under storm, standing
storms exact-count green. DRYNESS: S1+S2 — **B3 stays 0 of 2, NOT DRY**.
Re-wets ALSO on: `disconnect_if_rolled_back/2` / any `handle_execute`
error-path change / `with_xqlite/3` checkout semantics. Next-pass seeds:
F-B3-5 × SQL Sandbox; the connection-scoped-state family through
with_xqlite; F-B3-4 at pool_size > 1; cancelled-DML auto-rollback (with
the B8 re-cover); a cross-process contention wedge.

### B4. Type round-trips as properties
dump → store → load == identity per Ecto type (StreamData);
encode-only load paths pinned explicitly; Decimal precision path
(anything silently through REAL = data-integrity class); UUID
BLOB/TEXT interop + joins; JSON fidelity incl. key-type round-trip +
double-encode pin (object lands, not escaped string); usec
truncation; offset-preserving DateTime inherited semantics (format
drift between stored form and bound-param comparisons —
wrong-results class). Coverage: Run 3 built dump→store→load matrices
for every primitive + custom type through the real repo
(`types_roundtrip_matrix_test.exs`) — all round-trip (`:float` NUMERIC
affinity stores `1.0` as INTEGER but Ecto's loader re-floats it; atom-key
maps come back string-keyed, PINNED). Found F-B4-1 (S1-severity, silent
data transformation): a `:decimal` migration column (DECIMAL/NUMERIC
affinity) coerces the TEXT param to float64, so decimals beyond ~15
significant digits SILENTLY truncate. No clean fix — TEXT storage
preserves precision but makes bare range queries lexical (proven live);
common money round-trips. Shipped a loud moduledoc + comment fix + pin
test; remedy (opt-in TEXT / loud-reject / doc-only) is a maintainer call
→ BACKLOG. The old `types_test.exs` masked it with a hand-rolled TEXT
decimal column. NOT DRY. Re-wets on: any `column_type(:decimal/:float)`
change, a loaders/dumpers clause change, a new custom type, a
`Query.encode_param` change.
RE-WET 2026-07-20 by the F-B4-1 remedy: the maintainer ruling (LOUD REJECT
beyond precision) added `XqliteEcto3.DecimalPrecision.representable?/1` and
a raise in `Query.encode_param` (a listed re-wetter). The "silently
truncate" behaviour above is now REMEDIED — a beyond-float64 `Decimal`
raises `XqliteEcto3.DecimalPrecisionError` instead; numeric storage kept, so
money/ordering still work (see REVIEW_LEDGER Remedy 2026-07-20 for the
guard-vs-SQLite verification table). Needs a fresh covering pass on the
new guard's boundary (the guard table exists in `decimal_precision_test.exs`;
a next pass could add `stream_data` fuzzing around the ~15-sig threshold).
COVERING RE-RUN (Run 7, 2026-07-21 — dryness pass 3, covering the decimal-remedy
churn): the `stream_data` fuzz shipped. Added `{:stream_data, "~> 1.1", only:
[:test]}` (fetched via the sanctioned HEX_HOME; xqlite dep stays 0.10.0 hex) and a
property in `types_roundtrip_matrix_test.exs`: for arbitrary finite Decimals
(sign × coefficient[1..25 digits] × 10^[-20..20], straddling the ~15–17-sig
threshold), an insert through a REAL DECIMAL column either round-trips exactly
(guard accept) or raises `DecimalPrecisionError` (guard reject) — never a silent
mismatch. GREEN across 10 seeds (~1000 distinct values against the bundled C SQLite)
— no guard false-accept found. GUARD-vs-SQLITE cross-check re-verified BY MY OWN
runs (subagent history inadmissible): 6 values (19.99 / 9999999999999.99 /
3.141592653589793 accept; 12345678901234567890.12345 / 0.12345678901234567 /
18446744073709551615 reject) each cross-checked guard verdict ⟺ repo round-trip ⟺
raw-SQL SQLite typeof/value — all CONSISTENT. One-way pins re-confirmed
(Instant ns-truncation, TimestampTZ zone-collapse to Etc/UTC, atom-keys→string all
green). Zero new findings. DRYNESS: Run 3 found F-B4-1 (confirmed S1, since
remedied); this is the **first clean covering run over the remedy churn, 1 of 2, NOT
DRY**, one more owed. Re-wet triggers UNCHANGED (any `column_type(:decimal/:float)`,
loaders/dumpers, custom type, or `encode_param` change).
COVERING RE-RUN (Run 11, 2026-07-21 — dryness lap 2, batch 3): `data_type.ex` /
`decimal_precision.ex` / `query.ex` (encode_param) / the loaders-dumpers ZERO
commits in `828bb95..6539a14` (git-confirmed at gate — the range's only lib
churn is the rebuild path). Matrix + guard table + one-way pins green (55
tests); the decimal `stream_data` property green across 10 fresh seeds; a FRESH
6-value guard cross-check (guard verdict ⟺ repo round-trip ⟺ raw typeof) fully
consistent — including `1.2345678901234567` (17 significant digits yet genuinely
float64-exact → correctly ACCEPTED, demonstrating the guard is
representability-exact rather than a digit-count heuristic), plus 2^52 and 2^-13
accepts and 18/19-sig rejects. Probes re-run by the orchestrator (exit 0). Zero
new findings. DRYNESS: **DRY (2 of 2)** — second consecutive clean covering run.
Re-wet triggers UNCHANGED.
RE-WET (2026-08-20): the 0.11.0 dep bump + its own F-B4-2 fix (`be44463`,
the guard now mirrors NUMERIC integer demotion) + the law-generator oracle
change (`787ea23`).
COVERING RE-RUN (Run 25, 2026-08-20 — lap 3, the oracle attacked from
OUTSIDE the generator's guard-filter): **F-B4-3 (S2, FIXED, RED→green)** —
the guard converted every value through float64 first, but the bind path
sends TEXT and NUMERIC affinity stores an int64-fitting integer literal as
an EXACT INTEGER — so whole numbers past 2^53 were refused (6 over-refusals
in a 26-case harness incl. i64 max, while i64 MIN was accepted as
float64-exact; ZERO false accepts). Fix: a fast-accept keyed on the
RENDERED `:normal` form parsing as an int64 integer literal — the same
value written "…0.0" renders with a point, parses as REAL, and stays under
the float64 model (refuse pin committed). **F-B4-4 (S2, FIXED, RED→green;
closes the B2-filed encoder seed)** — map/list params used `Jason.encode!`,
so structs without `Jason.Encoder` (a `:duration` `%Duration{}`; Ecto
never validates `dump/1` output), nested such structs, and
JSON-unrepresentable values raised raw Jason/protocol errors. Fix: new
`UnencodableParameterError` (value/index/reason) from attempt-then-
structure `encode_json/2` (encoder-bearing structs keep working — no
narrowing); parameter positions threaded through `encode/3`;
`DecimalPrecisionError` gains `index`. CLEAN: zero silent transformations;
`representable?/1` never raises; `internal_encoding_error` classified;
UUID/binary byte-stable at 0.11.0; churn re-anchored (wrap/1 untouched).
DRYNESS: two S2 — **B4 RESETS to 0 of 2, NOT DRY**. Re-wets ALSO on:
`integer_literal_in_int64?/1` / `encode_json/2` /
`UnencodableParameterError` / the encode index threading. Next-pass seeds:
a property pinning the fast-accept's rendered-form predicate to the bind
text (and the loader to `stored_decimal/1`); `connection.ex`
`expr(%Decimal{}, …)` (no precision check, unreachable from ordinary Ecto
— dead code or second door?); decimal WHERE comparisons against
INTEGER-stored values; `-0` sign loss; collections of unencodable structs;
the int64-boundary fast-accept adversarially.

### B5. Constraint mapping
Names match what `unique_constraint/3` etc. expect; **PRAGMA
foreign_keys is per-connection and OFF by default — prove enforced
on EVERY pooled connection including after reconnects.** Coverage:
flagship structured errors + rich FK diagnostics shipped and
un-excluded the shared tag. Run 2 triggered every subtype live and
verified the `to_constraints/2` output against Ecto's
`constraints_to_errors/3` matcher: unique/composite/PK/named-index all
derive the `<table>_<col>_index` convention (matches
`unique_constraint/3`); check + not_null map correctly. Found F-B5-1
(S3, BACKLOG): the no-rich-payload FK path returns `[foreign_key: nil]`,
which crashes Ecto's matcher (`String.ends_with?(nil, …)`) under
`match: :suffix`/`:prefix`. NOT DRY. Reconnect-enforcement probe still
owed. Re-wets on: any `to_constraints/2` clause change, a new xqlite
constraint subtype, an Ecto constraint-matcher change.
COVERING RE-RUN (Run 6, 2026-07-20 — dryness pass 2, the owed reconnect probe):
PROVED FK enforcement on EVERY pool member and across reconnects. Every-member:
pool_size 5, 200 concurrent FK-violating inserts → 200/200 structured
`:constraint_foreign_key`, 5 distinct members observed serving, 0 orphans (a
non-enforcing member would insert the orphan). Reconnect PROVEN not inferred:
`Ecto.Adapters.SQL.disconnect_all(repo, 0)` forced a cycle witnessed by BOTH the
`[:xqlite_ecto3, :disconnect]` AND `[:xqlite_ecto3, :connect, :stop]` telemetry
(10 s ceiling, ≥10×); FK still rejected structurally with 0 orphans after two
cycles. No pre-FK-ON serving window: `foreign_keys` set INSIDE the connect `with`
chain (`driver.ex:65`), `connect/1` returns `{:ok,state}` only after the full
chain — the first query on a fresh pool already enforces FK (runtime-confirmed).
Committed the reconnect contract deterministically (`driver_connect_pragmas_test.exs`
+1: disconnect/2 then connect/1 → replacement conn still rejects the orphan +
`foreign_keys==1`). Mapping surface re-read (no churn since Run 2); F-B5-1
UNCHANGED (raw-insert probes didn't exercise the suffix-matcher path — no remedy
sharpening). Zero new findings. DRYNESS: **first clean covering run (1 of 2), NOT
DRY**, one more owed (Run 2 found F-B5-1). Re-wet triggers UNCHANGED.
COVERING RE-RUN (Run 10, 2026-07-21 — dryness lap 2, batch 2): the A4 rebuild
engine now reconstructs UNIQUE as table-level clauses (backed by
`sqlite_autoindex_*`); `to_constraints/2` + `fk_diagnostics.ex` verified
UNCHANGED in range. The mapping proven END-TO-END on a rebuilt table (the
Remedies entry had only reached `to_constraints/2` output): a real
`unique_constraint(:sku)` (single) and `unique_constraint(:name, name:
"rp_uq_name_region_index")` (composite) each CONVERT to `{:error, changeset}`
with the derived conventional name — the autoindex name is transparent because
SQLite reports the table.column message form and the adapter derives
`<table>_<cols>_index`. Column order proven by a reverse-declared
`UNIQUE(region, name)` → `..._region_name_index` (declaration order, not
alphabetical). Standing subtypes re-anchored live (rowid + WITHOUT ROWID PK
derive; partial index derives — matching Ecto's default-name contract;
expression index takes the `index_name` direct path); reconnect-enforcement
contract test green. `table_rebuild_preservation_test.exs` extended with the
changeset conversions. **F-B5-2 (S3, CONFIRMED, BACKLOG) — surfaced by this
run's probes, settled by an orchestrator deciding probe:** a CUSTOM-named plain
(or partial) unique index cannot be matched by its declared name — the
violation carries the table.column form, the adapter derives the conventional
name, so `unique_constraint(:v, name: :my_custom)` misses and Ecto raises
`Ecto.ConstraintError` (control with the derived name converts). Loud, not
silent; expression indexes DO carry their real name. Remedy (document the
naming contract vs synthesize via `index_list`) = maintainer call. DRYNESS: a
NEW confirmed surfaced, so NOT a clean covering run — **B5 resets to 0 of 2,
NOT DRY** (the reviewer's DRY proposal was overruled at gate). Re-wets ALSO
on: any `derive_index_name`/`unique_index_name` change.
REMEDY (2026-08-20 — the F-B5-2 synthesis ruling implemented): new
`XqliteEcto3.UniqueIndexNames` reads the real unique-index names back on the
violation path (`index_list` unique origin-"c" rows; `index_info` exact
ordered column match; sorted+deduped; always-on; pragma failure degrades to
the derived name), riding on two new Constraint fields
(`unique_index_names`, `unique_index_lookup`); `to_constraints/2` emits one
`{:unique, name}` per candidate — resolved names win, the derived
conventional name is the fallback. Ecto's matcher raises on any
emitted-but-undeclared constraint, so ambiguity requires declaring every
candidate, and a bare `unique_constraint/1` against a custom-named index now
raises (Postgres-parity) — both documented in the moduledoc. B5 churned by
its own remedy as planned; the covering runs review the synthesis
adversarially. Re-wets ALSO on: any `unique_index_names.ex` /
`unique_constraints/1` change. Covering-pass seeds: resolution inside an
explicit txn + ON CONFLICT ROLLBACK; `quote_ident` duplication (2×, below
the ≥3× bar); no telemetry span around the lookup (FkDiagnostics has one);
README documents FK synthesis but not unique synthesis (owed docs pass).
COVERING RE-RUN (Run 14, 2026-08-20 — the owed adversarial pass on the
synthesis engine): FIVE new findings — the emission design broke under
sibling indexes. **F-B5-3 (S2, FIXED at gate, RED→green):** emitting every
candidate made a by-the-book `unique_constraint(:v)` raise the moment a
sibling partial or differently-collated unique index existed over the same
columns (the sibling provably innocent — with the conventional index
dropped, the same insert SUCCEEDS under the partial alone). Fix: emit a
real name only when it is the SINGLE candidate; zero-or-several fall back
to the conventional derived name while the struct keeps the candidate
list. **F-B5-6 (S3, reviewer's S2 overruled at gate; HARDENED):** the
lookup is uncancellable post-token work billed to the checkout deadline —
candidate reads now capped at 24/table with structured degradation; the
1500-index kill lever collapsed to control parity on the orchestrator's
re-drive; contention leg (busy-blocked pragma, non-WAL) unproven → seeded.
Filed: F-B5-4 (cross-schema pragma resolution), F-B5-5 (mis-parsed
column list matches a real index), F-B5-7 (lookup-status collapse), a B3
seed (ON CONFLICT ROLLBACK mid-txn COMMIT failure, pre-existing). CLEAN:
explicit-txn resolution, sandbox ownership, exotic identifiers, mixed
expression+column (always `index 'name'` form), insert_all/update/STRICT/
WITHOUT ROWID, FK-diagnostics interplay, standing surface. DRYNESS:
finding-run + fix churn — **B5 stays 0 of 2, NOT DRY**. Re-wets ALSO on:
`capped_matching_indexes/3` / candidacy rules / `wrap_execute_error/4`
cancel-token position / xqlite `constraint_parse.rs`. Next-pass seeds: the
contention leg; conn death between the two pragmas; concurrent DDL racing
the lookup; WITHOUT ROWID × partial × expression crosses.
COVERING RE-RUN (Run 21, 2026-08-20 — lap 3, the post-fix pass over the
Run-14 seeds): the seeds bit — **F-B5-8 (S2, FIXED)**: the contention leg
settled AGAINST the code; rollback-journal contention blocks each pragma
read a full `busy_timeout`, uncancellable (post-token), multiplying up to
25× (44.5 s worst on a 30 s timeout); fix = a per-lookup wall-clock budget
equal to the connection's own `busy_timeout`, checked before every read
(`{:lookup_budget_exceeded, ms}` → derived fallback); WAL immune (probed);
the residual single-read block (= any statement's worst case under that
contention) documented + the full-remedy design fork filed. **F-B5-9 (S2,
FIXED, RED→green)**: autoindexes (`origin "u"/"pk"`) now count as
candidates, so a lone innocent named sibling is no longer blamed for a
table-level-UNIQUE violation; a lone `sqlite_autoindex_*` candidate emits
the derived name (prefix reserved by SQLite). **F-B5-10 (reviewer S2
regraded S3-docs)**: expression-twin creation order decides which name
SQLite reports — Postgres-parity engine surface; the declare-both-names
contract is now in the moduledoc, the structural detect-and-degrade option
filed. Filed F-B5-11 (expression form carries `table: nil, columns: []`);
documented in-run: cap reversion (F-B5-12) + post-hoc schema drift
(F-B5-13). Sharpened F-B5-5 (the first-dot split poisons the DERIVED name
too) and F-B5-7 (a dropped table yields `:ok`/`[]` on the FIRST pragma; a
busy observer is the one existing F-B5-8 mitigation). CLEAN: mid-lookup
connection death (200/200 structured), DDL races, WITHOUT ROWID × STRICT ×
partial × expression crosses (36), hook silence during the lookup, repo
churn `c6bfdb9..787ea23`, dep churn 0.10.0→0.11.0 (`constraint_parse.rs` /
`error.rs` byte-identical; 10/10 parse shapes re-anchored live). DRYNESS:
finding-run — **B5 stays 0 of 2, NOT DRY**. Re-wets ALSO on:
`busy_budget/1` / `within_budget?/3` / `unique_index/1` origin set / the
autoindex emission clause in `unique_constraints/1`.
RE-WET (2026-08-20): Run 26's F-X2-2 fix churned `within_budget?/3` /
`busy_budget/1` — the listed re-wetters.
COVERING RE-RUN (Run 27, 2026-08-20 — lap 4, the post-budget-fix pass):
**F-B5-14 (S2, FIXED, RED→green)** — Run 26's zero-disables-the-budget
rule held for a genuine zero timeout but NOT for the other two states
that also make `PRAGMA busy_timeout` report 0 (busy policy / observer
holding the slot): under a policy the candidate reads wait
policy-governed durations and the multiplication the budget existed to
stop came back (measured: 88/200 lookups blocking ≥2 of 25 reads; a
single 11,313 ms lookup; RED's policy leg unbounded at gate, 9,811 ms
max, 0/20 halts). Fixed: zero-reported timeout → fixed 500 ms budget
(`lookup_budget_ms/1`; healthy lookup ~409 µs; unexpected-shape branch
same budget); post-fix halts 12/20 on the policy leg, residual = 500 ms
+ ONE non-preemptible policy read (the F-B8-1 single-lock-wait class;
ceiling 25×`max_elapsed_ms` → 500 ms + 1×). Design fork FILED
[F-B5-14-fork] (deadline budget / repo option / xqlite slot-occupancy
API / replay budget). **F-B5-15 (S3, FILED, comment fixed)** — streamed
DML skips resolution (`:not_run` vs the execute path's `:ok` + real
name, probe-proven); the "declared query cannot violate UNIQUE" comment
was false, now states the real contract. **F-B5-16 (S3, FILED, cost
note added)** — the FK replay is a WRITE and blocks in default-WAL up
to a full `busy_timeout` on top of the statement's own (3,006 + 2,731
ms measured); moduledoc now says so; cleanup CLEAN under contention.
**F-B5-17 (S3, FILED)** — enrichment runs before
`disconnect_if_rolled_back/2`; under ON-CONFLICT-ROLLBACK in-txn the
names never reach a changeset; remedy sequenced with the disconnect
guard. **F-B5-18 (S3, FILED, gotcha owed)** — SQLite clamps
out-of-int32/negative `busy_timeout` to 0; repo config unvalidated.
F-B5-7 sweep DONE (exhaustive: all empty-read paths → `{:ok, []}`;
only a dead connection yields a status). CLEAN legs (RED-controlled,
orchestrator-re-driven): positive halt live at 402 ms; zero-budget
counts 2-24 all clean; match modes `:exact`/`:suffix`/`:prefix`/regex
9/9; insert_all/update_all; in-txn resolution; invisible-enforcer
CLOSED (rowid-PK duplicates → `:constraint_primary_key`, lookup never
runs); tests 23/23. DRYNESS: an S2 — **B5 stays 0 of 2, NOT DRY**; the
fix re-wets again. Re-wets ALSO on: `lookup_budget_ms/1` /
`@zero_slot_budget_ms`, `handle_declare`/`handle_fetch` error branches,
`FkDiagnostics.replay/3`, the `wrap_execute_error/4` ordering vs the
disconnect guard. Next-pass seeds: the fork's landing; the
OBSERVER-only post-fix case (reads fail fast → contended violations all
degrade — measure, judge vs pre-Run-26); FK replay under a policy +
in-sandbox under contention; streamed FK/CHECK/NOT-NULL subtypes;
last_insert_rowid after replay rollback (lead); ATTACH-schema lookup;
the 24-cap autoindex boundary; busy_timeout validation.

### B6. Query translation
LIKE's ASCII-only case-insensitivity; NOCASE collation limits; NULL
in joins/aggregates/DISTINCT; RETURNING quirks (ordering, trigger
interactions); on_conflict/upsert mapping; subquery LIMIT; windows;
fragment passthrough; grammar-gap seeds from sibling trackers
(EXISTS double-parens, ON CONFLICT expression targets, UPDATE FROM
subquery aliasing). Coverage: DISTINCT ON + DELETE+JOIN heavily
pinned. Run 2 built + ran real queries and inspected the emitted SQL
across every override; found THREE fixed bugs — F-B6-1 (S1) backslash
double-escaping in `escape_string/1` (silent wrong results on inlined
literals/LIKE/DDL defaults), F-B6-2 (S2) bare `OFFSET` without `LIMIT`
(SQLite syntax error on legit paginating queries), F-B6-3 (S2) missing
identifier-quote escaping in `quote_entity/1` (live injection via
`identifier(^value)`). Verified correct: `?N`/`$N::TYPE` placeholders,
single-quote escaping, empty-`IN`, on_conflict disambiguator, RETURNING,
subquery/CTE alias threading. NOT DRY. Deep NULL-in-join/aggregate,
NOCASE/LIKE-ASCII, and window-frame semantics still owed. Re-wets on:
any change to escaping helpers, `limit/2`, `quote_entity/1`, or an
ecto_sql SQL.Connection default override.
COVERING RE-RUN (Run 6, 2026-07-20 — dryness pass 2, the owed DEPTH pass): ran
real queries through a live repo inspecting BOTH emitted SQL and returned rows
against bundled SQLite 3.53.2. Every wrong-results seed CLEAN. NULL semantics —
`count(col)` skips NULL, `sum`/`avg` over NULLs, `sum`/`count` over empty sets,
GROUP BY (NULL its own group), DISTINCT (NULLs collapse), INNER/LEFT JOIN
orphan, `IN [1,nil,2]`, `NOT IN [1,nil]`→`[]` (three-valued-logic trap, IDENTICAL
to Postgres — not a divergence), `is_nil`→`IS NULL` (Ecto's `not_nil!` guard
blocks `== nil` upstream, so no `= NULL` ever emits). LIKE ASCII-case-insensitive
+ non-ASCII NOT folded — EXPLICITLY within Ecto's `like/2` contract (docs:
Postgres case-sensitive, others case-insensitive); `ilike/2` raises loud. NOCASE
migration collation folds ASCII only (correct-by-translation, `collate:` is
DB-specific). Window functions — running-sum/named-window/`row_number` + all
three frame types (`ROWS`/`RANGE`/`GROUPS … EXCLUDE`) via the sanctioned
`frame: fragment(…)` form all emit valid SQL and compute correctly. Grammar-gap
seeds LIVE-EXECUTED — EXISTS single-paren correlated, UPDATE-FROM alias threading,
ON CONFLICT partial-index + expression targets all correct. Churn re-verified live
(escape_string single-`\`, `LIMIT -1 OFFSET`, quote_entity injection collapse).
Zero new findings. DRYNESS: **first clean covering run (1 of 2), NOT DRY**, one
more owed (Run 2 found three fixed bugs). Re-wet triggers UNCHANGED.
COVERING RE-RUN (Run 10, 2026-07-21 — dryness lap 2, batch 2): the runtime
JSON-escape churn (`53599f4`, the ONLY connection.ex commit in range per git log)
re-covered through the TRANSLATION lens on RESULTS (Run 9 owned only the SQL
shape). Runtime keys via `d.meta[d.label]` — dot / backslash / double-quote /
single-quote / unicode (café, naïve日本) / digit-string "123" (routed to the
object key, NOT an array index) / empty string — plus mixed literal+runtime
paths in BOTH orders: every case returns the expected value, never silent nil
(raw `json_extract` ground truth confirms SQLite resolves `$.""`, `$."123"`,
`$."it's"`); a backslash+quote combo key set proves the backslash-first
replace() order under composition. escape_string/limit/quote_entity
byte-unchanged in range, so the Run-6 wrong-results seeds were re-anchored
targeted (count(col)/sum over NULLs, NOT IN with nil → [], LIKE ASCII-only
fold, `LIMIT -1` on bare offset, single-paren `exists(SELECT`, ON CONFLICT
expression target) + 85 committed anchors green. `json_extract_path_test.exs`
+5 durable tests (single-quote/digit/empty runtime keys, both mixed orders).
All probes re-run by the orchestrator (exit 0). Zero new findings. DRYNESS:
**DRY (2 of 2)** — second consecutive clean covering run. Re-wet triggers
UNCHANGED.

### B7. Migration ergonomics (novel surface)
No reference implementation exists = extra scrutiny. Probes: which
DDL ops supported vs refused, and are refusals LOUD (error) never
silent no-ops — sweep every path; DDL-in-transaction semantics;
rebuild-dance correctness (AUTOINCREMENT seq, indexes, triggers,
FK check); downgrade paths. Coverage: Run 3 ran the loud-refusal sweep —
generated DDL for the full construct set. Correct SQLite for FK
references (whole-key ON DELETE/UPDATE), `:check`, DROP COLUMN,
partial/unique indexes, composite PK/FK; every unsupported construct
(ADD/DROP CONSTRAINT, index concurrently/using/include/nulls_distinct/
only, keyword options/execute, ALTER COLUMN) refuses LOUDLY. Found +
fixed F-B7-1 (S2): `on_delete: {:nilify, cols}`/`{:default, cols}` (valid
Ecto shapes) SILENTLY dropped the whole ON DELETE clause — now a loud
`ArgumentError`. NOT DRY. Re-wets on: any `reference_on_delete/1`,
`execute_ddl` clause, or `column_change` change; an Ecto migration
grammar addition. Owed: `modifiers_expr` + ADD-COLUMN-with-REFERENCES
runtime rejection lived (raise on inspection, not yet run).
COVERING RE-RUN (Run 7, 2026-07-21 — dryness pass 3, living the rebuild dance): the
REBUILD DANCE (never exercised end-to-end before) surfaced a NEW CONFIRMED finding.
**F-B7-2 (S1, CONFIRMED + FIXED, RED→green).** The opt-in rebuild reconstructs the
new table from `PRAGMA table_xinfo` (name/type/notnull/default/pk only), so a
`:modify` SILENTLY DROPPED foreign keys, CHECK constraints, COLLATE / inline-UNIQUE
clauses, and generated columns. Proven live through `Ecto.Migrator` with idiomatic
`references/1` + `check:` (FK `child_parent_id_fkey` and CHECK `qty_pos` gone after
`modify :name`; orphan + CHECK-violating inserts then accepted; `foreign_key_check`
vacuously clean) and via a generated-column probe (STORED col frozen to a plain
column, VIRTUAL col vanished). Fixed to REFUSE loudly before any destructive step
(mirrors F-B7-1): `refuse_unpreservable_constraints!/3` scans the stored CREATE
TABLE SQL for REFERENCES/CHECK/COLLATE/UNIQUE and `table_xinfo` for generated
columns, over-approximating so the only failure mode is a safe refusal. Docs (README
rebuild section + `Migration` moduledoc) corrected. `table_rebuild_test.exs` +5.
The REST of the dance is CORRECT (all lived): rows preserved (count + spot values),
standalone index preserved + functional (unique violation), trigger preserved +
FIRING, AUTOINCREMENT sequence not reset (post-rebuild insert gets a higher rowid),
downgrade works (explicit up/down + `change/0` with `from:`) or refuses loudly
(`change/0` without `from:` → `Ecto.MigrationError`). OWED refusals lived:
`modifiers_expr` non-string → loud `ArgumentError`; ADD-COLUMN-with-REFERENCES →
nullable SUCCEEDS with the FK genuinely enforced (Run 3's "runtime rejection"
anticipation was wrong), NOT NULL → loud structured `XqliteEcto3.Error`. F-B7-1 fix
re-covered (`migration_test.exs` green). DRYNESS: a NEW confirmed (F-B7-2) surfaced,
so NOT a clean covering run — **stays at 0 of 2, NOT DRY**; the rebuild-guard fix
re-wets. Re-wets ALSO on: any `rebuild_table` / `refuse_unpreservable_constraints!`
/ `plan_new_schema` / `fetch_full_column_info!` change.
REMEDY (2026-07-21 — maintainer ruling A4): the rebuild engine CHURNED AGAIN. The
blanket refusal was replaced with faithful STRUCTURAL preservation — FKs
reconstructed from `foreign_key_list` (composite / ON DELETE+UPDATE actions /
implicit-PK / a self-ref temp-name trick so the drop cannot cascade into copied
rows) and UNIQUE from `index_list`+`index_info`, both emitted as table-level
clauses; `refuse_unpreservable_constraints!` dropped REFERENCES/UNIQUE and ADDED
DEFERRABLE + ON CONFLICT triggers (word-boundary CREATE-text scan);
`create_rebuild_table_sql/3` now takes table-level constraints; new
`fetch_foreign_keys!`/`fetch_unique_constraints!`/`foreign_key_clause`/`fk_target`.
Covered THIS run by RED→green `table_rebuild_preservation_test.exs` (+9, real
`Ecto.Migrator` migrations against PoolRepo — 1/9 against the old code, 9/9 after)
but NOT adversarially reviewed — B7 **stays 0 of 2, NOT DRY, re-wet**; the next
covering pass reviews the preservation engine adversarially (self-ref/incoming
dance, the incoming-FK populated-referencing refusal, the SQL-scan over-approximation).
ORCHESTRATOR-GATE CORRECTION (2026-07-21): the A4 incoming cascade/set-action hazard
was reclassified from a documented foot-gun to a LOUD PRE-FLIGHT REFUSAL. A new
`refuse_incoming_actions_on_populated!` runs alongside `refuse_unpreservable_constraints!`
(BEFORE any destructive step), enumerating incoming FKs via a correlated
`pragma_foreign_key_list` join over `sqlite_schema` (case-insensitive table match,
self-refs excluded) and refusing when a POPULATED referencing table carries an
`ON DELETE` CASCADE/SET NULL/SET DEFAULT action; empty referencing tables proceed;
+2 RED→green tests (populated CASCADE + SET NULL). Re-wetters UNCHANGED (now ALSO
`fetch_foreign_keys!` / `fetch_unique_constraints!` / `create_rebuild_table_sql` /
`refuse_incoming_actions_on_populated!` / `fetch_incoming_action_fks` / `table_has_rows?`).
COVERING RE-RUN (Run 11, 2026-07-21 — dryness lap 2, batch 3; the owed adversarial
pass on the preservation engine): BROKE the engine on three constructs. **F-B7-3
(S1, FIXED, RED→green)** — composite PRIMARY KEY silently narrowed:
`existing_to_column` emitted inline `PRIMARY KEY` only for the `pk == 1` column,
so a rebuild of a `PRIMARY KEY (a, b)` table produced a single-column key
(legitimate composite rows rejected). Fixed: `plan_new_schema` computes the pk
members by `table_xinfo` position; more than one suppresses the inline PK and
emits a table-level `composite_pk_clause` over the SURVIVING members in declared
order (a single-column key stays inline, preserving the INTEGER-PK rowid alias +
AUTOINCREMENT). **F-B7-4 (S1, FIXED, RED→green)** — `WITHOUT ROWID` / `STRICT`
table options silently dropped (bare CREATE tail, unscanned; no structural
pragma exposes them): a rebuilt WITHOUT ROWID table gained a rowid, a STRICT
table accepted `'not-an-int'` into INTEGER. Fixed: `unpreservable_table_option/1`
scans the tail after the FINAL `)` (table options carry no parens, so the
boundary is unambiguous — a column merely NAMED `strict`/`rowid` never
false-positives) and refuses loudly before any destructive step. **F-B7-5 (S2,
FIXED, RED→green)** — `quote_name` and raw interpolations did not double an
embedded `"` (malformed DDL on exotic names, loud) and `restore_autoincrement_sql`
inlined the table name into a `'…'` literal unescaped (a constructible silent
widening of the sqlite_sequence DELETE). Fixed: `quote_name` doubles `"`, new
`quote_string` doubles `'`, every rebuild DDL fragment routed through them,
transient name centralized in `transient_name/1`. RED reproduced INDEPENDENTLY at
gate (`git stash` of only `lib/xqlite_ecto3.ex` under the new tests → 11/15;
restored → 15/15). Clean re-anchors: mid-dance failure atomicity (the migration
txn rolls back and fully restores a pre-existing table), generated-column refusal
(hidden 2 AND 3), FK `MATCH` reported `NONE` by the pragma (inert in SQLite,
correctly dropped). **F-B7-6 (S3, BACKLOG, not fixed)** — the `ON CONFLICT`
refusal scan misses a comment interposed between the keywords (SQLite stores
CREATE text verbatim; `\bON\s+CONFLICT\b` misses `ON /* c */ CONFLICT`) → the
conflict algorithm would silently drop; reachability ≈ nil and comment-stripping
risks its own bugs — filed. `table_rebuild_preservation_test.exs` +4. DRYNESS:
three new confirmed → **B7 stays 0 of 2, NOT DRY**; the fixes re-wet. Re-wets
ALSO on: any `composite_pk_clause` / `unpreservable_table_option` / `quote_name`
/ `quote_string` / `existing_to_column` / `plan_new_schema` change.
COVERING RE-RUN (Run 15, 2026-08-20 — the owed adversarial pass on the Run 11
fixes + Run 13 defer-reset): the HEAVIEST finding run of the program — 2× S0 +
3× S1 + 2× S2 + 3× S3, two of them re-openings of the very holes under review.
Root pattern: the engine read its schema through two matching disciplines
(SQLite folds identifiers ASCII-case-insensitively; several engine reads
compared raw TEXT) and everything in the gap silently "did not exist".
FIXED at gate (13 RED→green committed tests, 40/40): **F-B7-7 (S0)**
case-mismatched self-ref FK → rebuild cascade-deleted its own copied rows
(`fk_target` now ASCII-folds); **F-B7-8 (S0)** `@disable_ddl_transaction` +
mid-dance failure lost the table (pre-flight refusal; guard = union of
`in_transaction?/1` and `DBConnection.status/2`, each half-blind alone);
**F-B7-9 (S1)** `:modify` rebuilt the column from options alone, silently
dropping NOT NULL/DEFAULT/PK/AUTOINCREMENT (new `modify_spec` merges options
OVER the stored declaration); **F-B7-10 (S1)** the options-tail scan
mis-anchored on `)` inside trailing comments (replaced with
`pragma_table_list` wr/strict — structural); **F-B7-11 (S1)** case-mismatched
`alter table` spelling dropped indexes/triggers/sequence and disarmed the
refusal scan (`resolve_stored_table_name!` resolves the stored spelling once,
used everywhere); **F-B7-12 (S2)** defer-reset only on success (now try/after
RESTORE of the prior value — also closing **F-B7-15 (S3)**, a caller's own ON
survives); **F-B7-13 (S2)** dependent views/foreign triggers killed the dance
at RENAME with a misleading error (pre-flight refusal naming dependents;
recreating views = future-feature candidate); **F-B7-14 (S3)** DESC in
table-level UNIQUE flattened to ASC (`index_xinfo` now preserves it). FILED:
F-B7-16 (S3 taste — composite-pk `:remove` narrowing; all-members case
recommended refusal). CLEAN: non-ASCII-case incoming FKs (nothing to refuse —
dangling), transient-collision, defer sequences, quoting dance incl.
injection attempt, partial/expression indexes, FK cycles, own-table triggers.
DRYNESS: **B7 stays 0 of 2, NOT DRY**. Re-wets ALSO on:
`resolve_stored_table_name!` / `modify_spec` /
`refuse_dependent_schema_objects!` / the transaction guard / `add_spec` /
`fetch_user_indexes!` / `fetch_table_triggers!` / `fetch_autoincrement_value!`
/ `scan_create_sql_for_unpreservable` / `unique_constraint_clause` /
`fk_target`. Next-pass seeds: complete the schema-name compare sweep
(`table_has_rows?`, `fetch_incoming_action_fks`, transient/copy legs);
adversarial lap on the modify-merge (FK/UNIQUE/composite-pk member modified;
`primary_key: true` × AUTOINCREMENT; `from:` shapes); the structural
before/after verification candidate; sqlite_stat1 / virtual-table shadows /
open stream cursor / `flush()` / concurrent readers during drop-rename.
LAW LAYER (Run 17, 2026-08-20 — the "structural verification candidate"
above, DELIVERED): every rebuild now runs a structural post-check before
COMMIT (`RebuildVerification` — one shared reader + change-set model, typed
`RebuildVerificationError` on any unexplained difference, the self-wrap
rolls back), and `table_rebuild_law_test.exs` drives the SAME model as a
600-run generator property + a 300-run ten-flavour refusal property. First
run found and gate-fixed **F-B7-17 (S1)** — AUTOINCREMENT silently dropped
on never-written tables (sqlite_sequence has no row before the first
insert; the flag now comes from the stored CREATE text via the shared
`autoincrement_declared?/1`; sqlite_sequence supplies only the value) —
and **F-B7-18 (S2)** — rebuild-path DEFAULT literals did not escape
embedded single quotes (now `quote_string`; the generator's deliberate
quote-exclusion removed). F-B7-16 RULED + implemented: keyed→keyless via
removal refuses (`refuse_removed_primary_key!/3`), narrowing to survivors
stays, keyless-created tables unaffected. B7 stays 0 of 2 (engine churn);
future covering runs lean on the law instead of re-deriving preservation
by hand. Re-wets ALSO on: `rebuild_verification.ex` /
`fetch_autoincrement_flag!` / `refuse_removed_primary_key!` /
`verify_structure!`.
COVERING RE-RUN (Run 22, 2026-08-20 — lap 3, the post-law-layer adversarial
pass): NINE findings — the column-level twin of Run 15's root pattern plus
the law layer's first blind spots. FIXED at gate (12 committed tests, 11
RED via the stash pattern): **F-B7-19 (S1)** implicit rowids silently
renumbered on tables without an INTEGER-pk alias (`primary_key: false`
shape) — an external-content FTS5 then returned the WRONG ROW; the copy
now carries `rowid` explicitly (`rowid_copy_needed?`); **F-B7-20 (S2)**
`PRIMARY KEY ASC AUTOINCREMENT` failed the shared adjacency regex — engine
dropped the keyword and the post-check, sharing the ONE predicate, agreed
(the seeded false-negative, found); regex now follows the grammar;
**F-B7-21 (S2)** raw-text column-name compares made case-mismatched
changes silent no-ops on the rebuild path (both engine and model) —
`same_column?` ASCII-folds both sides, stored spelling kept, and unknown
column names now REFUSE loudly; **F-B7-22 (S2)** trigger `tbl_name`
records the CREATE TRIGGER's spelling — a differently-spelled trigger was
dropped (post-check aborted, blaming the library); both schema-object
fetches now fold; **F-B7-23 (S2)** expression DEFAULTs (pragma strips the
required parens) made every rebuild of such a table die on a bare syntax
error — `carried_default` re-wraps non-literals; **F-B7-24 (S2)** the
model rendered fragment defaults WITH parens vs SQLite's stripped storage
— a correct `default: fragment(...)` modify was aborted as an engine bug;
`strip_outer_parens` mirrors the parser; **F-B7-25 (S2)**
`references(...)` in a rebuild block died as `UnsupportedTypeError` with
zero guidance — `refuse_reference_changes!` pre-flight now says what to
do (FK-merge = filed feature candidate); **F-B7-26 (S3, ruled)**
`modify ..., primary_key: false` stripped the key past the F-B7-16
refusal — `pk_removed` tracking closes the second door, key MOVES stay
allowed. FILED: F-B7-27 (S3, sqlite_stat1 dropped and never restored —
doc remedy owed to the docs pass). CLEAN: table-name reads, modify-merge
controls, the F-B7-17 anchors, stranded-constraint refusals, flush(),
concurrent-reader race (loud + consistent), the Run 21 B5 handoff (named
unique indexes survive AS named — the rebuild cannot manufacture the
F-B5-9 shape), Run 17 delta wiring, four ungenerated refusal flavours.
Gate self-check: the first verify came back RED on the gate's own fixes —
the key-move allowance needed mirroring into the model's `predict`
(+ `key_position` inline-first), and the law property found within 31 runs
that the generator emitted changes naming already-removed columns (now
loudly refused by the engine — generator normalize rules fixed per the
harness-vs-lib triage rule). DRYNESS: heavy finding-run — **B7 stays 0 of
2, NOT DRY**. Re-wets ALSO on: `same_column?` / `refuse_unknown_column!` /
`carried_default` / `rowid_copy_needed?` / `grants_inline_key?` /
`refuse_reference_changes!` / `strip_outer_parens` / the widened
`autoincrement_declared?` / the `pk_removed` tracking / the model's
`predict` grant allowance / the law generator's normalize rules.

### B8. Timeout→cancel divergence (flagship)
Ecto's `:timeout` elsewhere = stop waiting (query may complete);
here = the query dies. Deliberate divergence. Probes: post-cancel
connection state (txn aborted? poisoned or reusable? DBConnection
disconnect fired?); divergence documented LOUDLY (adopter retry
logic written for postgres semantics may misbehave). Coverage: Run 3
exercised the full path through a real `DBConnection` pool AND the direct
driver. CORE CLEAN: query-path timeout cancels promptly (159 ms for a
150 ms timeout on a ~3.5 s query), returns structured
`%DBConnection.ConnectionError{message: "query timed out"}`, pool stays
reusable; fresh cancel token per op (no spent-token bleed — proven on
cached + one-shot paths); in-txn timeout leaves the txn open + rollback
undoes writes; no mailbox leak. Codified as the post-cancel state matrix
(`cancellation_test.exs` +4). TWO divergences → BACKLOG: F-B8-1 (S3) op
`:timeout` doesn't interrupt a lock-contended write — busy_timeout
dominates (3005 ms for a 300 ms token; progress handler idle during
busy-wait); F-B8-2 (S3) the streaming path (`handle_declare`/
`handle_fetch`) has no cancel token (xqlite has no cancellable
`stream_fetch`), so `Repo.stream(…, timeout:)` runs a slow batch to
completion. NOT DRY. Re-wets on: any `run_statement`/`execute_with_cancel`/
`spawn_canceller` change, a DBConnection deadline-contract change, an
xqlite cancel-token or stream-fetch change.
COVERING RE-RUN (Run 7, 2026-07-21 — dryness pass 3): re-covered the core through
the driver churn (total_changes threading in finish_cached_stmt; disconnect reason)
and closed two owed items. CORE re-verified live: cached-path AND one-shot-path
timeouts still cancel promptly (~101 ms for a 100 ms token on a ~3500 ms query),
return structured `%DBConnection.ConnectionError{}`, pool reusable — `cancellation_
test.exs` green. ENCODE-RAISE × cancel machinery CLEAN: a `DecimalPrecisionError`
out of `DBConnection.Query.encode` (before `handle_execute`) creates NO cancel
token, spawns NO canceller (process count delta 0), leaves NO stray mailbox message,
the connection is unaffected, and the cancel path works promptly right after — the
raise precedes any token creation, so nothing to leak. OWED POOL-DEADLINE ITEM
resolved: through a REAL DBConnection pool a `:timeout` fires BOTH the graceful
cancel (caller gets the structured "query timed out") AND DBConnection's own
checkout deadline (same value), which disconnects+reconnects the connection
(connection-local TEMP table gone; `disconnect`+`connect:stop` both fire). SAFE +
self-healing + STANDARD DBConnection behavior (every adapter recycles on the
operation deadline) — not an adapter defect; the graceful cancel's pool-level value
is freeing the blocked dirty NIF promptly so the recycle happens at the deadline,
not at query completion. Pinned the pool-level contract deterministically
(`cancellation_test.exs` +1, dedicated pool, generous margins) + filed F-B8-3 (S3,
DOCS-only: pooled timeout recycles the connection / resets the statement cache).
DIRTYIO DETERMINATION: at deps/xqlite 0.10.0 the adapter's hot paths are ALREADY
predominantly DirtyIo; only 7 adapter-called NIFs are on the normal scheduler
(stmt_column_names, total_changes, changes, txn_state, create_cancel_token,
cancel_operation, register_progress_hook). xqlite main's unreleased 20-NIF flip
touches 5 of those (all but the two cancel-token NIFs), flipping them normal→DirtyIo
— ATTRIBUTE-ONLY (bodies byte-identical, verified per-function), so
correctness-transparent (result shapes unchanged, no adapter contract depends on
scheduler class). Unlike Run 6's clean busy-policy CLOSE, the flip DOES touch
adapter-called functions, so the disposition is: safe/non-breaking at the dep bump;
re-probe dirty-IO-pool occupancy under high read concurrency WHEN the dep is bumped.
Zero new S0–S2 on B8. DRYNESS: Run 3 found F-B8-1/2 (confirmed S3s), so this is the
**first clean covering run over B8, 1 of 2, NOT DRY**, one more owed. Re-wets ALSO
on: an xqlite scheduler-class change to an adapter-called NIF (a dep bump past
0.10.0 flips the 5 above).
REMEDY (2026-07-21 — maintainer ruling F-B8-3): DOC-ONLY (standard DBConnection
behavior, not an adapter defect). Added an honest line to the README timeout→cancel
divergence section: a pooled `:timeout` also trips DBConnection's checkout deadline,
which disconnects+reconnects the connection, so connection-local state (temp tables,
session PRAGMAs, statement cache) does not survive a timeout and there is a reconnect
cost; the graceful cancel's value is the blocked query returning at the deadline. NO
code change, so B8 is NOT re-wet — its re-wetter list is UNCHANGED.
COVERING RE-RUN (Run 11, 2026-07-21 — dryness lap 2, batch 3): `driver.ex` /
`query.ex` have ZERO commits in `828bb95..6539a14` (git-confirmed at gate; the
F-B8-3 remedy was README-only, the pool-deadline pin test-only). Core re-driven
LIVE: cached-path AND one-shot-path (`statement_cache_size: 0`) 100 ms timeouts
cancel at ~101 ms on a ~3.5 s query, both returning structured
`%DBConnection.ConnectionError{}` with the pool reusable after; an in-txn
timeout leaves `txn_state {:ok, :write}` with rollback + reuse working; the
encode-raise (DecimalPrecisionError out of `Query.encode`) spawns no canceller,
leaks no process or mailbox entry (delta 0), and the cancel path works
immediately after; `cancellation_test.exs` 11 green. Probes re-run by the
orchestrator (exit 0). Zero new findings. DRYNESS: **DRY (2 of 2)** — second
consecutive clean covering run. Re-wet triggers UNCHANGED.
RE-WET (2026-08-20): the 0.11.0 dep bump (scheduler-class flips of
adapter-called NIFs) + Run 23's `disconnect_if_rolled_back` on the sibling
error branch.
COVERING RE-RUN (Run 25, 2026-08-20 — lap 3): **F-B8-4 (S1, FIXED,
RED→green)** — the flagship's sharpest open question settled against the
code: SQLite rolls back the WHOLE transaction when it interrupts a write,
and the adapter's timeout is that interrupt; the cancelled branch returned
a plain error tuple, so post-cancel body statements ran in autocommit and
committed durably inside a transaction that reported failure (both
statement paths, driver-level and through a real pool; read-only controls
clean — which is why Run 11's SELECT-only pins never saw it). Fix: the
cancelled branch now routes through `disconnect_if_rolled_back/2`
(disconnect at the point of damage for writes; reads keep their
transaction; autocommit statements unaffected). **F-B8-5 (S3, FILED)** —
under dirty-scheduler saturation a 100 ms timeout returned in 11.3 s
(113×): the canceller runs (normal scheduler) but the statement had not
started; docs line owed (the timeout bounds the QUERY, not the caller's
wait). Ledger correction: Run 7's flip census — the driver calls
`transaction_status/1` (already dirty at 0.10.0), so the hot-path flips at
`c24383b` number THREE (`stmt_column_names`, `changes`, `total_changes`),
not five; cancel-token NIFs stay normal-scheduler (correct). CLEAN: core
100 ms timeout honored at 101 ms on cached AND one-shot paths at 0.11.0
(`:infinity` control 4.6 s); encode-raise hygiene (no canceller, zero
deltas); `handle_status/2` accurate mid-cancellation. DRYNESS: an S1 —
**B8 RESETS to 0 of 2, NOT DRY**. Re-wets ALSO on: the cancelled branch /
`disconnect_if_rolled_back`. Next-pass seeds: savepoint-nested cancelled
writes (`handle_rollback(:savepoint)`); SQL Sandbox × cancelled write;
streams in a sibling-rolled-back transaction; F-B8-5 through a
multi-connection pool; the guard's status read under dirty saturation.

### B9. Telemetry
Two compile configurations = two builds — CI must build AND test
both (probe: does it?); standard ecto telemetry contract
(event names/measurements/metadata) verified against Ecto.Repo's
own docs/source; extras (txn_state, connection_stats,
statement-cache hit/miss/evicted, OTel mapping) each need a
consumer-side assertion. Coverage: Run 4 drove EVERY documented event
live under the telemetry-ON build and captured actual measurements +
metadata. Fixed an S2-class contract mismatch: `disconnect` dropped the
documented `reason` key (callback arg was ignored) — now emitted; and
aligned the moduledoc to the observed emission (removed a never-emitted
`repo` on connect and the impossible `num_rows` *measurement* — span stop
measurements are fixed to monotonic_time+duration; split declare's
`query`/`sql` from fetch/deallocate's `cursor`; `mode` is on all txn
callbacks, not begin-only). OTel mapping re-verified correct + traceable;
statement-cache events confirmed. Both-configs-in-CI gap CONFIRMED (no
lane flips the flag; OFF path compiles clean locally) → BACKLOG. NOT DRY.
Re-wets on: any driver emission-site change, a new event, a moduledoc
event-surface edit, a `:telemetry.span`-vs-`emit` swap, an OTel-mapping
key change.
COVERING RE-RUN (Run 8, 2026-07-21 — dryness pass 4 + CI-OFF gap CLOSED): event-surface
re-drive CLEAN (zero new findings). `disconnect` reason re-verified live (== :normal);
Run 7 added no events (`git log 5b32d11..HEAD` on driver.ex/fk_diagnostics.ex = only
Run 4's fix; the `fk_diagnostics` span predates it, `794c121`). Spot-drove the full
documented surface under the ON build BY MY OWN runs: `telemetry_test.exs` 12
(connect/disconnect+reason/checkout/txn-trio+mode/execute/declare-fetch-deallocate
key-split), `driver_statement_cache_test.exs` 14 (hit/miss/evicted + cached_count/sql),
`fk_diagnostics_test.exs` 13 (span mode + violations_count/diagnostics_status),
`telemetry_open_telemetry_test.exs` 5. OTel mapping BYTE-UNCHANGED since Run 4
(`git log 5b32d11..HEAD` empty on its path). **[B9] CI GAP CLOSED**: new
`telemetry_disabled` CI lane (free-tier ubuntu-latest) + env-var config mechanism in
`config/test.exs` (`XQLITE_ECTO3_TELEMETRY=off` flips only the adapter flag) + a
build-agnostic `telemetry_disabled_smoke_test.exs` (module-level `if @telemetry_enabled`
to dodge the warnings-as-errors "always true" type warning). Both lane commands proven
locally from a warm ON `_build`: `MIX_ENV=test mix compile --force --warnings-as-errors`
exit 0, `mix test …smoke…` exit 0 (no-op span returns `%{rows: [[1]]}`; refute proves no
adapter event fires). DRYNESS: **first clean covering run over the Run-4 emission churn
(1 of 2), NOT DRY**; this run's OWN CI-lane + config-mechanism + smoke edits RE-WET the
flag-config surface (the owed second pass re-covers the OFF/ON compile path). Re-wets
ALSO on: any `config/test.exs` telemetry-flag mechanism change or a
`telemetry_disabled` lane/smoke change.
COVERING RE-RUN (Run 12, 2026-07-21 — dryness lap 2, batch 4; the owed flag-config
pass). Emission surface byte-unchanged in `811d544..458dc0c` (git log empty on
driver.ex / fk_diagnostics.ex / telemetry.ex / open_telemetry.ex). Flag-bleed
disproven BOTH directions: OFF compile (`XQLITE_ECTO3_TELEMETRY=off MIX_ENV=test
mix compile --force --warnings-as-errors`) exit 0 → OFF smoke (refute: no adapter
event) exit 0 → ON force-recompile exit 0 → ON smoke (assert_receive: emission
RESTORED) exit 0; the compile gating is `Application.compile_env` so a stale flag
raises at runtime rather than silently bleeding. `config/test.exs` env-flip
mechanism verified; the CI `telemetry_disabled` lane's commands MATCH the locally
proven pair; OTel mapping unchanged. **F-B9-2 (S3, CONFIRMED + FIXED): the
standing telemetry test cluster was async-unsafe** — `attach_capture`'s
process-global handler + two discriminator-free `:error` captures could grab a
concurrent test's `:ok` `:stop` first (~25% flake when several telemetry files
share one VM; ZERO impact on `test.seq`, which runs one file per OS process;
product classification correct — test-only). Fixed by filtering each `:error`
capture on its unique operation (sql / pinned database); cluster 0/25 post-fix
(orchestrator re-run) and the file alone stays 12/12. DRYNESS: the owed
flag-config pass itself was CLEAN, but a NEW confirmed surfaced in the
emission-test cluster → NOT a clean covering run — **B9 RESETS to 0 of 2, NOT
DRY** (the reviewer's stays-at-1-of-2 proposal was overruled at gate: a
finding-run breaks the consecutive-clean chain, same rule as B5/Run 10). The
test-hardening re-wets the emission-test surface. Re-wet triggers UNCHANGED.
COVERING RE-RUN (Run 13, 2026-07-21 — mini-lap batch 1, the owed first
re-cover of the hardened cluster + the `:ok`-capture audit): emission surface
byte-unchanged since Run 12 (`458dc0c..3c58c5c` empty). Hardened cluster
(8 files, one VM) 86/86 × 8 runs; the file alone 12/12; fresh event-surface
probe 9/9 (cache hit/miss/evicted + txn trio + connect/disconnect+reason;
orchestrator re-ran, exit 0); OTel path unchanged. **F-B9-3 (S3, CONFIRMED +
FIXED, test-only):** the disconnect test bound `metadata` UNFILTERED and
asserted `reason == :normal` OUTSIDE the receive pattern — a concurrent file's
non-`:normal` disconnect (a `ConnectionError`/`nil` reason emitted by
driver_connect_pragmas / driver_transaction_state) captured first FALSE-FAILS
it; the F-B9-2 fix had scoped to the two `:error` captures and missed this
value-asserting success-path capture. RED both ways: a deterministic injection
probe (orchestrator re-ran, CONFIRMED) plus a live 1/20 cluster flake; fixed
by pinning the capture on `%{conn: ^conn}`; GREEN 20/20 + 86/86×8. The
`:ok`-capture audit dispositioned every OTHER discriminator-free capture
harmless: they assert only instance-invariant fields, so a foreign same-name
event yields the identical verdict; begin/savepoint carry `mode:` inside the
pattern. DRYNESS: a new confirmed surfaced → NOT a clean covering run —
**stays 0 of 2, NOT DRY**; the fix re-wets the emission-test surface. Re-wet
triggers UNCHANGED.
COVERING RE-RUN (Run 23, 2026-08-20 — lap 3, 0.11.0 delta absorption):
**F-B9-5 (S2 doc divergence, FIXED as docs)** — `[:xqlite_ecto3,
:disconnect]` never fires on graceful pool/application shutdown (no
trap_exit in DBConnection's connection process; probed 0/0/1 vs the error
control), so the documented "pool closes a connection" trigger and the
guide's connect-vs-disconnect counter pattern were both wrong; guide +
moduledoc now state the real trigger and the unbalanced-pair fact.
**F-B9-4 (S3, FILED)** — the unique-name lookup (1+N pragma reads, up to
a busy_timeout per Run 21) runs inside `handle_execute` with no span
while sibling `fk_diagnostics` has one; filed with the proposed span
shape; the guide's "glue" sentence no longer implies microseconds.
**F-B9-6 (S3, FIXED as docs)** — span-contract omissions (`system_time`,
`telemetry_span_context`, duration-on-start ambiguity, missing
`fk_diagnostics` moduledoc entry, missing `:reason` in the guide row) all
corrected. CLEAN: emission churn = the two Run-21 driver hunks only
(sibling files byte-identical), flag-bleed disproven by compiled VALUE,
event-surface spot-drive 20/21, dirty-flip span neutrality
(1200/1200 paired, ns-scale), OTel byte-unchanged. DRYNESS: finding-run —
**B9 stays 0 of 2, NOT DRY**. Re-wets ALSO on: telemetry moduledoc /
guide event-table edits / `disconnect_if_rolled_back`. Next-pass seeds:
drive an `:exception` phase; OFF-build smoke re-drive; `cached_count`
semantics numerically; the bridge RawConn checkout's missing event
(decide with F-B9-4); `:checkout` counted against actual checkouts.

### B10. Benchmarks
Any number the announcement might cite is reproduced from a clean
checkout first. Coverage: Run 4 audited the surface. Methodology is
HONEST — pinned-identical pragmas (WAL/synchronous NORMAL/64 MB
cache/5 s busy/autocheckpoint 1000), versions disclosed-not-equalized,
cancellation labeled a demo, ledger-first (no committed figures),
scenarios span writes AND reads. BUT the harness does NOT compile:
`bench/mix.exs` pins `ecto_sql ~> 3.13.0` (stale lock) while the adapter
now requires `~> 3.14` (uses `Ecto.Migration.Table.:modifiers`) → compile
fails on the unknown struct key. F-B10-1 (S3) → BACKLOG; figures are
unreproducible until the dep bump. NOT DRY. Re-wets on: any `bench/`
dep-version change, any adapter `ecto_sql` floor bump, a new bench
scenario.
COVERING RE-RUN (Run 8, 2026-07-21 — dryness pass 4 + F-B10-1 CLOSED): methodology
re-verified CLEAN (zero new findings). **F-B10-1 CLOSED**: bumped `bench/mix.exs`
`ecto_sql ~> 3.13.0`→`~> 3.14` and `ecto_sqlite3 ~> 0.22.0`→`~> 0.24`, dropped the
stale insert/8 comments, refreshed `bench/mix.lock` via the sanctioned HEX_HOME
(ecto_sql→3.14.0, ecto→3.14.1, ecto_sqlite3→0.24.1, exqlite→0.39.0, decimal→3.1.1; local
path deps kept; TOP-LEVEL mix.lock untouched). `mix compile` in bench/ (prod,
`MIX_OS_DEPS_COMPILE_PARTITION_COUNT=1`, `XQLITE_BUILD=true`) exit 0 — `xqlite_ecto3`
(21 files) now compiles against ecto_sql 3.14 (the exact prior failure point gone) — and
a smoke run at the smallest integer budget (`BENCH_TIME=1 BENCH_WARMUP=0
BENCH_MEMORY_TIME=0 mix run bench.exs`) exit 0, all 8 scenarios + the cancellation demo
producing output (versions disclosed xqlite 3.53.2 / exqlite 3.53.3; NO figures recorded
— ledger-first). Methodology-honesty intact (edits touched only mix.exs+lock, not
bench.exs/bench.ex): pragma parity, disclosed versions, cancellation-as-demo,
ledger-first all unchanged. DRYNESS: methodology CLEAN (0 new findings), F-B10-1 CLOSED,
**first clean covering run (1 of 2), NOT DRY**; the dep bump (its own re-wet trigger)
re-wets B10 → the owed second pass re-covers the ecto_sql-3.14 / ecto_sqlite3-0.24 stack.
Re-wet triggers UNCHANGED.
COVERING RE-RUN (Run 12, 2026-07-21 — dryness lap 2, batch 4; the owed
ecto_sql-3.14-stack pass). Methodology honesty re-read CLEAN — `bench.exs` +
`bench/lib` unchanged in range (Run 8's bump touched only mix.exs + mix.lock):
pragma parity (WAL / synchronous NORMAL / 64 MB cache / 5 s busy /
autocheckpoint 1000), versions disclosed-not-equalized, cancellation-as-demo,
ledger-first all intact. Bench deps on disk match the bumped lock exactly
(ecto_sql 3.14.0 / ecto 3.14.1 / ecto_sqlite3 0.24.1 / exqlite 0.39.0 — no
fetch needed). `mix compile` exit 0 and the `BENCH_TIME=1` smoke exit 0 on the
3.14 stack (orchestrator re-ran both) — all 8 scenarios + the cancellation demo
produce output; NO figures recorded. The Run-11 rebuild fixes are
migration-path only — bench scenarios touch no ALTER path. Zero new findings.
DRYNESS: **DRY (2 of 2)** — second consecutive clean covering run over the
post-bump stack. Re-wet triggers UNCHANGED.

## Cross-repo axes (one system)

### X1. API/error-shape contract
Pin with contract tests IN THIS REPO: every xqlite error shape the
adapter matches on; every xqlite function+arity it calls. Version
lockstep policy (`~>` bounds) + a compatibility row in both READMEs;
release trains (which xqlite versions does an adapter change need?).
Coverage: Run 1 audited the entire `error_reason/0` union (48 shapes)
@0.10.0 against `Error.wrap/1` + `to_constraints/2`. Hot path CLEAN
(0.10.0 3-tuple migration complete). Found F-X1-1 (S3, FIXED —
`:sqlite_failure` nil-message dropped) + F-X1-2 (S3, BACKLOG — ~14
non-binary-payload shapes fall to inspect catch-all). NOT DRY. Re-wets
on: ANY `error_reason/0` typespec change in xqlite (this is the axis
that broke CI), any new `Error.wrap/1` clause, any Ecto constraint-
type addition.
COVERING RE-RUN (Run 5, 2026-07-20 — dryness pass 1): re-audited the FULL
`error_reason/0` union (48 shapes) @ deps/xqlite 0.10.0 AS COMPILED against
`wrap/1` + `to_constraints/2` — standing surface CLEAN, zero new findings.
F-X1-2 DECIDED = FIXED not ratified (house-doctrine ruling): added three
arity-bounded (2-/3-/4-tuple) tag-preserving `wrap/1` clauses so the 14
non-binary-payload shapes keep their tag as `type` (RED→green,
`error_wrap_test.exs` +4). The DecimalPrecisionError raise out of
`DBConnection.Query.encode/3` re-verified from db_connection SOURCE (encode/5
`db_connection.ex:1457` → `raised_close:1570` closes the QUERY via `:handle_close`,
not the connection → 4-tuple → `log:1698` → `log_result:1732` `:erlang.raise`
unchanged) AND runtime-confirmed (beyond-precision Decimal raised unchanged,
`disconnect_fired=false`, same pool served the next insert+select). FORWARD blast
(xqlite v0.10.0..main, 7 commits): `error_reason/0` changed ADDITIVELY only
(+`:extension_loading_disabled` +`:invalid_conflict_strategy`, both bare atoms
classified by wrap/1's atom clause, both UNREACHABLE from the adapter surface);
`error.rs` ZERO change; nif.rs = 20 DirtyIo attribute-only flips; the
`XqliteQueryResult` `columns` encoding went graceful-OOM but success shape is
byte-identical. NO X1-contract shape moved — the 2-vs-3-tuple CI-break class did
NOT recur. DRYNESS: the standing audit was clean, but resolving F-X1-2 CHURNED
`wrap/1` (a listed re-wetter) → **NOT DRY**, one covering pass owed over the new
clauses. Re-wet triggers UNCHANGED.
COVERING RE-RUN (Run 9, 2026-07-21 — dryness lap 2, batch 1): the owed adversarial
pass over the three new tag-preserving `wrap/1` clauses (`2a9089a`). Full
classification map re-derived @ deps/xqlite 0.10.0 AS COMPILED — 7 bare atoms / 8
dedicated-clause tuples / 17 binary-payload 2-tuples / 14 tag-preserved shapes (46
distinct; Run 5's "48" counted probe invocations, not shapes) — and driven LIVE:
every tag preserved, zero `type: nil`, `to_constraints/2` spot-checks correct
(probes re-run by the orchestrator, exit 0). Clause ordering: no dedicated clause
shadowed (the map-payload `:sql_input_error` 2-tuple precedes the generic clauses;
the binary-payload and tag-preserving 2-tuple clauses are mutually exclusive via
`is_binary`); the 2–4 arity bound exactly covers the union (all tuple shapes are
2/3/4 with atom heads, so `is_atom` is adequate); an adversarial edge probe
(non-atom head, 5-tuple, empty tuple, bare string) degrades to `type: nil` without
crash. The rebuild engine's pre-flight `ArgumentError` refusals are the sanctioned
migration-DDL exception, NOT `Error.wrap` paths — a rebuild statement failing at
RUNTIME still surfaces a structured `%XqliteEcto3.Error{}` via `query!`.
DecimalPrecisionError raise unchanged (churn diff empty on `query.ex` /
`decimal_precision.ex`). FORWARD blast v0.10.0..`80210b6` (7 commits, two newer
than Run 5's walk — diff-verified ledger+probe-script only, no lib//native/):
`error_reason/0` +2 bare atoms (additive, adapter-unreachable,
atom-clause-classified); `error.rs` zero change; nif.rs = the known 20 DirtyIo
attribute flips; `encode_val`→Result threading keeps the success shape
byte-identical. Zero new findings. DRYNESS: **NOT DRY — 1 of 2**, first clean
covering run over the `wrap/1` churn; the owed second pass goes to the mini-lap.
Re-wet triggers UNCHANGED.
COVERING RE-RUN (Run 13, 2026-07-21 — mini-lap batch 1, the owed second pass):
`error.ex` + `error_wrap_test.exs` + `connection.ex` (to_constraints) UNTOUCHED
in `76b0890..3c58c5c` (the range's lib churn is the rebuild engine plus a
docs-only migration.ex edit). The 46-shape classification map re-derived
@0.10.0 AS COMPILED and driven LIVE — 60/60 probe checks, all tags preserved,
zero `type: nil`, `to_constraints/2` spot-checks correct, adversarial edges
degrade without crash (orchestrator re-ran, exit 0); `error_wrap_test.exs`
23/23; clause ordering re-read clean. The Run-11 rebuild ArgumentError paths
confirmed the sanctioned migration-DDL exception, correctly NOT `Error.wrap`.
FORWARD blast: `../xqlite` HEAD `80210b6` UNMOVED since Run 9
(orchestrator-confirmed); `error_reason/0` byte-identical. Details-typespec
looseness (busy/utf8 bare-map `details`) dispositioned ACCEPT — a spec-honesty
nit never consumed by `to_constraints/2`; tightening would churn `wrap/1` for
zero correctness gain; if ever tightened, dedicated structs batched with future
error enrichment. Zero findings. DRYNESS: **DRY (2 of 2)** — second consecutive
clean covering run. Re-wet triggers UNCHANGED.
RE-WET (2026-08-20): the 0.11.0 dep bump — `error_reason/0` grew (+2 bare
atoms), the listed re-wetter.
COVERING RE-RUN (Run 26, 2026-08-20 — first re-cover at published 0.11.0,
hex-tarball channel): union re-derived FROM THE COMPILED BEAM = 48 members
(9 bare + 39 tuple; exactly Run 13's 46 + `dd7c9f9`'s two, both
adapter-unreachable, atom-clause-classified); 78/78 live through `wrap/1` +
`to_constraints/2`, zero `type: nil`, adversarial edges degrade without
raising; drift alarm proven (`X1_RED=1` trips on a hidden member);
`error_wrap_test.exs` 23/23; `{:internal_encoding_error, msg}` confirmed at
CLAUSE level (binary-payload 2-tuple, `error.ex:222-224` — completes Run
25's B4 proof); `changeset_apply` `:replace` doc semantics recorded
(abort+rollback on unreplaceable conflict, never degrades to `:omit`);
forward blast `v0.11.0..1dd5c2b` = tests only. **F-X1-3 (S2, FIXED in
xqlite as docs):** 0.11.0 SHIPPED the abandoned empty-columns rule for
`query_with_changes` (`xqlitenif.ex:193`, `README.md:299`) vs the code's
`total_changes`-delta rule — the exact doc that taught F-X2-1; both sites
rewritten (RED: `DOC_RED=1` asserts the doc's model, 5 failures).
**F-X1-4 (S2, FIXED):** `~> 0.11` admits 0.12+/0.99 while xqlite reserves
pre-1.0 minor breaks and `0.9→0.10` already broke this adapter
(`6d571e5`); no compatibility row existed in either README. Bound
tightened to `~> 0.11.0` + pin-one-minor rationale comment; compatibility
rows added to both live READMEs and both STE drafts. DRYNESS: two S2 —
**X1 stays 0 of 2, NOT DRY**. Re-wets ALSO on: the compatibility rows
(every bound change owes their sync) and xqlite's `query_with_changes`
doc surface. Next-pass seeds: production-side union check (can xqlite
still EMIT all 48 shapes); `Xqlite.ExplainAnalyze`/`Telemetry.*` shapes
(adapter-called, never driven at 0.11.0); `changeset_apply` doc becomes a
live contract if a session feature ever lands.

### X2. Blast radius is cross-repo by default
Any xqlite public-surface change enumerates adapter call sites
before it lands, every time. Coverage: Run 1 enumerated the full
surface (36 `XqliteNIF.*` + 5 `Xqlite.*`) and produced the durable
blast-radius table (REVIEW_LEDGER Run 1) ranking each site by
silent-vs-loud break mode. The map already earned its keep: it caught
F-X2-1 (S2, FIXED) — the statement-cache path re-derived
`query_with_changes`'s sticky-changes discipline and got it wrong
(DDL/PRAGMA leaked prior DML's `num_rows`). NOT DRY. Re-wets on: any
result-map key rename in xqlite (esp. `query_with_changes`), any new
`XqliteNIF.*`/`Xqlite.*` call site, any sentinel-atom rename
(`:done`, `:multiple_statements`).
COVERING RE-RUN (Run 5, 2026-07-20 — dryness pass 1): the F-X2-1 fix re-wet X2
(the driver `total_changes` threading = a new call site). Re-enumerated the surface
at HEAD 5a411ee (reproducible rg over all `lib/**/*.ex`, `XqliteNIF|NIF` unified):
**38 XqliteNIF-family + 7 Xqlite.\*** (Run 1's 36+5 used a different count method;
same method at Run 1's base 6d571e5 = 37+7). Churn-attributable delta = exactly
**+1 site: `XqliteNIF.total_changes/1`** (via `conn_total_changes/1`, absent at base;
0 removed; Xqlite.\* unchanged) — already covered by the blast-radius table's
`changes`/`total_changes` row (relies on `{:ok, non_neg_integer}`, falls to 0 on
error — the new site does exactly that). Walked the FORWARD xqlite delta
(v0.10.0..main) through the table ROW BY ROW: every result-map row
(query_with_changes/stmt_multi_step/query/stream_fetch/txn_state), every sentinel
(`:done`/`:multiple_statements`/`:cannot_execute`), and every txn/pragma/open row
UNTOUCHED (nif.rs = 20 DirtyIo attribute-only flips, bodies byte-identical;
`error.rs` zero change; `XqliteQueryResult.columns` graceful-OOM but success shape
byte-identical). Only the "all error reasons" row moved, ADDITIVELY (+2 bare atoms,
both unreachable from the surface). Zero new findings. DRYNESS: **NOT DRY** — first
clean covering run over the F-X2-1 churn (1 of 2), one more owed. Re-wet triggers
UNCHANGED.
COVERING RE-RUN (Run 9, 2026-07-21 — dryness lap 2, batch 1): surface re-enumerated
at `6539a14` (Run 5 method) = **38 XqliteNIF-family + 7 Xqlite.\***, identical to
the `5a411ee` baseline; `git diff 5a411ee..6539a14` shows ZERO
`XqliteNIF.`/`Xqlite.` call-site lines added or removed (orchestrator re-grepped).
The rebuild/preservation engine's 13 raw-SQL sites all route through
`Ecto.Adapters.SQL.query!/4` (or `query`) → the adapter's own `handle_execute` →
the already-mapped `query_with_changes` blast-radius row — no new row needed.
Forward-delta walk (v0.10.0..`80210b6`) row by row: only the "all error reasons"
row moved, additively (+2 adapter-unreachable bare atoms); every result-map,
sentinel, and txn/pragma/open row untouched (nif.rs DirtyIo attribute-only,
error.rs zero, `encode_val` success byte-identical). Zero new findings. DRYNESS:
**DRY (2 of 2)** — second consecutive clean covering run. Re-wet triggers
UNCHANGED.
RE-WET (2026-08-20): the 0.11.0 dep bump (channel switch to the hex tarball)
+ lap-3 call-site churn (`268261a` transaction_status, `badcbcb`
unique_index_names).
COVERING RE-RUN (Run 26, 2026-08-20 — first re-cover at published 0.11.0):
census at `cf2cc62` = 38 + 10 by name, **38 + 7 code-only** (new counter:
name followed by an open paren; method re-validated at `6d571e5` 37+7 and
`6539a14` 38+7) — executable surface UNCHANGED from Run 9; the 3 extra
names are prose in the `with_xqlite` busy-slot doc block. Occurrences
63→67, all attributed to existing rows. The durable table driven LIVE
against the realized tarball for the first time: 25/25, RED via
`ROWS_RED=1`. Channel switch byte-clean (30/30 `lib/` + 25/25
`native/src/` vs `git v0.11.0`, manifest reconciled;
`.cargo/config.toml` with `STMT_SCANSTATUS` ships — RED: `TAG=v0.10.0`
finds 16 diffs). Busy-slot doc claims 8/8 at 0.11.0; `max_elapsed_ms`
per-contention reset confirmed (807/807 ms) — discharges Run 9's deferred
re-probe. Forward delta `80210b6..1dd5c2b` per commit: floor bump /
version strings + rusqlite 0.40.2 / tests only — zero product surface, no
table row moved. **F-X2-2 (S2, FIXED, RED→green):** the lookup reused
`PRAGMA busy_timeout`'s VALUE as its wall-clock budget; zero (fail-fast
config, unvalidated at `driver.ex:37`, or any busy policy/observer via
`with_xqlite`) meant "no time at all" — 10-11/50 degradations at 23
candidates vs 0/50 at default; real-name changesets intermittently raised
`Ecto.ConstraintError`. Fixed: zero disables the wall-clock check (the
24-cap bounds work); zero-semantics unit + 30-trial integration pins;
stash-RED 21/23 → 23/23. One-candidate case never reproduces (recorded).
New durable-map ROW added for the value coupling. Census method note:
code-only is the recorded number from now on. DRYNESS: one S2 — **X2
stays 0 of 2, NOT DRY**. Re-wets ALSO on: `busy_budget/1` /
`within_budget?/3` (this run's fix owes the re-cover) and the
`with_xqlite` busy-slot doc block. Next-pass seeds: busy-slot claims
through a REAL pool (emptied-slot connection handed to the next
checkout); F-X2-2 timing on slow storage and candidate counts 2-22;
`Xqlite.backup`/`conn`/`error` rows absent from the table;
`ExplainAnalyze`/`Telemetry.*` shapes undriven; `driver.ex:37`
busy_timeout validation (negative / `:infinity`).

## Release-readiness (adapter-specific additions)

The shared RC-gate checklist lives in xqlite/REVIEW_AXES.md. Adapter
additions: the 21 accidental-public SQL helpers → `defp` BEFORE
first publish; CLAUDE.md bootstrap; exclusion-ledger reconciled +
two-tag probe resolved; Elixir-floor claim vs CI lanes; Hex badge
trio + publish mechanics per the pre-launch checklist.
