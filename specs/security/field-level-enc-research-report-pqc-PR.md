<!-- CANARY: FLE_PQC_INTEGRATION - Post-Quantum Cryptography Integration -->
<!-- CANARY: FLE_KYBER - Kyber KEM for Key Wrapping -->
<!-- CANARY: FLE_DILITHIUM - Dilithium Digital Signatures -->
<!-- CANARY: FLE_GEODE_INTEGRATION - Integration with Geode Storage & Execution -->
<!-- CANARY: FLE_ENCRYPT_ON_WRITE - Property Encryption Hook Points -->
<!-- CANARY: FLE_DECRYPT_ON_PROJECTION - Query Result Decryption -->

# Geode — Field-Level Encryption (FLE) & Quantum-Resistant TDE

*(Implementation report for `main` branch — code-level guidance with file/line references)*

> This Geode is a **graph database** and is **unrelated to Apache Geode**.
> Design bases and acceptance criteria come from the attached FLE research/design docs.

---

## 0) Executive summary

* Add **field-level encryption** with **AEAD + AAD** per (tenant, schema, field, record, key_version), **blind-index equality search**, and **RBAC/ABAC gates**. Implement **encrypt-on-write** in `graph_store.zig`, **decrypt-on-projection** in `execution.zig`, and a **KeyManager** with FEK/BIK & rotation. Parser gains **Geode-only annotations** (`@encrypted`, `@searchable`, `@visible`).
* Upgrade TDE’s **key wrapping** to support NIST PQC: **Kyber (KEM) for wrapping**, **Dilithium (sig) for integrity**; bulk data remains AES-GCM. Integrate at **KMS provider wrap/unwrap** layer used by `TDEKeyManager`.

---

## 1) Repository orientation & hook points

### 1.1 Encrypt-on-write (Node/Edge properties)

**File:** `src/graph_store.zig`
**Why here:** All property mutations go through these functions; disk persistence immediately follows.

* **Nodes:** insert **encryption step** inside `GraphStore.setNodeProperty(...)` **before** `saveToFile()`:

  * Lines **20–33** show the write path and persistence trigger; insert after the `value_copy` construction and before `put(...)` or right after, before `saveToFile()`.
* **Edges:** same pattern in `GraphStore.setEdgeProperty(...)`, lines **83–95**.

**Change (sketch):**

1. If schema marks `key` as `@encrypted`, call `KeyManager.getFEK(tenant,schema,key)`; build AAD = `tenant_id 0x1F schema 0x1F key 0x1F node_id 0x1F key_version`.
2. AEAD-encrypt (AES-256-GCM or ChaCha20-Poly1305) → **EnvelopeV1** `{alg_id, key_version, nonce, tag, ciphertext}` (store as bytes or base64).
3. If `@searchable`, compute **BI = HMAC-SHA256(BIK, normalize(plaintext))** and update a **blind-index map**.

> Persistence: the simple file store serializes strings directly; store envelope as **opaque bytes** (binary section) or **base64** in `.String`. The file format already writes value‐length then bytes (nodes at **saveToFile** lines **50–56**), so binary is fine.

### 1.2 Decrypt-on-projection (JSON output)

**File:** `src/execution.zig` → `writeValue` & Node property serialization block.

* `writeValue` handles JSON emission. The `.Str` arm (lines **92–102**) writes raw bytes now.
* Node properties loop writes strings at lines **62–66**; hook here to **detect encrypted fields** and **conditionally decrypt**.

**Change (sketch):**

* If `schema.isEncrypted(field)` then:

  * If `SecurityContext` has `READ_PLAINTEXT(field)`: **parse envelope → KeyManager.decrypt(FEK, AAD)** and write plaintext.
  * Else: emit **ciphertext** (or a policy‐defined `"[REDACTED]"`).
    *Insertion points:* `execution.zig` **properties loop** lines **61–71** for nodes; similarly, any other projection sites.

