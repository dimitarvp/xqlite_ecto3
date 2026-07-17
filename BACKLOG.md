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

- 2026-07-17 xqlite dep 0.8.0 → 0.9.0 (lock bump, hex-mode verify).
- 2026-07-17 erl_crash.dump: autopsied, dev-noise, stays gitignored.
