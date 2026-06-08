# Raft Transport Stream-Starvation Fix Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax.

**Goal:** Stop a 3-node raft cluster from degrading one peer to a stuck `candidate` under sustained heartbeat+AppendEntries load, per the k8s-verified root cause #5 in `docs/bugs/2026-06-04-cluster-raft-no-stable-quorum-writes-time-out.md`.

**Architecture:** Phased, geode-side (cluster transport is gated by `GEODE_CLUSTER_TOKEN`). Phase A = bounded, low-risk fixes to the *send error handling + drain* that directly stop the starvation (no wire-protocol change). Phase B = the durable wire-protocol rework (bounded long-lived multiplexed streams per peer) — higher-risk, gated behind a multi-node load test.

**Tech Stack:** Zig 0.16, `src/distributed/raft_consensus.zig` (sender `Transport`), `src/distributed/cluster.zig` (receiver `handleQuicConnection`), vendored `~/src/devnw/zig/quic`.

---

## Root cause (k8s-verified 2026-06-08, geode 0.6.25)

Leader's raft transport, per ~120s under load: `OutOfStreams = 14`, `HandshakeError = 19`, `QUIC poll cycle slow … cycle_ms≈1200`. Three compounding defects in `Transport.send` (`raft_consensus.zig:729`) + `dispatchOutbox` (`:549`):

1. **One QUIC stream per RPC.** `send` calls `conn.client.getStream()` for every RPC (`:762`), writes one frame, FINs, closes (`:773,788`). Under heartbeat (50 ms) + AppendEntries load this opens streams faster than the peer refills `MAX_STREAMS_BIDI` credit (the peer raises it only as it accepts/closes streams — `quic methods_b.zig:220` returns `error.OutOfStreams` when `opened_bidi >= peer_max_streams_bidi`). `OutOfStreams` is **transient backpressure**, not a dead connection.
2. **Evict-on-`OutOfStreams`.** On `getStream` failure `send` evicts the whole peer connection (`:770` → `evictPeerConnection`), forcing a full TLS handshake next send (the `HandshakeError=19` churn) and *resetting* the stream credit — making the exhaustion worse, not better.
3. **Single serial drain across all peers.** `outboxDrainLoop` (`:580`) → `dispatchOutbox` (`:549`) sends every peer's queued messages serially on one thread. A peer stuck in handshake/backpressure delays the other peers' heartbeats too.

Net: the busiest peer hits `OutOfStreams` → gets evicted → handshake churn → its heartbeats stop landing → election timeout → it parks as `candidate`. Quorum (2/3) holds, so the cluster keeps replicating but tolerates the degraded node like a permanent failure.

---

## Phase A — stop the starvation (bounded, no wire-protocol change)

### Task A1: Do NOT evict the peer connection on transient `OutOfStreams`

**Files:** `src/distributed/raft_consensus.zig` (`send`, ~762-772; add a classifier)

`OutOfStreams` (and `WouldBlock`) are transient backpressure — the connection is healthy; the peer's `MAX_STREAMS` credit will refill as it drains streams. Dropping one periodic heartbeat/AppendEntries is harmless (the next tick re-sends); tearing down the connection is catastrophic (handshake churn + credit reset). Only evict on genuinely-dead-connection errors.

- [ ] **Step 1: Write the failing unit test** — a `send_override`-free unit test of the classifier helper.

```zig
// in raft_consensus.zig tests (or tests/test_raft_transport_backpressure.zig)
test "OutOfStreams/WouldBlock are transient (no evict); other errors evict" {
    try std.testing.expect(!shouldEvictOnSendError(error.OutOfStreams));
    try std.testing.expect(!shouldEvictOnSendError(error.WouldBlock));
    try std.testing.expect(shouldEvictOnSendError(error.ConnectionReset));
    try std.testing.expect(shouldEvictOnSendError(error.BrokenPipe));
}
```

- [ ] **Step 2: Run it, confirm it FAILS** (`shouldEvictOnSendError` undefined). Build step: add `test-raft-transport-backpressure` mirroring an existing isolated test step, or run via the umbrella.

- [ ] **Step 3: Implement the classifier + apply at both `getStream` and `writeRaftFrame` failure sites.**

```zig
/// Transient backpressure (peer MAX_STREAMS credit momentarily exhausted, or
/// non-blocking would-block) must NOT tear down a healthy peer connection —
/// evicting forces a TLS handshake and resets the stream credit, worsening the
/// exhaustion (k8s root cause #5). Drop the message (periodic RPCs re-send on
/// the next tick) and keep the connection. Only evict on a genuinely dead conn.
fn shouldEvictOnSendError(err: anyerror) bool {
    return switch (err) {
        error.OutOfStreams, error.WouldBlock, error.StreamLimitReached => false,
        else => true,
    };
}
```

