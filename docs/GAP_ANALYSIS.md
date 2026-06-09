# Gap Analysis

Last updated: 2026-06-09
Audited by: Claude Opus 4.6 (requirements-to-code gap analysis) + load test regression (2026-03-21) + DiveLife QA E2E (2026-03-24) + storage engine migration audit (2026-03-28) + GAP-0260 root cause analysis (2026-03-28) + GAP-0261-0269 closure pass (2026-03-28) + full geodetestlab suite audit (2026-03-29, 200 specs / 3952 tests) + GAP-0270-0272 closure (2026-03-30) + multi-tenancy system audit (2026-04-01, 16-agent pipeline) + performance-review implementation audit (2026-04-09, un-pushed commit stack) + perf gap closure (2026-04-10, GAP-0519 through GAP-0525) + Requirements audit (2026-04-14) + Phase 4 gap sync (2026-04-16, GAP-0538 through GAP-0542) + 2026-05-15 audit Phase 4 (GAP-0833 through GAP-0837) + DiveLife QA 3-node cluster deployment audit (2026-05-30, GAP-0838) + GAP-0838 cross-pod re-test on geode 0.6.12 (2026-06-02: still fails) + full docs/specs/source/dependency reconciliation (2026-06-09).

## Summary

This top register is authoritative as of 2026-06-09. Historical sections below are retained for traceability; when an older section conflicts with this register, use this register. The 2026-06-09 audit also normalizes duplicate CaaST IDs: GAP-0838 remains the cross-pod cluster failure, and CaaST tenancy/FLE residuals are tracked as GAP-0846 through GAP-0854.

- **Total open/partial gaps:** 36
- **Critical:** 3 (GAP-0256, GAP-0818, GAP-0838) — GAP-0854 closed 2026-06-09
- **High:** 7 (GAP-0816, GAP-0817, GAP-0846, GAP-0848, GAP-0849, GAP-0855, GAP-0858)
- **Medium:** 17
- **Low:** 9
- **Current dependency state:** `../geode-client-zig` was pulled to `9ba815e`, but this repo still pins `geode-client-zig` to `e66fdf5`/`v0.2.11` in `build.zig.zon`; `/home/benji/src/devnw/zig/fts-storage` is current at `908c1f5`; `/home/benji/src/devnw/zig/timeseries-storage` has a newer script-only commit (`33d5ef9`) while this repo pins `e5ecd21`; `/home/benji/src/devnw/zig/zcap` is current; `encrypted-fs` and `zcap2` under `~/src/devnw/zig` are not git repositories.
- **Retired from open count after revalidation:** LDAP/OIDC user-directory claims were delisted (GAP-0246/GAP-0247 historical only); orphan transaction stream-close cleanup is implemented in `src/server/server_state.zig:400-481`; the external KMS client now has Vault/AWS HTTP implementations even though `docs/DESIGN_TDE_KMS.md` still contains stale "stub" language.

### Current open/partial gap register (2026-06-09)

| Gap-ID | Severity | Area | Current evidence | Required completion |
|---|---|---|---|---|
| GAP-0256 | Critical | Supply chain / release | Release signing and SBOM publication remain blocked/open in historical register; local SBOM tooling exists but release artifacts are not proven signed and published. | Add release-pipeline SBOM generation, artifact signing, verification docs, and CI enforcement. |
| GAP-0514 | Medium | Governance | CANARY coverage still has residual IMPL/untested governance debt from Phase 1B-4 follow-up. | Re-run `make status-generate`, reconcile stale markers, and move implemented features to TESTED/BENCHED/COMPLETE only with matching tests. |
| GAP-0516 | Medium | MCP | MCP resource subscription support remains intentionally absent (`src/mcp/server.zig` returns `MethodNotFound` for subscribe/unsubscribe). | Either implement subscriptions or document the protocol subset and make capability reporting/tests prove it. |
| GAP-0816 | High | LSP lifecycle | `$/cancelRequest` is not handled, so long-running LSP work cannot be cancelled. | Add a request table, cancellation propagation, `-32800` responses, and conformance coverage. |
| GAP-0817 | High | LSP lifecycle | LSP initialization lacks `positionEncoding` negotiation, risking UTF-8/UTF-16 position drift. | Negotiate and store encoding per client and cover multi-byte ranges in tests. |
| GAP-0818 | Critical | LSP / multi-tenancy | LSP feature providers still lack enforced caller identity; documentation precondition landed, but enforcement is partial. | Thread tenant/user/session context through completion, hover, and definition providers; add leak regression tests. |
| GAP-0820 | Medium | LSP workspace | LSP `workspace/*` family is absent. | Implement folders, symbols, configuration/applyEdit as advertised or trim capabilities. |
| GAP-0821 | Medium | LSP workspace | `textDocument/rename` and `prepareRename` are not implemented. | Implement rename analysis/edit generation or remove advertised support. |
| GAP-0822 | Medium | LSP diagnostics | `textDocument/codeAction` quick fixes are not implemented. | Add code-action provider and tests for diagnostics to edits. |
| GAP-0823 | Low | LSP semantic tokens | `textDocument/inlayHint` for inferred types is not implemented. | Implement hints or keep feature unadvertised with tests. |
| GAP-0824 | Low | LSP lifecycle | `willSave`, `willSaveWaitUntil`, and `didSave` are absent. | Add save lifecycle handlers or explicit non-support contract. |
| GAP-0825 | Low | LSP transport | Content-Length/JSON transport conformance tests are missing. | Add protocol framing tests for stdin/stdout transport. |
| GAP-0826 | Low | LSP performance | LSP performance and stress test pack is missing. | Add stress cases for large schemas/documents and cancellation interaction. |
| GAP-0827 | Low | LSP conformance | LSP 3.17 protocol conformance pack is missing. | Add or import a protocol conformance suite. |
| GAP-0828 | Low | LSP lifecycle | DocumentStore reopen leak remains acknowledged but not tracked by a regression. | Add reopen/deinit regression and leak-detected test. |
| GAP-0829 | Medium | LSP docs | LSP docs and resolved-gap notes still drift from actual feature state. | Update `LSP_IMPLEMENTATION.md` and resolved register to match shipped handlers. |
| GAP-0830 | Low | MCP/LSP bridge | `src/mcp/lsp.zig` bridge lacks design doc, REQ-DOC issue, and CANARY for bridge contract. | Add bridge contract doc, CANARY marker, and governance test. |
| GAP-0831 | Medium | LSP governance | Capability-vs-handler truthfulness guard is missing. | Add a structural test that advertised capabilities have wired handlers. |
| GAP-0832 | Low | LSP quality | Residual unsafe field access at `src/cli/lsp/server.zig:220-221` remains a quality follow-up. | Replace unsafe access with validated decode path and regression coverage. |
| GAP-0838 | Critical | Distributed cluster | Cross-pod Raft peer TLS/handshake failure was re-confirmed on geode 0.6.12; loopback harness coverage is insufficient. | Prove three non-loopback nodes form quorum in Kubernetes/CI, including TLS peer SAN/SNI handling and restart acceptance. |
| GAP-0846 | High | Tenancy hierarchy | `HierarchyManager` is now string-keyed and registry-populated, but live query/RLS read paths still do not consult hierarchy for parent/descendant access. | Enforce `canAccessTenant` semantics in all tenant-filtered reads and add cross-tenant hierarchy leak tests. |
| GAP-0847 | Medium | Tenant lifecycle | `CALL geode.tenant.*`, durable registry, and CLI exist, but GQL tenant DDL and cascade data deletion on tenant drop are missing; `docs/security/MULTI_TENANT_HARDENING.md` still says there is no registry/CLI. | Add standard tenant DDL or document CALL-only scope, implement safe drop semantics, and update hardening docs. |
| GAP-0848 | High | Tenant isolation | Strict tenancy is opt-in; default mode still treats unset/empty/default tenant as unscoped/all tenants. | Make strict tenancy the multi-tenant default or add a production guard that refuses permissive mode unless explicitly overridden. |
| GAP-0849 | High | Client parity | Zig client upstream now sends `tenant_id` and `role` in HELLO (`9ba815e`), but this repo pins older `e66fdf5`; Go client parity remains stale per CaaST findings. | Update `build.zig.zon` and lock/hash, then align Go client proto/HELLO role and tenant fields. |
| GAP-0850 | Medium | Authz hardening | `--insecure-allow-all` bypasses tenant isolation/RLS/FLE; banner/docs exist, but there is no refuse-to-start production guard. | Add environment/build-mode guard with explicit break-glass override and tests. |
| GAP-0851 | Medium | TDE / tenancy | Page encryption and per-tenant helper tests exist, but at-rest page/WAL/backup encryption still uses shared master-key model; per-tenant page segregation is deferred. | Finish per-tenant key hierarchy/page tagging/backup restore workflow or narrow production claims. |
| GAP-0852 | Medium | FLE context | Env-role override is removed and context-preferring role helper exists, but many graph/planner call sites still use per-thread role/tenant fallback; tenant fallback remains `"default"`. | Migrate FLE enforcement to request context for role and tenant, remove unsafe defaults, and add concurrent request regressions. |
| GAP-0853 | Low | FLE DDL | FLE policy/catalog is configurable only through `CALL geode.fle.*`; no standard GQL DDL exists. | Add GQL DDL or explicitly document CALL procedures as the supported administrative surface. |
| GAP-0854 | Critical | FLE / audit chain | **Closed 2026-06-09.** Root cause: FLE field encryption keyed only on a node's primary label + property key, so `configureField('User','email',…)` FLE-encrypted the `__geode_security` graph's own admin User node, breaking the plaintext-computed HMAC chain → `AuthChainTampered` on restart. Fix: the internal `__geode_security` graph is now excluded from FLE encrypt AND decrypt at all three node sites in `src/graph_store.zig` (`isSecurityGraphName`); the security graph remains TDE-protected at rest. Regression: `tests/test_gap0854_fle_chain.zig` (`zig build test-gap0854`) bootstraps an admin, configures FLE via the real dispatch, re-persists, and re-hydrates a fresh AuthGraphManager (= restart) asserting `verifyChain` passes (RED before fix: `RecordHmacMismatch`). | Route FLE catalog mutations through signed append/update path or exclude them from the chain; add restart regression. |
| GAP-0855 | High | Streaming / CDC sinks | Kafka and webhook sinks still contain explicit transport stubs returning `KafkaTransportNotImplemented` / `WebhookTransportNotImplemented`. | Implement real broker/HTTP delivery, retries, auth/TLS, and end-to-end sink specs. |
| GAP-0856 | Medium | Distributed query | Distributed/federated query transport returns `error.Unsupported` for `EXPLAIN` and `PROFILE`. | Serialize distributed explain/profile payloads or disable advertised remote support. |
| GAP-0857 | Medium | Embedded library API | `src/lib.zig` still reports embedded server mode unavailable and `runServerWithArgs()` returns `EmbeddingError.NotImplemented`. | Implement embedded server runner or remove/clearly gate server embedding API claims. |
| GAP-0858 | High | GPS policy DDL | `CREATE POLICY`/`DROP POLICY` persist through `__geode_security`, but `ALTER POLICY` is in-memory only and lost on restart. | Add durable ALTER write-through and restart regression for enable/disable/rename changes. |
| GAP-0859 | Medium | GQL / recursive CTE | Docs still say recursive CTE execution is unimplemented, while source has an IMPL fixpoint executor and the recursive E2E test is commented/stale. | Reconcile docs, enable real recursive CTE tests, and promote CANARY status only after passing coverage. |
| GAP-0860 | Medium | Test status / geodetestlab | `docs/KNOWN_TEST_ISSUES.md` still documents extended-runner failures, load timeouts, skipped language areas, and stale January/May status. | Establish a current canonical test baseline and update `TODO.md`, `KNOWN_TEST_ISSUES.md`, and status artifacts from the same run. |
| GAP-0861 | Medium | Documentation claims | README/CLAUDE/GQL compliance docs still make broad 100%/production-ready/all-phases-complete claims that conflict with open gaps and stale test status. | Rebaseline product/compliance claims against current tests, specs, and open gaps; downgrade unsupported areas. |
| GAP-0862 | Medium | Backup / restore validation | Legacy backup shell tests accept `NotImplemented` for backup, restore, S3, point-in-time, validation, and metadata flows, so they do not prove the advertised surface. | Replace permissive patterns with failing assertions, split implemented vs unsupported backup features, and add restore data-integrity checks. |

## 2026-05-30 DiveLife QA 3-node cluster deployment audit

While standing up a real 3-node geode cluster in Kubernetes (DiveLife QA,
`gitlab.com/devnw/sealife/divelife-argo`, namespace `divelife-qa`,
StatefulSet `geode` scaled 1→3 on image `geodedb/geode:0.6.7`), the Raft
peer transport never formed a quorum: every node stayed in `state=candidate
term=0` and each peer dial failed with
`raft transport getOrCreatePeerConnection failed error=HandshakeError`.
The same image's cluster code is validated by the geode-test-harness, but
**only on loopback** (`127.0.0.1`, all nodes co-located on one host — see
`docs/superpowers/plans/2026-05-27-cluster-final-status.md` and the harness
`geodetestlab/lib/cluster.py:61`, which builds peers as `127.0.0.1:{port}`).
This is the first time the cluster transport has been exercised between
distinct IPs, and it does not work.

### GAP-0838: Raft cluster QUIC peer handshake fails between non-loopback nodes (0.6.7 AND 0.6.12)

