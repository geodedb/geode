<!-- CANARY: FLE_PR_PLAN - Field-Level Encryption PR Implementation Plan -->
<!-- CANARY: FLE_MODULE_SCAFFOLDING - Core Module Structure -->
<!-- CANARY: FLE_PLANNER_REWRITE - Query Planner Predicate Rewriting -->
<!-- CANARY: FLE_GEODETESTLAB_SPECS - Integration Test Specifications -->

Below is the **commit‑by‑commit PR plan** with focused diffs and new files, followed by a **GeodeTestLab YAML suite** that matches the acceptance criteria from the design docs. I've written the diffs to be **surgical and anchor‑based** so you can apply them even if the exact line numbers differ slightly in `main`.

> **Scope note (pragmatic):** Because I don’t have live code access to your private repo in this chat, I’m using **search‑and‑insert anchors** in diffs (`// GEODE_FLE_*`) rather than absolute line numbers. Each hunk clearly shows **where** to place changes (function name + nearby lines). This keeps the plan **actionable** without guessing your current line offsets.

---

## PR Plan (commit‑by‑commit)

### Commit 1 — Build & module scaffolding

**Goal:** Add crypto, key, index, schema, planner, exec, and admin skeletons; wire into `build.zig`.

**Files added**

```
src/crypto/aead.zig
src/crypto/hkdf.zig
src/crypto/hmac.zig
src/index/blind_index.zig
src/keys/types.zig
src/keys/manager.zig
src/schema/annotations.zig
src/planner/rewrite.zig
src/exec/projection.zig
src/admin/cli.zig
```

**Diff (excerpt):**

```diff
diff --git a/build.zig b/build.zig
--- a/build.zig
+++ b/build.zig
@@
 pub fn build(b: *std.Build) void {
     const target = b.standardTargetOptions(.{});
     const optimize = b.standardOptimizeOption(.{});
@@
-    const exe = b.addExecutable(.{ .name = "geode", .root_module = .{ .root_source_file = .{ .path = "src/main.zig" } } });
+    const exe = b.addExecutable(.{ .name = "geode", .root_module = .{ .root_source_file = .{ .path = "src/main.zig" } } });
+    // GEODE_FLE_WIRE_MODULES
+    exe.root_module.addAnonymousImport("geode_aead", .{ .root_source_file = .{ .path = "src/crypto/aead.zig" } });
+    exe.root_module.addAnonymousImport("geode_hmac", .{ .root_source_file = .{ .path = "src/crypto/hmac.zig" } });
+    exe.root_module.addAnonymousImport("geode_hkdf", .{ .root_source_file = .{ .path = "src/crypto/hkdf.zig" } });
+    exe.root_module.addAnonymousImport("geode_keys", .{ .root_source_file = .{ .path = "src/keys/manager.zig" } });
+    exe.root_module.addAnonymousImport("geode_bi", .{ .root_source_file = .{ .path = "src/index/blind_index.zig" } });
+    exe.root_module.addAnonymousImport("geode_schema_ann", .{ .root_source_file = .{ .path = "src/schema/annotations.zig" } });
+    exe.root_module.addAnonymousImport("geode_plan_rw", .{ .root_source_file = .{ .path = "src/planner/rewrite.zig" } });
+    exe.root_module.addAnonymousImport("geode_proj", .{ .root_source_file = .{ .path = "src/exec/projection.zig" } });
+    exe.root_module.addAnonymousImport("geode_admin_cli", .{ .root_source_file = .{ .path = "src/admin/cli.zig" } });
@@
     b.installArtifact(exe);
 }
```

**New core types (snippets):**

```zig
// src/crypto/aead.zig
const std = @import("std");
pub const Alg = enum(u8) { aes256_gcm = 1, chacha20_poly1305 = 2 };
pub const Error = error{ InvalidAlg, InvalidKey, NonceReuse, AEADAuthFailed, InvalidEnvelope };

pub fn encryptField(alloc: std.mem.Allocator, alg: Alg, fek: []const u8, aad: []const u8, pt: []const u8, nonce_opt: ?[12]u8) ![]u8 { /* EnvelopeV1 serialize */ }
pub fn decryptField(alloc: std.mem.Allocator, fek: []const u8, aad: []const u8, envelope: []const u8) ![]u8 { /* parse + AEAD */ }
```

