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
never docs-from-memory. Coverage: wave-1 verified the 17 real
`Ecto.Adapters.SQL.Connection` callbacks; the full behaviour diff
(Adapter/Transaction/Migration/Structure + DBConnection) is owed.

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
Coverage: strong primary ledger; ECTO_INTEGRATION_TAGS.md drifted
(wave-1); README "suites run green" claim unverified for two tags.

### B3. Sandbox + pooling under a single writer
The week-one adopter surface. Probes: `:memory:` pooling trap (do we
guard pool_size > 1 like ecto_sqlite3 raises? UNKNOWN — probe);
connect-time PRAGMA storms under pool cold-start (file-level
serialization class); wedged-txn-state symmetry after failed ops
(commit vs rollback status reset); busy storms under `async: true`
app suites; Sandbox ownership semantics. Coverage: sandbox suite
runs shared cases; none of the storm/guard probes run.

### B4. Type round-trips as properties
dump → store → load == identity per Ecto type (StreamData);
encode-only load paths pinned explicitly; Decimal precision path
(anything silently through REAL = data-integrity class); UUID
BLOB/TEXT interop + joins; JSON fidelity incl. key-type round-trip +
double-encode pin (object lands, not escaped string); usec
truncation; offset-preserving DateTime inherited semantics (format
drift between stored form and bound-param comparisons —
wrong-results class). Coverage: types/ suites exist (5 files);
no property matrix.

### B5. Constraint mapping
Names match what `unique_constraint/3` etc. expect; **PRAGMA
foreign_keys is per-connection and OFF by default — prove enforced
on EVERY pooled connection including after reconnects.** Coverage:
flagship structured errors + rich FK diagnostics shipped and
un-excluded the shared tag; reconnect-enforcement probe owed.

### B6. Query translation
LIKE's ASCII-only case-insensitivity; NOCASE collation limits; NULL
in joins/aggregates/DISTINCT; RETURNING quirks (ordering, trigger
interactions); on_conflict/upsert mapping; subquery LIMIT; windows;
fragment passthrough; grammar-gap seeds from sibling trackers
(EXISTS double-parens, ON CONFLICT expression targets, UPDATE FROM
subquery aliasing). Coverage: DISTINCT ON + DELETE+JOIN heavily
pinned; grammar-gap shapes not pinned.

### B7. Migration ergonomics (novel surface)
No reference implementation exists = extra scrutiny. Probes: which
DDL ops supported vs refused, and are refusals LOUD (error) never
silent no-ops — sweep every path; DDL-in-transaction semantics;
rebuild-dance correctness (AUTOINCREMENT seq, indexes, triggers,
FK check); downgrade paths. Coverage: rebuild engine + helpers
tested; loud-refusal sweep not run.

### B8. Timeout→cancel divergence (flagship)
Ecto's `:timeout` elsewhere = stop waiting (query may complete);
here = the query dies. Deliberate divergence. Probes: post-cancel
connection state (txn aborted? poisoned or reusable? DBConnection
disconnect fired?); divergence documented LOUDLY (adopter retry
logic written for postgres semantics may misbehave). Coverage:
cancel threading tested; post-cancel state matrix owed.

### B9. Telemetry
Two compile configurations = two builds — CI must build AND test
both (probe: does it?); standard ecto telemetry contract
(event names/measurements/metadata) verified against Ecto.Repo's
own docs/source; extras (txn_state, connection_stats,
statement-cache hit/miss/evicted, OTel mapping) each need a
consumer-side assertion. Coverage: events + OTel mapping tested;
statement-cache events pinned; both-configs-in-CI unverified.

### B10. Benchmarks
Any number the announcement might cite is reproduced from a clean
checkout first. Coverage: bench/ exists; ledger-first policy;
no clean-checkout reproduction yet.

## Cross-repo axes (one system)

### X1. API/error-shape contract
Pin with contract tests IN THIS REPO: every xqlite error shape the
adapter matches on; every xqlite function+arity it calls. Version
lockstep policy (`~>` bounds) + a compatibility row in both READMEs;
release trains (which xqlite versions does an adapter change need?).
Coverage: NOT BUILT — a standing charter deliverable.

### X2. Blast radius is cross-repo by default
Any xqlite public-surface change enumerates adapter call sites
before it lands, every time. Coverage: operative practice (the
0.9.0 wrapper sweep did exactly this); not yet mechanized.

## Release-readiness (adapter-specific additions)

The shared RC-gate checklist lives in xqlite/REVIEW_AXES.md. Adapter
additions: the 21 accidental-public SQL helpers → `defp` BEFORE
first publish; CLAUDE.md bootstrap; exclusion-ledger reconciled +
two-tag probe resolved; Elixir-floor claim vs CI lanes; Hex badge
trio + publish mechanics per the pre-launch checklist.
