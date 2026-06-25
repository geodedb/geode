# geode FIPS Support — Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax. Work ONLY in the worktree (`geode-fips-wt`, branch `feat/fips`) for geode, and in the local `fips` repo at `/home/benji/src/devnw/zig/fips` for Task 0. Never touch geode's main tree or the other active geode worktrees.

**Goal:** Add a `-Dfips` build mode to geode where ALL security crypto EXECUTES inside the certified OpenSSL FIPS-140-3 module (via the `fips` seam), every non-FIPS algorithm fails closed, and Go components run under Go 1.24 FIPS mode — while the default `-Dfips=false` build is unchanged (`std.crypto`, no OpenSSL).

**Architecture:** Vendor the seam (`crypto_backend`/`std_shim`/`policy`/`link`) into geode `src/`; thread `-Dfips` through the single `build_options`; route every security primitive through the seam → OpenSSL FIPS; fail-close the algorithms the FIPS module doesn't implement; enable Go FIPS for the Go build/test. One seam extension (HMAC-SHA1 for TOTP) is needed first.

**Tech Stack:** Zig 0.16.0, OpenSSL 3.x FIPS provider (`/usr/local/ssl`), the `fips` package, Go 1.24.

## Global Constraints

- **FIPS compliance = execution in the validated module.** Under `-Dfips=true`, EVERY security primitive routes through `crypto_backend` → OpenSSL FIPS. A FIPS-approved algorithm running on `std.crypto` is NOT compliant. NO security primitive stays on `std.crypto` under fips.
- `// fips-exempt: non-security` is permitted ONLY for genuinely non-security randomness (UUID v7, sharding ids, jitter/backoff, query-eval seeds, test-only). Never for a security primitive.
- **Seam coverage (verified in fips@policy.zig):** the seam already covers SHA-256/384/512, SHA3-256/384/512, AES-128/256-GCM, HKDF, PBKDF2, HMAC-SHA256/384/512 AND HMAC-SHA3-256/512 (`Mac.hmac` takes a `policy.Hash`, which includes the SHA-3 digests), ECDSA-P256/P384/P521, RSA-PSS/PKCS1 (explicit SHA-2 digest), Ed25519, ML-DSA/SLH-DSA, the SP800-90A DRBG, `secureZero`, `timingSafeEql`. The ONLY gap is **HMAC-SHA1** (Task 0 adds it).
- **Fail-closed under `-Dfips` (FIPS module does not implement these): argon2id, BLAKE2b/2s, BLAKE3, ChaCha20-Poly1305.** `@compileError` where the algorithm is comptime-known; `error.FipsUnsupported` where selected at runtime. Callers propagate. CONSEQUENCE (spec-accepted): FIPS-mode geode cannot do argon2id password auth, BLAKE hashing, or ChaCha/Poly1305 AEAD.
- **TOTP HMAC-SHA1 is routed, not skipped** — HMAC-SHA1 is an approved MAC inside the FIPS module; it routes through the seam (Task 0 + Task 6). Bare SHA-1 (hashing/signatures) remains barred. SHA-1 SigV2 and MD5 are already removed from geode (comments confirm).
- **fips dep (interim, GitLab outage):** geode pins a LOCAL `.path` fips pointing at `/home/benji/src/devnw/zig/fips` (the extended seam). When GitLab is restored, publish `fips` v0.1.1 (with the HMAC-SHA1 addition) and repin geode to the `git+https#v0.1.1` form. (geode-client-zig stays on published v0.1.0 — it doesn't need HMAC-SHA1.)
- ONE `build_options` module only (geode build.zig:651 `addOptions()` → :670 `createModule()`); thread `-Dfips`/`-Dopenssl_path` into it. geode ALREADY has an `enable_openssl` option + ssl/crypto/dl linking at build.zig:855-862 — integrate with it, do not create a second build_options.
- Both modes green: `-Dfips=false` (std_shim) AND `-Dfips=true -Dopenssl_path=/usr/local/ssl` (OpenSSL FIPS; set `OPENSSL_CONF=/usr/local/ssl/ssl/openssl.cnf`). Commit per task on `feat/fips`. Commit-body trailer: `Co-Authored-By: Claude Opus 4.8 (1M context) <noreply@anthropic.com>`. Re-stage+re-commit if a pre-commit hook auto-fixes files. Do NOT push (GitLab down; work lands locally).
- During the outage, do NOT run commands that fetch from gitlab.com for NEW artifacts; the existing geode dep cache + the local `.path` fips resolve offline.

---

### Task 0: Extend the fips seam — add a narrow FIPS HMAC-SHA1 path (local fips repo)

**Files (in `/home/benji/src/devnw/zig/fips`, NOT the geode worktree):**
- Modify: `src/mac.zig` (add `hmacSha1`), `src/std_shim.zig` (add `Mac.hmacSha1`), `templates/crypto_backend.zig` if it needs to re-export (verify), `src/policy.zig` (add a SHA-1 EVP-name helper used ONLY by the HMAC path — do NOT add `sha1` to the `Hash` enum)
- Test: a KAT test in the fips repo

**Interfaces:**
- Produces: `Mac.hmacSha1(key: []const u8, msg: []const u8, out: []u8) Error!usize` — HMAC-SHA1, available in BOTH backends (OpenSSL FIPS provider's HMAC+SHA-1 under fips; `std.crypto.auth.hmac.HmacSha1` in std_shim). `out` must be ≥ 20 bytes; returns 20.

- [ ] **Step 1 — fips backend (`src/mac.zig`).** Add a `hmacSha1` fn to the `Mac` struct that calls the OpenSSL EVP HMAC path with digest name `"SHA-1"` (reuse the existing `Mac.hmac` FFI plumbing; pass the SHA-1 EVP_MD). Do NOT widen the `Hash` enum (keep bare SHA-1 barred). Add an internal SHA-1 EVP-name constant local to the HMAC path.

- [ ] **Step 2 — std_shim backend (`src/std_shim.zig`).** Add the matching `Mac.hmacSha1` using `std.crypto.auth.hmac.HmacSha1` (the standard-library HMAC-SHA1). Same signature/return.

- [ ] **Step 3 — KAT test.** Add a test asserting `Mac.hmacSha1` matches RFC 2202 HMAC-SHA1 Test Case 2 (key `"Jefe"`, data `"what do ya want for nothing?"`, mac `effcdf6ae5eb2fa2d27416d5f184df9c259a7c79`). It must pass under both backends (`zig build test` and `zig build test -Dfips=true -Dopenssl_path=/usr/local/ssl`).

- [ ] **Step 4 — Verify both backends.** `zig build test` and `OPENSSL_CONF=/usr/local/ssl/ssl/openssl.cnf zig build test -Dfips=true -Dopenssl_path=/usr/local/ssl` green in the fips repo.

- [ ] **Step 5 — Commit (local only, do NOT push — outage):** in the fips repo, `feat(mac): add FIPS HMAC-SHA1 path for RFC 6238 TOTP consumers`. This commit is the source the geode `.path` dep + later v0.1.1 publish will carry.

---

### Task 1: geode seam scaffolding + `-Dfips` build wiring + local-path fips + smoke test

**Files:**
- Create: `src/crypto_backend.zig`, `src/std_shim.zig`, `src/policy.zig`, `src/link.zig` (copy from the EXTENDED local fips repo: `/home/benji/src/devnw/zig/fips/{templates/crypto_backend.zig,src/std_shim.zig,src/policy.zig,src/link.zig}` — these now include `Mac.hmacSha1`)
- Modify: `build.zig` (`-Dfips`/`-Dopenssl_path` options near :651-670; `crypto_backend` module; linkOpenssl), `build.zig.zon` (local `.path` fips dep)
- Test: `src/crypto_backend_smoke_test.zig`

**Interfaces:** Produces a `crypto_backend` module importable by geode `src/` modules, re-exporting `Hash`/`Aead`/`Mac` (incl. `hmacSha1`)/`Kdf`/`Sig`/`Csprng`/`policy`/`secureZero`/`timingSafeEql`/`assertActive`.

- [ ] **Step 1 — Vendor the 4 seam files** from the extended local fips repo paths above. Open each to confirm imports (`crypto_backend` imports `build_options`, `std_shim`, and under fips `fips`; `std_shim` imports sibling `policy`).
- [ ] **Step 2 — Add options.** In `build.zig` near the other options (~:651-669) add `const fips = b.option(bool, "fips", "Route security crypto through the OpenSSL FIPS provider") orelse false;` and `const openssl_path = b.option([]const u8, "openssl_path", "OpenSSL FIPS prefix");` and `build_opts.addOption(bool, "fips", fips);` BEFORE `build_opts.createModule()` (:670).
- [ ] **Step 3 — Local `.path` fips dep.** In `build.zig.zon` add `.fips = .{ .path = "<relative-path-from-geode-build-root-to /home/benji/src/devnw/zig/fips>" }` (compute the build-root-relative path; verify with `zig build --fetch`). NOT lazy for the interim path form (path deps can't be lazy-fetched the same way) — OR keep `.lazy = true` if it resolves; verify. Comment that this is the outage interim, to become `git+https#v0.1.1` later.
- [ ] **Step 4 — crypto_backend module + linkOpenssl.** Build `std_shim` + `crypto_backend` modules (import `build_options` + `std_shim`); under `if (fips)`, `crypto_backend_mod.addImport("fips", <fips dep>.module("fips"))` + `link.linkOpenssl(b, crypto_backend_mod, openssl_path)`. Integrate with the existing `enable_openssl` block (:855-862) — when `-Dfips`, force the OpenSSL link to the FIPS prefix. Add `crypto_backend` import to the smoke-test target.
- [ ] **Step 5 — Smoke test** `src/crypto_backend_smoke_test.zig`: assert `cb.Hash.digest(.sha256, "abc", &out)` == the known SHA-256("abc") vector AND `cb.Mac.hmacSha1(...)` works. Wire into the test step.
- [ ] **Step 6 — Verify both modes.** `zig build test -Dfips=false` and `OPENSSL_CONF=/usr/local/ssl/ssl/openssl.cnf zig build test -Dfips=true -Dopenssl_path=/usr/local/ssl` PASS.
- [ ] **Step 7 — Commit:** `feat(fips): vendor crypto_backend seam + wire -Dfips (local-path fips interim)`.

---

### Task 2: Route `src/types/cryptographic.zig` (signatures, HMAC, timing-safe, secureZero)

**Files:** Modify `src/types/cryptographic.zig`; `build.zig` (add `crypto_backend` to its module + linkOpenssl coverage)

- [ ] **Step 1 — Signatures.** Route `Signature.verify` (:153), `KeyPair.generate` (:291), `KeyPair.sign` (:357) for Ed25519 (:298,368), ECDSA-P256 (:316,391), ECDSA-P384 (:331,424) through `cb.Sig` (`policy.SigAlg.ecdsa_p256/.ecdsa_p384/.ed25519`). For RSA-PSS-SHA256/512 verify, use `cb.Sig.verifyRsa(.pss, digest, ...)` with the explicit SHA-2 digest. Verify the exact `cb.Sig` API in the vendored source; adapt.
- [ ] **Step 2 — HMAC.** `Hmac.compute` (:496)/`verify` (:535): SHA-256→`cb.Mac.hmac(.sha256,...)`, SHA-512→`.sha512`, SHA3-256→`.sha3_256`, SHA3-512→`.sha3_512` (all via `cb.Mac.hmac(policy.Hash, key, msg, out)`).
- [ ] **Step 3 — Utilities.** `std.crypto.timing_safe.eql` (:543,544)→`cb.timingSafeEql`; `std.crypto.secureZero` (:461,562)→`cb.secureZero`.
- [ ] **Step 4 — Verify both modes** (the module's tests + dependents compile/run). Commit: `feat(fips): route types/cryptographic.zig through the seam`.

---

### Task 3: `src/types/hash.zig` — route SHA-3 (approved), fail-close BLAKE2/3 + argon2

**Files:** Modify `src/types/hash.zig`

- [ ] **Step 1 — Route approved.** `hash()` (:18) SHA3-256 (:22)/SHA3-512 (:30) → `cb.Hash.digest(.sha3_256/.sha3_512, ...)`. `equals()` (:186) → `cb.timingSafeEql`.
- [ ] **Step 2 — Fail-close non-approved (runtime dispatch).** In `hash()` the BLAKE3 (:38), BLAKE2b-256 (:46), BLAKE2b-512 (:54), BLAKE2s-256 (:62), and ARGON2ID (:76-89) arms must, under `-Dfips` (`if (build_options.fips) return error.FipsUnsupported;`), reject before touching std.crypto. Same for `argon2idStrHash` (:102), `argon2idStrVerify` (:113), `blake2bKdf` (:201), `blake2sKdf` (:210). Add `FipsUnsupported` to the module `Error` set (:8-15).
- [ ] **Step 3 — Tests.** Add tests: under fips, SHA3 hashing routes (KAT); BLAKE2/3 + argon2 calls return `error.FipsUnsupported`. Under shim, all behave as before. Verify both modes. Commit: `feat(fips): route SHA-3 + fail-close BLAKE/argon2 in types/hash.zig`.

---

### Task 4: Route the security TDE/KMS cluster

**Files:** Modify `src/security/{tde_key_manager,key_provider,kms,kms_remote,key_rotation,tde,tde_nonce_gen}.zig`; `build.zig` (crypto_backend import + linkOpenssl for the security module(s))

- [ ] **Step 1 — Route approved primitives to `cb`** in each file (verify exact lines from the diff; the map):
  - `tde_key_manager.zig`: SHA-256 (:197,250,262,274,301,309,562,570,590,597)→`cb.Hash`, HMAC-SHA256 (:198,648)→`cb.Mac.hmac(.sha256,...)`, AES-256-GCM (:427,431)→`cb.Aead.{seal,open}(.aes_256_gcm,...)`, secureZero (:680,718,724,766)→`cb.secureZero`.
  - `key_provider.zig`: SHA-256 (:88,184,214), HKDF (:106-107,131-132)→`cb.Kdf.hkdf(.sha256,...)`, AES-256-GCM (:117,144,148), secureZero (:111,136,143,150).
  - `kms.zig`: HKDF (:179-180,210-211), AES-256-GCM (:193,221), secureZero (:235,240). `kms_remote.zig`: route its AES-GCM/HKDF/HMAC similarly (read the file).
  - `key_rotation.zig`: SHA-256 (:383,574), AES-256-GCM (:635).
  - `tde.zig`: SHA-256 (:345,881,895), Ed25519 (:1177, test), secureZero (:1047,1466).
  - `tde_nonce_gen.zig`: secureZero (:76,98) → `cb.secureZero`. (Its random nonce fill is handled in Task 9.)
- [ ] **Step 2 — Verify both modes; commit:** `feat(fips): route security TDE/KMS cluster through the seam`.

---

### Task 5: Route storage / keys / audit / misc

**Files:** Modify `src/storage/{tde_file_encryption,backup}.zig`, `src/keys/manager.zig`, `src/execution/audit_dispatch.zig`, `src/server/quic_connection_handler.zig`, `src/cli/user_storage_secure.zig`

- [ ] **Step 1 — Route approved primitives to `cb`:**
  - `storage/tde_file_encryption.zig`: HMAC-SHA256 (:297-298)→`cb.Mac`, secureZero (:323), AES-GCM (via the encrypt/decrypt paths). `storage/backup.zig`: AES-256-GCM (:791,820).
  - `keys/manager.zig`: SHA-256 (:40), secureZero (:34,97,100,107,126,133).
  - `execution/audit_dispatch.zig`: SHA-256 (:475,617,652)→`cb.Hash`, Ed25519 generate/verify (:518,560)→`cb.Sig`.
  - `server/quic_connection_handler.zig`: secureZero (:2453,5370,5627,5673)→`cb.secureZero`.
  - `cli/user_storage_secure.zig`: AES-256-GCM (:401)→`cb.Aead`. (Its argon2 at :456-462 is fail-closed in Task 7.)
- [ ] **Step 2 — Verify both modes; commit:** `feat(fips): route storage/keys/audit crypto through the seam`.

---

### Task 6: Route TOTP HMAC-SHA1 through the seam

**Files:** Modify `src/security/mfa_risk.zig`

- [ ] **Step 1 — Route.** Replace the local `hmacSha1` impl (:226-253, which uses `std.crypto.hash.Sha1`) and its caller (`computeTotpCode` :167) with `cb.Mac.hmacSha1(counter_be, secret_raw, &out)`. This routes TOTP through OpenSSL FIPS HMAC-SHA1 under `-Dfips`. Remove the now-unused `std.crypto.hash.Sha1` import. Annotate: `// FIPS: HMAC-SHA1 is an approved MAC; routed through the validated module (not bare SHA-1).`
- [ ] **Step 2 — Test.** A TOTP RFC 6238 SHA-1 test vector must pass under BOTH modes. Verify. Commit: `feat(fips): route TOTP HMAC-SHA1 through the FIPS seam`.

---

### Task 7: Fail-close password hashing (argon2id) + legacy BLAKE2b

**Files:** Modify `src/security/geode_auth_lib.zig`, `src/security/user_management.zig`, `src/cli/{user_mgmt_cli,user_storage_secure,user_storage_simple}.zig`

- [ ] **Step 1 — Fail-close the argon2 paths under fips.** `geode_auth_lib.hashPasswordArgon2id` (:1745) and `verifyPasswordArgon2id` (:1805): `if (build_options.fips) return error.FipsUnsupported;` at entry. `verifyBlake2bLegacy` (:1180): same. The runtime dispatch in `verifyPassword` (:1146) keeps detecting format but both branches now error under fips. CLI argon2 in `user_storage_secure.zig` (:456) and `user_storage_simple.zig` (:309) gated likewise.
- [ ] **Step 2 — Caller handling.** `hashPassword` (:1115), `authenticate` (:1552/:1595), `authenticateMfa` (:1655/:1678), `createUserDetailed` (:1219), `user_management.hashPassword`/`verifyPassword` (:452/:459) propagate `error.FipsUnsupported` with a clear log/audit ("password hashing unavailable under FIPS"). `user_mgmt_cli.importUser` (:379) algorithm validation rejects `argon2id` AND `blake2b` under fips.
- [ ] **Step 3 — Tests.** Under fips: hash/verify password → `error.FipsUnsupported`; under shim: unchanged. Verify both modes. Commit: `feat(fips): fail-close argon2id/BLAKE2b password hashing under FIPS`.

---

### Task 8: Fail-close ChaCha20-Poly1305

**Files:** Modify `src/fle_integration.zig`, `src/transport/quic_parallel_serial.zig`, `src/admin/fle_commands.zig`

- [ ] **Step 1 — Fail-close at the AEAD selection.** `fle_integration.encryptField` (:485): when the algorithm enum is `chacha20_poly1305`, `if (build_options.fips) return error.FipsUnsupported;` (and the decrypt counterpart). `transport/quic_parallel_serial.headerProtectMask` (:304): under fips, the ChaCha20 header-protection path errors (AES header protection is the FIPS path — verify QUIC uses AES-based HP under fips, else fail-close). `admin/fle_commands.parseFleCreate` (:250): reject selecting chacha20 under fips.
- [ ] **Step 2 — Caller handling + tests.** Callers propagate. Under fips: selecting ChaCha → `error.FipsUnsupported`; AES-GCM FLE still works. Verify both modes. Commit: `feat(fips): fail-close ChaCha20-Poly1305 under FIPS`.

---

### Task 9: Route security CSPRNG to the FIPS DRBG

**Files:** Modify the SECURITY `compat_fillRandom`/getrandom sites; annotate non-security ones

- [ ] **Step 1 — Route security randomness.** Replace the `compat_fillRandom`/getrandom calls that produce KEY/NONCE/SALT/SEED material with `cb.Csprng.bytes(buf)` (OpenSSL FIPS DRBG under fips): `types/cryptographic.zig:297` (Ed25519 seed), `security/tde_nonce_gen.zig:71,89` (AES-GCM nonce), `storage/tde_file_encryption.zig` (file nonce), `storage/backup.zig` (backup nonce), `execution/audit_dispatch.zig:518/857` (signing key + TOTP/recovery secrets), `keys/manager.zig`, `security/key_provider.zig`/`kms.zig` salt gen. Verify each is a security path.
- [ ] **Step 2 — Annotate non-security.** Add `// fips-exempt: non-security` to `storage/id_map.zig` (UUID v7), `distributed/sharding.zig` (shard ids), `types/evaluator_functions.zig` (query seed), `distributed/raft_consensus.zig` (jitter), `index/*` test seeds — these stay on getrandom.
- [ ] **Step 3 — Tests + verify both modes.** Commit: `feat(fips): route security CSPRNG to the FIPS DRBG; annotate non-security`.

---

### Task 10: Go 1.24 FIPS wiring

**Files:** Modify `Makefile` (Go targets), add a Go test target; docs

- [ ] **Step 1 — Enable Go FIPS.** In the Makefile, set `GOFIPS140=latest` (and/or `GODEBUG=fips140=on`) for the `go build` of canaryscan (:739) and add a `go-test-fips` target that runs the `tests/quic_tests` under `GODEBUG=fips140=on`. go.mod is `go 1.24.0` (supports native FIPS).
- [ ] **Step 2 — Verify.** Confirm the quic-interop Go harnesses build (and run, if runnable in this env) under FIPS mode; their crypto (`crypto/tls` TLS 1.3, `crypto/rand`, `crypto/rsa`, `crypto/x509`) is FIPS-approved. Confirm no production `.go` uses crypto (canaryscan is crypto-free). Document the toggle in the README.
- [ ] **Step 3 — Commit:** `feat(fips): enable Go 1.24 FIPS mode for Go build/test`.

---

### Task 11: Dual-mode gate + fail-closed tests + KATs + docs + CI

**Files:** Modify `Makefile`, create `src/fips_parity_test.zig` + `src/fips_failclosed_test.zig`, `README.md`/docs, `.gitlab-ci.yml`

- [ ] **Step 1 — Parity/KAT test** (`src/fips_parity_test.zig`): assert via `cb` the known answers for SHA-256, SHA3-256, HMAC-SHA256, **HMAC-SHA1 (RFC 2202 TC2)**, AES-256-GCM round-trip+tamper, HKDF-SHA256, and an Ed25519 + an ECDSA-P256 + an RSA-PSS sign/verify round-trip. Passes under both backends.
- [ ] **Step 2 — Fail-closed test** (`src/fips_failclosed_test.zig`): under `-Dfips=true`, assert argon2id hash/verify, BLAKE2b/BLAKE3 hash, and ChaCha20-Poly1305 selection each return `error.FipsUnsupported`. (Under shim they work.)
- [ ] **Step 3 — Makefile** `test-shim`/`test-fips`/`test-dual` targets (tabs; `.PHONY`), mirroring geode-client-zig's.
- [ ] **Step 4 — Docs.** README "FIPS Mode" section: `-Dfips=true -Dopenssl_path=...`, `make test-dual`, the Go FIPS toggle, and the EXPLICIT caveat that FIPS builds disable argon2id password auth / BLAKE hashing / ChaCha AEAD (those callers error). Note the local-path fips interim + the v0.1.1 repin follow-up.
- [ ] **Step 5 — CI.** Add a `.gitlab-ci.yml` dual-mode FIPS job (mirror the fips repo's pattern: provision the provider, run `make test-dual`), if the CI structure makes it low-effort; else note as follow-up.
- [ ] **Step 6 — Final gate.** `make test-dual` green. `grep -rn 'std\.crypto\.' src` shows ONLY the seam (`std_shim.zig`), `// fips-exempt: non-security` sites, and tests — ZERO security `std.crypto` in production paths. Commit: `test(fips): dual-mode gate + parity/fail-closed tests + docs`.

---

## Self-Review

- **Spec coverage:** seam + `-Dfips` (T1) ✓; HMAC-SHA1 seam gap (T0) ✓; route cryptographic.zig (T2) ✓; hash.zig SHA-3 route + BLAKE/argon2 fail-close (T3) ✓; security/storage routing (T4,T5) ✓; TOTP routing (T6) ✓; argon2 fail-close (T7) ✓; ChaCha fail-close (T8) ✓; CSPRNG→DRBG (T9) ✓; Go FIPS (T10) ✓; dual-mode/fail-closed/KAT/docs/CI (T11) ✓. Every spec section maps to a task.
- **"Route, don't skip" invariant:** T2/T4/T5/T6/T9 route ALL security primitives (incl. TOTP HMAC-SHA1 and the DRBG) through the seam; the only `std.crypto` left in production is the seam itself + annotated non-security randomness (T11 Step 6 enforces this).
- **Placeholders:** file:line targets come from the recon map; each task names exact files + the seam call to use. Implementers verify exact `cb` signatures against the vendored source (the seam API is stable from geode-client-zig).
- **Type consistency:** `cb` = `@import("crypto_backend")`; seam API: `Hash.digest(policy.Hash, msg, out)`, `Mac.hmac(policy.Hash, key, msg, out)`, `Mac.hmacSha1(key, msg, out)` (T0), `Aead.seal/open(.aes_256_gcm,...)`, `Kdf.hkdf(.sha256,...)`, `Sig.verify/sign(policy.SigAlg,...)` + `Sig.verifyRsa(.pss, digest,...)`, `Csprng.bytes(out)`, `secureZero([]u8)`, `timingSafeEql`. `error.FipsUnsupported` is the uniform fail-closed error.
