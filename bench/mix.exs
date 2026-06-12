defmodule XqliteBench.MixProject do
  use Mix.Project

  def project do
    [
      app: :xqlite_bench,
      version: "0.1.0",
      elixir: "~> 1.15",
      start_permanent: false,
      deps: deps()
    ]
  end

  def application do
    [extra_applications: [:logger]]
  end

  # Standalone on purpose: this lockfile pins BOTH adapters explicitly
  # and keeps the published xqlite_ecto3 package's dependency tree
  # pristine. xqlite_ecto3 + xqlite come from the local working copies
  # (benchmarks track main); ecto_sqlite3 comes from Hex.
  defp deps do
    [
      {:benchee, "~> 1.3"},
      # 3.13 pinned: ecto_sql 3.14 changed the Connection.insert
      # callback to /8, which xqlite_ecto3 does not implement yet —
      # discovered by this bench project's fresh lockfile (the
      # adapter's own lock hides it). Tracked as a separate fix.
      {:ecto_sql, "~> 3.13.0"},
      {:xqlite_ecto3, path: "..", override: true},
      {:xqlite, path: "../../xqlite", override: true},
      # needed because XQLITE_BUILD=true forces the local source build
      {:rustler, "~> 0.38.0", runtime: false},
      # 0.22.x is the ecto_sql-3.13 era of ecto_sqlite3 (0.24+ requires
      # ecto_sql 3.14 — they already migrated to the insert/8 callback).
      {:ecto_sqlite3, "~> 0.22.0"}
    ]
  end
end
