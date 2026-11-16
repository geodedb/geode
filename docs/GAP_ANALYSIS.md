# Gap Analysis

Last updated: 2026-06-17
Audited by: 2026-06-10 docs/specs/source/dependency reconciliation, including open residuals from `docs/*_GAP_ANALYSIS.md`. 2026-06-16 addendum: a 14.27M-node divelife bulk-seed stress run against `geodedb/geode:dev` surfaced GAP-0894/0895/0896. **2026-06-17 correction:** a controlled host A/B (below) showed the 2026-06-16 GAP-0894 "reopen" was a **measurement error** — the ~50 nodes/sec was measured against the server *in a Docker container* (UDP-NAT round-trip latency), not the single-property lock. The unmodified server on the host does ~255–259 nodes/sec for the same workload at 8 connections, and a striped single-property handler patch tried this session **regressed that 2× (→~130) and was reverted**. GAP-0894 (the lock) is NOT the normal-concurrency bottleneck and stays **closed**. The high-connection ingest "stall" was first (mis)attributed to the `data-ingest` client because a 2-process × 16-worker run happened to sustain ~259 nodes/sec; that was a **lucky non-crash run** — the true cause is **GAP-0899 (Critical), now CLOSED (commit `7dcac17e`): a server CRASH**. Under high write concurrency the periodic checkpoint took `mg.rwlock` SHARED while the bulk writers also hold it SHARED and mutate `label_index`/`edge_index`, so `checkpointAll → … → label_index.scan()` raced a concurrent `addNode()` and panicked with `index out of bounds`, killing the process; the "0 nodes/sec freeze" was the server dying under the load. Fixed by making the checkpoint take the EXCLUSIVE lock (validated crash-free at 64 concurrent writers on host + container, full test suite green). Two further geode-side findings from the run: **GAP-0897 (Medium): a per-graph metrics name-collision** that masked the original GAP-0894 validation, and a non-crashing residual driver multi-stream behaviour tracked as geode-client-go **BUG-0002**. GAP-0895/0896 remain genuinely fixed; the `data-ingest` connection-pool clamp (≤16) is retained as a sensible client default. See [GAP_ANALYSIS_RESOLVED.md](GAP_ANALYSIS_RESOLVED.md) for GAP-0899 detail.

## Summary

This live register is authoritative as of 2026-06-11 (round close-out). Archived material has been moved to [GAP_ANALYSIS_RESOLVED.md](GAP_ANALYSIS_RESOLVED.md); when a sibling gap-analysis file conflicts, this register is the current actionable index. The 2026-06-09 audit also normalizes duplicate CaaST IDs: GAP-0838 remains the cross-pod cluster failure, and CaaST tenancy/FLE residuals are tracked as GAP-0846 through GAP-0854. The 2026-06-10 continuation audit pulled the requested downstream repositories, rechecked docs/spec/source claims, and reconciled the open residuals from `docs/*_GAP_ANALYSIS.md`.

- **2026-06-16/17 bulk-seed stress audit + correction:** A 14.27M-node taxonomy bulk seed (divelife `data-ingest ingest --from-dump`, single-property `MERGE`) against `geodedb/geode:dev` surfaced GAP-0894/0895/0896. **GAP-0895 and GAP-0896 are CLOSED** (re-verified fixed on build `bfb66f42` 2026-06-17 — compact one-line metrics, no false stall errors). The 2026-06-16 GAP-0894 "reopen" was **RETRACTED 2026-06-17**: the ~50 nodes/sec figure was measured against the server in a Docker container (UDP-NAT round-trip latency); a controlled host A/B (both binaries, `make release`, 8 connections, warmup-discarded, 2 rounds each) measured the unmodified server at **~255–259 nodes/sec** and a striped single-property handler patch at **~130 nodes/sec — a 2× regression — so the patch was reverted**. The single-property exclusive lock is not the normal-concurrency bottleneck (the path is per-op WAL-fsync / round-trip bound). Reproduction corpus retained at `~/divelife-dump`.
- **2026-06-17 high-connection ingest behaviour — corrected:** the bulk-seed "freeze to ~0 nodes/sec" was the **server CRASH GAP-0899** (now CLOSED, commit `7dcac17e`), NOT a client deadlock as first thought (a 2×16 run had got lucky and not crashed). With the crash fixed the ingest runs steadily; what remains is a **write-throughput ceiling, filed as GAP-0900 (High, open):** single-property bulk writes top out at **~1,100 ops/sec regardless of client concurrency** (16 vs 128 connections give the same rate) — a single-threaded serial section in the write/commit path. For the divelife 14.27M taxon seed (~30 server ops/taxon) this is ~36–39 taxa/sec ⇒ ~100 h end-to-end. The other geode-side finding from the run is **GAP-0897 (Medium)** — per-graph metrics register under fixed names so only the default graph's `mg_*` counters export. See the register rows below.
- **Total open/partial gaps:** 8
- **Critical:** 2 (GAP-0256, GAP-0838) — both **BLOCKED** (GAP-0256 on org cosign/CI-secret infra — `.goreleaser.yaml:745-753`/`755-767` disabled blocks re-verified 2026-06-11, unblock chain unchanged; GAP-0838 narrowed 2026-06-11: repo-side fixes for BOTH 0.6.14 k8s defects landed — DNS search-domain expansion `test-dns-search` 7/7 + hostname-derived node_id `test-cluster-bootstrap` — leaving only real-cluster Kubernetes end-to-end validation, which cannot run in-repo).
- **High:** 3 (GAP-0885, GAP-0893, GAP-0900). GAP-0885 is the security sibling backlog pointer — open/partial: the open-only `docs/SECURITY_GAP_ANALYSIS.md` still tracks LSP-SEC-002 (vendored MCP bearer compare — mitigated/documented at the geode boundary, pending an upstream patch + fork pin), the deferred SEC-MFA-FIPS-01 / SEC-MON-01 / SEC-INFRA-02 records (defer reasons recorded per row), and the GAP-0818 verified-tenant-derivation residual. GAP-0893 was RE-DIAGNOSED and FIXED 2026-08-25: the stated vendor root cause was stale. The `grpc_zig` 0.1.7 `allocStreamWindows` crash was fixed upstream in v0.1.8 and geode has pinned v0.1.9 since; the surviving hang was two GEODE-side bugs in `src/transport/grpc_tls.zig` / `src/transport/grpc_server.zig` (see the register row). GAP-0900 is the write-throughput serialization ceiling (new 2026-06-17 — full evidence below and in the register). (GAP-0880 backup upload/compression and GAP-0881 HMAC-SHA3/TDE-status — previously two High rows — closed this round; see `GAP_ANALYSIS_RESOLVED.md`.)
- **Medium:** 3 (GAP-0514, GAP-0873, GAP-0897). GAP-0514 — CANARY IMPL count reopened 2026-11-12 (873 IMPL, 15.0%, on 2026-11-16, above both the ≤250 and ≤5% targets; see the register row). GAP-0873 — per-tenant at-rest encryption, explicitly deferred to GAP-0290 with the single-master-key limitation documented (`docs/design/TDE_PER_TENANT_KEYS_DEFERRED.md`) and derivation-helper cross-tenant decrypt-fail tests already green (`test-gap0843-tenant-tde`). GAP-0897 — per-graph runtime metrics register under fixed names so only the first (default) graph's counters are ever exported; this masked GAP-0894 validation (`mg_merge_tuple_lock_acquired_total` always read 0 for named graphs).
- **Low:** 0
- **2026-06-10/11 closure round (complete):** 28 register gaps closed on branch `gap-closure-2026-06-10` — GAP-0863–0872, GAP-0874–0884, GAP-0886–0890, GAP-0892, and GAP-0514 — plus the security sub-items SEC-SESS-LOG-01, LSP-SEC-005/008, SEC-LSP-BIND-01, SEC-INFRA-03, SEC-S3-SIGV2-01, SEC-CLI-01, SEC-SUPPLY-01, SEC-MIG-02 and the GAP-0818 enforcement gate (GAP-0818 itself stays Partial). Full closure evidence — including the rows formerly struck in this register — lives in [GAP_ANALYSIS_RESOLVED.md](GAP_ANALYSIS_RESOLVED.md) under "2026-06-10/11 Closure Round". CANARY IMPL debt 499 → 223/5094 (4.4%, TESTED 85.2%); local baseline rebaselined to ~175/179 named `zig build test-*` steps (`docs/KNOWN_TEST_ISSUES.md`); ISO conformance suite re-scoped to 96/96 (parse-only) + executed-query `gql_conformance` 20/20.
- **Current dependency state:** Requested downstreams were fetched/pulled on 2026-06-10. `../geode-client-zig` is on `main...origin/main` at `9ba815e`, matching this repo's `build.zig.zon:322-323` pin and hash. Most `~/src/devnw/zig/*` symlinked Git repos are on their current upstream branch after fast-forward pulls; pull exceptions requiring owner decision are `ebnf` (tracking branch `origin/fix/low-security-findings` is gone), `ed25519` (local `main` is ahead 1), and `otel`/`quic` (feature branches were current; `origin/main` was fetched only). Non-git entries under the requested tree are `encrypted-fs` and `zcap2`. `build.zig.zon:162-163` now pins `quic v0.1.24#3f61c85`, whose `build.zig.zon` pins `tls v0.1.9#0cbbf1a`; local `tls` is at `0f8031e` and includes the GAP-0838 transcript fix. `fts-storage` is current at `908c1f5`; `timeseries-storage` local `main` is current at `33d5ef9` while this repo still pins `e5ecd21` (newer local delta appears script-only).

