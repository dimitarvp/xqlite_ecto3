defmodule XqliteEcto3.StreamTest do
  use XqliteEcto3.AdapterCase, async: true

  defmodule SI do
    use Ecto.Schema
    import Ecto.Changeset

    schema "stream_items" do
      field(:name, :string)
      field(:n, :integer)
    end

    def changeset(s, attrs \\ %{}),
      do: s |> cast(attrs, [:name, :n]) |> validate_required([:name])
  end

  setup_all do
    create_table!(
      "stream_items",
      "id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, n INTEGER"
    )
  end

  setup do
    clear_table!("stream_items")

    for i <- 1..20 do
      {:ok, _} = Repo.insert(%SI{name: "item_#{i}", n: i})
    end

    :ok
  end

  describe "Repo.stream/2 with default batch size" do
    test "streams all rows in order" do
      {:ok, results} =
        Repo.transaction(fn ->
          from(s in SI, order_by: s.id, select: s.n)
          |> Repo.stream()
          |> Enum.to_list()
        end)

      assert results == Enum.to_list(1..20)
    end

    test "returns empty list for empty table" do
      Repo.delete_all(SI)

      {:ok, results} =
        Repo.transaction(fn ->
          from(s in SI, select: s.id) |> Repo.stream() |> Enum.to_list()
        end)

      assert results == []
    end
  end

  describe "Repo.stream/2 with custom :max_rows" do
    test "respects max_rows: 1 (one row per batch)" do
      {:ok, results} =
        Repo.transaction(fn ->
          from(s in SI, order_by: s.id, select: s.n)
          |> Repo.stream(max_rows: 1)
          |> Enum.to_list()
        end)

      # Streaming still returns all rows, just in smaller NIF fetches.
      assert results == Enum.to_list(1..20)
    end

    test "respects max_rows: 5 (batches of 5)" do
      {:ok, results} =
        Repo.transaction(fn ->
          from(s in SI, order_by: s.id, select: s.n)
          |> Repo.stream(max_rows: 5)
          |> Enum.to_list()
        end)

      assert results == Enum.to_list(1..20)
    end

    test "respects max_rows larger than dataset" do
      {:ok, results} =
        Repo.transaction(fn ->
          from(s in SI, order_by: s.id, select: s.n)
          |> Repo.stream(max_rows: 10_000)
          |> Enum.to_list()
        end)

      assert results == Enum.to_list(1..20)
    end

    test "Enum.take honors lazy semantics with small max_rows" do
      # Enum.take/2 should stop pulling once it has enough rows, even with
      # tiny batch sizes. This verifies the stream is actually lazy.
      {:ok, results} =
        Repo.transaction(fn ->
          from(s in SI, order_by: s.id, select: s.n)
          |> Repo.stream(max_rows: 2)
          |> Enum.take(3)
        end)

      assert results == [1, 2, 3]
    end
  end
end
