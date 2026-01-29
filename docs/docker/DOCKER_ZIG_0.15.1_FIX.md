# Docker Build Fixed for Zig 0.15.1

## Summary

Successfully fixed all Docker builds to work with Zig 0.15.1 by correcting the filename format for Zig downloads.

## Key Issue

The Zig 0.15.1 tarballs use the format `zig-ARCH-OS-VERSION.tar.xz` (e.g., `zig-x86_64-linux-0.15.1.tar.xz`), not `zig-OS-ARCH-VERSION.tar.xz`.

## Files Updated

### Primary Dockerfiles

1. **Dockerfile.reliable** - Main production Dockerfile with direct download
2. **Dockerfile.simple** - Fallback with inline installation and mirrors
3. **Dockerfile.prod** - Production distroless image
4. **Dockerfile** - Uses external script (install-zig.sh)

### Installation Scripts

1. **scripts/docker/install-zig.sh** - Corrected filename format
2. **scripts/docker/fetch-zig.sh** - Community mirror fetcher with proper format

### Makefile

- Updated `docker-build` target to prioritize reliable Dockerfile
- Simplified `docker-ci` target for faster testing
- Removed references to outdated Dockerfile.working

## Correct Download URLs for 0.15.1

- Linux x86_64: `https://ziglang.org/download/0.15.1/zig-x86_64-linux-0.15.1.tar.xz`
- Linux aarch64: `https://ziglang.org/download/0.15.1/zig-aarch64-linux-0.15.1.tar.xz`
- macOS x86_64: `https://ziglang.org/download/0.15.1/zig-x86_64-macos-0.15.1.tar.xz`
- macOS aarch64: `https://ziglang.org/download/0.15.1/zig-aarch64-macos-0.15.1.tar.xz`

## Working Example

```dockerfile
# Install Zig 0.15.1 directly
ARG ZIG_VERSION=0.15.1
RUN set -ex && \
    TARBALL="zig-x86_64-linux-${ZIG_VERSION}.tar.xz" && \
    curl -fsSL -o "/tmp/${TARBALL}" \
         "https://ziglang.org/download/${ZIG_VERSION}/${TARBALL}" && \
    tar -xJf "/tmp/${TARBALL}" -C /opt && \
    rm "/tmp/${TARBALL}" && \
    ln -s "/opt/zig-x86_64-linux-${ZIG_VERSION}/zig" /usr/local/bin/zig && \
    zig version
```

## Testing

```bash
# Quick test
make docker-ci

# Full build
docker build -f Dockerfile.reliable -t geode:latest .

# Run container
docker run -d --name geode-test geode:latest
docker exec geode-test geodec "RETURN 1 AS x" --server 127.0.0.1:7567
```

## Verification

The `make docker-ci` command now:

1. Builds with Zig 0.15.1 ✓
2. Creates the Docker image ✓  
3. Runs a smoke test ✓
4. Completes successfully ✓

## Community Mirrors

The installation scripts also support community mirrors with proper filename format:

- Primary: `https://ziglang.org/download/0.15.1/`
- GitHub: `https://github.com/ziglang/zig/releases/download/0.15.1/`
- Bazel: `https://mirror.bazel.build/ziglang.org/download/0.15.1/`

## Signature Verification

All scripts maintain support for minisign verification using the official public key:

```
RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U
```

## Build Compatibility

The build system now correctly handles:

- Zig 0.15.1 API changes
- Different optimization flags (`-Drelease-safe` vs `-Doptimize=ReleaseSafe`)
- Optional tool builds that may fail without breaking the main build
