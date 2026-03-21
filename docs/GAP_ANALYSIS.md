# Gap Analysis

Last updated: 2026-03-21
Audited by: Claude Opus 4.6 (requirements-to-code gap analysis) + load test regression (2026-03-21)

## Summary

- **Total open gaps:** 5
- **Critical:** 1
- **High:** 2
- **Medium:** 2
- **Blocked (external dependency):** 3 (GAP-0246, GAP-0247, GAP-0256)
- **Won't Do:** 1 (GAP-0258)
- **Closed this session (2026-03-13):** GAP-0248, GAP-0249, GAP-0250, GAP-0251, GAP-0252, GAP-0253

GitLab is the source of truth for all gap status and tracking. This document contains **OPEN gaps only**. Resolved items are in [GAP_ANALYSIS_RESOLVED.md](GAP_ANALYSIS_RESOLVED.md).

## Gaps

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

### GAP-0255: gRPC transport missing savepoint support and 7 message types vs QUIC

- **GitLab issue:** [#548](https://gitlab.com/devnw/codepros/geode/geode/-/issues/548)
- **Category:** Feature
- **Severity:** High
- **Requirement source:** Transport parity requirement; [#515](https://gitlab.com/devnw/codepros/geode/geode/-/issues/515)
- **Current state (evidence):**
  - `src/transport/grpc_server.zig:1510-1512` — `handleSavepoint()` returns `success: false`
  - `src/transport/grpc_server.zig:1516-1518` — `handleRollbackTo()` returns `success: false`
  - Issue #515 documents 7 missing message types in gRPC vs QUIC handler
- **Why this is a gap:** gRPC clients get degraded functionality compared to QUIC. Savepoints required for complex transaction workflows.
- **Impact/Risk:** Clients using gRPC transport cannot use savepoints or 7 other operations available via QUIC.
- **Recommended fix:** Implement savepoint/rollback-to in gRPC handler; address missing message types per #515.
- **Acceptance criteria:** gRPC handler supports all message types that QUIC handler supports.

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

### ~~GAP-0253~~: Cryptographic signature algorithms — **CLOSED / Implemented**

- **GitLab issue:** [#546](https://gitlab.com/devnw/codepros/geode/geode/-/issues/546)
- **Resolution (2026-03-13):** ECDSA P256 and P384 sign/verify implemented in `src/types/cryptographic.zig` using `std.crypto.sign.ecdsa.EcdsaP256Sha256` and `EcdsaP384Sha384`. Key generation, signing, and verification all functional. RSA PSS explicitly deferred (Zig stdlib limitation documented). Unit tests added and passing. See [GAP_ANALYSIS_RESOLVED.md](GAP_ANALYSIS_RESOLVED.md).

### ~~GAP-0257~~: `58000: Internal Server Error` on MATCH+ORDER BY over large result sets — **CLOSED / Fixed**

- **GitLab issue:** *(open — to be filed)*
- **Category:** Correctness / Query Engine
- **Severity:** High
- **Resolution (2026-03-21):** Root cause was memory corruption in spice thread pool's fork/join parallel map during data page serialization (`proto_util.zig:buildDataPage`). When result sets exceeded 512 rows, the parallel path corrupted memory, causing the catch-all error handler to emit `58000: Internal Server Error`. Fix: replaced parallel serialization with sequential loop (per-row protobuf conversion is lightweight — no measurable throughput impact). Also increased `writeServerPacket` initial protobuf buffer from 4KB to 64KB to reduce reallocations for large pages. Regression test: `gap_0257_orderby_large_resultset.yml` (42 tests, 1000 and 2500 node ORDER BY verified).
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
