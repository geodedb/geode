# NEXT — Execution‑Ready Backlog

Each task lists: Why • What • Acceptance • ISO Anchors • Deps • Scope (S/M/L) • DRI. Swimlanes: Now / Next / Later. All acceptance include concrete GQL plus expected result shape or diagnostic.

## Recently Completed (December 2024)

✅ **OPTIONAL MATCH** (REQ-GQL-015)
- Implemented left-outer join semantics with NULL preservation
- Location: src/server/graph/exec.zig:executeOptionalMatch

✅ **Variable-Length Paths** (REQ-GQL-016)  
- Implemented PathExpand with bounded BFS traversal
- Location: src/server/graph/exec.zig:pathExpand

✅ **MVCC Conflict Detection** (REQ-GQL-027)
- Comprehensive conflict matrix with ISO 40001 mapping
- Location: src/server/txn/mvcc.zig:detectConflict

✅ **Storage Catalog Persistence** (REQ-GQL-025)
- Graph persistence with --data_dir integration
- Location: src/storage/catalog.zig:GraphMetadata

✅ **WITH Clause** (REQ-GQL-020)
- Implemented projection stage with aggregation support
- Location: src/server/graph/exec.zig:executeWith
- Tests: tests/e2e_with_clause.zig

✅ **Path Tie-Breaking** (UA005/UA006)
- Deterministic shortest path selection implemented
- Location: src/server/graph/exec.zig:applyPathTieBreaking
- Policy: (length, start_id, end_id, intermediate_ids)
- Tests: tests/unit_shortest_path_tiebreak.zig

## Now (P0) - Critical Gaps

- Status: Core graph primitives and query composition complete. Focus shifts to DML and advanced features.

1. Graph Mutations (REQ-GQL-019)
   - Why: Complete CRUD operations for graph data
   - What: Implement CREATE, DELETE, MERGE statements
   - Acceptance: `CREATE (n:Person {name: 'Alice'})` creates node; `DELETE n` removes nodes
   - ISO: 15
   - Deps: Parser, storage layer, transaction integration
   - Scope: L
   - DRI: dml

## Later (P2+) - Extensions

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
