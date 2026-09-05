# xqlite_ecto3 architecture

What each file under `lib/` does, the path a call takes through it, the state a
connection keeps, and the facts more than one place depends on. Every claim was
read out of the file it names. Paths are relative to `lib/xqlite_ecto3/`.

## Module map

- `lib/xqlite_ecto3.ex` — the adapter module. `use Ecto.Adapters.SQL` supplies
  most Ecto callbacks; this file adds the storage, structure and migration
  callbacks, the table-rebuild engine, the `loaders/2` / `dumpers/2` /
  `autogenerate/1` overrides, a `__before_compile__/1` that injects a
  `:url`-aware `init/2`, and the helpers `with_xqlite/3`, `txn_state/2`,
  `connection_stats/1`, `explain_analyze/3`, `parse_url/1`, `parse_url!/1`.
- `connection.ex` — `Ecto.Adapters.SQL.Connection`: the SQL generator (`all/2`,
  `update_all/2`, `delete_all/1`, `insert/8`, `expr/3`), DDL rendering
  (`execute_ddl/1`), `to_constraints/2`, `explain_query/4`, and the
  `child_spec/1` that starts the pool; `query_many/4` raises.
- `driver.ex` — the `DBConnection` behaviour: `connect/1` with its config
  validators, `checkout/1`, `ping/1`, `disconnect/2`, `handle_status/2`, the
  begin/commit/rollback and declare/fetch/deallocate callbacks,
  `handle_execute/4`, plus the statement cache, the cancel wiring and the
  transaction-state sync. `query.ex` holds `%XqliteEcto3.Query{}` and its
  `DBConnection.Query` implementation, whose `encode/3` converts every
  parameter; `raw_conn.ex` is the sentinel query that hands `with_xqlite/3` the
  raw xqlite connection reference.
- `data_type.ex` — `column_type/2`, `sqlite_affinity/1`, `bare_typename?/1`,
  `json_default/2`, `unsupported_default!/3`; `decimal_precision.ex` —
  `bind_form/1`, `representable?/1`. Between them they define
  `UnsupportedDefaultError`, `UnsupportedTypeError`, `DecimalPrecisionError`.
- `error.ex` — `XqliteEcto3.Error` and the payload structs `Error.Constraint`,
  `Error.SqliteFailure`, `Error.Input`, `Error.FkViolation`; `wrap/1` turns any
  xqlite reason into one. `fk_diagnostics.ex` (`wrap_with_replay/4`,
  `wrap_at_commit/2`) and `unique_index_names.ex` (`resolve/2`) are the
  error-path enrichments.
- `rebuild_verification.ex` — `read/2`, `verify/3`, and the predicates the
  rebuild engine shares with it (`autoincrement_declared?/1`,
  `primary_key_members/1`, `surviving_primary_key_members/2`, the two `CREATE
  TABLE` text scrubbers). Touches no database: `read/2` takes a query function.
- `url.ex`, `url_error.ex` — `parse/1`, `parse!/1` for `sqlite://`,
  `sqlite3://`, `file://` URLs, with a typed parameter allowlist.
  `telemetry.ex` — `enabled?/0` and the two macros that compile away when the
  flag is off; `telemetry/open_telemetry.ex` — `attributes/3` and
  `span_name/2`, a translation to OpenTelemetry's stable database attribute
  names with no OpenTelemetry dependency. `migration.ex` — the opt-in
  `enum_check/3` and `array_check/2`; `uuid_v7.ex` — `generate/0`; `types/` —
  `UUID` (parameterized `:storage`), `Instant`, `Duration`, `TimestampTZ`,
  `Array`, `ExactDecimal` (a decimal as canonical text over a TEXT column);
  `lib/mix/tasks/test_seq.ex` — one OS process per test file.

## Data flows

### 1. A query, from `Repo.all/2` to rows

