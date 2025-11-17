# Geode Docker Development Environment

A complete Docker-based development environment for Geode that replicates the Nix flake setup while avoiding Nix/Docker compatibility issues.

## 🎯 Features

- **Complete Development Stack**: All tools and dependencies from the Nix flake
- **Isolated Environment**: Consistent development experience across all machines
- **No Nix Required**: Pure Docker-based setup avoiding GLIBC and library mismatches
- **Hot Reload**: Source code mounted as volume for instant changes
- **All Services Included**: Vault, MinIO, Redis, Prometheus, Grafana
- **Built-in Tools**: Zig 0.15.1, Python 3, OpenSSL FIPS, MsQUIC v2.5.4
- **Development Helpers**: Pre-configured aliases and scripts

## 📋 Prerequisites

- Docker 20.10 or later
- Docker Compose 1.29 or later
- 8GB+ RAM available for Docker
- 20GB+ disk space

## 🚀 Quick Start

### 1. Build and Start Development Environment

```bash
# Make the helper script executable (if not already)
chmod +x dev.sh

# Start the development environment
./dev.sh start
```

This will:
- Build the Docker development image (first time only, ~10 minutes)
- Start all required services (Vault, MinIO, Redis)
- Create persistent volumes for data

### 2. Enter Development Shell

```bash
./dev.sh shell
```

You'll see a welcome message with available tools and quick commands:

```
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
🚀 Geode Development Environment
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━

📦 Development Tools:
  • Zig 0.15.1
  • Python 3.12
  • OpenSSL 3.3.2 FIPS
  • MsQUIC v2.5.4 (FIPS compatible)

🔨 Quick Commands:
  • zb        - zig build
  • zbr       - zig build -Doptimize=ReleaseSafe
  • zbt       - zig build test
  • make test - Run geodetestlab tests

📂 Workspace: /workspace (mounted to host)
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
```

### 3. Build Geode

Inside the development shell:

```bash
# Debug build
zb

# Release build
zbr

# Run tests
zbt

# Or use make commands
make build
make test
```

## 🛠️ Helper Script Commands

The `dev.sh` script provides convenient commands:

```bash
./dev.sh start          # Start development environment
./dev.sh stop           # Stop development environment
./dev.sh restart        # Restart development environment
./dev.sh shell          # Open interactive shell
./dev.sh exec <cmd>     # Execute command in container
./dev.sh build          # Build geode project
./dev.sh test           # Run tests
./dev.sh clean          # Clean build artifacts
./dev.sh logs [-f]      # View logs
./dev.sh status         # Show service status
./dev.sh down           # Remove all containers and volumes
./dev.sh rebuild        # Rebuild Docker image
./dev.sh monitoring     # Start with Prometheus + Grafana
```

## 📦 Available Services

### Core Services (Always Running)

| Service | Port | Credentials | Description |
|---------|------|-------------|-------------|
| Vault | 8200 | Token: `geode-dev-token` | Secrets management |
| MinIO | 9001 | `admin` / `geode-dev-secret-123` | S3-compatible storage |
| Redis | 6379 | Password: `geode-dev-password` | Caching layer |

### Optional Monitoring Stack

Start with `./dev.sh monitoring`:

| Service | Port | Credentials | Description |
|---------|------|-------------|-------------|
| Prometheus | 9090 | None | Metrics collection |
| Grafana | 3000 | `admin` / `geode-dev-password` | Visualization |

## 🔧 Development Workflow

### Standard Development Cycle

```bash
# 1. Start environment (if not already running)
./dev.sh start

# 2. Enter development shell
./dev.sh shell

# 3. Make code changes in your editor (changes are live-synced)

# 4. Build and test inside container
zb          # Quick build
zbt         # Run tests
make verify # Full verification

# 5. Run geode server
./zig-out/bin/geode serve --listen 127.0.0.1:9999

# 6. Exit shell when done
exit

# 7. Stop environment (optional)
./dev.sh stop
```

### Executing Commands from Host

You can run commands without entering the shell:

```bash
# Build from host
./dev.sh exec zig build

# Run tests from host
./dev.sh exec make test

# Run custom commands
./dev.sh exec ls -la zig-out/bin/
```

### Viewing Logs

```bash
# View all logs
./dev.sh logs

# Follow logs
./dev.sh logs -f

# Logs for specific service
./dev.sh logs geode-dev
./dev.sh logs vault

# Follow specific service
./dev.sh logs -f redis
```

## 📂 Directory Structure

