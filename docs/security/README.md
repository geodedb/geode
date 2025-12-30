# Geode Security Documentation

Comprehensive security documentation for Geode graph database.

## Security Status Matrix

- **[SECURITY_PROGRESS.md](../SECURITY_PROGRESS.md)** - Current implementation status and CANARY markers

## Authentication & Users

- **[USER_AUTH.md](../USER_AUTH.md)** - User authentication, RBAC/ABAC, MFA support
- **[ARGON2ID_IMPLEMENTATION.md](../ARGON2ID_IMPLEMENTATION.md)** - Password hashing implementation

## Encryption

### Transparent Data Encryption (TDE)

- **[KMS_PROVIDER_SYSTEM.md](../KMS_PROVIDER_SYSTEM.md)** - KMS provider system (Vault, Remote, Local)
- **[DESIGN_TDE_KMS.md](../DESIGN_TDE_KMS.md)** - TDE architecture and key hierarchy design

### Field-Level Encryption

- **[FIELD_LEVEL_ENCRYPTION.md](../FIELD_LEVEL_ENCRYPTION.md)** - Field-level encryption implementation

## Access Control

- **[RLS_IMPLEMENTATION.md](../kb/RLS_IMPLEMENTATION.md)** - Row-Level Security with RBAC/ABAC

## Audit & Compliance

- **[AUDIT_LOGGING.md](../AUDIT_LOGGING.md)** - Tamper-evident audit logging with hash chains

## Quick Reference

### Security Features Overview

| Feature | Status | Documentation |
|---------|--------|---------------|
| AES-256-GCM Page Encryption | Complete | KMS_PROVIDER_SYSTEM.md |
| WAL Encryption | Complete | KMS_PROVIDER_SYSTEM.md |
| Key Rotation | Complete | SECURITY_PROGRESS.md |
| HashiCorp Vault Integration | Complete | KMS_PROVIDER_SYSTEM.md |
| MFA (TOTP + Recovery) | Complete | USER_AUTH.md |
| Argon2id Password Hashing | Complete | ARGON2ID_IMPLEMENTATION.md |
| Row-Level Security | Complete | RLS_IMPLEMENTATION.md |
| Field-Level Encryption | Complete | FIELD_LEVEL_ENCRYPTION.md |
| Audit Logging (Hash Chain) | Complete | AUDIT_LOGGING.md |
| Ed25519 Signatures | Complete | AUDIT_LOGGING.md |

### Environment Variables

| Variable | Description |
|----------|-------------|
| `GEODE_DISK_KEY_HEX` | 32-byte hex key for TDE (StaticEnv provider) |
| `GEODE_AUDIT_PUB` | Ed25519 public key for audit signing (hex32) |
| `GEODE_AUDIT_SEC` | Ed25519 secret key for audit signing (hex64) |
| `VAULT_ADDR` | HashiCorp Vault address |
| `VAULT_TOKEN` | Vault authentication token |

### CANARY Requirements

Security implementations tracked via CANARY markers:

- `REQ-GQL-TDE-*` - TDE encryption features
- `REQ-GQL-SEC-*` - General security features
- `REQ-GQL-MFA-*` - Multi-factor authentication
- `REQ-GQL-RLS-*` - Row-level security

## Implementation Files

| Component | Source Location |
|-----------|----------------|
| KMS Providers | `src/security/kms.zig` |
| TDE-KMS Integration | `src/security/tde_kms_integration.zig` |
| Vault Provider | `src/security/vault_kms_provider.zig` |
| Auth/Users | `src/security/auth.zig` |
| RLS | `src/security/rls.zig` |
| Audit Logger | `src/security/audit/logger.zig` |
| Field Encryption | `src/security/fle.zig` |
