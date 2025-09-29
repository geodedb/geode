# Geode Quick Reference Guide

## Essential Commands

### Starting the Server
```bash
# Basic server start
geoded --listen-quic 0.0.0.0:8443

# With all options
geoded --listen-quic 0.0.0.0:8443 \
       --data-dir /var/geode/data \
       --tls-cert server.crt \
       --tls-key server.key \
       --log-json \
       --enable-tde
```

### Client Operations
```bash
# Run single query
geodec "MATCH (n) RETURN n LIMIT 10"

# Query with JSON output
geodec "RETURN 1 AS x" --format json

# Interactive REPL
gql

# Unified CLI
geode --help
```

## Build & Development

### Core Build Commands
```bash
make build              # Debug build
make release            # Optimized build
make test              # Run all tests
make bench             # Run benchmarks
make verify-all        # Full verification
make fmt               # Format code
```

### Docker Commands
```bash
make docker-build      # Build images
make docker-up-singleton    # Single node
make docker-up-distributed  # Cluster
make docker-down       # Stop all
make docker-test       # Test in Docker
```

### Governance Commands
```bash
make status-generate   # Update CANARY status
make governance-check  # Validate evidence
make no-feature-flags  # Check feature flags
```

## Common GQL Queries

### Basic Patterns
```gql
-- Find all nodes
MATCH (n) RETURN n

-- Find nodes by label
MATCH (p:Person) RETURN p

-- Find by property
MATCH (p:Person {name: "Alice"}) RETURN p

-- Find relationships
MATCH (a)-[r]->(b) RETURN a, r, b

-- Find specific relationship type
MATCH (a)-[r:KNOWS]->(b) RETURN a, b
```

### Graph Traversal
```gql
-- Friends of friends
MATCH (p:Person {name: "Alice"})-[:KNOWS*2]->(fof)
RETURN DISTINCT fof.name

-- Variable-length paths (bounded)
MATCH path = (a)-[*1..5]->(b)
WHERE a.id = 1 AND b.id = 100
RETURN path, length(path)

-- Shortest path
MATCH path = shortestPath((a)-[*]-(b))
WHERE a.id = 1 AND b.id = 100
RETURN path
```

### Data Modification
```gql
-- Create node
CREATE (p:Person {name: "Bob", age: 30})

-- Create relationship
MATCH (a:Person {name: "Alice"}), (b:Person {name: "Bob"})
CREATE (a)-[r:KNOWS {since: 2024}]->(b)

-- Update properties
MATCH (p:Person {name: "Alice"})
SET p.age = 31

-- Delete node
MATCH (p:Person {name: "Alice"})
DELETE p

-- Delete relationship
MATCH (a)-[r:KNOWS]->(b)
DELETE r
```

### Aggregations
```gql
-- Count nodes
MATCH (n) RETURN count(n)

-- Group by label
MATCH (n)
RETURN labels(n) AS label, count(n) AS count
ORDER BY count DESC

-- Average property value
MATCH (p:Person)
RETURN avg(p.age) AS average_age

-- Collect values
MATCH (p:Person)-[:KNOWS]->(f)
RETURN p.name, collect(f.name) AS friends
```

## Type Constructors

### Numeric Types
```sql
SmallInt(42)           -- i16
Int(1000)             -- i32  
BigInt(9999999)       -- i64
Real(3.14)            -- f32
Double(3.14159)       -- f64
Decimal(123.45, 2)    -- Decimal with scale
```

### String Types
```sql
Char('Hello', 10)     -- Fixed length
Varchar('World', 50)  -- Variable length
Text('Long text...')  -- Unlimited
```

### Temporal Types
```sql
Date('2024-12-25')
Time('14:30:00.123456')
TimeTZ('14:30:00', -28800)  -- With timezone
Timestamp('2024-12-25 14:30:00')
TimestampTZ('2024-12-25 14:30:00 -08:00')
Interval('P1Y2M3DT4H5M6S')
```

### Network Types
```sql
IpAddr('192.168.1.1')
IpAddr('2001:db8::1')
Cidr('192.168.0.0/24')
MacAddr('00:11:22:33:44:55')
```

### Geographic Types
```sql
Point2D(10.5, 20.3)
Point3D(10.5, 20.3, 100.0)
GeoPoint(37.7749, -122.4194)  -- lat, lon
LineString([(0,0), (1,1), (2,0)])
Polygon([[(0,0), (4,0), (4,4), (0,4), (0,0)]])
```

