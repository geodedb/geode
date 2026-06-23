<!-- SPDX-License-Identifier: Apache-2.0 -->

# geode — FIPS support design (2026-06-23)

**Status:** approved design (brainstorming) → next: implementation plan.
**Worktree:** external `geode-fips-wt` on branch `feat/fips` (isolated; many
other agents are active in the main tree + several worktrees).
**Scope:** large — Zig (~150 approved crypto sites + ~110 non-approved) AND a
Go 1.24 module. Will be implemented in phases.

## Goal

Add a `-Dfips` build mode to `geode` that routes all approved security crypto
through the OpenSSL FIPS-140-3 validated provider (via the `fips` seam), and
**removes/fails-closed every non-approved mechanism** under FIPS. The default
(`-Dfips=false`) build is unchanged (`std.crypto`, no OpenSSL). Plus: enable
Go 1.24 native FIPS mode for the Go components. Both modes stay green.

## Core principle (per user directive)

- **Approved crypto** (SHA-2/3, HMAC, HKDF, AES-GCM, ECDSA/RSA/Ed25519,
  ML-* PQC) → routed through the `crypto_backend` seam.
- **Non-approved mechanisms are REMOVED / fail-closed under `-Dfips=true`,
  NOT swapped.** Affected (current counts): argon2id (60), BLAKE2 (23),
  BLAKE3 (9), ChaCha20 (8), Poly1305 (7), SHA-1 (7). Under FIPS these paths
  must `@compileError` (when the algorithm is comptime-known) or return
  `error.FipsUnsupported` (runtime), with **callers handling the error**.
  Consequence (accepted): **FIPS-mode geode cannot do argon2id password
  hashing, BLAKE hashing, or ChaCha/Poly1305 AEAD** — those features are
  unavailable under FIPS and fail loudly rather than silently downgrading.
- Call sites import `crypto_backend`, never `std.crypto` in a security path.

## Mechanism — the seam

1. Vendor `crypto_backend.zig` + `std_shim.zig` + `policy.zig` into `src/`
   (byte-identical to the `fips` repo). Add a vendored `link.zig` (OpenSSL
   dynamic-link helper) or reuse the fips package's.
2. `build.zig`: add `-Dfips` option; thread it into the **single** existing
   `build_options` module (`build.zig:670`, GAP-0020 rule preserved) via
   `addOption(bool, "fips", fips)`. Add the lazy `fips` dep:

   ```zig
   .fips = .{ .url = "git+https://gitlab.com/devnw/zig/fips.git#v0.1.0",
              .hash = "fips-0.1.0-1wf3nbxWBgAp6yAk6cPRrF5l_U1tbblcVcN9xcjJDddy",
              .lazy = true },
   ```

   `b.lazyDependency("fips", ...)` + `linkOpenssl` (dynamic) onto crypto
   compile units under `-Dfips=true`.
3. `crypto_backend` selects `@import("fips")` vs local `std_shim` at comptime.

## Zig routing (approved → seam)

Central modules first, then the security subsystem:

- `src/types/cryptographic.zig` (~23 pub fns) and `src/types/hash.zig`
  (~11 pub fns) — the crypto/hash cores. Route SHA-2 hashing, HMAC, HKDF,
  AES-256-GCM, Ed25519, `timing_safe.eql`→`crypto_backend.timingSafeEql`,
  `secureZero`→`crypto_backend.secureZero`.
- `src/security/*` subsystem: `tde_key_manager`, `key_provider`, `kms`,
  `kms_remote`, `key_rotation`, `tde`, `tde_nonce_gen`, `tde_file_encryption`,
  `user_management`, `geode_auth_lib`, `auth_graph_manager` — route their
  AES-GCM / HKDF / HMAC / Ed25519 / hashing through the seam.
- `src/keys/manager.zig`, `src/storage/{backup,tde_file_encryption}.zig`,
  `src/server/quic_connection_handler.zig`, `src/transport/*`,
  `src/execution/audit_dispatch.zig`, `src/cli/user_storage_secure.zig`.
- **CSPRNG:** security uses of `std.crypto.random` → `crypto_backend.Csprng`
  (SP 800-90A DRBG under FIPS). Non-security uses (jitter/backoff/hashmap
  seeds) stay and are annotated `// fips-exempt: non-security`. (Many sites
  already migrated to a `getrandom` shim per in-file comments — fold those
  into the seam Csprng for security uses.)

## Zig fail-closed (non-approved → removed under FIPS)

For each non-approved mechanism, gate under `build_options.fips`:

- **argon2id** (password hashing — `geode_auth_lib`, `user_management`,
  `auth_graph_manager`, `user_storage`, `rls_core`, `types/hash.zig`,
  `cli/user_*`): under FIPS, the argon2 code path is `@compileError`
  (preferred, comptime) or returns `error.FipsUnsupported`. Callers (login,
  user-create, credential verify) propagate the error. Add a clear message
  ("argon2id password hashing is not available under FIPS").
- **BLAKE2 / BLAKE3** (hashing/integrity): under FIPS, security uses
  `@compileError`/`error.FipsUnsupported`; genuinely non-security integrity
  uses (if any) must be re-justified or moved to SHA-2 — default to
  fail-closed unless explicitly annotated non-security.
- **ChaCha20 / Poly1305** (AEAD): fail-closed under FIPS (AES-GCM is the
  approved AEAD; but per the directive we REMOVE ChaCha rather than auto-swap
  — callers must select an approved AEAD explicitly).
- **SHA-1**: fail-closed under FIPS.
- Each gate has a test asserting the FIPS build rejects the mechanism
  (`@compileError` proven via a `-Drepro`-style negative build, or
  `expectError(error.FipsUnsupported, ...)`).

## Go side (Go 1.24, test-only crypto)

geode's Go crypto is **test-only** (the `crypto/tls`/`x509`/`rsa` uses are all
in `tests/quic_tests/*.go` interop harnesses; no production Go crypto found).

- Enable Go 1.24 **native FIPS mode** for the Go build/test path: set
  `GODEBUG=fips140=on` (or `GOFIPS140=latest`) in the Makefile/CI Go test
  targets so the standard library uses the Go Cryptographic Module.
- Verify the quic-interop harnesses build + run (or are explicitly gated)
  under FIPS mode; confirm no non-approved algorithm usage in Go under FIPS.
- Document the toggle. (No production Go routing required.)

## Testing

- **Dual-mode gate** (`make test-dual`-style): `-Dfips=false` (shim) AND
  `-Dfips=true -Dopenssl_path=/usr/local/ssl` (OpenSSL FIPS) green.
- **KATs** for the seam-routed approved crypto in the central modules.
- **Fail-closed tests**: assert argon2id / BLAKE / ChaCha / SHA-1 paths
  error or `@compileError` under FIPS.
- **Go FIPS verification**: the Go test target runs under `GODEBUG=fips140`.

## Phasing (single repo, multiple plan phases)

1. Seam scaffolding + build wiring + lazy fips dep + dual-mode skeleton.
2. Route central modules (`types/cryptographic.zig`, `types/hash.zig`).
3. Route the `security/*` subsystem.
4. Fail-close the non-approved set (argon2/blake/chacha/sha1) + caller error
   handling.
5. CSPRNG security-use routing.
6. Go 1.24 FIPS wiring + verification.
7. Dual-mode + fail-closed + Go test gates green; CI job.

## Execution

All work in the `geode-fips-wt` worktree; commit on `feat/fips`. Do NOT touch
the main tree or the other active worktrees. Push the branch when green
(no merge to main without user direction). Given the size, implement via
subagents per phase/subsystem, each verifying the dual-mode build.
