<!-- CANARY: FLE_DESIGN - Field-Level Encryption Design Document -->
<!-- CANARY: FLE_AEAD - AEAD Encryption (AES-256-GCM, ChaCha20-Poly1305) -->
<!-- CANARY: FLE_KEY_HIERARCHY - TRK → SK → FEK → BIK Key Hierarchy -->
<!-- CANARY: FLE_ROTATION - Online Key Rotation (Rewrap & Re-encrypt) -->
<!-- CANARY: FLE_BLIND_INDEX - Blind Index Equality Search -->
<!-- CANARY: FLE_GQL_EXTENSIONS - Geode GQL Schema Annotations -->
<!-- CANARY: FLE_RBAC - Field-Level RBAC/ABAC Enforcement -->

# Geode Field-Level Encryption & Key Management — Design Report (Markdown)

> **Scope:** Native, application-level, **field-level encryption** for Geode that is transparent to authorized users, queryable (equality), rotatable at scale, tenant-aware, RBAC/ABAC-governed, and implemented in **Zig 0.15.1** using **`std.crypto`** only.
> **Standards:** ISO/IEC 39075 (GQL) baseline with **clearly marked Geode-only extensions**.

---

## 1) Architecture & Hook Points

### 1.1 Storage & Execution Flow (where to hook)

* **Encrypt-on-write:** Intercept property writes before persistence. If the field is marked `@encrypted`, encrypt plaintext → ciphertext (AEAD), compute optional blind index, store ciphertext (and index entry).
* **Decrypt-on-read:** At projection time, if the caller has `READ_PLAINTEXT(field)` (RBAC/ABAC), decrypt and return plaintext; otherwise return ciphertext or a redacted token.
* **Predicate rewrite:** When a query filters on an encrypted field, the planner rewrites the literal to either:

  * **Blind index token** (preferred) for equality search; or
  * **Encrypted constant** (not recommended; disabled by default except admin/debug).
* **Key resolution:** Executor consults a **KeyManager** cache to fetch appropriate FEK by `(tenant, schema, field, key_version)` and performs AEAD with **AAD** binding context `(tenant_id, schema_id, field_id, record_id, key_version)`.

### 1.2 Tenancy

* Every encryption operation is scoped by **tenant**. Per-tenant key hierarchies; **no key reuse across tenants**.
* AAD **always** includes `tenant_id` to cryptographically bind ciphertext to a tenant.

---

## 2) GQL (Geode-only) Extensions

> These are **non-standard** and documented separately from ISO GQL.

### 2.1 DDL Annotations

```gql
-- Geode extensions (non-standard)
CREATE NODE TYPE Person (
  id UUID PRIMARY KEY,
  name STRING,
  ssn STRING 
    @encrypted(alg:"AES-256-GCM", key_scope:"field", rotate:"90d")
    @classify(tags:["PII","Restricted"])
    @visible(to_roles:["pii_reader"]),
  email STRING 
    @encrypted(alg:"CHACHA20-POLY1305", key_scope:"field")
    @searchable(index:"blind-hmac-sha256")
);
```

* `@encrypted`: alg ∈ {`AES-256-GCM`, `CHACHA20-POLY1305`}, key scope, rotation hint.
* `@classify`: sensitivity tags (e.g., PII).
* `@visible`: roles permitted to see plaintext.
* `@searchable(index:"blind-hmac-sha256")`: enables equality search via blind index.

### 2.2 Query Helpers

* `PLAINTEXT(x)`, `CIPHERTEXT(x)` – force projection form (subject to policy).
* **Admin verbs:**

  * `ALTER KEYSET TENANT t SCHEMA s FIELD f ROTATE;`
  * `SHOW KEYSET TENANT t;`
  * `SHOW CLASSIFICATION FOR s;`

---

## 3) Key Hierarchy & Lifecycle

```
Tenant Root Key (TRK) [KEK]
 └─ Schema Key (SK) [KEK], per (tenant, schema)
     └─ Field Encryption Key (FEK) [DEK], per (tenant, schema, field, version)
         └─ Blind Index Key (BIK), per searchable field
```