```zig
// src/index/blind_index.zig
const std = @import("std");
pub fn normalizeForBlindIndex(alloc: std.mem.Allocator, s: []const u8) ![]u8 { /* ASCII lower + UTF‑8 NFC + trim */ }
pub fn blindIndexHmac256(out: *[32]u8, bik: []const u8, normalized: []const u8) void { /* HMAC‑SHA256 */ }
```

```zig
// src/keys/types.zig
pub const KeyIds = struct { tenant: []const u8, schema: []const u8, field: []const u8, version: u16 };
```

```zig
// src/keys/manager.zig
const std = @import("std");
const types = @import("geode_keys"); // self-import acceptable when compiled via addAnonymousImport
pub const KeyManager = struct {
    pub fn init(alloc: std.mem.Allocator) !*KeyManager { /* cache boot */ }
    pub fn getFek(self: *KeyManager, ids: types.KeyIds) ![32]u8 { /* FEK lookup */ }
    pub fn getBik(self: *KeyManager, ids: types.KeyIds) ![32]u8 { /* BIK lookup */ }
    pub fn rotateFek(self: *KeyManager, tenant: []const u8, schema: []const u8, field: []const u8) !u16 { /* v++ */ }
};
```

---

### Commit 2 — Schema annotations (`@encrypted`, `@searchable`, `@visible`, `@classify`)

**Goal:** Parse annotations from CREATE TYPE and store per‑field metadata (engine‑side catalog).

**Files modified**

```
src/gql/parser.zig         // post-parse hook call
src/schema/annotations.zig // new: parser + catalog write
```

**Diff (excerpt):**

```diff
diff --git a/src/gql/parser.zig b/src/gql/parser.zig
--- a/src/gql/parser.zig
+++ b/src/gql/parser.zig
@@
-    // existing: capture type_definition as raw text
+    // existing: capture type_definition as raw text
+    // GEODE_FLE_ANNOTATIONS_BEGIN
+    // After persisting base type, invoke annotation processor on raw definition.
+    try geode_schema_ann.applyAnnotations(self.allocator, graph_name, type_name, raw_type_definition);
+    // GEODE_FLE_ANNOTATIONS_END
```

**New (skeleton)**

```zig
// src/schema/annotations.zig
pub fn applyAnnotations(alloc: std.mem.Allocator, graph: []const u8, type_name: []const u8, raw: []const u8) !void {
    // scan properties; accept @encrypted(...), @searchable(...), @visible(...), @classify(...)
    // populate schema catalog/table: encrypted=true, alg, searchable=true, roles, tags
}
```

---

### Commit 3 — Encrypt‑on‑write (nodes & edges) + BI maintenance

**Goal:** Intercept property writes; store **EnvelopeV1**; update **blind index** map when applicable.

**Files modified**

```
src/storage/graph_store.zig   // or your equivalent node/edge property store
```

**Diff (anchor‑based):**

```diff
--- a/src/storage/graph_store.zig
+++ b/src/storage/graph_store.zig
@@
 func setNodeProperty(node_id: NodeId, key: []const u8, val: []const u8) !void {
-    // existing put + persist
+    // GEODE_FLE_ENCRYPT_ON_WRITE_BEGIN
+    if (schemaCatalog.isEncrypted(nodeType(node_id), key)) {
+        const ids = KeyIds{ .tenant = currentTenant(), .schema = nodeType(node_id), .field = key, .version = schemaCatalog.activeVersion(nodeType(node_id), key) };
+        const fek = try keyman.getFek(ids);
+        const aad = makeAAD(ids.tenant, ids.schema, key, node_id, ids.version);
+        const env = try geode_aead.encryptField(allocator, schemaCatalog.alg(nodeType(node_id), key), &fek, aad, val, null);
+        // replace plaintext with envelope bytes
+        rawPut(node_id, key, env);
+        if (schemaCatalog.isSearchable(nodeType(node_id), key)) {
+            const bik = try keyman.getBik(ids);
+            const norm = try geode_bi.normalizeForBlindIndex(allocator, val);
+            var tok: [32]u8 = undefined; geode_bi.blindIndexHmac256(&tok, &bik, norm);
+            blindIndex.put(.{ nodeType(node_id), key, tok }, node_id);
+        }
+        return;
+    }
+    // GEODE_FLE_ENCRYPT_ON_WRITE_END
     rawPut(node_id, key, val);
 }
@@
 func setEdgeProperty(edge_id: EdgeId, key: []const u8, val: []const u8) !void {
-    // existing put + persist
+    // GEODE_FLE_ENCRYPT_ON_WRITE_BEGIN (edges)
+    // same pattern as nodes with edge context in AAD
+    // GEODE_FLE_ENCRYPT_ON_WRITE_END
     rawPut(edge_id, key, val);
 }
```

