# Docker Development Environment - Complete Setup Guide

This document details the complete Docker-based development environment for Geode, including all configurations and recent updates.

## 📦 What's Included

### Development Tools
- **Zig 0.15.1** - Primary build system
- **Rust (stable)** - For Rust client development with OpenSSL/BoringSSL support
- **Go 1.22+** - For Go client development
- **Python 3.12** - For geodetestlab and Python client
- **Node.js** - For JavaScript/TypeScript clients

### Graphics & GPU
- **CUDA Toolkit 12.4** - NVIDIA GPU acceleration
- **Vulkan SDK** - Graphics API for GPU compute
  - Vulkan headers and development libraries
  - Vulkan validation layers
  - SPIR-V tools
  - GLSLANG compiler

### Security & Networking
- **OpenSSL 3.3.2 with FIPS** - Enterprise cryptography
- **MsQUIC v2.5.4** - High-performance QUIC implementation
- **HashiCorp Vault** - Secrets management
- **MinIO** - S3-compatible object storage
- **Redis** - Caching layer

### Optional Monitoring
- **Prometheus** - Metrics collection
- **Grafana** - Visualization

## 🗂️ File Structure

```
.
├── Dockerfile.dev                # Main development Dockerfile
├── docker-compose.dev.yml        # Development orchestration
├── dev.sh                        # Helper script (executable)
├── .envrc.docker                 # Docker-compatible direnv
├── .env.docker-dev.example       # Environment configuration template
├── docker/
│   ├── zig/.gitkeep             # Zig binaries (gitignored)
│   └── msquic/
│       └── lib/.gitkeep         # MsQUIC libs (gitignored)
├── DOCKER_DEV.md                 # Comprehensive documentation
├── QUICKSTART_DOCKER.md          # Quick start guide
└── DOCKER_DEV_SETUP.md           # This file
```

## 🔧 Configuration Files Updated

### 1. `.gitignore`
Added patterns to ignore:
- Large binary files in `docker/` directory
- Docker Compose override files
- Environment files (.env, .env.local, etc.)
- Preserves directory structure with `.gitkeep` files

```gitignore
# Docker development artifacts (large binary files)
docker/zig/*.tar.xz
docker/zig/*.tar.gz
docker/msquic/lib/*.so*
docker/msquic/lib/*.a
!docker/*/.gitkeep

# Docker environment and secrets
.env
.env.local
.env.*.local
docker-compose.override.yml
!.env.docker-dev.example
```

### 2. `.envrc.docker`
New Docker-compatible direnv configuration that:
- Checks Docker prerequisites
- Loads environment variables from `.env`
- Sets up service URLs
- Provides helper functions (dev-exec, dev-build, dev-test, dev-server)
- Displays environment information

Usage:
```bash
# Use Docker environment instead of Nix
mv .envrc .envrc.nix.backup
cp .envrc.docker .envrc
direnv allow
```

### 3. `Makefile`
Added new development environment targets:

```makefile
# Docker Development Environment
make dev-start          # Start development environment
make dev-stop           # Stop development environment
make dev-shell          # Open development shell
make dev-build-geode    # Build Geode in container
make dev-test           # Run tests in container
make dev-logs           # View development logs
make dev-clean          # Clean development environment
make dev-monitoring     # Start with monitoring stack
make dev-test-clients   # Run client tests in container
```

All targets are accessible through the `./dev.sh` script or directly via `make`.

## 🚀 Environment Variables

### Core Settings
```bash
# Development mode
GEODE_DEV_MODE=docker
GEODE_ENV=development
LOG_LEVEL=debug
RUST_BACKTRACE=1

# User configuration
USER_UID=1000          # Match your host UID
USER_GID=1000          # Match your host GID
USERNAME=dev           # Container username
```

### Service Configuration
```bash
# Vault
VAULT_ADDR=http://localhost:8200
VAULT_TOKEN=geode-dev-token

# MinIO (S3)
S3_ENDPOINT=http://localhost:9000
S3_ACCESS_KEY=geode-dev-admin
S3_SECRET_KEY=geode-dev-secret-123
S3_BUCKET=geode-dev-backups

# Redis
REDIS_PASSWORD=geode-dev-password
REDIS_URL=redis://:geode-dev-password@localhost:6379

# FIPS mode
FIPS_MODE=enabled
```

### Build Configuration
```bash
# OpenSSL paths for Rust client
OPENSSL_DIR=/opt/openssl-fips
OPENSSL_LIB_DIR=/opt/openssl-fips/lib64
OPENSSL_INCLUDE_DIR=/opt/openssl-fips/include

# CUDA paths
CUDA_HOME=/usr/local/cuda
CUDA_PATH=/usr/local/cuda

# Vulkan
VULKAN_SDK=/usr

# Zig
ZIG_VERSION=0.15.1
ZIG_LOCAL_CACHE_DIR=/workspace/zig-cache
ZIG_GLOBAL_CACHE_DIR=/home/dev/.cache/zig
```