* **Separation of usage:** TRK/SK wrap only; FEK encrypts data; BIK computes HMAC blind index.
* **Derivation:** Prefer **HKDF-SHA256** with context info (e.g., `"geode/trk"`, `"geode/sk/Schema"`, `"geode/fek/Schema.Field"`, `"geode/bi/Schema.Field"`). Use random FEKs for independent rotation.
* **Versioning:** Every key has a version. FEK rotations create vN+1; reads remain backward-compatible until migration completes.
* **Storage:** Keys stored as wrapped blobs + metadata (id, version, created_at, rotated_at, provenance). TRK may live in external KMS.

**Envelope format (stored per field value):**

```
struct EncryptedFieldV1 {
  alg_id: u8,
  key_version: u16,
  nonce: [12]u8,
  tag: [16]u8,
  ciphertext: []u8,
  // AAD is implicit: (tenant_id, schema_id, field_id, record_id, key_version)
}
```

---

## 4) Algorithms & Nonce Policy

* **AEADs (strong-only):**

  * **AES-256-GCM** — default on AES-NI/ARM CE platforms (NIST SP 800-38D).
  * **ChaCha20-Poly1305** — default on non-AES-NI platforms; constant-time.
* **Zig 0.15.1:** Use `std.crypto.aead` only; **no custom crypto**.
* **Nonce:** 96-bit unique per `(key, record, write)`; generate via CSPRNG; optionally derive with HKDF from `(FEK, record_id, counter)`. Consider XChaCha20-Poly1305 (192-bit nonce) if needed.
* **Limits:** Track per-key usage; rotate well before AEAD usage bounds.
* **AAD:** Always bind `{tenant, schema, field, record, key_version}` to prevent context swapping.

---

## 5) Querying Encrypted Data (Equality Search)

**Blind Index (HMAC):**

* On write:

  1. `ciphertext = AEAD_Enc(FEK, plaintext, AAD)`
  2. `bi = HMAC(BIK, normalize(plaintext))` (optional truncation)
  3. Store `ciphertext`, index `bi → record_id`.

* On filter (planner rewrite):

  * `WHERE p.email = "alice@example.com"`
  * → compute `q_bi = HMAC(BIK, normalize("alice@example.com"))`
  * → use BI index to fetch candidates.

**Leakage & mitigations:**

* Reveals equality/frequency (same as deterministic enc). Mitigate by:

  * Only enabling blind index where necessary.
  * Rotating BIKs (requires rebuild) if risk profile changes.
  * Normalization carefully defined per type.

**Unsupported (out of scope):** substring/range/prefix search on encrypted fields.

---

## 6) Rotation Mechanics

* **Rewrap (TRK/SK):** Re-encrypt child keys only; **no data rewrite**. Fast, online.
* **Re-encrypt (FEK):**

  * Create FEK vN+1; new writes use vN+1.
  * Background job: decrypt(vN) → encrypt(vN+1) per record (batched, resumable).
  * Reads of vN remain supported (KeyManager caches old FEKs) until complete.
  * Opportunistic re-encrypt on read is allowed.

**Admin UX:**

* `ALTER KEYSET … ROTATE [TRK|SK|FEK]`
* `SHOW ROTATION STATUS` (percent complete, ETA)

---

## 7) RBAC/ABAC Enforcement

**Permissions:**

* `READ_PLAINTEXT(field)` — view decrypted value.
* `READ_CIPHERTEXT(field)` — view only ciphertext (default if node readable).
* `WRITE(field)` — set value (engine encrypts automatically).

**Rules:**

* **Projection:** If caller lacks `READ_PLAINTEXT`, output ciphertext or redacted token.
* **Filters:** By default, **disallow** plaintext-literal predicates on encrypted fields unless caller has `READ_PLAINTEXT(field)` (closes guess-oracle).
* **ABAC (minimal):** Optional conditions (e.g., owner-only) via policy hooks; deny-by-default.

**Grants (CLI examples):**

