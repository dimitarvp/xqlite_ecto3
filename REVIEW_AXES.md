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
RE-WET (2026-08-20, lap-5 step-0 ruling): the audited return-shape
inventory changed — Runs 25/29 gave `handle_execute` (cancelled
branch), `handle_declare`, and `handle_fetch` a `{:disconnect, _, _}`
return they never previously produced (contract-valid per
DBConnection, but the verified conformance facts moved). **B1 back to
0 of 2**; next cover re-audits the callback return inventory +
the `sync_after_transaction_control` addition inside handle_execute.
COVERING RE-RUN (Run 33, 2026-08-20 — lap 5, batch 2): the return-shape
re-audit over the Runs-25/29/32 churn + the F-B8-8 court. Full
14-callback return inventory verified against db_connection 2.10.2
source; the moved surfaces probed live (disconnect returns from
execute/declare/fetch incl. teardown order and cursor cleanup;
savepoint-arm lifecycles with a RED control; the keyword sync
adversarially). FOUR findings — F-B1-2 (S2, FIXED): comment-prefixed
transaction control invisible to the keyword sync, the cached flag
lies both directions (a fourth durable-leak door + pool
over-disconnect on ordinary autocommit violations); F-B1-3 (S3,
FIXED): connect/1 put bare tuples where the contract wants
Exception.t (ArgumentError + lost reason under backoff_type: :stop);
F-B1-4 (S3, FIXED): dead reset line in disconnect/2; F-B1-5 (S3,
FILED → B9 court). F-B8-8 adjudicated DOCUMENT (README bullet landed;
the Sandbox injects mode: :savepoint into every out-of-transaction
statement, and SQLite's ABORT default + ROLLBACK-destroys-savepoints
make the wrap moot on every reachable class; FAIL + insert_all the
lone real one, hand-DDL only). DRYNESS: findings — **B1 stays 0 of 2,
NOT DRY**. Re-wet triggers GROW: any change to `leading_keyword/1`
(comment clauses included), the connect error path
(`Error.wrap/1` arm + its cannot_open_database clause), plus the
standing list.
COVERING RE-RUN (Run 42, 2026-08-21 — lap 6, solo; churn since
80257e4 = connection.ex/data_type SQL-gen, TWO connect-path
validation waves, the Run-40 statement stamping, and Run 41's five
driver deltas — each re-anchored): **F-B1-6 (S1, FIXED,
RED→green)** — `bool_decode/1`'s catch-all returned an ERROR TUPLE;
Ecto's loader contract is {:ok, v} | :error and
Ecto.Type.process_loaders/3 has no {:error, _} clause, so ANY
non-0/1/NULL stored value under a :boolean field crashed Repo.all
with a FunctionClauseError (decimal-loader control shows the owed
typed ArgumentError; the lone outlier among nine decode helpers).
Fixed to :error; matrix pin committed. **F-B1-7 (S1, FIXED,
RED→green; absorbs+closes [F-B5-1], graded up)** — with the SHIPPED
default rich_fk_diagnostics: false, `to_constraints/2` emitted
[foreign_key: nil]: a declared foreign_key_constraint NEVER matched
(Ecto.ConstraintError advising the very call the user made) and
match: :suffix/:prefix/regex crashed in String/Regex. Six changeset
spellings probed; reference adapters emit [] when nameless (postgres/
myxql/tds source). Why 41 runs missed it: both suite repos run
rich_fk_diagnostics: true; connection_test pinned the nil shape
without its consequence. Fixed to []; the [F-B5-1] synthesize option
ruled out (the generic FK error names no field). New
fk_constraint_default_config_test (own plain repo) + unit pin flip.
**F-B1-8 (S2, FIXED, RED→green)** — URL `:database` never
percent-decoded while Ecto's own parse_url decodes everything:
`my%20app.db` opened (and CREATED empty) a literally-named file —
probed with a seeded real file, `{:error, :no_such_table}` +
both files on disk. URI.new has already validated escapes so decode
cannot raise. Second leg: parser accepted busy_timeout past int32
max that connect refuses — busy_timeout is :int32_ms now
(:out_of_range structured). **F-B1-9 (S3, FILED — merged into
[F-B1-menu-connect-error-details])** — a STRING-valued config hits
wrap/1's {tag, binary} NIF-message clause, so the connect log reads
`failed to connect: ** (XqliteEcto3.Error) wal` naming neither key
nor problem (32 shapes probed; type field stays correct). Message
fix rides the menu's designed-shape decision. **F-B1-10 (S3, FIXED)**
— explain type: :analyze/nil raised FunctionClauseError naming a
private fn; now a named ArgumentError listing :query_plan/
:instructions and pointing at explain_analyze/3. **SEED-8
ADJUDICATED — REFUSE, implemented** ([F-B8-12-handoff] closed):
top-level mode: :savepoint measured byte-for-byte :deferred (lock
at first write, not entry) and under a verified-concurrent
two-writer race the deferred write fails INSTANTLY (busy handler
never consulted on stale-snapshot upgrade) — lost update where
:immediate serializes both. Sandbox unaffected (source sandbox.ex:659
+ runtime lock traces). handle_begin refuses the savepoint mode with
no enclosing transaction (ConnectionError naming the rule; the
savepoint arm is nested-only now, its redundant flag-set dropped);
translate rejected. Run-32's three top-level PoolRepo pins reworked
to the refusal pin (nested coverage stays: driver lifecycle tests +
sandbox suite); Run-41's recovery pin reworked nested. CHANGELOG
Changed + README + STE. CLEAN with controls: the guard's three call
sites all contract-permit both arms (source cites + closed-conn and
OCR probes); sync-on-error-branch CLEAN across ten inducible error
cases (flag always agrees with handle_status; the un-inducible
COMMIT-fails-AND-ends class is guard-covered first);
handle_begin(:transaction) stale-counter divergence unreachable
(all zeroing paths enumerated + negative-counter needs an
impossible random-prefix RELEASE); :disconnect_and_retry never
produced and would bad_return! via handle_common_result (source);
14-callback shape census legal on happy+error paths; wrap/1 total
over all 32 connect configs incl. the five
transaction_mode_as_connection_mode atoms; open_database/2
single-caller post-validation; URL↔validator round-trip green on
all nine pragma keys at enum+bounds (URL's narrower journal_mode
enum noted as documented); RawConn cannot reach the EncodeError
re-prepare path; leading_keyword doors still shut (11 spellings);
sandbox checkin releases the lock (plain-pool control). DRYNESS:
two S1 + one S2 + two S3 — **B1 stays 0 of 2, NOT DRY**; re-wets
ALSO on: loaders/dumpers lists, to_constraints clauses, the URL
extract/coerce path, build_explain_query, the handle_begin savepoint
arms. Next-pass seeds: the [check: <expression>] docs item
([F-B1-11-docs]); unique_index_name/not_null_column `-> nil`
catch-alls (expression indexes, WITHOUT ROWID composite PKs, empty
xqlite parses); query_many's raise vs the declared tuple contract;
dumper catch-alls reached without the Ecto type in front
(fragments/insert_all placeholders); handle_fetch mid-stream
disconnect × stream_deallocate after-fun/pool_ref; handle_status
{:error, state} read-failure semantics vs DBConnection's
transaction-aborted reading.

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
COVERING RE-RUN (Run 30, 2026-08-20 — lap 4; the seeded probes built):
**F-B2-17 (S2, FIXED)** — `:array_type` hid SIX passing upstream tests
(the shared migration creates the array tables only when the tag is
absent; every isolate-run since Run 4 measured the missing table; the
tags doc even called the shipped `x in t.ints` → JSON_EACH translation
unsupported). Tag dropped, three location tuples added (test lines
rg-verified), census flipped 434/32 → **440/26 green** — the suite
gained six tests. **F-B2-18 (S2, docs-FIXED)** — `:bitstring_type`
blamed SQLite while our `default_expr/1` raises a bare
FunctionClauseError first (non-byte-aligned bitstring default, inside
the shared migration — lifting the tag crashes ALL 434 tests);
rationale now owns the sequence; structured-refusal seed filed to the
B4 court. **F-B2-19 (S3, FIXED)** — the type.exs:362 tuple named a
body line (test = 359), the lone violation of its own three-lines-up
rule. **F-B2-20 (S3, FIXED)** — the duration rationale cited
`encode_param/1` (arity 2 since Run 25, structured error now); a
listed re-wetter fired without a sweep. Method banked: full-suite
isolation runs need `--no-warnings-as-errors` (four upstream Tds
warnings otherwise exit-1 a green suite). CLEAN: all n/m counts exact;
no exclusion passes at HEAD; the four ALTER pointers survived Run 28's
refusals; doors live-but-unreachable (loud on a bump); bijection holds
post-fix. Run 24's "no adapter frame" sentence corrected (loose, not
reusable as evidence). DRYNESS: finding run — **B2 stays 0 of 2, NOT
DRY** — with the gate RULING: clean-run counting starts from the
corrected list only, next pass re-covers the corrected surface with
the adapter-owned probes as standing instruments. Re-wets ALSO on:
the migration's exclusion-awareness list (`:bitstring_type`,
`:duration_type` remain isolate-untestable), `default_expr/1`'s
clause list, this run's narrowing (three tuples + the 440/26 anchor).
Next-pass seeds: the corrected surface inside the suite; the three
array tuples across an upstream bump; other migration-conditional
tables in vendored files; the duration subtlety split; a mechanical
line-pointer sweep loop.
COVERING RE-RUN (Run 38, 2026-08-21 — lap 5, batch 7): census at
HEAD **440/26, ZERO delta from Run 30** across 25 commits; vendored
deps unchanged; the six ex-`:array_type` tests re-proven IN-SUITE
(the gate ruling's re-cover discharged). INSTRUMENT UPGRADE banked:
full-suite `--trace` census + `--include "test:test <name>"` for all
26 names in ONE run (441/466, exactly 25 failures = ground truth
with built-in control); `--only` isolate-runs retired; the
migration-conditional pair (bitstring/duration) keeps adapter-owned
probes. **F-B2-21 (S2, docs-fixed)** — the public `:bitstring_type`
rationale was false at HEAD (named `default_expr/1` + a bare
FunctionClauseError; reality is arity 3 + structured
`UnsupportedDefaultError` — Run 31 fixed the helper and left the
doc: the F-B2-20 re-wetter-without-sweep class, second lap running).
**F-B2-22 (S2, docs-fixed)** — `sql.exs:30` blamed Postgres cast
GRAMMAR; SQLite accepts the statement ($1::text = TCL-style param,
[] = bracket alias) and the real cause is the untyped-raw-result
JSON-decode gap (= the type.exs:359 argument); three references
reworded, sibling :38 verified genuinely-grammar. S3s: F-B2-23
(stale 362 comment → 359), F-B2-24 (placeholders pointer → :1106),
F-B2-25 (the 4/5 disclosure landed both artifacts — F-B2-8 stays a
recorded trade, now disclosed), F-B2-26 (push/pull refusal said
"Arrays are not supported" — false since F-B2-17; messages now name
the two operators; push/pull-via-JSON filed as menu), F-B2-27 (the
duration rationale rewritten three-way: migration builds the table
fine / the encoder is the blocker with the table present /
fields:/precision: leave nothing to truncate by). Filed sweep:
F-B2-8 confirmed the ONLY over-broad exclusion (interval.exs:194
the lone non-failing include; four siblings RED in the same run);
ALTER pointers survive Run 37; macOS-flake count corrected on
record (two: Run 32 ledger + Run 33 board; disposition unchanged).
Stash-RED N/A (prose-only fixes; recorded honestly). CLEAN: all
counts exact, bijection exact both ways, transaction.exs:161
jointly-caused (2×2), logging.exs:74 mechanism pinned,
like_match_blob re-anchored over 54 compile options. DRYNESS: two
S2 — **B2 stays 0 of 2, NOT DRY**. Re-wets ALSO on: the tags-doc ↔
helper rationale pair (diff them FIRST next pass), the push/pull
messages. Next-pass seeds: the helper↔doc rationale diff as step
one; refusal-message sweep vs the doc's feature claims; bare-
`Repo.query` checks for every grammar-blaming rationale; the
upstream-bump watch (unmoved since pre-Run-24).

COVERING RE-RUN (Run 47, 2026-09-01 — lap 6, batch 7): census
440/26 exit 0, ZERO delta across Runs 39-46; RED twin exactly 25
failures, survivor = interval.exs:194 (F-B2-8 unchanged, the only
over-broad exclusion); bijection + snap 9/9; upstream watch
negative. EIGHT findings, one S2 + seven S3, ALL documentation-class
— F-B2-28 (S2, FIXED): the hex-shipped README's exclusion taxonomy
missed the deliberate-decision bucket AND two whole-file skips
(lock.exs/query_many.exs had no doc rows); three-bucket rewrite +
a "Whole-file skips" section + THE MECHANICAL PIN
(exclusion_artifacts_test: bijection both directions, snap rule,
whole-file rows — the p05 instrument promoted into the suite).
F-B2-29: the lock.exs rationale described advisory locks; the file
tests SELECT…FOR UPDATE — rewritten + the all/1 lock: refusal
pinned. F-B2-30: "query_many is not supported by SQLite" blamed the
engine for an adapter choice (third frame-attribution instance) —
message + rationale own it now. F-B2-31: the :lock_for_migrations
row blamed SQLite where the helper owns the deliberate no-op —
mirrored + pointer added. F-B2-32: the :duration_type HELPER lagged
its own doc row a full lap (the leak's direction REVERSED —
doc-correct/helper-stale); fact (a) carried over + the
durations-migration probe pinned. F-B2-33: test_helper's WAL
comment still told the story Run 46 refuted — re-truthed
(belt-and-braces over the driver retry). F-B2-34: sibling
rationales three lines apart contradicted each other on square
brackets — the :38 half dies by the SAME bracket-alias accident
one token later, rewritten. F-B2-35: the :modify_column notes
over-claimed post-affinity-guard — refusal clause added; the
settled fact: no vendored test crosses the guard because
integer→numeric converts EXACTLY (add p04 leg A to the standing
instruments — a guard change flips alter.exs:44's mechanism
silently). Cross-court seed [F-B2-36-seed → B6]: Connection.lock/2's
unreachable second refusal. Flake pair tally stands at THREE.
DRYNESS: findings — **B2 stays 0 of 2, NOT DRY**. Re-wets ADD: the
all_test skip comments + README taxonomy sentence (newly in scope),
the WAL block, the :modify_column row vs the affinity guard;
exclusion_artifacts_test is the standing instrument.

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
COVERING RE-RUN (Run 29, 2026-08-20 — lap 4, paired with B9): the
flagship seed CLEAN — ON CONFLICT ROLLBACK under the SQL Sandbox is
safe BECAUSE the disconnect guard fires and ecto_sql re-begins the
sandbox transaction on the replacement connection (leak-detector
control proven) — and the guard's two missing doors are the run's
findings. **F-B3-7 (S2, FIXED, RED→green):** the guard read the CACHED
transaction flag, which raw-SQL `BEGIN` never sets and `checkout/1`
(once per connection, source-verified) never re-syncs — durable
post-failure writes through BOTH the ON-CONFLICT-ROLLBACK and the
ordinary TIMEOUT door; fixed by a leading-keyword transaction-control
sync (~9 ns non-matching; one `txn_state` read on actual control
statements; `ROLLBACK TO` cannot false-idle — the read asks SQLite).
Residuals recorded: un-pinned raw BEGIN on a pool (inherent to
pooling, every adapter; probe leg FAIL BY DESIGN) and comment-prefixed
control (F-B7-6 comment-class sibling). **F-B3-8 (S2, FIXED):**
`handle_declare`/`handle_fetch` bypassed the guard — streamed
ROLLBACK-class DML leaked; both now route through it. **F-B3-9 (S2,
docs-FIXED):** bridge-enabled extension loading leaves SQL-level
`load_extension()` callable for the connection's life — moduledoc now
names the standing permission + restore; xqlite-court addendum filed.
**F-B3-10 (S3, docs-FIXED):** fail-fast poisoned connections are
preferentially reused (2/4 poisoned absorbed 23/24 contended writes);
amplification sentence added; post-Run-27 the lookup budget HOLDS.
CLEAN: state family (authorizer true-undo, no cache desync; hooks
persist harmlessly; progress hook does not clobber cancellation —
303/300 ms with control); REAL second-OS-process wedge exact-count
66 = 40 + 26. DRYNESS: finding run — **B3 stays 0 of 2, NOT DRY**.
Re-wets ALSO on: `sync_after_transaction_control/2` /
`leading_keyword/1`, the declare/fetch guard routing, the
`with_xqlite` state section. Next-pass seeds: the keyword-sync
surface itself; backup/serialize/session handles across check-in;
`set_busy_policy` form; `Repo.stream` inside `Ecto.Multi`;
`{:shared, owner}` sandbox mode under a ROLLBACK-class violation;
the amplification curve vs pool size/fraction.
COVERING RE-RUN (Run 37, 2026-08-21 — lap 5, batch 6, paired with
B9): **F-B3-11 (S2, FIXED)** — eight pragma-bound config values were
unvalidated and SQLite's parser silently defaults on nonsense:
`foreign_keys: :nonsense` disabled FK enforcement (orphan accepted,
probed end-to-end through a real repo), `journal_mode: :walk` meant
DELETE, `synchronous: :ful` meant NORMAL; fix = nine connect
validators (supersets of the URL parser's typed allowlists), incl.
**F-B3-12 (S3, FIXED)** — `rich_fk_diagnostics: "true"` silently
disabled the feature (struct-match guard). custom_pragmas stays
deliberately unvalidated, documented. DISCHARGES
[R35-handoff-config-validation]; 84-case verdict table in the
ledger/report. **F-B3-13 (S2, FIXED)** — UTF-8 BOM and leading
semicolon (both skipped by SQLite's tokenizer) still hid transaction
control from the keyword sync: BOM-BEGIN leaked durable post-failure
writes (a real Windows-authored .sql file reproduces it), ;COMMIT
destroyed a healthy connection via the stale flag; fix = `;` + BOM
join the skip set (the 14-spelling sweep bounds these as the
complete remaining set on this runtime). **F-B3-14 (S2, docs-fixed +
menu)** — `with_xqlite/3` ALWAYS starts its own checkout: the
sandbox-nesting promise was false (bare calls only); nested = queue-
timeout raise at pool 1 (plain-pool in-transaction: enclosing txn
ROLLS BACK) or a silently DIFFERENT connection at pool > 1;
moduledoc rewritten, reuse option filed [F-B3-14-menu]. **F-B3-15
(S3, docs-fixed)** — raw `PRAGMA wal_autocheckpoint` always reads 0
(xqlite's WAL-slot emulation); honest-read line landed. **F-B3-16
(S3, docs-fixed)** — a bridge-obtained session recorder keeps
recording other callers' pool traffic after check-in; now leads the
persistence list; F-B3-10's sentence sharpened with the measured
curve (1 of 8 poisoned absorbs 41/48; flat in the poisoned
fraction). CLEAN: the Run-33 comment-prefix residual CLOSED through
both F-B3-7 doors (5 spellings, leak-detector control); F-B3-8
declare/fetch routing at HEAD; multi-statement SQL not a route into
the sync; `{:shared, owner}` sandbox settled by an independent
reader; backup/serialize across check-in; set_busy_policy as
documented. Filed sweep: F-B3-4-xqlite / F-B3-1 hold; the Run-14
unverified seed superseded by F-B3-5. Stash-RED 7 predicted exactly
→ 88/88. DRYNESS: three S2 — **B3 stays 0 of 2, NOT DRY**. Re-wets
ALSO on: the nine `validate_*` connect validators, `leading_keyword/1`'s
skip set. Next-pass seeds: the `hooks` config value (never swept);
[config-value COMBINATIONS seed CUT by maintainer scope directive
2026-08-21 — the posture for pragma-value surfaces is
validate-or-refuse at connect plus documentation, not combination
probing; the readonly `writable/2` profile rides the same
directive];
tokenizer skip set read from SQLite's C source; with_xqlite under
Sandbox at pool > 1 from an allowed process; a second lock-hold
duration for the amplification curve; the Multi RuntimeError shape.

COVERING RE-RUN (Run 46, 2026-09-01 — lap 6, batch 6, paired with
B9): step-0 over `21026b7..HEAD` — the connect chain churned
(validate_connection_mode head + savepoint refusal + statement
stamping), the nine Run-37 validators byte-stable and re-anchored
11/11; leading_keyword byte-stable but its CALLER churned (savepoint
zeroing). THREE S2, all FIXED — F-B3-17: a hooks: progress option
outside the accepted shapes RAISED in connect/1, crashing the
connection process and killing the WHOLE repo supervision tree in
5-30 ms (every_n: "500" — the env-var idiom — every_n: nil/-1,
non-atom tag); validate_progress_opts/1 refuses structurally now,
unknown keys and non-keyword lists included. F-B3-18: the
first-boot WAL noise re-diagnosed — NO external writer needed (two
pool members racing, ~90% of fresh boots at pool 2, DELETE-mode
files too) and SQLite refuses the losing flip WITHOUT the busy
handler (120 s busy_timeout helps zero — README's mitigation
disproven, section rewritten + STE); FIXED with a bounded
journal-mode retry (10 × 2 ms; measured need: every loser succeeds
on attempt 1). F-B3-19: the vertical tab — settled from the bundled
tokenizer SOURCE (0x0B is run-interior whitespace, rejected only
statement-leading — the asymmetry Run 37's leading-position sweep
could not see); " \vBEGIN"/" \vCOMMIT" reopened both F-B3-7 doors;
?\v joined the skip set (safe unconditionally — leading VT never
executes). Skip-set table now ledger-recorded (Run 46 entry).
F-B1-5 CLOSED discard-unreachable at the Rust source (reopen
trigger recorded). CLEAN: with_xqlite allowed-process Sandbox leg
(owner's connection, nothing escapes; $callers-cleared stranger
control); amplification FLAT in hold time (41-42/48 at 300 and
1500 ms, 48/48 controls); Multi RuntimeError not reproduced through
three doors (structured everywhere; kill-door unconstructed);
BOM/semicolon pins hold; savepoint refusal pool-healthy.
Combinations seed directive-parked. DRYNESS: findings — **B3 stays
0 of 2, NOT DRY**. Re-wets ADD: validate_progress_opts/1 + the
hooks refusal family, set_journal_mode/3 + @journal_mode_attempts,
the skip set (again), the README first-boot section.

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
COVERING RE-RUN (Run 31, 2026-08-20 — lap-4 closer, paired with B8;
`types/`/`query.ex`/`decimal_precision.ex` had NEVER been covered since
Run 25's own fixes, and two S1s sat exactly there). **F-B4-6 (S1,
FIXED, RED→green):** decimal params bound as TEXT — affinity-less
operands (`HAVING sum(...)`, arithmetic fragments, `coalesce`)
compared storage classes and returned WRONG ROWS silently (float
controls correct); fixed by `bind_form/1` binding the guard-proven
numeric form (int64 integer, else lossless float); accept/refuse
verdicts unchanged by construction; four TEXT-bind pins re-pinned;
bind-exactness property added. **F-B4-7 (S1, FIXED):** the `is_map`
default clause matched every struct — `default: Decimal.new("1.5")`
stored `DEFAULT ('"1.5"')` and later reads RAISED (postgres refuses
loudly). **F-B4-8 (S3, adjudicated + landed):** five bare-crash
default classes across all three renderers → one
`UnsupportedDefaultError` (value/reason/column/type/cause) via a
shared refusal, map clauses struct-gated, charlists refused; closes
[F-B2-18-adjacent] too. **F-B4-5 (S2, FIXED):** the Run-25
fast-accept is column-blind — REAL-affinity columns (via the atom
passthrough `add :v, :real`, or legacy files) silently truncated
what the pre-fix model refused loudly (fix-creates-next-finding
instance three); `:real`/`:double`/`:double_precision` now map to
NUMERIC; README gotcha for legacy REAL columns. **F-B4-9 (S3,
settled + fixed):** `expr(%Decimal{})` unreachable from ordinary
Ecto (five routes probed), now guard-routed anyway. CLEAN:
predicate/bind drift zero pre-fix; unencodable collections fully
structured with positions; `json_default/1` unification
byte-identical (11 classes, RED control); signed-zero pinned
(sign lost, numerically equal); int64 boundary exact. DRYNESS: two
S1 + S2 — **B4 resets to 0 of 2, NOT DRY**. Re-wets ALSO on:
`bind_form/1`/`encode_param/2`, `column_type/2`'s float family,
`UnsupportedDefaultError` + the three renderer tails,
`expr(%Decimal{})`. Next-pass seeds: the `:decimal` LOADER side
(BLOB + NULL-in-aggregate); `precision:/scale:` vs SQLite; decimals
in `:map` fields / `insert_all placeholders` / `on_conflict set:`;
`{:array, :decimal}`; `json_default` under a non-Jason
`:json_library`; the migration-helper `default:` entry points.
COVERING RE-RUN (Run 39, 2026-08-21 — lap 5, batch 8):
`bind_form/1`/`encode_param/2` git-verified untouched since Run 31.
**F-B4-10 (S1; message+docs remedied, code fix = [F-B4-10-menu])** —
a `:decimal` field over a TEXT-affinity column silently stores
SQLite's float-to-text rendering (~10% of accepted values drift;
regression consequence of the bind-as-number fix, unfixable at the
column-blind bind boundary) and the `DecimalPrecisionError` message
itself steered users into it ("use a :string column"); message now
prescribes a :string FIELD, README gained the TEXT twin of the REAL
caveat, drift characterized in a pin. **F-B4-11 (S2, FIXED)** —
`decimal_decode/1` raised bare `Decimal.Error` on BLOB/non-numeric
TEXT, killing whole queries; now full-clean-parse-or-`:error`
(Ecto's typed load failure) + the missing catch-all; pinned.
**F-B4-12 (S3, FIXED)** — the undocumented `:json_library` knob was
honored on one of four JSON paths with a Jason-specific rescue
(configured-library defaults could be unreadable); knob DELETED per
pre-1.0 policy. **F-B4-13 (S3, docs-fixed)** — `precision:/scale:`
are DDL documentation only; README line landed. **F-B4-14 (S3,
pinned)** — JSON-carried decimals bypass the guard (array exact
past float64, map loads Strings); three characterization pins with
the plain-field guard RED. Filed sweep: F-B4-1 remedy / F-B4-4 /
bitstring class / [UUID-case] / the column contract all HOLD; the
migration-helper `default:` seed does not exist. CLEAN: the
affinity rewrite (13 spellings, raw-REAL truncation RED, three
2000-run sweeps zero NUMERIC drift); wrong-results dead on exotic
columns (pre-fix text-bind RED empty); Run 34's census note
corrected (arithmetic vulnerable on the comparison side too);
defaults 44/44 structured, refusals leave no debris. Stash-RED 1
predicted exactly → 34/34. DRYNESS: S1+S2 — **B4 resets to 0 of 2,
NOT DRY**. Re-wets ALSO on: `decimal_decode/1`,
`encode_default/2`, the precision-error message + README decimal
section. Next-pass seeds: F-B4-10 via insert_all/update_all/
on_conflict on TEXT; the migrator route for exotic DDL; a
two-competing-markers spelling sweep; `references(type: :float8)`;
the rebuild re-rendering exotic spellings; the full
`expr(%Decimal{})` matrix; an external foreign writer.

COVERING RE-RUN (Run 48, 2026-09-01 — lap 6, batch 8): FOUR
findings — F-B4-15 (S1, FIXED): SQLite-written :utc_datetime rows
(CURRENT_TIMESTAMP/datetime()) were UNREADABLE (missing_offset →
one row killed every read) and mis-ordered vs adapter rows (space
vs T at index 10; 748/2000 same-day pairs wrong); loader retries
offset-less text as UTC AND the stored form is now SQLite's own
(space, no designator; naive too; TimestampTZ deliberately keeps
its offset form) — a pre-1.0 stored-format break with a README
normalize snippet + honesty-ledger item 17. F-B4-16 (S2, FIXED):
the trailing Z sorted a sub-second value before its own whole
second (1009/2000 mixed-precision pairs) — the form change covers
it. F-B4-17 (S2, FIXED): Decimal.parse clean-parses NaN/±Inf and
Ecto's :decimal raises a nameless exception — finite_or_error/1 on
both loader clauses; Run 39's already-typed claim corrected on
record. F-B4-18 (S3, FIXED, B7-court): the affinity pre-flight's
CAST predicate over-refused plain text — the copy is the oracle now
(NUMERIC scratch table, rendered-text compare, preserving R45's
asymmetric rule; WITHOUT ROWID keeps the conservative predicate).
Gate honesty: two of my pin redesigns had lost their teeth
(far-past base; single-precision route) — rebuilt deterministic,
stash-RED 8/8 second run; the behavior sweep caught
query_encoding's three encode pins. CLEAN: CAST-AS-NUMERIC
neighborhood (17 witnesses, both casts side-by-side);
sqlite_affinity 35/35 vs live SQLite; aliases + exotic-spelling
rebuilds; the 55-value foreign-writer matrix (40 refusals/14
loads); expr(%Decimal{}) dead on 20 routes; 12 boundary instants ×
7 types. [F-B4-10-menu] holds at five doors (drift = SQLite
re-rendering ≥16-digit floats). DRYNESS: findings — **B4 stays
0 of 2, NOT DRY**. Re-wets ADD: the datetime encode/decode family
+ sqlite_datetime, finite_or_error, copy_rewritten_count! + its
scratch oracle, the stored-form pin family.

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
COVERING RE-RUN (Run 35, 2026-08-20 — lap 5, batch 4: the Run-34
routing handoff + the Run-27 seeds): **F-B5-20 (S2, FIXED,
RED→green)** — `busy_timeout` config was unvalidated; `:infinity`
(and strings, floats, negatives, past-int32) connected fine and
meant busy_timeout 0 = never wait (1 ms give-up vs 3003 ms control);
fix = `validate_busy_timeout/1` at connect (integers
0..2_147_483_647; structured `:invalid_busy_timeout` otherwise;
int32 max is the accepted "forever"), CLOSING F-B5-18. **F-B5-19
(S2, docs-fixed)** — the migration guide's "changeset mapping works
identically" promise is false for custom-named unique indexes (bare
`unique_constraint/1` raises here, converts on ecto_sqlite3); the
behavior is the ruled F-B5-2 Postgres parity, so the guide now
states the difference + remedy. Docs-fixed S3s: F-B5-21 (README
"Real unique index names" section + CHANGELOG feature entry — the
Run-10 owed docs pass), F-B5-23 (replay leaves `last_insert_rowid`
at the phantom row; moduledoc + README caveat; no code remedy
exists), F-B5-24 (moduledoc claimed observer-held slots make reads
wait; observer-only fails in 0 ms — three-way zero ambiguity now
stated). Filed: F-B5-22 → F-B5-15 extended (stream skips the WHOLE
enrichment incl. FK replay), F-B5-25 → F-B5-4 sharpened (the
wrong-schema name is now EMITTED; TEMP shadow poisons main-table
violations; `pragma_table_list` remedy probe-confirmed feasible).
Filed sweep: 14-fork/15/16/17 all reproduce at HEAD (16's
two-full-waits timing not re-hit a 2nd time — mechanism + cleanup
proven over 76 iterations; 17's ordering intact through the
Runs-29/32/33 guard churn); 18 reproduced then closed. CLEAN: the
Run-34 handoff verified end-to-end (9-shape emission matrix + 3-flip
RED control + 13/13 changeset matrix + spoof/quoting/two-autoindex
adversarial legs + the mainstream conventional-name bare
conversion); observer-only degradation measured (fail-fast is the
right trade; `with_xqlite/3` already documents it); sandbox replay
7/7; 24-cap counts autoindexes, structured refusal at 25; budget
degradation structured onto the derived name. Observed-not-proven:
the budget halt itself (both constructed shapes missed it,
explained); Run 27's live 402 ms halt remains the only observation.
DRYNESS: two S2s — **B5 stays 0 of 2, NOT DRY**. Re-wets ALSO on:
`validate_busy_timeout/1` / the busy_timeout config surface / the
naming-contract prose in README+guide (re-wet on any emission-rule
change). Next-pass seeds: deterministic budget-halt construction;
F-B5-16's interleaving or a text downgrade; enrichment on a doomed
connection (F-B5-17's other half); insert_all/update_all/
on_conflict under the emission rule; equal cross-schema index
names; DDL racing the candidate count; `Ecto.Multi` conversion
shape. Handoff: [R35-handoff-config-validation] (B3/B8 court — the
other dozen unvalidated repo-config pragmas).
COVERING RE-RUN (Run 44, 2026-09-01 — lap 6, batch 4): step-0 over
`23d9524..HEAD` (28 commits): unique_index_names.ex +
fk_diagnostics.ex blob-identical since Run 35; connection.ex's one
on-axis hunk = the e166c5f FK `[]` clause (re-anchored end-to-end
both configs, all five match modes, p02); error.ex churn = the
details-union widening, the statement field rides the constraint
path (p12/p10); both driver re-wetters byte-checked —
wrap_execute_error gained only put_statement (cancel-token position
+ guard ordering byte-stable), connect-chain FK ordering intact and
re-proven live (200/200 over 5 members + witnessed reconnect, p01).
SEVEN findings — F-B5-26 (S2, FIXED): the `[unique: nil]` class
alive on unique/PK/check with a LIVE producer (FTS5 duplicate rowid
→ bare "constraint failed" → all-nil details → matcher crashes /
nil advice); `named_or_empty/2` makes to_constraints/2 nil-total;
FTS5 + unit pins. F-B5-27 (S2, FIXED): unqualified
`foreign_key_check` scanned the WHOLE database — one pre-existing
orphan anywhere (foreign_keys: false is a supported repo option;
OFF is SQLite's default elsewhere) broke FK conversion for every
statement under rich diagnostics; fixed by a baseline diff inside
the replay savepoint (report only rows absent pre-statement);
commit path has no baseline — documented + [F-B5-27-commit] filed
probe-first. F-B5-28 (S2, FIXED): `[not_null:]` advised the
nonexistent not_null_constraint/3 and discarded the structured
error; clause dropped → [] (reference-adapter parity), CHANGELOG
Changed + README/guide/STE; THREE pin-of-the-bug flips (the third
found by the widened sweep, not the reviewer). F-B5-29 (S3,
FIXED): unbounded violation materialization (100k structs on a
100k-child delete) → capped 24 + `{:truncated, total}`. F-B5-30
(S3, docs-FIXED): the guide's "one deliberate difference" → three
(unique names / FK-under-default raises incl. no_assoc / NOT NULL
structured); no_assoc_constraint now named in README + pinned under
the default config. F-B5-31 (S3, FILED): `:constraint_rowid`
parseable but unmapped — split-court (xqlite parse arm queued
post-0.11.1 + adapter mapping). F-B5-32 (S3, FIXED): empty
index_info for a vanished index silently shrank the candidate
count, flipping the emitted name ~50/50 under a verified-concurrent
index rebuild; now halts `{:unavailable, {:index_vanished, name}}`
→ derived-name degrade (supersedes F-B5-13's promotion);
budgeted_match @doc false public, deterministic pin. Debts paid:
seed 1 CLOSED — the lookup budget halt is deterministic (10/10 RED
at 1 ms budget vs 10/10 GREEN control, twice; structural note: with
budget = busy_timeout and elapsed <= budget, one blocked read can
never trip it); F-B5-16's ceiling proven deterministically (1502 ms
block vs 1 ms read control; BACKLOG text downgraded from the
one-off sum). Filed sweep: 1 closed-stays, 4/25 directive-parked,
5/7/8-residual/10/11/14-fork/15+22(SHARPENED: the two paths emit
DIFFERENT names — remedy must equalize the name)/16/17 all
reproduce. Seed-7 handoff adjudicated: CHECK expression-as-name +
table-nil is faithful-to-SQLite docs-gap ([F-B1-11-docs], stays
B1); unique field split is designed contract. DRYNESS: findings —
**B5 stays 0 of 2, NOT DRY**. Re-wets ADD: `named_or_empty/2` +
the nil-totality contract, `collect_violations/2` baseline diff +
`cap_rows/2`, `budgeted_match/4`'s empty-info clause, the guide's
three-differences paragraph.

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
RE-WET (2026-08-20, lap-5 step-0 ruling): the translation surface
moved in Runs 28/31 — `expr(%Decimal{}, …)` now guard-routes (raises
on rejects where it inlined), `column_type`'s float family
(`:real`/`:double`/`:double_precision`) emits NUMERIC, and default
rendering refuses structs/charlists via `UnsupportedDefaultError`.
**B6 back to 0 of 2**; next cover re-anchors the affected emission
paths (expr decimal clause, DDL column types, default rendering).
COVERING RE-RUN (Run 34, 2026-08-20 — lap 5, batch 3): all three
churned paths re-anchored live (SQL + results). THREE findings —
F-B6-4 (S2, FIXED): the upcase passthrough still emitted
REAL-affinity DDL for `:float8`/`:float4`/`:"double precision"`,
silently truncating decimals past 2^53 through the enumeration gap
in Run 31's closure; fixed TOTAL — the passthrough now applies
SQLite's own affinity rule and rewrites any would-be-REAL spelling
to NUMERIC, making the docs claim true for unenumerated spellings
too. F-B6-5 (S3, FIXED): UnsupportedDefaultError.column atom on two
paths / string on the third — normalized to string. F-B6-6 (S3,
docs-fixed + B7 menu): add-with-non-constant-fragment-default is
row-count dependent by SQLite's own rule (fresh-DB green, prod
red); README bullet landed. Clean: expr-decimal guard (zero
door-disagreements, storage/results agreement by real inserts, 14
construction routes all parameterize), float family + 34-spelling
walk (the `-0.0` sign loss predates the churn, raw-REAL control),
36 structured default refusals + 15 supported defaults reading back
through rebuilds, 376 committed anchors green, Run-31-S1
neighborhood agreement (comparison, not arithmetic, is the
vulnerable shape). The `unique_constraints/1` churn handed to
B5/B2. DRYNESS: findings — **B6 stays 0 of 2, NOT DRY**. Re-wet
triggers GROW: `column_type/2`'s affinity rewrite +
`unsupported_default!/3`'s column normalization, plus the standing
list.
COVERING RE-RUN (Run 43, 2026-09-01 — lap 6, batch 3): step-0 over
`0a5386a..HEAD` (28 commits, all other axes' churn): connection.ex
three hunks (build_explain_query catch-all re-anchored GREEN
through Repo.explain; push/pull refusal renaming re-anchored GREEN;
to_constraints → B5's court), data_type.ex churn = encode_default
only (the F-B6-5 column-normalization residue closed at 059d9ec,
re-anchored GREEN all renderers × both reasons), migration.ex ZERO
bytes, escape_string/limit/quote_entity byte-unchanged (anchor-only
held). FOUR findings — F-B6-7 (S1, FIXED): `type(expr, :decimal)`
emitted `CAST(… AS REAL)`, forcing float64 on the query side: a
big integer-exact decimal came back a different number from a
tagged select and a tagged equality WHERE matched no rows, both
silent; the shared clause split — :decimal casts NUMERIC (the DDL
side's own affinity), :float keeps REAL; emission + live
select/where pinned (typed_decimal_cast_test). F-B6-4's
consequence, one layer up. F-B6-8 (S2, FIXED): the affinity
rewrite's rule-5 residue — :jsonb/:json/:xml/:inet/:cidr/:macaddr/
:tsvector/:bytea landed NUMERIC, mutating numeric-looking text on
write ("007"→7, silent, delayed load error); bounded semantic
alias table ahead of the unchanged TOTAL rule (7 → TEXT, :bytea →
BLOB), :money/:bit/:enum/:year-class stays NUMERIC with a README
Known-limitations bullet + STE mirror; alias mapping + live "007"
jsonb-vs-money boundary pinned (passthrough_affinity_test).
F-B6-10 (S3, FIXED): verbatim passthrough rendering let
`:"text, oops INTEGER"` splice a second column into CREATE TABLE —
typename-grammar validation added (identifier words + optional
(N)/(N,M)), UnsupportedTypeError otherwise; incidentally refuses
non-ASCII spellings (closes the Run-34-critic Unicode question).
F-B6-9 (S3, FILED): keyword-shaped spellings (:set) fit the
grammar and die as raw SqliteFailure — structured refusal needs a
keyword-list decision (BACKLOG). CLEAN: references(type:) 18/18
through both DDL paths with live truncation control;
non-constant-default boundary sharpened (11 row-count-dependent /
9 constant / 0 unconditional, README honest, adapter JSON defaults
constant-safe); UnsupportedDefaultError/UnsupportedTypeError
total; values/2 $N::TYPE live standalone + joined; BLOBs immune
across all 24 mutating spellings. DRYNESS: findings — **B6 stays
0 of 2, NOT DRY**. Re-wet triggers GROW: the Tagged
:decimal/:float CAST clauses + the alias clauses and
@typename_grammar, plus the standing list.

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
COVERING RE-RUN (Run 28, 2026-08-20 — lap 4, the program's heaviest:
**THIRTEEN findings fixed in-run, 4 S1 + 8 S2 + 1 S3**, engine code
byte-unchanged since Run 22 when the cover began). S1s: F-B7-29 PK
sort order invisible (`INTEGER PRIMARY KEY DESC` is NOT a rowid alias;
flattening rewrote a NULL key to 11 — key's backing index now read,
DESC re-emitted everywhere, rowids carried, snapshot gains
key-order + rowid facts); F-B7-30 fts5/virtual tables silently
replaced by plain tables (now refused via `table_list.type`);
F-B7-31 the self-wrapped dance split across pooled connections above
pool_size 1, strandable open write transaction (now checkout-pinned,
`defer_foreign_keys` read moved inside); F-B7-32 re-created triggers
reading removed columns bricked all writes (pre-flight word-scan
refusal). S2s: F-B7-28 conditional changes compared names raw
(folded); F-B7-33 stranded-constraint removals died mid-dance in raw
SQLite text (named pre-flight refusals); F-B7-34 map/list defaults
crashed the rebuild path (one shared JSON renderer, booleans
aligned); F-B7-35 the keyword scan read literals — `DEFAULT 'check
pending'` blocked a table forever (four-quoting-forms blanking, also
behind AUTOINCREMENT detection — closes F-B7-6's literal half);
F-B7-36 a view selecting a column named like the table blocked the
rebuild (savepointed test-rename confirm against SQLite);
F-B7-37+F-B7-39 grants beside a kept key emitted two primary keys
(composite AND single — unified rule: refuse iff any current member
survives keyed; own-column single grant excepted); F-B7-40
`primary_key: false` on composite members ignored (now narrows like
removal; de-key-all+grant = legal key move; keyless refusal counts
de-keys). S3: F-B7-38 post-check bang-read of `sqlite_sequence`
(tolerated). Gate: three serialized Opus implementation batches, the
THIRD fixing two S2s the gate's OWN widened generators exposed;
stash-RED 79/108 → 108/108; full probe matrix green except two
by-design legs (F-B7-27's stat survival, F-B7-6's comment evasion).
Doc correction landed: populated RESTRICT does NOT stop the rebuild
(`defer_foreign_keys` defers it — probed); README+draft+comments
aligned. F-B7-27 addendum: `sqlite_stat4` dropped too. Generators
widened (case-varied names, DESC keys, map/list/fragment defaults,
grants/de-keys/moves, conditionals, ten refusal flavors; law+refusal
properties green at 2000). DRYNESS: **B7 stays 0 of 2, NOT DRY** —
the gate's fixes re-wet the axis wholesale (trigger list in the
ledger entry). Next-pass seeds: cancel mid-dance × the disconnect
guard; external-content fts5 over a rebuilt table (the true-data-loss
variant); TEMP-schema objects invisible to both scans; the
independent-facts decision (post-check catches only what the halves
disagree on); loud-but-bare second pass; `composite_pk_clause`'s
raw-name compare; the savepoint-confirm's own adversarial lap; the
literal-blanking vs SQLite's lexer corners; the refusal-exception
struct (menu); `grants_own_key?` under case-varied spellings.
COVERING RE-RUN (Run 36, 2026-08-21 — lap 5, batch 5: the Run-28
re-anchor + its nine seeds; engine byte-identical since Run 28 except
the F-B6-5 threading, git-established): **F-B7-42 (S1, FIXED,
RED→green)** — an apostrophe inside a comment desynced the Run-28
literal blanking (comments were not tokens), pairing with the next
literal's quote and erasing real DDL from the scans: silent CHECK
drop + silent AUTOINCREMENT drop (freed id re-handed), post-check
blind because `autoincrement_declared?` is the shared predicate —
Run 28's seed-4 shared blind spot realized. Fix: the blanking
alternation now knows both comment forms, each → one space, which
also makes comment-INTERLEAVED keywords visible — **F-B7-6's comment
half CLOSED outright** (ruling superseded, honesty-ledger item
struck, STE fine-print removed). **F-B7-43 (S1, FIXED)** — TEMP
triggers on the target (sqlite_temp_schema) were invisible to the
capture and died silently with the dropped table; fix = union read +
TEMP-keyword reinstatement on replay (SQLite canonicalizes stored
temp SQL to a bare CREATE TRIGGER prefix — probed over three
spellings; the post-check itself caught the gate's half-fix
re-creating into MAIN) + schema-tagged `{schema, name}` trigger
snapshots so schema migration is a structure mismatch. **F-B7-44
(S2, FIXED)** — TEMP views defeated the dependents pre-flight and
killed the dance with raw SQLite prose; same union (+ `{schema,
name}`-keyed rewritten_dependents). **F-B7-45 (S2, FIXED)** — the
`:unencodable` rescue carried an atom column on plain ADD (F-B6-5's
fourth door); normalize_column. **F-B7-46 (S3, FILED + docs)** —
typeless column → declared BLOB, both halves agree so the post-check
is blind (values/affinity unharmed; the comma-splice RED control
proved the check fires on disagreement). Menus ENRICHED with
evidence + recommendations (F-B7-41: implement the refusal struct,
fold the post-dance RuntimeError in; F-B6-6: refuse pre-flight —
routing would freeze fragment defaults to one migration-time value,
probed). Filed sweep: F-B7-27 holds (doc line owed);
F-B7-25/29/30/31/32/36 hold live; F-B6-4's rebuild reach established
(modified/added columns re-render — README caveat landed). CLEAN:
cancel-mid-dance 13/13 (+ the migrator-drives-at-infinity
reachability bound), external-content fts5 7/7, composite-PK compare
latent-clean, savepoint-confirm adversarial lap, grants_own_key?
case variance. Stash-RED 7 (predicted exactly) → 151/151. DRYNESS:
2 S1 + 2 S2 — **B7 stays 0 of 2, NOT DRY**. Re-wets ALSO on:
`@quoted_text`/`blanked/1`, `recreate_trigger_sql/3` + the trigger
fetch, the dependents read + `rewritten_dependents/3`,
`read_triggers/2` + the snapshot trigger shape, the `:unencodable`
rescue. Next-pass seeds: property-test the blanking over generated
six-token-kind texts; ATTACHed schemas [REFRAMED by maintainer scope
directive 2026-08-21 — do not probe cross-schema resolution; the
posture is refuse-or-degrade on ambiguity plus a documented
main-schema-only line]; cancel landing on chosen dance statements
(DROP→RENAME window); the Sandbox × ownership × confirm-savepoint
three-way; the shared-helper enumeration (F-B7-46's class); down/
rollback migrations; COLLATE/DEFERRABLE live legs for the comment
door.

COVERING RE-RUN (Run 45, 2026-09-01 — lap 6, batch 5): step-0 over
`df10b37..HEAD`: the rebuild engine BYTE-IDENTICAL since Run 36
(rebuild_verification.ex empty diff, migration.ex zero bytes, every
Run-36 re-wet trigger stable by git log -S); the one on-axis churn =
0c09d01's data_type.ex (alias table + typename grammar) reaching the
rebuild through the shared column_type/2. SIX findings — F-B7-47
(S1, FIXED): a modify to a numeric affinity on a populated column
silently rewrote stored values through the copy ("007"→7, a
20-digit decimal rounds through float64 — the exact value the write
path REFUSES; moduledoc promise broken; irreversible by rollback);
new pre-flight `refuse_affinity_rewrites_on_populated!` counts
at-risk values and refuses pre-destructively, per-value so
exact-converting columns migrate. F-B7-49 (S2, FIXED): the Run-43
alias table made `modify :payload, :jsonb` flip a legacy JSONB
column NUMERIC→TEXT, stringifying storage classes — ORDER BY/range
results changed silently, post-check blind (shared column_type/2 =
the F-B7-46 class); same pre-flight, to-TEXT direction; GATE
ADJUDICATION recorded: asymmetric rule (toward numeric = refuse
byte loss only; toward TEXT = refuse any numeric storage class),
README "three type-rendering details" + STE. F-B7-48 (S2, FIXED):
a column NAMED check/collate/deferrable/on made its table
permanently un-rebuildable with a false CHECK explanation (the
construct scans read the name-preserving blanking); blanking SPLIT
— `without_string_literals_or_names/1` for the construct scans +
autoincrement_declared? (shared), name-preserving product for the
name-hungry scans; real constructs still refuse. F-B7-50 (S3,
FIXED): four legal stored type texts spliced bare bricked the
transient CREATE; `carried_type/1` emits verbatim only for
bare-grammar-no-keyword or already-quoted-token texts, else
quote_name; stored text stable across rebuilds (pragma strips
identifier quotes); CLOSES F-B6-9 — the full SQLite keyword list
lands in DataType.bare_typename?/1, shared: passthrough atoms
REFUSE (`add :x, :set` → UnsupportedTypeError), carried texts
QUOTE. F-B7-51 (S3, FIXED): balanced? counted parens inside string
literals — `('a)b')`-class fragment defaults aborted the rebuild
while the plain ALTER accepted them; counts over the blanked
product now. F-B7-52 (S3, docs): a SELECT*-trigger on a removed
column passes the pre-flight and bricks later writes — EXACTLY as
SQLite's own DROP COLUMN does (parity control); docs + a parity
canary pin, over-approximating refusal rejected. The 2000-run law
property TAUGHT the refusal branch (refused ⇒ byte-identical
table, asserted on random shapes). CLEAN: the blanking
PROPERTY-TESTED (640 generated CREATEs, SQLite itself as ground
truth: 0 false passes / 0 false refusals); COLLATE+DEFERRABLE live
consequences (closes Run-36 seed 7); carried_default 15/15;
deterministic dance-window failures via the authorizer incl. the
DROP→RENAME window; real cancel mid-dance 6/6; Sandbox × ownership
× confirm 5 legs; down/rollback; UNIQUE-collision copy loud.
Filed sweep: 27/46/25-feature/41-menu/B6-6-menu reproduce (menus
NOT re-adjudicated); Run-28/36 fixes all hold. ATTACH seed
directive-parked. DRYNESS: findings — **B7 stays 0 of 2, NOT
DRY**. Re-wets ADD: the affinity guard trio, carried_type +
@quoted_typename, DataType.bare_typename?/@sqlite_keywords/
sqlite_affinity, the nameless blanking product, balanced?'s
blanked counting, the README three-details paragraph.

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
RE-WET (2026-08-20): Runs 27+29 churned the flagship's own surface
(lookup budget; the txn-control sync + declare/fetch guard routing).
COVERING RE-RUN (Run 31, 2026-08-20 — lap-4 closer, paired with B4):
every seeded S0-S2 question CLEAN with controls — savepoint-nested
cancelled write atomic (the OUTER flag is what the guard reads); SQL
Sandbox × cancelled write leaks NOTHING (RED leak-detector control),
with the DX fact pinned + documented: that test's ownership is gone
afterward (`OwnershipError`, `checkin` → `:not_found`); streams ×
cancelled sibling clean BOTH orders; guard verdict identical under
dirty saturation; a cancelled `BEGIN`/`COMMIT` effectively
unreachable (400k-row COMMIT = 8 ms) and safe by construction; the
cancelled branch skips `wrap_execute_error/4` (no enrichment on a
doomed connection). SEED ANSWERED: cancellation is NOT worse than
the plain-error path — identical damage both branches, both `BEGIN`
spellings; the sync blind spot is WIDER than filed (leading `--`
line comments defeat `leading_keyword/1` like `/* */`) — handed to
B3's owed keyword-sync pass. **F-B8-6 (S3, docs, FIXED):** a pool
does not bound the F-B8-5 overshoot (141×/285× measured; saturation
lives on the dirty schedulers); pool EXHAUSTION is a third case,
`queue_target`/`queue_interval`-governed, distinguishable by
`reason: :queue_timeout` — README + drafts now say all three. New
committed tests: nested-cancel, sandbox-cancel (new file),
stream×cancel both orders, queue_timeout-shape (deterministic).
DRYNESS: **0 of 2, NOT DRY — GATE RULING:** the reviewer proposed
1-of-2 (S3-docs-only, the F-B8-3/Run-7 precedent); overruled for
consistency with the hardened rule applied every run since Run 12
(any finding-run breaks the chain); the old precedent predates the
rule and was a ruled not-a-defect. Honest note: every S0-S2 leg was
clean — B8 is the closest axis to dry. Re-wet triggers UNCHANGED
plus `sync_after_transaction_control/2`/`leading_keyword/1` (shared
with B3). Next-pass seeds: `Repo.transaction(mode: :savepoint)` at
top level (savepoint with no enclosing transaction — the guard
clause cannot match); `{:shared, owner}` sandbox × cancelled write;
ATTACH/TEMP targets; `Ecto.Multi` with a cancelled step; the
`disconnect` telemetry `reason` on the cancelled branch (with B9);
adversarial queuing of the guard's DirtyIo status read; F-B8-2's
stream cancellation (blocked on xqlite `stream_fetch_cancellable`).
COVERING RE-RUN (Run 32, 2026-08-20 — lap 5, solo; `driver.ex`
byte-unchanged since `04e8363`, git-verified — the cover hunted the
unreached seeds): **F-B8-7 (S2, FIXED, RED→green)** — the guard's
THIRD uncovered door: `handle_begin(:savepoint)` never set the
cached flag, so a TOP-LEVEL `Repo.transaction(fun, mode: :savepoint)`
(a lone SAVEPOINT starts an implicit transaction) leaked durable
post-failure writes — through cancels AND plain
ON-CONFLICT-ROLLBACK violations (no timing needed), also via
`Ecto.Multi`; the raw-SQL spelling of the same construct was already
protected by the keyword sync (the flag decides, not SQLite). Fixed
read-free: savepoint begin sets `:transaction`; releasing the
OUTERMOST managed savepoint refreshes from SQLite
(`released_savepoint_state/1`); no over-disconnect after RELEASE
(pinned). Tests +3 deterministic. CLEAN with controls:
`{:shared, owner}` sandbox × cancel (file byte-identical, post-cancel
writes refused); ATTACH+TEMP rollback spans every schema (cancelled-
read control); `Ecto.Multi` both shapes; the guard's status read
under a SELF-POLICING saturation window (1 µs → 2.13 s median,
verdict unmoved, cost = exactly one read; 50 ms deadline → 8.97 s =
live F-B8-5/6-class re-measurement); core 151 ms vs 9,999 ms
control; F-B8-2 blocker holds. Disconnect-`reason` taxonomy captured
for B9 (all structured; cancel vs recycle share `:error`,
distinguished via the execute-stop correlation — docs line owed).
HANDOFF filed: `mode: :savepoint` on single operations
(insert/update) is silently INERT here (Postgrex implements it in
handle_execute) — B1/B2 court. DRYNESS: an S2 — **B8 stays 0 of 2,
NOT DRY**; re-wets ALSO on the savepoint arms +
`released_savepoint_state/1`. Next-pass seeds: declare/fetch under a
top-level savepoint; the managed counter vs caller raw SAVEPOINT
names; the guard's fail-open `_open_or_unknown` fallback (unpinned);
F-B8-1 at 0.11.0; commit/rollback hooks × cancelled write;
`mode: :savepoint` via repo config.
COVERING RE-RUN (Run 41, 2026-08-21 — lap 6, solo; five driver.ex
commits since 91415ff re-anchored, two of them keyword-sync churn):
**F-B8-8 (S2, FIXED, RED→green)** — the keyword sync refreshed the
FLAG but never the savepoint COUNTER: a raw COMMIT/ROLLBACK amid a
managed savepoint left the counter stale-high forever, so the next
outermost RELEASE decremented to non-zero, took the read-free
`_nested` arm, and the cached flag then lied (:transaction vs real
autocommit) — over-disconnect on the next failed autocommit
statement, falsifying the in-code raw-dance safety claim
(xqlite_ecto3.ex rebuild comment) AND Run 32's no-over-disconnect
pin. Public-API blast radius capped: through Repo the drift
self-heals via an unrelated "no such savepoint" disconnect (probed
both per-call savepoint mode and the SQL Sandbox). Fixed:
refresh_transaction_status/1 zeroes the counter when landing :idle
(autocommit means every savepoint is gone); released_savepoint_state/1
treats non-positive as outermost (belt). NB: this F-B8-8 (finding) is
distinct from Run 32's [F-B8-8-handoff] (closed Run 33). **F-B8-9
(S2, FIXED, RED→green)** — a transaction-mode atom in repo config's
`:mode` key (DBConnection spells the transaction mode with the same
key; the README used both meanings one sentence apart) failed EVERY
connect with {:invalid_connection_mode, _}, bricking the pool;
callers saw only `:queue_timeout` — the error the README's own table
says a bigger pool fixes. Fixed: validate_connection_mode/1 in the
connect chain refuses the five transaction-mode atoms with a
dedicated {:transaction_mode_as_connection_mode, _} (generic wrap —
no new wrap clause); open_database/2 dropped its now-unreachable
catch-all; README disambiguates the two `mode:` meanings. Mirror
direction probed clean (config :readonly does not leak into
handle_begin; read-only pools run transactions and streams).
Seed-6 correction on record: ecto_sql's @pool_opts never forwards
`:mode` from repo config into operations — the premise "config mode
applies to every transaction" is false; the real bite is the
connect-time collision. **F-B8-10 (S2, FIXED, RED→green)** —
XqliteEcto3.URL documented AND parsed `busy_timeout=infinity` while
Run 35's validate_busy_timeout deliberately refuses :infinity at
connect: the documented URL could not open a single connection.
Fixed parser-side: busy_timeout's spec is :non_neg_integer now
(integer-only — it is a SQLite-side value), moduledoc dropped
`| infinity`; timeout/connect_timeout keep :infinity (controls
green). **F-B8-11 (S3, FIXED, RED→green)** — the guard's
`_open_or_unknown` arm folded status-READ ERRORS into fail-open
while checkout/1 and ping/1 disconnect on the identical error — a
dead connection stayed checked into the pool. Fixed: three-arm
split, read error ⇒ disconnect with the original wrapped error.
**F-B8-1 re-driven at 0.11.0: REPRODUCES** (3007 ms for a 300 ms
token; :infinity control 3005 ms proves the token contributed
nothing; uncontended control cancels at 301 ms); its DOCS half
closed — README pitch bullet + timeout section now state the
busy-wait carve-out (the busy handler blocks the progress handler,
so `busy_timeout` bounds the wait; structured
:database_busy_or_locked distinguishes it). CLEAN with controls:
declare/fetch error routing + streamed rollback-class DML under a
top-level savepoint (plain-BEGIN control — savepoint arm not weaker);
commit/rollback hooks × cancelled write coherent across four
instruments (cancelled-read + normal-commit controls);
multi-statement transaction control cannot slip the columns: [] gate
(:multiple_statements refusal, both directions); an abandoned stream
across a disconnect holds no read lock (deallocate + GC controls,
wal_checkpoint TRUNCATE evidence); non-integer :timeout unreachable
through Repo (DBConnection's deadline arithmetic raises ArgumentError
first); the cancelled branch still skips wrap_execute_error/4 —
consistent with Run 40's stamping (ConnectionError carries no
statement field). Handoffs FILED: [F-X1-7] handle_fetch error-branch
statement stamping (Run 40's truthful-nil rationale corrected: the
QUERY param carries the SQL and is ignored); [F-B8-12-handoff]
top-level mode: :savepoint runs DEFERRED, silently discarding the
default_transaction_mode: :immediate promise (B1/B2 court).
Stash-RED predicted 5/5 exactly. DRYNESS: three S2 + one S3 — **B8
stays 0 of 2, NOT DRY**; re-wets ALSO on validate_connection_mode/1,
the URL busy_timeout spec, the guard's read-error arm,
refresh_transaction_status/1's counter reset. Next-pass seeds: the
{:fallback, state} partly-dead path ({:error, {:cannot_execute, _}}
half unprobed); stmt_prepare before any cancel token (the F-B8-1
shape may cover preparation — measure); repo-config `timeout:`
(:infinity/0/sandbox — the one B8-relevant key ecto_sql DOES forward
per-operation); FK-replay × guard fault injection (a failed
release_savepoint cleanup hands the guard a diagnostics-started
transaction — the F-B8-4 shape); the negative-counter impossibility
(belt-guarded, probe-unpinned); rebuild's in_wrapping_transaction?
DBConnection.status half-blindness (shared with B7).

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
COVERING RE-RUN (Run 29, 2026-08-20 — lap 4, paired with B3; emission
sites blob-identical since Run 23, verified): FIVE confirmed + one
test-only + one filed. **F-B9-7 (S2, docs+test FIXED):**
`[:xqlite_ecto3, :checkout]` fires once per CONNECTION at connect
(source + 55-query/0-event measurement), not "per-call" as the guide
said; corrected both surfaces + a pool-level test (the old test called
the callback directly). **F-B9-8 (S2, FIXED, RED→green):** the
`fk_diagnostics` span's stop metadata dropped `conn`/`mode`
(`:telemetry.span/3` uses the returned map AS stop metadata; every
sibling merges) — a `%{mode: _}` handler detached VM-WIDE on first
diagnosed violation (control: same handler on `handle_begin`
survives); start metadata now merged in. **F-B9-9 (S3, docs-FIXED):**
first live `:exception` drive — real metadata is
kind/reason/stacktrace, NO result_class/error_reason; detachment
proven; pool-unreachable today (DBConnection raises first); both
surfaces document the shape, guide samples gained catch-alls.
**F-B9-10 (S3, FIXED):** OTel `error.type` collapsed every
disconnecting error to `"disconnect"` (the `{:disconnect, inner}`
wrapper matched generically) — mapper unwraps; the two
`error_reason` shapes KEPT and documented. **F-B9-11 (S3,
docs-FIXED):** guide table gained the three `statement_cache` rows;
the nanosecond claim now says span measurements are NATIVE units
(adapter emissions are ns). **F-B9-12 (S3 test-only, FIXED):**
statement-cache `:hit` capture was discriminator-free (the F-B9-2/3
class, ~1/3 flake in one multi-file VM) — SQL-filtered. **F-B9-13
(S3, FILED):** `fk_diagnostics_test`'s telemetry assertion fails
under the OFF build (pre-existing; the OFF CI lane runs only the
smoke file) — flag-guard or widen the lane. CLEAN: `cached_count`
before-the-action confirmed numerically (warm-cache RED evidence);
OFF/ON round trip re-driven live both directions, ON restored;
the bridge emits ZERO adapter events (the F-B9-4 evidence; ruling
stays the maintainer's). DRYNESS: finding run — **B9 stays 0 of 2,
NOT DRY**. Re-wets ALSO on: `classify_dbc`'s disconnect clause, the
`fk_diagnostics` span return shape, the guide's event table, the
OTel `error_type` unwrap. Next-pass seeds: NIF fault injection for a
pool-reachable `:exception`; `:checkout` under the SANDBOX ownership
pool (per-ownership-checkout risk — "true in tests, false in
production"); the `disconnect` event's `reason` under the Runs-23/25
disconnect paths; `statement_cache` `:miss` on the multi-statement
fallback; native-vs-ns on a non-Linux runtime; `group_fk_rows/1`
fallthroughs (filed).
COVERING RE-RUN (Run 37, 2026-08-21 — lap 5, batch 6, paired with
B3; emission sites byte-identical since Run 29's fix commit,
git-verified; fk_diagnostics moduledoc-only): **F-B9-15 (S2, FIXED)**
— OTel `error.type` collapsed to the ONE value "XqliteEcto3.Error"
for every adapter error since Run 33's connect wrap (F-B9-10's
collapse moved, not died; both docs surfaces claimed otherwise); fix
= a clause emitting the struct's typed :type atom, nil-type → struct
name, docs corrected, pins flipped/added. **F-B9-16 (S3, FIXED)** —
the statement_cache events carried [:sql] alone while the cache is
PER CONNECTION (pool-size-controlled measurement: hit-rate depressed
by pool_size misses per statement, cached_count interleaved); :conn
added to all three + per-connection sentence in both surfaces —
also makes the F-B8-9 :conn join uniform. **F-B8-9-docs CLOSED** —
the correlation line landed with probe-backed content (join
disconnect ↔ handle_execute :stop on :conn; reason shapes for
operation-error vs cancel on record). **F-B9-17 (S3, filed →
F-B9-13 WIDENED)** — the OFF build breaks FOUR files / 17 tests,
not one; entry rewritten with the settled trade-off (flag-guards
over lane-widening; whole-file guard for telemetry_test). **F-B9-18
(S3, filed → [F-B1-menu-connect-error-details] extended)** — the
connect stop event's error_reason carries the rejected config value
only as message prose; the Run-37 validators grew that family by
nine tags. Env fact pinned in the ledger: adapter telemetry is
compile-flagged OFF in :dev — telemetry probes must run
MIX_ENV=test. CLEAN: both span pairs re-anchored (merge rule
intact); :checkout under the SANDBOX ownership pool fires ZERO
per-ownership events (fresh-pool control fires 2 — F-B9-7's docs
hold in the risky configuration); the :miss-fallback seed's premise
corrected (fallback SQL fails anyway; a trailing semicolon does not
defeat the cache). Filed sweep: F-B9-14 holds (LATENT — the pragma
returns exactly 8 columns; crash shapes on record), F-B1-5 holds
with the failing-close-unconstructible caveat, F-B9-4 holds.
Deferrals explicit: pool-reachable :exception construction (carried
forward), native-vs-ns off-Linux (not probeable here). DRYNESS: an
S2 — **B9 stays 0 of 2, NOT DRY**. Re-wets ALSO on: the OTel
`error_type` clauses, the statement_cache emission metadata, the
guide's disconnect-correlation + cache paragraphs. Next-pass seeds:
the :exception construction; F-B1-5's fault injection or re-grade;
the OFF-build guard pass when it lands (verify BOTH builds); the
Multi RuntimeError shape; native-vs-ns when a non-Linux runtime is
available.

COVERING RE-RUN (Run 46, 2026-09-01 — lap 6, batch 6, paired with
B3): emission modules byte-identical since Run 29 (git-verified);
the churn = Run 44's fk_diagnostics {:truncated} status + baseline
scan, Run 40's statement field, the savepoint refusal's
ConnectionError shape — all re-anchored live. THREE S3 — F-B9-19
(FIXED): violations_count saturates at the cap and diag_tag
discarded the real total (40 orphans → count 24, total
unrecoverable from the event); violations_total added to the stop
metadata, diagnostics_status values enumerated on BOTH doc
surfaces (:truncated had been unannounced on a locked surface);
pinned with a handler capture (24/30). F-B9-20 (docs-FIXED): the
span :exception leg became pool-reachable through F-B3-17's raising
connect — full shape captured (kind/reason/stacktrace, no
result_class, OTel error.type "function_clause") — falsifying
F-B9-9's "pool-unreachable today"; both surfaces now say the phase
is real and handlers must tolerate it. F-B9-21 (docs-FIXED): the
fk_diagnostics span is linear in EVERY FK-bearing table's rows and
Run 44 doubled the scans (~36 ms at 200k child rows vs ~0.11 ms
flag-off, ~325×); the moduledoc cost paragraph now says so; numbers
ledger-recorded, no timing pin. Filed sweep: F-B9-4 reproduces
(lookup span-less); F-B9-13/17 reproduces statically (OFF lane
still one smoke file, zero flag-guards — the next fixer MUST run
both builds); F-B9-14 reproduces (five bare destructures — flagged
as the likely first real fk_diagnostics :exception). The statement
field rides handle_execute error_reason AND Multi's error value.
DRYNESS: findings — **B9 stays 0 of 2, NOT DRY**. Re-wets ADD: the
fk_diagnostics stop metadata + enumerated statuses, the
:exception-reachability prose on both surfaces.

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

COVERING RE-RUN (Run 40, 2026-08-21 — lap 5 closer, paired with X2):
the 48-member error union IDENTICAL to Run 26, zero fallthrough/nil
types, one attributed class move (cannot_open_database gained
details). **F-X1-5 (S3, FIXED)** — `Error.statement` was declared
and never written; now stamped at both wrap_execute_error clauses +
both declare error branches (fetch stays nil truthfully); pinned.
**F-X1-6 (S3, FIXED)** — `@type details` omitted the three plain-map
payloads (six shapes outside their own type, set growing unpinned);
union widened. The 18 connect tags verified end-to-end; the new
loader `:error` path CLEAN by Ecto's contract (limitations on
record). DRYNESS: findings — **X1 stays 0 of 2**. Re-wets ALSO on:
any new wrap/1 clause. Next-pass seeds: the full-48 emission
question; pin the census facts (:invalid_pragma_name malformed-only;
:invalid_stream_handle via stream_close only).

COVERING RE-RUN (Run 49, 2026-09-01 — lap 6 closer, paired with
X2): the lap's contract deltas enumerated (connect refusals 18→21
tags, all wrap-verified; details union unchanged; {:truncated,
pos_integer()} exact; the savepoint refusal's bare
DBConnection.ConnectionError divergence recorded for adjudication;
the datetime storage form logged as contract). F-X1-8 (S2, FIXED):
the Run-48 form change dropped offsets via the LOCAL wall clock —
a zoned DateTime on the raw-SQL path silently shifted by its
offset (typed surface protected by Ecto; the exposure = raw params
+ untyped fragment pins); shift_zone to Etc/UTC first (UTC-only tz
db suffices, proven), error arm degrades to the ISO form; pinned.
F-X1-7 (S3, FIXED, CLOSED): handle_fetch now stamps the failing
SQL from the query DBConnection passes (trace-proven pre-fix);
pinned in stream_test. F-B1-9's {tag, binary} collision re-verified
+ widened by one tag (stays in the menu, 21 sites). The full-48
emission question ANSWERED (19/33 provoked + zero wrap drift; rest
reachable-as-caller-tuples with Error.wrap public); busy-slot
claims 4/4 through a real pooled checkout; :invalid_pragma_name pin
confirmed; **Run 40's :invalid_stream_handle pin proposal REFUTED
(graceful post-close degradation — not constructible)**. DRYNESS:
findings — **X1 stays 0 of 2, NOT DRY**. Re-wets ADD: the four
temporal encode_param clauses, handle_fetch's stamp, any new wrap
clause, the next xqlite release.

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
COVERING RE-RUN (Run 40, 2026-08-21 — lap 5 closer, paired with X1):
drift verdict — hex tarball ≡ v0.11.0 tag on all six native sources;
repo worktree differs only in the clippy rewrite (no behavior) and
**F-X2-3 (S2, staged)**: Run 26's two xqlite doc fixes (the
query_with_changes rule + the compatibility statement) never shipped
— hex/hexdocs still teach the abandoned empty-columns rule (probe:
the shipped doc's model predicts 0 for all three RETURNING shapes;
the shipped code reports the real count). Remedy staged: xqlite
CHANGELOG Unreleased section records the 0.11.1 patch contents;
version bump/tag/publish = the maintainer's; a patch stays inside
`~> 0.11.0`, no adapter change owed. NIF call surface 41 distinct
name+arity, all exported exactly (AST-walk census — the earlier
name-grep miscounts explained). F-X1-4 holds across eight pairing
sites (noted: STE drafts un-versioned; bench lockfile comment
stale); F-B8-2's blocker intact; F-X2-1 stays closed, re-verified
through the adapter's CACHED path. Doc parity on cancellation + the
WAL read-back story CLEAN across the pair. DRYNESS: an S2 — **X2
stays 0 of 2, NOT DRY**; TWENTY straight finding runs; **LAP 5
COMPLETE**. Re-wets ALSO on: the next xqlite release. Next-pass
seeds: hexdocs rendering read directly; the busy-slot claims
through a pooled checkout.

COVERING RE-RUN (Run 49, 2026-09-01 — lap 6 closer, paired with
X1): the NIF call census = 41 name+arity / 73 occurrences, ALL
exported at 0.11.0 (AST-walk, @spec-pruned; the un-pruned control
explains historical miscounts). Forward blast vs the checkout
(1f1c8de, the staged 0.11.1) = ZERO product surface: the hex-vs-
checkout diff is exactly two files (a doc correction + a clippy
lint), and the "pending" 20-NIF DirtyIo flip ALREADY SHIPPED in
0.11.0 (91 DirtyIo in both trees — the stale standing note dies
here). F-X2-4 (S3, FILED, xqlite court): the lint rewrite raises
the source-build Rust floor to 1.88 undeclared (no rust-version,
stable-only CI). The xqlite-court queue verified REAL at the
source (no ROWID arm, no bare-"constraint failed" handling in
constraint_parse.rs — F-B5-31/F-B5-26 halves genuinely owed). The
~> 0.11.0 pin admits the coming patch automatically — no adapter
change owed. [F-B8-2] holds. DRYNESS: findings — **X2 stays 0 of
2, NOT DRY**. Re-wets: the next xqlite release (F-X2-3 + F-X2-4),
any adapter NIF-call addition.

