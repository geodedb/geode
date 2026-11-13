# GQL Conformance Profile — ISO/IEC 39075:2024

// CANARY: REQ=REQ-GQL-024; FEATURE="Conformance Profile Ledger"; ASPECT=Docs; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_ImplDefinedCollationAndNullOrdering; OWNER=docs; UPDATED=2026-02-09
// CANARY: REQ=REQ-GAP-0257-ISO-001; FEATURE="ISO Conformance Evidence"; ASPECT=Docs; STATUS=IMPL; TEST=geodetestlab/specs/gap_0257_iso_conformance_verification.yml; OWNER=docs; UPDATED=2026-02-09

This document captures Geode's conformance to the ISO/IEC 39075:2024 Graph Query Language (GQL) standard with comprehensive feature coverage and test evidence.

**Conformance Status**: 106/106 named ISO conformance-suite cases passing (`zig build test-iso-conformance`; parse-only scope)

## 1. Pattern Matching (ISO 15.1–15.3)

| Feature | ISO Clause | Status | Test Evidence |
|---------|-----------|--------|---------------|
| Node label predicate | 15.1 | Conformant | `gql_pattern_matching_comprehensive.yml` |
| Node property equality | 15.1 | Conformant | `gql_pattern_matching_comprehensive.yml` |
| Single-hop edge pattern | 15.2 | Conformant | `gql_edge_patterns.yml` |
| Bounded path expansion | 15.2 | Conformant | `gql_path_quantifier_comprehensive.yml` |
| Variable-length paths | 15.2 | Conformant | `gql_variable_length_paths.yml` |
| OPTIONAL MATCH | 15.3 | Conformant | `gql_optional_match.yml` |
| Multiple MATCH clauses | 15.1 | Conformant | `gql_pattern_matching_comprehensive.yml` |

**Implementation-defined behaviors:**

- Variable-length path maximum hops: 64 (configurable via `--match-max-frontier`)
- Shorter paths preferred in tie-break (UA005/UA006 determinism)

## 2. Data Manipulation (ISO 12.1–12.5)

| Feature | ISO Clause | Status | Test Evidence |
|---------|-----------|--------|---------------|
| INSERT node | 12.1 | Conformant | `gql_crud_operations.yml` |
| INSERT edge | 12.1 | Conformant | `gql_crud_operations.yml` |
| SET property | 12.2 | Conformant | `gql_set_properties.yml` |
| REMOVE property | 12.3 | Conformant | `gql_remove_property.yml` |
| DELETE node | 12.4 | Conformant | `gql_crud_operations.yml` |
| DELETE edge | 12.4 | Conformant | `gql_crud_operations.yml` |
| MERGE | 12.5 | Conformant | `gql_merge_operations.yml` |

## 3. Expressions (ISO 10.1–10.5)

| Feature | ISO Clause | Status | Test Evidence |
|---------|-----------|--------|---------------|
| Arithmetic (+, -, *, /) | 10.1 | Conformant | `gql_expressions_comprehensive.yml` |
| Comparison (>, <, >=, <=, =, <>) | 10.2 | Conformant | `gql_comparison_operators.yml` |
| Boolean logic (AND, OR, NOT) | 10.3 | Conformant | `gql_boolean_logic.yml` |
| CASE expression | 10.4 | Conformant | `gql_case_expression.yml` |
| NULL handling (IS NULL, IS NOT NULL) | 10.5 | Conformant | `gql_null_handling.yml` |
| String concatenation | 10.1 | Conformant | `gql_string_operations.yml` |
| COALESCE | 10.4 | Conformant | `gql_coalesce_nullif.yml` |

## 4. Type System (ISO 5.1–5.4)

| Feature | ISO Clause | Status | Test Evidence |
|---------|-----------|--------|---------------|
| INTEGER | 5.1 | Conformant | `gql_data_types.yml` |
| FLOAT | 5.1 | Conformant | `gql_data_types.yml` |
| STRING | 5.2 | Conformant | `gql_string_operations.yml` |
| BOOLEAN | 5.3 | Conformant | `gql_boolean_logic.yml` |
| NULL | 5.4 | Conformant | `gql_null_handling.yml` |
| LIST | 5.4 | Conformant | `gql_list_operations.yml` |
| MAP | 5.4 | Conformant | `gql_map_operations.yml` |

## 5. Aggregation Functions (ISO 11.1)

