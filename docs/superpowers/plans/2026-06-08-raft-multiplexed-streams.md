# Raft Bounded Multiplexed Streams Implementation Plan

> **For agentic workers:** REQUIRED SUB-SKILL: Use superpowers:subagent-driven-development (recommended) or superpowers:executing-plans to implement this plan task-by-task. Steps use checkbox (`- [ ]`) syntax for tracking.

**Goal:** Stop the raft transport from opening a fresh QUIC bidi stream per RPC (which exhausts per-peer stream credit under sustained write load and silently drops heartbeats/RequestVote → leader-flap/split-brain). Send all raft frames over **one bounded long-lived bidirectional stream per peer**, with the receiver looping over length-delimited frames on that stream.

**Architecture:** Each `PeerConnection` (src/distributed/raft_consensus.zig) gains a persistent `send_stream` reused across RPCs under the existing `client_mutex`; `send()` writes a length-prefixed frame to it and does NOT `finish()` per RPC. On any write/open error the stream is closed+nulled (reopened on the next send) but the connection is NOT evicted for transient backpressure. The receiver (src/distributed/cluster.zig `dispatchRaftFrameFromAdaptedStream`) loops `readRaftFrame` until `EndOfStream`, applying each frame. Frames are already 4-byte big-endian length-prefixed (`writeRaftFrame`/`readRaftFrame`), so no wire-format change is needed.

**Tech Stack:** Zig 0.16, vendored `quic` lib (`QuicClient`/`QuicClientStream`/`QuicStream`), the netns integration harness (`tests/cluster/netns_cluster_replication_test.sh`), `zig build` test steps.

---

## Confirmed root cause + repro (do not re-investigate — this is established)

