# Changelog

All notable changes to this project will be documented in this file.

The format is based on [Keep a Changelog](https://keepachangelog.com/en/1.1.0/),
and this project adheres to [Semantic Versioning](https://semver.org/spec/v2.0.0.html).

## [Unreleased]

<!-- types cycle: fold into the lists below at release time -->

### Changed

- **Breaking, pre-1.0: `XqliteEcto3.Types.Instant` loads the integer
  nanosecond count, not a `%DateTime{}`.** The old read rounded the
  stored count down to a whole microsecond, so a value the repo had just
  returned raised `Ecto.ChangeError` on re-insert, raised `ArgumentError`
  inside an embedded schema, and matched no rows when pinned in a `where`
  clause. The field now hands back exactly what it stored. The new
  `Instant.to_datetime/1` is the conversion for display: an integer
  becomes a `%DateTime{}` rounded down to a whole microsecond, `nil`
  passes through, anything else is `:error`. Two consequences worth
  knowing: assigning a `%DateTime{}` through a changeset or pinning one
  in a query still rounds down to the whole microsecond, so a row with
  sub-microsecond digits cannot be reached that way; and an unchanged
  instant no longer registers as a change in a changeset, where before
  every UPDATE carried the column. A pinned value near the int64 edges
  also used to be rejected by the driver with
  `{:cannot_convert_to_sqlite_value, _}`, because the rounded-down
  microsecond fell below int64 — that is gone with the integer read.

- **Breaking, pre-1.0: a datetime year outside -9999 to 9999 is
  refused.** The stored text carries a four-digit year while
  `to_iso8601/1` writes a wider one unpadded, and no loader can parse it
  back — one such row made every later read of the table raise. A `Date`,
  `NaiveDateTime` or `DateTime` outside the range is now refused at the
  binding boundary with `XqliteEcto3.UnencodableParameterError`
  (`reason: :year_out_of_range`) and nothing is written, on the
  parameter path, inside an embedded schema, and from
  `XqliteEcto3.Types.TimestampTZ.dump/1` (which answers `:error`, so
  Ecto raises `Ecto.ChangeError`). Both tails are reachable from
  ordinary arithmetic: `DateTime.add(now, 3_000_000, :day)` and
  `Date.add(~D[2026-09-17], -5_000_000)`. A row already written that way
  can no longer be bound, so removing it means binding the stored text
  yourself: `DELETE FROM t WHERE at = ?` with
  `"10000-06-07 01:02:03"`.

- **`XqliteEcto3.Types.ExactDecimal` refuses a written-out form past
  6178 digit characters.** `"1E+8000000"` is ten characters that wrote
  eight million bytes, because the stored form has no exponent and
  nothing between the cast and the dump looked at it. The ceiling is
  `Decimal`'s own default print limit, so every value a plain `:decimal`
  field accepts is still accepted here, and the width is computed from
  the coefficient's digit count and the exponent without rendering
  anything. `cast/1` and `dump/1` both answer `:error`; `load/1` has no
  ceiling, so a wider row already in a column still reads and only
  writing it back is refused.

- **Documented: `:binary_id` treats sixteen raw bytes as a UUID.**
  Sixteen bytes going in are written as the dashed lower-case text under
  either storage mode; coming out they are expanded only under `:binary`
  and handed back as raw bytes under `:string`. The moduledoc, the
  README, the migration guide and `XqliteEcto3.Types.UUID`'s moduledoc
  all previously said such a value passed through untouched. Behaviour
  is unchanged — opaque sixteen-byte identifiers belong in a `:binary`
  field.

- **Breaking, pre-1.0: under `:binary` storage an `Ecto.UUID` field is
  stored as a 16-byte BLOB, not as the 36-character text.** The
  `:binary_id_storage` setting now governs every UUID kind —
  `:binary_id`, `Ecto.UUID` and `XqliteEcto3.Types.UUID` — so one
  database holds one form. Rows written before this still load; a lookup
  by id binds the new form and does not find them, so convert an
  existing column once with the two statements in the README's custom
  types section. Under `:string` nothing changed, byte for byte.

- **The xqlite dependency is pinned at `~> 0.16.0`.** Its
  `%Xqlite.Blob{}` parameter, there since 0.12.2, is what makes a UUID
  reach SQLite as a BLOB whatever its bytes are. The entries that follow,
  through the batch-size entry, are what xqlite 0.13 to 0.16 change for a
  user of this adapter.

- **A call that meets another connection's lock waits for it in the
  calling process, and gives up with `type: :database_busy`.** xqlite
  0.16 answers a lock at once and leaves the waiting to its caller, so
  the adapter waits as `busy_timeout` says: a statement, a stream
  fetch, a transaction start, a commit, a savepoint release, a prepare,
  a stream's open and every PRAGMA the connect writes; a statement's or
  a fetch's `:timeout` ends its wait too. The error that comes back once
  the wait gives up is `%XqliteEcto3.Error{type: :database_busy}` with
  SQLite's message and xqlite's map in `details` (`code`, `retry`,
  `retries`, `elapsed_ms`), where it was `:database_busy_or_locked` with
  the extended code alone. `retry: :transaction` comes back at once: the
  transaction had already read, and another connection held the write
  lock or, in WAL mode, had committed since that read; roll it back and
  run it again. A table lock of the connection itself, such as a
  `DROP TABLE` while a stream still reads the table, answers
  `type: :database_locked` and is never waited for.

- **`mix ecto.load` waits for another connection's lock.**
  `structure_load/2` runs the dump through `Xqlite.execute_batch/3`,
  which waits as the busy timeout of the connection it opens says (5 s)
  and goes on from the statement that met the lock, where the raw batch
  answered busy at once.

- **A raw `PRAGMA busy_timeout = N` sets the wait, observers or not.**
  xqlite holds the connection's busy slot from the open on, so neither a
  busy observer nor a retry policy changes whether a call waits. Through
  `Repo.query/3`, or on the handle inside `XqliteEcto3.with_xqlite/3`,
  the write sets the wait as `Xqlite.put_busy_timeout/2` does and keeps
  every observer, where it used to replace xqlite's busy callback and
  silence them. `PRAGMA busy_timeout` read through SQL answers 0 on
  every connection; `Xqlite.get_busy_timeout/1` reads the wait. An
  authorizer denying `PRAGMA` no longer costs the connection its wait
  when an observer registers. `Xqlite.busy_timeout/2` is
  `Xqlite.put_busy_timeout/2` and keeps an installed retry policy. A raw
  `XqliteNIF` call on the handle answers busy at once: call the `Xqlite`
  function, or wrap the raw call in `Xqlite.retry_busy/3`.

- **SQL holding no statement answers `type: :no_statement`**, where it
  was `:cannot_execute`: whitespace or a comment alone through
  `Repo.query/3`.

- **`XqliteEcto3.connection_stats/1` reports `deferred_fks?`, a
  boolean**, where it reported `deferred_fks`, an integer. The lookaside
  hit and miss counters report SQLite's running totals (they read 0
  before), and every counter is read as 64 bits.

- **`XqliteEcto3.txn_state/2` answers `{:error, {:no_such_schema,
  name}}` for a schema that is not attached**, and `{:error,
  {:invalid_schema_name, ""}}` for `""`. `nil` no longer means every
  attached database: it raises `ArgumentError`, and `:all` means every
  attached database.

- **A parameter SQLite cannot take is named by its kind.** A bitstring
  that is no whole number of bytes is `type: :unsupported_data_type` and
  an integer past 64 bits is `type: :integer_out_of_range`, where both
  were `:cannot_convert_to_sqlite_value`. A TEXT or BLOB value longer
  than the connection's length limit is `type: :value_too_large`,
  answered before anything is bound; a value SQLite finds too big while
  it steps (a row, a concatenation, a column read) is `type: :too_big`
  with SQLite's message and `details: %{extended_code: 18}`, where it was
  `:sqlite_failure` with code 18. SQL or a database path whose bytes are
  not UTF-8 is `type: :invalid_utf8_in_string`, where it raised
  `ArgumentError`.

- **A keyword parameter list names every parameter exactly once.**
  Through `Repo.query/3`, a list that leaves a parameter out answers
  `type: :missing_parameter` instead of binding NULL to it, a key given
  twice answers `type: :duplicate_parameter_name` with
  `details: %{token: name}`, a list for a statement of more than 2 048
  parameters answers `type: :too_many_named_parameters`, and a key
  written with its `@` or `$` prefix binds that parameter.

- **An element of a keyword parameter list that is not an `{atom,
  value}` pair no longer puts your value into the error message.** The
  `type` stays `:expected_keyword_tuple`; the error carries the
  element's position and kind instead.

- **An error whose payload is a map carries that map in `details`.**
  `:missing_parameter`, `:value_too_large`, `:integer_out_of_range`,
  `:too_many_named_parameters` and every other xqlite reason that sends
  a map put it in `details`, where it was readable only inside the
  message.

- **A parameter list of the wrong length answers
  `type: :invalid_parameter_count` on every path**, a stream and
  `XqliteEcto3.explain_analyze/3` included, before anything is bound;
  `provided` is the list's own length.

- **A `custom_pragmas` value no statement can carry fails the
  connect** under xqlite's reason for its kind: `:unsupported_data_type`,
  `:invalid_utf8_in_string`, `:null_byte_in_string` or
  `:integer_out_of_range`. A NUL byte used to cut the value short
  silently, and a partial bitstring, bytes that are no UTF-8 and an
  integer past 64 bits answered `:cannot_convert_to_sqlite_value`. A
  `busy_timeout` that is not an integer from 0 to 2_147_483_647 answers
  `:invalid_pragma_value` and keeps the wait in force, where SQLite read
  a negative number, `:infinity`, a boolean or text that is no number as
  no wait at all, and a number past 2_147_483_647 as 0. An atom value
  goes into the PRAGMA as quoted text, which SQLite reads as it read the
  bare atom, so it can no longer end the PRAGMA and add a statement; one
  holding a NUL byte answers `:null_byte_in_string`, where the value was
  cut at the NUL.

- **A query `:timeout` answers only for work it stopped.** One that fires
  before the statement's first step stops it before it runs, where a
  one-row write used to commit and still answer the timeout, and one
  that fires after the last step no longer turns a finished write into a
  timeout.

- **`mix ecto.create` and `mix ecto.load` report a failed close** of the
  connection they open, where the result of the close was discarded.

- **A commit with no transaction open answers `type: :no_transaction`**,
  where it answered `type: :sqlite_failure` with SQLite's code 1: a
  `Repo.transaction/2` whose function ended the transaction with a raw
  `COMMIT` or `ROLLBACK` raises `%XqliteEcto3.Error{type:
  :no_transaction}` at its own commit, and the connection is dropped as
  before.

- **A string holding a second statement changes nothing.** Through
  `Repo.query/3` or a migration's `execute/1`, text after the first
  statement that holds anything but whitespace, comments and semicolons
  answers `type: :multiple_statements` before anything runs, where text
  that did not compile answered its own compile error. A PRAGMA in such
  a string no longer takes effect while SQLite compiles it:
  `"PRAGMA foreign_keys = OFF; SELECT 1"` failed and still turned
  foreign-key enforcement off on that pooled connection.

- **A result column whose stored name is not UTF-8 is an error.** It
  answers `type: :column_name_not_utf8` with `details: %{column: index,
  name: bytes}`, where a cached statement and a stream read the name
  with U+FFFD in place of each bad byte, so two names could read alike,
  and a statement with the cache off left the connection unusable. With
  the cache off (`statement_cache_size: 0`), or on a statement's first
  run, the error comes before anything runs. A cached statement meets the
  check only after it has run: once another connection changes its table
  so that a column's name is not UTF-8, a cached `INSERT ... RETURNING *`
  writes its row, committed outside a transaction, and then answers the
  error, and each retry writes again. A CTE column list renames such a
  column:
  `WITH s(a) AS (SELECT * FROM t) SELECT a FROM s`. A stream whose table
  another connection changes between its open and its first fetch
  answers `type: :columns_changed`, where its rows came back under the
  old column names.

- **The `hooks:` update and WAL listeners hear every database and
  table.** A write to a table whose stored name is not UTF-8, or to a
  database attached under such a name, sent the update listener no
  message, and the WAL listener got `""` for such a database. Both now
  arrive with the names as the bytes SQLite stores, which need not be
  UTF-8.

- **`Xqlite.enable_load_extension(conn, false)`, which the
  `XqliteEcto3.with_xqlite/3` docs advise before a callback returns, is
  `Xqlite.disable_load_extension(conn)`**, and turning loading on is
  `Xqlite.enable_load_extension(conn)`.

- **A batch size SQLite refuses reports what was refused.**
  `Repo.stream/2` with a `:max_rows` that is not a positive integer
  raises `%XqliteEcto3.Error{type: :invalid_batch_size}` with
  `details: %{provided: value, minimum: 1}`, the value exactly as it was
  given. The whole payload used to be legible only inside the message
  text.

### Fixed

- **Four connect options are bounded where SQLite stops keeping the
  value.** `cache_size` outside the 32-bit range and `wal_autocheckpoint`
  above 2_147_483_647 were stored by SQLite as 0, and `mmap_size` above
  2_147_418_112 as that ceiling; each is now a connect error naming its
  key (`:invalid_cache_size`, `:invalid_wal_autocheckpoint`,
  `:invalid_mmap_size`), and the URL parser answers `:out_of_range` for
  the same values. A progress hook `every_n` above 4_294_967_295 raised
  inside the connect and is now `:invalid_hook_option`.

- **A `custom_pragmas` name no PRAGMA can have fails the connect with a
  message in text.** `type: :invalid_pragma_name` carries the name as
  text in `details: %{token: name}`: an atom's text (`:"foo-bar"` comes
  back as `"foo-bar"`), `""` for `nil`, a binary's bytes as they are. The
  message was the name itself, empty for `nil` and raw bytes for a name
  that is no UTF-8.

