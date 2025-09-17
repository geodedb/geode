# NEXT — Execution‑Ready Backlog

Each task lists: Why • What • Acceptance • ISO Anchors • Deps • Scope (S/M/L) • DRI. Swimlanes: Now / Next / Later. All acceptance include concrete GQL plus expected result shape or diagnostic.

## Now (P0) - Critical Gaps

- Status: **BLOCKED** - Core graph features missing. These must be addressed before claiming GQL conformance.

1. **MATCH Pattern Execution (REQ-GQL-014)**
   - **Why**: Cannot claim GQL conformance without basic graph pattern matching - this is the fundamental feature
   - **What**: Implement NodeScan and basic edge traversal in evaluateSimpleQuery; map MATCH AST to execution operators
   - **Acceptance**: `MATCH (n) RETURN n` returns all nodes; `MATCH (n)-[r]->(m) RETURN n, m` returns connected node pairs
   - **ISO**: 14.4, 22
   - **Deps**: src/server/main.zig, src/exec.zig, storage adjacency
   - **Scope**: L
   - **DRI**: core

2. **Property Graph Model (REQ-GQL-017/018)**
   - **Why**: Cannot query graph data without property access and label filtering
   - **What**: Add property storage, implement property access (n.name), label predicates in NodeScan
   - **Acceptance**: `MATCH (n:Person) WHERE n.age > 30 RETURN n.name` filters by label and property
   - **ISO**: 4.3, 22
   - **Deps**: src/storage/heap.zig, src/server/main.zig
   - **Scope**: L
   - **DRI**: core

3. **Edge Traversal (REQ-GQL-016)**
   - **Why**: Graph queries require relationship traversal beyond single nodes
   - **What**: Implement Expand operator for edge traversal, CSR adjacency storage
   - **Acceptance**: `MATCH (n)-[r:KNOWS]->(m) RETURN n, r, m` traverses edges with type filtering
   - **ISO**: 22, 14.4
   - **Deps**: src/storage/csr_adjacency.zig, src/exec.zig
   - **Scope**: L
   - **DRI**: core

4. **MVCC Conflict Detection (REQ-GQL-027)**
   - **Why**: Current implementation lacks write-write conflict detection - data consistency at risk
   - **What**: Add conflict detection matrix, lock management, proper abort with 40001 status
   - **Acceptance**: Concurrent conflicting updates produce serialization failure; snapshot isolation maintained
   - **ISO**: 8
   - **Deps**: src/server/main.zig (TxnState), WAL integration
   - **Scope**: M
   - **DRI**: txn

## Next (P1) - Core Completion

1. **OPTIONAL MATCH (REQ-GQL-015)**
   - **Why**: Required for complete pattern matching with left-outer semantics
   - **What**: Implement OPTIONAL as left-outer join over pattern fragments
   - **Acceptance**: `MATCH (n) OPTIONAL MATCH (n)-[r]->(m) RETURN n, m` returns nodes with NULL for unmatched
   - **ISO**: 14.4
   - **Deps**: MATCH implementation, src/exec.zig
   - **Scope**: M
   - **DRI**: core

2. **Variable-Length Paths (REQ-GQL-016)**
   - **Why**: Enable bounded path queries with [*1..3] syntax
   - **What**: Implement PathExpand operator with BFS, bounded traversal
   - **Acceptance**: `MATCH (a)-[*1..3]->(b) RETURN a, b` returns paths up to length 3
   - **ISO**: 22.4
   - **Deps**: src/exec.zig, adjacency storage
   - **Scope**: L
   - **DRI**: core

3. **Storage Catalog Persistence (REQ-GQL-025)**
   - **Why**: No durable storage limits production use
   - **What**: Add --data_dir flag, implement catalog save/load, CSR adjacency persistence
   - **Acceptance**: Server restart preserves graph data; `--data_dir=/tmp/geode` creates persistent storage
   - **ISO**: impl-defined storage
   - **Deps**: src/storage/catalog.zig, src/storage/page_manager.zig
   - **Scope**: L
   - **DRI**: storage

