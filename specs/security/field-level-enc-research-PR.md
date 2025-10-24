<!-- CANARY: FLE_CORE - Field-Level Encryption Core Research & Requirements -->
<!-- CANARY: FLE_AEAD - AEAD Encryption with AAD Binding -->
<!-- CANARY: FLE_KEY_MANAGEMENT - Hierarchical Key Management (TRK/SK/FEK/BIK) -->
<!-- CANARY: FLE_BLIND_INDEX - Blind Index for Searchable Encryption -->
<!-- CANARY: FLE_RBAC - RBAC/ABAC Field-Level Access Control -->
<!-- CANARY: FLE_GQL_EXTENSIONS - Geode GQL Schema Annotations -->

## Research Prompt — Geode Field‑Level Encryption & Key Management

### 0) Objective (what success looks like)

Design and document a **native, application‑level, field‑level encryption** capability for Geode that is:

* **Transparent** to authorized users: plaintext is returned automatically when privileges allow; otherwise ciphertext is returned.
* **Seamlessly queryable**: query planning/exec automatically performs encrypt/decrypt of parameters and results when the reader has permission.
* **Rotatable at scale**: hierarchical key structure with online rotation (DEK/FEK, schema keys, tenant master keys), rewrap and re‑encrypt paths, and key‑versioning guarantees.
* **Configurable but strong‑algorithms‑only** (AEAD only; e.g., AES‑GCM, ChaCha20‑Poly1305).
* **Implemented in Zig 0.15.1** using **`std.crypto`**; no custom crypto.
* **Extensible GQL**: per‑property annotations (Geode‑only extensions to the ISO GQL spec), plus keywords/functions for plaintext/ciphertext selection and classification.
* **Governed by RBAC/ABAC** at field level; auditable.
* **Tenant‑aware**: per‑tenant hierarchy and isolation for multi‑tenant deployments.

### 1) Scope & Non‑Goals

* **In scope:** field‑level encryption (not TDE), RBAC/ABAC at property level, hierarchical keys & rotation, migration plan for existing data, blind‑indexing for equality search, query planner changes, admin/CLI & telemetry.
* **Out of scope:** homomorphic encryption, arbitrary substring/range/prefix searchable encryption beyond safe blind‑index equality (document risks and future work).

### 2) Sub‑Questions (SQs) to answer

1. **Repo orientation:** What is Geode’s storage layout, schema/DDL, query engine, transaction, and tenancy architecture? Where do we hook encryption, keys, and policy checks?
2. **GQL interface design:** What Geode‑specific **schema annotations** and **query keywords/functions** are required (and how to keep them clearly outside ISO GQL)?
3. **Key hierarchy:** What exact **tenant → schema → field key** structure, identifiers, versioning, and metadata model do we use? How are keys stored, wrapped, and rotated?
4. **Algorithm policy:** Which AEADs from `std.crypto` (AES‑GCM, ChaCha20‑Poly1305) do we support, and how do we choose per field/tenant/platform (AES‑NI vs not)?
5. **Search on encrypted fields:** How do we support **equality predicates** and indexing safely (e.g., **blind indexes** using keyed HMAC) without deterministic plaintext leakage?
6. **Rotation mechanics:** What are the **rewrap** (KEK/SK rotation only) and **re‑encrypt** (FEK rotation) flows? How do we do online rotation with minimal downtime and strong consistency?
7. **RBAC/ABAC model:** What is the minimal viable policy language to express **role/attribute‑based field privileges** and classification defaults? How do we enforce/deny at plan & projection time?
8. **Threat model & limits:** What are the **side channels**, leakage through access patterns, frequency, length, logs/metrics, and how do we mitigate?
9. **Migration:** How to backfill existing data to encrypted fields safely, incrementally, and resumably?
10. **Operational story:** What admin UX, CLI, observability, and audit logging are required (key usage, decrypt counts, denials, rotation events)?

### 3) Inputs & Constraints (to confirm at kickoff)

