# Field-Level Encryption (FLE) for Geode

<!-- CANARY: FLE_DOCUMENTATION - Field-Level Encryption Design & Implementation -->
<!-- CANARY: REQ=REQ-FLE-DOC-001; FEATURE="FieldLevelEncryption"; ASPECT=DOCUMENTATION; STATUS=TESTED; TEST=geodetestlab/specs/fle_comprehensive_security.yml; OWNER=security; UPDATED=2025-10-15 -->

## Overview

Geode implements **native, application-level field-level encryption** that provides:

- **Transparent encryption/decryption** for authorized users
- **RBAC/ABAC-gated access** to plaintext values
- **Equality search** on encrypted fields via blind indexes
- **Online key rotation** with zero downtime
- **Hierarchical key management** (TRK → SK → FEK/BIK)
- **AEAD encryption** using Zig `std.crypto` (AES-256-GCM, ChaCha20-Poly1305)

This feature is **production-ready** with comprehensive testing (97.4% pass rate) and follows NIST cryptographic standards.

---

## Architecture

### 1. Key Hierarchy

```
Master Key (ENV or KMS)
 └─ TRK (Tenant Root Key) [KEK]
     └─ SK (Schema Key) [KEK], per (tenant, schema)
         ├─ FEK (Field Encryption Key) [DEK], per (tenant, schema, field, version)
         └─ BIK (Blind Index Key) [HMAC key], per searchable field
```

**Derivation:** HKDF-SHA256 with context strings:

- TRK: `"geode/trk/{tenant_id}"`
- SK: `"geode/sk/{schema}"`
- FEK: `"geode/fek/{field}"`
- BIK: `"geode/bi/{field}"`

### 2. AEAD Encryption

**Algorithms:**

- **AES-256-GCM**: Default on AES-NI/ARM-CE hardware (NIST SP 800-38D)
- **ChaCha20-Poly1305**: Fallback for non-AES platforms; constant-time

**Additional Authenticated Data (AAD):**

```
tenant_id␟schema␟field␟record_id␟key_version
```

(␟ = 0x1F separator)

This cryptographically binds ciphertext to its context, preventing cross-record/field attacks.

### 3. Envelope Format (V1)

Binary serialization (little-endian):

```
[alg_id:u8][key_version:u16][nonce:12][tag:16][ciphertext_len:u32][ciphertext]
```

- `alg_id`: 1 = AES-256-GCM, 2 = ChaCha20-Poly1305
- `key_version`: For rotation tracking
- `nonce`: 96-bit unique per (key, record, write)
- `tag`: 128-bit authentication tag
- `ciphertext`: Encrypted field value

### 4. Blind Index for Equality Search

For fields marked `@searchable`, Geode maintains:

```
BI = HMAC-SHA256(BIK, normalize(plaintext))
```

**Normalization:** ASCII lowercase + trim whitespace

**Storage:** Index maps `BI → [record_ids]`

**Query Rewrite:** `WHERE p.email = "alice@example.com"` becomes BI token lookup

**Leakage:** Reveals equality patterns (same plaintext → same BI) and frequency. Document this risk.

---

## GQL Schema Extensions (Geode-Only)

> **Note:** These annotations are **non-standard** ISO GQL extensions, clearly marked as Geode-specific.

### DDL Annotations

```gql
CREATE NODE TYPE Person (
  id UUID PRIMARY KEY,
  name STRING,
  ssn STRING
    @encrypted(alg:"AES-256-GCM", key_scope:"field", rotate:"90d")
    @classify(tags:["PII","Restricted"])
    @visible(to_roles:["pii_reader"]),
  email STRING
    @encrypted(alg:"CHACHA20-POLY1305")
    @searchable(index:"blind-hmac-sha256")
);
```

**Annotations:**

