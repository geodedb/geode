# NEXT — Execution‑Ready Backlog

Each task lists: Why • What • Acceptance • ISO Anchors • Deps • Scope (S/M/L) • DRI. Swimlanes: Now / Next / Later. All acceptance include concrete GQL plus expected result shape or diagnostic.

## Now (P0) - Critical Gaps

- Status: PARTIAL — Core graph primitives (MATCH node/edge, labels, properties) are implemented. Remaining P0 targets: OPTIONAL, variable-length paths, MVCC strengthening, persistence.

1. OPTIONAL MATCH (REQ-GQL-015)
   - Why: Required for complete pattern matching with left-outer semantics
   - What: Implement OPTIONAL as left-outer join over pattern fragments
   - Acceptance: `MATCH (n) OPTIONAL MATCH (n)-[r]->(m) RETURN n, m` returns nodes with NULL for unmatched
   - ISO: 14.4
   - Deps: MATCH implementation, src/server/graph/exec.zig, src/server/main.zig
   - Scope: M
   - DRI: core

2. Variable-Length Paths (REQ-GQL-016)
   - Why: Enable bounded path queries with [*1..3] syntax
   - What: Implement PathExpand operator with BFS, bounded traversal
   - Acceptance: `MATCH (a)-[*1..3]->(b) RETURN a, b` returns paths up to length 3
   - ISO: 22.4
   - Deps: src/server/graph/exec.zig (new PathExpand), adjacency storage
   - Scope: L
   - DRI: core

3. MVCC Conflict Detection (REQ-GQL-027)
   - Why: Strengthen write-write conflict detection and ensure proper 40001 mapping
   - What: Add conflict detection matrix, lock management, explicit error surface on conflicts
   - Acceptance: Concurrent conflicting updates produce serialization failure; snapshot isolation maintained
   - ISO: 8
   - Deps: src/server/main.zig (TxnState), src/txn/mvcc.zig, WAL integration
   - Scope: M
   - DRI: txn

4. Storage Catalog Persistence (REQ-GQL-025)
   - Why: Persist graph/catalog for production use
   - What: Wire `--data_dir`, implement catalog save/load, persist CSR adjacency and properties
   - Acceptance: Server restart preserves graph data; `--data_dir=/tmp/geode` creates persistent storage
   - ISO: impl-defined storage
   - Deps: src/storage/catalog.zig, src/storage/page_manager.zig, src/server/main.zig
   - Scope: L
   - DRI: storage

## Next (P1) - Core Completion

1. WITH Clause (REQ-GQL-020)
   - Why: Query composition and chaining required for complex queries
   - What: Parse and execute WITH for intermediate projections
   - Acceptance: `MATCH (n) WITH n, count(*) AS c WHERE c > 1 RETURN n` chains queries
   - ISO: 14.5
   - Deps: gql/parser.zig, src/server/main.zig
   - Scope: M
   - DRI: planner

2. Path Tie-Breaking (UA005/UA006)
   - Why: Deterministic path selection required for reproducible results
   - What: Document and implement tie-break policy (length, start_id, end_id)
   - Acceptance: Multiple shortest paths return deterministic selection; policy documented
   - ISO: 22.4
   - Deps: PathExpand implementation
   - Scope: S
   - DRI: core

## Later (P2+) - Extensions

1. Graph Mutations (REQ-GQL-019)
   - Why: Complete CRUD operations for graph data
   - What: Implement CREATE, DELETE, MERGE statements
   - Acceptance: `CREATE (n:Person {name: 'Alice'})` creates node; `DELETE n` removes nodes
   - ISO: 15
   - Deps: Parser, storage layer, transaction integration
   - Scope: L
   - DRI: dml

2. Distributed Execution (REQ-GQL-028/042/043)
   - Why: Scale-out for large graphs
   - What: Complete Raft implementation, 2PC coordination, partition-aware planning
   - Acceptance: Multi-node cluster with replicated data; distributed query execution
   - ISO: impl-defined distribution
   - Deps: src/distributed/, network layer
   - Scope: XL
   - DRI: dist

3. Advanced Path Algorithms
   - Why: Shortest path, centrality, community detection
   - What: Implement graph algorithms as built-in functions
   - Acceptance: `MATCH p = shortestPath((a)-[*]-(b)) RETURN p` finds shortest path
   - ISO: Extensions beyond core
   - Deps: Path execution framework
   - Scope: L
   - DRI: algo

4. Index Structures
   - Why: Performance optimization for large graphs
   - What: B-tree indexes on properties, label indexes, full-text search
   - Acceptance: EXPLAIN shows index usage; 100x speedup on indexed lookups
   - ISO: impl-defined optimization
   - Deps: Storage layer, planner cost model
   - Scope: L
   - DRI: storage

5. Schema Constraints
   - Why: Data integrity and validation
   - What: Unique constraints, property existence, cardinality limits
   - Acceptance: `CREATE CONSTRAINT unique_name ON (n:Person) ASSERT n.name IS UNIQUE`
   - ISO: Extensions
   - Deps: Storage layer, DDL parsing
   - Scope: M
   - DRI: schema

## Documentation Sync Policy

- On running docs/PROMPTS.md (ISO‑GQL Auditor), automatically:
  - Promote items in GAP_ANALYSIS.md from Not Implemented/Partial to Implemented when evidence exists in source/tests.
  - Update NEXT.md Now/Next/Later with remaining tasks only; move completed items out of TODO sections.
  - Refresh evidence pointers (file:line/test names) and ISO anchors.
  - Ensure docs/README.md Status & Conformance Summary links remain accurate.
