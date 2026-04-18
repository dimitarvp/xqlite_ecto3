defmodule XqliteEcto3.Types.InstantTest do
  use ExUnit.Case, async: true

  alias XqliteEcto3.Types.Instant

  @ns 1_750_000_000_123_456_789
  # 2025-06-15 12:26:40.123456789 UTC ≈
  @dt DateTime.from_unix!(@ns, :nanosecond)

  describe "type/0" do
    test "returns :integer (NUMERIC storage in SQLite)" do
      assert Instant.type() == :integer
    end
  end

  describe "cast/1" do
    test "nil passes through" do
      assert Instant.cast(nil) == {:ok, nil}
    end

    test "accepts DateTime (to ns via DateTime.to_unix)" do
      assert Instant.cast(@dt) == {:ok, DateTime.to_unix(@dt, :nanosecond)}
    end

    test "accepts integer as ns directly" do
      assert Instant.cast(@ns) == {:ok, @ns}
    end

    test "accepts {n, :nanosecond} tuple" do
      assert Instant.cast({@ns, :nanosecond}) == {:ok, @ns}
    end

    test "accepts {n, :microsecond} and scales" do
      assert Instant.cast({42, :microsecond}) == {:ok, 42_000}
    end

    test "accepts {n, :millisecond} and scales" do
      assert Instant.cast({42, :millisecond}) == {:ok, 42_000_000}
    end

    test "accepts {n, :second} and scales" do
      assert Instant.cast({42, :second}) == {:ok, 42_000_000_000}
    end

    test "rejects unknown units" do
      assert Instant.cast({5, :eon}) == :error
    end

    test "rejects garbage" do
      assert Instant.cast("not a time") == :error
      assert Instant.cast(%{}) == :error
      assert Instant.cast(3.14) == :error
    end
  end

  describe "dump/1" do
    test "nil passes through" do
      assert Instant.dump(nil) == {:ok, nil}
    end

    test "dumps integer verbatim" do
      assert Instant.dump(@ns) == {:ok, @ns}
    end

    test "rejects non-integer" do
      assert Instant.dump(@dt) == :error
      assert Instant.dump("1234567890") == :error
    end
  end

  describe "load/1" do
    test "nil passes through" do
      assert Instant.load(nil) == {:ok, nil}
    end

    test "loads integer as DateTime" do
      {:ok, dt} = Instant.load(@ns)
      # DateTime has microsecond precision — nanoseconds are truncated.
      assert dt.year == 2025
      assert dt.microsecond == {123_456, 6}
    end

    test "rejects non-integer" do
      assert Instant.load("123") == :error
      assert Instant.load(%{}) == :error
    end

    test "load round-trips integers lossly at the ns level" do
      # The stored ns ends in 789, but DateTime stops at microsecond.
      {:ok, dt} = Instant.load(@ns)
      {:ok, reloaded} = Instant.cast(dt)
      # We lost the last 3 ns digits (789) on the way through DateTime.
      assert reloaded == @ns - rem(@ns, 1_000)
    end
  end

  describe "round-trip via cast then dump" do
    test "DateTime round-trips" do
      {:ok, ns} = Instant.cast(@dt)
      {:ok, dumped} = Instant.dump(ns)
      assert is_integer(dumped)
      {:ok, loaded} = Instant.load(dumped)
      assert DateTime.compare(@dt, loaded) == :eq
    end

    test "integer round-trips exactly" do
      {:ok, ns} = Instant.cast(@ns)
      {:ok, dumped} = Instant.dump(ns)
      assert dumped == @ns
    end
  end

  describe "equal?/2" do
    test "compares integers" do
      assert Instant.equal?(@ns, @ns) == true
      assert Instant.equal?(@ns, @ns + 1) == false
    end

    test "nil equality" do
      assert Instant.equal?(nil, nil) == true
      assert Instant.equal?(nil, @ns) == false
    end
  end

  describe "round-trip via TestRepo" do
    setup do
      alias Ecto.Integration.TestRepo
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
      TestRepo.query!("CREATE TEMP TABLE inst_test(id INTEGER PRIMARY KEY, ts INTEGER)")
      :ok
    end

    test "insert and select int ns through TestRepo.query!" do
      alias Ecto.Integration.TestRepo

      {:ok, dumped} = Instant.dump(@ns)
      TestRepo.query!("INSERT INTO inst_test(ts) VALUES (?1)", [dumped])
      %{rows: [[stored]]} = TestRepo.query!("SELECT ts FROM inst_test")
      assert stored == @ns
    end
  end
end
