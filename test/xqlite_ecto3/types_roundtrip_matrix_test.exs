defmodule XqliteEcto3.TypesRoundtripMatrixTest do
  @moduledoc """
  Table-driven dump -> store -> load == identity matrix per Ecto type,
  exercised through the real repo. (`stream_data` is not a dependency, so
  this is exhaustive example-based rather than generative.)

  The decimal block covers SQLite's lack of an exact-decimal storage class:
  a `:decimal` migration column has NUMERIC affinity, so values beyond
  float64's exact precision (~15 significant digits) cannot be stored
  losslessly. The adapter refuses those at the binding boundary rather than
  rounding them, so the block asserts both the exact round-trips and the
  loud rejection.
  """
  use XqliteEcto3.AdapterCase, async: true
  use ExUnitProperties

  defmodule Rec do
    use Ecto.Schema

    @primary_key {:id, :id, autogenerate: true}
    schema "roundtrip_matrix" do
      field(:int_field, :integer)
      field(:str_field, :string)
      field(:bin_field, :binary)
      field(:bool_field, :boolean)
      field(:map_field, :map)
      field(:arr_field, {:array, :integer})
      # NOTE: DECIMAL column — the exact type a `add :price, :decimal`
      # migration produces (NUMERIC affinity), NOT the TEXT column the older
      # types_test uses. This is what real users get.
      field(:dec_field, :decimal)
    end
  end

  defmodule EdgeRec do
    use Ecto.Schema

    @primary_key {:id, :id, autogenerate: true}
    schema "roundtrip_edges" do
      field(:dec_text, :decimal)
      field(:dec_num, :decimal)
      field(:dec_arr, {:array, :decimal})
      field(:dec_map, :map)
    end
  end

  defmodule EdgeRaw do
    use Ecto.Schema

    @primary_key {:id, :id, autogenerate: true}
    schema "roundtrip_edges" do
      field(:dec_text, :string)
      field(:dec_num, :string)
    end
  end

  setup_all do
    create_table!(
      "roundtrip_matrix",
      "id INTEGER PRIMARY KEY AUTOINCREMENT, int_field INTEGER, str_field TEXT, " <>
        "bin_field BLOB, bool_field INTEGER, map_field TEXT, arr_field TEXT, dec_field DECIMAL"
    )

    create_table!(
      "roundtrip_edges",
      "id INTEGER PRIMARY KEY AUTOINCREMENT, dec_text TEXT, dec_num DECIMAL, " <>
        "dec_arr TEXT, dec_map TEXT"
    )
  end

  setup do
    clear_table!("roundtrip_matrix")
  end

  defp roundtrip(field, value) do
    {:ok, rec} = Repo.insert(Ecto.Changeset.change(%Rec{}, %{field => value}))
    Map.fetch!(Repo.get(Rec, rec.id), field)
  end

  describe "integer round-trip" do
    for {label, value} <- [
          {"i64 max", 9_223_372_036_854_775_807},
          {"i64 min", -9_223_372_036_854_775_808},
          {"zero", 0},
          {"negative", -42},
          {"nil", nil}
        ] do
      test label do
        assert roundtrip(:int_field, unquote(value)) == unquote(value)
      end
    end
  end

  describe "string round-trip" do
    for {label, value} <- [
          {"empty", ""},
          {"unicode", "héllo 世界 🌍"},
          {"quotes and backslash", "O'Brien \"q\" \\z"},
          {"newlines and tabs", "a\nb\tc"},
          {"nil", nil}
        ] do
      test label do
        assert roundtrip(:str_field, unquote(value)) == unquote(value)
      end
    end
  end

  describe "binary round-trip" do
    for {label, value} <- [
          {"empty", ""},
          {"raw bytes", <<0, 1, 2, 255, 254>>},
          {"invalid utf-8", <<0xFF, 0xFE>>},
          {"nul bytes", <<0, 0, 0>>}
        ] do
      test label do
        assert roundtrip(:bin_field, unquote(value)) == unquote(value)
      end
    end
  end

  describe "boolean round-trip" do
    for {label, value} <- [{"true", true}, {"false", false}, {"nil", nil}] do
      test label do
        assert roundtrip(:bool_field, unquote(value)) == unquote(value)
      end
    end

    test "a stored value outside 0/1/NULL fails the load with Ecto's typed error" do
      Repo.query!("INSERT INTO roundtrip_matrix (bool_field) VALUES (2)")
      Repo.query!("INSERT INTO roundtrip_matrix (bool_field) VALUES ('true')")

      assert_raise ArgumentError, fn -> Repo.all(Rec) end
    end
  end

  describe "map (JSON) round-trip" do
    test "string-keyed map round-trips" do
      value = %{"a" => 1, "nested" => %{"b" => [1, 2, 3]}, "f" => 1.5, "n" => nil}
      assert roundtrip(:map_field, value) == value
    end

    test "empty map round-trips" do
      assert roundtrip(:map_field, %{}) == %{}
    end

    # JSON has no atom keys; Ecto's :map contract is string-keyed after a
    # DB round-trip. Pin it so the behaviour is explicit, not surprising.
    test "atom-keyed map comes back string-keyed" do
      assert roundtrip(:map_field, %{a: 1, b: 2}) == %{"a" => 1, "b" => 2}
    end
  end

  describe "array (JSON) round-trip" do
    for {label, value} <- [
          {"ints", [1, 2, 3]},
          {"empty", []},
          {"negatives", [-1, 0, 1]}
        ] do
      test label do
        assert roundtrip(:arr_field, unquote(value)) == unquote(value)
      end
    end
  end

  describe "decimal precision" do
    # Common money and anything within ~15 significant digits round-trips
    # exactly through the DECIMAL column.
    for {label, str} <- [
          {"simple", "1.5"},
          {"two-place money", "19.99"},
          {"large money within 15 sig digits", "9999999999999.99"},
          {"tiny", "0.000000000000000001"}
        ] do
      test "round-trips: #{label}" do
        dec = Decimal.new(unquote(str))
        assert Decimal.equal?(roundtrip(:dec_field, dec), dec)
      end
    end

    test "nil decimal round-trips" do
      assert roundtrip(:dec_field, nil) == nil
    end

    # Beyond float64's exact precision the value cannot be stored without
    # rounding. The adapter refuses it at the binding boundary rather than
    # writing a silently-wrong number — before this refusal existed, the same
    # insert stored a rounded value (~1.2345678901234568e19) and the mismatch
    # went unnoticed.
    test "beyond ~15 significant digits, the write is refused, not rounded" do
      dec = Decimal.new("12345678901234567890.12345")

      err =
        assert_raise XqliteEcto3.DecimalPrecisionError, fn ->
          roundtrip(:dec_field, dec)
        end

      assert Decimal.equal?(err.value, dec)
    end

    # A 17-digit integral value can round to a float64 neighbor whose
    # SHORTEST printing echoes the original digits — the old guard compared
    # against that printing and accepted. NUMERIC affinity then demotes the
    # integral float to INTEGER, which reads back with the true rounded
    # digits, off by two. Found by the boundary property at 2000 runs.
    test "an integral value that rounds to a float64 neighbor is refused" do
      dec = Decimal.new("20700317912310410.0")

      refute XqliteEcto3.DecimalPrecision.representable?(dec)

      err =
        assert_raise XqliteEcto3.DecimalPrecisionError, fn ->
          roundtrip(:dec_field, dec)
        end

      assert Decimal.equal?(err.value, dec)
    end

    # Fuzz the ~15–17 significant-digit boundary where the accept/reject verdict
    # flips. The invariant is total: for ANY finite Decimal, an insert either
    # stores a value equal to it or raises the precision error — there is no
    # third "stored but silently different" outcome. A guard false-accept (a
    # value the guard passes but the DECIMAL column rounds) would fail the
    # equality assertion; a guard false-reject would fail nothing here but is
    # covered by the exact-round-trip examples above.
    property "every finite Decimal either round-trips exactly or is refused, never silently mismatched" do
      check all(dec <- finite_decimal(), max_runs: 2000) do
        if XqliteEcto3.DecimalPrecision.representable?(dec) do
          loaded = roundtrip(:dec_field, dec)

          assert Decimal.equal?(loaded, dec),
                 "representable Decimal did not round-trip: " <>
                   "#{Decimal.to_string(dec, :normal)} stored as #{inspect(loaded)}"
        else
          assert_raise XqliteEcto3.DecimalPrecisionError, fn -> roundtrip(:dec_field, dec) end
        end
      end
    end
  end

  # sign * coefficient * 10^exponent, with the coefficient's digit count swept
  # across 1..25 so the stream straddles float64's ~15–17 significant-digit
  # exactness threshold in both directions.
  defp finite_decimal do
    gen all(
          sign <- StreamData.member_of([1, -1]),
          ndigits <- StreamData.integer(1..25),
          coefficient <-
            StreamData.integer(Integer.pow(10, ndigits - 1)..(Integer.pow(10, ndigits) - 1)),
          exponent <- StreamData.integer(-20..20)
        ) do
      Decimal.new(sign, coefficient, exponent)
    end
  end

  describe "decimal edge contracts" do
    setup do
      clear_table!("roundtrip_edges")
    end

    # SQLite renders the bound float to text on a TEXT-affinity column, so
    # some accepted decimals come back as a different number — a documented
    # limitation; the exact escape hatch is a :string FIELD.
    test "a :decimal field over a TEXT column drifts; a :string field is exact" do
      drifter = Decimal.new("9999999999999.99")

      {:ok, rec} = Repo.insert(Ecto.Changeset.change(%EdgeRec{}, %{dec_text: drifter}))
      loaded = Map.fetch!(Repo.get(EdgeRec, rec.id), :dec_text)
      refute Decimal.equal?(loaded, drifter)

      {:ok, raw} =
        Repo.insert(Ecto.Changeset.change(%EdgeRaw{}, %{dec_text: "9999999999999.99"}))

      assert Map.fetch!(Repo.get(EdgeRaw, raw.id), :dec_text) == "9999999999999.99"

      beyond = Decimal.new("12345678901234567890.12345")

      assert_raise XqliteEcto3.DecimalPrecisionError, fn ->
        Repo.insert(Ecto.Changeset.change(%EdgeRec{}, %{dec_text: beyond}))
      end
    end

    test "non-numeric stored values under :decimal fail the load with Ecto's typed error" do
      Repo.query!("INSERT INTO roundtrip_edges (dec_num) VALUES (X'DEADBEEF')")
      Repo.query!("INSERT INTO roundtrip_edges (dec_num) VALUES ('not a number')")

      assert_raise ArgumentError, fn -> Repo.all(EdgeRec) end

      # The same rows are readable — only the decimal loader must refuse.
      raw = Repo.all(EdgeRaw)
      assert length(raw) == 2

      Repo.query!("INSERT INTO roundtrip_edges (dec_num) VALUES (12.34)")

      [clean] = Repo.all(from(r in EdgeRec, where: r.dec_num == 12.34))
      assert Decimal.equal?(clean.dec_num, Decimal.new("12.34"))
    end

    # JSON-encoded collections carry decimals as strings, so the precision
    # guard never sees them: exact past float64 in {:array, :decimal}, and
    # loaded back as a String from a :map.
    test "JSON-carried decimals bypass the guard, exactly" do
      beyond = Decimal.new("12345678901234567890.12345")

      {:ok, arr} =
        Repo.insert(Ecto.Changeset.change(%EdgeRec{}, %{dec_arr: [beyond, Decimal.new(1)]}))

      [a, b] = Map.fetch!(Repo.get(EdgeRec, arr.id), :dec_arr)
      assert Decimal.equal?(a, beyond)
      assert Decimal.equal?(b, Decimal.new(1))

      {:ok, map} =
        Repo.insert(Ecto.Changeset.change(%EdgeRec{}, %{dec_map: %{"amount" => beyond}}))

      assert %{"amount" => "12345678901234567890.12345"} =
               Map.fetch!(Repo.get(EdgeRec, map.id), :dec_map)

      assert_raise XqliteEcto3.DecimalPrecisionError, fn ->
        Repo.insert(Ecto.Changeset.change(%EdgeRec{}, %{dec_num: beyond}))
      end
    end
  end
end
