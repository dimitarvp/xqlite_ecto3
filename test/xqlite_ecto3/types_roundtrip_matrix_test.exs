defmodule XqliteEcto3.TypesRoundtripMatrixTest do
  @moduledoc """
  Table-driven dump -> store -> load == identity matrix per Ecto type,
  exercised through the real repo. (`stream_data` is not a dependency, so
  this is exhaustive example-based rather than generative.)

  The decimal block pins a documented SQLite limitation (F-B4-1): a
  `:decimal` migration column has NUMERIC affinity, so values beyond ~15
  significant digits are coerced to float64 and lose precision. If the
  storage strategy ever changes, the high-precision pin flips and forces a
  ledger revisit.
  """
  use XqliteEcto3.AdapterCase, async: true

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

  setup_all do
    create_table!(
      "roundtrip_matrix",
      "id INTEGER PRIMARY KEY AUTOINCREMENT, int_field INTEGER, str_field TEXT, " <>
        "bin_field BLOB, bool_field INTEGER, map_field TEXT, arr_field TEXT, dec_field DECIMAL"
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

  describe "decimal precision (F-B4-1 pin — documented SQLite limitation)" do
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

    # PIN OF KNOWN LIMITATION, not desired behaviour: >15 significant digits
    # are coerced to float64 by NUMERIC affinity and lose precision. If this
    # ever starts round-tripping, the storage strategy changed — update the
    # review ledger (F-B4-1) before flipping this assertion.
    test "beyond ~15 significant digits, precision is silently lost" do
      dec = Decimal.new("12345678901234567890.12345")
      loaded = roundtrip(:dec_field, dec)
      refute Decimal.equal?(loaded, dec)
    end
  end
end
