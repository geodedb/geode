# Docker Build Guide

This directory contains optimized Docker configurations for building and running Geode in production.

## CI/CD Docker Images

The recommended approach is to use pre-built Docker images from the CI/CD pipeline, which are built from pre-compiled binaries and avoid slow recompilation.

### Quick Start

```bash
# Pull from GitHub Container Registry
docker pull ghcr.io/spyderorg/geode:latest

# Run the container
docker run -d -p 8443:8443/udp --name geode ghcr.io/spyderorg/geode:latest

# With GPU support
docker run -d -p 8443:8443/udp --gpus all --name geode ghcr.io/spyderorg/geode:gpu

# Alpine-based (smaller size)
docker run -d -p 8443:8443/udp --name geode ghcr.io/spyderorg/geode:alpine
```

## Available Images

| Image Tag | Base | Size | Use Case |
|-----------|------|------|----------|
| `latest` | Debian Bookworm | ~250MB | General purpose, recommended |
| `alpine` | Alpine 3.19 | ~80MB | Minimal size, musl-based |
| `gpu` | NVIDIA CUDA 12.6 | ~1.2GB | GPU acceleration support |

## Local Development Builds

For local development, you can build images from the CI Dockerfiles after compiling binaries:

```bash
# Build binaries first
zig build -Doptimize=ReleaseSafe

# Build Docker image using pre-built binaries
docker build -f Dockerfile.ci -t geode:local .

# Or for Alpine
zig build -Dtarget=x86_64-linux-musl -Doptimize=ReleaseSafe
docker build -f Dockerfile.ci.alpine -t geode:alpine-local .
```

## CI/CD Dockerfiles

The CI/CD pipeline uses lightweight Dockerfiles that avoid recompilation:

### 1. Dockerfile.ci (Debian-based)
- Uses pre-built binaries from pipeline artifacts
- Debian Bookworm base for compatibility
- Runtime dependencies only
- ~250MB final size

### 2. Dockerfile.ci.alpine (Alpine-based)
- Uses musl-compiled binaries
- Alpine 3.19 base for minimal size
- Static linking for portability
- ~80MB final size

### 3. Dockerfile.ci.gpu (GPU-enabled)
- Uses pre-built binaries from pipeline artifacts
- NVIDIA CUDA 12.6 base for GPU support
- Vulkan support included
- ~1.2GB final size

## Key Optimizations

### 1. No Recompilation in Docker
- Binaries are compiled once in the CI pipeline
- Docker images simply copy pre-built binaries
- **Result**: 10x faster Docker builds, no disk space issues

### 2. Multi-Platform Support
- amd64 (x86_64) and arm64 (ARM64) support
- Built from native artifacts for each platform
- No QEMU emulation overhead during builds

### 3. Security Scanning
- All images scanned with Trivy for vulnerabilities
- Results uploaded to GitHub Security tab
- Automated scanning on every build

### 4. Minimal Runtime Dependencies
- Only ca-certificates, openssl, and libvulkan1
- No build tools in final images
- Non-root user (geode:1000)

### 5. .dockerignore
Excludes unnecessary files from build context:
- Documentation (~50MB)
- Test files (~100MB)
- Build artifacts (~500MB)
- **Result**: 95% smaller build context

## GitHub Actions Integration

Docker builds are integrated into `.github/workflows/build.yml` and `.github/workflows/release.yml`:

### Build Pipeline Integration
1. **Build binaries** in build-and-test job
2. **Upload artifacts** to GitHub Actions
3. **Download artifacts** in docker-build job
4. **Build Docker images** using pre-built binaries
5. **Security scan** with Trivy
6. **Push to registry** (ghcr.io)

### Build Cache
```yaml
cache-from: type=gha,scope=debian
cache-to: type=gha,mode=max,scope=debian
```
- Uses GitHub Actions cache
- Separate cache scopes per variant
- **Result**: Instant Docker builds (binaries already compiled)

## Image Variants

| Dockerfile | Base | Binaries | Use Case |
|------------|------|----------|----------|
| `Dockerfile.ci` | Debian Bookworm | GNU libc | General purpose, maximum compatibility |
| `Dockerfile.ci.alpine` | Alpine 3.19 | musl libc | Minimal size, static linking |
| `Dockerfile.ci.gpu` | NVIDIA CUDA 12.6 | GNU libc | GPU acceleration, Vulkan support |

No build arguments required - images use pre-built binaries from artifacts.

## Image Sizes

| Variant | Uncompressed | Compressed (registry) |
|---------|--------------|----------------------|
| Debian (latest) | ~250MB | ~90MB |
| Alpine | ~80MB | ~30MB |
| GPU (CUDA) | ~1.2GB | ~450MB |

## Security Features

1. **Non-root user**: Runs as `geode` user (UID 1000)
2. **Minimal attack surface**: Only runtime dependencies
3. **Health checks**: Built-in container health monitoring
4. **No build tools**: gcc, make, etc. not in final image

## Troubleshooting

### Build fails with missing binaries
- Ensure you've compiled binaries first: `zig build -Doptimize=ReleaseSafe`
- For Alpine: Use musl target: `zig build -Dtarget=x86_64-linux-musl`
- Check `zig-out/bin/` directory exists and contains binaries

### Permission denied
- Images run as non-root user `geode:1000`
- Mount volumes with proper ownership: `docker run -v ./data:/data:rw`
- Or override user: `docker run --user root`

### GPU not detected
```bash
# Verify NVIDIA runtime
docker run --rm --gpus all nvidia/cuda:12.6.0-base nvidia-smi

# If successful, Geode should work
docker run --rm --gpus all geode:latest query "RETURN gpu.available()"
```

## Performance Benchmarks

| Metric | Old (Compilation) | New (Artifacts) | Improvement |
|--------|-------------------|-----------------|-------------|
| Docker build time | 15min | 30sec | 97% faster |
| CI build minutes | 15 | 0.5 | 97% reduction |
| Image size (Debian) | 3.2GB | 250MB | 92% smaller |
| Image size (Alpine) | N/A | 80MB | Minimal |
| Disk space issues | Frequent | Never | 100% reliable |
| Multi-platform builds | Slow (QEMU) | Fast (native) | 10x faster |

## Advanced Usage

### Local development with cache
```bash
# Export cache to local directory
docker build --cache-to type=local,dest=/tmp/docker-cache \
             -f Dockerfile.prod -t geode .

# Use cache on next build
docker build --cache-from type=local,src=/tmp/docker-cache \
             -f Dockerfile.prod -t geode .
```

### Multi-platform builds
```bash
docker buildx build --platform linux/amd64,linux/arm64 \
                    -f Dockerfile.prod -t geode:multi .
```

## Related Files

- `Dockerfile.ci` - Lightweight Debian-based image (uses pre-built binaries)
- `Dockerfile.ci.alpine` - Lightweight Alpine-based image (uses musl binaries)
- `Dockerfile.ci.gpu` - GPU-enabled image (NVIDIA CUDA base)
- `Dockerfile` - Legacy multi-stage build (slower, for reference)
- `Dockerfile.prod` - Legacy production build (slower, for reference)
- `.dockerignore` - Build context exclusions
- `.github/workflows/build.yml` - Main CI/CD pipeline with Docker builds
- `.github/workflows/release.yml` - Release pipeline with Docker builds
