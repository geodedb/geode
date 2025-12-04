# Docker Integration Test Suite for Geode

## Overview

This document describes a comprehensive Docker-based integration testing system for Geode that runs a persistent server with multiple language client containers testing concurrently against a shared dataset.

## Architecture

```
┌─────────────────────────────────────────────────────────────────────────────┐
│                          geode-integration-network                          │
├─────────────────────────────────────────────────────────────────────────────┤
│                                                                             │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                    geode-server (Primary)                            │   │
│  │  Port: 8443/UDP (QUIC+TLS)                                          │   │
│  │  Port: 9090/TCP (Metrics)                                           │   │
│  │  Volume: geode-data:/data (Persistent)                              │   │
│  │  Health: QUIC handshake verification                                │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                              ▲                                              │
│                              │                                              │
│    ┌─────────────┬─────────────┬─────────────┬─────────────┬─────────────┐ │
│    │             │             │             │             │             │ │
│    ▼             ▼             ▼             ▼             ▼             │ │
│ ┌───────┐   ┌───────┐   ┌───────┐   ┌───────┐   ┌───────────┐           │ │
│ │  Go   │   │Python │   │ Rust  │   │  Zig  │   │GeodeTestLab│           │ │
│ │Client │   │Client │   │Client │   │Client │   │  Runner   │           │ │
│ └───────┘   └───────┘   └───────┘   └───────┘   └───────────┘           │ │
│    │             │             │             │             │             │ │
│    └─────────────┴─────────────┴─────────────┴─────────────┴─────────────┘ │
│                              │                                              │
│                              ▼                                              │
│  ┌─────────────────────────────────────────────────────────────────────┐   │
│  │                         Shared Volumes                               │   │
│  │  - logs:/logs (Per-client logging)                                  │   │
│  │  - results:/results (Test results)                                  │   │
│  │  - migrations:/migrations (Schema migrations)                       │   │
│  └─────────────────────────────────────────────────────────────────────┘   │
│                                                                             │
└─────────────────────────────────────────────────────────────────────────────┘
```

## Container Specifications

### 1. Geode Server Container (`geode-server`)

**Purpose**: Primary graph database server with persistent storage

**Configuration**:
- Base Image: `debian:bookworm-slim` with Zig runtime
- Exposed Ports: 8443/UDP (QUIC), 9090/TCP (Metrics)
- Data Volume: `/data` (persistent across runs)
- Certificate Volume: `/certs` (TLS certificates)
- Log Level: Configurable via `GEODE_LOG_LEVEL` environment variable
- Authentication: Optional via `GEODE_ENABLE_AUTH`

**Health Check**:
```bash
geode query "RETURN 1 AS health" --server localhost:8443 --insecure
```

### 2. GeodeTestLab Container (`geodetestlab`)

**Purpose**: Run comprehensive black-box integration tests

**Configuration**:
- Base Image: `python:3.11-slim`
- Test Specs: All specs from `geodetestlab/specs/`
- Output: JSON reports to `/results/geodetestlab/`
- Logs: `/logs/geodetestlab/`

**Test Categories**:
- GQL Compliance (ISO/IEC 39075:2024)
- QUIC Transport
- Authentication & Security
- Graph Algorithms
- Performance Stress Tests
- Advanced Type Operations

### 3. Go Client Container (`client-go`)

**Purpose**: Test Go client library with concurrent workloads

**Configuration**:
- Base Image: `golang:1.24-bookworm`
- Client Path: `/app/clients/go/gql`
- Test Harness: Connection pooling, concurrent queries
- Output: JSON reports to `/results/go/`

**Test Scenarios**:
- Connection pool stress testing
- Concurrent transaction handling
- Large result set streaming
- Reconnection resilience

### 4. Python Client Container (`client-python`)

**Purpose**: Test async Python client with aioquic

**Configuration**:
- Base Image: `python:3.11-slim`
- Client Path: `/app/clients/python/geode_client`
- Dependencies: aioquic, cryptography, pytest-asyncio
- Output: JSON reports to `/results/python/`

**Test Scenarios**:
- Async connection management
- Concurrent query execution
- Type marshaling verification
- Session persistence

### 5. Rust Client Container (`client-rust`)

**Purpose**: Test high-performance Rust client