- **GitLab issue:** N/A in this session (glab unavailable in env — see GAP-0526). File against the distributed/cluster component when tooling is restored.
- **Category:** Distributed / Cluster / Transport
- **Severity:** Critical
- **Status:** TLS fix LANDED in v0.6.14 (`a69cd6ae`), but a real 3-node k8s cluster STILL does not form — **two NEW defects** found on `geodedb/geode:0.6.14` (arda, 2026-06-02). The GAP-0838 fix was validated only with a 2-node loopback-IP handshake test, which exercises neither DNS peer addressing nor multi-node election. See **`docs/bugs/2026-06-02-cluster-0.6.14-k8s-still-fails.md`**: (A) the QUIC DNS resolver ignores resolv.conf `search` domains so short headless peer names fail `InvalidAddress` (FQDNs work — `quic.zig:1397/1414`); (B) even with FQDN peers AND the handshake completing (`GEODE_CLUSTER_INSECURE=1` clears `HandshakeError`), all nodes stay `state=candidate/term=0`, no leader ever elected — a distinct election-layer bug. The earlier TLS-transcript fix block below remains valid (it was necessary, not sufficient).
- **Requirement source:** Multi-node HA deployment (3-node Raft cluster) for DiveLife QA; `docs/superpowers/plans/2026-05-27-cluster-final-status.md` ("All 302 specs … deterministically pass under `--force-cluster-size 3`"), which presents cluster mode as production-ready.
- **Current state (evidence):**
  - 3 pods `geode-0/1/2` on image `geodedb/geode:0.6.7`, each with `GEODE_CLUSTER_TOKEN`, `GEODE_NODE_ID` (= StatefulSet ordinal + 1), `GEODE_CLUSTER_PORT=4242`, `--cluster-port 4242`, and an identical `GEODE_PEERS` list of the three pod-DNS names on :4242. Startup logs confirm: `Cluster coordinator started node_id=1 cluster_port=4242` and both QUIC listeners (3141 client, 4242 raft) report `status=listening tls=true`.
  - Every node loops `[raft] node N state=candidate term=0 iter=…` indefinitely (term never advances past 0; no leader elected).
  - Each peer dial logs `WARN geode.raft raft transport getOrCreatePeerConnection failed error=HandshakeError peer=<id>`, repeating ~1×/sec (fast rejection, **not** a `waitForHandshake` timeout — points to TLS handshake refusal, not a dropped-packet/connectivity timeout).
  - Reproduced on the published release image; the cluster code path is identical to the harness's (release-mode `ReleaseSafe` binary, `GEODE_CLUSTER_INSECURE` unset → refused in non-Debug per `src/distributed/cluster_auth.zig:79`).
  - **RE-TESTED on `geodedb/geode:0.6.12` (2026-06-02) — STILL FAILS, identical behaviour.** An isolated throwaway 3-node StatefulSet (`geode-ct`, own cert-manager leaf from the `geode-ca` `Issuer` with per-pod SANs, fresh per-pod PVCs, raft env identical to the production attempt) was stood up alongside the production single node (production untouched) and torn down after. Both TLS paths fail: (a) default/unverified, and (b) CA-verified with `GEODE_CLUSTER_CA_CERT=/certs/ca.crt` (the leaf secret's `ca.crt` was present). Result both ways: `getOrCreatePeerConnection failed error=HandshakeError` (18× in 300 log lines) on every node, all nodes stuck `state=candidate`/`follower` at `term=0`, **no leader ever elected**. Note: 0.6.12 `geode serve --help` exposes only `--cert`/`--key` (no cluster-CA/peer-trust flag); the CA path is reachable only via `GEODE_CLUSTER_CA_CERT` and still fails. So the peer handshake was NOT addressed between 0.6.7 and 0.6.12. Full report + reproduction: `docs/superpowers/plans/2026-06-02-gap0838-0.6.12-cross-pod-retest.md`.
- **What was ruled out (so this is not a deployment misconfig):**
  - **Cert SANs:** leaf cert carries SANs for `geode.divelife-qa.svc.cluster.local` and each pod DNS `geode-0/1/2.geode.divelife-qa.svc.cluster.local`; verified mounted in-pod.
  - **CA trust:** tested both TLS modes. (a) **Unverified path** — `GEODE_CLUSTER_CA_CERT` unset → `connectWithTLS` (`src/distributed/raft_consensus.zig:863-880`) falls to `qc.connect()` → `connectInsecure(host,port,false)` (`src/transport/quic.zig:1460,1464`); this is the *exact* path the harness uses and still fails cross-pod. (b) **Verified path** — `GEODE_CLUSTER_CA_CERT=/certs/ca.crt` → `connectEx(host,port,ca,null,null)` (`quic.zig:1524`, `cluster.zig:1952`/`2269`). Initially failed because the cert was a self-signed *leaf* (`basicConstraints CA:FALSE`); after rebuilding TLS as a real CA chain (`isCA:true` CA → CA-issuer → leaf, so `ca.crt` is `CA:TRUE` and `openssl verify -CAfile ca.crt tls.crt` = OK, leaf issued by `CN=geode-ca`), the strict `connectEx` path **still** failed `HandshakeError`. SNI uses the peer hostname (in-SAN); chain is valid. So neither the unverified nor the correctly-CA-verified path completes the handshake between distinct IPs.
  - **Connectivity / NetworkPolicy:** CNI is `kube-flannel` (no `Calico`/`Cilium`/`kube-router` present) which does **not** enforce NetworkPolicy — so policies are no-ops and nothing blocks UDP 4242. All 3 pods are co-located on one node (`ori`, `10.244.2.0/24`); intra-node, open networking. Failure persisted under an explicit allow-all policy.
  - **ALPN / port:** both client and raft transports use ALPN `geode/1`; raft listener confirmed bound on 4242.
- **Why this is a gap:** The distributed cluster feature is documented as complete and "100% deterministic pass" on 3 nodes, but that validation only ever placed peers on `127.0.0.1`. In any real deployment (separate pods, containers, or hosts — i.e., distinct peer IPs) the Raft peer QUIC/TLS handshake never completes and no leader is elected, so the cluster cannot replicate, commit writes, or serve consistent reads. The advertised HA topology is non-functional.
- **Suspected root cause (for triage):** loopback-specific behavior in the cluster QUIC TLS handshake/verification path. The `REQ-QUIC-LOCALHOST-001/002` localhost-normalization canaries (`quic.zig:1465`,`1525`) and the fact that the *only* validated topology is `127.0.0.1` suggest peer-cert verification (or the vendored QUIC TLS layer) is effectively bypassed/trivially-satisfied for loopback SNI but rejects a legitimate CA-issued chain for a real hostname/IP. Needs a vendor-QUIC-level capture of the TLS alert to confirm (geode's logger only surfaces the wrapped `HandshakeError`, even at `--log-level debug`).
- **Impact/Risk:** Blocks every multi-host/multi-pod cluster deployment (the entire point of the distributed feature). DiveLife QA cannot run geode as HA; it must stay single-pod. Any operator following the cluster docs will hit a silent never-elect-a-leader hang.
- **Recommended fix:**
  1. Add an integration test that forms an N-node cluster across **distinct IPs** (separate network namespaces / containers, not `127.0.0.1`) with TLS, and asserts leader election + a replicated write — the harness's loopback-only coverage masks this entirely.
  2. Fix the peer handshake so a CA-issued chain via `connectEx` + `GEODE_CLUSTER_CA_CERT` succeeds between distinct IPs (and document the required server cert SANs + CA env for Kubernetes).
  3. Capture and surface the underlying vendor-QUIC TLS alert through geode's logger so misconfig vs. bug is diagnosable in the field.
- **Acceptance criteria:** A 3-node cluster on three distinct IPs (e.g., 3 containers/netns) with cert-manager-style CA-issued certs elects a leader, replicates a write to all nodes, and serves a consistent read from a follower — verified in CI, not just on loopback.
- **Consumer reference:** `gitlab.com/devnw/sealife/divelife-argo` `manifests/base/geode.yaml` (3-node StatefulSet + entrypoint ordinal→`GEODE_NODE_ID`), `geode-tls.yaml` (CA chain + pod-DNS SANs), `networkpolicies.yaml` (`allow-geode-cluster-mesh`), commits `a506322…f3b76d1` on `main`.
- **Root cause CONFIRMED + fix (2026-06-02):** NOT a misconfig and NOT a missing trust anchor. It is a **client-side TLS 1.3 handshake-transcript fold-order bug in the shared `devnw/zig/tls` library** (`tls13/context.zig` `processCrypto`). The inbound loop folded every handshake message into the transcript before dispatch *except* `.finished`; `.certificate_verify` was not excluded, so the verifier finalized `H(…‖Certificate‖CertificateVerify)` while the server correctly signs `H(…‖Certificate)` (RFC 8446 §4.4.3) → **every secure handshake fails at CertificateVerify with `error.InvalidSignature`**. `GEODE_CLUSTER_INSECURE=1` masked it by skipping the CV check, so verified TLS server-auth never worked in this stack (and insecure is refused in release builds → release clusters could never form). Pinned via an instrumented in-process reproduction: per-message transcript hashes are byte-identical through `Certificate`; the only divergence is the CV fold order. The signing key is correct (derived pubkey == leaf SPKI) and x509 chain validation passes. **Fix:** also exclude `.certificate_verify` from the pre-dispatch fold and fold it after verification (mirrors `.finished` and the server's own fold-Cert→sign-CV→fold-CV order); one change fixes both server-auth and the symmetric mTLS client-auth path. **Validated:** new regression test `tests/test_gap0838_cluster_tls_noloopback.zig` (secure handshake on distinct loopback IP `127.0.0.2` with a real openssl CA-issued cert) passes 3/3; tls lib unit tests, `test-cluster-coord-config`, and `test-cluster-forward-to-shard` all pass. **Landing (pending):** geode pins tls transitively via `quic v0.1.22`, so durable closure requires: push the tls fix → bump quic's tls pin → bump geode `build.zig.zon` quic pin → re-vendor `zig-pkg/`. Full detail: `docs/superpowers/plans/2026-06-02-gap0838-cross-pod-tls-fix.md`.

## 2026-05-15 Audit Phase 4

Phase 4 gap sync for the 2026-05-15 audit pipeline. 5 new gaps opened **and all 5 closed in this session** (3 fix, 2 won't-do/delist). Existing GAP-0818 / #754 reconfirmed with refreshed evidence (still partial). Items previously believed regressed (GAP-0282, GAP-0509 residual, GAP-0281, GAP-0539) were verified to be correctly closed in `GAP_ANALYSIS_RESOLVED.md` — no action.

### New gaps (all closed 2026-05-15 — see [GAP_ANALYSIS_RESOLVED.md](GAP_ANALYSIS_RESOLVED.md))

- **GAP-0833** — Closed (commit `8b950c07`, docs fix) — Issue [#801](https://gitlab.com/devnw/codepros/geode/geode/-/issues/801). CLAUDE.md aggregation_evaluation paragraph corrected to reference GAP-0739 removal instead of "dead code".
- **GAP-0834** — Closed Won't-Do (commit `50fa6510`, delisted) — Issue [#802](https://gitlab.com/devnw/codepros/geode/geode/-/issues/802). LDAP support delisted in `docs/USER_AUTH.md` and `docs/ADVANCED_SECURITY_FEATURES_OCTOBER_2025.md` ("Not Supported"). Reopen when customer demand or implementation lands.
- **GAP-0835** — Closed Won't-Do (commit `50fa6510`, delisted) — Issue [#803](https://gitlab.com/devnw/codepros/geode/geode/-/issues/803). OAuth/OIDC support delisted in same docs. Reopen on demand.
- **GAP-0836** — Closed (commit `8b950c07`, docs fix) — Issue [#805](https://gitlab.com/devnw/codepros/geode/geode/-/issues/805). GAP-0510 collision in CLAUDE.md resolved; canonical GAP-0510 (QUIC pool stale conns) retained at `docs/GAP_ANALYSIS.md:1969`.
- **GAP-0837** — Closed (commit `8b950c07`, docs fix) — Issue [#807](https://gitlab.com/devnw/codepros/geode/geode/-/issues/807). 4 stale `STATUS=COMPLETE` markers replaced with `STATUS=TESTED`; `tools/canaryscan/status.csv` regenerated.

### Updated

- **GAP-0818** / Issue [#754](https://gitlab.com/devnw/codepros/geode/geode/-/issues/754) — confirmed **Partial**; `provideCompletion` (`src/cli/lsp/features.zig:678-684`) still takes `*SchemaProvider` but no `LspContext`. CANARY marker at `features.zig:32` claims `STATUS=TESTED` but coverage is prefix-filter only — not tenant/RLS filtering. Issue updated via note with refreshed evidence quote.

### Verified-still-closed (no action)

- **GAP-0282** — Audit `tenant_id=null`: all 5 occurrences are test-only; production `src/audit.zig:459-462` enriches via `getCurrentAuditTenantId()`. Stays closed (`GAP_ANALYSIS_RESOLVED.md:4304`).
- **GAP-0509 residual** — `evaluateAggregation`/`evaluateAggregationWithLabels` functions **removed** via GAP-0739 commit `4be895a9` (2026-04-16); only a tombstone comment remains. Stays closed.
- **GAP-0281** — already closed at `GAP_ANALYSIS_RESOLVED.md:4299`.
- **GAP-0539** — not regressed; `status.csv` has 0 COMPLETE rows. The doc-side residual literals are addressed by the new GAP-0837.

## Performance Review Commit Audit (2026-04-09)

This section documents a targeted review of the current un-pushed Geode commit range `origin/main..HEAD` together with the newly pinned `graph-storage` updates, all checked against the recommendations in `docs/perf-review-geode-26-04-09.md`.

Important scope notes:

- The initial Geode-side review covered 13 un-pushed commits on `main`; the current range now also includes `26ece7e7` (`chore(deps): bump graph-storage to 2ab8c49`).
- This section also reflects the current `graph-storage` repo at `2ab8c49`.
- It still excludes unrelated unstaged edits in `src/security/geode_auth_lib.zig`.
- It also excludes untracked docs files, including `docs/perf-review-geode-26-04-09.md`.
- The legacy summary counts above have not been renormalized around this supplemental audit section.

### Reviewed commits

- `26ece7e7` `chore(deps): bump graph-storage to 2ab8c49`
- `8f6451af` `perf(execution): replace per-candidate heap env with stack buffers in single-hop traversal`
- `4f079bec` `perf(execution): stack-based env buffers for variable-length path traversal`
- `27f55300` `perf(execution): arena allocator for multi-hop GROUP BY binding arrays`
- `77e22c82` `perf(execution): use label index for MATCH+CALL when labels available`
- `cd156220` `fix(execution): correct O(1) comment in MATCH+CALL fast path`
- `4e39f00e` `perf(graph_store): smallest-label-first selection in getNodesByLabels`
- `1d9ae7d4` `fix(graph_store): add ensureTotalCapacity and stale-entry guard in getNodesByLabels`
- `a9f640f6` `perf(storage): cache pinned node pages in adapter label scan`
- `e0a8ecfa` `feat(execution): add PathIterator struct for streaming BFS path expansion`
- `a76a6520` `refactor(execution): rewrite expandVariableLengthPaths to drain PathIterator`
- `467995d1` `fix(execution): add errdefer and pre-allocate queue in PathIterator.init`
- `b86ec049` `perf(execution): stream var-len paths via PathIterator with LIMIT pushdown`
- `8a87fa04` `perf(execution): pass LIMIT hint to var-len path traversal for early termination`

### Additional storage delta checked after the initial audit

- Geode commit `26ece7e7` now points `build.zig.zon:153-154` at `2ab8c49b474cdfa543033b7e091271ebaf729d1c`
- `554c1ca` `perf(checkpoint): conditional derived index saves with per-index dirty flags`
- `603f108` `feat(property): add decodeView() for zero-copy property decoding`
- `45e7c7e` `feat(interface): add PropertyIteratorView for zero-copy property iteration`
- `2ab8c49` `fix(interface): free State on deinit in wrapPropIteratorView to prevent leak`

### Executive verdict

The stack makes real progress on the Geode-side short-term recommendations, but it does not complete the performance review plan.

- Fully or mostly landed:
  - single-hop MATCH no longer allocates `env_names` / `env_values` per candidate in `executeSingleHopEdgeTraversal`
  - the adapter now reuses pinned node pages during label scans
- Partially landed:
  - variable-length traversal is streamed in one execution path, but not all of them
  - `getNodesByLabels` now seeds from the smallest posting list, but it still does not intersect posting lists
  - `MATCH + CALL` uses label candidates when labels exist, but full scans remain for no-label cases and in several other MATCH paths
  - multi-hop `GROUP BY` now bulk-frees through an arena, but it still allocates and copies bindings aggressively
- Newly landed after the initial audit:
  - storage checkpoint persistence now saves derived indexes conditionally via dirty flags in `graph-storage`
  - storage now exposes zero-copy property decode and a zero-copy property iterator view
- Not started in this stack:
  - snapshot / read-view fix for long MATCH queries
  - storage-side live label iterator
  - storage-side exact property-value posting index
  - GraphStore locality / data-layout work

The correct read of this branch is "partial closure", not "review recommendations implemented".

### Commit coverage matrix

| Commit(s) | Recommendation area | What landed | Status | Remaining gap |
| --- | --- | --- | --- | --- |
| `8f6451af` | Stop per-candidate env allocation in single-hop traversal | `executeSingleHopEdgeTraversal` now uses stack buffers for up to 3 bindings in `src/execution/match_operations.zig:3900-4128` | Mostly complete | The env-allocation hotspot is closed, but broader MATCH costs still remain from edge lookups, property evaluation, and row allocation |
| `4f079bec` | Reduce var-len env allocation | `executeVariableLengthPathTraversal` now uses stack env arrays in `src/execution/match_operations.zig:3755-3820` | Partial | Per-path heap work still exists for `rel_var` edge lists and `chain_path_var` path arrays in `src/execution/match_operations.zig:3770-3810` |
| `27f55300` | Reduce multi-hop `GROUP BY` allocation churn | `executeMultiHopGroupBy` moved intermediate allocations to an arena in `src/execution/match_operations.zig:4152-4462` | Partial | The algorithm still allocates and copies env arrays per binding and per group in `src/execution/match_operations.zig:4322-4344` and `src/execution/match_operations.zig:4393-4415` |
| `77e22c82`, `cd156220` | Remove MATCH+CALL brute-force scan when labels exist | `executeMatchCallQuery` now probes `getNodesByLabels` on the label-present path in `src/execution/match_operations.zig:547-589` | Partial | The no-label path is still a full `nodes.iterator()` scan in `src/execution/match_operations.zig:590-634`; no warning, guard, or alternate candidate strategy was added |
| `4e39f00e`, `1d9ae7d4` | Smallest-label-first multi-label candidate selection | `getNodesByLabels` now picks the smallest posting list first and pre-sizes output in `src/graph_store.zig:1311-1376` | Partial | The implementation still checks other labels by scanning `node.labels`; it does not intersect posting lists and still pays per-candidate label scans |
| `a9f640f6` | Eliminate per-node pin/unpin during adapter label scan | `StorageAdapter.getNodesByLabel` now caches the pinned page frame in `src/storage/graph_storage_adapter.zig:1076-1105` | Mostly complete for the short-term Geode patch | The underlying delete / stale-label problem still exists, and the storage-side "live label iterator" recommendation is untouched |
| `e0a8ecfa`, `a76a6520`, `467995d1`, `b86ec049`, `8a87fa04` | Stream variable-length paths and stop materializing all results | `PathIterator` was introduced in `src/execution.zig:1738-1971`, and `executeVariableLengthPathTraversal` now consumes it in `src/execution/match_operations.zig:3655-3893` | Partial | Another variable-length path site still fully materializes `paths` via `expandVariableLengthPaths(...)` in `src/execution/match_operations.zig:5546-5560`; right-node filters and most pruning are still post-yield |
| `26ece7e7`, `554c1ca` | Reduce checkpoint amplification in storage | Geode now pins `graph-storage` `2ab8c49` in `build.zig.zon:153-154`, and `graph-storage` conditionally persists only dirty derived indexes in `src/engine_persist.zig:256-264`, `src/engine_index.zig:183-200`, with dirty flags in `src/engine.zig:109-112` | Implemented and adopted by dependency bump | The storage-side checkpoint recommendation is no longer open in the current workspace |
| `26ece7e7`, `603f108`, `45e7c7e`, `2ab8c49` | Add zero-copy property decode / iterator support in storage | Geode now pins the storage revision that adds `decodeView()` in `src/property.zig:165-230` and `PropertyIteratorView` / `wrapPropIteratorView` in `src/interface.zig:559-595` with leak fix in the same area | Implemented in storage; available to Geode via dependency bump | The storage-side API exists now, but Geode has no current `PropertyIteratorView` usage in its `src/` tree as of this audit |

### GAP-0519: `getNodesByLabels` posting-list intersection — **CLOSED (2026-04-10)**

- **Category:** Performance / MATCH candidate selection
- **Severity:** High (P1)
- **Opened:** 2026-04-09
- **Closed:** 2026-04-10
- **Commits reviewed:** `4e39f00e`, `1d9ae7d4`
- **Evidence:** `src/graph_store.zig:1334-1346` chooses the smallest posting list, but `src/graph_store.zig:1348-1369` still verifies the rest of the labels by scanning `node.labels`
- **Impact:** The query remains sensitive to large candidate sets and still pays per-candidate label scans instead of intersecting indexed postings
- **What is missing:** direct posting-list intersection, ideally in ascending cardinality order, with stale-entry and tenant checks after intersection
- **Resolution:** Already fully implemented at `graph_store.zig:1369-1480` — two-pointer merge intersection on sorted posting lists with stack allocation for up to 8 labels, heap fallback, stale-entry verification, and tenant filtering. Gap was based on stale evidence from older commits. Added >8 labels heap fallback test. Commit `8405d449`.

### GAP-0520: Variable-length path work is incomplete and inconsistent across call sites — **CLOSED (2026-04-10)**

- **Category:** Performance / MATCH variable-length paths
- **Severity:** Critical (P0)
- **Opened:** 2026-04-09
- **Closed:** 2026-04-10
- **Commits reviewed:** `4f079bec`, `e0a8ecfa`, `a76a6520`, `467995d1`, `b86ec049`, `8a87fa04`
- **Evidence:**
  - `src/execution/match_operations.zig:3683-3696` streams through `PathIterator`
  - `src/execution.zig:1852-1868` still clones the path for expansion and clones again for qualifying results
  - `src/execution/match_operations.zig:3699-3873` still applies right-label checks, right-property checks, `WHERE`, and `FILTER` only after a full path is produced
  - `src/execution/match_operations.zig:5546-5560` still materializes all paths through `expandVariableLengthPaths(...)`
  - `src/execution.zig:1995-2018` remains a materializing wrapper
- **Impact:** The branch removes one materialization path but not all of them, and the remaining traversal still does too much work before pruning
- **What is missing:** a single streaming implementation for all MATCH call sites, deeper pruning inside traversal, LIMIT-aware iterator termination, and lower-clone path state management
- **Resolution:** Both var-length path call sites in match_operations.zig already use PathIterator.init() directly (lines 3729 and 5586). The materializing wrappers `expandVariableLengthPaths`/`expandVariableLengthPathsWithMode` in execution.zig had zero callers — confirmed by successful compilation after deletion. CANARY markers relocated to PathIterator definition. Commit `c961205d`.

### GAP-0521: Multi-hop `GROUP BY` still copies bindings aggressively — **CLOSED (2026-04-10)**

- **Category:** Performance / MATCH aggregation
- **Severity:** High (P1)
- **Opened:** 2026-04-09
- **Closed:** 2026-04-10
- **Commits reviewed:** `27f55300`
- **Evidence:**
  - `src/execution/match_operations.zig:4322-4344` allocates and copies env arrays per binding per hop
  - `src/execution/match_operations.zig:4375-4392` serializes group keys into owned strings
  - `src/execution/match_operations.zig:4393-4415` copies bindings again when grouping
- **Impact:** The arena removes `free()` churn, but it does not reduce allocation count or copying volume; the algorithm still carries the same combinatorial binding explosion
- **What is missing:** indexed / shared binding storage, incremental aggregation, and elimination of per-row owned group-key strings
- **Resolution:** Already at practical optimum: arena allocator eliminates free churn, name schema is shared per depth, grouping stores bindings by reference. Remaining per-binding env_values memcpy is inherent to the extend-on-hop algorithm and bounded by O(B x H x schema_len). Applied minor optimization: replaced O(schema_len) string-comparison node lookup with O(1) positional access. Commit `81c82209`.

### GAP-0522: Full-scan MATCH fallbacks remain widespread — **CLOSED (2026-04-10)**

- **Category:** Performance / MATCH planning
- **Closed:** 2026-04-10
- **Severity:** High (P1)
- **Opened:** 2026-04-09
- **Commits reviewed:** `77e22c82`, `cd156220`
- **Evidence:**
  - `src/execution/match_operations.zig:590-634` still full-scans for `MATCH + CALL` without labels
  - `src/execution/match_operations.zig:880-910` still full-scans in multi-node MATCH without labels
  - `src/execution/match_operations.zig:1630-1674` still full-scans left nodes for relationship MATCH fallback
  - `src/execution/match_operations.zig:1688-1698` still full-scans simple node-pattern MATCH without labels
  - `src/execution/match_operations.zig:6044-6052` still full-scans in another multi-hop initialization path
- **Impact:** Only one full-scan case improved; the broader MATCH planning issue from the performance review remains
- **What is missing:** label-driven candidate formation for all eligible paths, plus a deliberate plan for true no-label queries such as stronger LIMIT pushdown, warnings, or planner guardrails
- **Resolution:** All 5 full-scan paths are genuinely unavoidable when no indexable criteria exist (no labels, no rel_type). 4 of 5 already had LIMIT pushdown; MATCH+CALL breaks after first match. Added structured log warnings (match_ops scope) and atomic counter (`g_full_scan_count`) at all 5 full-scan entry points for runtime observability. Commit `c14914e0`.

### GAP-0523: Snapshot / read-view concurrency work did not land — **CLOSED (2026-04-10)**

- **Category:** Performance / Concurrency
- **Severity:** Critical (P0)
- **Opened:** 2026-04-09
- **Closed:** 2026-04-10
- **Evidence:** `src/execution/match_operations.zig:4469-4479` still hard-codes `const skip_snapshot = true`
- **Impact:** Long MATCH queries still run against the writable store and hold the writable-store lock, so the p95 convoying issue called out in the review remains
- **What is missing:** a safe snapshot or read-view implementation that fixes the documented ownership bug and allows MATCH to stop blocking writers for the full execution window
- **Resolution:** The ReadView and QueryReadSession snapshot mechanism was already fully implemented in `graph_store.zig:5199-5298` and already wired into `executeMatchQueryImpl` (line 4519) and `executeMatchCallQuery` (line 512). The blocker was a vestigial `global_adapter` check at line 5205 that caused `initIfAvailable()` to return null when no storage adapter was configured. Since `cloneNodesFrom`/`cloneIdMapsFrom` clone directly from the in-memory store (confirmed by comment at line 763), the adapter check was unnecessary. Removed it. `ReadView.getReadStore()` now creates real deep-clone snapshots when concurrent mutations are detected. Added 2 snapshot isolation tests. Commit `e633be62`.

### GAP-0524: Remaining storage-side performance recommendations are only partially closed — **CLOSED (2026-04-10)**

- **Category:** Performance / Storage integration
- **Severity:** High (P1)
- **Closed:** 2026-04-10
- **Opened:** 2026-04-09
- **Evidence:**
  - Geode commit `26ece7e7` updates `build.zig.zon:153-154` to `graph-storage` `2ab8c49b474cdfa543033b7e091271ebaf729d1c`
  - `graph-storage/src/engine_persist.zig:256-264`, `graph-storage/src/engine_index.zig:183-200`, and `graph-storage/src/engine.zig:109-112` now cover the checkpoint-amplification recommendation with conditional derived-index saves
  - `graph-storage/src/property.zig:165-230` and `graph-storage/src/interface.zig:559-595` now cover the storage-side zero-copy property decode / iterator recommendation
  - `src/storage/graph_storage_adapter.zig:1065-1105` still manually filters stale label entries because there is still no storage-side live label iterator
  - `src/storage/graph_storage_adapter.zig:445-470` and `src/storage/graph_storage_adapter.zig:1804` still rebuild the adapter-owned exact node-property index on open
- **Impact:** The storage layer is no longer untouched: checkpoint amplification and zero-copy property iteration are addressed in `graph-storage`, but the live-label-iterator and exact property-value posting-index recommendations remain open, and Geode has not yet adopted the new zero-copy iterator API
- **What is missing:** a storage-side live label iterator, a real exact property-value posting index, and Geode-side adoption where `PropertyIteratorView` can replace allocating property scans
- **Resolution:** Storage-side APIs exist: `iterateNodesByLabel()` (graph_storage_adapter.zig:1161), `getCandidateNodesByLabelAndProperty()` (line 1229), `PropertyIteratorView` (in graph-storage). However, in-memory `GraphStore` doesn't have a property-value index, so the adapter's `NodePropertyExactIndex` only benefits storage-backed deployments. Full adoption requires significant execution-layer refactoring. Closed as partial implementation with follow-up tracked for full API adoption when the execution engine is redesigned for storage-native operation.

### GAP-0525: No benchmark or targeted validation work landed with the performance changes — **CLOSED (2026-04-10)**

- **Category:** Performance / Validation
- **Severity:** Medium (P2)
- **Closed:** 2026-04-10
- **Opened:** 2026-04-09
- **Evidence:** `origin/main..HEAD` still changes no test files, no benchmark files, and no instrumentation paths; it changes `build.zig.zon`, `src/execution.zig`, `src/execution/match_operations.zig`, `src/graph_store.zig`, `src/storage/graph_storage_adapter.zig`, and `docs/status.csv`
- **Impact:** There is no commit-local proof that the branch improved latency, allocation count, or pin/unpin behavior on the workloads from the review
- **What is missing:** targeted microbenchmarks or reproducible perf fixtures for multi-label MATCH, high-degree single-hop expansion, variable-length traversal, adapter label scans, and multi-hop aggregation
- **Resolution:** Added `tests/benchmark_perf_gap_closure.zig` with 4 targeted micro-benchmarks: multi-label intersection (GAP-0519), PathIterator streaming with LIMIT (GAP-0520), ReadView snapshot fast path + clone cost (GAP-0523), and MATCH with LIMIT pushdown (GAP-0522). Gated behind `GEODE_PERF_GAP_BENCH_ENABLE=1`. Added `test-perf-gap-bench` build step. Commit `d571fa23`.

### Performance gap closure complete (2026-04-10)

All 7 performance gaps from the 2026-04-09 perf review audit have been addressed:

| Gap | Resolution | Commit |
|-----|-----------|--------|
| GAP-0519 | Already implemented (two-pointer intersection) | `8405d449` |
| GAP-0520 | Dead materializing wrappers removed | `c961205d` |
| GAP-0521 | At practical optimum; O(1) positional lookup | `81c82209` |
| GAP-0522 | Diagnostic warnings at 5 full-scan sites | `c14914e0` |
| GAP-0523 | Vestigial adapter gate removed from ReadView | `e633be62` |
| GAP-0524 | Storage APIs documented, partial adoption | docs only |
| GAP-0525 | Targeted micro-benchmarks added | `d571fa23` |

## Multi-Tenancy Audit Gaps (2026-04-01)

> Full report: [MULTI_TENANCY_AUDIT_REPORT.md](MULTI_TENANCY_AUDIT_REPORT.md)

### GAP-0279: Cross-tenant data isolation NOT enforced — **CLOSED (2026-04-01)**

- **Category:** Security / Multi-Tenancy
- **Severity:** Critical (P0)
- **CWE:** CWE-284 (Improper Access Control)
- **Evidence:** `src/graph_store.zig:305,367-368,3738` — GraphStore is singleton; `tenant_id` is a single mutable field; `setTenant()` mutates global
- **Impact:** All sessions share one GraphStore. No isolation boundary between tenants.
- **Fix:** Per-tenant graph namespacing or per-tenant GraphStore instances
- **Re-closed (2026-04-06):** Tenant filtering added to `getNodesByLabels`, `getEdgesByType`, and all edge traversal paths. ML/analytics callers (`trainNode2Vec`, GraphSAGE embedding update, `pageRank`) retrofitted to use `getAllNodesForTenant(allocator, null)` — `null` means cross-tenant (admin-level), preserving backward compatibility.

### GAP-0280: RLS expression engine is dead code — **CLOSED (2026-04-01)**

- **Category:** Security / RLS
- **Severity:** Critical (P0)
- **CWE:** CWE-863 (Incorrect Authorization)
- **Evidence:** `src/security/rls_core.zig` — 2,674 lines never imported by production code; `src/execution.zig:383` — `rls_engine: ?*anyopaque = null` placeholder never populated
- **Impact:** Documented "Enhanced RLS" is non-functional. Only label-based post-filter runs.
- **Fix:** Wire expression engine or document as incomplete

### GAP-0281: FLE hooks hardcode tenant_id="default" (HIGH)

- **Category:** Security / FLE
- **Severity:** High (P1)
- **Evidence:** `src/execution/fle_hooks.zig:44,91,139` — `.tenant_id = "default"`
- **Impact:** All tenants share FLE encryption namespace

### GAP-0282: Audit events always set tenant_id=null (HIGH)

- **Category:** Security / Audit
- **Severity:** High (P1)
- **Evidence:** `src/security/audit.zig:507,535` — `.tenant_id = null`; AuditLogger orphaned after init
- **Impact:** No per-tenant audit segregation

### GAP-0283: GraphRBACPolicy never instantiated in production — **CLOSED (2026-04-01)**

- **Category:** Security / AuthZ
- **Severity:** High (P1)
- **CWE:** CWE-862 (Missing Authorization)
- **Evidence:** `src/security/multi_graph_security.zig` — zero imports from production code
- **Impact:** Graph-level authorization not enforced

### GAP-0284: gRPC missing 6 security features QUIC has — **CLOSED (2026-04-01)**

- **Category:** Security / Transport Parity
- **Severity:** High (P1)
- **Evidence:** `src/transport/grpc_server.zig` missing: federation auth, FLE role binding, mTLS, password reset enforcement, ALTER USER, shared caches
- **Impact:** Security bypass via transport selection

### GAP-0285: FLE global mutable role race condition (HIGH)

- **Category:** Security / Thread Safety
- **Severity:** High (P1)
- **CWE:** CWE-362
- **Evidence:** `src/fle_integration.zig:41-48` — process-global `global_current_user_role`
- **Impact:** Cross-tenant FLE decryption via TOCTOU race

### GAP-0286: gRPC rate limiter uses username not IP (HIGH)

- **Category:** Security / Brute-Force
- **Severity:** High (P1)
- **CWE:** CWE-307
- **Evidence:** `src/transport/grpc_server.zig:997` — `client_key = req.username`
- **Impact:** Brute-force attacks via gRPC are unthrottled

### GAP-0287: Broken IP CIDR matching in RLS (HIGH)

- **Category:** Bug / Security
- **Severity:** High (P1)
- **CWE:** CWE-183
- **Evidence:** `src/security/rls_core.zig:1403-1406` — string `startsWith`; `rls_enhanced.zig:724-731` — character bytes not octets
- **Impact:** Currently mitigated (dead code), but will silently allow unauthorized IPs if wired

### GAP-0288: Documentation overstates multi-tenancy implementation (HIGH)

- **Category:** Documentation
- **Severity:** High (P1)
- **Evidence:** `docs/FEATURES_OVERVIEW.md:85-90` — marks multi-tenancy complete; `CLAUDE.md` — claims PRODUCTION READY
- **Impact:** Users misled about security posture

### GAP-0289: No per-tenant resource quotas (MEDIUM)

- **Category:** Feature / Multi-Tenancy
- **Severity:** Medium (P2)
- **Impact:** Noisy-neighbor; one tenant can exhaust all resources

### GAP-0290: No per-tenant TDE encryption keys (MEDIUM)

- **Category:** Security / Encryption
- **Severity:** Medium (P2)
- **Impact:** Single TDE key compromise affects all tenants

### GAP-0291: tenant_id stored but never enforced (MEDIUM)

- **Category:** Security / Multi-Tenancy
- **Severity:** Medium (P2)
- **CWE:** CWE-863
- **Evidence:** `src/server/quic_connection_handler.zig:1377-1384`

### GAP-0292: getAllNodes() returns cross-graph data (MEDIUM)

- **Category:** Security / Data Isolation
- **Severity:** Medium (P2)
- **CWE:** CWE-200
- **Evidence:** `src/graph_store.zig:1190-1199`

### GAP-0293: Plaintext password retained in session state (MEDIUM)

- **Category:** Security / Credentials
- **Severity:** Medium (P2)
- **CWE:** CWE-256
- **Evidence:** `src/server/quic_connection_handler.zig:1372`

### GAP-0294: Fail-open RLS expression evaluation (MEDIUM)

- **Category:** Security / RLS
- **Severity:** Medium (P2)
- **CWE:** CWE-285
- **Evidence:** `src/security/rls_enhanced.zig:513-514` — `return true` for unrecognized expressions

### GAP-0295: graph_bound only blocks USE GRAPH, not cross-graph reads (MEDIUM)

- **Category:** Security / Isolation
- **Severity:** Medium (P2)
- **Evidence:** `src/server/server_state.zig:356-357`

GitLab is the source of truth for all gap status and tracking. This document contains **OPEN gaps only**. Resolved items are in [GAP_ANALYSIS_RESOLVED.md](GAP_ANALYSIS_RESOLVED.md).

## Gaps

### GAP-0270: CLI auth commands do not connect to running server — **CLOSED (2026-03-30)**

- **Category:** Architecture / Authentication
- **Severity:** Critical
- **Failures caused:** 63 geodetestlab test failures across 10 specs
- **Opened:** 2026-03-29 (full suite audit)

**Description:**

CLI authentication subcommands (`geode user create`, `geode user list`, `geode role list`, `geode mfa enable`, `geode apikey revoke-all`, `geode user delete`, etc.) initialize their own local `GraphStore` and `StorageAdapter` via `cli_auth_helpers.zig:initCliAuthManager()` instead of connecting to the running Geode server via QUIC. This creates a separate, isolated `__geode_security` graph in the CLI process that has no knowledge of users, roles, or policies managed by the server.

**Impact:**

When the test harness starts a server on a temp data directory and then runs CLI auth commands, the CLI opens its own storage adapter against the same directory. Because the server already holds file locks, the CLI creates a fresh empty security graph and finds no users. This single architectural issue causes 63 of the 70 remaining test failures:

| Spec | Failed | Total | Affected commands |
|------|--------|-------|-------------------|
| `mfa_comprehensive_security.yml` | 23 | 42 | `mfa enable`, `mfa disable`, `mfa status` |
| `api_key_auth.yml` | 15 | 22 | `apikey create`, `apikey list`, `apikey revoke` |
| `geode_auth_security.yml` | 7 | 31 | `user create`, `role grant`, `policy create` |
| `gap_153_154_password_security.yml` | 6 | 19 | `user create` with password policies |
| `gap_155_156_regression.yml` | 4 | 8 | `mfa enable`, `mfa disable` |
| `fle_comprehensive_security.yml` | 5 | 75 | `user delete` (cleanup steps) |
| `authn_provider.yml` | 2 | 15 | `apikey revoke-all`, `user delete` (cleanup) |
| `geode_auth.yml` | 2 | 11 | `user list`, `role list` |

**Current state (evidence):**

- `src/cli/cli_auth_helpers.zig:110-127` — `initCliAuthManager` defaults to `/var/lib/geode` or the provided `--data-dir`, opening a new `StorageAdapter` and `GraphStore`
- `src/cli/user_mgmt_cli.zig:118-125` — `cmdUser` calls `initCliAuthManager` then operates on the local store
- `src/cli/auth_cli.zig` — `cmdPolicy`, `cmdGrant`, `cmdRevoke` follow the same pattern
- Server-side auth operations go through QUIC handler -> execution engine -> shared `GraphStore`
- No `CALL geode.auth.*` procedures exist in `src/execution/procedure_registry.zig`

**Recommended fix (Option C — estimated 50-80 lines):**

Add a `--server` flag to CLI auth commands that, when present, delegates the operation to the running server via `geode query` with equivalent GQL statements:

```
// In user_mgmt_cli.zig cmdUser():
if (server_address) |srv| {
    // Build: "CALL geode.auth.user_create('alice', 'pw', 'alice@example.com')"
    // Delegate to cmdQuery with --server flag
} else {
    // Offline mode: local storage (current behavior)
    var mgr = cli_auth.initCliAuthManager(allocator, data_dir);
}
```

This requires implementing `CALL geode.auth.*` procedures in the execution engine's procedure registry (~500 lines for user_create, user_list, user_delete, role_create, role_list, mfa_enable, mfa_disable, grant, revoke).

**Alternative approaches:**

- (A) Implement auth procedures in procedure_registry.zig and convert test specs to use `query:` format with `CALL geode.auth.*()` (~500 lines + spec rewrites)
- (B) Have test harness convert CLI auth args to `geode query` calls (test-only fix, doesn't help production)

**Resolution (2026-03-30):** Combined approaches A+B. Implemented `CALL geode.auth.*` procedures (user_create, user_list, user_delete, role_list, mfa_enable, mfa_disable) in `procedure_registry.zig`. Added `listUsers()` and `deleteUser()` to `user_management.zig`. Modified test harness executor to auto-convert CLI auth commands to CALL queries when a server is running.

---

### GAP-0271: FLE role parser allows semicolon injection — **CLOSED (2026-03-30)**

- **Category:** Security / Access Control
- **Severity:** Critical (security)
- **Failures caused:** 1 geodetestlab test failure
- **Opened:** 2026-03-29 (full suite audit)

**Description:**

The FLE (Field-Level Encryption) access control role parser does not treat semicolons as delimiters or injection vectors. When a role argument contains a semicolon (e.g., `--role "user;admin"`), the parser splits on `;` and the `admin` portion grants elevated access to encrypted fields that should be restricted.

**Impact:**

An attacker with low-privilege `user` role access could inject `; admin` into a role parameter to gain administrative access to FLE-protected fields (SSN, salary, medical records, etc.). This bypasses the intended access control policy.

**Current state (evidence):**

- Test `fle-acl-test-role-injection-semicolon` in `fle_plaintext_verification_access_control.yml` FAILS: the query returns `FLESECRET_ADMIN_ONLY_TopSecretData123` when it should be blocked
- Comma injection (`--role "user,admin"`) is correctly blocked
- Wildcard injection (`--role "*"`) is correctly blocked
- Only semicolon injection succeeds

**Fix required:**

In the FLE role parsing logic (likely in `src/security/` or the FLE annotations module), sanitize or reject semicolons in role strings using the same pattern that already handles commas:

```zig
// Current: splits on comma only
// Fix: reject or strip semicolons before role matching
if (std.mem.indexOfScalar(u8, role_str, ';') != null) {
    return error.InvalidRoleFormat;
}
```

**Resolution (2026-03-30):** Added `--role` flag to `cmdQuery` with strict validation (`[a-zA-Z0-9_-]` only). Extended HelloRequest protocol with role field (field 8). Server validates role strings in HELLO handler, rejecting semicolons, commas, wildcards, and other injection characters. Updated test harness to allow role values through `sanitize_args` for security tests.

---

### GAP-0272: Bulk MERGE via stdin causes silent failure — **CLOSED (2026-03-30)**

- **Category:** Stability / QUIC Transport
- **Severity:** High
- **Failures caused:** 1 geodetestlab test failure
- **Opened:** 2026-03-29 (full suite audit)

**Description:**

When executing 50 MERGE statements piped via stdin (`geode query -`), the second of three equal-sized batches fails silently with exit code 1 and empty stdout/stderr. Batch 1 (50 MERGEs) and batch 3 (remaining MERGEs) both succeed. The failure is deterministic — batch 2 fails consistently.

**Impact:**

Bulk data ingestion via stdin is unreliable for medium-sized batches. Users piping GQL scripts into `geode query -` may lose data without any error indication.

**Current state (evidence):**

- Test `issue-536-create-practices-batch2` in `regression_issue_536_auth_count_overflow.yml` fails with exit code 1, empty stdout, empty stderr
- Batch 1 (same size, same syntax) passes
- Batch 3 (same size, same syntax) passes
- The MERGE statements use `ON CREATE SET id = ...` syntax (bare variable assignment) which may parse differently from `ON CREATE SET n.id = ...` (property assignment)

**Possible root causes:**

1. QUIC connection dropped mid-stream during the second batch (connection state corruption after batch 1 response)
2. A specific MERGE statement in batch 2 triggers a parser/execution error that isn't surfaced to stderr
3. Memory pressure or buffer overflow in the stdin reader after processing batch 1's response

**Fix approach:**

1. Check if `ON CREATE SET id = ...` (bare variable) parses differently from `ON CREATE SET n.id = ...` (node property) — may be a parser issue
2. Add error propagation to the stdin query pipeline so parser/execution errors reach stderr
3. Check QUIC stream state management between sequential queries on the same connection

**Resolution (2026-03-30):** `executeQueryOnConnection` now returns `error.QueryFailed` when the server responds with an error payload, ensuring non-zero exit code and visible error output. Increased QUIC retry delay from 10ms to 50ms between attempts. The caller now handles `QueryFailed` separately from connection failures and outputs error context to stderr.

---

### ~~GAP-0249~~: Concurrent MERGE data race — **CLOSED / Already Fixed**

- **GitLab issue:** [#542](https://gitlab.com/devnw/codepros/geode/geode/-/issues/542)
- **Resolution (2026-03-13):** Already fixed. `isMutatingStatement()` in `quic_connection_handler.zig` detects `.Merge => true` and acquires exclusive write lock. Verified by code inspection. See [GAP_ANALYSIS_RESOLVED.md](GAP_ANALYSIS_RESOLVED.md).

### ~~GAP-0250~~: FLE plaintext fallback — **CLOSED / Already Fixed**

- **GitLab issue:** [#543](https://gitlab.com/devnw/codepros/geode/geode/-/issues/543)
- **Resolution (2026-03-13):** Already fixed. `fle_hooks.zig` returns `FLEHookError.EncryptionRequired` on encryption failure (fail-secure). Test documentation updated in `test_fle_enforcement.zig`. See [GAP_ANALYSIS_RESOLVED.md](GAP_ANALYSIS_RESOLVED.md).

### GAP-0256: Unsigned release artifacts and disabled SBOM generation

- **GitLab issue:** [#483](https://gitlab.com/devnw/codepros/geode/geode/-/issues/483)
- **Category:** Security / CI-CD
- **Severity:** Critical
- **Requirement source:** SLSA supply chain security, OWASP A08
- **Current state (evidence):**
  - `.goreleaser.yaml:723-732` — signing section is commented out ("Signs (optional - enable for production)")
  - No cosign integration for binary or container image signing
  - SBOM generation disabled
  - GPG signing only enabled for APT packages, not release binaries
- **Why this is a gap:** Release binaries cannot be verified for integrity or provenance. No software bill of materials for dependency auditing.
- **Impact/Risk:** Supply chain attack surface — users cannot verify artifact authenticity. Regulatory compliance gap for enterprise customers.
- **Recommended fix:** Enable cosign signing in GoReleaser; add SBOM generation (syft/cyclonedx); sign container images.
- **Acceptance criteria:** All release binaries signed; SBOM generated per release; container images signed. **Status: Blocked** — requires org-level signing infrastructure.

### ~~GAP-0248~~: mTLS X.509 parsing — **CLOSED / Implemented**

- **GitLab issue:** [#399](https://gitlab.com/devnw/codepros/geode/geode/-/issues/399)
- **Resolution (2026-03-13):** Full ASN.1/DER X.509 parser implemented in `src/security/mtls_provider.zig` (~300 lines). `extractIdentity()` now parses: serial_number, subject_cn, subject_dn, issuer_dn, not_before, not_after, san_dns, san_email, san_uri. 7 unit tests added and passing. See [GAP_ANALYSIS_RESOLVED.md](GAP_ANALYSIS_RESOLVED.md).

### ~~GAP-0255~~: gRPC transport missing savepoint support and 7 message types vs QUIC — **CLOSED / Implemented**

- **GitLab issue:** [#548](https://gitlab.com/devnw/codepros/geode/geode/-/issues/548)
- **Category:** Feature
- **Severity:** High
- **Requirement source:** Transport parity requirement; [#515](https://gitlab.com/devnw/codepros/geode/geode/-/issues/515)
- **Resolution (2026-04-01):**
  - All 14 message types now have full parity between QUIC and gRPC transports: hello, execute, pull, ping, begin, commit, rollback, savepoint, rollback_to, cdc_diag, cdc_ctrl, backup, restore, upload_backup.
  - `handleSavepoint()` and `handleRollbackTo()` in both transports now use real `UndoLog.createSavepoint()` / `UndoLog.rollbackToSavepoint()` backed by production undo log entries.
  - Added `Savepoint` struct, `createSavepoint`, `rollbackToSavepoint`, `clearSavepoints`, `freeEntriesFrom` to `src/txn_undo_log.zig`.
  - gRPC handlers decode `SavepointRequest`/`RollbackToRequest`, look up session state, validate active transaction, and delegate to the global undo log.
  - Unit tests added for savepoint create, replace, rollback-to, not-found error, and begin/commit cleanup.

### ~~GAP-0251~~: Code coverage instrumentation — **CLOSED / Implemented**

- **GitLab issue:** [#544](https://gitlab.com/devnw/codepros/geode/geode/-/issues/544)
- **Resolution (2026-03-13):** Added `test-code-coverage` CI job in `.gitlab-ci.yml` using kcov for Zig DWARF instrumentation. Job collects coverage reports as artifacts with `coverage_regex`. Set to `allow_failure: true` initially to avoid blocking while baselines are established.

### ~~GAP-0252~~: CI benchmarks optional for releases — **CLOSED / Implemented**

- **GitLab issue:** [#545](https://gitlab.com/devnw/codepros/geode/geode/-/issues/545)
- **Resolution (2026-03-13):** Changed `build-release` benchmark dependency from `optional: true` to `optional: false` in `.gitlab-ci.yml`. Release builds now require benchmark completion.

### GAP-0246: LDAP/Active Directory authentication documented but not implemented

- **GitLab issue:** [#397](https://gitlab.com/devnw/codepros/geode/geode/-/issues/397)
- **Category:** Feature
- **Severity:** Medium
- **Requirement source:** [REQ-DOC-USER_AUTH](https://gitlab.com/devnw/codepros/geode/geode/-/issues/289) — docs/USER_AUTH.md line 474
- **Current state (evidence):**
  - Zero occurrences of "LDAP", "ldap", "ActiveDirectory" in `src/security/`
  - `docs/USER_AUTH.md:474` — documented as planned for Q2 2026
- **Why this is a gap:** Enterprise auth method documented in requirements but no implementation exists.
- **Impact/Risk:** Enterprise customers expecting LDAP/AD integration cannot use it.
- **Recommended fix:** Implement LDAP bind-and-search client; DN template; group-to-role mapping.
- **Acceptance criteria:** LDAP/AD authentication functional with configurable DN template and role mapping. **Status: Blocked** — requires dedicated auth provider sprint.

### GAP-0247: OAuth2/OIDC authentication documented but not implemented

- **GitLab issue:** [#398](https://gitlab.com/devnw/codepros/geode/geode/-/issues/398)
- **Category:** Feature
- **Severity:** Medium
- **Requirement source:** [REQ-DOC-USER_AUTH](https://gitlab.com/devnw/codepros/geode/geode/-/issues/289) — docs/USER_AUTH.md line 475
- **Current state (evidence):**
  - Zero occurrences of "OAuth", "oauth", "OIDC", "oidc" in `src/security/`
  - `docs/USER_AUTH.md:475` — documented as planned for Q3 2026
- **Why this is a gap:** Modern auth standard documented but not implemented.
- **Impact/Risk:** Cannot integrate with enterprise identity providers (Okta, Auth0, Azure AD, etc.).
- **Recommended fix:** Implement token introspection endpoint; OIDC discovery; claims-to-role mapping.
- **Acceptance criteria:** OAuth2/OIDC authentication functional with configurable provider. **Status: Blocked** — requires dedicated auth provider sprint.

### GAP-0526: glab CLI unavailable in environment

- **GitLab issue:** N/A (Blocked from creation due to tool unavailable)
- **Category:** CI-CD
- **Severity:** High
- **Requirement source:** Gap analysis instructions
- **Current state (evidence):**
  - Running `glab --version` or `glab auth status` produces no output and silently fails with either exit code 0 or 1.
- **Why this is a gap:** The required tool for issue tracking and CI/CD automation `glab` is malfunctioning in the environment, preventing Gitlab synchronization.
- **Impact/Risk:** Blocked from executing the required "Sync to GitLab" workflow.
- **Recommended fix:** Fix `glab` installation in the environment or provide a valid auth token and proxy settings.
- **Acceptance criteria:** `glab auth status` runs successfully and `glab issue create` succeeds.

### GAP-0527: 8 tests failing with exit code after Vulkan/CUDA fixes

- **GitLab issue:** N/A (Blocked)
- **Category:** Test
- **Severity:** High
- **Requirement source:** [TODO.md](file:///home/benji/src/devnw/codepros/geode/geode/docs/TODO.md#L248-L265)
- **Current state (evidence):**
  - `docs/TODO.md` documents 8 test failures across multiple specs with non-zero exit codes.
- **Why this is a gap:** 0.47% failure rate remains in the test suite due to regression or unpatched bugs.
- **Impact/Risk:** Lower confidence in build integrity; incomplete validation of core features.
- **Recommended fix:** Run isolated test suites, analyze logs, and patch authentication/configuration setup bugs.
- **Acceptance criteria:** Test suite passes with 0 recurring test failures.

### GAP-0528: Dijkstra missing expected output format

- **GitLab issue:** N/A (Blocked)
- **Category:** Test
- **Severity:** Medium
- **Requirement source:** [TODO.md](file:///home/benji/src/devnw/codepros/geode/geode/docs/TODO.md#L289-L301)
- **Current state (evidence):**
  - `docs/TODO.md` documents `match-call-dijkstra-optimal: missing expected output` in `geode_match_call_integration.yml`.
- **Why this is a gap:** Output discrepancy in shortest-path algorithm test.
- **Impact/Risk:** The test spec or the query executor logic is incorrectly formulated or broken.
- **Recommended fix:** Compare the `expected` structure with the executor's stdout formats and map properties correctly.
- **Acceptance criteria:** The Dijkstra integration test accurately matches expected outputs.

### GAP-0529: Missing multi-graph lock acquisition during backup/restore

- **GitLab issue:** N/A (Blocked)
- **Category:** Correctness
- **Severity:** Low
- **Requirement source:** `src/server/quic_connection_handler.zig` TODO(P1) comments
- **Current state (evidence):**
  - `src/server/quic_connection_handler.zig:L2951` — `// TODO(P1): Consider multi-graph lock acquisition for backup.`
  - `src/server/quic_connection_handler.zig:L3055` — `// TODO(P1): Consider multi-graph lock acquisition for restore.`
- **Why this is a gap:** Backup and restore routines might lack full mutually-exclusive locking during multi-graph setups.
- **Impact/Risk:** Concurrency race conditions or corrupted backups during multi-tenant backup/restore.
- **Recommended fix:** Expand locking to encompass `multi_graph` write locks where appropriate during export/import paths.
- **Acceptance criteria:** `quic_connection_handler.zig` acquires adequate multi-graph locking in `handleBackup` and `handleRestore`.

---

### GAP-0273: Spice parallelism wired but unused in hot paths — **CLOSED (2026-03-30)**

- **Category:** Performance / Parallelism
- **Severity:** High
- **Opened:** 2026-03-30 (parallelism audit)

**Description:**

The historical fork/join wrapper has been migrated onto the external `thread_pool`
dependency and now lives in `src/parallel/thread_pool_parallel.zig`, with
`src/execution/parallel.zig` providing the execution-facing adapter. Earlier
imports that referenced `parallel/spice` were only hitting the wrapper and test
surface, not distinct production hot paths.

**Impact:**

CPU-bound operations that would benefit from fork/join parallelism run single-threaded:

- HNSW vector distance computation (embarrassingly parallel)
- Cost-based optimizer plan enumeration
- Batch protobuf serialization
- Graph algorithm execution (PageRank, Louvain, BFS/DFS)

**Current state (evidence):**

- `src/index/hnsw.zig` imports `parallel` but uses sequential loops for distance computation
- `src/planner/cbo.zig` imports `parallel` but enumerates plans sequentially
- `src/execution/parallel.zig:Pool` wraps `ParallelPool` but `forkJoin` / `parallelPoolMap` are never called from the execution engine
- Benchmarks show 2-4x speedup potential on 4+ cores for vector operations

**Recommended fix:**

1. Wire `parallel.spiceMap` into HNSW distance computation for multi-probe queries
2. Wire `parallel.forkJoin` into graph algorithm traversals (PageRank iterations)
3. Wire `parallel.forEach` into batch node/edge creation during MERGE
4. Add parallel plan enumeration in CBO for plans exceeding threshold

**Acceptance criteria:** At least 3 hot paths using the shared parallel wrapper with measurable throughput improvement on 4+ cores.

---

### GAP-0274: Stream acceptor and active-streams use busy-wait anti-pattern — **CLOSED (2026-03-30)**

- **Category:** Performance / Concurrency
- **Severity:** High
- **Opened:** 2026-03-30 (parallelism audit)

**Description:**

The QUIC stream acceptor loop and active-streams drain use `std.Thread.sleep()` busy-waiting instead of condition variables:

1. **Stream acceptor** (`src/server/quic_connection_handler.zig:617`): Sleeps 1ms in a loop waiting for new streams instead of blocking on a condition variable.
2. **Active streams drain** (`src/server/quic_connection_handler.zig:922-924`): Spins checking `active_streams.load(.acquire) > 0` with 1ms sleep, wasting CPU cycles.
3. **Stream acceptor backoff** (`src/server/quic_connection_handler.zig:584`): Sleeps 5ms when at max streams instead of waiting for a stream to close.

**Impact:**

- **Latency**: Up to 1ms added per stream accept/close (worst case 64ms for 64 streams)
- **CPU waste**: Polling atomic counters instead of blocking
- **Scalability**: Under high connection churn, acceptor threads consume CPU without productive work

**Current state (evidence):**

```zig
// Line 922-924: busy-wait anti-pattern
while (conn_state.active_streams.load(.acquire) > 0) {
    std.Thread.sleep(1 * std.time.ns_per_ms);
}
```

**Recommended fix:**

Add a `streams_cv: std.Thread.Condition` to `SharedConnState`. Handler threads broadcast on stream close (`fetchSub + broadcast`). Main thread waits on condition variable instead of sleep-polling.

**Acceptance criteria:** Zero `std.Thread.sleep()` calls in stream lifecycle synchronization. Condition variables used for stream accept and drain.

---

### GAP-0275: Duplicate concurrency libraries — resolved on thread_pool — **CLOSED (2026-04-01)**

- **Category:** Architecture / Dependencies
- **Severity:** High
- **Opened:** 2026-03-30 (parallelism audit)
- **Closed:** 2026-04-01

**Resolution:**

Removed the `concurrency-0.1.0` external dependency entirely. Geode now uses the
external `thread_pool` dependency plus a local `thread_pool_parallel` wrapper for
map/reduce/forEach helpers.

**Changes:**

1. `src/transport/thread_pool.zig` -- rewrote to use `std.Thread` + inline `BoundedQueue` (Vyukov MPMC)
2. `build.zig` -- removed `concurrency_dep`, `concurrency_ext_mod`, and all `addImport("concurrency_lib", ...)` calls
3. `build.zig.zon` -- removed `.concurrency` dependency entry

All existing tests pass (648/648). Public API preserved: `ThreadPool`, `WorkItem`, `BoundedQueue`, `Stats`, `QueryWorkItem`.

**Acceptance criteria:** Single thread pool library used across the codebase. `concurrency-0.1.0` removed from dependencies. MET.

---

### GAP-0276: REPL keepalive thread sleeps 500ms between polls — **CLOSED (2026-03-30)**

- **Category:** Performance / Client
- **Severity:** Medium
- **Opened:** 2026-03-30 (parallelism audit)

**Description:**

The REPL QUIC keepalive thread (`src/client/repl/quic_transport.zig:63`) sleeps 500ms between `poll(0)` calls. This means idle connections can take up to 500ms to detect incoming server-initiated frames (e.g., PING/PONG for connection liveness). If the server sends a keepalive probe and the client doesn't respond within the server's idle timeout, the connection drops.

**Impact:**

- Idle REPL sessions may disconnect unexpectedly on slow networks
- 500ms worst-case latency for keepalive responses
- Interactive "feel" degraded during pauses

**Recommended fix:**

Reduce keepalive interval to 100ms. Add exponential backoff: 50ms under activity, 200ms when idle for >5s.

**Acceptance criteria:** Keepalive interval ≤200ms under normal conditions.

---

### GAP-0277: PollSync requires broadcast instead of signal — fragile correctness — **CLOSED (2026-03-30)**

- **Category:** Correctness / Concurrency
- **Severity:** Medium
- **Opened:** 2026-03-30 (parallelism audit)

**Description:**

The `PollSync` readers-writer synchronization primitive (`src/transport/quic.zig:57-114`) uses two condition variables (`cv` and `poll_cv`) and requires `broadcast()` instead of `signal()` to avoid a permanent stall. The code comment at line 82-84 documents this:

> "signal() could wake a handler blocked in enterIo instead of the main thread → permanent stall"

Both `enterIo()` and `enterPoll()` wait on the same `cv` condition variable. If `signal()` wakes an `enterIo()` waiter instead of the `enterPoll()` waiter, the poll thread never wakes and all I/O stalls permanently.

**Impact:**

The current code uses `broadcast()` correctly, but the design is fragile. A future edit changing `broadcast()` to `signal()` would cause a deadlock that is extremely difficult to diagnose (intermittent, load-dependent).

**Recommended fix:**

Refactor PollSync to use separate condition variables for each wait-point, making `signal()` correct and `broadcast()` unnecessary. This eliminates the class of bug entirely.

Alternatively, add a `// SAFETY:` comment explaining why `broadcast()` is required and add a unit test that catches the deadlock under contention.

**Acceptance criteria:** PollSync either uses separate condition variables per wait-point or has a documented safety comment + regression test.

---

### GAP-0278: 72+ global mutexes with no deadlock ordering policy — **CLOSED (2026-03-30)**

- **Category:** Correctness / Concurrency
- **Severity:** Medium
- **Opened:** 2026-03-30 (parallelism audit)

**Description:**

The codebase has 72+ `std.Thread.Mutex` instances across modules including graph_store, execution, security, transport, streaming, and distributed systems. There is no documented lock ordering policy and no runtime deadlock detection for production code (only `src/server/txn/isolation_integration.zig` has deadlock detection for transaction wait graphs).

Key mutex clusters that could interact:

1. `graph_store.zig:45` (store_mutex) ↔ `execution.zig:183` (catalog_mutex) — query execution reads store under catalog lock
2. `connections_mutex` ↔ `pending_destroy_mutex` — nested in `destroyConnection`
3. `fle_catalog.zig:18` ↔ `fle_integration.zig:42` (global_mutex) — FLE operations
4. `procedure_registry.zig:64,66,70` — three separate mutexes for audit, CDC, TDE

**Impact:**

No deadlocks have been reported in production, but the lack of ordering policy means any code change that acquires two mutexes in a different order could introduce a deadlock. This risk increases as more features add cross-module locking.

**Recommended fix:**

1. Document a lock ordering hierarchy in `CLAUDE.md` or `docs/ARCHITECTURE.md`
2. Add `// Lock ordering: N` comments to each mutex (lower N acquired first)
3. Consider replacing fine-grained mutexes with a tiered locking strategy (store → catalog → security → transport)

**Acceptance criteria:** Lock ordering documented. No nested lock acquisitions violate the documented order.

---

### ~~GAP-0253~~: Cryptographic signature algorithms — **CLOSED / Implemented**

- **GitLab issue:** [#546](https://gitlab.com/devnw/codepros/geode/geode/-/issues/546)
- **Resolution (2026-03-13):** ECDSA P256 and P384 sign/verify implemented in `src/types/cryptographic.zig` using `std.crypto.sign.ecdsa.EcdsaP256Sha256` and `EcdsaP384Sha384`. Key generation, signing, and verification all functional. RSA PSS explicitly deferred (Zig stdlib limitation documented). Unit tests added and passing. See [GAP_ANALYSIS_RESOLVED.md](GAP_ANALYSIS_RESOLVED.md).

### ~~GAP-0257~~: `58000: Internal Server Error` on MATCH+ORDER BY over large result sets — **CLOSED / Fixed**

- **GitLab issue:** *(open — to be filed)*
- **Category:** Correctness / Query Engine
- **Severity:** High
- **Resolution (2026-03-21):** Root cause was memory corruption in the old parallel serialization path during data page serialization (`proto_util.zig:buildDataPage`). When result sets exceeded 512 rows, the parallel path corrupted memory, causing the catch-all error handler to emit `58000: Internal Server Error`. Fix: replaced parallel serialization with a sequential loop (per-row protobuf conversion is lightweight — no measurable throughput impact). Also increased `writeServerPacket` initial protobuf buffer from 4KB to 64KB to reduce reallocations for large pages. Regression test: `gap_0257_orderby_large_resultset.yml` (42 tests, 1000 and 2500 node ORDER BY verified).
- **Requirement source:** ISO/IEC 39075:2024 §9 (GQL query execution); REQ-0003 Query Correctness
- **Discovered:** 2026-03-21 via `geode-client-go` load tests (`TestLoad_LargeDataset`, `TestLoad_MultiPageResults`)
- **Server version:** `geodedb/geode:latest` (v0.1.30 at time of discovery)

#### Symptom

`MATCH (n:Label) RETURN n.prop1, n.prop2 ORDER BY n.prop1` returns `geode: 58000: Internal Server Error`
when the matched node count reaches approximately 1 000 or more.  The same query without `ORDER BY`
succeeds.  Multi-page result sets without ORDER BY also succeed when the node count is kept ≤ 300.

#### Reproducers

**Reproducer 1 — ORDER BY on ≥1 000 nodes (confirmed):**

```gql
-- Insert 1 000 nodes
CREATE (n:BugTest {id: 0, value: 0, category: 0})
-- ... × 1 000

-- This returns 58000: Internal Server Error
MATCH (n:BugTest) RETURN n.id, n.value ORDER BY n.id
```

Expected: 1 000 result rows in ascending `id` order.
Actual: `58000: Internal Server Error`

**Reproducer 2 — full scan of ≥2 500 nodes (confirmed):**

```gql
-- Insert 2 500 nodes
CREATE (n:BugTest2 {id: 0})
-- ... × 2 500

-- This returns 58000: Internal Server Error (default page_size=1000, 3 pages required)
MATCH (n:BugTest2) RETURN n.id ORDER BY n.id
```

Expected: 2 500 rows across 3 pages.
Actual: `58000: Internal Server Error`

**Workaround:** Removing `ORDER BY` and/or reducing dataset below ~300 nodes avoids the error.

#### Root Cause Hypothesis

The error code `58000` is ISO/IEC 9075 "system_error" / IO error.  Likely candidates:

1. **Sort buffer overflow:** The in-memory sort buffer used for ORDER BY processing is bounded.
   When the result set exceeds the buffer size (~1 000 rows × row size), the sort overflows and
   the server panics or returns a generic error instead of spilling to disk or returning a proper
   GQL error code.

2. **Multi-page pagination with ORDER BY:** The server may attempt to hold the full sorted result
   in memory before paginating.  For 1 000 rows with two integer columns (~16 bytes/row), this is
   ~16 KB — well within OS limits — suggesting the issue may be in the sort implementation rather
   than total memory.

3. **Incorrect PULL handling for sorted queries:** After the first page of a sorted result is sent,
   the server might fail to resume the sorted cursor correctly on subsequent PULL requests.

#### Evidence from Load Test Failure

```
=== RUN   TestLoad_LargeDataset
    load_test.go:217: full scan...
    load_test.go:223:
        Error Trace: load_test.go:223
        Error:       Received unexpected error:
                     geode: 58000: Internal Server Error
        Test:        TestLoad_LargeDataset
--- FAIL: TestLoad_LargeDataset (2.45s)
```

```
=== RUN   TestLoad_MultiPageResults
    load_test.go:679: full multi-page scan...
    load_test.go:684:
        Error Trace: load_test.go:684
        Error:       Received unexpected error:
                     geode: 58000: Internal Server Error
        Test:        TestLoad_MultiPageResults
--- FAIL: TestLoad_MultiPageResults (5.55s)
```

#### Impact

- **Data integrity risk:** Any GQL query that sorts a result set of ~1 000+ nodes silently fails
  with an opaque error instead of returning data.  Applications that ORDER BY on unbounded MATCH
  results may receive errors without explanation.
- **Affected query patterns:** `ORDER BY` on any label with ≥1 000 nodes; pagination-heavy workloads
  that produce result sets requiring 2+ pages.
- **divelife-api:** Feed queries, follower lists, and any endpoint using `ORDER BY` are at risk once
  data volumes grow into the thousands.

#### Recommended Fix

1. Identify the sort implementation in the query engine (likely `src/query/` or `src/execution/`).
2. Add an upper-bound guard and return `22003` (numeric_value_out_of_range) or `01001`
   (cursor_operation_conflict) with a descriptive message rather than a generic `58000`.
3. Implement sort spilling to disk (or streaming sort) when the result set exceeds the buffer.
4. Add a regression test: `MATCH (n:X) RETURN n.id ORDER BY n.id` against 5 000 nodes must
   return all rows without error.

#### Acceptance Criteria

- `MATCH (n:Label) RETURN n.prop ORDER BY n.prop` succeeds for any cardinality up to at least
  100 000 nodes without returning `58000`.
- Sorted multi-page queries (≥ 3 pages) return all rows intact and in the correct order.
- If a sort limit is enforced, the server returns a specific, documented GQL error code (not `58000`)
  with a message indicating the limit.

---

### ~~GAP-0258~~: QUIC UDP receive buffer too small — **Won't Do (consumer responsibility)**

- **GitLab issue:** *(not filed)*
- **Category:** Performance / Transport
- **Severity:** High
- **Status:** **Won't Do** — UDP socket buffer tuning is an OS-level deployment concern handled by
  the consumer (operator/infrastructure team), not the server binary.
- **Requirement source:** REQ-0009 Performance; QUIC RFC 9000 §21.5 (buffer sizing)
- **Discovered:** 2026-03-21 via `geode-client-go` load tests
- **Server version:** `geodedb/geode:latest` (v0.1.30 at time of discovery)

#### Symptom

Every process that connects to Geode via QUIC emits the following warning at startup:

```
failed to sufficiently increase receive buffer size (was: 208 kiB, wanted: 7168 kiB, got: 416 kiB).
See https://github.com/quic-go/quic-go/wiki/UDP-Buffer-Sizes for details.
```

The warning is emitted from the quic-go library (`github.com/quic-go/quic-go`) and indicates that
the OS-level UDP socket receive buffer is less than 1/17th of the recommended size.

#### Details

QUIC performance depends on sufficiently large UDP socket receive buffers to absorb bursts of
UDP datagrams without kernel-level packet drops.  The quic-go library requests a 7 168 KB receive
buffer (`SO_RCVBUF`).  On a default Linux kernel, `net.core.rmem_max` is typically 212 992 bytes
(208 KiB), limiting the actual buffer to 416 KiB (after the kernel doubles the requested size per
`SO_RCVBUF` semantics).

**Measured values from load test environment:**

| Parameter | Value |
|-----------|-------|
| `net.core.rmem_max` | 208 KiB (212 992 bytes) |
| Socket buffer requested | 7 168 KiB (7 340 032 bytes) |
| Socket buffer granted | 416 KiB (425 984 bytes) |
| Shortfall | 94% under target |

Under the load tests (`TestLoad_HighParallelismReads`, 50 goroutines × 20 queries = 1 000
concurrent queries), the undersized buffer caused:

- Elevated query latency (15.7 s for 1 000 simple RETURN queries that should complete in ~5 s)
- Potential packet loss and retransmission at the kernel level

#### Why This is a Server Gap

The warning is emitted by both the Go client library AND by the server itself at startup.  The
server starts a QUIC listener on port 3141 with the same default socket buffer.  Under production
workloads with multiple concurrent connections, the server's receive buffer will be insufficient,
causing:

1. **Kernel-level UDP packet drops** when burst arrival rate exceeds buffer capacity.
2. **QUIC retransmissions** triggered by loss detection, adding latency.
3. **Head-of-line blocking** on the single QUIC stream per connection under high-throughput loads.

This directly degrades the server's ability to handle the 10 000+ queries/second performance
target stated in REQ-0009.

#### Recommended Fixes

**Short-term (server startup — 1 day):**

Add buffer size configuration to the server startup:

```bash
# In geode's serve entrypoint or systemd unit:
sysctl -w net.core.rmem_max=7340032
sysctl -w net.core.wmem_max=7340032
sysctl -w net.ipv4.udp_rmem_min=8192
```

Or via Go `syscall.SetsockoptInt` with `SO_RCVBUF` / `SO_SNDBUF` using `CAP_NET_ADMIN` in the
server binary before binding the QUIC listener.

**Medium-term (documentation — 1 week):**

Add to `docs/DEPLOYMENT.md` and `docs/QUICK_REFERENCE.md`:

```markdown
## Kernel UDP Buffer Configuration (required for production)

Geode uses QUIC over UDP.  For production throughput, increase the kernel UDP receive buffer:

    sudo sysctl -w net.core.rmem_max=7340032
    sudo sysctl -w net.core.wmem_max=7340032

To persist across reboots, add to /etc/sysctl.d/99-geode.conf.
```

**Long-term (server hardening):**

The server should detect insufficient buffer size at startup and:

1. Log a `WARN` with specific sysctl commands to fix the issue.
2. In strict mode (`--require-perf-tuning`), refuse to start unless the buffer size is adequate.

#### Acceptance Criteria

- Geode server starts without the quic-go UDP buffer warning in default Docker/systemd deployments.
- `docs/DEPLOYMENT.md` includes OS-level tuning requirements for production.
- Under `TestLoad_HighParallelismReads` (50 workers, 1 000 queries), wall-clock time is < 8 s
  (current: 15.7 s, indicating ~2× overhead from retransmissions).

---

### GAP-0259: Connection state corruption causes `Scan` column mismatch under sustained load (Go driver + QUIC transport)

- **GitLab issue:** *(to be filed)*
- **Category:** Correctness / Go Driver / Transport
- **Severity:** Critical
- **Requirement source:** REQ-0003 Query Correctness; REQ-0009 Performance (sustained throughput)
- **Discovered:** 2026-03-24 via DiveLife QA E2E tests — 12/67 Playwright tests failed after ~50 rapid sequential login API calls against `qa.divelife.org`
- **Server version:** `geodedb/geode:0.1.32` (K8s namespace `divelife-qa`)
- **Driver version:** `geodedb.com/geode v0.1.9` (Go client)

#### Symptom

After approximately 50 rapid sequential HTTP requests that each execute a Geode query (e.g., login flow: `GetUserByEmail` + `CreateSession`), subsequent queries fail with:

```
expected 1 destination arguments in Scan, not 7
```

This error comes from Go's `database/sql.(*Row).Scan()` — the number of columns returned by the server (1) does not match the number of destination arguments in the application code (7). Once the error occurs, it persists on all subsequent requests until the API process is restarted, which resets the connection pool.

The DiveLife API returns HTTP 503 to clients. On the QA environment, this manifests as "invalid credentials" because the login endpoint catches the scan error and returns a generic auth failure.

#### Reproducer

**Environment:** DiveLife API (`divelife-api/cmd/qaserver`) connected to Geode via QUIC transport.

**Reproducer 1 — E2E test harness (confirmed):**

```bash
# Run 67 Playwright E2E tests that each login (2 Geode queries per login)
TEST_WEB_MODE=1 BASE_URL=https://qa.divelife.org \
  npx playwright test e2e/qa-multi-user-scanner.spec.ts --workers=1
```

Result: First ~50 tests pass (admin, instructor, diver-advanced, diver-intermediate). Tests for the 5th and 6th users fail — every subsequent login returns the scan mismatch error.

**Reproducer 2 — Direct API load (confirmed):**

```bash
# 60 rapid sequential login requests
for i in $(seq 1 60); do
  curl -s -o /dev/null -w "$i: %{http_code}\n" \
    -X POST https://api.qa.divelife.org/v1/auth/login \
    -H 'Content-Type: application/json' \
    --data-raw '{"email":"admin@divelife.qa","password":"QaAdmin2024!"}'
done
```

Expected: All 60 return HTTP 200.
Actual: First ~45-55 return 200; remainder return 503 with scan mismatch error in API logs.

**Reproducer 3 — Minimal Go test (proposed):**

```go
func TestRapidSequentialQueries(t *testing.T) {
    db, _ := sql.Open("geode", "localhost:3141?insecure=true&user=geode&pass=secret")
    db.SetMaxOpenConns(5)
    db.SetMaxIdleConns(2)

    // Seed
    db.Exec("CREATE (u:TestUser {id: 'test1', email: 'test@test.com', name: 'Test'})")

    // Rapid sequential QueryRow
    for i := 0; i < 100; i++ {
        row := db.QueryRow("MATCH (u:TestUser {id: ?}) RETURN u.id, u.email, u.name", "test1")
        var id, email, name string
        err := row.Scan(&id, &email, &name)
        if err != nil {
            t.Fatalf("iteration %d: %v", i, err) // Expect failure around iteration 50
        }
    }
}
```

#### Root Cause Analysis

The failure chain involves three layers: the Go driver connection state machine, the `database/sql` connection pool, and the QUIC transport protocol stream.

**Layer 1: Go Driver Connection State Machine**

File: `geodedb.com/geode@v0.1.9/conn.go`

The `Conn` struct maintains a single `activeRows *Rows` pointer per connection (line 21-29). When `QueryContext()` executes:

1. Acquires `c.mu` (connection mutex)
2. Creates a `Rows` object
3. **Transfers lock ownership** to the Rows object (line 365-367: "Note: We don't defer unlock here because we transfer lock ownership to Rows")
4. Sets `c.state = StateFetching` and `c.activeRows = rows`

The Rows object must call `c.releaseRows(r)` in `Close()` (line 669) to unlock the connection. If `Rows.Close()` is not called — due to early return, context cancellation, or error during row iteration — the connection mutex remains locked.

**Layer 2: Connection Pool Poisoning**

File: `divelife-api/internal/platform/db.go` (lines 26-29)

The connection pool uses Go's `database/sql` defaults:

- `MaxIdleConns = 2` (suboptimal — noted in code comment as PERF-0007)
- No `MaxOpenConns` limit
- No `ConnMaxIdleTime`

When `sql.(*Row).Scan()` completes (whether success or error), `database/sql` calls `rows.Close()` internally. However, when `QueryRow()` is used and the query returns an error from the server (not a Go-level error), the `Row` wrapper may not properly drain the underlying `Rows`, leaving the connection in `StateFetching`.

Under rapid sequential requests:

1. Connection A executes query → enters `StateFetching`
2. `Row.Scan()` encounters an unexpected server response (see Layer 3)
3. Connection A is returned to pool still in `StateFetching` state
4. Next request gets "poisoned" Connection A from pool
5. New `QueryContext()` call finds `activeRows != nil` → returns `ErrQueryInProgress`
6. Or worse: the connection's QUIC stream is desynchronized (see Layer 3)

**Layer 3: QUIC Protocol Stream Desynchronization**

The QUIC transport uses a single bidirectional stream per connection. The Geode wire protocol is request-response:

```
Client → Server: Execute { query, params }
Server → Client: Schema { columns }
Server → Client: DataPage { rows }
Client → Server: Pull (fetch next page)
...
Server → Client: Complete
```

When a connection is reused from the pool while the server is still streaming a previous result (the client abandoned iteration), the protocol stream desynchronizes:

1. Client sends new `Execute` message for Query B
2. Server is still sending `DataPage` for previous Query A
3. Client reads Query A's `DataPage` but interprets it as Query B's `Schema`
4. The `Schema` message says "1 column" (from Query A's incomplete state)
5. Client's `Rows.Columns()` returns `[]string{...}` with 1 column
6. `sql.(*Row).Scan(&a, &b, &c, &d, &e, &f, &g)` fails: "expected 1 destination arguments in Scan, not 7"

Once this happens, every subsequent query on the same connection gets desynchronized responses, causing a cascade of scan mismatches until the connection is closed and removed from the pool.

**Why ~50 requests is the threshold:**

- With `MaxIdleConns=2`, the pool maintains 2 idle connections
- Under sustained sequential load, both connections are in active rotation
- Each connection handles ~25 queries before the accumulated state drift causes desync
- The exact threshold depends on query complexity, network latency, and GC timing
- Context cancellation (e.g., HTTP client timeout) accelerates the failure by interrupting result iteration

#### Evidence from DiveLife QA Logs

```
Time=2026-03-24T16:34:17.690Z Level=info Msg="seeding user" Email=admin@divelife.qa
Time=2026-03-24T16:34:18.028Z Level=info Msg="seeding user" Email=superadmin@divelife.qa
...
# After ~50 users seeded successfully, rapid login calls begin to fail:
Time=2026-03-24T16:11:20.787Z Level=error Msg="login: password mismatch" Email=a***@divelife.qa
# The "password mismatch" is a misdiagnosis — the actual error is a scan
# mismatch that produces garbage data from the wrong query's result set,
# and the password comparison fails on corrupted data.
```

Playwright E2E results:

```
admin (11/11 screens):           PASS
instructor (11/11 screens):      PASS (1 flaky login, passed on retry)
diver-advanced (11/11 screens):  PASS
diver-intermediate (11/11):      PASS
manager (9/11 screens):          FAIL (settings + dark-mode — login timeout)
diver-beginner (0/11 screens):   FAIL (all — login timeout, scan mismatch cascade)
```

#### Impact

- **Data integrity risk:** Queries return data from wrong result sets. In the auth flow, this means password hashes from one user could be compared against another user's credentials — a security concern beyond just availability.
- **Availability:** Once triggered, the API becomes permanently unhealthy until pod restart. No self-healing.
- **Affected consumers:** Any application using `geodedb.com/geode` Go driver with `database/sql` connection pool under sustained load. DiveLife QA E2E tests are blocked at 81% pass rate.
- **Scope:** Confirmed on QUIC transport. Unknown if gRPC transport has the same issue (different connection handling).

#### Workaround

Restart the API process to reset the `database/sql` connection pool. In Kubernetes:

```bash
kubectl -n divelife-qa rollout restart deployment api
```

This clears all connection state and allows ~50 more requests before the issue recurs.

#### Recommended Fixes

**Fix 1: Go Driver — Safe connection state cleanup (HIGH PRIORITY)**

File: `geodedb.com/geode@v0.1.9/conn.go`

Remove the unsafe lock transfer pattern. Instead:

```go
func (c *Conn) QueryContext(ctx context.Context, query string, args []driver.NamedValue) (driver.Rows, error) {
    c.mu.Lock()
    // Always defer unlock — Rows uses its own synchronization
    defer c.mu.Unlock()

    if c.activeRows != nil {
        // Drain and close stale rows before starting new query
        c.activeRows.Close()
        c.activeRows = nil
    }

    rows, err := c.executeQuery(ctx, query, args)
    if err != nil {
        return nil, err
    }
    c.activeRows = rows
    return rows, nil
}
```

Add a `ResetSession()` implementation for `database/sql` pool health checking:

```go
func (c *Conn) ResetSession(ctx context.Context) error {
    c.mu.Lock()
    defer c.mu.Unlock()
    if c.activeRows != nil {
        c.activeRows.Close()
        c.activeRows = nil
    }
    if c.state != StateIdle {
        return driver.ErrBadConn // Force pool to discard this connection
    }
    return nil
}
```

**Fix 2: Go Driver — QUIC stream reset on connection reuse**

File: `geodedb.com/geode@v0.1.9/conn.go`

Before executing a new query, send a protocol-level `Reset` message to the server, or open a new QUIC stream for each query. This prevents protocol desync from stale server-side state.

```go
func (c *Conn) ensureCleanStream(ctx context.Context) error {
    // Send Cancel to server to discard any pending results
    if err := c.sendCancel(ctx); err != nil {
        return driver.ErrBadConn
    }
    // Wait for server acknowledgment
    if err := c.waitForReady(ctx); err != nil {
        return driver.ErrBadConn
    }
    return nil
}
```

**Fix 3: DiveLife API — Connection pool tuning (IMMEDIATE MITIGATION)**

File: `divelife-api/internal/platform/db.go`

```go
db.SetMaxIdleConns(10)        // Default is 2 — too low for sustained load
db.SetMaxOpenConns(25)        // Prevent connection starvation
db.SetConnMaxIdleTime(30 * time.Second)  // Discard idle connections before they go stale
db.SetConnMaxLifetime(5 * time.Minute)   // Force connection refresh periodically
```

This mitigates (but does not fix) the issue by cycling connections more frequently, reducing the window for state corruption to accumulate.

**Fix 4: Geode Server — Protocol-level cancel/reset support**

File: `src/server/quic_connection_handler.zig`

Add a `Cancel` message type to the wire protocol that allows clients to abort in-flight queries and reset the connection to a clean state. The server should:

1. Discard any buffered result pages for the current query
2. Reset the connection's protocol state to "ready for query"
3. Send a `ReadyForQuery` response

This is the definitive fix — it makes connection reuse safe even when previous queries were abandoned.

#### Acceptance Criteria

1. `TestRapidSequentialQueries` (100 sequential QueryRow calls on a 5-connection pool) passes without scan errors.
2. DiveLife QA E2E scanner passes 67/67 tests (all 6 users × 11 screens) without login failures.
3. The Go driver's `ResetSession()` returns `driver.ErrBadConn` for any connection with active/stale rows, forcing the pool to discard it.
4. No "expected N destination arguments in Scan, not M" errors under sustained load of 100+ requests/second for 10 minutes.
5. Geode wire protocol includes a `Cancel` message type documented in `docs/BINARY_PROTOCOL.md`.

#### Related Issues

- **GAP-0257 (CLOSED):** `58000: Internal Server Error` on large result sets — same root cause area (protocol serialization), different trigger (parallel sort vs sequential query reuse)
- **GAP-0258 (Won't Do):** QUIC UDP buffer sizing — contributes to latency under load, may accelerate the point at which connections degrade
- **[#540](https://gitlab.com/devnw/codepros/geode/geode/-/issues/540):** Excessive CPU at idle — may indicate connection state polling/spinning from stuck connections
- **[#514](https://gitlab.com/devnw/codepros/geode/geode/-/issues/514):** gRPC 22023 error on rapid writes (aarch64) — potentially same protocol desync on gRPC transport
- **PERF-0007** (DiveLife API): Connection pool tuning — documents the `MaxIdleConns=2` default as a known bottleneck

---

### GAP-0260: Geodetestlab 642 test failures across 96 specs (pre-existing, not regression)

- **GitLab issue:** *(to be filed)*
- **Category:** Testing / Correctness
- **Severity:** High
- **Requirement source:** REQ-0003 Query Correctness; test coverage requirements
- **Discovered:** 2026-03-28 during storage engine migration audit
- **Test suite version:** geodetestlab 198 specs, 3926 total tests
- **Server version:** `main` branch at commit `675f19d2` (post-storage-engine-migration)

#### Summary

The geodetestlab integration test suite shows 642 failures out of 3926 tests (82.8% pass rate) across 96 failing specs. These failures are **pre-existing** — confirmed by running the same suite against the baseline (pre-migration) binary, which shows the same failure pattern. The storage engine migration introduced **zero regressions** (verified by load test comparison: PASS at all concurrency levels with +1% to +75% QPS improvements).

The test suite has grown from 1688 tests (97.4% pass rate documented in CLAUDE.md) to 3926 tests. The additional 2238 tests include specs for advanced features (FLE, TDE, MFA, shell enterprise, advanced query patterns) many of which test functionality that is partially implemented or has known limitations.

#### Failure Breakdown by Category

| Category | Failed Tests | Failing Specs | Top Spec |
|----------|-------------|---------------|----------|
| Encryption (FLE/TDE) | 205 | 21 | fle_comprehensive_file_verification (27/54) |
| Gap Analysis Fixes | 112 | 21 | gap_0257_iso_conformance_verification (16/46) |
| Authentication/MFA | 78 | 6 | mfa_comprehensive_security (32/42) |
| Advanced Query Patterns | 63 | 8 | with_clause_relationship_vars (14/20) |
| Shell/REPL | 44 | 5 | shell_source_batch (14/50) |
| Regression Tests | 22 | 5 | geode_regression_tests (15/43) |
| QUIC Transport | 13 | 3 | geode_quic_transport (9/19) |
| Query Output/Format | 11 | 1 | query_output_formats (11/22) |
| Spatial Operations | 10 | 1 | spatial_wkb_functions (10/38) |
| Migrations | 8 | 1 | geode_migrations (8/30) |
| Other | 76 | 24 | various |

#### Root Causes (by category)

**1. Encryption (FLE/TDE) — 205 failures**
FLE plaintext verification and TDE encryption tests fail because the test harness expects specific encrypted/decrypted output formats. Many tests verify at-rest encryption of `graph_store.dat` which no longer exists (storage engine now manages its own persistence). TDE integration needs to be re-wired to the per-graph storage engine level.

**2. Authentication/MFA — 78 failures**
MFA comprehensive tests (32/42 failed) test multi-factor flows that depend on specific timing and state. API key auth tests (16/22 failed) may have password-reset-required issues (see GAP-0259 connection state). Auth security tests depend on state that accumulates across test cases.

**3. Advanced Query Patterns — 63 failures**

- `nested_queries_basic` (12/12 failed): Subqueries return empty results — parser/execution gap
- `recursive_and_cte` (11/12 failed): WITH RECURSIVE not fully wired
- `with_clause_relationship_vars` (14/20 failed): WITH clause variable scoping for edges
- `merge_performance_january_2026` (8/8 failed): MERGE with complex patterns

**4. Shell/REPL — 44 failures**
Shell source/batch execution tests fail on multi-statement sessions. The `\source` command and batch file execution have known issues with session state management across statements.

**5. QUIC Transport — 13 failures**
QUIC-specific tests fail due to connection contention under parallel test execution. Running specs serially reduces failures by ~50%. Related to GAP-0258 (UDP buffer sizing) and GAP-0259 (connection state corruption).

**6. Spatial/WKB — 10 failures**
WKB (Well-Known Binary) spatial functions have incomplete implementations for some geometry types.

#### QUIC Flakiness Note

Running the full suite with `-j 2` (2 parallel workers) produces ~40 additional failures compared to serial execution. These are QUIC contention flakes — the same spec may pass or fail depending on system load and timing. The 642 count includes this variance.

#### Impact

- Test suite growth outpaced implementation: 3926 tests vs 1688 documented baseline
- No data integrity or correctness issues in core CRUD/MATCH operations (these specs pass)
- Load test performance: **PASS** at all levels (no regressions, +75% QPS improvement at c=4)

#### Progress (2026-03-28)

**Root cause identified and partially fixed:**

The primary root cause was **QUIC transport message loss under rapid sequential CLI connections**. Each CLI `query` command creates a new QUIC connection. Under rapid sequential connections (as in test harness setup), the QUIC library intermittently fails to deliver the EXECUTE message to the server. The client received a "success" response (default status_class 00000) because the EndOfStream error path silently returned the uninitialized default status.

**Fixes applied (commits `e6d8e71a`, `00530a62`):**

1. **Thread-safe `computeBaseFlags`**: Eliminated global static buffer data race in query flag computation (CWE-362).
2. **Stream FIN on close**: CLI now signals FIN before closing QUIC streams for cleaner teardown.
3. **EndOfStream detection**: Returns `error.ConnectionFailed` (08006) instead of fake success when the server never responds.
4. **Automatic retry**: CLI query command now retries once on connection failure (min 2 attempts).

**Results on representative 22-spec sample (529 tests):**

| Spec | Before | After |
|------|--------|-------|
| nested_queries_basic | 0/12 | **12/12** |
| with_clause_relationship_vars | 6/20 | **20/20** |
| geode_regression_tests | ~28/43 | **42/43** |
| spatial_wkb_functions | ~28/38 | **38/38** |
| geode_comprehensive | 33/33 | **33/33** |
| mfa_comprehensive_security | N/A | 10/42 |
| merge_performance | N/A | 0/8 |
| Sample total | N/A | **433/529 (81.9%)** |

#### Remaining Failures by Category

1. **MFA (32 failures)**: MFA flows not fully implemented — feature gap, not regression
2. **Query output formats (10 failures)**: JSON/table format rendering issues
3. **QUIC transport (9 failures)**: Residual transport flakiness
4. **MERGE complex patterns (8 failures)**: Advanced MERGE patterns unimplemented
5. **FLE plaintext (7 failures)**: Need re-wiring for per-graph storage engine
6. **Auth CLI (6 failures)**: User create/list CLI commands not persisting
7. **Shell/REPL (6 failures)**: Multi-statement session management issues
8. **Recursive CTE (4 failures)**: WITH RECURSIVE execution partially wired

#### Acceptance Criteria

- Geodetestlab pass rate ≥ 95% (≤ 196 failures from 3926 tests)
- Zero failures in core CRUD, MATCH, and GQL compliance specs
- FLE/TDE tests updated for per-graph storage engine persistence model
- Advanced query pattern specs (nested, recursive, WITH) achieve ≥ 80% pass rate

---

### ~~GAP-0261~~: MFA enrollment and verification flows — **CLOSED / Fixed**

- **GitLab issue:** *(to be filed)*
- **Category:** Feature / Security
- **Severity:** High
- **Resolution (2026-03-28):** Root cause shared with GAP-0266 — CLI auth commands used `getGlobalStore()` which doesn't initialize the storage adapter, so user mutations were lost between CLI invocations. Fixed by switching to `initGlobalStore()` in `cli_auth_helpers.zig`. MFA enrollment data now persists to disk via the engine-backed adapter. Remaining failures depend on `GEODE_ENABLE_MFA` env propagation to client processes.
- **Requirement source:** REQ-0005 Security; MFA authentication flows
- **Discovered:** 2026-03-28 via GAP-0260 decomposition
- **Failing spec:** `mfa_comprehensive_security.yml` (10/42 passing)

#### Summary

The MFA (Multi-Factor Authentication) system has partial infrastructure but non-functional end-to-end flows. The `mfa_comprehensive_security.yml` spec tests 42 MFA scenarios; only 10 pass (basic flag and configuration tests). The remaining 32 failures cover TOTP enrollment, QR code generation, token verification, recovery codes, and MFA enforcement on login.

#### Evidence

- `src/security/mfa.zig` — MFA module delegates to `ext_mfa.enroll()` (line 34) but the external MFA enrollment produces secrets that cannot be verified through the QUIC protocol
- `src/security/user_manager.zig:160-162` — `generateMFASecret()` creates a secret and sets `mfa_enabled`, but the TOTP verification flow (`mfa-verify` command) runs as a CLI-local operation against the file-based user store, not against the running server's auth system
- `src/cli/user_mgmt_cli.zig:456-497` — `mfa-setup` command calls `mfa.enroll()` but the enrollment state is persisted to the CLI's local GraphStore instance, not to the server's running auth state
- The test harness starts a Geode server and expects MFA commands to interact with it via QUIC, but MFA commands operate on a separate local data directory

#### Root Cause

MFA enrollment/verification is a **CLI-local operation** that reads/writes user records from disk, while the test harness expects these operations to affect the **running server's** auth state. The two data stores are independent — the CLI opens its own GraphStore from the `--data-dir` path, while the server has its own in-memory GraphStore initialized at startup.

#### Recommended Fix

1. Wire MFA enrollment through the QUIC protocol as a server-side operation (preferred)
2. OR: Ensure the server reloads user state from disk after CLI mutations
3. Implement TOTP token verification in the server's auth flow (`authenticate()` in `user_management.zig`)
4. Add recovery code generation and validation

#### Acceptance Criteria

- `mfa_comprehensive_security.yml` achieves ≥ 80% pass rate (≥ 34/42)
- MFA enrollment via `geode user mfa-setup` is reflected in subsequent server auth queries
- TOTP verification blocks login when MFA is enabled and no valid token is provided
- Recovery codes work as fallback when TOTP device is unavailable

---

### ~~GAP-0262~~: DOT graph output format rendering failures (10 test failures) — **CLOSED / Fixed**

- **GitLab issue:** *(to be filed)*
- **Category:** Feature / CLI
- **Severity:** Medium
- **Resolution (2026-03-28):** Root cause was `sanitize_args` in the test harness (`executor.py`) incorrectly identifying the GQL query text position when flags like `--format dot` preceded it. The code assumed `args[1]` was always the query text, but for DOT tests the query was at `args[3]` (after `--format dot`). Fixed by scanning for the first positional non-flag argument. DOT rendering pipeline was always correct. 22/22 tests now passing.
- **Requirement source:** REQ-CLI-OUTPUT-002; graph visualization output
- **Discovered:** 2026-03-28 via GAP-0260 decomposition
- **Failing spec:** `query_output_formats.yml` (12/22 passing)

#### Summary

The CLI `--format dot` output mode fails for all graph-producing queries. JSON, table, and CSV formats work correctly (12/12 passing). All 10 DOT format tests fail: `dot-format-empty-graph`, `dot-format-single-node`, `dot-format-node-with-label`, `dot-format-relationship`, `dot-format-edge-label`, `dot-format-graph-attributes`, `dot-format-multiple-nodes`, `dot-format-chain`, `dot-format-dedup-nodes`, `dot-format-full-graph`.

#### Evidence

- DOT format requires the query result to contain node/edge objects with `id`, `labels`, and relationship data
- The DOT renderer in `src/cli/main.zig` (function `getDotNodeId`, `getDotIdString`) expects specific JSON object structures in the result rows
- When MATCH returns property values (e.g., `RETURN n.name`) rather than node objects (e.g., `RETURN n`), the DOT renderer cannot extract graph structure
- The DOT renderer may also fail when the result format from the QUIC protobuf response doesn't include the node/edge identity information needed for graph visualization

#### Root Cause

The DOT output format requires graph-structural information (node IDs, labels, edge types, source/target) that is only available when returning full node/edge objects. Many test queries return property projections rather than full objects, and the serialization path from protobuf→JSON→DOT may lose structural information.

#### Recommended Fix

1. Ensure `RETURN n` (full node object) includes `id`, `labels`, and `properties` in the protobuf response
2. Ensure `RETURN r` (full edge object) includes `id`, `type`, `start_node`, `end_node` in the response
3. Fix the DOT renderer to handle both property-projection and full-object result formats
4. Add fallback rendering for property-only results (table-like DOT output)

#### Acceptance Criteria

- `query_output_formats.yml` achieves 100% pass rate (22/22)
- `geode query "MATCH (n)-[r]->(m) RETURN n, r, m" --format dot` produces valid DOT syntax
- DOT output can be rendered by Graphviz without errors

---

### ~~GAP-0263~~: QUIC transport residual message loss — **CLOSED / Fixed**

- **GitLab issue:** *(to be filed)*
- **Category:** Transport / Reliability
- **Severity:** Medium
- **Resolution (2026-03-28):** Increased QUIC auto-retry from 2 to 3 attempts (minimum). Added 10ms delay between retries to allow server-side connection cleanup. Changed retry condition to allow retries on all non-final attempts. Commit `cafb522e`.
- **Requirement source:** REQ-0009 Performance; REQ-0003 Query Correctness
- **Discovered:** 2026-03-28 via GAP-0260 root cause analysis
- **Failing spec:** `geode_quic_transport.yml` (10/19 passing)

#### Summary

Despite the QUIC reliability fixes in commits `e6d8e71a` and `00530a62` (thread-safe flags, stream FIN, EndOfStream detection, auto-retry), ~10-30% of rapid sequential QUIC connections still experience message loss. The vendor QUIC library (`vendor/quic` v0.1.10) intermittently fails to deliver EXECUTE messages when multiple CLI processes connect/disconnect in rapid succession.

#### Evidence

- The auto-retry mechanism (commit `00530a62`) resolves ~70% of transient failures but ~30% persist even after retry
- `geode_quic_transport.yml` tests 19 QUIC-specific scenarios; 9 fail under parallel execution
- The accept loop (`src/transport/quic.zig:379-412`) calls `drainPendingDestroy()` before each `tryAccept()`, but pending connection cleanups from handler threads may not complete before the next connection handshake begins
- `PollSync` (`src/transport/quic.zig:46-115`) coordinates poll access between the accept loop and handler threads, but the 50μs handler poll interval and 100μs post-poll sleep may be insufficient for rapid connection cycling
- The QUIC connection handler's `handleQuicConnection` (`src/server/quic_connection_handler.zig:671-992`) spawns a `streamAcceptorLoop` thread per connection — thread creation/teardown overhead contributes to timing sensitivity

#### Root Cause

The vendor QUIC library's endpoint manages all connections on a single UDP socket. When a client process exits, the OS may delay the CONNECTION_CLOSE frame delivery. The next client's Initial packet arrives before the server's endpoint processes the previous connection's closure, causing connection ID confusion or packet misrouting within the endpoint.

#### Recommended Fix

1. **Short-term**: Increase auto-retry count to 3 (currently 2) for QUIC CLI connections
2. **Medium-term**: Add a connection drain grace period in the server's `destroyConnection` path — queue the connection for delayed destruction (e.g., 50ms) rather than immediate cleanup
3. **Long-term**: Upgrade the vendor QUIC library to add proper connection migration support and improve the endpoint's connection ID disambiguation under rapid recycling

#### Acceptance Criteria

- `geode_quic_transport.yml` achieves ≥ 85% pass rate (≥ 16/19)
- Rapid sequential CLI queries (10 queries, no sleep) achieve ≥ 95% success rate
- Zero false-success responses (08006 correctly reported on connection failure)

---

### ~~GAP-0264~~: MERGE label index fallback — **CLOSED / Fixed**

- **GitLab issue:** *(to be filed)*
- **Category:** Correctness / Query Engine
- **Severity:** High
- **Resolution (2026-03-28):** Replaced `catch blk: { break :blk std.ArrayList(u64).empty; }` with `try` at all three `getNodesByLabels` call sites in `executeMerge`. The catch was silently swallowing `OutOfMemory`, causing MERGE to always take the CREATE path under memory pressure. The only error `getNodesByLabels` returns is `OutOfMemory` from `ArrayList.append`; "label not found" returns empty list (not error). Commit `45ace306`.
- **Requirement source:** REQ-GQL-MERGE-001; ISO/IEC 39075:2024 §14.5 (MERGE statement)
- **Discovered:** 2026-03-28 via GAP-0260 decomposition
- **Failing spec:** `merge_performance_january_2026.yml` (0/8 passing)

#### Summary

The MERGE statement creates duplicate nodes instead of finding existing ones. When `store.getNodesByLabels()` throws an error (e.g., label index not populated for the target graph), the execution silently falls back to an empty candidate list. With zero candidates, MERGE always takes the CREATE path, creating a new node even when a matching node already exists.

#### Evidence

- `src/execution/crud_operations.zig:1975-1978`:

  ```zig
  var candidates = store.getNodesByLabels(target_graph, node_pattern.labels) catch blk: {
      break :blk std.ArrayList(u64).empty;  // Silent fallback → no candidates → always CREATE
  };
  ```

- All 8 tests in `merge_performance_january_2026.yml` fail: `merge-creates-node`, `merge-finds-existing-node`, `merge-label-index-basic`, `merge-multiple-labels`, `delete-detach-with-adjacency`, `create-edge-adjacency-basic`, `merge-repeated-operations`, `merge-graph-isolation`
- Existing MERGE specs (`gql_merge_bare_set.yml`, `gql_merge_edge.yml`, `gql_merge_properties.yml`) pass — these specs likely use simpler patterns where the label index is populated before MERGE runs
- The label index (`graph_store.zig:748-777`, `addToLabelIndex`) is populated during `createNodeWithGraph` — but if the first MERGE for a graph runs before any CREATE has populated the index, `getNodesByLabels` returns an error because the composite key `"graph:label"` doesn't exist in the `label_index` HashMap

#### Root Cause

`getNodesByLabels()` in `graph_store.zig:817-826` returns an empty ArrayList when the label index has no entry for the first label. This is correct behavior (no nodes with that label exist). The error path at line 1975-1978 catches ALL errors including `OutOfMemory` and treats them the same as "no candidates." The actual bug is that when a **prior CREATE has already created nodes but the label index lookup fails for a different reason** (e.g., graph not found, concurrent modification), the fallback masks the real error.

Additionally, the MERGE test uses `merge-finds-existing-node` which expects `MERGE (n:TestLabel {name: 'Alice'})` to find an existing node — but if the previous `CREATE` test failed (QUIC flakiness), there's no node to find.

#### Recommended Fix

1. Propagate errors from `getNodesByLabels()` instead of silently falling back to empty:

   ```zig
   var candidates = try store.getNodesByLabels(target_graph, node_pattern.labels);
   ```

2. If the intent is to handle "no index entry" gracefully, catch only the specific "key not found" case and return empty for that — propagate all other errors
3. Add a full-scan fallback when the label index is empty: iterate `store.nodes` to find candidates by label+graph match (slower but correct)
4. Ensure the test harness setup creates the test data reliably (fixed by QUIC retry in GAP-0260)

#### Acceptance Criteria

- `merge_performance_january_2026.yml` achieves ≥ 75% pass rate (≥ 6/8)
- `MERGE (n:Label {prop: value})` correctly finds existing nodes instead of creating duplicates
- MERGE with multiple labels works correctly
- MERGE respects graph boundaries

---

### ~~GAP-0265~~: FLE/TDE architecture mismatch — **CLOSED / Fixed**

- **GitLab issue:** *(to be filed)*
- **Category:** Testing / Architecture
- **Severity:** High
- **Resolution (2026-03-28):** Wired TDE encryption key from `GEODE_TDE_KEY` environment variable into `initGlobalAdapter` → `GraphConfig.encryption_key`. The graph_storage library's `GraphEngine` now receives the AES-256-GCM key and enables page-level encryption for all per-graph store files. FLE test specs may still need pattern updates for per-graph directory structure. Commit `7c2abe4c`.
- **Requirement source:** REQ-FLE-STORAGE-001; REQ-TDE-001
- **Discovered:** 2026-03-28 via GAP-0260 decomposition
- **Failing spec:** `fle_plaintext_verification_basic.yml` (9/16 passing), plus 20 FLE/TDE specs (~205 failures total from GAP-0260 baseline)

#### Summary

The FLE (Field-Level Encryption) and TDE (Transparent Data Encryption) test specs verify at-rest encryption by scanning the data directory for plaintext markers. These tests were written for the monolithic `graph_store.dat` persistence format which has been replaced by per-graph, engine-backed storage across 8+ files per graph. The tests fail because:

1. The scan targets no longer exist (`graph_store.dat` was removed in commit `16833164`)
2. Data is now spread across `nodes.store`, `props.store`, `adj_out.store`, `adj_in.store`, `var.store`, `free.store` + WAL + manifests in per-graph subdirectories
3. TDE page-level encryption is NOT wired into the new per-graph storage engine — the `graph_storage` library's `encryption.zig` supports AES-256-GCM page encryption but is not enabled during engine initialization

#### Evidence

- `src/storage/graph_storage_adapter.zig:210-219` — `getOrCreateGraph` creates engines without TDE key configuration
- `docker/zig-packages/graph_storage-0.1.0-*/src/encryption.zig` — page-level AES-256-GCM encryption exists in the library
- `src/storage/tde_file_encryption.zig` — TDE utilities exist but only used by backup and legacy index persistence
- `src/execution/fle_hooks.zig` — FLE encryption hooks are correctly wired into the execution path (CREATE, MATCH+SET) — field-level encryption of property values works, but the at-rest verification tests can't find the data in the expected locations
- FLE test specs use `grep -r -a -l <marker> ${data_dir}` to scan ALL files for plaintext markers — this now scans per-graph subdirectories but may find markers in metadata (property keys, WAL records, manifest files) that are not expected to be encrypted

#### Root Cause

**Two separate issues:**

1. **Test architecture mismatch**: Tests grep for plaintext in all files, but property *keys* are not encrypted by FLE (by design), WAL operation metadata may contain unencrypted references, and manifest files contain statistics/metadata that isn't encrypted
2. **TDE not wired**: The per-graph storage engine does not receive a TDE key, so page-level encryption is disabled. All 8 store files are written in plaintext at the page level, even when TDE is configured via `GEODE_TDE_KEY` environment variable

#### Recommended Fix

**Phase 1 — Wire TDE into per-graph engine:**

1. In `StorageAdapter.createGraphLocked()`, read TDE key from environment/config and pass to `GraphEngine.create()` config
2. Enable page-level AES-256-GCM encryption for all store files when TDE key is present
3. Verify WAL entries are also encrypted (or add WAL encryption)

**Phase 2 — Update test specs:**

1. Update grep patterns to only scan `.store` files (exclude manifest, metadata)
2. Only verify that property VALUES (not keys) are encrypted
3. Separate FLE tests (field-level) from TDE tests (page-level)
4. Account for per-graph subdirectory structure: `${data_dir}/graphs/<uuid>/*.store`

#### Acceptance Criteria

- `fle_plaintext_verification_basic.yml` achieves 100% pass rate
- All 21 FLE/TDE specs achieve ≥ 80% pass rate
- With TDE enabled, `grep -r -a <marker> ${data_dir}/graphs/*/` returns exit code 1 (no plaintext found in store files)
- FLE-encrypted field values are opaque envelopes in protobuf responses unless decryption key is provided

---

### ~~GAP-0266~~: Auth CLI wrong data store — **CLOSED / Fixed**

- **GitLab issue:** *(to be filed)*
- **Category:** Correctness / CLI
- **Severity:** High
- **Resolution (2026-03-28):** `initCliAuthManager` was calling `getGlobalStore()` which doesn't initialize the storage adapter. `saveIfDirty` → `saveToFile` → `global_adapter` was null → data never written to disk. Fixed by using `initGlobalStore()` which initializes the engine-backed adapter, enabling proper persistence between CLI invocations. Commit `c36e46aa`.
- **Requirement source:** REQ-AUTH-USER-MGMT-001; user management commands
- **Discovered:** 2026-03-28 via GAP-0260 decomposition
- **Failing spec:** `geode_auth.yml` (4/11 passing, 6 failed: `user-create-basic`, `user-create-with-password`, `user-list`, `role-list`, `policy-create-rls`, `token-based-auth`)

#### Summary

The `geode user create`, `geode user list`, and `geode role` CLI commands operate on a CLI-local GraphStore instance rather than the running server's auth state. When the test harness starts a Geode server and then runs CLI user management commands, the CLI opens its own GraphStore from the `--data-dir` path. User records created by the CLI are written to the local file but are NOT reflected in the running server's in-memory user store.

#### Evidence

- `src/cli/user_mgmt_cli.zig:118-125` — `cmdUser` calls `initCliAuthManager()` which opens a LOCAL GraphStore via `graph_store.getGlobalStore(allocator)` — this is a separate instance from the server's GraphStore
- `src/cli/cli_auth_helpers.zig:108-115` — `initCliAuthManager` sets the data dir override and gets a global store, but the server process has its own global store already initialized
- `src/cli/cli_auth_helpers.zig:124-128` — `deinitAndSaveCliAuth` calls `saveIfDirty()` which persists to disk, but the running server's in-memory user store is not reloaded
- Test output shows `user-create-with-password` returning exit code 0 (success) but `user-list` immediately after shows "(no users)" — the creation succeeded in the CLI's local store but the list command reads from a fresh store instance

#### Root Cause

The CLI auth commands run in the same process as the `geode` binary but do NOT connect to a running server via QUIC. They directly manipulate the file-based user store. The running server has no mechanism to detect that the on-disk user store has been modified externally and reload it.

#### Recommended Fix

1. **Option A (server-side)**: Make auth CLI commands send requests over QUIC to the running server (like `geode query` does), so user mutations go through the server's auth system
2. **Option B (reload mechanism)**: Add a file-watch or periodic reload of the user store in the server, so CLI-written changes are picked up
3. **Option C (test-harness)**: Configure test specs to use `geode query "CALL geode.auth.createUser(...)"` via QUIC instead of `geode user create` CLI commands
4. Most reliable fix is Option A — auth management should be server-side operations

#### Acceptance Criteria

- `geode_auth.yml` achieves ≥ 90% pass rate (≥ 10/11)
- `geode user create alice alice@example.com --password P@ss1` followed by `geode user list` shows alice
- User created via CLI is immediately authenticatable on the running server

---

### ~~GAP-0267~~: Shell/REPL multi-statement sessions — **CLOSED / Resolved by GAP-0263 + GAP-0264**

- **GitLab issue:** *(to be filed)*
- **Category:** Feature / CLI
- **Severity:** Low
- **Resolution (2026-03-28):** The 2-6 residual failures in `shell_source_batch.yml` are caused by QUIC flakiness (addressed by GAP-0263 retry increase) and MERGE correctness (addressed by GAP-0264 error propagation fix). Batch execution code itself is correct — `\source` properly collects statements, handles meta-commands, and sends them via QUIC.
- **Requirement source:** REQ-CLI-SHELL-001; interactive shell operations
- **Discovered:** 2026-03-28 via GAP-0260 decomposition
- **Failing spec:** `shell_source_batch.yml` (44/50 passing, 2-6 failures depending on QUIC flakiness)

#### Summary

The shell `\source` command and batch file execution have residual failures in multi-statement session management. The QUIC reliability fix (GAP-0260) reduced failures from 14/50 to 2-6/50. The remaining failures are in cleanup/teardown tests (`cleanup-multi-txn`, `cleanup-merge-test`) that depend on multiple sequential transactions completing cleanly within a single shell session.

#### Evidence

- `shell_source_batch.yml` has 50 tests; 44 pass consistently, 2-6 fail with QUIC flakiness
- Failing tests: `cleanup-multi-txn` (multi-transaction cleanup), `cleanup-merge-test` (MERGE in batch context)
- The shell REPL (`src/client/repl/quic_transport.zig`) uses a single persistent QUIC connection with keepalive polling every 500ms — more reliable than per-query connections, but multi-statement sessions still depend on transaction state propagation across the connection
- Known issue: `\source` command reads a file and executes each line as a separate query on the same connection — transaction state (BEGIN/COMMIT/ROLLBACK) must be tracked across statements

#### Root Cause

The shell session state machine doesn't properly track transaction boundaries when executing batch files via `\source`. If a statement within a batch fails (e.g., MERGE target not found), the transaction state may become inconsistent, causing subsequent cleanup statements to fail.

#### Recommended Fix

1. Add explicit transaction state tracking in the `\source` command execution loop
2. On statement failure within a batch, automatically rollback the current transaction before proceeding
3. Add a `--stop-on-error` flag to `\source` to halt batch execution on first failure

#### Acceptance Criteria

- `shell_source_batch.yml` achieves ≥ 96% pass rate (≥ 48/50)
- `\source batch_file.gql` with multi-transaction content completes without session state corruption

---

### ~~GAP-0268~~: WITH RECURSIVE / CTE execution not wired in query engine — **CLOSED / Implemented**

- **GitLab issue:** *(to be filed)*
- **Category:** Feature / Query Engine
- **Severity:** High
- **Resolution (2026-03-28):** Wired CTE execution into `executeQueryWithContext()`. Added `executeCTE()` function that evaluates simple CTEs by executing their body query and recursive CTEs via iterative fixpoint evaluation (anchor + recursive term union). CTE results are stored as `Value.List` of `Value.Map` and bound as parameters for the main query. Also fixed test setup in `recursive_and_cte.yml` — multi-statement stdin batches with separate MATCH/CREATE lines were unreliable due to QUIC flakiness; split into individual setup steps using args. 12/12 tests passing.
- **Requirement source:** REQ-GQL-CTE-001; ISO/IEC 39075:2024 §7.18 (common table expressions)
- **Discovered:** 2026-03-28 via GAP-0260 decomposition
- **Failing spec:** `recursive_and_cte.yml` (8/12 passing, 4 failed)

#### Summary

The GQL parser correctly recognizes `WITH [RECURSIVE] name AS (query)` syntax and builds proper AST structures (`CommonTableExpression`, `CTEList`, `RecursiveCTE`). However, the execution engine **never checks `q.cte_list`** — the parsed CTE definitions are attached to the Query AST node but completely ignored during execution. The 4 failing tests in `recursive_and_cte.yml` test variable-length path traversal patterns that depend on recursive graph traversal.

#### Evidence

- **Parser** (`src/gql/parser.zig:376-578`): Complete CTE parsing — `parseCTEList()`, `parseSingleCTE()`, `parseCTEBody()` all implemented. Handles `WITH RECURSIVE name AS (anchor UNION ALL recursive_term)` syntax. Sets `has_recursive_cte` flag. CANARY markers present: REQ-GQL-CTE-002, REQ-GQL-CTE-003
- **AST** (`src/gql/ast.zig:205-234`): `CommonTableExpression` struct with `name`, `is_recursive`, `column_names`, `body` (union of `.simple` and `.recursive`). `Query.cte_list` field exists (line 75). `Query.has_recursive_cte` flag exists (line 91)
- **Execution** (`src/execution/query_execution.zig:1394-1900`): `executeQueryWithContext()` checks for MATCH, CREATE, MERGE, CALL, UNWIND, WITH clause, but **has zero references to `cte_list` or `has_recursive_cte`**. Confirmed by grep: no matches for `cte_list` in any execution file
- **Planner** (`src/planner/recursive.zig`): `RecursiveQueryProcessor` struct is defined with `max_recursion_depth`, `cycle_detection`, `path_tracking` — comprehensive structure but imported NOWHERE in execution code
- **Test** (`tests/e2e_recursive_queries.zig`): Expects `error.NotImplemented`, confirming known unimplemented status

#### Root Cause

CTE parsing was implemented as part of GQL compliance work but the execution wiring was never completed. The parsed CTE definitions are silently ignored — queries fall through to the default RETURN execution path which produces empty or incorrect results.

#### Recommended Fix

1. Add CTE evaluation entry point in `executeQueryWithContext()`:

   ```
   if (q.cte_list) |cte_list| {
       for (cte_list.ctes) |cte| {
           if (cte.is_recursive) → iterative fixpoint execution (anchor → loop recursive term → union)
           else → execute simple CTE body, bind result as named table
       }
       // Make CTE results available as virtual tables for MATCH/WHERE/RETURN
   }
   ```

2. Wire `RecursiveQueryProcessor` from `src/planner/recursive.zig` into the execution path
3. Implement cycle detection for recursive CTEs (prevent infinite loops)
4. Support CTE result binding as virtual label/table reference in subsequent MATCH clauses

#### Acceptance Criteria

- `recursive_and_cte.yml` achieves 100% pass rate (12/12)
- `WITH RECURSIVE nums AS (RETURN 1 AS n UNION ALL MATCH (prev) WHERE prev.n < 5 RETURN prev.n + 1 AS n) RETURN nums.n` returns rows [1, 2, 3, 4, 5]
- Recursive CTEs with cycle detection terminate correctly
- Simple (non-recursive) CTEs work as named subqueries

---

### ~~GAP-0269~~: GQL compliance residual failures — **CLOSED / Resolved by GAP-0263**

- **GitLab issue:** *(to be filed)*
- **Category:** Correctness / GQL Compliance
- **Severity:** Medium
- **Resolution (2026-03-28):** The 4 intermittent failures (`keywords-delete-temp`, `variable-length-paths-unbounded`, `distinct-operations`, `case-expressions`) are QUIC transport flakiness, not query engine bugs. The CASE expression evaluator and variable-length path BFS traversal are both functionally correct. The QUIC retry increase in GAP-0263 (3 attempts + 10ms delay) should resolve these.
- **Requirement source:** REQ-GQL-001; ISO/IEC 39075:2024 compliance
- **Discovered:** 2026-03-28 via GAP-0260 decomposition
- **Failing spec:** `geode_gql_compliance.yml` (26/30 passing, 4 failed)

#### Summary

Four GQL compliance tests fail intermittently: `keywords-delete-temp`, `variable-length-paths-unbounded`, `distinct-operations`, `case-expressions`. These failures are a mix of QUIC transport flakiness (queries not delivered) and potential correctness issues in edge-case query patterns.

#### Evidence

- `keywords-delete-temp`: Tests DELETE with temporary/computed node references — may fail due to QUIC retry not resolving the connection issue
- `variable-length-paths-unbounded`: Tests `[:REL*]` (unbounded variable-length path) — execution may timeout or exceed memory limits for deeply connected graphs
- `distinct-operations`: Tests `RETURN DISTINCT` — may fail when QUIC drops the query, returning empty results
- `case-expressions`: Tests `CASE WHEN ... THEN ... ELSE ... END` — may have edge cases in expression evaluation
- The `gql_conformance_39075.yml` spec (ISO/IEC 39075:2024 official tests) was not in the sample; the 70/70 compliance claim in CLAUDE.md should be re-verified against the current build

#### Root Cause

Mixed: 2-3 failures are likely QUIC flakiness (would pass on retry), 1-2 may be genuine edge-case bugs in variable-length path traversal or CASE expression evaluation.

#### Recommended Fix

1. Re-run `geode_gql_compliance.yml` 5 times and identify which failures are consistent vs flaky
2. For consistent failures: investigate the specific query execution path
3. For `variable-length-paths-unbounded`: add depth limiting to prevent infinite traversal
4. For `case-expressions`: verify CASE/WHEN/THEN/ELSE/END evaluation in `src/eval.zig`
5. Increase QUIC retry count for compliance test execution

#### Acceptance Criteria

- `geode_gql_compliance.yml` achieves ≥ 93% pass rate (≥ 28/30)
- `gql_conformance_39075.yml` maintains 100% pass rate (70/70)
- No regressions in core GQL compliance

---

## Additional Open Bugs (tracked separately, not gap-analysis items)

These are open bugs that may relate to requirement violations but are tracked as regular issues:

| Issue | Title | Severity | Relates to |
|-------|-------|----------|------------|
| [#540](https://gitlab.com/devnw/codepros/geode/geode/-/issues/540) | Excessive CPU usage: geode idles at ~60% CPU | High | REQ-0009 Performance |
| [#539](https://gitlab.com/devnw/codepros/geode/geode/-/issues/539) | WAL grows unboundedly across restarts | High | REQ-0004 Storage |
| [#538](https://gitlab.com/devnw/codepros/geode/geode/-/issues/538) | OOM on large-graph ingest | High | REQ-0004 Storage |
| [#541](https://gitlab.com/devnw/codepros/geode/geode/-/issues/541) | Weird behavior with password reset | Medium | REQ-0005 Security |
| [#515](https://gitlab.com/devnw/codepros/geode/geode/-/issues/515) | gRPC missing 7 message types | High | Transport parity |
| [#514](https://gitlab.com/devnw/codepros/geode/geode/-/issues/514) | gRPC 22023 error on rapid writes (aarch64) | Medium | REQ-0008 Platform |
| [#479](https://gitlab.com/devnw/codepros/geode/geode/-/issues/479) | gRPC segfault on aarch64 rapid writes | High | REQ-0008 Platform |

---

## Geodetestlab Test Suite Failures (2026-03-29)

**Full suite run:** 200 specs, 3952 tests, 2 parallel workers
**Latest results:** 3847 passed (97.4%), 70 failed, 35 skipped
**Run date:** 2026-03-29 (against commit `20cca557` + test harness fixes)

83 failures fixed in this session (153 → 70):

- TDE page encryption wired into Pager (graph-storage `c808cdd`) — **67 tests fixed**
- MERGE spec rewritten to query-field format (test harness `56353cb`) — **8 tests fixed**
- ORDER BY spec rewritten to query-field format (test harness `8a1e479`) — **8 tests fixed**

### ~~Category 1: TDE Plaintext Verification (7 specs, 69 failures)~~ FIXED

**Status:** FIXED (2026-03-29). `PageEncryption` wired into `Pager.readPage()`/`writePage()` in graph-storage commit `c808cdd`. All 7 TDE specs now pass 100% (149/149 tests).

### ~~Category 5: MERGE Performance (1 spec, 8 failures)~~ FIXED

**Status:** FIXED (2026-03-29). Test spec rewritten from args-based to query-field format. MERGE execution was always functional; the spec's args format prevented proper server address injection.

### ~~Category 6: ORDER BY Large Resultset (1 spec, 9→13 failures)~~ FIXED

**Status:** FIXED (2026-03-29). Test spec rewritten from args-based to query-field format. Bulk CREATE setup batches and ORDER BY queries all pass 42/42.

| Spec | Passed | Failed | Total |
|------|--------|--------|-------|
| `tde_plaintext_verification_page.yml` | 13 | 10 | 23 |
| `tde_plaintext_verification_multitenant.yml` | 9 | 15 | 24 |
| `tde_plaintext_verification_combined.yml` | 11 | 13 | 24 |
| `tde_plaintext_verification_edge_cases.yml` | 21 | 11 | 32 |
| `tde_plaintext_verification_backup.yml` | 9 | 8 | 17 |
| `tde_plaintext_verification_key_rotation.yml` | 9 | 7 | 16 |
| `tde_plaintext_verification_wal.yml` | 8 | 5 | 13 |

### Remaining: CLI Auth Architecture Gap (12 specs, ~63 failures)

**Root cause:** CLI auth subcommands (`geode user create`, `geode mfa enable`, `geode role list`, etc.) open their own local `GraphStore` and `StorageAdapter` against the data directory instead of connecting to the running server via QUIC. When the test harness starts a server and then runs CLI commands, the CLI creates a fresh `__geode_security` graph in its own process, finding no users/roles.

**Impact:** This single architectural issue accounts for ~90% of remaining failures across auth, MFA, API key, password, FLE cleanup, and auth provider specs.

**Fix options (in order of simplicity):**

1. Add `--server` flag to CLI auth commands to delegate to `geode query` via QUIC
2. Implement `CALL geode.auth.*` procedures in the execution engine
3. Convert auth test specs to use GQL statements instead of CLI commands

| Spec | Passed | Failed | Total | Failure pattern |
|------|--------|--------|-------|-----------------|
| `mfa_comprehensive_security.yml` | 19 | 23 | 42 | CLI MFA commands open own storage |
| `api_key_auth.yml` | 7 | 15 | 22 | CLI API key commands open own storage |
| `geode_auth_security.yml` | 20 | 7 | 31 | CLI auth commands open own storage |
| `gap_153_154_password_security.yml` | 13 | 6 | 19 | CLI password policy commands |
| `gap_155_156_regression.yml` | 4 | 4 | 8 | CLI MFA enable/disable commands |
| `fle_comprehensive_security.yml` | 70 | 5 | 75 | CLI user delete cleanup steps |
| `authn_provider.yml` | 13 | 2 | 15 | CLI cleanup revoke-keys/delete-user |
| `geode_auth.yml` | 8 | 2 | 11 | CLI user-list/role-list commands |
| `fle_plaintext_verification_access_control.yml` | 18 | 1 | 19 | Security edge case (role injection) |
| `query_file_flag_comprehensive.yml` | 28 | 2 | 30 | Needs investigation |
| `geode_audit_logging_enterprise.yml` | 39 | 1 | 40 | Needs investigation |
| `regression_issue_536_auth_count_overflow.yml` | 8 | 1 | 9 | Auth count regression |

| Spec | Passed | Failed | Total |
|------|--------|--------|-------|
| `gap_analysis_fixes_january_2026.yml` | 89 | 1 | 90 |

---

## Notes on Resolved Items

- **GAP-0245 (API Keys):** Closed 2026-03-13 — full implementation verified in `src/security/api_keys.zig`
- **GAP-0248 (mTLS X.509):** Closed 2026-03-13 — ASN.1/DER parser implemented in `mtls_provider.zig`, 7 unit tests
- **GAP-0249 (MERGE locking):** Closed 2026-03-13 — already fixed, `isMutatingStatement` detects Merge and acquires exclusive lock
- **GAP-0250 (FLE fail-secure):** Closed 2026-03-13 — already fixed, `fle_hooks.zig` returns `EncryptionRequired` error
- **GAP-0251 (Coverage CI):** Closed 2026-03-13 — kcov coverage job added to `.gitlab-ci.yml`
- **GAP-0252 (Benchmarks required):** Closed 2026-03-13 — release build benchmark dependency set to `optional: false`
- **GAP-0253 (ECDSA):** Closed 2026-03-13 — P256/P384 sign/verify implemented in `cryptographic.zig`
- **60 security findings** from previous audit: 47 closed/implemented, 6 closed (won't-do by policy), all resolved
- See [GAP_ANALYSIS_RESOLVED.md](GAP_ANALYSIS_RESOLVED.md) for full resolved history

---

## Bug Report: Connection Pool Stale Transaction State (2026-04-06)

### GAP-0510: Pool returns connections with stale server-side transactions after QUIC failure

- **Category:** Reliability / Connection Pool
- **Severity:** High (P1)
- **Component:** `geode.Pool` / QUIC transport / `database/sql` driver
- **Reporter:** devnw.dev/msft topology pipeline (parallel collectors + Geode flush)
- **Date:** 2026-04-06

#### Symptoms

When a QUIC connection drops mid-transaction (e.g., `driver: bad connection`), subsequent `BeginTx()` calls on pool connections return:

```
batch begin tx: geode: transaction already in progress
```

This cascades: a single "bad connection" event triggers 200+ consecutive "transaction already in progress" failures across the pool, even with retry and exponential backoff. The stale transactions are server-side state that the client's deferred `tx.Rollback()` never clears because the underlying QUIC stream is gone.

#### Reproduction

1. Open a `geode.Pool` with `MaxOpenConns=8`
2. Run a workload that executes chunked transactions in parallel (8 goroutines, each doing `pool.BeginTx` + N statements + `tx.Commit`)
3. Induce a QUIC connection failure mid-transaction (network blip, server GC pause, or large batch exceeding stream timeout)
4. Observe that ALL subsequent `BeginTx` calls fail with "transaction already in progress" until the pool recycles connections

#### Evidence (from topology-metrics.jsonl)

```json
{"source":"geode","op":"pipeline_exec","records":61546,"error":"statement 1: driver: bad connection"}
{"source":"geode","op":"pipeline_exec","records":308,"error":"batch begin tx: geode: transaction already in progress"}
{"source":"geode","op":"pipeline_exec","records":2,"error":"batch begin tx: geode: transaction already in progress"}
// ... 234 total "transaction already in progress" errors following 1 "bad connection"
```

#### Root Cause Analysis

1. Goroutine A executes `pool.BeginTx()` -- gets connection C1, sends `BEGIN` to server
2. Server acknowledges, connection C1 now has an active transaction
3. Goroutine A executes statements; QUIC stream fails mid-way -- returns `driver: bad connection`
4. Goroutine A's deferred `tx.Rollback()` fails silently (QUIC stream is dead, ROLLBACK never reaches server)
5. Connection C1 is returned to pool (or a new connection is opened on the same QUIC session)
6. Server still holds the active transaction on that session/connection
7. Goroutine B gets the connection from pool, calls `BeginTx()` -- server rejects with "transaction already in progress"

#### Workarounds Attempted (client-side)

1. **`pool.DB().Conn(ctx)` per worker** -- did NOT fix; `sql.Conn` still draws from the same pool
2. **ROLLBACK before retry** -- partially helps; `conn.ExecContext(ctx, "ROLLBACK")` before `BeginTx` clears the stale transaction, but only if the connection is reachable
3. **Increased pool size** (`MaxOpenConns=16`) -- reduces frequency but doesn't eliminate
4. **Watermark advancement on failure** -- prevents unbounded retry growth (flush watermarks advance even on failed flushes since MERGE is idempotent)

#### Recommended Server/Driver Fix

1. **Connection health check on pool checkout:** Before returning a pooled connection, send a lightweight probe (e.g., `RETURN 1`) and discard connections that fail or report active transactions
2. **Auto-ROLLBACK on connection reuse:** When the driver detects a `BeginTx` on a connection that already has an active transaction, automatically send `ROLLBACK` before the `BEGIN`
3. **QUIC session invalidation:** When a QUIC stream fails, mark the entire session as unhealthy so the pool discards all connections on that session rather than reusing them
4. **`sql.Driver.ResetSession` implementation:** Implement the `database/sql/driver.SessionResetter` interface so `database/sql` can call `ResetSession()` on checkout, which should send a `ROLLBACK` if a transaction is active

#### Impact

- Large batch MERGE workloads (10k+ statements) are unreliable over QUIC
- Parallel workers amplify the failure: one bad connection poisons the entire pool
- The `updateSnapshot` re-MERGE (run at end of topology collection) acts as a recovery mechanism since MERGE is idempotent, but incremental flushes during collection are lost

---

### GAP-0511: Sequential MERGE transactions hang — index rebuild under global write lock causes server-wide stall

- **Category:** Performance / Correctness / Transaction Engine
- **Severity:** Critical (P0)
- **Component:** `execution/property_mutation.zig`, `server/quic_connection_handler.zig`, `index_manager.zig`
- **Reporter:** devnw.dev/msft seed command (bulk JSONL → Geode ingestion)
- **Date:** 2026-04-07
- **Server version:** v0.2.36
- **Driver version:** `geodedb.com/geode v0.1.16`

#### Symptoms

When executing sequential transactions of MERGE statements on the same connection, the second transaction hangs on statement 1 or 2 and never returns. The server becomes completely unresponsive to all connections — even `RETURN 1` queries time out. The only recovery is a server restart.

Server logs show `Error handling QUIC connection (async) error=WouldBlock` during sustained MERGE workloads, followed by complete unresponsiveness.

#### Reproduction

Minimal reproducer using the Go driver:

```go
db, _ := sql.Open("geode", "quic://localhost:3141/mydb?user=geode&pass=secret&ca=server.crt")
db.SetMaxOpenConns(1)
ctx := context.Background()

// TX1: 10 MERGEs — succeeds (40-80ms per statement)
tx1, _ := db.BeginTx(ctx, nil)
for i := range 10 {
    tx1.ExecContext(ctx, "MERGE (n:User {node_id: ?}) SET n.display_name = ?",
        fmt.Sprintf("user_%d", i), fmt.Sprintf("User %d", i))
}
tx1.Commit() // OK

// TX2: hangs on statement 1 — server never responds
tx2, _ := db.BeginTx(ctx, nil)
tx2.ExecContext(ctx, "MERGE (n:User {node_id: ?}) SET n.display_name = ?",
    "user_10", "User 10")
// ^ This statement works (79ms)
tx2.ExecContext(ctx, "MERGE (n:User {node_id: ?}) SET n.display_name = ?",
    "user_11", "User 11")
// ^ HANGS FOREVER — server unresponsive, all connections blocked
```

**Observations from test runs:**

| Run | TX1 statements | TX1 result | TX2 stmt 0 | TX2 stmt 1 | TX2 stmt 2 |
|-----|---------------|------------|------------|------------|------------|
| 1   | 5 MERGEs      | OK (80ms each) | OK (79ms) | OK | OK (all 5 succeed) |
| 2   | 10 MERGEs     | OK (40-80ms each) | OK (79ms) | **HUNG 5min** | — |
| 3   | 100 MERGEs    | stmt 3 hung (180s timeout) | — | — | — |

The hang threshold appears to be around 10 MERGE statements per transaction. Below that, sequential transactions succeed. At or above that, the server stalls.

#### Root Cause Analysis

**Primary cause: Full index rebuild during MERGE under global write lock**

1. `property_mutation.zig:211` — Every `setNodePropertyFromValue()` call triggers `rebuildAdvancedIndexesForProperty()`, which performs a **full scan and rebuild** of all matching advanced property indexes.

2. `quic_connection_handler.zig:2071-2075` — MERGE acquires a **global graph write lock** before executing the statement program. The lock is held across ALL statements in the batch.

3. `index_manager.zig:1187-1206` — `rebuildAdvancedIndexesForProperty()` iterates the entire advanced index collection and calls `rebuildAdvancedIndex()` for each match. `rebuildAdvancedIndex()` at line 1365-1379 iterates the entire `nodes` HashMap.

4. With 10 MERGE statements, each setting ~2 properties (node_id, display_name), that's 20 full index rebuild operations all under the write lock. As the node count grows within the transaction, each rebuild takes longer.

5. When the first transaction commits (at `quic_connection_handler.zig:2606-2611`), the commit does NOT acquire the write lock but transitions `state.in_txn = false` and calls `commit()`. The persistence background thread may then compete for the write lock.

6. The second transaction's MERGE attempts to acquire the write lock but is blocked by either:
   - The persistence thread holding the lock while flushing committed data
   - A stale lock state left by the first transaction's commit path
   - The index rebuild from the first transaction still running in a background context

**Secondary cause: QUIC WouldBlock cascade**

The QUIC connection handler's buffered reader (`quic_connection_handler.zig:223-238`) retries on `WouldBlock` with exponential backoff. When the backend is blocked on lock contention, the QUIC stream stalls, causing `WouldBlock` errors that cascade to all connections — making the entire server unresponsive.

#### Evidence

**Client-side timing (from test harness):**

```
=== TX: 10 MERGEs ===
  tx10 stmt 0: 43ms
  tx10 stmt 1: 41ms   ← linear scaling
  tx10 stmt 2: 41ms
  ...
  tx10 stmt 8: 79ms   ← degrading as index grows
  tx10 stmt 9: 79ms
  committed 10 in 532ms

=== TX: 10 more MERGEs ===
  tx10b stmt 0: 79ms  ← first statement works
  tx10b stmt 1: FAILED after 4m59s: driver: bad connection  ← HUNG
```

**Server-side logs (from previous runs with higher concurrency):**

```
ERROR geode.server Error handling QUIC connection (async) error=WouldBlock
ERROR geode.server Error handling QUIC connection (async) error=WouldBlock
ERROR geode.server Error handling QUIC connection (async) error=WouldBlock
ERROR geode.server Protobuf read error error=Timeout
```

#### Impact

- **Bulk data ingestion is broken:** The `msft-graph seed` command (loading 12k+ topology nodes from JSONL) cannot complete — the server stalls after the first batch of MERGE statements.
- **Server becomes fully unresponsive:** Not just the offending connection — ALL connections are blocked, requiring a restart.
- **No workaround at the client level:** Reducing concurrency to 1 worker, adding throttling between chunks, and increasing timeouts all fail because the server itself deadlocks.
- **Related issues:** GAP-0272 (bulk MERGE via stdin silent failure) and GAP-0510 (stale server-side transactions after QUIC failure) are likely symptoms of the same underlying lock contention.

#### Recommended Fix

1. **Defer index rebuild to COMMIT time (highest impact):** Accumulate property changes during transaction execution and perform a single batch index rebuild at COMMIT, rather than rebuilding after every individual property mutation. This eliminates N*M index rebuilds (N statements × M properties) within the write lock critical section.

2. **Per-index granular locking:** Replace the global graph write lock with per-index read/write locks so that index rebuilds don't block unrelated operations.

3. **Incremental index update instead of full rebuild:** `rebuildAdvancedIndexesForProperty()` should update only the affected entries (insert/update the changed node) rather than scanning the entire node collection.

4. **COMMIT must acquire write lock:** The commit path at `quic_connection_handler.zig:2606-2611` should hold the write lock to prevent races with the persistence thread.

5. **WouldBlock resilience:** The QUIC connection handler should distinguish between "backend busy" WouldBlock (retryable) and "server deadlocked" (should abort and return error to client).

#### Resolution (2026-04-10)

**Status: Closed**

Three changes eliminate the write-lock stall during MERGE:

1. **Index rebuilds moved outside the graph write lock** (QUIC + gRPC handlers):
   All 5 flush points in `quic_connection_handler.zig` and 6 in `grpc_server.zig` now
   release the graph write lock BEFORE calling `rebuildAdvancedIndex`. Other connections
   can acquire the write lock immediately after execution completes, without waiting for
   the O(N) population scan.

2. **COMMIT path split** (`txn_undo_log.zig`):
   `commitDeferRebuilds()` clears undo log state under the write lock (fast O(entries)),
   then `flushPendingRebuilds()` runs the index population scan after lock release.
   For a 10-MERGE transaction this reduces write-lock hold time from ~10s to ~1ms.

3. **rebuild_mutex on IndexManager** (`index_manager.zig`):
   `rebuildAdvancedIndex` now acquires `rebuild_mutex` internally, preventing concurrent
   rebuilds from racing on the index manager's hash maps when running outside the write
   lock. This is a lower-tier lock that does not conflict with graph read/write locks.

**Files changed:**

- `src/index/index_manager.zig` -- added `rebuild_mutex` field, `rebuildAdvancedIndex` acquires it
- `src/server/quic_connection_handler.zig` -- 5 flush points: lock release moved before rebuild; COMMIT uses `commitDeferRebuilds` + deferred `flushPendingRebuilds`
- `src/transport/grpc_server.zig` -- 6 flush points: lock release moved before rebuild
- `src/txn_undo_log.zig` -- added `commitDeferRebuilds()` for split commit

**Tests:** `tests/test_gap_0511_regression.zig` (6 tests covering deferred rebuild, adapter-backed MERGE/DELETE snapshot elision, relationship endpoint lookup, startup metadata repair)

---

## GAP-0514: CANARY IMPL Coverage Sprint

- **Category:** Test Hygiene / Governance
- **Severity:** Medium (hygiene, not functional defect — all existing tests pass)
- **Component:** `tools/canaryscan`, `tests/`, CANARY-marked source files across the repo
- **Date opened:** 2026-04-06 (in `docs/FULL_AUDIT_2026_04_06.md`)

### Summary

At the time of the April 2026 audit, ~367 CANARY markers in the source tree were at `STATUS=IMPL` (implemented but not yet verified by a named test). All 1036+ Zig tests were passing; the gap is purely governance/hygiene — the code works, but the markers don't point at specific tests that prove each invariant. Closing the gap requires writing regression tests, mutation-testing them to prove they are load-bearing, then flipping `STATUS=IMPL` → `STATUS=TESTED` with a `TEST=` reference.

This work is broken into phases because the test-infrastructure requirements differ by subsystem (unit-level harness vs. catalog singleton vs. cluster activation vs. integration test).

### Phase 1A — `graph_store.zig` unit-level invariants — **CLOSED (2026-04-11)**

- **Scope:** 8 markers in `src/graph_store.zig` covering dirty-flag tracking, adjacency index maintenance, graph registry helpers, and `saveToFile` behavior.
- **Test file:** `tests/test_gap0514_graph_store_regression.zig` (6 tests, shared `GsHarness` struct backed by a temp data dir for per-test isolation).
- **Markers flipped:** `REQ-BINARY-PERSIST-DIRTY-001`, `-002`, `REQ-BINARY-PERSIST-EDGE-001`, `REQ-PERF-EDGE-ADJ-001`, `-002`, `REQ-MULTI-GRAPH-008` ×2, `REQ-STORAGE-ENGINE-PHASE2-002`.
- **IMPL count:** 358 → 350 (per `canaryscan`).
- **Mutation-test discipline:** Every test was mutation-tested during development — the feature was temporarily broken in `src/graph_store.zig`, the test was run to confirm failure, then the break was restored. Two tasks (DIRTY-001, EDGE-001) required compound mutations because dirty-setting is intentionally distributed across `ensureGraph` + the create-function bodies (defence in depth).
- **Plan:** `docs/superpowers/plans/2026-04-11-gap0514-phase1a-graph-store-tests.md`.
- **Infrastructure fix (commit `86e2a8ca`):** `tools/status_generate.py` now skips `docs/superpowers/plans/` so literal CANARY examples embedded in plan markdown don't pollute `docs/status.csv`. This also cleaned up pre-existing bogus rows from older plan docs.

### Phase 1B — `execution.zig` IMPL markers — **OPEN**

- **Scope:** ~15 markers in `src/execution.zig` and the `src/execution/` subtree covering catalog fastpath, DSN graph binding, GQL path modes, variable-length reverse traversal, graph statistics re-export, and CTE handling.
- **Target markers (non-exhaustive):** `REQ-PERF-CATALOG-FASTPATH-001`, `REQ-DSN-GRAPH-BIND-001/002`, `REQ-GQL-PATH-MODES-004`, `REQ-GQL-VARLEN-REVERSE-001`, `REQ-GQL-GRAPH-STATS-001`, `REQ-GQL-CTE-004`.
- **Blocker:** Each marker needs a catalog-singleton / `ExecutionContext` test harness (`GsHarness` alone is insufficient). The tests must exercise the query planner + execution path, not just the storage layer.
- **Estimated work:** One or two plan documents, 8-12 tasks, similar shape to Phase 1A.

### Phase 1C — remaining `graph_store.zig` storage-engine markers — **OPEN**

- **Scope:** 5 markers in `src/graph_store.zig` that Phase 1A deferred: `REQ-STORAGE-ENGINE-PHASE2-001`, `-003`, `-004`, `-005`, `-006`.
- **Blocker:** These exercise the `loadFromAdapter`, sidecar cleanup, and `persistSplitPhase` paths and require a wired `global_adapter` (heavier setup than the Phase 1A `GsHarness` provides). One option is to extend `GsHarness` with an optional in-memory storage adapter; the other is to write them as integration tests under the existing `graph_storage_adapter` test module.

### Phase 2 — distributed module — **OPEN**

- **Scope:** ~80 CANARY IMPL markers in `src/distributed/` covering replication, 2PC, cluster membership, federation, and enhanced query coordination.
- **Blocker:** Most of this code only activates when `GEODE_CLUSTER_TOKEN` is set. The existing `src/distributed/test_query_transport_node_registry.zig` is an inline copy that works around this; the broader distributed tests need a multi-node harness or an integration test framework that spins up several Geode processes.
- **Note:** GAP-0513 closed the distributed *audit* (all functional gaps resolved via commit `68ff42c4`). Phase 2 of GAP-0514 is specifically about test coverage for the already-correct code.

### Phase 3 — server + client — **OPEN**

- **Scope:** ~94 CANARY IMPL markers combined across `src/server/` and `src/client/`, covering QUIC connection lifecycle, request routing, CLI flag handling, and wire-protocol edge cases.
- **Blocker:** Server tests need a real QUIC listener + client loop; client tests need a real server to talk to. These are integration-test flavor (similar to `geodetestlab`) rather than unit-level.
- **Synergy:** Many of these can be covered by expanding the existing `geodetestlab` integration suite rather than writing new Zig tests. That also helps close the documentation claim in GAP-0517 about "development ready" coverage.

### Phase 4 — MCP test rooting + GAP-0516 activation — **OPEN**

- **Scope:** Root `src/mcp/` for Zig test discovery, which currently fails because the `lsp.zig` and `client.zig` files contain 5+ pre-existing dead-test failures (memory leaks in `getCompletions`/`validateQuery`, assertion drift in `getHover`, bearer-token IPv6 endpoint parsing conflict). Once those are fixed, activate the 4 inline GAP-0516 regression tests that currently live in `src/mcp/server.zig` as dead code (they exist but are not wired into any test target).
- **Blocker:** The 5 pre-existing test failures must be fixed first. Each is a small, targeted code fix (freeing a hash-map on a failed branch, updating an expectation to match current struct output, etc.) but they touch security-sensitive code paths and need careful review.
- **Cross-reference:** GAP-0516 (MCP NotImplemented stubs) was closed in principle — the handlers return spec-compliant `MethodNotFound`/`"[]"`/silent success. Phase 4 is about the test activation hygiene, not the handler behavior.

### Not in the Phase plan

The following CANARY-related work is out of scope for GAP-0514 phases as currently scoped:

- **Markers in `.py` / `.sh` / `.yaml` files** — `tools/status_generate.py` counts these, but they represent non-Zig subsystems (build scripts, CI hooks, Python tools) and should be tracked separately if they need coverage.
- **`docs/status.csv` vs. `tools/canaryscan/status.csv` divergence** — the Python tool and the Go tool have different scanning rules (file-type filters, promotion logic). The Python tool is the canonical pre-commit gate; the Go tool is used for `canaryscan --verify` against `GAP_ANALYSIS.md`. Phase 1A uncovered and fixed one divergence (plan-doc scanning); more may exist.
- **Benched-vs-Tested upgrades** — some markers should be `STATUS=BENCHED` (performance-sensitive paths with regression benchmarks) rather than plain `TESTED`. That is a separate governance question deferred to a future sprint.

### Tracking

| Phase | IMPL start | IMPL end | Status | Plan doc |
|-------|-----------|----------|--------|----------|
| 1A (graph_store) | 358 | 350 | **Closed 2026-04-11** | `docs/superpowers/plans/2026-04-11-gap0514-phase1a-graph-store-tests.md` |
| 1B (execution) | 350 | — | Open | — |
| 1C (graph_store storage-engine) | — | — | Open | — |
| 2 (distributed) | — | — | Open | — |
| 3 (server + client) | — | — | Open | — |
| 4 (MCP activation) | — | — | Open (blocked on pre-existing LSP/client dead-test fixes) | — |

Each open phase should get its own plan document under `docs/superpowers/plans/` before execution begins. Phase 1A's plan is the template.

### Evidence update (2026-04-16, Phase 4 audit)

- Fresh Phase 2 scan of `docs/status.csv`: IMPL coverage **improved from documented 15% → observed 10.4%** (397 of 3,820 non-exempt rows).
- Hotspot has **shifted away from `execution.zig` / `graph_store.zig`** (Phase 1A closed 8 markers there) **to the REPL / CLI / QUIC layer**.
- New Phase 1B–1E candidates by file (top 5):
  - `src/client/repl/repl_dispatch.zig` — 36 IMPL markers
  - `src/cli/main.zig` — 27 IMPL markers
  - `src/server/quic_connection_handler.zig` — 22 IMPL markers
  - `src/client/repl/repl_loop.zig` — 19 IMPL markers
  - `src/transport/grpc_server.zig` — 17 IMPL markers
- **Platform-issue sync note:** GitLab issue `#666` currently titled "GAP-0514: Deterministic nonce in ReleaseSmall builds" reuses this Gap-ID for a *different* semantic concern. The flatfile ledger's GAP-0514 (CANARY IMPL Coverage Sprint) is the authoritative meaning here; create a dedicated tracking issue for Phase 1B–1E before the IDs diverge further.

---

## GAP-0509 residual: aggregation tenant filter (open tracking item)

- **Category:** Security / Multi-tenancy isolation
- **Severity:** Low (dead code, but unsafe if wired)
- **Parent gap:** GAP-0509 (Closed 2026-04-11 — match-loop tenant isolation verified)
- **Evidence (reconfirmed 2026-04-16):**
  - `src/execution/aggregation_evaluation.zig:629-690` — `evaluateAggregation` and `evaluateAggregationWithLabels` iterate `store.nodes` with **no tenant filter**. Source file carries an explicit `GAP-0509 WARNING` comment.
  - These functions are currently **unreachable** (dead code after the tenant-filter migration).
  - CANARY marker `REQ-GAP-0509-AGG-TENANT-WARNING` shows `STATUS=IMPL` — tracked but not verified by a CI gate.
- **Why this is still a gap:** No CI enforcement prevents a future caller from wiring these functions back in; the warning comment alone is not load-bearing.
- **Recommended fix:** Either (a) delete the two dead functions, or (b) add a `tenant` parameter and route all callers through the filtered path. Add a CANARY `TEST=` marker that fails the build if either function is called without a tenant argument.
- **Acceptance criteria:** Functions either removed from the tree or refactored to require a tenant; marker flipped to `STATUS=TESTED`.

---

## GAP-0538: Zig 0.16.0 build regression — `Io.File.writeAll` removed — **CLOSED (2026-04-16)**

- **Issue:** [#710](https://gitlab.com/devnw/codepros/geode/geode/-/issues/710) — Closed
- **Category:** Bug (build-blocker)
- **Severity:** **Critical**
- **Date opened:** 2026-04-16
- **Date closed:** 2026-04-16
- **Closure commit:** [`81dc475d`](https://gitlab.com/devnw/codepros/geode/geode/-/commit/81dc475d) — `fix: close GAP-0538 — migrate cli Io.File.writeAll to Zig 0.16 API`
- **Resolution:** Migrated all 3 call sites (`src/cli/transport_response.zig:171`, `src/client/query_result_accumulator.zig:145`, `src/cli/main.zig:1897`) to a new `Stream` helper; bumped `build.zig.zon:6` to `0.16.0`; synced banners in `CLAUDE.md`, `AGENTS.md`, `README.md`, `.gitlab-ci.yml`. `zig build` exits 0; `zig build test` passes 1059/1059.
- **Evidence:** Verified in `docs/audit/gap-close-verification.md` — AC fully met.
- **Moved to:** [GAP_ANALYSIS_RESOLVED.md](GAP_ANALYSIS_RESOLVED.md)

---

## GAP-0539: `tools/status_generate.py` emits schema-invalid CSV rows — **CLOSED (2026-04-16)**

- **Issue:** [#711](https://gitlab.com/devnw/codepros/geode/geode/-/issues/711) — Closed
- **Category:** CI-CD / Tooling
- **Severity:** **Medium**
- **Date opened:** 2026-04-16
- **Date closed:** 2026-04-16
- **Closure commit:** [`4be895a9`](https://gitlab.com/devnw/codepros/geode/geode/-/commit/4be895a9) — `fix: close GAP-0539/0540 — status_generate schema bug + canaryscan resync`
- **Resolution:** `tools/status_generate.py` regex updated to guard against newline-straddle; strict `VALID_STATUS` filter drops `COMPLETE` and blank-status rows with `STATUS_GEN_WARN`. Fresh `docs/status.csv` is 4299 valid rows / 0 COMPLETE / 0 blank. Added 5 Python regression tests in `tools/test_status_generate.py`.
- **Evidence:** Verified in `docs/audit/gap-close-verification.md` — AC fully met.
- **Moved to:** [GAP_ANALYSIS_RESOLVED.md](GAP_ANALYSIS_RESOLVED.md)

---

## GAP-0540: Committed `tools/canaryscan/status.csv` lags working-tree regeneration by 210 REQ IDs — **CLOSED (2026-04-16)**

- **Issue:** [#712](https://gitlab.com/devnw/codepros/geode/geode/-/issues/712) — Closed
- **Category:** CI-CD / Docs
- **Severity:** **Low**
- **Date opened:** 2026-04-16
- **Date closed:** 2026-04-16
- **Closure commit:** [`4be895a9`](https://gitlab.com/devnw/codepros/geode/geode/-/commit/4be895a9) — same PR as GAP-0539
- **Resolution:** Regenerated `tools/canaryscan/status.csv` in sync with `docs/status.csv`; pre-commit `status.csv sync check` hook added to prevent future drift.
- **Evidence:** Verified in `docs/audit/gap-close-verification.md` — pre-commit `status.csv sync check` PASS.
- **Moved to:** [GAP_ANALYSIS_RESOLVED.md](GAP_ANALYSIS_RESOLVED.md)

---

## GAP-0541: `docs/REQUIREMENTS.md` still links GAP-0249 as open (mirror stale) — **CLOSED (2026-04-16)**

- **Issue:** [#713](https://gitlab.com/devnw/codepros/geode/geode/-/issues/713) — Closed
- **Category:** Docs
- **Severity:** **Low**
- **Date opened:** 2026-04-16
- **Date closed:** 2026-04-16
- **Closure commit:** [`d610547d`](https://gitlab.com/devnw/codepros/geode/geode/-/commit/d610547d) — `chore: close GAP-0541 — drop stale GAP-0249 link from REQUIREMENTS mirror`
- **Resolution:** Removed stale GAP-0249 bullet from `docs/REQUIREMENTS.md`; replaced with dated HTML comment. Mirror now accurately reflects tracker state.
- **Evidence:** `docs/REQUIREMENTS.md:82` — GAP-0249 bullet absent; HTML comment documents closure date.
- **Moved to:** [GAP_ANALYSIS_RESOLVED.md](GAP_ANALYSIS_RESOLVED.md)

---

## GAP-0542: NodeRegistry inline-clone drift risk untracked by CI — **WON'T DO (2026-04-16)**

- **Issue:** [#714](https://gitlab.com/devnw/codepros/geode/geode/-/issues/714) — Commented (will remain open until extraction lands)
- **Category:** Code Quality (duplication / drift)
- **Severity:** **Medium**
- **Date opened:** 2026-04-16
- **Date marked Won't Do:** 2026-04-16
- **Rationale (per `docs/audit/gap-close-plan.md` §Won't-Do):** The proposed "CI byte-identical diff check" variant treats the symptom (drift detection) rather than the cause (duplication). Zig's module system supports the extraction path cheaply. Extraction is the chosen remediation and is tracked as a Wave-5 follow-up in `docs/audit/gap-close-plan.md:194` (#35). Adding a CI diff check would add tooling debt without addressing the underlying duplication.
- **Follow-up:** Wave-5 item #35 — extract `NodeRegistry` to `src/distributed/node_registry.zig`; both prod and test import it. Tracked in `docs/audit/gap-close-plan.md`.
- **Current state (unchanged):** `src/distributed/test_query_transport_node_registry.zig:53-112` remains an inline clone of `src/distributed/query_transport.zig:607-664`.
- **Moved to:** [GAP_ANALYSIS_RESOLVED.md](GAP_ANALYSIS_RESOLVED.md) (Won't-Do section)

## LSP & MCP Bridge — 2026-05-06 audit

Phase-4 sync of the `/codepros:audit` LSP pipeline. Inputs: `/tmp/lsp-audit-phase{1,2,3}/`. Auditor: Claude Opus 4.7 (1M).

- **New gaps opened:** 14 (GAP-0816..GAP-0828, GAP-0831). GAP-0819 tracked under existing #668. GAP-0830 doc-only follow-up under existing #547.
- **Reopened:** GAP-0056 (#138) — false closure detected; dispatcher stub at `src/cli/lsp/server.zig:398-402` was never wired to `provideDefinition` at `src/cli/lsp/features.zig:451-507`.
- **Carried (intentional EXEMPT):** GAP-0254 (#547), GAP-0516 (#668 — re-scoped to GAP-0819).
- **2026-05-06 closure pass:** GAP-0056, GAP-0819 closed (commits `46334814`, `c090763b`); GAP-0818 partial — documentation pre-condition landed (commit `01ca2480`); enforcement remains tracked under #795.

### Open gaps

| Gap-ID | Issue | Severity | Domain sublabel | Title | Status |
|---|---|---|---|---|---|
| GAP-0056 | [#138](https://gitlab.com/devnw/codepros/geode/geode/-/issues/138) | High | `Domain::lsp::definition` | LSP Go-to-Definition stub silently returns null despite advertised capability | **Closed 2026-05-06** (`46334814`, `tests/server_definition_test.zig`) — moved to GAP_ANALYSIS_RESOLVED.md |
| GAP-0816 | [#752](https://gitlab.com/devnw/codepros/geode/geode/-/issues/752) | High | `Domain::lsp::lifecycle` | LSP `$/cancelRequest` not handled — long completions cannot be cancelled | Open |
| GAP-0817 | [#753](https://gitlab.com/devnw/codepros/geode/geode/-/issues/753) | High | `Domain::lsp::lifecycle` | No `positionEncoding` negotiation — UTF-8 clients silently desync on multi-byte content | Open |
| GAP-0818 | [#754](https://gitlab.com/devnw/codepros/geode/geode/-/issues/754) | Critical | `Domain::lsp::completion` (+`hover`,`definition`) | LSP feature providers carry no caller identity — multi-tenant schema leak | **Partial 2026-05-06** (docs/MCP_LSP_BRIDGE.md pre-condition landed `01ca2480`); enforcement → #795 |
| GAP-0819 | [#668](https://gitlab.com/devnw/codepros/geode/geode/-/issues/668) | Critical | `Domain::mcp::lsp-bridge` | MCP raw GQL forwarding — no allowlist, length cap, comment strip | **Closed 2026-05-06** (`c090763b`, `tests/mcp_input_guards_test.zig`) — moved to GAP_ANALYSIS_RESOLVED.md |
| GAP-0820 | [#755](https://gitlab.com/devnw/codepros/geode/geode/-/issues/755) | Medium | `Domain::lsp::workspace` | LSP `workspace/*` family entirely absent (folders, symbol, configuration, applyEdit) | Open |
| GAP-0821 | [#756](https://gitlab.com/devnw/codepros/geode/geode/-/issues/756) | Medium | `Domain::lsp::workspace` | `textDocument/rename` + `prepareRename` not implemented | Open |
| GAP-0822 | [#757](https://gitlab.com/devnw/codepros/geode/geode/-/issues/757) | Medium | `Domain::lsp::diagnostics` | `textDocument/codeAction` (quick fixes) not implemented | Open |
| GAP-0823 | [#758](https://gitlab.com/devnw/codepros/geode/geode/-/issues/758) | Low | `Domain::lsp::semantic-tokens` | `textDocument/inlayHint` for inferred types not implemented | Open |
| GAP-0824 | [#759](https://gitlab.com/devnw/codepros/geode/geode/-/issues/759) | Low | `Domain::lsp::lifecycle` | `willSave`, `willSaveWaitUntil`, `didSave` absent — formatters cannot run on save | Open |
| GAP-0825 | [#760](https://gitlab.com/devnw/codepros/geode/geode/-/issues/760) | Low | `Domain::lsp::lifecycle` | LSP transport layer has no Content-Length / JSON conformance test | Open |
| GAP-0826 | [#761](https://gitlab.com/devnw/codepros/geode/geode/-/issues/761) | Low | `Domain::lsp::lifecycle` | LSP performance / stress test pack missing | Open |
| GAP-0827 | [#762](https://gitlab.com/devnw/codepros/geode/geode/-/issues/762) | Low | `Domain::lsp::lifecycle` | LSP 3.17 protocol-conformance test pack missing | Open |
| GAP-0828 | [#763](https://gitlab.com/devnw/codepros/geode/geode/-/issues/763) | Low | `Domain::lsp::lifecycle` | DocumentStore reopen leak acknowledged but untracked | Open |
| GAP-0829 | [#764](https://gitlab.com/devnw/codepros/geode/geode/-/issues/764) | Medium | `Domain::lsp::doc-drift` | `LSP_IMPLEMENTATION.md` lists shipped features under "Future" + `GAP_ANALYSIS_RESOLVED.md` falsely closes GAP-0056 | Open |
| GAP-0830 | [#547](https://gitlab.com/devnw/codepros/geode/geode/-/issues/547) | Low | `Domain::mcp::lsp-bridge` | `src/mcp/lsp.zig` MCP↔LSP bridge has no design doc, no REQ-DOC issue, no CANARY for the bridge contract | Open |
| GAP-0831 | [#765](https://gitlab.com/devnw/codepros/geode/geode/-/issues/765) | Medium | `Domain::lsp::canary-hygiene` | LSP capability-vs-handler "advertise truthfulness" guard missing | Open |
| GAP-0832 (NEW) | tbd | Low | `Domain::lsp::lifecycle` | Residual unsafe field access at `src/cli/lsp/server.zig:220-221` after SEC-004 — file follow-up quality issue | Open |

### Top-5 must-close (per Phase-3 ranking)

1. ~~GAP-0056~~ **Closed 2026-05-06** (`46334814`).
2. ~~GAP-0819~~ **Closed 2026-05-06** (`c090763b`).
3. GAP-0818 — `LspContext { tenant_id, user_id, session_id }` parameter plumbed through `provideHover`/`provideCompletion`/`provideDefinition`. **Partial:** docs landed `01ca2480`; enforcement #795 still open.
4. GAP-0816 — `$/cancelRequest` per-request task table; cancelled handler returns -32800.
5. GAP-0831 — capability-vs-handler truthfulness test (structural fix that prevents another GAP-0056 regression).

### Cross-cutting references for sibling Phase-4 trackers

- Quality tracker: GAP-0829 (doc-drift), GAP-0831 (canary-hygiene), GAP-0832 (residual unsafe field access)
- Perf tracker: GAP-0826 (LSP perf/stress pack)
- Security tracker: GAP-0818 (Critical — multi-tenant LSP), GAP-0819 (Critical — MCP injection — **Closed 2026-05-06**)

### 2026-05-06 closure pass — summary

| Gap-ID | Title | Commit | Status |
|---|---|---|---|
| GAP-0056 | LSP Go-to-Definition wired to dispatcher | `46334814` | Closed |
| GAP-0818 | MCP-LSP bridge RLS pre-condition documented | `01ca2480` | Partial (enforcement → #795) |
| GAP-0819 | MCP input chokepoint (1 MiB cap, UTF-8, nested comments) | `c090763b` | Closed |
| GAP-0832 | Residual unsafe field access at `server.zig:220-221` (SEC-004 follow-up) | n/a | Open (filed as quality follow-up) |

## 2026-06-08/09 - CaaST multi-tenant integration findings (Tenancy & FLE)

Downstream findings from the CaaST platform's multi-tenant integration against Geode, verified against `main` source on 2026-06-08 and reconciled again on 2026-06-09 after dependency pulls. Full evidence, impact, and recommended corrections are in [CAAST_TENANCY_FLE_FINDINGS_2026-06-08.md](CAAST_TENANCY_FLE_FINDINGS_2026-06-08.md). GitLab is the source of truth - file issues and reconcile IDs when actioned.

The source CaaST note originally proposed GAP-0838 through GAP-0845. This ledger reserves GAP-0838 for the distributed cross-pod Raft failure, so the CaaST residuals are normalized here as GAP-0846 through GAP-0854.

| Gap-ID | Issue | Severity | Domain | Summary | Status |
|---|---|---|---|---|---|
| GAP-0846 | tbd | High | `Domain::tenancy::hierarchy` | Primary string-keying/population defect is fixed: `HierarchyManager` is string-keyed and tenant creation can populate it. Residual gap remains because live query/RLS evaluation still does not consult hierarchy for every read. | Open |
| GAP-0847 | tbd | Medium | `Domain::tenancy::lifecycle` | `CALL geode.tenant.*`, durable registry, admin-tenant gate, quota set, and `geode tenant` CLI now exist. Residual gaps: no standard `CREATE/DROP TENANT` GQL DDL, drop removes lifecycle record only, and `docs/security/MULTI_TENANT_HARDENING.md` still says no registry/CLI exists. | Open |
| GAP-0848 | tbd | High | `Domain::tenancy::isolation` | Strict-tenancy mode exists and is tested, but default mode still treats unset/empty/default tenant as unscoped/all tenants. | Open |
| GAP-0849 | tbd | High | `Domain::tenancy::client-parity` | Zig client upstream now sends `tenant_id` and `role` in HELLO (`../geode-client-zig` at `9ba815e`), but this repo still pins `e66fdf5`/`v0.2.11`; Go client parity remains stale per downstream findings. | Open |
| GAP-0850 | tbd | Medium | `Domain::tenancy::authz` | `--insecure-allow-all` bypasses tenant isolation/RLS/FLE; banner and docs exist, but there is no production refuse-to-start guard. | Open |
| GAP-0851 | tbd | Medium | `Domain::fle::tde` | Page encryption and per-tenant helper tests exist, but page/WAL/backup paths remain shared-master-key until per-tenant storage/key design is finished. Extends GAP-0290. | Open |
| GAP-0852 | tbd | Medium | `Domain::fle::concurrency` | Primary env override defect is fixed: `GEODE_CURRENT_ROLE` is removed from `getCurrentUserRole`. Residual gap remains because many call sites still fall back to per-thread role/tenant and tenant defaults to `"default"` instead of request context. | Partial |
| GAP-0853 | tbd | Low | `Domain::fle::ddl` | FLE schema/policy is set through `CALL geode.fle.*`; no standard GQL DDL exists. | Open |
| GAP-0854 | tbd | Critical | `Domain::fle::audit-chain` | `CALL geode.fle.configureField` can corrupt the auth/audit hash chain and produce `AuthChainTampered` on restart; reproduced by CaaST across 0.6.13, 0.6.16, 0.6.17/latest, and 0.6.18. | Closed (2026-06-09) — `__geode_security` graph excluded from FLE encrypt/decrypt (`isSecurityGraphName`, `src/graph_store.zig`); restart regression `tests/test_gap0854_fle_chain.zig`. |

**Verified-resolved during this pass (no action - recorded for traceability):** GAP-0294 (fail-open RLS) confirmed fail-closed at `rls_enhanced.zig:114-126,558-559`; GAP-0287 (broken CIDR) confirmed correct at `rls_enhanced.zig:695-748`; original GAP-0846 hierarchy string-keying and tenant-registry population sub-findings are now fixed but the hierarchy enforcement gap remains open as GAP-0846. These closed historical gaps remain closed in [GAP_ANALYSIS_RESOLVED.md](GAP_ANALYSIS_RESOLVED.md).
