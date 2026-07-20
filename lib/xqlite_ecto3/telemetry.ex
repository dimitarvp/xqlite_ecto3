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

  All time measurements are in nanoseconds via
  `System.monotonic_time(:nanosecond)`.

  ### Connection lifecycle

      [:xqlite_ecto3, :connect, :start | :stop | :exception]
        measurements: %{monotonic_time, duration}
        metadata:     %{database, result_class, error_reason}

      [:xqlite_ecto3, :disconnect]
        measurements: %{monotonic_time}
        metadata:     %{conn, reason}

      [:xqlite_ecto3, :checkout]
        measurements: %{monotonic_time}
        metadata:     %{conn}

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

  ### Statement cache

      [:xqlite_ecto3, :statement_cache, :hit | :miss]
        measurements: %{monotonic_time, cached_count}
        metadata:     %{sql}

      [:xqlite_ecto3, :statement_cache, :evicted]
        measurements: %{monotonic_time, cached_count}
        metadata:     %{sql}

  `:miss` fires whenever the statement is absent from the cache —
  including statements that then fall back to the uncached path
  (multi-statement SQL). `:evicted` names the LRU statement removed
  to make room; `cached_count` is the size BEFORE the event's action.

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
    Run `block` inside a `:telemetry.span/3`. The block must evaluate
    to a value; that value is returned. The block can also return
    `{value, extra_stop_metadata}` to enrich `:stop` metadata.
    """
    defmacro span_with_stop_metadata(event_name, start_metadata, do: block) do
      quote do
        :telemetry.span(unquote(event_name), unquote(start_metadata), fn ->
          unquote(block)
        end)
      end
    end
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

        case unquote(block) do
          {value, _stop_metadata} -> value
        end
      end
    end
  end

  @doc """
  Returns the current monotonic time in nanoseconds.
  Convenience wrapper for use in measurement maps.
  """
  @spec monotonic_time() :: integer()
  def monotonic_time, do: System.monotonic_time(:nanosecond)
end
