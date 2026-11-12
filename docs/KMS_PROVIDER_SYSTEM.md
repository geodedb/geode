# KMS Provider System Documentation

## Overview

Geode provides enterprise-grade Key Management Service (KMS) integration for Transparent Data Encryption (TDE) with support for multiple KMS providers including HashiCorp Vault.

## Multi-Provider Architecture

**Core Implementation**: `src/security/kms.zig`

- **Provider Types**: Local dev, External KMS, Remote KMS, HashiCorp Vault
- **Envelope Encryption**: AES-256-GCM with JSON metadata serialization
- **Factory Functions**: Easy provider instantiation with configuration management
- **Statistics Integration**: Performance tracking and cost estimation

## Supported KMS Providers

### 1. Local Development Provider (Development Only)

```zig
var provider = kms.localDevProvider(allocator);
// Simple XOR-based encryption for development/testing - NOT secure
```

### 2. External KMS Provider (Deterministic)

```zig  
var provider = kms.externalKMSProvider(allocator, 0xDEADBEEFCAFEBABE);
// AES-256-GCM with deterministic behavior for testing and CI
```

### 3. Remote KMS Provider (QUIC-based)

```zig
var provider = kms.remoteKMSProvider(allocator, "kms.example.com", 3141, "auth_token");
// Production KMS over QUIC with authentication and tamper detection
```

### 4. HashiCorp Vault Provider (Enterprise)

```zig
var provider = kms.vaultKMSProvider(allocator, "https://vault.example.com", "vault_token", "secret/path");
// Enterprise Vault integration with CLI-based operations
```

## TDE-KMS Integration — Not Implemented

**Status (2026-11-11, SONNY-6298):** the TDE master key is not obtained from,
or wrapped by, any KMS provider. This section used to describe a
`TDEKeyManager` in `src/security/tde_kms_integration.zig`
(`initializeWithKMS`, KMS-derived data/WAL keys, `rotateKeys`, and the
`createLocalDevTDE` / `createRemoteKMSTDE` / `createVaultTDE` factories). That
file was reachable from no executable or test in `build.zig`; it was never
compiled and was removed, with its uncompiled test
`tests/test_tde_kms_integration.zig`.

What the server does:

- The TDE master key is read from `GEODE_TDE_KEY` (64 hex characters) by
  `src/security/tde_key_manager.zig`.
- When `GEODE_KMS_URL` is set, server startup calls
  `tde_key_manager.configureKMS`, which only checks that the endpoint accepts a
  TCP connection and refuses to start if it does not. No key is fetched from
  or wrapped by that endpoint. For the symbolic provider names (`aws`, `azure`,
  `gcp`, `hashicorp`, `local`) it runs a local AES-256-GCM round trip with an
  ephemeral key.
- The providers in `src/security/kms.zig` are reached from the
  `tde.configure_kms`, `tde.configure_mock_kms` and `tde.test_kms_wrap_unwrap`
  procedures
  (`src/execution/storage_dispatch.zig`), which build a provider and run a
  wrap/unwrap round trip; they do not install a key into page or WAL
  encryption.

## Vault Integration Features

**Implementation**: `src/security/vault_kms_provider.zig`

### Key Operations

- **Key Generation**: Cryptographically secure 32-byte key generation
- **Vault Storage**: Direct integration with `vault kv put/get` operations
- **Envelope Encryption**: Complete metadata serialization for audit trails
- **Key Rotation**: Operator-invoked rotation (Vault re-versioning via `vault kv put`); geode does not run an in-server rotation timer
- **Cross-Platform**: Works with any Vault-compatible KMS

### Production Usage

