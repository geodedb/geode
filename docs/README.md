# Geode Documentation

## Overview

Geode v0.16.0 is a production-ready ACID property-graph database implementing ISO/IEC 39075:2024 (GQL) with enterprise features including high availability, advanced query optimization, and comprehensive security. This documentation covers all implemented features, architecture details, and usage patterns.

### Latest Updates (January 2025)

- **Time-Series (beta)**: Native TS scaffold (in-memory Store: insertMany, last, valueBefore, timeBucketAvg); full chunked storage, GQL functions, and protocol support planned. See TIMESERIES-GEODE.md.
- **Distributed Consensus**: Full Raft implementation with automatic failover
- **Adaptive Query Execution**: Runtime optimization with plan caching
- **Recursive Queries**: WITH RECURSIVE support for graph traversals
- **Materialized Views**: Incremental refresh with dependency tracking
- **Enhanced Security**: Hierarchical multi-tenant RLS with ABAC

## Quick Start

```bash
# Build the project
make build

# Generate TLS certificates
./zig-out/bin/cert_gen

# Start server with QUIC
./zig-out/bin/geoded --listen-quic 0.0.0.0:7567

# Run a query via CLI
./zig-out/bin/geodec "MATCH (n:Person) RETURN n.name" --server 127.0.0.1:7567

# Or use the Go client
cd clients/go/gql && go run example/main.go
```

## Core Features

### Transport Layer - QUIC with TLS 1.3
- **Primary Protocol**: QUIC for multiplexed, secure communication
- **Fallback**: TCP and stdio modes for compatibility
- **Security**: TLS 1.3 with certificate generation tool
- **Client Support**: Native Go client with `quic://` DSN prefix

### Transparent Data Encryption (TDE) - Enhanced
- **Algorithm**: AES-256-GCM with authenticated encryption
- **Key Management**: 
  - Master key and data encryption keys (DEK) hierarchy
  - Online key rotation without downtime
  - KMS integration (AWS KMS, Azure Key Vault, HashiCorp Vault, Google Cloud KMS)
- **Tools**: `key_rotate` CLI for key generation, rotation, and verification
- **Coverage**: Pages, WAL records, and temporary files
- **Tests**: `zig test tests/e2e_tde_encryption.zig`

### Multi-Graph Support
- **Commands**: `CREATE GRAPH`, `DROP GRAPH`, `USE GRAPH`, `SHOW GRAPHS`
- **Isolation**: Complete namespace separation with configurable isolation levels
- **Access**: DSN-based graph selection: `geode://host:port/graph_name`
- **Default Graph**: Automatic selection when no graph specified
- **Tests**: `zig test tests/e2e_multi_graph.zig`

### Machine Learning Integration
- **Algorithms**:
  - Node2Vec for graph embeddings
  - PageRank for node importance
  - Link prediction with multiple similarity metrics
  - Community detection (Louvain, Label Propagation)
  - Node classification
- **GDS Procedures**:
  - `CALL gds.node2vec.stream()`
  - `CALL gds.linkPrediction.mutate()`
  - `CALL gds.louvain.stream()`
- **Tests**: Unit tests in `src/ml/integration.zig`

### Streaming and Change Data Capture (CDC)
- **CDC Engine**: Real-time change capture with configurable retention
- **Sinks**: Memory, File, Kafka, Kinesis, PubSub, Webhook
- **Streaming Queries**: Windowed aggregations (tumbling, sliding, session)
- **Commands**:
  - `CALL db.cdc.start()`
  - `CALL db.cdc.stop()`
  - `CALL db.cdc.status()`
- **Tests**: Unit tests in `src/streaming/cdc.zig`

### Time-Travel Queries
- **AS OF Queries**: Query data at specific timestamps or transactions
- **BETWEEN Queries**: Analyze changes over time ranges
- **Version History**: Track all modifications with configurable retention
- **Bi-temporal Support**: System time vs valid time tracking
- **Vacuum**: Automatic cleanup of old versions

