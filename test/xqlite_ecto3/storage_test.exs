defmodule XqliteEcto3.StorageTest do
  use ExUnit.Case, async: true

  @tmp_dir System.tmp_dir!()

  defp unique_db_path do
    Path.join(@tmp_dir, "xqlite_storage_test_#{:erlang.unique_integer([:positive])}.db")
  end

  test "storage_up creates database file" do
    path = unique_db_path()
    on_exit(fn -> File.rm(path) end)

    assert :ok = XqliteEcto3.storage_up(database: path)
    assert File.exists?(path)
  end

  test "storage_up creates intermediate directories" do
    dir = Path.join(@tmp_dir, "xqlite_nested_#{:erlang.unique_integer([:positive])}")
    path = Path.join(dir, "test.db")
    on_exit(fn -> File.rm_rf(dir) end)

    assert :ok = XqliteEcto3.storage_up(database: path)
    assert File.exists?(path)
  end

  test "storage_up returns :already_up when file exists" do
    path = unique_db_path()
    File.write!(path, "")
    on_exit(fn -> File.rm(path) end)

    assert {:error, :already_up} = XqliteEcto3.storage_up(database: path)
  end

  test "storage_down deletes database file" do
    path = unique_db_path()
    File.write!(path, "")

    assert :ok = XqliteEcto3.storage_down(database: path)
    refute File.exists?(path)
  end

  test "storage_down removes WAL and SHM sidecar files" do
    path = unique_db_path()
    File.write!(path, "")
    File.write!(path <> "-wal", "")
    File.write!(path <> "-shm", "")

    assert :ok = XqliteEcto3.storage_down(database: path)
    refute File.exists?(path)
    refute File.exists?(path <> "-wal")
    refute File.exists?(path <> "-shm")
  end

  test "storage_down returns :already_down when file does not exist" do
    path = unique_db_path()
    refute File.exists?(path)

    assert {:error, :already_down} = XqliteEcto3.storage_down(database: path)
  end

  test "storage_status returns :up when file exists" do
    path = unique_db_path()
    File.write!(path, "")
    on_exit(fn -> File.rm(path) end)

    assert :up = XqliteEcto3.storage_status(database: path)
  end

  test "storage_status returns :down when file does not exist" do
    path = unique_db_path()
    refute File.exists?(path)

    assert :down = XqliteEcto3.storage_status(database: path)
  end
end
