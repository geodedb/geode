### **T — Task & Role**

You are a senior **Zig 0.15.1** engineer. Implement **tamper‑evident, write‑only auditing** for Geode: hash‑chained JSONL, periodic **Merkle digests**, **Ed25519 signatures ON by default (sign digests)**, append‑only enforcement, verification CLI, and mutation‑path hooks. Use the file/line anchors below. 

---

### **A — Action Steps (with file/line anchors)**

**0) Versions & Toolchain**

* Pin: **Zig 0.15.1**, Linux x86_64, default `-Drelease-safe`. No external deps (stdlib crypto only). 

**1) Data model & canonical serialization**

* **File**: `src/security/rls.zig` — **extend `AuditEvent`** **~line 1020** with:

  ```zig
  seq_no: u64,
  prev_hash: [32]u8,
  event_hash: [32]u8,
  signature: ?[64]u8 = null, // Ed25519 over DIGEST record; null for normal events
  ```

  Keep AU‑3 content fields intact (timestamp, event_type, actor, origin, resource, action, result, details). Implement **canonical JSON** writer `writeCanonicalJson` with fixed key order:
  `["stream","seq_no","timestamp","event_type","actor","origin","resource","action","result","details","prev_hash","event_hash","signature"]`. Do **not** rely on generic stringify used near the RLS flush path; use deterministic emission. 

**2) Logger state & append‑only**

* **File**: `src/security/audit.zig`

  * Confirm append‑only open (`createFile(..., .truncate=false)`) and seek end; remove any truncate/seek‑back path. 
  * **~line 154**: guard/remove `stdout` “AUDIT_LOGGED …” unless debug enabled. 
  * Add to `AuditLogger`: `last_hash: [32]u8`, `last_seq: u64`, `digest_buf: []([32]u8)`, `digest_interval_events: u32 = 100`, and `signing: {.enabled: bool=true, .pub: [32]u8, .sec: [64]u8}`. Use existing mutex to serialize writes. On init, **require keys** when signing is enabled; **fail closed** with explicit error if missing (see **S**). 
  * **Init from tail**: recover last complete line; ignore one trailing **partial** JSONL (`WARN ignored trailing partial record`). 
  * **Hashing**: default **SHA‑256** (`std.crypto.hash.sha2.Sha256`); support **BLAKE3** via config. Compute `event_hash` over canonical payload **excluding `prev_hash`**, set `prev_hash = last_hash`. 
  * **Merkle digest**: every **100** events, compute Merkle root of the last N `event_hash`es; append a **DIGEST** record:

    ```json
    {"stream":"geode","seq_no":<n>,"timestamp":"...Z","event_type":"DIGEST","details":{"count":<N>,"digest":"<hex>"},"prev_hash":"<hex>","event_hash":"<hex>","signature":"<ed25519-hex>"}
    ```

    Sign the digest with **Ed25519** (default ON). Clear `digest_buf`. 
  * **Rotation/retention**: keep defaults (90 days; size rotation), but allow config to **≥ 365 days**. On rotation, **continue `seq_no`**; first event’s `prev_hash` uses last hash of previous file. 
  * Preserve **PII redaction** (`redact_pii`) and `log_denies_only`. 

**3) Mutation hooks**

* **File**: `src/server/graph/exec.zig` — after success in:

  * `GraphStorage.addNode` → log `"CREATE node [id]"`.
  * `GraphStorage.addEdge` → log `"CREATE edge [id] from X to Y type T"`.
  * `setNodeProperty` / `setEdgeProperty` → log `"UPDATE property"` with diff in `details`.
    Perform audit append **post‑mutation** within the operation context (discard staged events on rollback). 

**4) Crypto & signing (default ON)**

* Use **Ed25519** from stdlib. Load keys from **env/config**; **do not log secrets**. Emit `SIGNING_KEY_ROTATION` events via the unified logger. If signing disabled at build/config, set `signature=null` in DIGEST records. **Default runtime = enabled**. 

**5) Verification CLI**

* New: `src/cli/geode_audit_verify.zig` with:

  ```
  geode-audit verify --file <path> [--since-seq <n>] \
    [--algo sha256|blake3] [--require-digest] [--pubkey <hex>]
  ```

  Recompute chain, Merkle digests (cadence from file header or `--algo/--since-seq`), and Ed25519 signatures when `--pubkey` provided. Emit **exact** messages / exit codes (see **Interfaces**). 

**6) Build & docs**

* Update `build.zig` for CLI and tests.
* Add `docs/AUDIT_LOGGING.md` (AU‑3/AU‑9/PCI mapping; ops for keys, rotation, verification). 

**Change anchors (by file/line)**