### GPU Acceleration (Experimental)
- **Backends**: CUDA and OpenCL support
- **Algorithms**: Parallel PageRank, BFS, connected components
- **Memory Management**: Efficient GPU buffer allocation
- **Feature Flag**: Compile with `-Dgpu-acceleration=true`

### Advanced Query Features

#### Graph Pattern Matching
- **MATCH Patterns**: Full pattern matching with labels and properties
- **Variable-length Paths**: `[*1..5]`, `[*]` with efficient expansion
- **OPTIONAL MATCH**: Outer joins with proper NULL handling
- **Path Functions**: shortest_path, all_shortest_paths
- **Tie-breaking**: Deterministic results (UA005/UA006)

#### Aggregations and Analytics
- **Functions**: COUNT, SUM, AVG, MIN, MAX, STDEV, VARIANCE
- **GROUP BY**: Multi-column grouping with HAVING
- **Window Functions**: ROW_NUMBER, RANK, DENSE_RANK, LAG, LEAD
- **Graph Algorithms**: PageRank, community detection, centrality

#### Set Operations
- **UNION/UNION ALL**: Combine result sets
- **INTERSECT/INTERSECT ALL**: Find common results
- **EXCEPT/EXCEPT ALL**: Find differences
- **Optimizations**: Sort-merge and hash-based implementations

#### Recursive Queries (NEW)
- **WITH RECURSIVE**: Transitive closure and hierarchical queries
- **Cycle Detection**: Multiple strategies (hash-based, DFS, union-find, topological)
- **Path Enumeration**: Find all paths with depth limits
- **Memory Management**: Automatic spill to disk for large result sets
- **Search Clauses**: Breadth-first and depth-first traversal options

#### Materialized Views (NEW)
- **CREATE MATERIALIZED VIEW**: Cache expensive query results
- **Refresh Strategies**:
  - Complete refresh: Full recomputation
  - Incremental refresh: Process only changes
  - Differential refresh: Apply deltas
  - Continuous refresh: Near real-time updates
- **Dependency Tracking**: Automatic invalidation and refresh
- **Query Rewriting**: Automatic optimization to use views
- **Storage Options**: Heap, columnar, in-memory, hybrid

### Query Optimization

#### Adaptive Query Execution (NEW)
- **Runtime Optimization**: Adjust plans during execution
- **Plan Caching**: Reuse compiled plans with parameter sensitivity
- **Statistics Collection**: 
  - Table and column statistics with histograms
  - Index statistics with selectivity estimates
  - Correlation statistics between columns
- **Reoptimization Triggers**: Cardinality errors, memory pressure, data skew
- **Workload Analysis**: Query patterns and optimization opportunities

### Storage Engine

#### Page Management
- **Slotted Pages**: Efficient space utilization
- **CSR Adjacency**: Compressed sparse row for edges
- **Property Heap**: Variable-length property storage
- **Buffer Pool**: LRU with configurable size

#### WAL and Recovery
- **ARIES Protocol**: Write-ahead logging with LSNs
- **Checkpointing**: Periodic and on-demand
- **Crash Recovery**: Automatic on startup
- **Compaction**: Automatic with configurable thresholds

#### Indexing
- **B-tree Indexes**: Property value lookups
- **Full-text Search**: Text indexing with relevance scoring
- **Bitmap Indexes**: Set membership queries
- **Index Hints**: Query optimizer guidance

### Transaction Management

#### MVCC Implementation
- **Isolation Level**: Snapshot Isolation (SI)
- **Conflict Detection**: Early detection with retry
- **Lock Management**: Fine-grained locking for DML
- **Deadlock Detection**: Timeout-based resolution

#### Transaction Control
- **Commands**: BEGIN, COMMIT, ROLLBACK, SAVEPOINT
- **Modes**: READ ONLY, READ WRITE, DEFERRABLE
- **Retries**: Automatic on serialization failures
- **Monitoring**: Transaction metrics and profiling