In `send`, replace the unconditional `evictPeerConnection` in the `getStream` and `writeRaftFrame` catch blocks with `if (shouldEvictOnSendError(err)) self.evictPeerConnection(peer.id);` and return the error (the drain logs at debug). (Confirm the exact transient error set against `~/src/devnw/zig/quic/src/quic/connection/methods_b.zig` — `OutOfStreams` is the primary one; add `WouldBlock` if `getStream` can return it.)

- [ ] **Step 4: Run the test, confirm PASS.** Commit: `fix(raft): don't evict peer connection on transient OutOfStreams backpressure`.

### Task A2: De-serialize the outbox drain per-peer

**Files:** `src/distributed/raft_consensus.zig` (`dispatchOutbox`, `:549`)

A slow/backpressured peer must not delay other peers' heartbeats. Group the drained snapshot by peer id and dispatch each peer's group independently so one peer's send latency is isolated. Per-peer `client_mutex` already serializes per-connection, so cross-peer concurrency is safe (different connections/mutexes); the `peers` map is `peers_mutex`-guarded.

- [ ] **Step 1: Write a unit test** asserting that, given queued messages for peers {1,2,3} where peer 3's `send_override` blocks/sleeps, peers 1 and 2 are still dispatched promptly (use the existing `send_override` hook + a per-peer dispatch-order/timestamp assertion). Confirm it FAILS against the current serial loop.

- [ ] **Step 2: Implement per-peer dispatch.** Partition `snap.items` by `entry.peer.id`; submit each peer's slice to the cluster thread pool (or spawn a bounded set of per-peer worker tasks). Keep ordering *within* a peer (raft requires in-order-ish heartbeat/AppendEntries per peer). Free each message after its send. Preserve the shutdown cancellation check.

- [ ] **Step 3: Run the test + the full distributed test suite. Commit:** `fix(raft): dispatch outbox per-peer so one backpressured peer can't starve others`.

### Task A3: Regression — netns 3-node steady-state under load

**Files:** extend `tests/cluster/netns_cluster_replication_test.sh` (or a new `netns_cluster_steady_state_load.sh`) + `tests/test_cluster_3node_steady_state.zig`

- [ ] Drive a 3-node distinct-IP netns cluster under **sustained write load** for ~60s (optionally CPU-constrained via cgroup, mirroring `tests/quic/quic_sustained_load_repro.sh`), then assert: (a) exactly one leader, (b) **both** followers stay `follower` (no node parks as `candidate`), (c) the leader's `OutOfStreams` counter stays bounded and the `QUIC poll cycle slow` warning does not fire, (d) a final write reads back on all three nodes. This is the acceptance gate for Phase A *and* Phase B.

---

## Phase B — bounded long-lived multiplexed streams per peer [SCOPED, protocol change, gated]

The complete fix for the per-RPC stream churn (eliminates `OutOfStreams` at the source). Higher risk: coordinated sender+receiver wire-protocol change to the cluster transport.

**Sender (`raft_consensus.zig`):** maintain a bounded pool (e.g. 2–4) of **long-lived** bidirectional streams per `PeerConnection`; write length-prefixed frames over them round-robin / least-busy; do **not** FIN/close per RPC. Reap/replace a stream only on genuine error.

**Receiver (`cluster.zig handleQuicConnection`):** read **multiple** length-prefixed frames per accepted stream in a loop (today: "one raft frame per stream", `:1220`), until the stream closes — so a long-lived multiplexed stream delivers many RPCs.

**Gate:** the Task A3 netns load test must show `OutOfStreams → 0` and all three nodes stable under sustained load, with **no regression** in the existing distributed test suite. Validate before landing.

---

## Self-review

- Spec coverage: doc root-cause #5 part "evicting on OutOfStreams" → A1; "single waitForHandshake-blocking drain serializing sends" → A2; "one QUIC stream per RPC … multiplex over bounded long-lived streams" → Phase B. Acceptance gate (doc's "assert a single leader survives + reads back on both followers + assert against the QUIC-poll-slow warning") → A3.
- Placeholders: A1 carries exact code; A2/A3/B are concrete designs (A2's per-peer partition + A3's assertions are specified; B is intentionally scoped/gated as the higher-risk protocol change).
- Risk ordering: A1 (smallest, highest-value — stops the evict/handshake churn) first; A2 (isolation); A3 (gate); B (protocol rework) last, gated.
