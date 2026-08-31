# USAGE.md - Geode User Guide

## Quick Start

### Starting the Server

```bash
# Default configuration (QUIC/TLS on port 3141)
./geode serve

# With custom data directory
./geode serve --data_dir /path/to/data

# With custom certificates
./geode serve --cert /path/to/cert.pem --key /path/to/key.pem
```

### Connecting with Client

```bash
# Interactive REPL
./geode query

# Execute single query
./geode query "MATCH (n) RETURN n LIMIT 10"

# Execute from file (max 16 MiB / 16777216 bytes; split larger files, or
# stream them with `--batch`, one statement per line).  Files over ~16 KB are
# executed in chunks: a statement the server rejects is retried on its own so
# only that statement is lost, and the process exits non-zero.
./geode query -f queries.gql

# JSON output (default)
./geode query --format json "RETURN 1 AS x"

# Plain text output
./geode query --format txt "RETURN 1 AS x"
```

## Feature Overview (Current State)

### Distributed Query Federation (Always On)

Federated query execution across shards is always enabled:

```bash
# Queries automatically consider federation
./geode query "MATCH (n:Person) RETURN n ORDER BY n.name LIMIT 100"

# View distributed plan
./geode query "EXPLAIN MATCH (n) RETURN n ORDER BY n.id"
```

### S3 Cloud Backups

Perform backups to S3-compatible storage:

```bash
# Configure S3 credentials
export AWS_ACCESS_KEY_ID=your-key
export AWS_SECRET_ACCESS_KEY=your-secret
export AWS_REGION=us-east-1

# Full backup
geode backup --dest s3://my-bucket/backups --mode full

# Incremental backup
geode backup --dest s3://my-bucket/backups --mode incremental --parent 12345

# List backups
geode backup --dest s3://my-bucket/backups --list

# Restore from backup
geode restore --source s3://my-bucket/backups --backup-id 12345 --target /data
```

### CDC Webhook Configuration

Configure webhooks with enhanced reliability:

```yaml
# cdc-config.yaml
webhooks:
  - name: primary
    endpoint: https://api.example.com/webhook
    headers:
      Authorization: 'Bearer ${WEBHOOK_TOKEN}'
      X-Tenant-ID: 'tenant-123'
      X-Environment: 'production'
    retry:
      max_attempts: 5
      base_delay_ms: 100
      max_delay_ms: 30000
    dlq:
      enabled: true
      max_size: 10000
      retention_hours: 168
    idempotency:
      enabled: true
      header: 'X-Idempotency-Key'
```

### Cost-Based Optimizer (Always On)

The optimizer runs by default; enable tracing for diagnostics:

```bash
# Optional: trace decisions
export GEODE_TRACE_OPTIMIZER=1

./geode query "EXPLAIN (VERBOSE) MATCH (n) RETURN n"
```

## Query Language (GQL)

### Basic Queries

```gql
-- Simple match
MATCH (n:Person)
RETURN n.name, n.age

-- Pattern matching
MATCH (p:Person)-[:KNOWS]->(f:Person)
WHERE p.age > 30
RETURN p.name AS person, f.name AS friend

-- Optional match
MATCH (p:Person)
OPTIONAL MATCH (p)-[:WORKS_AT]->(c:Company)
RETURN p.name, c.name

-- Aggregation
MATCH (p:Person)
RETURN p.city, COUNT(*) AS population
GROUP BY p.city
ORDER BY population DESC
```

### Advanced Queries

```gql
-- Variable-length paths
MATCH (p1:Person)-[:KNOWS*1..3]->(p2:Person)
WHERE p1.name = 'Alice'
RETURN p2.name

-- Graph algorithms
MATCH (start:City {name: 'Seattle'})
MATCH (end:City {name: 'Boston'})
RETURN shortestPath(start, end) AS route

-- PageRank
MATCH (n:Page)
RETURN n.url, pageRank(n) AS rank
ORDER BY rank DESC
LIMIT 10
```

### Data Modification (DML)

```gql
-- Insert node
INSERT (p:Person {name: 'Alice', age: 30})

-- Insert edge
MATCH (p1:Person {name: 'Alice'})
MATCH (p2:Person {name: 'Bob'})
INSERT (p1)-[:KNOWS {since: 2024}]->(p2)

-- Update properties
MATCH (p:Person {name: 'Alice'})
SET p.age = 31, p.city = 'Seattle'

-- Delete edge
MATCH (p1:Person)-[k:KNOWS]->(p2:Person)
WHERE k.since < 2020
DELETE k

-- Delete node (must have no edges)
MATCH (p:Person {name: 'Alice'})
DELETE p
```

## Configuration

### Server Configuration

```yaml
# geode.yaml
server:
  listen: '0.0.0.0:3141'
  data_dir: '/var/lib/geode'

tls:
  cert: '/etc/geode/cert.pem'
  key: '/etc/geode/key.pem'
  auto_generate: true

storage:
  page_size: 8192
  cache_size: '1GB'
  wal_dir: '/var/lib/geode/wal'

federation:
  # (Always active) Configuration focuses on shard endpoints
  coordinator: true
  shards:
    - id: 'shard1'
      endpoint: 'node1.cluster:3141'
    - id: 'shard2'
      endpoint: 'node2.cluster:3141'

optimizer:
  # Enable/disable removed; only tuning parameters remain
  small_n_threshold: 100
  trace: false

backup:
  s3:
    bucket: 'geode-backups'
    prefix: 'prod'
    retention_days: 30
```