```
/workspace/               # Mounted project directory
├── src/                  # Source code (live-synced)
├── tests/                # Test files
├── zig-out/              # Build output
├── zig-cache/            # Zig build cache (Docker volume)
└── .zig-cache/           # Zig global cache (Docker volume)
```

## 🎨 Customization

### Changing User ID/GID

Match your host user to avoid permission issues:

```bash
# Set in .env file
echo "USER_UID=$(id -u)" > .env
echo "USER_GID=$(id -g)" >> .env
echo "USERNAME=$(whoami)" >> .env

# Rebuild
./dev.sh rebuild
```

### Adding Custom Tools

Edit `Dockerfile.dev` and add packages in the base stage:

```dockerfile
RUN apt-get update && apt-get install -y \
    your-package-here \
    && rm -rf /var/lib/apt/lists/*
```

Then rebuild:

```bash
./dev.sh rebuild
```

### Environment Variables

Create a `.env` file for custom configuration:

```bash
# .env
GEODE_LOG_LEVEL=trace
CUSTOM_VAR=value
```

## 🐛 Troubleshooting

### Container Won't Start

```bash
# Check Docker daemon
docker info

# Check logs
./dev.sh logs geode-dev

# Rebuild image
./dev.sh rebuild
```

### Permission Errors

```bash
# Fix ownership (run from host)
sudo chown -R $(id -u):$(id -g) .

# Or set correct UID/GID (see Customization)
```

### Port Conflicts

If ports are already in use, edit `docker-compose.dev.yml`:

```yaml
ports:
  - "8201:8200"  # Change host port (left side)
```

### Out of Disk Space

```bash
# Clean up Docker
docker system prune -a

# Remove development volumes
./dev.sh down
```

### Slow Build Performance

The first build is slow (~10 min). Subsequent builds use cache:

```bash
# Check cache volumes are mounted
docker volume ls | grep zig-cache
```

## 🔬 Advanced Usage

### Debugging with GDB

```bash
./dev.sh shell

# Install GDB
sudo apt-get update && sudo apt-get install gdb

# Debug build
zig build -Doptimize=Debug

# Run with GDB
gdb --args ./zig-out/bin/geode serve
```

### Running Multiple Containers

```bash
# Scale geode-dev container
docker-compose -f docker-compose.dev.yml up -d --scale geode-dev=3
```

### Using Docker Buildkit

```bash
# Enable BuildKit for faster builds
export DOCKER_BUILDKIT=1
./dev.sh rebuild
```

### Attaching VSCode

1. Install "Remote - Containers" extension
2. Run `./dev.sh start`
3. In VSCode: "Remote-Containers: Attach to Running Container"
4. Select `geode-dev`

## 🆚 Comparison with Nix

| Feature | Docker Dev | Nix Flake |
|---------|-----------|-----------|
| Setup Time | ~10 min (first build) | ~5 min |
| Consistency | ✅ Perfect | ✅ Perfect |
| Portability | ✅ Any OS with Docker | ⚠️ Linux/macOS |
| Library Issues | ✅ None | ❌ GLIBC mismatches |
| Isolation | ✅ Container-level | ⚠️ User-level |
| MsQUIC | ✅ Works in privileged mode | ✅ Works natively |
| Resource Usage | ~2GB RAM | ~500MB RAM |

## 📝 Notes

- **Privileged Mode**: Required for MsQUIC to function properly in Docker
- **Cache Volumes**: `zig-cache` and `zig-global-cache` are Docker volumes for performance
- **SSH Keys**: Mounted read-only from host for git operations
- **FIPS Mode**: OpenSSL FIPS is enabled by default
- **Hot Reload**: Code changes are immediately available in the container

## 🤝 Migration from Nix

If you're currently using Nix:

```bash
# 1. Exit Nix shell
exit

# 2. Start Docker environment
./dev.sh start
./dev.sh shell

# 3. Your existing code works immediately!
zb
```

All commands from the Nix environment work identically in Docker.

## 📚 Additional Resources

- [Docker Documentation](https://docs.docker.com/)
- [Zig Build System](https://ziglang.org/learn/build-system/)
- [Geode Main README](README.md)
- [Production Deployment](docker-compose.yml)

## 🆘 Getting Help

If you encounter issues:

1. Check this README's Troubleshooting section
2. View logs: `./dev.sh logs -f`
3. Check service health: `./dev.sh status`
4. Open an issue with full error output

## 📜 License

Same as Geode project license.
