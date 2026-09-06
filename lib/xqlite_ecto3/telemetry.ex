defmodule XqliteEcto3.Telemetry do
  @moduledoc """
  `:telemetry` integration for the xqlite_ecto3 Ecto adapter.

  > #### Strictly opt-in {: .info}
  >
  > Compile-time flag, default `false`. Enable via:
  >
  > ```elixir
  > config :xqlite_ecto3, :telemetry_enabled, true
  > ```
  >
  > Mirrors the underlying `:xqlite, :telemetry_enabled` flag — both
  > must be enabled for full coverage. The xqlite-level events
  > (`[:xqlite, :*]`) are gated by xqlite's flag; the adapter-level
  > events (`[:xqlite_ecto3, :*]`) are gated here.

  ## Event surface

  Every time-valued measurement is an integer nanosecond count, from
  `System.monotonic_time(:nanosecond)` and `System.system_time(:nanosecond)`.
  That holds for the adapter's own single events (`:disconnect`,
  `:checkout` and the statement-cache events) and for span events alike:
  `:start` measures `%{monotonic_time, system_time}` (no `duration`);
  `:stop` and `:exception` measure `%{monotonic_time, duration}`. The
  spans are run by `run_span/3` here rather than by `:telemetry.span/3`
  for that reason alone — `:telemetry` reads the clock without a unit,
  which gives the runtime's native unit, a nanosecond on Linux and
  something else elsewhere, with nothing in the event to say which.

  Every span event's metadata also carries `telemetry_span_context`, the
  reference that pairs a `:start` with its `:stop`. The blocks below list
  the adapter's own metadata keys; where a block groups
  `:start | :stop | :exception`, its measurements line describes the
  `:stop`/`:exception` shape.

  ### The :exception phase carries other metadata

  The metadata listed per event below is what `:start` and `:stop` carry.
  An `:exception` event carries the `:start` metadata plus `kind`,
  `reason` and `stacktrace` — and NOT `result_class` or `error_reason`,
  which the adapter computes from a callback's return value and a raising
  callback never produced.

  `:telemetry` detaches any handler that raises, so a handler whose head
  binds `%{result_class: class}` is removed from the whole VM the first
  time an exception event reaches it — silently, taking every other event
  it subscribed to with it. Give handler functions a catch-all clause.
  The phase is not theoretical: anything that raises inside a span's body
  (connect included) emits it, so a handler must tolerate it from any
  span.

  ### Connection lifecycle

      [:xqlite_ecto3, :connect, :start | :stop | :exception]
        measurements: %{monotonic_time, duration}
        metadata:     %{database, result_class, error_reason}

      [:xqlite_ecto3, :disconnect]
        measurements: %{monotonic_time}
        metadata:     %{conn, reason}

  `:disconnect` fires when DBConnection tears a connection down after an
  operation error or a failed ping. A graceful pool or application
  shutdown does NOT emit it (the connection process exits before its
  terminate callback runs), so connect and disconnect counts are not a
  balanced pair.

      [:xqlite_ecto3, :checkout]
        measurements: %{monotonic_time}
        metadata:     %{conn}

  `:checkout` fires ONCE per connection, right after DBConnection opens
  it — not once per pool checkout. DBConnection calls the driver's
  checkout callback a single time, when the connection is established, so
  this event counts connections opened, not queries served.

  ### Transaction lifecycle (DBConnection callbacks)

      [:xqlite_ecto3, :handle_begin, :start | :stop | :exception]
      [:xqlite_ecto3, :handle_commit, :start | :stop | :exception]
      [:xqlite_ecto3, :handle_rollback, :start | :stop | :exception]
        measurements: %{monotonic_time, duration}
        metadata:     %{conn, mode, result_class, error_reason}

  ### Query / cursor lifecycle (DBConnection callbacks)

      [:xqlite_ecto3, :handle_execute, :start | :stop | :exception]
      [:xqlite_ecto3, :handle_declare, :start | :stop | :exception]
        measurements: %{monotonic_time, duration}
        metadata:     %{conn, query, sql, result_class, error_reason}

      [:xqlite_ecto3, :handle_fetch, :start | :stop | :exception]
      [:xqlite_ecto3, :handle_deallocate, :start | :stop | :exception]
        measurements: %{monotonic_time, duration}
        metadata:     %{conn, cursor, result_class, error_reason}

  ### Three shapes of error_reason

  `error_reason` is normally the error the callback returned. When the
  callback also told DBConnection to drop the connection — a statement
  error that took the whole transaction with it, a failed COMMIT — it is
  `{:disconnect, error}` instead: the same error, plus the fact that the
  connection is going away.

  The third shape is `{:transaction_status, status}`: the callback ran
  no statement because the connection's transaction status forbids it.
  `handle_begin` answers `:transaction` when a transaction is already
  open, and `handle_rollback` answers `:idle` when the caller's own raw
  `COMMIT`, `END` or `ROLLBACK` already ended the one it was asked to
  roll back. DBConnection turns either into a
  `DBConnection.TransactionError` carrying the same status and drops
  the connection, so the paired `:disconnect` event is where that error
  shows up — there is no stop event with `{:disconnect, _}` for it.
  A third status, `:error`, is admitted by the classifier and answered
  by no callback.

  Match all three, and end the handler in a clause that takes anything:

      def handle_event(_event, _measurements, metadata, _config) do
        case metadata[:error_reason] do
          nil -> :ok
          {:disconnect, error} -> record_disconnect(error)
          {:transaction_status, status} -> record_status(status)
          error -> record_error(error)
        end
      end

  Read the field as `metadata[:error_reason]`, never
  `metadata.error_reason`: the `:exception` event carries no such key,
  and the `KeyError` that follows detaches the handler from the whole
  VM. `XqliteEcto3.Telemetry.OpenTelemetry` looks inside the disconnect
  tuple, so `error.type` names the error either way, and gives the
  status tuple one name per status.

  ### Error-path diagnostics

      [:xqlite_ecto3, :fk_diagnostics, :start | :stop | :exception]
        measurements: %{monotonic_time, duration}
        metadata:     %{conn, mode}; on :stop also
                      %{violations_count, violations_total,
                        diagnostics_status}

  `diagnostics_status` is `:ok`, `:truncated` (more violations existed
  than the cap materializes — `violations_count` is the rows carried,
  `violations_total` the real number), or `:unavailable` (the diagnosis
  failed; the original error is surfaced regardless).
  Fires only when `rich_fk_diagnostics: true` and a foreign-key
  violation triggered the replay, and not at all when
  `diagnostics_budget_ms` is `0` or when the failed statement's own
  timeout has less left than the allowance would spend.

      [:xqlite_ecto3, :unique_index_names, :start | :stop | :exception]
        measurements: %{monotonic_time, duration}
        metadata:     %{conn, table, columns}; on :stop also
                      %{candidate_count, index_reads, lookup_status}

  `candidate_count` is how many unique indexes covered the violated
  columns, and `index_reads` how many PRAGMA reads the lookup made
  before it stopped.

  `lookup_status` is `:ok` (the candidates were read), `:ambiguous`
  (several unique indexes could have caused the violation and SQLite
  does not say which) or `:unavailable` (a read failed, the table
  carried more unique indexes than the cap allows, the allowance ran
  out, or the failed statement's own deadline was already inside the
  reserve the lookup leaves).

  The span covers both forms a UNIQUE violation message takes. On the
  form naming only a table and columns, `table` and `columns` are the
  parsed ones on both events. On the form naming the index instead,
  `:start` carries `table: nil` and `columns: []` — the message holds
  neither — and `:stop` carries what the lookup read back, so a
  subscriber grouping by table keeps those rows. It does not fire when
  `diagnostics_budget_ms` is `0`, nor when the statement's deadline is
  inside the reserve.

  ### Statement cache

      [:xqlite_ecto3, :statement_cache, :hit | :miss]
        measurements: %{monotonic_time, cached_count}
        metadata:     %{conn, sql}

      [:xqlite_ecto3, :statement_cache, :evicted]
        measurements: %{monotonic_time, cached_count}
        metadata:     %{conn, sql}

  `:miss` fires whenever the statement is absent from the cache —
  including statements that then fall back to the uncached path
  (multi-statement SQL). `:evicted` names the LRU statement removed
  to make room; `cached_count` is the size BEFORE the event's action.
  The cache is PER CONNECTION (`conn` is the discriminator): each
  pooled connection misses once per distinct statement, and a
  pool-wide `cached_count` series interleaves `pool_size` independent
  counters.

  ## Composing with Ecto's own telemetry

  Ecto already emits `[my_app, :repo, :query]` for every query through a
  Repo. The xqlite_ecto3 events fire ALSO, at the lower DBConnection
  callback layer. Subscribers who want only the high-level Ecto event
  attach to that; subscribers who want adapter-internal timing (e.g.,
  decode time, connect attempts) attach to the `[:xqlite_ecto3, :*]`
  events.

  ## See also

  `Xqlite.Telemetry` for the underlying xqlite library events,
  including hooks (`[:xqlite, :hook, :*]`), cancellation
  (`[:xqlite, :cancel, :*]`), and the operation surface
  (`[:xqlite, :query, :*]` etc.).
  """

  @enabled Application.compile_env(:xqlite_ecto3, :telemetry_enabled, false)

  @doc """
  Returns whether telemetry is compiled in for the adapter.

  Reads the `:telemetry_enabled` flag at compile time. Constant
  after compilation; safe anywhere.
  """
  @spec enabled?() :: boolean()
  def enabled?, do: unquote(@enabled)

  if @enabled do
    @doc """
    Emit a single telemetry event. Wraps `:telemetry.execute/3`. No-op
    when telemetry is compiled out.
    """
    defmacro emit(event_name, measurements, metadata) do
      quote do
        :telemetry.execute(
          unquote(event_name),
          unquote(measurements),
          unquote(metadata)
        )
      end
    end

    @doc """
    Run `block` inside a span: a `:start` event, then a `:stop` one.

    The block returns `{value, stop_metadata}` or `{value,
    extra_measurements, stop_metadata}`, so the `:stop` event can carry
    numbers and metadata that were not known at `:start`; `value` is
    what the macro returns. The stop metadata replaces the start
    metadata, and the extra measurements are merged under `duration`
    and `monotonic_time`. If the block raises, throws or exits, an
    `:exception` event fires instead of `:stop`, with `kind`, `reason`
    and `stacktrace` added to the metadata, and the exception re-raises
    unchanged.
    """
    defmacro span_with_stop_metadata(event_name, start_metadata, do: block) do
      quote do
        XqliteEcto3.Telemetry.run_span(unquote(event_name), unquote(start_metadata), fn ->
          unquote(block)
        end)
      end
    end

    @doc false
    @spec run_span([atom()], map(), (-> term())) :: term()
    def run_span(event_name, start_metadata, block) do
      context = make_ref()
      metadata = with_span_context(start_metadata, context)
      start_time = monotonic_time()

      :telemetry.execute(
        event_name ++ [:start],
        %{monotonic_time: start_time, system_time: System.system_time(:nanosecond)},
        metadata
      )

      # The one try/catch the adapter keeps: it turns the caller's own
      # exception into an `:exception` event and re-raises it untouched.
      try do
        block.()
      catch
        kind, reason ->
          stacktrace = __STACKTRACE__
          stop_time = monotonic_time()

          :telemetry.execute(
            event_name ++ [:exception],
            %{duration: stop_time - start_time, monotonic_time: stop_time},
            Map.merge(metadata, %{kind: kind, reason: reason, stacktrace: stacktrace})
          )

          :erlang.raise(kind, reason, stacktrace)
      else
        outcome -> emit_stop(event_name, start_time, context, outcome)
      end
    end

    defp emit_stop(event_name, start_time, context, {result, stop_metadata}) do
      stop_time = monotonic_time()

      :telemetry.execute(
        event_name ++ [:stop],
        %{duration: stop_time - start_time, monotonic_time: stop_time},
        with_span_context(stop_metadata, context)
      )

      result
    end

    defp emit_stop(event_name, start_time, context, {result, extra, stop_metadata}) do
      stop_time = monotonic_time()

      :telemetry.execute(
        event_name ++ [:stop],
        Map.merge(extra, %{duration: stop_time - start_time, monotonic_time: stop_time}),
        with_span_context(stop_metadata, context)
      )

      result
    end

    defp with_span_context(%{telemetry_span_context: _} = metadata, _context), do: metadata

    defp with_span_context(metadata, context),
      do: Map.put(metadata, :telemetry_span_context, context)
  else
    @doc false
    defmacro emit(event_name, measurements, metadata) do
      quote do
        _ = unquote(event_name)
        _ = unquote(measurements)
        _ = unquote(metadata)
        :ok
      end
    end

    @doc false
    defmacro span_with_stop_metadata(event_name, start_metadata, do: block) do
      quote do
        _ = unquote(event_name)
        _ = unquote(start_metadata)
        unquote(__MODULE__).span_block_value(unquote(block))
      end
    end

    # Unwrapping in a function rather than in a `case` inside the macro:
    # the compiler knows each call site's block shape exactly, so an
    # inlined `case` over both shapes leaves one clause provably dead
    # there — a warning, and warnings are errors here.
    @doc false
    @spec span_block_value(term()) :: term()
    def span_block_value({value, _extra_measurements, _stop_metadata}), do: value
    def span_block_value({value, _stop_metadata}), do: value
  end

  @doc """
  Returns the current monotonic time in nanoseconds.
  Convenience wrapper for use in measurement maps.
  """
  @spec monotonic_time() :: integer()
  def monotonic_time, do: System.monotonic_time(:nanosecond)
end