- `@encrypted(alg, key_scope, rotate)`: Enable encryption
  - `alg`: "AES-256-GCM" or "CHACHA20-POLY1305"
  - `key_scope`: "field" (per-field FEK) or "schema" (shared SK)
  - `rotate`: Optional rotation interval hint

- `@searchable(index)`: Enable equality search via blind index
  - `index`: "blind-hmac-sha256" (only supported option)

- `@visible(to_roles)`: RBAC gate for plaintext access
  - `to_roles`: List of roles permitted to see plaintext

- `@classify(tags)`: Sensitivity tags for audit/compliance
  - `tags`: e.g., ["PII", "PHI", "Restricted"]

### Query Helpers

```gql
-- Force plaintext projection (requires privilege)
RETURN PLAINTEXT(p.ssn)

-- Force ciphertext projection (always allowed)
RETURN CIPHERTEXT(p.ssn)
```

### Admin Commands

```bash
# Key rotation
geode key rotate --tenant T --schema S --field F --scope [FEK|SK|TRK]
geode show rotation-status --tenant T

# Access control
geode policy grant plaintext S.F --role R
geode policy revoke plaintext S.F --role R

# Migration
geode migrate encrypt --tenant T --field S.F --batch 1000
```

---

## Implementation Details

### Module Structure

```
src/crypto/
  ├── aead.zig           # AEAD wrapper (AES-256-GCM, ChaCha20-Poly1305)
  ├── hkdf.zig           # HKDF-SHA256 key derivation
  └── hmac.zig           # HMAC-SHA256 for blind indexes

src/keys/
  ├── types.zig          # KeyIds, KeyMetadata, RotationStats
  └── manager.zig        # KeyManager with cache and rotation

src/index/
  └── blind_index.zig    # BlindIndex for searchable fields

src/schema/
  └── annotations.zig    # Parse @encrypted/@searchable/@visible/@classify

src/planner/
  └── rewrite.zig        # Predicate rewriting for encrypted fields

src/exec/
  └── projection.zig     # Decrypt-on-projection with RBAC gates
```

### Encrypt-on-Write Hook

**Location:** `src/storage/graph_store.zig:setNodeProperty()` and `setEdgeProperty()`

**Flow:**

1. Check if field is `@encrypted` via schema catalog
2. Get FEK from KeyManager for `(tenant, schema, field, version)`
3. Construct AAD: `tenant␟schema␟field␟record_id␟version`
4. Encrypt: `EnvelopeV1 ← AEAD.encrypt(FEK, plaintext, AAD)`
5. If `@searchable`: compute `BI ← HMAC(BIK, normalize(plaintext))` and update blind index
6. Store envelope bytes (or base64)

### Decrypt-on-Projection Hook

**Location:** `src/execution.zig:writeValue()` for Node/Edge properties

**Flow:**

1. Detect encrypted field via schema catalog
2. If user has `READ_PLAINTEXT(field)` privilege:
   - Parse envelope
   - Get FEK from KeyManager
   - Decrypt: `plaintext ← AEAD.decrypt(FEK, envelope, AAD)`
   - Return plaintext
3. Else: return `"[REDACTED]"` or ciphertext blob

### Predicate Rewrite Hook

**Location:** `src/planner/rewrite.zig` (called before execution)

**Flow:**

1. For `WHERE p.field = "literal"` on encrypted field:
   - If field not `@searchable`: **error SearchNotPermitted**
   - If user lacks `READ_PLAINTEXT(field)`: **error SearchNotPermitted**
   - Else: compute `BI ← HMAC(BIK, normalize("literal"))` and rewrite to BI lookup

---

## Key Rotation

### FEK Re-Encryption (vN → vN+1)

1. **Create vN+1:** `KeyManager.rotateFEK(tenant, schema, field)`
2. **New writes:** Use vN+1
3. **Background migration:**

   ```zig
   for record in all_records:
     pt = decrypt(record.value, FEK_vN, AAD_vN)
     env = encrypt(pt, FEK_vN+1, AAD_vN+1)
     record.value = env
   ```

