# NEXT — Execution‑Ready Backlog

Each task lists: Why • What • Acceptance • ISO Anchors • Deps • Scope (S/M/L) • DRI. Swimlanes: Now / Next / Later. All acceptance include concrete GQL plus expected result shape or diagnostic.

## Completed (December 2024)

The following P1 features have been completed and moved to production:

### ✅ TDE Hardening (REQ-GQL-046)
- **Implemented**: AES-256-GCM, KMS integration (AWS/Azure/HashiCorp/Google), online key rotation
- **Files**: `src/storage/crypto_enhanced.zig`, `tests/e2e_tde_encryption.zig`
- **Status**: Production-ready with audit logging

### ✅ Multi-Graph Support (REQ-GQL-047)
- **Implemented**: CREATE/DROP/USE GRAPH, namespace isolation, DSN-based selection
- **Files**: `src/storage/multi_graph.zig`, `tests/e2e_multi_graph.zig`
- **Status**: Complete with cross-graph access control

### ✅ Machine Learning Integration (REQ-GQL-041)
- **Implemented**: Node2Vec, PageRank, Louvain, link prediction, GDS procedures
- **Files**: `src/ml/integration_enhanced.zig`, `tests/e2e_ml_integration.zig`
- **Status**: Full GDS-compatible interface

### ✅ Streaming and CDC (REQ-GQL-042)
- **Implemented**: Real-time CDC, multiple sinks, windowed queries
- **Files**: `src/streaming/cdc_enhanced.zig`, `tests/e2e_cdc_streaming.zig`
- **Status**: Production-ready with Kafka/Kinesis support

### ✅ Time-Travel Queries (REQ-GQL-045)
- **Implemented**: AS OF/BETWEEN queries, bi-temporal support, versioning
- **Files**: `src/temporal/time_travel.zig` (enhanced)
- **Status**: Complete with retention policies

### ✅ GPU Acceleration (REQ-GQL-040)
- **Implemented**: CUDA/OpenCL backends, parallel algorithms, 10-100x speedup
- **Files**: `src/gpu/acceleration.zig` (enhanced)
- **Status**: Feature-flagged, production-ready

## Now (P0) - Critical Gaps

- Status: **All core features implemented**. Database is production-ready with complete graph operations, monitoring, and scaling.

*No critical gaps remaining - all P0 items completed*

## Next (P1) - Production Hardening

1. **Distributed Activation** (REQ-GQL-048)
   - Why: Enable multi-node deployment for high availability
   - What: Activate Raft consensus, enable leader election, test failover
   - Acceptance: 3-node cluster with automatic failover
   - ISO: impl-defined clustering
   - Deps: Raft implementation (exists), network layer
   - Scope: L
   - DRI: distributed

2. **Advanced Query Optimization** (REQ-GQL-049)
   - Why: Improve performance for complex queries
   - What: Adaptive query execution, runtime statistics, plan caching
   - Acceptance: 2x performance improvement on TPC-H style queries
   - ISO: impl-defined optimization
   - Deps: Query planner, statistics collector
   - Scope: L
   - DRI: planner

3. **Recursive Queries** (REQ-GQL-050)
   - Why: Support transitive closure and hierarchical queries
   - What: WITH RECURSIVE clause, path enumeration
   - Acceptance: `WITH RECURSIVE` finds all paths
   - ISO: 14.5 (recursive queries)
   - Deps: Planner extensions, executor support
   - Scope: M
   - DRI: query

4. **Materialized Views** (REQ-GQL-051)
   - Why: Cache expensive query results
   - What: CREATE MATERIALIZED VIEW, refresh strategies
   - Acceptance: Views auto-refresh on data changes
   - ISO: Extensions
   - Deps: Storage layer, dependency tracking
   - Scope: L
   - DRI: views

5. **Row-Level Security** (REQ-GQL-052)
   - Why: Fine-grained access control for multi-tenant
   - What: Security policies per table/graph
   - Acceptance: Users see only authorized data
   - ISO: Security extensions
   - Deps: Auth system, policy engine
   - Scope: L
   - DRI: security

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

3. **Federated Queries** (REQ-GQL-053)
   - Why: Query across multiple Geode instances
   - What: Distributed query planning and execution
   - Acceptance: JOIN across remote graphs
   - ISO: Extensions
   - Deps: Network protocol, distributed planner
   - Scope: XL
   - DRI: federation

4. **AutoML Integration** (REQ-GQL-054)
   - Why: Automatic model selection and tuning
   - What: AutoML for graph algorithms
   - Acceptance: System auto-selects best ML algorithm
   - ISO: Extensions
   - Deps: ML framework, model registry
   - Scope: XL
   - DRI: automl

5. **Quantum-Resistant Crypto** (REQ-GQL-055)
   - Why: Future-proof against quantum attacks
   - What: Post-quantum cryptography algorithms
   - Acceptance: NIST-approved PQC algorithms
   - ISO: Security extensions
   - Deps: Crypto libraries
   - Scope: M
   - DRI: crypto

## Performance Targets (Q1 2025)

| Metric | Current | Target | Method |
|--------|---------|--------|--------|
| QPS (single node) | 70k | 100k | Query optimization |
| P99 Latency | 2ms | <1ms | Index improvements |
| Node capacity | 10M | 100M | Storage optimization |
| Concurrent connections | 1k | 10k | Connection pooling |
| Recovery time | 30s | <10s | Parallel recovery |

## Testing Requirements

For new features to be considered complete:
1. Unit tests with >90% coverage
2. Integration tests with real scenarios
3. Performance benchmarks
4. Fuzz testing where applicable
5. Documentation with examples

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
5. Security review for sensitive features

## Risk Mitigation

### Technical Risks
- **Distributed complexity**: Phased rollout, extensive testing
- **Performance regression**: Continuous benchmarking
- **Security vulnerabilities**: Regular audits, quick patches

### Resource Risks
- **Developer bandwidth**: Prioritize P1 items
- **Testing infrastructure**: Invest in CI/CD
- **Documentation debt**: Maintain as we go

## Success Metrics

### Q1 2025 Goals
- 100% P1 feature completion
- 99.99% availability in production
- <24hr security patch turnaround
- 1000+ GitHub stars
- 10+ production deployments

### Q2 2025 Goals
- Multi-region deployment capability
- Enterprise support offering
- Cloud marketplace listings
- Certification (SOC2, ISO 27001)
- 50+ production deployments

## Conclusion

With the completion of all P1 advanced features in December 2024, Geode has achieved production readiness with enterprise-grade capabilities. The focus now shifts to:

1. **Activation**: Enable distributed features
2. **Optimization**: Achieve performance targets
3. **Hardening**: Enterprise security and compliance
4. **Ecosystem**: Client libraries and tools
5. **Adoption**: Production deployments

The roadmap prioritizes stability and performance over new features, ensuring Geode becomes the trusted choice for production graph workloads.