- **A connect that fails once the database is open closes it.** A
  `custom_pragmas` or `hooks` entry the connect rejects left the
  connection open until a garbage collection, and with it the database
  file and its WAL.

- **A `database` that is not a binary and an improper `hooks` list are
  connect errors naming their key.** `database: nil`, a missing
  `database` and `database: :memory` answer `type: :invalid_database`
  with `details: %{key: :database, value: value}`, and a `hooks` list
  such as `[{:update, MyListener} | :tail]` answers
  `:invalid_hooks_config` with the list as given, both before the
  database is opened. Both used to raise inside the connect, the `hooks`
  list after the open, which left the database open until a garbage
  collection; the pool restarted the crashed connection three times, its
  default limit, then went down, its log naming only the exception's
  module.

- **A column of UUIDs under `:binary` storage no longer holds two
  storage classes.** A plain binary parameter is stored as TEXT when its
  bytes happen to be valid UTF-8 and as a BLOB otherwise, and about one
  UUID in fourteen thousand is valid UTF-8 — so a few rows per million
  landed as TEXT in a BLOB column. TEXT and BLOB sort apart and never
  compare equal, so a UNIQUE column accepted the same UUID twice and a
  lookup by that id found nothing. Every UUID kind now binds a value
  SQLite stores as a BLOB whatever the bytes are.

