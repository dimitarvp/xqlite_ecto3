defmodule XqliteEcto3.TelemetryDisabledSmokeTest do
  @moduledoc """
  Smoke coverage for the no-op telemetry build — the production default
  (`telemetry_enabled: false`). The dedicated CI lane compiles the
  adapter with the flag forced off and runs this file; it also runs in
  the normal enabled build, asserting whichever invariant matches the
  way the compile-time flag was baked in.

  Proves the disabled `emit/3` and `span_with_stop_metadata/3` macros
  behave: a driver query still runs and returns its real value (the
  no-op span unwraps the `{value, metadata}` block result), and no
  `[:xqlite_ecto3, :*]` event reaches a subscriber when the flag is off.
  """
  use ExUnit.Case, async: true

  alias XqliteEcto3.Driver

  # Compile-time constant — the assertion for each build is compiled in
  # via the module-level branch below, so no runtime conditional on a
  # constant trips the type checker under warnings-as-errors.
  @telemetry_enabled XqliteEcto3.Telemetry.enabled?()

  setup do
    db =
      Path.join(
        System.tmp_dir!(),
        "xqlite_ecto3_teloff_#{:erlang.unique_integer([:positive])}.db"
      )

    on_exit(fn -> for ext <- ["", "-wal", "-shm", "-journal"], do: File.rm(db <> ext) end)

    {:ok, state} = Driver.connect(database: db)
    on_exit(fn -> Driver.disconnect(:normal, state) end)
    {:ok, state: state}
  end

  test "no-op span path returns the query value and emits per the compiled flag", %{state: state} do
    handler_id = "teloff-#{:erlang.unique_integer([:positive])}"
    test_pid = self()

    :telemetry.attach_many(
      handler_id,
      [
        [:xqlite_ecto3, :handle_execute, :start],
        [:xqlite_ecto3, :handle_execute, :stop]
      ],
      fn name, measurements, metadata, _ ->
        send(test_pid, {:tel, name, measurements, metadata})
      end,
      nil
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    query = %XqliteEcto3.Query{statement: "SELECT 1", ref: nil}
    {:ok, _q, result, _state} = Driver.handle_execute(query, [], [], state)

    # The disabled span_with_stop_metadata still evaluates its block and
    # returns the block value, so the real query result flows through.
    assert %{rows: [[1]]} = result

    assert_emission_per_flag()
  end

  if @telemetry_enabled do
    defp assert_emission_per_flag do
      assert_receive {:tel, [:xqlite_ecto3, :handle_execute, :stop], _, _}
    end
  else
    defp assert_emission_per_flag do
      refute_received {:tel, [:xqlite_ecto3, :handle_execute, :start], _, _}
      refute_received {:tel, [:xqlite_ecto3, :handle_execute, :stop], _, _}
    end
  end
end
