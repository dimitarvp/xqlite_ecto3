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
| `[:xqlite_ecto3, :disconnect]` | Pool closes a connection | `:conn` |
| `[:xqlite_ecto3, :checkout]` | A pool checkout (per-call) | `:conn` |
| `[:xqlite_ecto3, :handle_begin, :*]` | DBConnection.transaction starts | `:mode` (`:transaction` or `:savepoint`) |
| `[:xqlite_ecto3, :handle_commit, :*]` | transaction committed | `:mode` |
| `[:xqlite_ecto3, :handle_rollback, :*]` | transaction rolled back | `:mode` |
| `[:xqlite_ecto3, :handle_execute, :*]` | a non-streaming query runs | `:sql`, `:query` |
| `[:xqlite_ecto3, :handle_declare, :*]` | a streaming cursor opens | `:sql`, `:query` |
| `[:xqlite_ecto3, :handle_fetch, :*]` | streaming batch fetched | `:cursor` |
| `[:xqlite_ecto3, :handle_deallocate, :*]` | streaming cursor closed | `:cursor` |
| `[:xqlite_ecto3, :fk_diagnostics, :*]` | opt-in rich FK diagnosis ran after an FK violation | `:mode` (`:replay` or `:in_transaction`); on `:stop` also `:violations_count`, `:diagnostics_status` |

Every span event (`*, :start | :stop | :exception`) carries
`monotonic_time` (ns) on `:start` and `monotonic_time` + `duration`
(both ns) on `:stop`.

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
  The difference is xqlite_ecto3's own glue (timeout setup, error
  classification).
* **"How long is the actual SQLite call?"** → `[:xqlite, :query]`.
  Closest to wall-clock SQLite time, excluding adapter glue.

## Sample handlers

### Per-Repo dashboard

```elixir
:telemetry.attach(
  "myapp-repo-dashboard",
  [:my_app, :repo, :query],
  fn _, %{total_time: t}, %{source: source}, _ ->
    StatsD.histogram("myapp.repo.#{source}.duration_us", t)
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
  end,
  nil
)
```

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
  fn name, %{duration: d}, _md, _ ->
    Telemetry.Metrics.Distribution.observe("xqlite_layer.#{Enum.join(name, ".")}", d)
  end,
  nil
)
```

The `xqlite_ecto3.handle_execute.stop` minus the inner
`xqlite.query.stop` duration is your adapter glue overhead.

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