### Environment Variables (Updated Set)

```bash
# Core settings
GEODE_DATA_DIR=/var/lib/geode
GEODE_LOG_LEVEL=info
GEODE_LOG_FORMAT=json

# Optimizer tracing (functional without flag)
GEODE_TRACE_OPTIMIZER=1   # Optional

# Transparent Data Encryption
GEODE_DISK_KEY_HEX=<64 hex chars>   # Provide to ensure encrypted pages/WAL on new data

# S3 Backup
AWS_ACCESS_KEY_ID=xxx
AWS_SECRET_ACCESS_KEY=yyy
AWS_REGION=us-east-1

# CDC
CDC_KAFKA_BROKERS=kafka1:9092,kafka2:9092
CDC_WEBHOOK_ENDPOINT=https://api.example.com/webhook
```

## Monitoring

### Metrics Endpoints

```bash
# Prometheus metrics
curl http://localhost:9090/metrics

# Health check
curl http://localhost:8080/health

# Ready check
curl http://localhost:8080/ready
```

### Key Metrics

```
# Query metrics
geode_query_total{status="success|error"}
geode_query_duration_ms{percentile="50|95|99"}

# Federation metrics
geode_federation_queries_total
geode_federation_shard_errors_total
geode_federation_merge_duration_ms

# Storage metrics
geode_storage_pages_total
geode_storage_wal_segments_total
geode_storage_cache_hit_ratio

# CDC metrics
geode_cdc_events_sent_total
geode_cdc_webhook_retries_total
geode_cdc_dlq_size

# Backup metrics
geode_backup_last_success_timestamp
geode_backup_size_bytes
geode_backup_duration_ms
```

## Troubleshooting

### Common Issues

#### Federation Troubleshooting

```bash
# Verify shard connectivity
geode query "CALL system.federation.status()"

# Check logs for errors
grep "federation" /var/log/geode/geode.log
```

#### S3 Backup Failures

```bash
# Test S3 connectivity
aws s3 ls s3://my-bucket/backups/

# Check credentials
aws sts get-caller-identity

# Verify permissions (need s3:PutObject, s3:GetObject)
aws s3api put-object --bucket my-bucket --key test.txt --body test.txt
```

#### CDC Webhook Issues

```bash
# Check webhook endpoint
curl -X POST https://api.example.com/webhook -H "Authorization: Bearer token"

# View DLQ contents
geode query "SELECT * FROM system.cdc.dlq"

# Check retry metrics
geode query "CALL system.cdc.metrics()"
```

#### Performance Problems

```bash
# View query plan for insight
geode query "EXPLAIN (ANALYZE) <your-query>"

# Check system resources
geode query "CALL system.resources()"
```

### Log Locations

```
/var/log/geode/geode.log        # Main server log
/var/log/geode/query.log        # Query audit log
/var/log/geode/cdc.log          # CDC specific log
/var/log/geode/federation.log   # Federation operations
```

## Best Practices

### Query Optimization

1. **Always use ORDER BY with LIMIT/OFFSET** - Required for deterministic results
2. **Create indexes on frequently filtered properties** - Improves query performance
3. **Use EXPLAIN to understand query plans** - Identify bottlenecks
4. **Limit path expansion depth** - Prevents combinatorial explosion

### Federation

1. **Start with read-only workloads** - Writes not yet distributed
2. **Monitor shard balance** - Ensure even distribution
3. **Use appropriate timeouts** - Prevent hanging queries
4. **Test failover scenarios** - Ensure resilience

### Backups

1. **Schedule regular full backups** - Weekly recommended
2. **Keep incremental chains short** - Max 7 incrementals
3. **Test restore procedures** - Verify backup integrity
4. **Monitor S3 costs** - Use lifecycle policies

### CDC

1. **Configure appropriate batch sizes** - Balance latency vs throughput
2. **Monitor DLQ size** - Alert on growth
3. **Use idempotency keys** - Prevent duplicates
4. **Set reasonable retry limits** - Avoid infinite loops

## Migration Guide

### Migration Guide

```bash
# 1. Backup existing data
geode backup --dest /backup/previous --mode full

# 2. Stop old server
systemctl stop geode serve

# 3. Install new binaries
tar -xzf geode-v0.1.0.tar.gz
cp geode/bin/* /usr/local/bin/

# 4. Start new server
systemctl start geode serve

# 5. Verify functionality
geode query "MATCH (n) RETURN COUNT(*)"
```

### Breaking Changes

- Federation must be explicitly enabled
- CBO remains off by default
- No other breaking changes

## Support

- Documentation: <https://docs.geode.io>
- GitLab Issues: <https://gitlab.com/devnw/codepros/geode/geode/-/issues>
- Discord: <https://discord.gg/geode>
- Email: [email protected]
