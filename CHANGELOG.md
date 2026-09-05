# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

### Added

- **`XqliteEcto3.Types.ExactDecimal`.** An opt-in `Ecto.Type` that
  stores a decimal as canonical text over a `:string`/TEXT column,
  keeping every digit and the scale you wrote. It binds text rather
  than a number, so neither the ~15-significant-digit float64 ceiling
  that makes `:decimal` raise `DecimalPrecisionError` nor the silent
  float-to-text drift a `:decimal` field suffers over a TEXT column
  applies, and both of `Decimal`'s own limits (a 34-digit parse, a
  6178-character print) are lifted on the way in and out. `cast/1` is
  deliberately wider than Ecto's `:decimal` — any number of digits —
  and returns `:error` where Ecto's raises for a non-finite value.
  The trade is that SQL ordering, ranges and equality on the column
  are textual, not numeric: `9.5` and `9.50` are one value to Ecto and
  two rows to SQLite.

- **Real unique index names in constraint errors.** On a UNIQUE
  violation the adapter reads the table's unique index names back
  (`PRAGMA index_list` + `index_info`) and reports the real name when
  exactly one index covers the violated columns, so
  `unique_constraint(:email, name: :users_email_uniq)` converts
  against a custom-named index exactly like PostgreSQL. Every
  candidate lands on the error
  (`details.unique_index_names`/`unique_index_lookup`); ambiguous and
  autoindex cases fall back to Ecto's derived
  `<table>_<columns>_index` name. Postgres parity cuts both ways: a
  bare `unique_constraint/1` against a custom-named index now raises
  `Ecto.ConstraintError` — declare the real name. The lookup runs
  only on the error path, is time-budgeted, and degrades to the
  derived name if its reads fail. Streamed DML
  (`Ecto.Adapters.SQL.stream/4`) skips the lookup and reports
  `unique_index_lookup: :not_run`.

- **`XqliteEcto3.Telemetry.OpenTelemetry`.** A pure, dependency-free
  mapping from the adapter's telemetry events to OpenTelemetry's
  stable database semantic-convention attributes, mirroring
  `Xqlite.Telemetry.OpenTelemetry`. Spec sources cited per name in
  the module docs.

- **Repo-level observability surface.** `XqliteEcto3.txn_state/2`
  and `connection_stats/1` observe a pooled connection through the
  pool (with documented plain-pool-vs-Sandbox checkout semantics —
  also now documented on `with_xqlite/3`), and the new `hooks:` repo
  config installs xqlite's update/WAL/commit/rollback/progress hooks
  on every pooled connection at connect time, delivering messages to
  registered process names. Unresolvable names and unknown hook
  kinds are structured connect errors.

