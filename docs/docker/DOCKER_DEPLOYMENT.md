# Docker Deployment Guide for Geode

This guide covers how to deploy Geode using Docker in both singleton and distributed configurations.

## Prerequisites

- Docker Engine 20.10+ and Docker Compose 1.29+
- At least 4GB RAM for singleton, 8GB for distributed deployment
- Port availability: 7567, 7569, 7571 (QUIC), 9090-9092 (metrics), 3000-3001 (Grafana)

## Quick Start

### Singleton Deployment

Deploy a single Geode instance:

```bash
# Build and start singleton instance
make docker-up-singleton

# Or manually:
docker-compose up -d

# Check status
docker-compose ps

# View logs
docker-compose logs -f geode

# Run tests
make docker-test-singleton

# Stop
docker-compose down
```

### Distributed Deployment

Deploy a 3-node Geode cluster with Raft consensus:

```bash
# Build and start distributed cluster
make docker-up-distributed

# Or manually:
docker-compose -f docker-compose.distributed.yml up -d

# Check cluster status
docker-compose -f docker-compose.distributed.yml ps

# View logs
docker-compose -f docker-compose.distributed.yml logs -f

# Run distributed tests
make docker-test-distributed

# Stop cluster
docker-compose -f docker-compose.distributed.yml down
```

## Architecture

### Singleton Configuration

```
┌─────────────────────────┐
│   Geode Singleton       │
│   - QUIC: 7567          │
│   - Metrics: 9090       │
└─────────────────────────┘
         │
    ┌────▼────┐
    │  Data   │
    │ Volume  │
    └─────────┘
```

### Distributed Configuration

```
       ┌──────────────┐
       │   HAProxy    │
       │  LB (7500)   │
       └──────┬───────┘
              │
    ┌─────────┴──────────┬──────────┐
    │                    │          │
┌───▼────┐         ┌────▼────┐ ┌───▼────┐
│ Leader │◄────────► Follow-1│ │Follow-2│
│  7567  │  Raft   │  7569   │ │  7571  │
└────────┘         └─────────┘ └────────┘
    │                    │          │
┌───▼────┐         ┌────▼────┐ ┌───▼────┐
│  Data  │         │  Data   │ │  Data  │
└────────┘         └─────────┘ └────────┘
```

## Configuration

### Environment Variables

Common environment variables for customization:

```bash
# Node configuration
NODE_ID=node-1
NODE_ROLE=leader|follower
CLUSTER_NAME=geode-cluster

# Performance tuning
GEODE_LOG_LEVEL=info|debug|error
GEODE_MAX_CONNECTIONS=1000
GEODE_CACHE_SIZE=1GB
GEODE_WAL_SIZE_LIMIT=10GB

# Distributed settings
GEODE_DISTRIBUTED=true
GEODE_SHARD_COUNT=3
GEODE_REPLICATION_FACTOR=2
```

### Volume Mounts

- `/data` - Persistent data storage (WAL, pages)
- `/certs` - TLS certificates
- `/var/log/geode` - Application logs

### Networking

Default network configuration:

- Singleton: `172.28.0.0/16`
- Distributed: `172.29.0.0/16`

## Monitoring

### Enable Monitoring Stack

Deploy with Prometheus and Grafana:

```bash
# Singleton with monitoring
docker-compose --profile monitoring up -d

# Distributed with monitoring
docker-compose -f docker-compose.distributed.yml up -d
```

Access points:

- Prometheus: http://localhost:9091 (singleton) or :9093 (distributed)
- Grafana: http://localhost:3000 (admin/admin)
- HAProxy Stats: http://localhost:8404/stats (distributed only)

### Metrics Available

- `geode_queries_total` - Total query count
- `geode_connections_active` - Active connections
- `geode_memory_used_bytes` - Memory usage
- `geode_wal_size_bytes` - WAL size
- `geode_transactions_total` - Transaction counts
- `geode_query_duration_seconds` - Query latency histogram

## Testing

### Automated Tests

```bash
# Run all Docker tests
make docker-test

# Test singleton deployment
./scripts/docker/test.sh singleton

# Test distributed deployment
./scripts/docker/test.sh distributed

# Verbose output
./scripts/docker/test.sh singleton true
```

### Manual Testing

```bash
# Connect to running container
docker exec -it geode-singleton bash

# Run queries via CLI
geodec "RETURN 1 AS x ORDER BY x LIMIT 1" --server 127.0.0.1:7567

# Test QUIC connectivity
geodec "RETURN 'hello' AS msg" --server 127.0.0.1:7567

# QUIC is the only network transport; stdio remains available via --no-quic when running client and server on the same host.
```

## Production Deployment

### Using Production Dockerfile

The `Dockerfile.prod` uses distroless base image for minimal attack surface:

