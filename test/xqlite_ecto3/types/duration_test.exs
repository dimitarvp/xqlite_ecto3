defmodule XqliteEcto3.Types.DurationTest do
  use XqliteEcto3.AdapterCase, async: true

  alias XqliteEcto3.Types.Duration, as: D

  describe "type/0" do
    test "returns :integer" do
      assert D.type() == :integer
    end
  end

  describe "cast/1" do
    test "nil passes through" do
      assert D.cast(nil) == {:ok, nil}
    end

    test "integer is treated as ns" do
      assert D.cast(42) == {:ok, 42}
      assert D.cast(-1_000) == {:ok, -1_000}
    end

    test "tuple with :nanosecond" do
      assert D.cast({42, :nanosecond}) == {:ok, 42}
    end

    test "tuple with :microsecond scales by 1_000" do
      assert D.cast({42, :microsecond}) == {:ok, 42_000}
    end

    test "tuple with :millisecond scales by 1_000_000" do
      assert D.cast({42, :millisecond}) == {:ok, 42_000_000}
    end

    test "tuple with :second scales by 10^9" do
      assert D.cast({42, :second}) == {:ok, 42_000_000_000}
    end

    test "tuple with :minute scales by 60*10^9" do
      assert D.cast({5, :minute}) == {:ok, 5 * 60 * 1_000_000_000}
    end

    test "tuple with :hour scales by 3600*10^9" do
      assert D.cast({2, :hour}) == {:ok, 2 * 3600 * 1_000_000_000}
    end

    test "tuple with :day scales by 86400*10^9" do
      assert D.cast({1, :day}) == {:ok, 86_400 * 1_000_000_000}
    end

    test "unknown tuple unit rejects" do
      assert D.cast({5, :fortnight}) == :error
    end

    test "rejects garbage" do
      assert D.cast("5 minutes") == :error
      assert D.cast(3.14) == :error
      assert D.cast(%{}) == :error
    end

    if Code.ensure_loaded?(Duration) do
      test "accepts Elixir Duration with zero calendar fields" do
        d = %Duration{
          year: 0,
          month: 0,
          week: 0,
          day: 1,
          hour: 2,
          minute: 30,
          second: 45,
          microsecond: {123_456, 6}
        }

        expected =
          1 * 86_400 * 1_000_000_000 +
            2 * 3600 * 1_000_000_000 +
            30 * 60 * 1_000_000_000 +
            45 * 1_000_000_000 +
            123_456 * 1_000

        assert D.cast(d) == {:ok, expected}
      end

      test "rejects Duration with non-zero year" do
        d = %Duration{year: 1, microsecond: {0, 0}}
        assert D.cast(d) == :error
      end

      test "rejects Duration with non-zero month" do
        d = %Duration{month: 1, microsecond: {0, 0}}
        assert D.cast(d) == :error
      end

      test "rejects Duration with non-zero week" do
        d = %Duration{week: 1, microsecond: {0, 0}}
        assert D.cast(d) == :error
      end
    end
  end

  describe "dump/1" do
    test "nil passes through" do
      assert D.dump(nil) == {:ok, nil}
    end

    test "integer dumps as-is" do
      assert D.dump(12_345) == {:ok, 12_345}
    end

    test "non-integer rejects" do
      assert D.dump("5s") == :error
      assert D.dump(3.14) == :error
    end
  end

  describe "load/1" do
    test "nil passes through" do
      assert D.load(nil) == {:ok, nil}
    end

    test "integer loads as-is" do
      assert D.load(12_345) == {:ok, 12_345}
    end

    test "non-integer rejects" do
      assert D.load("12345") == :error
    end
  end

  describe "round-trip" do
    test "integer round-trip is exact" do
      {:ok, ns} = D.cast(42_000_000_000)
      {:ok, dumped} = D.dump(ns)
      {:ok, loaded} = D.load(dumped)
      assert loaded == 42_000_000_000
    end

    test "tuple input round-trips to ns int" do
      {:ok, ns} = D.cast({5, :minute})
      assert ns == 5 * 60 * 1_000_000_000
      {:ok, dumped} = D.dump(ns)
      {:ok, loaded} = D.load(dumped)
      assert loaded == ns
    end
  end

  describe "equal?/2" do
    test "compares integers" do
      assert D.equal?(42, 42) == true
      assert D.equal?(42, 43) == false
    end

    test "nil equality" do
      assert D.equal?(nil, nil) == true
      assert D.equal?(nil, 42) == false
    end
  end

  describe "round-trip via TestRepo" do
    setup do
      alias Ecto.Integration.TestRepo

      TestRepo.query!("CREATE TEMP TABLE dur_test(id INTEGER PRIMARY KEY, d INTEGER)")
      :ok
    end

    test "insert and select int ns through TestRepo.query!" do
      {:ok, ns} = D.cast({5, :minute})
      {:ok, dumped} = D.dump(ns)
      TestRepo.query!("INSERT INTO dur_test(d) VALUES (?1)", [dumped])
      %{rows: [[stored]]} = TestRepo.query!("SELECT d FROM dur_test")
      assert stored == 5 * 60 * 1_000_000_000
    end
  end
end