- **Statement-cache telemetry.**
  `[:xqlite_ecto3, :statement_cache, :hit | :miss | :evicted]`
  events (compile-flagged like the rest of the adapter's telemetry):
  `cached_count` measurement plus the statement's SQL in metadata —
  enough to size `statement_cache_size` from production traffic.

- **`url:` repo config works out of the box.** Ecto's generic URL
  parsing rejects `sqlite://` URLs (no host, multi-segment path), so
  the adapter now injects a default `init/2` into repos that don't
  define their own, translating `:url` through
  `XqliteEcto3.parse_url!/1` before Ecto sees it —
  `config :app, Repo, url: System.fetch_env!("DATABASE_URL")` is all
  a Phoenix app needs. Repos with a custom `init/2` are left
  untouched (the README shows the two lines they keep).

- **Per-connection prepared-statement cache.** Every pooled connection
  keeps an LRU cache of prepared statements keyed by SQL text
  (`statement_cache_size`, default 50; `0` disables). Repeated
  statements skip SQLite's parse/plan step entirely — the first
  SQLite adapter in the ecosystem to cache prepared statements.
  Query timeouts keep working through cancellable statement stepping;
  multi-statement SQL falls back to the uncached path; schema changes
  are absorbed by SQLite's v2 auto-reprepare; evicted and
  disconnect-time statements are finalized eagerly so connections
  close cleanly.

- **`XqliteEcto3.explain_analyze/3`.** Runs an Ecto queryable under
  SQLite's real execution counters and returns xqlite's structured
  report — query plan, per-scan loop/visited-row counters
  (`sqlite3_stmt_scanstatus_v2`), statement counters, wall time.
  Executes the statement (that's what makes the numbers real);
  `wrap_in_transaction: true` rolls the execution back via a
  savepoint, so it composes with sandbox tests and caller
  transactions. Parameters go through the production encoding path.
  Built on `with_xqlite/3`; something `EXPLAIN QUERY PLAN` alone
  cannot give you.

- **Three connection knobs.** `custom_pragmas: [{name, value}]` —
  arbitrary PRAGMAs applied after the adapter defaults so explicit
  config wins (config-only by design; not URL-exposed).
  `mode: :readonly` — read-only pools: opens via `open_readonly`,
  skips write-requiring default pragmas (journal_mode, auto_vacuum,
  wal_autocheckpoint), and writes fail with the structured
  `{:read_only_database, _}` error. `default_transaction_mode:
  :deferred | :immediate | :exclusive` plus a per-transaction
  `mode:` override on `Repo.transaction/2` — the default remains
  `:immediate` (locks up front, no deadlock-prone mid-transaction
  upgrades; a deliberate divergence from ecto_sqlite3's `:deferred`).
  The concurrency model itself is unchanged and permanent.

- **`XqliteEcto3.with_xqlite/3` — the xqlite bridge.** Checks a
  connection out of the repo's pool and hands your callback the raw
  `XqliteNIF` handle, so SQLite-specific xqlite features (session
  extension, blob I/O, online backup, serialize/deserialize,
  extension loading, schema introspection) run against the same
  database and pool — no out-of-band second connection. The handle
  is valid only inside the callback; sandbox tests see their own
  uncommitted writes through it.

- **`DISTINCT ON` (expression DISTINCT) now works.** Ecto's
  `distinct: expr(s)` rewrites to a `ROW_NUMBER()` window subquery
  with PostgreSQL-parity semantics: one row per distinct-expression
  group (winner picked by `order_by`), results ordered by the
  distinct expressions then `order_by`. Whole-source schemaless
  selects and mixing with union/intersect/except raise
  `Ecto.QueryError`. The shared suite's `:subquery_in_distinct` tag
  is un-excluded.

### Changed

- **Datetimes are stored in SQLite's own form.** `:utc_datetime` and
  `:naive_datetime` values (and their `_usec` twins) are written as
  `YYYY-MM-DD HH:MM:SS[.ffffff]` — space separator, no trailing `Z`.
  The previous ISO-8601 `T`/`Z` form byte-sorted against SQLite-written
  values at the separator, and the trailing `Z` made a sub-second
  value sort BEFORE its own whole second — `ORDER BY` and range
  filters over mixed-writer or mixed-precision columns returned
  wrong rows. `XqliteEcto3.Types.TimestampTZ` keeps its
  offset-carrying ISO form (offset storage is its purpose). Rows
  written by earlier versions keep the old form and still load; to
  restore instant ordering against them, normalize once:
  `UPDATE t SET at = replace(replace(at, 'T', ' '), 'Z', '')`.

- **A NOT NULL violation raises the structured `XqliteEcto3.Error`
  instead of `Ecto.ConstraintError`.** The old mapping emitted
  `[not_null: "table.column"]`, but Ecto has no
  `not_null_constraint/3` to declare, so the only outcome was an
  `Ecto.ConstraintError` advising an impossible call — and the
  structured error (table and column intact) was discarded on the
  way. The reference adapters emit nothing here too. Catch the case
  before the database with `validate_required/2`.

- **Top-level `Repo.transaction(fun, mode: :savepoint)` is refused.**
  A lone SAVEPOINT runs the transaction DEFERRED, silently discarding
  `default_transaction_mode: :immediate` — and a deferred write that
  loses the lock race fails instantly with a lost update, because
  SQLite never consults the busy handler for a stale-snapshot lock
  upgrade. The begin now fails loudly (`DBConnection.ConnectionError`
  naming the rule) when no enclosing transaction is open; nested
  savepoints — including everything the SQL Sandbox does — are
  unaffected.

- **Query placeholders render as numbered `?N`.** Previously bare
  `?`; numbering pins each placeholder to its parameter-list
  position, so clause-reordering rewrites (DISTINCT ON) cannot skew
  bindings. Generated SQL text changes; binding behavior does not.
  The `insert` path already used `?N`; the `update`/`delete` DML
  builders keep bare `?` (their clause order is fixed).

- **`RETURNING` accepts `{:unsafe_fragment, iodata}`** in insert /
  update / delete returning clauses — ecto_sql 3.14's new escape
  hatch, mirroring the PostgreSQL adapter's behavior.
- **Table modifiers pass through in `CREATE TABLE`.** ecto_sql 3.14's
  `create table(..., modifiers: "...")` lands between `CREATE` and
  `TABLE` (SQLite's grammar accepts `TEMPORARY` there). Strings and
  nil only; anything else raises `ArgumentError`.
- **Dynamic JSON path segments.** `json_extract_path` (and the
  `o.meta[o.label][o.idx]` bracket syntax) now accepts runtime path
  segments — column references and expressions, not just literals.
  Built by SQL path concatenation with a runtime `typeof` dispatch:
  integers index arrays, anything else is a dot-safe quoted object
  key; a NULL segment yields NULL instead of an error. Un-excludes
  the shared suite's `:json_extract_path_with_field` tag, including
  its `parent_as`/subquery variants. A runtime key containing a
  backslash or a double quote is escaped in the generated SQL, so it
  matches the literal key instead of silently missing.
- **Documented boolean-extraction story.** Untyped
  `select: o.meta["enabled"]` returns SQLite's storage-faithful
  `1`/`0` — there is no boolean storage class and no JSON wire
  typing, and Ecto provides no load hook for untyped select
  expressions, so no SQLite adapter can return `true` there
  (PostgreSQL/MySQL pass via protocol-level typing). The sanctioned
  fix, `select: type(o.meta["enabled"], :boolean)`, routes through
  the adapter's `:boolean` loader and is covered by adapter-owned
  tests.

- **Rich FK diagnostics (opt-in).** `rich_fk_diagnostics: true` repo
  config. SQLite reports FK violations with no table, column, or
  constraint name; with the flag on, the adapter replays the failed
  statement under `defer_foreign_keys` inside a throwaway savepoint,
  reads `PRAGMA foreign_key_check` + `foreign_key_list`, and attaches
  sorted, deterministic `%XqliteEcto3.Error.FkViolation{}` entries
  (child table/rowid, parent table, exact columns, and a
  convention-synthesized constraint name) to the error. As a result
  `Ecto.Changeset.foreign_key_constraint/3` matches like on
  PostgreSQL, and the shared Ecto suite's `:foreign_key_constraint`
  exclusion is gone. Commit-time deferred violations are diagnosed
  in place (no replay). Streamed DML skips the replay and reports
  `fk_diagnostics: :not_run`. Zero happy-path cost; diagnostic failures
  degrade to the original error with
  `fk_diagnostics: {:unavailable, reason}`. Emits a
  `[:xqlite_ecto3, :fk_diagnostics]` telemetry span.

### Fixed

- **`alter table ... add` keeps `null: false` on datetime columns.**
  Adding a `:utc_datetime` or `:naive_datetime` column dropped the
  option before rendering, so `add :at, :utc_datetime, null: false` —
  and `timestamps()` inside an `alter` block, which asks for exactly
  that — produced a nullable column and said nothing. Every type now
  renders the constraint the migration asked for, matching what the
  table rebuild and `create table` already did. SQLite decides whether
  the add goes through: always on an empty table, and on a populated
  one only with a non-NULL constant default, otherwise it raises
  `%XqliteEcto3.Error{type: :sqlite_failure}`. A migration that
  silently produced a nullable column before will now either produce
  the column it asked for or fail; the README's known limitations and
  the ecto_sqlite3 migration guide cover the way through.

- **The table rebuild's affinity check no longer goes blind on a table
  with a column named `rowid`.** The check poured the column into a
  scratch table and compared the two side by side through SQLite's row
  id — which a user column of that name shadows, so on such a table the
  comparison matched nothing, the check counted zero, and the rebuild
  rewrote stored values without a word (`'007'` became the integer
  `7`). The comparison now happens inside the scratch table alone, with
  no row id involved. Column names spelled `ROWID` or any other casing
  are covered too.

- **The same check runs on one pinned connection and always drops its
  scratch table.** That table is a temporary one, which in SQLite
  belongs to the connection that created it. The four statements around
  it took whatever connection the pool handed each of them, so with a
  pool larger than one and no wrapping transaction — a migration marked
  `@disable_ddl_transaction` — they could land on different
  connections: the rebuild failed with "no such table" and left the
  scratch table behind on whichever connection had made it.

- **Rich FK diagnostics no longer report "no violations" for a
  violation they cannot tell apart from a pre-existing one.** The
  replay subtracts the violations that existed before the statement,
  row by row; a `WITHOUT ROWID` child table reports every violation
  with a `nil` rowid, and `INSERT OR REPLACE` at an orphan's rowid
  reproduces the orphan's row exactly, so in both cases the statement's
  own violation vanished from the diagnosis and `fk_diagnostics: :ok`
  came back with an empty list, which left a declared
  `foreign_key_constraint` unmatched. Such a diagnosis now reports
  `{:unavailable, :masked_by_baseline}`.

- **A raw `COMMIT` under rich FK diagnostics is diagnosed in place.**
  A deferred violation that surfaces at a `COMMIT` issued through
  `Repo.query` was replayed as if it were a statement: the replay
  could not name anything, and its cleanup reset `defer_foreign_keys`
  inside the caller's still-open transaction. Transaction-control
  statements now take the commit-time diagnosis, which reads the
  violating rows that are still present and touches no pragma.

- **`datetime_add`, `ago`, and `from_now` compare in the stored text
  form again.** The datetime storage form changed to SQLite's own
  `YYYY-MM-DD HH:MM:SS[.ffffff]` earlier in this cycle, but interval
  arithmetic still produced the old `T…Z` text, and SQLite compares
  text byte-wise: every stored datetime sorted below any
  `datetime_add` result on the same day, so a filter such as
  `where: e.at > ago(1, "hour")` silently returned no rows. The
  emitted form now matches storage (six fractional digits). The
  undocumented `:datetime_type` application-environment key that
  selected between two such formats is gone.

- **`type(^value, :binary)` finds its row.** The tagged parameter
  rendered as `CAST(? AS BLOB)`, but a valid-UTF-8 binary is bound
  and stored as TEXT, and SQLite never equates TEXT with BLOB, so the
  comparison matched nothing. The parameter is now bound bare, which
  matches both TEXT- and BLOB-stored values.

- **`values/2` quotes its column aliases.** A field named like an SQL
  keyword (`:order`) was spliced unquoted into `column1 AS order` and
  failed as a raw syntax error.

- **`structure_dump/2` answers with a tuple when it cannot dump.**
  `mix ecto.dump` shells out to the `sqlite3` command-line program;
  with that program missing the callback raised a bare
  `ErlangError :enoent` out of `System.cmd/3`, so the task died with
  a stack trace that never named `sqlite3` instead of the "couldn't
  be dumped" message it prints for `{:error, term}`. The executable
  is now looked up first (`{:error, {:missing_executable, "sqlite3"}}`),
  and a dump path that cannot be created or written is
  `{:error, {:cannot_write_dump, path, posix_reason}}` rather than a
  `File.Error`. The README now states the `sqlite3` requirement.

- **A negative `:timeout` no longer runs the query unbounded.** A
  non-positive timeout is clamped to zero, so it cancels at once
  like `timeout: 0`. Before, a negative value crashed the canceller
  process silently and the statement ran to completion while
  DBConnection's already-expired deadline recycled the connection
  underneath the next caller.

- **A lock-contended `BEGIN` keeps its connection.** With the
  default `:immediate` mode a held write lock makes transaction
  start fail with `:database_busy_or_locked` after `busy_timeout`,
  and the driver disconnected a healthy connection on every such
  failure — one reconnect per contended transaction, worst under
  the multi-writer load the README's retry advice describes. The
  busy error now returns like a busy statement does; other begin
  failures still disconnect. The README says that transaction start
  waits the full `busy_timeout` and that `:timeout` does not bound
  it.

- **`handle_begin`'s two refusals carry a typed error.** A savepoint
  begin with no enclosing transaction and an unknown transaction
  mode raised bare `DBConnection.ConnectionError`s, the only two
  refusals in the driver without a `:type`. They are
  `%XqliteEcto3.Error{type: :savepoint_without_transaction |
  :invalid_transaction_mode}` now, with the mode and transaction
  status in `details`, and the savepoint message no longer tells
  the caller to drop an option it may never have passed —
  `Ecto.Adapters.SQL.Sandbox` forces `mode: :savepoint` itself.

- **SQL with no statement is reported as `:cannot_execute`.**
  Whitespace- or comment-only SQL was refused precisely at prepare
  time and then handed to the uncached path anyway, where SQLite
  answered `SQLITE_MISUSE` — the code that means an adapter bug.
  The prepare-time refusal now surfaces as is. With
  `statement_cache_size: 0` the misuse answer remains until xqlite
  refuses no-statement SQL on its one-shot query path as well.

- **A non-UTC `DateTime` on the raw-SQL path stores the right
  instant.** The datetime-form change dropped the offset via the
  local wall clock, so a zoned value handed to `Repo.query` (or an
  untyped `fragment` pin) silently shifted by its offset. The value
  is shifted to UTC before the designator-less form is written.
  Typed fields were never affected — Ecto normalizes them first.

- **A failing streamed statement carries its SQL on the error.** The
  cursor-fetch error path was the one of five error sites without
  the statement stamp; a mid-stream constraint violation now names
  the statement like declare- and execute-time failures do.

- **A timestamp SQLite itself wrote is readable.** A `:utc_datetime`
  value written by `CURRENT_TIMESTAMP`, `datetime()` or any other
  tool carries no offset designator, and the loader failed it —
  one such row crashed every read of the table. An offset-less text
  under a UTC type now loads with `Etc/UTC` attached; `date()` and
  `time()` output already loaded.

- **Non-finite decimal text fails the load with the typed error.**
  `Decimal.parse/1` clean-parses `NaN`/`Infinity` spellings, and
  Ecto's `:decimal` then raises an exception naming no field, row,
  or value. The loader refuses them now, so the typed load failure
  names all three.

- **The rebuild's affinity pre-flight uses the copy itself as its
  oracle.** The CAST-based predicate over-refused columns holding
  plain text (`CAST` converts junk to 0; the copy's affinity
  coercion carries it byte-exact) — such columns now pour through a
  NUMERIC scratch table and only values the pour actually changes
  count as rewrites. Tables declared WITHOUT ROWID are unaffected: a
  rebuild refuses them outright, before this check runs.

- **The vendored-suite exclusion artifacts are re-trued and now
  self-checking.** The README's exclusion-taxonomy sentence gains the
  bucket it was missing (deliberate adapter/suite decisions, beside
  SQLite limits and tracked gaps) and the two whole-file skips
  (`lock.exs`, `query_many.exs`) get documented rows; four rationales
  that blamed SQLite for adapter decisions or named refuted mechanisms
  are rewritten; `query_many`'s refusal now says "not supported by
  this adapter" (one prepare call compiles one statement — looping
  the tail is implementable, the adapter chose not to). A new test
  mechanically checks the helper↔doc bijection, the test-line pointer
  rule, and the whole-file rows on every run.

- **A misconfigured `hooks:` progress option no longer takes the repo
  supervision tree down.** `hooks: [progress: {Name, every_n: "500"}]`
  (an env-var string), `every_n: nil`, a negative, or a non-atom
  `tag:` raised inside `connect/1` — a crash DBConnection counts
  against restart intensity, so the repo's whole supervision tree
  died within milliseconds of boot with no error naming the config
  key. Every progress option is validated now (`every_n` an integer
  >= 1, `tag` an atom, unknown keys and non-keyword option lists
  refused) with structured connect errors DBConnection retries with
  backoff.

- **A fresh database's first boot no longer logs a burst of failed
  connects.** Pool members racing each other to run
  `PRAGMA journal_mode = wal` on a not-yet-WAL file collided on most
  first boots, and SQLite refuses the losing flip without consulting
  the busy handler — so `busy_timeout` could not help (measured up to
  120 s). The connect now retries the journal-mode write a bounded
  number of times, milliseconds apart; the loser succeeds on the
  first retry in practice. A genuinely held lock still fails with the
  structured busy error. The README section that blamed boot-time
  migrations and recommended raising `busy_timeout` is rewritten.

- **A vertical tab before a transaction keyword no longer desyncs the
  transaction-state tracking.** SQLite skips a vertical tab inside a
  whitespace run (settled from the bundled tokenizer source), but the
  adapter's keyword scan did not — `" \vBEGIN"` through raw SQL
  opened a transaction the tracking missed, re-opening both failure
  doors the BOM/semicolon fix closed: a silently-committing "open"
  transaction, and a healthy pooled connection destroyed by a stale
  flag.

- **The FK-diagnostics stop event carries the real violation total.**
  The event's `violations_count` saturates at the materialization cap
  while the real number was discarded; `violations_total` now carries
  it, and the `diagnostics_status` values (`:ok`/`:truncated`/
  `:unavailable`) are enumerated on both doc surfaces.

- **The table rebuild refuses a `modify` that would silently rewrite
  stored values.** The rebuild's `INSERT … SELECT` converts every row
  through SQLite's affinity rules — the one door the parameter-binding
  guards never see — so `modify :code, :decimal` on a populated TEXT
  column silently turned `'007'` into `7` and rounded a 20-digit
  decimal through float64 while the migration reported success, and a
  `modify` re-rendering a column into TEXT affinity (the `:jsonb`
  alias family) stringified numeric storage classes, silently changing
  `ORDER BY` and range filters. A pre-flight now counts the stored
  values the copy would rewrite and refuses before any destructive
  step, naming the column and both affinities; values that convert
  exactly migrate freely.

- **A column named `check` (or `collate`, `deferrable`) no longer
  blocks its table's rebuild.** The construct scans read
  quoted identifiers verbatim, so `add :check, :boolean` made every
  later `modify` refuse claiming a CHECK constraint the table does
  not have. The scans now run over a product that empties quoted
  identifiers; real constructs still refuse.

- **A stored column type SQLite cannot re-read bare no longer bricks
  the rebuild.** A carried type text like `foo-bar` or a reserved
  word was spliced bare into the transient `CREATE TABLE` — a syntax
  error that made the table permanently un-rebuildable. Such spellings
  are re-emitted as quoted identifiers (same affinity). The same
  keyword rule now also applies to migration type atoms:
  `add :x, :set` raises `UnsupportedTypeError` instead of dying as a
  raw SQLite syntax error.

- **A parenthesis inside a string literal no longer aborts a rebuild's
  default check.** `default: fragment("('a)b')")` rendered and stored
  correctly but the post-check's parenthesis counter read the literal's
  `)` as structure and aborted the migration; it now counts over the
  literal-blanked text.

- **A constraint error with no derivable name maps to no constraint
  instead of a nil one.** A virtual table (FTS5) reports a duplicate
  rowid as a primary-key violation with the bare message "constraint
  failed" — no table, no columns — and the mapping emitted
  `[unique: nil]`: `match: :suffix`/`:prefix`/regex crashed inside
  Ecto and `:exact` raised advice naming `nil`. No nil name ever
  leaves the mapping now (unique, primary key, and check alike);
  empty lets ecto_sql re-raise the structured error.

- **Rich FK diagnostics no longer blame the statement for
  pre-existing orphans.** `PRAGMA foreign_key_check` scans the whole
  database, so orphans written with enforcement off (SQLite's own
  default, or the `foreign_keys: false` repo option) anywhere in the
  file were reported as violations of whatever statement failed —
  breaking `foreign_key_constraint/3` conversion for the whole
  database with one bad row. The replay now diffs against a baseline
  taken inside its savepoint and reports only the statement's own
  violations. (Commit-time deferred-FK failures still scan globally —
  there is no pre-transaction baseline; documented.)

- **Rich FK diagnostics cap the violations they materialize.** A
  `Repo.delete` of a parent with N children built N violation structs
  on the error path, unbounded. At most 24 are attached now; more
  sets `fk_diagnostics: {:truncated, total}`.

- **A unique index dropped by concurrent DDL mid-lookup degrades to
  the derived name instead of silently changing the candidate
  count.** `PRAGMA index_info` on a vanished index returns empty
  rather than an error, and the silent subtraction flipped which
  constraint name was emitted roughly 50/50 under a concurrent index
  rebuild. The lookup now reports
  `unique_index_lookup: {:unavailable, {:index_vanished, name}}` and
  falls back to the conventional derived name.

- **`type(expr, :decimal)` casts to NUMERIC instead of REAL.** The
  query-side cast forced every tagged decimal through float64, so an
  integer-exact decimal past 2^53 came back as a different number
  from `select: type(o.amount, :decimal)` and an equality filter
  written as `where: o.amount == type(^dec, :decimal)` found no rows
  — silently, in both cases. NUMERIC is the same affinity the DDL
  side already declares for `:decimal` columns. `type(expr, :float)`
  still casts to REAL.

- **Known text and blob type spellings no longer land on NUMERIC
  affinity.** A ported `add :doc, :jsonb` (or `:json`, `:xml`,
  `:inet`, `:cidr`, `:macaddr`, `:tsvector`) produced a column that
  rewrote numeric-looking text on the way in — `"007"` stored as the
  integer `7`, leading zeros gone, no error, and a delayed load
  failure later. Those spellings now declare `TEXT`, and `:bytea`
  declares `BLOB`. Unrecognized spellings still follow SQLite's own
  affinity rule; the README's Known limitations names the residual
  (`:money`, `:bit`, and friends stay NUMERIC).

- **A type spelling outside SQLite's typename grammar is refused
  with `UnsupportedTypeError`.** The passthrough rendered any atom
  verbatim into DDL, so a computed spelling containing a comma
  (`:"text, oops INTEGER"`) spliced an extra column definition into
  `CREATE TABLE`. Identifier words plus an optional `(N)`/`(N,M)`
  suffix pass; everything else raises with the offending spelling on
  the error.

- **A non-0/1 stored value under a `:boolean` field fails the load
  with Ecto's typed error instead of crashing the query.** The
  boolean loader returned an error tuple, a shape Ecto's loader
  pipeline has no clause for, so `Repo.all` died with a
  `FunctionClauseError` deep in `Ecto.Type`. It now refuses like
  every other loader and Ecto raises its load failure naming field,
  type, and value.

- **A foreign-key violation without rich diagnostics surfaces the
  structured error instead of a nil constraint name.** With the
  default `rich_fk_diagnostics: false`, `to_constraints/2` returned
  `[foreign_key: nil]`: a declared `foreign_key_constraint/3` never
  matched (`Ecto.ConstraintError` advising the very call the user
  already made), and `match: :suffix`/`:prefix`/regex crashed with a
  `FunctionClauseError` inside Elixir's `String`. It now returns `[]`
  — like every reference adapter that cannot name the constraint —
  so the raised error is the adapter's own, with
  `subtype: :constraint_foreign_key` and full details.

- **URL database paths are percent-decoded.** `sqlite:///var/lib/
  my%20app/db.sqlite` used to open — and silently create — a file
  literally named `my%20app`; Ecto's own URL parsing decodes, and now
  the adapter's does too. The parser also rejects `busy_timeout`
  values past int32 max, which connect-time validation would refuse
  anyway.

- **`Repo.explain/4` with an unknown `:type` raises a named
  `ArgumentError`** listing the supported values (`:query_plan`,
  `:instructions`) and pointing at `XqliteEcto3.explain_analyze/3`,
  instead of a `FunctionClauseError` naming a private function.

- **The savepoint counter survives raw transaction-control SQL.** A
  raw `COMMIT`/`ROLLBACK` run as ordinary SQL amid a managed
  savepoint updated the driver's cached transaction flag but left
  its savepoint counter stale, so the next outermost release skipped
  its status read and the rollback guard spuriously disconnected a
  later failed autocommit statement. The counter now zeroes whenever
  a transaction-control statement lands the connection in
  autocommit.

- **A transaction mode in repo config's `mode:` key is refused by
  name.** `mode:` in repo config is the connection mode
  (`:readwrite`/`:readonly`), but DBConnection spells the
  transaction mode with the same key, and `mode: :immediate` there
  used to fail every connect with the caller seeing only
  `:queue_timeout` — the one error a bigger pool cannot fix. It is
  now a dedicated structured connect error,
  `{:transaction_mode_as_connection_mode, _}`; the config key for
  transactions is `default_transaction_mode:`.

- **`busy_timeout=infinity` is rejected by the URL parser instead of
  failing at connect.** The parser documented and produced
  `:infinity`, which connect-time validation then refused, so the
  documented URL could never open a connection. `busy_timeout` is
  integer-only end to end; `timeout` and `connect_timeout` keep
  `infinity`.

- **A transaction-status read failure on the error path disconnects.**
  The rollback guard used to fail open when it could not read
  SQLite's transaction state (a closed or poisoned handle), keeping
  a dead connection in the pool; it now disconnects, the same
  disposition `checkout/1` and `ping/1` give that error.

- **A non-numeric stored value under a `:decimal` field fails the
  load with Ecto's typed error instead of a bare `Decimal.Error`.**
  NUMERIC affinity preserves BLOBs and non-numeric text (a legacy
  writer's leftovers); loading such a row used to raise a
  message-less `Decimal.Error` that took the whole query down. The
  loader now accepts only a full clean parse; anything else surfaces
  as Ecto's load failure naming the field, type, and value. The
  undocumented, half-wired `:json_library` config was removed in the
  same pass — Jason is the JSON library on every path.

- **Every pragma-bound repo-config value is validated at connect.**
  SQLite's pragma parser never errors on an unrecognized value — it
  silently picks a default, so `journal_mode: :walk` meant DELETE
  mode, `synchronous: :ful` meant NORMAL, and `foreign_keys:
  :nonsense` silently disabled FK enforcement (orphan rows accepted,
  nothing to diagnose). `journal_mode`, `synchronous`, `temp_store`,
  `foreign_keys`, `cache_size`, `auto_vacuum`, `wal_autocheckpoint`,
  `mmap_size`, and `rich_fk_diagnostics` (a struct-match consumer, so
  `"true"` used to silently disable the feature) now reject invalid
  values with structured connect errors, matching the existing three
  validators. The pragma names and values in `custom_pragmas` stay
  deliberately unchecked (the escape hatch) — documented as such —
  though a malformed option list is still refused at connect.

- **A UTF-8 BOM or a leading semicolon no longer hides transaction
  control from the driver's state sync.** SQLite's tokenizer skips
  both; the sync skipped only whitespace and comments, so
  `<BOM>BEGIN` (what a Windows-authored .sql file contains) opened a
  transaction the rollback guard could not see — post-failure writes
  became durable — and `;COMMIT` left a stale flag that destroyed a
  healthy pooled connection on the next ordinary error.

- **OpenTelemetry `error.type` names the failing error class again.**
  Since connect errors joined the `%XqliteEcto3.Error{}` wrap, every
  adapter error mapped to the one value `"XqliteEcto3.Error"`. The
  mapper now emits the struct's typed `:type` atom
  (`"constraint_violation"`, `"database_busy_or_locked"`, …), as the
  docs always claimed.

- **Statement-cache telemetry events carry `:conn`.** The cache is
  per connection, so the pool-wide `hit`/`miss`/`evicted` stream was
  un-demultiplexable — a hit-rate metric was silently depressed by
  `pool_size` misses per distinct statement. All three events now
  carry the connection reference like every sibling event, and both
  docs surfaces say the cache is per connection.

- **`busy_timeout` repo config is validated at connect.** SQLite
  stores the timeout as a C int and silently clamps negatives and
  values past 2_147_483_647 to 0 — so `busy_timeout: :infinity` (or
  `3_000_000_000`, "wait basically forever") connected fine and then
  never waited on a single lock, failing every contended statement
  immediately. Non-integers (`:infinity`, strings, floats) and
  out-of-range integers are now structured connect errors
  (`type: :invalid_busy_timeout`); `2_147_483_647` ms (~24.8 days)
  is the accepted way to spell "wait forever".

- **Decimal parameters now bind as numbers, so comparisons are
  correct everywhere.** They previously bound as TEXT; a direct
  column comparison was rescued by the column's affinity, but any
  operand WITHOUT affinity — `HAVING sum(col) > ^decimal`, an
  arithmetic fragment, `coalesce(...)` — compared text against
  numbers and silently returned wrong rows. The precision guard
  already proves which numeric form is exact, and that form
  (int64 integer, else the proven-lossless float) is now what binds.
  Values the guard rejects still raise `DecimalPrecisionError`.
  Inlined decimal literals in hand-built query ASTs now pass through
  the same guard instead of bypassing it.

- **Unsupported migration defaults are refused with a structured
  error.** A struct default (`default: Decimal.new("1.5")`,
  `default: ~D[...]`) was silently JSON-encoded — the stored default
  carried literal quotes and later reads raised. Non-boolean atoms,
  non-fragment tuples, non-byte-aligned bitstrings, and
  encoder-less structs crashed with bare errors from inside the
  migration. All three default renderers (plain path, table rebuild,
  and the rebuild's own post-check) now raise
  `XqliteEcto3.UnsupportedDefaultError` with the column, type,
  value, and reason. Plain maps and lists still JSON-encode
  byte-identically on every path; printable charlists are refused
  (write a string).

- **`:real`, `:double`, and `:double_precision` columns are created
  as `NUMERIC`.** REAL affinity converts every bind to float64, so
  int64-exact decimals silently lost digits past 2^53 on such
  columns; NUMERIC keeps them exact, matching what `:float` already
  did. A `:decimal` field over a pre-existing REAL column in a
  legacy database still has the limitation — the README's Known
  limitations names it.

- **The rollback-disconnect guard now covers raw-SQL transactions and
  streams.** SQLite rolls back the whole transaction when it rejects a
  statement under `ON CONFLICT ROLLBACK` or when a write is cancelled;
  the driver detects that and disconnects so later statements cannot
  commit durably in autocommit inside a transaction that reported
  failure. Two gaps closed: the detection depended on a cached flag
  that a `BEGIN` issued through `Repo.query` never set (the driver now
  re-reads SQLite's transaction state after a successful
  transaction-control statement run as an ordinary query — a
  leading-keyword check costing nanoseconds; a `BEGIN` sent through
  the streaming path is not seen), and the streaming callbacks
  (`handle_declare` / `handle_fetch`) bypassed the guard entirely. A
  raw transaction whose statements are not pinned to one connection
  (`BEGIN` via `Repo.query` without `Repo.checkout` on a pool) remains
  meaningless on any pooled adapter and cannot be protected.

- **Telemetry contract corrections.** `[:xqlite_ecto3, :fk_diagnostics]`
  `:stop` events now carry the documented `conn` and `mode` metadata
  (the span returned only its counters, so a handler binding `mode`
  was silently detached VM-wide on first fire). OTel's `error.type`
  now reports the real error class for disconnecting errors instead
  of the literal `"disconnect"`. The wiring guide's checkout row said
  "per-call" — the event fires once per connection right after
  connect; the guide also gained the three statement-cache event rows
  and catch-all sample handlers. Both doc surfaces now state the
  `:exception` phase's real metadata and that span measurements are
  in the runtime's native time unit (the adapter's own emissions are
  nanoseconds).

- **`with_xqlite/3` hazard notes.** The connection-scoped-state
  section now names two more standing hazards: enabling extension
  loading also leaves the SQL-level `load_extension()` function
  callable on that pooled connection for its lifetime (restore with
  `Xqlite.enable_load_extension(conn, false)`), and a connection
  whose busy slot fails fast is preferentially reused by the pool, so
  one poisoned connection can absorb and fail most contended writes.

- **Table-rebuild hardening, one review wave.** The opt-in
  ALTER-via-table-rebuild engine closed thirteen defects found by an
  adversarial review of its surface:
  - A primary key's per-member sort order now survives a rebuild:
    `INTEGER PRIMARY KEY DESC` is not a rowid alias (it takes NULLs
    and keeps real rowids), and flattening it silently rewrote stored
    key values. The rebuild reads the key's backing index and re-emits
    `DESC` inline, in `modify`, and in composite table-level keys, and
    carries rowids for a DESC key explicitly. The structural
    post-check now also snapshots rowid facts (presence, count,
    min/max), so a copy that renumbers rows fails loudly.
  - Virtual tables (fts5 and friends) and their shadow tables now
    refuse a rebuild up front. Previously every pre-flight check
    passed and the rebuild silently replaced the virtual table with a
    plain one, dropping the module's storage and breaking `MATCH`.
  - A rebuild outside a transaction (`@disable_ddl_transaction`) now
    pins one pooled connection for the whole dance. Previously each
    statement could take a different connection, failing
    non-deterministically above `pool_size: 1` and sometimes leaving
    a pooled connection stuck inside an open write transaction.
  - Removing a column that a trigger on the table reads now refuses
    up front (SQLite compiles trigger bodies lazily, so the rebuild
    used to succeed and every later write failed). Removing a column
    that a table-level UNIQUE, a foreign key, or a standalone index
    still needs also refuses up front in domain terms, instead of
    dying mid-dance with raw SQLite text.
  - `add_if_not_exists` / `remove_if_exists` now compare column names
    with SQLite's ASCII case folding, matching the rebuild path and
    SQLite itself. Previously `remove_if_exists :firstname` against a
    stored `"firstName"` was a silent no-op.
  - Map and list column defaults now work inside a rebuild block and
    render identically on the plain-ALTER path, the rebuild path, and
    the post-check (one JSON rule); boolean defaults render as
    `true`/`false` everywhere.
  - The unpreservable-construct scan no longer reads keywords inside
    string literals: a column default like `'check pending'`
    permanently blocked every future rebuild of its table. The same
    literal-blanking applies to AUTOINCREMENT detection.
  - The dependent-object check now confirms its word-scan hits
    against SQLite itself (a savepointed test rename): a view that
    merely selects a COLUMN named like the table no longer blocks the
    rebuild, while genuinely dependent views and triggers still
    refuse.
  - Granting `primary_key: true` while any current key member is
    still keyed now refuses in domain terms (it used to emit two
    primary keys and die mid-dance — on composite AND single-column
    keys). `modify ..., primary_key: false` on a composite member is
    now honored: it narrows the key like removing the member does,
    de-keying every member with a grant moves the key, and de-keying
    every member without a grant refuses (a rebuild never silently
    strips a table's key).
  - The post-check tolerates a database with no `sqlite_sequence`
    table (reachable when AUTOINCREMENT detection false-matches),
    instead of failing the migration before its first statement.

- **A `busy_timeout` of 0 no longer disables unique-index-name
  resolution.** The lookup that resolves real unique index names on a
  UNIQUE violation reuses the connection's `busy_timeout` as its
  wall-clock budget; a zero timeout (fail-fast config, or a busy
  policy/observer installed through `with_xqlite/3`) was read as "no
  time at all" and intermittently halted the lookup, so changesets
  declaring the real index name could raise `Ecto.ConstraintError`
  instead of converting. A zero-reported timeout now gets a fixed
  500 ms budget instead: a healthy lookup finishes in well under a
  millisecond, while a busy policy holding the slot (which also makes
  the pragma report 0) can no longer multiply its waits unbounded
  across the candidate reads.

- **The xqlite dependency bound is patch-level (`~> 0.11.0`).**
  xqlite is pre-1.0, so a minor bump is its break slot; the previous
  `~> 0.11` bound admitted any future 0.x minor. Each adapter release
  pins exactly one xqlite minor series, and both READMEs now state
  the pairing.

- **Connect-time pragmas accepted by the URL parser are now honored.**
  `auto_vacuum`, `wal_autocheckpoint`, and `mmap_size` — parsed and
  type-coerced since the URL feature shipped — were silently dropped
  by the driver; they now apply at connect (absent still means
  "SQLite's own default", not an adapter default). `auto_vacuum` is
  applied before any page is written so it takes effect on newly
  created databases; changing an existing database's mode still
  requires `VACUUM` (SQLite semantics). Two more params
  from the same allowlist stopped being overridden by hardcoded
  values: explicit `cache_size` and `foreign_keys` config now wins;
  the defaults are unchanged (`cache_size` of `-64_000`, meaning
  64 000 KiB, and foreign keys ON).

- **ecto_sql 3.14 compatibility.** ecto_sql 3.14.0 widened the
  `Connection.insert` callback to `insert/8` (trailing options
  keyword); fresh installs resolving 3.14 crashed `Repo.insert_all`
  with `UndefinedFunctionError` (single-row `Repo.insert` still calls
  `insert/7`, which 3.14 itself retains). One defaulted head now
  serves both arities. Ecto 3.14's
  schema-mapped fragment sources (`FROM` / `JOIN` on a fragment
  carrying a schema) also render now — previously the fragment tuple
  was quoted as a table name and SQL generation crashed. CI gained a
  fresh-resolve lane plus a weekly scheduled run so upstream drift
  surfaces between pushes.

### Changed

- **Requires ecto_sql `~> 3.14`** (was `~> 3.12`). One supported
  stack, tested exactly as claimed. This drops the pre-3.14 compat
  surface (`Ecto.Migration.Table.modifiers` is read directly now)
  and pulls decimal to 3.x — the first line patched for
  GHSA-rhv4-8758-jx7v. Adopters whose other dependencies still pin
  `decimal ~> 2.0` must update those first.

### Breaking

- **`XqliteEcto3.Error` payload restructure.** The flat
  `constraint_type` / `constraint_details` fields are replaced by a
  single `details` field carrying a typed per-class struct — a Rust
  enum with data in the variants, expressed as structs:
  - `type: :constraint_violation` → `details:
    %XqliteEcto3.Error.Constraint{subtype, table, columns, index_name,
    constraint_name, source_type, target_type, message}`
  - `type: :sqlite_failure` → `details:
    %XqliteEcto3.Error.SqliteFailure{code, extended_code, message}` —
    the primary and extended result codes were previously flattened
    into the message string and lost; now preserved structurally.
  - `type: :sql_input_error` → `details:
    %XqliteEcto3.Error.Input{code, message, sql, offset}` — only the
    message survived before; the offending SQL and byte offset were
    lost; now preserved structurally.
  - Tag-only errors keep `details: nil`, except a few named tags
    that carry a small map: the extended result code for busy,
    read-only, schema-changed, and authorization errors; the column
    number for a UTF-8 error; the path and result code for a failed
    database open.
  Migration: `e.constraint_type` → `e.details.subtype`;
  `e.constraint_details.table` → `e.details.table`. The exception
  type itself is unchanged — `rescue e in XqliteEcto3.Error` still
  catches everything.

### Added

- **`XqliteEcto3.UUIDv7.generate/0`** — time-ordered UUID v7 generator
  per RFC 9562 §5.7. Wire into a schema via
  `@primary_key {:id, :binary_id, autogenerate: {XqliteEcto3.UUIDv7, :generate, []}}`.
- **`XqliteEcto3.parse_url/1`** and **`parse_url!/1`** — parse database
  URLs (`sqlite:///path?busy_timeout=10000&journal_mode=wal`) into
  keyword-list opts. Accepts `sqlite://`, `sqlite3://`, and `file://`
  schemes; rejects URLs with a host component. Query parameters are
  allowlisted and type-coerced; unknown keys produce a structured
  `XqliteEcto3.URLError` rather than being silently dropped. Accepted
  keys: SQLite pragmas (`journal_mode`, `synchronous`, `temp_store`,
  `auto_vacuum`, `foreign_keys`, `busy_timeout`, `cache_size`,
  `wal_autocheckpoint`, `mmap_size`) plus pool / DBConnection knobs
  (`pool_size`, `timeout`, `connect_timeout`, `queue_target`,
  `queue_interval`).

## [0.1.0] - YYYY-MM-DD

Initial public release. The adapter wraps [xqlite](https://hex.pm/packages/xqlite)
for Ecto 3.x, passes the shared `ecto` + `ecto_sql` integration suite with
documented exclusions, and ships a handful of SQLite-flavored opt-in
ergonomics that other adapters do not provide.

### Added

- Full `Ecto.Adapter`, `Ecto.Adapter.Queryable`, `Ecto.Adapter.Schema`,
  `Ecto.Adapter.Transaction`, `Ecto.Adapter.Storage`, `Ecto.Adapter.Migration`,
  `Ecto.Adapter.Structure` implementations.
- `DBConnection` driver with per-query cancel tokens wired to Ecto's
  `:timeout` option, named savepoint support, and sandbox compatibility.
- Structured constraint errors (`%XqliteEcto3.Error{}`) mapping SQLite's
  13 constraint subtypes to Ecto changeset errors without string parsing.
- Streaming cursor protocol (`handle_declare` / `handle_fetch` /
  `handle_deallocate`) for `Repo.stream/2`.
- Custom Ecto types: `XqliteEcto3.Types.UUID`,
  `XqliteEcto3.Types.TimestampTZ`, `XqliteEcto3.Types.Instant`,
  `XqliteEcto3.Types.Duration`, `XqliteEcto3.Types.Array`.
- Global config knob `:xqlite_ecto3, :binary_id_storage, :string | :binary`
  for UUIDs stored via `field :id, :binary_id`.
- Opt-in migration helpers:
  - `XqliteEcto3.Migration.enum_check/3` — CHECK constraint from an
    `Ecto.Enum` declaration.
  - `XqliteEcto3.Migration.array_check/2` — `json_type(col) = 'array'` CHECK.
- Opt-in migration feature (behind repo config
  `support_alter_via_table_rebuild: true`): `MODIFY COLUMN` via the full
  SQLite table-rebuild dance, batching all changes in one `alter`
  block into a single rebuild.
- `DELETE` with `JOIN` support via conservative rewrite to
  `DELETE FROM t WHERE pk IN (SELECT t0.pk FROM t AS t0 ... JOINs ... WHERE ...)`.
  Raises a structured `Ecto.QueryError` on query shapes it cannot safely
  transform — zero ambiguity.
- `ALTER TABLE ... ADD COLUMN IF NOT EXISTS` and
  `DROP COLUMN IF EXISTS` via PRAGMA-based pre-check (SQLite grammar has
  no such syntax).
- Shared Ecto suite integration: 15/18 files loaded, ~588 tests passing,
  documented exclusions in `test/test_helper.exs` for every permanent
  SQLite limit and every tracked adapter gap.

[Unreleased]: https://github.com/dimitarvp/xqlite_ecto3/compare/v0.1.0...HEAD
[0.1.0]: https://github.com/dimitarvp/xqlite_ecto3/releases/tag/v0.1.0
