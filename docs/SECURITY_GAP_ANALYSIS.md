# Security Gap Analysis -- Geode Graph-Database Server

**Last updated:** 2026-06-27
**Scope:** Zig 0.16 graph-database server (`devnw/codepros/geode/geode`) + CI/CD + supply chain
**Pipeline stage:** Step 4 of 4 (scoring + issue tracking). Inputs: inventory, automated scan, manual adversarial review.
**Scoring:** Risk Score = Impact(1-4) x Likelihood(1-4) x 4.
**Severity:** assigned by the consolidated review and may diverge from the raw score where deployment posture or upstream-CVE weight justifies it (noted per row). Issue tracker: GitLab `devnw/codepros/geode/geode`. Confidential issues used for secrets, auth bypass, RCE, priv-esc, and detailed exploit chains.

> Companion doc: `docs/GAP_ANALYSIS.md` is the engineering register and is intentionally NOT modified by this analysis. This security gap analysis is the authoritative security register; it supersedes the 2026-06-26 first-pass scoring with the reconciled consolidated-review numbers below.
> The 2026-06-11 deferred-findings register that previously occupied this file is preserved verbatim in the final section "Pre-existing deferred findings (carried over from 2026-06-11)".

---

## Executive Summary

23 findings tracked from the 2026-06-26 consolidated review (3-agent pipeline); **7 resolved** on branch feat/security-fixes as of 2026-06-27 (NEW-8, SEC-002, NEW-9, NEW-1, NEW-10, NEW-11, SEC-004) -- **16 open**. The two governance-critical items are an **active credential leak in git history** (SEC-001 -- rotate first, before any other remediation) and **pre-auth-reachable CDC control/diagnostic handlers** (SEC-002). The highest-scoring finding is an **unsigned principal envelope** (NEW-8, score 64) that a client can forge to assert Admin role and an arbitrary tenant; its systemic root cause is the absence of a connection-level auth gate (NEW-9), and it is amplified by trusted-internal provenance stamping (NEW-10).

| Severity | Count | Findings |
|----------|-------|----------|
| Critical | 3 | NEW-8, SEC-001, SEC-002 |
| High | 5 | NEW-10, NEW-1, SEC-003, NEW-9, SEC-004 |
| Medium | 8 | SEC-005, SEC-006, SEC-007, NEW-2, NEW-3, NEW-5, SEC-013, NEW-11 |
| Low | 7 | NEW-4, NEW-6, SEC-008, SEC-009, SEC-010, SEC-011, SEC-012 |
| **Total** | **23** | |
| Open | 16 | SEC-001, SEC-003, SEC-005, SEC-006, SEC-007, NEW-2, NEW-3, NEW-4, NEW-5, NEW-6, SEC-008, SEC-009, SEC-010, SEC-011, SEC-012, SEC-013 |
| Fixed | 7 | NEW-8, SEC-002, NEW-9, NEW-1, NEW-10, NEW-11, SEC-004 (feat/security-fixes, 2026-06-27) |

