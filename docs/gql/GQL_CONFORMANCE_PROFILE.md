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

## Flagger

- I:IllegalOrderKeyPolicy=ident-only
- U:US001=enforced
- U:OrderTiebreak=LexJSON
- U:PathTieBreak=UA005/UA006

## Implementation-defined

- Default collation: binary; Unicode collation optional.
- Null ordering policy: default nulls-last; nulls-first via env override.
