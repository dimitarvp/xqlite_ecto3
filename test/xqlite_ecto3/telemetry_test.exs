defmodule XqliteEcto3.TelemetryTest do
  @moduledoc """
  Validates that adapter callbacks emit `[:xqlite_ecto3, :*]` telemetry
  events with the documented shape.

  Same harness as the parent xqlite telemetry tests: per-test handler
  attach with a unique handler-id, capture into the test mailbox,
  assert shape, detach. The driver is exercised directly (via
  `XqliteEcto3.Driver.connect/1` etc.) rather than through a Repo so
  the events fire synchronously and predictably.
  """

  use ExUnit.Case, async: true

  alias XqliteEcto3.Driver

  setup do
    db =
      Path.join(System.tmp_dir!(), "xqlite_ecto3_tel_#{:erlang.unique_integer([:positive])}.db")

    on_exit(fn ->
      for ext <- ["", "-wal", "-shm", "-journal"], do: File.rm(db <> ext)
    end)

    {:ok, state} = Driver.connect(database: db)
    on_exit(fn -> Driver.disconnect(:normal, state) end)
    {:ok, state: state, db: db}
  end

  describe "compile-time flag" do
    test "enabled?/0 reflects test config" do
      assert XqliteEcto3.Telemetry.enabled?() == true
    end
  end

  describe "connect / disconnect telemetry" do
    test "connect fires :start and :stop with database in metadata", %{db: _db} do
      handler_id = "test-connect-#{:erlang.unique_integer([:positive])}"

      attach_capture(handler_id, [
        [:xqlite_ecto3, :connect, :start],
        [:xqlite_ecto3, :connect, :stop]
      ])

      fresh_db =
        Path.join(
          System.tmp_dir!(),
          "xqlite_ecto3_telc_#{:erlang.unique_integer([:positive])}.db"
        )

      on_exit(fn ->
        for ext <- ["", "-wal", "-shm", "-journal"], do: File.rm(fresh_db <> ext)
      end)

      {:ok, fresh_state} = Driver.connect(database: fresh_db)
      on_exit(fn -> Driver.disconnect(:normal, fresh_state) end)

      assert_receive {:telemetry_event, [:xqlite_ecto3, :connect, :start], _,
                      %{database: ^fresh_db}}

      assert_receive {:telemetry_event, [:xqlite_ecto3, :connect, :stop], _, %{result_class: :ok}}

      :telemetry.detach(handler_id)
    end

    test "connect fires with error metadata on failure" do
      handler_id = "test-connect-err-#{:erlang.unique_integer([:positive])}"
      attach_capture(handler_id, [[:xqlite_ecto3, :connect, :stop]])

      bogus = "/no/such/dir/xqlite_test.db"
      assert {:error, _} = Driver.connect(database: bogus)

      assert_receive {:telemetry_event, [:xqlite_ecto3, :connect, :stop], _, metadata}
      assert metadata.result_class == :error
      assert metadata.database == bogus

      :telemetry.detach(handler_id)
    end

    test "disconnect fires single event" do
      handler_id = "test-disc-#{:erlang.unique_integer([:positive])}"
      attach_capture(handler_id, [[:xqlite_ecto3, :disconnect]])

      db =
        Path.join(
          System.tmp_dir!(),
          "xqlite_ecto3_disc_#{:erlang.unique_integer([:positive])}.db"
        )

      {:ok, state} = Driver.connect(database: db)
      :ok = Driver.disconnect(:normal, state)

      assert_receive {:telemetry_event, [:xqlite_ecto3, :disconnect], _, _metadata}

      for ext <- ["", "-wal", "-shm", "-journal"], do: File.rm(db <> ext)
      :telemetry.detach(handler_id)
    end
  end

  describe "checkout telemetry" do
    test "checkout fires single event", %{state: state} do
      handler_id = "test-checkout-#{:erlang.unique_integer([:positive])}"
      attach_capture(handler_id, [[:xqlite_ecto3, :checkout]])

      {:ok, _state2} = Driver.checkout(state)

      assert_receive {:telemetry_event, [:xqlite_ecto3, :checkout], _, %{conn: _}}

      :telemetry.detach(handler_id)
    end
  end

  describe "transaction callback telemetry" do
    test "handle_begin fires :start / :stop with mode metadata", %{state: state} do
      handler_id = "test-begin-#{:erlang.unique_integer([:positive])}"

      attach_capture(handler_id, [
        [:xqlite_ecto3, :handle_begin, :start],
        [:xqlite_ecto3, :handle_begin, :stop]
      ])

      {:ok, _, state2} = Driver.handle_begin([], state)

      assert_receive {:telemetry_event, [:xqlite_ecto3, :handle_begin, :start], _,
                      %{mode: :transaction}}

      assert_receive {:telemetry_event, [:xqlite_ecto3, :handle_begin, :stop], _,
                      %{result_class: :ok}}

      Driver.handle_rollback([], state2)
      :telemetry.detach(handler_id)
    end

    test "handle_commit fires after a begin", %{state: state} do
      {:ok, _, state2} = Driver.handle_begin([], state)

      handler_id = "test-commit-#{:erlang.unique_integer([:positive])}"
      attach_capture(handler_id, [[:xqlite_ecto3, :handle_commit, :stop]])

      {:ok, _, _state3} = Driver.handle_commit([], state2)

      assert_receive {:telemetry_event, [:xqlite_ecto3, :handle_commit, :stop], _,
                      %{result_class: :ok}}

      :telemetry.detach(handler_id)
    end

    test "handle_rollback fires after a begin", %{state: state} do
      {:ok, _, state2} = Driver.handle_begin([], state)

      handler_id = "test-rollback-#{:erlang.unique_integer([:positive])}"
      attach_capture(handler_id, [[:xqlite_ecto3, :handle_rollback, :stop]])

      {:ok, _, _state3} = Driver.handle_rollback([], state2)

      assert_receive {:telemetry_event, [:xqlite_ecto3, :handle_rollback, :stop], _,
                      %{result_class: :ok}}

      :telemetry.detach(handler_id)
    end

    test "savepoint mode is captured in metadata", %{state: state} do
      {:ok, _, state2} = Driver.handle_begin([], state)

      handler_id = "test-sp-#{:erlang.unique_integer([:positive])}"
      attach_capture(handler_id, [[:xqlite_ecto3, :handle_begin, :stop]])

      {:ok, _, state3} = Driver.handle_begin([mode: :savepoint], state2)

      assert_receive {:telemetry_event, [:xqlite_ecto3, :handle_begin, :stop], _,
                      %{mode: :savepoint}}

      Driver.handle_rollback([mode: :savepoint], state3)
      Driver.handle_rollback([], state3)
      :telemetry.detach(handler_id)
    end
  end

  describe "handle_execute telemetry" do
    test "fires :start and :stop on a successful query", %{state: state} do
      handler_id = "test-exec-#{:erlang.unique_integer([:positive])}"

      attach_capture(handler_id, [
        [:xqlite_ecto3, :handle_execute, :start],
        [:xqlite_ecto3, :handle_execute, :stop]
      ])

      query = %XqliteEcto3.Query{
        statement: "CREATE TABLE t(id INTEGER PRIMARY KEY)",
        ref: nil
      }

      {:ok, _q2, _state2} = Driver.handle_prepare(query, [], state)
      {:ok, _q3, _result, _state3} = Driver.handle_execute(query, [], [], state)

      assert_receive {:telemetry_event, [:xqlite_ecto3, :handle_execute, :start], _,
                      %{conn: _, sql: "CREATE TABLE t(id INTEGER PRIMARY KEY)"}}

      assert_receive {:telemetry_event, [:xqlite_ecto3, :handle_execute, :stop], _,
                      %{result_class: :ok}}

      :telemetry.detach(handler_id)
    end

    test "fires :stop with :error on bad SQL", %{state: state} do
      handler_id = "test-exec-err-#{:erlang.unique_integer([:positive])}"
      attach_capture(handler_id, [[:xqlite_ecto3, :handle_execute, :stop]])

      query = %XqliteEcto3.Query{
        statement: "SELECT * FROM nonexistent_table",
        ref: nil
      }

      {:error, _, _state2} = Driver.handle_execute(query, [], [], state)

      assert_receive {:telemetry_event, [:xqlite_ecto3, :handle_execute, :stop], _, metadata}
      assert metadata.result_class == :error

      :telemetry.detach(handler_id)
    end
  end

  describe "cursor lifecycle telemetry" do
    test "handle_declare / handle_fetch / handle_deallocate all fire", %{state: state} do
      query = %XqliteEcto3.Query{
        statement: "CREATE TABLE t(id INTEGER PRIMARY KEY)",
        ref: nil
      }

      {:ok, _, _, _state2} = Driver.handle_execute(query, [], [], state)

      query2 = %XqliteEcto3.Query{statement: "SELECT id FROM t", ref: nil}
      {:ok, _, state3} = Driver.handle_prepare(query2, [], state)

      handler_id = "test-cursor-#{:erlang.unique_integer([:positive])}"

      attach_capture(handler_id, [
        [:xqlite_ecto3, :handle_declare, :stop],
        [:xqlite_ecto3, :handle_fetch, :stop],
        [:xqlite_ecto3, :handle_deallocate, :stop]
      ])

      {:ok, _q, cursor, state4} = Driver.handle_declare(query2, [], [], state3)
      {:halt, _, state5} = Driver.handle_fetch(query2, cursor, [], state4)
      {:ok, _, _state6} = Driver.handle_deallocate(query2, cursor, [], state5)

      assert_receive {:telemetry_event, [:xqlite_ecto3, :handle_declare, :stop], _, _}
      assert_receive {:telemetry_event, [:xqlite_ecto3, :handle_fetch, :stop], _, _}
      assert_receive {:telemetry_event, [:xqlite_ecto3, :handle_deallocate, :stop], _, _}

      :telemetry.detach(handler_id)
    end
  end

  # ---------------------------------------------------------------------------
  # Helpers
  # ---------------------------------------------------------------------------

  defp attach_capture(handler_id, events) do
    test_pid = self()

    :telemetry.attach_many(
      handler_id,
      events,
      fn name, measurements, metadata, _ ->
        send(test_pid, {:telemetry_event, name, measurements, metadata})
      end,
      nil
    )
  end
end