### Current open/partial gap register (2026-06-11)

| Gap-ID | Severity | Area | Current evidence | Required completion |
|---|---|---|---|---|
| GAP-0256 | Critical | Supply chain / release | **BLOCKED on org-level signing infrastructure** (cosign keys + CI secrets are not provisioned for this project). The release config already contains the SBOM + signing wiring, but it is commented out pending the missing tooling/secrets: `.goreleaser.yaml:745-753` carries the disabled `sboms:` block (`syft scan --output cyclonedx-json` per archive; commented `# TODO: Install syft in CI and re-enable`) and `.goreleaser.yaml:755-767` carries the disabled cosign `signs:` block (`cosign sign-blob --output-signature ... --yes` over `checksum`). **Unblock chain (do in order once infra lands):** (1) install `syft` in the GitLab CI release runner image and un-comment the `.goreleaser.yaml` `sboms:` block; (2) provision a cosign key (keyless OIDC via GitLab CI `id_tokens`, or a `COSIGN_PRIVATE_KEY`/`COSIGN_PASSWORD` CI secret) and un-comment the `signs:` block; (3) add a CI verification step (`cosign verify-blob --signature` over the published checksum, `syft` SBOM artifact upload) gating the `release` job; (4) document the verification procedure in `docs/`. No code change is needed in this repo — the gate is the absence of org signing keys/CI secrets. | Add release-pipeline SBOM generation (`.goreleaser.yaml` `sboms:`), artifact signing (`signs:` cosign), verification docs, and CI enforcement — once cosign keys / CI secrets are provisioned. |
| GAP-0838 | Critical | Distributed cluster | **BLOCKED — repo-side fixes for BOTH 0.6.14 k8s defects have landed; the remaining blocker is real-cluster Kubernetes validation, which cannot run in-repo.** (1) **TLS transcript fix LANDED** in the shared `devnw/zig/tls` lib and is validated on this branch by `tests/test_gap0838_cluster_tls_noloopback.zig` (`zig build test-gap0838-cluster-tls`) — a non-loopback secure peer handshake completes. (2) Dependency chain complete in this workspace: geode `build.zig.zon:162-163` pins `quic v0.1.24#3f61c85`, that quic revision pins `tls v0.1.9#0cbbf1a`, and local `tls` is at `0f8031e` including the transcript fix. (3) **Defect (A) DNS search-domain resolution — FIXED repo-side** (commit `dc67e9d2`): the bundled dns library resolved hostnames verbatim with no resolv.conf `search`/`ndots` support, so short headless peer names (`geode-0.geode`) returned NXDOMAIN. New std-only `src/transport/dns_search.zig` implements the glibc stub-resolver candidate algorithm (parse `search`/`domain`/`options ndots:N`; search-first ordering for short names, bare-first once ≥ ndots dots, absolute for a trailing dot) and `resolveHostToIp` (`src/transport/quic.zig:1498-1537`) tries each candidate, falling back to the bare name on any resolv.conf read failure (non-k8s unchanged). Unit-tested without real DNS via the parse/ordering seam: `zig build test-dns-search` (7/7, re-run green 2026-06-11). (4) **Defect (B) election candidate/term=0 — FIXED repo-side** (Resolution 2026-06-03 in `docs/bugs/2026-06-02-cluster-0.6.14-k8s-still-fails.md`): root cause was a node_id↔peer-position contract violation that only manifests with DNS peers; `src/server/cluster_bootstrap.zig` now auto-derives the raft id from `$HOSTNAME`'s 1-based position in `GEODE_PEERS` (hostname position authoritative; a mismatched explicit `GEODE_NODE_ID` is overridden with a WARN; loopback/non-k8s explicit-id path unchanged), plus the `[cluster-identity]` boot diagnostic. Tests: `zig build test-cluster-bootstrap`, `test-cluster-identity` (7/7); loopback 3-node election regressions (`test-cluster-3node-election`, `test-cluster-3node-subprocess`) stay green. A DNS-resolved multi-pod election can only be proven where peers resolve via real cluster DNS — out of repo scope. | Validate end-to-end on a real Kubernetes cluster: re-enable the 3-node kustomize component in `geode-argo-arda`, prove three non-loopback nodes form quorum (including TLS peer SAN/SNI handling and restart acceptance), then close. |
| GAP-0873 | Medium | Multi-tenant at-rest encryption | **Open/deferred.** FLE field keys are tenant-scoped, but graph storage and backups remain master-keyed at rest. `docs/security/MULTI_TENANT_HARDENING.md:357-428` states page/TDE storage uses one `GEODE_TDE_KEY` and that per-tenant at-rest encryption requires per-tenant page segregation; `docs/ADVANCED_SECURITY_FEATURES_OCTOBER_2025.md:58-63` and `docs/KMS_PROVIDER_SYSTEM.md:130-133` repeat that there is no per-database or per-tenant at-rest key; `docs/CAAST_TENANCY_FLE_FINDINGS_2026-06-08.md:121-137` records the tractable subset done but keeps per-page/per-tenant TDE and per-tenant backups deferred to GAP-0290. Source evidence matches that model: per-tenant derivation helpers exist (`src/security/tde.zig:433-522`, `src/storage/tde_file_encryption.zig:239-304`), but the production graph page path is per-graph and initialized with a single encryption key. **Verified 2026-06-11 (Task 40):** `docs/design/TDE_PER_TENANT_KEYS_DEFERRED.md` states the single-master-key limitation with the GAP-0290 pointer (lines 3-4, 17-34), and the cross-tenant decrypt-fail unit tests for the derivation helpers EXIST and run green: `tests/test_gap0843_tenant_tde.zig` (`zig build test-gap0843-tenant-tde`) pins tenant-A ciphertext failing under tenant-B's derived key (both directions, `error.AuthenticationFailed`), round-trip under the owner key, and a real `tde.encrypt_page` round-trip. | Redesign storage or backup layout so bytes known to belong to one tenant are encrypted under tenant-derived keys, or document single-master-key at-rest scope as a hard product limitation. Cross-tenant decrypt-fail tests at the derivation-helper level already exist (`test-gap0843-tenant-tde`); add equivalents for any NEW per-tenant backup/export/page-segregation path when it is built. |
| GAP-0885 | High | Security sibling gap backlog | **Open/partial — mostly closed 2026-06-10.** The 2026-06-10 round closed and moved to `GAP_ANALYSIS_RESOLVED.md`: session-token stderr leakage (`SEC-SESS-LOG-01`, commit `c28d94c6`), diagnostics URI escaping + loopback assertion for MCP/LSP no-auth + LSP bind-all regression guard (`LSP-SEC-005`/`LSP-SEC-008`/`SEC-LSP-BIND-01`, commit `2b03d9ad`), cluster bearer-token rotation (`SEC-INFRA-03`, commit `6ace7483`), S3 SigV4 migration + insecure-TLS flag gating (`SEC-S3-SIGV2-01`/`SEC-CLI-01`, commits `b79fc5f7`+`4a5f4bba`). The GAP-0818 MCP-LSP enforcement gate landed (unverified principal → no tenant-scoped LSP data; `zig build test-gap0818-gate`) with the verified-tenant-derivation residual still tracked. `docs/SECURITY_GAP_ANALYSIS.md` (open-only) still tracks: TOTP SHA-256/SHA-512/FIPS (`SEC-MFA-FIPS-01`), metrics endpoint auth (`SEC-MON-01`), nginx h2c residual (`SEC-INFRA-02`), vendored MCP constant-time compare fork-pin (`LSP-SEC-002`, mitigated/documented), and the GAP-0818 verified-tenant-derivation residual. `SEC-SUPPLY-01` (supply-chain CODEOWNERS) and `SEC-MIG-02` (migration CI guard) closed 2026-06-11 with GAP-0882. | Finish the remaining open rows (LSP-SEC-002 fork pin, SEC-MON-01/SEC-INFRA-02 deferred infra, GAP-0818 tenant derivation); keep `SECURITY_GAP_ANALYSIS.md` open-only. |
| GAP-0893 | High | gRPC transport / e2e verifiability | **ROOT CAUSE CORRECTED + FIXED 2026-08-25 (geode-side, not vendor).** The original diagnosis — "vendor `grpc_zig` 0.1.7 crashes in `allocStreamWindows` ← `initServerTls` ← `handleConnection`" — was **stale**: that crash was fixed upstream in `grpc_zig` v0.1.8 and geode has pinned **v0.1.9** since (`build.zig.zon:303`). (The v0.1.9 tag still declares `version = 0.1.8` internally, which is why the resolved hash reads `grpc_zig-0.1.8-*`; upstream cosmetics only, no pin change needed.) The surviving hang was **two geode-side defects**: (1) `grpc_tls.rawRead` built a fresh `[4096]u8` stack buffer + `Stream.Reader` on every call, and `std.Io.Reader.readVec` passes readv(2) BOTH the caller's buffer and its internal buffer — so every byte past `buf.len` landed in the stack-local and was destroyed on return. HTTP/2 peers always coalesce (preface+SETTINGS, HEADERS+DATA), so the server dropped the tail of each coalesced write and `readFrame` blocked forever. `rawRead` is now an unbuffered single-iovec `netRead` through the Io vtable, mirroring grpc-zig's own non-TLS `Transport.ioRead`; `rawWriteAll` was hardened the same way. (2) Behind that, `registerHandlers` registered a single handler named `"Packet"` while grpc-zig dispatches on an exact `Handler.name == :path` match, so every method received `grpc-status: 12` (UNIMPLEMENTED); handlers are now registered under their full `/geode.GeodeService/<Method>` paths. Evidence: `zig build test-grpc-raw-io` (socketpair red/green — the pre-fix `rawRead` hangs); `GEODE_CI_QUIC_SMOKE=1 GEODE_QUIC_PASSIVE_TEARDOWN=1 zig build test-transport-parity` now **12/12** with three lanes exercising a real QUIC-vs-gRPC comparison (was 10/12 + 2 silent gRPC skips). Residual harness-hygiene finding from the original session still stands: bash-type specs resolve a STALE `/usr/bin/geode` unless `${GEODE_BINARY}` is used (`auth_chain_cli_offline.yml` already fixed). | Re-run the geode-test-harness grpc specs with `--transport grpc` end-to-end and promote the 17 `src/transport/grpc_server.zig` CANARY markers against green runs. Audit remaining bash-type harness specs for hardcoded `geode` instead of `${GEODE_BINARY}`. |

