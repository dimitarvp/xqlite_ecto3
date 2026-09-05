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
  a `NO ACTION`/`RESTRICT` reference does not stop the rebuild — the dance defers
  foreign-key checks, and the rebuilt table satisfies them at the end. See
  `XqliteEcto3.Migration` and the README for details.

  ## UUID / binary_id storage

  Set `config :xqlite_ecto3, :binary_id_storage, :string | :binary` and
  use the standard Ecto field type:

      @primary_key {:id, :binary_id, autogenerate: true}

  `:string` (default) stores the 36-character UUID form in a TEXT column.
  `:binary` stores the raw 16 bytes in a BLOB column — 55% smaller per
  row, worth it at large scale. The config governs the dumper, the
  loader, and the migration column type uniformly; the Elixir-side
  representation is always the 36-character string either way, and a
  `:binary_id` value that is not UUID-shaped passes through as-is.

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

  Because it always starts its own checkout, never call it from inside
  `Repo.transaction/2`, `Repo.checkout/2`, or another `with_xqlite/3` —
  the caller already holds a connection, and this second checkout
  queues behind the pool. At `pool_size: 1` that deadlocks into a
  queue-timeout raise (inside `Repo.transaction/2` on a plain pool the
  enclosing transaction is rolled back); at larger sizes the callback
  silently runs on a DIFFERENT pooled connection than the caller's, so
  anything connection-scoped it installs or reads targets the wrong
  connection. The same applies to `txn_state/2` and
  `connection_stats/1`, which route through here. Under
  `Ecto.Adapters.SQL.Sandbox` ownership a BARE call (no enclosing
  transaction or checkout) reuses the caller's sandboxed connection;
  nested calls hit the same wall as on a plain pool.

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

  ## Connection-scoped state persists after the callback

  Anything you install on the handle outlives `fun` for the life of
  that pooled connection: busy policies and busy observers, the
  authorizer, hooks, loaded extensions, session `PRAGMA`s — and a
  session-extension recorder, which keeps recording every later write
  the pool runs through that connection, so a changeset read after
  check-in contains other callers' traffic. Later checkouts of the
  same connection see all of it, and nothing repairs it.

  The busy slot deserves its own warning. SQLite has ONE busy slot per
  connection: `Xqlite.register_busy_observer/2` (and
  `Xqlite.set_busy_policy/2`) replaces the plain `busy_timeout` the
  adapter configured, and with no retry policy installed the connection
  stops waiting on contention entirely — writes that used to wait out
  `busy_timeout` fail immediately with `:database_busy_or_locked`.
  Unregistering the observer empties the slot without restoring the
  timeout. To get the configured behavior back, call
  `Xqlite.busy_timeout/2` with the repo's configured value before the
  callback returns.

  One connection left in that state does more damage than its share of
  the pool suggests. Failing immediately instead of waiting is the
  fastest way to finish a statement, so that connection is idle — and
  therefore first in line — far more often than the ones that wait out
  their busy timeout. Measured: a single such connection in a pool of
  eight absorbed and failed 41 of 48 contended writes, and poisoning
  more of the pool barely moves that number — one is enough.

  Extension loading needs the same care.
  `Xqlite.enable_load_extension(conn, true)` does not only unlock the
  C-API load you are about to do: it also makes the SQL function
  `load_extension()` callable on that connection, for the rest of that
  connection's life. Any later query on it — including one built from
  user input — can then load a shared library from disk. Call
  `Xqlite.enable_load_extension(conn, false)` before the callback
  returns.

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
  def structure_dump(default, config) do
    database = Keyword.fetch!(config, :database)
    path = config[:dump_path] || Path.join(default, "structure.sql")

    with :ok <- create_dump_dir(path),
         :ok <- ensure_sqlite3_executable(),
         {:ok, dump} <- run_sqlite3_dump(database),
         :ok <- write_dump(path, dump) do
      {:ok, path}
    end
  end

  # Creates the operator-configured dump directory (mix ecto.dump) — not
  # request-data traversal.
  # sobelow_skip ["Traversal.FileModule"]
  defp create_dump_dir(path) do
    case File.mkdir_p(Path.dirname(path)) do
      :ok -> :ok
      {:error, reason} -> {:error, {:cannot_write_dump, path, reason}}
    end
  end

  defp ensure_sqlite3_executable do
    case System.find_executable("sqlite3") do
      nil -> {:error, {:missing_executable, "sqlite3"}}
      _path -> :ok
    end
  end

  defp run_sqlite3_dump(database) do
    case System.cmd("sqlite3", [database, ".dump"], stderr_to_stdout: true) do
      {dump, 0} -> {:ok, dump}
      {output, _code} -> {:error, output}
    end
  end

  # Writes the operator-configured dump path (mix ecto.dump) — not
  # request-data traversal.
  # sobelow_skip ["Traversal.FileModule"]
  defp write_dump(path, dump) do
    case File.write(path, dump) do
      :ok -> :ok
      {:error, reason} -> {:error, {:cannot_write_dump, path, reason}}
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
  # or `ALTER TABLE ... MODIFY COLUMN`, so both are emulated: the conditional
  # forms resolve against PRAGMA table_info into plain :add / :remove, and
  # :modify triggers the table-rebuild dance below. One rebuild batches every
  # change in the alter block, not one rebuild per column.
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

  # SQLite resolves a column name with ASCII case folding, so
  # `remove_if_exists :firstname` has to find a stored "firstName" — the
  # rebuild path already resolves it that way. The folded name is the key and
  # the stored spelling is the value, so the DDL this path emits names the
  # column exactly as the table stores it.
  defp fetch_existing_columns!(meta, %Ecto.Migration.Table{name: name}, opts) do
    {:ok, %{rows: rows}} =
      Ecto.Adapters.SQL.query(
        meta,
        "SELECT name FROM pragma_table_info(?1)",
        [to_string(name)],
        opts
      )

    Map.new(rows, fn [col_name] -> {folded(col_name), col_name} end)
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
    key = folded(name)

    if Map.has_key?(current, key) do
      {[], current}
    else
      {[{:add, name, type, add_opts}], Map.put(current, key, to_string(name))}
    end
  end

  defp resolve_change({:remove_if_exists, name, type}, current) do
    key = folded(name)

    case Map.fetch(current, key) do
      {:ok, stored} -> {[{:remove, stored, type, []}], Map.delete(current, key)}
      :error -> {[], current}
    end
  end

  defp resolve_change({:remove_if_exists, name}, current) do
    key = folded(name)

    case Map.fetch(current, key) do
      {:ok, stored} -> {[{:remove, stored}], Map.delete(current, key)}
      :error -> {[], current}
    end
  end

  defp resolve_change({:add, name, _type, _opts} = change, current) do
    {[change], Map.put(current, folded(name), to_string(name))}
  end

  defp resolve_change({:remove, name, _type, _opts} = change, current) do
    {[change], Map.delete(current, folded(name))}
  end

  defp resolve_change({:remove, name} = change, current) do
    {[change], Map.delete(current, folded(name))}
  end

  defp resolve_change(change, current), do: {[change], current}

  # Any change that SQLite's grammar can't do as a plain ALTER requires
  # rebuilding the whole table.
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

    table = resolve_stored_table_name!(meta, table, opts)

    storage = fetch_table_storage!(meta, table, opts)

    refuse_reference_changes!(table, changes)
    refuse_virtual_table!(table, storage)
    refuse_unpreservable_constraints!(meta, table, storage, opts)
    refuse_incoming_actions_on_populated!(meta, table, opts)
    refuse_dependent_schema_objects!(meta, table, opts)

    existing_columns = fetch_full_column_info!(meta, table, opts)
    refuse_removed_primary_key!(table, existing_columns, changes)
    refuse_key_grant_beside_kept_key!(table, existing_columns, changes)
    refuse_affinity_rewrites_on_populated!(meta, table, existing_columns, changes, storage, opts)

    triggers = fetch_table_triggers!(meta, table, opts)
    refuse_triggers_reading_removed_columns!(table, existing_columns, triggers, changes)

    before_structure = snapshot_structure!(meta, table, opts)
    foreign_keys = fetch_foreign_keys!(meta, table, opts)
    unique_constraints = fetch_unique_constraints!(meta, table, opts)
    indexes = fetch_user_indexes!(meta, table, opts)

    refuse_stranded_constraints!(
      table,
      existing_columns,
      changes,
      unique_constraints ++ foreign_keys ++ indexes
    )

    key_sort_order = fetch_primary_key_sort_order!(meta, table, opts)
    autoincrement? = fetch_autoincrement_flag!(meta, table, opts)
    sequence_value = fetch_autoincrement_value!(meta, table, opts)

    {new_columns, copy_pairs, primary_key} =
      plan_new_schema(existing_columns, changes,
        autoincrement: autoincrement?,
        key_sort_order: key_sort_order
      )

    copy_rowid? = rowid_copy_needed?(existing_columns, changes, key_sort_order)

    table_constraints =
      primary_key ++
        Enum.map(foreign_keys, & &1.clause) ++ Enum.map(unique_constraints, & &1.clause)

    statements =
      [
        "PRAGMA defer_foreign_keys = ON",
        create_rebuild_table_sql(table, new_columns, table_constraints),
        copy_rows_sql(table, copy_pairs, copy_rowid?),
        "DROP TABLE #{quote_name(table.name)}",
        "ALTER TABLE " <>
          quote_name(transient_name(table.name)) <> " RENAME TO " <> quote_name(table.name),
        restore_autoincrement_sql(table, sequence_value)
      ] ++
        Enum.map(indexes, & &1.sql) ++
        Enum.map(triggers, & &1.sql)

    # The dance is only safe under a transaction: it drops and recreates the
    # table in several statements. A normal migration's DDL transaction,
    # Repo.transaction, or the SQL Sandbox already provide one; when none is
    # open (@disable_ddl_transaction, a raw Ecto.Migration.Runner drive),
    # open one for the dance and roll it back on any mid-dance failure. Raw
    # BEGIN/COMMIT via query is safe here: the driver re-reads SQLite's real
    # transaction state after every transaction-control statement that runs as
    # ordinary SQL, so its bookkeeping follows this dance instead of drifting.
    self_wrap? = not in_wrapping_transaction?(meta, opts)

    on_one_connection(meta, self_wrap?, opts, fn ->
      %{rows: [[prior_defer]]} =
        Ecto.Adapters.SQL.query!(meta, "PRAGMA defer_foreign_keys", [], opts)

      if self_wrap? do
        Ecto.Adapters.SQL.query!(meta, "BEGIN IMMEDIATE", [], opts)
      end

      try do
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
            verify_structure!(meta, table, before_structure, changes, opts)

            if self_wrap? do
              Ecto.Adapters.SQL.query!(meta, "COMMIT", [], opts)
            end

            {:ok, []}

          %{rows: violations} ->
            raise "table-rebuild for #{inspect(table.name)} left foreign-key violations: " <>
                    inspect(violations) <>
                    ". The rebuild ran under PRAGMA defer_foreign_keys = ON; check rows in " <>
                    "dependent tables that reference this one."
        end
      rescue
        # The one sanctioned rescue on this path: a self-opened transaction
        # must not leak past a mid-dance failure — roll it back (best-effort;
        # a dead connection has nothing to roll back) and let the original
        # error keep flying.
        e ->
          if self_wrap? do
            _ = Ecto.Adapters.SQL.query(meta, "ROLLBACK", [], opts)
          end

          reraise e, __STACKTRACE__
      after
        # SQLite auto-resets defer_foreign_keys only at COMMIT, which a
        # sandboxed transaction never reaches and a failed rebuild never gets
        # to — either way the flag would leak ON and silently disable FK
        # enforcement for the session. Restore rather than force OFF: a caller
        # may have deliberately deferred enforcement before migrating.
        # Best-effort (non-bang): if the connection itself died, there is no
        # flag left to leak and no error worth masking the original one with.
        _ = Ecto.Adapters.SQL.query(meta, "PRAGMA defer_foreign_keys = #{prior_defer}", [], opts)
      end
    end)
  end

  # Two half-blind signals, trust either: in_transaction?/1 tracks this
  # process's explicit transaction nesting (true under a real migration's
  # DDL transaction, blind to the SQL Sandbox), while DBConnection.status/2
  # reaches the driver's handle_status, which asks SQLite itself (true under
  # the Sandbox's wrapping transaction, but it may probe a different pool
  # member than the one about to run the rebuild).
  defp in_wrapping_transaction?(meta, opts) do
    in_transaction?(meta) or DBConnection.status(meta.pid, opts) == :transaction
  end

  # A migration marked @disable_ddl_transaction runs with no connection
  # checked out, so every statement in the dance would take whatever
  # connection the pool hands it next. The dance cannot survive that: its
  # BEGIN IMMEDIATE, its statements, its COMMIT and the connection-scoped
  # defer_foreign_keys flag around them all have to be one connection's
  # work. Hold one for the whole dance. A caller that already has a
  # transaction open is already holding its own.
  defp on_one_connection(meta, true, opts, fun), do: Ecto.Adapters.SQL.checkout(meta, opts, fun)

  defp on_one_connection(_meta, false, _opts, fun), do: fun.()

  # SQLite resolves table names case-insensitively (ASCII folding), but
  # several of the rebuild's schema reads compare names as raw TEXT.
  # Resolving the stored spelling once up front makes every later read —
  # CREATE-text scans, index/trigger/sequence fetches, quoting, the final
  # RENAME target — see the table exactly as the schema stores it, whatever
  # spelling the migration used.
  defp resolve_stored_table_name!(meta, table, opts) do
    result =
      Ecto.Adapters.SQL.query!(
        meta,
        "SELECT name FROM sqlite_schema WHERE type = 'table' AND lower(name) = lower(?1)",
        [to_string(table.name)],
        opts
      )

    case result do
      %{rows: [[stored]]} ->
        %{table | name: stored}

      %{rows: []} ->
        raise ArgumentError,
              "cannot rebuild #{inspect(table.name)} for ALTER ... MODIFY: no such table"
    end
  end

  # Since SQLite 3.25 the rebuild's final RENAME re-parses every view and
  # trigger in the schema, so any of them still naming the just-dropped
  # table kills the dance mid-way with an error about a table that "no
  # longer exists". Refuse up front instead, naming the dependents. The
  # word-boundary scan over the stored SQL is the cheap first pass; a name
  # that is a column somewhere hits it too, so every hit is confirmed below
  # before anything is refused.
  defp refuse_dependent_schema_objects!(meta, table, opts) do
    table_name = to_string(table.name)

    # TEMP objects live in sqlite_temp_schema, not sqlite_schema; a TEMP
    # view over the target would otherwise slip past this pre-flight and
    # kill the dance mid-way in SQLite's own rename re-parse.
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        meta,
        "SELECT 'main', type, name, sql FROM sqlite_schema WHERE sql IS NOT NULL AND " <>
          "(type = 'view' OR (type = 'trigger' AND lower(tbl_name) <> lower(?1))) " <>
          "UNION ALL " <>
          "SELECT 'temp', type, name, sql FROM sqlite_temp_schema WHERE sql IS NOT NULL AND " <>
          "(type = 'view' OR (type = 'trigger' AND lower(tbl_name) <> lower(?1)))",
        [table_name],
        opts
      )

    pattern = word_pattern(table_name)

    candidates =
      for [schema, type, name, sql] <- rows,
          Regex.match?(pattern, sql),
          do: %{schema: schema, type: type, name: name, sql: sql}

    case candidates do
      [] -> :ok
      hits -> refuse_confirmed_dependents!(meta, table, hits, opts)
    end
  end

  # SQLite itself can tell a real reference from a name that happens to be a
  # column: a RENAME rewrites the stored SQL of every view and trigger that
  # really references the table, and leaves the rest untouched. So rename the
  # table to the transient name the dance would use, read the candidates back,
  # and roll the whole thing away again. Nothing here is destructive — the
  # savepoint is released either way, and a rename that fails outright (some
  # other object in the schema is already broken) keeps every candidate, since
  # the rebuild's own RENAME would fail the same way.
  defp refuse_confirmed_dependents!(meta, table, candidates, opts) do
    case confirm_dependents(meta, table, candidates, opts) do
      [] ->
        :ok

      confirmed ->
        hits = Enum.map(confirmed, fn %{type: type, name: name} -> {type, name} end)
        raise ArgumentError, dependents_message(to_string(table.name), hits)
    end
  end

  # The rename is the table's own name, resolved from sqlite_schema, quoted
  # into a statement no parameter can carry.
  # sobelow_skip ["SQL.Query"]
  defp confirm_dependents(meta, table, candidates, opts) do
    on_one_connection(meta, not in_wrapping_transaction?(meta, opts), opts, fn ->
      Ecto.Adapters.SQL.query!(meta, ~s|SAVEPOINT "xqlite_rebuild_dependents"|, [], opts)

      try do
        rename =
          "ALTER TABLE " <>
            quote_name(table.name) <> " RENAME TO " <> quote_name(transient_name(table.name))

        case Ecto.Adapters.SQL.query(meta, rename, [], opts) do
          {:ok, _renamed} -> rewritten_dependents(meta, candidates, opts)
          {:error, _unrenamable} -> candidates
        end
      after
        # Both statements are best-effort: on a connection that died there is
        # nothing left to roll back, and no error worth masking the original.
        _ = Ecto.Adapters.SQL.query(meta, ~s|ROLLBACK TO "xqlite_rebuild_dependents"|, [], opts)
        _ = Ecto.Adapters.SQL.query(meta, ~s|RELEASE "xqlite_rebuild_dependents"|, [], opts)
      end
    end)
  end

  defp rewritten_dependents(meta, candidates, opts) do
    # Keyed by {schema, name}: a TEMP object may share its name with a
    # main-schema one, and the rename rewrites stored SQL in both schemas.
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        meta,
        "SELECT 'main', name, sql FROM sqlite_schema WHERE sql IS NOT NULL " <>
          "UNION ALL " <>
          "SELECT 'temp', name, sql FROM sqlite_temp_schema WHERE sql IS NOT NULL",
        [],
        opts
      )

    stored = Map.new(rows, fn [schema, name, sql] -> {{schema, name}, sql} end)

    Enum.filter(candidates, fn candidate ->
      Map.get(stored, {candidate.schema, candidate.name}) != candidate.sql
    end)
  end

  defp dependents_message(table_name, hits) do
    listing = Enum.map_join(hits, ", ", fn {type, name} -> "#{type} #{inspect(name)}" end)

    "cannot rebuild #{inspect(table_name)} for ALTER ... MODIFY: #{listing} still " <>
      "reference(s) it, and the rebuild's final RENAME would fail after the table was " <>
      "already dropped. Drop the dependent objects first, run this migration, then " <>
      "recreate them."
  end

  # A name mentioned as a whole word, matched the way SQLite folds ASCII
  # case. Deliberately generous: a mention inside a comment or a string
  # literal counts too, so the only failure mode is a safe refusal. A name
  # carrying a double quote is stored with that quote doubled, and cannot
  # appear unquoted at all, so both spellings are looked for.
  defp word_pattern(name) do
    bare = Regex.escape(name)
    doubled = Regex.escape(String.replace(name, ~s|"|, ~s|""|))

    Regex.compile!("(?<![A-Za-z0-9_])(?:#{bare}|#{doubled})(?![A-Za-z0-9_])", "i")
  end

  # SQLite compiles a trigger body the first time the trigger fires, not when
  # it is created, so the rebuild's re-CREATE of a trigger that reads a column
  # this same change set removes succeeds — and then every later write to the
  # table fails. Refuse up front, naming the trigger and the column. The
  # reference test is the same word-boundary scan the dependent-object check
  # uses.
  defp refuse_triggers_reading_removed_columns!(table, existing_columns, triggers, changes) do
    removed = removed_stored_columns(existing_columns, changes)

    hits =
      for %{name: trigger_name, sql: sql} <- triggers,
          column <- removed,
          Regex.match?(word_pattern(column), sql),
          do: {trigger_name, column}

    case hits do
      [] ->
        :ok

      [{trigger_name, column} | _rest] ->
        raise ArgumentError, trigger_column_message(table.name, trigger_name, column)
    end
  end

  defp removed_column({:remove, name, _type, _opts}), do: [to_string(name)]
  defp removed_column({:remove, name}), do: [to_string(name)]
  defp removed_column({:remove_if_exists, name, _type}), do: [to_string(name)]
  defp removed_column({:remove_if_exists, name}), do: [to_string(name)]
  defp removed_column(_change), do: []

  # The columns the change set removes, in the spelling the table stores them
  # under: a change may name a column in another case, and every construct
  # checked against this list is written in the stored spelling.
  defp removed_stored_columns(existing_columns, changes) do
    removed = Enum.flat_map(changes, &removed_column/1)

    for col <- existing_columns,
        Enum.any?(removed, &same_column?(col.name, &1)),
        do: col.name
  end

  # A removed column can still be named by something the rebuild re-creates
  # word for word: a table-level UNIQUE over it, a foreign key using it, or a
  # standalone index covering it. SQLite rejects each of those — the first two
  # when the new table is created, the third only after the old table has been
  # dropped. Refuse up front, naming the construct and the way out.
  defp refuse_stranded_constraints!(table, existing_columns, changes, constructs) do
    case removed_stored_columns(existing_columns, changes) do
      [] -> :ok
      removed -> refuse_first_stranded!(table, stranded(constructs, removed))
    end
  end

  defp refuse_first_stranded!(_table, []), do: :ok

  defp refuse_first_stranded!(table, [{construct, remedy, column} | _rest]),
    do: raise(ArgumentError, stranded_message(table.name, construct, remedy, column))

  defp stranded(constructs, removed) do
    for construct <- constructs,
        column <- removed,
        names_column?(construct, column),
        do: {construct_description(construct), construct_remedy(construct), column}
  end

  # An index can cover an expression over the column instead of the column
  # itself, and index_info reports no name for that, so the stored CREATE
  # text is what gets scanned — the same word-boundary scan the trigger check
  # uses, over-approximating into a safe refusal.
  defp names_column?(%{kind: :index, sql: sql}, column),
    do: Regex.match?(word_pattern(column), sql)

  defp names_column?(%{columns: columns}, column),
    do: Enum.any?(columns, &same_column?(&1, column))

  defp construct_description(%{kind: :unique, columns: columns}),
    do: "the UNIQUE constraint over (#{column_listing(columns)})"

  defp construct_description(%{kind: :foreign_key, columns: columns, target: target}),
    do: "the foreign key (#{column_listing(columns)}) referencing #{inspect(target)}"

  defp construct_description(%{kind: :index, name: name}), do: "the index #{inspect(name)}"

  defp construct_remedy(%{kind: :index}) do
    "Drop the index first with drop_if_exists index(...), run this migration, then " <>
      "recreate it over the columns that remain."
  end

  defp construct_remedy(_construct) do
    "It belongs to the table's own declaration, so dropping it takes the same full " <>
      "rebuild: make this change by hand with execute/1, recreating the table without it."
  end

  defp column_listing(columns), do: Enum.map_join(columns, ", ", &inspect/1)

  defp stranded_message(table_name, construct, remedy, column) do
    "cannot rebuild #{inspect(table_name)} for ALTER ... MODIFY: #{construct} names " <>
      "#{inspect(column)}, which this migration removes, and the rebuild re-creates it " <>
      "from the schema as it stands. #{remedy}"
  end

  defp trigger_column_message(table_name, trigger_name, column) do
    "cannot rebuild #{inspect(table_name)} for ALTER ... MODIFY: trigger " <>
      "#{inspect(trigger_name)} names the column #{inspect(column)}, which this migration " <>
      "removes, and the rebuild re-creates triggers exactly as they stand. SQLite would " <>
      "accept the trigger and then fail every later write to the table. Drop the trigger " <>
      "with execute/1 before this change and recreate it after."
  end

  # The rebuild reconstructs foreign keys from the existing schema; a
  # references/2 inside the change set would need that reconstruction to
  # merge in a new clause, which the engine does not do. Without this check
  # the type layer rejects the %Reference{} with an error that blames the
  # type system and hints at nothing.
  defp refuse_reference_changes!(table, changes) do
    case Enum.find(changes, &reference_change?/1) do
      nil -> :ok
      change -> raise ArgumentError, reference_change_message(table.name, change)
    end
  end

  defp reference_change?({op, _name, %Ecto.Migration.Reference{}, _opts})
       when op in [:add, :add_if_not_exists, :modify], do: true

  defp reference_change?(_change), do: false

  defp reference_change_message(table_name, {op, name, ref, _opts}) do
    "cannot rebuild #{inspect(table_name)} for ALTER ... MODIFY: #{op} " <>
      "#{inspect(name)} uses references(#{inspect(ref.table)}), and the table " <>
      "rebuild cannot add or repoint a foreign key. Add the column with " <>
      "references/2 in its own alter block without any :modify (plain ALTER " <>
      "supports it), or make the change by hand with execute/1."
  end

  # A rebuild re-emits the primary key over the key columns the change set
  # leaves keyed. Leaving none of them keyed — removing every one, or giving
  # every one primary_key: false — turns a keyed table into a keyless one:
  # the rows stay, but nothing identifies them any more, and no migration
  # asks for that in so many words. Refuse before any destructive step.
  # Narrowing a composite key to the members that stay keyed is still
  # allowed, and a table that never had a primary key is not affected.
  defp refuse_removed_primary_key!(table, existing_columns, changes) do
    members = XqliteEcto3.RebuildVerification.primary_key_members(existing_columns)

    survivors =
      XqliteEcto3.RebuildVerification.surviving_primary_key_members(existing_columns, changes)

    case {members, survivors} do
      {[], _none} -> :ok
      {_members, [_kept | _rest]} -> :ok
      {removed, []} -> refuse_unless_key_granted!(table, removed, changes)
    end
  end

  # A change set that de-keys every current member but grants another
  # column primary_key: true moves the key rather than removing it.
  defp refuse_unless_key_granted!(table, removed, changes) do
    if Enum.any?(changes, &grants_inline_key?/1) do
      :ok
    else
      raise ArgumentError, removed_primary_key_message(table.name, removed)
    end
  end

  # SQLite gives a table one primary key. Granting a column primary_key: true
  # therefore only works when the key the table has is gone by the end of the
  # change set — every member removed, or de-keyed with primary_key: false.
  # A member the change set keeps keyed would ask for a second key in one
  # table, which SQLite has no way to write. The one exception is a
  # single-column key granted to its own column: that asks for the key the
  # table already has.
  defp refuse_key_grant_beside_kept_key!(table, existing_columns, changes) do
    members = XqliteEcto3.RebuildVerification.primary_key_members(existing_columns)

    kept =
      XqliteEcto3.RebuildVerification.surviving_primary_key_members(existing_columns, changes)

    refuse_key_grant!(table, members, kept, granted_key_columns(changes))
  end

  defp refuse_key_grant!(_table, _members, _kept, []), do: :ok
  defp refuse_key_grant!(_table, _members, [], _granted), do: :ok

  defp refuse_key_grant!(table, [_only], kept, granted) do
    if grants_own_key?(kept, granted) do
      :ok
    else
      raise_key_grant!(table, kept, granted)
    end
  end

  defp refuse_key_grant!(table, _members, kept, granted),
    do: raise_key_grant!(table, kept, granted)

  defp grants_own_key?([kept], [granted]), do: same_column?(kept, granted)
  defp grants_own_key?(_kept, _granted), do: false

  defp raise_key_grant!(table, kept, [granted | _rest]),
    do: raise(ArgumentError, key_grant_message(table.name, kept, granted))

  defp granted_key_columns(changes) do
    for {_op, name, _type, _opts} = change <- changes,
        grants_inline_key?(change),
        do: to_string(name)
  end

  defp key_grant_message(table_name, kept, granted) do
    "cannot rebuild #{inspect(table_name)} for ALTER ... MODIFY: the change set grants " <>
      "#{inspect(granted)} primary_key: true while the table's primary key over " <>
      "(#{column_listing(kept)}) still stands, and a table can have only one primary key. " <>
      "Give every one of those columns primary_key: false in this same alter block, or " <>
      "remove them, to move the key; or make the change by hand with execute/1, " <>
      "recreating the table with the key you want it to have."
  end

  defp removed_primary_key_message(table_name, removed) do
    listing = Enum.map_join(removed, ", ", &inspect/1)

    "cannot rebuild #{inspect(table_name)} for ALTER ... MODIFY: the change set removes " <>
      "or de-keys every primary-key column (#{listing}), leaving the table with no " <>
      "primary key at all. Keep at least one of them, grant another column " <>
      "primary_key: true, or make the change by hand with execute/1, recreating the " <>
      "table with the key you want it to have."
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
  defp refuse_unpreservable_constraints!(meta, table, storage, opts) do
    case unpreservable_kind(meta, table, storage, opts) do
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
  # guard here — no action fires on their rows, and `defer_foreign_keys` defers
  # their enforcement check too, to the end of the dance, where the rebuilt
  # table satisfies it.
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

  # A modify that moves a column to another affinity makes the rebuild's
  # copy rewrite stored values through SQLite's conversion rules — the one
  # door the parameter-binding guards never see. Toward a numeric affinity
  # the rewrite can lose bytes ("007" becomes the integer 7; a 20-digit
  # decimal rounds through float64); toward TEXT it stringifies numeric
  # storage classes, silently changing ORDER BY and range comparisons.
  # Either way the refusal is per-value: stored values the conversion
  # carries exactly pass, so an all-clean column migrates freely.
  defp refuse_affinity_rewrites_on_populated!(
         meta,
         table,
         existing_columns,
         changes,
         storage,
         opts
       ) do
    Enum.each(changes, fn
      {:modify, name, type, modify_opts} ->
        case Enum.find(existing_columns, &same_column?(&1.name, name)) do
          nil ->
            :ok

          column ->
            refuse_affinity_rewrite!(meta, table, column, type, modify_opts, storage, opts)
        end

      _other ->
        :ok
    end)
  end

  defp refuse_affinity_rewrite!(meta, table, column, type, modify_opts, storage, opts) do
    old_affinity = XqliteEcto3.DataType.sqlite_affinity(column.type || "")

    new_affinity =
      type
      |> XqliteEcto3.DataType.column_type(modify_opts)
      |> XqliteEcto3.DataType.sqlite_affinity()

    rewritten = rewritten_count(meta, table, column, old_affinity, new_affinity, storage, opts)

    if rewritten > 0 do
      raise ArgumentError,
            affinity_rewrite_message(
              table.name,
              column.name,
              {old_affinity, new_affinity},
              rewritten
            )
    end
  end

  defp rewritten_count(_meta, _table, _column, affinity, affinity, _storage, _opts), do: 0

  defp rewritten_count(meta, table, column, _old, new_affinity, storage, opts) do
    col = quote_name(column.name)

    case new_affinity do
      :blob ->
        0

      :text ->
        count_rows!(meta, table, "typeof(#{col}) IN ('integer', 'real')", opts)

      _numeric_family ->
        copy_rewritten_count!(meta, table, column, storage, opts)
    end
  end

  # CAST is not affinity: CAST converts ANY text to a number (junk to 0)
  # while the copy's affinity coercion converts only well-formed numeric
  # literals — a CAST predicate over-refused columns holding plain text
  # the copy would carry byte-exact. The faithful oracle is the coercion
  # itself: pour the column through a NUMERIC-affinity scratch table and
  # count values the pour changed — where "changed" means the rendered
  # text differs AND the values are not two numbers of equal value
  # (NUMERIC storing an integral real as an integer, 2.0 as 2, is the
  # float family's documented value-preserving behavior, not a rewrite).
  # The number-equality tolerance requires BOTH sides already numeric by
  # typeof: a bare `=` would let comparison affinity coerce the text
  # side and wave byte loss like '007' -> 7 through. A WITHOUT ROWID table has no rowid
  # to pair on, so the CAST predicate stays there — over-refusing at
  # worst, never under.
  # sobelow_skip ["SQL.Query"]
  defp copy_rewritten_count!(meta, table, column, %{without_rowid: true}, opts) do
    col = quote_name(column.name)

    count_rows!(
      meta,
      table,
      "#{col} IS NOT NULL AND CAST(CAST(#{col} AS NUMERIC) AS TEXT) <> CAST(#{col} AS TEXT)",
      opts
    )
  end

  # sobelow_skip ["SQL.Query"]
  defp copy_rewritten_count!(meta, table, column, _storage, opts) do
    col = quote_name(column.name)
    tbl = quote_name(to_string(table.name))
    probe = quote_name("xqlite_affinity_probe_#{System.os_time(:nanosecond)}")

    Ecto.Adapters.SQL.query!(meta, "CREATE TEMP TABLE #{probe} (r INTEGER, v NUMERIC)", [], opts)

    Ecto.Adapters.SQL.query!(
      meta,
      "INSERT INTO #{probe} SELECT rowid, #{col} FROM #{tbl}",
      [],
      opts
    )

    %{rows: [[n]]} =
      Ecto.Adapters.SQL.query!(
        meta,
        "SELECT count(*) FROM #{probe} p JOIN #{tbl} t ON t.rowid = p.r " <>
          "WHERE t.#{col} IS NOT NULL AND CAST(t.#{col} AS TEXT) <> CAST(p.v AS TEXT) " <>
          "AND NOT (typeof(t.#{col}) IN ('integer', 'real') " <>
          "AND typeof(p.v) IN ('integer', 'real') AND t.#{col} = p.v)",
        [],
        opts
      )

    Ecto.Adapters.SQL.query!(meta, "DROP TABLE #{probe}", [], opts)
    n
  end

  # sobelow_skip ["SQL.Query"]
  defp count_rows!(meta, table, where_sql, opts) do
    %{rows: [[n]]} =
      Ecto.Adapters.SQL.query!(
        meta,
        "SELECT count(*) FROM #{quote_name(table.name)} WHERE #{where_sql}",
        [],
        opts
      )

    n
  end

  defp affinity_rewrite_message(table_name, column_name, {old_affinity, new_affinity}, count) do
    "cannot rebuild #{inspect(table_name)} for ALTER ... MODIFY: changing " <>
      "#{inspect(column_name)} moves it from #{old_affinity} to #{new_affinity} affinity, " <>
      "and the copy would silently rewrite #{count} stored value(s) through SQLite's " <>
      "conversion rules. Convert the data first with execute/1, or keep a type in the " <>
      "column's current affinity family."
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
  defp unpreservable_kind(meta, table, storage, opts) do
    if has_generated_columns?(meta, table, opts) do
      "generated columns"
    else
      unpreservable_table_option(storage) ||
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
  # resolution algorithm), so they must still refuse. The nameless product:
  # a column named "check" is not a CHECK constraint.
  defp unpreservable_constraint(create_sql) do
    scannable = XqliteEcto3.RebuildVerification.without_string_literals_or_names(create_sql)

    cond do
      Regex.match?(~r/\bCHECK\b/i, scannable) -> "CHECK constraints"
      Regex.match?(~r/\bCOLLATE\b/i, scannable) -> "COLLATE clauses"
      Regex.match?(~r/\bDEFERRABLE\b/i, scannable) -> "DEFERRABLE foreign keys"
      Regex.match?(~r/\bON\s+CONFLICT\b/i, scannable) -> "ON CONFLICT clauses"
      true -> nil
    end
  end

  # Three facts a scan of the CREATE text cannot get right, all structural in
  # pragma_table_list: what kind of table this is (`type`), and whether it was
  # declared WITHOUT ROWID or STRICT (`wr`, `strict`) — both of those live in
  # the CREATE text's tail, where a comment containing `)` can hide them from
  # any text scan.
  defp fetch_table_storage!(meta, table, opts) do
    result =
      Ecto.Adapters.SQL.query!(
        meta,
        "SELECT type, wr, strict FROM pragma_table_list " <>
          "WHERE schema = 'main' AND lower(name) = lower(?1)",
        [to_string(table.name)],
        opts
      )

    case result do
      %{rows: [[type, wr, strict]]} ->
        %{type: type, without_rowid: wr == 1, strict: strict == 1}

      _ ->
        %{type: nil, without_rowid: false, strict: false}
    end
  end

  # A virtual table's rows belong to the module behind it (fts5, rtree, …),
  # which keeps them in shadow tables of its own. sqlite_schema types both as
  # plain tables, so every other check here passes and the rebuild would
  # replace a search index with an ordinary table and drop the module's
  # storage along with it.
  defp refuse_virtual_table!(table, %{type: "virtual"}) do
    raise ArgumentError,
          "cannot rebuild #{inspect(table.name)} for ALTER ... MODIFY: it is a virtual table, " <>
            "and a rebuild would replace it with an ordinary one, dropping the storage its " <>
            "module keeps behind it. Make this change with execute/1, using the module's own " <>
            "DDL."
  end

  defp refuse_virtual_table!(table, %{type: "shadow"}) do
    raise ArgumentError,
          "cannot rebuild #{inspect(table.name)} for ALTER ... MODIFY: it is a shadow table, " <>
            "storage that belongs to a virtual table, and rebuilding it would corrupt that " <>
            "table. Change the virtual table itself with execute/1, using its module's own DDL."
  end

  defp refuse_virtual_table!(_table, _storage), do: :ok

  # A rebuild would silently drop either option — converting a WITHOUT ROWID
  # table to a rowid table, or dropping strict type-checking.
  defp unpreservable_table_option(%{without_rowid: true}), do: "WITHOUT ROWID storage"
  defp unpreservable_table_option(%{strict: true}), do: "STRICT typing"
  defp unpreservable_table_option(_storage), do: nil

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
    |> Enum.map(fn {_id, group} -> foreign_key(group, table_name) end)
  end

  defp foreign_key(group, table_name) do
    sorted = Enum.sort_by(group, fn [_id, seq | _] -> seq end)
    [_id, _seq, target, _from, _to, on_update, on_delete, match] = hd(sorted)
    from_cols = Enum.map(sorted, fn [_id, _seq, _table, from | _] -> from end)
    to_cols = Enum.map(sorted, fn [_id, _seq, _table, _from, to | _] -> to end)
    referenced = fk_target(target, table_name)

    clause = [
      "FOREIGN KEY (",
      quoted_column_list(from_cols),
      ") REFERENCES ",
      quote_name(referenced),
      references_column_list(to_cols),
      fk_action_clause(" ON DELETE ", on_delete),
      fk_action_clause(" ON UPDATE ", on_update),
      fk_match_clause(match)
    ]

    %{kind: :foreign_key, columns: from_cols, target: referenced, clause: clause}
  end

  # A self-reference must point at the transient rebuild table, so that dropping
  # the original cannot cascade (or restrict) into the freshly-copied rows;
  # ALTER TABLE ... RENAME then rewrites this target back to the final name.
  # SQLite matches the REFERENCES target case-insensitively (ASCII), so the
  # self-reference test must too — an exact compare misses `REFERENCES node`
  # on a table stored as `Node`, leaving the clause pointed at the original
  # table: its DROP would then cascade into the rows just copied out of it.
  defp fk_target(target, table_name) do
    if ascii_equal_fold?(target, table_name), do: transient_name(table_name), else: target
  end

  defp ascii_equal_fold?(a, b), do: folded(a) == folded(b)

  # The one folding rule the whole engine resolves names with: SQLite folds
  # ASCII case and leaves everything else alone.
  defp folded(name), do: String.downcase(to_string(name), :ascii)

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

    Enum.map(rows, fn [index_name] -> unique_constraint(meta, index_name, opts) end)
  end

  defp unique_constraint(meta, index_name, opts) do
    # index_xinfo, not index_info: only the former carries the per-column
    # sort direction, and a UNIQUE(a DESC, b) rebuilt without the DESC would
    # silently stop satisfying mixed-direction ORDER BYs. `key = 1` filters
    # the indexed columns from the trailing rowid entries.
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        meta,
        "SELECT name, \"desc\" FROM pragma_index_xinfo(?1) WHERE key = 1 ORDER BY seqno",
        [index_name],
        opts
      )

    cols =
      Enum.map(rows, fn
        [col_name, 1] -> [quote_name(col_name), " DESC"]
        [col_name, _asc] -> quote_name(col_name)
      end)

    %{
      kind: :unique,
      columns: Enum.map(rows, fn [col_name, _desc] -> col_name end),
      clause: ["UNIQUE (", Enum.intersperse(cols, ", "), ")"]
    }
  end

  defp quoted_column_list(cols) do
    cols
    |> Enum.map(&quote_name/1)
    |> Enum.intersperse(", ")
  end

  # The sort order a primary key gives each of its members, read the same way
  # the UNIQUE clause above reads its own: index_xinfo is the only pragma that
  # carries the direction, and `key = 1` filters the indexed columns from the
  # trailing rowid entries. Only a key with an index of its own has an entry
  # here — a single-column INTEGER key with no DESC is the table's rowid under
  # another name, and SQLite builds it no index — so an empty result also
  # says "this key is the rowid".
  defp fetch_primary_key_sort_order!(meta, %Ecto.Migration.Table{name: name}, opts) do
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        meta,
        "SELECT xi.name, xi.\"desc\" FROM pragma_index_list(?1) AS il, " <>
          "pragma_index_xinfo(il.name) AS xi " <>
          "WHERE il.origin = 'pk' AND xi.key = 1 ORDER BY xi.seqno",
        [to_string(name)],
        opts
      )

    Map.new(rows, fn [col_name, desc] -> {String.downcase(col_name, :ascii), desc == 1} end)
  end

  defp key_desc?(key_sort_order, name),
    do: Map.get(key_sort_order, String.downcase(name, :ascii), false)

  defp fetch_user_indexes!(meta, %Ecto.Migration.Table{name: name}, opts) do
    # User-created indexes have non-nil `sql`; auto-created ones (from UNIQUE
    # constraints etc.) have NULL sql and will be recreated automatically when
    # the new table is created with the same constraints. `tbl_name` is
    # matched with SQLite's own ASCII case folding: for indexes SQLite
    # happens to normalize the stored spelling, but the rule stays one rule.
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        meta,
        "SELECT name, sql FROM sqlite_schema WHERE type = 'index' " <>
          "AND lower(tbl_name) = lower(?1) AND sql IS NOT NULL",
        [to_string(name)],
        opts
      )

    Enum.map(rows, fn [idx_name, sql] -> %{kind: :index, name: idx_name, sql: sql} end)
  end

  defp fetch_table_triggers!(meta, %Ecto.Migration.Table{name: name}, opts) do
    # For a trigger, sqlite_schema.tbl_name records the spelling the
    # CREATE TRIGGER statement used — not the table's stored spelling — so
    # a raw compare would skip the trigger and the rebuild would drop it.
    # TEMP triggers on the target live in sqlite_temp_schema and die with
    # the dropped table exactly like main-schema ones, so they are captured
    # and re-created too. TEMP indexes need no such union — SQLite refuses
    # a TEMP index on a non-TEMP table.
    %{rows: rows} =
      Ecto.Adapters.SQL.query!(
        meta,
        "SELECT 'main', name, sql FROM sqlite_schema WHERE type = 'trigger' " <>
          "AND lower(tbl_name) = lower(?1) AND sql IS NOT NULL " <>
          "UNION ALL " <>
          "SELECT 'temp', name, sql FROM sqlite_temp_schema WHERE type = 'trigger' " <>
          "AND lower(tbl_name) = lower(?1) AND sql IS NOT NULL",
        [to_string(name)],
        opts
      )

    Enum.map(rows, fn [schema, trg_name, sql] ->
      %{schema: schema, name: trg_name, sql: recreate_trigger_sql(schema, trg_name, sql)}
    end)
  end

  # sqlite_temp_schema stores a temp trigger's SQL with the TEMP keyword
  # stripped and the prefix canonicalized to `CREATE TRIGGER` (holds for
  # the TEMP, TEMPORARY, and temp.-qualified spellings alike), so replaying
  # it verbatim would re-create the trigger in the MAIN schema. Reinstate
  # TEMP; a prefix that breaks the invariant is refused, not guessed at.
  defp recreate_trigger_sql("main", _trg_name, sql), do: sql

  defp recreate_trigger_sql("temp", trg_name, sql) do
    case sql do
      "CREATE TRIGGER" <> rest ->
        "CREATE TEMP TRIGGER" <> rest

      _other ->
        raise ArgumentError,
              "cannot rebuild: TEMP trigger #{inspect(trg_name)} has stored SQL in an " <>
                "unexpected form, so re-creating it in the temp schema is not possible. " <>
                "Drop it, run this migration, then recreate it."
    end
  end

  # sqlite_sequence cannot answer "is AUTOINCREMENT declared" — its row
  # appears only on the FIRST insert, so an empty table's declaration is
  # invisible there and a rebuild keyed on it would silently drop the
  # keyword (making freed ids reusable). The stored CREATE text is the
  # authoritative source; the shared predicate keeps this decision and the
  # post-rebuild verification in agreement.
  defp fetch_autoincrement_flag!(meta, %Ecto.Migration.Table{name: name}, opts) do
    result =
      Ecto.Adapters.SQL.query!(
        meta,
        "SELECT sql FROM sqlite_schema WHERE type = 'table' AND name = ?1",
        [to_string(name)],
        opts
      )

    case result do
      %{rows: [[create_sql]]} when is_binary(create_sql) ->
        XqliteEcto3.RebuildVerification.autoincrement_declared?(create_sql)

      _ ->
        false
    end
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

  # Defense in depth. The rebuild writes a new table from what the structural
  # pragmas report, so a construct it fails to re-emit would be gone with
  # nothing to show for it. Read the structure back once the dance and the
  # foreign-key check have succeeded, and hold it against what the changes
  # predict from the reading taken before the first statement ran. A
  # difference is a defect in the rebuild itself, so it stops the migration
  # before it commits.
  defp verify_structure!(meta, table, before_structure, changes, opts) do
    after_structure = snapshot_structure!(meta, table, opts)

    case XqliteEcto3.RebuildVerification.verify(before_structure, changes, after_structure) do
      :ok -> :ok
      {:error, error} -> raise error
    end
  end

  # Every statement here is a constant inside RebuildVerification. The table
  # name travels as a bound parameter wherever SQLite accepts one, and is
  # quoted into the statement where it does not (a table name cannot be
  # bound); it comes from sqlite_schema, not from user input.
  # sobelow_skip ["SQL.Query"]
  defp snapshot_structure!(meta, table, opts) do
    XqliteEcto3.RebuildVerification.read(to_string(table.name), fn sql, params ->
      %{rows: rows} = Ecto.Adapters.SQL.query!(meta, sql, params, opts)
      rows
    end)
  end

  # Columns added fresh have no matching old column, so they are omitted
  # from the INSERT SELECT copy.
  defp plan_new_schema(existing, changes, opts) do
    autoincrement? = Keyword.fetch!(opts, :autoincrement)
    key_sort_order = Keyword.fetch!(opts, :key_sort_order)

    # Primary-key columns in declared order (table_xinfo `pk` is the 1-based
    # position within the key, 0 otherwise). A single-column key stays inline on
    # its column; a composite key is emitted as a table-level clause below.
    pk_columns =
      existing
      |> Enum.filter(&(&1.pk > 0))
      |> Enum.sort_by(& &1.pk)
      |> Enum.map(& &1.name)

    composite_pk? = length(pk_columns) > 1

    # An explicit `primary_key: false` narrows the key exactly like removing
    # the member does: the clause comes back over the members the change set
    # leaves keyed. Both only tighten uniqueness — the rows a narrower key
    # accepts are a subset of the rows the wider one did.
    kept_pk_columns =
      XqliteEcto3.RebuildVerification.surviving_primary_key_members(existing, changes)

    base =
      Enum.map(existing, fn col ->
        existing_to_column(
          col,
          autoincrement?,
          composite_pk?,
          key_desc?(key_sort_order, col.name)
        )
      end)

    # %{name, source_name, spec}: source_name is the old column to copy
    # FROM (nil for a fresh add), spec the CREATE TABLE column definition.
    final =
      Enum.reduce(changes, base, fn change, cols ->
        apply_change(cols, change)
      end)

    copy_pairs =
      for %{name: name, source_name: src} <- final, not is_nil(src), do: {src, name}

    {final, copy_pairs,
     composite_pk_clause(composite_pk?, kept_pk_columns, final, key_sort_order)}
  end

  # A single-column PK is carried inline by `existing_to_column` (preserving the
  # INTEGER PRIMARY KEY rowid alias and AUTOINCREMENT). A composite PK cannot be
  # expressed inline, so reconstruct it as a table-level clause over the
  # surviving PK columns in declared order — never dropping members down to a
  # single narrower key.
  defp composite_pk_clause(false, _pk_columns, _final, _key_sort_order), do: []

  defp composite_pk_clause(true, pk_columns, final, key_sort_order) do
    case Enum.filter(pk_columns, fn name -> Enum.any?(final, &(&1.name == name)) end) do
      [] -> []
      cols -> [["PRIMARY KEY (", key_column_list(cols, key_sort_order), ")"]]
    end
  end

  # A key member re-emitted with the sort order it was declared with: a
  # `PRIMARY KEY (a DESC, b)` rebuilt without the DESC would silently stop
  # satisfying mixed-direction ORDER BYs, exactly as a flattened UNIQUE would.
  defp key_column_list(cols, key_sort_order) do
    cols
    |> Enum.map(fn name -> key_column(name, key_desc?(key_sort_order, name)) end)
    |> Enum.intersperse(", ")
  end

  defp key_column(name, true), do: [quote_name(name), " DESC"]
  defp key_column(name, false), do: quote_name(name)

  defp existing_to_column(
         %{name: name, type: type, notnull: notnull, default: dflt, pk: pk},
         autoincrement?,
         composite_pk?,
         key_desc?
       ) do
    # `x INTEGER PRIMARY KEY DESC` is SQLite's documented exception: unlike a
    # bare `INTEGER PRIMARY KEY`, it is NOT another name for the table's rowid
    # — the column takes NULLs and the table keeps rowids of its own. Dropping
    # the DESC would quietly turn one into the other.
    pk_clause =
      cond do
        composite_pk? -> ""
        pk == 1 and autoincrement? -> " PRIMARY KEY AUTOINCREMENT"
        pk == 1 and key_desc? -> " PRIMARY KEY DESC"
        pk == 1 -> " PRIMARY KEY"
        true -> ""
      end

    spec = [
      quote_name(name),
      " ",
      carried_type(type),
      if(notnull, do: " NOT NULL", else: ""),
      default_clause(dflt),
      pk_clause
    ]

    %{
      name: name,
      source_name: name,
      spec: spec,
      meta: %{
        type: type,
        notnull: notnull,
        default: dflt,
        pk: pk,
        composite_pk?: composite_pk?,
        key_desc?: key_desc?,
        autoincrement?: autoincrement? and pk == 1 and not composite_pk?
      }
    }
  end

  # A stored type text that is already one complete quoted token re-parses
  # as the same single name.
  @quoted_typename ~r/^(?:"(?:[^"]|"")*"|\[[^\]]*\]|`(?:[^`]|``)*`|'(?:[^']|'')*')$/

  # A stored type text re-renders verbatim only when SQLite reads it back
  # as one typename: the bare grammar with no keywords, or one already
  # fully quoted token. Everything else — reserved words, hyphens, dots,
  # stray quotes — is emitted as a quoted identifier (same affinity: the
  # marker scan reads the text either way). Splicing such text bare is a
  # syntax error on the transient CREATE, bricking every rebuild.
  defp carried_type(type) when type in [nil, ""], do: "BLOB"

  defp carried_type(type) do
    if XqliteEcto3.DataType.bare_typename?(String.upcase(type)) or
         Regex.match?(@quoted_typename, type) do
      type
    else
      quote_name(type)
    end
  end

  defp default_clause(nil), do: ""
  defp default_clause(value), do: [" DEFAULT ", carried_default(to_string(value))]

  @literal_default_pattern ~r/^(?:[+-]?(?:\d+(?:\.\d+)?|\.\d+)(?:[eE][+-]?\d+)?|'(?:[^']|'')*'|[xX]'[0-9A-Fa-f]*'|NULL|TRUE|FALSE|CURRENT_TIMESTAMP|CURRENT_DATE|CURRENT_TIME)$/i

  # pragma table_xinfo reports an expression DEFAULT without the parentheses
  # SQLite's grammar requires around it, so a carried-over default that is
  # not a plain literal must be re-wrapped or the emitted CREATE fails to
  # parse.
  defp carried_default(text) do
    if literal_default?(text), do: text, else: ["(", text, ")"]
  end

  defp literal_default?(text) do
    Regex.match?(@literal_default_pattern, String.trim(text))
  end

  defp apply_change(cols, {:add, name, type, opts}) do
    cols ++
      [%{name: to_string(name), source_name: nil, spec: add_spec(name, type, opts), meta: nil}]
  end

  defp apply_change(cols, {:add_if_not_exists, name, type, opts}) do
    if Enum.any?(cols, &same_column?(&1.name, name)) do
      cols
    else
      apply_change(cols, {:add, name, type, opts})
    end
  end

  defp apply_change(cols, {:remove, name, _type, _opts}), do: apply_change(cols, {:remove, name})

  defp apply_change(cols, {:remove, name}) do
    refuse_unknown_column!(cols, name, :remove)
    Enum.reject(cols, &same_column?(&1.name, name))
  end

  defp apply_change(cols, {:remove_if_exists, name, _type}),
    do: apply_change(cols, {:remove_if_exists, name})

  defp apply_change(cols, {:remove_if_exists, name}) do
    Enum.reject(cols, &same_column?(&1.name, name))
  end

  defp apply_change(cols, {:modify, name, type, opts}) do
    refuse_unknown_column!(cols, name, :modify)

    Enum.map(cols, fn col ->
      if same_column?(col.name, name) do
        %{col | spec: modify_spec(col, col.name, type, opts)}
      else
        col
      end
    end)
  end

  defp apply_change(cols, _other), do: cols

  # SQLite resolves column names ASCII-case-insensitively, so the rebuild
  # matches them the same way — a raw compare made a differently-spelled
  # change a silent no-op. The emitted definition keeps the stored spelling.
  defp same_column?(stored_name, change_name) do
    ascii_equal_fold?(stored_name, to_string(change_name))
  end

  defp refuse_unknown_column!(cols, name, kind) do
    if Enum.any?(cols, &same_column?(&1.name, name)) do
      :ok
    else
      raise ArgumentError,
            "cannot rebuild for ALTER ... MODIFY: #{kind} names the column " <>
              "#{inspect(to_string(name))}, and the table has no such column. " <>
              "Nothing was changed."
    end
  end

  # Ecto's contract for modify/3: an option not given leaves that aspect of
  # the column untouched (":null — … If this option is not set, the nullable
  # behaviour of the underlying column is not modified"). So the migration's
  # options merge OVER what the column already declares — rebuilding the
  # definition from the options alone silently dropped NOT NULL, DEFAULT,
  # PRIMARY KEY and AUTOINCREMENT. A column added earlier in the same alter
  # has no stored declaration to merge with (meta: nil).
  defp modify_spec(%{meta: nil}, name, type, opts), do: add_spec(name, type, opts)

  defp modify_spec(%{meta: meta}, name, type, opts) do
    notnull? =
      case Keyword.fetch(opts, :null) do
        {:ok, null} -> !null
        :error -> meta.notnull
      end

    default =
      case Keyword.fetch(opts, :default) do
        {:ok, _} = given -> default_spec(given, name, type)
        :error -> default_clause(meta.default)
      end

    pk? =
      case Keyword.fetch(opts, :primary_key) do
        {:ok, flag} -> flag
        :error -> meta.pk == 1 and not meta.composite_pk?
      end

    pk_clause =
      cond do
        !pk? -> ""
        meta.autoincrement? -> " PRIMARY KEY AUTOINCREMENT"
        meta.key_desc? -> " PRIMARY KEY DESC"
        true -> " PRIMARY KEY"
      end

    [
      quote_name(name),
      " ",
      XqliteEcto3.DataType.column_type(type, opts),
      if(notnull?, do: " NOT NULL", else: ""),
      default,
      pk_clause
    ]
  end

  defp add_spec(name, type, opts) do
    type_sql = XqliteEcto3.DataType.column_type(type, opts)

    [
      quote_name(name),
      " ",
      type_sql,
      if(Keyword.get(opts, :null) == false, do: " NOT NULL", else: ""),
      default_spec(Keyword.fetch(opts, :default), name, type),
      if(Keyword.get(opts, :primary_key, false), do: " PRIMARY KEY", else: "")
    ]
  end

  # One rule for `default:`, whichever path writes the column: these clauses
  # render exactly what XqliteEcto3.Connection.default_expr/3 renders on the
  # plain ALTER path, and refuse exactly what it refuses, so the same
  # migration option produces the same stored default — or the same
  # error — either way.
  defp default_spec({:ok, nil}, _name, _type), do: " DEFAULT NULL"
  defp default_spec({:ok, v}, _name, _type) when is_binary(v), do: [" DEFAULT ", quote_string(v)]

  defp default_spec({:ok, v}, _name, _type) when is_number(v) or is_boolean(v),
    do: [" DEFAULT ", to_string(v)]

  defp default_spec({:ok, {:fragment, frag}}, _name, _type), do: [" DEFAULT ", frag]

  defp default_spec({:ok, v}, name, type) when (is_map(v) and not is_struct(v)) or is_list(v),
    do: [
      " DEFAULT (",
      quote_string(XqliteEcto3.DataType.json_default(v, column: name, type: type)),
      ")"
    ]

  defp default_spec(:error, _name, _type), do: ""

  defp default_spec({:ok, v}, name, type),
    do: XqliteEcto3.DataType.unsupported_default!(v, :unsupported_shape, column: name, type: type)

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

  # A rowid table with no INTEGER PRIMARY KEY alias keeps its row identity
  # only in the implicit rowid, and INSERT ... SELECT does not carry it —
  # the copy renumbers every row behind a deleted gap, silently breaking
  # anything keyed on rowids (an external-content FTS5 index, manual rowid
  # joins). Copy it explicitly. Skipped when a change grants a new inline
  # key (the identity moves to it) or a stored column shadows the name.
  defp rowid_copy_needed?(existing, changes, key_sort_order) do
    pk_members = Enum.count(existing, &(&1.pk > 0))

    # A single-column INTEGER key is another name for the rowid only while
    # SQLite gives it no index of its own. A DESC one gets an index, which
    # means the table keeps rowids of its own for the copy to carry.
    aliased? =
      key_sort_order == %{} and
        Enum.any?(existing, fn col ->
          col.pk == 1 and pk_members == 1 and String.upcase(col.type || "") == "INTEGER"
        end)

    shadowed? =
      Enum.any?(existing, fn col ->
        String.downcase(col.name, :ascii) in ["rowid", "_rowid_", "oid"]
      end)

    not aliased? and not shadowed? and not Enum.any?(changes, &grants_inline_key?/1)
  end

  defp grants_inline_key?({op, _name, _type, opts})
       when op in [:add, :add_if_not_exists, :modify],
       do: Keyword.get(opts, :primary_key, false) == true

  defp grants_inline_key?(_change), do: false

  defp copy_rows_sql(table, copy_pairs, copy_rowid?) do
    copy_pairs = if copy_rowid?, do: [{"rowid", "rowid"} | copy_pairs], else: copy_pairs

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

  defp transient_name(name), do: "#{name}__xqlite_new"

  defp quote_name(name) when is_atom(name), do: quote_name(Atom.to_string(name))

  # SQLite escapes a `"` inside a quoted identifier by doubling it.
  defp quote_name(name) when is_binary(name),
    do: ~s|"| <> String.replace(name, ~s|"|, ~s|""|) <> ~s|"|

  # For the sqlite_sequence `name`, which is a string literal with no
  # identifier-quoting escape hatch.
  defp quote_string(value), do: ~s|'| <> String.replace(to_string(value), ~s|'|, ~s|''|) <> ~s|'|

  @impl Ecto.Adapter.Schema
  def autogenerate(:id), do: nil
  def autogenerate(:embed_id), do: Ecto.UUID.generate()
  # Ecto writes this value into the row as-is, without running the
  # dumpers, so it must already be in storage form.
  def autogenerate(:binary_id) do
    case binary_id_storage() do
      :string -> Ecto.UUID.generate()
      :binary -> Ecto.UUID.bingenerate()
    end
  end

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
  def loaders(:binary_id, type), do: [&binary_id_load/1, type]
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

  # Ecto's loader contract is {:ok, value} | :error — an error TUPLE has no
  # clause in Ecto.Type.process_loaders/3 and crashes the load. :error makes
  # Ecto raise its typed load failure naming field, type, and value.
  defp bool_decode(_x), do: :error

  defp bool_encode(false), do: {:ok, 0}
  defp bool_encode(true), do: {:ok, 1}
  defp bool_encode(x), do: {:ok, x}

  # Governs the :binary_id dumper's output shape, the loader, the migration
  # column type, and the CAST wrapping of query-param Tagged values.
  defp binary_id_storage do
    Application.get_env(:xqlite_ecto3, :binary_id_storage, :string)
  end

  # Input is whatever the field's own type produced: raw 16 bytes when the
  # field is Ecto.UUID, the 36-char string when it is :binary_id (Ecto's
  # primitive passes binaries through untouched).
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
        Ecto.UUID.cast(raw)

      :binary ->
        {:ok, raw}
    end
  end

  defp binary_id_dump(value) when is_binary(value) do
    case binary_id_storage() do
      :string -> {:ok, value}
      :binary -> compact_uuid_string(value)
    end
  end

  defp binary_id_dump(value), do: {:ok, value}

  defp compact_uuid_string(string) do
    case Ecto.UUID.dump(string) do
      {:ok, raw} -> {:ok, raw}
      :error -> {:ok, string}
    end
  end

  # Storage-aware on purpose: a 16-byte value under :string storage is an
  # opaque binary_id, not a UUID to expand.
  defp binary_id_load(<<_::128>> = raw) do
    case binary_id_storage() do
      :string -> {:ok, raw}
      :binary -> Ecto.UUID.load(raw)
    end
  end

  defp binary_id_load(value), do: {:ok, value}

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

  # SQLite's own writers (CURRENT_TIMESTAMP, datetime()) and the
  # adapter's storage form carry no offset designator — a UTC column's
  # values ARE UTC, so an offset-less text gets Etc/UTC attached rather
  # than failing the load.
  defp utc_datetime_decode(val) when is_binary(val) do
    case DateTime.from_iso8601(val) do
      {:ok, dt, _offset} -> {:ok, dt}
      {:error, :missing_offset} -> utc_from_naive(val)
      _ -> {:ok, val}
    end
  end

  defp utc_datetime_decode(val), do: {:ok, val}

  defp utc_from_naive(val) do
    with {:ok, ndt} <- NaiveDateTime.from_iso8601(val),
         {:ok, dt} <- DateTime.from_naive(ndt, "Etc/UTC") do
      {:ok, dt}
    else
      _ -> {:ok, val}
    end
  end

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

  # NUMERIC affinity stores BLOBs and non-numeric text (legacy writers);
  # Decimal.new/1 raises a bare Decimal.Error on them, killing the whole
  # query. A failed or partial parse returns :error instead, which routes
  # into Ecto's typed load failure naming field, type, and value.
  defp decimal_decode(val) when is_binary(val) do
    case Decimal.parse(val) do
      {%Decimal{} = d, ""} -> finite_or_error(d)
      _partial_or_error -> :error
    end
  end

  defp decimal_decode(val) when is_integer(val), do: {:ok, Decimal.new(val)}
  defp decimal_decode(val) when is_float(val), do: {:ok, Decimal.from_float(val)}
  defp decimal_decode(nil), do: {:ok, nil}
  defp decimal_decode(%Decimal{} = val), do: finite_or_error(val)
  defp decimal_decode(_val), do: :error

  # Decimal.parse/1 clean-parses NaN and +-Infinity, and Ecto's :decimal
  # then raises an exception naming no field or value; refusing here
  # routes them into the typed load failure like every other bad value.
  defp finite_or_error(d) do
    if Decimal.nan?(d) or Decimal.inf?(d) do
      :error
    else
      {:ok, d}
    end
  end

  defp json_decode(val) when is_binary(val) do
    case Jason.decode(val) do
      {:ok, decoded} -> {:ok, decoded}
      _ -> {:ok, val}
    end
  end

  defp json_decode(val), do: {:ok, val}
end
