# Geode Docker Guide

Complete documentation for Docker deployment and development with Geode.

## Table of Contents

- [Quick Start](#quick-start)
- [Pre-built Images](#pre-built-images)
- [Development Environment](#development-environment)
- [Production Deployment](#production-deployment)
- [Distributed Deployment](#distributed-deployment)
- [Configuration Reference](#configuration-reference)
- [Security & FIPS](#security--fips)
- [Troubleshooting](#troubleshooting)

---

## Quick Start

### Using Pre-built Images (Fastest)

```bash
# Pull from GitHub Container Registry
docker pull ghcr.io/spyderorg/geode:latest

# Run the container
docker run -d -p 8443:8443/udp --name geode ghcr.io/spyderorg/geode:latest

# Test connectivity
docker exec geode geode query "RETURN 1 AS health" --server 127.0.0.1:8443
```

### Development Environment (5 Minutes)

```bash
# Start development environment
./dev.sh start

# Open development shell
./dev.sh shell

# Build Geode
zb

# Run tests
make test
```

---

## Pre-built Images

### Available Variants

| Image Tag | Base | Size | Use Case |
|-----------|------|------|----------|
| `latest` | Debian Bookworm | ~250MB | General purpose, recommended |
| `alpine` | Alpine 3.19 | ~80MB | Minimal size, musl-based |
| `gpu` | NVIDIA CUDA 12.6 | ~1.2GB | GPU acceleration support |
| `prod` | Distroless | ~180MB | Production, minimal attack surface |

### Pull Commands

```bash
# Standard (recommended)
docker pull ghcr.io/spyderorg/geode:latest

# Alpine (smaller)
docker pull ghcr.io/spyderorg/geode:alpine

# GPU support
docker pull ghcr.io/spyderorg/geode:gpu

# Production optimized
docker pull ghcr.io/spyderorg/geode:prod
```

### Running Pre-built Images

```bash
# Basic server
docker run -d -p 8443:8443/udp ghcr.io/spyderorg/geode:latest

# With persistent data
docker run -d -p 8443:8443/udp \
  -v ./data:/data \
  ghcr.io/spyderorg/geode:latest --data-dir /data

# With TLS certificates
docker run -d -p 8443:8443/udp \
  -v ./certs:/certs:ro \
  -v ./data:/data \
  ghcr.io/spyderorg/geode:latest \
  --data-dir /data \
  --cert /certs/server.crt \
  --key /certs/server.key

# With GPU support
docker run -d -p 8443:8443/udp --gpus all ghcr.io/spyderorg/geode:gpu
```

---

## Development Environment

A complete Docker-based development environment replicating the Nix flake setup.

### What's Included

- **Zig 0.15.1** - Primary build system
- **Python 3.12** - Test harness and geodetestlab
- **OpenSSL 3.3.2 with FIPS** - Enterprise cryptography
- **MsQUIC v2.5.4** - High-performance QUIC implementation
- **HashiCorp Vault** - Secrets management
- **MinIO** - S3-compatible storage
- **Redis** - Caching layer
- **Optional**: Prometheus + Grafana monitoring

### Prerequisites

- Docker 20.10+
- Docker Compose 1.29+
- 8GB+ RAM
- 20GB+ disk space

### Setup & Usage

```bash
# Start environment (first build ~10 minutes)
./dev.sh start

# Check service health
./dev.sh status

# Enter development shell
./dev.sh shell

# Build Geode (inside shell)
zb          # Debug build
zbr         # Release build
zbt         # Build with tests

# Run tests
make test
make geodetestlab
make verify-fast

# Start Geode server
./zig-out/bin/geode serve --listen 127.0.0.1:9999

# View logs
./dev.sh logs -f

# Stop environment
./dev.sh stop

# Full cleanup (removes volumes)
./dev.sh down
```

### Development Commands

| Command | Description |
|---------|-------------|
| `./dev.sh start` | Start development environment |
| `./dev.sh stop` | Stop development environment |
| `./dev.sh restart` | Restart development environment |
| `./dev.sh shell` | Open interactive shell |
| `./dev.sh exec <cmd>` | Execute command in container |
| `./dev.sh build` | Build geode project |
| `./dev.sh test` | Run tests |
| `./dev.sh clean` | Clean build artifacts |
| `./dev.sh logs [-f]` | View logs |
| `./dev.sh status` | Show service status |
| `./dev.sh down` | Remove containers and volumes |
| `./dev.sh rebuild` | Rebuild Docker image |
| `./dev.sh monitoring` | Start with Prometheus + Grafana |

### Service Access

| Service | Port | Credentials |
|---------|------|-------------|
| Vault | 8200 | Token: `geode-dev-token` |
| MinIO Console | 9001 | `admin` / `geode-dev-secret-123` |
| Redis | 6379 | Password: `geode-dev-password` |
| Prometheus | 9090 | None |
| Grafana | 3000 | `admin` / `geode-dev-password` |

---

## Production Deployment

### Building Production Images

```bash
# Build complete production image
./docker-build.sh all geode:latest

# Or build specific stages
./docker-build.sh openssl     # OpenSSL FIPS only
./docker-build.sh msquic      # MsQUIC only
./docker-build.sh builder     # Full Geode build
./docker-build.sh runtime     # Production runtime
```

### Multi-Stage Build Architecture

1. **Stage 1 - OpenSSL FIPS Builder**: Compiles OpenSSL 3.3.2 with FIPS module
2. **Stage 2 - MsQUIC Builder**: Builds Microsoft MsQUIC v2.5.5
3. **Stage 3 - Geode Builder**: Compiles Geode with all dependencies
4. **Stage 4 - Runtime**: Minimal Debian base with only runtime dependencies

### Production Deployment

```bash
# Run with production configuration
docker run -d \
  --name geode-prod \
  --restart=unless-stopped \
  -p 8443:8443/udp \
  -v /var/lib/geode:/data \
  -v /etc/geode/certs:/certs:ro \
  -e LOG_LEVEL=warn \
  geode:latest \
  --data-dir /data \
  --cert /certs/server.crt \
  --key /certs/server.key \
  --listen 0.0.0.0:8443
```

### Docker Compose (Single Node)

```yaml
version: '3.8'

services:
  geode:
    image: ghcr.io/spyderorg/geode:latest
    container_name: geode-server
    ports:
      - "8443:8443/udp"
      - "9090:9090"
    volumes:
      - geode-data:/data
      - ./certs:/certs:ro
    environment:
      - GEODE_LOG_LEVEL=info
      - GEODE_MAX_CONNECTIONS=1000
    restart: unless-stopped
    healthcheck:
      test: ["CMD", "geode", "query", "RETURN 1", "--server", "127.0.0.1:8443"]
      interval: 30s
      timeout: 3s
      retries: 3

volumes:
  geode-data:
```

---

## Distributed Deployment

Deploy a 3-node Geode cluster with Raft consensus.

### Architecture

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
```

### Quick Start

```bash
# Start distributed cluster
make docker-up-distributed

# Or manually:
docker-compose -f docker-compose.distributed.yml up -d

# Check cluster status
docker-compose -f docker-compose.distributed.yml ps

# View logs
docker-compose -f docker-compose.distributed.yml logs -f

# Stop cluster
docker-compose -f docker-compose.distributed.yml down
```

### Cluster Environment Variables

```bash
NODE_ID=node-1
NODE_ROLE=leader|follower
CLUSTER_NAME=geode-cluster
GEODE_DISTRIBUTED=true
GEODE_SHARD_COUNT=3
GEODE_REPLICATION_FACTOR=2
```

---

## Configuration Reference

### Environment Variables

| Variable | Description | Default |
|----------|-------------|---------|
| `GEODE_LOG_LEVEL` | Log level (debug, info, warn, error) | info |
| `GEODE_MAX_CONNECTIONS` | Maximum concurrent connections | 1000 |
| `GEODE_CACHE_SIZE` | Query cache size | 1GB |
| `GEODE_WAL_SIZE_LIMIT` | WAL size limit | 10GB |
| `LOG_LEVEL` | Alternative log level env var | error |
| `FIPS_MODE` | Enable FIPS mode | enabled |

### Volume Mounts

| Path | Description |
|------|-------------|
| `/data` | Persistent data storage (WAL, pages) |
| `/certs` | TLS certificates |
| `/var/log/geode` | Application logs |
| `/config` | Configuration files |

### Ports

| Port | Protocol | Description |
|------|----------|-------------|
| 8443 | UDP | QUIC with TLS 1.3 (primary) |
| 9090 | TCP | Prometheus metrics endpoint |

---

## Security & FIPS

### FIPS Mode

OpenSSL FIPS module is enabled by default. Verify with:

```bash
docker run --rm ghcr.io/spyderorg/geode:latest openssl version -a

# Check FIPS providers
docker exec <container> openssl list -providers
```

### Security Best Practices

```yaml
services:
  geode:
    image: ghcr.io/spyderorg/geode:prod
    read_only: true
    tmpfs:
      - /tmp
    security_opt:
      - no-new-privileges:true
    cap_drop:
      - ALL
    cap_add:
      - NET_BIND_SERVICE
```

### TLS Configuration

```bash
# Generate certificates
docker run --rm -v ./certs:/certs ghcr.io/spyderorg/geode:latest \
  cert_gen --output-dir /certs

# Verify certificates
openssl x509 -in ./certs/server.crt -text -noout
```

---

## Troubleshooting

### Container Won't Start

```bash
# Check logs
docker logs <container>
docker-compose logs geode

# Verify port availability
netstat -uapn | grep 8443
```

### Health Check Failures

```bash
# Test manually
docker exec <container> geode query "RETURN 1" --server 127.0.0.1:8443
```

### Permission Errors

```bash
# Fix ownership (from host)
sudo chown -R $(id -u):$(id -g) .

# Or set UID/GID in .env
echo "USER_UID=$(id -u)" > .env
echo "USER_GID=$(id -g)" >> .env
./dev.sh rebuild
```

### Port Conflicts

Edit `docker-compose.yml` and change the host port:

```yaml
ports:
  - "9443:8443/udp"  # Change host port (left side)
```

### Build Failures

```bash
# Rebuild from scratch
./dev.sh rebuild

# Try simple Dockerfile
docker build -f Dockerfile.simple -t geode:latest .
```

### Debug Mode

```bash
# Enable debug logging
docker run -e GEODE_LOG_LEVEL=debug ghcr.io/spyderorg/geode:latest

# Attach for debugging
docker exec -it <container> /bin/sh
```

### Performance Tuning

```bash
# Increase UDP buffer sizes for QUIC
docker run \
  --sysctl net.core.rmem_max=26214400 \
  --sysctl net.core.wmem_max=26214400 \
  --ulimit nofile=65536:65536 \
  ghcr.io/spyderorg/geode:latest
```

### Resource Limits

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

---

## Related Files

- `Dockerfile` - Multi-stage production build
- `Dockerfile.dev` - Development environment
- `Dockerfile.simple` - Fallback with inline Zig installation
- `docker-compose.yml` - Standard deployment
- `docker-compose.dev.yml` - Development orchestration
- `docker-compose.distributed.yml` - 3-node cluster
- `dev.sh` - Development helper script
- `docker-build.sh` - Build orchestration script

---

*Last Updated: December 2025*