## 📝 Customization

### Adding More Tools

Edit `Dockerfile.dev` in the base stage:

```dockerfile
RUN apt-get update && apt-get install -y \
    your-new-package \
    && rm -rf /var/lib/apt/lists/*
```

Then rebuild:
```bash
./dev.sh rebuild
```

### Changing User ID/GID

Create a `.env` file:
```bash
cp .env.docker-dev.example .env
```

Edit `.env`:
```bash
USER_UID=$(id -u)
USER_GID=$(id -g)
USERNAME=$(whoami)
```

Rebuild:
```bash
./dev.sh rebuild
```

### Adding Custom Aliases

Edit `Dockerfile.dev` in the shell environment section:

```dockerfile
RUN echo 'alias my-alias="my command"' >> ~/.bashrc
```

## 🔒 Security Considerations

### Secrets Management

1. **Never commit `.env` files** - They're gitignored by default
2. **Use Vault for production secrets** - Development uses dev tokens
3. **Generate unique passwords** - Example defaults are for development only
4. **TLS certificates** - Mount your own or let Geode generate them

### Privileged Mode

The development container runs in privileged mode to support:
- MsQUIC networking
- CUDA GPU access
- Advanced debugging tools

**Warning**: Only use for development. Production deployments should use minimal permissions.

## 🐛 Troubleshooting

### Build Failures

**Issue**: Docker build fails with CUDA errors
**Solution**: CUDA installation is optional. Comment out CUDA section in Dockerfile.dev if not needed.

**Issue**: Rust installation fails
**Solution**: Check internet connectivity. Rustup requires downloading components.

### Permission Errors

**Issue**: Cannot write to workspace
**Solution**:
```bash
sudo chown -R $(id -u):$(id -g) .
```

Or set correct UID/GID in `.env`.

### CUDA Not Available

**Issue**: `nvcc: command not found`
**Solution**:
1. Check if NVIDIA drivers are installed on host
2. Pass `--gpus all` flag to Docker (added to docker-compose.dev.yml)
3. Verify CUDA installation in container: `nvcc --version`

### Vulkan Validation Errors

**Issue**: Vulkan validation layers report errors
**Solution**:
```bash
# Inside container
export VK_LAYER_PATH=/usr/share/vulkan/explicit_layer.d
```

## 📊 Resource Requirements

### Minimum
- CPU: 4 cores
- RAM: 8 GB
- Disk: 20 GB free

### Recommended
- CPU: 8+ cores
- RAM: 16 GB+
- Disk: 50 GB+ SSD
- GPU: NVIDIA with CUDA support (optional)

### Build Times

First build (no cache):
- Base image: ~5 minutes
- OpenSSL FIPS: ~3 minutes
- MsQUIC: ~2 minutes
- CUDA + Rust: ~5 minutes
- **Total**: ~15 minutes

Subsequent builds (with cache):
- Changed files only: ~1-2 minutes

## 🔄 Migration from Nix

### Step-by-Step Migration

1. **Backup current Nix environment**:
   ```bash
   mv .envrc .envrc.nix.backup
   ```

2. **Copy Docker environment**:
   ```bash
   cp .envrc.docker .envrc
   cp .env.docker-dev.example .env
   ```

3. **Customize environment**:
   ```bash
   vim .env  # Set your UID/GID
   ```

4. **Build and start**:
   ```bash
   ./dev.sh start
   ```

5. **Test environment**:
   ```bash
   ./dev.sh shell
   zb  # Build Geode
   make test
   ```

### What You Keep

- All source code and changes
- Git history and configuration
- SSH keys (mounted read-only)
- Build output (in Docker volumes)

### What Changes

- Build happens in Docker container
- Tools accessed via `dev-exec` or inside shell
- Environment variables in `.env` instead of Nix
- Services run in Docker Compose

## 📚 Additional Resources

- [Complete Documentation](DOCKER_DEV.md)
- [Quick Start Guide](QUICKSTART_DOCKER.md)
- [Main README](README.md)
- [Docker Compose Reference](https://docs.docker.com/compose/)

## 🎯 Next Steps

1. **Review this document** completely
2. **Copy `.env.docker-dev.example`** to `.env` and customize
3. **Start development environment**: `./dev.sh start`
4. **Read Quick Start Guide**: `cat QUICKSTART_DOCKER.md`
5. **Begin development**: `./dev.sh shell`

## 📞 Support

If you encounter issues:
1. Check troubleshooting section above
2. Run `./dev.sh logs -f` for detailed logs
3. Verify Docker is running: `docker info`
4. Check system resources: `docker stats`
5. Open an issue with full error details

---

**Last Updated**: 2025-11-17
**Docker Version Required**: 20.10+
**Docker Compose Version Required**: 1.29+
