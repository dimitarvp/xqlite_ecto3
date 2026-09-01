defmodule XqliteEcto3.ExclusionArtifactsTest do
  @moduledoc """
  The vendored-suite exclusion artifacts must stay honest.

  Three mechanical checks over `test/test_helper.exs`,
  `test/ecto3_integration/all_test.exs`, and `ECTO_INTEGRATION_TAGS.md`:
  every exclusion tag and location tuple has a doc row and vice versa
  (both directions), every location tuple names a `test` line (an ExUnit
  line filter snaps to the nearest test at or before the line, so a
  `@tag`-line pointer silently runs the wrong test), and both whole-file
  skips have doc rows.

  Beside them, two live probes for exclusions the suite can never run:
  the shared migration's durations table builds without complaint (the
  `:duration_type` blocker is the adapter's encoder, not the DDL), and a
  query with `lock:` set refuses up front (the `lock.exs` skip's
  adapter half).
  """
  use XqliteEcto3.AdapterCase, async: true

  @repo_root Path.expand("../..", __DIR__)

  defp helper, do: read_normalized("test/test_helper.exs")
  defp tags_doc, do: read_normalized("ECTO_INTEGRATION_TAGS.md")
  defp all_test, do: read_normalized("test/ecto3_integration/all_test.exs")

  # Windows checkouts arrive with CRLF endings; the anchors here match
  # against \n.
  defp read_normalized(path) do
    @repo_root |> Path.join(path) |> File.read!() |> String.replace("\r\n", "\n")
  end

  defp helper_excludes_body do
    [_, body] = Regex.run(~r/excludes = \[(.*?)\n\]\n/s, helper())
    body
  end

  test "every exclusion tag has a doc row marked excluded, and vice versa" do
    helper_tags =
      ~r/^  :([a-z_]+),?$/m
      |> Regex.scan(helper_excludes_body())
      |> Enum.map(fn [_, t] -> t end)
      |> Enum.sort()

    doc_excluded =
      ~r/^\| `:([a-z_]+)` \| ([^|]*?) \|/m
      |> Regex.scan(tags_doc())
      |> Enum.filter(fn [_, _, status] ->
        status |> String.trim() |> String.starts_with?("excluded")
      end)
      |> Enum.map(fn [_, t, _] -> t end)
      |> Enum.sort()

    assert helper_tags -- doc_excluded == []
    assert doc_excluded -- helper_tags == []
  end

  test "every location tuple has a doc row, and every pointer names a test line" do
    helper_locs =
      ~r/\{:location, \{"([^"]+)", (\d+)\}\}/
      |> Regex.scan(helper_excludes_body())
      |> Enum.map(fn [_, f, l] -> {f, String.to_integer(l)} end)

    doc_locs =
      ~r/^\| `(?:ecto|ecto_sql) \.\.\.\/([a-z_]+\/[a-z_]+\.exs):(\d+)` \|/m
      |> Regex.scan(tags_doc())
      |> Enum.map(fn [_, f, l] -> {f, String.to_integer(l)} end)
      |> Enum.sort()

    helper_short =
      helper_locs
      |> Enum.map(fn {f, l} -> {f |> String.split("/") |> Enum.take(-2) |> Enum.join("/"), l} end)
      |> Enum.sort()

    assert helper_short -- doc_locs == []
    assert doc_locs -- helper_short == []

    for {file, line} <- helper_locs do
      pointed =
        @repo_root |> Path.join(file) |> File.read!() |> String.split("\n") |> Enum.at(line - 1)

      assert Regex.match?(~r/^\s*test[ (]/, pointed),
             "location pointer #{file}:#{line} does not name a test line"
    end
  end

  test "both whole-file skips have doc rows" do
    skipped =
      ~r/^# ([a-z_]+\.exs)\s/m
      |> Regex.scan(all_test())
      |> Enum.map(fn [_, f] -> f end)
      |> Enum.uniq()

    assert Enum.sort(skipped) == ["lock.exs", "query_many.exs"]

    for file <- skipped do
      assert tags_doc() =~ "sql/#{file}`",
             "whole-file skip #{file} has no row in ECTO_INTEGRATION_TAGS.md"
    end
  end

  defmodule DurationMigration do
    use Ecto.Migration

    def up do
      create table(:excl_durations) do
        add(:dur, :duration)
        add(:dur_with_default, :duration, default: "10 MONTH")
      end
    end

    def down do
      drop(table(:excl_durations))
    end
  end

  test "the shared migration's durations shape builds; the blocker is the encoder" do
    assert :ok = Ecto.Migrator.up(Repo, 20_260_901_001, DurationMigration, log: false)

    assert_raise XqliteEcto3.UnencodableParameterError, fn ->
      Repo.query!("INSERT INTO excl_durations (id, dur) VALUES (1, ?1)", [
        Duration.new!(month: 13)
      ])
    end

    assert :ok = Ecto.Migrator.down(Repo, 20_260_901_001, DurationMigration, log: false)
  end

  defmodule LockCounter do
    use Ecto.Schema

    schema "lock_counters" do
      field(:count, :integer)
    end
  end

  test "a query with lock: set refuses up front" do
    q = %{Ecto.Query.from(lc in LockCounter, where: lc.id == 1) | lock: "FOR UPDATE"}

    assert_raise ArgumentError, fn -> Repo.all(q) end
  end
end