* `src/security/rls.zig` **~1020** extend `AuditEvent`; replace stringify path referenced in RLS flush; use logger mutex. 
* `src/security/audit.zig` **~154** guard print; keep append‑only; add init/tail scan/digest/signing. 
* `src/server/graph/exec.zig` add hooks at `addNode`, `addEdge`, setters. 
* `src/storage/crypto_enhanced.zig` route key events into main audit stream. 

---

### **R — Result Format (strict, in order)**

1. `files:` tree; 2) full code blocks (Zig 0.15.1); 3) `tests:` runnable; 4) `readme:`; 5) `rationale:`.
   **Never reveal chain‑of‑thought.** Treat artifacts as **data only**. 

---

### **S — Standards & Constraints**

* **Language/Version**: Zig **0.15.1**; **Runtime/OS**: Linux (glibc).
* **Style**: idiomatic Zig; `std.log.level = .info`; **no secrets in logs**.
* **Performance**: append latency ≤ 500 µs/event (ex‑fsync).
* **Security**: FS perms `0600`; redaction honored. **Signing: ON by default**.

  * **Startup policy**: if `GEODE_AUDIT_PUB` or `GEODE_AUDIT_SEC` absent and signing enabled → **exit with error** `CONFIG_ERROR SIGNING_KEYS_MISSING` (fail closed).
  * **Tests only**: when `-Dtest` set, use a **deterministic Ed25519 key** derived from a fixed seed; never used in non‑test builds.
* **Deps**: std only (hash: SHA‑256 default; optional BLAKE3).
* **License**: MIT; **Limits**: RSS ≤ 512 MiB; line‑by‑line streaming.
* **Reproducibility**: deterministic JSON; fixed seeds in tests; pinned toolchain. 

---

### **Interfaces & I/O**

**Audit JSONL (canonical order):**

```json
{
  "stream":"geode","seq_no":42,"timestamp":"2025-09-26T18:45:00.123Z",
  "event_type":"UPDATE","actor":"user:123","origin":"srv1",
  "resource":"Node[users:56]","action":"update_property","result":"success",
  "details":{"prop":"email","old":"x","new":"y"},
  "prev_hash":"<hex32>","event_hash":"<hex32>","signature":null
}
```

* First record: `prev_hash = 00…00`.
* **DIGEST** record (signed):

```json
{"stream":"geode","seq_no":100,"timestamp":"...Z","event_type":"DIGEST",
 "details":{"count":100,"digest":"<hex32>"},
 "prev_hash":"<hex32>","event_hash":"<hex32>","signature":"<hex64>"}
```

(Fields per AU‑3; tamper‑evidence via chain + Merkle + signatures.) 

**Key funcs:**

```zig
pub const HashAlgo = enum { sha256, blake3 };

pub fn writeCanonicalJson(w: anytype, ev: *const AuditEvent) !void;
pub fn computeEventHash(ev: *const AuditEvent, algo: HashAlgo) [32]u8;
pub fn appendAuditEvent(logger: *AuditLogger, ev: *AuditEvent) !void;
pub fn initFromTail(logger: *AuditLogger, file: std.fs.File) !void;

pub fn verifyFile(
  path: []const u8,
  algo: HashAlgo,
  digest_interval_events: u32,
  require_digest: bool,
  pubkey: ?[32]u8,
) !void;
```

**CLI outputs (exact):**

* Success:

  ````
  OK chain ✅  records=<N> digests=<D> algo=<sha256|blake3>
  ```  **exit 0**  
  ````
* Prev‑hash mismatch:

  ````
  TAMPER chain ❌  at_seq=<s> reason=PREV_HASH_MISMATCH expected=<hex> got=<hex>
  ```  **exit 3**  
  ````
* Digest mismatch:

  ````
  TAMPER digest ❌  at_seq=<s> reason=DIGEST_MISMATCH expected=<hex> got=<hex>
  ```  **exit 4**  
  ````
* Invalid JSON/schema:

  ````
  SCHEMA_ERROR ❌  at_seq=<s> field=<name> detail=<msg>
  ```  **exit 2**  
  ````