| GAP-0514 | Medium | Governance — CANARY IMPL count | **Partial (reopened 2026-11-12, SONNY-6321).** Closed 2026-06-11 at 223/5,094 IMPL against the ≤250 / ≤5% acceptance target. The SONNY-738 sweep found TESTED markers whose cited tests never compiled or do not exercise the code: SONNY-6320 (ABAC-WIRE), SONNY-6374 (51 TEST= tokens naming missing files, eleven downgraded), and SONNY-6321 (`tests/test_tde_kms_integration.zig` tests TDEKeyManager only: eight TDE self-test procedure markers re-pointed to `test-sonny6321-tde-procedures`, three FLE markers to `test-fle-online-grant` / `test-gap0852` / `test-fle-lifecycle`, and REQ-TDE-PROC-046 plus eight FLE markers — AST, PARSER, STORAGE, BI-002, SCHEMA, EXECUTION, ADMIN, MIGRATE-CLI — downgraded to IMPL). `docs/status.csv` after the downgrades: 6,161 rows, 5,387 TESTED (87.4%), **267 IMPL (4.3%)** — above the ≤250 count, within ≤5%. SONNY-6378 then downgraded the 172 markers of the GAP-0193 batch 2 engine, misc, security and testing suites, whose cases only parse a query: `docs/status.csv` 5,896 rows, 5,042 TESTED (85.5%), **412 IMPL (7.0%)** — above both targets. SONNY-6321 then promoted REQ-TDE-PROC-046 and REQ-FLE-AST/PARSER/SCHEMA/BI-002/EXECUTION/STORAGE-001 against `test-sonny6321-tde-fle-cases` and `test-sonny6321-fle-schema-blind-index`; REQ-FLE-ADMIN-001 (fle_commands `rotateKey` printed a rotation it did not perform; SONNY-6386 makes it and `geode fle rotate-key` refuse as unsupported until SONNY-6387, the marker stays IMPL for the untested grant/revoke/migrate/show commands) and REQ-FLE-MIGRATE-CLI-001 stay IMPL: 5,900 rows, 5,053 TESTED (85.6%), **405 IMPL (6.9%)**. SONNY-6542/6548 then found 564 `tests/*.zig` files no build step compiled; the markers citing the files still listed in `scripts/ci/unreachable_test_sources.zig` say IMPL until they run. `docs/status.csv` regenerated 2026-11-15: 5,792 rows, 4,600 TESTED (79.4%), **871 IMPL (15.0%)**. SONNY-6321 (2026-11-16) then promoted REQ-FLE-ADMIN-001 against `test-sonny6321-fle-admin-cli` and downgraded REQ-FLE-MIGRATE-001, REQ-FLE-BATCH-001 and fle_commands' REQ-FLE-STORAGE-001 (the storage-callback migration no caller sets); `geode fle migrate-encrypt` is refused as unsupported, so REQ-FLE-MIGRATE-CLI-001 stays IMPL: 5,806 rows, 4,612 TESTED (79.4%), **873 IMPL (15.0%)**. | Write real tests for the IMPL markers (first: `tde.simulate_oltp_workload` happy path, and the eight FLE requirements through the parser, executor and storage), promote them against green runs, and close again when IMPL ≤ 250. |
| GAP-0897 | Medium | Observability — per-graph metrics name collision | **Open (found 2026-06-17).** `StorageAdapter.getOrCreateGraph` (`src/storage/graph_storage_adapter.zig:~4452-4475`) registers each ManagedGraph's counters into the global runtime-metrics registry under FIXED names (`reg.register("mg_merge_tuple_lock_acquired_total", &mg.…) catch {}`, and the whole `mg_rwlock_*` / `mg_merge_*` family). Registration is per-graph but the names are not graph-qualified, so the second-and-later graphs hit a duplicate-name error that is swallowed by `catch {}` — only the FIRST graph created (the default graph) is ever exported. Consequence: for any named graph (e.g. divelife) `mg_merge_tuple_lock_acquired_total` and the `mg_rwlock_*` waits always read the default graph's (here ~0 / idle) values, which is why GAP-0894's striping could not be observed and the original fix was mis-validated as working. | Register per-graph metrics under graph-qualified names (or aggregate across graphs into a labeled gauge), so each graph's `mg_*` counters are independently observable; add a test asserting a second graph's `merge_tuple_lock_acquired_total` is exported and non-zero after a striped MERGE. |
| GAP-0900 | High | Write throughput — single-threaded commit-path serialization | **PARTIAL — pragmatic fix shipped 2026-06-17 (commit `905fddfb`): opt-in `GEODE_WAL_SYNC=deferred` amortizes the per-op fdatasync → divelife seed ~38→~240 taxa/s (~6×), durable across clean restart; default unchanged. Architectural ceiling-lift (cross-shard group commit) still needed for `sync_each_commit` to scale. Root-cause evidence + fix detail in the "GAP-0900" section below.** Single-property bulk `MERGE` throughput is capped at **~1,100 ops/sec and does NOT scale with client concurrency**: a minimal `geodedb.com/geode` reproducer doing one `MERGE` per op sustains ~1,132 ops/sec at 16 connections, and the divelife `data-ingest` seed (rich 19-property taxon `MERGE` + edges, ~30 server ops/taxon) sustains ~36–39 taxa/sec — and crucially **16 connections and 128 connections (8 client processes × 16) give the SAME ~36 taxa/sec aggregate.** During the seed the server burns only **~0.7–0.9 of ONE core on a 24-core host** (23 cores idle), i.e. a single-threaded serial section in the write/commit path is the limiter, not CPU, disk, fsync coalescing, or checkpoints (all ruled out — see below). For the 14.27M-taxon divelife seed this projects to ~100 h end-to-end and makes practical bulk seeding infeasible. The `group_commit` coordinator (`src/storage/group_commit.zig`) is sharded (16 workers, 256-op batches, 1 fsync/batch) but its own header notes it degrades to "mostly single-op shard batches, paying one WAL commit per mutation" at low per-shard concurrency — and adding connections (128) did NOT raise per-shard batch density, so the serialization is upstream of/around shard batching. NOTE: not safely fixable by a speculative WAL/commit rewrite (durability/data-corruption risk); needs a profiler (host had `perf_event_paranoid=3`, perf unavailable) to pinpoint the serial section first. | Profile the write/commit path under a 16-connection single-property MERGE load on a machine with `perf` (or in-process sampling) to identify the single-threaded serial section (suspects: a global WAL append/fsync serialization, the group-commit submit/wait coordinator, or a graph-global structure under one lock). Then parallelize it across the thread pool and/or engage real fsync coalescing across concurrent committers, and re-run the 1/8/16/32/128-connection ladder + the `~/divelife-dump` seed to prove throughput scales. Fix GAP-0897 first so per-graph commit/lock metrics are observable during profiling. |

