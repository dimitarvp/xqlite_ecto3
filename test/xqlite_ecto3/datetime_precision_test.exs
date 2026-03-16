defmodule XqliteEcto3.DatetimePrecisionTest do
  use ExUnit.Case, async: true

  alias XqliteEcto3.TestRepo, as: Repo
  import XqliteEcto3.TableHelper

  defmodule DT do
    use Ecto.Schema

    schema "dt_records" do
      field(:naive_dt, :naive_datetime)
      field(:naive_dt_usec, :naive_datetime_usec)
      field(:utc_dt, :utc_datetime)
      field(:utc_dt_usec, :utc_datetime_usec)
      timestamps()
    end
  end

  setup_all do
    create_table!(
      "dt_records",
      "id INTEGER PRIMARY KEY AUTOINCREMENT, naive_dt TEXT, naive_dt_usec TEXT, utc_dt TEXT, utc_dt_usec TEXT, inserted_at TEXT NOT NULL, updated_at TEXT NOT NULL"
    )
  end

  setup do
    clear_table!("dt_records")
  end

  # ---------------------------------------------------------------------------
  # NaiveDateTime (second precision)
  # ---------------------------------------------------------------------------

  test "naive_datetime truncates to seconds" do
    ndt = ~N[2024-06-15 14:30:45]
    {:ok, record} = Repo.insert(%DT{naive_dt: ndt})
    fetched = Repo.get(DT, record.id)
    assert fetched.naive_dt == ~N[2024-06-15 14:30:45]
    assert fetched.naive_dt.microsecond == {0, 0}
  end

  # ---------------------------------------------------------------------------
  # NaiveDateTime with microseconds
  # ---------------------------------------------------------------------------

  test "naive_datetime_usec preserves microseconds" do
    ndt = ~N[2024-06-15 14:30:45.123456]
    {:ok, record} = Repo.insert(%DT{naive_dt_usec: ndt})
    fetched = Repo.get(DT, record.id)
    assert fetched.naive_dt_usec == ~N[2024-06-15 14:30:45.123456]
    assert fetched.naive_dt_usec.microsecond == {123_456, 6}
  end

  test "naive_datetime_usec with zero microseconds" do
    ndt = ~N[2024-06-15 14:30:45.000000]
    {:ok, record} = Repo.insert(%DT{naive_dt_usec: ndt})
    fetched = Repo.get(DT, record.id)
    assert fetched.naive_dt_usec.microsecond == {0, 6}
  end

  # ---------------------------------------------------------------------------
  # UTC DateTime (second precision)
  # ---------------------------------------------------------------------------

  test "utc_datetime truncates to seconds" do
    dt = ~U[2024-06-15 14:30:45Z]
    {:ok, record} = Repo.insert(%DT{utc_dt: dt})
    fetched = Repo.get(DT, record.id)
    assert fetched.utc_dt == ~U[2024-06-15 14:30:45Z]
    assert fetched.utc_dt.microsecond == {0, 0}
  end

  # ---------------------------------------------------------------------------
  # UTC DateTime with microseconds
  # ---------------------------------------------------------------------------

  test "utc_datetime_usec preserves microseconds" do
    dt = ~U[2024-06-15 14:30:45.654321Z]
    {:ok, record} = Repo.insert(%DT{utc_dt_usec: dt})
    fetched = Repo.get(DT, record.id)
    assert fetched.utc_dt_usec == ~U[2024-06-15 14:30:45.654321Z]
    assert fetched.utc_dt_usec.microsecond == {654_321, 6}
  end

  test "utc_datetime_usec with zero microseconds" do
    dt = ~U[2024-06-15 14:30:45.000000Z]
    {:ok, record} = Repo.insert(%DT{utc_dt_usec: dt})
    fetched = Repo.get(DT, record.id)
    assert fetched.utc_dt_usec.microsecond == {0, 6}
  end

  # ---------------------------------------------------------------------------
  # Timestamps field precision
  # ---------------------------------------------------------------------------

  test "inserted_at and updated_at are set on insert" do
    {:ok, record} = Repo.insert(%DT{})
    fetched = Repo.get(DT, record.id)
    assert %NaiveDateTime{} = fetched.inserted_at
    assert %NaiveDateTime{} = fetched.updated_at
  end
end
