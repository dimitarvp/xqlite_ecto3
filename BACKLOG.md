# Backlog — xqlite_ecto3 (review program)

Severity per the ratified bar in `xqlite/REVIEW_AXES.md`. Nothing
here is ever silently dropped; S3s get a committed closer-look pass
after the S0–S2 burn-down.

## Pre-publish gates (release-readiness, regardless of severity)

- [G1] 21 accidental-public SQL helpers in `Connection` → `defp`
  (verify the zero-external-caller claim per function first;
  includes the `insert_all/1,2` name-confusion hazard). (wave-1)
- [G2] ECTO_INTEGRATION_TAGS.md reconciliation: drop the orphaned
  `:concurrent_poolrepo_transactions` row; rewrite the stale
  `:foreign_key_constraint` row; fix headers (SQLite 3.51.3 →
  3.53.2; 15/18 → 16/18); thicken the two vague rows after the
  two-tag probe. (wave-1)
- [G3] Elixir floor: `~> 1.15` claimed, CI floor 1.17 — add lanes
  or raise the floor (floor-raise = Dimi values call; identical gap
  in xqlite). (wave-1)
- [G5] CLAUDE.md bootstrap (content list inventoried in
  `~/kod/fleet_review_staging/recon/recon_adapter_distilled.md`).

## Probes (orchestrator-run)

- [P1] Two-tag status probe: run the suite isolating
  `:transaction_checkout_raises` and `:values_list` — resolves the
  ledger-vs-README contradiction; failures get classified per the
  bar. (B2)
- [B3] `:memory:` + pool_size guard probe; connect-time PRAGMA storm
  under pool cold-start; wedged-txn-state symmetry.
- [B9] Verify CI builds AND tests both telemetry compile configs.

## Open (S3 — tracked, never dropped)

- [X1-2] `Error.wrap/1`'s generic `{tag, msg}` clause requires
  `is_binary(msg)`, so ~14 documented `error_reason/0` shapes with a
  map/int/atom/tuple payload fall to the `inspect` catch-all and lose
  their `type` tag (`:integral_value_out_of_range`,
  `:cannot_convert_to_sqlite_value`, `:cannot_execute_pragma`,
  `:invalid_parameter_count`, `:invalid_column_type`,
  `:from_sql_conversion_failure`, `:cannot_open_database`,
  `:invalid_open_option`, `:invalid_pages_per_step`,
  `:invalid_authorizer_action`, `:invalid_column_index`,
  `:unsupported_data_type`, `:schema_parsing_error`,
  `:invalid_on_error`). Still valid exceptions, never misclassified —
  unclassified. Completeness. A 2nd X1 pass decides: add clauses or
  ratify inspect-fallback as intended for exotic shapes. (Run 1)
- [B1-1] `dump_cmd/3` is a required `Ecto.Adapter.Structure` callback
  (no `@optional_callbacks`) but the adapter `raise`s. Unreachable via
  mix tasks (`mix ecto.dump` uses `structure_dump/2`), so harmless —
  but consider a structured `{:error, ...}` or a moduledoc note. Same
  entry: `storage_up/1` MatchErrors on `XqliteNIF.open` failure
  instead of returning `{:error, term}` (near-impossible path). (Run 1)
- [S3] docs `groups_for_modules` lists 3 `@moduledoc false` modules
  (dead config). (wave-1)
- [S3] Untracked `.expert/` root clutter — gitignore or remove
  (Dimi's call). (wave-1)
- [S3] test_helper's `logging.exs:74` exclusion rationale is thin —
  state permanent-vs-trackable. (wave-1)
- [S3] `async: false` ban is honored (0/52) but written down
  nowhere in this repo — codify in the CLAUDE.md bootstrap. (wave-1)

## Feature follow-ups (owed, not review findings)

- [A2] hooks config `:busy` kind + busy-aware concurrency docs —
  unlocked by xqlite 0.9.0's busy split.
- [A3] Optionally migrate raw `XqliteNIF.txn_state/connection_stats`
  doc references to the new `Xqlite` wrappers (additive, optional).

## Closed

- 2026-07-20 [F-X2-1] (S2) statement-cache path leaked sticky
  `sqlite3_changes()` as `num_rows` for columnless non-DML (DDL/
  PRAGMA) statements — fixed via `total_changes`-delta gating in the
  driver, RED→green in `driver_statement_cache_test.exs`. (Run 1)
- 2026-07-20 [F-X1-1] (S3) `wrap/1` `:sqlite_failure` clause dropped
  the type-permitted nil-message variant — fixed, RED→green in
  `error_wrap_test.exs`. (Run 1)
- 2026-07-17 xqlite dep 0.8.0 → 0.9.0 (lock bump, hex-mode verify).
- 2026-07-17 erl_crash.dump: autopsied, dev-noise, stays gitignored.
