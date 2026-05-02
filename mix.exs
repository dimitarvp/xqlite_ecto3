defmodule XqliteEcto3.MixProject do
  use Mix.Project

  @name "XqliteEcto3"
  @version "0.1.0-dev"
  @source_url "https://github.com/dimitarvp/xqlite_ecto3"

  def project do
    [
      app: :xqlite_ecto3,
      version: @version,
      elixir: "~> 1.15",
      name: @name,
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps(),

      # hex
      description: description(),
      package: package(),

      # docs
      docs: docs(),

      # type checking
      dialyzer: dialyzer(),

      # convenience
      aliases: aliases()
    ]
  end

  # `mix precommit` shadows the `Mix.Tasks.Precommit` that the xqlite
  # dependency also ships — alias resolution runs before task module
  # lookup, so this wins. Same spirit as xqlite's precommit, minus the
  # Rust steps (no NIF in this library).
  defp aliases do
    [
      precommit: [
        "format --check-formatted",
        "compile --warnings-as-errors",
        "dialyzer",
        "xqlite_ecto3.test.seq"
      ]
    ]
  end

  defp elixirc_paths(:test), do: ["lib", "test/support"]
  defp elixirc_paths(_), do: ["lib"]

  def application do
    [
      extra_applications: [:logger]
    ]
  end

  defp deps do
    [
      {:ecto_sql, "~> 3.12"},
      {:db_connection, "~> 2.7"},
      xqlite_dep(),
      {:rustler, "~> 0.37", optional: true, only: [:dev, :test]},
      {:telemetry, "~> 1.0"},
      {:jason, "~> 1.4"},
      {:dialyxir, "~> 1.4", only: :dev, runtime: false},
      {:ex_doc, "~> 0.20", only: :dev, runtime: false}
    ]
  end

  # Upstream-default is the Hex release; devs (and CI for integration testing
  # unreleased xqlite changes) can point at a working copy via
  #   export XQLITE_PATH=../xqlite
  # in their shell or .envrc. Matches the ergonomics xqlite itself uses via
  # XQLITE_BUILD=true for forced local compilation.
  defp xqlite_dep do
    case System.get_env("XQLITE_PATH") do
      nil -> {:xqlite, "~> 0.6"}
      path -> {:xqlite, path: path, override: true}
    end
  end

  defp description,
    do:
      "Ecto 3.x adapter backed by xqlite, with per-operation cancel tokens, structured constraint errors, and opt-in SQLite-flavored migration ergonomics."

  defp package do
    [
      licenses: ["MIT"],
      links: %{
        "GitHub" => @source_url,
        "Hexdocs" => "https://hexdocs.pm/xqlite_ecto3"
      },
      files: [
        "lib",
        "guides",
        ".formatter.exs",
        "mix.exs",
        "README.md",
        "LICENSE.md",
        "CHANGELOG.md"
      ]
    ]
  end

  defp docs do
    [
      main: "readme",
      name: @name,
      source_url: @source_url,
      source_ref: "v#{String.replace_suffix(@version, "-dev", "")}",
      extras: [
        "README.md",
        "guides/migrating_from_ecto_sqlite3.md",
        "CHANGELOG.md",
        "LICENSE.md"
      ],
      groups_for_extras: [
        Guides: Path.wildcard("guides/*.md")
      ],
      groups_for_modules: [
        Adapter: [
          XqliteEcto3,
          XqliteEcto3.Connection,
          XqliteEcto3.Driver,
          XqliteEcto3.Query,
          XqliteEcto3.DataType,
          XqliteEcto3.Error,
          XqliteEcto3.URL,
          XqliteEcto3.URLError
        ],
        "Custom Types": [
          XqliteEcto3.Types.UUID,
          XqliteEcto3.Types.TimestampTZ,
          XqliteEcto3.Types.Instant,
          XqliteEcto3.Types.Duration,
          XqliteEcto3.Types.Array
        ],
        Generators: [
          XqliteEcto3.UUIDv7
        ],
        "Migration Helpers": [
          XqliteEcto3.Migration
        ]
      ]
    ]
  end

  defp dialyzer do
    [
      plt_core_path: "priv/plts/",
      plt_file: {:no_warn, "priv/plts/core.plt"},
      plt_add_apps: [:mix, :ecto, :ecto_sql, :db_connection],
      ignore_warnings: ".dialyzer_ignore.exs"
    ]
  end
end
