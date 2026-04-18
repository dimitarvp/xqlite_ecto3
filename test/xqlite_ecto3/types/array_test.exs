defmodule XqliteEcto3.Types.ArrayTest do
  use ExUnit.Case, async: true

  alias XqliteEcto3.Types.Array

  describe "init/1" do
    test "defaults to :any element type" do
      assert Array.init([]) == %{element: :any}
    end

    test "accepts valid element types" do
      for element <- [:any, :string, :integer, :float, :boolean] do
        assert Array.init(element: element) == %{element: element}
      end
    end

    test "raises on invalid element type" do
      assert_raise ArgumentError, fn -> Array.init(element: :uuid) end
      assert_raise ArgumentError, fn -> Array.init(element: "string") end
    end
  end

  describe "type/1" do
    test "always :string (TEXT storage)" do
      assert Array.type(%{element: :any}) == :string
      assert Array.type(%{element: :integer}) == :string
    end
  end

  describe "cast/2 with :any element" do
    test "nil passes through" do
      assert Array.cast(nil, %{element: :any}) == {:ok, nil}
    end

    test "accepts mixed-type list" do
      assert Array.cast([1, "two", 3.0, true, nil], %{element: :any}) ==
               {:ok, [1, "two", 3.0, true, nil]}
    end

    test "accepts nested structures" do
      assert Array.cast([[1, 2], %{"k" => "v"}], %{element: :any}) ==
               {:ok, [[1, 2], %{"k" => "v"}]}
    end

    test "rejects non-list input" do
      assert Array.cast("not a list", %{element: :any}) == :error
      assert Array.cast(42, %{element: :any}) == :error
      assert Array.cast(%{}, %{element: :any}) == :error
    end

    test "accepts empty list" do
      assert Array.cast([], %{element: :any}) == {:ok, []}
    end
  end

  describe "cast/2 with typed element" do
    test ":integer accepts int list" do
      assert Array.cast([1, 2, 3], %{element: :integer}) == {:ok, [1, 2, 3]}
    end

    test ":integer rejects non-int element" do
      assert Array.cast([1, "two"], %{element: :integer}) == :error
    end

    test ":string accepts string list" do
      assert Array.cast(["a", "b"], %{element: :string}) == {:ok, ["a", "b"]}
    end

    test ":string rejects non-string element" do
      assert Array.cast(["a", 1], %{element: :string}) == :error
    end

    test ":boolean accepts booleans" do
      assert Array.cast([true, false, true], %{element: :boolean}) == {:ok, [true, false, true]}
    end

    test ":boolean rejects non-boolean" do
      assert Array.cast([true, 1], %{element: :boolean}) == :error
    end

    test ":float accepts floats and promotes integers" do
      assert Array.cast([1.5, 2], %{element: :float}) == {:ok, [1.5, 2.0]}
    end

    test ":float rejects non-numeric" do
      assert Array.cast([1.5, "two"], %{element: :float}) == :error
    end

    test "nil elements pass through typed arrays" do
      assert Array.cast([1, nil, 2], %{element: :integer}) == {:ok, [1, nil, 2]}
    end
  end

  describe "dump/3" do
    test "nil passes through" do
      assert Array.dump(nil, nil, %{element: :any}) == {:ok, nil}
    end

    test "encodes list as JSON text" do
      assert Array.dump([1, 2, 3], nil, %{element: :integer}) == {:ok, "[1,2,3]"}
    end

    test "encodes mixed-type list under :any" do
      {:ok, json} = Array.dump([1, "two", true, nil], nil, %{element: :any})
      assert json == ~s|[1,"two",true,null]|
    end

    test "rejects non-list" do
      assert Array.dump("not a list", nil, %{element: :any}) == :error
    end
  end

  describe "load/3" do
    test "nil passes through" do
      assert Array.load(nil, nil, %{element: :any}) == {:ok, nil}
    end

    test "decodes JSON array to list" do
      assert Array.load("[1,2,3]", nil, %{element: :integer}) == {:ok, [1, 2, 3]}
    end

    test "decodes and type-casts elements" do
      assert Array.load(~s|["a","b"]|, nil, %{element: :string}) == {:ok, ["a", "b"]}
    end

    test "rejects non-array JSON" do
      assert Array.load(~s|{"k":"v"}|, nil, %{element: :any}) == :error
      assert Array.load("null", nil, %{element: :any}) == :error
      assert Array.load("42", nil, %{element: :any}) == :error
    end

    test "rejects invalid JSON" do
      assert Array.load("[1, 2,", nil, %{element: :any}) == :error
    end

    test "rejects elements that don't match typed element" do
      assert Array.load(~s|[1, "two"]|, nil, %{element: :integer}) == :error
    end
  end

  describe "round-trip" do
    test "integer array round-trips exactly" do
      {:ok, casted} = Array.cast([1, 2, 3], %{element: :integer})
      {:ok, dumped} = Array.dump(casted, nil, %{element: :integer})
      {:ok, loaded} = Array.load(dumped, nil, %{element: :integer})
      assert loaded == [1, 2, 3]
    end

    test "mixed-type array with :any round-trips" do
      input = [1, "two", true, nil, 3.5]
      {:ok, casted} = Array.cast(input, %{element: :any})
      {:ok, dumped} = Array.dump(casted, nil, %{element: :any})
      {:ok, loaded} = Array.load(dumped, nil, %{element: :any})
      assert loaded == input
    end

    test "empty array round-trips" do
      {:ok, casted} = Array.cast([], %{element: :any})
      {:ok, dumped} = Array.dump(casted, nil, %{element: :any})
      {:ok, loaded} = Array.load(dumped, nil, %{element: :any})
      assert loaded == []
    end
  end

  describe "equal?/3" do
    test "lists compare by content" do
      assert Array.equal?([1, 2], [1, 2], %{element: :integer}) == true
      assert Array.equal?([1, 2], [1, 3], %{element: :integer}) == false
    end
  end

  describe "round-trip via TestRepo" do
    setup do
      alias Ecto.Integration.TestRepo
      :ok = Ecto.Adapters.SQL.Sandbox.checkout(TestRepo)
      TestRepo.query!("CREATE TEMP TABLE arr_test(id INTEGER PRIMARY KEY, items TEXT)")
      :ok
    end

    test "insert + select preserves JSON array" do
      alias Ecto.Integration.TestRepo

      input = ["apple", "banana", "cherry"]
      params = %{element: :string}

      {:ok, casted} = Array.cast(input, params)
      {:ok, dumped} = Array.dump(casted, nil, params)

      TestRepo.query!("INSERT INTO arr_test(items) VALUES (?1)", [dumped])
      %{rows: [[stored]]} = TestRepo.query!("SELECT items FROM arr_test")

      assert stored == ~s|["apple","banana","cherry"]|

      {:ok, loaded} = Array.load(stored, nil, params)
      assert loaded == input
    end

    test "array_check/2 from Migration helper composes with :check option" do
      alias XqliteEcto3.Migration

      check = Migration.array_check(:items)
      assert check.name == "items_array_check"
      assert check.expr == "json_type(items) = 'array'"
    end
  end
end
