# Wiring xqlite_ecto3 telemetry

The xqlite_ecto3 adapter emits `:telemetry` events at the
`DBConnection` callback layer. These complement the higher-level
Ecto events (`[:my_app, :repo, :query]`) and the lower-level xqlite
events (`[:xqlite, :*]`). All three layers compose: pool → adapter
→ driver.

Like the underlying xqlite library, telemetry is **compile-time
opt-in**. When disabled (the default), no `:telemetry` calls exist
in the bytecode at all.

## Enable telemetry

Both flags must be set to capture the full picture:

```elixir
# config/config.exs
config :xqlite, :telemetry_enabled, true
config :xqlite_ecto3, :telemetry_enabled, true
```

Rebuild both deps:

```bash
mix deps.compile xqlite xqlite_ecto3 --force
```

Verify:

```elixir
iex> Xqlite.Telemetry.enabled?()
true
iex> XqliteEcto3.Telemetry.enabled?()
true
```

## Event surface

| Event | Trigger | Key metadata |
|---|---|---|
| `[:xqlite_ecto3, :connect, :*]` | DBConnection opens a connection | `:database`, `:result_class`, `:error_reason` |
| `[:xqlite_ecto3, :disconnect]` | DBConnection tears a connection down (an operation error, a failed ping) | `:conn`, `:reason` |
| `[:xqlite_ecto3, :checkout]` | Once per connection, right after DBConnection opens it — NOT once per pool checkout | `:conn` |
| `[:xqlite_ecto3, :handle_begin, :*]` | DBConnection.transaction starts | `:mode` (`:transaction` or `:savepoint`) |
| `[:xqlite_ecto3, :handle_commit, :*]` | transaction committed | `:mode` |
| `[:xqlite_ecto3, :handle_rollback, :*]` | transaction rolled back | `:mode` |
| `[:xqlite_ecto3, :handle_execute, :*]` | a non-streaming query runs | `:sql`, `:query` |
| `[:xqlite_ecto3, :handle_declare, :*]` | a streaming cursor opens | `:sql`, `:query` |
| `[:xqlite_ecto3, :handle_fetch, :*]` | streaming batch fetched | `:cursor` |
| `[:xqlite_ecto3, :handle_deallocate, :*]` | streaming cursor closed | `:cursor` |
| `[:xqlite_ecto3, :fk_diagnostics, :*]` | opt-in rich FK diagnosis ran after an FK violation | `:conn`, `:mode` (`:replay` or `:in_transaction`); on `:stop` also `:violations_count`, `:diagnostics_status` |
| `[:xqlite_ecto3, :statement_cache, :hit]` | a cached prepared statement was reused | `:sql` |
| `[:xqlite_ecto3, :statement_cache, :miss]` | the statement was not in the cache (this includes SQL that then falls back to the uncached path) | `:sql` |
| `[:xqlite_ecto3, :statement_cache, :evicted]` | the least recently used statement was finalized to make room | `:sql` |

The three statement-cache events are not spans: each carries
`monotonic_time` (ns) and `cached_count`, the number of cached
statements BEFORE the event's own action.

Every span event (`*, :start | :stop | :exception`) carries
`monotonic_time` on `:start` and `monotonic_time` + `duration` on
`:stop`. Those come from `:telemetry.span/3` and are in the runtime's
NATIVE time unit, not necessarily nanoseconds — on Linux a native unit
IS a nanosecond, so the numbers coincide; `System.convert_time_unit(1,
:second, :native)` tells you what your runtime uses. The adapter's own
non-span events (`:disconnect`, `:checkout`, the statement-cache
events) are always in nanoseconds.

`:telemetry.span/3` also adds `system_time` to every `:start`'s
measurements and a `telemetry_span_context` reference to every span
event's metadata — that reference is what pairs a `:start` with its
`:stop`.

A graceful pool or application shutdown does NOT emit
`[:xqlite_ecto3, :disconnect]`: the connection process exits before
its terminate callback runs (DBConnection does not trap exits there).
Do not treat connect and disconnect counts as a balanced pair — every
clean deploy leaves the connect count ahead.

### The `:exception` phase carries other metadata

A span's `:exception` event carries the `:start` metadata plus `kind`,
`reason` and `stacktrace`. It does NOT carry `result_class` or
`error_reason`: the adapter builds those from a callback's return
value, and a callback that raised never returned one.

`:telemetry` detaches any handler that raises. A handler whose head
binds `%{result_class: class}` therefore disappears from the whole VM
the first time an exception event reaches it — silently, taking every
other event that handler subscribed to with it. Give handler functions
a catch-all clause, as the samples below do.

### Two shapes of `error_reason`

`error_reason` is normally the error the callback returned. When the
callback also told DBConnection to drop the connection — a statement
error that took the whole transaction with it, a failed COMMIT — it is
`{:disconnect, error}` instead: the same error, plus the fact that the
connection is going away. Match both shapes.
`XqliteEcto3.Telemetry.OpenTelemetry` looks inside the tuple, so
`error.type` names the error either way.

## Composing layers

A typical Ecto query through the Repo fires events at all three
layers:

```
[:my_app, :repo, :query]               (Ecto's own — high-level)
[:xqlite_ecto3, :handle_execute, :*]   (adapter callback — DBConnection)
[:xqlite, :query, :*]                  (xqlite NIF wrapper)
```

Pick the layer that matches your observability question:

* **"Which Ecto query is slow?"** → `[:my_app, :repo, :query]`.
  Highest-level, includes Ecto-side decode/encode time.
* **"Is the slow query the adapter or the driver?"** →
  `[:xqlite_ecto3, :handle_execute]` vs `[:xqlite, :query]`.
  The difference is xqlite_ecto3's own glue: timeout setup, error
  classification, and — on failed statements only — the error-path
  reads (the `fk_diagnostics` replay, which has its own span, and the
  unique-index-name lookup, which currently does not; under write
  contention on a rollback-journal database that lookup can wait up
  to one `busy_timeout`).
* **"How long is the actual SQLite call?"** → `[:xqlite, :query]`.
  Closest to wall-clock SQLite time, excluding adapter glue.

## Sample handlers

### Per-Repo dashboard

```elixir
:telemetry.attach(
  "myapp-repo-dashboard",
  [:my_app, :repo, :query],
  fn
    _, %{total_time: t}, %{source: source}, _ when is_binary(source) ->
      StatsD.histogram("myapp.repo.#{source}.duration_us", t)

    _, _, _, _ ->
      :ok
  end,
  nil
)
```

### Pool lifecycle alerting

```elixir
:telemetry.attach_many(
  "pool-watchdog",
  [
    [:xqlite_ecto3, :connect, :stop],
    [:xqlite_ecto3, :disconnect]
  ],
  fn
    [:xqlite_ecto3, :connect, :stop], _, %{result_class: :error, database: db}, _ ->
      Logger.error("xqlite_ecto3 connect failed for #{db}")

    [:xqlite_ecto3, :disconnect], _, _, _ ->
      Telemetry.Metrics.Counter.inc("xqlite_ecto3.disconnects")

    _name, _measurements, _metadata, _config ->
      :ok
  end,
  nil
)
```

The last clause is what keeps this handler attached. Without it, a
successful connect (`result_class: :ok`) or an `:exception` event —
which carries no `result_class` at all — raises inside the handler, and
`:telemetry` responds by detaching it for good.

### Detecting deadlock-like adapter behaviour

If you suspect a query hung between adapter and driver (e.g.,
DBConnection wrap is the culprit, not SQLite), watch the time
difference:

```elixir
:telemetry.attach_many(
  "adapter-vs-driver",
  [
    [:xqlite_ecto3, :handle_execute, :stop],
    [:xqlite, :query, :stop]
  ],
  fn
    name, %{duration: d}, _md, _ ->
      Telemetry.Metrics.Distribution.observe("xqlite_layer.#{Enum.join(name, ".")}", d)

    _name, _measurements, _md, _ ->
      :ok
  end,
  nil
)
```

The `xqlite_ecto3.handle_execute.stop` minus the inner
`xqlite.query.stop` duration is your adapter glue overhead.

### Properly-named database attributes (semantic conventions)

Database-aware backend features key off OpenTelemetry's [stable
database semantic-convention names](https://opentelemetry.io/docs/specs/semconv/database/database-spans/).
`XqliteEcto3.Telemetry.OpenTelemetry` maps the adapter's events to
that vocabulary (`db.system.name`, `db.query.text`,
`db.operation.name`, `db.namespace`, `error.type`) with no
OpenTelemetry dependency — call `attributes/3` from your own handler
and attach the result to the span you create. The xqlite library
events have their mirror in `Xqlite.Telemetry.OpenTelemetry`. Every
mapped name is cited to its spec page in the module docs.

### OpenTelemetry

Use `:opentelemetry_telemetry`:

```elixir
:opentelemetry_telemetry.attach(:xqlite_ecto3_otel, [
  [:xqlite_ecto3, :connect],
  [:xqlite_ecto3, :handle_begin],
  [:xqlite_ecto3, :handle_commit],
  [:xqlite_ecto3, :handle_rollback],
  [:xqlite_ecto3, :handle_execute],
  [:xqlite_ecto3, :handle_declare],
  [:xqlite_ecto3, :handle_fetch],
  [:xqlite_ecto3, :handle_deallocate]
])
```

xqlite_ecto3 does NOT depend on `:opentelemetry` directly — that's
a downstream concern. The OTel bridge maps each span to an OTel
span automatically.

## Sandbox & test environments

`Ecto.Adapters.SQL.Sandbox` operates above this layer. Sandbox
checkout / checkin / allow events are NOT emitted by xqlite_ecto3
itself — they come from `Ecto.Adapters.SQL.Sandbox`. Attach to
those events directly if you need sandbox observability.

(A future xqlite_ecto3-specific sandbox adapter — if we ship one —
would emit `[:xqlite_ecto3, :sandbox, :*]`. Not present today.)

## See also

* xqlite library guide: `Xqlite.Telemetry` moduledoc.
* `:telemetry` package: <https://hexdocs.pm/telemetry/>
* OpenTelemetry bridge: <https://hexdocs.pm/opentelemetry_telemetry/>