### Advanced Types
```sql
UUID('550e8400-e29b-41d4-a716-446655440000')
Json('{"key": "value"}')
Jsonb('{"key": "value"}')  -- Binary JSON
Xml('<root><child/></root>')
Vector([1.0, 2.0, 3.0])
Bytea('\\xDEADBEEF')
URL('https://example.com')
```

## Configuration

### Environment Variables
```bash
# Query behavior
export GEODE_ORDER_KEYS_EXPR=1       # Allow ORDER BY expressions

# Performance
export GEODE_TELEMETRY_PAGING=1      # Enable telemetry
export GEODE_CDC_ENABLE=1            # Enable CDC

# QUIC settings
export GEODE_QUIC_FORCE_CLOSE=1      # Force connection close
export GEODE_QUIC_PASSIVE_TEARDOWN=1 # Passive teardown

# Testing
export GEODE_CAPTURE_SERVER_STDERR=1 # Capture stderr
```

### Server Flags
```bash
geoded --help
  --listen-quic      QUIC listen address
  --data-dir         Data directory path
  --tls-cert         TLS certificate path
  --tls-key          TLS private key path
  --log-json         JSON log format
  --enable-tde       Enable encryption
  --max-connections  Max connections (10000)
  --page-cache-size  Page cache MB (1024)
```

## Troubleshooting

### Common Issues

#### Server won't start
```bash
# Check port availability
lsof -i :8443

# Verify TLS certificates
openssl x509 -in server.crt -text -noout

# Check data directory permissions
ls -la /var/geode/data
```

#### Query errors
```bash
# Enable verbose logging
geoded --log-level debug --log-json

# Check query syntax
geodec "EXPLAIN MATCH (n) RETURN n"
```

#### Performance issues
```bash
# Run profiling
geodec "PROFILE MATCH (n) RETURN n"

# Check indexes
geodec "SHOW INDEXES"

# Monitor metrics
curl http://localhost:9090/metrics
```

### Log Locations
- Server logs: stderr or `--log-file`
- Audit logs: `data_dir/audit/`
- WAL: `data_dir/wal/`

## Status Codes

### GQLSTATUS Codes
- `00000` - Success
- `02000` - No data
- `22000` - Data exception
- `42000` - Syntax error
- `42001` - Undefined object
- `42002` - Duplicate object

### Internal Error Codes
- `ERR_OOM` - Out of memory
- `ERR_FLOAT_NAN` - Invalid float
- `ERR_CHAR_LEN` - String too long
- `ERR_DEC_DIV_ZERO` - Division by zero
- `ERR_IP_PARSE` - Invalid IP address
- `ERR_JSON_PARSE` - Invalid JSON

## Testing

### Run Specific Tests
```bash
# Single test file
zig test tests/test_parser.zig

# With filter
zig build test -Dtest-filter="CANARY"

# Integration tests
make integration-test

# Fuzz testing
make fuzz
```

### Benchmark Commands
```bash
# Run all benchmarks
make bench

# Extract benchmark results
make bench 2>&1 | bench_extract

# Compare with baseline
bench_regress --baseline old.json --current new.json
```

## CANARY Markers

### Adding Evidence
```zig
// CANARY: REQ=REQ-GQL-XXX; FEATURE="Feature Name"; 
//         ASPECT=Component; STATUS=TESTED; 
//         TEST=TestName; OWNER=team; 
//         UPDATED=2025-09-29
```

### Status Levels
- `MISSING` - Not implemented
- `STUB` - Placeholder only
- `IMPL` - Implemented, needs test
- `TESTED` - Has test coverage
- `BENCHED` - Has benchmarks

### Validation
```bash
# Generate status
make status-generate

# View status
cat docs/status.csv

# Check freshness
grep STALE docs/status.csv | wc -l
```

## Useful Aliases

Add to your shell profile:

```bash
# Geode aliases
alias gs='geoded --listen-quic 0.0.0.0:8443'
alias gc='geodec'
alias gql='gql'
alias gbuild='make build'
alias gtest='make test'
alias gfmt='make fmt'
alias gverify='make verify-all'

# Quick queries
alias gnodes='geodec "MATCH (n) RETURN count(n)"'
alias gedges='geodec "MATCH ()-[r]->() RETURN count(r)"'
alias gstats='geodec "CALL db.stats()"'
```

## Links

- [Full Documentation](GROUND_TRUTH.md)
- [Types Reference](TYPES_AND_FUNCTIONS.md)
- [Binary Protocol](BINARY_PROTOCOL.md)
- [Security Guide](SECURITY_PROGRESS.md)
- [Contributing](../CONTRIBUTING.md)

---

*Quick Reference v0.18.0 - Generated 2025-09-29*