**Confidential issues (7):** SEC-001 (#848), SEC-002 (#849), SEC-003 (#850), NEW-8 (#860), NEW-1 (#861), NEW-9 (#867), NEW-10 (#868). SEC-004 (#851) is High but non-confidential (public upstream CVEs, no sensitive exploit detail).

**Top 5 risks (by risk score)**

1. NEW-8 (64, Critical) -- Unsigned principal envelope trusted as identity -> role/tenant forgery, priv-esc.
2. SEC-001 (48, Critical) -- Real credentials committed to git history; treat as compromised, rotate now.
3. SEC-002 (48, Critical) -- CDC `.cdc_ctrl`/`.cdc_diag` reachable pre-auth, no auth/role/audit.
4. NEW-10 (48, High) -- Forged envelope gains `.distributed_worker` trusted-internal provenance (amplifies NEW-8).
5. NEW-1 (36, High) -- Cross-graph BOLA: fail-open graph RBAC, no `USE GRAPH` re-check.

---

## Stack-Ranked Findings

| Rank | Sev | Score | ID | Finding | Component (file:line) | CWE / OWASP | Issue | Conf | Confidence | SLA (due) | Status |
|------|-----|-------|----|---------|----------------------|-------------|-------|------|-----------|-----------|--------|
| 1 | Critical | 64 | NEW-8 | Unsigned principal envelope trusted as request identity (role/tenant forgery) | `principal_envelope.zig:146-222,267-286`; `quic_connection_handler.zig:6255-6394` | CWE-290/345/269 / API3:2023 | [#860](https://gitlab.com/devnw/codepros/geode/geode/-/issues/860) | yes | suspected | 7d (2026-07-03) | Fixed |
| 2 | Critical | 48 | SEC-001 | Real credentials in git history (commit 2308910d) | `.env` history | CWE-540 / A02:2021 | [#848](https://gitlab.com/devnw/codepros/geode/geode/-/issues/848) | yes | confirmed | 7d (2026-07-03) | triage |
| 3 | Critical | 48 | SEC-002 | CDC ctrl/diag handlers reachable pre-auth, unauthenticated, unaudited | `quic_connection_handler.zig:7634-7661` (cf. `.backup` 7662-7684); `5629-5639` | CWE-306/862 / API2:2023 | [#849](https://gitlab.com/devnw/codepros/geode/geode/-/issues/849) | yes | confirmed | 7d (2026-07-03) | Fixed |
| 4 | High | 48 | NEW-10 | Forged envelope acquires `.distributed_worker` trusted-internal provenance | `quic_connection_handler.zig:6263` | CWE-290/269 | [#868](https://gitlab.com/devnw/codepros/geode/geode/-/issues/868) | yes | confirmed | 30d (2026-07-26) | Fixed |
| 5 | High | 36 | NEW-1 | Cross-graph BOLA: fail-open graph RBAC, no `USE GRAPH` re-check | `quic_connection_handler.zig:5848-5849,5074-5092` | CWE-639/863 / API1:2023 | [#861](https://gitlab.com/devnw/codepros/geode/geode/-/issues/861) | yes | suspected | 30d (2026-07-26) | Fixed |
| 6 | High | 32 | SEC-003 | RLS two-gate invariant -- single point of failure for fast-path reads (alias bypass) | `rls_filter.zig:286-299`; `node_scan_stream.zig`; `quic_connection_handler.zig:7080`; `query_execution.zig:1673`; `match_operations.zig:347-350` | CWE-863 / API1:2023 | [#850](https://gitlab.com/devnw/codepros/geode/geode/-/issues/850) | yes | confirmed | 30d (2026-07-26) | triage |
| 7 | High | 32 | NEW-9 | No connection-level auth gate (root cause of SEC-002 and NEW-8) | `quic_connection_handler.zig:5629-5639,4760-4761` | CWE-306 / API2:2023 | [#867](https://gitlab.com/devnw/codepros/geode/geode/-/issues/867) | yes | confirmed | 30d (2026-07-26) | Fixed |
| 8 | Medium | 32 | SEC-005 | Federation cluster token: single shared secret, irrevocable ReadWrite sessions | `quic_connection_handler.zig:5398,5664-5686` | CWE-287/613 | [#852](https://gitlab.com/devnw/codepros/geode/geode/-/issues/852) | no | confirmed | 90d (2026-09-24) | triage |
| 9 | High | 24 | SEC-004 | 15+ HIGH CVEs in Go deps (x/crypto, x/net) + quic-go DoS | `go.mod` | CVE list / A06:2021 | [#851](https://gitlab.com/devnw/codepros/geode/geode/-/issues/851) | no | confirmed | 30d (2026-07-26) | Fixed |
| 10 | Medium | 24 | SEC-006 | curl-pipe-bash unpinned remote scripts in CI/install | `.gitlab-ci.yml:756,1693,2170`; `scripts/install-deps.sh:56` | CWE-494 | [#853](https://gitlab.com/devnw/codepros/geode/geode/-/issues/853) | no | confirmed | 90d (2026-09-24) | triage |
| 11 | Medium | 24 | SEC-007 | docker login -p passes password as CLI arg | `.gitlab-ci.yml:1773,1943,2070` | CWE-214 | [#854](https://gitlab.com/devnw/codepros/geode/geode/-/issues/854) | no | confirmed | 90d (2026-09-24) | triage |
| 12 | Medium | 24 | NEW-2 | CDC guardrail reset unaudited (compounds SEC-002) | `quic_connection_handler.zig:7650-7661` | CWE-778 | [#862](https://gitlab.com/devnw/codepros/geode/geode/-/issues/862) | no | suspected | 90d (2026-09-24) | triage |
| 13 | Medium | 24 | NEW-3 | gitleaks CI uses --no-git, never scans history (missed SEC-001) | `.gitlab-ci.yml:1603` | CWE-540 / A02:2021 | [#863](https://gitlab.com/devnw/codepros/geode/geode/-/issues/863) | no | confirmed | 90d (2026-09-24) | triage |
| 14 | Medium | 24 | NEW-5 | auth_version==0 short-circuit -> irrevocable federation sessions | `quic_connection_handler.zig:5398` | CWE-613 / A07:2021 | [#864](https://gitlab.com/devnw/codepros/geode/geode/-/issues/864) | no | confirmed | 90d (2026-09-24) | triage |
| 15 | Medium | 24 | SEC-013 | RLS silently no-ops when authenticated_user is null | `quic_connection_handler.zig:5499,7027,7231`; `match_operations.zig:347-350` | CWE-863 | [#859](https://gitlab.com/devnw/codepros/geode/geode/-/issues/859) | no | confirmed | 90d (2026-09-24) | triage |
| 16 | Medium | 12 | NEW-11 | Graph-RBAC username->uid via non-cryptographic Wyhash (grant-borrow) | `quic_connection_handler.zig:5828` | CWE-328 | [#869](https://gitlab.com/devnw/codepros/geode/geode/-/issues/869) | no | suspected | 90d (2026-09-24) | Fixed |
| 17 | Low | 12 | NEW-4 | Role enum Admin==0 footgun (zero-default yields Admin) | `user_management.zig:65-70` | CWE-1188 / A05:2021 | [#865](https://gitlab.com/devnw/codepros/geode/geode/-/issues/865) | no | confirmed | 180d (2026-12-23) | triage |
| 18 | Low | 8 | NEW-6 | --privileged binfmt container in default-branch build | `.gitlab-ci.yml:1972` | CWE-250 / A05:2021 | [#866](https://gitlab.com/devnw/codepros/geode/geode/-/issues/866) | no | confirmed | 180d (2026-12-23) | triage |
| 19 | Low | 8 | SEC-008 | protobuf 4.25.1 in vendored grpc-zig test reqs (HIGH CVE, test-only) | `zig-pkg/grpc_zig-*/integration_test/requirements.txt` | CVE list | [#855](https://gitlab.com/devnw/codepros/geode/geode/-/issues/855) | no | confirmed | 180d (2026-12-23) | triage |
| 20 | Low | 8 | SEC-009 | 19 Zig deps pinned by tag only (no commit SHA) | `build.zig.zon` | CWE-494/1357 | [#856](https://gitlab.com/devnw/codepros/geode/geode/-/issues/856) | no | confirmed | 180d (2026-12-23) | triage |
| 21 | Low | 8 | SEC-010 | Test/vendor Dockerfiles run as root | `tests/ha/Dockerfile.runner`; `zig-pkg/quic-*/tools/high_parallel/Dockerfile` | CWE-250 | [#857](https://gitlab.com/devnw/codepros/geode/geode/-/issues/857) | no | confirmed | 180d (2026-12-23) | triage |
| 22 | Low | 8 | SEC-011 | PULL path TOCTOU: mid-stream policy not rechecked | `quic_connection_handler.zig:7372-7432` | CWE-367 | [#858](https://gitlab.com/devnw/codepros/geode/geode/-/issues/858) | no | suspected | 180d (2026-12-23) | triage |
| 23 | Low | 8 | SEC-012 | Prometheus /metrics endpoint unauthenticated (loopback default) | `metrics_server.zig:81-83` | CWE-306 / A05:2021 | [#870](https://gitlab.com/devnw/codepros/geode/geode/-/issues/870) | no | confirmed | 180d (2026-12-23) | triage |

> Severity/score divergences (by design): SEC-004 is High despite score 24 (driven by count/criticality of upstream CVEs); SEC-005 is Medium despite score 32 (deployment posture -- cluster token rarely exposed); NEW-11 is Medium despite score 12 (suspected priv-esc pending confirmation). SEC-012 is tracked as standalone #870; it shares the metrics-endpoint root cause with the pre-existing SEC-MON-01/#674 (see deferred section).

---

## Findings by Area

### Authentication & connection gating

- **NEW-9 (#867, High)** -- No connection-level auth gate: `handleClientMessage` (5629-5639) dispatches any message type pre-auth; each arm must self-guard. Systemic root cause of SEC-002 and NEW-8. Add a default-deny gate that rejects non-HELLO messages until authentication completes; keep per-arm guards as defense-in-depth.
  - **Status: FIXED** (feat/security-fixes, 2026-06-27): Default-deny gate added before request dispatch; allow-list {.hello,.ping}. Commit 918a0307.
- **SEC-002 (#849, Critical)** -- CDC `.cdc_diag`/`.cdc_ctrl` arms lack `validateSessionAuth()`, Admin role check, and audit; reachable pre-auth. Mirror the `.backup` arm (7662-7684).
  - **Status: FIXED** (feat/security-fixes, 2026-06-27): QUIC: `validateSessionAuth`+Admin guards on `.cdc_diag`/`.cdc_ctrl` + systemic default-deny connection gate. gRPC: `authorizeAdminSession` on `handleCdcDiag`/`handleCdcCtrl` (native + legacy shim). Commits c5544d61, 309470c2, 918a0307, 474e5abe, c51c7d66, 93e94099.
- **SEC-005 (#852, Medium)** + **NEW-5 (#864, Medium)** -- Federation sessions set `auth_version=0`, which short-circuits `validateSessionAuth` to `.ok` permanently; revoking the cluster token does not end live sessions. NEW-5 is the mechanism; fix together.
- **NEW-4 (#865, Low)** -- Role enum `Admin==0`: any future zero-default/uninitialized role yields Admin. Latent fail-open default.

### Authorization (identity, RLS, RBAC, tenancy)

- **NEW-8 (#860, Critical)** -- Unsigned principal envelope (wire field 4) deserialized with only magic+version+ordinal validation; `toPrincipal` rebuilds the full Principal from attacker bytes with no `roles ⊆ session_roles` / tenant check. Highest-impact authz finding. Reject field 4 on normal connections; HMAC-verify for federation peers only; enforce subset + tenant equality.
  - **Status: FIXED** (feat/security-fixes, 2026-06-27): `shouldTrustEnvelope` gate added -- trust forwarded principal only when `authenticated_user=="geode-cluster"`; `"geode-cluster"` reserved across all 6 user create/load/bootstrap paths. NEW-10 (envelope-source provenance) also covered by this fix. Commits 4875e4cf, 0b367c70, 45a52b65, fcd30e62, 6e88807e. Residual (defense-in-depth, NOT done): HMAC-sign the envelope.
- **NEW-10 (#868, High)** -- Forged envelopes are stamped `source=.distributed_worker` (6263) even from normal clients, unlocking GPS rules meant for internal federation traffic. Restrict the stamp to authenticated federation peers.
  - **Status: FIXED** (feat/security-fixes, 2026-06-27): Covered by NEW-8 fix (`shouldTrustEnvelope` gate). Commits 4875e4cf, 0b367c70, 45a52b65, fcd30e62, 6e88807e.
- **NEW-1 (#861, High)** -- Cross-graph BOLA: graph RBAC fails open (5848-5849 "allow based on global role") and `USE GRAPH` / `syncGraphFromSession` (5074-5092) perform no graph-RBAC re-check. Default-deny when a graph policy exists; re-check on graph switch.
  - **Status: FIXED** (feat/security-fixes, 2026-06-27): `GraphRBACPolicy` registered and hydrated at startup; QUIC+gRPC HELLO graph-bind routed through `gps.decide(.bind_graph)` (fail-closed); default-graph compat short-circuit; race-recovery bind guarded. Commits e090a9bb, ed7eedbc, 7e1ca652, 31ae3735, b47fe551, 4d4ea112, 2eeb39aa, d5a701e9.
- **SEC-003 (#850, High)** -- RLS fast path depends on a two-gate invariant; commit 77c0ccaa removed the defense-in-depth snapshot clone. Alias bypass (`YIELD nodeId AS n`) defeats the literal column-name check in `applyAlgorithmRLSFilter` (286-299). Resolve node-id columns by type; add in-path `passesRLSFilter` to streaming/planned-read; default-deny on null user when policies exist.
- **SEC-013 (#859, Medium)** -- RLS filter + both gates silently no-op when `authenticated_user==null` (compounds SEC-003). When `policyCount()>0`, null user must be default-deny.
- **NEW-11 (#869, Medium)** -- Graph-RBAC username->uid via non-cryptographic Wyhash (5828); a 64-bit / chosen collision could borrow another user's per-graph grants (suspected -- confirm `multi_graph_security` storage model).
  - **Status: FIXED** (feat/security-fixes, 2026-06-27): Dissolved by NEW-1 fix -- QUIC HELLO no longer uses Wyhash(username); GPS resolves uid via `agm.findUserIdByName`. Commit 7e1ca652.

### Secrets & detection

- **SEC-001 (#848, Critical)** -- VAULT_TOKEN, S3_SECRET_KEY, REDIS_PASSWORD, GF_SECURITY_ADMIN_PASSWORD committed at `2308910d` (all redacted in tracking). Rotate all four; purge `.env` from history with `git filter-repo`.
- **NEW-3 (#863, Medium)** -- CI gitleaks runs `--no-git`, so SEC-001's historical commit is invisible to the secret gate. Remove `--no-git` (or add `--log-opts=--all`).
- **SEC-007 (#854, Medium)** -- `docker login -p` exposes the registry password in process args / CI logs; switch to `--password-stdin`.

### Observability / audit

- **NEW-2 (#862, Medium)** -- CDC arms call no `auditQueryExecution`; `RESET_GUARDRAILS` leaves zero audit trail. Bundle with SEC-002.
- **SEC-012 (#870, Low)** -- `/metrics` unauthenticated, binds 127.0.0.1 by default (risk only if bound to a routable interface). Warn/refuse on non-loopback bind without auth.

### Supply chain

- **SEC-004 (#851, High)** -- x/crypto v0.48.0->v0.52.0 (9 HIGH), x/net v0.50.0->v0.55.0 (7 HIGH), quic-go v0.54.1->v0.59.1 (CVE-2025-64702, CVE-2026-40898 MEDIUM DoS).
  - **Status: FIXED** (feat/security-fixes, 2026-06-27): Bumped x/crypto v0.48->v0.53.0, x/net v0.50->v0.56.0, quic-go v0.54.1->v0.60.0 (go directive 1.24->1.25) in geode's Go module. (data-ingest module was already patched.) Commit a33990b3.
- **SEC-006 (#853, Medium)** -- curl-pipe-bash unpinned remote scripts in CI + install tooling -> upstream compromise = CI RCE. Pin to commit SHAs and verify SHA256.
- **SEC-008 (#855, Low)** -- protobuf 4.25.1 in vendored grpc-zig integration-test reqs (test-only).
- **SEC-009 (#856, Low)** -- 19 Zig deps pinned by tag only; content hash provides build-time integrity, all internal org repos.

### CI/CD & infra

- **NEW-6 (#866, Low)** -- `docker run --privileged tonistiigi/binfmt` on the default-branch build host. Use rootless QEMU user-mode on an isolated runner.
- **SEC-010 (#857, Low)** -- test/vendor Dockerfiles run as root (production Dockerfile correctly uses `USER geode`).

---

## Immediate Actions (24-48 hours)

1. **Rotate the four leaked credentials in SEC-001 (#848) NOW** -- VAULT_TOKEN, S3_SECRET_KEY, REDIS_PASSWORD, GF_SECURITY_ADMIN_PASSWORD. Treat all as compromised regardless of current validity. This is the precondition for every other remediation. Then plan `git filter-repo` to purge `.env` from history (coordinate force-push window).
2. **Close the pre-auth CDC handlers (SEC-002 #849)** -- add `validateSessionAuth()` + Admin role check + `auditQueryExecution` to `.cdc_ctrl` and `.cdc_diag` (mirror `.backup` at 7662-7684). Until patched, network-restrict the QUIC listener / disable CDC control if unused. 7-day SLA, pre-auth reachable.
3. **Stop trusting the unsigned principal envelope (NEW-8 #860)** -- reject wire field 4 on normal client connections; HMAC-verify it only for federation peers; enforce `roles ⊆ session_roles` and `tenant_id == session_tenant_id`. Fix the root cause (NEW-9 #867) in the same window by adding the connection-level auth gate; this also forecloses NEW-10 (#868).
4. **Fix the detection blind spot (NEW-3 #863)** in the SEC-001 change window: drop `--no-git` so the secret gate scans history and confirms SEC-001 is the only historical leak.

No active RCE was identified. The two highest-priority code changes besides credential rotation are the pre-auth CDC exposure (SEC-002) and the forged-identity chain (NEW-8 + NEW-9 + NEW-10).

---

## Remediation Roadmap

### Quick wins (< 1 day each)

- SEC-001 (#848): rotate creds (do first); NEW-3 (#863): remove `--no-git`.
- SEC-007 (#854): `--password-stdin`. NEW-2 (#862): audit CDC ctrl (ships with SEC-002).
- NEW-4 (#865): reorder role enum so ordinal 0 fails closed.
- SEC-010 (#857): add `USER nonroot`. SEC-012 (#870): warn/refuse non-loopback metrics bind.

### Medium (1-5 days each)

- **Phase 0 (by 2026-07-03, Critical SLA):** SEC-002 (#849) + NEW-9 (#867) connection-auth gate; NEW-8 (#860) envelope verification + NEW-10 (#868) provenance restriction.
- **Phase 1 (by 2026-07-26, High SLA):** SEC-003 (#850) + SEC-013 (#859) in-path RLS + type-based node-id resolution + default-deny null user; NEW-1 (#861) fail-closed graph bind + `USE GRAPH` re-check; SEC-004 (#851) Go dep bumps.
- SEC-006 (#853): pin/checksum remote install scripts.

### Strategic (> 5 days)

- SEC-001 history purge: `git filter-repo` + coordinated force-push and downstream re-sync (sequence after rotation).
- SEC-005 (#852) + NEW-5 (#864): per-node keys / short-lived cluster JWTs; finite federation `auth_version` with real session invalidation.
- NEW-11 (#869): re-key graph-RBAC grants by canonical username; confirm `multi_graph_security` storage.
- SEC-009 (#856): commit-SHA pinning across `build.zig.zon`. SEC-008 (#855): bump protobuf test dep.
- SEC-011 (#858): re-evaluate `rls_active` on PULL of in-flight streams.
- NEW-6 (#866): rootless QEMU binfmt on an isolated runner.

---

## False Positives & Corrections from Deep Review

These corrections were applied to scoring and issue bodies:

1. **`--insecure-allow-all` HAS a production/release guard** at `main.zig:1042-1077`. The "no debug-mode guard" claim is withdrawn -- do not cite it in any issue.
2. **`/metrics` binds 127.0.0.1 by default** (not 0.0.0.0). SEC-012 scored Low (8); exposure requires an explicit non-loopback bind. Tracked as standalone #870; shares root cause with SEC-MON-01/#674.
3. **Bulk write paths are NOT an ABAC bypass.** `executeBulkSimpleCreate` et al. ARE gated by the pre-dispatch permission check at `quic_connection_handler.zig:6387-6408`. No issue filed.
4. **SEC-003 is a latent/fragile-invariant risk** (gates currently hold; legacy per-candidate filter is the active guard) -- but the alias-bypass in `applyAlgorithmRLSFilter` is a live leak vector for algorithm-result columns and is in scope of the fix.

**Severity reconciliation (consolidated review, authoritative):** NEW-8 -> Critical (score 64); NEW-1 -> High (36); SEC-003/NEW-9 -> High (32); SEC-004 -> High (24, CVE-weighted); SEC-005 -> Medium (32, posture); SEC-013 -> Medium (24); NEW-11 -> Medium (12, suspected). NEW-9, NEW-10, NEW-11 and standalone SEC-012 were added in this pass (not present in the 2026-06-26 first cut).

---

## Tool Coverage Gaps

1. **No Zig SAST in CI.** Every Zig-side finding (auth, RLS, CDC, principal envelope, role enum) came from manual adversarial review. Treat Zig server code as having no automated security gate today.
2. **Secret scanning is history-blind (NEW-3 #863).** gitleaks `--no-git` only sees the working tree; historical leaks (SEC-001) pass CI.
3. **Suspected findings needing confirmation:**
   - NEW-8 (#860): confirm forged-envelope -> Admin write succeeds against a running server; escalate likelihood if confirmed.
   - NEW-1 (#861): confirm a bound cross-tenant graph returns another tenant's rows under the default (no-policy) config.
   - NEW-2 (#862): confirm absence of any out-of-band audit for CDC actions.
   - NEW-11 (#869): confirm `multi_graph_security` keys grants by Wyhash uid alone and that usernames are attacker-chosen; then demonstrate a colliding-username grant borrow.
   - SEC-011 (#858): trace EXECUTE->PULL to confirm in-flight streams are not re-evaluated against newly installed policy.
4. **No dependency/CVE gate on Zig deps** (`build.zig.zon` SEC-009) or vendored Python test reqs (SEC-008).
5. **No IaC/Dockerfile linter** (would have caught SEC-010 root containers and NEW-6 privileged step).

---

## Blockers / Unknowns

- Confirmation of NEW-8 / NEW-1 / NEW-11 exploitability requires a running cluster + a willing test harness; not performed in this static pass.
- `git filter-repo` for SEC-001 requires a coordinated force-push window and downstream-clone re-sync; sequence after credential rotation.
- The exact CVE IDs for the Go HIGH advisories (SEC-004) should be enumerated from `govulncheck`/OSV at remediation time to confirm the version bumps fully close them.

---

## Pre-existing deferred findings (carried over from 2026-06-11)

These entries were the prior contents of this file (a separate, earlier security pass). They are preserved unchanged so no prior tracking is lost. Note: SEC-MON-01 below and SEC-012 above both reference the metrics endpoint; SEC-012 is now tracked standalone (#870) while SEC-MON-01 remains on #674 -- treat them as the same root cause.

| ID | Severity | Risk | Finding | Component | Issue | Status |
|---|---|---:|---|---|---|---|
| SEC-MFA-FIPS-01 | Info | 4 | TOTP HMAC-SHA1 only; add SHA-256/SHA-512 for FIPS-mode customers. | `src/security/mfa_risk.zig` | #821 | Backlog -- deferred: no FIPS customer requirement is documented anywhere in the repo or issue tracker; HMAC-SHA1 remains RFC 6238-compliant for TOTP. Revisit when a FIPS-mode deployment requirement lands. |
| SEC-MON-01 | Low | 6 | Metrics endpoint auth remains a timing-oracle concern when re-implemented/exposed. | `src/monitoring/metrics_server.zig` | #674 | Open / deferred -- deferred: the metrics endpoint is not currently exposed (no serve-path listener wires `metrics_server.zig`); the concern only materializes if/when it is re-implemented or exposed. Gate any re-exposure on a constant-time auth compare. |
| SEC-INFRA-02 | Medium | 2 | nginx h2c residual on Grafana vhost. | `config/nginx/conf.d/geode.conf` | #740 | Open / deferred -- deferred: infrastructure configuration, operator action required (repo only ships the example config); not closable by a code change in this repo. |
| LSP-SEC-002 | Medium | 32 | Vendored `mcp` bearer compare (`checkAuth`, `std.mem.eql`) is not constant-time; no override hook in the pinned package, so the fix needs an upstream patch + fork pin. Mitigated at the geode boundary 2026-06-10 (commit `2b03d9ad`): geode-owned token compares audited constant-time (auth_lib api_keys SHA-256+`timing_safe.eql`; `src/security/authn.zig:526`), HTTP `http_bind` defaults to loopback and the CLI never exposes it (pinned by `zig build test-gap0885-lsp`), stdio never reaches `checkAuth`. | vendored MCP/LSP package | #785 | Open -- mitigated/documented; fork-pin follow-up |
| GAP-0818 enforcement gate | Critical-latent | n/a | MCP-LSP RLS pre-condition. Enforcement gate LANDED 2026-06-10: when auth provides no VERIFIED principal, LSP serves no tenant-scoped schema/RLS-filtered data. Residual (GAP-0818 stays Partial): the LSP tenant for a VERIFIED principal is still client-asserted (`initializeOptions.geode.tenant`) -- token verification establishes user/role but does not derive/validate the tenant against the principal. Until verified tenant derivation lands, do not attach tenant-aware RLS policies to MCP/LSP-reachable databases (see `docs/MCP_LSP_BRIDGE.md`). | `src/cli/lsp/server.zig`; `docs/MCP_LSP_BRIDGE.md` | #795 | Open -- gate landed; residual: verified tenant derivation |
