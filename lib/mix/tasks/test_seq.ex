defmodule Mix.Tasks.XqliteEcto3.Test.Seq do
  @shortdoc "Run tests sequentially, one file at a time"

  @moduledoc """
  Runs all test files sequentially, each in its own OS process.

  Avoids SQLite's single-writer contention that causes spurious
  "database is locked" errors when test files run in parallel.

  ## Usage

      mix xqlite_ecto3.test.seq
      mix xqlite_ecto3.test.seq --trace
  """

  use Mix.Task

  def run(args) do
    test_files = find_test_files()

    IO.puts("Found #{length(test_files)} test files")
    IO.puts("Running tests sequentially...")

    failed_files = run_test_files(test_files, args, [])

    if failed_files == [] do
      IO.puts("\nAll tests passed!")
    else
      IO.puts("\nFailed files: #{Enum.join(failed_files, ", ")}")
      Mix.raise("#{length(failed_files)} test file(s) failed")
    end
  end

  defp run_test_files([], _args, failed_files), do: failed_files

  defp run_test_files([file | rest], args, failed_files) do
    IO.puts("\n=== Running #{file} ===")

    case System.cmd("mix", ["test", file] ++ args, into: IO.stream()) do
      {_, 0} ->
        run_test_files(rest, args, failed_files)

      {_, exit_code} ->
        IO.puts("FAILED (exit code: #{exit_code})")
        run_test_files(rest, args, [file | failed_files])
    end
  end

  defp find_test_files do
    Path.wildcard("test/**/*_test.exs")
    |> Enum.sort()
  end
end
