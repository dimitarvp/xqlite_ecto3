defmodule XqliteEcto3.Types.UUIDTest do
  use ExUnit.Case, async: true

  alias XqliteEcto3.Types.UUID, as: UUIDType

  @uuid_string "550e8400-e29b-41d4-a716-446655440000"
  # 550e8400-e29b-41d4-a716-446655440000 as raw 16 bytes
  @uuid_raw <<0x55, 0x0E, 0x84, 0x00, 0xE2, 0x9B, 0x41, 0xD4, 0xA7, 0x16, 0x44, 0x66, 0x55, 0x44,
              0x00, 0x00>>

  describe "init/1" do
    test "defaults to :string storage when no option given" do
      assert UUIDType.init([]) == %{storage: :string}
    end

    test "accepts explicit :storage => :string" do
      assert UUIDType.init(storage: :string) == %{storage: :string}
    end

    test "accepts explicit :storage => :binary" do
      assert UUIDType.init(storage: :binary) == %{storage: :binary}
    end

    test "raises on invalid storage value" do
      assert_raise ArgumentError, fn ->
        UUIDType.init(storage: :jpeg)
      end

      assert_raise ArgumentError, fn ->
        UUIDType.init(storage: "string")
      end
    end

    test "ignores unknown options" do
      # Ecto.ParameterizedType passes the full field options; we only care about :storage.
      params = UUIDType.init(storage: :binary, autogenerate: true, primary_key: true)
      assert params == %{storage: :binary}
    end
  end

  describe "type/1" do
    test "returns :string for :string storage" do
      assert UUIDType.type(%{storage: :string}) == :string
    end

    test "returns :binary for :binary storage" do
      assert UUIDType.type(%{storage: :binary}) == :binary
    end
  end

  describe "cast/2" do
    test "nil passes through" do
      assert UUIDType.cast(nil, %{storage: :string}) == {:ok, nil}
      assert UUIDType.cast(nil, %{storage: :binary}) == {:ok, nil}
    end

    test "accepts 36-char string form" do
      assert UUIDType.cast(@uuid_string, %{storage: :string}) == {:ok, @uuid_string}
      assert UUIDType.cast(@uuid_string, %{storage: :binary}) == {:ok, @uuid_string}
    end

    test "accepts raw 16-byte form and normalizes to string" do
      assert UUIDType.cast(@uuid_raw, %{storage: :string}) == {:ok, @uuid_string}
      assert UUIDType.cast(@uuid_raw, %{storage: :binary}) == {:ok, @uuid_string}
    end

    test "rejects garbage" do
      assert UUIDType.cast("not-a-uuid", %{storage: :string}) == :error
      assert UUIDType.cast(12_345, %{storage: :string}) == :error
      assert UUIDType.cast(<<1, 2, 3>>, %{storage: :string}) == :error
    end
  end

  describe "load/3 with :string storage" do
    test "loads a 36-char string as itself" do
      assert UUIDType.load(@uuid_string, nil, %{storage: :string}) == {:ok, @uuid_string}
    end

    test "nil passes through" do
      assert UUIDType.load(nil, nil, %{storage: :string}) == {:ok, nil}
    end

    test "rejects non-string garbage" do
      assert UUIDType.load(123, nil, %{storage: :string}) == :error
      assert UUIDType.load("not-a-uuid", nil, %{storage: :string}) == :error
    end
  end

  describe "load/3 with :binary storage" do
    test "loads raw 16 bytes to the string form" do
      assert UUIDType.load(@uuid_raw, nil, %{storage: :binary}) == {:ok, @uuid_string}
    end

    test "nil passes through" do
      assert UUIDType.load(nil, nil, %{storage: :binary}) == {:ok, nil}
    end

    test "rejects non-16-byte binaries" do
      assert UUIDType.load(<<1, 2, 3>>, nil, %{storage: :binary}) == :error
      assert UUIDType.load(@uuid_string, nil, %{storage: :binary}) == :error
    end
  end

  describe "dump/3 with :string storage" do
    test "dumps string form as itself" do
      assert UUIDType.dump(@uuid_string, nil, %{storage: :string}) == {:ok, @uuid_string}
    end

    test "dumps raw form as string" do
      assert UUIDType.dump(@uuid_raw, nil, %{storage: :string}) == {:ok, @uuid_string}
    end

    test "nil passes through" do
      assert UUIDType.dump(nil, nil, %{storage: :string}) == {:ok, nil}
    end

    test "rejects garbage" do
      assert UUIDType.dump("not-a-uuid", nil, %{storage: :string}) == :error
    end
  end

  describe "dump/3 with :binary storage" do
    test "dumps string form as raw 16 bytes" do
      assert UUIDType.dump(@uuid_string, nil, %{storage: :binary}) == {:ok, @uuid_raw}
    end

    test "dumps raw form as raw 16 bytes (unchanged round-trip)" do
      assert UUIDType.dump(@uuid_raw, nil, %{storage: :binary}) == {:ok, @uuid_raw}
    end

    test "nil passes through" do
      assert UUIDType.dump(nil, nil, %{storage: :binary}) == {:ok, nil}
    end

    test "rejects garbage" do
      assert UUIDType.dump("not-a-uuid", nil, %{storage: :binary}) == :error
    end
  end

  describe "autogenerate/1" do
    test "produces a valid v4 UUID string for :string storage" do
      uuid = UUIDType.autogenerate(%{storage: :string})
      assert is_binary(uuid)
      assert byte_size(uuid) == 36
      assert {:ok, _} = Ecto.UUID.cast(uuid)
    end

    test "produces a valid v4 UUID string for :binary storage" do
      # autogenerate runs BEFORE dump, so it's always string form regardless
      # of storage mode. dump/3 then converts to raw bytes for :binary storage.
      uuid = UUIDType.autogenerate(%{storage: :binary})
      assert is_binary(uuid)
      assert byte_size(uuid) == 36
      assert {:ok, _} = Ecto.UUID.cast(uuid)
    end

    test "produces a different UUID each call" do
      uuids = for _ <- 1..10, do: UUIDType.autogenerate(%{storage: :string})
      assert length(Enum.uniq(uuids)) == 10
    end
  end

  describe "equal?/3" do
    test "compares two UUIDs structurally" do
      assert UUIDType.equal?(@uuid_string, @uuid_string, %{storage: :string}) == true
      assert UUIDType.equal?(@uuid_string, "other", %{storage: :string}) == false
      assert UUIDType.equal?(nil, nil, %{storage: :string}) == true
      assert UUIDType.equal?(nil, @uuid_string, %{storage: :string}) == false
    end
  end

  describe "round-trip through SQLite with :string storage" do
    setup do
      alias Ecto.Integration.TestRepo
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)

      TestRepo.query!("""
      CREATE TEMP TABLE uuid_string_test (
        id TEXT PRIMARY KEY,
        label TEXT
      )
      """)

      on_exit(fn ->
        # Tempgets cleaned when connection closes; Sandbox rolls back anyway.
        :ok
      end)

      :ok
    end

    test "insert + select via raw TestRepo.query! preserves the string form" do
      alias Ecto.Integration.TestRepo

      uuid = Ecto.UUID.generate()

      {:ok, dumped} = UUIDType.dump(uuid, nil, %{storage: :string})
      TestRepo.query!("INSERT INTO uuid_string_test VALUES (?1, ?2)", [dumped, "first"])

      %{rows: [[stored, _]]} = TestRepo.query!("SELECT id, label FROM uuid_string_test")
      assert {:ok, ^uuid} = UUIDType.load(stored, nil, %{storage: :string})
    end
  end

  describe "round-trip through SQLite with :binary storage" do
    setup do
      alias Ecto.Integration.TestRepo
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)

      TestRepo.query!("""
      CREATE TEMP TABLE uuid_binary_test (
        id BLOB PRIMARY KEY,
        label TEXT
      )
      """)

      :ok
    end

    test "insert raw 16 bytes + select preserves the bytes" do
      alias Ecto.Integration.TestRepo

      uuid = Ecto.UUID.generate()

      {:ok, dumped} = UUIDType.dump(uuid, nil, %{storage: :binary})
      assert byte_size(dumped) == 16

      TestRepo.query!("INSERT INTO uuid_binary_test VALUES (?1, ?2)", [dumped, "first"])

      %{rows: [[stored, _]]} = TestRepo.query!("SELECT id, label FROM uuid_binary_test")
      assert byte_size(stored) == 16
      assert {:ok, ^uuid} = UUIDType.load(stored, nil, %{storage: :binary})
    end
  end
end