`Ecto.Adapters.SQL`'s generated `prepare/2`
(`deps/ecto_sql/lib/ecto/adapters/sql.ex:160`) calls `Connection.all/1` and
caches the SQL; generated `execute/5` reaches `Connection.prepare_execute/5`
first time and `Connection.execute/4` after. Both wrap the SQL in a
`%XqliteEcto3.Query{}`; DBConnection then calls `Driver.handle_prepare/3` (it
only stamps a `make_ref()`), `DBConnection.Query.encode/3` (flow 3), and
`Driver.handle_execute/4`.

`run_statement/4` picks one of two paths. With the cache on it prepares or
reuses a statement and steps it in 500-row batches through
`NIF.stmt_multi_step_cancellable/3`; `finish_cached_stmt/4` then concatenates
the batches, reads the column names, computes the changed-row count and resets
the statement for its next use. It falls back to the uncached one-shot
`NIF.query_with_changes_cancellable/4` — or `NIF.query_with_changes/3` when
`:timeout` is `:infinity` — when `statement_cache_size` is 0 or `stmt_prepare`
reports `:multiple_statements`.

A column-less result gets `num_rows: changes`, `rows: nil` and a pass through
`sync_after_transaction_control/2`. An integer `:timeout` (default 15 s)
creates a cancel token and spawns a process firing `NIF.cancel_operation/1` at
the deadline (`spawn_canceller/2`) — the dirty NIF blocks the caller, so a
separate process is needed.

### 2. Streaming, from `Repo.stream/2` to batches

`Connection.stream/4` wraps the SQL in a `%XqliteEcto3.Query{}` and hands it to
`DBConnection.stream/4`, which drives three driver callbacks.
`Driver.handle_declare/4` calls `NIF.stream_open/3`, reads the column names
once with `NIF.stream_get_columns/1`, and stores them on the cursor together
with a batch size taken from `:max_rows` (default 500, and any non-positive
value falls back to that default — `batch_size_from_opts/1`). A failed
`stream_get_columns` closes the handle before wrapping the error.
`handle_fetch/4` calls `NIF.stream_fetch/2` once per batch and returns `:cont`
with the rows, or `:halt` with an empty batch when the stream reports `:done`.
`handle_deallocate/4` closes the handle.

This path never calls `UniqueIndexNames.resolve/2`: a streamed DML violation
(an `INSERT ... RETURNING` through `Ecto.Adapters.SQL.stream/4`) stays
correctly classified but reports `unique_index_lookup: :not_run`, because no
changeset traverses a stream.

### 3. Parameters in, values out

`DBConnection.Query.encode/3` in `query.ex` maps each parameter by position:
booleans to `1`/`0`; `NaiveDateTime` and `DateTime` to SQLite's own datetime
text via `sqlite_datetime/1` (a zoned value shifted to UTC first); `Date` and
`Time` to ISO 8601; a `Decimal` through `DecimalPrecision.bind_form/1`; a map
or list to JSON, raising `UnencodableParameterError` when Jason refuses. Coming
back, `XqliteEcto3.loaders/2` prepends one decoder per Ecto base type;
`decimal_decode/1` returns `:error` on a partial parse, NaN or infinity so Ecto
raises its typed load failure, and `utc_datetime_decode/1` attaches `Etc/UTC`
to offset-less text.

`Types.ExactDecimal` sits outside that decimal path in both directions. Its
`dump/1` produces a plain string, so `DecimalPrecision.bind_form/1` never sees
the value and no number is ever bound; its `load/1` parses that string itself,
so `decimal_decode/1` and its 34-significant-digit parse ceiling are not on the
way back either.

### 4. Transactions, the state sync, the disconnect guard