```
GRANT READ_PLAINTEXT ON Person.ssn TO ROLE pii_reader;
REVOKE READ_PLAINTEXT ON Person.ssn FROM ROLE analyst;
```

---

## 8) Threat Model & Mitigations (STRIDE snapshot)

* **At-rest compromise:** Without keys, field data remains confidential (AEAD). TRK in KMS or isolated store.
* **Tampering:** AEAD tag + AAD prevents undetected modification or context swap.
* **Access pattern leakage:** Blind index leaks equality/frequency; document risks; restrict usage; audit queries.
* **Logging leakage:** Never log plaintext/keys. Audit by key IDs, counts, denials.
* **Nonce misuse:** Central nonce policy; counters/alerts; consider XChaCha on platforms without robust RNG.
* **Oracle/guessing:** Disallow searches on encrypted fields for roles lacking `READ_PLAINTEXT(field)`.
* **DoS:** Batch/limit rotations; size limits on properties; admin-only rotation.

---

## 9) Migration (Plaintext → Encrypted)

1. **ALTER schema** to add `@encrypted` (policy enforced immediately).
2. **New writes**: encrypted from that point.
3. **Backfill job**: iterate records, encrypt field, write ciphertext (+ BI).
4. **Access during migration:**

   * Authorized roles: still see values (plaintext or decrypted).
   * Unauthorized roles: treated as protected (null/redacted) even if still plaintext in store.
5. **Resumable** and **verifiable**; finalize by ensuring no version-0 values remain.

---

## 10) Operational Story (Admin/CLI/Observability)

**CLI commands (sketch):**

```
geode key list --tenant T
geode key rotate --tenant T --scope [trk|schema|field] --schema S --field F
geode migrate encrypt --field Person.ssn --batch 1000
geode policy grant plaintext Person.ssn --role pii_reader
geode policy revoke plaintext Person.ssn --role analyst
```

**Metrics & audit:**

* Decrypt ops/sec, key cache hit rate, rotation progress.
* Audit events: key create/rotate, decrypt allow/deny (aggregated), BI search usage.

**Backups:**

* Include wrapped keys and metadata; TRK handled via KMS or secure secret store backup.

---

## 11) GeodeTestLab Specs to Add

Place under `geodetestlab/specs/`:

* `encryption_basic.yml`

  * Create encrypted fields; insert data; query as authorized vs unauthorized; verify projection behavior.
* `encryption_blind_index.yml`

  * Mark field `@searchable`; verify equality predicate uses BI and returns correct rows; check non-searchable field raises error on predicate.
* `encryption_rotation.yml`

  * Insert data under FEK v1; rotate to v2; ensure reads succeed; verify ciphertext/version change post-migration.
* `encryption_migration.yml`

  * Start plaintext field; `ALTER` to `@encrypted`; run migration; verify transitional behavior and completion.
* `encryption_rbac.yml`

  * Test `GRANT/REVOKE` of `READ_PLAINTEXT(field)`; ensure filters require permission.

Each spec should include: setup, commands, expected results (including role contexts).

---

## 12) Implementation Sketch (Zig 0.15.1)

### 12.1 Modules & Types

```
/crypto/aead.zig           // thin wrappers over std.crypto.aead (AES-GCM, ChaCha20-Poly1305)
 /crypto/hkdf.zig          // HKDF helpers
 /crypto/hmac.zig          // HMAC-SHA256 for blind index

/keys/manager.zig          // KeyManager: cache, unwrap, rotation APIs
/keys/types.zig            // KeyId, KeyVersion, KeySet, Provenance

/schema/annotations.zig    // parse @encrypted/@classify/@visible/@searchable
/planner/rewrite.zig       // predicate/literal rewrites (BI tokens)
/exec/projection.zig       // decrypt-on-output with RBAC/ABAC
/index/blind_index.zig     // BI storage & lookup

/audit/log.zig             // audit events (key ops, decrypt, deny)
/admin/cli_*.zig           // key list/rotate, migrate, grants
```

