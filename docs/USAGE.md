# Geode Usage Guide - v0.17.0

## Transport: QUIC/TLS 1.3 (Mandatory)

As of v0.17.0, Geode uses QUIC with TLS 1.3 as the **only** network transport. TCP code has been completely eliminated from the codebase.

**Key v0.17.0 Changes:**
- Complete MATCH/DML implementation with RLS enforcement
- Cost-Based Optimizer v1 (enable with GEODE_ENABLE_CBO=1)
- CDC external sinks (Kafka/Webhook) with at-least-once delivery
- Raft persistence with snapshots and dynamic membership
- Graph algorithms: shortestPath() and pageRank() functions
- Port 8443 is mandatory for QUIC+TLS

### Server

```bash
# Start server with QUIC (default port 8443)
./zig-out/bin/geoded --data_dir ./data --log_json
# Auto-generates self-signed certificates if missing in certs/

# Custom certificates (optional)
./zig-out/bin/geoded --cert path/to/cert.pem --key path/to/key.pem

# Multi-node cluster (v0.17.0 - persistent Raft with dynamic membership)
./zig-out/bin/geoded --node-id 1 --port 8443 --peers 2:8444,3:8445 --data_dir ./node1

# Or use the test script for 3-node cluster
sh scripts/cluster_spawn.sh
```

### Client

```bash
# Connect using QUIC (v0.17.0 - only option)
./zig-out/bin/geodec "RETURN 1 AS x" --server 127.0.0.1:8443

# Complex MATCH with nested OPTIONAL
./zig-out/bin/geodec "MATCH (p:Person)-[:KNOWS*1..3]->(f) OPTIONAL MATCH (p)-[:WORKS_AT]->(c) RETURN p, f, c"

# DML operations
./zig-out/bin/geodec "INSERT (:Person {name: 'Alice', age: 30})"
./zig-out/bin/geodec "UPDATE (p:Person {name: 'Alice'}) SET p.age = 31"

# Graph algorithms
./zig-out/bin/geodec "MATCH (a), (b) WHERE a.id = 1 AND b.id = 10 RETURN shortestPath((a)-[*]-(b))"
./zig-out/bin/geodec "MATCH (n) RETURN n.name, pageRank(n) AS rank ORDER BY rank DESC"

# Process mode (stdio)
./zig-out/bin/geodec "RETURN 1 AS x" --process ./zig-out/bin/geoded
```

### Go Client

```go
// Connect using QUIC
db, _ := gql.Open("quic:127.0.0.1:8443")

// Connect using process mode
db, _ := gql.Open("process:./zig-out/bin/geoded")
```

Flags (subset):

- --ast | --ast-json | --ast-json-verbose
- --strict-order-keys | --ident-order-only | --forbid-orderby-calls | --forbid-orderby-paths
- --normalize-temporals | --clamp-frac <0-9> | --session-offset <Z|+HH[:MM]|-HH[:MM]>
- Demos:
  - --demo-sort: Sorts sample temporal rows using first ORDER BY key in the query file.
  - --demo-setops: Shows UNION/INTERSECT/EXCEPT ALL/DISTINCT semantics over sample rows.
  - --bench-setops: Micro-benchmark for UNION DISTINCT thresholded path.
  - --bench-eval: Micro-benchmarks for regex (=~) and IN/NOT IN evaluation.
  - --demo-eval: Evaluates WHERE and RETURN on a small synthetic rowset with identifiers a (Int) and s (Str).
  - --demo-diagnostics: Runs the planner and prints diagnostic codes for certain legality errors.
  - --demo-agg: Runs a tiny grouping demo over (name:str, val:int|null) using GROUP BY and aggregates in the query.
  - --param name=value: Bind a parameter for $name in the query (repeatable). Values: unquoted digits -> Int; "true"/"false" -> Bool; "null" -> NULL; otherwise String. Quotes around value are optional for strings.

Examples

- gql --ast examples/q1.gql
- gql --session-offset +02 --demo-sort examples/order_by_temporal.gql
- gql --demo-eval examples/eval_where_return.gql
- gql --demo-diagnostics examples/offset_without_order.gql
- gql --demo-eval --param prefix=Al --param limit=10 examples/params_example.gql
- gql --demo-agg examples/group_by_demo.gql

Demo: evaluator recipes

See `docs/TELEMETRY.md` for details. Quick example to enable paging telemetry:

- Basic WHERE and RETURN with identifiers a (Int) and s (Str):
  - Query: MATCH (n) WHERE s STARTS WITH "A" AND a = "42" RETURN CASE WHEN a IN ["41", "42"] THEN s ELSE "x" END
  - Run: gql --demo-eval examples/eval_where_return.gql
- IN and NOT IN with NULL semantics:
  - Query: MATCH (n) WHERE a NOT IN [1, null, 3] RETURN n
  - Note: If any NULL is present and there is no match, the result is NULL (unknown) for NOT IN.
- Mixed-type equality policy:

Parameters

- Use $name inside expressions: WHERE n.name STARTS WITH $prefix AND n.age = $age
- Bind with --param on CLI (demo-eval): --param prefix=Al --param age=21
  Embedding (ParamBindings)

- In host code, you can pass parameters to the evaluator with ParamBindings and makeEnv:
  - geode.lib.ParamBindings{ .names = &.{"age","prefix"}, .values = &.{ .{ .Int = 21 }, .{ .Str = "Al" } } }
  - geode.lib.makeEnv(&.{"a","s"}, &.{ .{ .Int = 1 }, .{ .Str = "Alice" } }, params)
  - Then call eval.evalExpr(allocator, expr, env)

## Policies

- Equality casting
  - Int vs Str: compare decimal forms
    - 7 = "7" → true
    - 7 = "007" → false
  - Int vs Str ordering (<, <=, >, >=): illegal (TypeMismatch)
- NULL behavior
  - IN: value NULL → NULL; list contains NULL and no match → NULL; match present → true
  - NOT IN: logical negation of IN when boolean; NULL stays NULL

Aggregation and path tie-break

- GROUP BY legality (phase 1/2): Non-aggregated SELECT items must belong to grouped keys (ident or member). HAVING must use aggregates or grouped keys.
- Path search tie-break (UA005/UA006): Shorter paths first; then lexicographic by node-id sequence.
- Demo: --demo-agg reads aggregates from RETURN (COUNT/SUM/MIN/MAX) and prints grouped results over a sample table.

## Troubleshooting

- TypeMismatch: shown when ordering compares incompatible types (e.g., Int vs Str). In CLI diagnostics, this may be surfaced as a parser/planner policy violation if applicable; otherwise reported as a runtime/evaluator error.
- Illegal ORDER BY key: enable flags to control strictness:
  - --strict-order-keys, --ident-order-only, --forbid-orderby-calls, --forbid-orderby-paths
    The CLI maps these to the IllegalOrderKey diagnostic when violated.

## Telemetry (optional)

For development and ops observability, you can enable paging telemetry on the server and optionally have the client forward it:

- Set `GEODE_TELEMETRY_PAGING=1` to emit one JSON line per `PULL` page on server `stderr`.
- Set `GEODE_CAPTURE_SERVER_STDERR=1` to have `geodec` capture and forward the server's `stderr` to the client's `stderr`.

See `docs/TELEMETRY.md` for event shape and examples. In CI, telemetry smoke runs in soft mode by default; strict mode is opt-in.

Quick smoke (local):

```bash
make quic-smoke       # non-fatal, convenience
make quic-smoke-strict # strict, fails on missing telemetry or QUIC smoke issues
```
