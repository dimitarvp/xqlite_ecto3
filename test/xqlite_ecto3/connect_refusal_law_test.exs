defmodule XqliteEcto3.ConnectRefusalLawTest do
  @moduledoc """
  The rule every connect-time refusal has to obey: it names the repo
  configuration key it refused and the value it was given.

  A connect error that says only `wal` leaves the reader guessing which
  setting was wrong and what about it was wrong. So each validator refuses
  with the key and the value together, and `XqliteEcto3.Error.wrap/1` turns
  that into `details: %{key: key, value: value}` under the tag that says
  which check refused.

  The domain is hostile on purpose: every key meets integers, floats,
  strings — including the string spelling of a value that would be valid as
  an atom — booleans and atoms from a neighbouring setting, filtered down to
  the values that key really refuses.
  """
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias XqliteEcto3.Driver

  @law_runs 2000

  @journal_modes [:delete, :truncate, :persist, :memory, :wal, :off]
  @synchronous_levels [:off, :normal, :full, :extra]
  @temp_stores [:default, :file, :memory]
  @auto_vacuum_modes [:none, :full, :incremental]
  @transaction_modes [:deferred, :immediate, :exclusive]
  @int32_max 2_147_483_647

  # Atoms that read like a setting but belong to another one, or to nothing.
  @stray_atoms [:nope, :Wal, :WAL, :yes, :no, :infinity, :on, :off, :none, :full, :memory]

  # Floats as a fixed set: StreamData's float/0 costs time quadratic in the
  # size parameter, and three awkward values cover the same ground here.
  @stray_floats [1.5, -0.5, 2.5e9]

  describe "every rejected configuration value carries its key and value" do
    property "over generated values no validator accepts" do
      check all({key, tag, value} <- rejected_option(), max_runs: @law_runs) do
        assert {:error, %XqliteEcto3.Error{type: ^tag, details: details}} =
                 Driver.connect([{:database, ":memory:"}, {key, value}])

        assert details == %{key: key, value: value}
      end
    end

    test "a journal mode spelled as a string names the key, not just the value" do
      assert {:error, %XqliteEcto3.Error{type: :invalid_journal_mode, details: details}} =
               Driver.connect(database: ":memory:", journal_mode: "wal")

      assert details == %{key: :journal_mode, value: "wal"}
    end

    test "a transaction mode in the connection-mode key keeps its own tag" do
      assert {:error,
              %XqliteEcto3.Error{type: :transaction_mode_as_connection_mode, details: details}} =
               Driver.connect(database: ":memory:", mode: :immediate)

      assert details == %{key: :mode, value: :immediate}
    end
  end

  describe "hook refusals carry the option or the entry that was refused" do
    property "a refused progress option names that option and its value" do
      check all({key, value} <- rejected_progress_option(), max_runs: @law_runs) do
        assert {:error, %XqliteEcto3.Error{type: :invalid_hook_option, details: details}} =
                 Driver.connect(
                   database: ":memory:",
                   hooks: [progress: {:xq_connect_law_listener, [{key, value}]}]
                 )

        assert details == %{key: key, value: value}
      end
    end

    test "a hooks value that is not a list names the hooks key" do
      assert {:error, %XqliteEcto3.Error{type: :invalid_hooks_config, details: details}} =
               Driver.connect(database: ":memory:", hooks: :update)

      assert details == %{key: :hooks, value: :update}
    end

    test "an unknown hook kind names the hooks key and the entry" do
      assert {:error, %XqliteEcto3.Error{type: :invalid_hook_config, details: details}} =
               Driver.connect(database: ":memory:", hooks: [frobnicate: :some_listener])

      assert details == %{key: :hooks, value: {:frobnicate, :some_listener}}
    end

    test "progress options that are not a keyword list name the hooks key" do
      assert {:error, %XqliteEcto3.Error{type: :invalid_hook_config, details: details}} =
               Driver.connect(
                 database: ":memory:",
                 hooks: [progress: {:xq_connect_law_listener, [1, 2, 3]}]
               )

      assert details == %{key: :hooks, value: {:progress, [1, 2, 3]}}
    end

    test "a subscriber name nobody registered names the hooks key and the name" do
      assert {:error, %XqliteEcto3.Error{type: :hook_subscriber_not_registered, details: details}} =
               Driver.connect(database: ":memory:", hooks: [update: :xq_connect_law_absentee])

      assert details == %{key: :hooks, value: :xq_connect_law_absentee}
    end
  end

  # Each entry is a key, the tag its refusal carries, and the test for a
  # value that key accepts — everything else is a refusal this law covers.
  defp validated_options do
    [
      {:mode, :invalid_connection_mode,
       &(&1 in [:readwrite, :readonly] or &1 in [:transaction, :savepoint | @transaction_modes]),
       [:readwrite, :readonly]},
      {:default_transaction_mode, :invalid_default_transaction_mode, &(&1 in @transaction_modes),
       @transaction_modes},
      {:statement_cache_size, :invalid_statement_cache_size, &(is_integer(&1) and &1 >= 0), []},
      {:busy_timeout, :invalid_busy_timeout, &(is_integer(&1) and &1 >= 0 and &1 <= @int32_max),
       []},
      {:journal_mode, :invalid_journal_mode, &(&1 in @journal_modes), @journal_modes},
      {:synchronous, :invalid_synchronous, &(&1 in @synchronous_levels), @synchronous_levels},
      {:temp_store, :invalid_temp_store, &(&1 in @temp_stores), @temp_stores},
      {:foreign_keys, :invalid_foreign_keys, &is_boolean/1, [true, false]},
      {:cache_size, :invalid_cache_size, &is_integer/1, []},
      {:auto_vacuum, :invalid_auto_vacuum, &(is_nil(&1) or &1 in @auto_vacuum_modes),
       @auto_vacuum_modes},
      {:wal_autocheckpoint, :invalid_wal_autocheckpoint,
       &(is_nil(&1) or (is_integer(&1) and &1 >= 0)), []},
      {:mmap_size, :invalid_mmap_size, &(is_nil(&1) or (is_integer(&1) and &1 >= 0)), []},
      {:rich_fk_diagnostics, :invalid_rich_fk_diagnostics, &is_boolean/1, [true, false]},
      {:diagnostics_budget_ms, :invalid_diagnostics_budget_ms, &(is_integer(&1) and &1 >= 0), []}
    ]
  end

  defp rejected_option do
    gen all(
          {key, tag, accepted?, spellable} <- StreamData.member_of(validated_options()),
          value <- refused_value(accepted?, spellable)
        ) do
      {key, tag, value}
    end
  end

  # The string spellings of the values the key would accept as atoms are in
  # the domain deliberately: that spelling used to be reported as a message
  # with no key beside it.
  defp refused_value(accepted?, spellable) do
    [
      StreamData.integer(),
      StreamData.member_of(@stray_floats),
      StreamData.string(:ascii, max_length: 8),
      StreamData.member_of(@stray_atoms),
      StreamData.boolean(),
      StreamData.member_of([nil | Enum.map(spellable, &to_string/1)])
    ]
    |> StreamData.one_of()
    |> StreamData.filter(fn value -> not accepted?.(value) end, 100)
  end

  defp rejected_progress_option do
    StreamData.one_of([
      StreamData.map(refused_every_n(), fn value -> {:every_n, value} end),
      StreamData.map(refused_tag(), fn value -> {:tag, value} end),
      unknown_progress_option()
    ])
  end

  defp unknown_progress_option do
    gen all(
          key <- StreamData.member_of([:bogus, :everyn, :Tag, :interval]),
          value <- StreamData.integer()
        ) do
      {key, value}
    end
  end

  defp refused_every_n do
    [
      StreamData.integer(-50..0),
      StreamData.member_of(@stray_floats),
      StreamData.string(:ascii, max_length: 8),
      StreamData.member_of([nil, :many, true, false])
    ]
    |> StreamData.one_of()
  end

  defp refused_tag do
    [
      StreamData.integer(),
      StreamData.member_of(@stray_floats),
      StreamData.string(:ascii, max_length: 8)
    ]
    |> StreamData.one_of()
  end
end