- **An `Ecto.UUID` column under `:binary` storage is no longer filled
  with TEXT.** The `Ecto.UUID` dumper did not read the storage setting,
  so the column was declared BLOB and written as the 36-character text,
  and a join between an `Ecto.UUID` column and a `:binary_id` column
  returned nothing.

- **A UUID inside an embedded schema no longer raises under `:binary`
  storage.** An `embeds_one` or `embeds_many` field declared
  `:binary_id` under `:binary` storage, or
  `XqliteEcto3.Types.UUID, storage: :binary` under either setting,
  raised `XqliteEcto3.UnencodableParameterError` on every write, because
  the embed is JSON and raw UUID bytes are not JSON. Sixteen raw bytes
  that JSON cannot carry are now written into the embed as the dashed
  text, the same form the column path stores.

- **`XqliteEcto3.Types.UUID` with `storage: :binary` loads a
  36-character text row.** It answered `:error` where both `Ecto.UUID`
  and `:binary_id` accept either stored form, so a column written before
  the storage mode was flipped, or by another tool, could not be read.

- **`XqliteEcto3.UnencodableParameterError` tells its three causes
  apart.** Its message named a JSON encoding failure whatever the
  `:reason` field held, including for the `DateTime.shift_zone/2`
  refusal its own moduledoc documents.

<!-- end types cycle -->


### Added

- **`XqliteEcto3.binary_id_storage/0`.** The one reader for `config
  :xqlite_ecto3, :binary_id_storage`, now public: the `:binary_id`
  dumper, the loader, the migration column type and the
  query-parameter `CAST` all go through it, so they can never disagree
  about what the setting says.

- **`diagnostics_budget_ms` repo option (default 500).** One
  wall-clock allowance, in milliseconds, for each of the two
  error-path diagnoses: the unique-index-name lookup and the
  foreign-key replay. Both read the database back on a statement that
  already failed while the caller waits, so the allowance is checked
  before every read and the diagnosis stops as soon as it is spent —
  degrading to what the adapter knew without it, never masking the
  original error. `0` turns both diagnoses off. Anything but a
  non-negative integer is a structured connect error
  (`:invalid_diagnostics_budget_ms`).

- **`[:xqlite_ecto3, :unique_index_names]` telemetry span.** The
  unique-index-name lookup is timed on its own instead of adding
  invisible time to `handle_execute`. `:start` carries `conn`, `table`
  and `columns`; `:stop` adds `candidate_count`, `index_reads` and
  `lookup_status`. It does not fire when `diagnostics_budget_ms` is
  `0`, nor when the failed statement's deadline is already inside the
  reserve the lookup leaves.

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

- **`XqliteEcto3.DecimalPrecisionError` says which of five things is
  wrong.** Its new `:reason` field is `:precision`,
  `:above_float64_range`, `:below_float64_range`, `:nan` or
  `:infinity`, with one message per reason, so a caller branches on a
  field instead of reading English. The `XqliteEcto3.Types.ExactDecimal`
  remedy is now printed only for the three reasons that type accepts:
  it refuses NaN and Infinity too.

