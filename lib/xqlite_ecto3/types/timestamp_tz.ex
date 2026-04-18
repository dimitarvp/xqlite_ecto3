defmodule XqliteEcto3.Types.TimestampTZ do
  @moduledoc """
  Timezone-aware `DateTime` type for SQLite.

  Stores the datetime as ISO 8601 text with its original offset preserved
  (e.g. `"2024-01-15T10:30:00.123456-05:00"`). Unlike Ecto's built-in
  `:utc_datetime` and `:utc_datetime_usec`, this type **accepts non-UTC
  DateTimes on cast and dump** without forcing you to shift to UTC first.

  ## Usage

      schema "events" do
        field :occurred_at, XqliteEcto3.Types.TimestampTZ
      end

  ## Migration

      create table(:events) do
        add :occurred_at, :string
      end

  The migration column type is plain `:string` (stored as TEXT in SQLite).
  The adapter does not auto-map field type to migration column type; schemas
  and migrations stay separate sources of truth.

  ## Round-trip

  | Step | Value |
  |------|-------|
  | User provides | `%DateTime{time_zone: "America/New_York", …}` |
  | `dump/1` produces | `"2024-01-15T10:30:00.000000-05:00"` (text stored in DB) |
  | `load/1` returns | `%DateTime{time_zone: "Etc/UTC", utc_offset: 0, …}` |

  The offset is encoded in the stored ISO 8601 string and preserved across
  the dump/load round-trip. However, `DateTime.from_iso8601/1` normalizes
  to UTC on parse, so the returned struct has `time_zone: "Etc/UTC"` and
  the offset is effectively collapsed. If you need to display the value in
  its original zone, use `DateTime.shift_zone!/2` with a `TimeZoneDatabase`
  (e.g. `Tz` or `Tzdata`) and store the zone name alongside.

  ## Why not just use `:utc_datetime`?

  `:utc_datetime` requires you to shift to UTC before casting:

      # Raises if not already UTC
      Ecto.Changeset.cast(changeset, %{occurred_at: local_dt}, [:occurred_at])

  With this type you can hand any `DateTime` to cast/dump without
  pre-shifting, and the stored form carries the offset. For apps that
  routinely work with wallclock times in specific zones, that's less
  boilerplate at call sites.

  ## Precision

  Microsecond precision is preserved when present on the input `DateTime`.
  A zero-precision `DateTime` (`{0, 0}`) dumps without fractional seconds.
  SQLite's TEXT column stores either verbatim.

  ## Limitation

  `DateTime.from_iso8601/1` only returns the offset, not the original
  time-zone name. If round-tripping `"America/New_York"` → DB →
  `"America/New_York"` matters, store the zone name in a separate column
  and re-attach it after loading.
  """

  use Ecto.Type

  @impl Ecto.Type
  def type, do: :string

  @impl Ecto.Type
  def cast(nil), do: {:ok, nil}
  def cast(%DateTime{} = dt), do: {:ok, dt}

  def cast(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> {:ok, dt}
      _ -> :error
    end
  end

  def cast(_), do: :error

  @impl Ecto.Type
  def dump(nil), do: {:ok, nil}
  def dump(%DateTime{} = dt), do: {:ok, DateTime.to_iso8601(dt)}
  def dump(_), do: :error

  @impl Ecto.Type
  def load(nil), do: {:ok, nil}

  def load(str) when is_binary(str) do
    case DateTime.from_iso8601(str) do
      {:ok, dt, _offset} -> {:ok, dt}
      _ -> :error
    end
  end

  def load(_), do: :error

  @impl Ecto.Type
  def equal?(a, b), do: a == b
end
