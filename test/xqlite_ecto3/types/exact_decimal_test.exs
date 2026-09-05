defmodule XqliteEcto3.Types.ExactDecimalTest do
  use XqliteEcto3.AdapterCase, async: true

  alias XqliteEcto3.Connection
  alias XqliteEcto3.Types.ExactDecimal, as: ED

  defmodule Amount do
    use Ecto.Schema

    @primary_key {:id, :id, autogenerate: true}
    schema "exact_decimals" do
      field(:amount, XqliteEcto3.Types.ExactDecimal)
    end
  end

  defmodule AmountRaw do
    use Ecto.Schema

    @primary_key {:id, :id, autogenerate: true}
    schema "exact_decimals" do
      field(:amount, :string)
    end
  end

  defmodule Money do
    use Ecto.Schema

    @primary_key false
    embedded_schema do
      field(:amount, XqliteEcto3.Types.ExactDecimal)
    end
  end

  defmodule Wallet do
    use Ecto.Schema

    @primary_key {:id, :id, autogenerate: true}
    schema "exact_decimal_wallets" do
      embeds_one(:money, Money)
    end
  end

  @forty String.duplicate("9", 40)
  @wide String.duplicate("9", 120)

  setup_all do
    create_table!("exact_decimals", "id INTEGER PRIMARY KEY AUTOINCREMENT, amount TEXT")
    create_table!("exact_decimal_wallets", "id INTEGER PRIMARY KEY AUTOINCREMENT, money TEXT")
  end

  setup do
    clear_tables!(["exact_decimals", "exact_decimal_wallets"])
  end

  defp to_sql(query) do
    {query, _, _} = Ecto.Query.Planner.plan(query, :all, XqliteEcto3)
    {query, _} = Ecto.Query.Planner.normalize(query, :all, XqliteEcto3, 0)
    query |> Connection.all() |> IO.iodata_to_binary()
  end

  defp stored(table, column, id) do
    %{rows: [[type, value]]} =
      Repo.query!("SELECT typeof(#{column}), #{column} FROM #{table} WHERE id = ?", [id])

    {type, value}
  end

  describe "type/0" do
    test "returns :string" do
      assert ED.type() == :string
    end
  end

  describe "embed_as/1" do
    test "is :dump in every format" do
      assert ED.embed_as(:json) == :dump
      assert ED.embed_as(:self) == :dump
    end
  end

  describe "cast/1" do
    test "nil passes through" do
      assert ED.cast(nil) == {:ok, nil}
    end

    test "a finite Decimal passes through with its scale kept" do
      assert ED.cast(Decimal.new("1.50")) == {:ok, Decimal.new("1.50")}
      assert ED.cast(Decimal.new("-0")) == {:ok, Decimal.new("-0")}
    end

    test "an integer becomes a Decimal" do
      assert ED.cast(7) == {:ok, Decimal.new("7")}
      assert ED.cast(-7) == {:ok, Decimal.new("-7")}
      assert ED.cast(0) == {:ok, Decimal.new("0")}
    end

    test "a float goes through Decimal.from_float/1" do
      assert ED.cast(1.5) == {:ok, Decimal.from_float(1.5)}
      assert ED.cast(0.1) == {:ok, Decimal.from_float(0.1)}
    end

    test "string forms Decimal.parse consumes whole" do
      assert ED.cast("1.50") == {:ok, Decimal.new("1.50")}
      assert ED.cast("1E+3") == {:ok, Decimal.new("1E+3")}
      assert ED.cast("1e5") == {:ok, Decimal.new("1E+5")}
      assert ED.cast("007") == {:ok, Decimal.new("7")}
      assert ED.cast(".5") == {:ok, Decimal.new("0.5")}
      assert ED.cast("5.") == {:ok, Decimal.new("5")}
      assert ED.cast("+1") == {:ok, Decimal.new("1")}
      assert ED.cast("-1") == {:ok, Decimal.new("-1")}
    end

    test "a string with an unconsumed remainder rejects" do
      assert ED.cast("1_000") == :error
      assert ED.cast("0x10") == :error
      assert ED.cast("1 ") == :error
      assert ED.cast("12abc") == :error
    end

    test "a string Decimal.parse refuses outright rejects" do
      assert ED.cast(" 1") == :error
      assert ED.cast("\t1") == :error
      assert ED.cast("") == :error
      assert ED.cast("abc") == :error
    end

    test "a 40-digit string is accepted here and refused by Ecto's :decimal" do
      assert {:ok, d} = ED.cast(@forty)
      assert Decimal.to_string(d, :normal, max_digits: :infinity) == @forty

      assert Ecto.Type.cast(:decimal, @forty) == :error
    end

    test "a 120-digit string is accepted" do
      assert {:ok, d} = ED.cast(@wide)
      assert Decimal.to_string(d, :normal, max_digits: :infinity) == @wide
    end

    test "a non-finite string rejects" do
      assert ED.cast("NaN") == :error
      assert ED.cast("Infinity") == :error
      assert ED.cast("-Infinity") == :error
      assert ED.cast("inf") == :error
    end

    test "a non-finite Decimal returns :error where Ecto's :decimal raises" do
      assert ED.cast(Decimal.new("NaN")) == :error
      assert ED.cast(Decimal.new("Infinity")) == :error
      assert ED.cast(Decimal.new("-Infinity")) == :error

      assert_raise ArgumentError, fn -> Ecto.Type.cast(:decimal, Decimal.new("NaN")) end
      assert_raise ArgumentError, fn -> Ecto.Type.cast(:decimal, Decimal.new("Infinity")) end
    end

    test "any other term rejects" do
      assert ED.cast(:atom) == :error
      assert ED.cast([1, 2]) == :error
      assert ED.cast(%{}) == :error
      assert ED.cast({1, 2}) == :error
      assert ED.cast(true) == :error
    end
  end

  describe "dump/1" do
    test "nil passes through" do
      assert ED.dump(nil) == {:ok, nil}
    end

    test "a positive exponent is expanded" do
      assert ED.dump(Decimal.new("1E+3")) == {:ok, "1000"}
    end

    test "negative zero keeps its sign" do
      assert ED.dump(Decimal.new("-0")) == {:ok, "-0"}
      assert ED.dump(Decimal.new("-0E+3")) == {:ok, "-0000"}
    end

    test "the scale is kept" do
      assert ED.dump(Decimal.new("1.50")) == {:ok, "1.50"}
    end

    test "a small negative exponent is written out in full" do
      assert ED.dump(Decimal.new("0.000001E-20")) ==
               {:ok, "0.00000000000000000000000001"}
    end

    test "a 120-digit value dumps every digit" do
      d = Decimal.new(1, String.to_integer(@wide), 0)

      assert ED.dump(d) == {:ok, @wide}
    end

    test "a non-finite Decimal rejects" do
      assert ED.dump(Decimal.new("NaN")) == :error
      assert ED.dump(Decimal.new("Infinity")) == :error
      assert ED.dump(Decimal.new("-Infinity")) == :error
    end

    test "any other term rejects" do
      assert ED.dump("1.50") == :error
      assert ED.dump(1) == :error
      assert ED.dump(1.5) == :error
    end
  end

  describe "load/1" do
    test "nil passes through" do
      assert ED.load(nil) == {:ok, nil}
    end

    test "a canonical string loads back" do
      assert ED.load("1.50") == {:ok, Decimal.new("1.50")}
      assert ED.load("-0") == {:ok, Decimal.new("-0")}
      assert ED.load("1000") == {:ok, Decimal.new("1000")}
    end

    test "a 120-digit string loads back whole" do
      assert {:ok, d} = ED.load(@wide)
      assert d == Decimal.new(1, String.to_integer(@wide), 0)
    end

    test "a non-numeric string rejects" do
      assert ED.load("abc") == :error
      assert ED.load("") == :error
      assert ED.load("1_000") == :error
    end

    test "a non-finite string rejects" do
      assert ED.load("NaN") == :error
      assert ED.load("Infinity") == :error
    end

    test "a non-binary rejects" do
      assert ED.load(1) == :error
      assert ED.load(1.5) == :error
      assert ED.load(Decimal.new("1.5")) == :error
    end
  end

  describe "equal?/2" do
    test "two decimals compare numerically" do
      assert ED.equal?(Decimal.new("1E+3"), Decimal.new("1000")) == true
      assert ED.equal?(Decimal.new("1.50"), Decimal.new("1.5")) == true
      assert ED.equal?(Decimal.new("0"), Decimal.new("-0")) == true
      assert ED.equal?(Decimal.new("1"), Decimal.new("2")) == false
    end

    test "two nils are equal" do
      assert ED.equal?(nil, nil) == true
    end

    test "anything else is not equal" do
      assert ED.equal?(nil, Decimal.new("1")) == false
      assert ED.equal?(Decimal.new("1"), nil) == false
      assert ED.equal?(Decimal.new("1"), 1) == false
      assert ED.equal?("1", "1") == false
    end
  end

  describe "changesets" do
    test "the same number at another scale is not a change and the stored text keeps its scale" do
      {:ok, rec} = Repo.insert(%Amount{amount: Decimal.new("1.50")})

      changeset = Ecto.Changeset.change(rec, %{amount: Decimal.new("1.5")})
      assert changeset.changes == %{}

      {:ok, _updated} = Repo.update(changeset)

      assert stored("exact_decimals", "amount", rec.id) == {"text", "1.50"}
    end

    test "a different number is a change" do
      {:ok, rec} = Repo.insert(%Amount{amount: Decimal.new("1.50")})

      changeset = Ecto.Changeset.change(rec, %{amount: Decimal.new("2.50")})
      assert changeset.changes == %{amount: Decimal.new("2.50")}
    end

    test "a non-finite decimal reaching dump raises Ecto.ChangeError" do
      assert_raise Ecto.ChangeError, fn ->
        Repo.insert(Ecto.Changeset.change(%Amount{}, %{amount: Decimal.new("NaN")}))
      end

      assert_raise Ecto.ChangeError, fn ->
        Repo.insert(Ecto.Changeset.change(%Amount{}, %{amount: Decimal.new("Infinity")}))
      end
    end
  end

  describe "load failures through the Repo" do
    test "a non-numeric stored string fails the load with an ArgumentError" do
      Repo.query!("INSERT INTO exact_decimals (amount) VALUES ('abc')")

      assert_raise ArgumentError, fn -> Repo.all(Amount) end

      assert [%AmountRaw{amount: "abc"}] = Repo.all(AmountRaw)
    end

    test "a stored BLOB fails the load with an ArgumentError" do
      Repo.query!("INSERT INTO exact_decimals (amount) VALUES (X'DEADBEEF')")

      assert_raise ArgumentError, fn -> Repo.all(Amount) end
    end
  end

  describe "round-trip through the Repo" do
    test "a 40-digit value survives insert and select" do
      {:ok, d} = ED.cast(@forty)
      {:ok, rec} = Repo.insert(%Amount{amount: d})

      assert Repo.get(Amount, rec.id).amount == d
      assert stored("exact_decimals", "amount", rec.id) == {"text", @forty}
    end

    test "nil round-trips as nil" do
      {:ok, rec} = Repo.insert(%Amount{amount: nil})

      assert Repo.get(Amount, rec.id).amount == nil
      assert stored("exact_decimals", "amount", rec.id) == {"null", nil}
    end
  end

  describe "embedded schemas" do
    test "an embedded value is stored as the canonical string" do
      {:ok, wallet} = Repo.insert(%Wallet{money: %Money{amount: Decimal.new("1.50")}})

      loaded = Repo.get(Wallet, wallet.id)
      assert loaded.money.amount == Decimal.new("1.50")

      %{rows: [[json]]} =
        Repo.query!("SELECT money FROM exact_decimal_wallets WHERE id = ?", [wallet.id])

      assert Jason.decode!(json) == %{"amount" => "1.50"}
    end

    test "a 40-digit embedded value survives the JSON round trip" do
      {:ok, d} = ED.cast(@forty)
      {:ok, wallet} = Repo.insert(%Wallet{money: %Money{amount: d}})

      assert Repo.get(Wallet, wallet.id).money.amount == d
    end
  end

  describe "SQL comparisons on the column" do
    test "equality is textual, so two scales of one number are two rows" do
      {:ok, _} = Repo.insert(%Amount{amount: Decimal.new("9.5")})
      {:ok, _} = Repo.insert(%Amount{amount: Decimal.new("9.50")})

      assert ED.equal?(Decimal.new("9.5"), Decimal.new("9.50")) == true
      assert length(Repo.all(Amount)) == 2

      matched = Repo.all(from(a in Amount, where: a.amount == ^Decimal.new("9.5")))
      assert [%Amount{amount: one}] = matched
      assert Decimal.to_string(one, :normal) == "9.5"
    end

    test "a tagged parameter emits CAST(?1 AS TEXT)" do
      q = from(a in Amount, select: type(^Decimal.new("9.5"), XqliteEcto3.Types.ExactDecimal))

      assert to_sql(q) == ~s|SELECT CAST(?1 AS TEXT) FROM "exact_decimals" AS e0|
    end

    test "a Decimal compared against a plain :string field is refused at query build" do
      assert_raise Ecto.Query.CastError, fn ->
        Repo.all(from(a in AmountRaw, where: a.amount == ^Decimal.new("9.5")))
      end
    end
  end
end
