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

  # `:max_rows` bounds the memory one batch holds, so a value that cannot
  # mean a batch size is refused by name rather than replaced with the
  # default nobody asked for. The refusal comes from the library, on the
  # first fetch — declaring the stream only records the number.
  describe "Repo.stream/2 with a :max_rows that is not a batch size" do
    for value <- [0, -1, "100", 1.5, :infinity, nil, {:a, 1}] do
      test "max_rows: #{inspect(value)} is refused, not replaced" do
        error =
          assert_raise XqliteEcto3.Error, fn ->
            Repo.transaction(fn ->
              from(s in SI, order_by: s.id, select: s.n)
              |> Repo.stream(max_rows: unquote(Macro.escape(value)))
              |> Enum.to_list()
            end)
          end

        assert error.type == :invalid_batch_size
      end
    end

    test "a positive integer is honoured" do
      {:ok, results} =
        Repo.transaction(fn ->
          from(s in SI, order_by: s.id, select: s.n)
          |> Repo.stream(max_rows: 2)
          |> Enum.to_list()
        end)

      assert results == Enum.to_list(1..20)
    end

    test "no :max_rows at all declares the documented default" do
      state = XqliteEcto3.DriverHelper.connect!([])
      query = %XqliteEcto3.Query{statement: "SELECT 1"}

      assert {:ok, _query, cursor, _state} =
               XqliteEcto3.Driver.handle_declare(query, [], [], state)

      assert cursor.batch_size == 500
    end
  end

  describe "a failing streamed statement" do
    test "carries its SQL on the error" do
      TestRepo.query!("CREATE TABLE st_fail (id INTEGER PRIMARY KEY, v TEXT)")
      TestRepo.query!("CREATE UNIQUE INDEX st_fail_uq ON st_fail (v)")
      TestRepo.query!("INSERT INTO st_fail (id, v) VALUES (1, 'a')")

      sql = "INSERT INTO st_fail (id, v) VALUES (10, 'zz'), (11, 'a') RETURNING id"

      error =
        assert_raise XqliteEcto3.Error, fn ->
          TestRepo.transaction(fn ->
            TestRepo
            |> Ecto.Adapters.SQL.stream(sql, [], max_rows: 1)
            |> Enum.to_list()
          end)
        end

      assert error.type == :constraint_violation
      assert error.statement == sql
    end
  end
end
