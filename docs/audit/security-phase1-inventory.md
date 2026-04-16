# Geode Security Audit — Phase 1 Inventory

**Root:** `/home/benji/src/devnw/codepros/geode/geode`
**Platform:** GitLab (`git@gitlab.com:devnw/codepros/geode/geode.git`)
**Languages:** Zig 0.15.1+ (primary), Python (tooling), Go (loadtest harness), shell, Dockerfile
**Frameworks / vendored libs:** vendor QUIC (`quic@2ca4f8db`), grpc_zig, protobuf, mcp, auth (HMAC/TOTP/API keys), fle, audit, wal, graph_storage, raft, hnsw, rtree, gql, advanced_types, timeseries, json, yaml, toml (all via `build.zig.zon`)

---

## Security Inventory

### Entrypoints & Auth Boundaries

| Entrypoint | Type | Auth Required | Auth Mechanism | File:Line |
|-----------|------|---------------|----------------|-----------|
| QUIC listener (default `3141/udp`) | Stream-oriented, TLS 1.3 only | Yes (fail-closed) | HELLO exchange: mTLS → API key → Session → Password+MFA chain | `src/transport/quic.zig:139,251` ; `src/server/main.zig:620-760` |
| QUIC HELLO handler (first-stream handshake) | Protocol | Yes | `handleClientMessage` + rate limiter | `src/server/quic_connection_handler.zig:963,1153,1734` |
| gRPC listener (optional, HTTP/2 + TLS) | RPC | Yes (shares auth) | Same unified chain | `src/transport/grpc_server.zig` (2968 LOC) ; `src/server/main.zig:578-616` |
| Federation HELLO (node-to-node) | QUIC | Yes | `GEODE_CLUSTER_TOKEN` as password, user = `"geode-cluster"` (constant-time eql 256-byte pad) | `src/server/quic_connection_handler.zig:1460-1477` ; `src/distributed/cluster_auth.zig:17-30` |
| MCP server (stdio or HTTP) | JSON-RPC | Bearer token (default) | `auth_mode=.bearer`, refuses to start without token | `src/mcp/server.zig:19-33,86-96` |
| Prometheus metrics | HTTP | None by design | Plain HTTP metrics exporter | `src/monitoring/metrics_server.zig` (188 LOC) |
| LSP server | stdio | None (local) | IDE integration | `src/cli/lsp/server.zig`, `src/mcp/lsp.zig` |
| CLI (`geode <cmd>`) | local process | Varies | Reads `~/.geode` session tokens, apikey, DSN creds | `src/cli/main.zig`, `src/cli/cli_dispatcher.zig:472-1043` |
| Shutdown signals | syscall | root / owner | Handled in `main.zig` | `src/server/main.zig:~600` |

### Tenant Isolation

| Mechanism | Scope | Implementation | File:Line |
|-----------|-------|----------------|-----------|
| Per-tenant label filter (full scans) | Nodes | `passesTenantFilter` at 17 sites | `src/execution/match_operations.zig` |
| Label-index tenant filter | Nodes by label | `getNodesByLabels(..., tenant)` at 7 sites | same file |
| Edge-scan tenant filter | Edges by type | `getEdgesByType(..., tenant, graph)` | `src/graph_store.zig`, `src/execution/match_operations.zig` |
| Catalog filtering | SHOW TABLES / listNodeLabels | `filter_tenant` pulled from `ExecutionContext` | `src/execution/meta_dispatch.zig`, `graph_store.zig` |
| RLS label-deny engine | Per-user, per-label | `rls_types.getGlobalRLSFilterEngine` | `src/server/rls_filter.zig`, `src/security/rls_types.zig` |
| RLS expression engine (GAP-0510) | Property + temporal row filter | `passesRLSExprFilter` → `RLSEngine.checkRowAccessByUsername`; fail-closed on errors | `src/execution/match_operations.zig:125-145` ; `src/security/rls_core.zig:367,986` |
| Per-tenant quotas (connections, queries) | Runtime limits | `TenantQuotaManager.checkConnectionQuota/checkQueryQuota` | `src/security/tenant_quota.zig:154,208` |
| Per-tenant FLE keys | Field-level encryption | `fle_integration`, `schema/fle_catalog.zig` | `src/fle_integration.zig`, `src/schema/fle_catalog.zig` |
| Multi-graph RBAC | Per-graph permission grants | `multi_graph_security.zig` | `src/security/multi_graph_security.zig` |
| Known dead+unsafe | `evaluateAggregation` / `evaluateAggregationWithLabels` iterate `store.nodes` without tenant filter | Annotated `GAP-0509 WARNING`; not wired | `src/execution/aggregation_evaluation.zig:629-692` |