* **Language/runtime:** Zig **0.15.1**; use **`std.crypto`** only—no custom primitives; prefer **AEAD** (AES‑GCM, ChaCha20‑Poly1305). ([Zig Programming Language][1])
* **Query language:** ISO **GQL** (property graph) as baseline; we will add **Geode‑only extensions** (clearly documented as non‑standard). ([ISO][2])
* **Security references:** NIST SP 800‑38D (**GCM**) and SP 800‑57 (**key management & rotation**), HKDF (RFC 5869), optional AES‑GCM‑SIV background (RFC 8452). ([NIST Computer Security Resource Center][3])
* **Prior art for field‑level encryption/search:** MongoDB **CSFLE** / **Queryable Encryption** (design patterns, blind indexes), comparative graph‑DB security (Neo4j RBAC). ([MongoDB][4])

### 4) Deliverables

1. **Design RFC** (≥15 pp) covering API/DDL, on‑read/on‑write flows, rotation, indexing, tenancy, RBAC/ABAC, threat model, ops.
2. **GQL Extension Spec** (“Geode Extensions”): grammar, keywords, semantics, error cases, examples.
3. **Key Management Spec**: data model, storage, wrapping, versioning, rotation SLAs, lifecycle, audit fields.
4. **Query Planner Changes**: plan‑rewrite rules; how constants are encrypted; how projections are decrypted; failure/partial‑redaction behavior.
5. **Prototype** PR(s): minimal slice across DDL→parser→planner→executor→storage; unit/prop tests; micro‑benchmarks.
6. **Migration & Rotation playbooks**: online rewrap/re‑encrypt; backfill strategy; roll‑forward/rollback.
7. **Security Review**: STRIDE/LINDDUN notes; testing matrix; logging redaction policy.
8. **Admin/CLI**: key lifecycle ops; “view as role” debugging; rotation triggers; metrics.

### 5) Research Plan (where to look; how to decide)

* **Codebase audit (github/spyderorg/geode):** Identify parser/AST, schema catalog, property storage, serialization, index subsystem, query planner/executor, transaction boundaries, tenant isolation layer. Map hook points for **encrypt‑on‑write**, **decrypt‑on‑read**, and **policy checks**.
* **Standards & crypto APIs:** Confirm Zig 0.15.1 `std.crypto` capabilities for **AES‑GCM** and **ChaCha20‑Poly1305**, **HMAC**, **HKDF**, secure RNG; select a unified AEAD abstraction. ([Zig Guide][5])
* **GQL baseline:** Review ISO GQL language constructs and how other engines extend syntax (e.g., property annotations) without colliding with the standard. ([ISO][2])
* **Prior art:** Study MongoDB **CSFLE/QE** (client‑side, blind indexes, query rewriting), risks and logging pitfalls (USENIX analysis), and Neo4j fine‑grained RBAC for property access patterns. ([MongoDB][4])
* **Key management best practices:** Apply NIST SP 800‑57 for **separation of key usages**, versioning, and rotation; envelope encryption from major KMS docs to justify DEK/KEK layering. ([NIST Computer Security Resource Center][6])

### 6) Proposed Architecture (to validate/iterate)

**6.1 Key hierarchy (tenant aware)**

```
Tenant Root Key (TRK) [KEK]
 └─ Schema Key (SK) [KEK], per (tenant, schema)
     └─ Field Encryption Keys (FEK) [DEK], per (tenant, schema, field, version)
         └─ Optional Blind Index Keys (BIK), per searchable field
```

* **Envelope encryption:** FEKs encrypt field values (AEAD). FEKs are **wrapped** by SK; SK is **wrapped** by TRK or external KMS (optional). Rotation supports: **rewrap** (TRK/SK) and **re‑encrypt** (FEK). (Pattern per industry/KMS docs.) ([Google Cloud][7])
* **Derivation:** Where appropriate, derive sub‑keys with **HKDF‑SHA256** with context strings (`"geode/trk"`, `"geode/sk"`, `"geode/fek"`, `"geode/bi"`). ([IETF Datatracker][8])
* **Key usage separation:** Distinct keys for AEAD vs blind‑index HMAC per NIST guidance. ([CMS Information Security][9])