**Configuration**:
- Base Image: `rust:1.75-bookworm`
- Client Path: `/app/clients/rust`
- Runtime: Tokio async
- Output: JSON reports to `/results/rust/`

**Test Scenarios**:
- Zero-copy query handling
- Concurrent connection pools
- Large batch operations
- Memory safety verification

### 6. Zig Client Container (`client-zig`)

**Purpose**: Test native Zig client with minimal overhead

**Configuration**:
- Base Image: Custom with Zig 0.15.1
- Client Path: `/app/clients/zig`
- Output: JSON reports to `/results/zig/`

**Test Scenarios**:
- Direct QUIC protocol testing
- Memory allocation patterns
- Binary protocol verification

## Large-Scale Graph Schema

The integration tests use a comprehensive "Enterprise Network" schema designed to stress-test all Geode capabilities:

### Node Types (15 types, ~50,000 nodes)

```gql
-- Core Entities
CREATE (:Organization {id, name, industry, founded, revenue, employee_count, headquarters})
CREATE (:Department {id, name, budget, cost_center, floor_number})
CREATE (:Employee {id, name, email, hire_date, salary, title, skills: VectorF32})
CREATE (:Project {id, name, status, start_date, deadline, budget, description})
CREATE (:Document {id, title, content, created_at, modified_at, version, content_hash})

-- Infrastructure
CREATE (:Server {id, hostname, ip_addr: IpAddr, mac: Mac, os, cpu_cores, memory_gb})
CREATE (:Application {id, name, version, port, health_status, last_deploy})
CREATE (:Database {id, name, engine, size_gb, replica_count, connection_string})
CREATE (:Network {id, name, cidr: Subnet, vlan_id, gateway: IpAddr})
CREATE (:Datacenter {id, name, location: LatLon, tier, pue_rating})

-- Security & Compliance
CREATE (:User {id, username, password_hash, mfa_enabled, last_login, role})
CREATE (:Permission {id, resource, action, conditions})
CREATE (:AuditLog {id, timestamp, user_id, action, resource, details})
CREATE (:Policy {id, name, type, enforcement_level, effective_date})
CREATE (:Incident {id, severity, description, detected_at, resolved_at, root_cause})
```

### Relationship Types (25 types, ~500,000 edges)

```gql
-- Organizational
(:Organization)-[:HAS_DEPARTMENT]->(:Department)
(:Department)-[:HAS_EMPLOYEE]->(:Employee)
(:Employee)-[:MANAGES]->(:Employee)
(:Employee)-[:WORKS_ON]->(:Project)
(:Employee)-[:AUTHORED]->(:Document)
(:Project)-[:BELONGS_TO]->(:Department)

-- Infrastructure
(:Application)-[:RUNS_ON]->(:Server)
(:Application)-[:CONNECTS_TO]->(:Database)
(:Server)-[:IN_NETWORK]->(:Network)
(:Server)-[:LOCATED_IN]->(:Datacenter)
(:Network)-[:PEERS_WITH]->(:Network)
(:Database)-[:REPLICATED_TO]->(:Database)

-- Security
(:User)-[:HAS_PERMISSION]->(:Permission)
(:User)-[:BELONGS_TO_ROLE]->(:Role)
(:AuditLog)-[:PERFORMED_BY]->(:User)
(:Policy)-[:APPLIES_TO]->(:Resource)
(:Incident)-[:AFFECTS]->(:Application)
(:Incident)-[:ASSIGNED_TO]->(:Employee)

-- Temporal/Versioned
(:Document)-[:PREVIOUS_VERSION]->(:Document)
(:Application)-[:DEPENDS_ON]->(:Application)
(:Project)-[:DEPENDS_ON]->(:Project)

-- Analytics
(:Employee)-[:SIMILAR_TO {score: Float}]->(:Employee)  -- Vector similarity
(:Document)-[:RELATES_TO {weight: Float}]->(:Document)
```

### Data Distribution