4. **Mixed-version reads:** KeyManager supports both vN and vN+1 simultaneously
5. **Opportunistic re-encrypt:** On read, if vN detected, re-encrypt to vN+1

### SK/TRK Rewrap (No Data Re-Encryption)

1. **Rewrap child keys:** Decrypt with old parent, re-encrypt with new parent
2. **Update metadata:** Rotate timestamps
3. **No data rewrite:** Actual field values unchanged

---

## RBAC/ABAC Enforcement

### Permissions

- `READ_PLAINTEXT(schema.field)`: View decrypted value
- `READ_CIPHERTEXT(schema.field)`: View ciphertext (always granted if node readable)
- `WRITE(schema.field)`: Set value (engine encrypts automatically)

### Enforcement

**Projection:**

```zig
if (!rbac.canReadPlaintext(user, schema, field)) {
    return "[REDACTED]"; // or ciphertext blob
}
```

**Filters:**

```zig
if (field.encrypted && !field.searchable) {
    return error.SearchNotPermitted;
}
if (field.encrypted && !rbac.canReadPlaintext(user, schema, field)) {
    return error.SearchNotPermitted;
}
```

**CLI Grants:**

```bash
GRANT READ_PLAINTEXT ON Person.ssn TO ROLE pii_reader;
REVOKE READ_PLAINTEXT ON Person.ssn FROM ROLE analyst;
```

---

## Performance

### Targets

- **Encryption:** Encrypt+BI for 2 KiB field ≤ 250 µs (x86-64 AES-NI)
- **Key cache hit:** ≤ 10 µs
- **Overhead:** 5-10% for read-heavy workloads with proper caching

### Optimization

1. **Key caching:** KeyManager maintains LRU cache with hit/miss tracking
2. **Batch operations:** Encrypt/decrypt multiple fields in parallel for graph traversals
3. **Selective encryption:** Only encrypt genuinely sensitive fields
4. **Hardware acceleration:** AES-NI auto-detected and used when available

### Monitoring

```zig
stats = KeyManager.cacheStats();
// { hits: 1234, misses: 56 }
// cache hit rate = 95.7%
```

---

## Security Considerations

### Threat Model

**Protected Against:**

- ✅ At-rest data compromise (without keys)
- ✅ Ciphertext tampering (authenticated encryption)
- ✅ Cross-record/field ciphertext swapping (AAD binding)
- ✅ Plaintext leakage in logs (never logged)
- ✅ Unauthorized plaintext access (RBAC gates)

**Not Protected Against:**

- ❌ Compromise of master/TRK keys
- ❌ Frequency analysis via blind indexes (document risk)
- ❌ Access pattern leakage (timing/volume)
- ❌ Spectre-class CPU vulnerabilities
- ❌ Physical memory attacks (cold boot)

### Mitigations

**Nonce reuse prevention:**

- Random 96-bit nonces via `std.crypto.random`
- Deterministic nonces only in tests

**Secure memory cleanup:**

```zig
defer std.crypto.secureZero(u8, &fek);
defer std.crypto.secureZero(u8, plaintext);
```

**Logging:**

- Never log plaintext or keys
- Audit by key IDs and operation counts
- Redact all sensitive values

**Limits:**

- Max plaintext: 64 KiB (configurable)
- AEAD usage limits enforced (track operations per key)

---

## Testing

### Unit Tests

Located in module files:

- `src/crypto/aead.zig:test` - Round-trip, bad AAD, envelope serialization
- `src/crypto/hmac.zig:test` - RFC 4231 vector (Jefe), normalization
- `src/crypto/hkdf.zig:test` - Key hierarchy derivation
- `src/keys/manager.zig:test` - Cache, rotation, FEK/BIK
- `src/index/blind_index.zig:test` - Put, lookup, remove

Run: `zig build test -Doptimize=ReleaseSafe`

### Integration Tests

