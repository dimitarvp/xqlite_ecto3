# xqlite_ecto3 vs ecto_sqlite3 benchmarks

Standalone project, deliberately outside the package: its lockfile
pins both adapters explicitly (ecto_sqlite3 from Hex; xqlite_ecto3 +
xqlite from the local working copies).

```bash
cd bench
mix deps.get
mix run bench.exs
```

Knobs: `BENCH_TIME`, `BENCH_WARMUP`, `BENCH_MEMORY_TIME` (seconds).

Methodology: identical schemas and pragmas on both adapters (WAL,
synchronous NORMAL, 64 MB cache, 5 s busy timeout, autocheckpoint
1000), file-backed databases under `bench/tmp/`, `pool_size: 1`,
logging off, stock defaults otherwise (xqlite telemetry compiled out,
FK diagnostics off). The bundled SQLite versions differ between the
two libraries and are printed at startup — disclosed, not equalized.

The cancellation section is a capability demonstration, not a
comparison: ecto_sqlite3 has no cancellation mechanism. It measures
wall time from issuing a doomed query with a 100 ms `:timeout` until
control returns with the query actually dead.

Run benchmarks ONLY on a quiet machine. Results are recorded in the
maintainer's internal ledger before any public figures are written.
