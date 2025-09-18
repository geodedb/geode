# Docker Build Fixes and Solutions

## Overview

The Docker build for Geode has been updated to handle Zig installation more reliably using community mirrors and signature verification.

## Key Changes

### 1. Zig Version Update
- Updated from Zig 0.13.0 to 0.15.1 to match the project requirements
- Fixed download URLs to use the correct paths for each version

### 2. Robust Installation Script
Created `scripts/docker/install-zig.sh` that:
- Tries multiple community mirrors for downloading Zig
- Includes signature verification using minisign
- Falls back gracefully if mirrors are unavailable
- Uses the official Zig public key: `RWSGOq2NVecA2UPNdBUZykf1CCb147pkmdtYxgb3Ti+JO/wCYvhbAb/U`

### 3. Multiple Dockerfiles

#### Dockerfile (Main)
- Uses the external installation script
- Requires `scripts/docker/install-zig.sh` to be present

#### Dockerfile.simple (Fallback)
- Self-contained with inline Zig installation
- Tries multiple mirrors in order
- Includes optional signature verification
- More resilient to build failures

#### Dockerfile.prod (Production)
- Minimal image using distroless base
- Security-hardened configuration

### 4. Docker Compose Configurations

- `docker-compose.yml` - Standard singleton deployment
- `docker-compose.test.yml` - Minimal test configuration
- `docker-compose.distributed.yml` - 3-node cluster setup
- `docker-compose.override.yml` - Development overrides

## Usage

### Quick Test
```bash
# Fastest way to test Docker setup
make docker-quick-test
```

### Standard Build
```bash
# Build with automatic fallback
make docker-build

# Or manually with simple Dockerfile
docker build -f Dockerfile.simple -t geode:latest .
```

### Full CI Pipeline
```bash
# Runs build, test, and cleanup
make docker-ci
```

## Troubleshooting

### Build Failures

If the main Dockerfile fails, the build system automatically falls back to `Dockerfile.simple`.

### Mirror Issues

The installation script tries these mirrors in order:
1. Official Zig download site
2. GitHub releases
3. Bazel mirror
4. Community mirrors (fetched dynamically)

### Signature Verification

- Signature verification is attempted but not required
- If minisign is not available, it will be installed automatically (Debian/Ubuntu)
- Verification failures produce warnings but don't stop the build

### Common Issues and Solutions

#### Issue: Zig download fails
**Solution**: The script automatically tries multiple mirrors. If all fail, check your internet connection.

#### Issue: XZ decompression fails
**Solution**: The script verifies the downloaded file is valid XZ compressed data before extraction.

#### Issue: Build fails with "no field or member function"
**Solution**: Ensure you're using Zig 0.15.1 or compatible version.

## Testing Docker Builds

### Minimal Test
```bash
# Test with minimal configuration
docker-compose -f docker-compose.test.yml up -d
docker exec geode-test geodec "RETURN 1 AS x" --server 127.0.0.1:7567
docker-compose -f docker-compose.test.yml down
```

### Full Test Suite
```bash
# Run comprehensive Docker tests
make docker-test
```

### CI Pipeline
```bash
# Complete CI pipeline with error handling
make docker-ci
```

## Architecture Support

Currently optimized for:
- Linux x86_64 (amd64)
- Debian-based containers

Future support planned for:
- ARM64 (aarch64)
- Alpine Linux
- Multi-arch builds

## Security Considerations

1. **Signature Verification**: Always attempts to verify Zig tarball signatures
2. **Public Key**: Uses official Zig minisign public key
3. **Non-root User**: Containers run as `geode` user (UID 1000)
4. **Minimal Attack Surface**: Production image uses distroless base

## Performance Optimizations

1. **Multi-stage Builds**: Reduces final image size
2. **Layer Caching**: Optimized for Docker layer caching
3. **Parallel Downloads**: Installation script can be modified to download in parallel
4. **Build Flags**: Uses `-Drelease-safe` for optimized builds with safety checks

## Maintenance

### Updating Zig Version

1. Update `ZIG_VERSION` in Dockerfiles
2. Test with new version:
```bash
docker build --build-arg ZIG_VERSION=0.16.0 -f Dockerfile.simple -t geode:test .
```

### Adding New Mirrors

Edit `scripts/docker/install-zig.sh` and add to the `MIRRORS` array:
```bash
MIRRORS+=(
    "https://your-mirror.com/zig/${ZIG_VERSION}"
)
```

### Updating Public Key

If Zig updates their signing key, update the `PUBKEY` variable in:
- `scripts/docker/install-zig.sh`
- `Dockerfile.simple`

## Contributing

When contributing Docker-related changes:
1. Test with `make docker-quick-test`
2. Ensure `make docker-ci` passes
3. Update this documentation if needed
4. Consider backward compatibility