- **Mechanism:** `Transport.send` (raft_consensus.zig:878) calls `conn.client.getStream()` for **every** RPC, writes one frame, `finish()`es, `deinit()`s the stream — serialized per peer on `conn.client_mutex`. Under sustained write load, AppendEntries-with-entries consume the peer's `max_streams_bidi` credit; the next `getStream()` returns `OutOfStreams`/`WouldBlock`, and `send` **drops the RPC** ("next raft tick re-sends"). When the dropped RPC is a heartbeat (AppendEntries with no entries) or RequestVote/Response, the control plane starves → follower election timeout → term advance → split-brain.
- **Faithful repro:** `tests/cluster/netns_cluster_replication_test.sh` (distinct routable IPs in network namespaces — the topology that reproduces the real multi-pod bug; loopback does NOT). Run AS USER: `make test-cluster-netns` (uses `sudo` internally + privilege-drops to the invoking user). Current result on `main` (4dea5740): **A1–A4 PASS** (election + at-rest CREATE/CREATE...RETURN replication + follower-write rejection); **A5 FAILS** under 6 concurrent writers for 45s — `node2 state=leader term=1`, `node3 state=leader term=2`, `node1 candidate`, `LoadFinal=0` (replication stalled), `evict-on-error lines=0` (A1's no-evict holds).
- **Why per-RPC streams, historically:** A6c made the *connection* long-lived but kept per-RPC streams "the cheap part." A6b adds explicit `finish()` so the vendor lib flushes payload instead of RESET. A6f serializes all `client.*` calls on `client_mutex` (the vendor stream-tracking HashMap is not thread-safe). The multiplexed-stream design must preserve A6b's flush semantics (write completes before the next frame) and A6f's serialization (still hold `client_mutex` around every `client.*`/`stream.*` call).

## Files to modify

- `src/distributed/raft_consensus.zig` — `PeerConnection` (add `send_stream`), `send()` (reuse stream), eviction/reopen helpers, `PeerConnection.deinit` (close `send_stream`).
- `src/distributed/cluster.zig` — `dispatchRaftFrameFromAdaptedStream` (loop frames), and verify `runConnectionTask`/the per-connection stream-accept path keeps one worker per connection for the stream's lifetime.

## Pre-flight verification (the implementer MUST read exact signatures before coding)

These are read-only confirmations; record findings in the task's commit message.

- [ ] **V1:** `quic.QuicClient.getStream()` return type and `QuicClientStream` methods actually available (`writeAll`, `finish`, `deinit`, and whether the *same* stream object can be written repeatedly without `finish`). Grep the vendored quic pkg: `grep -rnE "pub fn getStream|pub fn writeAll|pub fn finish|pub fn deinit|pub const QuicClientStream" zig-pkg/quic-*/src/`. If `writeAll` after a prior `writeAll` on the same stream is unsupported, STOP and escalate (the design assumes a stream is a reusable byte channel).
- [ ] **V2:** Receiver per-connection model — read `runConnectionTask` and the function it calls to obtain streams from a connection in `src/distributed/cluster.zig` (search from `fn runConnectionTask`). Confirm: (a) each accepted connection runs on its own `connection_pool` worker, (b) within a connection, how streams are accepted (one stream, or a loop). The long-lived raft stream means ONE worker stays parked reading frames for that connection's life; confirm `connection_pool` worker count ≥ (cluster size − 1) + headroom for transient cluster-RPC connections. If a connection multiplexes BOTH the long-lived raft stream AND transient cluster-RPC streams and the receiver only handles one stream per connection, note it — the sender already uses a *separate* `QuicClient` connection for raft (`getOrCreatePeerConnection`) distinct from the cluster-RPC client, so the raft connection carries only the one long-lived stream. Verify this separation holds.
- [ ] **V3:** Confirm `readRaftFrame` returns `error.EndOfStream` (not a hang) when the peer closes/resets the long-lived stream, and that `PrefixedStream.read` only injects its prefix byte once (so looping `readRaftFrame` on the same `&prefix` reads subsequent frames straight from the inner stream). Read `readRaftFrame` (raft_consensus.zig:1386) and `PrefixedStream` (cluster.zig:290).

---

### Task 1: Receiver — loop length-delimited frames on a raft stream

**Files:**
- Modify: `src/distributed/cluster.zig` — `dispatchRaftFrameFromAdaptedStream` (~line 1364)

- [ ] **Step 1: Capture current netns A5 failure as the baseline (RED).**

Run: `make test-cluster-netns` (or `timeout 360 sudo tests/cluster/netns_cluster_replication_test.sh zig-out/bin/geode`)
Expected: `FAIL: A5 expected exactly 1 leader after load, got 2` and `LoadFinal=0`. Record the output.

- [ ] **Step 2: Change `dispatchRaftFrameFromAdaptedStream` to loop until EndOfStream.**

Current:
```zig
fn dispatchRaftFrameFromAdaptedStream(self: *ClusterCoordinator, prefix: anytype) !void {
    const frame_res = try raft_consensus.readRaftFrame(self.allocator, prefix);
    defer frame_res.deinit(self.allocator);
    try self.applyDecodedRaftFrame(frame_res);
}
```
New (loop; the first frame consumes `prefix`'s injected byte, subsequent frames read straight from the inner stream; a closed/reset stream surfaces as `error.EndOfStream` which ends the loop cleanly):
```zig
fn dispatchRaftFrameFromAdaptedStream(self: *ClusterCoordinator, prefix: anytype) !void {
    // 2026-06-08 raft multiplexed streams: a peer now sends ALL raft frames
    // over ONE long-lived bidi stream (bounded per-peer stream usage, so
    // heartbeats/votes are never dropped on OutOfStreams under write load).
    // Read length-delimited frames until the peer closes/resets the stream.
    while (true) {
        const frame_res = raft_consensus.readRaftFrame(self.allocator, prefix) catch |err| switch (err) {
            error.EndOfStream => return, // peer closed/reopened the stream — normal
            else => return err,
        };
        defer frame_res.deinit(self.allocator);
        self.applyDecodedRaftFrame(frame_res) catch |err| {
            // A single bad/late frame must not tear the whole stream down;
            // log and keep reading (raft re-sends on its own cadence).
            log.warn("raft frame apply failed; continuing stream", &.{Attr.string("error", @errorName(err))});
        };
    }
}
```

- [ ] **Step 3: Build.**

Run: `zig build 2>&1 | tail -5`
Expected: builds clean (no errors).

- [ ] **Step 4: Commit.**

```bash
git add src/distributed/cluster.zig
git commit -m "fix(raft): receiver loops length-delimited frames on a long-lived stream"
```

Note: this change is backward-compatible with the CURRENT per-RPC sender (old sender sends 1 frame + FIN → receiver reads it, next `readRaftFrame` hits EndOfStream → loop exits). So Task 1 is safe to land before Task 2.

---

### Task 2: Sender — reuse one long-lived stream per peer

**Files:**
- Modify: `src/distributed/raft_consensus.zig` — `PeerConnection` struct (~line 383), `PeerConnection.deinit` (~line 416), `send()` (~line 878)

- [ ] **Step 1: Add a persistent send-stream field to `PeerConnection`.**

In the `PeerConnection` struct (after `client_mutex`):
```zig
        /// 2026-06-08 raft multiplexed streams: ONE long-lived bidirectional
        /// stream reused for every raft frame to this peer, so we never open a
        /// stream per RPC (which exhausted per-peer bidi-stream credit under
        /// write load and dropped heartbeats/votes → split-brain). Guarded by
        /// `client_mutex` (same as every other client.* access — A6f). Lazily
        /// opened on first send; closed+nulled on any write/open error and
        /// reopened on the next send.
        send_stream: ?*quic.QuicClientStream = null,
```

- [ ] **Step 2: Close `send_stream` in `PeerConnection.deinit`.**

Current:
```zig
        fn deinit(self: *PeerConnection) void {
            self.client.deinit();
            self.allocator.free(self.endpoint);
            self.allocator.destroy(self);
        }
```
New (finish+deinit the stream before the client, best-effort):
```zig
        fn deinit(self: *PeerConnection) void {
            if (self.send_stream) |s| {
                s.finish() catch {};
                s.deinit();
                self.send_stream = null;
            }
            self.client.deinit();
            self.allocator.free(self.endpoint);
            self.allocator.destroy(self);
        }
```

- [ ] **Step 3: Rewrite the stream-handling portion of `send()` to reuse `send_stream`.**

Replace the per-RPC `getStream()`/`writeRaftFrame()`/`finish()`/`s.deinit()` block (raft_consensus.zig:911–959) with: ensure the persistent stream exists, write the framed message, and DO NOT finish. Keep the `client_mutex` lock (A6f) and the `shouldEvictOnSendError` distinction. On a transient error, close+null the stream (so the next send reopens) but keep the connection; on an evict-worthy error, evict the connection.
```zig
        // 2026-06-08 raft multiplexed streams: reuse ONE long-lived stream per
        // peer instead of opening a fresh bidi stream per RPC. Lazily (re)open
        // it; never finish() per RPC (that would close it). On error, close+null
        // so the next send reopens — but only EVICT the connection for
        // genuinely-fatal errors (shouldEvictOnSendError), never for transient
        // backpressure (which per-RPC streams used to hit as OutOfStreams).
        if (conn.send_stream == null) {
            conn.send_stream = conn.client.getStream() catch |err| {
                if (shouldEvictOnSendError(err)) {
                    log.warn("raft transport open send_stream failed; evicting peer connection", &.{
                        Attr.string("error", @errorName(err)), Attr.uint("peer", peer.id),
                    });
                    self.evictPeerConnection(peer.id);
                } else {
                    log.debug("raft transport open send_stream backpressure; keeping connection", &.{
                        Attr.string("error", @errorName(err)), Attr.uint("peer", peer.id),
                    });
                }
                return err;
            };
        }
        const s = conn.send_stream.?;
        writeRaftFrame(self.allocator, s, from, term, msg) catch |err| {
            // The stream is now suspect — close+null it so the next send opens a
            // fresh one (the receiver's frame loop ends on EndOfStream and the
            // re-opened stream is re-accepted). Evict the whole connection only
            // for fatal errors.
            s.finish() catch {};
            s.deinit();
            conn.send_stream = null;
            if (shouldEvictOnSendError(err)) {
                log.warn("raft transport writeRaftFrame failed; evicting peer connection", &.{
                    Attr.string("error", @errorName(err)), Attr.uint("peer", peer.id),
                });
                self.evictPeerConnection(peer.id);
            } else {
                log.debug("raft transport writeRaftFrame backpressure; reopening stream next send", &.{
                    Attr.string("error", @errorName(err)), Attr.uint("peer", peer.id),
                });
            }
            return err;
        };
        // NOTE: no per-RPC finish()/deinit() — the stream stays open for the
        // next frame. The dedicated client_poll_thread (A6e) flushes the write
        // onto the wire.
```

IMPORTANT interaction (the implementer must handle): `evictPeerConnection` frees the `PeerConnection`. After eviction, `conn.send_stream` is gone with it — do not touch `conn` after calling `evictPeerConnection`. The `defer self.releasePeerConnection(conn)` at the top of `send` already handles the refcount. Verify `evictPeerConnection`/`PeerConnection.deinit` does not double-free the stream (deinit finish+deinits it; the write-error path also finish+deinits then nulls BEFORE evict — so set `conn.send_stream = null` BEFORE `evictPeerConnection`, as written above, so deinit sees null).

- [ ] **Step 4: Build.**

Run: `zig build 2>&1 | tail -5`
Expected: builds clean.

- [ ] **Step 5: Commit.**

```bash
git add src/distributed/raft_consensus.zig
git commit -m "fix(raft): send all frames over one long-lived multiplexed stream per peer"
```

---

### Task 3: Validate against the faithful repro + no-regression

**Files:** none (validation only)

- [ ] **Step 1: netns A5 gate (the regression that defines done).**

Run (AS USER; needs passwordless sudo for `ip netns`): `timeout 400 sudo tests/cluster/netns_cluster_replication_test.sh zig-out/bin/geode 2>&1 | tail -40`
Expected: A1–A4 PASS (as before) AND **A5 PASS** — `exactly 1 leader after load`, both followers `LoadFinal=1` (replication held under 6 writers/45s), `evict-on-error lines=0`. If A5 still splits brain, the single multiplexed stream may be head-of-line-blocked by large AppendEntries; escalate to the alternative design in the Notes (separate control vs data stream) rather than reverting.

- [ ] **Step 2: In-process raft tests still pass (election/propose-write/isolation).**

Run: `zig build test-cluster-3node-election test-cluster-propose-write 2>&1 | tail -8` (and any `test-raft-*` steps: `grep -oE "test-raft[a-z0-9-]*|test-cluster[a-z0-9-]*" build.zig | sort -u`)
Expected: all pass.

- [ ] **Step 3: No-regression on the transport-adjacent suites.**

Run: `GEODE_SKIP_SUBPROC_CLUSTER=1 CI=1 zig build test -Dtest-shard-total=4 -Dtest-shard-index=0 2>&1 | tail -5` (and shards 1–3)
Expected: same pass counts as `main` (the steady-state subprocess test skips under the env var; everything else green).

- [ ] **Step 4: Update the bug doc + commit.**

Append a dated "RE-RESOLVED 2026-06-08 — root cause #5 fixed via bounded multiplexed streams" section to `docs/bugs/2026-06-04-cluster-raft-no-stable-quorum-writes-time-out.md` recording the netns A5 PASS evidence. Commit:
```bash
git add docs/bugs/2026-06-04-cluster-raft-no-stable-quorum-writes-time-out.md
git commit -m "docs(bugs): raft root cause #5 fixed — multiplexed streams hold quorum under load"
```

- [ ] **Step 5: Merge to main + push (per the standing workflow).**

```bash
git branch -f main HEAD && git push origin main
```
Expected: the pre-push gate passes (subproc cluster skipped via the GEODE_SKIP_SUBPROC_CLUSTER export already on main).

---

## Notes / alternative design (only if Task 3 Step 1 shows residual head-of-line blocking)

If a single multiplexed stream lets a large AppendEntries-with-entries delay a heartbeat enough to still flap under load: split into **two** bounded long-lived streams per peer — a `control_stream` (heartbeats = empty AppendEntries, RequestVote/Response) and a `data_stream` (AppendEntries with entries). Route by message type in `send`; the receiver loop is unchanged (it reads frames off whichever stream). This keeps the control plane immune to data-plane backpressure. Prefer the single-stream design first (simpler; raft frames are << MTU per the `writeRaftFrame` comment, so HOL should be negligible).

## Rolling-restart / mixed-version note (not a blocker for this fix)

During a production rolling restart, a new (multiplexed) sender talking to an old (one-frame-then-FIN) receiver, or vice-versa, may mis-frame for the brief mixed-version window. Raft tolerates transient message loss (re-sends), so the cluster reconverges once both ends are upgraded. The netns/CI tests run a single version, so this does not affect the validation gate. Mention in the bug doc.