> **Follow-up note (2026-06-10) — RESOLVED 2026-06-11:** the `gql_conformance` T11/T12/T14 count-pushdown defect was assigned **GAP-0892** and closed (commit `8833fc4a`; row archived in [GAP_ANALYSIS_RESOLVED.md](GAP_ANALYSIS_RESOLVED.md)). The original lazy-on-disk-load diagnosis was corrected during the fix: the fast path was skipping the `SESSION SET PROPERTY GRAPH` preamble entirely.

Archived gap records have been moved to [GAP_ANALYSIS_RESOLVED.md](GAP_ANALYSIS_RESOLVED.md). This file intentionally contains only actionable open, partial, blocked, or deferred gaps.

## GAP-0900 — write-throughput serialization (full evidence, 2026-06-17)

**Severity:** High · **Status:** PARTIAL — pragmatic fix shipped (commit `905fddfb`); architectural ceiling-lift remains · **Area:** Storage / write + commit path.

### FIX SHIPPED 2026-06-17 — opt-in deferred WAL sync (`GEODE_WAL_SYNC=deferred`)

The per-op `fdatasync` wall is the dominant cost (proven below: ~1 fdatasync/op).
`graph_storage` already implements `SyncMode.deferred` (append the COMMIT record but
skip the per-commit fsync; durable at checkpoint / clean close / 16 MB·60 s
auto-checkpoint), intended for replayable bulk loads. geode now plumbs it via an
**opt-in** env knob `GEODE_WAL_SYNC=deferred` (`src/graph_store.zig`,
`initGlobalAdapter`); the **default is unchanged** (`sync_each_commit`, per-commit
fsync, NFR-SEC-003 intact).

Validated (`make release`, /var NVMe, GAP-0899-fixed build):

| Workload | default (each_commit) | `GEODE_WAL_SYNC=deferred` | speedup |
|---|---|---|---|
| raw single-prop MERGE, 16 conns | 1,107 ops/s, 1.04 fdatasync/op | 2,989 ops/s, 0.03 fdatasync/op | 2.7× (~32× fewer fsyncs) |
| divelife `data-ingest` (19-prop taxon + edges) | ~38 taxa/s (~100 h) | ~133–242 taxa/s (~16–29 h) | ~4–6× |

**Durability check:** 20,366 taxa → SIGTERM (graceful flush/checkpoint) → restart →
20,366 (zero loss). Crash-resilience for the seed = idempotent re-run from the dump +
the 16 MB/60 s auto-checkpoint. Server stable, 0 panics, 0 ingest errors.
**Use only for idempotent / replayable loads that checkpoint or cleanly close before
treating data as durable.** For the divelife seed: run the server with
`GEODE_WAL_SYNC=deferred`, ingest, then SIGTERM/clean-close (checkpoints) → durable.

**Remaining (why PARTIAL):** with fsync amortized the wall is now CPU/contention-bound
(~240 taxa/s) and still does not scale with cores — the architectural fix below
(cross-shard group commit + moving the bulk-edge path off the whole-graph exclusive
lock) is still required to make `sync_each_commit` throughput scale with concurrency.

### Symptom

Bulk write throughput is capped at **~1,100 server ops/sec** and is **flat with respect to client concurrency**. The divelife 14.27M-taxon seed (`data-ingest ingest --from-dump ~/divelife-dump`, rich 19-property `MERGE (n:Taxon {…}) SET …` + parent/rank edges) runs at **~36–39 taxa/sec**, projecting to **~100 hours** end-to-end. This was discovered while validating the GAP-0899 crash fix: with the crash gone the seed no longer dies, but it is throughput-bound.

### Environment

- Host: 24 logical cores, 93 GiB RAM. geode `make release` (ReleaseSafe), build `v0.7.1-29-g7dcac17e` (i.e. includes the GAP-0899 checkpoint-exclusive fix).
- Client: divelife `data-ingest` (`diver.dev/species` v0.1.2 pipeline) via `geodedb.com/geode` v0.1.23, and a minimal raw-`MERGE` Go reproducer using the same driver.
- Measurement: server-side `MATCH (n:Taxon) RETURN count(n)` delta over a fixed window after a warmup; raw reproducer counts its own successful `ExecContext` calls.

### Evidence 1 — throughput does NOT scale with client concurrency (the decisive result)

| Client configuration | Connections | Throughput | Notes |
|---|---|---|---|
| 1 × `data-ingest` `--workers 16` | 16 | ~38 taxa/sec | single process |
| 8 × `data-ingest` `--workers 16` (one per taxonomy source) | 128 | ~36 taxa/sec **(aggregate)** | 8 client endpoints; server UP, 0 panics, 1 client error |

8× the connections → **same aggregate throughput**. A bottleneck that does not move when concurrency goes 16→128 is a serial section, not a contended-but-parallel resource.

### Evidence 2 — server is single-thread bound, not CPU bound

During the seed the geode process used **~0.7–0.9 of ONE core** (`ps %cpu` ≈ 70–88%) on a **24-core** host — ~23 cores idle and the 64-worker thread pool largely unused. One thread is the limiter.

### Evidence 3 — server+disk are NOT the bottleneck (the client pipeline issues rich ops, but the server ceiling is the wall)

A minimal raw single-property `MERGE (x:RawProbe {k:?}) SET x.a=?` reproducer against the **same** server/disk sustained **~1,132 ops/sec** at 16 connections. The divelife seed's ~36 taxa/sec × ~30 server ops/taxon ≈ ~1,100 ops/sec — i.e. the seed is already at the server's per-op commit ceiling; both workloads hit the same ~1,100 ops/sec wall.

### Evidence 4 — storage backend changes the constant but not the ceiling shape

| Data dir | fsync latency (4 KiB, measured) | `data-ingest` throughput |
|---|---|---|
| `/tmp` (tmpfs / RAM) | ~0.001 ms (~870k/s) | ~128 taxa/sec |
| `/var` (NVMe, LUKS) | ~0.427 ms (~2.3k/s) | ~38 taxa/sec |
| `/home` (ext4 on LVM) | ~0.700 ms (~1.4k/s) | ~36 taxa/sec |

tmpfs (no real fsync) is ~3.5× faster, but `/var` (0.427 ms) and `/home` (0.700 ms) give nearly identical throughput despite a 1.6× fsync-latency difference — so it is **not** simple fsync-latency bounding either. Even tmpfs (128/sec) is far below the raw-MERGE ceiling, i.e. the rich-op path has its own serial cost.

### Ruled-out hypotheses (with evidence)

