defmodule XqliteEcto3.Types.TimestampTZTest do
  use XqliteEcto3.AdapterCase, async: true

  alias XqliteEcto3.Types.TimestampTZ, as: TS

  @utc_dt DateTime.new!(~D[2024-01-15], ~T[10:30:00.000000], "Etc/UTC")
  @utc_iso "2024-01-15T10:30:00.000000Z"

  describe "type/0" do
    test "returns :string (SQLite TEXT storage)" do
      assert TS.type() == :string
    end
  end

  describe "cast/1" do
    test "nil passes through" do
      assert TS.cast(nil) == {:ok, nil}
    end

    test "accepts a UTC DateTime" do
      assert TS.cast(@utc_dt) == {:ok, @utc_dt}
    end

    test "accepts an ISO 8601 string" do
      assert {:ok, %DateTime{year: 2024, month: 1, day: 15}} = TS.cast(@utc_iso)
    end

    test "accepts an ISO 8601 string with offset" do
      {:ok, dt} = TS.cast("2024-01-15T10:30:00-05:00")
      # DateTime.from_iso8601/1 normalizes to UTC.
      assert dt.time_zone == "Etc/UTC"
      # 10:30 at -05:00 is 15:30 UTC.
      assert dt.hour == 15
      assert dt.minute == 30
    end

    test "rejects garbage" do
      assert TS.cast("not-a-date") == :error
      assert TS.cast(12_345) == :error
      assert TS.cast(%{}) == :error
    end
  end

  describe "dump/1" do
    test "nil passes through" do
      assert TS.dump(nil) == {:ok, nil}
    end

    test "dumps UTC DateTime as ISO 8601" do
      {:ok, dumped} = TS.dump(@utc_dt)
      assert dumped == @utc_iso
    end

    test "dumps non-UTC DateTime preserving offset" do
      # Construct a DateTime explicitly in a non-UTC zone without tzdb.
      dt = %DateTime{
        year: 2024,
        month: 1,
        day: 15,
        hour: 10,
        minute: 30,
        second: 0,
        microsecond: {0, 6},
        time_zone: "Etc/GMT+5",
        zone_abbr: "-05",
        utc_offset: -18_000,
        std_offset: 0,
        calendar: Calendar.ISO
      }

      {:ok, dumped} = TS.dump(dt)
      # ISO 8601 encodes the offset as part of the string.
      assert dumped =~ "-05:00"
    end

    test "rejects non-DateTime input" do
      assert TS.dump("2024-01-15T10:30:00Z") == :error
      assert TS.dump(12_345) == :error
    end
  end

  describe "load/1" do
    test "nil passes through" do
      assert TS.load(nil) == {:ok, nil}
    end

    test "parses ISO 8601 back to a DateTime" do
      {:ok, dt} = TS.load(@utc_iso)
      assert %DateTime{year: 2024, month: 1, day: 15, hour: 10, minute: 30} = dt
    end

    test "parses ISO 8601 with offset to UTC-normalized DateTime" do
      {:ok, dt} = TS.load("2024-01-15T10:30:00-05:00")
      assert dt.time_zone == "Etc/UTC"
      assert dt.hour == 15
    end

    test "rejects unparseable strings" do
      assert TS.load("not-a-date") == :error
      assert TS.load(12_345) == :error
    end
  end

  describe "round-trip" do
    test "UTC DateTime survives dump/load" do
      {:ok, dumped} = TS.dump(@utc_dt)
      {:ok, loaded} = TS.load(dumped)
      assert DateTime.compare(@utc_dt, loaded) == :eq
    end

    test "non-UTC offset is preserved in the stored string" do
      dt = %DateTime{
        year: 2024,
        month: 1,
        day: 15,
        hour: 10,
        minute: 30,
        second: 0,
        microsecond: {0, 6},
        time_zone: "Etc/GMT+5",
        zone_abbr: "-05",
        utc_offset: -18_000,
        std_offset: 0,
        calendar: Calendar.ISO
      }

      {:ok, dumped} = TS.dump(dt)
      assert dumped =~ "-05:00"

      # After load, the DateTime is UTC-normalized but represents the same instant.
      {:ok, loaded} = TS.load(dumped)
      assert loaded.time_zone == "Etc/UTC"
      assert DateTime.compare(dt, loaded) == :eq
    end

    test "microsecond precision preserved" do
      dt = DateTime.new!(~D[2024-06-15], ~T[14:23:45.678901], "Etc/UTC")
      {:ok, dumped} = TS.dump(dt)
      assert dumped =~ ".678901"

      {:ok, loaded} = TS.load(dumped)
      assert loaded.microsecond == {678_901, 6}
    end

    test "zero-precision DateTime dumps without fractional seconds" do
      dt = DateTime.new!(~D[2024-06-15], ~T[14:23:45], "Etc/UTC")
      {:ok, dumped} = TS.dump(dt)
      refute dumped =~ "."
    end
  end

  describe "equal?/2" do
    test "two equal DateTimes compare equal" do
      assert TS.equal?(@utc_dt, @utc_dt) == true
    end

    test "different DateTimes compare unequal" do
      other = DateTime.new!(~D[2024-01-16], ~T[10:30:00.000000], "Etc/UTC")
      assert TS.equal?(@utc_dt, other) == false
    end

    test "nil equality" do
      assert TS.equal?(nil, nil) == true
      assert TS.equal?(nil, @utc_dt) == false
    end
  end

  describe "round-trip via TestRepo" do
    setup do
      alias Ecto.Integration.TestRepo

      TestRepo.query!("CREATE TEMP TABLE tsz_test(id INTEGER PRIMARY KEY, t TEXT)")
      :ok
    end

    test "DateTime with offset survives TEXT-column round-trip" do
      dt = %DateTime{
        year: 2024,
        month: 1,
        day: 15,
        hour: 10,
        minute: 30,
        second: 0,
        microsecond: {123_456, 6},
        time_zone: "Etc/GMT+5",
        zone_abbr: "-05",
        utc_offset: -18_000,
        std_offset: 0,
        calendar: Calendar.ISO
      }

      {:ok, dumped} = TS.dump(dt)
      TestRepo.query!("INSERT INTO tsz_test(t) VALUES (?1)", [dumped])
      %{rows: [[stored]]} = TestRepo.query!("SELECT t FROM tsz_test")

      assert stored == dumped
      assert stored =~ "-05:00"
      assert stored =~ ".123456"

      {:ok, loaded} = TS.load(stored)
      assert DateTime.compare(dt, loaded) == :eq
    end
  end
end
