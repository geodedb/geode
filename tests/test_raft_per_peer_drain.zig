// CANARY: REQ=REQ-DIST-RAFT-A2-PER-PEER-DRAIN; FEATURE="Raft per-peer non-blocking outbox drain"; ASPECT=PeerIsolation; STATUS=TESTED; TEST=tests/test_raft_per_peer_drain.zig; OWNER=distributed; UPDATED=2026-06-08
//
// Task A2 (2026-06-08 raft-transport-stream-starvation plan):
// per-peer non-blocking outbox drain isolation test.
//
// k8s root cause #5: the single serial `outboxDrainLoop` drains every peer's
// queued raft message through `send` on ONE thread.  `send` can block up to
// ~1s in `getOrCreatePeerConnection → waitForHandshake` for a slow/unreachable
// peer.  At election time that serial blocking stalls votes/heartbeats to ALL
// peers → no leader is elected → the cluster can't converge.
//
// This test proves the fix: with one drain thread PER peer, a blocking send to
// a slow peer (peer 3, whose override sleeps ~1s) is isolated to that peer's
// thread and never delays the delivery of peers 1 and 2's messages.  Using the
// `send_override` hook (no QUIC / TLS) we enqueue one message per peer {1,2,3}
// and assert peers 1 and 2's overrides fire within ~150ms — NOT serialized
// behind peer 3's 1s sleep.
//
// On the OLD single-serial drain (with peer 3 enqueued first) peers 1 and 2
// would only fire after peer 3's 1s sleep completes, so this test FAILS there.

const std = @import("std");
const builtin = @import("builtin");
const geode = @import("geode");

const raft_consensus = geode.distributed.raft_consensus;
const Transport = raft_consensus.Transport;
const Peer = raft_consensus.Peer;
const Message = raft_consensus.Message;

const SLOW_PEER_ID: u64 = 3;
const FAST_DEADLINE_MS: u64 = 150;

/// Zig 0.16 dropped `std.time.Timer`; read the monotonic clock directly.
fn monotonicNs() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = if (comptime @import("builtin").os.tag == .linux)
        std.os.linux.clock_gettime(.MONOTONIC, &ts)
    else
        std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

/// Records, per peer, the elapsed time (ns) from a shared start instant to the
/// moment the peer's `send_override` fired.  Peer 3's override additionally
/// sleeps ~1s to model a blocking handshake to a slow/unreachable peer.
const Recorder = struct {
    mutex: std.Io.Mutex = std.Io.Mutex.init,
    start_ns: u64 = 0,
    fired_ns: [4]?u64 = .{ null, null, null, null }, // indexed by peer.id (1..3)

    fn captureSend(
        t: *Transport,
        peer: Peer,
        from: u64,
        term: u64,
        msg: Message,
    ) anyerror!void {
        _ = from;
        _ = term;
        _ = msg;
        const ctx_ptr = t.send_override_ctx orelse return error.MissingCtx;
        const self: *Recorder = @ptrCast(@alignCast(ctx_ptr));

        const io = std.Io.Threaded.global_single_threaded.io();
        // Record the firing time BEFORE the slow-peer sleep so the recorded
        // instant reflects when this peer's drain thread reached `send` (a
        // per-peer thread is not delayed by another peer's in-progress sleep).
        const now = monotonicNs();
        self.mutex.lockUncancelable(io);
        const elapsed = now -% self.start_ns;
        if (peer.id < self.fired_ns.len) self.fired_ns[@intCast(peer.id)] = elapsed;
        self.mutex.unlock(io);

        // Model a slow/unreachable peer: this send blocks ~1s (mirrors a
        // stalled QUIC handshake).  On a per-peer drain this only ties up
        // peer 3's own thread.
        if (peer.id == SLOW_PEER_ID) {
            const req = std.os.linux.timespec{ .sec = 1, .nsec = 0 };
            std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(@as(i96, req.sec) * std.time.ns_per_s + req.nsec), .awake) catch {};
        }
    }

    fn firedWithin(self: *Recorder, peer_id: u64, deadline_ms: u64) bool {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.mutex.lockUncancelable(io);
        defer self.mutex.unlock(io);
        const v = self.fired_ns[@intCast(peer_id)] orelse return false;
        return v <= deadline_ms * std.time.ns_per_ms;
    }
};

fn mkPeer(id: u64) Peer {
    return .{
        .id = id,
        .endpoint = "127.0.0.1",
        .port = @intCast(21000 + id),
        .last_contact = 0,
    };
}

test "raft per-peer drain: a slow peer's blocking send does not delay other peers" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;

    var rec = Recorder{};

    var transport = Transport.init(a);
    defer transport.deinit();
    transport.send_override = Recorder.captureSend;
    transport.send_override_ctx = @ptrCast(&rec);

    // Start the drain machinery (per-peer threads spawned lazily on enqueue).
    try transport.startOutboxDrain();

    // Reset the shared clock right before enqueuing so the recorded elapsed
    // times measure dispatch latency, not transport setup.
    rec.start_ns = monotonicNs();

    // Enqueue the SLOW peer FIRST.  On the old single-serial drain this peer's
    // 1s sleep would block the drain thread before it ever reaches peers 1/2.
    const vote_resp = Message{ .request_vote_response = .{
        .term = 7,
        .vote_granted = true,
        .voter_id = 1,
        .pre_vote = false,
    } };
    try transport.enqueueOutbound(mkPeer(SLOW_PEER_ID), 1, 7, vote_resp);
    try transport.enqueueOutbound(mkPeer(1), 1, 7, vote_resp);
    try transport.enqueueOutbound(mkPeer(2), 1, 7, vote_resp);

    // Poll until peers 1 and 2 have fired or the deadline elapses.  With
    // per-peer drains they fire within ~2ms (the idle interval); the old serial
    // drain would not fire them until peer 3's 1s sleep completes.
    var waited_ns: u64 = 0;
    const poll_ns: u64 = 2 * std.time.ns_per_ms;
    while (waited_ns < FAST_DEADLINE_MS * std.time.ns_per_ms) {
        if (rec.firedWithin(1, FAST_DEADLINE_MS) and rec.firedWithin(2, FAST_DEADLINE_MS)) break;
        const req = std.os.linux.timespec{ .sec = 0, .nsec = @intCast(poll_ns) };
        std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(@as(i96, req.sec) * std.time.ns_per_s + req.nsec), .awake) catch {};
        waited_ns += poll_ns;
    }

    // CRITICAL ASSERTION: peers 1 and 2 must NOT be serialized behind peer 3.
    try std.testing.expect(rec.firedWithin(1, FAST_DEADLINE_MS));
    try std.testing.expect(rec.firedWithin(2, FAST_DEADLINE_MS));

    // Tear down: stopOutboxDrain joins peer 3's thread (after its 1s sleep
    // finishes), so this also exercises shutdown joining an in-progress send.
    transport.stopOutboxDrain();
}