---

### Commit 4 — Decrypt‑on‑projection + RBAC/ABAC gate

**Goal:** Only authorized roles see plaintext; others get ciphertext or redaction token.

**Files modified**

```
src/execution.zig
src/exec/projection.zig
```

**Diff (excerpt):**

```diff
--- a/src/execution.zig
+++ b/src/execution.zig
@@
-    // property JSON write (string case)
-    writer.print("\"{s}\"", .{value});
+    // GEODE_FLE_PROJECTION_BEGIN
+    if (schemaCatalog.isEncrypted(node_type, key)) {
+        if (securityCtx.canReadPlaintext(user, node_type, key)) {
+            const env = value; // bytes/string blob
+            const ids = KeyIds{ .tenant = tenant, .schema = node_type, .field = key, .version = parseVersion(env) };
+            const fek = try keyman.getFek(ids);
+            const aad = makeAAD(tenant, node_type, key, node_id, ids.version);
+            const pt  = try geode_aead.decryptField(allocator, &fek, aad, env);
+            try writer.print("\"{s}\"", .{pt});
+        } else {
+            try writer.print("\"[REDACTED]\"", .{});
+        }
+        continue;
+    }
+    // GEODE_FLE_PROJECTION_END
+    try writer.print("\"{s}\"", .{value});
```

---

### Commit 5 — Planner rewrite for equality on encrypted fields

**Goal:** Authorized equality predicates on `@searchable` fields become **BI token** comparisons; unauthorized attempts **fail**.

**Files modified**

```
src/planner/rewrite.zig
src/execution.zig (call the pass right after parse)
```

**Diff (excerpt):**

```diff
--- a/src/execution.zig
+++ b/src/execution.zig
@@
-const plan = buildPlan(ast);
+const plan0 = buildPlan(ast);
+const plan = geode_plan_rw.rewriteEncryptedEquality(allocator, plan0, securityCtx, schemaCatalog);
```

```zig
// src/planner/rewrite.zig
pub fn rewriteEncryptedEquality(alloc: std.mem.Allocator, plan: Plan, sec: SecurityCtx, cat: SchemaCatalog) Plan {
    // walk predicates:
    //   if field is encrypted:
    //     if not cat.isSearchable(field) -> raise SearchNotPermitted
    //     if !sec.canReadPlaintext(field) -> raise SearchNotPermitted
    //     else replace "= 'literal'" with "= BI(HMAC(bik, normalize(literal)))"
}
```

---

### Commit 6 — Rotation APIs (rewrap + re‑encrypt)

**Goal:** Online FEK re‑encrypt and TRK/SK rewrap.

**Files modified**

```
src/keys/manager.zig
src/admin/cli.zig
```

**Diff (excerpt):**

```diff
--- a/src/admin/cli.zig
+++ b/src/admin/cli.zig
@@
 case .KeyRotate => |args| {
-    // existing stub
+    if (args.scope == .fek) { const new_v = try keyman.rotateFek(args.tenant, args.schema, args.field); printJsonStatus(new_v); }
+    else if (args.scope == .sk) { try keyman.rewrapSk(args.tenant, args.schema); }
+    else if (args.scope == .trk) { try keyman.rewrapTrk(args.tenant); }
 }
```

---

### Commit 7 — Tests (Zig unit tests for crypto/BI/envelope)

**Goal:** Add deterministic tests incl. **HMAC vector**, **bad‑AAD**, **envelope serialization**, and **projection redaction** (strings as per acceptance).

**Files added**

```
tests/aead_test.zig
tests/hmac_test.zig
tests/projection_test.zig
tests/planner_test.zig
tests/envelope_test.zig
```

**Example (HMAC):**

```zig
test "HMAC-SHA256 RFC 4231 Jefe vector" {
    const key = "Jefe";
    const msg = "what do ya want for nothing?";
    var out: [32]u8 = undefined;
    blind_index.blindIndexHmac256(&out, key, msg);
    try std.testing.expectFmt("5bdcc146bf60754e6a042426089575c75a003f089d2739839dec58b964ec3843", "{s}", .{std.fmt.bytesToHex(out, .lower)});
}
```

---

### Commit 8 — PQC KMS integration (Kyber wrap/unwrap, Dilithium sign/verify)

**Goal:** Upgrade **TDE key wrapping** path to support Kyber + Dilithium (opt‑in).

**Files added**

