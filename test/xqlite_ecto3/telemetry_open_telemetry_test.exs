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

  test "an error that also drops the connection is classified by the error inside" do
    inner = {:constraint_violation, :constraint_unique, "UNIQUE constraint failed"}
    metadata = %{result_class: :error, error_reason: {:disconnect, inner}}

    assert %{"error.type" => "constraint_violation"} =
             Otel.attributes([:xqlite_ecto3, :handle_execute, :stop], %{}, metadata)
  end

  test "a wrapped adapter error is classified by its typed field" do
    metadata = %{
      result_class: :error,
      error_reason: %XqliteEcto3.Error{type: :constraint_violation}
    }

    assert %{"error.type" => "constraint_violation"} =
             Otel.attributes([:xqlite_ecto3, :handle_execute, :stop], %{}, metadata)
  end

  test "a wrapped error that also drops the connection keeps its typed field" do
    metadata = %{
      result_class: :error,
      error_reason: {:disconnect, %XqliteEcto3.Error{type: :constraint_violation}}
    }

    assert %{"error.type" => "constraint_violation"} =
             Otel.attributes([:xqlite_ecto3, :handle_execute, :stop], %{}, metadata)
  end

  test "a wrapped error with no typed field falls back to the struct name" do
    metadata = %{result_class: :error, error_reason: %XqliteEcto3.Error{type: nil}}

    assert %{"error.type" => "XqliteEcto3.Error"} =
             Otel.attributes([:xqlite_ecto3, :handle_execute, :stop], %{}, metadata)
  end

  test "a foreign struct error still reports the struct name" do
    metadata = %{
      result_class: :error,
      error_reason: %DBConnection.ConnectionError{message: "boom", reason: :error}
    }

    assert %{"error.type" => "DBConnection.ConnectionError"} =
             Otel.attributes([:xqlite_ecto3, :handle_execute, :stop], %{}, metadata)
  end
end
