ecto = Mix.Project.deps_paths()[:ecto]
ecto_sql = Mix.Project.deps_paths()[:ecto_sql]

# Shared Ecto integration cases
Code.require_file("#{ecto}/integration_test/cases/assoc.exs", __DIR__)
Code.require_file("#{ecto}/integration_test/cases/joins.exs", __DIR__)
Code.require_file("#{ecto}/integration_test/cases/preload.exs", __DIR__)
Code.require_file("#{ecto}/integration_test/cases/repo.exs", __DIR__)
Code.require_file("#{ecto}/integration_test/cases/windows.exs", __DIR__)
Code.require_file("#{ecto}/integration_test/cases/interval.exs", __DIR__)
Code.require_file("#{ecto}/integration_test/cases/type.exs", __DIR__)

# Shared ecto_sql integration tests
Code.require_file("#{ecto_sql}/integration_test/sql/migration.exs", __DIR__)
Code.require_file("#{ecto_sql}/integration_test/sql/migrator.exs", __DIR__)
Code.require_file("#{ecto_sql}/integration_test/sql/sandbox.exs", __DIR__)
Code.require_file("#{ecto_sql}/integration_test/sql/sql.exs", __DIR__)
Code.require_file("#{ecto_sql}/integration_test/sql/stream.exs", __DIR__)
Code.require_file("#{ecto_sql}/integration_test/sql/subquery.exs", __DIR__)
Code.require_file("#{ecto_sql}/integration_test/sql/transaction.exs", __DIR__)
Code.require_file("#{ecto_sql}/integration_test/sql/logging.exs", __DIR__)
Code.require_file("#{ecto_sql}/integration_test/sql/alter.exs", __DIR__)

# Skipped shared suite files (permanent SQLite architectural limits):
#
# lock.exs      — advisory locks are a PostgreSQL concept. SQLite's single-
#                 writer model means it has no advisory lock API and the test
#                 scenarios are structurally impossible.
# query_many.exs — multi-statement `query_many!/4` would require the NIF to
#                 execute several statements and return multiple result sets.
#                 SQLite's C API handles one statement at a time; batching is
#                 possible (`execute_batch/2`) but doesn't collect result sets
#                 the way Ecto.SQL.query_many expects. Permanent API gap.
# Code.require_file("#{ecto_sql}/integration_test/sql/lock.exs", __DIR__)
# Code.require_file("#{ecto_sql}/integration_test/sql/query_many.exs", __DIR__)
