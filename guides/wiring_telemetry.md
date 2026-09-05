# Wiring xqlite_ecto3 telemetry

The xqlite_ecto3 adapter emits `:telemetry` events at the
`DBConnection` callback layer. These complement the higher-level
Ecto events (`[:my_app, :repo, :query]`). The lower-level xqlite
events (`[:xqlite, :*]`) fire only for calls you make through the
`Xqlite` module yourself — the adapter drives the NIF layer directly
(see "Composing layers" below).

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
| `[:xqlite_ecto3, :fk_diagnostics, :*]` | opt-in rich FK diagnosis ran after an FK violation | `:conn`, `:mode` (`:replay` or `:in_transaction`); on `:stop` also `:violations_count` (rows carried, capped), `:violations_total` (the real number), `:diagnostics_status` (`:ok` \| `:truncated` \| `:unavailable`) |
| `[:xqlite_ecto3, :statement_cache, :hit]` | a cached prepared statement was reused | `:conn`, `:sql` |
| `[:xqlite_ecto3, :statement_cache, :miss]` | the statement was not in the cache (this includes SQL that then falls back to the uncached path) | `:conn`, `:sql` |
| `[:xqlite_ecto3, :statement_cache, :evicted]` | the least recently used statement was finalized to make room | `:conn`, `:sql` |

The three statement-cache events are not spans: each carries
`monotonic_time` (ns) and `cached_count`, the number of cached
statements BEFORE the event's own action. The cache is per
connection — group by `:conn`, or a pool-wide hit rate is depressed
by `pool_size` misses per distinct statement and `cached_count`
interleaves independent counters.

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

To correlate a disconnect with the statement that caused it, join on
`:conn`: the `[:xqlite_ecto3, :disconnect]` event and the
`[:xqlite_ecto3, :handle_execute]` `:stop` event whose `error_reason`
is `{:disconnect, _}` carry the same connection reference. When the
disconnect came from an operation error, the event's `:reason` is the
wrapped `%XqliteEcto3.Error{}` and its `:type` says what failed; when
it came from a cancel it is
`%DBConnection.ConnectionError{reason: :error}` — indistinguishable
from DBConnection's own checkout-deadline recycle, so use the matching
`:stop` event's `error_reason` to tell those two apart.

### The `:exception` phase carries other metadata

A span's `:exception` event carries the `:start` metadata plus `kind`,
`reason` and `stacktrace`. It does NOT carry `result_class` or
`error_reason`: the adapter builds those from a callback's return
value, and a callback that raised never returned one.

`:telemetry` detaches any handler that raises. A handler whose head
binds `%{result_class: class}` therefore disappears from the whole VM
the first time an exception event reaches it — silently, taking every
other event that handler subscribed to with it. Give handler functions
a catch-all clause, as the samples below do. The phase is not
theoretical: anything that raises inside a span's body (connect
included) emits it.

### Two shapes of `error_reason`

`error_reason` is normally the error the callback returned. When the
callback also told DBConnection to drop the connection — a statement
error that took the whole transaction with it, a failed COMMIT — it is
`{:disconnect, error}` instead: the same error, plus the fact that the
connection is going away. Match both shapes.
`XqliteEcto3.Telemetry.OpenTelemetry` looks inside the tuple, so
`error.type` carries the wrapped `%XqliteEcto3.Error{}`'s typed `:type` atom (`"constraint_violation"`, `"database_busy_or_locked"`, ...) either way — never the bare struct name.

## Composing layers

Under Ecto, a query through the Repo fires events at two layers:

```
[:my_app, :repo, :query]               (Ecto's own — high-level)
[:xqlite_ecto3, :handle_execute, :*]   (adapter callback — DBConnection)
```

The adapter drives xqlite's NIF layer directly, so the `[:xqlite, …]`
spans do NOT fire for Repo traffic. They fire only for calls you make
through the `Xqlite` module yourself — inside
`XqliteEcto3.with_xqlite/3`, or via `XqliteEcto3.explain_analyze/3`,
which calls `Xqlite.explain_analyze/3`.

Pick the layer that matches your observability question:

* **"Which Ecto query is slow?"** → `[:my_app, :repo, :query]`.
  Highest-level, includes Ecto-side decode/encode time.
* **"How long did the adapter spend on the statement?"** →
  `[:xqlite_ecto3, :handle_execute]`. Its duration is the SQLite call
  plus xqlite_ecto3's own glue: timeout setup, error classification,
  and — on failed statements only — the error-path reads (the
  `fk_diagnostics` replay, which has its own span, and the
  unique-index-name lookup, which currently does not; under write
  contention on a rollback-journal database that lookup can wait up
  to one `busy_timeout`).

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
require Logger

:telemetry.attach_many(
  "pool-watchdog",
  [
    [:xqlite_ecto3, :connect, :stop],
    [:xqlite_ecto3, :disconnect]
  ],
  fn
    [:xqlite_ecto3, :connect, :stop], _, %{result_class: :error, database: db}, _ ->
      Logger.error("xqlite_ecto3 connect failed for #{db}")

    [:xqlite_ecto3, :disconnect], _, %{reason: reason}, _ ->
      Logger.warning("xqlite_ecto3 dropped a connection: #{inspect(reason)}")

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

### Catching slow statements

`duration` is in native time units; convert before comparing:

```elixir
require Logger

:telemetry.attach(
  "slow-statements",
  [:xqlite_ecto3, :handle_execute, :stop],
  fn _, %{duration: d}, %{sql: sql}, budget_ms ->
    ms = System.convert_time_unit(d, :native, :millisecond)
    if ms > budget_ms, do: Logger.warning("slow statement (#{ms} ms): #{sql}")
  end,
  250
)
```

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

xqlite_ecto3 does NOT depend on `:opentelemetry` — that's a downstream
concern. What it ships is the mapping: `XqliteEcto3.Telemetry.OpenTelemetry`
turns an event into the stable OpenTelemetry database attributes (the
previous section), and every span carries a stable
`telemetry_span_context` in its metadata. To turn those into OTel
spans, write a handler that calls the `opentelemetry_telemetry`
package's `:otel_telemetry.start_telemetry_span/4` on `:start` and
`:otel_telemetry.end_telemetry_span/2` on `:stop` and `:exception`.
That package is a toolkit for handlers you write; it has no attach
call that subscribes on its own.

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
