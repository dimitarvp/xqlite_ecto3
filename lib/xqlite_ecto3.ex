defmodule XqliteEcto3 do
  @moduledoc """
  Ecto 3.x adapter for SQLite via xqlite.

  ## Usage

      # In your config:
      config :my_app, MyApp.Repo,
        adapter: XqliteEcto3,
        database: "priv/my_app.db"

      # In your repo:
      defmodule MyApp.Repo do
        use Ecto.Repo,
          otp_app: :my_app,
          adapter: XqliteEcto3
      end

  ## Migration helpers

  `XqliteEcto3.Migration` exposes opt-in helpers for SQLite-specific
  migration patterns — most notably `enum_check/3` for generating a
  `CHECK (col IN (...))` constraint that mirrors an `Ecto.Enum`'s
  declared values. Importing those helpers couples your migrations to
  `xqlite_ecto3`; each helper also documents its inline equivalent if
  portability matters more than ergonomics.

  ## `ALTER TABLE ... MODIFY COLUMN` via table rebuild

  SQLite cannot modify a column in place. Set `support_alter_via_table_rebuild:
  true` in your repo config to enable the opt-in 12-step rebuild dance for a
  migration `:modify`. The rebuild preserves everything SQLite exposes
  structurally — foreign keys (composite keys, `ON DELETE`/`ON UPDATE` actions,
  and implicit-primary-key references included), the primary key (single-column
  and composite), and UNIQUE constraints are reconstructed from the structural
  pragmas, alongside indexes, triggers, and the AUTOINCREMENT sequence. `CHECK`
  constraints, `COLLATE` clauses, generated columns, `DEFERRABLE` foreign keys,
  `ON CONFLICT` clauses, and the `WITHOUT ROWID` / `STRICT` table options cannot
  be reconstructed structurally, so a `:modify` on a table declaring any of them
  refuses loudly rather than dropping it — perform those by hand with
  `execute/1`. A rebuild also refuses when another, *populated* table references
  the rebuilt table with an `ON DELETE CASCADE`/`SET NULL`/`SET DEFAULT` action:
  dropping the old table would fire that action on the referencing rows, so empty
  those rows first or make the change by hand. Empty referencing tables are fine;
  a `NO ACTION`/`RESTRICT` reference fails loudly by SQLite's own rules. See
  `XqliteEcto3.Migration` and the README for details.

  ## UUID / binary_id storage

  Set `config :xqlite_ecto3, :binary_id_storage, :string | :binary` and
  use the standard Ecto field type:

      @primary_key {:id, :binary_id, autogenerate: true}

  `:string` (default) stores the 36-character UUID form in a TEXT column.
  `:binary` stores the raw 16 bytes in a BLOB column — 55% smaller per
  row, worth it at large scale. The config governs the dumper and the
  migration column type uniformly; the Elixir-side representation is
  always the 36-character string either way.

  **Fresh databases only.** Flipping the config after rows exist in
  `:string` form is not transparent — Ecto's default UUID loader expects
  raw 16-byte input, so the adapter cannot read back old `:string`-form
  rows after switching to `:binary`. Either pick a mode at project
  inception, or run a data migration when switching.

  For the rare case where different fields in the same schema need
  different storage modes, see `XqliteEcto3.Types.UUID` — a parameterized
  type with a per-field `:storage` option.

  ## Timezone-aware timestamps

  `XqliteEcto3.Types.TimestampTZ` stores `DateTime` values as ISO 8601
  text with the original offset preserved. Unlike Ecto's built-in
  `:utc_datetime` / `:utc_datetime_usec` which force UTC and drop zone
  info, this type accepts non-UTC DateTimes on cast and dump without
  making you shift first. The stored string carries the offset; the
  loaded value is UTC-normalized with the offset encoded in the ISO
  text. See its moduledoc for the round-trip caveats.

  ## Array, Instant, Duration types

  `XqliteEcto3.Types.Array` stores Elixir lists as JSON text. Accepts
  a `:element` parameter for per-element type-checking (`:any` default,
  or `:string | :integer | :float | :boolean`). Pair with
  `XqliteEcto3.Migration.array_check/2` in migrations to reject
  non-array writes at the DB level.

  `XqliteEcto3.Types.Instant` stores moments in time as int64
  nanoseconds from Unix epoch. Compact + fast for high-volume
  timestamp workloads (IoT, APM, trading). Loads as `%DateTime{}`.

  `XqliteEcto3.Types.Duration` stores fixed-length time spans as int64
  nanoseconds. Accepts Elixir 1.17+ `%Duration{}` when the calendar
  fields (year/month/week) are zero. Loads as integer nanoseconds.

  ## JSON path coercion (the `o.metadata["enabled"] == true` case)

  SQLite's `json_extract` returns **integer 1 or 0** for JSON booleans.
  There is no native boolean type. A query like

      from o in Order, select: o.metadata["enabled"]

  returns `1` or `0`, not `true` or `false`, so `TestRepo.one(...) == true`
  fails at the Elixir-level comparison. Postgres and MySQL's JSON types
  preserve booleans natively; SQLite does not.

  **The canonical workaround is Ecto's built-in `type/2`:**

      # Doesn't work — returns 1 or 0
      from o in Order, select: o.metadata["enabled"]

      # Works — loader coerces 0/1 to false/true
      from o in Order, select: type(o.metadata["enabled"], :boolean)

  Same pattern applies for any path whose JSON type needs a specific
  Elixir shape (`:integer`, `:string`, `:naive_datetime`, etc.). The
  adapter's loaders chain handles the coercion once the type is declared.

  The same annotation is the **schemaless** story: without a schema
  there is no field type to trigger the JSON loader, so
  `from(t in "items", select: t.meta)` returns the stored TEXT.
  Annotate and it decodes — on whole columns, on JSON paths, and inside
  select maps:

      from t in "items", select: type(t.meta, :map)
      from t in "items", select: type(t.meta["nested"], :map)
      from t in "items", select: %{id: t.id, meta: type(t.meta, :map)}

  There is deliberately no always-decoding custom type for this:
  untyped select expressions have no Ecto load hook to attach one to,
  so `type/2` is the mechanism.

  The shared Ecto test suite's `:json_extract_path` tests that don't use
  `type/2` remain excluded — this matches `ecto_sqlite3`'s stance. The
  two of four variants that don't hit this case (arrays/objects, embeds)
  run cleanly.

  ## Decimal precision (the >15-significant-digit trap)

  SQLite has **no exact-decimal storage class.** The `:decimal` migration
  type maps to a `DECIMAL` column, which carries NUMERIC affinity: SQLite
  coerces a numeric value to INTEGER or REAL (IEEE-754 float64) at write
  time. Only values that survive a float64 round-trip — roughly the first
  ~15 significant decimal digits — can be stored exactly.

  Rather than **silently round** a value beyond that precision, the adapter
  **refuses it at the binding boundary.** A `Decimal` that would not survive
  the float64 round-trip raises `XqliteEcto3.DecimalPrecisionError` (the
  offending value is on its `:value` field) instead of being written as a
  quietly-wrong number:

      # a :decimal column, storing more than float64 can hold exactly:
      Repo.insert(%Ledger{amount: Decimal.new("12345678901234567890.12345")})
      # ** (XqliteEcto3.DecimalPrecisionError) decimal 12345678901234567890.12345
      #    exceeds SQLite's exact numeric precision ...

  Numeric storage is kept deliberately, so ordering and range queries on the
  column still work. Typical money (two decimal places up to ~13 integer
  digits — i.e. within 15 significant digits) round-trips exactly and stores
  without complaint, so most applications never see the error. If you need
  more than 15 significant digits (large sums, 18-decimal crypto amounts,
  scientific data), pick an exact representation up front:

    * store an **integer count of the smallest unit** (e.g. cents, wei) in
      an `:integer` / `:id` column and scale in your domain code, or
    * store the canonical string in a `:string` column yourself — exact,
      but SQL range comparisons then sort lexically, not numerically, so
      only do equality/prefix lookups on it.

  This is a fundamental SQLite limitation shared by every SQLite adapter;
  there is no column type that preserves both arbitrary precision *and*
  numeric comparison. The adapter refuses the lossy write rather than
  silently pick one for you.

  ## Nested transactions and raw SAVEPOINT SQL

  Ecto's `Repo.transaction/2` nests via savepoints internally — the driver
  emits `SAVEPOINT xqlite_sp_<random-prefix>_N`, `RELEASE SAVEPOINT ...`, and
  `ROLLBACK TO SAVEPOINT ...` to implement nesting. The random prefix is a
  per-connection token generated at `connect/1` time, and the `N` is a
  counter of currently-open managed savepoints.

  **Don't mix raw `SAVEPOINT`/`RELEASE`/`ROLLBACK TO SAVEPOINT` SQL inside a
  `Repo.transaction` callback.** The managed savepoint stack and any raw
  savepoints you issue live on the same SQLite connection, but the driver
  tracks only its own counter. A raw `SAVEPOINT myname` executed mid-
  transaction will not collide with the driver's naming thanks to the random
  prefix, but a raw `RELEASE SAVEPOINT` or `ROLLBACK TO SAVEPOINT` that
  accidentally hits *above* the driver's counter will unwind state the
  driver thinks it still owns — leaving subsequent `Repo.transaction` nesting
  to fail with `SQLite error: no such savepoint` or silently commit changes
  you did not expect.

  If you need savepoint-like atomicity inside a transaction, use nested
  `Repo.transaction/2` calls and let the driver manage the stack. If you
  absolutely must issue raw savepoint SQL (e.g. integrating with a library
  that predates `Repo.transaction`), keep it strictly within its own pair of
  raw begin/commit and do not wrap it in `Repo.transaction`.
  """

  @behaviour Ecto.Adapter.Storage
  @behaviour Ecto.Adapter.Structure

  use Ecto.Adapters.SQL,
    driver: :xqlite_ecto3

  # Ecto's generic `:url` handling raises on sqlite:// URLs (it demands a
  # host and a single-segment path), and it runs AFTER the repo's init/2.
  # Injecting a default init/2 into repos that don't define their own pops
  # `:url` and merges our parser's output before Ecto ever sees it — so
  # `config :app, Repo, url: "sqlite:///..."` just works. Repos with a
  # custom init/2 are left untouched (see the README for the two lines
  # they need).
  @impl true
  defmacro __before_compile__(env) do
    sql = Ecto.Adapters.SQL.__before_compile__(@driver, env)

    url_init =
      if !Module.defines?(env.module, {:init, 2}) do
        quote do
          @impl Ecto.Repo
          def init(_type, config) do
            {url, config} = Keyword.pop(config, :url)

            case url do
              empty when empty in [nil, ""] -> {:ok, config}
              url -> {:ok, Keyword.merge(config, XqliteEcto3.parse_url!(url))}
            end
          end
        end
      end

    quote do
      unquote(sql)
      unquote(url_init)
    end
  end

  @doc """
  Parses a database URL into keyword-list options.

  Delegates to `XqliteEcto3.URL.parse/1`. See that module for the
  accepted URL shape, the query-parameter allowlist, and the error
  cases.

  Returns `{:ok, opts}` or `{:error, %XqliteEcto3.URLError{}}`.
  """
  @spec parse_url(String.t()) :: {:ok, keyword()} | {:error, XqliteEcto3.URLError.t()}
  def parse_url(url), do: XqliteEcto3.URL.parse(url)

  @doc """
  Like `parse_url/1` but raises `XqliteEcto3.URLError` on failure.

  Prefer this in config-time call sites — bad URL in
  `config/runtime.exs` should fail app boot early with a clear stack
  trace rather than surface as a later cryptic pool error.
  """
  @spec parse_url!(String.t()) :: keyword()
  def parse_url!(url), do: XqliteEcto3.URL.parse!(url)

  @doc """
  Returns a pooled connection's transaction state:
  `{:ok, :none | :read | :write}`.

  Checks a connection out of the pool: an idle pool reports
  `{:ok, :none}`; under `Ecto.Adapters.SQL.Sandbox` the caller's
  sandboxed connection is observed (typically `{:ok, :write}` — the
  sandbox wrapper transaction under the `:immediate` default). Do not
  call inside `Repo.transaction/2` on a plain pool — like
  `with_xqlite/3` it needs a checkout while the transaction already
  holds one; there, call `XqliteNIF.txn_state/2` on the connection you
  already hold. `schema` names an attached database (default
  `"main"`).
  """
  @spec txn_state(module() | pid(), String.t()) ::
          {:ok, :none | :read | :write} | {:error, term()}
  def txn_state(repo, schema \\ "main") do
    with_xqlite(repo, fn conn -> XqliteNIF.txn_state(conn, schema) end)
  end

  @doc """
  Returns SQLite's per-connection counters (`sqlite3_db_status`) for a
  pooled connection as `{:ok, map}` of integers — cache
  hits/misses/spills, schema and statement memory, lookaside stats.
  """
  @spec connection_stats(module() | pid()) :: {:ok, map()} | {:error, term()}
  def connection_stats(repo) do
    with_xqlite(repo, fn conn -> XqliteNIF.connection_stats(conn) end)
  end

  @doc """
  Checks a connection out of `repo`'s pool and calls `fun` with the raw
  `XqliteNIF` connection reference.

  Because it needs its own checkout, do not call it from inside
  `Repo.transaction/2` on a plain pool — the transaction already holds
  a connection, and a second checkout queues behind the pool (deadlock
  on `pool_size: 1`). Under `Ecto.Adapters.SQL.Sandbox` ownership the
  caller's sandboxed connection is reused instead, so nesting is fine
  there.

  This is the bridge to SQLite-specific xqlite features that have no
  Ecto-level equivalent — session extension, incremental blob I/O,
  online backup, `serialize`/`deserialize`, extension loading, typed
  schema introspection — letting them run against the same database
  and pool as your repo, with no out-of-band second connection:

      XqliteEcto3.with_xqlite(MyApp.Repo, fn conn ->
        Xqlite.backup(conn, "/backups/app.db")
      end)

      {:ok, columns} =
        XqliteEcto3.with_xqlite(MyApp.Repo, fn conn ->
          XqliteNIF.schema_columns(conn, "users")
        end)

  Returns whatever `fun` returns.

  ## Handle validity

  The reference is only yours between checkout and return — do not
  store it, send it to another process, or use it after `fun` returns.
  A smuggled reference keeps working (the connection serializes access
  internally, so there is no memory-safety hazard) but it races other
  pool users at the application level: statements interleave with
  whatever the pool is running.

  ## Options

  Forwarded to `DBConnection.run/3` — most usefully `:timeout` for the
  checkout duration (DBConnection's default is 15 seconds).

  Inside `Ecto.Adapters.SQL.Sandbox` tests the handle is the sandboxed
  connection: your test's uncommitted writes are visible to it.
  """
  @spec with_xqlite(module() | GenServer.server(), (Xqlite.conn() -> result), keyword()) ::
          result
        when result: var
  def with_xqlite(repo, fun, opts \\ []) when is_function(fun, 1) do
    name =
      if is_atom(repo) and function_exported?(repo, :get_dynamic_repo, 0) do
        repo.get_dynamic_repo()
      else
        repo
      end

    %{pid: pool, opts: default_opts} = Ecto.Adapter.lookup_meta(name)
    run_opts = Keyword.merge(default_opts, opts)

    DBConnection.run(
      pool,
      fn conn ->
        handle = DBConnection.execute!(conn, %XqliteEcto3.RawConn{}, [], run_opts)
        fun.(handle)
      end,
      run_opts
    )
  end

  @doc """
  Runs `queryable` under SQLite's real execution counters and returns
  xqlite's structured `Xqlite.ExplainAnalyze` report: the query plan,
  per-scan loop and visited-row counters (`sqlite3_stmt_scanstatus_v2`),
  statement-level counters, and wall-clock time.

  ⚠️ **This executes the statement** — that is what makes the numbers
  real. For `:update_all` / `:delete_all` the side effects are applied
  unless you pass `wrap_in_transaction: true`, which runs the statement
  inside a savepoint that is always rolled back (a savepoint rather than
  `BEGIN`, so it also composes with sandbox tests and caller
  transactions).

  Parameters go through the exact same encoding the adapter uses for
  production queries.

  ## Options

    * `:operation` — `:all` (default), `:update_all`, or `:delete_all`.
    * `:wrap_in_transaction` — roll the execution back afterwards
      (default `false`, matching `Ecto.Adapters.SQL`'s option of the
      same name for `Repo.explain/3`).
    * remaining options are forwarded to the pool checkout, most
      usefully `:timeout` (see `with_xqlite/3`).

  ## Examples

      {:ok, report} =
        XqliteEcto3.explain_analyze(MyApp.Repo, from(u in User, where: u.age > ^18))

      report.rows_produced
      report.scans
      report.wall_time_ns
  """
  @spec explain_analyze(module() | GenServer.server(), Ecto.Queryable.t(), keyword()) ::
          {:ok, Xqlite.ExplainAnalyze.t()} | Xqlite.error()
  def explain_analyze(repo, queryable, opts \\ []) do
    {operation, opts} = Keyword.pop(opts, :operation, :all)
    {wrap, opts} = Keyword.pop(opts, :wrap_in_transaction, false)

    {sql, params} = Ecto.Adapters.SQL.to_sql(operation, repo, queryable)
    encoded_params = DBConnection.Query.encode(%XqliteEcto3.Query{}, params, [])

    with_xqlite(repo, fn conn -> run_explain_analyze(conn, sql, encoded_params, wrap) end, opts)
  end

  defp run_explain_analyze(conn, sql, params, false) do
    Xqlite.explain_analyze(conn, sql, params)
  end

  defp run_explain_analyze(conn, sql, params, true) do
    savepoint = "xqlite_explain_analyze"

    with :ok <- Xqlite.savepoint(conn, savepoint) do
      result = Xqlite.explain_analyze(conn, sql, params)
      rollback_explain_savepoint(conn, savepoint, result)
    end
  end

  # A failed rollback MUST NOT masquerade as a successful analysis — the
  # rollback/release error wins over the report if either step fails.
  defp rollback_explain_savepoint(conn, savepoint, result) do
    with :ok <- Xqlite.rollback_to_savepoint(conn, savepoint),
         :ok <- Xqlite.release_savepoint(conn, savepoint) do
      result
    end
  end

  @impl Ecto.Adapter.Storage
  # File ops on the operator's own configured database path are this
  # callback's contract (mix ecto.create) — not request-data traversal.
  # sobelow_skip ["Traversal.FileModule"]
  def storage_up(opts) do
    database = Keyword.fetch!(opts, :database)

    if File.exists?(database) do
      {:error, :already_up}
    else
      database
      |> Path.dirname()
      |> File.mkdir_p!()

      {:ok, conn} = XqliteNIF.open(database)
      XqliteNIF.close(conn)
      :ok
    end
  end

  @impl Ecto.Adapter.Storage
  # Removes the configured database + sidecars (mix ecto.drop) — the
  # path is operator config, not request data.
  # sobelow_skip ["Traversal.FileModule"]
  def storage_down(opts) do
    database = Keyword.fetch!(opts, :database)

    case File.rm(database) do
      :ok ->
        File.rm(database <> "-wal")
        File.rm(database <> "-shm")
        :ok

      {:error, :enoent} ->
        {:error, :already_down}

      {:error, reason} ->
        {:error, reason}
    end
  end

  @impl Ecto.Adapter.Storage
  def storage_status(opts) do
    database = Keyword.fetch!(opts, :database)

    if File.exists?(database) do
      :up
    else
      :down
    end
  end

  @impl Ecto.Adapter.Structure
  # Writes the schema dump to the operator-configured dump path
  # (mix ecto.dump) — not request-data traversal.
  # sobelow_skip ["Traversal.FileModule"]
  def structure_dump(default, config) do
    database = Keyword.fetch!(config, :database)
    path = config[:dump_path] || Path.join(default, "structure.sql")

    case System.cmd("sqlite3", [database, ".dump"], stderr_to_stdout: true) do
      {dump, 0} ->
        File.mkdir_p!(Path.dirname(path))
        File.write!(path, dump)
        {:ok, path}

      {output, _code} ->
        {:error, output}
    end
  end

  @impl Ecto.Adapter.Structure
  # Reads the operator-configured dump path (mix ecto.load) — not
  # request-data traversal.
  # sobelow_skip ["Traversal.FileModule"]
  def structure_load(default, config) do
    database = Keyword.fetch!(config, :database)
    path = config[:dump_path] || Path.join(default, "structure.sql")

    case File.read(path) do
      {:ok, sql} ->
        {:ok, conn} = XqliteNIF.open(database)
        result = XqliteNIF.execute_batch(conn, sql)
        XqliteNIF.close(conn)

        case result do
          :ok -> {:ok, path}
          {:error, reason} -> {:error, inspect(reason)}
        end

      {:error, reason} ->
        {:error, "Could not read #{path}: #{inspect(reason)}"}
    end
  end

  @impl Ecto.Adapter.Structure
  def dump_cmd(_args, _opts, _config) do
    raise "dump_cmd is not supported — use structure_dump/2 instead"
  end

  @impl Ecto.Adapter.Migration
  def supports_ddl_transaction?, do: true

  @impl Ecto.Adapter.Migration
  def lock_for_migrations(_meta, _options, fun) do
    fun.()
  end

  # SQLite does not support `ADD COLUMN IF NOT EXISTS`, `DROP COLUMN IF EXISTS`,
  # or `ALTER TABLE ... MODIFY COLUMN`. Two escape hatches:
  #
  # 1. Conditional column changes (:add_if_not_exists, :remove_if_exists)
  #    get filtered via PRAGMA table_info and normalized to :add / :remove
  #    before falling through to the standard Ecto.Adapters.SQL flow.
  #
  # 2. Modify column changes (:modify) trigger the full SQLite 12-step
  #    table-rebuild dance when the repo is configured with
  #    `support_alter_via_table_rebuild: true`. Without that flag, :modify
  #    raises a clear error. The rebuild batches ALL changes in the alter
  #    block (:modify + :add + :remove + :rename + conditional variants)
  #    into a single new-table create + INSERT SELECT + drop + rename +
  #    index/trigger recreation cycle, not N rebuilds for N columns.
  @impl Ecto.Adapter.Migration
  def execute_ddl(meta, {:alter, %Ecto.Migration.Table{} = table, changes}, opts) do
    cond do
      Enum.any?(changes, &requires_rebuild?/1) ->
        rebuild_table(meta, table, changes, opts)

      Enum.any?(changes, &conditional_change?/1) ->
        existing = fetch_existing_columns!(meta, table, opts)

        case resolve_conditional_changes(changes, existing) do
          [] ->
            {:ok, []}

          resolved ->
            Ecto.Adapters.SQL.execute_ddl(
              meta,
              XqliteEcto3.Connection,
              {:alter, table, resolved},
              opts
            )
        end

      true ->
        Ecto.Adapters.SQL.execute_ddl(
          meta,
          XqliteEcto3.Connection,
          {:alter, table, changes},
          opts
        )
    end
  end

  def execute_ddl(meta, command, opts) do
    Ecto.Adapters.SQL.execute_ddl(meta, XqliteEcto3.Connection, command, opts)
  end

  defp conditional_change?({:add_if_not_exists, _, _, _}), do: true
  defp conditional_change?({:remove_if_exists, _, _}), do: true
  defp conditional_change?({:remove_if_exists, _}), do: true
  defp conditional_change?(_), do: false

  defp fetch_existing_columns!(meta, %Ecto.Migration.Table{name: name}, opts) do
    {:ok, %{rows: rows}} =
      Ecto.Adapters.SQL.query(
        meta,
        "SELECT name FROM pragma_table_info(?1)",
        [to_string(name)],
        opts
      )

    rows
    |> MapSet.new(fn [col_name] -> col_name end)
  end

  # Thread the live column set through the changes so two
  # `add_if_not_exists :foo` inside the same alter block resolve correctly:
  # the first emits `ADD COLUMN foo`, the second sees foo now present and
  # becomes a no-op. Same for mixed `add` then `remove_if_exists`, etc.
  defp resolve_conditional_changes(changes, initial_existing) do
    {resolved, _final_state} =
      Enum.flat_map_reduce(changes, initial_existing, fn change, current ->
        resolve_change(change, current)
      end)

    resolved
  end

  defp resolve_change({:add_if_not_exists, name, type, add_opts}, current) do
    key = to_string(name)

    if MapSet.member?(current, key) do
      {[], current}
    else
      {[{:add, name, type, add_opts}], MapSet.put(current, key)}
    end
  end

  defp resolve_change({:remove_if_exists, name, type}, current) do
    key = to_string(name)

    if MapSet.member?(current, key) do
      {[{:remove, name, type, []}], MapSet.delete(current, key)}
    else
      {[], current}
    end
  end

  defp resolve_change({:remove_if_exists, name}, current) do
    key = to_string(name)

    if MapSet.member?(current, key) do
      {[{:remove, name}], MapSet.delete(current, key)}
    else
      {[], current}
    end
  end

  defp resolve_change({:add, name, _type, _opts} = change, current) do
    {[change], MapSet.put(current, to_string(name))}
  end

  defp resolve_change({:remove, name, _type, _opts} = change, current) do
    {[change], MapSet.delete(current, to_string(name))}
  end

  defp resolve_change({:remove, name} = change, current) do
    {[change], MapSet.delete(current, to_string(name))}
  end

  defp resolve_change(change, current), do: {[change], current}

  # ---------------------------------------------------------------------------
  # Table-rebuild path (for ALTER ... MODIFY COLUMN support)
  # ---------------------------------------------------------------------------

  # Any change that SQLite's grammar can't do as a plain ALTER requires
  # rebuilding the whole table. Today that's :modify. Future: might expand
  # to :alter_primary_key / :alter_foreign_key if shared tests demand.
  defp requires_rebuild?({:modify, _name, _type, _opts}), do: true
  defp requires_rebuild?(_), do: false

  defp rebuild_enabled?(meta) do
    case meta do
      %{repo: repo} when is_atom(repo) ->
        repo.config()
        |> Keyword.get(:support_alter_via_table_rebuild, false)

      _ ->
        false
    end
  end

  # Replays DDL text read back from sqlite_schema.sql plus a PRAGMA with
  # a quote_name-quoted identifier — schema-sourced, not user input.
  # sobelow_skip ["SQL.Query"]
  defp rebuild_table(meta, table, changes, opts) do
    if !rebuild_enabled?(meta) do
      raise ArgumentError,
            "SQLite does not support ALTER TABLE ... MODIFY COLUMN. xqlite_ecto3 " <>
              "can implement it via a full table rebuild (create new, copy, drop, " <>
              "rename, recreate indexes/triggers) but requires the opt-in flag:\n\n" <>
              "    config :my_app, MyApp.Repo,\n" <>
              "      support_alter_via_table_rebuild: true\n\n" <>
              "Consider the cost on large tables: the rebuild acquires a write lock " <>
              "and rewrites every row."
    end

    refuse_unpreservable_constraints!(meta, table, opts)
    refuse_incoming_actions_on_populated!(meta, table, opts)

    existing_columns = fetch_full_column_info!(meta, table, opts)
    foreign_keys = fetch_foreign_keys!(meta, table, opts)
    unique_constraints = fetch_unique_constraints!(meta, table, opts)
    indexes = fetch_user_indexes!(meta, table, opts)
    triggers = fetch_table_triggers!(meta, table, opts)
    autoincrement = fetch_autoincrement_value!(meta, table, opts)

    {new_columns, copy_pairs, primary_key} =
      plan_new_schema(existing_columns, changes, autoincrement: not is_nil(autoincrement))

    table_constraints = primary_key ++ foreign_keys ++ unique_constraints

    statements =
      [
        "PRAGMA defer_foreign_keys = ON",
        create_rebuild_table_sql(table, new_columns, table_constraints),
        copy_rows_sql(table, copy_pairs),
        "DROP TABLE #{quote_name(table.name)}",
        "ALTER TABLE " <>
          quote_name(transient_name(table.name)) <> " RENAME TO " <> quote_name(table.name),
        restore_autoincrement_sql(table, autoincrement)
      ] ++
        Enum.map(indexes, & &1.sql) ++
        Enum.map(triggers, & &1.sql)

    statements
    |> List.flatten()
    |> Enum.reject(&is_nil/1)
    |> Enum.each(&Ecto.Adapters.SQL.query!(meta, &1, [], opts))

    # foreign_key_check returns rows if violations exist. It's a PRAGMA that
    # only produces rows on failure, so an empty result means clean.
    case Ecto.Adapters.SQL.query!(
           meta,
           "PRAGMA foreign_key_check(#{quote_name(table.name)})",
           [],
           opts
         ) do
      %{rows: []} ->
        {:ok, []}

      %{rows: violations} ->
        raise "table-rebuild for #{inspect(table.name)} left foreign-key violations: " <>
                inspect(violations) <>
                ". The rebuild ran under PRAGMA defer_foreign_keys = ON; check rows in " <>
                "dependent tables that reference this one."
    end
  end

  # Foreign keys and UNIQUE constraints are reconstructed from the structural
  # pragmas (foreign_key_list, index_list), so they survive the rebuild. The
  # rest — CHECK expressions, COLLATE clauses, generated columns, DEFERRABLE
  # foreign keys, and ON CONFLICT clauses — live only in the original CREATE
  # TABLE text or carry detail the structural pragmas do not expose, so a
  # rebuild would silently drop them. Refuse loudly instead. Detection
  # over-approximates (a scan of the stored CREATE TABLE SQL, plus a table_xinfo
  # check for generated columns), so the only failure mode is a safe refusal,
  # never a silent drop. Separate CREATE INDEX statements are untouched by this
  # and are re-created by the rebuild.
  defp refuse_unpreservable_constraints!(meta, table, opts) do
    case unpreservable_kind(meta, table, opts) do
      nil ->
        :ok

      kind ->
        raise ArgumentError,
              "cannot rebuild #{inspect(table.name)} for ALTER ... MODIFY: the table declares " <>
                "#{kind} that a table rebuild cannot preserve, so rebuilding would silently " <>
                "drop them. Perform this change by hand with execute/1, recreating the full " <>
                "table — columns, constraints, indexes, and triggers — so nothing is lost."
    end
  end

  # A rebuild drops the old table before renaming its replacement into place.
  # With foreign keys enforced — the default, and unavoidable inside a migration
  # transaction where `PRAGMA foreign_keys=OFF` is a no-op — that drop's implicit
  # DELETE fires the ON DELETE action of every OTHER table that references this
  # one: CASCADE would silently delete their rows, SET NULL / SET DEFAULT would
  # silently mutate them (`defer_foreign_keys` defers the enforcement check, not
  # the action). So if any such referencing table currently holds rows, refuse
  # loudly before any destructive step. RESTRICT / NO ACTION references need no
  # guard here — SQLite makes the drop fail loudly on them by its own rules.
  # Self-references are excluded: the rebuild repoints them at the transient
  # table, so the drop cannot reach the freshly-copied rows.
  defp refuse_incoming_actions_on_populated!(meta, table, opts) do
    table_name = to_string(table.name)

    populated =
      meta
      |> fetch_incoming_action_fks(table_name, opts)
      |> Enum.uniq()
      |> Enum.filter(fn {ref_table, _action} -> table_has_rows?(meta, ref_table, opts) end)

    case populated do
      [] -> :ok
      hits -> raise ArgumentError, incoming_actions_message(table_name, hits)
    end
  end

  # Every other table whose foreign_key_list targets this one with a row-affecting
  # ON DELETE action. The correlated table-valued pragma reads each candidate
  # table's foreign keys; `"table"` is the referenced table (matched
  # case-insensitively, as SQLite table names are), and excluding the rebuilt
  # table itself drops self-references.
  defp fetch_incoming_action_fks(meta, table_name, opts) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        meta,
        ~s|SELECT m.name, fk."on_delete" | <>
          ~s|FROM sqlite_schema AS m, pragma_foreign_key_list(m.name) AS fk | <>
          ~s|WHERE m.type = 'table' AND lower(fk."table") = lower(?1) | <>
          ~s|AND lower(m.name) <> lower(?1) | <>
          ~s|AND fk."on_delete" IN ('CASCADE', 'SET NULL', 'SET DEFAULT')|,
        [table_name],
        opts
      )

    Enum.map(rows, fn [ref_table, on_delete] -> {ref_table, on_delete} end)
  end

  # sobelow_skip ["SQL.Query"]
  defp table_has_rows?(meta, ref_table, opts) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        meta,
        "SELECT 1 FROM #{quote_name(ref_table)} LIMIT 1",
        [],
        opts
      )

    rows != []
  end

  defp incoming_actions_message(table_name, hits) do
    refs =
      Enum.map_join(hits, ", ", fn {ref, action} -> "#{inspect(ref)} (ON DELETE #{action})" end)

    "cannot rebuild #{inspect(table_name)} for ALTER ... MODIFY: dropping the old table as " <>
      "part of the rebuild would fire ON DELETE actions on rows in the table(s) that reference " <>
      "it — #{refs} — silently deleting (CASCADE) or mutating (SET NULL / SET DEFAULT) them. " <>
      "Empty or drop those referencing rows first, or perform this change by hand with execute/1."
  end

  # Generated columns are not in the CREATE TABLE keyword set the scan below
  # catches (the `col TYPE AS (expr)` shorthand carries no distinctive keyword),
  # so detect them from table_xinfo, where they are hidden = 2 (virtual) or 3
  # (stored). A rebuild would drop a virtual one and freeze a stored one into a
  # plain column.
  defp unpreservable_kind(meta, table, opts) do
    if has_generated_columns?(meta, table, opts) do
      "generated columns"
    else
      scan_create_sql_for_unpreservable(meta, table, opts)
    end
  end

  defp has_generated_columns?(meta, table, opts) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        meta,
        "SELECT 1 FROM pragma_table_xinfo(?1) WHERE hidden IN (2, 3) LIMIT 1",
        [to_string(table.name)],
        opts
      )

    rows != []
  end

  defp scan_create_sql_for_unpreservable(meta, table, opts) do
    result =
      Ecto.Adapters.SQL.query!(
        meta,
        "SELECT sql FROM sqlite_schema WHERE type = 'table' AND name = ?1",
        [to_string(table.name)],
        opts
      )

    case result do
      %{rows: [[create_sql]]} when is_binary(create_sql) -> unpreservable_constraint(create_sql)
      _ -> nil
    end
  end

  # REFERENCES and UNIQUE are preserved structurally, so they are not scanned
  # for here. DEFERRABLE and ON CONFLICT ride on those constructs but carry
  # detail the pragmas do not expose (deferred enforcement timing, a conflict
  # resolution algorithm), so they must still refuse.
  defp unpreservable_constraint(create_sql) do
    cond do
      Regex.match?(~r/\bCHECK\b/i, create_sql) -> "CHECK constraints"
      Regex.match?(~r/\bCOLLATE\b/i, create_sql) -> "COLLATE clauses"
      Regex.match?(~r/\bDEFERRABLE\b/i, create_sql) -> "DEFERRABLE foreign keys"
      Regex.match?(~r/\bON\s+CONFLICT\b/i, create_sql) -> "ON CONFLICT clauses"
      true -> unpreservable_table_option(create_sql)
    end
  end

  # WITHOUT ROWID and STRICT are table options that live in the tail after the
  # final `)` closing the column/constraint list. Table options carry no
  # parentheses, so the last `)` is an unambiguous boundary — a column merely
  # named `rowid` or `strict` sits inside the list and never reaches the tail,
  # avoiding a false positive. Neither option is exposed by the structural
  # pragmas, so a rebuild would silently drop it (converting a WITHOUT ROWID
  # table to a rowid table, or dropping strict type-checking); refuse instead.
  defp unpreservable_table_option(create_sql) do
    tail = create_sql |> String.split(")") |> List.last() || ""

    cond do
      Regex.match?(~r/\bWITHOUT\s+ROWID\b/i, tail) -> "WITHOUT ROWID storage"
      Regex.match?(~r/\bSTRICT\b/i, tail) -> "STRICT typing"
      true -> nil
    end
  end

  defp fetch_full_column_info!(meta, %Ecto.Migration.Table{name: name}, opts) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        meta,
        "SELECT name, type, \"notnull\", dflt_value, pk FROM pragma_table_xinfo(?1) " <>
          "WHERE hidden NOT IN (1, 2)",
        [to_string(name)],
        opts
      )

    Enum.map(rows, fn [col_name, col_type, notnull, dflt, pk] ->
      %{name: col_name, type: col_type, notnull: notnull == 1, default: dflt, pk: pk}
    end)
  end

  # Reconstruct the table's foreign keys as table-level clauses. Rows from
  # foreign_key_list carry one entry per key column; group them by `id`
  # (composite keys share an id, one row per column) and order by `seq` to
  # recover column order.
  defp fetch_foreign_keys!(meta, %Ecto.Migration.Table{name: name}, opts) do
    table_name = to_string(name)

    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        meta,
        ~s(SELECT id, seq, "table", "from", "to", on_update, on_delete, "match" ) <>
          "FROM pragma_foreign_key_list(?1) ORDER BY id, seq",
        [table_name],
        opts
      )

    rows
    |> Enum.group_by(fn [id | _] -> id end)
    |> Enum.sort_by(fn {id, _group} -> id end)
    |> Enum.map(fn {_id, group} -> foreign_key_clause(group, table_name) end)
  end

  defp foreign_key_clause(group, table_name) do
    sorted = Enum.sort_by(group, fn [_id, seq | _] -> seq end)
    [_id, _seq, target, _from, _to, on_update, on_delete, match] = hd(sorted)
    from_cols = Enum.map(sorted, fn [_id, _seq, _table, from | _] -> from end)
    to_cols = Enum.map(sorted, fn [_id, _seq, _table, _from, to | _] -> to end)

    [
      "FOREIGN KEY (",
      quoted_column_list(from_cols),
      ") REFERENCES ",
      quote_name(fk_target(target, table_name)),
      references_column_list(to_cols),
      fk_action_clause(" ON DELETE ", on_delete),
      fk_action_clause(" ON UPDATE ", on_update),
      fk_match_clause(match)
    ]
  end

  # A self-reference must point at the transient rebuild table, so that dropping
  # the original cannot cascade (or restrict) into the freshly-copied rows;
  # ALTER TABLE ... RENAME then rewrites this target back to the final name.
  defp fk_target(target, table_name) when target == table_name, do: transient_name(table_name)

  defp fk_target(target, _table_name), do: target

  # A NULL `to` means the key references the target's implicit primary key —
  # emit `REFERENCES target` with no column list so SQLite resolves it there.
  defp references_column_list(to_cols) do
    if Enum.any?(to_cols, &is_nil/1) do
      []
    else
      [" (", quoted_column_list(to_cols), ")"]
    end
  end

  # NO ACTION is SQLite's default; omit it rather than emit a redundant clause.
  defp fk_action_clause(_keyword, "NO ACTION"), do: []
  defp fk_action_clause(keyword, action), do: [keyword, action]

  # SQLite parses but ignores MATCH and reports NONE for every declared type;
  # keep a non-default value verbatim on the off chance one surfaces.
  defp fk_match_clause("NONE"), do: []
  defp fk_match_clause(match), do: [" MATCH ", match]

  # index_list rows with origin `u` are the auto-indexes backing table/column
  # UNIQUE constraints; reconstruct each as a table-level `UNIQUE (cols)` clause.
  # origin `pk` (primary key) is already carried by the column info, and origin
  # `c` (standalone CREATE INDEX) is re-created separately.
  defp fetch_unique_constraints!(meta, %Ecto.Migration.Table{name: name}, opts) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        meta,
        "SELECT name FROM pragma_index_list(?1) WHERE origin = 'u' ORDER BY seq",
        [to_string(name)],
        opts
      )

    Enum.map(rows, fn [index_name] -> unique_constraint_clause(meta, index_name, opts) end)
  end

  defp unique_constraint_clause(meta, index_name, opts) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        meta,
        "SELECT name FROM pragma_index_info(?1) ORDER BY seqno",
        [index_name],
        opts
      )

    cols = Enum.map(rows, fn [col_name] -> col_name end)
    ["UNIQUE (", quoted_column_list(cols), ")"]
  end

  defp quoted_column_list(cols) do
    cols
    |> Enum.map(&quote_name/1)
    |> Enum.intersperse(", ")
  end

  defp fetch_user_indexes!(meta, %Ecto.Migration.Table{name: name}, opts) do
    # User-created indexes have non-nil `sql`; auto-created ones (from UNIQUE
    # constraints etc.) have NULL sql and will be recreated automatically when
    # the new table is created with the same constraints.
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        meta,
        "SELECT name, sql FROM sqlite_schema WHERE type = 'index' AND tbl_name = ?1 " <>
          "AND sql IS NOT NULL",
        [to_string(name)],
        opts
      )

    Enum.map(rows, fn [idx_name, sql] -> %{name: idx_name, sql: sql} end)
  end

  defp fetch_table_triggers!(meta, %Ecto.Migration.Table{name: name}, opts) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        meta,
        "SELECT name, sql FROM sqlite_schema WHERE type = 'trigger' AND tbl_name = ?1 " <>
          "AND sql IS NOT NULL",
        [to_string(name)],
        opts
      )

    Enum.map(rows, fn [trg_name, sql] -> %{name: trg_name, sql: sql} end)
  end

  defp fetch_autoincrement_value!(meta, %Ecto.Migration.Table{name: name}, opts) do
    # sqlite_sequence table exists only if any AUTOINCREMENT column in the DB.
    case Ecto.Adapters.SQL.query(
           meta,
           "SELECT seq FROM sqlite_sequence WHERE name = ?1",
           [to_string(name)],
           opts
         ) do
      {:ok, %{rows: [[seq]]}} -> seq
      _ -> nil
    end
  end

  # Walk the changes list, producing (a) the new column list for the rebuilt
  # table in declared order and (b) the pairs of (old_name -> new_name) to
  # copy via INSERT SELECT. Columns added fresh have no matching old column
  # and are omitted from the copy.
  defp plan_new_schema(existing, changes, opts) do
    autoincrement? = Keyword.fetch!(opts, :autoincrement)

    # Primary-key columns in declared order (table_xinfo `pk` is the 1-based
    # position within the key, 0 otherwise). A single-column key stays inline on
    # its column; a composite key is emitted as a table-level clause below.
    pk_columns =
      existing
      |> Enum.filter(&(&1.pk > 0))
      |> Enum.sort_by(& &1.pk)
      |> Enum.map(& &1.name)

    composite_pk? = length(pk_columns) > 1
    base = Enum.map(existing, &existing_to_column(&1, autoincrement?, composite_pk?))

    # Apply changes in order. Result is a list of %{name, source_name, spec}
    # where source_name is the old column to copy FROM (nil for added cols),
    # and spec is the CREATE TABLE column definition iodata.
    final =
      Enum.reduce(changes, base, fn change, cols ->
        apply_change(cols, change)
      end)

    copy_pairs =
      for %{name: name, source_name: src} <- final, not is_nil(src), do: {src, name}

    {final, copy_pairs, composite_pk_clause(composite_pk?, pk_columns, final)}
  end

  # A single-column PK is carried inline by `existing_to_column` (preserving the
  # INTEGER PRIMARY KEY rowid alias and AUTOINCREMENT). A composite PK cannot be
  # expressed inline, so reconstruct it as a table-level clause over the
  # surviving PK columns in declared order — never dropping members down to a
  # single narrower key.
  defp composite_pk_clause(false, _pk_columns, _final), do: []

  defp composite_pk_clause(true, pk_columns, final) do
    case Enum.filter(pk_columns, fn name -> Enum.any?(final, &(&1.name == name)) end) do
      [] -> []
      cols -> [["PRIMARY KEY (", quoted_column_list(cols), ")"]]
    end
  end

  defp existing_to_column(
         %{name: name, type: type, notnull: notnull, default: dflt, pk: pk},
         autoincrement?,
         composite_pk?
       ) do
    pk_clause =
      cond do
        composite_pk? -> ""
        pk == 1 and autoincrement? -> " PRIMARY KEY AUTOINCREMENT"
        pk == 1 -> " PRIMARY KEY"
        true -> ""
      end

    spec = [
      quote_name(name),
      " ",
      if(type in [nil, ""], do: "BLOB", else: type),
      if(notnull, do: " NOT NULL", else: ""),
      default_clause(dflt),
      pk_clause
    ]

    %{name: name, source_name: name, spec: spec}
  end

  defp default_clause(nil), do: ""
  defp default_clause(value), do: [" DEFAULT ", to_string(value)]

  defp apply_change(cols, {:add, name, type, opts}) do
    cols ++ [%{name: to_string(name), source_name: nil, spec: add_spec(name, type, opts)}]
  end

  defp apply_change(cols, {:add_if_not_exists, name, type, opts}) do
    if Enum.any?(cols, &(&1.name == to_string(name))) do
      cols
    else
      apply_change(cols, {:add, name, type, opts})
    end
  end

  defp apply_change(cols, {:remove, name, _type, _opts}), do: apply_change(cols, {:remove, name})

  defp apply_change(cols, {:remove, name}) do
    Enum.reject(cols, &(&1.name == to_string(name)))
  end

  defp apply_change(cols, {:remove_if_exists, name, _type}),
    do: apply_change(cols, {:remove_if_exists, name})

  defp apply_change(cols, {:remove_if_exists, name}) do
    Enum.reject(cols, &(&1.name == to_string(name)))
  end

  defp apply_change(cols, {:modify, name, type, opts}) do
    name_s = to_string(name)

    Enum.map(cols, fn col ->
      if col.name == name_s do
        %{col | spec: add_spec(name, type, opts)}
      else
        col
      end
    end)
  end

  defp apply_change(cols, _other), do: cols

  defp add_spec(name, type, opts) do
    type_sql = XqliteEcto3.DataType.column_type(type, opts)

    [
      quote_name(name),
      " ",
      type_sql,
      if(Keyword.get(opts, :null) == false, do: " NOT NULL", else: ""),
      default_spec(Keyword.fetch(opts, :default)),
      if(Keyword.get(opts, :primary_key, false), do: " PRIMARY KEY", else: "")
    ]
  end

  defp default_spec({:ok, nil}), do: " DEFAULT NULL"
  defp default_spec({:ok, v}) when is_integer(v) or is_float(v), do: [" DEFAULT ", to_string(v)]
  defp default_spec({:ok, v}) when is_binary(v), do: [" DEFAULT '", v, "'"]
  defp default_spec({:ok, true}), do: " DEFAULT 1"
  defp default_spec({:ok, false}), do: " DEFAULT 0"
  defp default_spec({:ok, {:fragment, frag}}), do: [" DEFAULT ", frag]
  defp default_spec(:error), do: ""

  defp create_rebuild_table_sql(table, cols, table_constraints) do
    definitions =
      cols
      |> Enum.map(& &1.spec)
      |> Kernel.++(table_constraints)
      |> Enum.intersperse(", ")

    IO.iodata_to_binary([
      "CREATE TABLE ",
      quote_name(transient_name(table.name)),
      " (",
      definitions,
      ")"
    ])
  end

  defp copy_rows_sql(table, copy_pairs) do
    if copy_pairs != [] do
      {old_cols, new_cols} = Enum.unzip(copy_pairs)

      new_list = Enum.map_join(new_cols, ", ", &quote_name/1)
      old_list = Enum.map_join(old_cols, ", ", &quote_name/1)

      "INSERT INTO " <>
        quote_name(transient_name(table.name)) <>
        " (#{new_list}) SELECT #{old_list} FROM " <> quote_name(table.name)
    end
  end

  # sqlite_sequence has no unique constraint on `name`. ALTER TABLE ... RENAME
  # TO inserts its own row for the renamed table (seq=0 because the new-table
  # is empty), so we have to delete first and then re-insert the preserved value.
  defp restore_autoincrement_sql(_table, nil), do: []

  defp restore_autoincrement_sql(table, seq) do
    name_literal = quote_string(table.name)

    [
      "DELETE FROM sqlite_sequence WHERE name = " <> name_literal,
      "INSERT INTO sqlite_sequence (name, seq) VALUES (" <> name_literal <> ", #{seq})"
    ]
  end

  # The transient table the rebuild creates, copies into, and renames over the
  # original.
  defp transient_name(name), do: "#{name}__xqlite_new"

  defp quote_name(name) when is_atom(name), do: quote_name(Atom.to_string(name))

  # SQLite escapes a `"` inside a quoted identifier by doubling it.
  defp quote_name(name) when is_binary(name),
    do: ~s|"| <> String.replace(name, ~s|"|, ~s|""|) <> ~s|"|

  # Escapes a value for a single-quoted SQL string literal (doubles embedded
  # single quotes). Used for the sqlite_sequence `name`, which is a string
  # literal with no identifier-quoting escape hatch.
  defp quote_string(value), do: ~s|'| <> String.replace(to_string(value), ~s|'|, ~s|''|) <> ~s|'|

  @impl Ecto.Adapter.Schema
  def autogenerate(:id), do: nil
  def autogenerate(:embed_id), do: Ecto.UUID.generate()
  def autogenerate(:binary_id), do: Ecto.UUID.generate()

  @impl Ecto.Adapter
  def loaders(:boolean, type), do: [&bool_decode/1, type]
  def loaders(:naive_datetime, type), do: [&naive_datetime_decode/1, type]
  def loaders(:naive_datetime_usec, type), do: [&naive_datetime_decode/1, type]
  def loaders(:utc_datetime, type), do: [&utc_datetime_decode/1, type]
  def loaders(:utc_datetime_usec, type), do: [&utc_datetime_decode/1, type]
  def loaders(:date, type), do: [&date_decode/1, type]
  def loaders(:time, type), do: [&time_decode/1, type]
  def loaders(:time_usec, type), do: [&time_decode/1, type]
  def loaders(:decimal, type), do: [&decimal_decode/1, type]
  def loaders(:uuid, type), do: [&uuid_string_load/1, type]
  def loaders(:map, type), do: [&json_decode/1, type]
  def loaders({:map, _}, type), do: [&json_decode/1, type]
  def loaders({:array, _}, type), do: [&json_decode/1, type]
  def loaders(_, type), do: [type]

  @impl Ecto.Adapter
  def dumpers(:boolean, type), do: [type, &bool_encode/1]
  def dumpers(:uuid, _type), do: [&uuid_string_dump/1]
  def dumpers(:binary_id, type), do: [type, &binary_id_dump/1]
  def dumpers(_, type), do: [type]

  defp bool_decode(0), do: {:ok, false}
  defp bool_decode(1), do: {:ok, true}
  defp bool_decode(nil), do: {:ok, nil}

  defp bool_decode(x) do
    {:error, %{reason: :invalid_boolean_value, value: x, expected: [0, 1, nil]}}
  end

  defp bool_encode(false), do: {:ok, 0}
  defp bool_encode(true), do: {:ok, 1}
  defp bool_encode(x), do: {:ok, x}

  # :binary_id storage mode, read from `config :xqlite_ecto3,
  # :binary_id_storage`. Defaults to :string. Governs how the :binary_id
  # dumper shapes its output, how the loader interprets rows, how the
  # migration column type maps, and how query-param Tagged values are
  # wrapped in CAST.
  #
  # Per-field overrides are available via `XqliteEcto3.Types.UUID` when
  # different fields in the same schema need different modes.
  defp binary_id_storage do
    Application.get_env(:xqlite_ecto3, :binary_id_storage, :string)
  end

  # :binary_id dumper runs AFTER Ecto.UUID.dump in the chain. Input is
  # the raw 16-byte binary (from Ecto.UUID.dump) or an already-raw value
  # that was passed through. Shape the output to match configured storage.
  #
  # CRITICAL: every arm returns `{:ok, value}`, never `:error`. Ecto's
  # process_dumpers halts the whole insert/update on `:error`; we can
  # occasionally receive values that aren't the expected UUID shape
  # (e.g. when the same dumper chain is walked for values that weren't
  # really UUIDs), and aborting the insert is the wrong response.
  defp binary_id_dump(nil), do: {:ok, nil}

  defp binary_id_dump(<<_::128>> = raw) do
    case binary_id_storage() do
      :string ->
        # Convert raw to 36-char string so NIF binds as TEXT.
        Ecto.UUID.cast(raw)

      :binary ->
        # Keep raw for BLOB binding.
        {:ok, raw}
    end
  end

  defp binary_id_dump(value), do: {:ok, value}

  # SQLite stores UUIDs as TEXT. Ecto.UUID.dump/1 produces raw 16-byte binary,
  # but the xqlite NIF can't bind raw bytes as text without a utf-8 error.
  # Keep the string representation so it binds as TEXT.
  defp uuid_string_dump(nil), do: {:ok, nil}

  defp uuid_string_dump(<<_::128>> = raw) do
    Ecto.UUID.cast(raw)
  end

  defp uuid_string_dump(value) when is_binary(value), do: {:ok, value}
  defp uuid_string_dump(value), do: {:ok, value}

  # SQLite stores UUIDs as TEXT strings. Ecto.UUID.load/1 expects raw
  # 16-byte binary and raises on strings. Convert string UUIDs to the raw
  # form before the type's load/1 runs.
  defp uuid_string_load(nil), do: {:ok, nil}

  defp uuid_string_load(val) when is_binary(val) and byte_size(val) != 16 do
    Ecto.UUID.dump(val)
  end

  defp uuid_string_load(val), do: {:ok, val}

  defp naive_datetime_decode(val) when is_binary(val) do
    case NaiveDateTime.from_iso8601(val) do
      {:ok, dt} -> {:ok, dt}
      _ -> {:ok, val}
    end
  end

  defp naive_datetime_decode(val), do: {:ok, val}

  defp utc_datetime_decode(val) when is_binary(val) do
    case DateTime.from_iso8601(val) do
      {:ok, dt, _offset} -> {:ok, dt}
      _ -> {:ok, val}
    end
  end

  defp utc_datetime_decode(val), do: {:ok, val}

  defp date_decode(val) when is_binary(val) do
    case Date.from_iso8601(val) do
      {:ok, d} -> {:ok, d}
      _ -> {:ok, val}
    end
  end

  defp date_decode(val), do: {:ok, val}

  defp time_decode(val) when is_binary(val) do
    case Time.from_iso8601(val) do
      {:ok, t} -> {:ok, t}
      _ -> {:ok, val}
    end
  end

  defp time_decode(val), do: {:ok, val}

  defp decimal_decode(val) when is_binary(val), do: {:ok, Decimal.new(val)}
  defp decimal_decode(val) when is_integer(val), do: {:ok, Decimal.new(val)}
  defp decimal_decode(val) when is_float(val), do: {:ok, Decimal.from_float(val)}
  defp decimal_decode(nil), do: {:ok, nil}
  defp decimal_decode(%Decimal{} = val), do: {:ok, val}

  defp json_decode(val) when is_binary(val) do
    case Jason.decode(val) do
      {:ok, decoded} -> {:ok, decoded}
      _ -> {:ok, val}
    end
  end

  defp json_decode(val), do: {:ok, val}
end