> RBAC gate aligns with the design’s `READ_PLAINTEXT/READ_CIPHERTEXT` split.

### 1.3 WHERE-predicate rewrite (blind-index)

Geode’s execution currently serializes results and evaluates expressions in `eval`/`execution`. Add a **planner/rewrite** pass after parse to transform:

```
WHERE n.email = "alice@example.com"
→ WHERE n.email_bi = BI(HMAC(BIK_email, normalize("alice@example.com")))
```

Authorized users only; otherwise **reject** to close guess-oracle.

* **Where to wire:** After parse, before `executeQueryWithContext(...)` in `execution.zig` (see flow at **executeStatementWithContext** lines **56–66**).
* **Eval side:** If you choose not to add a separate index now, perform BI token compute on the right side and compare against a stored **bi property** or **in-memory map** maintained by `GraphStore` during writes.

### 1.4 Storage/persistence touch points

* **File I/O:** Node properties are length-prefixed and raw‐written at `saveToFile` (nodes) lines **50–56** and edges area; binary envelopes are safe to write/read as bytes.
* **Load path:** `loadFromFile` reads properties and reconstructs strings at lines **60–73**; preserve envelopes as opaque bytes (not auto-decrypt).

---

## 2) GQL — Geode-only schema extensions

Implement **annotation parsing** for:

```gql
@encrypted(alg:"AES-256-GCM"|"CHACHA20-POLY1305")
@searchable(index:"blind-hmac-sha256")
@visible(to_roles:["roleA","roleB"])
@classify(tags:["PII","Restricted"])
```

**Parser location today:** `src/gql/ast.zig` creates AST; the type definition currently carries raw text (see change-log guidance and TODOs referencing AST/exec integration).
**Action:**

* Add a tiny annotation parser (e.g., `schema/annotations.zig`) to process the **raw type_definition** captured by AST and populate a **SchemaCatalog** with per-field flags (encrypted/searchable/roles).
* Validate and store algorithm choice; default to **AES-256-GCM** on AES-NI/ARM-CE, **ChaCha20-Poly1305** otherwise.

> All extensions are explicitly non-ISO GQL and must be documented as **Geode-only**.

---

## 3) Crypto & envelopes (Zig 0.15.1, `std.crypto`)

* **AEAD:** use `std.crypto.aead.aes_gcm.Aes256Gcm` (see current TDE usage at `tde_kms_integration.zig` **encryptWithKey** lines **60–67** & decrypt lines **74–79**). Add ChaCha20-Poly1305 as fallback per platform policy.
* **AAD binding:** `"tenant␟schema␟field␟record_id␟key_version"` (␟ = 0x1F) as specified in the design.
* **EnvelopeV1:** `{alg_id:u8, key_version:u16, nonce[12], tag[16], ciphertext}` (binary).
* **Limits:** track per-key usage; 96-bit nonces; RNG by default; deterministic test-nonce injection for tests.

---

## 4) Key management & rotation (FLE)

Introduce **`src/keys/manager.zig`**:

* **Hierarchy:** TRK(KEK) → SK(KEK, per schema) → FEK(DEK, per field, version) + BIK (HMAC key).
* **APIs:** `getFEK(ids)`, `getBIK(ids)`, `rotateFEK(schema,field)`, `rewrapTRK()`, `rewrapSK(schema)`.
* **Storage:** start with in-DB wrapped blobs + metadata; TRK may come from env/KMS; integrate later with TDE KMS plumbing.

**Rotation flows:**

* **Rewrap:** rotate TRK/SK without data rewrite (update wrapped child keys).
* **Re-encrypt:** create FEK vN+1; new writes use vN+1; background job re-encrypts old values online; mixed-version reads supported.

**Zeroization:** Use `std.crypto.secureZero` on key/pt buffers; mirror existing TDE hygiene (see `tde_kms_integration.zig` patterns; keys are handled in memory and never logged).

---

## 5) RBAC/ABAC rules

