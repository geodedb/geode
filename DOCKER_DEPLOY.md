# Geode Docker Deployment Guide

## Overview

The Geode database Docker image includes:
- **OpenSSL 3.3.2 with FIPS 140-2/140-3 Module** - Enterprise-grade cryptography
- **MsQUIC v2.5.5** - Microsoft's high-performance QUIC implementation
- **Zig 0.15.1** - Fast systems programming language
- **Geode Database** - Complete graph database with QUIC-only transport

## Quick Start

### Build the Image

```bash
# Build complete production image
./docker-build.sh all geode:latest

# Or build for specific stage
./docker-build.sh openssl     # OpenSSL FIPS only
./docker-build.sh msquic      # MsQUIC only
./docker-build.sh builder     # Full Geode build
./docker-build.sh runtime     # Production runtime (default)
```

### Run Geode Server

```bash
# Basic server
docker run -p 8443:8443/udp geode:latest

# With persistent data
docker run -p 8443:8443/udp \
  -v ./data:/data \
  geode:latest --data-dir /data

# With TLS certificates
docker run -p 8443:8443/udp \
  -v ./certs:/certs:ro \
  -v ./data:/data \
  geode:latest --data-dir /data --cert /certs/server.crt --key /certs/server.key
```

## Architecture

### Multi-Stage Build

The Dockerfile uses a 4-stage build process:

#### Stage 1: OpenSSL FIPS Builder
- Downloads and compiles OpenSSL 3.3.2
- Enables FIPS module for compliance
- Installs to `/opt/openssl-fips`
- Generates FIPS module configuration

#### Stage 2: MsQUIC Builder
- Clones Microsoft MsQUIC v2.5.5
- Builds with Release configuration
- Installs to `/opt/msquic`

#### Stage 3: Geode Builder
- Installs Zig 0.15.1 compiler
- Copies OpenSSL FIPS and MsQUIC from previous stages
- Builds Geode with all dependencies
- Compiles all tools and binaries

#### Stage 4: Runtime
- Minimal Debian bookworm-slim base
- Only runtime dependencies (ca-certificates, liblttng-ust1, libnuma1)
- Includes OpenSSL FIPS and MsQUIC libraries
- Non-root user (`geode:geode`)
- Health check configured

## Environment Variables

The runtime image sets:

```bash
OPENSSL_ROOT_DIR=/opt/openssl-fips
OPENSSL_CONF=/opt/openssl-fips/openssl.cnf
OPENSSL_MODULES=/opt/openssl-fips/lib64/ossl-modules
LD_LIBRARY_PATH=/opt/openssl-fips/lib64:/opt/msquic/lib
PATH=/opt/openssl-fips/bin:$PATH
LOG_LEVEL=error  # Can be overridden with -e LOG_LEVEL=debug
```

## Ports

- **8443/udp**: QUIC protocol (primary)
- **9090/tcp**: Metrics endpoint (optional)

## Volumes

### Data Directory
```bash
-v ./data:/data
```
Mount for persistent database storage.

### Certificates
```bash
-v ./certs:/certs:ro
```
Mount for TLS certificates (read-only recommended).

### Logs
```bash
-v ./logs:/var/log/geode
```
Mount for persistent logging.

## Advanced Configuration

### Multi-Platform Build

```bash
# Build for ARM64
./docker-build.sh all geode:arm64 linux/arm64

# Build for AMD64
./docker-build.sh all geode:amd64 linux/amd64
```

### Custom Build Arguments

```bash
docker build \
  --build-arg ZIG_VERSION=0.15.1 \
  --build-arg TARGETARCH=amd64 \
  -t geode:custom \
  .
```

### Development Mode

For development with debug logging:

```bash
docker run -p 8443:8443/udp \
  -e LOG_LEVEL=debug \
  -v ./data:/data \
  geode:latest
```

## Security Features

### FIPS Mode

OpenSSL FIPS module is enabled by default. Verify with:

```bash
docker run --rm geode:latest openssl version -a
```

### TLS Configuration

Geode uses QUIC-only transport with TLS 1.3:
- Certificate validation required (unless `--skip-verify` flag)
- Perfect forward secrecy
- Modern cipher suites only

### User Isolation

Runtime container runs as non-root user `geode` (UID 1000).

## Troubleshooting

### Health Check

The image includes a built-in health check:

```bash
docker inspect --format='{{.State.Health.Status}}' <container-id>
```

### Logs

View server logs:

```bash
docker logs <container-id>
```

### Verify FIPS

Check FIPS module is loaded:

```bash
docker exec <container-id> openssl list -providers
```

Should show:
```
Providers:
  default
    name: OpenSSL Default Provider
    ...
  fips
    name: OpenSSL FIPS Provider
    ...
```

## Integration with Test Harness

The Docker-built Geode server is compatible with the client test harness:

```bash
# Start server in Docker
docker run -d --name geode-test -p 8443:8443/udp geode:latest

# Run tests from host
cd clients/test-harness
make test SERVER=localhost:8443

# Cleanup
docker stop geode-test && docker rm geode-test
```

## Performance

### Build Time

- Stage 1 (OpenSSL FIPS): ~3-5 minutes
- Stage 2 (MsQUIC): ~2-3 minutes
- Stage 3 (Geode): ~1-2 minutes
- Stage 4 (Runtime): ~30 seconds

**Total**: ~7-11 minutes (first build), ~1-2 minutes (cached layers)

### Image Size

- Full builder image: ~2.5 GB
- Runtime image: ~450 MB
- Compressed: ~180 MB

## Related Files

- `Dockerfile` - Multi-stage build definition
- `docker-build.sh` - Build orchestration script
- `scripts/docker/install-zig.sh` - Zig installation with verification
- `clients/rust/Dockerfile` - Rust client Docker build

## Examples

### Production Deployment

```bash
# Build production image
./docker-build.sh all geode:v1.0

# Run with production configuration
docker run -d \
  --name geode-prod \
  --restart=unless-stopped \
  -p 8443:8443/udp \
  -v /var/lib/geode:/data \
  -v /etc/geode/certs:/certs:ro \
  -e LOG_LEVEL=warn \
  geode:v1.0 \
  --data-dir /data \
  --cert /certs/server.crt \
  --key /certs/server.key \
  --listen 0.0.0.0:8443
```

### Development Testing

```bash
# Quick test with ephemeral storage
docker run --rm -it \
  -p 8443:8443/udp \
  -e LOG_LEVEL=debug \
  geode:latest
```

---

*Last Updated: November 16, 2025*
*Geode Version: Production Ready*
*Docker Support: Complete*
