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
      # The URL string stays platform-neutral: Windows absolute paths
      # (C:\...) are not expressible in the sqlite:// grammar, so the
      # real tmp path is swapped into the parsed opts instead
      # (CLAUDE.md gotcha 15).
      url =
        "sqlite:///ignored.db?auto_vacuum=incremental&wal_autocheckpoint=0" <>
          "&mmap_size=2097152&cache_size=-2000&foreign_keys=false" <>
          "&journal_mode=truncate&synchronous=full&temp_store=file&busy_timeout=1234"

      assert {:ok, parsed} = URL.parse(url)
      opts = Keyword.put(parsed, :database, tmp_db!("url"))
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

  describe "custom_pragmas" do
    test "apply after the defaults, so explicit config wins" do
      state =
        connect!(
          database: tmp_db!("custom"),
          custom_pragmas: [{:journal_mode, "truncate"}, {"cache_size", -2_000}]
        )

      assert pragma!(state.conn, "journal_mode") == "truncate"
      assert pragma!(state.conn, "cache_size") == -2_000
    end

    test "malformed entry is a structured connect error" do
      assert {:error, {:invalid_custom_pragma, :oops}} =
               Driver.connect(database: tmp_db!("bad_entry"), custom_pragmas: [:oops])
    end

    test "non-list value is a structured connect error" do
      assert {:error, {:invalid_custom_pragmas, :nope}} =
               Driver.connect(database: tmp_db!("bad_shape"), custom_pragmas: :nope)
    end

    test "an invalid pragma name surfaces the NIF's structured error" do
      assert {:error, {:invalid_pragma_name, _}} =
               Driver.connect(database: tmp_db!("bad_name"), custom_pragmas: [{"no;pe", 1}])
    end
  end

  describe "mode: :readonly" do
    test "reads work, writes fail structurally, write-pragmas are skipped" do
      path = tmp_db!("ro")

      rw = connect!(database: path)
      {:ok, _} = NIF.execute(rw.conn, "CREATE TABLE t(x INTEGER)", [])
      {:ok, 1} = NIF.execute(rw.conn, "INSERT INTO t(x) VALUES (7)", [])
      :ok = NIF.close(rw.conn)

      # auto_vacuum given but silently skipped in readonly mode — the connect
      # must succeed rather than fail on a write-requiring pragma.
      state = connect!(database: path, mode: :readonly, auto_vacuum: :full)

      assert {:ok, %{rows: [[7]]}} = NIF.query(state.conn, "SELECT x FROM t", [])

      assert {:error, {:read_only_database, _}} =
               NIF.execute(state.conn, "INSERT INTO t(x) VALUES (8)", [])

      assert pragma!(state.conn, "journal_mode") == "wal"
    end

    test "invalid mode is a structured connect error" do
      assert {:error, {:invalid_connection_mode, :turbo}} =
               Driver.connect(database: tmp_db!("badmode"), mode: :turbo)
    end
  end
end
