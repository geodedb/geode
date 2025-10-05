# Integration Testing Guide

## Overview

Geode includes comprehensive integration tests that validate functionality at scale with realistic datasets. These tests ensure the database performs correctly under real-world conditions with complex graph structures, large data volumes, and sophisticated query patterns.

## Test Categories

### 1. Large-Scale Dataset Tests

#### Social Network Dataset (`test_large_social_network.zig`)
- **Scale**: 10,000+ users, 50,000+ relationships
- **Features Tested**:
  - User relationships (FOLLOWS, FRIENDS_WITH)
  - Content creation (posts, comments, reactions)
  - Groups and memberships
  - Events with spatial data
  - Vector embeddings for content similarity
  - Temporal patterns in user activity

**Key Queries**:
```gql
// Find influencers with high engagement
MATCH (u:User)-[:POSTED]->(p:Post)<-[:LIKED]-(l:User)
WITH u, COUNT(DISTINCT l) as reach
WHERE reach > 1000
RETURN u.username, reach
ORDER BY reach DESC

// Content recommendation using embeddings
MATCH (u:User {id: $userId})-[:LIKED]->(p:Post)
WITH u, AVG(p.embedding) as user_preference
MATCH (rec:Post)
WHERE vector_cosine(rec.embedding, user_preference) > 0.8
RETURN rec.content
```

#### IoT Network Dataset (`test_iot_network_dataset.zig`)
- **Scale**: 25,000 devices, 50,000+ metrics
- **Features Tested**:
  - Network topology (IP/MAC addresses)
  - Sensor telemetry data
  - Time-series metrics
  - Security monitoring
  - Spatial indexing for device locations
  - Alert correlation

**Key Queries**:
```gql
// Network anomaly detection
MATCH (d:Device)-[:GENERATED]->(a:Alert)
WHERE a.severity = 'critical' 
  AND a.timestamp > timestamp() - duration('PT1H')
WITH d.network_segment, COUNT(a) as alert_count
WHERE alert_count > 5
RETURN network_segment, alert_count

// Device proximity search
MATCH (d:Device)
WHERE distance_haversine(d.location, LatLon(37.7749, -122.4194)) < 1000
  AND d.status = 'active'
RETURN d.device_id, d.ip_address
```

#### Financial Fraud Network (`test_financial_fraud_network.zig`)
- **Scale**: 50,000 accounts, 250,000 transactions
- **Features Tested**:
  - Transaction pattern analysis
  - Fraud detection algorithms
  - Money flow tracking
  - AML (Anti-Money Laundering) patterns
  - Risk scoring
  - Real-time alerting

**Key Queries**:
```gql
// Velocity attack detection
MATCH (a:Account)-[:SENT]->(t:Transaction)
WHERE t.timestamp > timestamp() - duration('PT60S')
WITH a, COUNT(t) as tx_count
WHERE tx_count > 10
RETURN a.id, tx_count

// Money mule network detection
MATCH path = (a1:Account)-[:SENT*2..4]->(:Transaction)-[:RECEIVED_BY]->(a2:Account)
WHERE a1.kyc_verified = true AND a2.kyc_verified = false
RETURN path, LENGTH(path) as chain_length
```

#### Geographic Mapping Dataset (`test_geographic_mapping.zig`)
- **Scale**: 100 cities, 25,000 POIs, 50,000 buildings
- **Features Tested**:
  - Spatial indexing (R-tree)
  - Geographic calculations
  - Route planning
  - Geofencing
  - Proximity searches
  - Urban density analysis

**Key Queries**:
```gql
// Find POIs within radius
MATCH (p:PointOfInterest)
WHERE distance_haversine(p.location, $user_location) < 5000
RETURN p.name, p.category
ORDER BY distance_haversine(p.location, $user_location)

// Transit route planning
MATCH path = (start:TransitStop)-[:CONNECTS_TO*..5]->(end:TransitStop)
WHERE start.id = $start_id AND end.id = $end_id
RETURN path, REDUCE(time = 0, r IN relationships(path) | time + r.travel_time_min) as total_time
ORDER BY total_time
```

### 2. Index Performance Tests

#### Index Type Comparisons (`test_index_performance.zig`)
Tests performance characteristics of different index types:

- **B-tree Index**: Range queries, ordered traversals
- **Hash Index**: Exact match lookups
- **Spatial Index (R-tree)**: Geographic queries
- **Vector Index (HNSW)**: Similarity searches
- **Full-text Index**: Text search operations

**Performance Metrics**:
- Insertion time per index type
- Lookup performance comparison
- Range scan efficiency
- Memory usage analysis
- Index maintenance overhead

### 3. Specialized Tests

#### Backup and Restore (`test_backup_restore.zig`)
- Full backup creation
- Incremental backups
- Point-in-time recovery
- Cross-version compatibility
- Data integrity verification

#### Variable Path Patterns (`test_variable_paths.zig`)
- Variable-length path queries
- Shortest path algorithms
- All paths enumeration
- Cycle detection
- Path filtering

#### Union Operations (`test_union_operations.zig`)
- UNION queries across labels
- Result set merging
- Duplicate elimination
- Performance optimization

