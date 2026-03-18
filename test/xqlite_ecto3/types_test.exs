defmodule XqliteEcto3.TypesTest do
  use ExUnit.Case, async: true

  alias Ecto.Integration.TestRepo, as: Repo
  import XqliteEcto3.TableHelper

  defmodule TR do
    use Ecto.Schema

    schema "typed_records" do
      field(:uuid_field, :string)
      field(:binary_uuid_field, :binary)
      field(:map_field, :map)
      field(:array_field, {:array, :string})
      field(:bool_field, :boolean)
      field(:decimal_field, :decimal)
      field(:date_field, :date)
      field(:time_field, :time)
      field(:naive_dt_field, :naive_datetime)
      field(:utc_dt_field, :utc_datetime)

      timestamps()
    end
  end

  setup_all do
    create_table!(
      "typed_records",
      "id INTEGER PRIMARY KEY AUTOINCREMENT, uuid_field TEXT, binary_uuid_field BLOB, map_field TEXT, array_field TEXT, bool_field INTEGER, decimal_field TEXT, date_field TEXT, time_field TEXT, naive_dt_field TEXT, utc_dt_field TEXT, inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL"
    )
  end

  setup do
    :ok = Ecto.Adapters.SQL.Sandbox.checkout(Ecto.Integration.TestRepo)
    clear_table!("typed_records")
  end

  # ---------------------------------------------------------------------------
  # UUID
  # ---------------------------------------------------------------------------

  test "string UUID round-trips" do
    uuid = Ecto.UUID.generate()
    {:ok, record} = Repo.insert(%TR{uuid_field: uuid})

    fetched = Repo.get(TR, record.id)
    assert fetched.uuid_field == uuid
  end

  # ---------------------------------------------------------------------------
  # Boolean
  # ---------------------------------------------------------------------------

  test "boolean true round-trips" do
    {:ok, record} = Repo.insert(%TR{bool_field: true})
    fetched = Repo.get(TR, record.id)
    assert fetched.bool_field == true
  end

  test "boolean false round-trips" do
    {:ok, record} = Repo.insert(%TR{bool_field: false})
    fetched = Repo.get(TR, record.id)
    assert fetched.bool_field == false
  end

  test "nil boolean round-trips" do
    {:ok, record} = Repo.insert(%TR{bool_field: nil})
    fetched = Repo.get(TR, record.id)
    assert fetched.bool_field == nil
  end

  # ---------------------------------------------------------------------------
  # Map (JSON)
  # ---------------------------------------------------------------------------

  test "map round-trips through JSON" do
    data = %{"key" => "value", "nested" => %{"a" => 1}}
    {:ok, record} = Repo.insert(%TR{map_field: data})
    fetched = Repo.get(TR, record.id)
    assert fetched.map_field == data
  end

  test "empty map round-trips" do
    {:ok, record} = Repo.insert(%TR{map_field: %{}})
    fetched = Repo.get(TR, record.id)
    assert fetched.map_field == %{}
  end

  # ---------------------------------------------------------------------------
  # Array (JSON)
  # ---------------------------------------------------------------------------

  test "string array round-trips through JSON" do
    data = ["alpha", "beta", "gamma"]
    {:ok, record} = Repo.insert(%TR{array_field: data})
    fetched = Repo.get(TR, record.id)
    assert fetched.array_field == data
  end

  test "empty array round-trips" do
    {:ok, record} = Repo.insert(%TR{array_field: []})
    fetched = Repo.get(TR, record.id)
    assert fetched.array_field == []
  end

  # ---------------------------------------------------------------------------
  # Decimal
  # ---------------------------------------------------------------------------

  test "decimal round-trips" do
    dec = Decimal.new("123.456")
    {:ok, record} = Repo.insert(%TR{decimal_field: dec})
    fetched = Repo.get(TR, record.id)
    assert Decimal.equal?(fetched.decimal_field, dec)
  end

  # ---------------------------------------------------------------------------
  # Date
  # ---------------------------------------------------------------------------

  test "date round-trips" do
    date = ~D[2024-06-15]
    {:ok, record} = Repo.insert(%TR{date_field: date})
    fetched = Repo.get(TR, record.id)
    assert fetched.date_field == date
  end

  # ---------------------------------------------------------------------------
  # Time
  # ---------------------------------------------------------------------------

  test "time round-trips" do
    time = ~T[14:30:00]
    {:ok, record} = Repo.insert(%TR{time_field: time})
    fetched = Repo.get(TR, record.id)
    assert fetched.time_field == time
  end

  # ---------------------------------------------------------------------------
  # NaiveDateTime
  # ---------------------------------------------------------------------------

  test "naive_datetime round-trips" do
    ndt = ~N[2024-06-15 14:30:00]
    {:ok, record} = Repo.insert(%TR{naive_dt_field: ndt})
    fetched = Repo.get(TR, record.id)
    assert fetched.naive_dt_field == ndt
  end

  # ---------------------------------------------------------------------------
  # UTC DateTime
  # ---------------------------------------------------------------------------

  test "utc_datetime round-trips" do
    dt = ~U[2024-06-15 14:30:00Z]
    {:ok, record} = Repo.insert(%TR{utc_dt_field: dt})
    fetched = Repo.get(TR, record.id)
    assert fetched.utc_dt_field == dt
  end
end