- **A `:max_rows` that is not a positive integer is refused, not
  replaced.** `Repo.stream/2` passed every value it disliked — zero,
  a negative, a string, a float, an atom — to the default 500, so a
  mistyped option silently produced a batch size nobody asked for.
  Every value now reaches the library, which refuses it with
  `%XqliteEcto3.Error{type: :invalid_batch_size}` on the first batch.
  An absent `:max_rows` is still 500.

- **`config :xqlite_ecto3, :binary_id_storage` is validated.** Anything
  but `:string` or `:binary` used to surface as a `CaseClauseError`
  from inside the adapter at migration time, at insert time, at read
  time or while building SQL. It now raises `ArgumentError` naming the
  setting, the value and the two allowed values — at repo boot as well.

- **Three refused-parameter errors carry what they refused.**
  `%XqliteEcto3.Error{}` with `type: :invalid_parameter_count` now
  carries `details: %{expected: n, provided: m}`, and `:unsupported_atom`
  and `:invalid_parameter_name` carry `details: %{token: token}` with a
  message naming what was wrong with the token — the whole message used
  to be the bare token itself.

- **The xqlite dependency moves to `~> 0.12.0`.** The bundled SQLite
  is unchanged at 3.53.2. Three of that release's changes are visible
  through the adapter and are described in the three entries below;
  nothing else in it has an adapter consumer.

- **An error that names a table or an index carries the name.**
  `%XqliteEcto3.Error{}` with `type: :no_such_table`, `:no_such_index`,
  `:table_exists` or `:index_exists` now has `details: %{name: name}`
  where it had `nil`, so the name can be read without taking the
  message apart. The message itself is unchanged — `no such table:
  users`, `table users already exists` — and the name inside it is what
  SQLite rendered, qualified (`main.users`) or quoted (`"a b"`) exactly
  as the failing statement wrote it.

- **A rowid conflict now reports a unique constraint.** Inserting a
  duplicate `rowid` used to give `Ecto` an empty constraint list, so a
  changeset could not match it. It now reports the unique constraint of
  the `rowid` column under Ecto's default index name —
  `[unique: "<table>_rowid_index"]` — which
  `Ecto.Changeset.unique_constraint(:rowid)` matches. A changeset that
  relied on the empty list to fall through to a generic error will now
  find that constraint instead.

- **A `Decimal` inside JSON goes through the precision guard.** A
  `%Decimal{}` in a `:map` field or an `{:array, :decimal}` field used
  to reach Jason untouched, which prints one as a quoted string: a
  value the guard refuses at the top level was stored anyway, and a
  `:map` field read it back as a `String`. Such a value is now written
  as the number it binds as — so `{:array, :decimal}` loads each
  element back as a `Decimal`, and a plain `:map` field, which has no
  per-value type to load through, gives integers and floats. A decimal
  with no exact int64 or float64 form raises the same
  `XqliteEcto3.DecimalPrecisionError` wherever it sits. One knock-on:
  a `%Decimal{}` too wide for `Decimal`'s own print limit used to
  surface as `XqliteEcto3.UnencodableParameterError` from inside the
  JSON encoder and now refuses earlier, as a precision error.
  `XqliteEcto3.Types.Array` and `XqliteEcto3.Types.ExactDecimal` build
  their own JSON and text and stay outside this guard on purpose.

- **A wide `Decimal` binds in milliseconds instead of seconds.** The
  guard compared a value against its float64 round-trip through
  `Decimal.normalize/1`, which strips trailing zeros sixteen at a time
  — a coefficient carrying 100_000 of them cost about 350 ms to bind
  and 500_000 about nine seconds. The trailing zeros now go in one
  division before anything else reads the coefficient, and a
  coefficient still wider than 19 significant digits after that is
  refused outright: no float64 reads back with more, so no such value
  could ever have been exact. Values that were accepted before are
  accepted still, and bind about seventy times faster at 100_000
  zeros. The one behaviour change is at the edge `Decimal`'s own
  28-digit arithmetic context used to hide: a value like
  `10.000…0007` written with more than 19 significant digits was
  accepted and stored as `10.0`, and is now refused rather than
  silently rounded.

- **A `:decimal` field reads a float back through the same model the
  guard measured.** The loader used `Decimal.from_float/1`, the
  shortest printing that round-trips, where the binding guard checks
  against the digits SQLite actually stores. The two differ for an
  integral float past 2^53, so a value the guard accepted could load
  back changed. Both ends now use the storage model.

- **The `:microsecond_precision` exclusion covers four upstream tests
  instead of five.** The tag also covered `interval.exs:194`, which
  passes, so that test now runs; the four `datetime_add` tests that
  cannot pass — SQLite's `strftime %f` is millisecond-precision — are
  excluded one at a time by location. The vendored-suite anchor moves
  from 440 passed / 26 excluded to 441 passed / 25 excluded.

- **Adding a column with a `{:fragment, "..."}` default is refused.**
  SQLite computes an added column's default once for every row already
  in the table and takes only a literal there, so the same `alter
  table ... add` succeeded against an empty database and failed against
  a populated one. The adapter now refuses every `add` (and
  `add_if_not_exists`) whose `default:` is a raw SQL fragment, before
  the statement runs, with `XqliteEcto3.RebuildRefusedError` and reason
  `:non_constant_default_add`. Which fragments SQLite would have
  accepted is decided by its own parser, which the adapter does not
  run, so the whole shape goes. Plain defaults are unaffected, and a
  fragment default still works when the same alter block carries a
  `:modify` under `support_alter_via_table_rebuild: true` — that path
  rewrites the table and evaluates the fragment for every row.

- **Span measurements are nanoseconds on every machine.** The adapter's
  spans used to come from `:telemetry.span/3`, which reads the clock
  with no unit and therefore reports the runtime's native unit — a
  nanosecond on Linux, something else elsewhere, with nothing in the
  event to say which. They now run through
  `XqliteEcto3.Telemetry.run_span/3`, which reads
  `System.monotonic_time(:nanosecond)` and
  `System.system_time(:nanosecond)`, matching xqlite's own spans and the
  adapter's non-span events. The events are otherwise identical: same
  names, same `telemetry_span_context` reference pairing `:start` with
  its closing event, same `:exception` event with `kind`, `reason` and
  `stacktrace`, same two block shapes.

