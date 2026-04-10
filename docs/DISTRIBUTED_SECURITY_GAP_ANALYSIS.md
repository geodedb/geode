# Distributed Module Security Gap Analysis

**Date:** 2026-04-01
**Scope:** `src/distributed/`

## Summary

| Risk Level | Open | Closed | Total |
|-----------|------|--------|-------|
| Critical | 0 | 2 | 2 |
| High | 1 | 4 | 5 |
| Medium | 5 | 0 | 5 |
| Low | 2 | 0 | 2 |

## Critical

### SEC-D001: Unauthenticated Raft QUIC Listener (CWE-306) -- **CLOSED (2026-04-10)**

- **File:** `cluster.zig:531-538`
- **Description:** `networkLoop` accepts any QUIC connection. `handleQuicConnection` reads and dispatches Raft frames with zero authentication -- no HELLO, no token, no certificate check.
- **Attack:** Connect to cluster QUIC port, send `RequestVote` with `term=999999` to force leader stepdown. Send fabricated `AppendEntries` to corrupt graph data.
- **Mitigation:** Require mTLS with cluster-issued certificates, or implement GEODE_CLUSTER_TOKEN pre-auth handshake on accepted connections before processing Raft frames.
- **Resolution:** Cluster token validation + nonce replay protection implemented at `cluster.zig:531-538`. Connections are rejected before Raft frame processing if token is invalid.

### SEC-D002: Unauthenticated JOIN_CLUSTER + Data Exfiltration (CWE-306, CWE-862) -- **CLOSED (2026-04-10)**

- **File:** `cluster.zig:562-567`
- **Description:** `handleJoinCluster` parses `NodeInfo` from message data and directly appends to `cluster_state.nodes` with no auth. Then triggers `rebalanceShards()` which assigns shards to the rogue node, and `performReplication()` which sends shard snapshots to all replicas including the attacker.
- **Attack:** Send JOIN_CLUSTER message with rogue endpoint. Receive full cluster topology in response. Wait for replication to receive data snapshots.
- **Mitigation:** Authenticate join requests. Add node allowlisting. Never return topology to unauthenticated joiners.
- **Resolution:** Auth token validation before join processing at `cluster.zig:562-567`. JOIN_CLUSTER requests are rejected if cluster token is missing or invalid.

## High

### SEC-D003: 2PC Has No Application-Layer Auth (CWE-306, CWE-345) -- **CLOSED (2026-04-10)**

- **File:** `twophase.zig:22-26,758,791,900,1223-1228`
- **Description:** `TwoPhaseTransport` sends/receives raw protobuf `TwoPhaseMessage` with no HELLO, no auth token. An attacker can send COMMIT for a known transaction_id to force premature commit.
- **Mitigation:** Add HELLO handshake with GEODE_CLUSTER_TOKEN (same pattern as `federation.zig:174-207`).
- **Resolution:** GEODE_CLUSTER_TOKEN used for outbound 2PC messages, `validateClusterToken` for inbound. Auth enforced at `twophase.zig:22-26,758,791,900,1223-1228`.

### SEC-D004: query_transport Sends Empty Credentials (CWE-287) -- **CLOSED (2026-04-10)**

- **File:** `query_transport.zig:527-537`
- **Description:** `Connection.connect()` sends `username=""`, `password=""` in HELLO. In no-auth mode: full query access. In auth mode: distributed queries silently fail.
- **Mitigation:** Use `buildFederationHelloRequest()` pattern from `federation.zig`.
- **Resolution:** `buildClusterHelloRequest` implemented for HELLO handshake at `query_transport.zig:527-537`, sending proper credentials for distributed query connections.

### SEC-D005: Debug Build Auto-Bypasses TLS (CWE-295, CWE-319) -- **CLOSED (2026-04-05)**

- **Files:** `query_transport.zig:578`, `twophase.zig:161`, `twophase.zig:343`
- **Description:** `if (builtin.mode == .Debug) break :blk true;` unconditionally skips TLS in debug builds. `federation.zig` was already fixed (does NOT auto-bypass).
- **Resolution:** Removed `builtin.mode == .Debug` TLS bypass. All builds now require explicit GEODE_CLUSTER_INSECURE env var to skip TLS, matching federation.zig pattern.

### SEC-D006: TLS Downgrade via 3 Inconsistent Env Vars (CWE-757) -- **CLOSED (2026-04-05)**

- **Description:** `GEODE_CLUSTER_INSECURE` (query_transport, twophase), `GEODE_FEDERATION_INSECURE` (federation), `GEODE_CLUSTER_ALLOW_INSECURE` (cluster). No audit trail for TLS downgrade.
- **Resolution:** Consolidated to single env var GEODE_CLUSTER_INSECURE across all distributed modules. Removed GEODE_FEDERATION_INSECURE and GEODE_CLUSTER_ALLOW_INSECURE aliases.

### SEC-D007: Federation Queries May Bypass Coordinator-Side RLS (CWE-863)

- **File:** `federation.zig:277-398`
- **Description:** Federation sends raw `query_text` to remote nodes. Remote applies its own RLS. But merged results returned to coordinator skip coordinator-side `rls_filter.applyRLSFilter`.
- **Mitigation:** Apply RLS filter to federated results using the requesting user's identity before returning to client.

## Medium

### SEC-D008: Unbounded Alloc from u32 Length Prefix (CWE-770)

- **Files:** 5 locations (`raft_consensus.zig:375`, `twophase.zig:312,784`, `federation.zig:1354`, `query_transport.zig:843`)
- **Description:** u32 length from wire used directly as allocation size. Max 4GiB. QUIC stream window (10MiB) partially mitigates but alloc still happens before data arrives.
- **Mitigation:** Add `MAX_FRAME_SIZE` constant (16MiB) and reject before allocating.

### SEC-D009: No Replay Protection (CWE-294)

- **Files:** `cluster.zig:471-491`, `twophase.zig:939-987`
- **Description:** No nonces or timestamp freshness checks. 2PC `handlePrepare` provides idempotency but not replay rejection -- attacker can replay PREPARE to keep locks held.

### SEC-D010: Cross-Tenant Leakage via Federation (CWE-200)

- **File:** `federation.zig:277-296`
- **Description:** Federation HELLO sends `tenant_id: null`. Queries forwarded without tenant context. Remote node may not apply tenant-specific RLS.

### SEC-D011: Raft RPC Zero TLS Configuration (CWE-319)

- **File:** `raft_consensus.zig:181-218`
- **Description:** Raft RPC uses bare `qc.connect()` with no TLS config. No mTLS -- any client completing TLS handshake can inject Raft frames.

### SEC-D012: Topology Leak in JOIN_CLUSTER Response (CWE-200)

- **File:** `cluster.zig:513-516`
- **Description:** Returns all node endpoints, shard assignments, key ranges to unauthenticated joiners.

## Low

### SEC-D013: Debug Print Bypasses Structured Logging (CWE-532)

- **File:** `network_transport.zig:165`
- **Description:** `std.debug.print("PEER_UNHEALTHY node=...")` leaks topology info to stderr outside audit framework.

### SEC-D014: TOCTOU Race in Raft Persistent State (CWE-367)

- **File:** `raft_persistent.zig:123-151`
- **Description:** State save uses non-atomic `createFile`+`writeAll` with no fsync. Crash mid-write loses term file.

---

*Generated 2026-04-01, updated 2026-04-10*
