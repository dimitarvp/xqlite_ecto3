defmodule XqliteEcto3.Types.Duration do
  @moduledoc """
  Absolute time-span type stored as int64 nanoseconds.

  Represents a fixed-length interval (5 minutes, 3 hours, 1.5 days) —
  **not a calendar duration** (1 month, 1 year, which have variable
  length and can't be flattened to nanoseconds losslessly). For
  calendar durations, model as separate columns (e.g. `months :int`
  + `remainder_ns :int`).

  ## Usage

      schema "tasks" do
        field :timeout, XqliteEcto3.Types.Duration
      end

  Migration:

      add :timeout, :integer

  ## Cast accepts

    * integer — treated as nanoseconds
    * `{value, :nanosecond | :microsecond | :millisecond | :second |
       :minute | :hour | :day}` tuple
    * `%Duration{}` (Elixir 1.17+) — only when `year`, `month`, and
      `week` are zero. Non-zero calendar fields return `:error`
      because they can't be flattened without a reference date.

  ## Load returns

  Integer nanoseconds. Lossless, ergonomic. Users who want a
  `%Duration{}` struct convert explicitly:

      # Elixir 1.17+
      Duration.new!(
        second: div(ns, 1_000_000_000),
        microsecond: {div(rem(ns, 1_000_000_000), 1_000), 6}
      )

  (The `%Duration{}` struct's microsecond precision means nanoseconds
  truncate on that path. Our stored int preserves ns, so load-as-int
  is always lossless.)

  ## Range

  int64 ns covers ±292 years of span. Any realistic application
  interval fits.
  """

  use Ecto.Type

  @ns_per_second 1_000_000_000
  @ns_per_millisecond 1_000_000
  @ns_per_microsecond 1_000
  @ns_per_minute 60 * 1_000_000_000
  @ns_per_hour 3_600 * 1_000_000_000
  @ns_per_day 86_400 * 1_000_000_000

  @impl Ecto.Type
  def type, do: :integer

  @impl Ecto.Type
  def cast(nil), do: {:ok, nil}
  def cast(ns) when is_integer(ns), do: {:ok, ns}
  def cast({n, :nanosecond}) when is_integer(n), do: {:ok, n}
  def cast({n, :microsecond}) when is_integer(n), do: {:ok, n * @ns_per_microsecond}
  def cast({n, :millisecond}) when is_integer(n), do: {:ok, n * @ns_per_millisecond}
  def cast({n, :second}) when is_integer(n), do: {:ok, n * @ns_per_second}
  def cast({n, :minute}) when is_integer(n), do: {:ok, n * @ns_per_minute}
  def cast({n, :hour}) when is_integer(n), do: {:ok, n * @ns_per_hour}
  def cast({n, :day}) when is_integer(n), do: {:ok, n * @ns_per_day}

  # Elixir 1.17+ `Duration` struct. Gated so this module compiles on
  # Elixir 1.15 / 1.16 where `Duration` does not exist. The pattern
  # uses `%{__struct__: Duration, ...}` to avoid a compile-time struct
  # reference that would fail pre-1.17.
  if Code.ensure_loaded?(Duration) do
    def cast(%{__struct__: Duration, year: 0, month: 0, week: 0} = d) do
      {us_value, _precision} = d.microsecond

      ns =
        d.day * @ns_per_day +
          d.hour * @ns_per_hour +
          d.minute * @ns_per_minute +
          d.second * @ns_per_second +
          us_value * @ns_per_microsecond

      {:ok, ns}
    end

    def cast(%{__struct__: Duration}), do: :error
  end

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
end