- **`dump_cmd/3` returns instead of raising.** `Ecto.Adapter.Structure`
  types it as `{output, exit_status}`, so the unsupported command now
  reports itself the way a shell reports a command it cannot find: the
  explanation as the output and `127` as the status. Use
  `structure_dump/2`, which writes the dump itself.

- **A rebuilt table keeps a typeless column typeless.** A column stored
  with no declared type at all was re-declared as `BLOB` by the rebuild,
  and the post-rebuild check made the same substitution, so it could not
  see the change. Both sides now carry the empty declared type through,
  and any drift in a declared type is reported.

- **A unique violation SQLite reports as `index 'name'` now carries a
  table and columns.** That form — the one an index built over an
  expression produces — used to leave `table: nil` and `columns: []`
  on the error, and the name lookup skipped it entirely
  (`unique_index_lookup: :not_run`). It now reads the index's table
  from `sqlite_schema` and its columns from `PRAGMA index_info`, so
  both fields are filled; the columns are `nil`, because an indexed
  expression has no column name. The emitted constraint name is
  unchanged: it is still the name SQLite reported.

- **A table carrying an expression unique index reports the ambiguity
  instead of naming one index.** An expression index matches no column
  list, so nothing can rule it in or out, and which of the two message
  forms a violation takes depends on the order the indexes were
  created in rather than on the schema. When such an index sits beside
  another unique index on the violated table, the lookup now records
  every candidate and reports `unique_index_lookup: {:ambiguous,
  names}`; the constraint mapping emits the name SQLite named, or the
  conventional derived one, and never picks a candidate. A changeset
  on such a table needs one `unique_constraint/3` per name it wants
  converted.

- **The unique-index lookup refuses a violation message that a name
  garbled.** SQLite quotes nothing in `UNIQUE constraint failed:
  <table>.<column>`, so a table or column name holding a `.` or a `, `
  splits somewhere else, and the pieces could name a real, unrelated
  table whose index the lookup would then report as the violated one.
  The lookup now counts the separators the parsed table and columns
  account for, and reads nothing when the count does not match or when
  the parsed table exists in no schema: `{:unavailable,
  {:unparseable_violation_table, message}}`, with the conventional
  derived name emitted. This also degrades a parse that happened to be
  right, such as a column name holding a `.`.

- **The unique-index lookup qualifies its pragmas with the violated
  table's schema.** `PRAGMA index_list` ran unqualified, so an
  attached database or the temp schema holding a table of the same
  name could answer with the wrong table's indexes. One
  `pragma_table_list` read now says which schema holds it; two rows
  degrade to `{:unavailable, {:ambiguous_schema, schemas}}`.

- **The failed statement's own timeout caps both error-path
  diagnoses.** They read the database back on the connection the
  caller is still waiting on, and nothing cancels a read once it
  blocks on another connection's write lock. The unique-index-name
  lookup now spends the smaller of `diagnostics_budget_ms` and what
  the deadline leaves once a 20 ms reserve is set aside, and reports
  `{:unavailable, {:deadline_near, remaining_ms}}` only when the
  deadline is already inside that reserve — so a `:timeout` under
  500 ms no longer costs a changeset the real index name, and a
  declared `unique_constraint(:field, name: ...)` keeps converting.
  The foreign-key replay follows the same rule (see the entry below on
  what bounds its reads). A statement with no timeout is never skipped,
  and an allowance of `0` is still off.

- **A rollback with no transaction left answers the transaction
  status.** Raw `COMMIT`, `END` or `ROLLBACK` in your own SQL ends the
  transaction underneath the driver. The following rollback used to
  issue a `ROLLBACK` SQLite refuses and report "cannot rollback - no
  transaction is active"; it now answers DBConnection's
  `{:idle, state}` instead, read live from SQLite rather than from the
  driver's cached flag. `Ecto.Adapters.SQL.Sandbox` turns that into its
  own "the sandbox transaction was already committed/rolled back"
  diagnostic, and DBConnection into a `DBConnection.TransactionError`
  carrying the status. The connection is dropped either way, and rows a
  raw `COMMIT` already committed stay committed — what changes is that
  the log names the cause. `handle_commit/2` is unchanged.

- **`error_reason` has a documented third shape.** A callback that
  refuses because of the connection's transaction status reports
  `error_reason: {:transaction_status, status}` on its `:stop` event —
  `:transaction` from `handle_begin`, `:idle` from `handle_rollback`.
  The shape was already emitted; the moduledoc, the telemetry guide and
  the architecture map said there were two shapes, and a handler
  written to that contract raised and was detached from the whole VM.
  `Telemetry.OpenTelemetry` now maps the tuple to one name per status —
  `"transaction_already_started"` and `"transaction_not_started"` —
  where it reported the tag `"transaction_status"` for every status.
  A callback answer no clause anticipates reports
  `{:unclassified, answer}` instead of raising inside the span.

- **The unique-index-name span reports what it found on both message
  forms.** `lookup_status: :ambiguous` is now documented beside `:ok`
  and `:unavailable` (it was always emitted), the span's `:stop` on the
  form where SQLite names the index carries the table and columns the
  lookup read back instead of the `nil` and `[]` the message came with,
  and `index_reads` counts the `pragma_table_list` read that starts the
  lookup — one more than it reported before.

- **The foreign-key replay subtracts its baseline by group count.** It
  compared the two `PRAGMA foreign_key_check` scans row by row, which
  cannot see a new violation in a `WITHOUT ROWID` child table: every
  violation there reports a `nil` rowid, so the new row is
  byte-identical to a pre-existing one and the diagnosis degraded to
  `{:unavailable, :masked_by_baseline}`. The scans are now compared by
  counting violations per `{child table, fk id}`, which recovers that
  case exactly. A rowid reused after its orphan was replaced still
  reports `:masked_by_baseline`, since no group grew.

- **`[:xqlite_ecto3, :unique_index_names]` counts the `index_list`
  read.** `index_reads` on the `:stop` event reported only the
  `index_info` reads; it now reports 1 + one per unique index on the
  table, and `lookup_status` gained `:ambiguous`.

