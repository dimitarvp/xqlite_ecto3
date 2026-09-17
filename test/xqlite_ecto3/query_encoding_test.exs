defmodule XqliteEcto3.QueryEncodingTest do
  use ExUnit.Case, async: true
  use ExUnitProperties

  alias Ecto.Integration.TestRepo
  alias XqliteEcto3.Query

  defp encode(params), do: DBConnection.Query.encode(%Query{statement: "?"}, params, [])

  describe "encode booleans" do
    test "true encodes to 1" do
      assert encode([true]) == [1]
    end

    test "false encodes to 0" do
      assert encode([false]) == [0]
    end
  end

  describe "encode date/time types" do
    test "NaiveDateTime encodes to the stored space-separated form" do
      ndt = ~N[2024-06-15 14:30:45]
      assert encode([ndt]) == ["2024-06-15 14:30:45"]
    end

    test "NaiveDateTime with microseconds keeps them in the stored form" do
      ndt = ~N[2024-06-15 14:30:45.123456]
      assert encode([ndt]) == ["2024-06-15 14:30:45.123456"]
    end

    test "DateTime encodes to the stored UTC form with no designator" do
      dt = ~U[2024-06-15 14:30:45Z]
      assert encode([dt]) == ["2024-06-15 14:30:45"]
    end

    # Never an offset-carrying form: that would sort against the adapter's
    # own values by the offset digits.
    test "a zoned DateTime encodes in the stored UTC text form" do
      dt = %DateTime{
        year: 2024,
        month: 6,
        day: 15,
        hour: 14,
        minute: 30,
        second: 45,
        microsecond: {0, 0},
        time_zone: "America/New_York",
        zone_abbr: "EST",
        utc_offset: -18_000,
        std_offset: 0
      }

      assert encode([dt]) == ["2024-06-15 19:30:45"]
    end

    test "Date encodes to ISO 8601" do
      assert encode([~D[2024-06-15]]) == ["2024-06-15"]
    end

    test "Time encodes to ISO 8601" do
      assert encode([~T[14:30:45]]) == ["14:30:45"]
    end

    # The stored form carries a four-digit year. A wider one writes text the
    # loaders cannot read back, poisoning every later read of the table, so it
    # is refused here instead — where nothing has been written yet.
    test "the four-digit year boundaries encode" do
      assert encode([Date.new!(9999, 12, 31)]) == ["9999-12-31"]
      assert encode([Date.new!(-9999, 1, 1)]) == ["-9999-01-01"]
      assert encode([NaiveDateTime.new!(9999, 12, 31, 23, 59, 59)]) == ["9999-12-31 23:59:59"]
    end

    test "a year past 9999 is refused, on every datetime shape" do
      for value <- [
            Date.new!(10_000, 6, 7),
            NaiveDateTime.new!(10_000, 6, 7, 1, 2, 3),
            DateTime.from_naive!(NaiveDateTime.new!(10_000, 6, 7, 1, 2, 3), "Etc/UTC")
          ] do
        error = assert_raise XqliteEcto3.UnencodableParameterError, fn -> encode([value]) end

        assert error.reason == :year_out_of_range
        assert error.value == value
        assert error.index == 1
      end
    end

    test "a year below -9999 is refused the same way" do
      value = Date.add(~D[2026-09-17], -5_000_000)

      assert value.year == -11_663

      error = assert_raise XqliteEcto3.UnencodableParameterError, fn -> encode([value]) end

      assert error.reason == :year_out_of_range
    end

    test "an out-of-range year inside a map is refused too" do
      value = DateTime.from_naive!(NaiveDateTime.new!(10_000, 6, 7, 1, 2, 3), "Etc/UTC")

      error =
        assert_raise XqliteEcto3.UnencodableParameterError, fn -> encode([%{"at" => value}]) end

      assert error.reason == :year_out_of_range
      assert error.value == value
    end
  end

  # A decimal binds as a number, never as text. SQLite compares by storage
  # class whenever the other operand has no column affinity to coerce with,
  # and every number sorts below every text, so a text bind answers those
  # comparisons by type instead of by value.
  describe "encode Decimal" do
    test "a value with a fractional part encodes as a float" do
      assert encode([Decimal.new("123.456")]) == [123.456]
    end

    test "preserves high-precision values" do
      assert encode([Decimal.new("0.00000000001")]) == [1.0e-11]
    end

    test "whole numbers encode as integers, not floats" do
      assert encode([Decimal.new("1.0e10")]) == [10_000_000_000]
    end

    test "a whole number past float64's exact range keeps every digit" do
      assert encode([Decimal.new("9223372036854775807")]) == [9_223_372_036_854_775_807]
    end

    test "large money within 15 significant digits still encodes" do
      assert encode([Decimal.new("9999999999999.99")]) == [9_999_999_999_999.99]
    end

    test "refuses a value beyond float64 precision instead of silently rounding" do
      dec = Decimal.new("12345678901234567890.12345")

      err =
        assert_raise XqliteEcto3.DecimalPrecisionError, fn ->
          encode([dec])
        end

      assert Decimal.equal?(err.value, dec)
      assert err.reason == :precision
    end

    # Whatever the guard accepts must bind as a number of the same value: an
    # integer or a float, never text, and never a different number.
    property "an accepted decimal binds as a numerically equal number" do
      check all(dec <- finite_decimal(), max_runs: 2000) do
        if XqliteEcto3.DecimalPrecision.representable?(dec) do
          [bound] = encode([dec])

          assert is_integer(bound) or is_float(bound)
          assert Decimal.equal?(dec, decimal_of(bound))
        else
          assert_raise XqliteEcto3.DecimalPrecisionError, fn -> encode([dec]) end
        end
      end
    end
  end

  defp decimal_of(bound) when is_integer(bound), do: Decimal.new(bound)

  # A bound float must equal the value SQLite STORES for it, and the storage
  # model is the guard's own: NUMERIC affinity demotes an integral float in
  # int64 range to an INTEGER with its exact digits. Decimal.from_float/1 is
  # the wrong lens here — it renders the shortest string that round-trips,
  # which can drop digits a demoted INTEGER keeps (a 17-digit integral float
  # prints as 16).
  defp decimal_of(bound) when is_float(bound),
    do: XqliteEcto3.DecimalPrecision.stored_decimal(bound)

  # sign * coefficient * 10^exponent, with the coefficient's digit count swept
  # across 1..25 so the stream straddles float64's ~15-17 significant-digit
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

  describe "encode map and list as JSON" do
    test "map encodes to JSON" do
      assert encode([%{"k" => "v", "n" => 1}]) == [~s|{"k":"v","n":1}|]
    end

    test "empty map encodes to {}" do
      assert encode([%{}]) == ["{}"]
    end

    test "list encodes to JSON array" do
      assert encode([[1, 2, 3]]) == ["[1,2,3]"]
    end

    test "empty list encodes to []" do
      assert encode([[]]) == ["[]"]
    end

    test "nested map encodes via Jason" do
      value = %{"outer" => %{"inner" => [1, "two", true]}}
      [encoded] = encode([value])
      assert Jason.decode!(encoded) == value
    end

    # A UUID field under `:binary` storage dumps to a BLOB parameter, and an
    # embedded schema hands the whole map to the JSON encoder. JSON cannot
    # carry raw bytes, so the sixteen inside it are written as the dashed text
    # every UUID loader reads back.
    test "a sixteen-byte BLOB parameter inside a map writes the dashed UUID text" do
      raw = Ecto.UUID.dump!("550e8400-e29b-41d4-a716-446655440000")

      assert encode([%{"id" => %Xqlite.Blob{bytes: raw}}]) ==
               [~s({"id":"550e8400-e29b-41d4-a716-446655440000"})]
    end
  end

  describe "encode passes through primitives" do
    test "integer unchanged" do
      assert encode([42]) == [42]
    end

    test "float unchanged" do
      assert encode([3.14]) == [3.14]
    end

    test "binary string unchanged" do
      assert encode(["hello"]) == ["hello"]
    end

    test "nil unchanged" do
      assert encode([nil]) == [nil]
    end

    test "atom unchanged (will fail at NIF, but encoder doesn't block)" do
      # We intentionally do not filter atoms here — the NIF either accepts or
      # raises. The Query encode step is transport-only.
      assert encode([:foo]) == [:foo]
    end
  end

  describe "encode mixed params" do
    test "encodes each element independently" do
      params = [true, ~D[2024-01-01], "str", 42, %{"k" => "v"}]
      assert encode(params) == [1, "2024-01-01", "str", 42, ~s|{"k":"v"}|]
    end
  end

  describe "DBConnection.Query protocol contract" do
    test "parse/2 is identity" do
      q = %Query{statement: "SELECT 1"}
      assert DBConnection.Query.parse(q, []) == q
    end

    test "describe/2 is identity" do
      q = %Query{statement: "SELECT 1"}
      assert DBConnection.Query.describe(q, []) == q
    end

    test "decode/3 is identity" do
      q = %Query{statement: "SELECT 1"}
      result = %{columns: ["n"], rows: [[1]], num_rows: 1}
      assert DBConnection.Query.decode(q, result, []) == result
    end
  end

  describe "unencodable parameters refuse with structure" do
    test "a struct without a JSON form raises with value, position, and cause" do
      err =
        assert_raise XqliteEcto3.UnencodableParameterError, fn ->
          encode([1, %Version{major: 1, minor: 2, patch: 3}])
        end

      assert %Version{} = err.value
      assert err.index == 2
      assert %Protocol.UndefinedError{} = err.reason
    end

    test "a map that JSON cannot represent raises with the failure attached" do
      err =
        assert_raise XqliteEcto3.UnencodableParameterError, fn ->
          encode([%{a: <<0xFF, 0xFE>>}])
        end

      assert err.index == 1
      assert %Jason.EncodeError{} = err.reason
    end

    test "a struct nested inside a plain map raises structured, not a protocol error" do
      err =
        assert_raise XqliteEcto3.UnencodableParameterError, fn ->
          encode([%{v: %Version{major: 1, minor: 0, patch: 0}}])
        end

      assert err.index == 1
      assert %Protocol.UndefinedError{} = err.reason
    end

    test "a plain map still encodes to JSON" do
      assert encode([%{a: 1}]) == [~s({"a":1})]
    end

    # Only sixteen bytes are a UUID. Any other BLOB parameter inside a JSON
    # value is refused exactly as raw bytes are, rather than guessed at.
    test "a BLOB parameter of another size inside a map is refused" do
      err =
        assert_raise XqliteEcto3.UnencodableParameterError, fn ->
          encode([%{"b" => %Xqlite.Blob{bytes: <<1, 2, 3>>}}])
        end

      assert err.index == 1
      assert %Protocol.UndefinedError{} = err.reason
    end

    test "a decimal with no exact numeric form refuses inside a map, carrying itself" do
      dec = Decimal.new(1, 1, 7000)

      err =
        assert_raise XqliteEcto3.DecimalPrecisionError, fn ->
          encode([%{"amount" => dec}])
        end

      assert err.value == dec
      assert err.index == 1
    end

    # NaN and Infinity are not wide numbers, so the refusal has to say
    # something else about them: the remedy that fits a wide number does
    # not accept either of these.
    for {text, reason} <- [{"NaN", :nan}, {"Inf", :infinity}] do
      test "a #{text} inside a map is refused as #{reason}" do
        err =
          assert_raise XqliteEcto3.DecimalPrecisionError, fn ->
            encode([%{"amount" => Decimal.new(unquote(text))}])
          end

        assert err.reason == unquote(reason)
        assert err.index == 1
      end
    end

    test "an accepted decimal reaches JSON as a number, not a quoted string" do
      assert encode([%{"amount" => Decimal.new("19.99")}]) == [~s({"amount":19.99})]
      assert encode([[Decimal.new("1E+18")]]) == ["[1000000000000000000]"]
    end

    # Whatever the exponent, the parameter either encodes carrying that
    # number or raises the precision error — never another exception, and
    # never a quoted string that would come back as text.
    property "a nested decimal follows the same numeric guard as a bare one" do
      check all(
              exponent <- StreamData.integer(-8_000..8_000),
              coefficient <- StreamData.integer(1..999),
              nesting <- StreamData.member_of([:map, :list, :deep]),
              max_runs: 2000
            ) do
        dec = Decimal.new(1, coefficient, exponent)
        param = nest(dec, nesting)

        case encode_outcome([param]) do
          {:ok, [json]} ->
            assert XqliteEcto3.DecimalPrecision.representable?(dec)
            assert Jason.decode!(json) == nest(bound_number(dec), nesting)

          {:raised, %XqliteEcto3.DecimalPrecisionError{} = err} ->
            refute XqliteEcto3.DecimalPrecision.representable?(dec)
            assert err.value == dec
            assert err.index == 1

          other ->
            flunk("encoding #{inspect(param)} gave #{inspect(other)}")
        end
      end
    end

    test "the decimal refusal carries its parameter position" do
      err =
        assert_raise XqliteEcto3.DecimalPrecisionError, fn ->
          encode([Decimal.new("1"), Decimal.new("0.12345678901234567")])
        end

      assert err.index == 2
    end
  end

  defp nest(value, :map), do: %{"v" => value}
  defp nest(value, :list), do: [value]
  defp nest(value, :deep), do: %{"outer" => [%{"inner" => value}]}

  defp bound_number(dec) do
    case XqliteEcto3.DecimalPrecision.bind_form(dec) do
      {:integer, int} -> int
      {:float, float} -> float
      {:error, _reason} -> :no_bind_form
    end
  end

  defp encode_outcome(params) do
    {:ok, encode(params)}
  rescue
    e -> {:raised, e}
  end

  describe "String.Chars protocol" do
    test "to_string returns the SQL statement" do
      q = %Query{statement: "SELECT 1"}
      assert to_string(q) == "SELECT 1"
    end

    test "flattens iodata statements" do
      q = %Query{statement: ["SELECT ", "1"]}
      assert to_string(q) == "SELECT 1"
    end
  end

  defmodule Doc do
    use Ecto.Schema

    @primary_key {:id, :id, autogenerate: true}
    schema "qe_docs" do
      field(:meta, :map)
      field(:metas, {:array, :map})
    end
  end

  defp iso_text(%Date{} = value), do: Date.to_iso8601(value)
  defp iso_text(%Time{} = value), do: Time.to_iso8601(value)
  defp iso_text(%NaiveDateTime{} = value), do: NaiveDateTime.to_iso8601(value)
  defp iso_text(%DateTime{} = value), do: DateTime.to_iso8601(value)

  defp parsed_back(%Date{}, text), do: Date.from_iso8601!(text)
  defp parsed_back(%Time{}, text), do: Time.from_iso8601!(text)
  defp parsed_back(%NaiveDateTime{}, text), do: NaiveDateTime.from_iso8601!(text)

  defp parsed_back(%DateTime{}, text) do
    {:ok, value, _offset} = DateTime.from_iso8601(text)
    value
  end

  # JSON has no datetime, so a datetime struct inside a `:map` value is written
  # as ISO 8601 text — `T` separator, `Z` for UTC, not the space-separated form
  # a datetime column gets — and comes back as a plain string, because a `:map`
  # field has no per-value type to load it through. An embedded schema is the
  # way to get the struct back.
  describe "a datetime struct inside a :map field" do
    setup do
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)

      TestRepo.query!(
        "CREATE TEMP TABLE qe_docs(id INTEGER PRIMARY KEY AUTOINCREMENT, meta TEXT, metas TEXT)"
      )

      :ok
    end

    test "all four kinds read back as their ISO 8601 text, bare and nested" do
      written = %{
        "at" => ~U[2026-09-17 01:02:03.456789Z],
        "nd" => ~N[2026-09-17 01:02:03.456789],
        "d" => ~D[2026-09-17],
        "t" => ~T[01:02:03.456789]
      }

      %Doc{id: id} = TestRepo.insert!(%Doc{meta: written, metas: [%{"nested" => written}]})

      %Doc{meta: meta, metas: [%{"nested" => nested}]} = TestRepo.get!(Doc, id)

      for {key, value} <- written do
        text = Map.fetch!(meta, key)

        assert is_binary(text)
        assert text == iso_text(value)
        assert parsed_back(value, text) == value
        assert Map.fetch!(nested, key) == text
      end
    end

    # The stored text carries a four-digit year, inside a JSON value as much as
    # in a datetime column, so the same boundary holds on both paths.
    test "the year boundaries store, and a wider year is refused" do
      for year <- [-9999, 9999] do
        value = Date.new!(year, 9, 17)
        %Doc{id: id} = TestRepo.insert!(%Doc{meta: %{"d" => value}})

        assert TestRepo.get!(Doc, id).meta == %{"d" => Date.to_iso8601(value)}
      end

      for year <- [-10_000, 10_000] do
        value = Date.new!(year, 9, 17)

        error =
          assert_raise XqliteEcto3.UnencodableParameterError, fn ->
            TestRepo.insert!(%Doc{meta: %{"d" => value}})
          end

        assert error.reason == :year_out_of_range
      end
    end
  end
end
