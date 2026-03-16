defmodule XqliteEcto3.DataCase do
  use ExUnit.CaseTemplate

  using do
    quote do
      alias XqliteEcto3.TestRepo, as: Repo
      import Ecto.Query
      import Ecto.Changeset
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(XqliteEcto3.TestRepo)
    :ok
  end
end
