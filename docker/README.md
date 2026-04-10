# Docker Configuration

This directory and repository contain multiple Dockerfile variants for different use cases.

## Shared Resources (docker/)

| File | Purpose |
|------|---------|
| `docker/health-check.sh` | Shared health check script used by all server Dockerfiles (issue #549) |
| `Dockerfile.base` | Common Debian runtime base image (optional, for pre-built base workflows) |

### Health Check Consolidation (#549)

All Geode server containers use `docker/health-check.sh` as a single source of truth for
health checks instead of duplicating the inline HEALTHCHECK CMD across every Dockerfile.
The script respects `GEODE_HEALTH_PORT` (default 3141), `GEODE_USERNAME`, and `GEODE_PASSWORD`
environment variables.

## Dockerfile Overview

### Production Server (Root Directory)

| File | Purpose | Base Image |
|------|---------|------------|
| `Dockerfile` | Main development build | debian:bookworm-slim |
| `Dockerfile.base` | Shared runtime base | debian:bookworm-slim |
| `Dockerfile.prod` | Production build with GPU support | ubuntu:24.04 + nvidia/cuda |
| `Dockerfile.gpu` | GPU-enabled build | nvidia/cuda:12.3.2-devel |
| `Dockerfile.simple` | Simple fallback build | debian:bookworm-slim |
| `Dockerfile.reliable` | Reliable build with retry logic | debian:bookworm-slim |
| `Dockerfile.dev` | Full dev environment | ubuntu:24.04 |

### CI/CD (Root Directory)

| File | Purpose | Base Image |
|------|---------|------------|
| `Dockerfile.ci` | CI runtime (pre-built binaries) | debian:bookworm-slim |
| `Dockerfile.ci.alpine` | Alpine CI runtime | alpine:3.19 |
| `Dockerfile.ci.gpu` | GPU CI runtime | nvidia/cuda:12.6.0-base |

### Release (Root Directory)

| File | Purpose | Base Image |
|------|---------|------------|
| `Dockerfile.release` | Standard Debian release (GoReleaser) | debian:bookworm-slim |
| `Dockerfile.release.alpine` | Alpine release (GoReleaser) | alpine:3.19 |
| `Dockerfile.release.gpu` | GPU release (GoReleaser) | nvidia/cuda |

### Integration Tests (docker-integration/)

| File | Purpose | Base Image |
|------|---------|------------|
| `Dockerfile.server` | Geode server for integration tests | debian:bookworm-slim |
| `Dockerfile.client-go` | Go client integration tests | golang:1.24-bookworm |
| `Dockerfile.client-python` | Python client integration tests | python:3.11-slim |
| `Dockerfile.client-rust` | Rust client integration tests | rust:1.83-bookworm |
| `Dockerfile.client-zig` | Zig client integration tests | debian:bookworm-slim |
| `Dockerfile.geodetestlab` | Geodetestlab integration test runner | python:3.11-slim |

### Test Runners

| File | Purpose | Base Image |
|------|---------|------------|
| `geodetestlab/Dockerfile` | Geodetestlab Python test runner | python:3.11-slim |
| `tests/ha/Dockerfile.runner` | HA test runner | python:3.11-slim |

## Usage Examples

### Development Build

```bash
docker build -t geode:dev .
docker run -p 3141:3141/udp geode:dev
```

### Production Build

```bash
docker build -f Dockerfile.prod -t geode:prod .
docker run -p 3141:3141/udp geode:prod
```

### CI Build

```bash
docker build -f Dockerfile.ci -t geode:ci .
```

### Integration Tests

```bash
cd docker-integration
docker-compose up --build
```

## Consolidation Status

**Issue #549**: Health check logic and runtime setup consolidated via `docker/health-check.sh`
and `Dockerfile.base`. All 11 server-role Dockerfiles now reference the shared health check
script instead of duplicating the inline HEALTHCHECK CMD.

**Issue #408**: The Dockerfiles serve distinct purposes and are organized by use case.
Further consolidation into ~6 parameterized multi-target builds is tracked in issue #408.

## Notes

- All Dockerfiles use multi-stage builds where applicable
- GPU support requires NVIDIA container toolkit
- QUIC transport uses UDP port 3141
- Metrics server uses TCP port 9091