| Node Type | Count | Properties | Index Types |
|-----------|-------|------------|-------------|
| Organization | 100 | 7 | B-tree, Full-text |
| Department | 1,000 | 5 | B-tree |
| Employee | 25,000 | 7 + Vector | B-tree, HNSW |
| Project | 5,000 | 6 | B-tree, Full-text |
| Document | 10,000 | 7 | B-tree, Full-text |
| Server | 2,000 | 7 | B-tree, Patricia Trie |
| Application | 3,000 | 6 | B-tree |
| Database | 500 | 6 | B-tree |
| Network | 200 | 5 | Patricia Trie |
| Datacenter | 20 | 5 | R-tree |
| User | 1,000 | 6 | B-tree |
| Permission | 500 | 3 | B-tree |
| AuditLog | 100,000 | 5 | B-tree, Time-series |
| Policy | 50 | 5 | B-tree |
| Incident | 500 | 6 | B-tree |

## Migration System

### Migration Files Structure

```
docker-integration/migrations/
├── 001_schema_core.gql           # Core node types and constraints
├── 002_schema_infrastructure.gql # Infrastructure entities
├── 003_schema_security.gql       # Security and audit entities
├── 004_indexes.gql               # Index definitions
├── 005_seed_organizations.gql    # Organization data
├── 006_seed_departments.gql      # Department data
├── 007_seed_employees.gql        # Employee data (with vectors)
├── 008_seed_infrastructure.gql   # Server, network, datacenter data
├── 009_seed_relationships.gql    # All relationships
├── 010_seed_audit_logs.gql       # Historical audit data
```

### Migration Execution

Migrations run automatically on server startup via init container:

```yaml
services:
  migration-runner:
    image: geode-client:latest
    command: |
      for f in /migrations/*.gql; do
        echo "Running migration: $f"
        geode query --server geode-server:8443 --insecure < "$f"
      done
    volumes:
      - ./migrations:/migrations:ro
    depends_on:
      geode-server:
        condition: service_healthy
```

## Concurrent Test Orchestration

### Test Phases

1. **Phase 1: Schema Verification** (Sequential)
   - Verify all node types exist
   - Verify all relationship types exist
   - Verify all indexes are active
   - Verify constraints are enforced

2. **Phase 2: Data Integrity** (Parallel per client)
   - Count verification for each node type
   - Relationship count verification
   - Sample data validation

3. **Phase 3: Concurrent Workload** (Fully Parallel)
   - Each client runs randomized query patterns
   - Mix of reads, writes, and graph traversals
   - Connection pool stress testing
   - Transaction isolation verification

4. **Phase 4: Analytics Queries** (Parallel with contention)
   - Complex path queries
   - Aggregation queries
   - Vector similarity searches
   - Graph algorithm execution

5. **Phase 5: Chaos Testing** (Controlled chaos)
   - Random connection drops
   - Query timeouts
   - Large result set handling
   - Memory pressure testing

### Randomized Query Generator

```python
class QueryGenerator:
    def __init__(self, seed: int = 42):
        self.rng = random.Random(seed)
        self.query_types = [
            self.generate_node_query,
            self.generate_path_query,
            self.generate_aggregation_query,
            self.generate_vector_query,
            self.generate_write_query,
        ]

    def generate_batch(self, count: int) -> List[str]:
        return [self.rng.choice(self.query_types)() for _ in range(count)]
```

## Logging Configuration

### Per-Client Log Structure

```
/logs/
├── geode-server/
│   ├── server.log           # Main server log
│   ├── queries.log          # Query execution log
│   ├── audit.log            # Audit trail
│   └── metrics.log          # Performance metrics
├── geodetestlab/
│   ├── runner.log           # Test runner output
│   ├── results.jsonl        # JSONL test results
│   └── failures/            # Failed test details
├── client-go/
│   ├── client.log           # Go client operations
│   ├── pool.log             # Connection pool events
│   └── results.json         # Test results
├── client-python/
│   ├── client.log           # Python async client
│   ├── queries.log          # Query execution
│   └── results.json         # Test results
├── client-rust/
│   ├── client.log           # Rust client operations
│   ├── perf.log             # Performance metrics
│   └── results.json         # Test results
└── client-zig/
    ├── client.log           # Zig client operations
    └── results.json         # Test results
```

### Log Format

All logs use structured JSON format:
```json
{
  "timestamp": "2025-12-02T10:15:30.123Z",
  "level": "INFO",
  "client": "go",
  "component": "pool",
  "message": "Connection acquired",
  "connection_id": "conn-42",
  "pool_size": 10,
  "active_connections": 5
}
```

## Test Duration and Modes

### Quick Mode (5 minutes)
- Schema verification only
- 1,000 randomized queries per client
- No chaos testing

