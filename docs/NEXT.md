# NEXT — v0.16.0 Full Integration Release - Regenerated 2025-09-25

Purpose: Track immediate forward work after v0.16.0 integration. Historical content in `GAP_ANALYSIS.md` & `IMPLEMENTATION_REALITY.md`.

## v0.16.0 Integration Complete

Major milestone achieved with full system integration:
- **456 CANARY aspects tracked** (334 TESTED, 60 BENCHED, 60 IMPL, 2 STUB)
- **All compile-time feature flags removed** - unified build
- **QUIC+TLS mandatory** - TCP removed, port 8443 default, auto-generates certificates
- **All subsystems integrated** - RLS/ABAC with audit, MV, full Raft clustering, CDC, backup/restore

## Active Work (Post-v0.16.0)

| Priority | Area | Task | Rationale | Acceptance |
|----------|------|------|-----------|------------|
| P0 | GPU | Kernel execution | Move beyond detection | Single operator kernel launch + variance bench |
| P0 | Federation | Query routing | Complete federation scaffold | Router tests + shard map validation |
| P1 | Analytics | PageRank/Betweenness | Advanced graph analytics | Deterministic results + variance envelope |
| P1 | Performance | Query plan cache | Reduce planning overhead | Hit rate >90% + eviction policy test |
| P2 | Storage | Columnar format | Analytical workloads | Compression ratio >3x + scan perf bench |
| P2 | ML | Integration APIs | External model serving | Python binding + inference latency bench |

## Recently Completed (v0.16.0)

### Core Integration
- ✅ **Planner**: ORDER BY enforcement with LIMIT/OFFSET (ISO compliance)
- ✅ **Recursive CTEs**: Default-enabled with cycle detection and depth limits
- ✅ **Bounded Path Expansions**: Default-enabled with deterministic ordering
- ✅ **RLS/ABAC**: Full enforcement via planner rewrite + tuple filter with audit logging
- ✅ **MV Refresh**: Complete (atomic swap) and incremental (CDC apply) fully implemented
- ✅ **Backup/Restore**: Full + incremental with zstd compression, CRC-32 verification
- ✅ **Phantom Prevention**: Range tracking enabled by default (SERIALIZABLE)
- ✅ **QUIC+TLS**: Mandatory with auto-generated self-signed certificates
- ✅ **Raft Clustering**: Full implementation - leader election, log replication, InstallSnapshot, failover
- ✅ **Inter-node Messaging**: QUIC streams with retry logic and health checks
- ✅ **Feature Flags**: Complete removal, unified build, enforced by CI

### Testing & Tooling
- ✅ **no_feature_flags_check.py**: Enforce no compile flags (fails CI on violation)
- ✅ **status_generate.py**: Auto-generate status.csv from CANARY annotations
- ✅ **cluster_spawn.sh**: 3-node cluster testing with leader election and failover
- ✅ **Audit Logger**: JSON Lines output with PII redaction support
- ✅ **Network Transport**: Inter-node QUIC messaging with length-prefix framing
- ✅ **12 New Acceptance Tests**: Exact expected outputs for all v0.16.0 features

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