### External Integrations

| Integration | Type | Credential Source | File:Line |
|------------|------|-------------------|-----------|
| HashiCorp Vault (Transit) | KV over `vault` CLI subprocess | `VAULT_ADDR`, `VAULT_TOKEN`, `VAULT_KEY_PATH` env | `src/security/vault_kms_provider.zig:378-384,163,251,270` |
| S3 / DO Spaces cloud backup | HTTPS (AWS Sig v2) | `S3Config{access_key, secret_key, region, bucket, endpoint}` | `src/storage/s3_backup.zig:49-80,303-412` |
| External KMS | Custom protocol | `KMSConfig.auth_token`, optional seed | `src/security/external_kms_client.zig:126` ; `src/security/kms.zig:63-72` |
| Remote KMS over QUIC | QUIC | endpoint+port+auth_token | `src/security/kms_remote.zig:188,663` |
| DNS resolver (hostname→IP) | DoT/DoH/DoQ | static config | vendor `dns` lib, `src/transport/quic.zig:28` |
| Federation peers | QUIC mTLS | `GEODE_CLUSTER_TOKEN`; optional `GEODE_CLUSTER_INSECURE=1` | `src/distributed/federation.zig:274-323` ; `src/distributed/cluster_auth.zig:60-63` |
| Raft peers | QUIC | `GEODE_CLUSTER_TOKEN` | `src/distributed/raft_consensus.zig:534,1193` |
| Prometheus / metrics scrape | HTTP | None | `src/monitoring/metrics_server.zig` |

### Datastores & Queues

| Store | Type | Connection Pool | Credential Source | File:Line |
|-------|------|-----------------|-------------------|-----------|
| Local graph store (page-backed + MVCC) | File-mmap + WAL | Per-graph rwlock; `graph_handles_mutex` | `GEODE_DATA_DIR` | `src/graph_store.zig:102`, vendor `graph_storage` |
| WAL | Append-only encrypted | Single writer | `GEODE_WAL_KEY` (hex) | `src/wal.zig:39,136` |
| TDE-encrypted backup files | AES-256-GCM | — | `GEODE_TDE_KEY`, or KMS-wrapped DEK | `src/security/tde.zig:54-100` ; `src/storage/tde_file_encryption.zig` |
| WAL / snapshot backup (local & S3) | Checkpoint | — | Envelope-wrapped keys | `src/storage/backup.zig`, `src/storage/s3_backup.zig` |
| User storage | JSON on disk | `user_store_mutex` (Tier 5) | Argon2id PHC (legacy blake2b migration) | `src/storage/user_storage.zig`, `src/security/user_management.zig:556-575` |
| Session storage | In-memory + file | `session_mutex` | Generated 32-byte token | `src/cli/security/session_storage.zig`, `src/security/authn.zig:117-150` |
| API keys | In-memory + file | — | prefix `gk1`, SHA-256 hash | `src/security/authn.zig:53-58` |
| Audit log (signed) | JSONL + Ed25519 | `audit_mutex` (Tier 6) | `audit.jsonl.key` / `audit.jsonl.pub` (in repo root; local-dev only) | `src/security/audit.zig`, `src/security/auth_graph_manager.zig:351-462` |
| CDC / streaming | In-process | `cdc_mutex` | Uses TDE path | `src/streaming/cdc_enhanced.zig:38-365` |

### Admin Surfaces