**6.2 Algorithms (configurable, strong‑only)**

* **AEAD choices:** **AES‑256‑GCM** (hardware‑accelerated where available) and **ChaCha20‑Poly1305** (constant‑time, good without AES‑NI). Expose policy to choose per tenant/field. ([NIST Computer Security Resource Center][3])
* **Determinism:** Avoid deterministic encryption for search; instead, use **blind indexes** (HMAC‑SHA256 or keyed BLAKE2) alongside **randomized AEAD** ciphertexts. ([GitHub][10])
* **Usage limits:** Respect AEAD key/nonce usage limits; enforce per‑key data/operation counters. ([IETF][11])

**6.3 Blind index for equality search (optional per field)**

* On write: compute `BI = HMAC(BIK, normalize(value))` (configurable truncation), store in a dedicated index column. On query with literal: compute the same BI on the client/planner path and search via index. (Design inspired by CSFLE/QE and CipherSweet.) ([MongoDB][12])
* Document leakage (equality pattern leakage, frequency analysis) and mitigations (salting strategies, pepper storage, cardinality considerations). (See USENIX QE analysis.) ([USENIX][13])

**6.4 Storage format (per encrypted property)**

* **Envelope record:** `{alg_id, key_id, key_version, nonce, aad_digest, ciphertext, tag}` with canonical **AAD** binding (tenant_id, schema_id, field_id, record_id, key_version) to prevent context swapping. (GCM per SP 800‑38D.) ([NIST Publications][14])

**6.5 Planner & executor changes**

* **At parse/plan time:** Recognize encrypted fields from schema metadata. For authorized users, **rewrite constants** in predicates to encrypt (or compute blind index) before execution.
* **At projection time:** Decrypt fields just‑in‑time for authorized users; otherwise return **ciphertext** (or `NULL`/`REDACTED` per policy).
* **Key lookup:** Resolve FEK by `(tenant, schema, field, version)` via key cache; lazy unwrap via SK/TRK when needed.

**6.6 RBAC/ABAC policy**

* **RBAC** roles grant `READ_PLAINTEXT(field)` and/or `READ_CIPHERTEXT(field)` and `WRITE(field)`.
* Optional **ABAC** constraints (time, network, device posture) as additional predicates; deny‑by‑default. (Reference: Neo4j RBAC docs and general RBAC/ABAC guidance.) ([Graph Database & Analytics][15])

**6.7 Rotation flows (high priority)**

* **Rewrap rotation:** Rotate TRK or SK by rewrapping child keys; **no data rewrite**.
* **FEK re‑encrypt rotation:** Introduce FEK vN+1; new writes use vN+1; background job **re‑encrypts** existing values; reads of vN trigger opportunistic re‑encrypt.
* **Admin verbs:** `ALTER KEYSET … ROTATE [TRK|SK|FEK]`, `SHOW KEYS`, `SHOW ROTATION STATUS`.
* **SLA:** Provide throughput targets, back‑pressure behavior, and safe rollback. (Key rotation principles per NIST & KMS docs.) ([NIST Computer Security Resource Center][6])

### 7) GQL (Geode‑only) Extension Draft

> All **Geode extensions** are explicitly non‑standard (not ISO GQL). They follow an annotation‑style syntax and **won’t conflict** with existing keywords.

**7.1 Schema annotations (DDL)**

```gql
-- Geode extensions (non-standard)
CREATE NODE TYPE Person (
  id UUID PRIMARY KEY,
  name STRING,
  ssn STRING 
    @encrypted(alg:"AES-256-GCM", key_scope:"field", rotate:"90d")
    @classify(tags:["PII","Restricted"])
    @visible(to_roles:["pii_reader"]),          -- who may see plaintext
  email STRING 
    @encrypted(alg:"CHACHA20-POLY1305", key_scope:"field")
    @searchable(index:"blind-hmac-sha256")
);
```

