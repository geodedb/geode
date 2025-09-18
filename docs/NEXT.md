# NEXT — Execution‑Ready Backlog

Each task lists: Why • What • Acceptance • ISO Anchors • Deps • Scope (S/M/L) • DRI. Swimlanes: Now / Next / Later. All acceptance include concrete GQL plus expected result shape or diagnostic.

## Now (P0) - Critical Gaps

- Status: All core features implemented. Database is production-ready with complete graph operations, monitoring, and scaling.

*No critical gaps remaining - all P0 items completed*

## Next (P1) - Enhancements

1. **TDE Hardening (At Rest)** (REQ-GQL-046)
   - Why: Strengthen crypto and compliance; production readiness
   - What: Upgrade cipher to AES-256-GCM; add online/offline re-encryption tool; optional KMS integration and key provenance
   - Acceptance: AES-256-GCM used for pages+WAL; rotation without data exposure; recovery validated with encrypted WAL
   - ISO: Security (impl-defined)
   - Deps: Page manager/WAL crypto layer, key management interface
   - Scope: M
   - DRI: security

2. **Multi-Graph Support** (REQ-GQL-047)
   - Why: Multi-tenant and workload isolation; modeling separate graph spaces
   - What: Catalog-level multiple graphs; `CREATE GRAPH`, `DROP GRAPH`, `USE GRAPH` semantics; isolation in planner/executor
   - Acceptance: Graph selection via CLI/DSN; isolation validated by E2E tests
   - ISO: 4.3 (graph model), 14 (semantics)
   - Deps: Catalog, planner context, storage namespaces
   - Scope: M
   - DRI: catalog

3. **Machine Learning Integration** (REQ-GQL-041)
   - Why: Graph neural networks and embeddings
   - What: Built-in ML operators for node classification, link prediction
   - Acceptance: `CALL gds.node2vec.stream()` returns embeddings
   - ISO: Extensions
   - Deps: ML framework integration
   - Scope: XL
   - DRI: ml

4. **Streaming and CDC** (REQ-GQL-042)
   - Why: Real-time data processing
   - What: Change data capture, streaming queries, Kafka integration
   - Acceptance: `CALL db.cdc.start()` enables change streaming
   - ISO: Extensions
   - Deps: Event streaming infrastructure
   - Scope: L
   - DRI: streaming

5. **Time-Travel Queries** (REQ-GQL-045)
   - Why: Historical analysis and auditing
   - What: Temporal versioning, AS OF queries
   - Acceptance: `MATCH (n) AS OF TIMESTAMP '2024-01-01'` returns historical state
   - ISO: Temporal extensions
   - Deps: Temporal storage, MVCC extensions
   - Scope: L
   - DRI: temporal

6. **GPU Acceleration** (REQ-GQL-040)
   - Why: Massive parallelization for graph algorithms
   - What: CUDA/OpenCL integration for path algorithms and analytics
   - Acceptance: 10x+ speedup on large graph traversals
   - ISO: impl-defined optimization
   - Deps: GPU libraries, memory management
   - Scope: XL
   - DRI: gpu

## Later (P2+) - Future Extensions

1. **Graph Visualization** (REQ-GQL-043)
   - Why: Interactive exploration of graph data
   - What: Built-in visualization server with WebGL rendering
   - Acceptance: Web UI shows interactive graph visualization
   - ISO: impl-defined tooling
   - Deps: Web framework, rendering engine
   - Scope: L
   - DRI: viz

2. **Multi-Model Support** (REQ-GQL-044)
   - Why: Support document and key-value workloads
   - What: JSON document storage, key-value API
   - Acceptance: Store and query JSON documents alongside graph
   - ISO: Extensions
   - Deps: Storage layer extensions
   - Scope: XL
   - DRI: multimodel

## Documentation Sync Policy

- Completed items should be moved to docs/IMPLEMENTED.md with full details
- GAP_ANALYSIS.md tracks requirement status with evidence
- This file (NEXT.md) only contains pending work
- README.md provides high-level status summary

## Completion Criteria

For an item to be considered complete and moved to IMPLEMENTED.md:
1. Code implementation in appropriate src/ files
2. Test coverage in tests/ directory
3. Documentation updates
4. Performance validation where applicable
5. Integration with existing systems
