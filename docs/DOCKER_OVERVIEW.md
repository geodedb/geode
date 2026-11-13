# Geode Docker Overview

Geode is a feature-complete single-tenant graph database implementing the ISO/IEC 39075:2024 Graph Query Language (GQL) standard. This document provides Docker-specific guidance for deploying and running Geode containers. **Deployment status:** development-ready for single-tenant workloads — see [Known Limitations](../CLAUDE.md#known-limitations) before enabling multi-tenancy or cluster mode.

## Quick Start

```bash
# Pull the latest image
docker pull geodedb/geode:latest

# Run with default settings
docker run -d \
  --name geode \
  -p 3141:3141/udp \
  -p 9091:9091/tcp \
  -v geode-data:/data \
  geodedb/geode:latest

# Run with custom configuration
docker run -d \
  --name geode \
  -p 3141:3141/udp \
  -p 9091:9091/tcp \
  -v geode-data:/data \
  -v ./certs:/certs:ro \
  geodedb/geode:latest \
  --data-dir /data \
  --listen 0.0.0.0:3141 \
  --cert /certs/server.crt \
  --key /certs/server.key \
  --log-level info
```

## Image Variants

### Standard Image (`geodedb/geode:latest`)

- **Base**: Debian Bookworm Slim
- **Size**: ~150MB
- **Use Case**: Production deployments, general-purpose workloads
- **Tags**: `latest`, `0.18.0`, `0.18`

### Alpine Image (`geodedb/geode:alpine`)

- **Base**: Alpine Linux 3.20
- **Size**: ~50MB
- **Use Case**: Minimal footprint, resource-constrained environments
- **Tags**: `alpine`, `0.18.0-alpine`

### CUDA-Toolchain-Ready Image (`geodedb/geode:gpu`)

- **Base**: NVIDIA CUDA 12.3.2 Runtime (Ubuntu 22.04)
- **Size**: ~2GB
- **Use Case**: environments that want the CUDA runtime available for future GPU acceleration; today all graph algorithms run the same CPU path as the standard image
- **Tags**: `gpu`, `0.18.0-gpu`
- **Requirements**: NVIDIA Container Toolkit, CUDA-capable GPU
- **Honest status (GAP-0878)**: this image is CUDA-toolchain-ready, NOT CUDA-accelerated. Geode's GPU support is a build foundation (Vulkan backend scaffold + dlopen-based CUDA device detection); no graph algorithm currently executes on the GPU. When no GPU is present, Geode reports zero devices (it never fabricates a mock device).

## GPU vs Non-GPU Builds

| Feature | Standard | GPU image |
|---------|----------|-----------|
| Graph traversal | CPU | CPU (GPU planned) |
| PageRank | CPU | CPU (GPU planned) |
| Shortest path | CPU | CPU (GPU planned) |
| Set operations | CPU | CPU (GPU planned) |
| Vector similarity | SIMD | SIMD |
| BFS/DFS | CPU | CPU (GPU planned) |
| CUDA runtime present | No | Yes (for future acceleration) |
| Image size | ~150MB | ~2GB |
| Base image | Debian Slim | NVIDIA CUDA |

### Running the CUDA-Toolchain-Ready Container

```bash
# Requires NVIDIA Container Toolkit
docker run -d \
  --name geode-gpu \
  --gpus all \
  -p 3141:3141/udp \
  -p 9091:9091/tcp \
  -v geode-data:/data \
  -e CUDA_VISIBLE_DEVICES=0 \
  geodedb/geode:gpu
```

Note: there is no `--gpu-acceleration` server flag and no `GPU_ENABLED`
environment variable -- the server runs the CPU path regardless. The
`--gpus`/`CUDA_VISIBLE_DEVICES` settings only make the GPU visible inside
the container for future use (GAP-0878).

## Exposed Ports

| Port | Protocol | Purpose |
|------|----------|---------|
| 3141/udp | QUIC | Primary database connection (default) |
| 8443/udp | QUIC | Alternative database connection |
| 9090/tcp | HTTP | Prometheus `/metrics` + `/health` liveness (released images; `9091` in `Dockerfile`/`Dockerfile.prebuilt`) |

**Note**: Geode uses QUIC (UDP) exclusively for database connections. There is no TCP fallback.

## Volumes

| Path | Purpose |
|------|---------|
| `/data` | Database storage (WAL, catalog, graph data) |
| `/certs` | TLS certificates (mount read-only) |
| `/var/log/geode` | Log files |

## Environment Variables

### Core Configuration

| Variable | Default | Description |
|----------|---------|-------------|
| `GEODE_DATA_DIR` | `/data` | Data storage directory |
| `GEODE_ENV` | - | Environment identifier (`development`, `production`) |

The log level is the `--log-level` option (or the config file's
`log_level`); geode reads no `LOG_LEVEL` variable (only the vendored QUIC
library's own logger does). Corrected 2026-11-12, SONNY-6435.

### Query Engine

| Variable | Default | Description |
|----------|---------|-------------|
| `GEODE_ENABLE_QUERY_OPTIMIZER` | `1` | Enable cost-based query optimization |
| `GEODE_INLINE_RESULTS` | `1` | Enable inline result streaming |
| `GEODE_INLINE_RESULTS_MAX_ROWS` | - | Maximum rows for inline results |
| `GEODE_QUERY_MEM_LIMIT_BYTES` | - | Memory limit per query |
| `GEODE_NULLS_LAST` | - | Sort NULLs last in ORDER BY |

### Storage & WAL

| Variable | Default | Description |
|----------|---------|-------------|
| `GEODE_SPILL_THRESHOLD_BYTES` | - | Disk spill threshold |
| `GEODE_WAL_SYNC` | `each_commit` | `each_commit` (fsync per commit) or `deferred` (durable at the next checkpoint; replayable bulk loads only) |

The server reads none of `GEODE_WAL_COMPACT_INTERVAL`,
`GEODE_FORCE_SORT_SPILL`, `GEODE_FORCE_DISTINCT_SPILL` or
`GEODE_FORCE_UNION_SPILL` (corrected 2026-11-12, SONNY-6435).

### Clustering & Distribution

| Variable | Default | Description |
|----------|---------|-------------|
| `GEODE_CLUSTER_TOKEN` | - | Turns cluster mode on (and authenticates cluster clients); without it the server is standalone |
| `GEODE_PEERS` | - | Comma-separated `host:port` of every node, the same list on each |
| `GEODE_NODE_ID` | - | This node's number: its 1-based position in `GEODE_PEERS` (derived from `$HOSTNAME` when that matches an entry) |
| `GEODE_CLUSTER_NAME` | - | Cluster name |
| `GEODE_CLUSTER_PORT` | - | Intra-cluster (Raft) port |
| `GEODE_CLUSTER_LISTEN_ADDRESS` | `0.0.0.0` | Intra-cluster bind address (an IPv6 address may be written bare, `::1`, or bracketed, `[::1]`) |

See `src/server/cluster_bootstrap.zig`. The server reads none of
`GEODE_MAX_SHARDS`, `GEODE_QUERY_TIMEOUT_MS`, `GEODE_MAX_PARALLEL_QUERIES`,
`GEODE_CONNECTION_POOL_SIZE`, `GEODE_QUERY_CACHE_ENABLED`,
`GEODE_QUERY_CACHE_TTL_MS`, `GEODE_QUERY_CACHE_MAX_ENTRIES`,
`GEODE_RETRY_ATTEMPTS`, `GEODE_CONNECTION_TIMEOUT_MS` or
`GEODE_HEARTBEAT_INTERVAL_MS` (corrected 2026-11-12, SONNY-6435).

### Encryption - Transparent Data Encryption (TDE)

| Variable | Default | Description |
|----------|---------|-------------|
| `GEODE_TDE_KEY` | - | AES-256-GCM encryption key (64 hex chars / 32 bytes) |
| `GEODE_ENABLE_TDE` | `false` | Enables the `tde.*` procedures; page and WAL encryption need only `GEODE_TDE_KEY` |
| `GEODE_MASTER_KEY` | - | FLE master key. With `GEODE_MASTER_KEY_FORMAT` unset: at least 32 bytes, the first 32 used as raw bytes (a longer value warns; a shorter one refuses startup, SONNY-6422) |
| `GEODE_MASTER_KEY_FORMAT` | - | How `GEODE_MASTER_KEY` is read: `hex` (64 hex characters), `base64` (32 bytes) or `raw` (exactly 32 bytes); a value that does not match refuses startup (SONNY-6430, docs/FIELD_LEVEL_ENCRYPTION.md) |

### Encryption - KMS Integration

There is none. The server reads none of `GEODE_KMS_PROVIDER`,
`GEODE_VAULT_KEY_PATH`, `VAULT_ADDR` or `VAULT_TOKEN`: the page key is
`GEODE_TDE_KEY` and the FLE master key `GEODE_MASTER_KEY`, both from the
environment (corrected 2026-11-12, SONNY-6435;
[KMS_PROVIDER_SYSTEM.md](KMS_PROVIDER_SYSTEM.md)).

### Security & Access Control

| Variable | Default | Description |
|----------|---------|-------------|
| `GEODE_ENABLE_ABAC` | `true` | Has no effect: no request path enforces ABAC policies (authorization is GPS; SONNY-6376). Only reported in a startup log line. |

### Monitoring & Telemetry

| Variable | Default | Description |
|----------|---------|-------------|
| `GEODE_METRICS_PORT` | `9090` (image default; unset = listener off) | Prometheus `/metrics` and `/health` liveness port |
| `GEODE_METRICS_BIND` | `127.0.0.1` | Bind address for the metrics/liveness listener |
| `GEODE_AUDIT_LOG_PATH` | - | Audit log file path |
| `GEODE_TELEMETRY_PAGING` | - | Enable telemetry paging |

FIPS is a build (`-Dfips=true`, the `fips` image), not a variable: geode
reads no `FIPS_MODE`. The server reads none of `GEODE_CDC_ENABLE` (corrected
2026-11-12, SONNY-6435).

### Backup & Recovery

| Variable | Default | Description |
|----------|---------|-------------|
| `S3_ENDPOINT` | - | Read by the MinIO service only: geode reads no `S3_*` variable and has no object-storage backup (backups are local files, SONNY-6290) |
| `S3_ACCESS_KEY` | - | Read by the MinIO service only: geode reads no `S3_*` variable and has no object-storage backup (backups are local files, SONNY-6290) |
| `S3_SECRET_KEY` | - | Read by the MinIO service only: geode reads no `S3_*` variable and has no object-storage backup (backups are local files, SONNY-6290) |
| `S3_BUCKET` | - | Read by the MinIO service only: geode reads no `S3_*` variable and has no object-storage backup (backups are local files, SONNY-6290) |

### GPU Configuration (GPU image only)

These are standard NVIDIA container-runtime variables; they control GPU
visibility inside the container only. Geode itself reads none of them and
currently executes all algorithms on the CPU path (GAP-0878).

| Variable | Default | Description |
|----------|---------|-------------|
| `CUDA_VISIBLE_DEVICES` | - | GPU device selection (container runtime) |
| `NVIDIA_VISIBLE_DEVICES` | `all` | NVIDIA device visibility (container runtime) |
| `NVIDIA_DRIVER_CAPABILITIES` | `compute,utility` | NVIDIA capabilities (container runtime) |

## Command-Line Arguments

The container entrypoint is `geode serve`. Additional arguments can be passed:

```bash
docker run geodedb/geode:latest \
  --data-dir /data \
  --listen 0.0.0.0:3141 \
  --cert /certs/server.crt \
  --key /certs/server.key \
  --log-level info
```

| Argument | Description |
|----------|-------------|
| `--listen <addr:port>` | Bind address and port (default: `0.0.0.0:3141`) |
| `--data-dir <path>` | Data storage directory (default: `/data`) |
| `--cert <path>` | TLS certificate path |
| `--key <path>` | TLS private key path |
| `--log-level <level>` | Log level: `error`, `warn`, `info`, `debug` |

## Encryption Configuration

### Transparent Data Encryption (TDE)

TDE encrypts all data at rest using AES-256-GCM. Enable it by providing a 256-bit key:

```bash
# Generate a secure 256-bit key (64 hex characters)
openssl rand -hex 32

# Run with TDE enabled
docker run -d \
  --name geode-encrypted \
  -p 3141:3141/udp \
  -v geode-data:/data \
  -e GEODE_TDE_KEY=0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef \
  geodedb/geode:latest
```

### KMS Provider Integration

There is no KMS provider integration (no Vault, AWS, Azure or GCP key
source): give the key in `GEODE_TDE_KEY`, from your own secret store
(corrected 2026-11-12, SONNY-6435).

### Field-Level Encryption (FLE)

Field-level encryption uses the master key in `GEODE_MASTER_KEY` (not the
TDE key):

```bash
docker run -d \
  --name geode \
  -e GEODE_MASTER_KEY_FORMAT=hex \
  -e GEODE_MASTER_KEY=$(openssl rand -hex 32) \
  geodedb/geode:latest
```

Declare an encrypted field with `CALL geode.fle.configureField('Person',
'ssn')` ([FIELD_LEVEL_ENCRYPTION.md](FIELD_LEVEL_ENCRYPTION.md)).

## Clustering Configuration

### Distributed Query Coordination

Geode supports distributed query execution across multiple shards with automatic load balancing and result merging.

### 3-Node Cluster with Docker Compose

No validated Docker Compose cluster ships with this release. A cluster is
configured with the variables of "Clustering & Distribution" above and the
cluster TLS certificate (`src/server/cluster_bootstrap.zig`); the netns
cluster tests (`tests/cluster/`) are the tested setup.
`docker-compose.distributed.yml` runs three standalone nodes. Encrypt each
node with its own `GEODE_TDE_KEY`; there is no Vault-backed key (corrected
2026-11-12, SONNY-6435).

### Distributed Query Performance

| Operation Type | Single Node | 2 Shards | 4 Shards | 8 Shards | Scaling |
|---------------|-------------|----------|----------|----------|---------|
| Simple MATCH | 10ms | 15ms | 20ms | 30ms | Sub-linear |
| Ordered Query | 50ms | 75ms | 100ms | 150ms | Linear |
| Aggregation | 100ms | 60ms | 40ms | 30ms | Super-linear |
| Top-K (LIMIT) | 80ms | 50ms | 35ms | 25ms | Super-linear |

## Health Checks

Every server image ships the shared probe at `/usr/local/bin/health-check.sh`
(source: `docker/health-check.sh`):

```dockerfile
ENV GEODE_METRICS_PORT=9090
HEALTHCHECK --interval=30s --timeout=10s --start-period=10s --retries=3 \
    CMD /usr/local/bin/health-check.sh
```

The probe runs, in order:

1. `GET http://127.0.0.1:$GEODE_METRICS_PORT/health` — the server's
   **out-of-band liveness endpoint** (`src/monitoring/metrics_server.zig`).
   It is unauthenticated plain HTTP on its own thread, entirely off the QUIC
   query path, so a probe tick can neither fail TLS verification nor be
   recorded as a failed authentication attempt. Returns
   `200 {"status":"ok"}`. The server only starts that listener when
   `GEODE_METRICS_PORT` is set, which is why the images bake in a default;
   `GEODE_METRICS_BIND` (default `127.0.0.1`) controls the bind address, so
   the endpoint stays loopback-only unless you opt in.
2. An authenticated `geode query "RETURN 1 AS health"` — **only** when both
   `GEODE_USERNAME` and `GEODE_PASSWORD` are set, as a fallback for images or
   configurations where the liveness endpoint is disabled.

| Variable | Default | Purpose |
|----------|---------|---------|
| `GEODE_METRICS_PORT` | `9090` (`9091` in `Dockerfile`/`Dockerfile.prebuilt`) | Port of the liveness endpoint the probe uses |
| `GEODE_HEALTH_TIMEOUT` | `2` | Seconds allowed for the liveness probe |
| `GEODE_HEALTH_PORT` | `3141` | QUIC port used by the authenticated fallback |
| `GEODE_USERNAME` / `GEODE_PASSWORD` | - | Enable the authenticated fallback |
| `GEODE_HEALTH_CA_CERT` | - | CA bundle used to verify the server certificate in the fallback (`--ca-cert`) |

Notes:

- The password is passed as a single `argv` element, so multi-word
  passphrases work. The server's password policy effectively requires three
  or more words, and an earlier version of the script word-split them.
- Do **not** configure a credential-less authenticated probe. The server
  counts every credential-less HELLO against its per-source-IP auth rate
  limiter (10 attempts, 60s lockout), and a probe that can never authenticate
  never resets the counter, so the limiter re-trips on every tick forever.
  Note that containers sharing a network namespace
  (`docker run --network container:<name>`) share the same `127.0.0.1` key.
- The probe never asks the CLI to skip TLS verification — see the next
  section for why that would fail outright in a release image.

### `--insecure-tls-skip-verify` is refused in release builds (SEC-CLI-01)

This is deliberate, designed defense-in-depth (`src/cli/insecure_tls_gate.zig`),
not a defect. The flag (and its deprecated `--insecure` alias) is refused at
argv-parse time, with exit status 1, before any socket is opened, whenever:

```text
insecure_requested AND NOT GEODE_ALLOW_INSECURE_TLS AND (is_release OR GEODE_ENV=production)
```

where `is_release` is `builtin.mode != .Debug`. Published images are built
ReleaseSafe (`.goreleaser.yaml` → `Dockerfile.release` → `geodedb/geode:latest`),
so they always satisfy `is_release`. The verbatim refusal message is:

```text
SECURITY: refusing --insecure-tls-skip-verify — TLS certificate verification cannot be disabled under production conditions (release build or GEODE_ENV=production). Connections without verification are exposed to man-in-the-middle attacks. Use --ca-cert <path> to trust a private CA, or set GEODE_ALLOW_INSECURE_TLS=1 to explicitly acknowledge the risk.
```

Preferred resolution, in order:

1. **Use `--ca-cert <path>`** to trust the CA that signed the server
   certificate. This keeps verification on and is the supported production
   answer for private CAs and self-signed deployments.
2. **Do not put the CLI on the health path at all** — the liveness endpoint
   above is plain HTTP on loopback and needs no TLS decision.
3. `GEODE_ALLOW_INSECURE_TLS=1` (accepted values: `1`, `true`, `yes`, `on`)
   as an explicit, audited acknowledgement of MITM exposure. Even when
   accepted, the CLI prints a loud `WARNING: TLS certificate verification
   DISABLED` banner. Never do this in production.

`geode query`, `geode shell` and the REPL verify the server against a
`--ca-cert` bundle whenever one is given, and refuse to connect if it
cannot be loaded (SONNY-6448; before, they ignored `--ca-cert` unless
`--client-cert`/`--client-key` were also given). With no `--ca-cert`, no
client certificate and no insecure flag they follow the `geode auth`
rule (SONNY-6453): a release build, or any build with
`GEODE_ENV=production`, refuses to connect (`SECURITY: refusing to connect
without TLS certificate verification`) unless `GEODE_ALLOW_INSECURE_TLS=1`
is set; a Debug build outside `GEODE_ENV=production` connects without
verification and prints `WARNING: TLS server certificate NOT verified (no
--ca-cert given)` once on stderr. `geode backup` / `restore` and the
`geode auth` login path refuse the same way up front instead of failing
the handshake. Pass `--ca-cert` inside the container (the release image
is a release build).

A Debug build (the default of `zig build`) is not gated unless
`GEODE_ENV=production` is set. This is why `.gitlab-ci.yml` deliberately
builds Debug for the GQL compliance job — its test runner connects to
per-spec self-signed servers with `--insecure-tls-skip-verify` — and, in
turn, why the release-image health-check path was never exercised by that
job.

## QUIC Performance Tuning

For optimal QUIC throughput, increase UDP buffer sizes:

```bash
# Using Docker sysctls (recommended)
docker run -d \
  --sysctl net.core.rmem_max=7340032 \
  --sysctl net.core.wmem_max=7340032 \
  geodedb/geode:latest

# Or configure host system
sudo sysctl -w net.core.rmem_max=7340032
sudo sysctl -w net.core.wmem_max=7340032
```

## Docker Compose Example

```yaml
services:
  geode:
    image: geodedb/geode:latest
    container_name: geode
    restart: unless-stopped
    ports:
      - "3141:3141/udp"
      - "9091:9091/tcp"
    environment:
      - GEODE_DATA_DIR=/data
    volumes:
      - geode-data:/data
      - ./certs:/certs:ro
    command:
      - "--data-dir"
      - "/data"
      - "--listen"
      - "0.0.0.0:3141"
      - "--cert"
      - "/certs/server.crt"
      - "--key"
      - "/certs/server.key"
      - "--log-level"
      - "info"
    sysctls:
      - net.core.rmem_max=7340032
      - net.core.wmem_max=7340032
    healthcheck:
      # The image's baked-in HEALTHCHECK already does this; override only if
      # you need different timings. It probes the unauthenticated liveness
      # endpoint, never the TLS/auth query path (see "Health Checks").
      test: ["CMD", "/usr/local/bin/health-check.sh"]
      interval: 30s
      timeout: 10s
      retries: 3
      start_period: 40s

volumes:
  geode-data:
```

## GPU Docker Compose Example

```yaml
services:
  geode-gpu:
    image: geodedb/geode:gpu
    container_name: geode-gpu
    restart: unless-stopped
    ports:
      - "3141:3141/udp"
      - "9091:9091/tcp"
    environment:
      - CUDA_VISIBLE_DEVICES=0
      - NVIDIA_VISIBLE_DEVICES=all
      - NVIDIA_DRIVER_CAPABILITIES=compute,utility
    volumes:
      - geode-data:/data
      - ./certs:/certs:ro
    command:
      - "--data-dir"
      - "/data"
      - "--listen"
      - "0.0.0.0:3141"
    deploy:
      resources:
        reservations:
          devices:
            - driver: nvidia
              count: 1
              capabilities: [gpu]

volumes:
  geode-data:
```

## Production Deployment with Monitoring

For production deployments, use the full stack with monitoring:

```yaml
services:
  geode:
    image: geodedb/geode:latest
    ports:
      - "3141:3141/udp"
      - "9091:9091/tcp"
    environment:
      # Page and WAL key; geode reads no VAULT_*, REDIS_* or S3_* variable
      # (SONNY-6435).
      - GEODE_TDE_KEY=${GEODE_TDE_KEY}
    volumes:
      - geode-data:/data
      - geode-logs:/var/log/geode
      - ./certs:/certs:ro
    command: ["--data-dir", "/data", "--listen", "0.0.0.0:3141", "--cert", "/certs/server.crt", "--key", "/certs/server.key", "--log-level", "info"]

  prometheus:
    image: prom/prometheus:latest
    ports:
      - "9090:9090"
    volumes:
      - ./prometheus.yml:/etc/prometheus/prometheus.yml:ro

  grafana:
    image: grafana/grafana:latest
    ports:
      - "3000:3000"
    environment:
      - GF_SECURITY_ADMIN_PASSWORD=${GRAFANA_PASSWORD}

volumes:
  geode-data:
  geode-logs:
```

## Security Considerations

1. **TLS Certificates**: Always mount certificates read-only (`:ro`)
2. **Non-root User**: Container runs as user `geode` (UID 10000)
3. **Secret Management**: Pass `GEODE_TDE_KEY`, `GEODE_MASTER_KEY` and passwords from Docker secrets or your secret store; geode itself reads no secret store
4. **Network Isolation**: Use Docker networks to isolate database traffic
5. **FIPS Mode**: Use the FIPS build (`-Dfips=true`, the `fips` image); there is no `FIPS_MODE` switch
6. **Encryption at Rest**: Enable TDE for data protection
7. **Key Rotation**: Use KMS providers for automated key rotation

## Connecting to Geode

### Using the CLI

```bash
# Interactive shell
docker exec -it geode geode shell --server 127.0.0.1:3141

# Execute a query
docker exec geode geode query "MATCH (n) RETURN count(n)" --server 127.0.0.1:3141
```

### Client Libraries

Connect using any official client library:

- **Go**: `geodedb.com/geode`
- **Python**: `geode-client-python`
- **Rust**: `geode-client-rust`
- **Zig**: `geode-client-zig`

All clients connect via QUIC on port 3141 using JSON line protocol.

## Troubleshooting

### Container won't start

Check if port 3141/udp is available:

```bash
docker logs geode
ss -ulpn | grep 3141
```

### Connection refused

Ensure QUIC (UDP) traffic is allowed:

```bash
# Liveness (no TLS, no auth) — see "Health Checks"
docker exec geode /usr/local/bin/health-check.sh

# Test an actual query. Released images are release builds, so
# --insecure-tls-skip-verify is REFUSED (SEC-CLI-01); trust the CA instead.
docker exec geode geode query "RETURN 1" --server 127.0.0.1:3141 \
  --ca-cert /certs/ca.crt -U "$GEODE_USERNAME" -P "$GEODE_PASSWORD"
```

### GPU not detected

Verify NVIDIA Container Toolkit:

```bash
docker run --rm --gpus all nvidia/cuda:12.3.2-base-ubuntu22.04 nvidia-smi
```

### TDE key errors

Ensure the TDE key is exactly 64 hex characters:

```bash
# Verify key length
echo -n "$GEODE_TDE_KEY" | wc -c  # Should output 64
```

### Cluster nodes not connecting

1. Verify all nodes are on the same Docker network
2. Check `GEODE_CLUSTER_NAME` matches across nodes
3. Ensure unique `GEODE_NODE_ID` for each node
4. Verify UDP connectivity between containers

### Performance issues

1. Increase UDP buffer sizes (see QUIC Performance Tuning)
2. Check memory limits: `docker stats geode`
3. Enable debug logging: `--log-level debug`

## Additional Resources

- [API Reference](https://geodedb.com/docs/api-reference/)
- [GQL Compliance](https://geodedb.com/docs/gql)
- [Feature Overview](https://geodedb.com/docs/features)
- [GitLab Issues](https://gitlab.com/devnw/codepros/geode/geode/-/issues)

---

**License**: Apache License 2.0
**Copyright**: 2025-2026 CodePros