- **A connect error now names the repo option it refused.** Every
  validator that rejects a repo configuration value carries the key and
  the value together, and `XqliteEcto3.Error.wrap/1` puts them in
  `details` as `%{key: key, value: value}`. Before, `details` was `nil`
  and the message was `inspect` of the internal reason tuple — or, when
  the value happened to be a string, only the value: a
  `journal_mode: "wal"` typo failed the connect with the message `wal`,
  naming neither the setting nor what was wrong with it. It now reads
  `config journal_mode rejected: "wal"`, and the same structured error
  reaches the `[:xqlite_ecto3, :connect, :stop]` telemetry event as
  `error_reason`. The `:type` atom of each refusal is unchanged, so
  code matching on it keeps working. Affected settings: `mode`,
  `default_transaction_mode`, `statement_cache_size`, `busy_timeout`,
  `journal_mode`, `synchronous`, `temp_store`, `foreign_keys`,
  `cache_size`, `auto_vacuum`, `wal_autocheckpoint`, `mmap_size`,
  `rich_fk_diagnostics`, `diagnostics_budget_ms`, `custom_pragmas` and
  `hooks` (a refused progress option names that option as the key).

- **The table rebuild raises `XqliteEcto3.RebuildRefusedError` instead
  of `ArgumentError`.** Every pre-flight refusal, and the foreign-key
  check after the copy, used to be an `ArgumentError` (or, in one case,
  a `RuntimeError`) whose only content was its message, so telling one
  refusal from another meant matching prose. The new exception carries
  `reason` (an atom per check), `table`, `construct`, `column`,
  `violations`, `details` and the same full `message` as before. The
  `reason` values are `:rebuild_not_enabled`, `:table_not_found`,
  `:virtual_table`, `:shadow_table`, `:unpreservable_construct`,
  `:dependents_exist`, `:incoming_action_on_populated`,
  `:reference_change`, `:primary_key_removed`, `:key_already_granted`,
  `:affinity_rewrite`, `:trigger_reads_removed_column`,
  `:stranded_constraint`, `:unknown_column`,
  `:trigger_sql_unrecognized` and `:foreign_key_violations`. Code that
  rescued `ArgumentError` around a migration has to rescue
  `XqliteEcto3.RebuildRefusedError` now.

- **`handle_begin/2` reports an open transaction instead of
  disconnecting.** Asked for a top-level `BEGIN` while a transaction is
  already open on the connection, the driver returns DBConnection's
  `{:transaction, state}` status form. Before, it ran the `BEGIN`
  anyway and disconnected on SQLite's "cannot start a transaction
  within a transaction". `Ecto.Adapters.SQL.Sandbox` turns the status
  form into its "a connection was not appropriately rolled back after
  use" message; on the disconnect it silently threw the connection away
  and opened a new one, so the mistake that caused it stayed invisible.
  The savepoint path and `handle_commit/2` / `handle_rollback/2` are
  unchanged.

- **A pooled private in-memory database is refused when the repo
  starts.** `database: ":memory:"`, the empty string, and any `file:`
  URI that opens an in-memory database without `cache=shared` — the
  path `:memory:`, or `mode=memory`, which names one — give every
  pooled connection its own empty database, so writes land on one
  connection and reads scatter over the others. With a `pool_size` above 1 that
  configuration now raises `ArgumentError` from
  `XqliteEcto3.Connection.child_spec/1`, naming the two ways out:
  `pool_size: 1`, or the shared-cache URI `file::memory:?cache=shared`,
  which every connection in the pool opens as the same database. This
  is the adapter's own choice and stricter than ecto_sqlite3, which
  raises from `storage_up/1` (the `mix ecto.create` path) and never on
  `Repo.start_link/1`.

- **The adapter's `pool_size: 5` default is gone.** It never applied:
  Ecto merges its own default of 10 into the repo configuration before
  the adapter's defaults are consulted, so every repo that set nothing
  already got 10. The docs say so now instead of repeating a number
  that was never in force.

- **The unique-index-name lookup no longer takes its allowance from
  `PRAGMA busy_timeout`.** That read could not tell a deliberate
  `busy_timeout: 0` from a busy policy or observer holding the
  connection's busy slot, and fell back to a fixed 500 ms for all
  three. The allowance is `diagnostics_budget_ms`, read at connect and
  carried on the connection, and the pragma read is gone: the lookup
  costs 1 + N reads (one `index_list`, one `index_info` per unique
  index) rather than 2 + N. The foreign-key replay, which had no time
  bound at all, takes the same allowance.

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

- **A `:decimal` value at int64's lower limit loads as SQLite stores
  it.** SQLite turns a whole-number REAL into an INTEGER only for
  values strictly inside int64's range, and `-9223372036854775808` sits
  exactly on the lower limit, so it stays a REAL. The loader predicted
  an INTEGER for it and handed back digits the column never held.

- **A transaction a `with_xqlite/3` callback left open on its way out of
  a raise no longer confuses the pool.** The callback holds the raw
  SQLite connection, so a `BEGIN` it runs never passes the adapter's
  statement path — the one place that noticed transaction control and
  re-read SQLite's real state. A callback that returns normally with a
  transaction open is caught by `DBConnection`'s own comparison of the
  status at checkout and at check-in, but one that raises is not: the
  connection went back into the pool with the transaction open and the
  driver still believing none was, and the next `Repo.transaction/2` on
  it issued a `BEGIN` SQLite refused, raising a generic
  `XqliteEcto3.Error`. The status is now re-read on both ways out of the
  callback, so that transaction comes back `{:error, :rollback}` —
  `DBConnection`'s answer for a transaction already started — and drops
  the connection, which rolls the forgotten transaction back.

