defmodule XqliteEcto3.AdapterCallbacksTest do
  use ExUnit.Case, async: true

  # Direct tests for adapter-level callbacks declared in lib/xqlite_ecto3.ex:
  # autogenerate/1, loaders/2, dumpers/2, lock_for_migrations/3,
  # supports_ddl_transaction?/0.

  describe "autogenerate/1" do
    test ":id returns nil (SQLite assigns via INTEGER PRIMARY KEY AUTOINCREMENT)" do
      assert XqliteEcto3.autogenerate(:id) == nil
    end

    test ":embed_id returns a generated UUID string" do
      id = XqliteEcto3.autogenerate(:embed_id)
      assert is_binary(id)
      assert {:ok, _} = Ecto.UUID.cast(id)
    end

    test ":binary_id returns a generated UUID string" do
      id = XqliteEcto3.autogenerate(:binary_id)
      assert is_binary(id)
      assert {:ok, _} = Ecto.UUID.cast(id)
    end

    test ":embed_id and :binary_id produce unique values" do
      ids = for _ <- 1..50, do: XqliteEcto3.autogenerate(:embed_id)
      assert Enum.uniq(ids) == ids
    end
  end

  describe "supports_ddl_transaction?/0" do
    test "returns true (SQLite supports transactional DDL)" do
      assert XqliteEcto3.supports_ddl_transaction?() == true
    end
  end

  describe "lock_for_migrations/3" do
    test "simply invokes the given fn (SQLite is single-writer, no advisory lock needed)" do
      assert XqliteEcto3.lock_for_migrations(:meta, [], fn -> :result end) == :result
    end

    test "is transparent to return shape" do
      assert XqliteEcto3.lock_for_migrations(:meta, [], fn -> {:ok, 42} end) == {:ok, 42}
    end
  end

  describe "loaders/2" do
    test ":boolean loader decodes 0 and 1" do
      [decoder | _] = XqliteEcto3.loaders(:boolean, :boolean)
      assert decoder.(0) == {:ok, false}
      assert decoder.(1) == {:ok, true}
      assert decoder.(nil) == {:ok, nil}
    end

    test ":boolean loader rejects non-0/1 values with structured error" do
      [decoder | _] = XqliteEcto3.loaders(:boolean, :boolean)
      assert {:error, msg} = decoder.(2)
      assert msg =~ "expected 0 or 1 for boolean column"
    end

    test ":naive_datetime loader parses ISO 8601 strings" do
      [decoder | _] = XqliteEcto3.loaders(:naive_datetime, :naive_datetime)
      assert {:ok, %NaiveDateTime{year: 2024}} = decoder.("2024-06-15T14:30:45")
    end

    test ":naive_datetime loader passes through already-parsed values" do
      [decoder | _] = XqliteEcto3.loaders(:naive_datetime, :naive_datetime)
      value = ~N[2024-06-15 14:30:45]
      assert decoder.(value) == {:ok, value}
    end

    test ":naive_datetime loader passes unparseable strings through for upstream handling" do
      [decoder | _] = XqliteEcto3.loaders(:naive_datetime, :naive_datetime)
      assert decoder.("not a datetime") == {:ok, "not a datetime"}
    end

    test ":utc_datetime loader parses ISO 8601 strings with offset" do
      [decoder | _] = XqliteEcto3.loaders(:utc_datetime, :utc_datetime)
      assert {:ok, %DateTime{}} = decoder.("2024-06-15T14:30:45Z")
    end

    test ":date loader parses ISO 8601 date strings" do
      [decoder | _] = XqliteEcto3.loaders(:date, :date)
      assert decoder.("2024-06-15") == {:ok, ~D[2024-06-15]}
    end

    test ":time loader parses ISO 8601 time strings" do
      [decoder | _] = XqliteEcto3.loaders(:time, :time)
      assert decoder.("14:30:45") == {:ok, ~T[14:30:45]}
    end

    test ":decimal loader parses strings, integers, and floats" do
      [decoder | _] = XqliteEcto3.loaders(:decimal, :decimal)
      assert {:ok, d1} = decoder.("123.456")
      assert Decimal.equal?(d1, Decimal.new("123.456"))
      assert {:ok, d2} = decoder.(42)
      assert Decimal.equal?(d2, Decimal.new(42))
      assert {:ok, d3} = decoder.(3.14)
      assert Decimal.equal?(d3, Decimal.from_float(3.14))
      assert decoder.(nil) == {:ok, nil}
    end

    test ":uuid loader converts string UUIDs to raw binary" do
      [decoder | _] = XqliteEcto3.loaders(:uuid, :uuid)
      uuid = Ecto.UUID.generate()
      assert {:ok, raw} = decoder.(uuid)
      assert byte_size(raw) == 16
    end

    test ":uuid loader passes nil through" do
      [decoder | _] = XqliteEcto3.loaders(:uuid, :uuid)
      assert decoder.(nil) == {:ok, nil}
    end

    test ":map loader decodes JSON strings" do
      [decoder | _] = XqliteEcto3.loaders(:map, :map)
      assert decoder.(~s|{"k":"v"}|) == {:ok, %{"k" => "v"}}
    end

    test ":map loader passes invalid JSON through" do
      [decoder | _] = XqliteEcto3.loaders(:map, :map)
      assert decoder.("not json") == {:ok, "not json"}
    end

    test "{:array, _} loader decodes JSON arrays" do
      [decoder | _] = XqliteEcto3.loaders({:array, :string}, {:array, :string})
      assert decoder.(~s|["a","b"]|) == {:ok, ["a", "b"]}
    end

    test "unknown type returns [type] without custom loader" do
      # An unknown type falls through to the base case with no custom decoder.
      assert XqliteEcto3.loaders(:string, :string) == [:string]
    end
  end

  describe "dumpers/2" do
    test ":boolean dumper encodes true and false" do
      [_type, encoder] = XqliteEcto3.dumpers(:boolean, :boolean)
      assert encoder.(true) == {:ok, 1}
      assert encoder.(false) == {:ok, 0}
    end

    test ":boolean dumper passes through other values (for unusual pipelines)" do
      [_type, encoder] = XqliteEcto3.dumpers(:boolean, :boolean)
      assert encoder.(nil) == {:ok, nil}
    end

    test ":uuid dumper preserves string form" do
      [encoder] = XqliteEcto3.dumpers(:uuid, :uuid)
      uuid = Ecto.UUID.generate()
      assert encoder.(uuid) == {:ok, uuid}
    end

    test ":uuid dumper converts raw binary to string form" do
      [encoder] = XqliteEcto3.dumpers(:uuid, :uuid)
      uuid = Ecto.UUID.generate()
      {:ok, raw} = Ecto.UUID.dump(uuid)
      assert encoder.(raw) == {:ok, uuid}
    end

    test ":uuid dumper passes nil through" do
      [encoder] = XqliteEcto3.dumpers(:uuid, :uuid)
      assert encoder.(nil) == {:ok, nil}
    end

    test "unknown type returns [type] without custom dumper" do
      assert XqliteEcto3.dumpers(:string, :string) == [:string]
    end
  end

  describe "dump_cmd/3" do
    test "raises with a clear message (intentionally unsupported)" do
      assert_raise RuntimeError, "dump_cmd is not supported — use structure_dump/2 instead", fn ->
        XqliteEcto3.dump_cmd([], [], [])
      end
    end
  end
end
