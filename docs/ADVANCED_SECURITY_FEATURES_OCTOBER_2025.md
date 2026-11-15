# Advanced Security Features - October 2025

**Last Updated**: January 2026 (GAP-0111 fix)
**Status**: Implemented (single-tenant scope) — see [GAP_ANALYSIS.md](GAP_ANALYSIS.md) and [CLAUDE.md Known Limitations](../CLAUDE.md#known-limitations)

> **Status note (2026-11-11, SONNY-6298):** the RLS section below names
> `src/security/rls.zig`, which does not exist, and the "Enhanced RLS"
> layer (`src/security/rls_enhanced.zig`: `EnhancedRLSEngine`,
> `ExpressionCompiler`, `RLSStatisticsCollector`, `EnhancedCacheManager`)
> was never compiled by any build artifact and has been removed. What the
> server runs is `src/security/rls_core.zig` (the `rls` module): policy
> CRUD, bytecode-compiled expression policies enforced in the MATCH loop
> through `passesRLSExprFilter` (`src/execution/match_operations.zig`; engine
> installed at startup by `setGlobalExprRLSEngine`), `current_user()` and
> `has_role()`, temporal and IPv4 CIDR conditions, and a policy cache; plus
> the label-level post-result filter in `src/server/rls_filter.zig` and GPS
> policy DDL. Test steps: `test-rls-core`, `test-rls-filter`,
> `test-rls-expr-engine-wiring`, `test-rls-policy-ddl`,
> `test-gps-policy-expression`. Not implemented: an RLS policy optimizer,
> per-policy evaluation statistics, and "index-aware filtering". Policy
> expressions still have to be pinned as pre-compiled bytecode (see
> CLAUDE.md Known Limitations). The `ALTER TABLE ... ENABLE ROW LEVEL
> SECURITY` example below is SQL, not Geode syntax.

## Overview

This document details the advanced security features implemented in Geode, including the Enhanced Row-Level Security (RLS) system and related enterprise security capabilities.

## Enhanced Row-Level Security (RLS)

### Implementation

The Enhanced RLS system provides fine-grained access control at the row level with:

- **Policy Evaluation Engine**: `src/security/rls.zig`
- **Expression Compilation**: Optimized policy expression handling
- **Context-Aware Filtering**: User/role/session-based policy application

### Features

1. **Policy Types**
   - SELECT policies (read access)
   - INSERT policies (write access)
   - UPDATE policies (modify access)
   - DELETE policies (remove access)

2. **Policy Composition**
   - Multiple policies per table
   - AND/OR composition rules
   - Role-based policy binding

3. **Performance Optimizations**
   - Policy caching
   - Expression pre-compilation
   - Index-aware filtering

### Usage Example

Not supported as written: this is SQL (`ON employees`, `FOR SELECT`,
`ALTER TABLE ... ENABLE ROW LEVEL SECURITY`); Geode has no tables, no
`current_user_department()`, and its own policy DDL (see
docs/GQL_AUTH_DDL.md).

```text
-- Create an RLS policy
CREATE POLICY employee_access ON employees
  FOR SELECT
  USING (department_id = current_user_department());

-- Enable RLS on table
ALTER TABLE employees ENABLE ROW LEVEL SECURITY;
```

## Transparent Data Encryption (TDE)

### Implementation

- **Algorithm**: AES-256-GCM (NIST SP 800-38D compliant)
- **Key Management**: External KMS support (Vault, AWS KMS)
- **Page Encryption**: Automatic encryption/decryption at storage layer
- **Key scope**: At-rest TDE (pages, WAL, backups) uses a **single instance
  master key** (`GEODE_TDE_KEY`), **not** per-tenant keys. A master-key
  compromise spans every tenant's at-rest data; for cryptographic at-rest
  separation between tenants, isolate per tenant at the instance / data-directory
  level. Per-tenant at-rest encryption is deferred — see
  [Per-Tenant At-Rest Encryption (Deferred)](design/TDE_PER_TENANT_KEYS_DEFERRED.md)
  (GAP-0851 / GAP-0290). Per-tenant cryptographic boundaries that *do* ship today
  are field-level (FLE) — see [Field-Level Encryption](FIELD_LEVEL_ENCRYPTION.md).

### Security Enhancements (January 2026)

| Issue | Fix | Evidence |
|-------|-----|----------|
| Deterministic nonces | Use std.crypto.random | GAP-0107 |
| Deterministic mode | Block in production | GAP-0109 |
| Weak test PRNG | Use crypto random | GAP-0110 |

## Authentication & Authorization

### Implemented Authentication Methods (January 2026)

| Method | Status | Use Case | Security Level | Implementation |
|--------|--------|----------|----------------|----------------|
| Username/Password | ✅ Implemented | Interactive login | High | `src/security/user_management.zig` |
| MFA (TOTP) | ✅ Implemented | Two-factor auth | Very High | `src/security/mfa.zig` |
| Session Tokens | ✅ Implemented | Session continuity | High | `src/security/authn.zig` |
| API Keys | ✅ Implemented | Service accounts, automation | Medium-High | `src/security/api_keys.zig` |
| mTLS (Certificate) | ✅ Implemented | Zero-trust, service mesh | Very High | `src/security/mtls_provider.zig` |

### Not Supported (Tracking Issues Open)

| Method | Status | Tracking | Notes |
|--------|--------|----------|-------|
| LDAP/Active Directory | ❌ Not supported | [#802](https://gitlab.com/devnw/codepros/geode/geode/-/issues/802) (GAP-0834) | The previous documentation overstated current capability. Will be implemented when a customer requires it. |
| OAuth2/OIDC | ❌ Not supported | [#803](https://gitlab.com/devnw/codepros/geode/geode/-/issues/803) (GAP-0835) | The previous documentation overstated current capability. Will be implemented when a customer requires it. |

### Features

1. **Authentication Methods**
   - Username/password with Argon2id hashing
   - MFA support (TOTP, recovery codes)
   - Session token management with rotation (`src/security/authn.zig`)
   - API Keys for programmatic access (`src/security/api_keys.zig`)
   - mTLS certificate-based authentication (`src/security/mtls_provider.zig`)

2. **Authorization**
   - Role-Based Access Control (RBAC)
   - Attribute-Based Access Control (ABAC)
   - Fine-grained permissions

### Security Enhancements (January 2026)

| Issue | Fix | Evidence |
|-------|-----|----------|
| Hardcoded credentials | Removed; use env vars | GAP-0104 |
| Auth disabled default | Enabled by default | GAP-0106 |
| Default password | Random generation | GAP-0108 |

## Transport Security

### QUIC+TLS Configuration

- **Protocol**: QUIC with TLS 1.3
- **Certificate Validation**: Enabled by default (GAP-0105 fix)
- **Cipher Suites**: Strong ciphers only

### Security Enhancements (January 2026)

| Issue | Fix | Evidence |
|-------|-----|----------|
| Insecure TLS default | allow_insecure=false | GAP-0105 |
| KMS insecure TLS | Fixed in kms_remote.zig | GAP-0105 |

## Audit Logging

### Features

- Signed audit trails with Ed25519
- Tamper detection via hash chains
- Structured JSON format
- Syslog integration with real TLS

### Implementation

- `src/security/audit.zig` - Core audit logging
- `src/audit/syslog.zig` - Syslog with TLS support

## Field-Level Encryption (FLE)

### Features

- Searchable encryption with blind indexes
- Per-field encryption keys
- Role-based decryption permissions
- Predicate rewriting for encrypted queries

## Security Verification

### CANARY Markers

All security implementations are tracked with CANARY markers:

```
CANARY: REQ=REQ-AUTH-001; FEATURE="UserManagement"; ASPECT=Authentication; STATUS=TESTED; OWNER=security; UPDATED=2025-10-14
CANARY: REQ=REQ-GQL-TDE-001; FEATURE="TDE"; ASPECT=Encryption; STATUS=TESTED; OWNER=security; UPDATED=2025-10-14
```

### Regression Tests

Security fixes include regression tests in:

- `geodetestlab/specs/gap_0104_0122_security_regression.yml`
- `geodetestlab/specs/gap_0102_0103_security_regression.yml`

## References

- [KMS_PROVIDER_SYSTEM.md](KMS_PROVIDER_SYSTEM.md) - Key management details
- [USER_AUTH.md](USER_AUTH.md) - Authentication documentation
- [GAP_ANALYSIS.md](GAP_ANALYSIS.md) - Security gap tracking
