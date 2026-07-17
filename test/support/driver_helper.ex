defmodule XqliteEcto3.DriverHelper do
  @moduledoc """
  Helpers for driver-level tests that construct `XqliteEcto3.Driver`
  states directly (no Repo, no pool).
  """

  import ExUnit.Assertions

  alias XqliteEcto3.Driver

  @doc """
  Connects a bare Driver state; the underlying NIF connection is closed
  on test exit. `:database` defaults to `":memory:"` — pass an explicit
  path (e.g. a tmp file) to override.
  """
  def connect!(opts \\ []) do
    assert {:ok, state} = Driver.connect(Keyword.put_new(opts, :database, ":memory:"))
    ExUnit.Callbacks.on_exit(fn -> XqliteNIF.close(state.conn) end)
    state
  end
end
