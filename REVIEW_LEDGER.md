# Review ledger — xqlite_ecto3 (append-only)

One entry per fleet run: date, commit, scope, fleet composition,
findings with verdicts + severity + fix commit or backlog ref,
per-axis dryness state. Nothing found is ever silently dropped.

---

## Run 0 — 2026-07-17 — Phase-1 recon (wave 1)

- Commit at scan: `f419016`. Fleet: shared with xqlite's Run 0
  (4 sonnet read-only agents + orchestrator synthesis); raw
  transcripts + distillates in `~/kod/fleet_review_staging/recon/`.
- Outcomes:
  - **21 accidental-public SQL helpers** in
    `XqliteEcto3.Connection` (zero docs/specs/external callers per
    agent rg) → BACKLOG G1, pre-publish gate. Spot-check callers
    before converting.
  - **Exclusion-ledger drift**: ECTO_INTEGRATION_TAGS.md carries an
    orphaned tag, a stale-contradicted row (`:foreign_key_constraint`
    — rich FK diagnostics solved it), two statically-unverifiable
    rows (`:transaction_checkout_raises`, `:values_list`) and stale
    header numbers → BACKLOG G2 + the two-tag probe (B2).
  - erl_crash.dump: dev-noise (May 2, init/stdio shutdown race),
    closed.
  - CI floor gap (Elixir ~> 1.15 claimed, 1.17 tested) → BACKLOG G3.
  - CLAUDE.md absent; bootstrap content inventoried → BACKLOG G5.
  - 23 + 15 failure classes harvested and mapped onto B1–B10/X1–X2
    seed probes (distillates hold the map).
- Post-run action same day: xqlite dep lock bumped 0.8.0 → 0.9.0
  (hex-mode; kills the 1.20 dep-compile warnings; first consumer
  validation of the published 0.9.0 precompiled artifacts).
- Dryness: all axes WET (no adversarial pass has run yet).
