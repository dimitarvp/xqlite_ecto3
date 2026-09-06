defmodule XqliteEcto3.TelemetryErrorReasonLawTest do
  @moduledoc """
  The rule every `:stop` event's `error_reason` obeys, and what a
  handler written to the documented contract may assume.

  A failed callback reports one of three shapes: the error itself, that
  same error inside `{:disconnect, error}` when the connection is going
  away with it, and `{:transaction_status, status}` when the callback
  refused because the connection's transaction status forbade the
  statement. `:telemetry` detaches a handler that raises — from the
  whole VM, taking every other event that handler subscribed to with it
  — so the clause the documentation shows has to accept all three, and
  the `:exception` event, which carries no `error_reason` at all.

  On the OpenTelemetry side each shape has to answer an `error.type`
  that names what failed: the adapter's own typed atom for an error,
  and one constant per status for the status tuple, because "the
  transaction was already started" and "no transaction was started" are
  different failures and a dashboard keyed on the attribute has to keep
  them apart.

  `%XqliteEcto3.Error{type: nil}` is outside the generated domain: it
  is `Error.wrap/1`'s fallback for a reason it does not recognize, must
  never reach an event, and answers a struct name rather than a failure
  name. Its unit pin lives beside the other OpenTelemetry examples.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias XqliteEcto3.Telemetry.OpenTelemetry, as: Otel

  @law_runs 2000

  @error_types [
    :constraint_violation,
    :database_busy_or_locked,
    :sqlite_failure,
    :invalid_transaction_mode,
    :savepoint_without_transaction,
    :savepoint_counter_underflow
  ]

  @statuses %{transaction: "transaction_already_started", idle: "transaction_not_started"}

  property "every documented error_reason shape answers an error.type that names a failure" do
    check all(reason <- error_reason(), max_runs: @law_runs) do
      attributes = Otel.attributes([:xqlite_ecto3, :handle_begin, :stop], %{}, error_stop(reason))

      assert %{"error.type" => type} = attributes
      assert is_binary(type)
      assert type != ""
      assert type == expected_type(reason)
    end
  end

  property "the documented handler clause accepts every shape it can meet" do
    check all(metadata <- stop_or_exception_metadata(), max_runs: @law_runs) do
      assert documented_clause(metadata) in [:ok, :error, :disconnected, :status]
    end
  end

  # What the moduledoc and the guide tell a handler to write: bracket
  # access, so the `:exception` event (which carries no `error_reason`)
  # reaches the catch-all instead of raising `KeyError`.
  defp documented_clause(metadata) do
    case metadata[:error_reason] do
      nil -> :ok
      {:disconnect, _error} -> :disconnected
      {:transaction_status, _status} -> :status
      _error -> :error
    end
  end

  defp expected_type({:transaction_status, status}), do: Map.fetch!(@statuses, status)
  defp expected_type({:disconnect, error}), do: expected_type(error)
  defp expected_type(%XqliteEcto3.Error{type: type}), do: Atom.to_string(type)

  defp error_stop(reason) do
    %{conn: make_ref(), mode: :transaction, result_class: :error, error_reason: reason}
  end

  defp stop_or_exception_metadata do
    StreamData.one_of([
      StreamData.map(error_reason(), &error_stop/1),
      StreamData.constant(%{
        conn: make_ref(),
        mode: :transaction,
        result_class: :ok,
        error_reason: nil
      }),
      StreamData.constant(%{
        conn: make_ref(),
        mode: :transaction,
        kind: :error,
        reason: %ArgumentError{},
        stacktrace: []
      })
    ])
  end

  defp error_reason do
    StreamData.one_of([
      adapter_error(),
      StreamData.map(adapter_error(), fn error -> {:disconnect, error} end),
      StreamData.map(StreamData.member_of(Map.keys(@statuses)), fn status ->
        {:transaction_status, status}
      end)
    ])
  end

  defp adapter_error do
    StreamData.map(StreamData.member_of(@error_types), fn type ->
      %XqliteEcto3.Error{type: type, message: "generated"}
    end)
  end
end