- **Checkpoints / persistence loop:** `--persist-interval 600000` (checkpoints effectively disabled) gave ~37 taxa/sec vs ~36 with the default interval — **no effect**. (The persist flag is honored: `cli_args` → `startPersistenceThread`, `src/server/main.zig:2092`.)
- **Statement batching / chunk size:** `--chunk-size 100` vs `--chunk-size 1000` → ~36 vs ~38 taxa/sec — **no effect**.
- **Client (data-ingest / driver):** during the seed the client process used ~13–18% CPU (idle-waiting on the server); the raw reproducer proves the driver can push ~1,132 ops/sec. The earlier "client deadlock" hypothesis was the GAP-0899 server crash, now fixed.
- **The GAP-0899 checkpoint-exclusive lock:** on tmpfs it does cost ~2× (252→128 in the pre/post comparison), but on a real disk throughput is ~36/sec with checkpoints on OR off, so it is not the dominant real-disk limiter.

### `group_commit` analysis

`src/storage/group_commit.zig` is designed to coalesce: 16 shard workers, each draining up to `max_batch = 256` ops into one statement transaction = **one WAL fsync per shard-batch**, with a `default_shard_coalesce_wait_us = 500` accumulation window. Its own header comment (lines ~44–50) records the failure mode: at low per-shard concurrency it produces "mostly single-op shard batches, paying one WAL commit per mutation." Critically, driving 128 connections (≈8 ops/shard) did **not** raise batch density or throughput, so either the coalescing window never fills (synchronous clients wait for each commit before issuing the next op on a connection → no queue builds per shard) or the serialization is upstream of shard batching. `GEODE_SHARD_COALESCE_WAIT_US` (cap 5000) did not help because there are no concurrent same-shard ops to batch.

### Impact

The 14.27M-taxon divelife seed projects to **~100 hours** at ~38 taxa/sec; practical bulk seeding of a real corpus is infeasible until this is addressed. Correctness is unaffected (the seed completes; it is just slow). The single-property exclusive-lock and GAP-0894 striping are NOT the cause (separately disproven).

### ROOT CAUSE — PROVEN 2026-06-17 (perf + bpftrace, after `make deps` installed them)

`make deps` was fixed to install `perf`/`bpftrace`/`bpfcc-tools` on Debian/Kali and to
lower `kernel.perf_event_paranoid` (commit `6d269629`), which unblocked the measurement.

**The wall is ~1 `fdatasync` per write op, with no cross-shard coalescing:**

- **bpftrace (decisive):** a steady 16-connection single-property `MERGE` load did
  **16,607 ops and 17,234 `fdatasync` calls in the geode process — ~1.04 fdatasync/op.**
  (`bpftrace -e 'tracepoint:syscalls:sys_enter_fdatasync /comm=="geode"/{@=count()}'`.)
- **Why single-op batches:** the group-commit coordinator IS enabled and on-path, and
  it batches *within a shard* (one statement txn → one WAL fsync per shard-batch). But
  the engine is **16 shards, each with its OWN independent GraphEngine + WAL**, and a
  `MERGE` is routed to a shard by `hash(merge_key)` (required so same-key writers
  serialize). With 16 connections writing **distinct** keys, the 16 ops fan out to 16
  shards → **1 op per shard per coalesce window → 1 fsync per op.** The coordinator's
  per-shard batching can never accumulate >1 op for a distinct-key MERGE stream.
- **More concurrency makes it WORSE, not better:** 16 conns ≈ 1,100 ops/sec; **64 conns
  (4×16) ≈ 479 ops/sec aggregate, still ~1 fdatasync/op** — added lock/allocator
  contention with zero coalescing benefit. So this is NOT fixable by offering more
  concurrency.
- **Tuning knobs do NOT help:** `GEODE_GROUP_COMMIT_ACTIVE_SHARDS=2` left MERGE at
  ~1,088 ops/sec, ~1 fdatasync/op (the knob concentrates *reserve-id*/CREATE sharding,
  not `hash(merge_key)` MERGE sharding). `GEODE_GROUP_COMMIT_COALESCE_US` cannot help
  because no shard ever has >1 concurrent op to coalesce.
- The earlier off-CPU `acquireGraphWriteLockCancelable` blocking corresponds to the
  **bulk EDGE path** (`quic_connection_handler.zig:800`) which takes the whole-graph
  EXCLUSIVE lock — a real *secondary* serialization for edge-heavy loads (e.g. the
  divelife parent edges), separate from the fsync wall.

### Why not fixed yet

The fix is an **architectural change to the WAL/commit path — the highest-risk area in
the engine (durability / data corruption)** — and it lives in the vendored
`graph_storage` dependency (16 independent per-shard WALs), not just geode's adapter. A
correct fix must batch `fdatasync` **across shards** without breaking per-shard WAL
ordering or crash recovery, then be validated for both correctness (crash/recovery
tests) and throughput. That is a focused, benchmark-driven effort that must not be
rushed or shipped unvalidated; this session's host became too unstable for reliable A/B
benchmarking (fresh servers intermittently failed to initialize under the accumulated
experiment load). Root cause is proven; the implementation is deliberately deferred to a
stable, dedicated effort rather than risk an unvalidated WAL change.

### Concurrency characterization — 2026-06-17 (later, perf/bpftrace/microbench)

The ceiling is a **stack of serializations**, not one bottleneck. Measured on /var (NVMe
ext4), 16-connection distinct-key MERGE, geode `905fddfb`:

| variable removed | ops/sec | factor |
|---|---|---|
| baseline (`sync_each_commit`, 500 µs coalesce) | ~1,030–1,107 | 1.0× |
| `GEODE_GROUP_COMMIT_COALESCE_US=0` | ~1,436 | 1.4× |
| `GEODE_WAL_SYNC=deferred` (no per-op fsync) | ~2,989 | 2.7× |
| **OS `fdatasync` ceiling (16 concurrent, ext4)** | **~15,777** | (target) |