> **Not wired (2026-11-11, SONNY-6298):** no code reads `GEODE_KMS_PROVIDER`
> or `GEODE_VAULT_KEY_PATH`, and `geode serve` has no `--kms-provider` flag.
> The TDE master key comes from `GEODE_TDE_KEY`; see
> [TDE-KMS Integration](#tde-kms-integration--not-implemented). The commands
> below do not produce Vault-backed TDE.

```bash
# Set Vault environment
export VAULT_ADDR="https://vault.company.com"
export VAULT_TOKEN="hvs.CAESI..."

# Configure Geode TDE with Vault
export GEODE_KMS_PROVIDER="vault"
export GEODE_VAULT_KEY_PATH="geode/encryption"

# Start Geode with Vault-backed TDE
./zig-out/bin/geode serve --enable-tde --kms-provider vault
```

## Security & Compliance Features

### Key Hierarchy Architecture

- **Master Key**: Loaded from `GEODE_TDE_KEY` (env-var only; no KMS unwrap path into page encryption),
  stored securely in the KMS provider (Vault, HSM, etc.).
- **Derived keys**: The master key derives **domain-separated** data and backup
  keys via `SHA-256(master || domain)`
  ([`src/security/tde_hierarchy.zig`](../src/security/tde_hierarchy.zig)). These
  domains separate **data pages vs. backups**, **not** database from database or
  tenant from tenant. Every per-graph storage engine is wired with the **same**
  raw master key (`GraphConfig.encryption_key` in
  [`src/graph_store.zig`](../src/graph_store.zig)).
- **Key scope**: At-rest TDE (pages, WAL, backups) is **instance-wide** under
  one master key — there is **no** per-database or per-tenant at-rest key. A
  master-key compromise spans all data. Per-tenant at-rest encryption is deferred
  — see [Per-Tenant At-Rest Encryption (Deferred)](design/TDE_PER_TENANT_KEYS_DEFERRED.md)
  (GAP-0851 / GAP-0290). Per-tenant cryptographic boundaries that ship today are
  field-level (FLE) — see [Field-Level Encryption](FIELD_LEVEL_ENCRYPTION.md).
- **Metadata**: Complete audit trail with algorithm, nonce, and authentication tag.

### Enterprise Security

- **Key Rotation**: Policy-ENFORCED, operator-invoked rotation (GAP-0890). `KeyRegistry.rotateNow()` refuses with `error.RotationPolicyRefused` while the active key is younger than `RotationPolicy.min_interval_secs`; `max_age_secs` forces rotation past the deadline; `rotateIfDue()` is the scheduler tick an external scheduler (cron / operator script) calls with an injected clock. There is **no in-server rotation timer**, and re-encryption of existing pages is **lazy** (`reencryptPage` on access / `reencryptBatch` on demand) — no eager full-scan re-encrypt exists. Verified by `zig build test-gap0890` (`tests/test_gap0890_rotation_policy.zig`); real rotation/re-wrap latency measured by `zig build bench-tde-key-rotate`
- **Audit Logging**: All KMS operations logged for compliance
- **Zero Plaintext**: Master keys never stored in plaintext on disk
- **Multiple Providers**: Easy migration between KMS systems
- **Performance**: <5% TDE overhead on OLTP workloads (the validated target: `tests/test_tde_oltp_overhead_threshold.zig`, [BENCHMARK_REPORT.md](../BENCHMARK_REPORT.md))

## Test Coverage & Verification

### Test Suites

- `zig build test-remote-kms`, `test-remote-kms-hardening` and
  `test-sonny2394-kms-client-deadline`: the remote KMS server and client over
  real QUIC (`src/security/kms_remote.zig`).
- `zig build test-gap0890`: key rotation policy and lazy re-wrap.
- `tests/test_kms_provider.zig` is in no build step (not compiled or run).
  `tests/test_vault_kms_provider.zig` and `tests/test_tde_kms_integration.zig`
  do not exist.

### Key Test Scenarios

- **Multi-Provider Compatibility**: Cross-provider key wrapping/unwrapping
- **Deterministic Behavior**: Reproducible encryption for testing
- **Error Handling**: Comprehensive error scenario coverage
- **Performance Testing**: Large-scale encryption operations (1KB-64KB)
- **Key Rotation**: Policy-refusal, max-age force, scheduler-tick, and real AES-256-GCM lazy re-wrap regression tests (`zig build test-gap0890`)
- **Vault Integration**: Real Vault server testing with live authentication

## Production Deployment

> **Not wired:** the Vault and `GEODE_KMS_PROVIDER` settings in this section are
> not read by the server (see [Production Usage](#production-usage)).

### Vault Configuration

```bash
# Enable KV secrets engine for Geode
vault secrets enable -path=geode kv-v2

# Store master encryption key
vault kv put geode/master-key \
  value="64-char-hex-encoded-master-key..."

# Configure access policy
vault policy write geode-tde - <<EOF
path "geode/*" {
  capabilities = ["create", "read", "update", "delete", "list"]
}
EOF
```

### Environment Setup

```bash
# Vault authentication
export VAULT_ADDR="https://vault.production.com"  
export VAULT_TOKEN="$(vault write -field=token auth/github/login token=$GITHUB_TOKEN)"

# Geode TDE configuration
export GEODE_ENABLE_TDE="true"
export GEODE_KMS_PROVIDER="vault"
export GEODE_VAULT_KEY_PATH="geode"

# Start Geode with enterprise encryption
./zig-out/bin/geode serve --data-dir /secure/data --listen-quic 0.0.0.0:3141
```

## Performance Characteristics

- **Key Operations**: <10ms for wrap/unwrap operations
- **Vault Integration**: <50ms for key retrieval including network latency
- **TDE Overhead**: <5% TDE overhead on OLTP workloads (validated by `tests/test_tde_oltp_overhead_threshold.zig`)
- **Memory Efficiency**: Minimal key caching with automatic cleanup
- **Scalability**: Supports thousands of concurrent encrypt/decrypt operations

## Enterprise Benefits

- **Compliance**: SOX, PCI-DSS, HIPAA, GDPR data protection standards
- **Audit Trail**: Complete key operation history for regulatory requirements
- **High Availability**: Multi-region Vault deployment support
- **Key Recovery**: Disaster recovery through Vault backup and replication
- **Zero-Downtime Rotation**: Hot key rotation without service interruption

## API Reference

### KMSProvider Interface

```zig
pub const KMSProvider = struct {
    pub fn init(allocator: std.mem.Allocator, config: KMSConfig) KMSProvider;
    pub fn deinit(self: *KMSProvider) void;
    pub fn fetchActiveMasterKey(self: *KMSProvider) !MasterKeyId;
    pub fn wrapDataKey(self: *KMSProvider, plaintext: []const u8) !WrappedKey;
    pub fn unwrapDataKey(self: *KMSProvider, wrapped: WrappedKey) ![]u8;
    pub fn getProviderInfo(self: *KMSProvider) ProviderInfo;
};
```

### TDEKeyManager Interface

```zig
pub const TDEKeyManager = struct {
    pub fn init(allocator: std.mem.Allocator) TDEKeyManager;
    pub fn deinit(self: *TDEKeyManager) void;
    pub fn initializeWithKMS(self: *TDEKeyManager, kms_config: kms.KMSConfig) !void;
    pub fn initializeWithEnv(self: *TDEKeyManager) !void;
    pub fn getDataKey(self: *TDEKeyManager) ![32]u8;
    pub fn getWALKey(self: *TDEKeyManager) ![32]u8;
    pub fn rotateKeys(self: *TDEKeyManager) !void;
    pub fn getStatus(self: *TDEKeyManager) KeyStatus;
};
```

### Factory Functions

```zig
// KMS Provider factories
pub fn localDevProvider(allocator: std.mem.Allocator) KMSProvider;
pub fn externalKMSProvider(allocator: std.mem.Allocator, seed: u64) KMSProvider;
pub fn remoteKMSProvider(allocator: std.mem.Allocator, endpoint: []const u8, port: u16, auth_token: ?[]const u8) KMSProvider;
pub fn vaultKMSProvider(allocator: std.mem.Allocator, vault_addr: []const u8, vault_token: []const u8, key_path: []const u8) KMSProvider;

// TDE factories
pub fn createLocalDevTDE(allocator: std.mem.Allocator) !TDEKeyManager;
pub fn createExternalKMSTDE(allocator: std.mem.Allocator, seed: u64) !TDEKeyManager;
pub fn createRemoteKMSTDE(allocator: std.mem.Allocator, endpoint: []const u8, port: u16, auth_token: ?[]const u8) !TDEKeyManager;
pub fn createVaultTDE(allocator: std.mem.Allocator, vault_addr: []const u8, vault_token: []const u8, key_path: []const u8) !TDEKeyManager;
pub fn createEnvTDE(allocator: std.mem.Allocator) !TDEKeyManager;
```