| Feature | ISO Clause | Status | Test Evidence |
|---------|-----------|--------|---------------|
| COUNT | 11.1 | Conformant | `gql_aggregation_queries.yml` |
| SUM | 11.1 | Conformant | `gql_aggregation_queries.yml` |
| AVG | 11.1 | Conformant | `gql_aggregation_queries.yml` |
| MIN | 11.1 | Conformant | `gql_aggregation_queries.yml` |
| MAX | 11.1 | Conformant | `gql_aggregation_queries.yml` |
| COLLECT | 11.1 | Conformant | `gql_aggregation_queries.yml` |

## 6. Set Operations (ISO 14.1)

| Feature | ISO Clause | Status | Test Evidence |
|---------|-----------|--------|---------------|
| UNION ALL | 14.1 | Conformant | `gql_set_operations.yml` |
| UNION DISTINCT | 14.1 | Conformant | `gql_set_operations.yml` |
| INTERSECT | 14.1 | Conformant | `gql_set_operations.yml` |
| EXCEPT | 14.1 | Conformant | `gql_set_operations.yml` |

## 7. Query Clauses (ISO 13.1–13.4)

| Feature | ISO Clause | Status | Test Evidence |
|---------|-----------|--------|---------------|
| WHERE | 13.1 | Conformant | `gql_where_clause.yml` |
| ORDER BY | 13.2 | Conformant | `gql_orderby_comprehensive.yml` |
| LIMIT | 13.3 | Conformant | `gql_limit_offset.yml` |
| OFFSET | 13.3 | Conformant | `gql_limit_offset.yml` |
| WITH projection | 13.4 | Conformant | `gql_with_clause.yml` |
| RETURN | 13.4 | Conformant | All query specs |

**Implementation-defined behaviors:**

- ORDER BY deterministic comparator with JSON lexicographic tie-break
- LIMIT/OFFSET without ORDER BY is ACCEPTED (US001 is not enforced; ISO leaves unordered-result ordering implementation-defined and Geode declares `UnorderedPaginationAllowed`)
- ORDER BY keys accept expressions by default (`I:PropertyOrderingEnabled`); the ident-only IllegalOrderKey policy is opt-in via `GEODE_ORDER_KEYS_EXPR=0`
- Null ordering: default nulls-last; nulls-first via env override

## 8. Transaction Management (ISO 16.1–16.3)

| Feature | ISO Clause | Status | Test Evidence |
|---------|-----------|--------|---------------|
| BEGIN | 16.1 | Conformant | `gql_transaction_handling.yml` |
| COMMIT | 16.2 | Conformant | `gql_transaction_handling.yml` |
| ROLLBACK | 16.3 | Conformant | `gql_transaction_handling.yml` |
| SAVEPOINT | 16.3 | Partial | `gql_transaction_handling.yml` |

## 9. Functions (ISO 10.6)

| Feature | ISO Clause | Status | Test Evidence |
|---------|-----------|--------|---------------|
| upper() | 10.6 | Conformant | `gql_string_operations.yml` |
| lower() | 10.6 | Conformant | `gql_string_operations.yml` |
| trim() | 10.6 | Conformant | `gql_string_operations.yml` |
| length()/size() | 10.6 | Conformant | `gql_string_operations.yml` |
| substring() | 10.6 | Conformant | `gql_string_operations.yml` |
| abs() | 10.6 | Conformant | `gql_math_functions.yml` |
| ceil()/floor() | 10.6 | Conformant | `gql_math_functions.yml` |
| id() | 10.6 | Conformant | `gql_id_function.yml` |
| labels() | 10.6 | Conformant | `gql_labels_function.yml` |
| properties() | 10.6 | Conformant | `gql_properties_function.yml` |

## 10. Session & Catalog Operations (ISO 17–18)

| Feature | ISO Clause | Status | Test Evidence |
|---------|-----------|--------|---------------|
| EXPLAIN | 17.1 | Conformant | `gql_explain_profile.yml` |
| PROFILE | 17.1 | Conformant | `gql_explain_profile.yml` |
| CREATE GRAPH | 18.1 | Conformant | `gql_catalog_operations.yml` |
| USE GRAPH | 18.1 | Conformant | `gql_catalog_operations.yml` |
| DROP GRAPH | 18.1 | Conformant | `gql_catalog_operations.yml` |
| SHOW GRAPHS | 18.1 | Conformant | `gql_catalog_operations.yml` |

## Safety Guards (Execution Limits)

