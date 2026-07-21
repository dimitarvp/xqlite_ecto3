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

## Release-readiness (adapter-specific additions)

The shared RC-gate checklist lives in xqlite/REVIEW_AXES.md. Adapter
additions: the 21 accidental-public SQL helpers → `defp` BEFORE
first publish; CLAUDE.md bootstrap; exclusion-ledger reconciled +
two-tag probe resolved; Elixir-floor claim vs CI lanes; Hex badge
trio + publish mechanics per the pre-launch checklist.