### Distributed Features (Production-Ready)

#### Raft Consensus (Enhanced)
- **Leader Election**: Automatic failover with configurable timeouts
- **Log Replication**: Consistent state across nodes with snapshots
- **Cluster Management**: 3-node clusters with automatic failover
- **Health Monitoring**: Node failure detection and recovery
- **Commands**: Graph mutations, schema changes, configuration updates

#### Cluster Coordination
- **Node Management**: Dynamic node addition/removal
- **Shard Distribution**: Automatic shard assignment and rebalancing
- **Replica Management**: Configurable replication factor maintenance
- **Failover Handling**: Automatic promotion of replicas on node failure
- **Network Transport**: Message queue with connection management

#### Two-Phase Commit
- **Coordinator**: Transaction coordination logic
- **Participants**: Resource managers
- **Recovery**: Automatic after failures
- **Timeout Handling**: Configurable timeouts

#### Sharding
- **Strategies**: Hash-based, range-based, graph-based
- **Shard Maps**: Metadata management with key ranges
- **Rebalancing**: Automatic shard rebalancing on topology changes
- **Cross-shard Queries**: Distributed execution planning

### Security

#### Row-Level Security (Enhanced)
- **Policy Engine**: Fine-grained access control per graph/table
- **Policy Types**:
  - USING expressions for SELECT/DELETE
  - CHECK expressions for INSERT/UPDATE
  - Permissive (OR) and restrictive (AND) policies
- **Temporal Constraints**: Time-based access with recurrence rules
- **Hierarchical Multi-tenant**: Parent tenants can access child data
- **Attribute-Based Access Control (ABAC)**:
  - Dynamic attribute evaluation
  - User, resource, and environment attributes
  - Custom validators and transformers
- **Audit Logging**: Comprehensive security event tracking

#### Authentication & Authorization
- **Methods**: Password, certificate, token-based
- **Role-Based Access**: Hierarchical role system
- **Permissions**: Fine-grained operation control
- **Session Management**: Secure session handling

### Monitoring and Observability

#### Metrics
- **Types**: Counters, gauges, histograms, timers
- **Export**: Prometheus format at `/metrics`
- **Custom Metrics**: Application-specific tracking
- **Dashboards**: Grafana templates included

#### Query Profiling
- **EXPLAIN**: Query plans with cost estimates
- **PROFILE**: Runtime statistics and actual costs
- **Memory Tracking**: Allocation and peak usage
- **Spill Monitoring**: Disk usage for large operations

#### Distributed Tracing
- **OpenTelemetry**: Standard tracing protocol
- **Span Creation**: Automatic for operations
- **Context Propagation**: Across service boundaries
- **Sampling**: Configurable rates

### Developer Tools

#### CLI Tools
- `geoded` - Server daemon with hot reload
- `geodec` - Interactive query client
- `cert_gen` - TLS certificate generation
- `key_rotate` - Encryption key management
- `wal_compact` - Manual WAL compaction
- `doccheck` - Documentation validation

#### Client Libraries
- **Go Client**: Full-featured with connection pooling
- **Query Builder**: Type-safe query construction
- **Struct Scanning**: Automatic result mapping
- **Retry Logic**: Configurable backoff strategies

#### Testing Infrastructure
- **Unit Tests**: Module-level testing
- **Integration Tests**: Cross-module testing
- **E2E Tests**: Full system validation
- **Fuzz Testing**: Input validation
- **Benchmarks**: Performance tracking
- **Conformance Tests**: ISO compliance

## Documentation Structure

### Core Documentation
- [API_DOCUMENTATION.md](API_DOCUMENTATION.md) - Complete API reference
- [BINARY_PROTOCOL.md](BINARY_PROTOCOL.md) - Wire protocol specification
- [IMPLEMENTED.md](IMPLEMENTED.md) - Complete feature list
- [REQUIREMENTS.md](REQUIREMENTS.md) - System requirements