4. **WITH Clause (REQ-GQL-020)**
   - **Why**: Query composition and chaining required for complex queries
   - **What**: Parse and execute WITH for intermediate projections
   - **Acceptance**: `MATCH (n) WITH n, count(*) AS c WHERE c > 1 RETURN n` chains queries
   - **ISO**: 14.5
   - **Deps**: gql/parser.zig, src/server/main.zig
   - **Scope**: M
   - **DRI**: planner

5. **Path Tie-Breaking (UA005/UA006)**
   - **Why**: Deterministic path selection required for reproducible results
   - **What**: Document and implement tie-break policy (length, start_id, end_id)
   - **Acceptance**: Multiple shortest paths return deterministic selection; policy documented
   - **ISO**: 22.4
   - **Deps**: PathExpand implementation
   - **Scope**: S
   - **DRI**: core

## Later (P2+) - Extensions

1. **Graph Mutations (REQ-GQL-019)**
   - **Why**: Complete CRUD operations for graph data
   - **What**: Implement CREATE, DELETE, MERGE statements
   - **Acceptance**: `CREATE (n:Person {name: 'Alice'})` creates node; `DELETE n` removes nodes
   - **ISO**: 15
   - **Deps**: Parser, storage layer, transaction integration
   - **Scope**: L
   - **DRI**: dml

2. **Distributed Execution (REQ-GQL-028/042/043)**
   - **Why**: Scale-out for large graphs
   - **What**: Complete Raft implementation, 2PC coordination, partition-aware planning
   - **Acceptance**: Multi-node cluster with replicated data; distributed query execution
   - **ISO**: impl-defined distribution
   - **Deps**: src/distributed/, network layer
   - **Scope**: XL
   - **DRI**: dist

3. **Advanced Path Algorithms**
   - **Why**: Shortest path, centrality, community detection
   - **What**: Implement graph algorithms as built-in functions
   - **Acceptance**: `MATCH p = shortestPath((a)-[*]-(b)) RETURN p` finds shortest path
   - **ISO**: Extensions beyond core
   - **Deps**: Path execution framework
   - **Scope**: L
   - **DRI**: algo

4. **Index Structures**
   - **Why**: Performance optimization for large graphs
   - **What**: B-tree indexes on properties, label indexes, full-text search
   - **Acceptance**: EXPLAIN shows index usage; 100x speedup on indexed lookups
   - **ISO**: impl-defined optimization
   - **Deps**: Storage layer, planner cost model
   - **Scope**: L
   - **DRI**: storage

5. **Schema Constraints**
   - **Why**: Data integrity and validation
   - **What**: Unique constraints, property existence, cardinality limits
   - **Acceptance**: `CREATE CONSTRAINT unique_name ON (n:Person) ASSERT n.name IS UNIQUE`
   - **ISO**: Extensions
   - **Deps**: Storage layer, DDL parsing
   - **Scope**: M
   - **DRI**: schema

## Documentation Updates Required

1. **README Accuracy**
   - Update to reflect actual capabilities vs aspirations
   - Remove claims of MATCH/OPTIONAL support until implemented
   - Add clear roadmap to graph database functionality

2. **Conformance Profile**
   - Mark graph features as "Planned" not "Yes"
   - Document current SQL-like subset clearly
   - Add timeline for core graph features

3. **Test Coverage**
   - Add test stubs for missing features with skip markers
   - Document why custom functions (MATCH_1HOP) exist as workarounds
   - Create acceptance test suite for graph features

## Summary (Top Risks)

1. **False Advertising** — System claims GQL conformance but lacks graph database fundamentals
2. **No Graph Execution** — MATCH patterns parsed but not executed
3. **Data Consistency** — MVCC conflicts undetected
4. **No Property Model** — Cannot access node/edge properties
5. **No Persistence** — Storage not durable

The system currently provides a **SQL-like query engine** with GQL syntax parsing but requires substantial work to become a true graph database. Priority must be on implementing core graph features (MATCH, properties, traversal) before any other enhancements.