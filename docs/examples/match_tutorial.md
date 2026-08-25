# MATCH Subset Tutorial (Geode)

// CANARY: REQ=REQ-GQL-017; FEATURE="MatchTutorial"; ASPECT=Docs; STATUS=TESTED; TEST=geodetestlab/specs/gql_pattern_matching_comprehensive.yml; TEST=TestCANARY_REQ_GQL_017_E2EMatchBasic; OWNER=docs; UPDATED=2025-09-24

This short tutorial demonstrates the currently supported MATCH subset in Geode, with deterministic ordering and pagination policies.

## Prerequisites

- Build Geode with Zig 0.15.1

```bash
zig build -Doptimize=ReleaseSafe
```

- Start the server (QUIC):

```bash
./zig-out/bin/geode serve --listen-quic 127.0.0.1:7567 --log_json --result-format json
```

## Basic Pattern: Single Hop

Graph assumptions: a small `Person` graph is available via in-memory defaults or examples (see repo examples). Query:

```gql
MATCH (a:Person {age: 30})-[:KNOWS]->(b:Person) RETURN a.id AS a, b.id AS b ORDER BY a, b
```

Example with CLI:

```bash
./zig-out/bin/geode query "MATCH (a:Person {age: 30})-[:KNOWS]->(b:Person) RETURN a.id AS a, b.id AS b ORDER BY a, b" --format json
```

Output (rows are deterministically ordered):

```json
{"a":1,"b":2}
{"a":2,"b":3}
```

## Bounded Variable-Length

Bounded paths with deterministic tie-break (UA005/UA006): shorter paths first, then bound IDs, then JSON-lex row key.

```gql
MATCH (a:Person)-[:KNOWS*1..2]->(b:Person)
RETURN a.name AS a, b.name AS b
ORDER BY a, b
LIMIT 3
```

CLI:

```bash
./zig-out/bin/geode query "MATCH (a:Person)-[:KNOWS*1..2]->(b:Person) RETURN a.name AS a, b.name AS b ORDER BY a, b LIMIT 3" --format json
```

## OPTIONAL MATCH (subset)

OPTIONAL preserves nulls when the optional branch has no match.

```gql
MATCH (a:Person {name: 'Alice'})
OPTIONAL MATCH (a)-[:KNOWS]->(b:Person)
RETURN a.name AS a, b.name AS b
ORDER BY a, b
```

## Pagination Policy (US001 — not enforced)

`LIMIT`/`OFFSET` without `ORDER BY` is **accepted**. ISO/IEC 39075:2024 leaves the
ordering of an unordered result set implementation-defined, so Geode does not
raise a diagnostic; instead it declares `UnorderedPaginationAllowed` in its
implementation-defined flagger report. This succeeds with `status_class` 00000:

```gql
RETURN 1 LIMIT 10 OFFSET 5
```

Because the row order is implementation-defined, results are **not** guaranteed
to be stable across executions — add `ORDER BY` whenever you need a repeatable
page. An opt-in strict mode (`ExecutionContext.strict_offset_validation`) exists
as a seam for a future configurable policy but is not wired.

## Transports and Parity

- QUIC and gRPC are supported (protobuf wire format).
- Determinism and results are validated by transport parity tests.

Run a single parity test (example):

```bash
zig test tests/e2e_protocol_transport_parity_match_varlen_rows.zig
```

## Notes

- MATCH semantics are partial; advanced features (chained OPTIONAL over varlen, complex property predicates on varlen) are in progress.
- Default collation is binary; nulls sort last by default (flagger surfaces policy).
- Always include `ORDER BY` before `LIMIT/OFFSET` if you need a stable page: unordered pagination is legal (US001 is not enforced) but its row order is implementation-defined.
- Safety guards: max_results=100k, max_frontier=100k, max_hops_limit=64 (diagnostic `ExecutionGuardTrip` if tripped; partial results possible).
- Deterministic ordering comparator: variable names asc → structural ids (node/edge) → path length + path nodes (lex order).
