# Docker Usage Guide for Geode

## Available Images

Geode provides multiple Docker images optimized for different use cases:

### Image Variants

1. **Standard Image** (`ghcr.io/[owner]/geode:latest`)
   - Based on Debian bookworm-slim
   - Includes all tools and utilities
   - Good for development and testing
   - Multi-platform: linux/amd64, linux/arm64

2. **Production Image** (`ghcr.io/[owner]/geode:prod`)
   - Based on distroless for minimal attack surface
   - Optimized with ReleaseFast
   - Stripped binaries for smaller size
   - Best for production deployments

3. **Alpine Image** (`ghcr.io/[owner]/geode:alpine`)
   - Based on Alpine Linux
   - Smaller image size
   - Good balance between size and functionality

## Quick Start

### Pull the Image

```bash
# Latest stable version
docker pull ghcr.io/[owner]/geode:latest

# Specific commit
docker pull ghcr.io/[owner]/geode:main-[sha]

# Production optimized
docker pull ghcr.io/[owner]/geode:prod
```

### Run the Server

#### QUIC Mode (Default)
```bash
# Run with auto-generated certificates
docker run -d \
  --name geode-server \
  -p 7567:7567/udp \
  -v geode-data:/data \
  ghcr.io/[owner]/geode:latest

# Run with custom certificates
docker run -d \
  --name geode-server \
  -p 7567:7567/udp \
  -v geode-data:/data \
  -v ./certs:/certs:ro \
  ghcr.io/[owner]/geode:latest \
  --cert /certs/server.crt \
  --key /certs/server.key
```

#### TCP Mode (Legacy)
```bash
docker run -d \
  --name geode-server \
  -p 7568:7568/tcp \
  -v geode-data:/data \
  ghcr.io/[owner]/geode:latest \
  --listen-tcp 0.0.0.0:7568
```

### Run Queries

#### Using the CLI
```bash
# Direct query
docker run --rm ghcr.io/[owner]/geode:latest \
  geodec "RETURN 1 AS x ORDER BY x LIMIT 1" --no-quic

# Connect to running server
docker run --rm --network container:geode-server \
  ghcr.io/[owner]/geode:latest \
  geodec "MATCH (n) RETURN n LIMIT 10" --server 127.0.0.1:7567
```

#### Interactive Session
```bash
docker run -it --rm \
  --network container:geode-server \
  ghcr.io/[owner]/geode:latest \
  /bin/sh
```

## Docker Compose

### Single Node Deployment

```yaml
version: '3.8'

services:
  geode:
    image: ghcr.io/[owner]/geode:latest
    container_name: geode-server
    ports:
      - "7567:7567/udp"  # QUIC
      - "7568:7568/tcp"  # TCP (optional)
      - "9090:9090"      # Metrics
    volumes:
      - geode-data:/data
      - ./certs:/certs:ro  # Optional: custom certificates
    environment:
      - GEODE_LOG_LEVEL=info
      - GEODE_MAX_CONNECTIONS=1000
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "geodec", "RETURN 1 AS health", "--server", "127.0.0.1:7567"]
      interval: 30s
      timeout: 3s
      retries: 3

volumes:
  geode-data:
    driver: local
```

### With Monitoring

```yaml
version: '3.8'

services:
  geode:
    image: ghcr.io/[owner]/geode:latest
    # ... geode config ...

  prometheus:
    image: prom/prometheus:latest
    volumes:
      - ./monitoring/prometheus.yml:/etc/prometheus/prometheus.yml:ro
      - prometheus-data:/prometheus
    ports:
      - "9091:9090"

  grafana:
    image: grafana/grafana:latest
    volumes:
      - grafana-data:/var/lib/grafana
      - ./monitoring/grafana:/etc/grafana/provisioning:ro
    ports:
      - "3000:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=admin

volumes:
  geode-data:
  prometheus-data:
  grafana-data:
```

## Building Custom Images

### Multi-stage Build Example

