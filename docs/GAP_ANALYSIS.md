# Gap Analysis

Last updated: 2026-06-17
Audited by: 2026-06-10 docs/specs/source/dependency reconciliation, including open residuals from `docs/*_GAP_ANALYSIS.md`. 2026-06-16 addendum: a 14.27M-node divelife bulk-seed stress run against `geodedb/geode:dev` surfaced GAP-0894/0895/0896. **2026-06-17 correction:** a controlled host A/B (below) showed the 2026-06-16 GAP-0894 "reopen" was a **measurement error** — the ~50 nodes/sec was measured against the server *in a Docker container* (UDP-NAT round-trip latency), not the single-property lock. The unmodified server on the host does ~255–259 nodes/sec for the same workload at 8 connections, and a striped single-property handler patch tried this session **regressed that 2× (→~130) and was reverted**. GAP-0894 (the lock) is NOT the normal-concurrency bottleneck and stays **closed**. The high-connection ingest "stall" was first (mis)attributed to the `data-ingest` client because a 2-process × 16-worker run happened to sustain ~259 nodes/sec; that was a **lucky non-crash run** — the true cause is **GAP-0899 (Critical), now CLOSED (commit `7dcac17e`): a server CRASH**. Under high write concurrency the periodic checkpoint took `mg.rwlock` SHARED while the bulk writers also hold it SHARED and mutate `label_index`/`edge_index`, so `checkpointAll → … → label_index.scan()` raced a concurrent `addNode()` and panicked with `index out of bounds`, killing the process; the "0 nodes/sec freeze" was the server dying under the load. Fixed by making the checkpoint take the EXCLUSIVE lock (validated crash-free at 64 concurrent writers on host + container, full test suite green). Two further geode-side findings from the run: **GAP-0897 (Medium): a per-graph metrics name-collision** that masked the original GAP-0894 validation, and a non-crashing residual driver multi-stream behaviour tracked as geode-client-go **BUG-0002**. GAP-0895/0896 remain genuinely fixed; the `data-ingest` connection-pool clamp (≤16) is retained as a sensible client default. See [GAP_ANALYSIS_RESOLVED.md](GAP_ANALYSIS_RESOLVED.md) for GAP-0899 detail.

## Summary

This live register is authoritative as of 2026-06-11 (round close-out). Archived material has been moved to [GAP_ANALYSIS_RESOLVED.md](GAP_ANALYSIS_RESOLVED.md); when a sibling gap-analysis file conflicts, this register is the current actionable index. The 2026-06-09 audit also normalizes duplicate CaaST IDs: GAP-0838 remains the cross-pod cluster failure, and CaaST tenancy/FLE residuals are tracked as GAP-0846 through GAP-0854. The 2026-06-10 continuation audit pulled the requested downstream repositories, rechecked docs/spec/source claims, and reconciled the open residuals from `docs/*_GAP_ANALYSIS.md`.