* **Projection:** if caller lacks `READ_PLAINTEXT(field)`, return **ciphertext or redacted**. Apply check in `execution.zig` properties block lines **61–71**.
* **Filters:** plaintext equality on encrypted fields requires **privilege + @searchable**; else **error** (close oracles).
* **Grants:** wire minimal CLI/DDL to grant `READ_PLAINTEXT(s.f)` to roles; default is deny-by-default.

---

## 6) Tests (additions)

1. **AEAD round-trip + bad-AAD fails:** mirror TDE tests style; add FLE tests.
2. **Projection redaction:** unauthorized role sees `"[REDACTED]"`.
3. **Predicate rewrite:** BI equality finds matches; non-searchable equality rejected.
4. **Rotation:** insert under FEK v1 → rotate → reads OK; opportunistic re-encrypt.
5. **Perf micro-benches:** AES-GCM vs ChaCha20-Poly1305.

*(TDE already has canary tests; see `tests/test_tde_kms_integration.zig` for pattern and enablement via feature flags, e.g., TDE enable at lines **16–21** and provider flows **22–33**, **55–67**)*.

---

## 7) Migration

* `ALTER` schema to add `@encrypted` → new writes encrypted.
* Backfill job: iterate records, encrypt field, write envelope (+ BI).
* During backfill: plaintext access for authorized users still works transparently; unauthorized receive redaction. Resumable; verify with counters/progress.

---

## 8) Quantum-resistant TDE (Kyber + Dilithium)

### 8.1 Where to integrate (today’s TDE stack)

* **TDE key flow:** `TDEKeyManager.initializeWithKMS` → `KMSProvider.fetchActiveMasterKey()` → **generate DEK** → `KMSProvider.wrapDataKey(dek)` → build hierarchy (see `tde_kms_integration.zig` lines **39–55**, **68–73**).
* **Encrypt/Decrypt:** uses AES-GCM (see **encryptWithKey/decryptWithKey** lines **50–67**, **71–79**).

### 8.2 PQC design

* **Kyber (KEM) for wrap/unwrap:**

  * **Wrap:** KMS provider holds Kyber **public key**. On `wrapDataKey(dek)`, **encapsulate → (ct, ss)**; derive symmetric key from `ss` (HKDF) and AES-GCM-wrap DEK (or XOR - with Dilithium integrity). Store `ct || encDEK` in `WrappedKey`.
  * **Unwrap:** provider (or external KMS) **decapsulates** `ct` with **private key** → `ss` → derive → unwrap DEK.
* **Dilithium for integrity:** sign rotation state / wrapped blobs; verify on load.
* **Bulk crypto stays AES-GCM** (data pages/WAL), consistent with current `TDEOperations` interface.

**Code impact:**

* Extend **`src/security/kms.zig`** (`KMSProvider.wrapDataKey/unwrapDataKey`) to add a **PQC mode** (e.g., `provider_type = .pqc_local` or a `pqc=true` flag).
* Keep `TDEKeyManager` API unchanged; only provider internals differ (call path remains at `tde_kms_integration.zig` **52–55**, **44–47**, **36–55** for rotation).
* Optional hybrid: store both classical and PQC wraps for migration safety.

**Build/FFI:** Zig 0.15.1 lacks Kyber/Dilithium in stdlib; vendor minimal C (PQClean / NIST ref) and wrap via `@cImport`. Encapsulation/decapsulation and sign/verify live in `src/crypto/pqc.zig`.
**Storage:** expect ~1–1.2 KB per Kyber ciphertext; adjust `WrappedKey` JSON/binary.
**Ops:** escrow PQC private keys (HSM/KMS ideally). Backups must include PQC key material or external KMS handles it.

---

## 9) Security & compliance notes