The engine enforces protective upper bounds during MATCH evaluation to prevent excessive memory or time consumption. These are implementation-defined and surfaced via diagnostics (ExecutionGuardTrip) when tripped; partial results MAY be returned (truncated) per STEAL/NO-FORCE policy while maintaining deterministic ordering of emitted rows.

- Default `max_results`: 100,000 (bindings) — truncates result set if exceeded.
- Default `max_frontier`: 100,000 (active frontier nodes / partial paths in BFS for variable-length expansions) — halts further expansion when exceeded.
- Default `max_hops_limit`: 64 (upper bound on variable-length traversal hops) — guards against unbounded or accidental large expansions when query-specified upper bound is higher or absent.
- Diagnostic code: `ExecutionGuardTrip` (maps to internal engine guard; reported with ISO precedence rules alongside any additional statuses).
- Policy: Guard trip preserves already produced bindings (up to truncation) and sets deterministic ordering via existing ordering key comparator.

// CANARY: REQ=REQ-GQL-017; FEATURE="MatchSafetyGuardsPolicy"; ASPECT=Docs; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; TEST=TestCANARY_REQ_GQL_017_MatchGuardTrips; OWNER=engine; UPDATED=2025-09-25

## Transport Parity Evidence

Verified across QUIC and gRPC transports:

- Simple RETURN ordering
- Set operations DISTINCT
- Projection slices
- ORDER/LIMIT/OFFSET pagination
- MATCH variable-length expansions
- Diagnostics (US001, IllegalOrderKey)
- CASE 3VL null semantics
- Nulls-last ordering

// CANARY: REQ=REQ-GQL-017; FEATURE="Transport Parity Simple RETURN"; ASPECT=Docs; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_TransportParity_ReturnOrdered; OWNER=engine; UPDATED=2025-09-24
// CANARY: REQ=REQ-GQL-017; FEATURE="Transport Parity SetOp DISTINCT"; ASPECT=Docs; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_TransportParity_SetOpDistinct; OWNER=engine; UPDATED=2025-09-24
// CANARY: REQ=REQ-GQL-017; FEATURE="Transport Parity Projection Rows"; ASPECT=Docs; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_TransportParity_ProjectionRows; OWNER=engine; UPDATED=2025-09-24
// CANARY: REQ=REQ-GQL-017; FEATURE="Transport Parity ORDER/LIMIT/OFFSET Rows"; ASPECT=Docs; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_TransportParity_OrderPaginationRows; OWNER=engine; UPDATED=2025-09-24
// CANARY: REQ=REQ-GQL-017; FEATURE="Transport Parity MATCH VarLen Rows"; ASPECT=Docs; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_TransportParity_MatchVarLenRows; OWNER=engine; UPDATED=2025-09-24
// CANARY: REQ=REQ-GQL-017; FEATURE="VarLen Path Determinism UA005/UA006"; ASPECT=Docs; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_VarLenDeterminism_QUIC; OWNER=engine; UPDATED=2025-09-24
// CANARY: REQ=REQ-GQL-017; FEATURE="VarLen Path Determinism UA005/UA006"; ASPECT=Docs; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_017_VarLenDeterminism_GRPC; OWNER=engine; UPDATED=2025-09-24

## Policies and Diagnostics

| Policy | Status | Description |
|--------|--------|-------------|
| US001 | Not enforced | LIMIT/OFFSET without ORDER is accepted; implementation-defined ordering declared as `UnorderedPaginationAllowed` |
| IllegalOrderKey | Opt-in | ORDER BY accepts expressions by default; restricted to identifiers only under `GEODE_ORDER_KEYS_EXPR=0` |
| OrderTiebreak | LexJSON | JSON lexicographic tie-break |
| PathTieBreak | UA005/UA006 | Bounded path determinism |
| NullOrdering | Nulls-last | Implementation-defined default |

## Implementation-Defined Behaviors

- Default collation: binary; Unicode collation optional.
- Null ordering policy: default nulls-last; nulls-first via env override.
- Variable-length path max hops: 64 (configurable).
- Guard thresholds: 100,000 results, 100,000 frontier nodes.

## Environment Overrides (Test / Diagnostics)

Guard threshold overrides (test/support use only):

- Environment: `GEODE_MATCH_MAX_RESULTS` and `GEODE_MATCH_MAX_FRONTIER` lower the `max_results` and `max_frontier` guards. `geode serve` has no `--match-max-*` options (it refuses unknown options, SONNY-6442).

Production deployments SHOULD leave these unset (defaults: 100,000). Frames emitted under overridden thresholds still carry the additional status for transparency.