```dockerfile
# Build stage
FROM ghcr.io/[owner]/geode:latest as builder

# Your build steps here
COPY custom-config.gql /config/

# Runtime stage  
FROM ghcr.io/[owner]/geode:prod

COPY --from=builder /config/custom-config.gql /config/

# Custom entrypoint
ENTRYPOINT ["/usr/local/bin/geoded", "--config", "/config/custom-config.gql"]
```

## Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `GEODE_LOG_LEVEL` | Log level (debug, info, warn, error) | info |
| `GEODE_MAX_CONNECTIONS` | Maximum concurrent connections | 1000 |
| `GEODE_CACHE_SIZE` | Query cache size | 1GB |
| `GEODE_WAL_SIZE_LIMIT` | WAL size limit | 10GB |

## Volumes

| Path | Description |
|------|-------------|
| `/data` | Data directory for storage and WAL |
| `/certs` | TLS certificates directory |
| `/config` | Configuration files |

## Networking

### Ports

- **7567/udp** - QUIC with TLS 1.3 (default)
- **7568/tcp** - TCP (legacy compatibility)
- **9090/tcp** - Prometheus metrics endpoint

### Docker Networks

```bash
# Create custom network
docker network create geode-net

# Run server on network
docker run -d \
  --name geode-server \
  --network geode-net \
  ghcr.io/[owner]/geode:latest

# Connect client
docker run --rm \
  --network geode-net \
  ghcr.io/[owner]/geode:latest \
  geodec "RETURN 1" --server geode-server:7567
```

## Security Considerations

1. **Use Production Images**: For production, use the `:prod` tag which uses distroless base
2. **Custom Certificates**: Always use proper CA-signed certificates in production
3. **Network Isolation**: Use Docker networks to isolate database traffic
4. **Resource Limits**: Set appropriate CPU and memory limits
5. **Read-Only Root**: Consider running with read-only root filesystem

```yaml
services:
  geode:
    image: ghcr.io/[owner]/geode:prod
    read_only: true
    tmpfs:
      - /tmp
    volumes:
      - geode-data:/data
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
```

## Troubleshooting

### View Logs
```bash
docker logs geode-server
docker logs -f geode-server  # Follow logs
```

### Check Health
```bash
docker exec geode-server geodec "RETURN 1 AS health" --server 127.0.0.1:7567
```

### Debug Connection Issues
```bash
# Check if server is listening
docker exec geode-server ss -tuln | grep 7567

# Test from inside container
docker exec -it geode-server geodec "RETURN 1" --server 127.0.0.1:7567
```

### Certificate Issues
```bash
# Generate new certificates
docker run --rm -v certs:/certs ghcr.io/[owner]/geode:latest \
  cert_gen --output-dir /certs

# Verify certificates
docker run --rm -v certs:/certs:ro alpine:latest \
  openssl x509 -in /certs/server.crt -text -noout
```

## Performance Tuning

### Resource Allocation
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

### Kernel Parameters
```bash
# Increase UDP buffer sizes for QUIC
docker run --sysctl net.core.rmem_max=26214400 \
           --sysctl net.core.rmem_default=26214400 \
           --sysctl net.core.wmem_max=26214400 \
           --sysctl net.core.wmem_default=26214400 \
           ghcr.io/[owner]/geode:latest
```

## CI/CD Integration

### GitHub Actions Example
```yaml
- name: Test with Geode
  run: |
    docker run -d --name geode-test -p 7567:7567/udp \
      ghcr.io/[owner]/geode:latest
    
    # Wait for server
    for i in {1..30}; do
      if docker exec geode-test geodec "RETURN 1" --server 127.0.0.1:7567; then
        break
      fi
      sleep 1
    done
    
    # Run tests
    docker exec geode-test geodec "CREATE (n:Test {id: 1})"
    docker exec geode-test geodec "MATCH (n:Test) RETURN n"
```

## Multi-Platform Support

All images support multiple architectures:
- `linux/amd64` - Intel/AMD x86_64
- `linux/arm64` - ARM64/Apple Silicon

Docker automatically pulls the correct architecture for your platform.