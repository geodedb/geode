# NEXT.md - Geode Development Roadmap

## Current Version: v0.18.0 (Released)

### ✅ Delivered in v0.18.0
- **Distributed Query Federation** - Coordinator-worker with global ORDER BY
- **S3 Cloud Backups** - Full + incremental with multipart uploads
- **CDC Webhook Hardening** - Headers, retries, DLQ, idempotency
- **CBO Small-N Calibration** - Bias fixes for <100 row datasets

## Next Version: v0.19.0 (Q4 2024)

### P0 - Security & Compliance
1. **Transparent Data Encryption (TDE)**
   - AES-256-GCM for data files and WAL
   - Key provider interface (KMS ready)
   - Target: <5% performance overhead
   - Integration with backup/restore

2. **Multi-Factor Authentication (MFA)**
   - TOTP-based 2FA
   - Admin policy controls
   - Recovery codes
   - Audit logging integration

### P1 - Performance & Scale
3. **Full-Text Search Enhancements**
   - Phrase queries with proximity operators
   - Hit highlighting with configurable fragments
   - Pluggable analyzers (language-specific)
   - BM25 scoring improvements

4. **Multi-threaded Query Execution**
   - Thread pool for parallel operators
   - Intra-query parallelism
   - Work-stealing scheduler
   - Maintain determinism for ordered queries

5. **Distributed Write Path**
   - Federation for INSERT/UPDATE/DELETE
   - Cross-shard transaction coordination
   - Conflict resolution strategies
   - Global consistency guarantees

### P2 - Developer Experience
6. **Schema Evolution**
   - Online DDL operations
   - Backward-compatible migrations
   - Version tracking
   - Rollback capabilities

7. **Query Performance Insights**
   - Query plan cache statistics
   - Slow query log with analysis
   - Index recommendations
   - Workload replay tools

## Future Versions (2025+)

### v0.20.0 - Cloud Native
- **Kubernetes Operator**
- **Cloud Storage Native** (beyond S3)
- **Auto-scaling** based on workload
- **Multi-region replication**

### v0.21.0 - AI/ML Integration
- **Vector Search** capabilities
- **Graph Neural Network** support
- **Embeddings** as first-class citizens
- **ML model serving** within queries

### v0.22.0 - Advanced Analytics
- **Temporal Graphs** with time-travel
- **Graph OLAP** operations
- **Streaming Analytics** on CDC
- **Approximate algorithms** for scale

## Technical Debt & Maintenance

### Ongoing Work
- **Test Coverage**: Maintain 100% claimed feature coverage
- **Performance**: Sub-linear scaling to 1B edges
- **Documentation**: API references, tutorials, examples
- **Client Libraries**: Python, Java, JavaScript SDKs

### Infrastructure
- **CI/CD**: Faster test runs (<5 min)
- **Benchmarking**: Automated regression detection
- **Release**: Semantic versioning, changelog automation
- **Monitoring**: Built-in metrics, tracing, profiling

## Research & Innovation

### Active Research
- **Incremental View Maintenance** algorithms
- **Adaptive Query Optimization** with ML
- **Graph Compression** techniques
- **Differential Privacy** for graph queries

### Standards Participation
- ISO/IEC 39075 (GQL) working group
- OpenCypher compatibility
- Apache Arrow integration
- GraphBLAS compliance

## Community Roadmap

### Developer Ecosystem
- Plugin architecture for custom functions
- Extension marketplace
- Community operators library
- Integration templates (Kafka, Spark, etc.)

### Educational
- Graph database course materials
- Interactive tutorials
- Certification program
- Conference talks and workshops

## Success Metrics

### v0.19.0 Targets
- TDE overhead: <5% on OLTP workload
- MFA adoption: 50% of production deployments
- FTS performance: 100K docs/sec indexing
- Thread scaling: Linear to 8 cores

### Long-term Goals
- Market position: Top 5 graph databases
- Community: 10K+ GitHub stars
- Production: 100+ enterprise deployments
- Performance: #1 in LDBC benchmarks

## Decision Log

### v0.18.0 Decisions
- **Federation before sharding**: Read path first, write path in v0.19
- **S3 before other clouds**: Most requested, others follow same pattern
- **CBO off by default**: Stability over performance until v0.19
- **No breaking changes**: Smooth upgrade path from v0.17

### v0.19.0 Decisions (Proposed)
- **TDE mandatory**: Security by default
- **MFA optional**: Adoption gradual
- **Threading conservative**: Opt-in per query
- **Write federation experimental**: Flag-gated

## Dependencies

### External
- Zig 0.15.1 (considering 0.16.0 for v0.19)
- QUIC library (vendored)
- S3 SDK (minimal implementation)

### Internal
- Status generator (maintain 0% untested)
- CANARY markers (full coverage)
- Benchmark suite (no regressions)

## Risk Management

### v0.19.0 Risks
1. **TDE Performance**: Mitigation - extensive benchmarking
2. **Thread Safety**: Mitigation - race detector, stress tests
3. **API Stability**: Mitigation - deprecation policy
4. **Backward Compatibility**: Mitigation - upgrade tests

### Contingency Plans
- Feature flags for risky changes
- Canary deployments
- Rollback procedures
- Performance escape hatches

## Release Schedule

- **v0.18.0**: ✅ Released (Sept 2024)
- **v0.19.0**: Target Dec 2024
- **v0.20.0**: Target Mar 2025
- **v0.21.0**: Target Jun 2025

## How to Contribute

1. Check GitHub issues tagged "good first issue"
2. Review the CONTRIBUTING.md guide
3. Join Discord for discussion
4. Submit PRs with tests and benchmarks
5. Help with documentation and examples

## Contact

- GitHub: github.com/your-org/geode
- Discord: discord.gg/geode
- Email: [email protected]