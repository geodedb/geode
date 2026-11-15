# MFA Security Implementation

**Last Updated**: January 29, 2026
**Status**: TOTP + recovery codes implemented and tested; step-up uses explicit operation classification (GAP-0884). SMS/email/hardware methods and real risk signals are planned (see SERVER_FEATURES.md §7.4).
**Security Audit**: Passed (January 2026)

> **MFA is not enforced at login (SONNY-6602).** The QUIC and gRPC HELLO
> never ask for a TOTP code or a recovery code, and
> `SecurityManager.authenticateWithMFA` (the "Authentication Flow" below)
> has no production caller: it is a library path only. No login is
> protected by MFA until story SONNY-6604 wires it into HELLO. The
> `geode.auth.mfa_*` procedures enroll a secret and check a code on request,
> and answer a `warning` column saying so. See
> [USER_AUTH.md](USER_AUTH.md#mfa-is-not-enforced-at-login).

## Overview

Geode implements Multi-Factor Authentication (MFA) using the **RFC 6238 TOTP** (Time-based One-Time Password) algorithm with HMAC-SHA1. This document covers the security architecture, API reference, enrollment flows, and enforcement mechanisms.

## Table of Contents

1. [Security Architecture](#security-architecture)
2. [Enrollment Flow](#enrollment-flow)
3. [Authentication Flow](#authentication-flow)
4. [Recovery Codes](#recovery-codes)
5. [MFA Policies](#mfa-policies)
6. [Session Elevation](#session-elevation)
7. [API Reference](#api-reference)
8. [Security Considerations](#security-considerations)
9. [Testing](#testing)

---

## Security Architecture

### Cryptographic Foundations

| Component | Algorithm | Standard |
|-----------|-----------|----------|
| TOTP Generation | HMAC-SHA1 | RFC 6238 |
| Secret Encoding | Base32 | RFC 4648 |
| Secret Size | 160 bits (20 bytes) | RFC 4226 recommendation |
| Time Step | 30 seconds | RFC 6238 default |
| Code Digits | 6 | Industry standard |
| Time Window | ±1 step (±30s) | Clock drift tolerance |

### Secret Generation

**CRITICAL SECURITY PROPERTY**: All MFA secrets are generated using cryptographically secure random number generation.

```zig
// src/security/mfa.zig
fn generateRandomSecret(allocator: std.mem.Allocator) ![]u8 {
    const secret = try allocator.alloc(u8, 20);
    crypto.random.bytes(secret);  // Cryptographically secure
    return secret;
}
```

**Security Guarantee**: Each user enrollment generates a unique, unpredictable secret. Secrets are NOT derived from usernames or any other predictable data.

### Recovery Code Generation

**8 single-use recovery codes** are generated per enrollment using cryptographically secure randomness:

```zig
// Configuration
pub const RECOVERY_CODE_COUNT: usize = 8;   // Industry standard: 8-10
pub const RECOVERY_CODE_LENGTH: usize = 8;  // 8 characters per code

// Character set (ambiguous characters removed)
const charset = "ABCDEFGHJKLMNPQRSTUVWXYZ23456789";  // No I, O, 0, 1
```

---

## Enrollment Flow

### Step 1: Generate Enrollment

```zig
const mfa = @import("mfa");

// Enable MFA globally (required)
mfa.enableForTests();  // Or via GEODE_ENABLE_MFA environment variable

// Generate enrollment for user
var enrollment = try mfa.enroll(allocator, "username@example.com");
defer mfa.freeEnrollment(allocator, &enrollment);
```

The `Enrollment` struct contains:

| Field | Type | Description |
|-------|------|-------------|
| `secret_base32` | `[]u8` | Base32-encoded secret for provisioning |
| `secret_raw` | `[]u8` | Raw 20-byte secret (internal use) |
| `scratch_codes` | `[][]u8` | 8 single-use recovery codes |
| `provisioning_uri` | `[]u8` | `otpauth://` URI for QR codes |

### Step 2: Display Provisioning URI

The provisioning URI can be converted to a QR code for authenticator app scanning:

```
otpauth://totp/Geode:username%40example.com?secret=JBSWY3DPEHPK3PXP...&issuer=Geode&algorithm=SHA1&digits=6&period=30
```

**URI Components**:

- `otpauth://totp/` - Protocol and type
- `Geode:username` - Issuer and account (URL-encoded)
- `secret=...` - Base32-encoded secret
- `issuer=Geode` - Application name
- `algorithm=SHA1` - HMAC algorithm
- `digits=6` - Code length
- `period=30` - Time step in seconds

### Step 3: Verify First Code (REQUIRED)

**CRITICAL SECURITY REQUIREMENT**: The user MUST provide a valid TOTP code before MFA is enabled. This prevents "fake MFA" where MFA is enabled without the user having a working authenticator.

```zig
// User enters code from their authenticator app
const user_code: u32 = 123456;

// Verify the code is correct
const is_valid = try mfa.verifyEnrollment(allocator, enrollment.secret_base32, user_code);
if (!is_valid) {
    return error.InvalidCode;  // Do NOT enable MFA
}
```

### Step 4: Enable MFA in SecurityManager

```zig
// Only after code verification succeeds
try security_manager.enableUserMfa(
    user_id,
    enrollment.secret_base32,
    user_code,  // The verified code
    enrollment.scratch_codes,
);
```

### Step 5: Store Recovery Codes Securely

Display recovery codes to the user **once** and instruct them to store securely:

```
Your recovery codes (save these in a secure location):
1. ABCD1234
2. EFGH5678
3. IJKL9012
4. MNOP3456
5. QRST7890
6. UVWX1234
7. YZAB5678
8. CDEF9012

WARNING: Each code can only be used once.
         Store these codes securely - they cannot be recovered.
```

---

## Authentication Flow

### Standard Authentication (No MFA Required)

```zig
const token = try security_manager.authenticate("username", "password");
// Success - session token returned
```

### Authentication with MFA Policy Active

When an MFA policy requires MFA for the user:

```zig
// Step 1: Initial authentication
const result = security_manager.authenticate("username", "password");
// Returns error.MFARequired if MFA is needed

// Step 2: Complete with TOTP code
const token = try security_manager.authenticateWithMFA(
    "username",
    "password",
    totp_code,    // 6-digit code from authenticator
    null,         // No recovery code
);
```

### Authentication with Recovery Code

If the user has lost access to their authenticator:

```zig
const token = try security_manager.authenticateWithMFA(
    "username",
    "password",
    0,                // Code = 0 signals recovery code use
    "ABCD1234",       // Recovery code
);
// Recovery code is consumed (single-use)
```

---

## Recovery Codes

### Properties

| Property | Value | Rationale |
|----------|-------|-----------|
| Count | 8 | Industry standard (8-10) |
| Length | 8 characters | Balance of security and usability |
| Character Set | A-Z (no I, O), 2-9 (no 0, 1) | Avoid ambiguous characters |
| Usage | Single-use | Prevent replay attacks |
| Generation | Cryptographically random | Unpredictable |

### Single-Use Enforcement

Recovery codes are removed immediately upon use:

```zig
// In authenticateWithMFA:
if (std.mem.eql(u8, codes.items[idx], recovery_code)) {
    _ = codes.orderedRemove(idx);  // Remove before verification completes
    try self.audit_log.logMfaRecoveryCodeUsed(user_id);
    used_recovery = true;
}
```

### Checking Remaining Codes

```zig
const remaining = try security_manager.getRecoveryCodeCount(user_id);
if (remaining < 3) {
    // Warn user to generate new recovery codes
}
```

---

## MFA Policies

### Policy Types

| Condition | Description | Use Case |
|-----------|-------------|----------|
| `.always` | MFA required for all users | High-security environments |
| `.match_any_role` | MFA for users with any listed role | Admin protection |
| `.match_all_roles` | MFA for users with ALL listed roles | Privileged access |
| `.user_attribute_equals` | MFA based on user attribute | Conditional access |
| `.time_window` | MFA only during specific hours | Business hours policy |
| `.risk_score_min` | MFA when risk score exceeds threshold | Risk-based auth |
| `.reauth_interval_elapsed` | Re-MFA after time since last MFA | Session refresh |

### Adding a Policy

```zig
// Require MFA for all admin users
try security_manager.addMfaPolicy(.{
    .id = 1,
    .enabled = true,
    .condition = .match_any_role,
    .roles = &[_]auth.RoleId{ admin_role_id },
});

// Require MFA for everyone
try security_manager.addMfaPolicy(.{
    .id = 2,
    .enabled = true,
    .condition = .always,
});

// Time-based MFA (business hours only)
try security_manager.addMfaPolicy(.{
    .id = 3,
    .enabled = true,
    .condition = .time_window,
    .time_start_minute = 9 * 60,   // 09:00 UTC
    .time_end_minute = 17 * 60,    // 17:00 UTC
});
```

### Deleting a Policy

**IMPORTANT**: Policy deletion clears the evaluation cache to ensure immediate effect.

```zig
try security_manager.deleteMfaPolicy(policy_id);
// Cache is automatically cleared
```

### Policy Evaluation

```zig
const requires_mfa = security_manager.evaluateMfaPolicies(user);
// Or with session context for dynamic policies:
const requires_mfa = security_manager.evaluateMfaPoliciesAdvanced(user, session, now_ms);
```

---

## Session Elevation

### Concept

After successful MFA, the session is "elevated" for a limited time. Sensitive operations can require elevation.

### Marking Elevation

```zig
// After successful MFA authentication
try security_manager.markStepUp(session_token, 5 * 60 * 1000);  // 5 minutes
```

### Checking Elevation Requirement

```zig
if (security_manager.requireStepUp(session_token, "admin_delete_user")) {
    // Require fresh MFA before proceeding
    return error.StepUpRequired;
}
```

### Elevation TTL

Default: 5 minutes (`elevation_ttl_ms = 5 * 60 * 1000`)

Configurable per SecurityManager instance:

```zig
security_manager.elevation_ttl_ms = 15 * 60 * 1000;  // 15 minutes
```

---

## API Reference

### mfa.zig Functions

#### `enroll(allocator, username) !Enrollment`

Generates a new MFA enrollment with cryptographically random secret and recovery codes.

**Parameters**:

- `allocator`: Memory allocator
- `username`: User identifier (used in provisioning URI)

**Returns**: `Enrollment` struct

**Errors**:

- `error.FeatureDisabled`: MFA not enabled globally

---

#### `verifyEnrollment(allocator, secret_base32, code) !bool`

Verifies a TOTP code against a secret. Use before enabling MFA.

**Parameters**:

- `allocator`: Memory allocator
- `secret_base32`: Base32-encoded secret
- `code`: 6-digit TOTP code

**Returns**: `true` if valid, `false` if invalid

---

#### `verifyCode(allocator, secret_base32, timestamp_ms, code, step, digits, window) !bool`

Full TOTP verification with configurable parameters.

**Parameters**:

- `timestamp_ms`: Current time in milliseconds
- `step`: Time step in seconds (usually 30)
- `digits`: Number of digits (usually 6)
- `window`: ±steps to accept (usually 1)

---

#### `generateCodeFromBase32(allocator, secret_base32, timestamp_ms, step, digits) !u32`

Generates a TOTP code. Useful for testing.

---

`verifyRecoveryCode` was removed (SONNY-6602): it matched 8-character
codes only, the issued codes are 32 characters, and it had no caller.
Recovery codes are redeemed by `SecurityManager.authenticateWithMFA` alone.

---

#### `freeEnrollment(allocator, enrollment)`

Frees all memory associated with an enrollment.

---

### SecurityManager Functions

#### `enableUserMfa(user_id, secret_base32, totp_code, recovery_codes) !void`

Enables MFA for a user after verifying their TOTP code.

**CRITICAL**: Validates the TOTP code before enabling. Rejects if code is invalid.

---

#### `disableUserMfa(user_id) !void`

Disables MFA for a user, clearing secret and recovery codes.

---

#### `getRecoveryCodeCount(user_id) !usize`

Returns the number of remaining recovery codes.

---

#### `addMfaPolicy(policy) !void`

Adds an MFA policy. Clears evaluation cache.

---

#### `deleteMfaPolicy(policy_id) !void`

Removes an MFA policy. Clears evaluation cache.

---

#### `evaluateMfaPolicies(user) bool`

Checks if any policy requires MFA for the user.

---

#### `evaluateMfaPoliciesAdvanced(user, session, now_ms) bool`

Full policy evaluation with session context for dynamic conditions.

---

#### `requireStepUp(token, action) bool`

Checks if an action requires fresh MFA elevation.

---

#### `markStepUp(token, lifetime_ms) !void`

Marks a session as elevated after successful MFA.

---

## Security Considerations

### Threat Mitigations

| Threat | Mitigation |
|--------|------------|
| Secret enumeration | Cryptographically random secrets (not derived from username) |
| Recovery code enumeration | Cryptographically random codes |
| Timing attacks | Constant-time comparison for all secret comparisons |
| Replay attacks | Single-use recovery codes, time-based TOTP |
| Fake MFA enablement | TOTP verification required before enabling |
| Stale policy cache | Cache cleared on policy add/delete |
| Clock drift | ±30 second window tolerance |

### Audit Logging

All MFA events are logged:

| Event | Description |
|-------|-------------|
| `mfa_challenge_issued` | MFA required for authentication |
| `mfa_challenge_success` | TOTP code verified successfully |
| `mfa_challenge_failure` | Invalid TOTP or recovery code |
| `mfa_recovery_code_used` | Recovery code consumed |
| `user_updated` (MFA enabled) | MFA enabled for user |
| `user_updated` (MFA disabled) | MFA disabled for user |
| `policy_created` | MFA policy added |
| `policy_deleted` | MFA policy removed |

### Best Practices

1. **Always verify enrollment**: Never enable MFA without validating a TOTP code first
2. **Display recovery codes once**: Show to user during enrollment, don't store retrievably
3. **Monitor recovery code usage**: Alert when codes are used, warn when few remain
4. **Use role-based policies**: Require MFA for admin/privileged roles at minimum
5. **Implement re-auth**: Use `reauth_interval_elapsed` for long sessions
6. **Audit all MFA events**: Review logs for suspicious patterns

---

## Testing

### Unit Tests

**Location**: `src/security/mfa.zig` (inline tests)

```bash
zig test src/security/mfa.zig
# All 24 tests passed
```

**Coverage**:

- Secret randomness verification
- Recovery code generation and uniqueness
- Provisioning URI format
- TOTP algorithm correctness
- Base32 encoding/decoding
- Constant-time comparison
- Enrollment validation

### Integration Tests

**Location**: `tests/test_mfa_enforcement_comprehensive.zig`

```bash
zig build test
# All tests passed (exit code 0)
```

### End-to-End Tests (Geodetestlab)

**Location**: `geodetestlab/specs/mfa_comprehensive_security.yml`

```bash
python3 scripts/test/extended_test_runner.py mfa_comprehensive_security
```

**Coverage (16 test sections, 60+ test cases)**:

1. MFA Enrollment - Basic Workflows
2. MFA Enrollment - Validation Required
3. MFA Admin Operations
4. MFA Policy Enforcement
5. Recovery Codes
6. Edge Cases - Nonexistent Users
7. Edge Cases - Invalid Codes
8. Edge Cases - Disabled MFA
9. Edge Cases - Double Enable
10. Security - Bypass Prevention
11. Security - Brute Force Protection
12. Audit Logging
13. Special Characters in Username
14. Concurrent Access
15. Session Integration
16. Help and Documentation

**Coverage**:

- Full enrollment flow
- Policy enforcement (all types)
- Authentication with MFA
- Recovery code authentication
- Session elevation
- No-bypass verification

### CANARY Markers

| Marker | Feature |
|--------|---------|
| `REQ-MFA-ENROLL-001` | Enrollment structure |
| `REQ-MFA-ENROLL-002` | Secure enrollment |
| `REQ-MFA-ENROLL-003` | Enrollment validation |
| `REQ-MFA-SECRET-001` | Cryptographic random secrets |
| `REQ-MFA-RECOVERY-001` | Recovery code count |
| `REQ-MFA-RECOVERY-002` | Cryptographic random recovery codes |
| `REQ-MFA-RECOVERY-003` | Recovery code verification |
| `REQ-MFA-PROVISION-001` | Provisioning URI generation |
| `REQ-MFA-ENABLE-001` | Validated MFA enablement |
| `REQ-MFA-DISABLE-001` | MFA disablement |
| `REQ-MFA-POLICY-DELETE-001` | Policy deletion with cache clear |
| `REQ-MFA-TEST-COMPREHENSIVE` | Comprehensive test suite |

---

## Changelog

### January 29, 2026 - Security Audit Fixes

**Critical Fixes**:

1. **MFA enrollment validation** - TOTP code must be verified before enabling MFA
2. **Cryptographically random secrets** - No longer derived from username
3. **8 recovery codes** - Increased from 2 to industry standard 8
4. **Cryptographically random recovery codes** - No longer deterministic
5. **Provisioning URI generation** - Added for QR code support
6. **Policy deletion cache clearing** - Prevents stale policy evaluation

**New Functions**:

- `mfa.verifyEnrollment()`
- `mfa.generateProvisioningUri()`
- `SecurityManager.enableUserMfa()`
- `SecurityManager.disableUserMfa()`
- `SecurityManager.deleteMfaPolicy()`
- `SecurityManager.getRecoveryCodeCount()`

**Test Coverage**:

- 24 inline unit tests in `mfa.zig`
- 31 comprehensive integration tests

---

## References

- [RFC 6238 - TOTP: Time-Based One-Time Password Algorithm](https://tools.ietf.org/html/rfc6238)
- [RFC 4226 - HOTP: An HMAC-Based One-Time Password Algorithm](https://tools.ietf.org/html/rfc4226)
- [RFC 4648 - Base Encodings](https://tools.ietf.org/html/rfc4648)
- [OWASP Multi-Factor Authentication Cheat Sheet](https://cheatsheetseries.owasp.org/cheatsheets/Multifactor_Authentication_Cheat_Sheet.html)

---

*Copyright 2024-2026 CodePros. Licensed under Apache License 2.0.*
