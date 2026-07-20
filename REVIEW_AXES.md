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

## Release-readiness (adapter-specific additions)

The shared RC-gate checklist lives in xqlite/REVIEW_AXES.md. Adapter
additions: the 21 accidental-public SQL helpers → `defp` BEFORE
first publish; CLAUDE.md bootstrap; exclusion-ledger reconciled +
two-tag probe resolved; Elixir-floor claim vs CI lanes; Hex badge
trio + publish mechanics per the pre-launch checklist.
