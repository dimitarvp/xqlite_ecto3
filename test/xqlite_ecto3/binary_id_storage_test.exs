defmodule XqliteEcto3.BinaryIdStorageTest do
  # These tests mutate global Application env (snapshot/restore per
  # test). That is safe under async: true because ExUnit runs tests
  # WITHIN a module serially, and mix xqlite_ecto3.test.seq runs one
  # file per OS process — no concurrent module can observe the
  # mutation. (Bare `mix test` is forbidden project-wide anyway.)
  use ExUnit.Case, async: true

  import Ecto.Query, only: [from: 2]

  alias Ecto.Integration.TestRepo
  alias XqliteEcto3.DataType

  @uuid_string "550e8400-e29b-41d4-a716-446655440000"
  # 550e8400-e29b-41d4-a716-446655440000 as raw 16 bytes
  @uuid_raw <<0x55, 0x0E, 0x84, 0x00, 0xE2, 0x9B, 0x41, 0xD4, 0xA7, 0x16, 0x44, 0x66, 0x55, 0x44,
              0x00, 0x00>>

  # About one UUID in fourteen thousand has raw bytes that are valid UTF-8.
  # Bound as a plain binary they would be stored as TEXT rather than as a BLOB,
  # and a JSON encoder accepts them where it refuses every other UUID's bytes,
  # so the rare case gets its own vector instead of waiting for a random run.
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

  # A misspelled setting used to surface as a CaseClauseError from whichever
  # reader ran first — at migration time, at insert time, at read time or
  # while building SQL. One reader answers for all of them now.
  describe "a :binary_id_storage value that is neither :string nor :binary" do
    setup do
      Application.put_env(:xqlite_ecto3, :binary_id_storage, :blob)
      :ok
    end

    test "the shared reader refuses it" do
      assert_raise ArgumentError, fn -> XqliteEcto3.binary_id_storage() end
    end

    test "every run-time reader goes through that reader" do
      require Ecto.Query

      assert_raise ArgumentError, fn -> DataType.column_type(:binary_id, []) end
      assert_raise ArgumentError, fn -> XqliteEcto3.autogenerate(:binary_id) end

      [_type, dump] = XqliteEcto3.dumpers(:binary_id, Ecto.UUID)
      assert_raise ArgumentError, fn -> dump.(@uuid_raw) end
      assert_raise ArgumentError, fn -> dump.(@uuid_string) end

      [load, _type] = XqliteEcto3.loaders(:binary_id, Ecto.UUID)
      assert_raise ArgumentError, fn -> load.(@uuid_raw) end

      tagged =
        Ecto.Query.from(f in Flip,
          where: f.id == type(^@uuid_string, :binary_id),
          select: f.note
        )

      assert_raise ArgumentError, fn -> Ecto.Adapters.SQL.to_sql(:all, TestRepo, tagged) end
    end

    test "a repo refuses to boot with it" do
      assert_raise ArgumentError, fn ->
        XqliteEcto3.Connection.child_spec(database: "bid_never_opened.db", pool_size: 1)
      end
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

    test "with :binary config, wraps the raw 16 bytes as a BLOB parameter" do
      Application.put_env(:xqlite_ecto3, :binary_id_storage, :binary)
      [_type, fun] = XqliteEcto3.dumpers(:binary_id, Ecto.UUID)
      assert fun.(@uuid_raw) == {:ok, %Xqlite.Blob{bytes: @uuid_raw}}
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
      assert dumped == %Xqlite.Blob{bytes: @uuid_raw}

      TestRepo.query!("INSERT INTO bid_b VALUES (?1, ?2)", [dumped, "first"])

      %{rows: [[type, stored, _]]} =
        TestRepo.query!("SELECT typeof(id), id, note FROM bid_b")

      assert type == "blob"
      assert stored == @uuid_raw
      assert byte_size(stored) == 16
    end

    # The bytes of this UUID are valid UTF-8, so bound as a plain binary they
    # would be stored as TEXT and sort and compare apart from every other row
    # in the column. The wrapper is what keeps one column to one storage class.
    test "a UUID whose bytes are valid UTF-8 is stored as a BLOB too" do
      raw = Ecto.UUID.dump!(@utf8_safe_uuid)
      assert String.valid?(raw)

      {:ok, dumped} = Ecto.Type.adapter_dump(XqliteEcto3, :binary_id, @utf8_safe_uuid)

      TestRepo.query!("INSERT INTO bid_b VALUES (?1, ?2)", [dumped, "first"])

      %{rows: [[type, stored]]} = TestRepo.query!("SELECT typeof(id), id FROM bid_b")

      assert type == "blob"
      assert stored == raw
    end

    # TEXT and BLOB never compare equal, so a column holding both classes lets
    # a PRIMARY KEY take the same UUID twice. The row already in the column is
    # written as a BLOB; the second write has to collide with it.
    test "a primary key refuses a UUID already stored as a BLOB" do
      raw = Ecto.UUID.dump!(@utf8_safe_uuid)
      TestRepo.query!("INSERT INTO bid_b VALUES (CAST(?1 AS BLOB), ?2)", [raw, "first"])

      {:ok, dumped} = Ecto.Type.adapter_dump(XqliteEcto3, :binary_id, @utf8_safe_uuid)

      error =
        assert_raise XqliteEcto3.Error, fn ->
          TestRepo.query!("INSERT INTO bid_b VALUES (?1, ?2)", [dumped, "second"])
        end

      assert error.type == :constraint_violation
    end

    test "insert_all writes two ids, both as blobs" do
      rows = [
        %{id: @uuid_string, note: "first"},
        %{id: @utf8_safe_uuid, note: "second"}
      ]

      TestRepo.query!("CREATE TEMP TABLE bid_flip(id BLOB PRIMARY KEY, note TEXT)")
      assert {2, nil} = TestRepo.insert_all(Flip, rows)

      %{rows: stored} =
        TestRepo.query!("SELECT typeof(id), length(id) FROM bid_flip ORDER BY note")

      assert stored == [["blob", 16], ["blob", 16]]
    end
  end

  describe "a BLOB parameter through the driver" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
      :ok
    end

    test "the wrapper binds as a BLOB whatever the bytes are" do
      %{rows: [[type]]} =
        TestRepo.query!("SELECT typeof(?1)", [%Xqlite.Blob{bytes: "0123456789abcdef"}])

      assert type == "blob"
    end

    test "a wrapper whose bytes are not a binary is refused with its position" do
      assert {:error, error} = TestRepo.query("SELECT ?1", [%Xqlite.Blob{bytes: 1}])

      assert error.type == :invalid_blob_bytes
      assert error.details == %{position: 1, type: :integer}
    end
  end

  describe "the :binary_id field chain (Ecto hands the 36-char string to the adapter)" do
    test "with :binary config, a UUID string dumps to its 16 raw bytes" do
      Application.put_env(:xqlite_ecto3, :binary_id_storage, :binary)

      assert Ecto.Type.adapter_dump(XqliteEcto3, :binary_id, @uuid_string) ==
               {:ok, %Xqlite.Blob{bytes: @uuid_raw}}
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
        assert Ecto.Type.adapter_dump(XqliteEcto3, :binary_id, raw) ==
                 {:ok, %Xqlite.Blob{bytes: raw}}

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

  # An `Ecto.UUID` field follows the setting the way `:binary_id` does. One
  # adapter function is the whole chain for it: `Ecto.UUID.dump/1` refuses raw
  # sixteen bytes and every non-UUID string, and a dumper that answers `:error`
  # halts the insert instead of storing what today's chain stores.
  describe "the Ecto.UUID field chain" do
    test "with :binary config, a UUID string dumps to the wrapped 16 bytes" do
      Application.put_env(:xqlite_ecto3, :binary_id_storage, :binary)

      assert Ecto.Type.adapter_dump(XqliteEcto3, Ecto.UUID, @uuid_string) ==
               {:ok, %Xqlite.Blob{bytes: @uuid_raw}}
    end

    test "with :binary config, sixteen raw bytes are wrapped as they are" do
      Application.put_env(:xqlite_ecto3, :binary_id_storage, :binary)

      for raw <- [@uuid_raw, @sixteen_ascii, @sixteen_counted] do
        assert Ecto.Type.adapter_dump(XqliteEcto3, Ecto.UUID, raw) ==
                 {:ok, %Xqlite.Blob{bytes: raw}}
      end
    end

    test "with :binary config, a string that is not a UUID passes through" do
      Application.put_env(:xqlite_ecto3, :binary_id_storage, :binary)

      assert Ecto.Type.adapter_dump(XqliteEcto3, Ecto.UUID, "not-a-uuid-at-all") ==
               {:ok, "not-a-uuid-at-all"}
    end

    test "with :binary config, nil passes through" do
      Application.put_env(:xqlite_ecto3, :binary_id_storage, :binary)
      assert Ecto.Type.adapter_dump(XqliteEcto3, Ecto.UUID, nil) == {:ok, nil}
    end

    test "with :string config, the 36-character text is what it has always been" do
      Application.put_env(:xqlite_ecto3, :binary_id_storage, :string)

      assert Ecto.Type.adapter_dump(XqliteEcto3, Ecto.UUID, @uuid_string) == {:ok, @uuid_string}
      assert Ecto.Type.adapter_dump(XqliteEcto3, Ecto.UUID, @uuid_raw) == {:ok, @uuid_string}
      assert Ecto.Type.adapter_dump(XqliteEcto3, Ecto.UUID, nil) == {:ok, nil}
    end
  end

  # A UUID written straight into a query, without `^`, is not a value the
  # adapter can inline. Ecto refuses one under `:string` storage and asks for
  # interpolation; under `:binary` the dumped value is a struct that slips past
  # Ecto's own check, so SQL generation has to refuse it in the same place.
  describe "a UUID literal in a query" do
    test "is refused under both storage modes" do
      for mode <- [:string, :binary] do
        Application.put_env(:xqlite_ecto3, :binary_id_storage, mode)

        assert_raise Ecto.QueryError, fn ->
          TestRepo.to_sql(
            :all,
            from(f in Flip,
              where: f.id == "550e8400-e29b-41d4-a716-446655440000",
              select: f.id
            )
          )
        end
      end
    end

    test "the interpolated form binds one parameter under both storage modes" do
      for mode <- [:string, :binary] do
        Application.put_env(:xqlite_ecto3, :binary_id_storage, mode)

        {sql, params} =
          TestRepo.to_sql(:all, from(f in Flip, where: f.id == ^@uuid_string, select: f.id))

        assert sql =~ "?1"
        assert [_one] = params
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

  defmodule Kinds do
    use Ecto.Schema

    @primary_key {:id, :id, autogenerate: false}
    schema "bid_kinds" do
      field(:bid, :binary_id)
      field(:eu, Ecto.UUID)
      field(:tu_str, XqliteEcto3.Types.UUID, storage: :string)
      field(:tu_bin, XqliteEcto3.Types.UUID, storage: :binary)
    end
  end

  # Sixteen stored bytes in a UUID column are read as a UUID whatever they
  # were. The byte count alone decides it — the characters need not be hex —
  # so a 16-character identifier that is not a UUID belongs in a `:string`
  # field, where nothing expands it.
  describe "a 16-character text row loads as a fabricated UUID" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)

      TestRepo.query!(
        "CREATE TEMP TABLE bid_kinds(id INTEGER PRIMARY KEY, bid TEXT, eu TEXT, tu_str TEXT, tu_bin TEXT)"
      )

      :ok
    end

    test "through every UUID kind, under both storage modes" do
      text = "sixteen  bytes!!"
      fabricated = Ecto.UUID.cast!(text)

      TestRepo.query!("INSERT INTO bid_kinds VALUES (1, ?1, ?2, ?3, ?4)", [
        text,
        text,
        text,
        text
      ])

      for mode <- [:string, :binary] do
        Application.put_env(:xqlite_ecto3, :binary_id_storage, mode)

        row = TestRepo.get!(Kinds, 1)

        assert row.eu == fabricated
        assert row.tu_str == fabricated
        assert row.tu_bin == fabricated
      end

      Application.put_env(:xqlite_ecto3, :binary_id_storage, :string)
      assert TestRepo.get!(Kinds, 1).bid == text

      Application.put_env(:xqlite_ecto3, :binary_id_storage, :binary)
      assert TestRepo.get!(Kinds, 1).bid == fabricated
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

  # The one-time conversion the README publishes for a column written under
  # `:string` and read under `:binary`. It has to convert every row holding a
  # dashed UUID text and leave every other row byte for byte, and the count
  # query has to answer exactly how many rows it will not convert.
  describe "the normalize statement for rows written as text" do
    @dashless_hex String.duplicate("ab", 18)

    @normalize_count """
    SELECT count(*) FROM norm WHERE typeof(c) = 'text' AND NOT
      (length(c) = 36 AND length(replace(c, '-', '')) = 32
       AND unhex(replace(c, '-', '')) IS NOT NULL)
    """

    @normalize_update """
    UPDATE norm SET c = unhex(replace(c, '-', ''))
      WHERE typeof(c) = 'text' AND length(c) = 36
      AND length(replace(c, '-', '')) = 32
      AND unhex(replace(c, '-', '')) IS NOT NULL
    """

    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
      TestRepo.query!("CREATE TEMP TABLE norm(id INTEGER PRIMARY KEY, c)")

      rows = [
        {1, @uuid_string},
        {2, String.upcase(@uuid_string)},
        {3, "not-a-uuid-at-all"},
        {4, @dashless_hex},
        {5, String.duplicate("z", 36)},
        {7, String.duplicate("ab", 16)},
        {8, String.replace_suffix(@uuid_string, "0", "z")},
        {9, @uuid_raw},
        {10, nil}
      ]

      for {id, value} <- rows do
        TestRepo.query!("INSERT INTO norm VALUES (?1, ?2)", [id, value])
      end

      # A NUL inside the text is built in SQL: the parameter path refuses one,
      # and the row is here because SQLite's `length()` stops counting at it.
      TestRepo.query!(
        "INSERT INTO norm VALUES (6, ? || char(0) || 'b')",
        [String.duplicate("a", 34)]
      )

      :ok
    end

    test "it converts the two UUID texts and leaves the other eight alone" do
      %{rows: [[uncovertible]]} = TestRepo.query!(@normalize_count)
      assert uncovertible == 6

      TestRepo.query!(@normalize_update)

      %{rows: classes} = TestRepo.query!("SELECT typeof(c) FROM norm ORDER BY id")

      assert classes == [
               ["blob"],
               ["blob"],
               ["text"],
               ["text"],
               ["text"],
               ["text"],
               ["text"],
               ["text"],
               ["blob"],
               ["null"]
             ]

      %{rows: converted} = TestRepo.query!("SELECT c FROM norm WHERE id IN (1, 2) ORDER BY id")
      assert converted == [[@uuid_raw], [@uuid_raw]]

      %{rows: [[untouched]]} = TestRepo.query!("SELECT c FROM norm WHERE id = 4")
      assert untouched == @dashless_hex
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
