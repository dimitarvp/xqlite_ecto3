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
      {:ecto_sql, "~> 3.14"},
      {:xqlite_ecto3, path: "..", override: true},
      {:xqlite, path: "../../xqlite", override: true},
      # needed because XQLITE_BUILD=true forces the local source build
      {:rustler, "~> 0.38.0", runtime: false},
      {:ecto_sqlite3, "~> 0.24"}
    ]
  end
end