* **Never log plaintext or keys**; audit only key IDs & counts.
* **Zeroize** secrets and plaintext buffers (as already done for TDE data paths).
* **Nonce policy:** unique 96-bit per (key, write); track usage; consider XChaCha for BI derivations if added later.
* **NIST alignment:** AEAD per SP 800-38D; key lifecycles per SP 800-57; Kyber/Dilithium per NIST PQC (FIPS 203/204 as they finalize).

---

## 10) Minimal code insertion map (first PR slice)

1. **Encrypt-on-write:**

   * `graph_store.zig` — `setNodeProperty` (**L20–33**) & `setEdgeProperty` (**L83–95**) → envelope generation & BI update.
2. **Decrypt-on-projection:**

   * `execution.zig` — Node properties emission (**L61–71**) & `.Str` arm (**L92–102**) → decrypt when authorized.
3. **Planner rewrite:**

   * Add `planner/rewrite.zig`; call from `executeStatementWithContext` before `executeQueryWithContext(...)` (**L56–66**).
4. **KeyManager:**

   * New `src/keys/manager.zig`, used by (1) & (2).
5. **Parser annotations:**

   * Add `schema/annotations.zig`; integrate after `CREATE ... TYPE` is parsed (AST holds raw text; see dev notes).
6. **PQC wrap:**

   * `src/security/kms.zig` → extend `wrapDataKey/unwrapDataKey`; used by `tde_kms_integration.zig` (`initializeWithKMS`, rotation) (**L39–55**, **L36–55**).
7. **Tests:**

   * Mirror TDE test style `tests/test_tde_kms_integration.zig` (feature flag enable **L16–21**, provider init **L22–33**, encrypt/decrypt **L55–67**).

---

## 11) Acceptance criteria (from design)

* Correct AEAD (auth fails closed), AAD binds context, **transparent projection** for authorized, **ciphertext/redacted** for others.
* Blind-index equality works; leakage documented.
* Rotation: rewrap & re-encrypt online with progress telemetry.
* Perf bounds: encrypt+BI for 2 KiB ≤ 250 µs on AES-NI; key-cache hit ≤ 10 µs.

---

## 12) References (design inputs)

* **FLE prompt & architecture**; **Design report (Markdown)**; **Alt detailed write-up**; **Code-PR spec (files/tests tree)**.

---

### Appendix A — Pseudocode snippets

**Encrypt on write (node):**

```zig
if (schema.isEncrypted(field)) {
    const fek = try keyman.getFEK(tenant, schema, field); // returns [32]u8 + version
    const aad = makeAAD(tenant,schema,field,node_id,fek_version);
    const env = try aeadEncryptEnvelope(allocator, alg, fek, aad, plaintext);
    value_copy = .String => try allocator.dupe(u8, base64(env.bytes()));
    if (schema.isSearchable(field)) {
        const bik = try keyman.getBIK(tenant,schema,field);
        const bi = HMAC_SHA256(bik, normalize(plaintext));
        blindIndex.put((field, bi), node_id);
    }
}
```

**Decrypt on projection:**

```zig
if (schema.isEncrypted(field)) {
    if (rbac.canReadPlaintext(user, field)) {
        const env = parseEnvelope(s);
        const fek = try keyman.getFEK(tenant,schema,field, env.key_version);
        const aad = makeAAD(...);
        const pt  = try aeadDecryptEnvelope(allocator, fek, aad, env);
        emitString(pt);
    } else {
        emitString(policyRedactionOrCiphertext(s));
    }
}
```

**PQC wrap (KMS provider):**

```zig
// wrapDataKey(dek):
const (ct, ss) = kyberEncapsulate(pub);
const wrap_key = HKDF(ss, "geode/tde/wrap");
const enc_dek  = AES_GCM_Encrypt(wrap_key, dek, aad="dek");
return WrappedKey{ .alg="kyber-aesgcm", .ct=ct, .blob=enc_dek };
```

---

> If you want, I can follow this with a **files-and-diffs PR plan** (commit-by-commit) and a **GeodeTestLab YAML** suite matching the acceptance tests from the design.