### Conformance & Standards
- [GQL_CONFORMANCE_PROFILE.md](GQL_CONFORMANCE_PROFILE.md) - ISO GQL conformance
- [CONFORMANCE_MATRIX.md](CONFORMANCE_MATRIX.md) - Feature matrix
- [GQL_ENGINE_CROSSWALK.md](GQL_ENGINE_CROSSWALK.md) - Operator mapping
- [ISO_GQL_AUDIT_SUMMARY.md](ISO_GQL_AUDIT_SUMMARY.md) - Compliance audit

### Implementation Details
- [GRAPH_EXECUTION_API.md](GRAPH_EXECUTION_API.md) - Execution engine
- [NUMERIC_PROMOTION.md](NUMERIC_PROMOTION.md) - Type system
- [PROFILING.md](PROFILING.md) - Performance analysis
- [query_engine.md](query_engine.md) - Query architecture
- [TIMESERIES-GEODE.md](TIMESERIES-GEODE.md) - Time-series research & design

### Development
- [FILE_INVENTORY.md](FILE_INVENTORY.md) - Code organization
- [GAP_ANALYSIS.md](GAP_ANALYSIS.md) - Feature gaps
- [NEXT.md](NEXT.md) - Roadmap
- [PROPOSED_NEXT_STEPS.md](PROPOSED_NEXT_STEPS.md) - Priorities

### Research Papers
- MVCC conflict detection strategies
- Graph-specific MVCC patterns
- Transaction conflict resolution
- Distributed graph processing

## Performance Characteristics

- **Throughput**: ≥50k simple expands/sec on 1M edges
- **Memory**: ≤512 MiB RSS for standard workloads
- **Latency**: Sub-millisecond indexed lookups
- **Recovery**: <30s for 1GB WAL
- **Scalability**: Linear with CPU cores (read-heavy)

## System Requirements

- **OS**: Linux x86_64 (primary), macOS, Windows (experimental)
- **Memory**: Minimum 2GB, recommended 8GB+
- **Storage**: SSD recommended for production
- **Network**: 1Gbps+ for distributed deployments
- **Zig**: Version 0.15.1 for building

## Testing

```bash
# Run all tests
make test

# Run specific test suite
zig test tests/e2e_protocol.zig

# Run benchmarks
./zig-out/bin/bench

# Run fuzz tests
./zig-out/bin/fuzz

# Run Go client tests
make go-test
```

## Configuration

### Environment Variables
- `GEODE_DATA_DIR` - Data directory path
- `GEODE_LOG_LEVEL` - Logging verbosity
- `GEODE_DISK_ENCRYPTION` - Enable TDE
- `GEODE_DISK_KEY_HEX` - Encryption key
- `GEODE_WAL_ENCRYPTION` - WAL encryption
- `GEODE_MEMORY_LIMIT` - Memory governor limit
- `GEODE_SPILL_THRESHOLD` - Spill-to-disk threshold

### Server Flags
- `--listen-quic` - QUIC listener address
- `--listen-tcp` - TCP listener address
- `--data-dir` - Data directory
- `--log-json` - JSON logging
- `--result-format` - Output format (json/txt)

## License

MIT License - See [LICENSE](../LICENSE) for details.

## Support

- GitHub Issues: Report bugs and request features
- Documentation: This directory
- Examples: [/examples](../examples/) directory
- Community: Discord and forums (coming soon)

## Version History

### v0.15.0 (December 2024)
- Full ACID graph database
- ISO GQL conformance
- QUIC transport layer
- MVCC transactions
- Cost-based optimizer
- ML integration
- CDC and streaming
- Multi-graph support
- TDE with KMS
- GPU acceleration (experimental)

### Roadmap
- v0.16.0: Multi-node distribution activation
- v0.17.0: Advanced GQL features (recursive queries)
- v0.18.0: Online schema changes
- v0.19.0: Incremental view maintenance
- v1.0.0: Production-ready release