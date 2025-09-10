# Geode Design Documentation

## Status & Conformance Summary

- Requirements Ledger and evidence: docs/GAP_ANALYSIS.md
- GQL Conformance Profile (initial): docs/GAP_ANALYSIS.md (GQL Conformance Profile section)
- Execution-ready backlog: docs/NEXT.md

## Troubleshooting (diagnostics quick reference)

- US001 — Unordered pagination: LIMIT/OFFSET without explicit ORDER BY on an unordered input is illegal (ISO 16.18–16.19).
- IllegalOrderKey — ORDER BY key violates ident‑only policy (ISO 14.10).
- GroupByIllegal — RETURN/HAVING expressions not aligned with GROUP BY keys or aggregates (ISO 14.10).
- TypeMismatch — Incomparable types for the requested operation (e.g., ordering across heterogeneous types) (ISO 16.x; 23.2).

## Flagger Findings (policy / behavior flags)

Frames may include a `flagger_findings` array describing enforced policies or behavioral caveats.

Current flags:

- I:IllegalOrderKeyPolicy=ident-only — ORDER BY restricted to simple identifiers (preventing arbitrary expressions/functions).
- U:NullsFirstPolicy — Server currently applies a NULLS FIRST ordering policy (deterministic, not client configurable yet).
- U:OrderTiebreak=LexJSON — Final ordering tie-break uses lexical comparison of full row JSON to ensure deterministic output when keys compare equal.
- U:DistinctOutputUnordered — DISTINCT applied to an otherwise unordered input (surface to client that row order is not guaranteed beyond selection semantics).
- U:US001/enforced — Unordered pagination legality (US001) was enforced for this statement (appears only on related ERROR frames).
- U:UnionPhaseTimings — Granular UNION PROFILE includes phase timing ops (UnionLeft, UnionTails, UnionDedup, SetOpUnion).

Planned additions (not yet emitted):

- U:ComparatorFuzzed — Indicates comparator implementation passed extended fuzz harness (post-integration quality marker).

Semantics:

- Prefix I: indicates an invariant policy enforced by the server.
- Prefix U: indicates an usability / behavior flag providing clarity rather than a strict invariant breach.

Clients should treat unknown flags as informational (forward compatible). Flags are intentionally terse for low overhead in wire encoding.
