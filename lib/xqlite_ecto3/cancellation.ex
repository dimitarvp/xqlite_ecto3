defmodule XqliteEcto3.Cancellation do
  @moduledoc false

  alias XqliteNIF, as: NIF

  @ready_timeout_ms 1_000

  @doc """
  Starts a process that cancels `token` once `timeout` milliseconds have
  passed, and returns its pid. Send it `:stop` to disarm it.

  The call it guards runs a dirty NIF, which blocks the calling process
  for its whole duration: a timer this process owns would never fire, so
  the wait has to live in a process of its own. The spawned process
  reports itself before this function returns, so it is scheduled and
  waiting by the time the NIF blocks the caller.
  """
  @spec spawn_canceller(reference(), integer()) :: pid()
  def spawn_canceller(token, timeout) do
    parent = self()
    ref = make_ref()

    spawn(fn ->
      send(parent, {ref, :ready})

      receive do
        :stop -> :ok
      after
        max(timeout, 0) ->
          _ = NIF.cancel_operation(token)
      end
    end)
    |> tap(fn _pid ->
      receive do
        {^ref, :ready} -> :ok
      after
        @ready_timeout_ms -> :ok
      end
    end)
  end
end
