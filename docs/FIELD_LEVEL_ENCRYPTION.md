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

## Managing FLE Schema via `CALL geode.fle.*` (Supported, Stable Surface — GAP-0845)

<!-- CANARY: REQ=REQ-GAP-0845-FLE-CALL-DOC-001; FEATURE="FLECallProcedureSurface"; ASPECT=DOCUMENTATION; STATUS=TESTED; TEST=geode-test-harness/geodetestlab-cli/specs/fle_decrypt_denied_placeholder.yml; OWNER=security; UPDATED=2026-06-08 -->

> **The `CALL geode.fle.*` procedures are the supported, stable path for FLE
> schema management.** First-class GQL FLE DDL (declaring `@encrypted` /
> `@visible` / `@searchable` directly in `CREATE` / `ALTER` statements) is a
> **future enhancement** and is **not** currently available — see
> [`docs/GQL_AUTH_DDL.md`](GQL_AUTH_DDL.md) ("FLE DDL … not part of this
> surface"). Until that lands, configure encrypted fields **only** through the
> `CALL` procedures documented here. Downstream consumers (e.g. CaaST) should
> depend on this surface, not on annotation DDL.

These procedures use ISO/IEC 39075:2024 `CALL`-procedure form (the same shape as
`CALL geode.fts.search` / `CALL geode.ts.*`); they ride the generic GQL rows
wire protocol, so there is no client or proto change. Procedure names are
case-insensitive (normalized to lowercase per RQ-0022).
Implementation: [`src/execution/storage_dispatch.zig`](../src/execution/storage_dispatch.zig)
(`fle_table`); access policy: [`src/execution/procedure_access.zig`](../src/execution/procedure_access.zig).

### Administrative surface (GAP-0853)

**The `CALL geode.fle.*` procedures ARE the supported administrative surface for
FLE policy/catalog configuration. There is no GQL FLE DDL, and none is planned.**

Rationale: standard GQL (ISO/IEC 39075:2024) defines no FLE DDL, so any DDL form
would be a non-standard Geode extension to the grammar. Keeping FLE
administration on `CALL` procedures keeps the surface **versionable and additive**
(new keys/procedures can ship without grammar changes), routes every call —
read AND write — through the single GPS procedure gate (see authz below), and
matches the established admin surface for other subsystems
(`CALL geode.tenant.*`, `CALL geode.fts.*`, `CALL geode.ts.*`).

#### Authorization (who may call)

Every `CALL geode.fle.*` invocation passes through the mandatory GPS dispatch
gate (`procedure_registry.executeProcedure`, `REQ-GPS-PROC-001`) **before** the
procedure body runs. The gate classifies each procedure as read-only or mutating
([`src/execution/procedure_access.zig`](../src/execution/procedure_access.zig)
`classifyProcedureName`) and remaps that to a GPS action; a principal is denied
(`error.Unauthorized`) unless its role/policy permits that action on the
procedure resource (fail-closed for unknown principals/procedures):

| Procedure | Classification | GPS action | Who may call |
|-----------|----------------|------------|--------------|
| `geode.fle.configureField` | mutating | `.write` | Admin role, or a role/policy explicitly granted `write` on the procedure. This is the declare/mutate path. |
| `geode.fle.getFieldConfig` | read-only | `.read` | Any role/policy with `read` on the procedure (read-only classification). |
| `geode.fle.listEncryptedFields` | read-only | `.read` | Any role/policy with `read` on the procedure (read-only classification). |

`configureField` declares **which** fields are encrypted; it does **not** grant
decryption. Reading decrypted plaintext is a separate, per-field authorization
(the `visibility` roles set on the field plus the `decrypt_field` /
`READ_PLAINTEXT` privilege) — see [Permissions](#permissions) below.

#### The internal security graph is never FLE-encrypted (GAP-0854)

FLE **never** applies to the internal `__geode_security` graph — the HMAC-chained
store that holds users, roles, policies, and grants. That graph is excluded from
FLE encrypt **and** decrypt at every node site
([`src/graph_store.zig`](../src/graph_store.zig) `isSecurityGraphName`), because
FLE-encrypting an admin record would corrupt the plaintext-computed audit HMAC
chain and trip `AuthChainTampered` on restart. So a `configureField('User', …)`
call cannot accidentally encrypt the security graph's own `User` records; it
configures FLE only for application-graph data. The security graph remains
protected at rest by TDE. See the GAP-0854 closure in
[`docs/GAP_ANALYSIS.md`](GAP_ANALYSIS.md) and regression
`tests/test_gap0854_fle_chain.zig`.

### Procedure reference

#### `CALL geode.fle.configureField(type_name, field_name [, config])`

Configures (creates or updates) a field as FLE-encrypted in the FLE catalog.
This is the write/declare path — the equivalent of an `@encrypted` annotation.

| Argument | Type | Required | Notes |
|----------|------|----------|-------|
| `type_name` | STRING | yes | Node/edge label the field belongs to (e.g. `'Person'`). |
| `field_name` | STRING | yes | Property name to encrypt (e.g. `'ssn'`). |
| `config` | MAP | no | `{ algorithm: <str>, visibility: [<role>, ...] }`. |

`config` keys actually read by the server:

- `algorithm` — `'AES-256-GCM'` (default) or `'CHACHA20-POLY1305'`. Unknown
  values fall back to `AES-256-GCM`.
- `visibility` — list of role names permitted to decrypt the field (e.g.
  `['admin']`). Other keys shown in older examples (`keyVersion`, etc.) are
  accepted/ignored for forward-compatibility.

Returns one row: `status` (STRING, `"configured"`).

```gql
CALL geode.fle.configureField('Person', 'ssn',
  { algorithm: 'AES-256-GCM', visibility: ['pii_reader'] })
RETURN 'configured' AS status;
```

#### `CALL geode.fle.getFieldConfig(type_name, field_name)`

Reads the FLE configuration of a single field.

Returns one row: `encrypted` (BOOL), `algorithm` (STRING, `"none"` when not
encrypted), `searchable` (BOOL).

```gql
CALL geode.fle.getFieldConfig('Person', 'ssn');
-- encrypted | algorithm   | searchable
-- true      | aes256_gcm  | false
```

#### `CALL geode.fle.listEncryptedFields(type_name)`

Lists all encrypted fields configured on a type.

Returns one row per encrypted field: `field_name` (STRING), `algorithm`
(STRING), `searchable` (BOOL).

```gql
CALL geode.fle.listEncryptedFields('Person');
```

### End-to-end example: declare → write → read with/without role

This mirrors the regression harness spec
[`fle_decrypt_denied_placeholder.yml`](../../geode-test-harness/geodetestlab-cli/specs/fle_decrypt_denied_placeholder.yml)
(GAP-0301), which is run in CI.

```gql
-- 1. Declare the encrypted field (admin). Only the 'admin' role may decrypt.
CALL geode.fle.configureField('Person', 'ssn',
  { algorithm: 'AES-256-GCM', visibility: ['admin'] })
RETURN 'configured' AS status;

-- 2. Create a readonly user that is NOT granted decrypt access.
CREATE USER pii_reader SET PASSWORD 'reader-pass-123' ROLE readonly;

-- 3. Write a row (admin). The engine encrypts ssn transparently on write;
--    the plaintext never lands on disk.
CREATE (p:Person { user_id: 'P001', ssn: 'SECRET-123-45-6789', city: 'Denver' })
RETURN p.user_id AS user_id;
```

```bash
# 4a. Admin reads — sees decrypted plaintext (decrypt authorized).
geode query -U geode -P "$GEODE_ADMIN_PASSWORD" \
  "MATCH (p:Person {user_id:'P001'}) RETURN p.ssn AS ssn"
#   ssn
#   SECRET-123-45-6789

# 4b. Readonly user reads — the ROW is visible (row_count matches admin), but
#     the ssn field is REDACTED (e.g. <ENCRYPTED> / null / [REDACTED]).
#     Field visibility != row visibility.
geode query -U pii_reader -P reader-pass-123 \
  "MATCH (p:Person {user_id:'P001'}) RETURN p.ssn AS ssn, p.city AS city"
#   ssn          | city
#   <ENCRYPTED>  | Denver
```

The unauthorized reader gets a redacted placeholder for `ssn` (never raw
ciphertext, never plaintext) while still reading the non-encrypted `city`
field and seeing the same row count as the admin — the decrypt gate is
enforced per field, not per row.

### Future enhancement

First-class FLE DDL (honoring `@encrypted` / `@visible` / `@searchable` on
`CREATE` / `ALTER`) is planned but **not** currently implemented. The `CALL
geode.fle.*` surface above is the stable contract; do not depend on annotation
DDL for encryption configuration.

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
