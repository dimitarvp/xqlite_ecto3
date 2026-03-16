defmodule XqliteEcto3.ConnectionLifecycleTest do
  use ExUnit.Case, async: true

  alias XqliteEcto3.TestRepo, as: Repo
  import XqliteEcto3.TableHelper

  defmodule CL do
    use Ecto.Schema
    import Ecto.Changeset

    schema "cl_users" do
      field(:name, :string)
      timestamps()
    end

    def changeset(user, attrs \\ %{}),
      do: user |> cast(attrs, [:name]) |> validate_required([:name])
  end

  setup_all do
    create_table!(
      "cl_users",
      "id INTEGER PRIMARY KEY AUTOINCREMENT, name TEXT NOT NULL, inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL"
    )
  end

  setup do
    clear_table!("cl_users")
  end

  # ---------------------------------------------------------------------------
  # Basic connectivity
  # ---------------------------------------------------------------------------

  test "repo is started and responds to queries" do
    result = Repo.query!("SELECT 1 + 1")
    assert result.rows == [[2]]
  end

  test "repo can execute PRAGMA queries" do
    result = Repo.query!("PRAGMA journal_mode")
    # WAL mode is set by the driver on connect
    assert result.rows == [["wal"]]
  end

  test "repo can execute multiple sequential queries" do
    for i <- 1..10 do
      {:ok, _} = Repo.insert(CL.changeset(%CL{}, %{name: "User #{i}"}))
    end

    assert Repo.aggregate(CL, :count) == 10
  end

  # ---------------------------------------------------------------------------
  # Concurrent access
  # ---------------------------------------------------------------------------

  test "concurrent inserts succeed with pool" do
    tasks =
      for i <- 1..20 do
        Task.async(fn ->
          Repo.insert(CL.changeset(%CL{}, %{name: "Concurrent #{i}"}))
        end)
      end

    results = Task.await_many(tasks, 10_000)
    assert Enum.all?(results, &match?({:ok, _}, &1))
    assert Repo.aggregate(CL, :count) == 20
  end

  test "concurrent reads and writes don't deadlock" do
    for i <- 1..5 do
      {:ok, _} = Repo.insert(CL.changeset(%CL{}, %{name: "Seed #{i}"}))
    end

    tasks =
      for i <- 1..10 do
        Task.async(fn ->
          if rem(i, 2) == 0 do
            Repo.all(CL)
          else
            Repo.insert(CL.changeset(%CL{}, %{name: "Mixed #{i}"}))
          end
        end)
      end

    results = Task.await_many(tasks, 10_000)

    assert Enum.all?(results, fn
             {:ok, _} -> true
             [_ | _] -> true
           end)
  end

  # ---------------------------------------------------------------------------
  # Transaction isolation
  # ---------------------------------------------------------------------------

  test "transaction isolates changes until commit" do
    {:ok, _} =
      Repo.transaction(fn ->
        {:ok, _} = Repo.insert(CL.changeset(%CL{}, %{name: "Inside"}))
        assert Repo.aggregate(CL, :count) == 1
      end)

    assert Repo.aggregate(CL, :count) == 1
  end

  test "rollback undoes all changes" do
    Repo.transaction(fn ->
      {:ok, _} = Repo.insert(CL.changeset(%CL{}, %{name: "Rolled"}))
      Repo.rollback(:nope)
    end)

    assert Repo.aggregate(CL, :count) == 0
  end

  # ---------------------------------------------------------------------------
  # Foreign keys enabled
  # ---------------------------------------------------------------------------

  test "foreign_keys pragma is on" do
    result = Repo.query!("PRAGMA foreign_keys")
    assert result.rows == [[1]]
  end

  # ---------------------------------------------------------------------------
  # Busy timeout
  # ---------------------------------------------------------------------------

  test "busy_timeout is set" do
    result = Repo.query!("PRAGMA busy_timeout")
    [[timeout]] = result.rows
    assert timeout == 5000
  end
end
