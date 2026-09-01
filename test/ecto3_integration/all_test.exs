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
# lock.exs      — row-level `SELECT ... FOR UPDATE` locking. The adapter
#                 refuses any query with `lock:` set (ArgumentError in all/1)
#                 and SQLite itself rejects the FOR UPDATE syntax; the file's
#                 one test also requires :lock_for_update app config.
# query_many.exs — multi-statement `query_many!/4`. One prepare call compiles
#                 one statement and hands back the unused tail; looping over
#                 that tail and collecting one result set per statement is
#                 implementable — the adapter chose not to. An adapter
#                 decision, not a SQLite limit.
# Code.require_file("#{ecto_sql}/integration_test/sql/lock.exs", __DIR__)
# Code.require_file("#{ecto_sql}/integration_test/sql/query_many.exs", __DIR__)