| Surface | Auth Level | Exposure | File:Line |
|---------|-----------|----------|-----------|
| `ALTER USER SET PASSWORD` via query path | Self-only, authenticated | QUIC / gRPC | `src/server/quic_connection_handler.zig:1479-1639` |
| Default admin bootstrap | `GEODE_ADMIN_USERNAME/EMAIL/PASSWORD` env | Container/systemd startup | `src/security/user_management.zig:556-575` ; `src/security/geode_auth_lib.zig:1222-1252` |
| `CALL geode.backup.*` / `geode.admin.*` / `geode.user.*` / `geode.apikey.*` / `geode.tde.*` / `geode.audit.*` / `geode.fle.*` / `geode.storage.*` | RBAC-enforced | QUIC/gRPC | `src/execution/procedure_registry.zig` → dispatchers in `src/execution/*_dispatch.zig`, `src/admin/fle_commands.zig` |
| CLI admin (`geode user-mgmt`, `geode apikey`, `geode backup`, `geode mtls`, `geode fle`, `geode storage`) | Session token or DSN | Local shell | `src/cli/{user_mgmt_cli.zig,apikey_cli.zig,backup_cli.zig,mtls_cli.zig,fle_cli.zig,storage_cli.zig}` |
| Audit verify tool | None (reads local file) | Offline | `src/cli/geode_audit_verify.zig` |
| LSP and MCP (dev) | bearer token / local | local / stdio | `src/mcp/server.zig`, `src/cli/lsp/` |

### Build/Deploy & Secret Management

