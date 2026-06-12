# Gap Register Closure (2026-06-10) Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Close every actionable gap in the 2026-06-10 register (`docs/GAP_ANALYSIS.md` GAP-0863..GAP-0890, plus open items in `docs/SECURITY_GAP_ANALYSIS.md`, `docs/QUALITY_GAP_ANALYSIS.md`, `docs/PERF_GAP_ANALYSIS.md`, `docs/GQL_GAP_ANALYSIS.md`, `docs/DISTRIBUTED_QUALITY_GAP_ANALYSIS.md`, and GAP-0514 Phase 6) with real code, tests, and docs — one commit per gap or sub-batch.

**Architecture:** Each task closes one Gap-ID (or one enumerated sub-batch of a roll-up gap) using TDD: write a failing test that proves the gap, implement the minimal fix, verify, commit. Where the register offers an "implement or trim/document" choice, this plan locks in the smallest honest option (noted per task). Blocked items (GAP-0256, GAP-0838) and explicitly deferred items (GAP-0873) get their state documented with explicit unblock steps. Doc-truth items (GAP-0864 and tracker updates) run LAST so docs reflect the final state.

**Tech Stack:** Zig 0.16, `zig build` / `zig build test-<name>` targets, `zig fmt`. Pre-commit does NOT compile Zig — always run `zig build` before committing Zig changes. `errdefer |err|` capture breaks on inferred error sets. Integration harness (`../geode-test-harness`) is out of scope for per-task verification; use repo-local `zig build test-*` targets.

**Baseline (verified 2026-06-10):** `zig build` exit 0 at commit `a3a1f104`. Named-step baseline 167/175 (known FAIL: `test-perf`, `test-stream-pool-concurrent-lanes`, `test-perf-c-introspection-index`, `test-gpu`, `test-e2e`; known TIMEOUT: `test-cluster-3node-subprocess`, `test-all`). Sharded `zig build test` (CI=1 GEODE_SKIP_SUBPROC_CLUSTER=1, 4 shards) all green. Do NOT treat the 8 known-failing steps as new regressions — several are direct targets of this round.

**Conventions for every task (do not repeat per task):**
1. Read the named source files FIRST; follow existing code style, allocator patterns, and CANARY marker conventions (`// CANARY: REQ=... STATUS=...`).
2. TDD: failing test → run to confirm fail → minimal implementation → run to confirm pass → `zig build` (whole repo) → `zig fmt` touched files → commit.
3. Commit message format: `fix: close GAP-XXXX - <short title>` (or `docs:`/`test:`/`chore:`/`perf:` as appropriate). One commit per gap/sub-batch.
4. After closing a gap, append a one-line closure note to the journal `docs/superpowers/plans/2026-06-10-gap-closure-journal.md` (create on first use): `GAP-XXXX — closed/blocked/wont-do — commit <sha> — <one-line summary>`.
5. New test files go in `tests/` and must be wired into `build.zig` as a named test step (follow the existing `test-gap0838-cluster-tls` pattern).
6. Mutex acquisition must follow the lock-ordering table in CLAUDE.md (never hold a higher tier while acquiring a lower tier; timeseries `store_mutex` is a tier-7 leaf).
7. Work happens on branch `gap-closure-2026-06-10` (created in Task 0).
8. Honesty rule: NEVER mock or simulate behavior to make a test pass; NEVER paper-promote a CANARY marker. If a feature can't be implemented honestly in scope, the honest action is to gate/remove the claim and say so in the tracker.

---

## Pass 0 — Setup

### Task 0: Branch + journal

**Files:**
- Create: `docs/superpowers/plans/2026-06-10-gap-closure-journal.md`

- [ ] **Step 1:** `git checkout -b gap-closure-2026-06-10` from current main (`a3a1f104` or later).
- [ ] **Step 2:** Create the journal file with a header line `# Gap Closure Journal — 2026-06-10 round` and a `## Closure log` section.
- [ ] **Step 3:** Commit `chore: open 2026-06-10 gap-closure round (journal)`.

---

## Pass 1 — Test-gate fixes (GAP-0863, split into 4 sub-batches)

### Task 1: GAP-0863a — `graph_algos_stub` export + `test-e2e` compile repair

**Files:**
- Modify: `tests/e2e_graph_algos_new.zig` (line 2 imports `@import("geode").graph_algos_stub` — symbol not exported by `src/lib.zig`)
- Modify: `tests/e2e_tde_encryption.zig` (uses removed `std.time.milliTimestamp`)
- Modify: `fuzz/targets/txn_sequence_fuzz.zig`, `fuzz/targets/decimal_roundtrip_fuzz.zig` (old `testing.Smith` fuzz signature)
- Modify: bench targets `bench_federation_mismatch_*`, `bench_redo_optimization_delta` (compile failures; locate via `zig build test-e2e 2>&1 | head -100`)
- Read: `src/lib.zig`, `build.zig` (the `test-e2e` step definition)

- [ ] **Step 1:** Run `zig build test-e2e 2>&1 | head -120` and capture the full list of compile errors. This is the failing baseline.
- [ ] **Step 2:** For `e2e_graph_algos_new.zig`: decide export-vs-rewrite. Preferred: rewrite the test to use the real public API (`src/graph/algorithms.zig` entry points) instead of a stub — the stub API is itself flagged for removal by GAP-0883. If the test exercises nothing real, replace its body with calls into the real algorithms module over a small in-memory graph.
- [ ] **Step 3:** Fix Zig 0.16 migration errors: replace `std.time.milliTimestamp` with `std.time.timestamp()*1000` or `std.time.nanoTimestamp()` derived ms; update fuzz targets to the current `std.testing.fuzz` signature (check another working fuzz target in `fuzz/targets/` for the current pattern); fix bench target compile errors per compiler output.
- [ ] **Step 4:** `zig build test-e2e` — expect compile success; tests run (env-dependent subtests may skip). `zig build` PASS.
- [ ] **Step 5:** Commit `fix: close GAP-0863a - test-e2e compiles (graph_algos import, Zig 0.16 fuzz/bench migration)`.

### Task 2: GAP-0863b — FLE leak at `src/fle_integration.zig:469`

**Files:**
- Modify: `src/fle_integration.zig` (~line 469, `encryptFieldIfNeeded` → `key_manager.getFEK`; 3 allocations leaked)
- Verify via: `zig build test-perf-c-introspection-index`

- [ ] **Step 1:** Run `zig build test-perf-c-introspection-index 2>&1 | tail -40` — confirm the 3 leak reports point at `fle_integration.zig:469` (`getFEK` allocations).
- [ ] **Step 2:** Read `encryptFieldIfNeeded` and `key_manager.getFEK`: determine ownership of the returned FEK buffer. Fix by freeing/`defer`-freeing the FEK after use (or switching to a caller-provided buffer) — match how other `getFEK` call sites handle ownership.
- [ ] **Step 3:** `zig build test-perf-c-introspection-index` — expect exit clean, zero leaks. Run `zig build test-fle-*` steps (grep `build.zig` for fle test steps) — PASS.
- [ ] **Step 4:** Commit `fix: close GAP-0863b - free FEK in encryptFieldIfNeeded (3-alloc leak)`.

### Task 3: GAP-0863c — stream-pool lanes assertion

**Files:**
- Modify: `tests/test_stream_pool_concurrent_lanes.zig:236` (concurrency-observation assertion too strict)

- [ ] **Step 1:** Run `zig build test-stream-pool-concurrent-lanes 2>&1 | tail -30`; read the assertion at line 236 and what it observes (it asserts a minimum observed concurrency that depends on scheduler timing).
- [ ] **Step 2:** Fix honestly: keep a real assertion (the pool must demonstrate >1 concurrent lane at least once across N attempts with retries), but make it robust to scheduling variance — e.g., retry loop with deadline, or assert on the pool's own counters rather than wall-clock interleaving. Do NOT delete the assertion or mark the test skip-always.
- [ ] **Step 3:** Run the step 10x in a loop (`for i in 1..10`) — expect 10/10 PASS. `zig build` PASS.
- [ ] **Step 4:** Commit `fix: close GAP-0863c - robust concurrency observation in stream-pool lanes test`.

### Task 4: GAP-0863d — KNOWN_TEST_ISSUES refresh + verification-baseline note

**Files:**
- Modify: `docs/KNOWN_TEST_ISSUES.md`
- Modify: `docs/GAP_ANALYSIS.md` (GAP-0863 row)

- [ ] **Step 1:** Re-run the formerly-failing steps fixed in Tasks 1–3 plus `test-perf` and `test-gpu` (expected to still fail for host reasons). Update `docs/KNOWN_TEST_ISSUES.md`: remove fixed entries, keep host-relative residuals (`test-perf`, `test-gpu`, `test-cluster-3node-subprocess`) with current evidence. Note the new expected baseline (target: 171+/175).
- [ ] **Step 2:** Mark GAP-0863 Closed in the register with residuals named (harness run still owed — keep that as the one open residual, folded into the GAP-0864 doc language).
- [ ] **Step 3:** Commit `docs: close GAP-0863 - test-gate fixes landed, KNOWN_TEST_ISSUES rebaselined`.

