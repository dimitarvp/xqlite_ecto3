defmodule XqliteEcto3.Types.Instant do
  @moduledoc """
  Point-in-time type stored as int64 nanoseconds since Unix epoch.

  Analogous to `java.time.Instant`. Designed for high-volume timestamp
  workloads (IoT telemetry, event logs, APM, trading) where:

    * nanosecond precision matters,
    * compact storage matters (8 bytes vs ~25–30 for ISO 8601 text),
    * range queries should be index-backed integer comparisons.

  For human-facing timestamps (`created_at`, `updated_at`) Ecto's
  built-in `:utc_datetime_usec` is usually the better fit — it's
  readable in the SQLite CLI and portable across engines.

  ## Usage

      schema "ticks" do
        field :occurred_at, XqliteEcto3.Types.Instant
      end

  Migration:

      add :occurred_at, :integer

  (SQLite stores as NUMERIC; xqlite's NIF binds Elixir integers as
  INTEGER.)

  ## Cast accepts

    * `%DateTime{}` — converted via `DateTime.to_unix(dt, :nanosecond)`
    * integer — treated as nanoseconds since Unix epoch
    * `{value, :nanosecond | :microsecond | :millisecond | :second}`
      tuple

  ## Load returns

  The integer nanosecond count that was stored, exactly. A value read
  from a field can therefore be written back, pinned in a `where`
  clause, or copied into a new row without losing its last three
  digits.

  ## Showing the value

  `to_datetime/1` is the conversion for display. Elixir's `DateTime`
  carries microseconds, so the conversion rounds the count **down** to
  a whole microsecond — a negative count moves earlier, never later:

      Instant.to_datetime(1_750_000_000_123_456_789)
      #=> {:ok, ~U[2025-06-15 15:06:40.123456Z]}

      Instant.to_datetime(-1)
      #=> {:ok, ~U[1969-12-31 23:59:59.999999Z]}

  The same rounding happens on the way in: `cast/1` of a `%DateTime{}`
  is its microseconds times 1000, so assigning a `%DateTime{}` to the
  field through a changeset, or pinning one in a query, cannot reach a
  row whose stored count has sub-microsecond digits. Hand those the
  integer.

  ## Range

  int64 ns from Unix epoch covers **1677-09-21 to 2262-04-11**. The
  type itself passes any integer through; the driver refuses one that
  does not fit an int64 column
  (`{:cannot_convert_to_sqlite_value, _}`). Every production Elixir
  timestamp sits well inside.
  """

  use Ecto.Type

  @ns_per_second 1_000_000_000
  @ns_per_millisecond 1_000_000
  @ns_per_microsecond 1_000

  @impl Ecto.Type
  def type, do: :integer

  @impl Ecto.Type
  def embed_as(_format), do: :self

  @impl Ecto.Type
  def cast(nil), do: {:ok, nil}

  def cast(%DateTime{} = dt) do
    {:ok, DateTime.to_unix(dt, :nanosecond)}
  end

  def cast(ns) when is_integer(ns), do: {:ok, ns}
  def cast({n, :nanosecond}) when is_integer(n), do: {:ok, n}
  def cast({n, :microsecond}) when is_integer(n), do: {:ok, n * @ns_per_microsecond}
  def cast({n, :millisecond}) when is_integer(n), do: {:ok, n * @ns_per_millisecond}
  def cast({n, :second}) when is_integer(n), do: {:ok, n * @ns_per_second}
  def cast(_), do: :error

  @impl Ecto.Type
  def dump(nil), do: {:ok, nil}
  def dump(ns) when is_integer(ns), do: {:ok, ns}
  def dump(_), do: :error

  @impl Ecto.Type
  def load(nil), do: {:ok, nil}
  def load(ns) when is_integer(ns), do: {:ok, ns}
  def load(_), do: :error

  @impl Ecto.Type
  def equal?(a, b), do: a == b

  @doc """
  Converts a stored nanosecond count into a `%DateTime{}` for display.

  `DateTime` carries microseconds, so the count is rounded down to a
  whole microsecond. `nil` passes through. A term that is not an
  integer, and a magnitude no `DateTime` can hold, both answer
  `:error`.

      iex> XqliteEcto3.Types.Instant.to_datetime(0)
      {:ok, ~U[1970-01-01 00:00:00.000000Z]}

      iex> XqliteEcto3.Types.Instant.to_datetime("now")
      :error
  """
  @spec to_datetime(term()) :: {:ok, DateTime.t() | nil} | :error
  def to_datetime(nil), do: {:ok, nil}

  def to_datetime(ns) when is_integer(ns) do
    case DateTime.from_unix(ns, :nanosecond) do
      {:ok, _datetime} = ok -> ok
      {:error, _reason} -> :error
    end
  end

  def to_datetime(_other), do: :error
end
