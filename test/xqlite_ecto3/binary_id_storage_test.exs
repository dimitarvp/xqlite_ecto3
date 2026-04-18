defmodule XqliteEcto3.BinaryIdStorageTest do
  # async: false — these tests mutate Application env, save/restore in setup.
  use ExUnit.Case, async: false

  alias Ecto.Integration.TestRepo
  alias XqliteEcto3.DataType

  @uuid_string "550e8400-e29b-41d4-a716-446655440000"
  # 550e8400-e29b-41d4-a716-446655440000 as raw 16 bytes
  @uuid_raw <<0x55, 0x0E, 0x84, 0x00, 0xE2, 0x9B, 0x41, 0xD4, 0xA7, 0x16, 0x44, 0x66, 0x55, 0x44,
              0x00, 0x00>>

  setup do
    # Tests within this file run serially (async: false), so we can mutate
    # the global env inside each test without cross-test contamination. We
    # snapshot + restore so the rest of the suite stays unaffected.
    prior = Application.get_env(:xqlite_ecto3, :binary_id_storage)

    on_exit(fn ->
      if is_nil(prior) do
        Application.delete_env(:xqlite_ecto3, :binary_id_storage)
      else
        Application.put_env(:xqlite_ecto3, :binary_id_storage, prior)
      end
    end)

    :ok
  end

  describe "DataType.column_type/2 with :binary_id_storage config" do
    test ":binary_id and :uuid map to TEXT when :string (default)" do
      Application.put_env(:xqlite_ecto3, :binary_id_storage, :string)
      assert DataType.column_type(:binary_id, []) == "TEXT"
      assert DataType.column_type(:uuid, []) == "TEXT"
    end

    test ":binary_id and :uuid map to BLOB when :binary" do
      Application.put_env(:xqlite_ecto3, :binary_id_storage, :binary)
      assert DataType.column_type(:binary_id, []) == "BLOB"
      assert DataType.column_type(:uuid, []) == "BLOB"
    end

    test "config absent → TEXT" do
      Application.delete_env(:xqlite_ecto3, :binary_id_storage)
      assert DataType.column_type(:binary_id, []) == "TEXT"
      assert DataType.column_type(:uuid, []) == "TEXT"
    end
  end

  describe "adapter dumper chain for :binary_id" do
    test "with :string config, outputs 36-char string form" do
      Application.put_env(:xqlite_ecto3, :binary_id_storage, :string)
      [_type, fun] = XqliteEcto3.dumpers(:binary_id, Ecto.UUID)
      # Input is what Ecto.UUID.dump already produced: raw 16 bytes.
      assert fun.(@uuid_raw) == {:ok, @uuid_string}
      assert fun.(nil) == {:ok, nil}
    end

    test "with :binary config, keeps raw 16 bytes" do
      Application.put_env(:xqlite_ecto3, :binary_id_storage, :binary)
      [_type, fun] = XqliteEcto3.dumpers(:binary_id, Ecto.UUID)
      assert fun.(@uuid_raw) == {:ok, @uuid_raw}
      assert fun.(nil) == {:ok, nil}
    end

    test "fallthrough for unexpected shapes does NOT raise or :error" do
      Application.put_env(:xqlite_ecto3, :binary_id_storage, :string)
      [_type, fun] = XqliteEcto3.dumpers(:binary_id, Ecto.UUID)
      # Pass-through behavior: Ecto's process_dumpers halts on :error, so
      # unknown shapes must pass cleanly.
      assert fun.("something-unexpected") == {:ok, "something-unexpected"}
      assert fun.(123) == {:ok, 123}
    end
  end

  describe "round-trip via TestRepo with :string storage" do
    setup do
      Application.put_env(:xqlite_ecto3, :binary_id_storage, :string)
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
      TestRepo.query!("CREATE TEMP TABLE bid_s(id TEXT PRIMARY KEY, note TEXT)")
      :ok
    end

    test "a raw UUID binds as TEXT and comes back as the 36-char string" do
      # Simulate the adapter dumper chain: Ecto.UUID.dump first, then our fn.
      [_type, fun] = XqliteEcto3.dumpers(:binary_id, Ecto.UUID)
      {:ok, dumped} = fun.(@uuid_raw)
      assert dumped == @uuid_string

      TestRepo.query!("INSERT INTO bid_s VALUES (?1, ?2)", [dumped, "first"])
      %{rows: [[stored, _]]} = TestRepo.query!("SELECT id, note FROM bid_s")
      assert stored == @uuid_string
      assert byte_size(stored) == 36
    end
  end

  describe "round-trip via TestRepo with :binary storage" do
    setup do
      Application.put_env(:xqlite_ecto3, :binary_id_storage, :binary)
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
      TestRepo.query!("CREATE TEMP TABLE bid_b(id BLOB PRIMARY KEY, note TEXT)")
      :ok
    end

    test "a raw UUID stays raw on the wire and comes back as 16 bytes" do
      [_type, fun] = XqliteEcto3.dumpers(:binary_id, Ecto.UUID)
      {:ok, dumped} = fun.(@uuid_raw)
      assert dumped == @uuid_raw
      assert byte_size(dumped) == 16

      TestRepo.query!("INSERT INTO bid_b VALUES (?1, ?2)", [dumped, "first"])
      %{rows: [[stored, _]]} = TestRepo.query!("SELECT id, note FROM bid_b")
      assert stored == @uuid_raw
      assert byte_size(stored) == 16
    end
  end
end