## Running Integration Tests

### Prerequisites
1. Build Geode: `make build`
2. Start server: `./zig-out/bin/geoded --data_dir ./data`
3. Ensure sufficient resources (4GB+ RAM recommended for large tests)

### Running All Integration Tests
```bash
# Run all integration tests
make integration-test

# Run specific test file
zig test tests/integration/test_large_social_network.zig

# Run with verbose output
zig test tests/integration/test_financial_fraud_network.zig --verbose

# Run dataset integration tests
make dataset-integration-test
```

### Performance Testing
```bash
# Run performance benchmarks
make bench

# Run specific performance test
zig test tests/integration/test_index_performance.zig --release-fast

# Profile with detailed metrics
GEODE_PROFILE=1 zig test tests/integration/test_geographic_mapping.zig
```

## Test Data Generation

### Synthetic Data Patterns
Integration tests use realistic synthetic data generation:

1. **Temporal Distribution**: Events follow realistic time patterns
2. **Geographic Distribution**: Locations use real-world coordinate systems
3. **Network Topology**: IP/MAC addresses follow valid formats
4. **Relationship Patterns**: Social connections follow power-law distribution
5. **Financial Patterns**: Transactions include normal and anomalous patterns

### Data Seeding
Tests can use migration files as templates:
```bash
# Load example dataset
make load-dataset

# Use specific migration
./scripts/load_example_dataset.sh --host localhost --port 8443
```

## Performance Expectations

### Baseline Metrics
Expected performance for standard hardware (8-core CPU, 16GB RAM, SSD):

| Operation | Records | Expected Time |
|-----------|---------|---------------|
| Bulk Insert | 10,000 | < 5s |
| Bulk Insert | 100,000 | < 60s |
| Point Lookup (indexed) | 1 | < 1ms |
| Range Scan (1000 results) | 1,000 | < 10ms |
| KNN Search (k=10) | 10 | < 5ms |
| Spatial Query (10km radius) | varies | < 20ms |
| 3-hop Path Query | varies | < 100ms |

### Scalability Targets
- Support 1M+ nodes without degradation
- Handle 10M+ edges with consistent performance
- Maintain sub-second response for indexed queries
- Scale to 100GB+ datasets with predictable performance

## Troubleshooting

### Common Issues

#### Out of Memory
- Increase heap size: `export GEODE_HEAP_SIZE=8G`
- Run tests sequentially: `make test-sequential`
- Clear data between tests: `rm -rf ./data/*`

#### Slow Performance
- Check indexes are created: `MATCH (n) RETURN n.indexStatus`
- Verify query plans: `EXPLAIN <query>`
- Monitor resource usage: `make monitor`

#### Connection Issues
- Verify server is running: `ps aux | grep geoded`
- Check port availability: `netstat -an | grep 8443`
- Review server logs: `tail -f geode.log`

## Writing New Integration Tests

### Test Structure Template
```zig
const std = @import("std");
const geode = @import("geode");
const testing = std.testing;

test "CANARY: REQ=REQ-GQL-YOUR-FEATURE" {
    // CANARY marker for requirement tracking
    const allocator = std.testing.allocator;
    
    var client = try geode.Client.init(allocator, .{
        .host = "127.0.0.1",
        .port = 8443,
        .insecure = true,
    });
    defer client.deinit();
    
    // Create schema
    try client.execute("CREATE LABEL YourEntity");
    
    // Create indexes for performance
    try client.execute("CREATE INDEX your_index ON YourEntity(property)");
    
    // Generate test data
    const num_entities = 10000;
    var i: usize = 0;
    while (i < num_entities) : (i += 1) {
        // Insert data
    }
    
    // Run test queries
    const result = try client.query("MATCH (n:YourEntity) RETURN n");
    defer result.deinit();
    
    // Validate results
    try testing.expect(result.rows.len == num_entities);
}
```

### Best Practices
1. Use CANARY markers for requirement traceability
2. Clean up resources in defer blocks
3. Generate realistic data distributions
4. Test both positive and negative cases
5. Include performance assertions
6. Document expected behavior
7. Use meaningful entity and property names

## CI/CD Integration

### GitHub Actions
```yaml
- name: Run Integration Tests
  run: |
    make build
    ./zig-out/bin/geoded --data_dir ./test-data &
    sleep 5
    make integration-test
```

### Docker Testing
```bash
# Build test container
make docker-build

# Run containerized tests
make docker-test

# Clean up
make docker-down
```

## Monitoring Test Execution

### Metrics Collection
Tests can emit metrics for monitoring:
- Query execution times
- Memory usage patterns
- Index utilization rates
- Cache hit ratios

### Visualization
Use the included Grafana dashboards:
```bash
# Start monitoring stack
docker-compose -f monitoring/docker-compose.yml up

# Access dashboards
open http://localhost:3000
```

## Contributing

When adding new integration tests:
1. Follow existing patterns and conventions
2. Include CANARY markers for requirements
3. Document test purpose and expectations
4. Add to appropriate test category
5. Update this documentation
6. Ensure tests are deterministic
7. Consider performance implications