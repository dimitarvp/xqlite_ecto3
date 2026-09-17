defmodule XqliteEcto3.BinaryIdStorageTest do
  # These tests mutate global Application env (snapshot/restore per
  # test). That is safe under async: true because ExUnit runs tests
  # WITHIN a module serially, and mix xqlite_ecto3.test.seq runs one
  # file per OS process — no concurrent module can observe the
  # mutation. (Bare `mix test` is forbidden project-wide anyway.)
  use ExUnit.Case, async: true

  alias Ecto.Integration.TestRepo
  alias XqliteEcto3.DataType

  @uuid_string "550e8400-e29b-41d4-a716-446655440000"
  # 550e8400-e29b-41d4-a716-446655440000 as raw 16 bytes
  @uuid_raw <<0x55, 0x0E, 0x84, 0x00, 0xE2, 0x9B, 0x41, 0xD4, 0xA7, 0x16, 0x44, 0x66, 0x55, 0x44,
              0x00, 0x00>>

  # About one UUID in seventeen thousand has raw bytes that are valid UTF-8.
  # SQLite then stores them as TEXT rather than as a BLOB, and a JSON encoder
  # accepts them where it refuses every other UUID's bytes, so the rare case
  # gets its own vector instead of waiting for a random run to meet it.
  @utf8_safe_uuid "61626364-6566-4ac3-8067-68696a6b6c6d"

  defmodule Ids do
    use Ecto.Schema

    @primary_key false
    embedded_schema do
      field(:bid, :binary_id)
      field(:eu, Ecto.UUID)
      field(:tu, XqliteEcto3.Types.UUID, storage: :binary)
    end
  end

  defmodule Holder do
    use Ecto.Schema

    @primary_key {:id, :id, autogenerate: true}
    schema "bid_holders" do
      embeds_one(:ids, Ids)
    end
  end

  defmodule Flip do
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: true}
    schema "bid_flip" do
      field(:note, :string)
    end
  end

  setup do
    # Tests within this file run serially (ExUnit is per-module serial), so we mutate
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

  describe "the :binary_id field chain (Ecto hands the 36-char string to the adapter)" do
    test "with :binary config, a UUID string dumps to its 16 raw bytes" do
      Application.put_env(:xqlite_ecto3, :binary_id_storage, :binary)
      assert Ecto.Type.adapter_dump(XqliteEcto3, :binary_id, @uuid_string) == {:ok, @uuid_raw}
    end

    test "with :binary config, a string that is not a UUID passes through" do
      Application.put_env(:xqlite_ecto3, :binary_id_storage, :binary)
      assert Ecto.Type.adapter_dump(XqliteEcto3, :binary_id, "not-a-uuid") == {:ok, "not-a-uuid"}
    end

    test "with :string config, a UUID string dumps unchanged" do
      Application.put_env(:xqlite_ecto3, :binary_id_storage, :string)
      assert Ecto.Type.adapter_dump(XqliteEcto3, :binary_id, @uuid_string) == {:ok, @uuid_string}
    end

    test "with :binary config, 16 raw bytes load as the 36-char string" do
      Application.put_env(:xqlite_ecto3, :binary_id_storage, :binary)
      assert Ecto.Type.adapter_load(XqliteEcto3, :binary_id, @uuid_raw) == {:ok, @uuid_string}
    end

    test "with :binary config, a row written as text before the flip still loads" do
      Application.put_env(:xqlite_ecto3, :binary_id_storage, :binary)
      assert Ecto.Type.adapter_load(XqliteEcto3, :binary_id, @uuid_string) == {:ok, @uuid_string}
    end

    test "with :string config, a 16-byte value loads unchanged" do
      Application.put_env(:xqlite_ecto3, :binary_id_storage, :string)

      assert Ecto.Type.adapter_load(XqliteEcto3, :binary_id, "sixteen  bytes!!") ==
               {:ok, "sixteen  bytes!!"}
    end
  end

  # The rule the moduledoc states, example by example: sixteen raw bytes going
  # IN are a UUID and are written as the dashed text in both storage modes;
  # any other length passes through untouched.
  describe "sixteen raw bytes going in are a UUID in both storage modes" do
    @sixteen_ascii "0123456789abcdef"
    @sixteen_counted <<1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16>>

    test "sixteen bytes of any shape dump as the dashed text under :string" do
      Application.put_env(:xqlite_ecto3, :binary_id_storage, :string)

      for raw <- [@sixteen_ascii, @sixteen_counted, @uuid_raw] do
        assert Ecto.Type.adapter_dump(XqliteEcto3, :binary_id, raw) ==
                 {:ok, Ecto.UUID.cast!(raw)}
      end
    end

    test "sixteen bytes of any shape stay raw under :binary and load as the dashed text" do
      Application.put_env(:xqlite_ecto3, :binary_id_storage, :binary)

      for raw <- [@sixteen_ascii, @sixteen_counted, @uuid_raw] do
        assert Ecto.Type.adapter_dump(XqliteEcto3, :binary_id, raw) == {:ok, raw}
        assert Ecto.Type.adapter_load(XqliteEcto3, :binary_id, raw) == {:ok, Ecto.UUID.cast!(raw)}
      end
    end

    test "any other length passes through in both directions and both modes" do
      for mode <- [:string, :binary] do
        Application.put_env(:xqlite_ecto3, :binary_id_storage, mode)

        for value <- [
              "shortid8",
              String.duplicate("z", 36),
              "",
              "fifteen  bytes!",
              "seventeen bytes!!"
            ] do
          assert Ecto.Type.adapter_dump(XqliteEcto3, :binary_id, value) == {:ok, value}
          assert Ecto.Type.adapter_load(XqliteEcto3, :binary_id, value) == {:ok, value}
        end
      end
    end
  end

  describe "flipping the config with rows already written" do
    setup do
      Application.put_env(:xqlite_ecto3, :binary_id_storage, :binary)
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
      TestRepo.query!("CREATE TEMP TABLE bid_flip(id BLOB PRIMARY KEY, note TEXT)")
      :ok
    end

    test "ids written under :binary read back as raw bytes once the config says :string" do
      %Flip{id: id} = TestRepo.insert!(%Flip{note: "before the flip"})
      assert byte_size(id) == 36

      Application.put_env(:xqlite_ecto3, :binary_id_storage, :string)

      assert %Flip{id: raw} = TestRepo.one(Flip)
      assert raw == Ecto.UUID.dump!(id)
      assert byte_size(raw) == 16
    end
  end

  describe "a UUID inside an embedded schema" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)

      TestRepo.query!(
        "CREATE TEMP TABLE bid_holders(id INTEGER PRIMARY KEY AUTOINCREMENT, ids TEXT)"
      )

      :ok
    end

    test "all three UUID kinds round-trip under both storage modes" do
      for mode <- [:string, :binary],
          uuid <- [@uuid_string, @utf8_safe_uuid] do
        Application.put_env(:xqlite_ecto3, :binary_id_storage, mode)

        held = %Holder{ids: %Ids{bid: uuid, eu: uuid, tu: uuid}}
        %Holder{id: id} = TestRepo.insert!(held)

        assert %Holder{ids: %Ids{bid: ^uuid, eu: ^uuid, tu: ^uuid}} = TestRepo.get!(Holder, id)
      end
    end
  end

  describe "a 36-character text row loads through every UUID kind" do
    test "under both storage modes" do
      for mode <- [:string, :binary] do
        Application.put_env(:xqlite_ecto3, :binary_id_storage, mode)

        assert Ecto.Type.adapter_load(XqliteEcto3, :binary_id, @uuid_string) ==
                 {:ok, @uuid_string}

        assert Ecto.Type.adapter_load(XqliteEcto3, Ecto.UUID, @uuid_string) == {:ok, @uuid_string}

        assert XqliteEcto3.Types.UUID.load(@uuid_string, nil, %{storage: :binary}) ==
                 {:ok, @uuid_string}
      end
    end
  end

  defmodule Account do
    use Ecto.Schema

    @primary_key {:id, :binary_id, autogenerate: true}
    schema "bid_accounts" do
      field(:note, :string)
    end
  end

  describe "a :binary_id schema under :binary storage" do
    setup do
      Application.put_env(:xqlite_ecto3, :binary_id_storage, :binary)
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
      TestRepo.query!("CREATE TEMP TABLE bid_accounts(id BLOB PRIMARY KEY, note TEXT)")
      :ok
    end

    test "stores a 16-byte BLOB and reads back the 36-char string" do
      %Account{id: id} = TestRepo.insert!(%Account{note: "first"})
      assert byte_size(id) == 36

      assert %{rows: [["blob", 16]]} =
               TestRepo.query!("SELECT typeof(id), length(id) FROM bid_accounts")

      assert %Account{id: ^id, note: "first"} = TestRepo.get!(Account, id)
    end
  end
end