### 12.2 Zig AEAD helper (example)

```zig
const std = @import("std");

pub const Alg = enum { aes256_gcm, chacha20_poly1305 };

pub fn encrypt(
    allocator: std.mem.Allocator,
    alg: Alg,
    key: []const u8,          // 32 bytes
    nonce: []const u8,        // 12 bytes
    aad: []const u8,
    plaintext: []const u8,
) ![]u8 {
    var out = try allocator.alloc(u8, plaintext.len);
    switch (alg) {
        .aes256_gcm => {
            const G = std.crypto.aead.aes_gcm.Aes256Gcm;
            var tag: [G.tag_length]u8 = undefined;
            try G.encrypt(out, &tag, plaintext, aad, nonce, key);
            return try std.mem.concat(allocator, u8, &.{ out, tag[0..] });
        },
        .chacha20_poly1305 => {
            const C = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
            var tag: [C.tag_length]u8 = undefined;
            try C.encrypt(out, &tag, plaintext, aad, nonce, key);
            return try std.mem.concat(allocator, u8, &.{ out, tag[0..] });
        },
    }
}

pub fn decrypt(
    alg: Alg,
    key: []const u8,
    nonce: []const u8,
    aad: []const u8,
    in_with_tag: []const u8,
    out: []u8,
) !void {
    switch (alg) {
        .aes256_gcm => {
            const G = std.crypto.aead.aes_gcm.Aes256Gcm;
            const tag_len = G.tag_length;
            try G.decrypt(out, in_with_tag[0..(in_with_tag.len - tag_len)], aad,
                          in_with_tag[(in_with_tag.len - tag_len)..], nonce, key);
        },
        .chacha20_poly1305 => {
            const C = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
            const tag_len = C.tag_length;
            try C.decrypt(out, in_with_tag[0..(in_with_tag.len - tag_len)], aad,
                          in_with_tag[(in_with_tag.len - tag_len)..], nonce, key);
        },
    }
}
```

### 12.3 Blind index (HMAC) helper (example)

```zig
const std = @import("std");

pub fn blindIndexHmac256(out: *[32]u8, bik: []const u8, normalized: []const u8) void {
    var mac = std.crypto.auth.hmac.sha2.HmacSha256.init(bik);
    mac.update(normalized);
    mac.final(out);
}
```

---

## 13) Acceptance Criteria

* **Correctness:** AEAD decrypt verifies tag & AAD; fails closed. No plaintext in logs.
* **Transparency:** Authorized users see plaintext automatically; unauthorized see ciphertext/redacted.
* **Rotation:** Rewrap and re-encrypt flows are online, consistent, and observable via status.
* **Search:** Equality predicates on `@searchable` fields work via blind index.
* **Performance:** Overheads bounded and documented; AEAD usage limits enforced.
* **Docs:** Clear ISO vs Geode extension separation with examples and error messages.

---

## 14) References (for the researcher/implementor)

* ISO/IEC 39075:2024 — **GQL** (property graph).
* Zig 0.15.1 — **`std.crypto`** docs (AEAD/HKDF/HMAC).
* NIST SP 800-38D (GCM) & SP 800-57 (Key Management).
* RFC 5869 (HKDF), RFC 8452 (AES-GCM-SIV background).
* MongoDB **CSFLE / Queryable Encryption** (blind index & rewrite patterns).
* USENIX Security 2023 — *Security Analysis of MongoDB Queryable Encryption* (leakage).
* Neo4j RBAC docs (privilege granularity).

---

## 15) Next Steps

* Wire up parser support for annotations; plumb metadata to planner/executor.
* Implement `KeyManager` with TRK/SK/FEK load, unwrap, cache, and rotation.
* Add blind index module + simple hash/B-tree index.
* Implement projection & predicate rewrites with RBAC checks.
* Land **GeodeTestLab** specs listed above to lock behavior.
* Prepare admin docs + “view as role” troubleshooting guide.

---

> **Note:** *This Geode is a property graph database and is **unrelated to Apache Geode** (the in-memory data grid).*
