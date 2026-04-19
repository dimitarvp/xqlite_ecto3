# Dialyzer warnings that are known false positives — each entry has a
# justification next to it. If you're tempted to add one here, pause and
# try fixing the underlying code first.

[
  # `use Ecto.Adapters.SQL` generates a `rollback/2` whose only control flow
  # is to raise — it propagates rollback via an exception to be caught by
  # `handle_rollback/3`. Dialyzer correctly notes "no local return"; this
  # is intentional Ecto design, shared across every ecto_sql adapter.
  {"lib/xqlite_ecto3.ex", :no_return}
]