**7.2 Query‑time helpers**

* **Functions:** `PLAINTEXT(x)`, `CIPHERTEXT(x)` to force projection form (subject to policy).
* **Predicates:** Literals in predicates on `@searchable` fields get **auto‑transformed** to blind index tokens.
* **Admin:**

  * `ALTER KEYSET TENANT t SCHEMA s FIELD f ROTATE;`
  * `SHOW KEYSET TENANT t;`
  * `SHOW CLASSIFICATION FOR s;`

> Alternative keyword form (if functions are undesirable): `VISIBLE AS PLAINTEXT/CIPHERTEXT`, `ENCRYPTED USING`, `CLASSIFY`.

### 8) Validation & Acceptance Criteria

* **Correctness:** Round‑trip AEAD auth; decryption fails closed; AAD bound to context.
* **Transparency:** Authorized queries return plaintext without extra user code; unauthorized return ciphertext or redaction.
* **Rotation:** Rewrap and re‑encrypt workflows complete online; mixed‑version reads succeed; telemetry exposes progress.
* **Search:** Equality predicate on `@searchable` fields works via blind index; leakage risks documented.
* **Performance:** Overheads bounded (N p50, p95 targets) and benchmarked on **AES‑NI vs non‑AES** hardware; AEAD key/nonce limits enforced. ([NIST Computer Security Resource Center][3])
* **Docs:** Clear separation between ISO GQL and Geode extensions, with examples and error messages.

### 9) Implementation Sketch (Zig 0.15.1; `std.crypto`)

* **Modules:**

  * `crypto/aead.zig` (unified wrapper for AES‑GCM, ChaCha20‑Poly1305),
  * `crypto/hkdf.zig`, `crypto/hmac.zig` (blind index),
  * `kms/keystore.zig` (pluggable TRK/SK storage, in‑DB or external),
  * `keys/manager.zig` (keyversion, wrapping, caching, rotation),
  * `schema/annotations.zig` (parse `@encrypted`, `@classify`, `@searchable`),
  * `planner/rewrite.zig` (encrypt constants / compute BIs),
  * `exec/projection.zig` (decrypt on output).
* **Data structures:** `KeyId`, `KeyVersion`, `KeySet`, `EncryptedFieldV1`, `BlindIndexToken`.
* **Testing:** property tests for AEAD misuse detection; fuzz parser; golden tests for rotation; perf micro‑benches.

### 10) Risks & Mitigations

* **Logging/telemetry leakage** (QE risk): scrub values, avoid logging plaintext/keys; audit only on key IDs and counts. ([USENIX][13])
* **Pattern leakage** via equality search: document BI leakage channels; allow per‑field opt‑out; consider slow/peppered BI for highly sensitive fields. ([GitHub][10])
* **Nonce misuse:** central nonce generation and counters; consider XChaCha20‑Poly1305 where long nonces help (if available). ([Zig Guide][5])
* **Role explosion:** keep RBAC minimal; allow ABAC constraints to reduce role proliferation. ([Satori][16])

---

## Background & References (quick notes)

* **ISO GQL** (property graph query standard) for baseline syntax; we extend it (clearly non‑standard). ([ISO][2])
* **Zig 0.15.1 docs**; `std.crypto` includes AES/ChaCha, HMAC, HKDF. ([Zig Programming Language][1])
* **NIST SP 800‑38D (GCM)** and **SP 800‑57 (Key Management)** for AEAD usage and rotation best practices. ([NIST Computer Security Resource Center][3])
* **HKDF (RFC 5869)** for deriving sub‑keys; **AES‑GCM‑SIV (RFC 8452)** context (determinism & misuse resistance) for design tradeoffs. ([IETF Datatracker][8])
* **MongoDB CSFLE / Queryable Encryption** (blind‑index and query rewrite patterns) and security analysis caveats. ([MongoDB][4])
* **Neo4j RBAC** for property‑level privileges. ([Graph Database & Analytics][15])

---

## Appendix A — Decision Matrix (skim)