GeodeTestLab specs in `geodetestlab/specs/encryption/`:

- `encryption_basic.yml` - Encrypt-on-write, decrypt-on-projection, RBAC
- `encryption_blind_index.yml` - Equality search via BI
- `encryption_rotation.yml` - Online FEK rotation
- `encryption_migration.yml` - Plaintext → encrypted backfill
- `encryption_rbac.yml` - Grant/revoke READ_PLAINTEXT

Run: `python3 extended_test_runner.py`

### Acceptance Criteria

1. **Correctness:** AEAD auth fails closed; AAD binds context
2. **Transparency:** Authorized users see plaintext; unauthorized see redaction
3. **Rotation:** Rewrap/re-encrypt online with progress telemetry
4. **Search:** Equality predicates on @searchable fields work
5. **Performance:** <250 µs encrypt+BI; <10 µs key cache hit

---

## Migration from Plaintext

### Process

1. **ALTER schema** to add `@encrypted` annotation:

   ```gql
   ALTER NODE TYPE Person ALTER PROPERTY ssn
     SET @encrypted(alg:"AES-256-GCM") @classify(tags:["PII"]);
   ```

2. **New writes:** Immediately encrypted

3. **Backfill existing data:**

   ```bash
   geode migrate encrypt --tenant default --field Person.ssn --batch 1000
   ```

   - Iterates records in batches
   - Encrypts plaintext → envelope
   - Resumable on failure

4. **Access during migration:**
   - Authorized users: still see values (plaintext or decrypted)
   - Unauthorized users: redacted even if still plaintext in storage

5. **Verify completion:**
   - Ensure no version-0 values remain
   - All records have EnvelopeV1

---

## Compliance

### Standards

- **NIST SP 800-38D:** GCM mode specification
- **NIST SP 800-57:** Key management lifecycle
- **RFC 5869:** HKDF key derivation
- **ISO/IEC 39075:2024:** GQL baseline (extensions clearly marked)

### Regulatory Alignment

- **GDPR:** Encryption at rest, pseudonymization, right to erasure (key destruction)
- **HIPAA:** PHI encryption, access controls, audit logging
- **PCI-DSS:** Cardholder data encryption, key rotation
- **SOC 2:** Confidentiality controls, security monitoring

---

## Future Work

### Planned Enhancements

1. **Post-Quantum Cryptography (PQC):**
   - Kyber for key wrapping
   - Dilithium for signatures
   - See `specs/security/field-level-enc-research-report-pqc-PR.md`

2. **External KMS Integration:**
   - AWS KMS, Azure Key Vault, GCP KMS
   - HSM support for TRK storage

3. **Advanced Searchable Encryption:**
   - Range queries (experimental)
   - Substring search (limited)
   - Order-preserving encryption (evaluate risks)

4. **Performance Improvements:**
   - SIMD acceleration for batch operations
   - GPU offload for high-volume encryption
   - Streaming encryption for large fields

### Research Areas

- Homomorphic encryption for computation on encrypted data
- Zero-knowledge proofs for search without decryption
- Secure multi-party computation for tenant isolation

---

## References

- [FLE Research Prompt](../specs/security/field-level-enc-research-PR.md)
- [FLE Design Report](../specs/security/field-level-enc-research-report.md)
- [FLE Implementation Spec](../specs/security/field-level-enc-research-report-code-PR.md)
- [FLE Geode Integration](../specs/security/field-level-enc-research-report-pqc-PR.md)
- [FLE Commit Plan](../specs/security/field-level-enc-research-report-pqc-commit-by-commit.md)
- [Zig std.crypto Documentation](https://ziglang.org/documentation/0.15.1/std/#std.crypto)

---

**Last Updated:** January 2026
**Status:** IMPLEMENTED - Core components complete
**Test Coverage:** 97.4% (geodetestlab - 1644/1688 tests)
**Security Review:** Pending external audit
