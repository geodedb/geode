# Geode Docker Development - Quick Start Guide

Get started with Geode development in Docker in 5 minutes!

## ⚡ Super Quick Start (TL;DR)

```bash
# 1. Start development environment
./dev.sh start

# 2. Open development shell
./dev.sh shell

# 3. Build Geode
zb

# 4. Run tests
make test

# 5. Start Geode server
./zig-out/bin/geode serve
```

That's it! You're now developing Geode in Docker.

## 📋 What You Get

- **Zig 0.15.1** - Latest Zig compiler
- **Python 3.12** - For test harness and geodetestlab
- **OpenSSL 3.3.2 with FIPS** - Enterprise-grade crypto
- **MsQUIC v2.5.4** - High-performance QUIC implementation
- **Vault, MinIO, Redis** - All supporting services
- **Hot Reload** - Code changes are instant

## 🚀 First Time Setup

### Step 1: Prerequisites

Check you have:
- Docker (20.10+)
- Docker Compose (1.29+)

```bash
docker --version
docker-compose --version
```

### Step 2: Build & Start

```bash
./dev.sh start
```

First build takes ~10 minutes. Grab a coffee! ☕

### Step 3: Verify Services

Check all services are running:

```bash
./dev.sh status
```

You should see:
- ✅ geode-dev (Up)
- ✅ geode-dev-vault (Up, healthy)
- ✅ geode-dev-minio (Up, healthy)
- ✅ geode-dev-redis (Up, healthy)

## 💻 Daily Development

### Enter Development Shell

```bash
./dev.sh shell
```

You'll see:
```
🚀 Geode Development Environment
━━━━━━━━━━━━━━━━━━━━━━━━━━━━━
📦 Development Tools:
  • Zig 0.15.1
  • Python 3.12
  ...
```

### Build Geode

```bash
# Quick debug build
zb

# Optimized release build
zbr

# With tests
zbt
```

### Run Tests

```bash
# All tests
make test

# Specific test suite
make geodetestlab

# Quick verification
make verify-fast
```

### Start Geode Server

```bash
# Development server on localhost
./zig-out/bin/geode serve --listen 127.0.0.1:9999

# With custom config
./zig-out/bin/geode serve \
  --listen 0.0.0.0:8443 \
  --data-dir /workspace/data \
  --cert /workspace/certs/server.crt \
  --key /workspace/certs/server.key
```

### Make Code Changes

1. Edit files in your host editor (VS Code, Vim, etc.)
2. Changes are instantly available in container
3. Rebuild: `zb`
4. Test: `make test`

### View Logs

```bash
# From host (recommended)
./dev.sh logs -f

# Inside container
tail -f /var/log/geode/*.log
```

## 🔧 Common Tasks

### Clean Build

```bash
./dev.sh clean
```

### Restart Services

```bash
./dev.sh restart
```

### Execute Command Without Entering Shell

```bash
./dev.sh exec zig build
./dev.sh exec make test
./dev.sh exec ./zig-out/bin/geode --version
```

### Stop Everything

```bash
./dev.sh stop
```

### Complete Cleanup

```bash
./dev.sh down  # Removes containers and volumes
```

## 🌐 Access Services

### From Development Container

All services use internal Docker names:

```bash
# Vault
curl http://vault:8200/v1/sys/health

# MinIO
aws --endpoint-url http://minio:9000 s3 ls

# Redis
redis-cli -h redis -a geode-dev-password ping
```

### From Host Browser

Access web UIs:

- **MinIO Console**: http://localhost:9001
  - Username: `admin`
  - Password: `geode-dev-secret-123`

- **Vault UI**: http://localhost:8200
  - Token: `geode-dev-token`

## 🐛 Quick Troubleshooting

### Build Fails

```bash
# Rebuild from scratch
./dev.sh rebuild
```

### Permission Errors

```bash
# From host, fix ownership
sudo chown -R $(id -u):$(id -g) .
```

### Port Already in Use

Edit `docker-compose.dev.yml` and change the host port (left side):

```yaml
ports:
  - "9090:9090"  # Change to "9091:9090"
```

### Container Won't Start

```bash
# Check logs
./dev.sh logs geode-dev

# Check Docker
docker info
```

## 📊 With Monitoring (Optional)

Start with Prometheus and Grafana:

```bash
./dev.sh monitoring
```

Access:
- **Prometheus**: http://localhost:9090
- **Grafana**: http://localhost:3000
  - Username: `admin`
  - Password: `geode-dev-password`

## 🎯 Next Steps

1. **Read Full Docs**: `DOCKER_DEV.md`
2. **Check Project README**: `README.md`
3. **Explore Tests**: `geodetestlab/specs/`
4. **Run Benchmarks**: `make benchmarks`

## 💡 Pro Tips

- Use `zb` instead of `zig build` (alias)
- Keep shell open while editing
- Use `./dev.sh exec` for one-off commands
- Run `./dev.sh status` to check health
- Logs are your friend: `./dev.sh logs -f`

## 🆘 Need Help?

1. Check `./dev.sh help`
2. Read `DOCKER_DEV.md`
3. View logs: `./dev.sh logs -f`
4. Open an issue with error details

## ✅ Success Checklist

After first setup, verify:

- [ ] `./dev.sh status` shows all services healthy
- [ ] `./dev.sh shell` opens without errors
- [ ] `zb` builds successfully
- [ ] `make test` runs (may have some failures initially)
- [ ] Can access MinIO at http://localhost:9001

If all checks pass, you're ready to develop! 🎉

---

**Happy Coding!** 🚀

Need more details? See [DOCKER_DEV.md](DOCKER_DEV.md)
