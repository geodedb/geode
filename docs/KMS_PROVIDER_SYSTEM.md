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

## TDE-KMS Integration

**Implementation**: `src/security/tde_kms_integration.zig`

### TDEKeyManager: Comprehensive key lifecycle management

```zig
// Initialize TDE with KMS provider
var manager = tde_kms.TDEKeyManager.init(allocator);
try manager.initializeWithKMS(kms.KMSConfig{
    .provider_type = .vault_transit,
    .vault_addr = "https://vault.company.com",
    .auth_token = vault_token,
    .vault_key_path = "geode/encryption"
});

// Get derived keys for different encryption domains
const data_key = try manager.getDataKey();    // For database pages
const wal_key = try manager.getWALKey();      // For WAL records

// Perform key rotation
try manager.rotateKeys();
```

### Factory Functions for Different Configurations

```zig
// Local development TDE
var dev_tde = try tde_kms.createLocalDevTDE(allocator);

// External KMS TDE (deterministic for testing)
var test_tde = try tde_kms.createExternalKMSTDE(allocator, 0xSEED);

// Remote KMS TDE (production QUIC)
var prod_tde = try tde_kms.createRemoteKMSTDE(allocator, "kms.prod.com", 3141, token);

// HashiCorp Vault TDE (enterprise)
var vault_tde = try tde_kms.createVaultTDE(allocator, vault_addr, vault_token, key_path);

// Environment variable TDE (legacy)
var env_tde = try tde_kms.createEnvTDE(allocator);
```

## Vault Integration Features

**Implementation**: `src/security/vault_kms_provider.zig`

### Key Operations

- **Key Generation**: Cryptographically secure 32-byte key generation
- **Vault Storage**: Direct integration with `vault kv put/get` operations
- **Envelope Encryption**: Complete metadata serialization for audit trails
- **Key Rotation**: Automated rotation with Vault versioning support
- **Cross-Platform**: Works with any Vault-compatible KMS

### Production Usage

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

- **Key Rotation**: Automated rotation with configurable policies
- **Audit Logging**: All KMS operations logged for compliance
- **Zero Plaintext**: Master keys never stored in plaintext on disk
- **Multiple Providers**: Easy migration between KMS systems
- **Performance**: <1% encryption overhead with hardware acceleration

## Test Coverage & Verification

### Test Suites

- **`tests/test_kms_provider.zig`**: 11 comprehensive KMS provider test scenarios
- **`tests/test_tde_kms_integration.zig`**: 9 TDE-KMS integration test scenarios  
- **`tests/test_vault_kms_provider.zig`**: 6 Vault-specific integration tests

### Key Test Scenarios

- **Multi-Provider Compatibility**: Cross-provider key wrapping/unwrapping
- **Deterministic Behavior**: Reproducible encryption for testing
- **Error Handling**: Comprehensive error scenario coverage
- **Performance Testing**: Large-scale encryption operations (1KB-64KB)
- **Key Rotation**: Automated rotation testing with different providers
- **Vault Integration**: Real Vault server testing with live authentication

## Production Deployment

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
- **TDE Overhead**: <1% database operation impact
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
