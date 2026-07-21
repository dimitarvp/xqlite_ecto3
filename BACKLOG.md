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
- [F-B5-2] (S3) A CUSTOM-named plain or partial unique index cannot be
  matched by its declared name: SQLite's violation message for such
  indexes carries the `table.column` form, so `to_constraints/2`
  derives the conventional `<table>_<cols>_index`; a changeset
  declaring `unique_constraint(:v, name: :my_custom)` never matches
  and Ecto raises `Ecto.ConstraintError` (loud, not silent — deciding
  probe: the control with the derived name converts, the custom name
  raises). Expression unique indexes DO carry their real name
  (`index 'name'` message form → `index_name` direct path). Remedy is
  a maintainer call: document the naming contract in the
  constraint-mapping docs, or synthesize the name by matching
  `index_list` unique indexes over the violated columns (ambiguous
  when several cover the same columns). (Run 10, B5)
  RULED (maintainer, 2026-07-21): implement the SYNTHESIS remedy from
  the get-go — resolve the real index name via `index_list` +
  `index_info` on the violation path (reactive-replay style, like the
  rich FK diagnostics); when several unique indexes cover the violated
  columns, emit all candidate names. Stays OPEN until implemented —
  queued to land with B5's remaining covering runs.
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