- **A short `:timeout` no longer costs a foreign-key changeset error.**
  The rich foreign-key diagnosis used to be skipped whole whenever the
  failed statement's deadline left less than the whole
  `diagnostics_budget_ms`, so at `timeout: 400` a declared
  `foreign_key_constraint(:field)` stopped converting and
  `Repo.insert/2` re-raised the raw `%XqliteEcto3.Error{}`. It now
  spends the smaller of the allowance and what the deadline leaves once
  a 20 ms reserve is set aside — the rule the unique-index-name lookup
  already follows — and is skipped only for an allowance of `0` or a
  deadline already inside that reserve. What kept the skip in place was
  the cost of `PRAGMA foreign_key_check`, which scans every table in
  the database; every read of the diagnosis now runs under a cancel
  token fired at the allowance instead, so a scan too slow to finish
  stops mid-scan and reports `{:unavailable, :operation_cancelled}`.
  The replayed statement itself carries no token: it is the caller's
  own write, and SQLite rolls the whole transaction back when it
  interrupts a write. A read waiting for another connection's lock stops
  at the allowance or at `busy_timeout`, whichever comes first; the
  replayed write and the savepoint release after it wait on
  `busy_timeout` alone.

- **A diagnosis that ends the transaction is reported as a
  disconnect.** The error path took its "is this connection's
  transaction still open" verdict before running the two diagnoses and
  never again, so a foreign-key replay whose write SQLite answered by
  rolling back (a full database, for one) left the driver believing a
  transaction was open: the transaction body carried on in autocommit
  and its later writes committed durably inside a transaction that
  reported failure. The verdict is now taken again after the diagnosis,
  and a transaction that was open and is gone drops the connection.

- **A savepoint commit or rollback with no savepoint says so.** Raw
  transaction control in a test body — a `COMMIT`, `END` or `ROLLBACK`
  run through `Repo.query!/2` inside an `Ecto.Adapters.SQL.Sandbox`
  test — ends the savepoints the adapter opened without moving the
  counter it names them from, and the next close then asked SQLite for
  `xqlite_sp_<prefix>_-1`, a savepoint that never existed, reporting a
  generic `type: :sqlite_failure`. Both closing callbacks now read the
  live transaction status first: with no transaction left the close
  raises `type: :savepoint_without_transaction`, and with a transaction
  open and no managed savepoint it raises the new
  `type: :savepoint_counter_underflow`, both carrying the counter in
  `details`. Both still drop the connection, as before. A counter above
  `0` whose savepoints a raw `RELEASE` or `ROLLBACK TO` removed keeps
  `type: :sqlite_failure`: no side-effect-free read tells that case
  apart from a healthy one.

- **`Repo.stream/2` honours `:timeout`.** Each batch the stream fetches
  now runs under the deadline given to `Repo.stream/2`, or under the
  repo's configured `:timeout` when the call gives none, and a batch
  still running when its deadline passes is cancelled on SQLite's
  progress handler — the same signal a whole statement gets. The stream
  then raises `%DBConnection.ConnectionError{reason: :error}`, the error
  the execute path already reports on a deadline. Before this, a slow
  batch ran to completion whatever `:timeout` said. Every batch gets its
  own deadline, so the time earlier batches took never counts against a
  later one, and a `:timeout` on the surrounding `Repo.transaction/2`
  still does not reach the fetches. `timeout: :infinity` fetches without
  a deadline, as it did.

- **The telemetry-disabled build runs the whole test suite.** The CI
  lane that compiles telemetry to no-ops ran one smoke file, and 24
  tests across five files failed in that build without anyone seeing
  it. The tests that assert on emitted events are now compiled out of
  that build, together with the helpers only they use, and the lane
  runs the whole suite. A test whose telemetry assertion is only half
  of it keeps its other half in both builds.

- **A zoned `DateTime` on the raw-SQL path can no longer write a third
  text form.** The shift to UTC carried a fallback that wrote
  offset-carrying ISO 8601, which would have sorted against the
  adapter's own values by the offset digits. No input reaches it — a
  shift to `Etc/UTC` needs no time zone database — so the branch is
  gone and a shift that somehow failed refuses with
  `XqliteEcto3.UnencodableParameterError` instead.

- **Transaction control sent through `Ecto.Adapters.SQL.stream/4` no
  longer strands the driver's cached transaction flag.** A cursor
  prepares its statement when it is declared and runs it on the first
  fetch, and only the ordinary execute path re-read SQLite's real
  transaction state afterwards. A streamed `BEGIN` therefore left the
  driver believing the connection was in autocommit: the next
  `Repo.transaction` issued a real `BEGIN` on a connection already
  inside one, SQLite refused it, the connection was dropped, and every
  write since the streamed `BEGIN` rolled back with it. `handle_fetch`
  now runs the same re-read the execute path runs.

- **`storage_up/1` and `structure_load/2` report their failures instead
  of raising.** An unwritable database directory raised a `File.Error`
  out of `mix ecto.create`, and a database path that cannot be opened
  raised a `MatchError` out of `mix ecto.load`. Both now return
  `{:error, term}` as their callbacks allow:
  `{:cannot_create_directory, directory, posix_reason}` for the first,
  and xqlite's own `{:cannot_open_database, path, code, message}` for
  the second.

- **UUID case is documented for all three paths.**
  `XqliteEcto3.Types.UUID` lower-cases on the way in, `Ecto.UUID`
  stores as written and lower-cases on the way out, and `:binary_id`
  over `:string` storage passes case through untouched in both
  directions. No behaviour changed; the third rule had no
  documentation and no test, and `=` on a TEXT column is
  case-sensitive, so two spellings of one UUID are two values to
  SQLite.

- **A `Decimal` of any width or exponent gets an answer instead of a
  `Decimal` exception.** The precision guard used to write the value
  out as plain digits and read that text back to decide whether it was
  a whole number inside int64. A `Decimal` is three words wide however
  many digits it stands for, so `Decimal.new(1, 1, 7000)`, which is
  1E+7000, asked for a 7001-character string and `Decimal` refused
  with an `ArgumentError`
  — on `Repo.insert`, on a decimal inlined into a query as a literal,
  and inside `DecimalPrecisionError`'s own message, where formatting
  the refusal produced a stack trace instead of the explanation. The
  guard now decides from the struct and never writes the value out, so
  every finite `Decimal` binds as an exact int64, binds as an exact
  float64, or raises `DecimalPrecisionError` carrying the value. A
  zero binds at any exponent (`0E-1000000000` included), a value
  written with a wide coefficient of trailing zeros binds as the small
  number it stands for, and the refusal's message prints the
  coefficient and the exponent — the same text as before for typical
  money, and `1E+3` where a value written with a positive exponent
  used to print `1000`.