| Topic    | Option             | Pros                                           | Cons                                                | Source/Notes                                  |
| -------- | ------------------ | ---------------------------------------------- | --------------------------------------------------- | --------------------------------------------- |
| AEAD     | AES‑256‑GCM        | HW‑accelerated on AES‑NI; standard             | Nonce‑reuse catastrophic; 64 GiB per nonce guidance | ([NIST Computer Security Resource Center][3]) |
| AEAD     | ChaCha20‑Poly1305  | Fast w/o AES‑NI; constant‑time                 | Slightly larger CPU on AES‑NI machines              | ([Zig Guide][5])                              |
| Search   | Blind index (HMAC) | Supports equality; keeps ciphertext randomized | Equality/frequency leakage; needs extra index       | ([GitHub][10])                                |
| Rotation | Rewrap (TRK/SK)    | No data rewrite; fast                          | Doesn’t change FEK exposure                         | NIST/KMS ([AWS Documentation][17])            |
| Rotation | Re‑encrypt (FEK)   | Strongest hygiene; new FEK                     | Needs online background job                         | NIST/KMS ([AWS Documentation][17])            |

---

### What the researcher should hand back

* A **design doc + extension spec** that compiles the above choices to Geode’s architecture, with concrete **DDL examples**, planner rules, and **Zig module outlines**, plus **benchmarks** comparing AES‑GCM vs ChaCha20‑Poly1305 on target hardware, and a **rotation demo** (both rewrap and re‑encrypt) with progress metrics.

---

### Citations (APA style; URL + Accessed)

