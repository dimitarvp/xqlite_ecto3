defmodule XqliteEcto3.TypesLawTest do
  @moduledoc """
  One law per shipped field type, checked by writing generated values into a
  real table through a real schema and reading them back.

  Everything here goes through `Repo.insert/1` and `Repo.get/2`, so the
  adapter's own dumper and loader chain runs on every case. Nothing calls
  `dump/1` or `load/1` directly — a type can only pass by surviving the trip
  through SQLite.

  Two shapes of law appear:

    * **Identity.** What you write is what you read, compared with the
      equality that fits the type. Most types are here.

    * **Projection.** The type deliberately changes the value, and the law
      pins exactly what comes back, so a silent widening or narrowing of that
      change fails the property. `Instant` truncates nanoseconds to whole
      microseconds. `TimestampTZ` shifts to UTC on read while keeping the
      original offset in the stored text. `:decimal` reads back the number
      SQLite actually stored rather than the scale you wrote. `:map` written
      with atom keys reads back string-keyed. `Types.Array` with
      `element: :float` widens whole numbers to floats, and `Types.UUID`
      lower-cases what you give it.

  Several properties also read the raw column with a second query, so the law
  covers the stored form as well as the loaded value. That is what makes the
  `TimestampTZ` offset claim testable at all: the offset only exists in the
  stored text, because the loaded struct is UTC by then.

  Decimal's accept-or-refuse rule already has a property in
  `XqliteEcto3.TypesRoundtripMatrixTest`; this file covers the shape of the
  value that comes back when the write is accepted, which that property does
  not.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  alias XqliteEcto3.DecimalPrecision

  defmodule LawRepo do
    use Ecto.Repo, otp_app: :xqlite_ecto3, adapter: XqliteEcto3
  end

  defmodule Rec do
    use Ecto.Schema

    @primary_key {:id, :id, autogenerate: true}
    schema "law_types" do
      field(:int_field, :integer)
      field(:float_field, :float)
      field(:str_field, :string)
      field(:bin_field, :binary)
      field(:bool_field, :boolean)
      field(:dec_field, :decimal)
      field(:date_field, :date)
      field(:time_field, :time)
      field(:time_usec_field, :time_usec)
      field(:naive_field, :naive_datetime)
      field(:naive_usec_field, :naive_datetime_usec)
      field(:utc_field, :utc_datetime)
      field(:utc_usec_field, :utc_datetime_usec)
      field(:map_field, :map)
      field(:map_str_field, {:map, :string})
      field(:arr_int_field, {:array, :integer})
      field(:arr_str_field, {:array, :string})
      field(:arr_float_field, {:array, :float})
      field(:bid_field, :binary_id)
      field(:euuid_field, Ecto.UUID)
      field(:dur_field, XqliteEcto3.Types.Duration)
      field(:inst_field, XqliteEcto3.Types.Instant)
      field(:tsz_field, XqliteEcto3.Types.TimestampTZ)
      field(:xarr_any_field, XqliteEcto3.Types.Array)
      field(:xarr_int_field, XqliteEcto3.Types.Array, element: :integer)
      field(:xarr_str_field, XqliteEcto3.Types.Array, element: :string)
      field(:xarr_float_field, XqliteEcto3.Types.Array, element: :float)
      field(:xarr_bool_field, XqliteEcto3.Types.Array, element: :boolean)
      field(:uuid_str_field, XqliteEcto3.Types.UUID, storage: :string)
      field(:uuid_bin_field, XqliteEcto3.Types.UUID, storage: :binary)
    end
  end

  @i64_max 9_223_372_036_854_775_807
  @i64_min -9_223_372_036_854_775_808

  # Run counts are picked so the whole file stays around ten seconds. Every
  # case is one INSERT plus one primary-key SELECT, and most add a second
  # SELECT for the raw stored value, so the cost per case is roughly flat
  # across the properties.
  @runs 1100

  setup_all do
    database =
      Path.join(
        System.tmp_dir!(),
        "xqlite_ecto3_types_law_#{System.os_time(:nanosecond)}.db"
      )

    remove_database(database)

    config = [adapter: XqliteEcto3, database: database, pool_size: 1]

    Application.put_env(:xqlite_ecto3, LawRepo, config)
    :ok = XqliteEcto3.storage_up(config)
    start_supervised!({LawRepo, config})

    LawRepo.query!(
      """
      CREATE TABLE law_types (
        id INTEGER PRIMARY KEY AUTOINCREMENT,
        int_field INTEGER,
        float_field NUMERIC,
        str_field TEXT,
        bin_field BLOB,
        bool_field INTEGER,
        dec_field DECIMAL,
        date_field TEXT,
        time_field TEXT,
        time_usec_field TEXT,
        naive_field TEXT,
        naive_usec_field TEXT,
        utc_field TEXT,
        utc_usec_field TEXT,
        map_field TEXT,
        map_str_field TEXT,
        arr_int_field TEXT,
        arr_str_field TEXT,
        arr_float_field TEXT,
        bid_field TEXT,
        euuid_field TEXT,
        dur_field INTEGER,
        inst_field INTEGER,
        tsz_field TEXT,
        xarr_any_field TEXT,
        xarr_int_field TEXT,
        xarr_str_field TEXT,
        xarr_float_field TEXT,
        xarr_bool_field TEXT,
        uuid_str_field TEXT,
        uuid_bin_field BLOB
      )
      """,
      []
    )

    on_exit(fn -> remove_database(database) end)

    :ok
  end

  defp remove_database(database) do
    Enum.each(["", "-wal", "-shm"], fn suffix -> File.rm(database <> suffix) end)
  end

  # Writes one row holding only this field, then reads the row back through
  # the schema. `Ecto.Changeset.change/2` hands the field the value a schema
  # field really holds at run time, so the dumper sees exactly what a caller
  # would give it.
  defp written_back(field, value) do
    {:ok, inserted} = LawRepo.insert(Ecto.Changeset.change(%Rec{}, %{field => value}))
    fetched = LawRepo.get(Rec, inserted.id)
    Map.fetch!(fetched, field)
  end

  # Same write, but also reads the column with a plain query, so the law can
  # talk about the value SQLite is actually holding and not only about what
  # the loader makes of it.
  defp written_back_with_stored(field, value) do
    {:ok, inserted} = LawRepo.insert(Ecto.Changeset.change(%Rec{}, %{field => value}))
    fetched = LawRepo.get(Rec, inserted.id)

    %{rows: [[stored]]} =
      LawRepo.query!("SELECT #{field} FROM law_types WHERE id = ?", [inserted.id])

    {Map.fetch!(fetched, field), stored}
  end

  # --- 1. integers -----------------------------------------------------------

  # The whole int64 range binds and comes back unchanged. The extremes matter:
  # they are the values a 64-bit round trip loses first if anything on the way
  # narrows to 32 bits or drifts through a float.
  property "an integer comes back equal to itself" do
    check all(value <- int_value(), max_runs: @runs) do
      {loaded, stored} = written_back_with_stored(:int_field, value)

      assert loaded == value
      assert stored == value
    end
  end

  # --- 2. floats -------------------------------------------------------------

  # A `:float` migration column is NUMERIC, so SQLite stores a whole-valued
  # float as an INTEGER. The law is that the field still reads back as a
  # float of equal value — the storage class changes, the Elixir value does
  # not.
  property "a float comes back equal to itself and still a float" do
    check all(value <- float_value(), max_runs: @runs) do
      {loaded, stored} = written_back_with_stored(:float_field, value)

      case value do
        nil ->
          assert loaded == nil
          assert stored == nil

        _ ->
          assert is_float(loaded)
          assert loaded == value
          assert stored == value
      end
    end
  end

  # Negative zero is the one float whose identity the NUMERIC column does not
  # keep: it stores as the integer 0 and reads back as positive zero. The two
  # still compare equal with `==`, which is why the property above passes, so
  # the sign loss is pinned here on its own.
  test "negative zero reads back as positive zero" do
    {loaded, stored} = written_back_with_stored(:float_field, -0.0)

    assert loaded == 0.0
    assert Float.to_string(loaded) == "0.0"
    assert stored == 0
  end

  # --- 3. strings and binaries -----------------------------------------------

  # TEXT holds the bytes verbatim, NUL bytes included — SQLite binds text with
  # an explicit length rather than stopping at the first NUL.
  property "a string comes back equal to itself" do
    check all(value <- text_value(), max_runs: @runs) do
      {loaded, stored} = written_back_with_stored(:str_field, value)

      assert loaded == value
      assert stored == value
    end
  end

  # A BLOB column takes any byte sequence, including bytes that are not valid
  # UTF-8 and would be rejected on the TEXT path.
  property "a binary comes back byte for byte" do
    check all(value <- binary_value(), max_runs: @runs) do
      {loaded, stored} = written_back_with_stored(:bin_field, value)

      assert loaded == value
      assert stored == value
    end
  end

  # --- 4. booleans -----------------------------------------------------------

  # SQLite has no boolean storage class, so the adapter writes 1 and 0 and
  # decodes them back. Both halves are pinned: a decoder that started
  # accepting other integers would still pass an identity-only check.
  property "a boolean comes back equal to itself and is stored as 1 or 0" do
    check all(value <- member_of([true, false, nil]), max_runs: @runs) do
      {loaded, stored} = written_back_with_stored(:bool_field, value)

      assert loaded == value

      case value do
        true -> assert stored == 1
        false -> assert stored == 0
        nil -> assert stored == nil
      end
    end
  end

  # --- 5. decimals -----------------------------------------------------------

  # A DECIMAL column has NUMERIC affinity, so an accepted decimal is held as a
  # float64 or an integer and the scale you wrote is gone: `1.50` is stored as
  # 1.5 and `1.0` as the integer 1. The law is that the loaded decimal is
  # exactly the decimal of the number SQLite is holding, and that it is still
  # numerically the value that was written.
  #
  # The generator stays inside 15 significant digits, which always survives a
  # float64 round trip, so every case here is one the adapter accepts. The
  # accept-or-refuse rule itself is a separate property in
  # `XqliteEcto3.TypesRoundtripMatrixTest`.
  property "a decimal reads back as the number SQLite stored" do
    check all(value <- representable_decimal(), max_runs: @runs) do
      assert DecimalPrecision.representable?(value)

      {loaded, stored} = written_back_with_stored(:dec_field, value)

      assert loaded == decimal_of(stored)
      assert Decimal.equal?(loaded, value)
    end
  end

  defp decimal_of(stored) when is_float(stored), do: Decimal.from_float(stored)
  defp decimal_of(stored) when is_integer(stored), do: Decimal.new(stored)

  # --- 6. dates and times ----------------------------------------------------

  # Dates are ISO 8601 text, across the whole calendar range the type accepts.
  property "a date comes back equal to itself" do
    check all(value <- date_value(), max_runs: @runs) do
      {loaded, stored} = written_back_with_stored(:date_field, value)

      assert loaded == value
      assert stored == Date.to_iso8601(value)
    end
  end

  # `:time` takes whole seconds only — Ecto refuses a `Time` carrying
  # microseconds before the adapter ever sees it — and `:time_usec` keeps all
  # six digits. Both are checked in one pass so the pair cannot drift apart.
  property "a time comes back equal to itself at both precisions" do
    check all(
            whole <- second_time(),
            precise <- microsecond_time(),
            max_runs: @runs
          ) do
      {loaded_whole, stored_whole} = written_back_with_stored(:time_field, whole)

      assert loaded_whole == whole
      assert stored_whole == Time.to_iso8601(whole)

      {loaded_precise, stored_precise} = written_back_with_stored(:time_usec_field, precise)

      assert loaded_precise == precise
      assert loaded_precise.microsecond == precise.microsecond
      assert stored_precise == Time.to_iso8601(precise)
    end
  end

  # Same split for naive datetimes: whole seconds for `:naive_datetime`, full
  # microseconds for `:naive_datetime_usec`.
  property "a naive datetime comes back equal to itself at both precisions" do
    check all(
            whole <- second_naive_datetime(),
            precise <- microsecond_naive_datetime(),
            max_runs: @runs
          ) do
      {loaded_whole, stored_whole} = written_back_with_stored(:naive_field, whole)

      assert loaded_whole == whole
      assert stored_whole == NaiveDateTime.to_iso8601(whole)

      {loaded_precise, stored_precise} = written_back_with_stored(:naive_usec_field, precise)

      assert loaded_precise == precise
      assert loaded_precise.microsecond == precise.microsecond
      assert stored_precise == NaiveDateTime.to_iso8601(precise)
    end
  end

  # And again for the UTC datetimes. These stay in UTC end to end, which is
  # the difference from `TimestampTZ` below.
  property "a utc datetime comes back equal to itself at both precisions" do
    check all(
            whole <- second_utc_datetime(),
            precise <- microsecond_utc_datetime(),
            max_runs: @runs
          ) do
      {loaded_whole, stored_whole} = written_back_with_stored(:utc_field, whole)

      assert loaded_whole == whole
      assert loaded_whole.time_zone == "Etc/UTC"
      assert stored_whole == DateTime.to_iso8601(whole)

      {loaded_precise, stored_precise} = written_back_with_stored(:utc_usec_field, precise)

      assert loaded_precise == precise
      assert loaded_precise.microsecond == precise.microsecond
      assert stored_precise == DateTime.to_iso8601(precise)
    end
  end

  # --- 7. JSON-backed maps and arrays ----------------------------------------

  # `:map` is JSON text. Any value JSON can express — nested objects and
  # arrays, unicode keys, nulls, floats — comes back equal.
  property "a string-keyed map comes back equal to itself" do
    check all(value <- json_object(), max_runs: @runs) do
      {loaded, stored} = written_back_with_stored(:map_field, value)

      assert loaded == value
      assert {:ok, ^value} = Jason.decode(stored)
    end
  end

  # JSON has no atom keys, so a map written with them reads back string-keyed.
  # That is a projection, not a loss: the law names the exact map that comes
  # back.
  property "an atom-keyed map comes back string-keyed" do
    check all(value <- atom_keyed_object(), max_runs: @runs) do
      expected = Map.new(value, fn {key, inner} -> {Atom.to_string(key), inner} end)

      assert written_back(:map_field, value) == expected
    end
  end

  # The typed variants declare what the values are, and the declared type is
  # what comes back.
  property "typed maps and arrays come back equal to themselves" do
    check all(
            strings <- json_string_object(),
            ints <- list_of(int_element(), max_length: 6),
            texts <- list_of(text_element(), max_length: 6),
            floats <- list_of(float_element(), max_length: 6),
            max_runs: @runs
          ) do
      assert written_back(:map_str_field, strings) == strings
      assert written_back(:arr_int_field, ints) == ints
      assert written_back(:arr_str_field, texts) == texts
      assert written_back(:arr_float_field, floats) == floats
    end
  end

  # --- 8. binary_id ----------------------------------------------------------

  # `:binary_id` keeps the 36-character form on the Elixir side whatever the
  # configured storage mode is. The generator builds the string from raw bytes
  # so a failing case is reproducible from the seed.
  property "a binary_id comes back equal to itself" do
    check all(value <- uuid_value(), max_runs: @runs) do
      assert written_back(:bid_field, value) == value
    end
  end

  # The two UUID generators the library ships have to survive the same trip.
  test "both shipped UUID generators round-trip as binary_id" do
    v4 = Ecto.UUID.generate()
    v7 = XqliteEcto3.UUIDv7.generate()

    assert written_back(:bid_field, v4) == v4
    assert written_back(:bid_field, v7) == v7
  end

  # --- 8b. Ecto.UUID ---------------------------------------------------------

  # A field declared as `Ecto.UUID` goes through a different dumper and loader
  # than `:binary_id` does, so it needs its own law: the string form survives
  # the trip in both directions.
  property "an Ecto.UUID field comes back equal to itself" do
    check all(value <- uuid_value(), max_runs: @runs) do
      {loaded, stored} = written_back_with_stored(:euuid_field, value)

      assert loaded == value
      assert stored == value
    end
  end

  # Upper case is a legal way to write a UUID, and `Ecto.UUID` accepts it —
  # but it normalizes on the way out, not on the way in, so the database keeps
  # the upper-case text while the field reads back lower-cased. That is the
  # opposite of `Types.UUID`, which normalizes before writing, and the two
  # laws are worth having side by side.
  property "an upper-case Ecto.UUID is stored as written and read back lower-cased" do
    check all(value <- uuid_value(), max_runs: div(@runs, 2)) do
      upper = String.upcase(value)

      {loaded, stored} = written_back_with_stored(:euuid_field, upper)

      assert loaded == value
      assert stored == upper
    end
  end

  test "a nil Ecto.UUID stays nil" do
    assert written_back(:euuid_field, nil) == nil
  end

  # --- 9. Duration -----------------------------------------------------------

  # Duration is an int64 nanosecond count in and an int64 nanosecond count
  # out, with nothing in between to lose precision. The int64 extremes are
  # about 292 years of span, which is the documented range.
  property "a Duration comes back as the same nanosecond count" do
    check all(value <- int_value(), max_runs: @runs) do
      {loaded, stored} = written_back_with_stored(:dur_field, value)

      assert loaded == value
      assert stored == value
    end
  end

  # --- 10. Instant -----------------------------------------------------------

  # Instant stores full nanoseconds but loads a `DateTime`, and `DateTime`
  # only carries microseconds — so the read-back is the write rounded down to
  # a whole microsecond. Rounded *down*, not toward zero: a negative
  # nanosecond count moves earlier, never later. The stored column still holds
  # every nanosecond, which is what the type's docs promise, so that is
  # checked too.
  property "an Instant reads back as its nanosecond count floored to microseconds" do
    check all(value <- int_value(), max_runs: @runs) do
      {loaded, stored} = written_back_with_stored(:inst_field, value)

      assert stored == value

      case value do
        nil ->
          assert loaded == nil

        ns ->
          assert %DateTime{} = loaded
          assert loaded.time_zone == "Etc/UTC"
          assert loaded.utc_offset == 0
          assert DateTime.to_unix(loaded, :nanosecond) == Integer.floor_div(ns, 1000) * 1000
      end
    end
  end

  # --- 11. TimestampTZ -------------------------------------------------------

  # The flagship claim: the offset you wrote survives into the database. It
  # cannot survive into the loaded value, because `DateTime.from_iso8601/1`
  # normalizes to UTC on the way back, so the law has two halves that have to
  # hold together.
  #
  #   * The stored text ends in the offset that was written, computed here
  #     from the offset in seconds rather than by re-running the type.
  #   * The loaded value is UTC, is the same instant, and carries the same
  #     microsecond field — value and precision both.
  #
  # Dates stay inside years 1000-9000 so that shifting by up to fourteen hours
  # cannot walk off either end of the calendar; the calendar edges are covered
  # by the plain date and datetime properties above, which do no shifting.
  property "a TimestampTZ keeps its offset in storage and reads back as UTC" do
    check all(
            {value, offset} <- offset_datetime(),
            max_runs: @runs
          ) do
      {loaded, stored} = written_back_with_stored(:tsz_field, value)

      assert String.ends_with?(stored, offset_designator(offset))
      assert stored == DateTime.to_iso8601(value)

      assert loaded.time_zone == "Etc/UTC"
      assert loaded.zone_abbr == "UTC"
      assert loaded.utc_offset == 0
      assert loaded.std_offset == 0
      assert loaded.microsecond == value.microsecond
      assert DateTime.compare(loaded, value) == :eq
      assert DateTime.to_unix(loaded, :microsecond) == DateTime.to_unix(value, :microsecond)
    end
  end

  test "a nil TimestampTZ stays nil" do
    assert written_back(:tsz_field, nil) == nil
  end

  # --- 12. Types.Array -------------------------------------------------------

  # With no `:element` the list is whatever JSON can carry, nested included.
  property "an untyped Array comes back equal to itself" do
    check all(value <- json_list(), max_runs: @runs) do
      {loaded, stored} = written_back_with_stored(:xarr_any_field, value)

      assert loaded == value
      assert {:ok, ^value} = Jason.decode(stored)
    end
  end

  # Integer, string and boolean elements come back as they went in, nil
  # elements included — `:element` type-checks the items it has and lets nil
  # through.
  property "an element-typed Array comes back equal to itself" do
    check all(
            ints <- list_of(int_element(), max_length: 6),
            texts <- list_of(text_element(), max_length: 6),
            flags <- list_of(bool_element(), max_length: 6),
            max_runs: @runs
          ) do
      assert written_back(:xarr_int_field, ints) == ints
      assert written_back(:xarr_str_field, texts) == texts
      assert written_back(:xarr_bool_field, flags) == flags
    end
  end

  # `element: :float` is the one Array mode that changes the value: a whole
  # number in the list is widened to a float on the way back. The law names
  # the widened list exactly.
  property "a float-element Array widens whole numbers to floats" do
    check all(value <- list_of(number_element(), max_length: 6), max_runs: @runs) do
      expected = Enum.map(value, &widen/1)

      assert written_back(:xarr_float_field, value) == expected
    end
  end

  defp widen(nil), do: nil
  defp widen(number), do: number * 1.0

  test "a nil Array stays nil at every element type" do
    assert written_back(:xarr_any_field, nil) == nil
    assert written_back(:xarr_int_field, nil) == nil
    assert written_back(:xarr_str_field, nil) == nil
    assert written_back(:xarr_float_field, nil) == nil
    assert written_back(:xarr_bool_field, nil) == nil
  end

  # --- 13. Types.UUID --------------------------------------------------------

  # Both storage modes hand back the same 36-character string; only the bytes
  # on disk differ. The `:binary` column holds the raw sixteen bytes, which is
  # the whole point of that mode, so the stored size is part of the law.
  property "a Types.UUID comes back as the same string in both storage modes" do
    check all(value <- uuid_value(), max_runs: @runs) do
      {loaded_string, stored_string} = written_back_with_stored(:uuid_str_field, value)

      assert loaded_string == value
      assert stored_string == value

      {loaded_binary, stored_binary} = written_back_with_stored(:uuid_bin_field, value)

      assert loaded_binary == value
      assert stored_binary == Ecto.UUID.dump!(value)
      assert byte_size(stored_binary) == 16
    end
  end

  # An upper-case UUID is a legal way to write one, and both modes normalize
  # it to the lower-case form on the way in, so that is what storage and the
  # read-back both hold.
  property "an upper-case Types.UUID is normalized to lower case" do
    check all(value <- uuid_value(), max_runs: div(@runs, 2)) do
      upper = String.upcase(value)

      {loaded_string, stored_string} = written_back_with_stored(:uuid_str_field, upper)

      assert loaded_string == value
      assert stored_string == value
      assert written_back(:uuid_bin_field, upper) == value
    end
  end

  test "a nil Types.UUID stays nil in both storage modes" do
    assert written_back(:uuid_str_field, nil) == nil
    assert written_back(:uuid_bin_field, nil) == nil
  end

  # --- generators ------------------------------------------------------------

  defp int_value do
    frequency([
      {5, integer(@i64_min..@i64_max)},
      {3, integer(-1_000_000..1_000_000)},
      {2,
       member_of([
         0,
         1,
         -1,
         @i64_max,
         @i64_min,
         2_147_483_647,
         -2_147_483_648,
         4_294_967_296,
         -4_294_967_296,
         999,
         -999,
         1000,
         -1000,
         1500,
         -1500
       ])},
      {1, constant(nil)}
    ])
  end

  defp float_value do
    frequency([
      {5, bounded_float()},
      {2, float(min: -1.0e15, max: 1.0e15)},
      {2,
       member_of([
         0.0,
         -0.0,
         1.0,
         -1.0,
         0.5,
         -0.5,
         1.0e300,
         -1.0e300,
         5.0e-324,
         2.2250738585072014e-308,
         1.7976931348623157e308,
         -1.7976931348623157e308,
         300_000.0
       ])},
      {1, constant(nil)}
    ])
  end

  @text_edges [
    "",
    " ",
    "O'Brien",
    ~s("quoted"),
    "back\\slash",
    "a\nb\tc\r",
    <<0>>,
    "a\0b",
    "héllo 世界 🌍",
    "ß İ Ελληνικά",
    "😀😀😀",
    "NULL",
    "0"
  ]

  defp text_value do
    frequency([
      {5, string(:utf8, max_length: 200)},
      {2, string(:utf8, min_length: 1, max_length: 120)},
      {1, member_of(@text_edges)},
      {1, map(integer(200..2000), fn size -> String.duplicate("üx", size) end)},
      {1, constant(nil)}
    ])
  end

  defp binary_value do
    frequency([
      {5, binary(max_length: 200)},
      {2, binary(min_length: 1, max_length: 200)},
      {1,
       member_of(["", <<0, 0, 0>>, <<0xFF, 0xFE>>, <<0x80>>, <<0xC3>>, <<0, 1, 2, 255, 254>>])},
      {1, map(integer(200..2000), fn size -> :binary.copy(<<0xFF, 0x00>>, size) end)},
      {1, constant(nil)}
    ])
  end

  # Fifteen significant digits is the width a float64 always round-trips
  # exactly, so every decimal this builds is one the adapter accepts.
  defp representable_decimal do
    gen all(
          sign <- member_of([1, -1]),
          ndigits <- integer(1..15),
          coefficient <- integer(Integer.pow(10, ndigits - 1)..(Integer.pow(10, ndigits) - 1)),
          exponent <- integer(-15..15)
        ) do
      Decimal.new(sign, coefficient, exponent)
    end
  end

  defp date_value do
    frequency([
      {7, calendar_date(1..9999)},
      {3, member_of([~D[0001-01-01], ~D[1970-01-01], ~D[2024-02-29], ~D[9999-12-31]])}
    ])
  end

  defp calendar_date(years) do
    gen all(
          year <- integer(years),
          month <- integer(1..12),
          day <- integer(1..28)
        ) do
      Date.new!(year, month, day)
    end
  end

  defp second_time do
    gen all(
          hour <- integer(0..23),
          minute <- integer(0..59),
          second <- integer(0..59)
        ) do
      Time.new!(hour, minute, second)
    end
  end

  defp microsecond_time do
    gen all(
          whole <- second_time(),
          microsecond <- microsecond_value()
        ) do
      %{whole | microsecond: {microsecond, 6}}
    end
  end

  defp microsecond_value do
    frequency([
      {6, integer(0..999_999)},
      {4, member_of([0, 1, 999_999, 500_000, 1000, 999_000, 123_456])}
    ])
  end

  defp second_naive_datetime do
    gen all(date <- date_value(), time <- second_time()) do
      NaiveDateTime.new!(date, time)
    end
  end

  defp microsecond_naive_datetime do
    gen all(date <- date_value(), time <- microsecond_time()) do
      NaiveDateTime.new!(date, time)
    end
  end

  defp second_utc_datetime do
    gen all(date <- date_value(), time <- second_time()) do
      DateTime.new!(date, time, "Etc/UTC")
    end
  end

  defp microsecond_utc_datetime do
    gen all(date <- date_value(), time <- microsecond_time()) do
      DateTime.new!(date, time, "Etc/UTC")
    end
  end

  # A `DateTime` at an arbitrary whole-minute offset, up to the fourteen hours
  # real zones actually reach. Built as a struct because shifting into a named
  # zone would need a time-zone database, which the test suite does not carry
  # — and the type reads only the offset fields, never the zone name, which
  # its own docs say is never preserved.
  defp offset_datetime do
    gen all(
          date <- calendar_date(1000..9000),
          time <- second_time(),
          microsecond <- one_of([constant({0, 0}), map(microsecond_value(), &{&1, 6})]),
          offset <- offset_seconds()
        ) do
      value = %DateTime{
        year: date.year,
        month: date.month,
        day: date.day,
        hour: time.hour,
        minute: time.minute,
        second: time.second,
        microsecond: microsecond,
        time_zone: zone_name(offset),
        zone_abbr: zone_abbr(offset),
        utc_offset: offset,
        std_offset: 0,
        calendar: Calendar.ISO
      }

      {value, offset}
    end
  end

  defp offset_seconds do
    frequency([
      {6, map(integer(-840..840), fn minutes -> minutes * 60 end)},
      {4, member_of([0, 3600, -3600, -18_000, 19_800, -50_400, 50_400, -1800, 2700])}
    ])
  end

  defp zone_name(0), do: "Etc/UTC"
  defp zone_name(_offset), do: "Etc/Fixed"

  defp zone_abbr(0), do: "UTC"
  defp zone_abbr(offset), do: offset_designator(offset)

  defp offset_designator(0), do: "Z"

  defp offset_designator(seconds) do
    sign = if seconds < 0, do: "-", else: "+"
    magnitude = abs(seconds)
    hours = div(magnitude, 3600)
    minutes = div(rem(magnitude, 3600), 60)

    sign <> two_digits(hours) <> ":" <> two_digits(minutes)
  end

  defp two_digits(number) do
    number
    |> Integer.to_string()
    |> String.pad_leading(2, "0")
  end

  # `tree/2` deepens with the generation size, which climbs with the run
  # index, so an unbounded JSON generator turns a long property run into a few
  # enormous documents. Capping the size keeps every case small enough that
  # the run count, not the document size, is what the budget buys.
  defp bounded(generator, cap) do
    scale(generator, fn size -> min(size, cap) end)
  end

  defp json_scalar do
    one_of([integer(), float(), string(:utf8, max_length: 12), boolean(), constant(nil)])
  end

  defp json_value do
    bounded(
      tree(json_scalar(), fn child ->
        one_of([
          list_of(child, max_length: 4),
          map_of(json_key(), child, max_length: 4)
        ])
      end),
      8
    )
  end

  defp json_object do
    bounded(map_of(json_key(), json_value(), max_length: 5), 10)
  end

  defp json_list do
    bounded(list_of(json_value(), max_length: 6), 10)
  end

  defp json_string_object do
    bounded(map_of(json_key(), string(:utf8, max_length: 12), max_length: 5), 10)
  end

  defp json_key do
    string(:utf8, min_length: 1, max_length: 8)
  end

  # A small fixed set of atoms, so the generator never creates new ones.
  # Built by zipping keys onto values rather than with `map_of/3`, which needs
  # distinct keys and gives up when the key space is this narrow.
  defp atom_keyed_object do
    gen all(
          keys <- list_of(member_of([:a, :b, :c, :alpha, :beta]), max_length: 5),
          values <- list_of(json_value(), length: length(keys))
        ) do
      pairs = Enum.zip(keys, values)
      Map.new(pairs)
    end
  end

  defp bounded_float do
    bounded(float(), 40)
  end

  defp int_element do
    frequency([
      {6, integer()},
      {3, member_of([0, 1, -1, @i64_max, @i64_min])},
      {1, constant(nil)}
    ])
  end

  defp text_element do
    frequency([
      {6, string(:utf8, max_length: 20)},
      {3, member_of(["", "héllo 世界 🌍", "a\nb", ~s("q"), "O'Brien"])},
      {1, constant(nil)}
    ])
  end

  defp float_element do
    frequency([
      {7, bounded_float()},
      {2, member_of([0.0, -0.0, 1.5, 1.0e300, 5.0e-324])},
      {1, constant(nil)}
    ])
  end

  defp number_element do
    frequency([
      {4, bounded_float()},
      {4, integer()},
      {1, member_of([0, 1, -1, 0.0, -0.0, 1.5, @i64_max])},
      {1, constant(nil)}
    ])
  end

  defp bool_element do
    frequency([{9, boolean()}, {1, constant(nil)}])
  end

  # Built from sixteen generated bytes rather than from a real UUID generator,
  # so a failing case replays from the seed.
  defp uuid_value do
    gen all(raw <- binary(length: 16)) do
      Ecto.UUID.cast!(raw)
    end
  end
end