```bash
# Build production image
docker build -t geode:prod -f Dockerfile.prod .

# Run with security options
docker run -d \
  --name geode-prod \
  --read-only \
  --security-opt no-new-privileges \
  --cap-drop ALL \
  --cap-add NET_BIND_SERVICE \
  -v geode-data:/data \
  -v geode-certs:/certs:ro \
  -p 7567:7567/udp \
  geode:prod
```

### TLS Configuration

Generate and use TLS certificates:

```bash
# Generate certificates
make cert-gen

# Or manually
./zig-out/bin/cert_gen

# Mount certificates
docker run -v ./certs:/certs:ro geode:latest \
  --listen-quic 0.0.0.0:7567 \
  --tls-cert /certs/server.crt \
  --tls-key /certs/server.key
```

### Resource Limits

Configure resource constraints:

```yaml
deploy:
  resources:
    limits:
      cpus: '4'
      memory: 8G
    reservations:
      cpus: '2'
      memory: 4G
```

## Troubleshooting

### Common Issues

1. **Container fails to start**

   ```bash
   # Check logs
   docker-compose logs geode

   # Verify port availability
   netstat -uapn | grep -E '7567|7569|7571'
   ```

2. **Health check failures**

   ```bash
   # Test health endpoint manually
   docker exec geode geodec "RETURN 1 AS health" --server 127.0.0.1:7567
   ```

3. **Cluster nodes not joining**

   ```bash
   # Check Raft logs
   docker-compose -f docker-compose.distributed.yml logs | grep -i raft

   # Verify network connectivity
   docker exec geode-leader ping geode-follower-1
   ```

4. **Performance issues**

   ```bash
   # Check resource usage
   docker stats geode

   # Increase memory limits
   docker-compose up -d --scale geode=1 --memory=8g
   ```

### Debug Mode

Enable debug logging:

```bash
# Set debug log level
docker run -e GEODE_LOG_LEVEL=debug geode:latest

# Attach to container for debugging
docker exec -it geode /bin/sh

# Use debug profile
docker-compose --profile debug up -d
```

## CI/CD Integration

### GitHub Actions Example

```yaml
name: Docker CI
on: [push, pull_request]

jobs:
  test:
    runs-on: ubuntu-latest
    steps:
      - uses: actions/checkout@v3

      - name: Build Docker images
        run: make docker-build

      - name: Run tests
        run: make docker-test

      - name: Push to registry
        if: github.ref == 'refs/heads/main'
        run: |
          docker tag geode:latest myregistry/geode:latest
          docker push myregistry/geode:latest
```

### Kubernetes Deployment

Example StatefulSet configuration:

```yaml
apiVersion: apps/v1
kind: StatefulSet
metadata:
  name: geode
spec:
  serviceName: geode
  replicas: 3
  selector:
    matchLabels:
      app: geode
  template:
    metadata:
      labels:
        app: geode
    spec:
      containers:
        - name: geode
          image: geode:latest
          ports:
            - containerPort: 7567
              protocol: UDP
          volumeMounts:
            - name: data
              mountPath: /data
  volumeClaimTemplates:
    - metadata:
        name: data
      spec:
        accessModes: ['ReadWriteOnce']
        resources:
          requests:
            storage: 10Gi
```

## Backup and Recovery

### Backup Data

```bash
# Backup singleton data
docker run --rm -v geode-data:/data -v $(pwd):/backup alpine \
  tar czf /backup/geode-backup-$(date +%Y%m%d).tar.gz /data

# Backup distributed cluster
for node in leader follower-1 follower-2; do
  docker run --rm -v geode-${node}-data:/data -v $(pwd):/backup alpine \
    tar czf /backup/geode-${node}-backup-$(date +%Y%m%d).tar.gz /data
done
```

### Restore Data

```bash
# Restore singleton data
docker run --rm -v geode-data:/data -v $(pwd):/backup alpine \
  tar xzf /backup/geode-backup-20240101.tar.gz -C /

# Restore and start
docker-compose up -d
```

## Performance Tuning

### Docker Settings

```bash
# Increase container limits
docker update --memory="8g" --memory-swap="8g" --cpus="4" geode

# Enable host networking for better performance
docker run --network=host geode:latest
```

### Geode Optimization

```bash
# Run with optimized settings
docker run -d \
  -e GEODE_CACHE_SIZE=4GB \
  -e GEODE_WAL_SIZE_LIMIT=20GB \
  -e GEODE_MAX_CONNECTIONS=5000 \
  --sysctl net.core.somaxconn=65535 \
  --ulimit nofile=65536:65536 \
  geode:latest
```

## Support

For issues or questions:

- Check logs: `docker-compose logs -f`
- GitHub Issues: https://gitlab.com/devnw/geode/geode/issues
- Documentation: /docs/README.md
