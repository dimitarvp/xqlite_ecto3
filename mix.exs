defmodule XqliteEcto3.MixProject do
  use Mix.Project

  @name "XqliteEcto3"

  def project do
    [
      app: :xqlite_ecto3,
      version: "0.1.0-dev",
      elixir: "~> 1.15",
      name: @name,
      start_permanent: Mix.env() == :prod,
      elixirc_paths: elixirc_paths(Mix.env()),
      deps: deps()
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
      {:xqlite, "~> 0.5.2"},
      {:jason, "~> 1.4"}
    ]
  end
end
