# GQL Conformance Profile — MATCH (subset)

// CANARY: REQ=REQ-GQL-024; FEATURE="Conformance Profile Ledger"; ASPECT=Docs; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_ImplDefinedCollationAndNullOrdering; OWNER=docs; UPDATED=2025-09-24

This document captures currently claimed features and implementation-defined/dependent behaviors relevant to MATCH ordering and pagination.

## Supported (subset)

- MATCH with:
  - Node label and single property equality predicate (baseline)
  - Single-hop expand and bounded path expansion (subset)
  - OPTIONAL MATCH (null-preserving) semantics (subset)
- ORDER BY over RETURN items for MATCH result bindings, with deterministic comparator and JSON lexicographic tiebreak.
- LIMIT/OFFSET slicing post-ordering.
- Set operations: UNION/INTERSECT/EXCEPT (existing engine path).

### Deterministic Transport Parity Evidence (Curated Datasets)

- Curated varlen determinism dataset (`data/varlen_determinism`) exercises equal-length path expansions to validate whole-row JSON lex tie-break and UA005/UA006 ordering consistency.
- Transport parity (STDIO vs QUIC) verified for: simple RETURN ordering, set operations DISTINCT, projection slices, ORDER/LIMIT/OFFSET pagination, MATCH variable-length expansions, diagnostics (US001, IllegalOrderKey), CASE 3VL null semantics, and nulls-last ordering.
- New client passthrough flag `--server-arg` enables supplying graph dataset (e.g., `--server-arg --data_dir --server-arg ./data/varlen_determinism`) under stdio spawning to mirror external QUIC server configuration; feature included in parity matrix.

// CANARY: REQ=REQ-GQL-018; FEATURE="Transport Parity VarLen Dataset Rows"; ASPECT=Docs; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_018_TransportParity_VarLenDatasetRows; OWNER=engine; UPDATED=2025-09-24
// CANARY: REQ=REQ-GQL-091; FEATURE="Client Server Arg Passthrough"; ASPECT=Docs; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_091_ClientServerArgPassthrough; OWNER=client; UPDATED=2025-09-24

// CANARY: REQ=REQ-GQL-017; FEATURE="Transport Parity Simple RETURN"; ASPECT=Docs; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_TransportParity_ReturnOrdered; OWNER=engine; UPDATED=2025-09-24
// CANARY: REQ=REQ-GQL-017; FEATURE="Transport Parity SetOp DISTINCT"; ASPECT=Docs; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_TransportParity_SetOpDistinct; OWNER=engine; UPDATED=2025-09-24
// CANARY: REQ=REQ-GQL-017; FEATURE="Transport Parity Projection Rows"; ASPECT=Docs; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_TransportParity_ProjectionRows; OWNER=engine; UPDATED=2025-09-24
// CANARY: REQ=REQ-GQL-017; FEATURE="Transport Parity ORDER/LIMIT/OFFSET Rows"; ASPECT=Docs; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_TransportParity_OrderPaginationRows; OWNER=engine; UPDATED=2025-09-24
// CANARY: REQ=REQ-GQL-017; FEATURE="Transport Parity MATCH VarLen Rows"; ASPECT=Docs; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_TransportParity_MatchVarLenRows; OWNER=engine; UPDATED=2025-09-24

// CANARY: REQ=REQ-GQL-017; FEATURE="VarLen Path Determinism UA005/UA006"; ASPECT=Docs; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_VarLenDeterminism_STDIO; OWNER=engine; UPDATED=2025-09-24
// CANARY: REQ=REQ-GQL-017; FEATURE="VarLen Path Determinism UA005/UA006"; ASPECT=Docs; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_VarLenDeterminism_QUIC; OWNER=engine; UPDATED=2025-09-24
// CANARY: REQ=REQ-GQL-017; FEATURE="Transport Parity Diagnostics US001"; ASPECT=Docs; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_TransportParity_US001; OWNER=engine; UPDATED=2025-09-24

## Policies and Diagnostics

- US001 (unordered pagination): LIMIT/OFFSET without explicit ORDER is rejected. Anchor: 16.18–16.19.
- IllegalOrderKey (policy): ORDER BY keys restricted to identifiers by default. Anchor: 14.10.
  // CANARY: REQ=REQ-GQL-017; FEATURE="Transport Parity Diagnostics IllegalOrderKey"; ASPECT=Docs; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_TransportParity_IllegalOrderKey; OWNER=engine; UPDATED=2025-09-24
  // CANARY: REQ=REQ-GQL-017; FEATURE="Transport Parity CASE 3VL"; ASPECT=Docs; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_TransportParity_Case3VL; OWNER=engine; UPDATED=2025-09-24
- Null ordering policy: implementation-defined default; see Requirements — binary collation, nulls-last policy (flagger exposed).
  // CANARY: REQ=REQ-GQL-024; FEATURE="Nulls-Last Ordering Parity"; ASPECT=Docs; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_TransportParity_NullsLastOrder; OWNER=engine; UPDATED=2025-09-24
- UA005/UA006 (bounded path tie-break determinism): Shorter paths preferred; ties broken deterministically by bound IDs and JSON-lex row key. Transport-parity enforced by tests.

## Safety Guards (Execution Limits)

The engine enforces protective upper bounds during MATCH evaluation to prevent excessive memory or time consumption. These are implementation-defined and surfaced via diagnostics (ExecutionGuardTrip) when tripped; partial results MAY be returned (truncated) per STEAL/NO-FORCE policy while maintaining deterministic ordering of emitted rows.

- Default `max_results`: 100_000 (bindings) — truncates result set if exceeded.
- Default `max_frontier`: 100_000 (active frontier nodes / partial paths in BFS for variable-length expansions) — halts further expansion when exceeded.
- Default `max_hops_limit`: 64 (upper bound on variable-length traversal hops) — guards against unbounded or accidental large expansions when query-specified upper bound is higher or absent.
- Diagnostic code: `ExecutionGuardTrip` (maps to internal engine guard; reported with ISO precedence rules alongside any additional statuses).
- Policy: Guard trip preserves already produced bindings (up to truncation) and sets deterministic ordering via existing ordering key comparator.
- Override (future): Environment or session parameters (flagger will emit findings when overridden; not yet exposed in v0.15.0).

Rationale: Provides predictable resource ceilings and governance evidence (CANARY) for controlled execution of bounded quantifiers and high fan-out graphs.

// CANARY: REQ=REQ-GQL-017; FEATURE="MatchSafetyGuardsPolicy"; ASPECT=Docs; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_017_MatchGuardTrips; OWNER=engine; UPDATED=2025-09-25
// CANARY: REQ=REQ-GQL-017; FEATURE="MatchFrontierGuard"; ASPECT=Docs; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_017_MatchGuardTrips; OWNER=engine; UPDATED=2025-09-25
// CANARY: REQ=REQ-GQL-017; FEATURE="MatchResultGuard"; ASPECT=Docs; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_017_MatchGuardTrips; OWNER=engine; UPDATED=2025-09-25

## Flagger

- I:IllegalOrderKeyPolicy=ident-only
- U:US001=enforced
- U:OrderTiebreak=LexJSON
- U:PathTieBreak=UA005/UA006

## Implementation-defined

- Default collation: binary; Unicode collation optional.
- Null ordering policy: default nulls-last; nulls-first via env override.