| Component | Type | Secret Handling | File:Line |
|-----------|------|-----------------|-----------|
| Dockerfile (prod) | multi-stage Debian slim | Runs as non-root `geode` uid 1000; certs mounted read-only volume; `--enable-auth` default | `Dockerfile:60-118` |
| docker-compose.yml | local dev stack | Uses `${REDIS_PASSWORD:?...}` from `.env`; does not commit secrets | `docker-compose.yml:59,198` |
| .gitlab-ci.yml | GitLab CI | Uses `$CI_JOB_TOKEN` via `git config` URL insteadOf; no static secrets in file | `.gitlab-ci.yml:75-77,473-482` |
| Self-signed TLS fallback | auto-gen on first start if certs missing | `certs/server.crt`, `certs/server.key` (0600) | `src/transport/quic.zig:251-299`, `src/tools/cert_gen.zig` |
| Env-driven secrets | `getEnvVarOwned` wrapper | `GEODE_ADMIN_PASSWORD`, `GEODE_MASTER_KEY`, `GEODE_WAL_KEY`, `GEODE_TDE_KEY`, `GEODE_CLUSTER_TOKEN`, `GEODE_CLUSTER_INSECURE`, `GEODE_MTLS_REQUIRED`, `VAULT_TOKEN`, `GEODE_DEFAULT_PASSWORD`, `GEODE_AUTH_CACHE_SIZE`, `GEODE_PASSWORD_MIN_LENGTH/WORDS` | `src/compat.zig:11-15` ; 26 consumers (see Grep) |
| Subprocess use (supply-chain hazard) | `std.ChildProcess.exec` calls `vault kv {list,get,put}` | Key-name regex: `[A-Za-z0-9._/-]`; rejects leading `-` (Issue #435) | `src/security/vault_kms_provider.zig:38-47,163,251,270` |
| In-repo artefacts | `audit.jsonl`, `audit.jsonl.key` (0600), `audit.jsonl.pub`, `certs/server.key` (0600) | These are dev-only — must NOT ship to production | `/` repo root |

---

## Threat Model

### Assets

| Asset | Sensitivity | Location |
|-------|------------|----------|
| Customer graph data (nodes / edges / props) | High (may include PII, PHI per RLS policies) | `GEODE_DATA_DIR` pages + WAL |
| Authenticated user records | High | `user_storage` (Argon2id hashes) |
| Session tokens + API keys | High | in-memory + session files |
| FLE field keys (per tenant) | Critical | wrapped via KMS; `fle_catalog` |
| WAL/TDE master keys | Critical | env `GEODE_WAL_KEY`, KMS (Vault/remote/local) |
| Cluster token | Critical | `GEODE_CLUSTER_TOKEN` (grants node-trust) |
| Audit log integrity | High | Ed25519-signed, HMAC-chained |
| TLS server private key | Critical | `certs/server.key` |
| Backup archives (local + S3) | High | envelope-encrypted |
| CI job token / registry creds | Medium | GitLab CI masked vars |

### Trust Boundaries

| Boundary | From | To | Controls |
|----------|------|-----|----------|
| B1 | Public internet | QUIC listener | TLS 1.3, optional mTLS (`GEODE_MTLS_REQUIRED`), per-IP auth rate limiter (`AuthRateLimiter`, S6), HELLO auth, fail-closed by default |
| B2 | Public internet / internal | gRPC listener | same unified auth chain |
| B3 | Authenticated session | Graph execution | RLS label-deny + RLS expression engine + tenant filter + FLE hooks + per-tenant quotas |
| B4 | Server | KMS (Vault / Remote / External) | Vault CLI subprocess, remote QUIC auth_token, AES-GCM envelope |
| B5 | Server | S3 / DO Spaces | HTTPS, AWS Sig v2, TLS (vendor http client) |
| B6 | Node | Node (cluster) | QUIC mTLS + `GEODE_CLUSTER_TOKEN`; insecure escape via `GEODE_CLUSTER_INSECURE=1` (SEC risk if set in prod) |
| B7 | Dev laptop / CI | Repo / container registry | GitLab `CI_JOB_TOKEN`, signed commits optional |
| B8 | Operator | systemd unit / container | env-var secrets; docker non-root; cert volume read-only |
| B9 | LLM/AI client | MCP server | Bearer token, stdio or HTTP |
| B10 | Filesystem | Server process | uid 1000 non-root in container; host deployments inherit process UID |

### Attacker Types

- Unauthenticated external (B1/B2/B9)
- Authenticated tenant user (B3)
- Compromised cluster peer (B6)
- Compromised KMS / backup target (B4/B5)
- Supply chain (vendor git+https deps at Phase 1–7, `build.zig.zon`)
- Insider / developer with repo access (B7/B8)

### Top Abuse Cases (Prioritized)

| Rank | Abuse Case | Attacker Type | Likelihood | Impact | Entry Points |
|------|-----------|---------------|-----------|--------|-------------|
| 1 | Cross-tenant data read via dead-code aggregation paths being revived / bypass of RLS expression engine due to manual policy compilation | Auth tenant user | Med | High | `src/execution/aggregation_evaluation.zig:629-692` ; `src/security/rls_core.zig` |
| 2 | Federation / Raft peer spoof if `GEODE_CLUSTER_TOKEN` leaks or `GEODE_CLUSTER_INSECURE=1` in prod | Network attacker | Med | Critical | `src/distributed/cluster_auth.zig:17-63` ; `src/distributed/federation.zig:274-323` |
| 3 | Password brute force / credential stuffing on HELLO | Unauth ext | High | High | QUIC HELLO path; limiter at `src/server/auth_rate_limiter.zig` |
| 4 | Argument injection / command injection into `vault` subprocess (mitigated by `validateKeyName`) | Operator with key-admin rights | Low | High | `src/security/vault_kms_provider.zig:38-47,163-275` |
| 5 | Session-token theft (30-min idle, 24 h lifetime, 1 min grace for rotated) / replay across IPs | Auth user | Med | High | `src/security/authn.zig:117-150` |
| 6 | Supply-chain compromise of any `.zig` dep listed in `build.zig.zon` (audit, auth, fle, graph_storage, wal, raft, quic) | External | Low | Critical | `build.zig.zon:9-216` |
| 7 | Bootstrap admin weak-password / env leak (`GEODE_ADMIN_PASSWORD`) | Operator mistake | Med | Critical | `src/security/user_management.zig:556-575`; `Dockerfile:96,118` |
| 8 | Audit-log tamper / disable (HMAC key file `audit.jsonl.key` present in repo root for dev) | Insider | Med | High | `src/security/audit.zig`, `src/security/auth_graph_manager.zig:351-462` |
| 9 | TDE/WAL key rollover mismatch or plaintext fallback when `GEODE_ENABLE_TDE` off | Operator | Low | Critical | `src/security/tde.zig:63-100`, `src/security/key_rotation.zig` |
| 10 | MCP server auth bypass if operator sets `auth_mode=.none` for prod | Operator / remote | Low | High | `src/mcp/server.zig:19-33` |
| 11 | S3 Sig v2 MITM / replay (Sig v2 is weaker than v4); endpoint override allows DNS hijack | Net attacker | Low | Med | `src/storage/s3_backup.zig:303-412` |
| 12 | Fuzzing / DoS of GQL parser or vendored QUIC | Unauth ext | Med | Med | `src/gql/`, `vendor/quic` |

### Sensitive Modules Flagged for Deeper Scan (Phase 2+)

- `src/security/geode_auth_lib.zig` (authN, RBAC, password hashing, step-up)
- `src/security/authn.zig` (unified auth chain, session rotation)
- `src/security/rls_core.zig` (3,103 LOC — expression evaluator + policy evaluation)
- `src/security/tde.zig` + `src/security/tde_key_manager.zig` + `src/security/tde_nonce_gen.zig`
- `src/security/kms.zig` + `vault_kms_provider.zig` + `kms_remote.zig` + `external_kms_client.zig`
- `src/security/audit.zig` (2,133 LOC; signing, chain verify)
- `src/security/user_management.zig` + `user_manager.zig` (admin bootstrap)
- `src/security/mfa.zig` + `mfa_policy.zig` + `mfa_risk.zig`
- `src/server/quic_connection_handler.zig` (HELLO, federation auth, rate limit)
- `src/server/auth_rate_limiter.zig` + `rls_filter.zig`
- `src/transport/quic.zig` (TLS load, self-signed fallback)
- `src/transport/grpc_server.zig` (2,968 LOC — HTTP/2, TLS)
- `src/distributed/cluster_auth.zig` + `federation.zig` + `raft_consensus.zig` + `twophase.zig`
- `src/execution/match_operations.zig` (tenant/RLS enforcement points)
- `src/execution/aggregation_evaluation.zig` (dead-code bypass warnings)
- `src/execution/procedure_registry.zig` + `src/execution/*_dispatch.zig` (admin procedures)
- `src/execution/fle_hooks.zig` + `src/schema/fle_catalog.zig`
- `src/storage/s3_backup.zig` (Sig v2 AWS) + `src/storage/tde_file_encryption.zig`
- `src/mcp/server.zig` (bearer, stubbed handlers)
- `src/wal.zig` (env-loaded key)

### Unknowns & Assumptions

- gRPC transport (2.9k LOC) applies the same unified auth chain as QUIC — assumed from import topology; confirm via reading `handleMessage` path in `src/transport/grpc_server.zig`.
- HNSW / R-tree / vector paths have no separate auth enforcement — assumed to inherit from node-scan RLS; confirm in `src/index/`.
- Whether `GEODE_CLUSTER_INSECURE=1` is gated behind a build flag or purely env — evidence says env-only.
- Policy compilation for RLS expressions is manual (per CLAUDE.md); GQL→bytecode pipeline missing — parser path should be confirmed.
- `docker-compose.yml` uses Redis — not in main server; likely dev-only satellite stack, confirm it is not used as a shared session store in prod.
- Actual CI GitLab variables list (`CI/CD variables` UI) — not visible in repo; assume `REGISTRY_PASSWORD`, `GEODE_ADMIN_PASSWORD`, etc. configured as masked.
- Secret scanning / gitleaks: `audit.jsonl.key` is present and 0600 — confirm it is in `.gitignore` (it is not committed as staged secret but lives at repo root).
- No explicit CSRF protection needed (no browser cookie surface) — MCP HTTP is the only browser-adjacent transport and uses bearer.
- gRPC auth is assumed enforced per CANARY `REQ-ABAC-WIRE-*` markers but not independently exercised in Phase 1 inventory.