`handle_begin/2` with `mode: :transaction` (DBConnection's default marker)
resolves to the connection's `default_transaction_mode` — `:immediate` unless
configured otherwise — and issues `NIF.begin/2`. `mode: :savepoint` inside an
open transaction issues `NIF.savepoint/2`; at top level it returns a
`:savepoint_without_transaction` error and disconnects, because a lone
`SAVEPOINT` would open the transaction deferred and discard the configured
mode. `handle_commit/2` and `handle_rollback/2` split on the same `:savepoint`
marker. Transaction control arriving as ordinary SQL never reaches those
callbacks, so `handle_execute/4`
calls `sync_after_transaction_control/2` on every column-less result; a
statement failing while a transaction is believed open goes through
`disconnect_if_rolled_back/2` — see the state table below.

### 5. Errors, and the two reads on the error path

`Error.wrap/1` produces `%XqliteEcto3.Error{type:, message:, details:}`;
`Driver.wrap_execute_error/4` then runs `UniqueIndexNames.resolve/2` always and
`FkDiagnostics` only under `rich_fk_diagnostics: true`, and stamps
`:statement`. `Ecto.Adapters.SQL`
(`deps/ecto_sql/lib/ecto/adapters/sql.ex:1207`) calls
`Connection.to_constraints/2`, which matches the `Error.Constraint` subtype and
returns `[{:unique, name}]`, `[{:foreign_key, name}, ...]`, `[{:check, name}]`
or `[]` — an empty list makes ecto_sql re-raise the structured error, which is
what NOT NULL and unnamed foreign-key violations do.
`UniqueIndexNames.resolve/2` reads `PRAGMA busy_timeout` for a time budget,
then `PRAGMA index_list` and `PRAGMA index_info` per unique index.
`FkDiagnostics.wrap_with_replay/4` opens the reserved savepoint
`xqlite_fk_diag`, defers foreign keys, takes a `PRAGMA foreign_key_check`
baseline, replays the failed statement, checks again, and keeps only rows the
baseline did not have; `cleanup/1` always rolls back, releases and resets
`defer_foreign_keys`. `wrap_at_commit/2` skips the replay and so has no
baseline.

### 6. Connect, and URLs

`Connection.child_spec/1` fills in `@default_opts` (`journal_mode: :wal`,
`cache_size: -64_000`, `temp_store: :memory`, `pool_size: 5`, `busy_timeout:
5_000`) and starts `DBConnection.child_spec(XqliteEcto3.Driver, opts)`.
`Driver.connect/1` validates every pragma-bound value first — SQLite's pragma
parser silently picks a default for an unrecognized value, so this layer is the
only one that says no — then opens the database and applies pragmas in a fixed
order: `auto_vacuum` (before anything writes a page), `busy_timeout`,
`journal_mode`, `foreign_keys`, `cache_size`, `synchronous`, `temp_store`,
`wal_autocheckpoint`, `mmap_size`, and `custom_pragmas` last so explicit
configuration wins. `set_journal_mode/4` makes up to 10 attempts at a
busy-rejected WAL conversion, 2 ms apart; read-only connections skip the
write-requiring pragmas; `register_config_hooks/2` installs each `hooks:` entry
on the process name it registers. Every failure returns `{:error,
Error.wrap(reason)}`, never a raise, so DBConnection can retry.
`XqliteEcto3.__before_compile__/1` injects a default `init/2` into repos
without one, popping `:url` and merging `parse_url!/1`'s output before Ecto's
generic URL handling runs.

### 7. DDL, and what it refuses

`XqliteEcto3.execute_ddl/3` forwards everything except `{:alter, table,
changes}` to `Ecto.Adapters.SQL.execute_ddl/4`, which calls
`Connection.execute_ddl/1` and runs each rendered statement. An alter block
branches three ways: any `:modify` triggers the rebuild; otherwise any
`add_if_not_exists` / `remove_if_exists` is resolved against
`pragma_table_info` by `resolve_conditional_changes/2`, which threads the live
column set through the block so two conditional changes to one column agree;
otherwise the changes pass through.

`Connection.execute_ddl/1` raises `ArgumentError` for what SQLite has no
grammar for, one clause per case:

| Rejected | Because |
| --- | --- |
| a keyword-list `:options` on a table | no SQLite table-option grammar |
| `{:create, %Constraint{}}` | no `ALTER TABLE ADD CONSTRAINT` |
| `{:drop, %Constraint{}}` and its `_if_exists` twin | no `DROP CONSTRAINT` |
| an index with `concurrently: true` | no concurrent index build |
| an index with `only: true` | no inheritance, so nothing to restrict |
| an index with a non-empty `include` | no covering-index clause |
| an index with `using:` set | one index method only |
| an index with `nulls_distinct:` set | NULLs are always distinct |
| a keyword list passed to `execute/1` | no keyword DDL form |

Two more raises sit beside the DDL renderer: `Connection.quote_table/2` rejects
a table prefix (SQLite has no schemas), and `Connection.all/1` rejects a query
with `lock:` set.

### 8. The table rebuild

`rebuild_table/4` runs only under `support_alter_via_table_rebuild: true`. It
resolves the table's stored spelling from `sqlite_schema`, reads
`pragma_table_list` for the table kind and the `WITHOUT ROWID` / `STRICT`
flags, and runs ten pre-flight checks, each raising `ArgumentError` with
nothing changed: a `references(...)` in the change set; a virtual or shadow
table; a construct no pragma exposes (`rebuild-cannot-preserve` below); a
populated table referencing this one with a row-affecting `ON DELETE` action; a
view or another table's trigger still naming it; the primary key removed; the
key granted to a second column while one is still keyed; a `modify` that would
rewrite stored values into another affinity; a trigger reading a removed
column; and a UNIQUE, foreign key or index left naming a removed column.

It then reads the structure — columns, foreign keys, UNIQUE constraints,
indexes, triggers (main and temp schemas), primary-key sort order, the
AUTOINCREMENT declaration and sequence value — takes a
`RebuildVerification.read/2` snapshot, and builds the statements: `PRAGMA
defer_foreign_keys = ON`, `CREATE TABLE <name>__xqlite_new`, the `INSERT INTO
... SELECT` copy (carrying `rowid` explicitly when no INTEGER primary key
aliases it), `DROP TABLE`, `ALTER TABLE ... RENAME TO`, the `sqlite_sequence`
restore, then every index and trigger. `in_wrapping_transaction?/2` asks both
`in_transaction?/1` and `DBConnection.status/2`; if neither reports a
transaction the rebuild checks a connection out and wraps itself in `BEGIN
IMMEDIATE` / `COMMIT`, and the `after` block restores the prior
`defer_foreign_keys` value. Finally `PRAGMA foreign_key_check(<table>)` must
come back empty and `verify_structure!/5` runs `RebuildVerification.verify/3`,
which applies the change set to the pre-rebuild reading (`predict/2`) and
compares it against a fresh reading, raising `RebuildVerificationError` on the
first mismatch — before COMMIT, so the table is unchanged.

### 9. `with_xqlite/3`, `explain_analyze/3`, telemetry

`with_xqlite/3` resolves the repo's dynamic name, reads the pool pid from
`Ecto.Adapter.lookup_meta/1`, and runs `DBConnection.run/3`; inside it,
`DBConnection.execute!/4` with a `%XqliteEcto3.RawConn{}` yields the raw xqlite
connection reference, and `txn_state/2` and `connection_stats/1` are thin
wrappers over that. `explain_analyze/3` compiles the queryable with
`Ecto.Adapters.SQL.to_sql/3`, encodes parameters through the same
`DBConnection.Query.encode/3` production uses, and calls
`Xqlite.explain_analyze/3`; `wrap_in_transaction: true` runs it inside the
`xqlite_explain_analyze` savepoint and always rolls back, letting a rollback
error win over the report. The driver wraps `connect`, the
begin/commit/rollback trio, `handle_execute` and the declare/fetch/deallocate
trio in `:telemetry` spans and emits single events for `disconnect`, `checkout`
and the three statement-cache events; `FkDiagnostics` adds one span,
`classify_dbc/2` adds `result_class` and `error_reason` to stop metadata, and
`Telemetry.OpenTelemetry.attributes/3` maps any event to the stable `db.*` and
`error.type` names.

## State machines

### Transaction status (the driver struct's cached flag)

| State | Event | Next | Moved by |
| --- | --- | --- | --- |
| any | connection opened | from SQLite | `checkout/1` |
| `:idle` | begin, not savepoint | `:transaction` | `handle_begin/2` |
| `:idle` | begin, savepoint | disconnect | `handle_begin/2` |
| `:transaction` | commit, rollback | `:idle` | those callbacks |
| any | column-less control SQL | from SQLite | `sync_after_...` |
| any | status asked | from SQLite | `handle_status/2` |
| `:transaction` | statement error | disconnect unless still open | the guard |

"From SQLite" means `NIF.transaction_status/1` decides. The guard
(`disconnect_if_rolled_back/2`) keeps the connection only when that read comes
back `true`; both a `false` and a failed read disconnect.

### Managed savepoint depth

| State | Event | Next | Moved by |
| --- | --- | --- | --- |
| `n`, in transaction | begin, savepoint | `n + 1` | `handle_begin/2` |
| `n > 0` | commit, savepoint | `n - 1` | `released_savepoint_state/1` |
| `n > 0` | rollback, savepoint | `n - 1` | `released_savepoint_state/1` |
| `n` | full commit or rollback | `0` | commit, rollback callbacks |
| `n` | SQLite reports autocommit | `0` | `refresh_transaction_status/1` |

Under `Ecto.Adapters.SQL.Sandbox` the wrapper transaction opens with `mode:
:transaction` (`deps/ecto_sql/lib/ecto/adapters/sql/sandbox.ex:659`) and every
nested `Repo.transaction` arrives as `mode: :savepoint` (line 361), so the
counter is the test's own nesting depth.

### Statement cache (per connection)

| State | Event | Next | Moved by |
| --- | --- | --- | --- |
| miss | prepare succeeds | cached, key at head | `insert_stmt/3` |
| miss | `:multiple_statements` | uncached one-shot | `prepare_and_cache/2` |
| hit | statement reused | key moved to head | `touch_stmt/2` |
| over capacity | insert | tail key finalized | `evict_over_capacity/1` |
| any | disconnect | all finalized | `disconnect/2` |

Capacity is `statement_cache_size`, default 50; `0` bypasses the cache
entirely (`run_statement/4`). Eviction takes the last key of
`stmt_cache_keys`, which `touch_stmt/2` and `insert_stmt/3` keep in
most-recently-used order.

## Shared facts with consumers

Facts more than one place depends on. The complete consumer list and the
`rg` / `ast-grep` anchors for every row live in the invariant registry, in the
review-records directory `AGENTS.md` points at; this table is the readable
half. Producers are relative to `lib/xqlite_ecto3/`, pins to
`test/xqlite_ecto3/`.

| id | statement | producer | pin |
| --- | --- | --- | --- |
| `datetime-text-form` | Datetimes store as `YYYY-MM-DD HH:MM:SS[.ffffff]`: space separator, no `T`, no `Z`. | `query.ex:sqlite_datetime/1` | `datetime_add_form_test.exs: "datetime_add renders the stored text form: space separator, no designator"` |
| `real-affinity-numeric` | A spelling SQLite would give REAL affinity renders `NUMERIC`, so an integer-exact value past 2^53 is not rounded in. | `data_type.ex:column_type/2`, `sqlite_affinity/1` | `data_type_test.exs: "any unrecognized spelling SQLite would give REAL affinity"` |
| `decimal-numeric-bind` | A `Decimal` binds as an exact int64 or float64, never as text; one with no exact form raises. | `decimal_precision.ex:bind_form/1` | `decimal_precision_test.exs: "an int64 whole number stores as an exact INTEGER"` |
| `binary-id-storage` | `config :xqlite_ecto3, :binary_id_storage` governs the dumper/loader chain, the migration column type and the query-parameter `CAST` together. | `xqlite_ecto3.ex:binary_id_storage/0` | `binary_id_storage_test.exs: ":binary_id and :uuid map to BLOB when :binary"` |
| `busy-timeout-int32` | `busy_timeout` must be an integer in `0..2_147_483_647`; outside that SQLite clamps to 0 and stops waiting. | `driver.ex:validate_busy_timeout/1` | `driver_connect_pragmas_test.exs: "the int32 boundaries connect and read back exactly"` |
| `busy-timeout-is-the-lookup-budget` | The unique-index-name lookup budget is the connection's `busy_timeout`; a reported 0 becomes a fixed 500 ms. | `unique_index_names.ex:lookup_budget_ms/1` | `unique_index_names_test.exs: "a zero-reported busy timeout gets the fixed budget, not zero and not unlimited"` |
| `with-xqlite-fresh-checkout` | `with_xqlite/3` always starts its own checkout, so it must never be nested inside a transaction, a checkout, or itself. | `xqlite_ecto3.ex:with_xqlite/3` | unpinned |
| `transaction-status-source` | `NIF.transaction_status/1` is the only answer to whether a transaction is open; the driver field caches it. | `driver.ex:refresh_transaction_status/1` | `driver_transaction_state_test.exs: "stale :idle cache is corrected to :transaction after raw BEGIN"` |
| `transaction-control-keywords` | `BEGIN`, `COMMIT`, `END`, `ROLLBACK`, `SAVEPOINT`, `RELEASE`, found past whitespace, both comment forms, semicolons and a UTF-8 BOM. | `driver.ex:leading_keyword/1` | `driver_transaction_state_test.exs: "a BOM-prefixed BEGIN updates the cached flag"` |
| `savepoint-names` | Managed savepoints are `xqlite_sp_<4-byte hex prefix>_<n>`; three other savepoint names are reserved constants. | `driver.ex:savepoint_name/2` | `driver_transaction_state_test.exs: "raw SAVEPOINT xqlite_sp_0 by user does not collide with managed stack"` |
| `changes-need-total-changes` | A changed-row count is reported only when `sqlite3_total_changes()` moved, because `sqlite3_changes()` is sticky. | `driver.ex:changes_since/2` | `driver_statement_cache_test.exs: "DDL after a DML through the cache reports zero, not the stale change count"` |
| `error-type-atom` | Every adapter error is one `%XqliteEcto3.Error{}` with a typed `:type` atom and a per-class `:details` struct; classification never reads message text. | `error.ex:wrap/1` | `error_wrap_test.exs: "handles every constraint subtype atom"` |
| `error-path-cap-24` | Both error-path reads stop at 24 items: 24 FK violations materialized, 24 unique indexes examined. | `fk_diagnostics.ex:@violation_cap`, `unique_index_names.ex:@max_candidate_lookups` | `unique_index_names_test.exs: "more named unique indexes than the lookup cap degrade to the derived name"` |
| `unique-index-emission-rule` | A real index name is emitted only for a single non-autoindex candidate; anything else falls back to `"<table>_<cols>_index"`. | `connection.ex:unique_constraints/1` | `unique_index_names_test.exs: "ambiguous candidates are recorded but the derived name is emitted"` |
| `fk-name-convention` | A foreign-key constraint name is `"<table>_<col>[_<col>...]_fkey"`, Ecto's default for `references/3`. | `fk_diagnostics.ex:synthesize_name/2`, `connection.ex:reference_name/3` | `fk_diagnostics_test.exs: "compound FK reports both columns and a joined name"` |
| `fk-diagnostics-status` | `details.fk_diagnostics` is `:not_run`, `:ok`, `{:truncated, total}` or `{:unavailable, reason}`, and never replaces the error. | `fk_diagnostics.ex:enrich/4` | `fk_diagnostics_test.exs: "violations past the cap are truncated with the total on the status"` |
| `telemetry-metadata-contract` | Every event but the `connect` span carries `:conn`; `error_reason` may be `{:disconnect, error}`; `:exception` carries neither field. | `driver.ex:classify_dbc/2` | `telemetry_test.exs: "checkout fires single event"` |
| `sql-text-escaping` | An identifier doubles an embedded `"`; a string literal doubles `'` and leaves the backslash alone; a JSON path key escapes both. | `connection.ex:escape_identifier/1`, `escape_string/1`, `escape_json_key/1` | `escape_roundtrip_law_test.exs: "a generated table and column name survive a round trip"` |
| `ascii-case-folding` | Names resolve by ASCII case folding; the rebuild emits the stored spelling and scratches to `"<name>__xqlite_new"`. | `xqlite_ecto3.ex:folded/1`, `transient_name/1` | `table_rebuild_test.exs: "a modify spelled in another case reaches the stored column"` |
| `rebuild-cannot-preserve` | Generated columns, `WITHOUT ROWID`, `STRICT`, `CHECK`, `COLLATE`, `DEFERRABLE` and `ON CONFLICT` each stop the rebuild. | `xqlite_ecto3.ex:unpreservable_kind/4` | `table_rebuild_preservation_test.exs: "a WITHOUT ROWID table refuses the rebuild and stays intact"` |
| `shared-create-text-predicates` | One reading of a stored `CREATE TABLE` text serves the engine and its verifier: the AUTOINCREMENT test plus two text scrubbers. | `rebuild_verification.ex:autoincrement_declared?/1`, `without_string_literals/1`, `without_string_literals_or_names/1` | `rebuild_verification_test.exs: "a literal naming AUTOINCREMENT is not a declaration"` |
| `one-rule-for-defaults` | A migration `default:` renders and is refused the same on the plain ALTER, the rebuild, and the rebuild's prediction. | `data_type.ex:json_default/2`, `unsupported_default!/3` | `rebuild_verification_test.exs: "a struct default is refused, not predicted"` |
| `bare-typename-rule` | `bare_typename?/1` decides whether a declared type renders bare: the migration passthrough refuses, the rebuild quotes. | `data_type.ex:bare_typename?/1` | `data_type_test.exs: "SQLite keywords in type position"` |
| `pragma-defaults-in-two-places` | `journal_mode: :wal`, `cache_size: -64_000`, `temp_store: :memory` and `busy_timeout: 5_000` live in two lists and must agree. | `connection.ex:@default_opts`, `driver.ex:connect/1` | `driver_connect_pragmas_test.exs: "cache_size and foreign_keys keep the adapter defaults when absent"` |
| `url-params-match-connect-validators` | The URL allowlist coerces to exactly what the connect validators accept, so a refusable value is refused at parse time. | `url.ex:@param_specs` | `url_test.exs: "rejects values past int32 max — connect would refuse them"` |
| `exclusion-list-matches-tags-doc` | Every exclusion tag and location tuple has a doc row and the reverse; every tuple names a `test` line. | `test/test_helper.exs` | `exclusion_artifacts_test.exs: "every location tuple has a doc row, and every pointer names a test line"` |

## Build facts

- Telemetry is `config :xqlite_ecto3, :telemetry_enabled`, read with
  `Application.compile_env/3` in `telemetry.ex`; changing it needs `mix
  deps.compile xqlite_ecto3 --force`. The sibling `config :xqlite,
  :telemetry_enabled` gates the xqlite-level events.
- UUID storage is `config :xqlite_ecto3, :binary_id_storage`, read at run time
  from the three call sites under `binary-id-storage` above.
- Warnings are errors everywhere: `elixirc_options` in `mix.exs` for `lib/`,
  and the `test: "test --warnings-as-errors"` alias for `.exs` files. The one
  exemption is `test/ecto3_integration/all_test.exs`, which
  `lib/mix/tasks/test_seq.ex:warnings_args/1` runs with
  `--no-warnings-as-errors` because the vendored upstream files carry warnings.
- `mix verify` chains format check, compile, `deps.audit`, `sobelow --skip
  --exit low`, `dialyzer`, the sequential suite and a
  `scripts/tree_fingerprint.exs --stamp` run; sobelow's role-inherent findings
  carry inline `# sobelow_skip` marks.
- The xqlite dependency is pinned at patch level in `mix.exs` because xqlite is
  pre-1.0 and its minor version is where it breaks; `XQLITE_PATH` swaps it for
  a path dependency with `override: true`, which hides breakage against the
  released package. SQLite itself is bundled by xqlite, and no build option
  here affects it.