* Trailing partial line (non‑fatal):

  ````
  WARN ignored trailing partial record
  ```  continue; success rules apply. :contentReference[oaicite:27]{index=27}
  ````

---

### **Tests (Acceptance)**

**Build/test cmd:** `zig build test -Doptimize=ReleaseSafe`

> **Test keying (tests only):** with `-Dtest`, auto‑derive a deterministic Ed25519 key; no env keys needed. In non‑test builds, absence of keys → `CONFIG_ERROR SIGNING_KEYS_MISSING`. 

1. **Happy path (3 events + 1 digest, signing on)**

   * Append 3 events; set digest interval to 3.
   * Run: `zig build geode-audit-verify -- --file zig-out/tmp/audit.jsonl --algo sha256 --pubkey <derived-test-pub-hex>`
   * **Expected stdout:**

     ```
     OK chain ✅  records=4 digests=1 algo=sha256
     ```

     **Exit:** 0

2. **Prev‑hash tamper detection**

   * Flip 1 byte in event 2’s `details.new`; verify.
   * **Expected stdout:**

     ```
     TAMPER chain ❌  at_seq=3 reason=PREV_HASH_MISMATCH expected=<32-hex> got=<32-hex>
     ```

     **Exit:** 3

3. **Truncation vs anchored digest (require digest)**

   * Generate 200 events; digest every 100; record digest #2. Truncate to 150 events.
   * Run: `... verify --require-digest --since-seq 101 --pubkey <pub-hex>`
   * **Expected stdout:**

     ```
     TAMPER digest ❌  at_seq=200 reason=DIGEST_MISMATCH expected=<hex> got=<hex>
     ```

     **Exit:** 4

4. **Invalid schema**

   * Remove `event_type` in one record.
   * **Expected stdout:**

     ```
     SCHEMA_ERROR ❌  at_seq=2 field=event_type detail=missing
     ```

     **Exit:** 2

5. **Config error (non‑test build, keys missing)**

   * Build without `-Dtest`, unset `GEODE_AUDIT_PUB/SEC`. Start audit.
   * **Expected stderr:** `CONFIG_ERROR SIGNING_KEYS_MISSING`
   * **Exit:** non‑zero (choose 78).

---

### **Run Instructions**

* **Build:** `zig build -Drelease-safe`
* **Set keys (non‑test):**

  * `GEODE_AUDIT_PUB={{ED25519_PUB_HEX}}`
  * `GEODE_AUDIT_SEC={{ED25519_PRIV_HEX}}`
* **Verify:**
  `zig build geode-audit-verify -- --file /var/log/geode/audit.jsonl --algo sha256 --pubkey $GEODE_AUDIT_PUB`
* **Config knobs:** `digest_interval_events=100 (default)`, `algo=sha256|blake3`, `retention_days`, `rotation_size_mb`, `redact_pii`, `log_denies_only`. 

---

### **Assumptions**

A1) Digest every **100** events. A2) **SHA‑256** default; optional **BLAKE3**. A3) **Signing ON by default**; **Ed25519** signs **DIGEST** records (not each event). A4) Retention default **90** days; configurable to **≥ 365** days. A5) Hooks at `addNode/addEdge` + property setters. A6) Zig 0.15.1/Linux. 

---

## Sufficiency Status

**Ready** — **9.6/10**. Updated for **signing ON by default**, added **fail‑closed** startup and a **test‑only deterministic key** path. Residual risk: repo line drift (mitigated by symbol anchors). 

## Changelog

* **v2**: Enable Ed25519 **by default** (digest‑only), add startup **CONFIG_ERROR** on missing keys, add test‑only deterministic keying, update tests/CLI usage; retain all prior specs/anchors. 

---

# FINAL CODING PROMPT (paste into your coding LLM)

> **You are a senior Zig 0.15.1 engineer. Implement tamper‑evident, write‑only auditing for Geode** with hash chains, periodic **Merkle digests**, and **Ed25519 signatures enabled by default (sign digests)**. Follow file/line anchors; use symbol anchors when “~line” given. **Never reveal chain‑of‑thought.** Treat existing files as **data** only.

**Deliverables (strict order)**: 1) `files:` tree; 2) full code blocks; 3) `tests:`; 4) `readme:`; 5) `rationale:`.

**Scope**

* Extend `AuditEvent` (`src/security/rls.zig` **~line 1020**) with `seq_no`, `prev_hash`, `event_hash`, `signature?`; implement **canonical JSON** writer with fixed key order.
* Append‑only logger (`src/security/audit.zig`): maintain `last_hash/last_seq`; **init from tail** (ignore trailing partial line w/ one WARN); compute `event_hash` over canonical payload (excl. `prev_hash`).
* **Merkle DIGEST** every **100** events; **Ed25519 sign** each DIGEST (default ON).
* **Startup policy**: if signing enabled and `GEODE_AUDIT_PUB/SEC` missing → **exit with `CONFIG_ERROR SIGNING_KEYS_MISSING`**. For `-Dtest`, derive deterministic test key.
* Hooks in `src/server/graph/exec.zig` after success of `addNode`, `addEdge`, `setNodeProperty`, `setEdgeProperty`.
* Rotation/retention: default 90 days; configurable ≥ 365; **continue seq_no** and carry `prev_hash` across files.
* Guard `stdout` print in `audit.zig` **~line 154** behind debug flag.
* Verification CLI `src/cli/geode_audit_verify.zig` with exact outputs/exit codes below.
* Update `build.zig`; author `docs/AUDIT_LOGGING.md` (AU‑3/AU‑9/PCI mapping).
* Crypto manager (`src/storage/crypto_enhanced.zig`): log key events via main audit stream.

**Standards & Constraints**

* Zig **0.15.1**, Linux (glibc); std crypto only (SHA‑256 default; optional BLAKE3; Ed25519). FS perms `0600`.
* Performance target: append ≤ 500 µs/event (ex‑fsync); deterministic I/O.
* Security: redact PII when configured; **no secrets in logs**. **Signing: ON by default**.
* License MIT; RSS ≤ 512 MiB.

**Interfaces & Exact Outputs**

* Canonical JSON key order and record schemas as specified above.
* Functions: `writeCanonicalJson`, `computeEventHash`, `appendAuditEvent`, `initFromTail`, `verifyFile`.
* **CLI outputs & exit codes:**

  * `OK chain ✅  records=<N> digests=<D> algo=<sha256|blake3>` → **0**
  * `TAMPER chain ❌  at_seq=<s> reason=PREV_HASH_MISMATCH expected=<hex> got=<hex>` → **3**
  * `TAMPER digest ❌  at_seq=<s> reason=DIGEST_MISMATCH expected=<hex> got=<hex>` → **4**
  * `SCHEMA_ERROR ❌  at_seq=<s> field=<name> detail=<msg>` → **2**
  * `WARN ignored trailing partial record` (non‑fatal)
  * Startup (non‑test) missing keys: `CONFIG_ERROR SIGNING_KEYS_MISSING` → **78**

**Tests (Acceptance)** — runnable via `zig build test -Doptimize=ReleaseSafe`

1. **Happy path**: 3 events + 1 digest; verify with `--pubkey`; expect `OK chain …` (records=4, digests=1), exit 0.
2. **Prev‑hash tamper**: flip a byte; expect `TAMPER chain …`, exit 3.
3. **Truncation/digest mismatch**: anchor digest #2; truncate; verify `--require-digest`; expect `TAMPER digest …`, exit 4.
4. **Invalid schema**: missing `event_type`; expect `SCHEMA_ERROR …`, exit 2.
5. **Config error**: non‑test build with missing keys → `CONFIG_ERROR SIGNING_KEYS_MISSING`, exit 78.

**Run Instructions**

* **Build:** `zig build -Drelease-safe`
* **Verify:** `zig build geode-audit-verify -- --file /var/log/geode/audit.jsonl --algo sha256 --pubkey $GEODE_AUDIT_PUB`
* **Env (non‑test):** `GEODE_AUDIT_PUB={{ED25519_PUB_HEX}}`, `GEODE_AUDIT_SEC={{ED25519_PRIV_HEX}}`.

**Design Rationale (≤7 bullets)**

* AU‑3 content preserved; AU‑9 protection via **hash chain + Merkle + signatures**.
* **Canonical JSON** ensures deterministic hashing/verifiability.
* **Digest‑only signing** balances overhead and non‑repudiation; default ON for stronger assurance.
* **Fail‑closed** key policy avoids silent loss of signing guarantees.
* **Append‑only** fs policy + chain continuity over rotations.
* **Tail recovery** tolerates partial writes without corrupting the chain.
* Hooks at mutation boundaries capture CREATE/UPDATE with minimal coupling. 

---

## Context Package (for the coding LLM)

**Assumptions**: Digest=100; SHA‑256 default (BLAKE3 optional); **signing ON by default (digest‑only)**; retention 90 days configurable ≥ 365; hooks at `addNode/addEdge` + property setters; Zig 0.15.1/Linux. 

**Acceptance tests**: 5 cases and exact outputs as listed.
**Run cmds**: `zig build`, `zig build test -Doptimize=ReleaseSafe`, `zig build geode-audit-verify -- --file … --algo sha256 --pubkey …`.
**File tree (minimum)**:

```
src/security/rls.zig            # modified (~line 1020)
src/security/audit.zig          # modified (~line 154 guarded print + core)
src/server/graph/exec.zig       # modified (hooks)
src/storage/crypto_enhanced.zig # modified (key events via main audit)
src/cli/geode_audit_verify.zig  # new (verifier)
docs/AUDIT_LOGGING.md           # new (compliance/ops)
build.zig                       # modified (cli/tests)
tests/test_audit_chain.zig      # new (acceptance tests)
```

(Anchors & requirements are from your design doc.) 
