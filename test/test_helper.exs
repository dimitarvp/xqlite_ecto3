alias Ecto.Integration.PoolRepo
alias Ecto.Integration.TestRepo

Logger.configure(level: :info)

Application.put_env(:ecto, :primary_key_type, :id)
Application.put_env(:ecto, :async_integration_tests, false)

ecto = Mix.Project.deps_paths()[:ecto]
ecto_sql = Mix.Project.deps_paths()[:ecto_sql]

# -- Repo configuration -------------------------------------------------------

test_db =
  Path.join(System.tmp_dir!(), "xqlite_ecto3_test_#{:erlang.unique_integer([:positive])}.db")

pool_db =
  Path.join(System.tmp_dir!(), "xqlite_ecto3_pool_#{:erlang.unique_integer([:positive])}.db")

Application.put_env(:xqlite_ecto3, TestRepo,
  adapter: XqliteEcto3,
  database: test_db,
  pool: Ecto.Adapters.SQL.Sandbox,
  show_sensitive_data_on_connection_error: true,
  support_alter_via_table_rebuild: true,
  rich_fk_diagnostics: true
)

Application.put_env(:xqlite_ecto3, PoolRepo,
  adapter: XqliteEcto3,
  database: pool_db,
  pool_size: 1,
  show_sensitive_data_on_connection_error: true,
  support_alter_via_table_rebuild: true,
  rich_fk_diagnostics: true
)

# Some shared tests read config from the :ecto_sql app
Application.put_env(:ecto_sql, TestRepo, Application.get_env(:xqlite_ecto3, TestRepo))
Application.put_env(:ecto_sql, PoolRepo, Application.get_env(:xqlite_ecto3, PoolRepo))

# -- Exclusions (must be before migrations — migration checks these) -----------

excludes = [
  # SQLite has no native array column type
  :array_type,

  # SQLite has no SQL-standard isolation levels
  :transaction_isolation,

  # repo.exs:864 "insert all": SQLite multi-row VALUES requires all rows
  # to have the same columns, and Ecto pads a missing cell with NULL — so
  # the column DEFAULT never applies. Only this one upstream test inserts
  # uneven rows; the other seven tagged :insert_cell_wise_defaults use
  # uniform rows, pass, and now run.
  {:location, {"deps/ecto/integration_test/cases/repo.exs", 864}},

  # JSON stored as TEXT; without schema Ecto cannot invoke JSON decoder
  :map_type_schemaless,

  # Our lock_for_migrations/3 is a deliberate no-op passthrough
  # (single-writer SQLite needs no advisory migration lock), so Ecto never
  # raises its pool-size-below-2 MigrationError. The one tagged test —
  # deps/ecto_sql/integration_test/sql/migrator.exs:198 — expects that
  # raise. (Line pointers name the `test` line: an ExUnit line filter
  # snaps to the nearest test AT OR BEFORE the line, so pointing at a
  # @tag line silently runs the preceding test.)
  :lock_for_migrations,

  # (permanent SQLite limit) no schema/namespace concept; ATTACH DATABASE
  # is the closest approximation but it is deliberately not wired up.
  :prefix,

  # The rebuild engine refuses `modify :col, references(...)` up front
  # with guidance (refuse_reference_changes!): it reconstructs foreign
  # keys from the existing schema and cannot merge a new or repointed
  # one into that list. An ADAPTER gap, not a SQLite limit — making
  # `modify references` work is filed as F-B7-25-feature in BACKLOG.
  # The two :alter_primary_key tests fail for two separate reasons:
  # migration.exs:640 hits the reference refusal above;
  # migration.exs:705 adds a PRIMARY KEY column to an existing table,
  # which SQLite's ALTER TABLE cannot do (no rebuild involved — the
  # rebuild only engages for `modify`).
  :alter_primary_key,
  :alter_foreign_key,

  # SQLite ON DELETE SET NULL/DEFAULT applies to all FK columns; no column-list syntax
  :on_delete_nilify_column_list,
  :on_delete_default_column_list,

  # SQLite has no native bitstring type
  :bitstring_type,

  # Ecto's :duration type dumps to a %Duration{} struct that our param
  # encoder has no clause for (query.ex encode_param/1), so it reaches
  # the JSON fallback and raises. SQLite also has no interval storage
  # class, but the blocker here is OURS: supporting :duration means an
  # encode clause plus a load path, and the upstream tests additionally
  # assert Postgres fields:/precision: truncation semantics.
  :duration_type,

  # transaction.exs:161 "transactions are not shared in repo" runs two
  # concurrent transactions from separate processes. It fails from two
  # ADAPTER-SUITE settings, not a SQLite limit: this helper pins PoolRepo
  # to pool_size 1 (the second process never gets a connection), and the
  # driver's default_transaction_mode: :immediate promotes the parent's
  # read-only transaction to a writer holding the write lock. The same
  # test passes against the same SQLite at pool_size >= 2 with :deferred
  # mode. Kept excluded because the suite keeps pool_size 1 on purpose
  # and :immediate is the safer production default.
  {:location, {"deps/ecto_sql/integration_test/sql/transaction.exs", 161}},

  # alter.exs:44 "reset cache on returning query after alter column
  # type": after `modify :value, :numeric` the test asserts a
  # schemaless SELECT returns %Decimal{}. SQLite has no decimal
  # storage class — NUMERIC affinity stores 1 as INTEGER, and a
  # schemaless read faithfully returns the storage value. Making this
  # pass would require affinity-based type divination on schemaless
  # reads, which we refuse by design (types live at the Ecto schema
  # layer). The sibling parameterized-query cache test passes.
  {:location, {"deps/ecto_sql/integration_test/sql/alter.exs", 44}},

  # logging.exs:74 "cast params" asserts the query-telemetry params for a
  # UUID field equal Ecto.UUID.dump!/1 — the raw 16-byte binary (Postgres's
  # binary UUID storage). This adapter stores UUIDs as TEXT by default
  # (binary_id_storage: :string), so the bound param is the 36-char string
  # form and metadata.params faithfully reports it. The telemetry handler
  # fires correctly in the sandboxed process (the in-handler assertion runs);
  # only the storage shape differs, so the params equality can't hold.
  {:location, {"deps/ecto_sql/integration_test/sql/logging.exs", 74}},

  # type.exs:362 "json_extract_path with primitive values": two SELECT
  # assertions expect Elixir booleans (`select: o.metadata["enabled"]`
  # == true). SQLite has no boolean storage class and no JSON wire
  # typing — json_extract faithfully returns INTEGER 1/0, and Ecto
  # gives untyped select expressions no load hook, so no SQLite
  # adapter can pass this without protocol-level typing (which is how
  # PostgreSQL/MySQL pass). Permanent. The sanctioned user-facing fix
  # is explicit typing — `select: type(o.metadata["enabled"],
  # :boolean)` routes through the adapter's :boolean loader; covered
  # by adapter-owned tests in json_extract_path_test.exs. All WHERE
  # comparisons and non-boolean SELECTs in this test work.
  {:location, {"deps/ecto/integration_test/cases/type.exs", 362}},

  # (permanent SQLite limit) strftime %f gives only millisecond precision.
  # interval.exs datetime_add tests that add microsecond counts round to
  # the nearest millisecond. The adapter emits fractional-seconds SQL
  # correctly; exact-value asserts still fail on nonzero-microsecond
  # fractions because SQLite cannot compute them. Non-arithmetic
  # microsecond round-trips pass — TEXT storage keeps full precision
  # (see types_test.exs). Not an adapter gap; won't be fixed here.
  :microsecond_precision,

  # migration.exs:664 "modify foreign key's on_update constraint" is tagged
  # :assigns_id_type but really fails on `modify` with a `references(...)`
  # type — the same up-front reference refusal as :alter_foreign_key
  # (F-B7-25-feature in BACKLOG), not a SQLite limit. The 3 other
  # :assigns_id_type tests pass, so the exclusion stays narrowed to this
  # line.
  {:location, {"deps/ecto_sql/integration_test/sql/migration.exs", 664}}
]

