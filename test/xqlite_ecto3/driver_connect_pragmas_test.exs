defmodule XqliteEcto3.DriverConnectPragmasTest do
  use ExUnit.Case, async: true

  alias XqliteEcto3.Driver
  alias XqliteEcto3.URL
  alias XqliteNIF, as: NIF

  defp tmp_db!(kind) do
    path =
      Path.join(System.tmp_dir!(), "xq_pragmas_#{kind}_#{:erlang.unique_integer([:positive])}.db")

    on_exit(fn ->
      for ext <- ["", "-wal", "-shm", "-journal"], do: File.rm(path <> ext)
    end)

    path
  end

  defp connect!(opts) do
    assert {:ok, state} = Driver.connect(opts)
    on_exit(fn -> NIF.close(state.conn) end)
    state
  end

  defp pragma!(conn, name) do
    assert {:ok, value} = NIF.get_pragma(conn, name)
    value
  end

  describe "config-optional pragmas" do
    test "auto_vacuum, wal_autocheckpoint, and mmap_size apply when given" do
      state =
        connect!(
          database: tmp_db!("opts"),
          auto_vacuum: :full,
          wal_autocheckpoint: 250,
          mmap_size: 1_048_576
        )

      assert pragma!(state.conn, "auto_vacuum") == 1
      assert pragma!(state.conn, "wal_autocheckpoint") == 250
      assert pragma!(state.conn, "mmap_size") == 1_048_576
    end

    test "absent optional pragmas leave SQLite defaults untouched" do
      state = connect!(database: tmp_db!("defaults"))

      assert pragma!(state.conn, "auto_vacuum") == 0
      assert pragma!(state.conn, "wal_autocheckpoint") == 1000
      assert pragma!(state.conn, "mmap_size") == 0
    end
  end

  describe "previously hardcoded pragmas" do
    test "cache_size and foreign_keys honor explicit config" do
      state =
        connect!(database: tmp_db!("explicit"), cache_size: -2_000, foreign_keys: false)

      assert pragma!(state.conn, "cache_size") == -2_000
      assert pragma!(state.conn, "foreign_keys") == 0
    end

    test "cache_size and foreign_keys keep the adapter defaults when absent" do
      state = connect!(database: tmp_db!("adapter_defaults"))

      assert pragma!(state.conn, "cache_size") == -64_000
      assert pragma!(state.conn, "foreign_keys") == 1
    end
  end

  describe "URL round-trip" do
    test "every pragma the URL parser accepts takes effect at connect" do
      path = tmp_db!("url")

      url =
        "sqlite://#{path}?auto_vacuum=incremental&wal_autocheckpoint=0" <>
          "&mmap_size=2097152&cache_size=-2000&foreign_keys=false" <>
          "&journal_mode=truncate&synchronous=full&temp_store=file&busy_timeout=1234"

      assert {:ok, opts} = URL.parse(url)
      state = connect!(opts)

      assert pragma!(state.conn, "auto_vacuum") == 2
      assert pragma!(state.conn, "wal_autocheckpoint") == 0
      assert pragma!(state.conn, "mmap_size") == 2_097_152
      assert pragma!(state.conn, "cache_size") == -2_000
      assert pragma!(state.conn, "foreign_keys") == 0
      assert pragma!(state.conn, "journal_mode") == "truncate"
      assert pragma!(state.conn, "synchronous") == 2
      assert pragma!(state.conn, "temp_store") == 1
      assert pragma!(state.conn, "busy_timeout") == 1234
    end
  end
end
