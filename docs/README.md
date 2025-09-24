# Geode Documentation

## Start Here

### Reality Check (Required)

- [IMPLEMENTATION_REALITY.md](IMPLEMENTATION_REALITY.md) — Evidence-driven snapshot of what’s actually implemented (generated 2025-09-24)
- [GAP_ANALYSIS.md](GAP_ANALYSIS.md) — Machine-verified evidence ledger and conformance summary (hash-guarded)
- [REQUIREMENTS.md](REQUIREMENTS.md) — v0.15.0 scope, acceptance, and policies (ISO/IEC 39075 GQL–first)

### Technical Documentation

- [BINARY_PROTOCOL.md](BINARY_PROTOCOL.md) — Wire frames, diagnostics, pagination semantics
- [USAGE.md](USAGE.md) — Build/run usage, client flags, demos, telemetry
- [TELEMETRY.md](TELEMETRY.md) — Optional paging telemetry (stderr JSON) and how to enable
- [GOVERNANCE.md](GOVERNANCE.md) — CANARY governance and CI reference
- [NEXT.md](NEXT.md) — Forward backlog (date‑guarded)

Telemetry (optional):

```bash
# Quick local telemetry smoke (captures PULL_PAGE events)
make telemetry-smoke
```

## Current Evidence Snapshot (2025-09-24)

- 607 tracked aspects (TOTAL)
- 365 TESTED (functional)
- 229 BENCHED (variance‑guarded performance)
- Residuals: 6 STUB, 7 IMPL (unpromoted)

Counts originate from the CANARY scanner (`status.csv` authoritative) and are cross-checked in governance. See IMPLEMENTATION_REALITY for component-by-component detail.

## High-Level Status

### ✅ Strong (well-tested + benchmarked)

- Wire protocol (HELLO/RUN_GQL/PULL; SCHEMA/BINDINGS/EXPLAIN/PROFILE)
- Query engine core (RETURN, ORDER BY legality, set operations)
- Schema constraints (check/unique/pattern)
- CDC engine (internal sinks; guardrails)

### ⚠️ Moderate (tested but limited)

- Transactions (MVCC SI; phantom‑prevention instrumentation)
- Path operations (bounded expansion; determinism; partial MATCH semantics)
- Storage & WAL (recovery; compaction; partial ARIES optimizations pending)

### ❌ Weak / Not Implemented

- Distributed: partial Raft scaffolding (append entries/commit advance); no election/snapshot; sharding future
- QUIC transport: experimental (feature‑flagged), TCP remains primary
- GPU acceleration, advanced graph analytics, full-text search: not implemented
- Cost-based optimizer: initial cost model scaffolding; no cost-based plan selection

## Verification

All claims are backed by CANARY evidence. To verify locally:

```bash
# Build the scanner
make canary

# Strict verification of GAP_ANALYSIS vs evidence
./bin/canaryscan --root . --out status.json --csv status.csv --verify docs/GAP_ANALYSIS.md --strict

# Inspect CANARY lines
grep -r "CANARY: REQ=REQ-GQL-" src/ tests/ docs/ | head
```

## Documentation Standards

1. No undocumented claims — every feature claim must have a CANARY token.
2. Evidence-based — STATUS is TESTED or BENCHED (STUB/IMPL are residuals tracked to zero).
3. Freshness — NEXT and IMPLEMENTATION_REALITY are date‑guarded by governance.
4. Automated checks — CI runs scanner + governance on each push/PR.

## For Contributors

Before claiming a feature is implemented:

1. Add a CANARY line to the implementation or tests.
2. Add tests and, if relevant, variance benches.
3. Run `make governance-check` until green.
4. If counts changed, update docs under governance scripts (hash marker in GAP_ANALYSIS will be rewritten by helper).

Example CANARY token:

```zig
// CANARY: REQ=REQ-GQL-XXX; FEATURE="Feature Name"; ASPECT=Component; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_XXX_FeatureName; OWNER=team; UPDATED=2025-09-24
```

## Notes

- QUIC is experimental; TCP remains the primary transport. See USAGE for flags and TLS notes.
- Distributed features are scaffolding only in v0.15.0 (leader-only posture).
