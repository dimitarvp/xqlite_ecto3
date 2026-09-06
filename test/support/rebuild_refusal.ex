defmodule XqliteEcto3.RebuildRefusal do
  @moduledoc """
  Assertion helper for the table rebuild's pre-flight refusals.

  Every refusal raises `XqliteEcto3.RebuildRefusedError` naming the check
  that refused in its `reason` field. `assert_refused/2` runs the migration
  step, asserts that reason, and hands the exception back so a test can go
  on to the fields carrying the rest of the refusal.
  """

  import ExUnit.Assertions

  alias XqliteEcto3.RebuildRefusedError

  @spec assert_refused(atom(), (-> any())) :: RebuildRefusedError.t()
  def assert_refused(reason, fun) do
    error = assert_raise(RebuildRefusedError, fun)
    assert error.reason == reason
    error
  end
end