- **A `:decimal` field reads back numeric text of any width.** The
  loader parsed stored text with `Decimal`'s defaults, which stop at
  34 significant digits and an exponent of 6144, so a number past
  those limits sitting in a TEXT column — a foreign writer's, or one
  written by hand back when this README suggested it — failed the load
  with Ecto's typed error even though it was a perfectly good number,
  while the `Types.ExactDecimal` field beside it read the same text
  happily. The two now share one parse with both limits lifted, so 35
  nines, 120 digits and `1E+6145` load as the numbers written. Text
  that is not a finite number — `NaN`, `Infinity`, digits with
  trailing junk, the empty string, a BLOB — still fails the load with
  Ecto's typed error naming the field and value.

- **A connection closed under a running operation reports
  DBConnection's own error and leaves the pool.** A NIF call that came
  back `:connection_closed` — a prepare, a bind or a step, and the
  stream path's open and fetch — was wrapped as
  `%XqliteEcto3.Error{type: :connection_closed}` and returned as an
  ordinary statement error, which left a dead connection in the pool.
  A pooled `:timeout` is the common way to get there: DBConnection's
  checkout deadline starts when you call, before you hold a
  connection, so a call that spent its whole budget queueing is
  disconnected as its query begins. That call now returns
  `%DBConnection.ConnectionError{message: "connection closed during
  the operation", reason: :error}` and the connection is dropped, so
  either order of that race wears the same exception, told apart by
  `reason` and never by message text.

- **The disconnect decision now comes before the error enrichment.**
  The unique-index name lookup and the FK replay read the database
  back through the same connection, and they ran before the driver
  decided whether the failed statement had taken the whole transaction
  with it. The driver decides first now. A rolled-back transaction
  leaves a connection that still reads, so its error is enriched
  exactly as before — a `unique_constraint/3` naming a custom index
  still matches a violation that rolled the transaction back. A
  connection whose own transaction status cannot be read is dropped
  without those reads, its error carrying the structured details
  SQLite gave with `unique_index_lookup: :not_run`.

- **An unexpected `PRAGMA foreign_key_list` row no longer raises out
  of the diagnosis.** Rich FK diagnostics group that pragma's rows
  with fixed patterns, and a row carrying fewer columns than the
  grouping reads — an empty row included — raised a
  `FunctionClauseError` through an error path that was already
  handling a constraint violation, so a structured error became an
  exception. Such a row now degrades to `fk_diagnostics:
  {:unavailable, {:unexpected_fk_row, row}}`, the way an unexpected
  `foreign_key_check` row already did. Extra columns and `nil` values
  were harmless before and stay harmless.

- **A decimal that JSON cannot print refuses with structure.** Jason
  renders a `%Decimal{}` in its plain form, which `Decimal` itself
  refuses past its print limit (6178 digits by default), so a map or
  list parameter holding a decimal that large raised a bare
  `ArgumentError` out of the encoder instead of the
  `XqliteEcto3.UnencodableParameterError` that boundary promises. It
  now raises that error, carrying the parameter, its position, and the
  `ArgumentError` as the reason. The digit limit itself is not lifted:
  a 7000-digit JSON number is still refused, only now with structure.

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
  start fail with `type: :database_busy` once `busy_timeout` is
  spent, and the driver disconnected a healthy connection on every
  such failure — one reconnect per contended transaction, worst
  under the multi-writer load the README's retry advice describes.
  That error and a table lock's `type: :database_locked` now return
  like a busy statement does; other begin failures still disconnect.
  The README says that transaction start waits the full
  `busy_timeout` and that `:timeout` does not bound it.

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
  first boots, and SQLite failed the losing switch at once without
  consulting the busy handler, so `busy_timeout` could not help
  (measured up to 120 s). The losing switch now waits for the lock as
  `busy_timeout` says and goes through once the winner is done. A lock
  held past `busy_timeout` still fails the connect with
  `type: :database_busy`. The README section that blamed boot-time
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
  (`"constraint_violation"`, `"database_busy"`, …), as the
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

<!-- refusals and the busy slot: start -->

### Changed

- **`Repo.query_many/3` returns its refusal instead of raising it.**
  The adapter does not implement `query_many`, and it used to say so by
  raising `ArgumentError` — which broke `Repo.query_many/3`'s own
  `{:ok, _} | {:error, _}` contract and left the refusal impossible to
  classify without reading the message. It now comes back as
  `{:error, %XqliteEcto3.Error{type: :query_many_unsupported}}`, so
  `Repo.query_many/3` returns and `Repo.query_many!/3` raises that same
  struct. The type atom is about the callback, not the statement count:
  a one-statement `query_many` is refused with it too, while
  `:multiple_statements` keeps its old meaning ("this SQL held a second
  statement").

- **A query carrying `lock:` is refused with a typed error.** It used
  to raise `ArgumentError` with the message "locks are not supported by
  SQLite", which named the wrong culprit — SQLite never saw the
  statement. It now raises
  `%XqliteEcto3.Error{type: :locks_unsupported, details: %{lock: text}}`
  carrying the lock text the query asked for, and the message says who
  refuses: the adapter does not render row locks.

- **`with_xqlite/3`'s busy-slot warning matches what xqlite 0.12 does.**
  The old text said a busy observer stopped the connection waiting and
  that unregistering never gave the wait back; neither is true at 0.12.
  Registering an observer keeps the wait, unregistering the last one
  restores the timeout the slot displaced, and the one surprise left —
  `PRAGMA busy_timeout` reads 0 through SQL while the slot is held,
  although the connection still waits — is now written down, in the
  README's busy section as well. At 0.12 a raw `PRAGMA busy_timeout = N`
  silenced every observer and an authorizer denying `PRAGMA` cost the
  connection its wait once an observer registered; neither holds at
  0.16 (see the raw `PRAGMA busy_timeout = N` entry above).

### Fixed

- **A `lock:` carried by a subquery, a join subquery or a CTE is no
  longer dropped without a word.** The refusal was on the top-level
  render only, so a lock one nesting level down produced SQL with no
  lock in it and returned rows. The guard now sits on the arity every
  one of those paths renders through.

<!-- refusals and the busy slot: end -->

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