ExUnit.configure(exclude: excludes)

# -- Load shared schemas and migration ----------------------------------------

Code.require_file("#{ecto}/integration_test/support/schemas.exs")
Code.require_file("#{ecto_sql}/integration_test/support/migration.exs")

# -- Integration case template ------------------------------------------------

defmodule Ecto.Integration.Case do
  use ExUnit.CaseTemplate

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
  end
end

# -- Start repos ---------------------------------------------------------------

{:ok, _} = XqliteEcto3.ensure_all_started(TestRepo.config(), :temporary)

_ = XqliteEcto3.storage_down(TestRepo.config())
:ok = XqliteEcto3.storage_up(TestRepo.config())

_ = XqliteEcto3.storage_down(PoolRepo.config())
:ok = XqliteEcto3.storage_up(PoolRepo.config())

# Pre-set WAL mode before the pool opens connections. This avoids a race where
# pool connections try "PRAGMA journal_mode = wal" (a write operation) while a
# migration holds a write lock, causing transient "database is locked" errors.
for db <- [test_db, pool_db] do
  {:ok, conn} = XqliteNIF.open(db)
  {:ok, _} = XqliteNIF.set_pragma(conn, "journal_mode", "wal")
  XqliteNIF.close(conn)
end

{:ok, _} = TestRepo.start_link()
{:ok, _} = PoolRepo.start_link()

# -- Run migrations ------------------------------------------------------------

case Ecto.Migrator.migrated_versions(PoolRepo) do
  [] ->
    :ok = Ecto.Migrator.up(PoolRepo, 0, Ecto.Integration.Migration, log: false)

  _ ->
    :ok = Ecto.Migrator.down(PoolRepo, 0, Ecto.Integration.Migration, log: false)
    :ok = Ecto.Migrator.up(PoolRepo, 0, Ecto.Integration.Migration, log: false)
end

:ok = Ecto.Migrator.up(TestRepo, 0, Ecto.Integration.Migration, log: false)

# -- Sandbox -------------------------------------------------------------------

Ecto.Adapters.SQL.Sandbox.mode(TestRepo, :manual)
Process.flag(:trap_exit, true)

ExUnit.start()
