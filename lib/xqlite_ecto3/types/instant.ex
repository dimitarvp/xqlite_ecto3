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

  `%DateTime{}` in UTC. Elixir's `DateTime` has microsecond precision,
  so the last ~3 decimal digits of nanosecond precision are lost on
  the Elixir-side read. The database still stores the full int64 ns;
  only the struct-return is truncated. If you need the exact ns back,
  query the raw column:

      from t in Tick, select: fragment("?", t.occurred_at)

  ## Range

  int64 ns from Unix epoch covers **1677-09-21 to 2262-04-11**.
  Timestamps outside that window will silently overflow or fail to
  load. Every production Elixir timestamp sits well inside.
  """

  use Ecto.Type

  @ns_per_second 1_000_000_000
  @ns_per_millisecond 1_000_000
  @ns_per_microsecond 1_000

  @impl Ecto.Type
  def type, do: :integer

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

  def load(ns) when is_integer(ns) do
    case DateTime.from_unix(ns, :nanosecond) do
      {:ok, _} = ok -> ok
      _ -> :error
    end
  end

  def load(_), do: :error

  @impl Ecto.Type
  def equal?(a, b), do: a == b
end
