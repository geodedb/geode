# Geode Docker Overview

Geode is a feature-complete single-tenant graph database implementing the ISO/IEC 39075:2024 Graph Query Language (GQL) standard. This document provides Docker-specific guidance for deploying and running Geode containers. **Deployment status:** development-ready for single-tenant workloads — see [Known Limitations](../CLAUDE.md#known-limitations) before enabling multi-tenancy or cluster mode.

## Quick Start

```bash
# Pull the latest image
docker pull geodedb/geode:latest

# Run with default settings
docker run -d \
  --name geode \
  -p 3141:3141/udp \
  -p 9091:9091/tcp \
  -v geode-data:/data \
  geodedb/geode:latest

# Run with custom configuration
docker run -d \
  --name geode \
  -p 3141:3141/udp \
  -p 9091:9091/tcp \
  -v geode-data:/data \
  -v ./certs:/certs:ro \
  -e LOG_LEVEL=info \
  geodedb/geode:latest \
  --data-dir /data \
  --listen 0.0.0.0:3141 \
  --cert /certs/server.crt \
  --key /certs/server.key
```

## Image Variants

### Standard Image (`geodedb/geode:latest`)

- **Base**: Debian Bookworm Slim
- **Size**: ~150MB
- **Use Case**: Production deployments, general-purpose workloads
- **Tags**: `latest`, `0.18.0`, `0.18`

### Alpine Image (`geodedb/geode:alpine`)

- **Base**: Alpine Linux 3.20
- **Size**: ~50MB
- **Use Case**: Minimal footprint, resource-constrained environments
- **Tags**: `alpine`, `0.18.0-alpine`

### GPU-Accelerated Image (`geodedb/geode:gpu`)

- **Base**: NVIDIA CUDA 12.3.2 Runtime (Ubuntu 22.04)
- **Size**: ~2GB
- **Use Case**: GPU-accelerated graph algorithms, vector operations, ML embeddings
- **Tags**: `gpu`, `0.18.0-gpu`
- **Requirements**: NVIDIA Container Toolkit, CUDA-capable GPU

## GPU vs Non-GPU Builds

| Feature | Standard | GPU |
|---------|----------|-----|
| Graph traversal | CPU | CUDA-accelerated |
| PageRank | CPU | CUDA-accelerated |
| Shortest path | CPU | CUDA-accelerated |
| Set operations | CPU | CUDA-accelerated |
| Vector similarity | SIMD | CUDA + SIMD |
| BFS/DFS | CPU | CUDA-accelerated |
| Image size | ~150MB | ~2GB |
| Base image | Debian Slim | NVIDIA CUDA |

### Running GPU-Accelerated Container

```bash
# Requires NVIDIA Container Toolkit
docker run -d \
  --name geode-gpu \
  --gpus all \
  -p 3141:3141/udp \
  -p 9091:9091/tcp \
  -v geode-data:/data \
  -e GPU_ENABLED=true \
  -e CUDA_VISIBLE_DEVICES=0 \
  geodedb/geode:gpu \
  --gpu-acceleration
```

## Exposed Ports

| Port | Protocol | Purpose |
|------|----------|---------|
| 3141/udp | QUIC | Primary database connection (default) |
| 8443/udp | QUIC | Alternative database connection |
| 9091/tcp | HTTP | Prometheus metrics endpoint |

**Note**: Geode uses QUIC (UDP) exclusively for database connections. There is no TCP fallback.

## Volumes

| Path | Purpose |
|------|---------|
| `/data` | Database storage (WAL, catalog, graph data) |
| `/certs` | TLS certificates (mount read-only) |
| `/var/log/geode` | Log files |

## Environment Variables

### Core Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `LOG_LEVEL` | `error` | Logging verbosity: `error`, `warn`, `info`, `debug` |
| `GEODE_DATA_DIR` | `/data` | Data storage directory |
| `GEODE_ENV` | - | Environment identifier (`development`, `production`) |

### Query Engine

| Variable | Default | Description |
|----------|---------|-------------|
| `GEODE_ENABLE_QUERY_OPTIMIZER` | `1` | Enable cost-based query optimization |
| `GEODE_INLINE_RESULTS` | `1` | Enable inline result streaming |
| `GEODE_INLINE_RESULTS_MAX_ROWS` | - | Maximum rows for inline results |
| `GEODE_QUERY_MEM_LIMIT_BYTES` | - | Memory limit per query |
| `GEODE_NULLS_LAST` | - | Sort NULLs last in ORDER BY |

### Storage & WAL

| Variable | Default | Description |
|----------|---------|-------------|
| `GEODE_WAL_COMPACT_INTERVAL` | - | WAL compaction interval |
| `GEODE_SPILL_THRESHOLD_BYTES` | - | Disk spill threshold |
| `GEODE_FORCE_SORT_SPILL` | - | Force sort operations to disk |
| `GEODE_FORCE_DISTINCT_SPILL` | - | Force DISTINCT to disk |
| `GEODE_FORCE_UNION_SPILL` | - | Force UNION to disk |

### Clustering & Distribution

| Variable | Default | Description |
|----------|---------|-------------|
| `GEODE_CLUSTER_NAME` | - | Cluster identifier for distributed deployments |
| `GEODE_NODE_ID` | - | Unique node ID within the cluster |
| `GEODE_MAX_SHARDS` | `16` | Maximum number of shards |
| `GEODE_QUERY_TIMEOUT_MS` | `30000` | Distributed query timeout |
| `GEODE_MAX_PARALLEL_QUERIES` | `10` | Maximum concurrent distributed queries |
| `GEODE_CONNECTION_POOL_SIZE` | `20` | Connections per cluster node |
| `GEODE_QUERY_CACHE_ENABLED` | `true` | Enable distributed query caching |
| `GEODE_QUERY_CACHE_TTL_MS` | `300000` | Query cache TTL (5 minutes) |
| `GEODE_QUERY_CACHE_MAX_ENTRIES` | `1000` | Maximum cached queries |
| `GEODE_RETRY_ATTEMPTS` | `3` | Connection retry attempts |
| `GEODE_CONNECTION_TIMEOUT_MS` | `5000` | Connection establishment timeout |
| `GEODE_HEARTBEAT_INTERVAL_MS` | `10000` | Cluster heartbeat interval |

### Encryption - Transparent Data Encryption (TDE)

| Variable | Default | Description |
|----------|---------|-------------|
| `GEODE_TDE_KEY` | - | AES-256-GCM encryption key (64 hex chars / 32 bytes) |
| `GEODE_ENABLE_TDE` | `false` | Enable Transparent Data Encryption |
| `GEODE_KMS_PROVIDER` | - | KMS provider: `local`, `vault`, `external`, `remote` |
| `GEODE_MASTER_KEY` | - | Master encryption key (hex) |

### Encryption - KMS Integration

| Variable | Default | Description |
|----------|---------|-------------|
| `VAULT_ADDR` | - | HashiCorp Vault address |
| `VAULT_TOKEN` | - | Vault authentication token |
| `GEODE_VAULT_KEY_PATH` | - | Vault secret path for encryption keys |

### Security & Access Control

| Variable | Default | Description |
|----------|---------|-------------|
| `GEODE_ENABLE_ABAC` | - | Enable attribute-based access control |
| `FIPS_MODE` | - | Enable FIPS 140-2 compliant cryptography |

### Monitoring & Telemetry

| Variable | Default | Description |
|----------|---------|-------------|
| `GEODE_METRICS_PORT` | `9091` | Prometheus metrics port |
| `GEODE_AUDIT_LOG_PATH` | - | Audit log file path |
| `GEODE_TELEMETRY_PAGING` | - | Enable telemetry paging |
| `GEODE_CDC_ENABLE` | - | Enable Change Data Capture |

### Backup & Recovery

| Variable | Default | Description |
|----------|---------|-------------|
| `S3_ENDPOINT` | - | S3-compatible backup endpoint |
| `S3_ACCESS_KEY` | - | S3 access key |
| `S3_SECRET_KEY` | - | S3 secret key |
| `S3_BUCKET` | - | S3 bucket for backups |
| `REDIS_URL` | - | Redis cache connection string |

### GPU Configuration (GPU image only)

| Variable | Default | Description |
|----------|---------|-------------|
| `GPU_ENABLED` | `false` | Enable GPU acceleration |
| `CUDA_VISIBLE_DEVICES` | - | GPU device selection |
| `NVIDIA_VISIBLE_DEVICES` | `all` | NVIDIA device visibility |
| `NVIDIA_DRIVER_CAPABILITIES` | `compute,utility` | NVIDIA capabilities |

### QUIC Performance

| Variable | Default | Description |
|----------|---------|-------------|
| `QUIC_GO_DISABLE_GSO` | - | Disable Generic Segmentation Offload |

## Command-Line Arguments

The container entrypoint is `geode serve`. Additional arguments can be passed:

```bash
docker run geodedb/geode:latest \
  --data-dir /data \
  --listen 0.0.0.0:3141 \
  --cert /certs/server.crt \
  --key /certs/server.key \
  --log-level info
```

| Argument | Description |
|----------|-------------|
| `--listen <addr:port>` | Bind address and port (default: `0.0.0.0:3141`) |
| `--data-dir <path>` | Data storage directory (default: `/data`) |
| `--cert <path>` | TLS certificate path |
| `--key <path>` | TLS private key path |
| `--log-level <level>` | Log level: `error`, `warn`, `info`, `debug` |
| `--gpu-acceleration` | Enable GPU acceleration (GPU image only) |

## Encryption Configuration

### Transparent Data Encryption (TDE)

TDE encrypts all data at rest using AES-256-GCM. Enable it by providing a 256-bit key:

```bash
# Generate a secure 256-bit key (64 hex characters)
openssl rand -hex 32

# Run with TDE enabled
docker run -d \
  --name geode-encrypted \
  -p 3141:3141/udp \
  -v geode-data:/data \
  -e GEODE_ENABLE_TDE=true \
  -e GEODE_TDE_KEY=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
  geodedb/geode:latest
```

### KMS Provider Integration

For enterprise deployments, integrate with HashiCorp Vault or other KMS providers:

```yaml
services:
  geode:
    image: geodedb/geode:latest
    environment:
      - GEODE_ENABLE_TDE=true
      - GEODE_KMS_PROVIDER=vault
      - VAULT_ADDR=http://vault:8200
      - VAULT_TOKEN=${VAULT_TOKEN}
      - GEODE_VAULT_KEY_PATH=geode/encryption
    depends_on:
      - vault

  vault:
    image: hashicorp/vault:latest
    cap_add:
      - IPC_LOCK
    environment:
      - VAULT_DEV_ROOT_TOKEN_ID=${VAULT_TOKEN}
    ports:
      - "8200:8200"
```

### Vault Setup for TDE

```bash
# Enable KV secrets engine
vault secrets enable -path=geode kv-v2

# Store master encryption key
vault kv put geode/encryption \
  key="$(openssl rand -hex 32)"

# Configure access policy
vault policy write geode-tde - <<EOF
path "geode/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
EOF
```

### Field-Level Encryption (FLE)

Geode supports field-level encryption for sensitive properties:

```bash
docker run -d \
  --name geode \
  -e GEODE_ENABLE_TDE=true \
  -e GEODE_TDE_KEY=${TDE_KEY} \
  geodedb/geode:latest
```

Use GQL to define encrypted fields:

```gql
CREATE NODE TYPE Person (
  name STRING,
  ssn STRING ENCRYPTED,
  email STRING ENCRYPTED
)
```

## Clustering Configuration

### Distributed Query Coordination

Geode supports distributed query execution across multiple shards with automatic load balancing and result merging.

### 3-Node Cluster with Docker Compose

```yaml
version: '3.8'

services:
  geode-node1:
    image: geodedb/geode:latest
    container_name: geode-node1
    hostname: geode-node1
    ports:
      - "3141:3141/udp"
      - "9091:9091/tcp"
    environment:
      - LOG_LEVEL=info
      - GEODE_CLUSTER_NAME=production
      - GEODE_NODE_ID=1
      - GEODE_MAX_SHARDS=16
      - GEODE_DATA_DIR=/data
      - GEODE_HEARTBEAT_INTERVAL_MS=10000
      - GEODE_CONNECTION_POOL_SIZE=20
    volumes:
      - geode-node1-data:/data
      - ./certs:/certs:ro
    networks:
      - geode-cluster
    sysctls:
      - net.core.rmem_max=7340032
      - net.core.wmem_max=7340032

  geode-node2:
    image: geodedb/geode:latest
    container_name: geode-node2
    hostname: geode-node2
    ports:
      - "3142:3141/udp"
      - "9092:9091/tcp"
    environment:
      - LOG_LEVEL=info
      - GEODE_CLUSTER_NAME=production
      - GEODE_NODE_ID=2
      - GEODE_MAX_SHARDS=16
      - GEODE_DATA_DIR=/data
      - GEODE_HEARTBEAT_INTERVAL_MS=10000
      - GEODE_CONNECTION_POOL_SIZE=20
    volumes:
      - geode-node2-data:/data
      - ./certs:/certs:ro
    networks:
      - geode-cluster
    sysctls:
      - net.core.rmem_max=7340032
      - net.core.wmem_max=7340032

  geode-node3:
    image: geodedb/geode:latest
    container_name: geode-node3
    hostname: geode-node3
    ports:
      - "3143:3141/udp"
      - "9093:9091/tcp"
    environment:
      - LOG_LEVEL=info
      - GEODE_CLUSTER_NAME=production
      - GEODE_NODE_ID=3
      - GEODE_MAX_SHARDS=16
      - GEODE_DATA_DIR=/data
      - GEODE_HEARTBEAT_INTERVAL_MS=10000
      - GEODE_CONNECTION_POOL_SIZE=20
    volumes:
      - geode-node3-data:/data
      - ./certs:/certs:ro
    networks:
      - geode-cluster
    sysctls:
      - net.core.rmem_max=7340032
      - net.core.wmem_max=7340032

volumes:
  geode-node1-data:
  geode-node2-data:
  geode-node3-data:

networks:
  geode-cluster:
    driver: bridge
```

### Cluster with Encryption

```yaml
version: '3.8'

services:
  geode-node1:
    image: geodedb/geode:latest
    container_name: geode-node1
    environment:
      - GEODE_CLUSTER_NAME=secure-cluster
      - GEODE_NODE_ID=1
      - GEODE_ENABLE_TDE=true
      - GEODE_KMS_PROVIDER=vault
      - VAULT_ADDR=http://vault:8200
      - VAULT_TOKEN=${VAULT_TOKEN}
      - GEODE_VAULT_KEY_PATH=geode/cluster/node1
    volumes:
      - geode-node1-data:/data
    depends_on:
      - vault
    networks:
      - geode-cluster

  geode-node2:
    image: geodedb/geode:latest
    container_name: geode-node2
    environment:
      - GEODE_CLUSTER_NAME=secure-cluster
      - GEODE_NODE_ID=2
      - GEODE_ENABLE_TDE=true
      - GEODE_KMS_PROVIDER=vault
      - VAULT_ADDR=http://vault:8200
      - VAULT_TOKEN=${VAULT_TOKEN}
      - GEODE_VAULT_KEY_PATH=geode/cluster/node2
    volumes:
      - geode-node2-data:/data
    depends_on:
      - vault
    networks:
      - geode-cluster

  vault:
    image: hashicorp/vault:latest
    cap_add:
      - IPC_LOCK
    environment:
      - VAULT_DEV_ROOT_TOKEN_ID=${VAULT_TOKEN}
    ports:
      - "8200:8200"
    networks:
      - geode-cluster

volumes:
  geode-node1-data:
  geode-node2-data:

networks:
  geode-cluster:
    driver: bridge
```

### Distributed Query Performance

| Operation Type | Single Node | 2 Shards | 4 Shards | 8 Shards | Scaling |
|---------------|-------------|----------|----------|----------|---------|
| Simple MATCH | 10ms | 15ms | 20ms | 30ms | Sub-linear |
| Ordered Query | 50ms | 75ms | 100ms | 150ms | Linear |
| Aggregation | 100ms | 60ms | 40ms | 30ms | Super-linear |
| Top-K (LIMIT) | 80ms | 50ms | 35ms | 25ms | Super-linear |

## Health Checks

The container includes a built-in health check:

```dockerfile
HEALTHCHECK --interval=30s --timeout=3s --start-period=5s --retries=3 \
    CMD ["geode", "query", "RETURN 1 AS health", "--server", "127.0.0.1:3141", "--insecure"]
```

## QUIC Performance Tuning

For optimal QUIC throughput, increase UDP buffer sizes:

```bash
# Using Docker sysctls (recommended)
docker run -d \
  --sysctl net.core.rmem_max=7340032 \
  --sysctl net.core.wmem_max=7340032 \
  geodedb/geode:latest

# Or configure host system
sudo sysctl -w net.core.rmem_max=7340032
sudo sysctl -w net.core.wmem_max=7340032
```

## Docker Compose Example

```yaml
services:
  geode:
    image: geodedb/geode:latest
    container_name: geode
    restart: unless-stopped
    ports:
      - "3141:3141/udp"
      - "9091:9091/tcp"
    environment:
      - LOG_LEVEL=info
      - GEODE_DATA_DIR=/data
    volumes:
      - geode-data:/data
      - ./certs:/certs:ro
    command:
      - "--data-dir"
      - "/data"
      - "--listen"
      - "0.0.0.0:3141"
      - "--cert"
      - "/certs/server.crt"
      - "--key"
      - "/certs/server.key"
    sysctls:
      - net.core.rmem_max=7340032
      - net.core.wmem_max=7340032
    healthcheck:
      test: ["CMD", "geode", "query", "RETURN 1 AS health", "--server", "127.0.0.1:3141", "--insecure"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s

volumes:
  geode-data:
```

## GPU Docker Compose Example

```yaml
services:
  geode-gpu:
    image: geodedb/geode:gpu
    container_name: geode-gpu
    restart: unless-stopped
    ports:
      - "3141:3141/udp"
      - "9091:9091/tcp"
    environment:
      - LOG_LEVEL=info
      - GPU_ENABLED=true
      - CUDA_VISIBLE_DEVICES=0
      - NVIDIA_VISIBLE_DEVICES=all
      - NVIDIA_DRIVER_CAPABILITIES=compute,utility
    volumes:
      - geode-data:/data
      - ./certs:/certs:ro
    command:
      - "--data-dir"
      - "/data"
      - "--listen"
      - "0.0.0.0:3141"
      - "--gpu-acceleration"
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]

volumes:
  geode-data:
```

## Production Deployment with Monitoring

For production deployments, use the full stack with monitoring:

```yaml
services:
  geode:
    image: geodedb/geode:latest
    ports:
      - "3141:3141/udp"
      - "9091:9091/tcp"
    environment:
      - LOG_LEVEL=info
      - GEODE_ENABLE_TDE=true
      - GEODE_KMS_PROVIDER=vault
      - VAULT_ADDR=http://vault:8200
      - VAULT_TOKEN=${VAULT_TOKEN}
      - GEODE_VAULT_KEY_PATH=geode/encryption
      - REDIS_URL=redis://:${REDIS_PASSWORD}@redis:6379
      - S3_ENDPOINT=http://minio:9000
      - S3_ACCESS_KEY=${S3_ACCESS_KEY}
      - S3_SECRET_KEY=${S3_SECRET_KEY}
      - S3_BUCKET=geode-backups
    volumes:
      - geode-data:/data
      - geode-logs:/var/log/geode
      - ./certs:/certs:ro
    depends_on:
      - vault
      - redis
      - minio

  vault:
    image: hashicorp/vault:latest
    cap_add:
      - IPC_LOCK
    environment:
      - VAULT_DEV_ROOT_TOKEN_ID=${VAULT_TOKEN}
    ports:
      - "8200:8200"

  redis:
    image: redis:alpine
    command: redis-server --requirepass ${REDIS_PASSWORD}
    ports:
      - "6379:6379"

  minio:
    image: minio/minio:latest
    command: server /data --console-address ":9001"
    environment:
      - MINIO_ROOT_USER=${S3_ACCESS_KEY}
      - MINIO_ROOT_PASSWORD=${S3_SECRET_KEY}
    ports:
      - "9000:9000"
      - "9001:9001"
    volumes:
      - minio-data:/data

  prometheus:
    image: prom/prometheus:latest
    ports:
      - "9090:9090"
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro

  grafana:
    image: grafana/grafana:latest
    ports:
      - "3000:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_PASSWORD}

volumes:
  geode-data:
  geode-logs:
  minio-data:
```

## Security Considerations

1. **TLS Certificates**: Always mount certificates read-only (`:ro`)
2. **Non-root User**: Container runs as user `geode` (UID 10000)
3. **Secret Management**: Use Docker secrets or Vault for sensitive values
4. **Network Isolation**: Use Docker networks to isolate database traffic
5. **FIPS Mode**: Set `FIPS_MODE=enabled` for FIPS 140-2 compliant cryptography
6. **Encryption at Rest**: Enable TDE for data protection
7. **Key Rotation**: Use KMS providers for automated key rotation

## Connecting to Geode

### Using the CLI

```bash
# Interactive shell
docker exec -it geode geode shell --server 127.0.0.1:3141

# Execute a query
docker exec geode geode query "MATCH (n) RETURN count(n)" --server 127.0.0.1:3141
```

### Client Libraries

Connect using any official client library:

- **Go**: `geodedb.com/geode`
- **Python**: `geode-client-python`
- **Rust**: `geode-client-rust`
- **Zig**: `geode-client-zig`

All clients connect via QUIC on port 3141 using JSON line protocol.

## Troubleshooting

### Container won't start

Check if port 3141/udp is available:

```bash
docker logs geode
ss -ulpn | grep 3141
```

### Connection refused

Ensure QUIC (UDP) traffic is allowed:

```bash
# Test connectivity
docker exec geode geode query "RETURN 1" --server 127.0.0.1:3141 --insecure
```

### GPU not detected

Verify NVIDIA Container Toolkit:

```bash
docker run --rm --gpus all nvidia/cuda:12.3.2-base-ubuntu22.04 nvidia-smi
```

### TDE key errors

Ensure the TDE key is exactly 64 hex characters:

```bash
# Verify key length
echo -n "$GEODE_TDE_KEY" | wc -c  # Should output 64
```

### Cluster nodes not connecting

1. Verify all nodes are on the same Docker network
2. Check `GEODE_CLUSTER_NAME` matches across nodes
3. Ensure unique `GEODE_NODE_ID` for each node
4. Verify UDP connectivity between containers

### Performance issues

1. Increase UDP buffer sizes (see QUIC Performance Tuning)
2. Check memory limits: `docker stats geode`
3. Enable debug logging: `-e LOG_LEVEL=debug`
4. For clusters, verify `GEODE_CONNECTION_POOL_SIZE` is adequate

## Additional Resources

- [API Reference](https://geodedb.com/docs/api-reference/)
- [GQL Compliance](https://geodedb.com/docs/gql)
- [Feature Overview](https://geodedb.com/docs/features)
- [GitLab Issues](https://gitlab.com/devnw/codepros/geode/geode/-/issues)

---

**License**: Apache License 2.0
**Copyright**: 2025-2026 CodePros