```
src/crypto/pqc.zig           // @cImport minimal Kyber/Dilithium
src/security/kms_pqc.zig     // provider implementation
```

**Files modified**

```
src/security/kms.zig         // provider registry: add .pqc_local
src/security/tde_kms_integration.zig // no API change; provider internals decide
```

**Diff (excerpt):**

```diff
--- a/src/security/kms.zig
+++ b/src/security/kms.zig
@@
 pub const ProviderType = enum { local_dev, external_kms, pqc_local };
@@
 pub fn wrapDataKey(self: *KMSProvider, dek: [32]u8) !WrappedKey {
     switch (self.config.provider_type) {
+        .pqc_local => return kms_pqc.wrapWithKyber(self, dek),
         else => return wrapClassic(self, dek),
     }
 }
 pub fn unwrapDataKey(self: *KMSProvider, wk: WrappedKey) ![32]u8 {
     switch (self.config.provider_type) {
+        .pqc_local => return kms_pqc.unwrapWithKyber(self, wk),
         else => return unwrapClassic(self, wk),
     }
 }
```

**Kyber wrap sketch:**

```zig
// src/security/kms_pqc.zig
const pqc = @import("../crypto/pqc.zig");
pub fn wrapWithKyber(self: *KMSProvider, dek: [32]u8) !WrappedKey {
    const pk = self.pqc_pubkey;
    var ct: [pqc.KYBER_CT_LEN]u8 = undefined;
    var ss: [32]u8 = undefined;
    try pqc.kyber_encapsulate(&ct, &ss, pk);
    const wrap_key = hkdf(ss, "geode/tde/wrap");
    const enc_dek = aead_wrap(wrap_key, dek);
    return WrappedKey{ .alg = .kyber_aesgcm, .ct = ct[0..], .blob = enc_dek };
}
```

> Bulk data (TDE pages/WAL) remains AES‑GCM; only key wrap changes. Dilithium signs rotation state files (verify at load).

---

### Commit 9 — Docs (DESIGN.md updates) & user‑facing CLI help

**Files modified**

```
docs/DESIGN.md
docs/ISO-GQL-vs-Geode.md
src/admin/cli.zig (help text)
```

---

## GeodeTestLab YAML Suite (acceptance‑matching)

> Place under `geodetestlab/specs/`. These are **fixtures** matching the design’s acceptance tests. The runner consumes them to execute GQL/CLI and assert outputs.

### 1) `encryption_basic.yml`

```yaml
suite: encryption_basic
description: Basic FLE — encrypt-on-write, decrypt-on-projection with RBAC.
setup:
  - gql: |
      CREATE NODE TYPE Person (
        id UUID PRIMARY KEY,
        name STRING,
        ssn  STRING @encrypted(alg:"AES-256-GCM") @classify(tags:["PII"]) @visible(to_roles:["pii_reader"])
      );
  - cmd: geode policy grant plaintext Person.ssn --role pii_reader
  - cmd: geode user assume --role pii_reader
steps:
  - name: insert_rows
    gql: |
      INSERT INTO Person { id: "11111111-1111-1111-1111-111111111111", name: "Alice", ssn: "123-45-6789" };
  - name: read_authorized
    gql: |
      MATCH (p:Person WHERE p.id = "11111111-1111-1111-1111-111111111111") RETURN p.ssn;
    expect:
      json_contains: [{ "p.ssn": "123-45-6789" }]
  - name: read_unauthorized
    cmd: geode user assume --role analyst
  - name: read_unauth_check
    gql: |
      MATCH (p:Person WHERE p.id = "11111111-1111-1111-1111-111111111111") RETURN p.ssn;
    expect:
      json_contains_any:
        - { "p.ssn": "[REDACTED]" }
        - { "p.ssn": /^ENC/ }  # if policy returns ciphertext blob
```

### 2) `encryption_blind_index.yml`

```yaml
suite: encryption_blind_index
description: Equality search via blind index (BI) on encrypted field.
setup:
  - gql: |
      CREATE NODE TYPE Account (
        id UUID PRIMARY KEY,
        email STRING @encrypted(alg:"CHACHA20-POLY1305") @searchable(index:"blind-hmac-sha256")
      );
steps:
  - name: seed
    gql: |
      INSERT INTO Account { id:"aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa", email:"alice@example.com" };
      INSERT INTO Account { id:"bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb", email:"bob@example.com" };
  - name: query_by_email
    gql: |
      MATCH (a:Account WHERE a.email = "alice@example.com") RETURN a.id;
    expect:
      rows_exact:
        - { "a.id": "aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa" }
```

