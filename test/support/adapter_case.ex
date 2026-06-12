defmodule XqliteEcto3.AdapterCase do
  @moduledoc """
  Case template for adapter tests that talk to the shared sandboxed
  `Ecto.Integration.TestRepo`.

  `use XqliteEcto3.AdapterCase, async: true` gives a test module:

    * ExUnit with the given options;
    * the repo under both customary names — `Repo` and `TestRepo`;
    * `Ecto.Query` and `XqliteEcto3.TableHelper` imports;
    * a sandbox checkout before every test.

  Module-specific setup (table seeding, `clear_table!/1`, extra
  imports such as `Ecto.Changeset`) stays in the test module; setups
  declared here run first, so module setups can rely on the checkout
  having happened.

  Tests that do not go through the sandboxed TestRepo (raw
  `DBConnection` driver tests, pure SQL-generation tests) keep using
  `ExUnit.Case` directly.
  """

  use ExUnit.CaseTemplate

  using do
    quote do
      alias Ecto.Integration.TestRepo, warn: false
      alias Ecto.Integration.TestRepo, as: Repo, warn: false

      import Ecto.Query, warn: false
      import XqliteEcto3.TableHelper, warn: false
    end
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Ecto.Integration.TestRepo)
    :ok
  end
end
