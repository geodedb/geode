# MATCH Subset Tutorial (Geode)

This short tutorial demonstrates the currently supported MATCH subset in Geode, with deterministic ordering and pagination policies.

## Prerequisites

- Build Geode with Zig 0.15.1

```bash
zig build -Doptimize=ReleaseSafe
```

- Start the server (QUIC):

```bash
./zig-out/bin/geoded --listen-quic 127.0.0.1:7567 --log_json --result-format json
```

## Basic Pattern: Single Hop

Graph assumptions: a small `Person` graph is available via in-memory defaults or examples (see repo examples). Query:

```gql
MATCH (a:Person {age: 30})-[:KNOWS]->(b:Person) RETURN a.id AS a, b.id AS b ORDER BY a, b
```

Example with CLI:

```bash
./zig-out/bin/geodec "MATCH (a:Person {age: 30})-[:KNOWS]->(b:Person) RETURN a.id AS a, b.id AS b ORDER BY a, b" --format json
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
./zig-out/bin/geodec "MATCH (a:Person)-[:KNOWS*1..2]->(b:Person) RETURN a.name AS a, b.name AS b ORDER BY a, b LIMIT 3" --format json
```

## OPTIONAL MATCH (subset)

OPTIONAL preserves nulls when the optional branch has no match.

```gql
MATCH (a:Person {name: 'Alice'})
OPTIONAL MATCH (a)-[:KNOWS]->(b:Person)
RETURN a.name AS a, b.name AS b
ORDER BY a, b
```

## Pagination Policy (US001)

LIMIT/OFFSET require a stable ORDER. The following is rejected with diagnostic `US001` (anchor 16.18–16.19):

```gql
RETURN 1 LIMIT 10 OFFSET 5
```

Enable alternate policies via configuration/flagger only; default is enforced.

## Transports and Parity

- stdio (local) and QUIC (network) are supported.
- Determinism and results are validated by transport parity tests (gated by `GEODE_CI_QUIC_SMOKE=1`).

Run a single parity test (example):

```bash
GEODE_CI_QUIC_SMOKE=1 zig test tests/e2e_protocol_transport_parity_match_varlen_rows.zig
```

## Notes

- MATCH semantics are partial; advanced features (chained OPTIONAL over varlen, complex property predicates on varlen) are in progress.
- Default collation is binary; nulls sort last by default (flagger surfaces policy).
- Always include `ORDER BY` before `LIMIT/OFFSET` to avoid `US001`.