### Standard Mode (30 minutes)
- Full schema and data verification
- 10,000 randomized queries per client
- Limited chaos testing

### Extended Mode (2 hours)
- Complete test suite
- 100,000 randomized queries per client
- Full chaos testing
- Memory leak detection
- Performance regression analysis

### Continuous Mode (Infinite)
- Runs until stopped
- Rotating log files
- Periodic health checks
- Auto-recovery from failures

## Make Targets

```makefile
# Quick validation (5 min)
make docker-integration-quick

# Standard test run (30 min)
make docker-integration

# Extended test run (2 hours)
make docker-integration-extended

# Continuous testing
make docker-integration-continuous

# Build all containers
make docker-integration-build

# Start infrastructure only (for debugging)
make docker-integration-up

# View logs
make docker-integration-logs

# Stop all containers
make docker-integration-down

# Clean up volumes and images
make docker-integration-clean

# Generate HTML report
make docker-integration-report
```

## Expected Outcomes

### Success Criteria

1. **All clients connect successfully** via QUIC+TLS
2. **Schema migrations complete** without errors
3. **Data verification passes** for all node/edge counts
4. **Concurrent queries execute** without deadlocks
5. **Transaction isolation maintained** under load
6. **Vector similarity searches** return correct results
7. **Graph traversals complete** within time limits
8. **No memory leaks** detected over extended runs
9. **All test specs pass** (95%+ pass rate required)

### Performance Baselines

| Metric | Quick | Standard | Extended |
|--------|-------|----------|----------|
| Simple queries | <10ms p99 | <10ms p99 | <10ms p99 |
| 3-hop traversals | <50ms p99 | <50ms p99 | <50ms p99 |
| Vector search (k=10) | <5ms p99 | <5ms p99 | <5ms p99 |
| Aggregations | <100ms p99 | <100ms p99 | <100ms p99 |
| Concurrent connections | 100 | 500 | 1000 |

## Directory Structure

```
docker-integration/
├── docker-compose.integration.yml     # Main compose file
├── Dockerfile.server                  # Geode server image
├── Dockerfile.geodetestlab            # GeodeTestLab image
├── Dockerfile.client-go               # Go client test image
├── Dockerfile.client-python           # Python client test image
├── Dockerfile.client-rust             # Rust client test image
├── Dockerfile.client-zig              # Zig client test image
├── migrations/                        # Schema and seed migrations
│   ├── 001_schema_core.gql
│   ├── 002_schema_infrastructure.gql
│   ├── ...
│   └── 010_seed_audit_logs.gql
├── scripts/
│   ├── orchestrator.py               # Main test orchestrator
│   ├── query_generator.py            # Randomized query generator
│   ├── report_generator.py           # HTML/JSON report generation
│   └── health_check.sh               # Container health verification
├── specs/                             # Integration-specific test specs
│   ├── concurrent_writes.yml
│   ├── cross_client_transactions.yml
│   ├── persistence_verification.yml
│   └── stress_test.yml
└── README.md                          # Usage documentation
```

## Implementation Notes

1. **QUIC Protocol**: All clients use vendored ztls and zig-quic, no external OpenSSL/MsQUIC dependencies
2. **TLS Certificates**: Self-signed certs generated at build time, clients use `--insecure` flag
3. **Data Persistence**: Server data persists between test runs for incremental testing
4. **Network Isolation**: All containers on dedicated Docker network, no host networking
5. **Resource Limits**: Each client container limited to 2GB RAM, 2 CPUs
6. **Log Rotation**: Logs rotate at 100MB, keep last 5 rotations

## Troubleshooting

### Common Issues

1. **QUIC connection failures**: Check UDP port 8443 is exposed, verify TLS handshake
2. **Migration failures**: Check server health, verify query syntax
3. **Memory exhaustion**: Reduce concurrent connections, increase container limits
4. **Test timeouts**: Increase query timeouts, reduce batch sizes
5. **Data inconsistency**: Run full migration reset, verify seed data

### Debug Mode

```bash
# Start with debug logging
make docker-integration-debug

# Attach to specific container
docker exec -it geode-server /bin/bash

# View real-time server logs
docker logs -f geode-server

# Run single client manually
docker-compose -f docker-integration/docker-compose.integration.yml \
  run --rm client-go go test -v ./...
```