- **2026-06-16/17 bulk-seed stress audit + correction:** A 14.27M-node taxonomy bulk seed (divelife `data-ingest ingest --from-dump`, single-property `MERGE`) against `geodedb/geode:dev` surfaced GAP-0894/0895/0896. **GAP-0895 and GAP-0896 are CLOSED** (re-verified fixed on build `bfb66f42` 2026-06-17 — compact one-line metrics, no false stall errors). The 2026-06-16 GAP-0894 "reopen" was **RETRACTED 2026-06-17**: the ~50 nodes/sec figure was measured against the server in a Docker container (UDP-NAT round-trip latency); a controlled host A/B (both binaries, `make release`, 8 connections, warmup-discarded, 2 rounds each) measured the unmodified server at **~255–259 nodes/sec** and a striped single-property handler patch at **~130 nodes/sec — a 2× regression — so the patch was reverted**. The single-property exclusive lock is not the normal-concurrency bottleneck (the path is per-op WAL-fsync / round-trip bound). Reproduction corpus retained at `~/divelife-dump`.
- **2026-06-17 high-connection ingest behaviour — corrected:** the bulk-seed "freeze to ~0 nodes/sec" was the **server CRASH GAP-0899** (now CLOSED, commit `7dcac17e`), NOT a client deadlock as first thought (a 2×16 run had got lucky and not crashed). With the crash fixed the ingest runs steadily; what remains is a **write-throughput ceiling, filed as GAP-0900 (High, open):** single-property bulk writes top out at **~1,100 ops/sec regardless of client concurrency** (16 vs 128 connections give the same rate) — a single-threaded serial section in the write/commit path. For the divelife 14.27M taxon seed (~30 server ops/taxon) this is ~36–39 taxa/sec ⇒ ~100 h end-to-end. The other geode-side finding from the run is **GAP-0897 (Medium)** — per-graph metrics register under fixed names so only the default graph's `mg_*` counters export. See the register rows below.
- **Total open/partial gaps:** 7
- **Critical:** 2 (GAP-0256, GAP-0838) — both **BLOCKED** (GAP-0256 on org cosign/CI-secret infra — `.goreleaser.yaml:745-753`/`755-767` disabled blocks re-verified 2026-06-11, unblock chain unchanged; GAP-0838 narrowed 2026-06-11: repo-side fixes for BOTH 0.6.14 k8s defects landed — DNS search-domain expansion `test-dns-search` 7/7 + hostname-derived node_id `test-cluster-bootstrap` — leaving only real-cluster Kubernetes end-to-end validation, which cannot run in-repo).
- **High:** 3 (GAP-0885, GAP-0893, GAP-0900). GAP-0885 is the security sibling backlog pointer — open/partial: the open-only `docs/SECURITY_GAP_ANALYSIS.md` still tracks LSP-SEC-002 (vendored MCP bearer compare — mitigated/documented at the geode boundary, pending an upstream patch + fork pin), the deferred SEC-MFA-FIPS-01 / SEC-MON-01 / SEC-INFRA-02 records (defer reasons recorded per row), and the GAP-0818 verified-tenant-derivation residual. GAP-0893 is BLOCKED (vendor): any `--transport grpc` harness run crashes inside vendor `grpc_zig` 0.1.7 (`allocStreamWindows` ← `initServerTls` ← `handleConnection`); gRPC is non-verifiable end-to-end until a vendor fix/pin-bump. GAP-0900 is the write-throughput serialization ceiling (new 2026-06-17 — full evidence below and in the register). (GAP-0880 backup upload/compression and GAP-0881 HMAC-SHA3/TDE-status — previously two High rows — closed this round; see `GAP_ANALYSIS_RESOLVED.md`.)
- **Medium:** 2 (GAP-0873, GAP-0897). GAP-0873 — per-tenant at-rest encryption, explicitly deferred to GAP-0290 with the single-master-key limitation documented (`docs/design/TDE_PER_TENANT_KEYS_DEFERRED.md`) and derivation-helper cross-tenant decrypt-fail tests already green (`test-gap0843-tenant-tde`). GAP-0897 — per-graph runtime metrics register under fixed names so only the first (default) graph's counters are ever exported; this masked GAP-0894 validation (`mg_merge_tuple_lock_acquired_total` always read 0 for named graphs).
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
| GAP-0893 | High | gRPC transport / e2e verifiability | **BLOCKED (vendor).** Discovered during GAP-0514 Phase 6 P2 (Task 38, journal entry of commit `b51e0b77`): running ANY geode-test-harness spec with `--transport grpc` crashes the geode-side gRPC listener inside vendor `grpc_zig` 0.1.7 — per-connection panic trace `allocStreamWindows` ← `initServerTls` ← `handleConnection`. The QUIC-equivalent runs of the same specs pass (`grpc_mtls_rejection_matrix.yml` 9/9, `grpc_rapid_sequential_writes_479.yml` 29/29, both green over QUIC), isolating the failure to the vendor gRPC accept/TLS path, not geode handler logic. Consequence: the gRPC transport is non-verifiable end-to-end and the 17 `src/transport/grpc_server.zig` CANARY markers honestly stay IMPL. Related harness-hygiene finding from the same session: bash-type specs resolve a STALE `/usr/bin/geode` unless `${GEODE_BINARY}` is used (`auth_chain_cli_offline.yml` already fixed) — other bash-type specs should be audited for the same trap. | Fix or pin-bump `grpc_zig` past the `allocStreamWindows`/`initServerTls` per-connection crash, re-run the grpc specs with `--transport grpc`, then promote the `grpc_server.zig` markers against green runs. Also audit remaining bash-type harness specs for hardcoded `geode` instead of `${GEODE_BINARY}`. |

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