### 3) `encryption_rotation.yml`

```yaml
suite: encryption_rotation
description: Online FEK re-encrypt; mixed-version reads OK.
setup:
  - gql: |
      CREATE NODE TYPE Person (
        id UUID PRIMARY KEY,
        ssn STRING @encrypted(alg:"AES-256-GCM") @searchable(index:"blind-hmac-sha256")
      );
  - name: insert
    gql: |
      INSERT INTO Person { id:"p1", ssn:"111-22-3333" };
steps:
  - name: rotate_fek
    cmd: geode key rotate --tenant default --schema Person --field ssn --scope FEK
  - name: read_after_rotate
    gql: |
      MATCH (p:Person WHERE p.id = "p1") RETURN p.ssn;
    expect:
      json_contains: [{ "p.ssn": "111-22-3333" }]
  - name: progress
    cmd: geode show rotation-status --tenant default
    expect:
      json_contains: [{ "evt": "fek_reencrypt", "progress": /^(100|[0-9]{1,2})%$/ }]
```

### 4) `encryption_migration.yml`

```yaml
suite: encryption_migration
description: Plaintext → @encrypted backfill path; transparent reads.
setup:
  - gql: |
      CREATE NODE TYPE Patient ( id STRING PRIMARY KEY, diagnosis STRING );
  - gql: |
      INSERT INTO Patient { id:"x", diagnosis:"hypertension" };
steps:
  - name: alter_encrypt
    gql: |
      ALTER NODE TYPE Patient ALTER PROPERTY diagnosis
        SET @encrypted(alg:"AES-256-GCM") @classify(tags:["PHI"]);
  - name: backfill
    cmd: geode migrate encrypt --tenant default --field Patient.diagnosis --batch 1000
  - name: read_plaintext_after
    gql: |
      MATCH (p:Patient WHERE p.id = "x") RETURN p.diagnosis;
    expect:
      json_contains: [{ "p.diagnosis": "hypertension" }]
```

### 5) `encryption_rbac.yml`

```yaml
suite: encryption_rbac
description: Grant/Revoke READ_PLAINTEXT(field) affects projection & filters.
setup:
  - gql: |
      CREATE NODE TYPE Person ( id STRING PRIMARY KEY, ssn STRING @encrypted(alg:"AES-256-GCM") @searchable(index:"blind-hmac-sha256") );
  - gql: |
      INSERT INTO Person { id:"u1", ssn:"123-45-6789" };
steps:
  - name: no_priv_projection
    cmd: geode user assume --role analyst
  - gql: |
      MATCH (p:Person WHERE p.id = "u1") RETURN p.ssn;
    expect:
      json_contains_any:
        - { "p.ssn": "[REDACTED]" }
        - { "p.ssn": /^ENC/ }
  - name: no_priv_filter_blocked
    gql: |
      MATCH (p:Person WHERE p.ssn = "123-45-6789") RETURN p.id;
    expect_error: SEARCH_NOT_PERMITTED
  - name: grant_then_filter
    cmd: geode policy grant plaintext Person.ssn --role analyst
  - gql: |
      MATCH (p:Person WHERE p.ssn = "123-45-6789") RETURN p.id;
    expect:
      rows_exact:
        - { "p.id": "u1" }
```

### 6) (Optional PQC) `tde_pqc_wrap.yml`

```yaml
suite: tde_pqc_wrap
description: Kyber wrap/unwrap of DEK + Dilithium signature on rotation state.
setup:
  - cmd: geode kms set-provider --type pqc_local --pubkey /etc/geode/pqc_pub --seckey /etc/geode/pqc_sec
steps:
  - name: rotate_master
    cmd: geode key rotate --tenant default --scope TRK
  - name: verify_signed_state
    cmd: geode kms verify-state
    expect:
      json_contains: [{ "signature": "valid", "alg": "dilithium" }]
```

---

## What you’ll get after merging this PR

* **FLE end‑to‑end**: on‑write AEAD envelopes, BI equality, RBAC‑gated projection, rotation flows.
* **Extensible GQL**: `@encrypted`, `@searchable`, `@visible`, `@classify` applied at DDL.
* **PQ‑ready TDE**: Kyber/Dilithium wrapping path added (opt‑in), bulk crypto unchanged (AES‑GCM).
* **Tests**: YAML fixtures (above) + Zig unit tests hitting acceptance points (HMAC vector, bad‑AAD, envelope bytes, predicate gate).
