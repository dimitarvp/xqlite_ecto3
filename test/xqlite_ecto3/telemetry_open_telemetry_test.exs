defmodule XqliteEcto3.Telemetry.OpenTelemetryTest do
  use ExUnit.Case, async: true

  alias XqliteEcto3.Query
  alias XqliteEcto3.Telemetry.OpenTelemetry, as: Otel

  test "callback events map the query struct's statement to db.query.text" do
    metadata = %{
      conn: nil,
      query: %Query{statement: "SELECT 1"},
      result_class: :ok,
      error_reason: nil
    }

    assert %{
             "db.system.name" => "sqlite",
             "db.operation.name" => "handle_execute",
             "db.query.text" => "SELECT 1"
           } == Otel.attributes([:xqlite_ecto3, :handle_execute, :stop], %{}, metadata)
  end

  test "iodata statements are flattened" do
    metadata = %{query: %Query{statement: ["SELECT ", "1"]}, result_class: :ok}

    assert %{"db.query.text" => "SELECT 1"} =
             Otel.attributes([:xqlite_ecto3, :handle_execute, :stop], %{}, metadata)
  end

  test "statement-cache events map their sql and dotted operation" do
    attrs =
      Otel.attributes(
        [:xqlite_ecto3, :statement_cache, :hit],
        %{},
        %{sql: "SELECT x FROM t"}
      )

    assert attrs["db.operation.name"] == "statement_cache.hit"
    assert attrs["db.query.text"] == "SELECT x FROM t"
  end

  test "connect events map the database to db.namespace" do
    metadata = %{database: "/data/app.db", result_class: :ok, error_reason: nil}
    attrs = Otel.attributes([:xqlite_ecto3, :connect, :stop], %{}, metadata)

    assert attrs["db.namespace"] == "/data/app.db"
    assert "connect /data/app.db" == Otel.span_name([:xqlite_ecto3, :connect, :stop], metadata)
  end

  test "error results map error.type from the structured reason" do
    metadata = %{result_class: :error, error_reason: {:read_only_database, "nope"}}

    assert %{"error.type" => "read_only_database"} =
             Otel.attributes([:xqlite_ecto3, :handle_execute, :stop], %{}, metadata)
  end
end
