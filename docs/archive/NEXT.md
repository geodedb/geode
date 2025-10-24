# NEXT — Near‑Term Plan (v0.18.0 baseline)

This plan contains only actionable, near‑term items consistent with current evidence (docs/status.csv). No speculative or multi‑year items.

## Security & Durability

- Remote KMS hardening: add signature report in geode‑audit (optional pubkey verify) and document strict mode digest anchoring
- Audit CLI: add signature verification output (OK/FAIL) and digest count expectations; `--require-digest` enforcement
- Background vacuum: config toggle `-Dvacuum_bg` plumbing docs and thresholds doc

## Engine & Distributed

- Parallel operators: extend ordered parallelMap to Expand/Filter with barrier guarantees
- Federation resilience: partial shard failure policy (warnings vs fail) and retry budget

## Storage & Indexes

- FSM heuristics auto‑tune; expose metrics (free bytes histogram, compaction triggers)
- Register index WAL handles for all persisted indexes (R‑tree, JSONB inverted, Domain Trie, HNSW)

## Observability

- Audit metrics: chain breaks, digest cadence, signature verification outcomes
- PROFILE/EXPLAIN additions: storage fsync points, page LSN horizon, commit flush policy in effect

## Governance & Docs

- Extend conformance profile to include AU‑3/AU‑9 mapping (audit chain/digest/signature)
- Nightly regeneration of docs/status.csv and refresh of docs/GAP_ANALYSIS.md

All items will be validated by CANARY evidence and reflected in docs/status.csv once implemented.