---

## Pass 2 — Security correctness

### Task 5: GAP-0881 — HMAC-SHA3 construction + TDE status truth

**Files:**
- Modify: `src/types/cryptographic.zig:510-522` (HMAC-SHA3-256/512 currently SHA3(key||data))
- Modify: `src/security/tde.zig:118-121` (`loaded=true` with zero key_id without validating key material)
- Test: `tests/test_gap0881_crypto_truth.zig` (create), wire as `test-gap0881`

- [ ] **Step 1:** Read `cryptographic.zig:480-560`. Replace the placeholder with real HMAC per FIPS 198-1 (K xor ipad / K xor opad over SHA3) — note Zig's `std.crypto.auth.hmac.Hmac(std.crypto.hash.sha3.Sha3_256)` provides this generically; use stdlib, do not hand-roll.
- [ ] **Step 2:** Failing test with known-answer vectors: NIST HMAC-SHA3-256 test vectors (e.g., from RFC-style KATs; embed 2 vectors with key/data/expected-mac hex). Run `zig build test-gap0881` — expect FAIL against the old construction.
- [ ] **Step 3:** Implement; KATs PASS.
- [ ] **Step 4:** Read `tde.zig:100-140`. Failing test: TDE enabled but key manager has no loadable key → status must NOT report `loaded=true`; with a real key loaded → status reports `loaded=true` and a non-zero, non-secret key id. Implement: derive status from an actual key-manager load/validate call.
- [ ] **Step 5:** `zig build test-gap0881` PASS; existing TDE test steps PASS; `zig build` PASS. Commit `fix: close GAP-0881 - real HMAC-SHA3 + TDE status validates key material`.

### Task 6: GAP-0885a — SEC-SESS-LOG-01: session token printed to stderr

**Files:**
- Modify: `src/cli/session_cli.zig:569-570`
- Test: extend nearest session CLI test (grep `tests/` for `session_cli`) or create `tests/test_sec_sess_log.zig` wired as `test-sec-sess-log`

