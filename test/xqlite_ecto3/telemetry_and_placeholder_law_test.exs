defmodule XqliteEcto3.TelemetryAndPlaceholderLawTest do
  @moduledoc """
  Two rules the adapter has to obey no matter what is thrown at it.

  ## 1. Every timed operation reports both ends

  The driver times eight kinds of operation by wrapping them in
  `:telemetry.span/3`: `connect`, `handle_begin`, `handle_commit`,
  `handle_rollback`, `handle_execute`, `handle_declare`, `handle_fetch`
  and `handle_deallocate`. A span emits `[..., :start]` when the work
  begins and exactly one closing event when it ends. `:telemetry.span/3`
  closes with `[..., :stop]` when the wrapped code returns a value and
  with `[..., :exception]` when it raises, and it tags all three with the
  same fresh reference under `telemetry_span_context`.

  The driver never lets its wrapped code raise: every path funnels through
  `classify/2` or `classify_dbc/2` in `lib/xqlite_ecto3/driver.ex`, which
  turn a returned `{:error, ...}` into a normal `:stop` carrying
  `result_class: :error` and `error_reason`. So the promise these
  operations make is `:stop` — a failed statement is still a completed
  span, never a dropped one. The property attaches to `:exception` as
  well, so a raise would be caught rather than silently look like a
  missing closing event.

  Whatever sequence of operations runs, at the end of it:

    * every `:start` has exactly one closing event with the same span
      reference, and no closing event stands alone;
    * the two events belong to the same operation kind;
    * every field the `:start` carried is on the closing event unchanged,
      so a subscriber can join the two on the connection, the SQL, or the
      cursor it already saw;
    * the closing event's duration is not negative and its clock reading
      is not earlier than the start's;
    * `result_class` is `:ok` exactly when `error_reason` is `nil`;
    * the operations that were made to fail produce exactly that many
      `:error` closings — the half of the rule where bugs actually live.

  Telemetry handlers are global to the whole VM, so the handler here
  keeps only events belonging to this file's own connection (or its own
  database path, for the `connect` events that have no connection yet).
  Filtering on the event name alone picks up other test files' work and
  has produced flaky failures before.

  Like `XqliteEcto3.TelemetryTest`, this half only makes sense in the
  telemetry-enabled build the test config selects. The CI lane that
  compiles the flag off runs `telemetry_disabled_smoke_test.exs` alone.

  ## 2. Reordering the conditions of a query cannot change its answer

  The adapter writes numbered `?1`, `?2`, ... placeholders instead of
  bare `?` (`expr({:^, [], [ix]}, ...)` in `lib/xqlite_ecto3/connection.ex`),
  which pins every bound value to its absolute slot no matter where the
  condition ended up in the SQL text. Composing the same conditions in a
  different order therefore has to return the same rows.

  Each run builds one query in the generated order of its conditions and
  one in a shuffled order, checks that the shuffle really did move the
  bound values around (otherwise the comparison proves nothing), and
  compares the rows both against each other and against the same filter
  applied in Elixir. Every condition uses a different column and a value
  drawn from a different set, so a binding that landed on the wrong
  column changes the answer instead of raising.
  """

  use ExUnit.Case, async: true
  use ExUnitProperties

  import Ecto.Query

  alias XqliteEcto3.Driver

  defmodule SpanRepo do
    use Ecto.Repo, otp_app: :xqlite_ecto3, adapter: XqliteEcto3
  end

  # Run counts keep the whole file near ten seconds. A telemetry case runs
  # a handful of small statements and then walks the events it captured; a
  # placeholder case reloads its rows, compiles two queries and runs both.
  @span_runs 12_000
  @placeholder_runs 10_000

  @span_families [
    [:xqlite_ecto3, :connect],
    [:xqlite_ecto3, :handle_begin],
    [:xqlite_ecto3, :handle_commit],
    [:xqlite_ecto3, :handle_rollback],
    [:xqlite_ecto3, :handle_execute],
    [:xqlite_ecto3, :handle_declare],
    [:xqlite_ecto3, :handle_fetch],
    [:xqlite_ecto3, :handle_deallocate]
  ]

  @span_events for family <- @span_families,
                   suffix <- [:start, :stop, :exception],
                   do: family ++ [suffix]

  # Reserved so the deliberate-conflict operation always has something to
  # collide with, and so no other operation can take the value from it.
  @conflict_value "duplicate"

  # Row 0 is the conflict seed; the operations only ever write ids 1..20.
  @seeded_ids 1..20

  setup_all do
    database =
      Path.join(
        System.tmp_dir!(),
        "xqlite_ecto3_span_law_#{System.os_time(:nanosecond)}.db"
      )

    remove_database(database)

    config = [adapter: XqliteEcto3, database: database, pool_size: 1]

    Application.put_env(:xqlite_ecto3, SpanRepo, config)
    :ok = XqliteEcto3.storage_up(config)
    start_supervised!({SpanRepo, config})

    SpanRepo.query!(
      """
      CREATE TABLE span_rows (
        id INTEGER PRIMARY KEY,
        n INTEGER NOT NULL,
        s TEXT NOT NULL,
        u TEXT NOT NULL UNIQUE
      )
      """,
      []
    )

    SpanRepo.query!(
      "INSERT INTO span_rows (id, n, s, u) VALUES (0, 0, 'seed', ?)",
      [@conflict_value]
    )

    Enum.each(@seeded_ids, fn id ->
      SpanRepo.query!("INSERT INTO span_rows (id, n, s, u) VALUES (?, ?, 'row', ?)", [
        id,
        id,
        "u#{id}"
      ])
    end)

    SpanRepo.query!(
      """
      CREATE TABLE perm_rows (
        id INTEGER PRIMARY KEY,
        n INTEGER NOT NULL,
        s TEXT NOT NULL,
        f REAL NOT NULL,
        g TEXT NOT NULL
      )
      """,
      []
    )

    on_exit(fn -> remove_database(database) end)

    # A directory that does not exist, so opening a database under it
    # always fails. Unique to this run, which is what lets the handler
    # tell this file's failed connect apart from anybody else's.
    missing_database =
      Path.join([
        "/",
        "xqlite_ecto3_absent_#{System.os_time(:nanosecond)}",
        "law.db"
      ])

    {:ok, database: database, missing_database: missing_database}
  end

  defp remove_database(database) do
    Enum.each(["", "-wal", "-shm"], fn suffix -> File.rm(database <> suffix) end)
  end

  # --- 1. span pairing --------------------------------------------------------

  property "every timed operation reports a start and exactly one closing event",
           context do
    connection = XqliteEcto3.with_xqlite(SpanRepo, fn handle -> handle end)

    handler_id = "span-law-#{:erlang.unique_integer([:positive])}"
    databases = MapSet.new([context.database, context.missing_database])

    :telemetry.attach_many(
      handler_id,
      @span_events,
      &__MODULE__.forward_span_event/4,
      %{pid: self(), conn: connection, databases: databases}
    )

    on_exit(fn -> :telemetry.detach(handler_id) end)

    # Nothing should be waiting yet, but starting from a known-empty
    # mailbox keeps the first case honest.
    drain_span_events()

    check all(
            operations <- list_of(operation(), min_length: 1, max_length: 5),
            max_runs: @span_runs
          ) do
      Enum.each(operations, fn operation -> run_operation(operation, context) end)

      events = drain_span_events()

      assert_span_law(events, %{
        errors: sum_over(operations, &failing_spans/1),
        minimum_spans: sum_over(operations, &least_spans/1)
      })
    end
  end

  # Telemetry runs handlers in whichever process emitted the event, and
  # the pool runs the driver callbacks in the caller — so these arrive in
  # the test's own mailbox before the operation that caused them returns.
  @doc false
  def forward_span_event(name, measurements, metadata, config) do
    if own_event?(metadata, config) do
      send(config.pid, {:span_event, name, measurements, metadata})
    else
      :ok
    end
  end

  defp own_event?(%{conn: connection}, %{conn: connection}), do: true

  defp own_event?(%{database: database}, %{databases: databases}) do
    MapSet.member?(databases, database)
  end

  defp own_event?(_metadata, _config), do: false

  defp drain_span_events(acc \\ []) do
    receive do
      {:span_event, name, measurements, metadata} ->
        event = %{
          family: Enum.drop(name, -1),
          suffix: List.last(name),
          measurements: measurements,
          metadata: metadata
        }

        drain_span_events([event | acc])
    after
      0 -> Enum.reverse(acc)
    end
  end

  defp assert_span_law(events, expected) do
    assert events != []
    Enum.each(events, fn event -> assert event.family in @span_families end)

    events
    |> Enum.group_by(fn event -> event.metadata.telemetry_span_context end)
    |> Enum.each(fn {_span, group} -> assert_one_span(group) end)

    starts = Enum.filter(events, fn event -> event.suffix == :start end)
    stops = Enum.filter(events, fn event -> event.suffix == :stop end)
    failed = Enum.filter(stops, fn event -> event.metadata.result_class == :error end)

    assert length(starts) == length(stops)
    assert length(starts) >= expected.minimum_spans
    assert length(failed) == expected.errors
  end

  # One start, one stop, in that order, and nothing else under the same
  # span reference. An operation whose closing event never fired leaves a
  # group of one; a doubled closing event leaves a group of three.
  defp assert_one_span(group) do
    assert Enum.map(group, fn event -> event.suffix end) == [:start, :stop]

    [start_event, stop_event] = group

    assert start_event.family == stop_event.family
    assert_identity_carried(start_event, stop_event)
    assert_timings(start_event, stop_event)
    assert_outcome(stop_event)
  end

  defp assert_identity_carried(start_event, stop_event) do
    carried = Map.delete(start_event.metadata, :telemetry_span_context)

    assert Map.take(stop_event.metadata, Map.keys(carried)) == carried
  end

  defp assert_timings(start_event, stop_event) do
    assert is_integer(start_event.measurements.monotonic_time)
    assert is_integer(start_event.measurements.system_time)
    assert is_integer(stop_event.measurements.duration)
    assert stop_event.measurements.duration >= 0
    assert stop_event.measurements.monotonic_time >= start_event.measurements.monotonic_time
  end

  defp assert_outcome(%{metadata: %{result_class: :ok, error_reason: reason}}) do
    assert reason == nil
  end

  defp assert_outcome(%{metadata: %{result_class: :error, error_reason: reason}}) do
    assert reason != nil
  end

  defp assert_outcome(stop_event) do
    flunk("closing event reported neither :ok nor :error: #{inspect(stop_event.metadata)}")
  end

  defp sum_over(operations, fun) do
    operations
    |> Enum.map(fun)
    |> Enum.sum()
  end

  # --- the operations the property strings together ---------------------------

  defp operation do
    one_of([
      tuple({constant(:select), integer(0..20)}),
      tuple({constant(:insert), integer(@seeded_ids)}),
      tuple({constant(:transaction_commit), integer(@seeded_ids)}),
      tuple({constant(:transaction_rollback), integer(@seeded_ids)}),
      tuple({constant(:stream), integer(1..8)}),
      constant({:syntax_error, nil}),
      constant({:unique_conflict, nil}),
      constant({:failing_query_in_transaction, nil}),
      constant({:failed_connect, nil})
    ])
  end

  defp run_operation({:select, threshold}, _context) do
    query =
      from(r in "span_rows", where: r.n > ^threshold, order_by: r.id, limit: 5, select: r.id)

    SpanRepo.all(query)
  end

  defp run_operation({:insert, id}, _context) do
    SpanRepo.query!(replace_sql(), replace_params(id))
  end

  defp run_operation({:transaction_commit, id}, _context) do
    SpanRepo.transaction(fn -> SpanRepo.query!(replace_sql(), replace_params(id)) end)
  end

  defp run_operation({:transaction_rollback, id}, _context) do
    SpanRepo.transaction(fn ->
      SpanRepo.query!(replace_sql(), replace_params(id))
      SpanRepo.rollback(:law)
    end)
  end

  defp run_operation({:stream, batch}, _context) do
    query = from(r in "span_rows", order_by: r.id, select: r.id)

    SpanRepo.transaction(fn ->
      query
      |> SpanRepo.stream(max_rows: batch)
      |> Enum.take(batch)
    end)
  end

  defp run_operation({:syntax_error, nil}, _context) do
    assert {:error, _reason} = SpanRepo.query("SELEKT law", [])
  end

  defp run_operation({:unique_conflict, nil}, _context) do
    assert {:error, _reason} =
             SpanRepo.query(
               "INSERT INTO span_rows (id, n, s, u) VALUES (900, 1, 'row', ?)",
               [@conflict_value]
             )
  end

  defp run_operation({:failing_query_in_transaction, nil}, _context) do
    SpanRepo.transaction(fn -> assert {:error, _reason} = SpanRepo.query("SELEKT law", []) end)
  end

  defp run_operation({:failed_connect, nil}, context) do
    assert {:error, _reason} = Driver.connect(database: context.missing_database)
  end

  defp replace_sql do
    "INSERT OR REPLACE INTO span_rows (id, n, s, u) VALUES (?, ?, 'row', ?)"
  end

  defp replace_params(id), do: [id, id, "u#{id}"]

  # How many closing events each operation is made to fail.
  defp failing_spans({:syntax_error, _arg}), do: 1
  defp failing_spans({:unique_conflict, _arg}), do: 1
  defp failing_spans({:failing_query_in_transaction, _arg}), do: 1
  defp failing_spans({:failed_connect, _arg}), do: 1
  defp failing_spans(_operation), do: 0

  # The fewest spans an operation can possibly open, so a run that
  # captured nothing (a filter that stopped matching, say) fails loudly
  # instead of passing on an empty list.
  defp least_spans({:transaction_commit, _arg}), do: 3
  defp least_spans({:transaction_rollback, _arg}), do: 3
  defp least_spans({:failing_query_in_transaction, _arg}), do: 3
  defp least_spans({:stream, _arg}), do: 5
  defp least_spans(_operation), do: 1

  # --- 2. numbered placeholders ----------------------------------------------

  @slots [:n, :s, :f, :g]

  property "the same conditions in any order return the same rows" do
    check all(
            rows <- data_set(),
            specs <- condition_set(),
            style <- member_of([:dynamic, :where_chain]),
            order <- shuffles(length(specs)),
            max_runs: @placeholder_runs
          ) do
      load_rows(rows)

      as_written = build_query(style, specs)
      reordered = build_query(style, reorder(specs, order))

      {_sql, written_params} = Ecto.Adapters.SQL.to_sql(:all, SpanRepo, as_written)
      {_sql, reordered_params} = Ecto.Adapters.SQL.to_sql(:all, SpanRepo, reordered)

      # Without this the row comparison below would be comparing a query
      # against itself: the shuffle has to reach the bound values.
      assert reordered_params == reorder(written_params, order)
      assert reordered_params != written_params

      written_rows = SpanRepo.all(as_written)

      assert written_rows == expected_rows(rows, specs)
      assert SpanRepo.all(reordered) == written_rows
    end
  end

  test "a reordered condition renumbers the placeholders and moves the values" do
    specs = [{:n, 5}, {:s, "s3"}, {:f, 9.5}]
    as_written = build_query(:dynamic, specs)
    reordered = build_query(:dynamic, reorder(specs, [2, 0, 1]))

    {written_sql, written_params} = Ecto.Adapters.SQL.to_sql(:all, SpanRepo, as_written)
    {reordered_sql, reordered_params} = Ecto.Adapters.SQL.to_sql(:all, SpanRepo, reordered)

    assert written_params == [5, "s3", 9.5]
    assert reordered_params == [9.5, 5, "s3"]

    assert written_sql ==
             ~s{SELECT p0."id", p0."n", p0."s", p0."f", p0."g" FROM "perm_rows" AS p0 } <>
               ~s{WHERE (((p0."n" > ?1) AND (p0."s" != ?2)) AND (p0."f" < ?3)) ORDER BY p0."id"}

    assert reordered_sql ==
             ~s{SELECT p0."id", p0."n", p0."s", p0."f", p0."g" FROM "perm_rows" AS p0 } <>
               ~s{WHERE (((p0."f" < ?1) AND (p0."n" > ?2)) AND (p0."s" != ?3)) ORDER BY p0."id"}
  end

  defp load_rows(rows) do
    SpanRepo.query!("DELETE FROM perm_rows", [])

    groups = Enum.map_join(rows, ",", fn _row -> "(?,?,?,?,?)" end)
    params = Enum.flat_map(rows, fn row -> [row.id, row.n, row.s, row.f, row.g] end)

    SpanRepo.query!("INSERT INTO perm_rows (id, n, s, f, g) VALUES " <> groups, params)
  end

  defp build_query(:dynamic, specs) do
    combined =
      specs
      |> Enum.map(fn spec -> condition(spec) end)
      |> Enum.reduce(fn next, acc -> dynamic(^acc and ^next) end)

    base_query()
    |> where(^combined)
    |> finish_query()
  end

  defp build_query(:where_chain, specs) do
    specs
    |> Enum.reduce(base_query(), fn spec, query -> add_where(query, spec) end)
    |> finish_query()
  end

  defp base_query, do: from(r in "perm_rows")

  defp finish_query(query) do
    from(r in query, order_by: r.id, select: [r.id, r.n, r.s, r.f, r.g])
  end

  defp condition({:n, value}), do: dynamic([r], r.n > ^value)
  defp condition({:s, value}), do: dynamic([r], r.s != ^value)
  defp condition({:f, value}), do: dynamic([r], r.f < ^value)
  defp condition({:g, value}), do: dynamic([r], r.g >= ^value)

  defp add_where(query, {:n, value}), do: where(query, [r], r.n > ^value)
  defp add_where(query, {:s, value}), do: where(query, [r], r.s != ^value)
  defp add_where(query, {:f, value}), do: where(query, [r], r.f < ^value)
  defp add_where(query, {:g, value}), do: where(query, [r], r.g >= ^value)

  # The same filter applied in Elixir. All five columns are NOT NULL and
  # every text value is plain ASCII of the same length, so Elixir's
  # comparisons and SQLite's are the same comparisons.
  defp expected_rows(rows, specs) do
    rows
    |> Enum.filter(fn row -> Enum.all?(specs, fn spec -> keeps?(row, spec) end) end)
    |> Enum.map(fn row -> [row.id, row.n, row.s, row.f, row.g] end)
  end

  defp keeps?(row, {:n, value}), do: row.n > value
  defp keeps?(row, {:s, value}), do: row.s != value
  defp keeps?(row, {:f, value}), do: row.f < value
  defp keeps?(row, {:g, value}), do: row.g >= value

  defp reorder(list, order) do
    Enum.map(order, fn index -> Enum.at(list, index) end)
  end

  # --- generators -------------------------------------------------------------

  defp data_set do
    gen all(values <- list_of(row_values(), min_length: 1, max_length: 12)) do
      values
      |> Enum.with_index(1)
      |> Enum.map(fn {{n, s, f, g}, id} -> %{id: id, n: n, s: s, f: f, g: g} end)
    end
  end

  defp row_values do
    gen all(
          n <- integer(0..30),
          s <- label("s"),
          f <- half_step(),
          g <- label("g")
        ) do
      {n, s, f, g}
    end
  end

  # Each condition names a different column, and the four value sets share
  # no member: an integer, a float ending in .5, an "s" label and a "g"
  # label are four values that can never be equal. That is what makes a
  # binding landing in the wrong slot show up as different rows rather
  # than as a type error SQLite would shrug off.
  #
  # The columns are picked by shuffling all four and taking a prefix, not
  # by drawing until the draws happen to differ: with only four to choose
  # from, drawing gives up long before it finds a fourth distinct one.
  defp condition_set do
    gen all(
          size <- integer(2..4),
          ordering <- member_of(orderings(@slots)),
          specs <- ordering |> Enum.take(size) |> Enum.map(&spec/1) |> fixed_list()
        ) do
      specs
    end
  end

  defp spec(slot) do
    slot
    |> slot_values()
    |> map(fn value -> {slot, value} end)
  end

  defp slot_values(:n), do: integer(0..30)
  defp slot_values(:s), do: label("s")
  defp slot_values(:f), do: half_step()
  defp slot_values(:g), do: label("g")

  defp label(prefix) do
    map(integer(0..9), fn digit -> prefix <> Integer.to_string(digit) end)
  end

  defp half_step do
    map(integer(0..20), fn step -> step + 0.5 end)
  end

  # Only orders that actually move something — the identity order would
  # make the comparison vacuous.
  defp shuffles(count) do
    positions = Enum.to_list(0..(count - 1))

    positions
    |> orderings()
    |> Enum.reject(fn order -> order == positions end)
    |> member_of()
  end

  defp orderings([]), do: [[]]

  defp orderings(positions) do
    for head <- positions, tail <- orderings(positions -- [head]), do: [head | tail]
  end
end