Decisive microbenchmark (`/tmp/fsynctest.c`): **ext4 batches concurrent `fdatasync`s** —
1 thread = 1,995/s, 16 threads = 15,777/s (~8×), 32 = 33,122/s. So the 16 per-shard WALs
*could* sustain ~16k fsync/s **if the shard commits ran concurrently**. They do not: the
coordinator runs 16 dedicated shard-worker threads (17-thread pool), but the
single-property MERGE stream is throttled to ~1,030 ops/sec (≈ one thread's fsync rate),
i.e. a serialization keeps the per-shard `fdatasync`s from overlapping. Layers found:
(a) the 500 µs coalesce window adds pure per-op latency for the synchronous distinct-key
case (no batch to fill) → ~1.4×; (b) per-op fsync inside the commit critical section
prevents fsync overlap → another ~2×; (c) a residual ~3,000 ops/sec CPU/lock ceiling
remains even with fsync removed (deferred), seen in perf as CRC32 (~18%),
`NodePropertyExactIndex.add`, wyhash. Off-CPU sampling could not isolate (c)'s lock on
this host (threads block too briefly / contend on-CPU); it needs a stable bench host.

### Recommended fix / required completion

1. **Make per-shard commit fsyncs overlap (primary).** ext4 already batches concurrent
   `fdatasync`s ~8–16×, so the fix is to stop serializing them: move the `fdatasync` out
   of the per-op commit critical section into a **cross-shard group-commit barrier** —
   shard workers append COMMIT (no fsync) and park; a coordinator fsyncs all dirty shard
   WALs **concurrently** (16 syscalls the OS coalesces into ≈1 journal commit), then acks
   all parked submitters whose LSN is now durable. This keeps per-commit durability (ack
   after fsync) while amortizing to the ~16k/s ceiling. Recovery is unchanged (same WAL
   records; only un-acked/un-fsynced commits are lost on crash — exactly the existing
   `deferred` semantics, but acked commits stay durable). Also make the coalesce window
   adaptive (skip it when the shard queue holds ≤1 op) for the secondary 1.4×.
2. **Secondary:** convert the bulk EDGE path (`quic_connection_handler.zig:800`) off the
   whole-graph EXCLUSIVE lock onto the shared+striped path the node bulk path uses, so
   edge-heavy ingests (divelife) aren't additionally serialized.
3. Fix **GAP-0897** first so per-graph `coord_*` / `mg_*` batch-density + commit metrics
   are observable (validate fsync/op and ops/batch directly).
4. **Validate** with the connection ladder (1/8/16/32/64/128) + the `~/divelife-dump`
   full 14.27M seed: require fsync/op ≪ 1, throughput scaling with concurrency, no
   low-concurrency regression, AND crash/recovery correctness tests green.

Profiling toolchain is now available locally (`perf` 6.19, `bpftrace`, `bpfcc-tools`,
`offcputime-bpfcc`; `kernel.perf_event_paranoid=1`) — see commit `6d269629`.

### Implementation attempt + RESULT — 2026-06-17 (cross-shard group commit does NOT help; reverted)

The cross-shard group-commit barrier from recommendation #1 was fully implemented and
benchmarked, then **reverted** because it does not beat the existing `deferred` mode at
the relevant concurrency. Implementation: `graph_storage` `ShardedGraphEngine.syncShard(idx)`

- a geode opt-in `GEODE_WAL_SYNC=group` where shard workers commit deferred (no per-op
fsync), rendezvous in a short bounded window so their per-shard `fdatasync`s overlap
(ext4 coalesces concurrent fsyncs ~8–16×, proven by `/tmp/fsynctest.c`), then ack only
after the fsync (durable; recovery unchanged).

A/B at 16 connections, raw single-property MERGE (`make release`, /var NVMe):

- `sync_each_commit` (default): **~1,673 ops/sec**
- `group` (window 200µs): **~1,568 ops/sec** (slower than each_commit)
- `group` (window 100 / 400µs): ~1,461 / ~1,346 ops/sec
- `deferred`: **~2,431 ops/sec**

**Why it fails:** the gain a group commit can capture is the fsync cost, which at this
concurrency is only the `each_commit → deferred` gap (~1,673 → ~2,431, i.e. **~1.45×**).
And it can't even capture that: with 16 *synchronous* connections the effective number of
commits in flight at any instant is ~1–2 (each connection spends most of its ~5 ms/op
cycle in processing + round-trip, only ~0.5 ms in fsync), so there is **almost never more
than one fsync to coalesce** — the rendezvous window is then pure added latency and `group`
lands *below* `each_commit`. Higher offered concurrency does not rescue it: 64 connections
*degrades* every mode (contention), so there is no operating point where coalescing wins.

**Corrected conclusion:** the throughput ceiling at the divelife seed's concurrency is
**per-op CPU/processing (~2,431 ops/sec = the `deferred` ceiling)**, NOT WAL fsync. perf at
that ceiling: CRC32 ~18% (two polynomials), `NodePropertyExactIndex.add`, wyhash. fsync is
a secondary ~1.45× factor that the shipped **`GEODE_WAL_SYNC=deferred`** already captures
for replayable bulk loads (its 6× on the seed comes from removing fsync *and* the
checkpoint-lock interplay). A durable mode cannot exceed `deferred`'s throughput here, so
group commit was not worth its complexity/risk and is not shipped. Remaining real levers
(separate, lower-yield, deferred): (a) cut per-op CPU — hardware CRC32C, cheaper exact
property-index insert; (b) move the bulk-EDGE path off the whole-graph exclusive lock for
edge-heavy ingests; (c) a true client batch protocol so writes aren't 1-op synchronous
round-trips (the only thing that would create the concurrency a group commit needs).

### Lever (a) follow-up — per-op CPU: the dominant cost was a per-poll memset, not CRC (2026-06-17)

Re-profiling the `deferred` ceiling on the shipped **ReleaseSafe** build (not an
earlier optimize mode) changed the picture: `compiler_rt.memset` was **44% of total
process CPU**, dwarfing CRC. The breakdown: **~31% inside the QUIC poll loop**
(`endpoint.Endpoint.pollWithStats` ← the 16 poll worker threads) and **~6.7% in the WAL
append path** (`wal.WalManager.appendRecord`).

Root cause of the poll-loop share: `pollWithStats` declared its 64×4096-byte receive
scratch as a stack local `var recv_bufs: [UdpBatchCap][4096]u8 = undefined` (256 KiB).
In ReleaseSafe a stack `= undefined` is filled with the 0xAA sentinel **on every call**,
so each poll cycle memset 256 KiB that `recvBatch` then immediately overwrites — pure
waste, paid per poll across 16 threads.

**Fix (quic `a53197a`, branch `gap0900-pollbuf` off the v0.1.30 pin):** move the scratch
to `threadlocal` static storage. Release builds run 16 poll workers on the *same*
endpoint concurrently, so the buffer must be per-thread (a single shared heap buffer
raced and corrupted received packets → `Utf8ExpectedContinuation` panics in the GQL
lexer). `threadlocal` matches the old per-call stack isolation but pays the undefined-fill
**once per thread at TLS setup** instead of once per poll.

**A/B (geode ReleaseSafe, `GEODE_WAL_SYNC=deferred`, baseline = same binary pre-fix
captured via `/proc/<pid>/exe`):**

- perf: `compiler_rt.memset` **44% → 17.7%**; the poll-loop memset is gone from the call
  graph — the residual 17.7% is now entirely the WAL `appendRecord` stack buffer.
- Poll-bound `RETURN 1` bench (32 conns, interleaved A/B ×3, drift-cancelling):
  **+14.8% mean throughput** (min(fixed) 61,675/s > max(baseline) 57,049/s, no overlap).
- Write-bound `MERGE` bench: throughput delta within run-to-run noise (~30%) — expected,
  since MERGE is WAL/commit-bound, not poll-bound; the freed poll-thread CPU does not
  raise a workload whose wall is elsewhere.
- Correctness: 300K+ MERGE + 180K+ RETURN 1 ops with zero corruption; round-trip
  read-back exact; 423,990 nodes intact; `zig build test` (quic) passes.

**Takeaway:** a real, low-risk CPU-efficiency win that frees ~31% of every poll thread's
CPU and gives ~+15% on poll/read-bound traffic — valuable on loaded multi-tenant servers
even though it does not move the WAL-bound bulk-seed number. **Status: committed in quic
locally (`a53197a`), pending release** (push + tag `v0.1.31` + bump the geode `.quic` pin
hash). The next per-op-CPU target is the WAL `appendRecord` stack buffer (the residual
17.7% memset). Hardware CRC32C is now lower priority — CRC was not the dominant cost.

### Lever (b) follow-up — bulk-EDGE lock: already on the shared+striped path (2026-06-18)

Hypothesis: bulk edge inserts take the whole-graph EXCLUSIVE lock
(`acquireGraphWriteLockCancelable`) and should move onto the same shared+striped
path node inserts use. Investigated + **empirically verified — for the seed's edge
shape it is already on the striped path**, so no change is warranted.

Findings:

- `group_commit.isEnabled()` returns **true by default** (only an explicit
  `GEODE_GROUP_COMMIT` disable value turns it off). The handler has single-statement
  fast paths — `executeBulkInsertNode`, `executeBulkMatchCreateEdge`,
  `executeBulkMergeNode` (`src/server/quic_connection_handler.zig` ~504/~683/~932) —
  each of which, when group commit is on, submits to the `ShardedCoordinator` instead
  of taking the exclusive lock.
- The divelife seed's edge statement (`internal/geode/taxon.go`) is a single
  `MATCH (a:Taxon {…}), (b:Taxon {…}) CREATE (a)-[:PARENT_OF {…}]->(b)` — exactly the
  `executeBulkMatchCreateEdge` shape.
- perf on an edge-only workload of that exact shape (16 conns, default config,
  `GEODE_WAL_SYNC=deferred`): **0 samples in `acquireGraphWriteLock`** vs **85 in the
  group-commit edge path**. Full stack: `executeBulkMatchCreateEdge →
  ShardedCoordinator.submit → applyShardBatch → bulkInsertEdgeWithIdsShardLockedForTenant
  → bulkInsertEdgeInnerShardLocked → addEdgeTxn` (shared graph lock + 1–2 per-shard
  striped locks; all edge state — `edge_index`, `adj_out/in`, node head pointers,
  `manifest.next_edge_id/edge_count` — is per-shard, so striping is safe).
- The exclusive lock only appears for **multi-statement / general mutations** that miss
  every fast path (verified: a 3-`MERGE` edge program does take it, via the general
  write path `quic_connection_handler.zig:433-434`). The seed does not use that shape.

Conclusion: the bulk-edge lever is already satisfied for single-statement edge creates
(the seed's pattern). Moving the *general* multi-statement path off the exclusive lock is
a much larger, riskier change (it is the arbitrary-mutation catch-all and is intertwined
with the GAP-0899 checkpoint/`label_index` exclusive-lock invariant) and is out of scope
for an edge-specific lever — so no code change. The remaining write-throughput wall is the
per-op/round-trip ceiling (lever c).

### Lever (c) — client batch protocol: SHIPPED + validated (2026-06-18)

Lever (c) is the batch/pipeline write protocol — the only thing that creates the
same-shard write concurrency the `group_commit` coordinator needs to coalesce fsyncs
(the cross-shard group-commit attempt was reverted precisely because synchronous
1-op-per-round-trip clients never build a per-shard queue).

**Root cause now MEASURED (not just inferred).** Read the coordinator counters via the
Prometheus endpoint (`GEODE_METRICS_PORT`) — `coord_apply_ops_total /
coord_apply_batches_total` is the average ops-per-shard-batch (= ops per fsync in
sync_each_commit). Single-property node `MERGE`, 16 connections, fresh graph:

- `sync_each_commit`: 977 ops/s, **avg batch = 1.03** (29,515 ops / 28,578 batches)
- `deferred`: 1,335 ops/s, **avg batch = 1.05** (40,290 ops / 38,522 batches)

The coordinator is coalescing essentially nothing: ~1 op per batch ⇒ ~1 fsync per op in
the durable mode. Raising `GEODE_SHARD_COALESCE_WAIT_US` cannot help — with synchronous
clients the next op on a connection is not issued until the previous one's response
returns, so ops never overlap within the window regardless of its length. This is the
definitive confirmation that the write ceiling is the synchronous round-trip, and that
group commit is dead weight until concurrency exists.

**Why it can't be a minimal change.** The wire protocol carries one statement per
`ExecuteRequest` (`proto/schema.zig`); multi-statement GQL programs *parse* (parser.zig
`parseProgram` loops) but *execute serially* (`execution.zig` `executeProgramWithContext`
loops one statement at a time), and the Go driver's `BatchExec` wraps N statements in a
txn but still sends N round-trips (`conn.go` one send + one receive per `ExecContext`).
None of these submit concurrent same-shard ops, so none move avg-batch off ~1.

**Implementation (shipped).** Rather than a new wire opcode + driver change, the concurrency
is created with a server-side concurrent-submit path that needs no protocol change:

- `ShardedCoordinator.submit` (src/storage/group_commit.zig) was split into `submitNoWait`
  (per-thread prepare — tenant capture + node-id reservation — then enqueue + signal) and
  `awaitOp` (block on the `ApplyOp.done` futex). `submit` is now `submitNoWait` + `awaitOp`,
  so single-op behavior is unchanged.
- `executeBatchSimpleMerge` (src/server/quic_connection_handler.zig) classifies every
  statement of the program (via the new per-statement `matchSimpleNodeMergeSpecStmt` in
  bulk_ingest.zig), builds all N `ApplyOp`s into one arena, `submitNoWait`s them ALL (so they
  pile into the per-shard queues and the coordinator coalesces them), then `awaitOp`s all and
  sends one no-RETURN response. Falls back to the general executor (no side effects, no
  response) if group-commit is off or any statement is not a simple node MERGE.
- Opt-in with no wire/driver change: a `/*+BATCH*/` sentinel prefix on the query text (a
  block comment the lexer already strips) routes the program here. The default path (no
  sentinel) is byte-for-byte unchanged. All prepare stays on the handler thread; no threads
  are spawned — concurrency is purely "enqueue all, then await all".

**Validation (make-release build; fresh copy of the provisioned graph; batch=100):**

- Coalescing: avg ops-per-shard-batch **1.09 → 12.76** (coordinator `coord_apply_*` counters).
- Throughput `deferred`: **2,864 → 7,340 ops/s (~2.5×)**, 16 conns → 8 conns batched.
- Throughput `sync_each_commit` (durable, the real target): **1,688 → 6,225 ops/s (~3.7×)** —
  fewer fsyncs per op, exactly the predicted durable-mode lift.
- Correctness: a batch of 50 distinct keys each with a distinct value round-trips exactly
  (0 missing / 0 wrong); `coord_apply_ops_total` equals submitted statements on every run
  (0 errors); no panic; default single-MERGE path unaffected; coordinator unit tests pass.

Caveats: best operating point is moderate concurrency × batch size (e.g. 8 conns × 100);
piling more connections on top of batching hits diminishing returns. The sentinel form shares
one param set across the program, so the current path suits literal/templated multi-statement
batches; a driver `BatchExecute` helper and per-statement params are a clean follow-up but were
not needed to land or prove the win.

### Deferred-mode checkpoint cadence — SHIPPED + validated (2026-06-18, fix `4020356c`)

Running the full 13M `--from-dump` ingest (deferred mode, 16 workers) surfaced a separate
scaling wall: server RSS grew unbounded (12.6 GB at ~254K nodes, ~50 KB/node) and throughput
decayed (5,000 → 567 ops/s), heading to OOM; **zero checkpoints fired** in 6 minutes.

Root cause (triaged — the initial "checkpoint exclusive-lock starvation" hypothesis was
disproven; the per-graph `std.Io.RwLock` is writer-fair): the group-commit bulk fast path
writes through the engine-backed adapter but calls NEITHER `notifyMutation` (legacy CDC WAL)
NOR sets `GraphStore.dirty`. `persistenceLoop`'s two checkpoint triggers are gated on exactly
those signals, so `checkpointAll` is never invoked between startup and shutdown during a pure
bulk ingest → engine WAL + dirty pages grow without bound. Compounding it, the timer-based
persistence loop is itself starved under sustained ingest (its futex-timeout tick never fires
when all I/O workers are busy — 0 ticks in 3 min at the 30 s interval).

Fix (geode-only, no graph-storage change): make checkpointing **load-driven** from the bulk
write path. The adapter counts `pending_bulk_ops` on every applied bulk node/edge op and, once
it crosses `GEODE_CHECKPOINT_OPS` (default 50,000 ≈ 16 MB WAL) or `GEODE_CHECKPOINT_INTERVAL_MS`,
the first thread to win a `checkpoint_in_progress` CAS runs `checkpointAll` inline — AFTER the
bulk helper's shared rwlock + shard locks are released (checkpointAll needs the exclusive lock,
so triggering in-lock would self-deadlock) — while other writers proceed. The persistence loop
calls the same `maybeCheckpoint` decision as a backstop. Observability: `checkpoints_total`,
`pending_bulk_ops`.

Validated: a sustained deferred MERGE load now truncates the engine WAL on a sawtooth and bounds
RSS to ~1.4 GB at 137K nodes (~10 KB/node) vs the old 12.6 GB at 254K, with checkpoints firing
(0→2 over the run); data correct; coordinator/merge/wal/adapter test suites green; new regression
test `zig build test-gap0900-deferred-checkpoint` (RED before, GREEN after). Tune `GEODE_CHECKPOINT_OPS`
lower for tighter memory / higher for fewer checkpoint pauses.

**Residual (Layer 2 — was OPEN after the trigger fix; CLOSED 2026-06-18 by incremental checkpoint + backpressure, see below):**
The trigger fix closes the primary cause (checkpoints were firing ZERO times — now they fire), but
a sustained **rich, sharded** ingest (the real divelife `col` taxa: 2-key coalesce MERGE, ~14 KB
WAL/op, divelife sharded into ~16 engines) still grows RSS at scale because the per-graph checkpoint
is **O(total graph size)** (`engine.checkpoint() → label_index.saveToFile → scan()` rewrites the
whole index each time), so it cannot keep pace with sustained writes — and in deferred mode the
buffer pool cannot evict dirty pages until they are checkpointed. Measured: default
`GEODE_CHECKPOINT_OPS=50000` → only 2 checkpoints in 316K ops, per-shard WAL ~290 MB, RSS ~11.7 GB.
Aggressive `GEODE_CHECKPOINT_OPS=3000` → 38 checkpoints, total WAL bounded better (89→366 MB) but
still rising, RSS ~7.2 GB at 120K nodes (~60 KB/node) and climbing. So the full 13M ingest still
heads to OOM, just slower. The simple single-key path (e.g. `MERGE (n:N {k:?}) SET n.a=?`) DOES
sawtooth/bound cleanly (small WAL/op), so the trigger fix fully solves moderate/non-rich workloads.
Proper close for 13M-scale needs **incremental/bounded checkpointing** (flush only dirty pages,
O(dirty) not O(graph) — and/or WAL rotation + dirty-page write-backpressure so memory is hard-capped)
in graph-storage.

**Layer-2 fix SHIPPED 2026-06-18 — incremental checkpoint (A) + write-backpressure (B):**

- **(A) Incremental "light" checkpoint** — graph-storage **v0.2.3** (`98f179b`): `engine.checkpointLight()`
  / `sharded_engine.checkpointLight()` flush dirty pages + truncate the WAL but SKIP the O(graph)
  derived-index re-save; recovery rebuilds those indexes from pages when stale (engine.zig:335-337,
  already present). geode `9df76443` pins v0.2.3 and routes the load-driven periodic checkpoint
  (`maybeCheckpointInline`) through the light path; clean shutdown / DDL keep the FULL checkpoint so a
  clean restart loads without a rebuild. Light path also skips geode's O(graph) `prop_exact.idx`
  re-serialize (reopen rebuilds). Validated: real `col` ingest reached **865K nodes (3.4× past the
  prior ~254K OOM point)**, sub-linear KB/node, WAL truncated on a sawtooth, checkpoint cadence keeping
  pace; clean restart recovered exactly (865,600 nodes).
- **(B) Write-backpressure** — geode `7730cac8`: hard-cap un-checkpointed work (`GEODE_CHECKPOINT_MAX_PENDING`,
  default 4× `GEODE_CHECKPOINT_OPS`); when exceeded and a checkpoint is in progress, the writer blocks
  (bounded spin) until it drains. Guarantees the dirty-page/WAL set can never blow up under a cadence
  stall (OOM safety net). Validated: ingest progresses with no hang under a tight cap.

**Remaining limit (Layer 3 — index memory, NOT WAL/checkpoint):** with A+B the WAL/dirty-page growth
is bounded, but RSS still tracks the **in-memory derived indexes** at ~8 KB/node (the buffer pool is
already capped at ≤512 MB/engine; the marginal growth is label/property/edge index maps held in RAM).
At ~8 KB/node a full 13M ingest needs ~110 GB+ on this 93 GB box → still OOMs. Closing 13M-on-this-box
needs one of: disk-backed/bounded derived indexes (graph-storage architecture change), more RAM, or
operationally sharding the ingest into smaller per-run graphs. A+B remove the unbounded-WAL OOM and
multiply the feasible single-run scale (≥3.4×); Layer-3 (index memory) is the next tracked item.

### Layer-3 memory bounds — shipped 2026-06-18 (branch `gap0900-l3-memory-bounds`)

Two of the three triaged Layer-3 levers shipped; the third is documented as read-path-blocked.

- **Fix 1 (default-on): bytes-bounded shared AST cache.** `SharedAstCache` evicted only on a
  2048-**entry** count cap (`src/server/query_ast_cache.zig`, `server_init.zig:544`). On the batch
  ingest each cached AST is a ~100-MERGE×19-SET program whose parse arena is ~MB, so the count cap
  admitted ~8 GB of cached ASTs — a fixed RSS constant. Now the cache also evicts the LRU tail until
  total cached bytes (arena `queryCapacity()` + query text + per-entry overhead) are under
  `GEODE_AST_CACHE_BYTES` (default **256 MB**; `0` disables → count-only legacy behavior). Only
  eviction policy changed; results are identical, so it is default-on. Turns the ~8 GB constant into
  ≤256 MB. Test: `zig build test-gap0900-ast-cache-bytes`.
- **Fix 2 (opt-in: `GEODE_INDEX_MERGE_KEYS_ONLY=1`, default OFF): lean indexing.** Every SET property
  was added to BOTH geode's exact node-property index (~820 B/node) and GraphStore's `merge_prop_index`
  (~262 B/node), but only the MERGE key (`taxon_id`) is ever looked up (dedup + edge-endpoint
  `MATCH (a:Taxon {taxon_id: ?})`). The other 19 props are dead index weight (~1 KB/node). In lean mode
  a single gate (`graph_store.shouldIndexProperty`) skips non-merge keys in both indexes; both MERGE
  paths (bulk fast path + regular executor) register their pattern keys first so dedup still works.
  Read-path safety: the point-read fast path (`planned_read_runtime.fp:`) treated an empty exact-index
  result as authoritative — wrong for an unindexed key — so it now skips the fast path for non-indexed
  keys and falls back to a label scan (correct, just not O(1)). Default OFF ⇒ plain server unchanged.
  Test: `zig build test-gap0900-lean-index` (incl. executor-level dedup / point-read-by-non-merge-key).
- **Fix 3 (NOT shipped — read-path-blocked, documented): legacy GraphStore node mirror.** The triage's
  highest-value lever (~3.5 KB/node) was to stop the bulk path populating the legacy in-memory
  `GraphStore.nodes` mirror + per-node `properties` map. Investigation of the read paths
  (`graph_store.zig`, `match_operations.zig`, `planned_read_runtime.zig`, the adapter) shows the mirror
  is the **live read source of truth even for bulk-created nodes**, NOT dead weight:
  - `getNodeProperty` (`graph_store.zig:3602`) reads `node.properties.get(key)` — every
      `RETURN n.foo` property read comes from the mirror.
  - `lookupMergeCandidate` (`graph_store.zig:2921`) reads `self.nodes.get(node_id)` to verify a
      MERGE-dedup candidate exists and matches the graph.
  - `countNodes`/`countNodesByLabel` (`graph_store.zig:3930`) use `self.nodes.count()` and read
      `node.tenant_id` for tenant-scoped counts.
  - `getNodesByLabels` reads the mirror for tenant filtering; `bulkInsertEdgeWithIds`
      (`graph_storage_adapter.zig:2822`) re-checks `store.nodes.getPtr` for endpoint existence.
  Removing the mirror for bulk nodes would break property reads, MERGE dedup, count, tenant-scoped
  MATCH/count, and edge-endpoint re-checks. A safe lean variant would require routing ALL property
  reads (~40 call sites in `match_operations.zig`), count, and tenant filtering through the
  engine/adapter — a large, high-correctness-risk change that exceeds a minimal, safe fix. The engine
  is **not** a complete read path for these today. Tracked as the next architectural item; needs a
  coordinated graph-storage read-through API before the mirror can be made lean. NO graph-storage pin
  bump was required for Fix 1 or Fix 2 (both are geode-side only).

A/B (real `~/divelife-dump` `col` seed, `GEODE_WAL_SYNC=deferred`, 16 workers, RSS sampled vs
`MATCH (n) RETURN count(n)`):

| build | nodes reached | RSS @ ~210 K nodes | peak RSS | outcome |
|-------|---------------|--------------------|----------|---------|
| baseline (main) | OOM-capped ~212 K | **11.5 GB** | 12.9 GB (cap) | hit 12 GB before 250 K |
| + Fix 1 (default) | **478 K (full `col`)** | **~3.3 GB** | **7.65 GB** | ~3.5× lower RSS at equal node count; finished the dataset |

bytes/node falls monotonically with Fix 1 (the ~8 GB AST constant is gone): ~25.6 KB/node at 83 K →
~13.3 KB/node at 362 K and still dropping. Fix 2 (`GEODE_INDEX_MERGE_KEYS_ONLY=1`) removes a further
~1 KB/node of derived-index entries on top of Fix 1. Correctness verified on each build: `count(n)`,
property read by merge key, point-read by a non-merge key, MERGE dedup (re-MERGE same `taxon_id` →
count unchanged, exactly one node per key), and clean-restart reopen recovery.

**Recommended data-ingest seed settings:** `GEODE_WAL_SYNC=deferred` (Layer-2) + default
`GEODE_AST_CACHE_BYTES=256MB` (Fix 1, automatic) + `GEODE_INDEX_MERGE_KEYS_ONLY=1` (Fix 2, opt-in) —
the ingest only ever looks up Taxon nodes by `taxon_id`, so lean indexing is safe for this workload
and removes the dead 19-property index weight.

### Reproduction

```sh
# Server (fixed build) on host loopback, NVMe data dir:
GEODE_ADMIN_PASSWORD=seed GEODE_ALLOW_INSECURE_TLS=1 \
  ./zig-out/bin/geode serve --listen 127.0.0.1:3150 --data-dir /var/tmp/seed --log-level warn

# Seed (single process, 16 conns):
data-ingest ingest --geode-dsn "localhost:3150?insecure=true&user=geode&pass=seed" \
  --geode-graph divelife --from-dump ~/divelife-dump --workers 16 --chunk-size 100
# Watch: MATCH (n:Taxon) RETURN count(n) grows ~36–39/sec; server uses <1 core of 24.

# Concurrency-scaling check: launch 8 processes, one per taxonomy source
# (each --species-data <dir-with-one-source>, 16 workers) → aggregate stays ~36/sec.
```