* ISO/IEC. (2024). *Database languages — GQL (ISO/IEC 39075:2024)*. [https://www.iso.org/standard/76120.html](https://www.iso.org/standard/76120.html) (Accessed 2025‑10‑07). ([ISO][2])
* Zig. (2024). *Zig 0.15.1 Documentation*. [https://ziglang.org/documentation/0.15.1/](https://ziglang.org/documentation/0.15.1/) (Accessed 2025‑10‑07). ([Zig Programming Language][1])
* NIST. (2007). *SP 800‑38D: GCM and GMAC*. [https://nvlpubs.nist.gov/nistpubs/legacy/sp/nistspecialpublication800-38D.pdf](https://nvlpubs.nist.gov/nistpubs/legacy/sp/nistspecialpublication800-38D.pdf) (Accessed 2025‑10‑07). ([NIST Publications][14])
* NIST. (2020). *SP 800‑57 Pt.1 Rev.5: Key Management*. [https://csrc.nist.gov/pubs/sp/800/57/pt1/r5/final](https://csrc.nist.gov/pubs/sp/800/57/pt1/r5/final) (Accessed 2025‑10‑07). ([NIST Computer Security Resource Center][6])
* Krawczyk, H., & Eronen, P. (2010). *RFC 5869: HKDF*. [https://www.rfc-editor.org/info/rfc5869](https://www.rfc-editor.org/info/rfc5869) (Accessed 2025‑10‑07). ([RFC Editor][18])
* Gueron, S., Langley, A., & Lindell, Y. (2019). *RFC 8452: AES‑GCM‑SIV*. [https://datatracker.ietf.org/doc/html/rfc8452](https://datatracker.ietf.org/doc/html/rfc8452) (Accessed 2025‑10‑07). ([IETF Datatracker][19])
* MongoDB. (n.d.). *Client‑Side Field Level Encryption; Queryable Encryption*. [https://www.mongodb.com/docs/manual/core/csfle/](https://www.mongodb.com/docs/manual/core/csfle/) ; [https://www.mongodb.com/docs/manual/core/queryable-encryption/](https://www.mongodb.com/docs/manual/core/queryable-encryption/) (Accessed 2025‑10‑07). ([MongoDB][4])
* Gui, Z., et al. (2023). *Security Analysis of MongoDB Queryable Encryption*. USENIX Security. [https://www.usenix.org/system/files/usenixsecurity23-gui_1.pdf](https://www.usenix.org/system/files/usenixsecurity23-gui_1.pdf) (Accessed 2025‑10‑07). ([USENIX][13])
* Neo4j. (2025). *Role‑based access control*. [https://neo4j.com/docs/operations-manual/current/authentication-authorization/manage-privileges/](https://neo4j.com/docs/operations-manual/current/authentication-authorization/manage-privileges/) (Accessed 2025‑10‑07). ([Graph Database & Analytics][15])
* zig.guide. (2024). *std.crypto overview* (community docs; cross‑check with official). [https://zig.guide/standard-library/crypto/](https://zig.guide/standard-library/crypto/) (Accessed 2025‑10‑07). ([Zig Guide][5])

---

If you want, I can adapt this prompt into a **checklist‑driven task board** (stories/subtasks), or add a **lightweight schema grammar** and **test matrix** next.

[1]: https://ziglang.org/documentation/0.15.1/?utm_source=chatgpt.com "Documentation - The Zig Programming Language"
[2]: https://www.iso.org/standard/76120.html?utm_source=chatgpt.com "Database languages — GQL - ISO/IEC 39075:2024"
[3]: https://csrc.nist.gov/pubs/sp/800/38/d/final?utm_source=chatgpt.com "Recommendation for Block Cipher Modes of Operation: Galois ..."
[4]: https://www.mongodb.com/docs/manual/core/csfle/?utm_source=chatgpt.com "Client-Side Field Level Encryption - Database Manual"
[5]: https://zig.guide/standard-library/crypto/?utm_source=chatgpt.com "Crypto"
[6]: https://csrc.nist.gov/pubs/sp/800/57/pt1/r5/final?utm_source=chatgpt.com "SP 800-57 Part 1 Rev. 5, Recommendation for Key Management"
[7]: https://cloud.google.com/kms/docs/envelope-encryption?utm_source=chatgpt.com "Envelope encryption | Cloud Key Management Service"
[8]: https://datatracker.ietf.org/doc/html/rfc5869?utm_source=chatgpt.com "RFC 5869 - HMAC-based Extract-and-Expand Key ..."
[9]: https://security.cms.gov/learn/cms-key-management-handbook?utm_source=chatgpt.com "CMS Key Management Handbook"
[10]: https://github.com/ankane/blind_index?utm_source=chatgpt.com "ankane/blind_index: Securely search encrypted database ..."
[11]: https://www.ietf.org/archive/id/draft-irtf-cfrg-aead-limits-07.html?utm_source=chatgpt.com "Usage Limits on AEAD Algorithms"
[12]: https://www.mongodb.com/docs/manual/core/queryable-encryption/about-qe-csfle/?utm_source=chatgpt.com "Choosing an In-Use Encryption Approach - Database Manual"
[13]: https://www.usenix.org/system/files/usenixsecurity23-gui_1.pdf?utm_source=chatgpt.com "Security Analysis of MongoDB Queryable Encryption"
[14]: https://nvlpubs.nist.gov/nistpubs/legacy/sp/nistspecialpublication800-38d.pdf?utm_source=chatgpt.com "Galois/Counter Mode (GCM) and GMAC"
[15]: https://neo4j.com/docs/operations-manual/current/authentication-authorization/manage-privileges/?utm_source=chatgpt.com "Role-based access control - Operations Manual"
[16]: https://satoricyber.com/data-protect-guide/rbac-vs-abac-the-complete-guide/?utm_source=chatgpt.com "RBAC vs. ABAC: The Complete Guide - Satori"
[17]: https://docs.aws.amazon.com/kms/latest/developerguide/rotate-keys.html?utm_source=chatgpt.com "Rotate AWS KMS keys - AWS Key Management Service"
[18]: https://www.rfc-editor.org/info/rfc5869?utm_source=chatgpt.com "Information on RFC 5869"
[19]: https://datatracker.ietf.org/doc/html/rfc8452?utm_source=chatgpt.com "RFC 8452 - AES-GCM-SIV: Nonce Misuse-Resistant ..."
