# NEXT — v0.17.0 Feature Completeness Release - Updated 2025-09-25

Purpose: Track immediate forward work after v0.17.0 feature completeness. Historical content in `GAP_ANALYSIS.md` & `IMPLEMENTATION_REALITY.md`.

## v0.17.0 Feature Completeness Achieved

Critical feature gaps closed with production-ready implementations:
- **827 CANARY aspects tracked** (generated via tools/status_generate.py)
- **Complete MATCH/DML** - Complex patterns, nested OPTIONAL, filtered variable-length paths
- **Cost-Based Optimizer v1** - Statistics registry, cardinality estimation, join reordering (gated)
- **CDC External Sinks** - Kafka and Webhook with at-least-once delivery, retry, DLQ
- **Raft Persistence** - Durable log, snapshots, compaction, dynamic membership
- **QUIC+TLS only** - Port 8443 mandatory, no TCP fallback whatsoever

## Active Work (Post-v0.17.0)

| Priority | Area | Task | Rationale | Acceptance |
|----------|------|------|-----------|------------|
| P0 | Performance | CBO Tuning | Optimize cost model calibration | Prediction accuracy >85% |
| P0 | Federation | Cross-shard joins | Complete distributed query execution | 2PC over Raft for consistency |
| P1 | Storage | Columnar format | Analytical workloads | Compression ratio >3x + scan perf bench |
| P1 | ML | Embedding support | Vector similarity search | HNSW index + recall >95% |
| P2 | Observability | OpenTelemetry | Distributed tracing | Trace propagation + sampling |
| P2 | Cloud | S3 backup | Cloud-native deployment | Multipart upload + IAM integration |

## Recently Completed (v0.17.0)

### Feature Completeness
- ✅ **MATCH Engine**: Complex patterns, nested OPTIONAL, filtered variable-length paths with cycle detection
- ✅ **WHERE Clauses**: Subqueries, IN/EXISTS/ANY/ALL predicates, correlated expressions
- ✅ **DML Operations**: INSERT/UPDATE/DELETE for nodes/edges with property management and RLS enforcement
- ✅ **Cost-Based Optimizer**: Statistics registry, histograms, cardinality estimation, left-deep join enumeration
- ✅ **CDC Sinks**: Kafka and Webhook with at-least-once delivery, exponential backoff, DLQ
- ✅ **Incremental MV**: CDC-driven delta application in addition to complete refresh
- ✅ **Raft Persistence**: Durable log with CRC, snapshots with compression, log compaction
- ✅ **Dynamic Membership**: Joint consensus for add/remove nodes without downtime
- ✅ **Graph Algorithms**: shortestPath() and pageRank() integrated as GQL functions
- ✅ **2PC over Raft**: Cross-shard transactions with replicated coordinator log
- ✅ **QUIC-only Transport**: TCP completely removed, port 8443 mandatory

### Testing & Tooling
- ✅ **no_feature_flags_check.py**: Enforce no compile flags (excludes docs, fails CI on violation)
- ✅ **status_generate.py**: Parse CANARY markers to generate docs/status.csv (827 aspects)
- ✅ **cluster_spawn.sh**: Multi-process Raft cluster with election, replication, failover testing
- ✅ **14 New E2E Tests**: ORDER BY enforcement, MATCH complex, WHERE subqueries, DML+RLS, CBO toggle, CDC sinks, MV incremental, backup/restore, Raft persistence
- ✅ **Makefile Enhanced**: New targets for status-generate, no-feature-flags, cluster-test
- ✅ **CI Integration**: Automated status generation and feature flag checking in pipeline

## Variance Policy

| Category | CV Target | p95/mean Target |
|----------|-----------|-----------------|
| Hot Path | ≤0.18 | ≤2.40 |
| Storage/WAL | ≤0.21 | ≤2.50 |
| General | ≤0.22 | ≤2.55 |
| Graph Analytics | ≤0.23 | ≤2.60 |

Exceptions require `// VARIANCE_EXCEPTION:` justification.

## Governance

```bash
# Daily checks
make governance-check           # Freshness + strict verify
tools/status_generate.py --repo . --out docs/status.csv
tools/no_feature_flags_check.py --repo .

# Nightly aggregate
make governance-aggregate       # Combined delta + pre-warn

# After changes
make update-status-hash
```

## Migration Notes (v0.15.0 → v0.16.0)

1. **Remove all feature flags from build scripts**
2. **Update ports**: 7567 → 8443 (QUIC+TLS)
3. **Add ORDER BY to queries with LIMIT/OFFSET**
4. **Review RLS policies** (now enforced by default)
5. **Ensure certs/ directory** (auto-generates if missing)

## Next Sprint Focus

### Sprint 17 (Oct 2025)
- GPU kernel execution prototype
- Federation query router completion
- PageRank implementation
- Query plan cache v1

### Sprint 18 (Oct 2025)
- Columnar storage format
- ML integration APIs
- Betweenness centrality
- Performance regression suite

## Appendix

For detailed implementation status, see:
- [GAP_ANALYSIS.md](GAP_ANALYSIS.md) - Feature gap tracking
- [IMPLEMENTATION_REALITY.md](IMPLEMENTATION_REALITY.md) - Evidence-based status
- [status.csv](status.csv) - Auto-generated CANARY report (DO NOT EDIT)

// CANARY: REQ=REQ-GQL-100; FEATURE="v0.16.0 Integration"; ASPECT=Complete; STATUS=TESTED; TEST=all_acceptance_tests; OWNER=team; UPDATED=2025-09-25