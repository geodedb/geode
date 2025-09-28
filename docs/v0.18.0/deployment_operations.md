# Deployment & Operations

Build:
- Zig 0.15.1: `zig build -Drelease-safe`; tests: `zig build test`; Make targets available.

Docker:
- QUIC on 8443/udp; mount data & certs; JSON logs; Prometheus/Grafana example.

Config (YAML/env):
- server.listen, data_dir; tls.cert/key (auto_generate true/false)
- storage.page_size, cache_size, wal_dir
- federation.coordinator, shards list
- optimizer.small_n_threshold, trace
- backup.s3 bucket/prefix/retention
- Env vars: GEODE_DATA_DIR, GEODE_CERT_FILE/KEY_FILE, GEODE_DISK_KEY_HEX, GEODE_LOG_LEVEL, GEODE_CACHE_SIZE, etc.

Backups:
- Full & incremental; S3 via AWS env; list/retention; test restores.

Monitoring:
- Prometheus /metrics (port 9090); dashboards included; health endpoints /health, /ready.

Troubleshooting:
- Connectivity (listen 0.0.0.0:8443, UDP firewall); TLS errors (cert/key perms); auth (exit 3); US001 (add ORDER BY); WAL growth (long txns, checkpoint); S3 creds.

Upgrades & Tuning:
- Follow MIGRATION.md; adjust commit flush policy; increase cache; indexes for hot predicates; batch writes.