- [ ] **Step 1:** Read the `session rotate` output path. Failing test: capture the stderr/debug output of the rotate handler; assert the token value does NOT appear in stderr (it may go to stdout once, as the command's purpose — check how `session create` prints; match that contract).
- [ ] **Step 2:** Implement: remove/redact the stderr debug print of the token.
- [ ] **Step 3:** Test PASS; `zig build` PASS. Commit `fix: close SEC-SESS-LOG-01 - no session token on stderr after rotate`.

### Task 7: GAP-0885b — LSP-SEC-002 + LSP-SEC-005 + LSP-SEC-008 (LSP/MCP hardening batch)

**Files:**
- LSP-SEC-002: vendored MCP/LSP token compare — locate via `rg -n "std.mem.eql" src/mcp/ src/cli/lsp/` (auth token comparison sites); replace with `std.crypto.utils.timingSafeEql` (or current Zig equivalent `std.crypto.timing_safe.eql`)
- LSP-SEC-005: `publishDiagnostics` URI escaping in `src/cli/lsp/` (grep `publishDiagnostics`)
- LSP-SEC-008: hard-assert loopback bind when MCP/LSP auth mode is `.none` (grep `auth_mode` / `.none` in `src/mcp/server.zig`, `src/cli/lsp/server.zig`)
- Test: `tests/test_gap0885_lsp_hardening.zig` (create), wire as `test-gap0885-lsp`

- [ ] **Step 1:** For each of the three: read the site, write a failing assertion in the new test file (timing-safe compare: assert the comparison function used is the timing-safe one via behavior or by exporting the compare fn; URI escaping: feed a path with spaces/`#`/non-ASCII and assert the emitted URI is RFC-3986 percent-encoded; loopback assert: constructing server with auth `.none` + non-loopback bind must return error).
- [ ] **Step 2:** Implement all three smallest-fix changes.
- [ ] **Step 3:** `zig build test-gap0885-lsp` PASS; existing LSP/MCP steps PASS; `zig build` PASS. Commit `fix: close LSP-SEC-002/005/008 - timing-safe compare, URI escaping, loopback assert for .none auth`.

### Task 8: GAP-0885c — SEC-INFRA-03: cluster bearer token rotation

**Files:**
- Modify: `src/distributed/cluster_auth.zig:17-56`
- Test: `tests/test_sec_infra03_token_rotation.zig` (create), wire as `test-sec-infra03`

- [ ] **Step 1:** Read `cluster_auth.zig`. Design smallest honest rotation: support a primary + optional secondary (`GEODE_CLUSTER_TOKEN`, `GEODE_CLUSTER_TOKEN_PREVIOUS`); inbound accepts either during overlap; outbound always sends primary. This enables zero-downtime rotation.
- [ ] **Step 2:** Failing test: validator initialized with primary+previous accepts both, rejects a third value; with only primary, rejects previous. Run — FAIL (no secondary support today).
- [ ] **Step 3:** Implement; ensure constant-time compares for both tokens.
- [ ] **Step 4:** Test PASS; cluster auth existing tests PASS; `zig build` PASS. Document rotation procedure in `docs/security/MULTI_TENANT_HARDENING.md` or `docs/DISTRIBUTED_QUERY_COORDINATION.md` (wherever cluster token is documented; grep `GEODE_CLUSTER_TOKEN` in docs/). Commit `fix: close SEC-INFRA-03 - dual-token cluster bearer rotation`.

### Task 9: GAP-0885d — SEC-S3-SIGV2-01 + SEC-CLI-01 (S3 SigV4, insecure-TLS flag gating)

**Files:**
- Modify: `src/storage/s3_backup.zig:351-356` (SigV2 → SigV4)
- SEC-CLI-01: locate `--insecure-tls-skip-verify` handling via `rg -n "insecure-tls-skip-verify" src/`
- Test: `tests/test_s3_sigv4.zig` (create), wire as `test-s3-sigv4`

- [ ] **Step 1:** Read the S3 request signing path. Implement AWS SigV4 (canonical request, string-to-sign, HMAC-SHA256 signing key chain) using `std.crypto.auth.hmac.sha2.HmacSha256`. Keep the existing endpoint/credential plumbing.
- [ ] **Step 2:** Failing test with the official AWS SigV4 test-suite vector (the canonical `GET /?Param2=value2&Param1=value1` example from AWS docs — embed key/date/region/expected signature) asserting our signer produces the documented signature. FAIL first (SigV2 produces different output), then PASS.
- [ ] **Step 3:** SEC-CLI-01: gate `--insecure-tls-skip-verify` behind a build-mode or env check (refuse in release/production posture unless `GEODE_ALLOW_INSECURE_TLS=1` also set; print loud warning) — mirror the GAP-0850 startup-guard pattern (grep `insecure-allow-all` guard in `src/server/main.zig`).
- [ ] **Step 4:** Tests PASS; backup tests PASS; `zig build` PASS. Commit `fix: close SEC-S3-SIGV2-01 + SEC-CLI-01 - S3 SigV4 signing, gated insecure-TLS flag`.

### Task 10: GAP-0884 — MFA step-up operation classification

**Files:**
- Modify: `src/security/geode_auth_lib.zig:888-903` (`requireStepUp()` substring checks for `admin`/`write`)
- Test: `tests/test_gap0884_stepup_classification.zig` (create), wire as `test-gap0884`
- Docs: `docs/SERVER_FEATURES.md:1092-1110`, `docs/security/README.md:43`, `docs/MFA_SECURITY_IMPLEMENTATION.md:4`

- [ ] **Step 1:** Read `requireStepUp()` and its callers to learn what operation descriptors exist. Define an explicit `OperationClass` enum (read / write / admin / security_admin) and a classification function mapping the real operation identifiers (statement kinds / procedure names) — not substrings.
- [ ] **Step 2:** Failing negative tests: an operation named e.g. `read_admin_dashboard_summary` (contains "admin", is read-only) must NOT require step-up; a privileged op with a bland name (e.g. `geode.fle.configureField`) MUST. Run — FAIL under substring logic.
- [ ] **Step 3:** Implement classification; wire `requireStepUp` to it.
- [ ] **Step 4:** Docs: narrow adaptive/risk-based MFA claims (location/device/behavioral) to "planned"; keep what's real (TOTP, step-up on classified ops). Tests PASS; `zig build` PASS. Commit `fix: close GAP-0884 - explicit operation classification for MFA step-up`.

### Task 11: GAP-0890 — Key rotation policy wiring

**Files:**
- Modify: `src/security/key_rotation.zig:253-254` (`rotateNow()` discards `RotationPolicy`), `:540-548` (`scheduleRotation()` has no production caller)
- Test: `tests/test_gap0890_rotation_policy.zig` (create), wire as `test-gap0890`; replace stub `tests/benchmark_tde_key_rotate.zig:5-13`
- Docs: `docs/KMS_PROVIDER_SYSTEM.md:98,139,159`, `docs/SECURITY_PROGRESS.md:10`

- [ ] **Step 1:** Read `key_rotation.zig` fully. Smallest honest scope: make `rotateNow()` honor the policy it receives (interval/eligibility checks; refuse rotation when policy forbids), and wire `scheduleRotation()` into the server's existing periodic-task path (grep `src/server/` for an existing timer/periodic loop, e.g. the leaked-conn reaper) so a configured rotation interval actually triggers rotation.
- [ ] **Step 2:** Failing tests: (a) `rotateNow` with a policy whose `min_interval` hasn't elapsed returns policy-refused error; (b) scheduler invokes rotation callback after interval elapses (use injected clock if the module has one; otherwise add a `now_fn` parameter for testability).
- [ ] **Step 3:** Implement. Replace `benchmark_tde_key_rotate.zig` stub with a real micro-benchmark over an in-memory store rotating a real key (measure re-wrap latency; no simulated numbers).
- [ ] **Step 4:** Tests PASS; `zig build` PASS. Docs: keep "automated rotation" claim now that it's true; cite the test. Commit `fix: close GAP-0890 - rotation policy enforced and scheduled`.

### Task 12: GAP-0885e — GAP-0818 enforcement gate (MCP-LSP RLS pre-condition) + tracker reconcile

**Files:**
- Read: `docs/SECURITY_GAP_ANALYSIS.md` (GAP-0818 enforcement-gate row for exact required behavior)
- Modify: `src/mcp/server.zig` / `src/cli/lsp/` per the row's pre-condition (LSP tenant is client-asserted — the gate must refuse RLS-scoped operations when tenant identity is unverified)
- Test: extend `tests/test_gap0818_lsp_context.zig` or create `tests/test_gap0818_gate.zig`, wire as `test-gap0818-gate`

- [ ] **Step 1:** Read the tracker row + `docs/LSP_FEATURES.md` to pin the exact gate semantics: when auth mode provides no verified principal, LSP/MCP must not serve tenant-scoped schema/RLS-filtered data — serve only public/unscoped data or refuse.
- [ ] **Step 2:** Failing test: unverified session requests tenant-scoped completion → expect refusal/empty rather than tenant data. Implement smallest gate. Note residual honestly: full verified-principal tenant derivation stays open (GAP-0818 remains Partial); this task closes the *enforcement gate* sub-item only.
- [ ] **Step 3:** Tests PASS; `zig build` PASS. Update `docs/SECURITY_GAP_ANALYSIS.md`: mark closed items from Tasks 5–12 (move to `GAP_ANALYSIS_RESOLVED.md`), reconcile SEC-MIG-01 stale "open" lines (`:452,:505` say open; it's closed). Commit `fix: close GAP-0818 enforcement gate; reconcile security tracker`.

---

## Pass 3 — Backup & time-series data integrity

### Task 13: GAP-0880 — Backup protocol upload + compression truth

**Files:**
- Modify: `src/server/quic_connection_handler.zig:6723-6735` (upload backup returns success after metadata-only validation, empty file)
- Modify: `src/transport/grpc_server.zig:3139-3159` (same)
- Modify: `src/storage/backup.zig:643-668` (records `.none` even when `.zstd` requested)
- Test: `tests/test_gap0880_backup_upload.zig` (create), wire as `test-gap0880`
- Docs: `docs/API_REFERENCE.md:130-141`, `docs/SERVER_FEATURES.md:167,934`

- [ ] **Step 1:** Read all three sites + the backup wire protocol (how does the client stream backup bytes? grep the proto/message definitions used at :6723). Decide the honest contract: upload must ingest streamed bytes, verify size/checksum against the manifest, register durably, and only then return success.
- [ ] **Step 2:** Failing test: drive the real handler path (in-process server or direct handler-fn invocation as other quic handler tests do — find an existing test of a quic_connection_handler backup/restore message for the harness pattern) with a non-empty backup payload; assert the file on disk has the payload bytes and the registry records correct size/checksum. Today it's empty → FAIL.
- [ ] **Step 3:** Implement upload ingestion in QUIC handler; mirror in gRPC handler.
- [ ] **Step 4:** Compression: smallest honest option — Zig stdlib has DEFLATE (`std.compress.flate`); wire `.gzip`/`.deflate` as the supported codec, and make `.zstd` requests return a clear `error.UnsupportedCompression` (do NOT record false `.none`-as-zstd). Record the actual codec used in the manifest. Update docs to list the real supported codecs.
- [ ] **Step 5:** Round-trip test: create backup with compression → restore → data identical; manifest codec matches bytes. Tests PASS; existing backup steps PASS; `zig build` PASS. Commit `fix: close GAP-0880 - real backup upload ingestion + honest compression codec`.

### Task 14: GAP-0865 — Time-series durability (WAL/replay/retention/backup)

**Files:**
- Read FIRST: `docs/optimizing-ts-storage.md` (the authoritative gap evidence), `src/timeseries/timeseries.zig`, the vendored `timeseries-storage` lib API (in `~/.cache/zig/p/` or `zig-pkg/`; check `build.zig.zon` pin)
- Modify: `src/timeseries/timeseries.zig` (fail-soft `loadFromDisk()` at ~line 33; durability mode)
- Modify: `src/storage/backup.zig:167` (GraphStore-only backup root)
- Test: `tests/ts_durability.zig` (create), wire as `test-ts-durability`

- [ ] **Step 1:** Investigate what the external `timeseries-storage` LSM engine ALREADY provides (WAL? segments? manifest? crash recovery?). The gap may be in geode's wrapper (fail-soft loads, snapshot-style persistence) rather than the engine. Record findings in the test file header. Scope the smallest honest fix set:
  (a) fail-closed (or explicitly configured `durability=best_effort`) on `loadFromDisk` errors instead of silent empty store;
  (b) crash-atomic write path — if the engine has WAL, ensure geode uses the engine's durable-write API rather than full-series snapshot rewrite;
  (c) retention actually deletes expired data from disk (verify engine API; wire geode's retention config to it);
  (d) backup integration — include the `ts/` directory tree in backup/restore alongside graph data.
- [ ] **Step 2:** Failing tests, one per sub-item: (a) corrupt/truncate a ts file → open must surface an error (not silently succeed empty) unless best-effort configured; (b) insert points → hard-kill (skip graceful close) → re-open → points present; (c) configure retention=N, insert old+new points, run retention pass → old points gone from disk and queries; (d) backup → wipe → restore → ts points present.
- [ ] **Step 3:** Implement each; respect tier-7 leaf lock rule for `store_mutex`.
- [ ] **Step 4:** TDE framing for ts files: if engine supports a pluggable block/file codec, wire TDE; if not, document explicitly in `docs/TIMESERIES.md` as a known limitation (per-file TDE deferred with rationale) — do not fake it. Note decision in tracker.
- [ ] **Step 5:** Tests PASS (`zig build test-ts-durability`, existing `test-ts-*` steps); `zig build` PASS. Update `docs/optimizing-ts-storage.md` + `docs/TIMESERIES.md` to current truth. Commit `fix: close GAP-0865 - time-series durability: fail-closed load, crash-atomic writes, retention, backup`.

### Task 15: GAP-0866 — Time-series GQL surface truth

**Files:**
- Read: `docs/TIMESERIES_REQUIREMENTS_INVENTORY.md:166,240` (TS-INT-004; parallel `TSFunctionCall` system), `src/execution/ts_dispatch.zig`, `src/timeseries/gql_functions.zig`, `src/eval.zig`
- Test: extend `tests/ts_ingest_roundtrip.zig` or create `tests/ts_gql_surface.zig`, wire as `test-ts-gql-surface`

- [ ] **Step 1:** Audit: the live `CALL geode.ts.*` path (ts_dispatch.zig) is real and tested. The gap is (a) a parallel dead `TSFunctionCall` system in `gql_functions.zig` not wired to eval, and (b) stale inventory rows. Determine if `TSFunctionCall` has ANY live caller (`rg -n "TSFunctionCall" src/`).
- [ ] **Step 2:** If dead: delete the parallel system (user feedback: remove dead code, don't flag it) and re-audit inventory rows against the live dispatch path with server-level evidence (the `CALL geode.ts.*` tests). If partially live: wire the documented functions through the real evaluator with an integration test per function.
- [ ] **Step 3:** Signal-analysis spec (FFT/STFT/spectral anomaly, `spectral_anomaly_score()`, GPU/WASM detectors): mark explicitly future/non-GA in `docs/TIMESERIES_REQUIREMENTS_INVENTORY.md` and `specs/signal-analysis/integrating-signal-analysis.md` header; ensure no user-facing doc advertises them as present (`rg -n "spectral_anomaly_score|STFT" docs/ README.md`).
- [ ] **Step 4:** Tests PASS; `zig build` PASS. Commit `fix: close GAP-0866 - remove dead TSFunctionCall path, rebaseline TS inventory, gate signal-analysis as future`.

---

## Pass 4 — Planner & observability truth

### Task 16: GAP-0867 — CBO/EXPLAIN estimates

**Files:**
- Modify: `src/planner/cbo.zig` (`:341-360` static debug allocator; `choosePlanAPI()` no-op; `explainEstimateJSON` canned skeleton; `:649-652` `analyzeTable()` → `error.FeatureDisabled`; `:133` `choosePlan()` discards ctx)
- Modify: `src/server/index_catalog.zig:55-57` (ignores predicate expression)
- Modify: `src/planner/cost_explain.zig:95-105` (stub calibration object), `src/planner/pipeline.zig:231-233`
- Test: `tests/test_gap0867_cbo_estimates.zig` (create), wire as `test-gap0867`

- [ ] **Step 1:** Read the planner module + how `src/planner/` integrates with execution today (the IndexOptimizer in CLAUDE.md is described as live — find the REAL cost-based path: `rg -n "IndexOptimizer" src/`). Determine which of the flagged items are dead convenience APIs vs. live-but-stubbed.
- [ ] **Step 2:** Smallest honest scope: (a) delete dead no-op convenience APIs (`choosePlanAPI` if no live caller); (b) wire `StatsRegistry.analyzeTable()` to real statistics from the graph store (node/edge counts per label/type are available — grep `listNodeLabels` / label count APIs); (c) make `explainEstimateJSON` emit the real plan tree with per-node row estimates from those statistics; (d) `index_catalog.zig:55-57` must consult the predicate expression when matching candidate indexes.
- [ ] **Step 3:** Failing tests: (a) `analyzeTable` on a store with 100 nodes of label A returns count=100 (not FeatureDisabled); (b) EXPLAIN estimate JSON for `MATCH (n:A) RETURN n` contains a scan node with estimated_rows=100; (c) index catalog selects a property index when the predicate references the indexed property and skips it otherwise.
- [ ] **Step 4:** Implement; calibration object in `cost_explain.zig` either computes from real stats or is removed from output. Tests PASS; existing planner steps PASS; `zig build` PASS.
- [ ] **Step 5:** Docs: update planner docs to state what's estimated vs. heuristic (grep `docs/` for EXPLAIN cost docs). Commit `fix: close GAP-0867 - real statistics into CBO + truthful EXPLAIN estimates`.

### Task 17: GAP-0868 — PROFILE runtime telemetry

**Files:**
- Modify: `src/execution/statement_handlers.zig:1126-1131` (PROFILE `time` hard-coded to `1`)
- Docs: `docs/EXPLAIN_PROFILE.md:202,443`
- Test: `tests/test_gap0868_profile_timing.zig` (create), wire as `test-gap0868`

- [ ] **Step 1:** Read the PROFILE handler. Wrap statement execution with `std.time.Timer`; record wall-clock ms (and rows already available). Per-operator timing: check whether the executor exposes per-operator hooks — if yes, propagate counts; if not, scope to statement-level wall-clock + rows + (if cheaply available) index-hit counters, and document the per-operator residual in the tracker honestly.
- [ ] **Step 2:** Failing test: PROFILE of a query that sleeps/scans non-trivially must report `execution_time_ms` > 1 and not exactly the placeholder constant; two queries of very different cost must report measurably different times.
- [ ] **Step 3:** Implement; update `docs/EXPLAIN_PROFILE.md` to remove "placeholder" language for what's now real. Tests PASS; `zig build` PASS. Commit `fix: close GAP-0868 - real wall-clock PROFILE timing`.

### Task 18: GAP-0874 — Metrics sums + allocation telemetry

**Files:**
- Modify: `src/monitoring/registry.zig:86-87` (`geode_query_latency_ms_sum` hard-coded 0)
- Modify: `src/monitoring/otel_metrics.zig:2375-2382` (auth duration discards `duration_s`)
- Modify: `src/server/main.zig:805` (allocation metrics heuristic)
- Test: `tests/test_gap0874_metrics_sums.zig` (create), wire as `test-gap0874`

- [ ] **Step 1:** Read the histogram/counter registry. Track cumulative sum alongside bucket counts for query latency; make auth-duration instrument record the duration value (histogram or sum+count pair), not just a count.
- [ ] **Step 2:** Failing test: record latencies 5ms+7ms → `_sum` == 12 (±float tolerance), `_count` == 2; auth duration recorded twice → sum reflects both durations.
- [ ] **Step 3:** Allocation heuristic at `main.zig:805`: replace with a counting-allocator wrapper if one exists in the codebase (`rg -n "CountingAllocator|counting_allocator" src/`) or report the GPA's own stats; if neither is feasible cheaply, delete the misleading metric (honest > fake).
- [ ] **Step 4:** Tests PASS; `zig build` PASS; OTel parity: update `docs/OBSERVABILITY_ARCHITECTURE.md` if metric names change. Commit `fix: close GAP-0874 - real latency/auth-duration sums, honest allocation metrics`.

---

## Pass 5 — Feature-truth batch (advertised vs. real)

### Task 19: GAP-0869 — Advanced FTS (phrase/proximity/highlight)

**Files:**
- Read: `src/fts/advanced.zig:62-115` (hard-coded corpora), `tests/e2e_fts_advanced.zig:7-34`, `src/storage/fts_storage_adapter.zig`, `src/index/fulltext.zig`, fts-storage lib API
- Docs: `docs/optimizing-fts-storage.md:74-75,334`, `docs/FULLTEXT_SEARCH.md`
- Test: `tests/test_gap0869_fts_advanced.zig` (create), wire as `test-gap0869`

- [ ] **Step 1:** Investigate whether the pinned `fts-storage` v0.1.1 engine exposes positional/postings data (phrase queries need term positions). Record findings.
- [ ] **Step 2:** If positions ARE available: implement phrase + proximity against the real adapter (query terms→postings→position-adjacency check) and highlighting via offsets, RLS/FLE-safe (snippet generation must run AFTER row-level authorization — generate from authorized doc content only). Failing test over real indexed nodes (CREATE INDEX ... USING fulltext; insert docs; phrase query must match only adjacent-term docs).
- [ ] **Step 3:** If positions are NOT available in the engine: smallest honest option — implement phrase/proximity as a post-filter over BM25 candidates (fetch candidate docs' indexed text, verify phrase/window on the real stored property values), which is real (not simulated) though slower; OR mark the module test-only and strip user-facing claims. Prefer the post-filter (it's honest and functional).
- [ ] **Step 4:** Delete the hard-coded-corpus functions in `advanced.zig` and the synthetic-only assertions in `e2e_fts_advanced.zig`; replace with the real-path tests. Tests PASS; existing fts steps PASS; `zig build` PASS. Commit `fix: close GAP-0869 - phrase/proximity/highlight over real FTS index`.

### Task 20: GAP-0872 — CDC cloud sinks (Kinesis/PubSub) fail-loud

**Files:**
- Modify: `src/streaming/cdc_enhanced.zig:1010-1048` (Kinesis/PubSub `send()` discard events, return success)
- Docs: `docs/SERVER_FEATURES.md:695`
- Test: `tests/test_gap0872_cdc_sinks.zig` (create), wire as `test-gap0872`

- [ ] **Step 1:** Locked decision (smallest honest): implementing authenticated Kinesis/PubSub clients with retries/batching is out of scope for this round — make the constructors/`send()` fail loudly with `error.SinkNotImplemented` instead of silently succeeding, and remove Kinesis/PubSub from the supported-sinks doc list (keep Webhook + File + Kafka which are real).
- [ ] **Step 2:** Failing test: constructing/sending to a Kinesis or PubSub sink returns `error.SinkNotImplemented` (today returns success). Also assert webhook/file sinks still work (regression guard).
- [ ] **Step 3:** Implement; update docs. Tests PASS; `zig build` PASS. Commit `fix: close GAP-0872 - CDC Kinesis/PubSub sinks fail loud; docs list only real sinks`.

### Task 21: GAP-0876 — Materialized view rewrite

**Files:**
- Read: `src/query/enhanced_materialized_views.zig:1164-1223` (non-rewrite exits), `tests/test_materialized_views_enhanced.zig:434-439`
- Docs: `docs/MATERIALIZED_VIEWS.md:10-16`, `docs/IMPLEMENTATION_STATUS_OCTOBER_2025.md:38`, `docs/FEATURES_OVERVIEW.md:15,144`
- Test: extend `tests/test_materialized_views_enhanced.zig`

- [ ] **Step 1:** Read the rewrite matcher: determine why all paths exit non-rewrite. Implement the narrowest real positive case: exact-match rewrite — a query structurally identical to the view definition (same MATCH pattern + same RETURN projection) is answered from the view.
- [ ] **Step 2:** Failing test: define view over `MATCH (n:Person) RETURN n.name`; run the identical query; assert rewrite != null and results come from the view (e.g., after base-data mutation without refresh, results still reflect view snapshot — proving the view served it).
- [ ] **Step 3:** Implement exact-match rewrite. Keep the existing negative test (non-matching query → rewrite == null) — both must pass.
- [ ] **Step 4:** Docs: scope rewrite claims to "exact-match rewrite; cost-based partial rewrite future". Tests PASS; `zig build` PASS. Commit `fix: close GAP-0876 - exact-match materialized view rewrite`.

### Task 22: GAP-0877 — Advanced types semantics

**Files:**
- Modify: `src/value_types.zig:538-549` (placeholder stringify `"date"`, `"url"`), `src/eval_extended.zig:1785-1786` (unsupported geometry → silent false), `src/types/evaluator_functions.zig:240` (WKT-as-WKB placeholder), `src/index/advanced_types_index.zig:1059`
- `domain_root`: implement eTLD+1 (`specs/advanced-types/type-extensions-2-pr.md:66`; advertised in `docs/TYPES_AND_FUNCTIONS.md:426`)
- Test: `tests/test_gap0877_advanced_types.zig` (create), wire as `test-gap0877`

- [ ] **Step 1:** Canonical stringify: Date/Time/Timestamp/Interval render ISO-8601; URL/Domain render their actual value. Failing tests with concrete expected strings (e.g. Date(2026,6,10) → `"2026-06-10"`).
- [ ] **Step 2:** Geometry relations not implemented → return `error.UnsupportedGeometryRelation` (stable error), never silent false. Failing test asserts error, not false.
- [ ] **Step 3:** `domain_root`: smallest honest implementation — embedded snapshot of the public-suffix list's top entries is NOT honest at full fidelity; instead implement with a bundled compile-time PSL snapshot file (`src/types/public_suffix_snapshot.zig` generated from the real publicsuffix.org list — vendor the list file under `src/types/data/public_suffix_list.dat` with attribution + date) and exact-match + wildcard rule evaluation. Tests: `domain_root("a.b.example.co.uk") == "example.co.uk"`, `domain_root("x.example.com") == "example.com"`.
- [ ] **Step 4:** WKT/WKB: store WKT canonically or implement real WKB encode (check what the R-tree path consumes); fix the spatial-search zero-result placeholder at `advanced_types_index.zig:1059` or convert to stable unsupported error. Tests PASS; `zig build` PASS. Commit `fix: close GAP-0877 - canonical advanced-type serialization, eTLD+1 domain_root, honest geometry errors`.

### Task 23: GAP-0878 — GPU claims truth

**Files:**
- Modify: `src/gpu/acceleration.zig:97-122` (reports "Mock GPU Device" when backend `.none`)
- Docs: `README.md:286,317,324`, `docs/DOCKER_OVERVIEW.md:50-67`
- Read: `src/gpu/phase1_kernels.zig:9-31`

- [ ] **Step 1:** Locked decision (smallest honest): downgrade docs; no GPU algorithm implementation this round. `acceleration.zig`: backend `.none` must report no device available (not a "Mock GPU Device" that looks real); device-listing API returns empty/`null` with backend `.none`.
- [ ] **Step 2:** Failing test (extend existing gpu unit test if present, else `tests/test_gap0878_gpu_truth.zig` wired as `test-gap0878`): with backend `.none`, `listDevices()`/status reports zero devices and `available=false`.
- [ ] **Step 3:** Docs: README GPU bullets reframed to "GPU build foundation (Vulkan backend scaffold); algorithms currently CPU-path with GPU acceleration planned"; DOCKER_OVERVIEW GPU image described as CUDA-toolchain-ready, not CUDA-accelerated. `test-gpu` compile failure: make the step compile and self-skip cleanly when no GPU toolchain (mirror the `protobuf_union_submessage_supported` self-skip pattern) — a compile-failing step is a baseline wart.
- [ ] **Step 4:** Tests PASS (`zig build test-gpu` now compiles + skips cleanly on this host); `zig build` PASS. Commit `fix: close GAP-0878 - honest GPU device reporting, docs downgraded, test-gpu self-skips`.

### Task 24: GAP-0879 — ML embeddings truth

**Files:**
- Modify: `src/ml/graph_embeddings.zig:811-825` (GraphSAGE simplified projection), `src/ml/integration_enhanced.zig:743-768` (placeholder GraphData, c_allocator without ownership contract)
- Modify: `tests/test_ml_graph_embeddings_integration.zig:243-247` (simulated loss improvement), `:548-551` (random-walk ignores p/q)
- Docs: `docs/ML_GRAPH_EMBEDDINGS.md:387-389` (unsourced throughput numbers)

- [ ] **Step 1:** Locked decision: reframe as experimental + fix the two concrete algorithm defects that are tractable: (a) Node2Vec biased walks — implement p/q bias (return parameter p, in-out parameter q) in the walk transition sampling; (b) remove the simulated-loss test assertions and replace with a real training-loop test asserting loss is finite and decreases over epochs on a tiny deterministic graph (real computation, small scale).
- [ ] **Step 2:** Failing test for p/q: on a path graph with extreme q (DFS-like) vs extreme p (BFS-like), walk statistics must differ in the documented direction (e.g., return-to-previous frequency higher when p is small). Deterministic seed.
- [ ] **Step 3:** Fix the c_allocator ownership: use the module's injected allocator with documented ownership (caller frees via deinit) — no raw `std.heap.c_allocator` in production src (governance hook also forbids page_allocator).
- [ ] **Step 4:** Docs: mark GraphSAGE as "simplified aggregation (experimental)"; delete unsourced throughput numbers (replace with "run `zig build bench-ml` for current numbers" if a bench exists, else remove). Tests PASS; `zig build` PASS. Commit `fix: close GAP-0879 - Node2Vec p/q bias, real loss test, experimental framing`.

### Task 25: GAP-0883 — Graph algorithm procedure tests

**Files:**
- Read: `src/graph/algorithms.zig:57-64` (one-community-per-node when no adjacency), `src/ml/integration.zig:292-307` (embedding-sign as community), `docs/GRAPH_ALGORITHMS_USAGE_GUIDE.md:200-220`
- Modify: `tests/e2e_advanced_graph_features.zig:43-60`
- Test: `tests/test_gap0883_algo_procedures.zig` (create), wire as `test-gap0883`

- [ ] **Step 1:** Enumerate documented `CALL algo.*` (or `geode.algo.*`) procedures (`rg -n "algo\." docs/GRAPH_ALGORITHMS_USAGE_GUIDE.md` + `rg -n "\"algo" src/execution/`). For each documented procedure, write a server-level test over a real small graph (two triangles joined by one bridge edge is a good community/centrality fixture) through the real dispatch path (same harness pattern as `CALL geode.fts.search` tests).
- [ ] **Step 2:** Fix `algorithms.zig:57-64`: when adjacency exists, Louvain/label-propagation must produce non-trivial communities on the fixture (two communities for two triangles); the degenerate one-community-per-node result only for genuinely edgeless graphs.
- [ ] **Step 3:** `src/ml/integration.zig:292-307` embedding-sign community hack: route to the real community algorithm or mark the fn experimental + unused (delete if dead — `rg -n` callers).
- [ ] **Step 4:** Verify the usage-guide example outputs against the new tests; correct doc examples to actual outputs. Tests PASS; `zig build` PASS. Commit `fix: close GAP-0883 - server-level algo procedure tests over real graphs`.

### Task 25b: GAP-0875 — Residual local stubs batch (Low)

**Files (each independently small; one commit for the batch):**
- `src/schema/constraint_manager.zig:407-412` — unique constraints don't consult indexes
- `src/gql/print.zig:277-289` — printer doesn't walk `IN`/`NOT IN` subqueries
- `src/mcp/tools.zig:86` — cancellation token discarded
- `src/server/server_flags.zig:40-47` — pagination streaming writes full results (scaffold)
- `src/client/repl.zig:190` — future parsing unimplemented
- `src/tools/doccheck.zig:4-10`, `src/tools/security_progress.zig:267-269` — placeholder tools
- `src/performance/async_io_simple.zig:6-20`, `src/performance/io_optimized.zig:412-418` — mock/placeholder async
- `src/performance/memory_mapped_io.zig:561-563` — write bench numbers copied from read
- Test: `tests/test_gap0875_stubs.zig` (create), wire as `test-gap0875`

- [ ] **Step 1:** Implement the three real fixes: (a) unique-constraint check consults the property index when one exists (failing test: insert duplicate value under unique constraint with index present → constraint violation error); (b) printer walks IN/NOT IN subquery expressions (failing test: parse→print→reparse round-trip of a query with `WHERE x IN (subquery)` preserves the subquery); (c) MCP cancellation token propagated to tool execution (failing test: pre-cancelled token → tool returns cancelled error).
- [ ] **Step 2:** For the scaffolds that stay scaffolds this round: `memory_mapped_io.zig:561-563` write-bench must measure writes or be deleted (no copied numbers — delete the false output path); `async_io_simple`/`io_optimized` placeholder async marked explicitly non-GA (doc comment + module doc stating sync implementation); `server_flags` pagination scaffold gated behind explicit non-GA comment + tracker note; `repl.zig:190` + `doccheck` + `security_progress` either finish trivially or convert to explicit `error.NotImplemented` (no silent stub success).
- [ ] **Step 3:** Tests PASS; `zig build` PASS. Commit `fix: close GAP-0875 - unique-index check, printer subqueries, MCP cancellation, honest scaffolds`.

---

## Pass 6 — GQL & distributed residuals

### Task 26: GAP-0871 — GQL BACKUP/RESTORE + SEARCH/CYCLE decision

**Files:**
- Read: `src/gql/parser.zig:6310-6401`, `src/gql/ast.zig:598-612`, `src/execution.zig:2244`, `docs/GQL_COMPLIANCE.md:303`
- Test: extend the existing assert-unsupported tests (find via `rg -n "NotImplemented" tests/ | rg -i "backup"`)

- [ ] **Step 1:** Locked decision (smallest honest): GQL `BACKUP`/`RESTORE` statements stay unsupported (CLI is the supported surface); recursive CTE `SEARCH`/`CYCLE` stays unimplemented. This task makes the refusals stable and documented: executor returns a proper SQLSTATE `0A000`-mapped error (grep how other unsupported features map to SQLSTATE; follow that pattern) instead of bare `error.NotImplemented`.
- [ ] **Step 2:** Failing test: executing `BACKUP ...` returns the documented error code/message naming the CLI alternative (`geode backup create`). Implement mapping.
- [ ] **Step 3:** Docs: `docs/GQL_COMPLIANCE.md` residual-limits section lists both, with the CLI alternative for backup. Tests PASS; `zig build` PASS. Commit `fix: close GAP-0871 - stable 0A000 refusal for GQL BACKUP/RESTORE, documented residuals`.

### Task 27: GAP-0888 — GQL tracker sub-items (GAP-0534/0535/0536/0537)

**Files:**
- GAP-0535: `src/execution.zig:509-565` (`ExecutionResult` value-memory ownership not tracked by `deinit`)
- GAP-0537: `src/eval.zig` fallback `.Call` branch (handles `timeseries.value`, `evalTimeseriesFunction`, `all()`/`any()`, `char(N)`) → move into dedicated handler modules (follow the existing `call_handlers` module pattern — `rg -n "call_handlers" src/`)
- GAP-0534/0536: harness specs in `../geode-test-harness/geodetestlab-cli/specs/` (`gql_case_insensitivity_comprehensive.yml`, mixed-case `TIMESERIES.*` spec)
- Test: `tests/test_gap0535_result_ownership.zig` (create), wire as `test-gap0535`

- [ ] **Step 1:** GAP-0535 failing test: build an `ExecutionResult` containing allocated string values (e.g. from `RETURN UPPER('x')` through the real execution path), call `deinit`, run under testing allocator → leak reported today. Fix ownership tracking in `deinit`.
- [ ] **Step 2:** GAP-0537: move the fallback `.Call` handlers into dedicated modules with unit tests each; the fallback branch should shrink to dispatch-only. `zig build` + eval test steps PASS.
- [ ] **Step 3:** GAP-0534/0536: write the two harness spec YAMLs (mixed-case keyword spec covering SELECT/MATCH/RETURN/CALL case variants; mixed-case `timeseries`/`TIMESERIES`/`TimeSeries` CALL spec with a real store-bound series — follow `timeseries_basic.yml` if present, else `fts_storage_basic.yml` pattern). Mark them runnable; actually running the harness is the round-end verification step, not per-task.
- [ ] **Step 4:** Commit `fix: close GAP-0888 - ExecutionResult ownership, call-handler extraction, case-insensitivity harness specs`.

### Task 28: GAP-0870 — Raft command variants + query transport routing

**Files:**
- Modify: `src/distributed/raft_apply.zig:105-119` (skips `config_change`, `snapshot_pointer`, `txn_prepare`, `txn_decide`), `:315` (skips `alter_graph`)
- Modify: `src/distributed/enhanced_query_transport.zig:942-1006` (placeholder log-only handlers)
- Read: `src/distributed/federation.zig:1099`
- Test: `tests/test_gap0870_raft_variants.zig` (create), wire as `test-gap0870`

- [ ] **Step 1:** Read `raft_apply.zig` + the RaftCommand encoding (NOTE: protobuf union-as-submessage blocks 2PC wire encode — `txn_prepare`/`txn_decide` wire path is blocked upstream; implement the APPLY logic so it's exercised by in-process tests that construct commands directly, and keep the wire-encode gate documented).
- [ ] **Step 2:** Implement apply for `config_change` (membership change applied to cluster config), `alter_graph` (route to the same handler create_graph uses, for alter), `snapshot_pointer` (record snapshot metadata for log truncation). `txn_prepare`/`txn_decide`: apply into the 2PC undo/redo machinery that already exists (`rg -n "twophase" src/distributed/`). Commands that can't be valid must be REJECTED at proposal time, not skipped at apply time.
- [ ] **Step 3:** Failing in-process tests per variant: single-node raft applies each command type and observable state changes (config has new member; graph altered; snapshot pointer recorded; prepared txn present in 2PC table).
- [ ] **Step 4:** `enhanced_query_transport.zig:942-1006`: smallest honest — placeholder handlers either route to the real coordinator functions (where they exist: result merge, cancel, heartbeat have real counterparts — `rg -n "mergePartial|handleCancel|heartbeat" src/distributed/`) or return explicit `error.NotImplemented` surfaced to the caller instead of log-and-drop. No silent drops.
- [ ] **Step 5:** `federation.zig:1099` unimplemented strategies → explicit error, listed in docs as unsupported. Tests PASS; distributed steps PASS (`zig build test-cluster-coord-config` etc.); `zig build` PASS. Commit `fix: close GAP-0870 - raft command variants applied, transport handlers route or fail loud`.

### Task 29: GAP-0889 — Distributed quality batch

**Files:**
- Extract shared: create `src/distributed/result_utils.zig` (`cloneBindingRow`/`freeBindingRow`/`cloneSchema` — currently 3-4 copies across `federation.zig`, `query_coordinator.zig`, `enhanced_query_coordinator.zig`, `query_transport.zig`)
- Delete dead: `src/distributed/federation_root.zig` (zero imports — verify `rg -n "federation_root" src/ build.zig` first), `raft.zig handleMessage` arg-discarding stub, cluster request stubs (leave/replicate/failover/shard-forward) if dead
- Dedup: `ShardInfo` (5 files), `NodeRegistry` (2 files — note inline-copy drift warning in `src/distributed/test_query_transport_node_registry.zig`), pagination merge (5 copies in `enhanced_query_coordinator.zig`)
- Error handling: `raft_persistent.zig` (persistent-state failures ignored), `twophase.zig` (2PC/network errors discarded), `query_coordinator.zig` (parse errors → empty results), `cluster.zig` (replica/affected-shard slice leaks)
- Test: inline tests in extracted/fixed modules

- [ ] **Step 1:** Extract `result_utils.zig` with the canonical clone/free implementations + inline tests (clone→mutate-original→clone-unchanged; free under testing allocator). Update the 4 call-site files to import it; delete local copies.
- [ ] **Step 2:** Dead code: verify zero callers (`rg`), then `git rm` / delete `federation_root.zig` and dead stubs. `ShardInfo`: define once in the most foundational module (likely `sharding.zig`), re-export/import elsewhere. NodeRegistry: keep the drift-warned inline copy in sync or import the real one if the test can.
- [ ] **Step 3:** Error propagation fixes: parse errors in `query_coordinator.zig` must return the error to the caller (failing test: malformed fragment query → error, not empty result set); `raft_persistent.zig` persistence failures must fail the operation or panic per design (failing test with failing-writer injection if the module supports it); `twophase.zig` network errors recorded + retried or aborted, not discarded; `cluster.zig` slice leaks: `errdefer` frees on failure paths (leak test under testing allocator).
- [ ] **Step 4:** Inline test backfill: add at least one real inline test to each of the distributed files that have zero (list in tracker; 11 of 20). Keep them small but real (construct module, exercise one happy + one error path).
- [ ] **Step 5:** `zig build` + all distributed test steps PASS. Update `docs/DISTRIBUTED_QUALITY_GAP_ANALYSIS.md` marking addressed findings. Commit per logical chunk if large; final `fix: close GAP-0889 - distributed dedup, dead-code removal, error propagation, inline tests`.

---

## Pass 7 — Quality batches (GAP-0886 highest-priority sub-items)

### Task 30: GAP-0886a — #813 FLE enforcement TODOs + #812 dead WAL block + #728 gitleaks noise

**Files:**
- #813: `rg -n "TODO" src/execution/fle_hooks.zig src/fle_integration.zig src/schema/fle_catalog.zig` — each FLE enforcement TODO becomes either an assertion/explicit check or a comment documenting why the path is safe (with the invariant named)
- #812: dead `if (false)` WAL replay block — locate via `rg -n "if (false)" src/` → delete
- #728: `.gitleaks.toml` allowlist noise — tighten allowlist patterns that are too broad

- [ ] **Step 1:** #813: enumerate every FLE TODO; for each, read enough context to decide assert-vs-document; implement. Any TODO that masks a real enforcement hole gets a failing test + fix instead (escalate in journal if found).
- [ ] **Step 2:** #812: delete the dead block (user rule: remove dead code). #728: review `.gitleaks.toml`; narrow over-broad allowlists; run `pre-commit run gitleaks --all-files` if hook exists (else skip with note).
- [ ] **Step 3:** `zig build` PASS + FLE test steps PASS. Commit `fix: close quality #813/#812/#728 - FLE TODO resolution, dead WAL block removed, gitleaks tightened`.

### Task 31: GAP-0886b — #721 catch {} audit + #556/#809/#810 catch-unreachable hot paths

**Files:**
- Audit: `rg -n "catch \{\}" src/ --count-matches` (653 sites per tracker) and `rg -n "catch unreachable" src/`
- Policy doc: `docs/ERROR_HANDLING_POLICY.md` (create)

- [ ] **Step 1:** This is an audit+categorize task, not a 653-site rewrite. Write `docs/ERROR_HANDLING_POLICY.md`: categories (A: safe-to-ignore with comment justification, B: must-log, C: must-propagate, D: must-crash) with concrete code examples from the repo.
- [ ] **Step 2:** Triage the highest-risk subset NOW: all `catch {}`/`catch unreachable` in `src/security/`, `src/storage/wal*.zig`, and `src/execution/` write paths (data-loss/security relevance). Fix category-C/D violations found there (propagate or convert to explicit error). Target: zero unjustified swallows in those three trees; add `// error-policy: A — <reason>` comments for justified ones.
- [ ] **Step 3:** Record remaining-count by directory in the tracker (so the next round has a burn-down). `zig build` + affected test steps PASS. Commit `fix: close quality #721/#556/#809/#810 (security/WAL/execution tier) - error-policy + high-risk catch audit`.

### Task 32: GAP-0886c — #806 LSP features.zig split + #730 CANARY golden tests + #733 hot-path test backfill

**Files:**
- #806: split `src/cli/lsp/features.zig` into `features/completion.zig`, `features/hover.zig`, `features/definition.zig`, `features/diagnostics.zig` (or the natural seams found on read) with `features.zig` as re-export facade
- #730: golden tests for the CANARY parser/generator regex — `scripts/` (find the status generator: `rg -n "VALID_STATUS" scripts/`); add `tests/`-side or script-side golden tests (sample marker lines → expected parse)
- #733: add inline tests to the 3 least-covered hot-path functions in `src/gql/parser.zig`, `src/execution/match_operations.zig` (pick functions with zero direct tests; verify via existing test greps)

- [ ] **Step 1:** #806: mechanical split preserving public API; `zig build` + LSP steps PASS after.
- [ ] **Step 2:** #730: golden test fixture with ~10 marker lines (valid, malformed, COMPLETE-status reject case from the STATUS_GEN_WARN seen 2026-06-10) → expected CSV rows. Wire into pre-commit or a `make` target if the generator is Python (pytest-style inline or a simple assert script).
- [ ] **Step 3:** #733: three real inline tests (parser edge: deep nesting; match: tenant-filter path; execution: error path). All PASS; `zig build` PASS. Commit `fix: close quality #806/#730/#733 - LSP module split, CANARY golden tests, hot-path test backfill`.

### Task 33: GAP-0886d — remaining quality tracker reconcile

**Files:**
- Modify: `docs/QUALITY_GAP_ANALYSIS.md`

- [ ] **Step 1:** The big architectural items (#474 cli/main split, #520 globals, #515 gRPC parity, #462 GraphStore god object, #409 evalExpr dispatch, #405 param structs, #521 arg parsing, #719/#804 match fn size, #725 lint debt, #736/#815 lock TODOs, Q9-Q19) remain design-gated. For each: confirm status is current, ensure each row has a named unblock condition or design doc pointer, and re-severity any that Tasks 30-32 partially addressed.
- [ ] **Step 2:** Mark #812/#813/#721(tier-1)/#728/#730/#733/#806 closed → move rows to `GAP_ANALYSIS_RESOLVED.md`. Commit `docs: reconcile QUALITY_GAP_ANALYSIS after 2026-06-10 quality batch`.

---

## Pass 8 — Performance (GAP-0887)

### Task 34: GAP-0887a — PERF-A: RLS row-rebuild elimination (#808)

**Files:**
- Modify: `src/security/rls_value_bridge.zig:83-95` (`nodePropertiesToRLSRowInto` rebuilds StringHashMap per row), call sites in `src/execution/match_operations.zig` (17 sites)
- Bench: existing RLS/match benchmarks (`rg -n "rls" benchmarks/`)
- Test: existing RLS test steps as regression guard

- [ ] **Step 1:** Read the bridge + `passesRLSExprFilter` path. Implement the register's suggested fix: skip row construction entirely when the compiled policy bytecode contains no `load_row` instruction (cheap pre-scan cached on the CompiledExpression); for policies that DO need rows, reuse a per-iteration scratch map (`clearRetainingCapacity`) instead of rebuilding.
- [ ] **Step 2:** Correctness first: all existing RLS test steps PASS unchanged.
- [ ] **Step 3:** Benchmark evidence: run the relevant existing benchmark (or add a micro-bench under `benchmarks/` following the VarianceEnvelope pattern) before/after; record numbers in the journal. Expect measurable improvement on RLS-filtered scans with row-free policies.
- [ ] **Step 4:** `zig build` PASS. Commit `perf: close PERF-A/#808 - skip/reuse RLS row construction in match filtering`.

### Task 35: GAP-0887b — LSP-F-02: AST cache keystone (#770)

**Files:**
- Read: `docs/PERF_GAP_ANALYSIS.md` LSP-F-02 row for the existing design notes; `src/cli/lsp/` parse paths (`rg -n "parse" src/cli/lsp/features.zig src/cli/lsp/server.zig`)
- Create: `src/cli/lsp/ast_cache.zig`
- Test: `tests/test_lsp_ast_cache.zig` (create), wire as `test-lsp-ast-cache`

- [ ] **Step 1:** Read how each LSP feature currently re-parses the document. Implement a per-document AST cache keyed by (uri, version): didChange invalidates; completion/hover/definition/diagnostics consult the cache before parsing.
- [ ] **Step 2:** Failing test: parse-count instrumentation (inject a counting parser or expose cache hit/miss counters); two successive hovers on the same doc version → 1 parse, 1 cache hit. didChange → invalidation → re-parse.
- [ ] **Step 3:** Tests PASS; LSP steps PASS; `zig build` PASS. Update `docs/PERF_GAP_ANALYSIS.md` (LSP-F-02 closed; unblocks F-05/F-06/F-12/F-15/F-16 — note them as now-unblocked). Commit `perf: close LSP-F-02/#770 - per-document AST cache for LSP providers`.

---

## Pass 9 — CI & supply chain

### Task 36: GAP-0882 — Migration CI guard + SEC-SUPPLY-01

**Files:**
- Modify: `.gitlab-ci.yml` (new `migration-guard` job)
- Create: `scripts/ci/check_migrations.sh` (or python under `scripts/`)
- SEC-SUPPLY-01: add CODEOWNERS rule for `build.zig.zon` (`.gitlab/CODEOWNERS` or root `CODEOWNERS` — check which exists)
- Docs: `docs/SECURITY_GAP_ANALYSIS.md` SEC-MIG-02 + SEC-SUPPLY-01 rows

- [ ] **Step 1:** Write `check_migrations.sh`: for files under `migrations/**/*.gql` changed in the MR, parse each with the geode binary (`geode query --parse-only` if available; else `zig build` + a small parse-check entry — check `src/cli/main.zig` for a validate/parse flag) and flag destructive statements (DROP/DELETE without guard comment) per policy.
- [ ] **Step 2:** Add `.gitlab-ci.yml` job running on MRs touching `migrations/`; `allow_failure: false`. Conform to existing CI conventions in the file (image, tags, rules syntax — read existing jobs first; docker jobs require linux tag per pre-commit hook).
- [ ] **Step 3:** SEC-SUPPLY-01: CODEOWNERS rule requiring review on `build.zig.zon` (2-reviewer enforcement is a GitLab settings matter — document the required project-setting change in the tracker row as the operator action; the CODEOWNERS file is the repo-side half).
- [ ] **Step 4:** Validate YAML (`pre-commit run check-yaml --files .gitlab-ci.yml`); test the script locally against a sample migration file. Commit `fix: close GAP-0882 + SEC-SUPPLY-01 - migration CI guard, build.zig.zon CODEOWNERS`.

---

## Pass 10 — CANARY governance (GAP-0514 Phase 6)

### Task 37: GAP-0514 Phase 6 — P1 files (repl_dispatch 36, server/main 25, quic_connection_handler 22)

**Files:**
- `src/client/repl/repl_dispatch.zig`, `src/server/main.zig`, `src/server/quic_connection_handler.zig`
- `docs/status.csv` via `make status-generate`

- [ ] **Step 1:** For each file: `rg -n "STATUS=IMPL" <file>` to list markers. For each marker: find whether a named test exercises the requirement (grep the REQ id in `tests/` and spec files). If tested → promote marker to `TESTED` with `TEST=<file>` reference. If implemented but untested → write the missing test (smallest real test through a public path) then promote. If genuinely unimplemented → leave IMPL.
- [ ] **Step 2:** HONESTY AUDIT each batch: for every promotion, run the named test and paste the pass line into the journal. No paper promotions.
- [ ] **Step 3:** `make status-generate`; commit `chore: GAP-0514 Phase 6 P1 - repl_dispatch/server-main/quic-handler CANARY reconciliation`.

### Task 38: GAP-0514 Phase 6 — P2 files (server_init 19, repl_loop 19, build.zig 19, grpc_server 17, gql_iso_conformance 16, e2e_quic_high_concurrency 16, auth_graph_manager 16, graph_store 16, cli/main 15, match_operations 14)

- [ ] **Step 1:** Same per-marker workflow as Task 37 for the P2 file list. NOTE: `match_operations.zig` promotions only AFTER Task 34 (PERF-A) lands — its RLS filter paths are touched there.
- [ ] **Step 2:** Honesty audit + `make status-generate`; commit `chore: GAP-0514 Phase 6 P2 CANARY reconciliation`.

### Task 39: GAP-0514 Phase 6 — P3 distributed files + final count

- [ ] **Step 1:** Same workflow for: `query_planner` 13, `enhanced_query_transport` 11, `sharding` 10, `query_transport` 10, `quic` 8, `geode_auth_lib` 8, `execution` 8 (run after Tasks 28/29 which touch the same files).
- [ ] **Step 2:** `make status-generate`; check total IMPL count. Target ≤250 (≤5%). If above target after honest promotion, record the residual per-file table in the register (GAP-0514 stays Partial with updated numbers — honest state beats forced target).
- [ ] **Step 3:** Commit `chore: GAP-0514 Phase 6 P3 + final IMPL count <N>`.

---

## Pass 11 — Blocked & deferred documentation

### Task 40: GAP-0256, GAP-0838, GAP-0873 — blocked/deferred state records

**Files:**
- Modify: `docs/GAP_ANALYSIS.md` (three rows), `docs/design/TDE_PER_TENANT_KEYS_DEFERRED.md` (verify current)

- [ ] **Step 1:** GAP-0256 (Blocked): verify `.goreleaser.yaml:745-767` disabled blocks still match the documented unblock chain (syft install → cosign key → un-comment → CI verify step). Refresh the row's unblock steps if drifted.
- [ ] **Step 2:** GAP-0838 (Blocked): confirm the two k8s defects (DNS search-domain at `quic.zig:1397/1414`; election-layer candidate/term=0) are still accurately described; link `docs/bugs/2026-06-02-cluster-0.6.14-k8s-still-fails.md`. If the DNS search-domain fix is tractable repo-side (parse `resolv.conf` search domains in the resolver), implement THAT sub-item now with a unit test (resolv.conf fixture → short name resolves through search list) and narrow the blocker to election-layer only.
- [ ] **Step 3:** GAP-0873 (Deferred): confirm `docs/design/TDE_PER_TENANT_KEYS_DEFERRED.md` states the single-master-key at-rest limitation as a product limitation with the GAP-0290 pointer; add a cross-tenant decrypt-fail test ONLY if a per-tenant path already exists (per register: derivation helpers exist at `src/security/tde.zig:433-522` — add the unit test that tenant-A-derived key fails to decrypt tenant-B-derived ciphertext; that's real and cheap).
- [ ] **Step 4:** Commit `docs: close-out blocked/deferred records (GAP-0256, GAP-0838 narrowed, GAP-0873) + tenant-key derivation test`.

---

## Pass 12 — Docs rebaseline LAST

### Task 41: GAP-0864 — stale-claims rebaseline

**Files (exact stale claims from register):**
- `docs/IMPLEMENTATION_STATUS_OCTOBER_2025.md:17-40` (blanket Complete labels)
- `docs/SERVER_FEATURES.md:8-9,491,1412` (100% compliance, 97.4%, Production Ready)
- `docs/TESTING.md:15-19` (100% coverage)
- `docs/CURRENT_ARCHITECTURE.md:36,319,325,623` (97.4%/100% pass language)
- `docs/README.md:7,87,88`
- `docs/GQL_AUTH_DDL.md:158` (says RLS policy persistence NOT implemented — it IS now; fix in the true direction)
- `docs/DESIGN_TDE_KMS.md:1,83,86` (labels ExternalKms stub — real Vault/AWS paths exist; fix in the true direction)

- [ ] **Step 1:** For each file:line, rewrite the claim to name the exact suite and scope: ISO suite "70/70 in tests/gql_iso_conformance.zig"; local baseline "<current>/175 named test-* steps (see KNOWN_TEST_ISSUES.md)"; harness "fresh run owed; last dated snapshot ~97%". No `Complete`/`100%`/`Production Ready` without named-suite qualification. Cite `docs/GAP_ANALYSIS.md` + `docs/KNOWN_TEST_ISSUES.md` as canonical.
- [ ] **Step 2:** The two reverse-direction fixes (GQL_AUTH_DDL RLS persistence; DESIGN_TDE_KMS ExternalKms) get updated to current reality with test references.
- [ ] **Step 3:** `rg -n "100%|Production Ready|97.4" docs/ README.md` sweep — fix any further unqualified instances in user-facing pages (skip historical completion_reports/ and RESOLVED archives).
- [ ] **Step 4:** Commit `docs: close GAP-0864 - rebaseline stale claims to named-suite scoped truth`.

### Task 42: Tracker close-out + register update

**Files:**
- `docs/GAP_ANALYSIS.md`, `docs/GAP_ANALYSIS_RESOLVED.md`, sibling trackers, `CLAUDE.md` status header

- [ ] **Step 1:** For every gap closed this round: move register row to `GAP_ANALYSIS_RESOLVED.md` under a "2026-06-10 Closure Round" section with commit SHAs from the journal. Keep open: GAP-0256 (Blocked), GAP-0838 (Blocked, possibly narrowed), GAP-0873 (Deferred), GAP-0514 (Partial unless ≤target), plus any task that ended Blocked.
- [ ] **Step 2:** Update sibling trackers (SECURITY/QUALITY/PERF/GQL/DISTRIBUTED_QUALITY) to open-only current state. Explicit won't-do/deferred records with reasons: SEC-MFA-FIPS-01 (no FIPS customer requirement documented), SEC-MON-01 (deferred until metrics endpoint re-exposed), SEC-INFRA-02 (infrastructure config item, operator action documented).
- [ ] **Step 3:** Update `CLAUDE.md` Known Limitations + status lines for changed facts (compression now real for supported codecs; FTS advanced; baseline count).
- [ ] **Step 4:** Commit `docs: update gap analysis tracking - 2026-06-10 closure round complete`.

---

## Final verification (round end, before merge)

1. Full named-step sweep (or at minimum: every step touched this round + the 8 formerly-known-failing) — record new baseline in `docs/KNOWN_TEST_ISSUES.md`.
2. Sharded `zig build test` (4 shards, `CI=1 GEODE_SKIP_SUBPROC_CLUSTER=1`) — all green.
3. `make status-generate` clean; `git status` clean.
4. gap-closer-verifier agent pass (security review of all diffs; acceptance criteria re-check).
5. Merge `gap-closure-2026-06-10` → main; push.
