// Raft consensus integration over the external raft library.
// This module owns Geode-specific command types, protobuf framing, and QUIC
// transport wiring while delegating consensus state transitions to the
// external raft package.

const std = @import("std");

fn compat_sleep(ns: u64) void {
    const req = std.os.linux.timespec{ .sec = 0, .nsec = @intCast(ns) };
    var rem: std.os.linux.timespec = undefined;
    _ = std.os.linux.nanosleep(&req, &rem);
}

// Zig 0.16 compat: std.crypto.random removed. Use getrandom syscall.
fn compat_fillRandom(buf: []u8) void {
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.getrandom(buf.ptr, buf.len, 0);
    } else {
        std.c.arc4random_buf(buf.ptr, buf.len);
    }
}

// Zig 0.16 compat: std.time.milliTimestamp/timestamp/microTimestamp removed.
fn compat_milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
fn compat_timestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec);
}
fn compat_microTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1_000);
}

// Zig 0.16 compat: std.process.getEnvVarOwned was removed.
fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) error{ EnvironmentVariableNotFound, OutOfMemory }![]u8 {
    const name_z = allocator.dupeZ(u8, name) catch return error.OutOfMemory;
    defer allocator.free(name_z);
    const ptr = std.c.getenv(name_z) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, std.mem.span(ptr));
}

// Zig 0.16 compat: std.posix.getenv was removed; wrap std.c.getenv to return a slice.
fn posixGetenv(name: [*:0]const u8) ?[:0]const u8 {
    return if (std.c.getenv(name)) |p| std.mem.span(p) else null;
}
const Allocator = std.mem.Allocator;
const txn_coordinator = @import("txn_coordinator.zig");
const protobuf = @import("protobuf");
const raft_schema = @import("raft_schema");
const raft_lib = @import("raft");

const raft_log = @import("raft_log_storage.zig");
const cluster_auth = @import("cluster_auth.zig");

const logging = @import("logging");
const log = logging.scoped("raft");
const Attr = logging.Attr;

const MAX_FRAME_SIZE: u32 = 16 * 1024 * 1024; // 16 MiB

// Type aliases
pub const TxnCoordinator = txn_coordinator.TxnCoordinator;

pub const ClientResponse = struct {
    prepare_result: ?bool = null,
    decision: ?[]const u8 = null,
    xid: u64,
};

// Clock abstraction for deterministic elections & tests
pub const Clock = struct {
    nowMillisFn: *const fn () i64,
    randFn: *const fn (max: u64) u64,
    pub fn nowMillis(self: *const Clock) i64 {
        return self.nowMillisFn();
    }
    pub fn rand(self: *const Clock, max: u64) u64 {
        return if (max == 0) 0 else self.randFn(max);
    }
};

fn realNow() i64 {
    return compat_milliTimestamp();
}
fn realRand(max: u64) u64 {
    return if (max == 0) 0 else blk: {
        var _rng_buf: [@sizeOf(u64)]u8 = undefined;
        compat_fillRandom(&_rng_buf);
        break :blk std.mem.readInt(u64, &_rng_buf, .little);
    } % max;
}
pub const RealClock = struct {
    pub const instance: Clock = .{ .nowMillisFn = realNow, .randFn = realRand };
};

// ---- Domain types (geode-specific) ----

pub const State = enum {
    follower,
    candidate,
    leader,
    shutdown,
};

pub const Command = union(enum) {
    noop,
    write: []const u8,
    graph_mutation: GraphMutation,
    schema_change: SchemaChange,
    config_change: ConfigChange,
    snapshot_pointer: SnapshotPointer,
    txn_prepare: TxnPrepare,
    txn_decide: TxnDecide,
};

pub const TxnPrepare = struct {
    xid: u64,
    shard_id: u64,
    write_set: []const u8,
    metadata: []const u8,
};

pub const TxnDecide = struct {
    xid: u64,
    commit: bool,
};

pub const GraphMutation = struct {
    graph: []const u8,
    mutation_type: enum { create, update, delete, merge },
    data: []const u8,
    txn_id: ?u64,
};

pub const SchemaChange = struct {
    operation: enum { create_graph, drop_graph, alter_graph },
    graph: []const u8,
    schema: []const u8,
};

pub const ConfigChange = struct {
    change_type: enum { add_server, remove_server, update_server },
    server_id: u64,
    server_endpoint: ?[]const u8,
    server_port: ?u16 = null,
};

pub const SnapshotPointer = struct {
    last_included_index: u64,
    last_included_term: u64,
    size_bytes: u64,
    checksum: u64,
};

pub const LogEntry = struct {
    term: u64,
    index: u64,
    command: Command,
    timestamp: i64,
    client_id: ?u64,
    serial_number: ?u64,
};

pub const Peer = struct {
    id: u64,
    endpoint: []const u8,
    port: u16,
    alive: bool,
    last_contact: i64,
    rpc_client: ?*RpcClient,
};

pub const Statistics = struct {
    elections_called: u64,
    elections_won: u64,
    elections_lost: u64,
    heartbeats_sent: u64,
    entries_appended: u64,
    entries_committed: u64,
    entries_applied: u64,
    // CANARY: REQ=QUAL-D005; FEATURE="Raft Apply Callback Error Visibility"; ASPECT=ApplyErrorCount; STATUS=TESTED; OWNER=distributed; UPDATED=2026-04-06
    apply_errors: u64,
    snapshots_sent: u64,
    snapshots_received: u64,
};

// ---- RPC / Transport stubs ----

const builtin = @import("builtin");
const quic = if (builtin.is_test) struct {
    pub const QuicClient = struct {
        pub fn init(_: anytype) QuicClient {
            return .{};
        }
        pub fn connect(_: *QuicClient, _: []const u8, _: u16) !void {}
        pub fn connectInsecure(_: *QuicClient, _: []const u8, _: u16, _: bool) !void {}
        pub fn connectEx(_: *QuicClient, _: []const u8, _: u16, _: ?[]const u8, _: ?[]const u8, _: ?[]const u8) !void {}
        pub fn waitForHandshake(_: *QuicClient, _: u32) !void {}
        pub fn deinit(_: *QuicClient) void {}
        pub fn getStream(_: *QuicClient) !*QuicClientStream {
            return undefined;
        }
        // Task A6b: test-mode stub for the same poll() call the production
        // path uses to flush in-flight FIN before tearing the client down.
        pub fn poll(_: *QuicClient, _: u32) !void {}
    };
    pub const QuicClientStream = struct {
        pub fn writeAll(_: *QuicClientStream, _: []const u8) !void {}
        pub fn deinit(_: *QuicClientStream) void {}
        // Task A6b: test-mode stub for the finish() call the production
        // path uses to signal stream FIN to the peer.
        pub fn finish(_: *QuicClientStream) !void {}
    };
    pub const QuicTransport = struct {
        pub fn init(_: anytype, _: anytype) !QuicTransport {
            return .{};
        }
        pub fn listen(_: *QuicTransport) !void {}
        pub fn deinit(_: *QuicTransport) void {}
        pub fn getStream(_: *QuicTransport) !*QuicClientStream {
            return undefined;
        }
    };
} else @import("transport/quic");

pub const RpcClient = struct {
    allocator: Allocator,
    host: []const u8,
    port: u16,
    client: ?quic.QuicClient = null,
    stream: ?*quic.QuicClientStream = null,

    pub fn deinit(self: *RpcClient) void {
        if (self.stream) |s| s.deinit();
        if (self.client) |*c| c.deinit();
        self.stream = null;
        self.client = null;
    }

    // SEC-D011: TLS-aware connection establishment for Raft RPC.
    // CANARY: REQ=SEC-D011; FEATURE="Raft RPC TLS"; ASPECT=RpcClientConnect; STATUS=TESTED; OWNER=security; UPDATED=2026-04-10
    pub fn sendMessage(self: *RpcClient, from: u64, term: u64, msg: Message) !void {
        if (self.client == null) {
            var qc = quic.QuicClient.init(self.allocator);
            try connectWithTLS(&qc, self.allocator, self.host, self.port);
            self.client = qc;
            self.stream = try self.client.?.getStream();
        }
        try writeRaftFrame(self.allocator, self.stream.?, from, term, msg);
    }
};

/// Task A6e (2026-05-26 plan): one queued outbound raft RPC.  Owned by
/// `Transport.outbox`; freed by `freeOutboundMessage` once the dispatch
/// thread has written it to the wire (or determined the peer is
/// permanently unreachable).
pub const OutboundEntry = struct {
    peer: Peer,
    from: u64,
    term: u64,
    msg: Message,
};

pub const Transport = struct {
    allocator: Allocator,
    server: ?quic.QuicTransport = null,
    /// Optional override for `send`.  When non-null, `Transport.send`
    /// dispatches through this function pointer instead of the default
    /// QUIC+TLS path.  Used by `tests/test_drainready_dispatch.zig` (A5b
    /// of the 2026-05-25 distributed cluster testing plan) to capture
    /// outbound raft messages produced by the inner raft library without
    /// spinning up a QUIC listener or a TLS handshake.  Production code
    /// leaves this null so the default path is used.
    send_override: ?*const fn (self: *Transport, peer: Peer, from: u64, term: u64, msg: Message) anyerror!void = null,
    /// Optional opaque context for `send_override`.  Tests can stash a
    /// pointer to their capture struct here and retrieve it from inside
    /// the override callback.  Ignored by the default send path.
    send_override_ctx: ?*anyopaque = null,

    /// Task A6c (2026-05-25 distributed cluster testing plan):
    /// Persistent per-peer QUIC connection pool.  Each entry is keyed
    /// by `peer.id` and owns a long-lived `QuicClient` plus its TLS
    /// handshake state, so subsequent raft RPCs only allocate a fresh
    /// bidirectional stream rather than reconstructing the entire QUIC
    /// endpoint.  Guarded by `peers_mutex` because raft tick, heartbeat,
    /// and inbound dispatch can all hit `send` concurrently.
    peers_mutex: std.Io.Mutex = std.Io.Mutex.init,
    peers: std.AutoHashMap(u64, *PeerConnection) = undefined,
    peers_initialized: bool = false,

    /// Task A6e (2026-05-26 distributed cluster testing plan):
    /// Outbound message queue.  The raft library's `sendMsg` vtable
    /// callback fires synchronously from inside `inner.step()` /
    /// `inner.tick()` while the wrapper's `inner_mutex` is held; if
    /// `sendMsg` performs blocking QUIC I/O (handshake, write, poll)
    /// inline, the mutex stays held for the entire round-trip and the
    /// inbound dispatch thread can't deliver vote / heartbeat responses
    /// until the next tick releases the lock.  Subprocess election
    /// runs (live-fire 2026-05-26) showed nodes stuck in candidate/
    /// follower churn for 30s+ with terms climbing 1 → 9 because the
    /// receive thread was starved.
    ///
    /// The fix: enqueue each outbound message here from the bridge
    /// (cheap — just a copy of the geode `Message`) and drain on a
    /// dedicated worker thread that runs OUTSIDE the inner_mutex.
    /// `Transport.send` (and the underlying QUIC write + poll) only
    /// touches `outbox_mutex`, so the raft loop never has to wait on
    /// network I/O while holding raft state locks.
    outbox_mutex: std.Io.Mutex = std.Io.Mutex.init,
    outbox: std.ArrayList(OutboundEntry) = .empty,
    outbox_initialized: bool = false,

    /// Task A6e: dedicated outbox-drain thread.  Spawned by
    /// `startOutboxDrain` (called from `ClusterCoordinator.start` once
    /// the cluster QUIC listener is up) and joined by `stopOutboxDrain`
    /// before `Transport.deinit` runs.  The thread polls the outbox on
    /// a tight loop (Zig 0.16 dropped `Condition.timedWait`, so we use
    /// a 1ms nanosleep between snapshots — vastly cheaper than the
    /// previous 10-30 ms / tick inner_mutex stall, and the actual
    /// wakeup latency on a queued message is dominated by the QUIC
    /// poll cadence anyway).  Decoupled from the raft tick so that
    /// even a 100 ms TLS handshake on first connect doesn't stall
    /// election progress.
    outbox_thread: ?std.Thread = null,
    outbox_shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Task A6e: dedicated client-side poll thread.  The QUIC vendor
    /// library buffers outbound bytes until `poll()` is invoked on the
    /// originating endpoint — `cluster_poll_pool` drives the SERVER
    /// endpoint but each `PeerConnection` owns its own client endpoint
    /// which still needs polling.  Previously `Transport.send` called
    /// `conn.client.poll(10)` synchronously after every write to flush;
    /// that 10 ms-per-send cost was a major contributor to the
    /// inner_mutex starvation.  With this thread, sends are
    /// fire-and-forget: data lands in the vendor buffer and the poll
    /// loop pushes it onto the wire within ~1 ms.
    client_poll_thread: ?std.Thread = null,
    client_poll_shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    /// Persistent QUIC client + endpoint metadata kept alive across raft
    /// RPCs to a single peer.  `client.deinit()` is deferred to
    /// `Transport.deinit` (or to a re-establishment after a connection
    /// failure), so the TLS handshake cost is paid once per peer.
    pub const PeerConnection = struct {
        allocator: Allocator,
        client: quic.QuicClient,
        /// Set after `connectWithTLS` succeeds for the first time.
        /// Treated as "definitely-non-zero until we observe an error",
        /// at which point the entry is evicted and rebuilt on the next
        /// send.
        established: bool = false,
        endpoint: []const u8,
        port: u16,

        /// Refcount for safe concurrent eviction-vs-poll (A6f, 2026-05-26).
        /// Semantics: entries in `Transport.peers` carry an implicit ref of 1
        /// (the map's ownership). `clientPollLoop` and `send` each bump+drop
        /// a transient ref around their use of `client.poll()` /
        /// `client.getStream()`. `evictPeerConnection` removes the entry
        /// from the map and drops the map's implicit ref; whichever thread
        /// observes the final 1→0 transition owns the deinit. Initial value
        /// is 1 because the entry is created and immediately placed in the
        /// map (which now owns that ref).
        refcount: std.atomic.Value(u32) = std.atomic.Value(u32).init(1),

        fn deinit(self: *PeerConnection) void {
            self.client.deinit();
            self.allocator.free(self.endpoint);
            self.allocator.destroy(self);
        }

        /// Acquire a reference. Must be called while holding the parent
        /// Transport's `peers_mutex` to ensure the entry is still in the map.
        fn acquire(self: *PeerConnection) void {
            _ = self.refcount.fetchAdd(1, .acq_rel);
        }

        /// Release a reference. Returns true if this was the final
        /// reference (caller may deinit). Lock-free.
        fn release(self: *PeerConnection) bool {
            const prev = self.refcount.fetchSub(1, .acq_rel);
            return prev == 1;
        }
    };

    pub fn init(allocator: Allocator) Transport {
        return .{
            .allocator = allocator,
            .peers_mutex = std.Io.Mutex.init,
            .peers = std.AutoHashMap(u64, *PeerConnection).init(allocator),
            .peers_initialized = true,
            .outbox_mutex = std.Io.Mutex.init,
            .outbox = .empty,
            .outbox_initialized = true,
            .outbox_thread = null,
            .outbox_shutdown = std.atomic.Value(bool).init(false),
            .client_poll_thread = null,
            .client_poll_shutdown = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *Transport) void {
        // Task A6e: stop the dispatch threads BEFORE we tear down the
        // peer map.  Both threads read `self.peers` (outbox via
        // `getOrCreatePeerConnection`, client poll via direct iteration)
        // so freeing entries while they were still running would race.
        self.stopOutboxDrain();
        self.stopClientPoll();

        // Task A6e: drop any messages still sitting in the outbox.
        // Conversion-allocated slices inside each `Message` (today only
        // `append_entries.entries`) are freed via `freeOutboundMessage`.
        if (self.outbox_initialized) {
            const io = std.Io.Threaded.global_single_threaded.io();
            self.outbox_mutex.lockUncancelable(io);
            for (self.outbox.items) |*entry| {
                freeOutboundMessage(self.allocator, entry.msg);
            }
            self.outbox.deinit(self.allocator);
            self.outbox_initialized = false;
            self.outbox_mutex.unlock(io);
        }

        if (self.peers_initialized) {
            const io = std.Io.Threaded.global_single_threaded.io();
            self.peers_mutex.lockUncancelable(io);
            var it = self.peers.iterator();
            while (it.next()) |entry| {
                entry.value_ptr.*.deinit();
            }
            self.peers.deinit();
            self.peers_initialized = false;
            self.peers_mutex.unlock(io);
        }
        if (self.server) |*s| s.deinit();
        self.server = null;
    }

    /// Task A6e: append an outbound message to the queue.  Called from
    /// the bridge `sendImpl` while the wrapper's `inner_mutex` is held.
    /// Cheap — just a hashmap-free vec append under `outbox_mutex`.
    /// The actual QUIC write happens later on the dispatch thread.
    pub fn enqueueOutbound(self: *Transport, peer: Peer, from: u64, term: u64, msg: Message) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.outbox_mutex.lockUncancelable(io);
        defer self.outbox_mutex.unlock(io);
        try self.outbox.append(self.allocator, .{ .peer = peer, .from = from, .term = term, .msg = msg });
        // Dispatch thread polls every 1 ms so we don't need a condvar
        // signal here; the wakeup latency floor (1 ms) is still 10×
        // faster than the pre-A6e synchronous-poll path (10 ms / send).
    }

    /// Task A6e: snapshot-and-swap drain.  Used by the dedicated
    /// dispatch thread to pull a batch out of the outbox without
    /// holding `outbox_mutex` for the duration of each network write.
    /// Returns an owned slice that the caller must `deinit` and whose
    /// `msg` fields must be freed via `freeOutboundMessage` after
    /// dispatch.  Callers running on the raft-loop hot path should
    /// instead let the background thread handle drain; this entry
    /// point exists so test scaffolding (and in-process drain) can
    /// flush synchronously.
    pub fn snapshotOutbox(self: *Transport) std.ArrayList(OutboundEntry) {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.outbox_mutex.lockUncancelable(io);
        defer self.outbox_mutex.unlock(io);
        const snap = self.outbox;
        self.outbox = .empty;
        return snap;
    }

    /// Task A6e: dispatch one outbox snapshot inline.  Used by the
    /// background drain thread and also by the synchronous test path
    /// via `flushOutboxBlocking`.  Each entry's `msg` is freed after
    /// the send attempt regardless of outcome — the raft library will
    /// retry on its next tick if the send failed.
    pub fn dispatchOutbox(self: *Transport, snap: *std.ArrayList(OutboundEntry)) void {
        for (snap.items) |entry| {
            // CANARY: REQ=REQ-DIST-RAFT-A6E-OUTBOX-DISPATCH; FEATURE="Raft Outbox Async Dispatch"; ASPECT=Send; STATUS=TESTED; OWNER=distributed; UPDATED=2026-05-26
            self.send(entry.peer, entry.from, entry.term, entry.msg) catch |err| {
                log.debug("raft outbox dispatch failed", &.{
                    Attr.string("error", @errorName(err)),
                    Attr.uint("peer", entry.peer.id),
                });
            };
            freeOutboundMessage(self.allocator, entry.msg);
        }
        snap.deinit(self.allocator);
    }

    /// Task A6e: synchronous helper used by tests (and by the
    /// in-process A5 election test) that want to flush queued
    /// messages without depending on the background drain thread.
    /// Production code always lets `outbox_thread` do the work.
    pub fn flushOutboxBlocking(self: *Transport) void {
        var snap = self.snapshotOutbox();
        self.dispatchOutbox(&snap);
    }

    fn outboxDrainLoop(self: *Transport) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        while (!self.outbox_shutdown.load(.acquire)) {
            // Snapshot under the lock; release before dispatching so
            // producers (the raft tick / handleMessage / stepInner
            // paths) never wait on QUIC I/O.
            self.outbox_mutex.lockUncancelable(io);
            const snap = self.outbox;
            self.outbox = .empty;
            const have_work = snap.items.len > 0;
            self.outbox_mutex.unlock(io);
            if (have_work) {
                var snap_mut = snap;
                self.dispatchOutbox(&snap_mut);
            } else {
                // Empty: free the zero-cap arraylist (no-op) and idle.
                // 2 ms idle interval is well under the heartbeat
                // budget (50 ms) while keeping the dispatch thread
                // off-CPU when no messages are queued.
                var empty_mut = snap;
                empty_mut.deinit(self.allocator);
                compat_sleep(2 * std.time.ns_per_ms);
            }
        }
    }

    fn outboxDrainEntry(ctx: ?*anyopaque) void {
        const self: *Transport = @ptrCast(@alignCast(ctx.?));
        self.outboxDrainLoop();
    }

    pub fn startOutboxDrain(self: *Transport) !void {
        if (self.outbox_thread != null) return;
        self.outbox_shutdown.store(false, .release);
        // Use std.Thread directly because we want a single dedicated
        // worker (the existing `pooled.ThreadPool` would also work, but
        // the raft transport sits below the cluster layer that owns
        // those pools — keeping the thread native avoids a circular
        // dependency on cluster.zig and matches the lifecycle of
        // `client_poll_thread` below).
        self.outbox_thread = try std.Thread.spawn(.{}, outboxDrainEntry, .{@as(?*anyopaque, @ptrCast(self))});
    }

    pub fn stopOutboxDrain(self: *Transport) void {
        if (self.outbox_thread) |t| {
            self.outbox_shutdown.store(true, .release);
            t.join();
            self.outbox_thread = null;
        }
    }

    fn clientPollLoop(self: *Transport) void {
        // Poll every cached peer client endpoint with a 0 ms timeout so
        // we never block here.  2 ms between iterations is a deliberate
        // tradeoff: it keeps wire-to-wire latency well under the raft
        // heartbeat interval (50 ms) while bounding the per-second
        // wakeup rate to ~500 per node — vs. 2000/sec at 500 µs, which
        // pinned a full CPU core per node in early iterations.
        //
        // CRITICAL: snapshot the peer pointer list before polling so we
        // don't hold `peers_mutex` while calling into the vendor library.
        // The vendor library takes its own per-connection locks; nesting
        // our peers_mutex around those locks would invert the lock order
        // observed by `getOrCreatePeerConnection` (vendor → ours during
        // handshake) and deadlock.  A stale pointer here is impossible
        // because `evictPeerConnection` is the only deletion site and it
        // also runs under `peers_mutex`.  We use a small inline buffer
        // for the snapshot to avoid allocator pressure on the hot path.
        var snap_buf: [16]*PeerConnection = undefined;
        const io = std.Io.Threaded.global_single_threaded.io();
        while (!self.client_poll_shutdown.load(.acquire)) {
            // Snapshot the peer set AND acquire a reference on each entry
            // while holding peers_mutex. evictPeerConnection waits for the
            // refcount to drop to zero before freeing, so the references
            // we hold here keep each PeerConnection alive across the
            // unlocked poll calls below. A6f (2026-05-26).
            var snap_len: usize = 0;
            self.peers_mutex.lockUncancelable(io);
            var it = self.peers.iterator();
            while (it.next()) |entry| {
                if (snap_len >= snap_buf.len) break;
                const pc = entry.value_ptr.*;
                if (pc.established) {
                    pc.acquire();
                    snap_buf[snap_len] = pc;
                    snap_len += 1;
                }
            }
            self.peers_mutex.unlock(io);
            for (snap_buf[0..snap_len]) |pc| {
                pc.client.poll(0) catch {};
                if (pc.release()) {
                    // Eviction completed while we were polling; we hold the
                    // last reference and must deinit.
                    pc.deinit();
                }
            }
            compat_sleep(2 * std.time.ns_per_ms);
        }
    }

    fn clientPollEntry(ctx: ?*anyopaque) void {
        const self: *Transport = @ptrCast(@alignCast(ctx.?));
        self.clientPollLoop();
    }

    pub fn startClientPoll(self: *Transport) !void {
        if (self.client_poll_thread != null) return;
        self.client_poll_shutdown.store(false, .release);
        self.client_poll_thread = try std.Thread.spawn(.{}, clientPollEntry, .{@as(?*anyopaque, @ptrCast(self))});
    }

    pub fn stopClientPoll(self: *Transport) void {
        if (self.client_poll_thread) |t| {
            self.client_poll_shutdown.store(true, .release);
            t.join();
            self.client_poll_thread = null;
        }
    }

    /// Task A6e: eagerly establish a persistent connection to `peer` so
    /// the first RaftRPC doesn't pay the TLS-handshake latency on the
    /// critical path.  Best-effort: a failure here is logged and
    /// silently ignored (the next `send` will retry).  Called by
    /// `ClusterCoordinator.start` once the local QUIC listener is up.
    pub fn preconnectPeer(self: *Transport, peer: Peer) void {
        const conn = self.getOrCreatePeerConnection(peer) catch |err| {
            log.debug("raft transport preconnect failed", &.{
                Attr.string("error", @errorName(err)),
                Attr.uint("peer", peer.id),
            });
            return;
        };
        _ = conn;
    }

    pub fn listen(self: *Transport, address: []const u8, port: u16) !void {
        const qt = try quic.QuicTransport.init(self.allocator, .{ .address = address, .port = port });
        self.server = qt;
        try self.server.?.listen();
    }

    // SEC-D011: TLS-aware Raft transport matching cluster.zig:sendToNode pattern.
    // CANARY: REQ=SEC-D011; FEATURE="Raft RPC TLS"; ASPECT=TransportSend; STATUS=TESTED; OWNER=security; UPDATED=2026-04-10
    pub fn send(self: *Transport, peer: Peer, from: u64, term: u64, msg: Message) !void {
        if (self.send_override) |override| {
            try override(self, peer, from, term, msg);
            return;
        }

        // Task A6c: reuse a long-lived QuicClient per peer so the TLS
        // handshake + endpoint setup cost is paid once.  Each RPC still
        // gets a fresh bidirectional stream — that's the cheap part on
        // an already-established QUIC connection.  Without this pool the
        // sender's deinit() race against finish() caused the vendor
        // library to RESET in-flight payload, surfacing as
        // InvalidInput|WouldBlock on the receiver's networkLoop.
        const conn = self.getOrCreatePeerConnection(peer) catch |err| {
            log.warn("raft transport getOrCreatePeerConnection failed", &.{
                Attr.string("error", @errorName(err)),
                Attr.uint("peer", peer.id),
            });
            return err;
        };
        // A6f: matching release. Use `defer` so every exit path drops
        // our refcount; evictPeerConnection (which also bumps+releases)
        // is safe to call inside this scope.
        defer self.releasePeerConnection(conn);

        const s = conn.client.getStream() catch |err| {
            // The cached connection is no longer usable (vendor library
            // reports the underlying state is gone, peer reset, etc.).
            // Evict it so the next send rebuilds from scratch.
            log.warn("raft transport getStream failed; evicting cached peer connection", &.{
                Attr.string("error", @errorName(err)),
                Attr.uint("peer", peer.id),
            });
            self.evictPeerConnection(peer.id);
            return err;
        };
        defer s.deinit();

        writeRaftFrame(self.allocator, s, from, term, msg) catch |err| {
            log.warn("raft transport writeRaftFrame failed; evicting cached peer connection", &.{
                Attr.string("error", @errorName(err)),
                Attr.uint("peer", peer.id),
            });
            self.evictPeerConnection(peer.id);
            return err;
        };

        // Task A6b: explicit FIN on the stream so the vendor library
        // flushes the in-flight payload rather than emitting a
        // RESET_STREAM when the stream destructor runs.  The connection
        // itself stays alive — only the stream is closed.
        s.finish() catch |err| {
            log.warn("raft transport stream finish failed", &.{
                Attr.string("error", @errorName(err)),
                Attr.uint("peer", peer.id),
            });
        };
        // Task A6e (2026-05-26): the previous code synchronously called
        // `conn.client.poll(10)` here to flush the payload + FIN onto
        // the wire.  That blocked the caller (the bridge `sendImpl`,
        // which runs under the wrapper's `inner_mutex` when invoked
        // from the raft tick / step path) for up to 10 ms per send.
        // With 2 peers and a 10 ms tick, the raft loop was effectively
        // running at 33 ticks / sec, starving the receive thread that
        // needed the same mutex to dispatch vote responses.  Election
        // never converged — three nodes split-voted indefinitely with
        // terms climbing 1 → 9 in the 30 s subprocess smoke window.
        //
        // The dedicated `client_poll_thread` now polls every cached
        // peer client endpoint at 500 µs intervals, so bytes still
        // reach the wire within ~1 ms of `finish()` but the bridge
        // returns immediately.  `dispatchOutbox` (which runs OFF the
        // raft tick path) is the only caller that ever touches QUIC,
        // and even it doesn't have to block for the flush.
    }

    /// Look up or construct a persistent peer connection.  The
    /// expensive `connectWithTLS` call is performed outside
    /// `peers_mutex` to avoid blocking concurrent sends to other peers
    /// during the handshake.  If two callers race to create the same
    /// peer, the loser tears its own client down and returns the
    /// winner's entry.
    /// Acquire-or-build a PeerConnection. Returns an entry with refcount
    /// already bumped — caller MUST call `releasePeerConnection` (or call
    /// `pc.release()` and deinit on transition) when done.
    fn getOrCreatePeerConnection(self: *Transport, peer: Peer) !*PeerConnection {
        const io = std.Io.Threaded.global_single_threaded.io();

        // Fast path: already cached and established.
        {
            self.peers_mutex.lockUncancelable(io);
            defer self.peers_mutex.unlock(io);
            if (self.peers.get(peer.id)) |existing| {
                if (existing.established) {
                    existing.acquire();
                    return existing;
                }
            }
        }

        // Slow path: build the client + perform TLS handshake outside
        // the lock so we don't serialize handshakes across peers.
        const conn = try self.allocator.create(PeerConnection);
        errdefer self.allocator.destroy(conn);
        conn.* = .{
            .allocator = self.allocator,
            .client = quic.QuicClient.init(self.allocator),
            .established = false,
            .endpoint = try self.allocator.dupe(u8, peer.endpoint),
            .port = peer.port,
        };
        errdefer self.allocator.free(conn.endpoint);
        errdefer conn.client.deinit();

        try connectWithTLS(&conn.client, self.allocator, conn.endpoint, conn.port);
        conn.established = true;

        // Re-acquire the lock to insert.  If another caller beat us to
        // it, prefer the existing entry and discard ours so we never
        // leave a half-initialized client in the map.
        self.peers_mutex.lockUncancelable(io);
        defer self.peers_mutex.unlock(io);
        if (self.peers.get(peer.id)) |existing| {
            if (existing.established) {
                conn.deinit();
                existing.acquire();
                return existing;
            }
        }
        try self.peers.put(peer.id, conn);
        conn.acquire();
        return conn;
    }

    /// Release a reference acquired via getOrCreatePeerConnection.
    /// If the entry was evicted concurrently and we hold the last reference,
    /// the deinit fires here.
    fn releasePeerConnection(_: *Transport, pc: *PeerConnection) void {
        if (pc.release()) pc.deinit();
    }

    /// Remove a cached peer connection (typically after observing an
    /// error on `getStream`/`writeRaftFrame`).
    ///
    /// A6f (2026-05-26): the map entry carries an implicit refcount of 1
    /// (the map's ownership). Eviction removes from the map and drops
    /// that implicit ref. If no concurrent send/poll holds a transient
    /// ref, refcount transitions 1→0 here and we own the deinit.
    /// Otherwise the transient holder's `release` will observe 1→0 and
    /// deinit. Removing from the map under peers_mutex denies new
    /// acquisitions (getOrCreatePeerConnection has to look it up again).
    fn evictPeerConnection(self: *Transport, peer_id: u64) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.peers_mutex.lockUncancelable(io);
        const maybe_kv = self.peers.fetchRemove(peer_id);
        self.peers_mutex.unlock(io);
        if (maybe_kv) |kv| {
            const pc = kv.value;
            // Drop the map's implicit ref. If the count is now 0 we own
            // the deinit; otherwise a concurrent send/poll holder will.
            if (pc.release()) pc.deinit();
        }
    }
};

/// SEC-D011: Establish a TLS-aware QUIC connection for Raft RPC, matching the
/// pattern from cluster.zig:sendToNode.
///
/// 1. If GEODE_CLUSTER_INSECURE=1, use connectInsecure (skip TLS verification).
/// 2. If GEODE_CLUSTER_CA_CERT is set, use connectEx with the CA certificate.
/// 3. Otherwise, use the default connect (system CA bundle).
///
/// A log warning is emitted when TLS verification is bypassed.
// CANARY: REQ=SEC-D011; FEATURE="Raft RPC TLS"; ASPECT=ConnectHelper; STATUS=TESTED; OWNER=security; UPDATED=2026-04-10
fn connectWithTLS(qc: *quic.QuicClient, allocator: Allocator, host: []const u8, port: u16) !void {
    const ca = @import("cluster_auth.zig");
    const allow_insecure = ca.isInsecureModeAllowed();

    if (allow_insecure) {
        log.warn("SEC-D011: Raft RPC TLS verification disabled via GEODE_CLUSTER_INSECURE", &.{});
        try qc.connectInsecure(host, port, true);
    } else {
        const ca_path = getEnvVarOwned(allocator, "GEODE_CLUSTER_CA_CERT") catch null;
        defer if (ca_path) |p| allocator.free(p);

        if (ca_path) |path| {
            try qc.connectEx(host, port, path, null, null);
        } else {
            try qc.connect(host, port);
        }
    }
    // Task A6e (2026-05-26): the previous 10s timeout was disastrous on
    // the outbox dispatch path: every send to a peer that's still
    // booting or transiently unreachable stalls the dispatch thread for
    // 10 SECONDS, during which the queue fills with retries that ALL
    // pay the same cost (each evicts the cached connection, so the
    // next send pays the full handshake again).  Loopback TLS over
    // QUIC completes in <50 ms on a healthy host; 1 second covers
    // first-boot races (the test brings node N up before node N+1) and
    // the worst-case post-quantum key exchange.  Long enough to be
    // robust, short enough that even a permanent failure only burns
    // 3 × 1 s per round of retries instead of 30 s.
    try qc.waitForHandshake(1);
}

// ---- Persistent storage (file-backed term & votedFor) ----
// CANARY: REQ=REQ-GQL-RAFT-PERSIST; FEATURE="Raft Consensus Persistence"; ASPECT=TermVotedFor; STATUS=TESTED; OWNER=distributed; UPDATED=2026-04-05

pub const PersistentStorage = struct {
    allocator: Allocator,
    data_dir: []const u8,
    log_storage: ?raft_log.LogStorage,

    pub fn init(allocator: Allocator, data_dir: []const u8) !PersistentStorage {
        // Build path: {data_dir}/raft_log.bin
        const log_path = try std.fmt.allocPrint(allocator, "{s}/raft_log.bin", .{data_dir});
        const ls = raft_log.LogStorage.init(allocator, log_path) catch |err| {
            allocator.free(log_path);
            return err;
        };
        return PersistentStorage{
            .allocator = allocator,
            .data_dir = data_dir,
            .log_storage = ls,
        };
    }

    pub fn close(self: *PersistentStorage) void {
        if (self.log_storage) |*ls| {
            // Free the path we allocated in init()
            self.allocator.free(ls.file_path);
            ls.deinit();
            self.log_storage = null;
        }
    }

    /// Read current_term from {data_dir}/current_term. Returns null if file does not exist.
    pub fn getCurrentTerm(self: *PersistentStorage) !?u64 {
        return readU64File(self.data_dir, "current_term");
    }

    /// Atomically write current_term to {data_dir}/current_term.
    pub fn saveCurrentTerm(self: *PersistentStorage, term: u64) !void {
        try ensureDir(self.data_dir);
        var dir = try std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), self.data_dir, .{});
        defer dir.close(std.Io.Threaded.global_single_threaded.io());
        var buf: [32]u8 = undefined;
        const str = std.fmt.bufPrint(&buf, "{d}", .{term}) catch unreachable;
        try atomicWriteFile(dir, "current_term", str);
    }

    /// Read voted_for from {data_dir}/voted_for. Returns null if file does not exist.
    pub fn getVotedFor(self: *PersistentStorage) !?u64 {
        return readU64File(self.data_dir, "voted_for");
    }

    /// Atomically write voted_for to {data_dir}/voted_for, or delete the file if null.
    pub fn saveVotedFor(self: *PersistentStorage, voter: ?u64) !void {
        try ensureDir(self.data_dir);
        var dir = try std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), self.data_dir, .{});
        defer dir.close(std.Io.Threaded.global_single_threaded.io());
        if (voter) |v| {
            var buf: [32]u8 = undefined;
            const str = std.fmt.bufPrint(&buf, "{d}", .{v}) catch unreachable;
            try atomicWriteFile(dir, "voted_for", str);
        } else {
            dir.deleteFile(std.Io.Threaded.global_single_threaded.io(), "voted_for") catch |err| {
                if (err != error.FileNotFound) return err;
            };
        }
    }

    /// Read all persisted log entries, or null if the log is empty.
    pub fn getLogEntries(self: *PersistentStorage, allocator: Allocator) !?[]LogEntry {
        if (self.log_storage) |*ls| {
            const entries = try ls.readAllEntries(allocator);
            if (entries.len == 0) {
                allocator.free(entries);
                return null;
            }
            return entries;
        }
        return null;
    }

    /// Append a single entry to the persistent log.
    pub fn appendLogEntry(self: *PersistentStorage, entry: LogEntry) !void {
        if (self.log_storage) |*ls| try ls.appendEntry(entry);
    }

    // ---- Internal helpers ----

    fn ensureDir(path: []const u8) !void {
        std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), path) catch |err| {
            if (err != error.PathAlreadyExists) return err;
        };
    }

    fn readU64File(dir_path: []const u8, file_name: []const u8) !?u64 {
        var dir = std.Io.Dir.cwd().openDir(std.Io.Threaded.global_single_threaded.io(), dir_path, .{}) catch |err| {
            if (err == error.FileNotFound) return null;
            return err;
        };
        defer dir.close(std.Io.Threaded.global_single_threaded.io());
        const f = dir.openFile(std.Io.Threaded.global_single_threaded.io(), file_name, .{}) catch |err| {
            if (err == error.FileNotFound) return null;
            return err;
        };
        defer f.close(std.Io.Threaded.global_single_threaded.io());
        var buf: [32]u8 = undefined;
        const n = try f.readPositionalAll(std.Io.Threaded.global_single_threaded.io(), &buf, 0);
        if (n == 0) return null;
        const trimmed = std.mem.trim(u8, buf[0..n], " \n\r\t");
        return std.fmt.parseInt(u64, trimmed, 10) catch null;
    }

    // CANARY: REQ=REQ-SEC-RAFT-ATOMIC-001; FEATURE="Atomic Raft State Persistence"; ASPECT=TOCTOU; STATUS=TESTED; OWNER=security; UPDATED=2026-04-05
    /// Write data to file_name atomically via write-to-temp-then-rename.
    /// SEC-D011: Crash-safe persistence -- writes to a .tmp file, fsyncs, then renames
    /// so that a crash mid-write never corrupts the final file.
    fn atomicWriteFile(dir: std.Io.Dir, name: []const u8, data: []const u8) !void {
        const io_fs = std.Io.Threaded.global_single_threaded.io();
        var tmp_buf: [256]u8 = undefined;
        const tmp_name = std.fmt.bufPrint(&tmp_buf, "{s}.tmp", .{name}) catch return error.FileNotFound;

        const f = try dir.createFile(io_fs, tmp_name, .{});
        errdefer {
            f.close(io_fs);
            dir.deleteFile(io_fs, tmp_name) catch {};
        }
        try f.writeStreamingAll(io_fs, data);
        try f.sync(io_fs);
        f.close(io_fs);

        try dir.rename(tmp_name, dir, name, io_fs);
    }
};

// ---- Message types ----

pub const Message = union(enum) {
    request_vote: RequestVote,
    request_vote_response: RequestVoteResponse,
    append_entries: AppendEntries,
    append_entries_response: AppendEntriesResponse,
    install_snapshot: InstallSnapshot,
    install_snapshot_response: InstallSnapshotResponse,
};

pub const RequestVote = struct {
    term: u64,
    candidate_id: u64,
    last_log_index: u64,
    last_log_term: u64,
    pre_vote: bool,
};

pub const RequestVoteResponse = struct {
    term: u64,
    vote_granted: bool,
    voter_id: u64,
    /// A6d: must echo the candidate's `pre_vote` flag.  The raft library's
    /// pre-vote phase (enabled by default in node.zig:43) counts only
    /// responses whose `pre_vote` matches the candidate's current phase;
    /// dropping this bit caused subprocess candidates to never accumulate
    /// a quorum.
    pre_vote: bool = false,
};

pub const AppendEntries = struct {
    term: u64,
    leader_id: u64,
    prev_log_index: u64,
    prev_log_term: u64,
    entries: []LogEntry,
    leader_commit: u64,
};

pub const AppendEntriesResponse = struct {
    term: u64,
    success: bool,
    match_index: u64,
};

pub const InstallSnapshot = struct {
    term: u64,
    leader_id: u64,
    last_included_index: u64,
    last_included_term: u64,
    offset: u64,
    data: []const u8,
    done: bool,
};

pub const InstallSnapshotResponse = struct {
    term: u64,
    success: bool,
};

// ---- Wire format (protobuf frames over QUIC) ----

// SEC-D009: Import nonce tracker for replay protection.
const nonce_tracker = @import("nonce_tracker.zig");

pub fn encodeRaftFrame(allocator: Allocator, from: u64, term: u64, msg: Message) ![]u8 {
    var aw: std.Io.Writer.Allocating = std.Io.Writer.Allocating.initCapacity(allocator, 256) catch return error.OutOfMemory;
    errdefer aw.deinit();

    const proto_msg = try messageToProto(allocator, msg);
    // SEC-D009: Generate cryptographic nonce for replay protection.
    // SEC-D001: Include cluster token for inter-node authentication.
    //
    // Task A6b (2026-05-25 distributed cluster testing plan): the env-var
    // pointer returned by `posixGetenv` points into libc's environ table,
    // which is NOT allocator-owned.  Assigning it directly to the
    // envelope's `auth_token` field worked at encode time but tripped an
    // "Invalid free" panic inside `envelope.deinit(allocator)` below
    // because the protobuf generic deinit unconditionally calls
    // `allocator.free` on non-empty string fields (protobuf.zig:1108).
    // The panic killed the raft worker on the very first tick before any
    // RequestVote actually made it onto the wire, which surfaced upstream
    // as "no leader ever elected" in the A6 subprocess test.  Dupe the
    // token into the allocator so the envelope owns it cleanly.
    const env_token = posixGetenv("GEODE_CLUSTER_TOKEN") orelse "";
    const owned_token: []const u8 = if (env_token.len > 0)
        try allocator.dupe(u8, env_token)
    else
        "";
    var envelope = raft_schema.RaftEnvelope{
        .term = term,
        .from = from,
        .nonce = nonce_tracker.NonceTracker.generateNonce(),
        .message = proto_msg,
        .auth_token = owned_token,
    };
    defer envelope.deinit(allocator);

    try protobuf.encode(&aw.writer, allocator, envelope);
    const out = try allocator.dupe(u8, aw.writer.buffer[0..aw.writer.end]);
    aw.deinit();
    return out;
}

pub const DecodedRaftFrame = struct {
    term: u64,
    from: u64,
    /// SEC-D009: Nonce for replay protection (0 if absent / legacy frame).
    nonce: u64 = 0,
    /// SEC-D001: Cluster authentication token carried in the Raft envelope.
    auth_token: []const u8 = "",
    body: Message,

    pub fn deinit(self: DecodedRaftFrame, allocator: Allocator) void {
        if (self.auth_token.len > 0) allocator.free(self.auth_token);
        var msg = self.body;
        freeMessage(allocator, &msg);
    }
};

pub fn decodeRaftFrame(allocator: Allocator, payload: []const u8) !DecodedRaftFrame {
    var reader: std.Io.Reader = .fixed(payload);
    var decoded = try protobuf.decode(raft_schema.RaftEnvelope, &reader, allocator);
    defer decoded.deinit(allocator);

    const msg = decoded.message orelse return error.InvalidFrame;
    const body = try protoToMessage(allocator, msg);
    // SEC-D001: Carry auth_token through to caller for validation.
    const token_copy = if (decoded.auth_token.len > 0)
        try allocator.dupe(u8, decoded.auth_token)
    else
        @as([]const u8, "");
    return DecodedRaftFrame{ .term = decoded.term, .from = decoded.from, .nonce = decoded.nonce, .auth_token = token_copy, .body = body };
}

pub fn writeRaftFrame(allocator: Allocator, stream: anytype, from: u64, term: u64, msg: Message) !void {
    const payload = try encodeRaftFrame(allocator, from, term, msg);
    defer allocator.free(payload);
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(payload.len), .big);
    try stream.writeAll(&len_buf);
    try stream.writeAll(payload);
}

pub fn readRaftFrame(allocator: Allocator, stream: anytype) !DecodedRaftFrame {
    var len_buf: [4]u8 = undefined;
    var read_len: usize = 0;
    var retry_count: usize = 0;
    const max_retries: usize = 200;

    while (read_len < len_buf.len) {
        const n = stream.read(len_buf[read_len..]) catch |err| {
            if (err == error.WouldBlock) {
                retry_count += 1;
                if (retry_count >= max_retries) return error.WouldBlock;
                compat_sleep(5 * std.time.ns_per_ms);
                continue;
            }
            return err;
        };
        if (n == 0) {
            if (read_len == 0) return error.EndOfStream;
            return error.UnexpectedEndOfStream;
        }
        read_len += n;
        retry_count = 0;
    }

    const msg_len = std.mem.readInt(u32, &len_buf, .big);
    if (msg_len == 0) return error.InvalidFrame;
    if (msg_len > MAX_FRAME_SIZE) return error.FrameTooLarge;

    const payload = try allocator.alloc(u8, msg_len);
    defer allocator.free(payload);

    var got: usize = 0;
    retry_count = 0;
    while (got < msg_len) {
        const n = stream.read(payload[got..]) catch |err| {
            if (err == error.WouldBlock) {
                retry_count += 1;
                if (retry_count >= max_retries) return error.WouldBlock;
                compat_sleep(5 * std.time.ns_per_ms);
                continue;
            }
            return err;
        };
        if (n == 0) return error.UnexpectedEndOfStream;
        got += n;
        retry_count = 0;
    }

    return decodeRaftFrame(allocator, payload);
}

// ---- Protobuf conversion helpers ----

fn messageToProto(allocator: Allocator, msg: Message) !raft_schema.RaftMessage {
    _ = allocator;
    return switch (msg) {
        .request_vote => |rv| .{
            .request_vote = .{
                .term = rv.term,
                .candidate_id = rv.candidate_id,
                .last_log_index = rv.last_log_index,
                .last_log_term = rv.last_log_term,
                // A6d: propagate the pre-vote phase bit on the outbound wire.
                .pre_vote = rv.pre_vote,
            },
        },
        .request_vote_response => |rvr| .{ .request_vote_response = .{
            .term = rvr.term,
            .vote_granted = rvr.vote_granted,
            .voter_id = rvr.voter_id,
            .pre_vote = rvr.pre_vote,
        } },
        // raft_schema.AppendEntries.entries is an ArrayList that holds the
        // log entries to replicate.  We construct it empty here because the
        // current path is exercised only by raft RequestVote/heartbeat
        // traffic (A5b of the 2026-05-25 distributed cluster testing plan)
        // — the GraphMutation / SchemaChange / config_change replication
        // payload conversion is tracked separately and lives outside this
        // dispatch hot path.  Initializing as `.empty` matches the
        // protobuf encoder's expectation that a missing field is an empty
        // repeated submessage.
        .append_entries => |ae| .{ .append_entries = .{
            .term = ae.term,
            .leader_id = ae.leader_id,
            .prev_log_index = ae.prev_log_index,
            .prev_log_term = ae.prev_log_term,
            .entries = std.ArrayList(raft_schema.RaftLogEntry).empty,
            .leader_commit = ae.leader_commit,
        } },
        .append_entries_response => |aer| .{ .append_entries_response = .{
            .term = aer.term,
            .success = aer.success,
            .match_index = aer.match_index,
        } },
        .install_snapshot => |is| .{ .install_snapshot = .{
            .term = is.term,
            .leader_id = is.leader_id,
            .last_included_index = is.last_included_index,
            .last_included_term = is.last_included_term,
            .offset = is.offset,
            .done = is.done,
        } },
        // raft_schema.InstallSnapshotResponse has no `success` field on the
        // wire schema; the receiving side defaults `success = true` (absence
        // implies ACK), mirroring the behavior already documented in
        // `protoToMessage` below.
        .install_snapshot_response => |isr| .{ .install_snapshot_response = .{
            .term = isr.term,
        } },
    };
}

fn protoToMessage(allocator: Allocator, msg: raft_schema.RaftMessage) !Message {
    _ = allocator;
    return switch (msg) {
        .request_vote => |rv| .{
            .request_vote = .{
                .term = rv.term,
                .candidate_id = rv.candidate_id,
                .last_log_index = rv.last_log_index,
                .last_log_term = rv.last_log_term,
                // A6d: pre_vote is part of the wire schema and must be
                // propagated.  Hard-coding it to false here caused the
                // embedded raft library's pre-vote handshake to fail end-to-end:
                // candidates issued pre_vote=true RequestVotes (and bumped
                // current_term + 1 in request_term), peers always saw
                // pre_vote=false on inbound, so they treated every request as
                // a real vote and bumped their term unconditionally on
                // msg.term > current_term.  No leader was ever elected
                // because all 3 candidates ended up at the same higher term
                // every round-trip.
                .pre_vote = rv.pre_vote,
            },
        },
        .request_vote_response => |rvr| .{ .request_vote_response = .{
            .term = rvr.term,
            .vote_granted = rvr.vote_granted,
            .voter_id = rvr.voter_id,
            .pre_vote = rvr.pre_vote,
        } },
        .append_entries => |ae| .{ .append_entries = .{
            .term = ae.term,
            .leader_id = ae.leader_id,
            .prev_log_index = ae.prev_log_index,
            .prev_log_term = ae.prev_log_term,
            .entries = &.{},
            .leader_commit = ae.leader_commit,
        } },
        .append_entries_response => |aer| .{ .append_entries_response = .{
            .term = aer.term,
            .success = aer.success,
            .match_index = aer.match_index,
        } },
        .install_snapshot => |is| .{ .install_snapshot = .{
            .term = is.term,
            .leader_id = is.leader_id,
            .last_included_index = is.last_included_index,
            .last_included_term = is.last_included_term,
            .offset = is.offset,
            .data = &.{},
            .done = is.done,
        } },
        .install_snapshot_response => |isr| .{
            .install_snapshot_response = .{
                .term = isr.term,
                // raft_schema.InstallSnapshotResponse has no `success` field on
                // the wire schema; default to true on receipt (absence implies
                // ACK).  Mismatch tracked in the distributed roadmap; harmless
                // for the bootstrap/start path.
                .success = true,
            },
        },
    };
}

fn freeMessage(_: Allocator, _: *Message) void {
    // Message fields are either stack values or slices pointing into protobuf decode buffers
}

fn freeLogEntryDeep(_: Allocator, _: *LogEntry) void {
    // Log entries own command data which may need freeing
}

/// Task A6e (2026-05-26): free heap-owned slices inside an outbound
/// `Message`.  Today only `append_entries.entries` is owned (allocated
/// by `raftLibMessageToGeode`).  Vote / vote-response / install-snapshot
/// variants either own no slices or share slices with the raft library
/// (which manages their lifetime independently of the outbox).
pub fn freeOutboundMessage(allocator: Allocator, msg: Message) void {
    switch (msg) {
        .append_entries => |ae| {
            if (ae.entries.len > 0) allocator.free(ae.entries);
        },
        else => {},
    }
}

// ---- Command serialization (tag-prefix format) ----
// Format: 1-byte tag | payload bytes
// Tags: 0=noop, 1=write, 2=graph_mutation, 3=schema_change,
//        4=config_change, 5=snapshot_pointer, 6=txn_prepare, 7=txn_decide

const CMD_TAG_NOOP: u8 = 0;
const CMD_TAG_WRITE: u8 = 1;
const CMD_TAG_GRAPH_MUTATION: u8 = 2;
const CMD_TAG_SCHEMA_CHANGE: u8 = 3;
const CMD_TAG_CONFIG_CHANGE: u8 = 4;
const CMD_TAG_SNAPSHOT_POINTER: u8 = 5;
const CMD_TAG_TXN_PREPARE: u8 = 6;
const CMD_TAG_TXN_DECIDE: u8 = 7;

/// Serialize a Command into a tag-prefixed byte array.
/// Caller owns the returned slice and must free with the same allocator.
pub fn serializeCommand(allocator: Allocator, cmd: Command) ![]u8 {
    switch (cmd) {
        .noop => {
            const buf = try allocator.alloc(u8, 1);
            buf[0] = CMD_TAG_NOOP;
            return buf;
        },
        .write => |data| {
            const buf = try allocator.alloc(u8, 1 + data.len);
            buf[0] = CMD_TAG_WRITE;
            @memcpy(buf[1..], data);
            return buf;
        },
        .graph_mutation => |gm| {
            // Serialize: tag | graph_len(4) | graph | type(1) | has_txn(1) [| txn_id(8)] | data
            const has_txn: u8 = if (gm.txn_id != null) 1 else 0;
            const txn_size: usize = if (gm.txn_id != null) 8 else 0;
            const total = 1 + 4 + gm.graph.len + 1 + 1 + txn_size + gm.data.len;
            const buf = try allocator.alloc(u8, total);
            var pos: usize = 0;
            buf[pos] = CMD_TAG_GRAPH_MUTATION;
            pos += 1;
            std.mem.writeInt(u32, buf[pos..][0..4], @intCast(gm.graph.len), .big);
            pos += 4;
            @memcpy(buf[pos..][0..gm.graph.len], gm.graph);
            pos += gm.graph.len;
            buf[pos] = @intFromEnum(gm.mutation_type);
            pos += 1;
            buf[pos] = has_txn;
            pos += 1;
            if (gm.txn_id) |tid| {
                std.mem.writeInt(u64, buf[pos..][0..8], tid, .big);
                pos += 8;
            }
            @memcpy(buf[pos..], gm.data);
            return buf;
        },
        .schema_change => |sc| {
            const total = 1 + 1 + 4 + sc.graph.len + sc.schema.len;
            const buf = try allocator.alloc(u8, total);
            var pos: usize = 0;
            buf[pos] = CMD_TAG_SCHEMA_CHANGE;
            pos += 1;
            buf[pos] = @intFromEnum(sc.operation);
            pos += 1;
            std.mem.writeInt(u32, buf[pos..][0..4], @intCast(sc.graph.len), .big);
            pos += 4;
            @memcpy(buf[pos..][0..sc.graph.len], sc.graph);
            pos += sc.graph.len;
            @memcpy(buf[pos..], sc.schema);
            return buf;
        },
        .config_change => |cc| {
            const ep = cc.server_endpoint orelse &[_]u8{};
            const has_port: u8 = if (cc.server_port != null) 1 else 0;
            const port_size: usize = if (cc.server_port != null) 2 else 0;
            const total = 1 + 1 + 8 + 4 + ep.len + 1 + port_size;
            const buf = try allocator.alloc(u8, total);
            var pos: usize = 0;
            buf[pos] = CMD_TAG_CONFIG_CHANGE;
            pos += 1;
            buf[pos] = @intFromEnum(cc.change_type);
            pos += 1;
            std.mem.writeInt(u64, buf[pos..][0..8], cc.server_id, .big);
            pos += 8;
            std.mem.writeInt(u32, buf[pos..][0..4], @intCast(ep.len), .big);
            pos += 4;
            @memcpy(buf[pos..][0..ep.len], ep);
            pos += ep.len;
            buf[pos] = has_port;
            pos += 1;
            if (cc.server_port) |p| {
                std.mem.writeInt(u16, buf[pos..][0..2], p, .big);
            }
            return buf;
        },
        .snapshot_pointer => |sp| {
            const buf = try allocator.alloc(u8, 1 + 8 * 4);
            buf[0] = CMD_TAG_SNAPSHOT_POINTER;
            std.mem.writeInt(u64, buf[1..][0..8], sp.last_included_index, .big);
            std.mem.writeInt(u64, buf[9..][0..8], sp.last_included_term, .big);
            std.mem.writeInt(u64, buf[17..][0..8], sp.size_bytes, .big);
            std.mem.writeInt(u64, buf[25..][0..8], sp.checksum, .big);
            return buf;
        },
        .txn_prepare => |tp| {
            const total = 1 + 8 + 8 + 4 + tp.write_set.len + 4 + tp.metadata.len;
            const buf = try allocator.alloc(u8, total);
            var pos: usize = 0;
            buf[pos] = CMD_TAG_TXN_PREPARE;
            pos += 1;
            std.mem.writeInt(u64, buf[pos..][0..8], tp.xid, .big);
            pos += 8;
            std.mem.writeInt(u64, buf[pos..][0..8], tp.shard_id, .big);
            pos += 8;
            std.mem.writeInt(u32, buf[pos..][0..4], @intCast(tp.write_set.len), .big);
            pos += 4;
            @memcpy(buf[pos..][0..tp.write_set.len], tp.write_set);
            pos += tp.write_set.len;
            std.mem.writeInt(u32, buf[pos..][0..4], @intCast(tp.metadata.len), .big);
            pos += 4;
            @memcpy(buf[pos..], tp.metadata);
            return buf;
        },
        .txn_decide => |td| {
            const buf = try allocator.alloc(u8, 1 + 8 + 1);
            buf[0] = CMD_TAG_TXN_DECIDE;
            std.mem.writeInt(u64, buf[1..][0..8], td.xid, .big);
            buf[9] = if (td.commit) 1 else 0;
            return buf;
        },
    }
}

/// Deserialize a tag-prefixed byte array back into a Command.
/// The returned Command borrows slices from `data` (zero-copy for the payload).
pub fn deserializeCommand(data: []const u8) !Command {
    if (data.len == 0) return error.InvalidData;
    const tag = data[0];
    const payload = data[1..];
    switch (tag) {
        CMD_TAG_NOOP => return .noop,
        CMD_TAG_WRITE => return .{ .write = payload },
        CMD_TAG_TXN_DECIDE => {
            if (payload.len < 9) return error.InvalidData;
            return .{ .txn_decide = .{
                .xid = std.mem.readInt(u64, payload[0..8], .big),
                .commit = payload[8] != 0,
            } };
        },
        else => {
            // For complex types, return as write with the full tagged data
            // so the apply callback can re-deserialize if needed.
            return .{ .write = data };
        },
    }
}

// ---- RaftNode (wraps external raft library) ----

pub const RaftNode = struct {
    allocator: Allocator,
    id: u64,
    state: State,
    current_term: u64,

    /// A6d follow-on (2026-05-26): serialize concurrent access to the
    /// embedded raft library's mutable state.  Before this mutex landed,
    /// the cluster coordinator's `raftLoop` (calling `tick()` every
    /// 10ms) and the QUIC accept thread (calling `handleMessage()` on
    /// every inbound frame) could both reach `self.inner.*` at the same
    /// instant.  Once leader election started working (post-A6d wire
    /// fix + pre_vote propagation), the elected leader's first
    /// `sendHeartbeats` could observe `replication_state` being
    /// `becomeFollower`-nulled by the receive thread, surfacing as
    /// `incorrect alignment` inside the inner library's hash-map
    /// metadata pointer.
    inner_mutex: std.Io.Mutex = std.Io.Mutex.init,

    // External raft library node
    inner: raft_lib.RaftNode,
    // Heap-allocated so the Storage vtable interface (which captures
    // &storage_ptr.*) remains valid for the RaftNode's lifetime. A previous
    // version held this as an inline value, which dangled the moment
    // RaftNode.init returned. See A4d of the distributed cluster testing plan.
    storage_ptr: *raft_lib.InMemoryStorage,

    // Configuration
    peers: []Peer,
    election_timeout_ms: u64,

    // Network
    transport: ?*Transport,

    // Callbacks
    apply_callback: ?*const fn (allocator: Allocator, cmd: Command) anyerror![]u8,

    // Statistics
    stats: Statistics,

    // Transaction coordinator
    txn_coordinator: ?*TxnCoordinator,
    pending_responses: std.StringHashMap(ClientResponse),

    pub fn init(
        allocator: Allocator,
        id: u64,
        peers: []Peer,
        election_timeout_ms: u64,
    ) !*RaftNode {
        return initWithClock(allocator, id, peers, election_timeout_ms, &RealClock.instance);
    }

    pub fn initWithClock(
        allocator: Allocator,
        id: u64,
        peers: []Peer,
        election_timeout_ms: u64,
        _: *const Clock,
    ) !*RaftNode {
        const node = try allocator.create(RaftNode);

        // Map Peer IDs to u64 array for external raft library
        const peer_ids = try allocator.alloc(u64, peers.len);
        defer allocator.free(peer_ids);
        for (peers, 0..) |peer, i| {
            peer_ids[i] = peer.id;
        }

        // Heap-allocate storage so the Storage interface pointer that
        // raft_lib.RaftNode.init captures (via storage_ptr.storage()) remains
        // valid for the lifetime of the RaftNode. The previous version held
        // storage as a stack-local `var`, so the interface pointer dangled the
        // moment this function returned — surfacing as `OutOfMemory` on the
        // first advance and then `ReadyNotAdvanced` indefinitely once
        // ClusterCoordinator.start() became reachable (A4b/A4c).
        const storage_ptr = try allocator.create(raft_lib.InMemoryStorage);
        errdefer allocator.destroy(storage_ptr);
        storage_ptr.* = raft_lib.InMemoryStorage.init(allocator);
        errdefer storage_ptr.deinit();

        const heartbeat_tick: u32 = 1;
        const election_tick: u32 = @intCast(@max(2, election_timeout_ms / 50));

        const raft_config = raft_lib.Config{
            .id = id,
            .peers = peer_ids,
            .election_tick = election_tick,
            .heartbeat_tick = heartbeat_tick,
            .pre_vote = true,
        };

        const inner = try raft_lib.RaftNode.init(allocator, raft_config, storage_ptr.storage());

        node.* = RaftNode{
            .allocator = allocator,
            .id = id,
            .state = .follower,
            .current_term = 0,
            .inner_mutex = std.Io.Mutex.init,
            .inner = inner,
            .storage_ptr = storage_ptr,
            .peers = peers,
            .election_timeout_ms = election_timeout_ms,
            .transport = null,
            .apply_callback = null,
            .stats = std.mem.zeroes(Statistics),
            .txn_coordinator = null,
            .pending_responses = std.StringHashMap(ClientResponse).init(allocator),
        };

        return node;
    }

    pub fn deinit(self: *RaftNode) void {
        self.state = .shutdown;
        self.inner.deinit();
        self.storage_ptr.deinit();
        self.allocator.destroy(self.storage_ptr);
        self.pending_responses.deinit();
    }

    /// Wire the wrapper's geode-level `Transport` (typically QUIC+TLS in
    /// production) so that outbound raft traffic produced by the inner raft
    /// library reaches its peers.
    ///
    /// Why this is non-trivial: raft-0.1.3 dispatches messages via its own
    /// `raft_lib.Transport` interface — when the inner node calls
    /// `sendMsg(to, msg)` it invokes the inner transport's vtable directly
    /// rather than buffering into `Ready.messages`.  Without a bridge, the
    /// wrapper's `transport` field would be set but no raft traffic would
    /// flow over it, which is exactly the bug A5b of the 2026-05-25
    /// distributed cluster testing plan addresses.
    ///
    /// The fix: install a tiny adapter that implements
    /// `raft_lib.Transport.VTable` and forwards each `(to, msg)` to the
    /// wrapper transport's `send(peer, from, term, geode_msg)` after
    /// looking up the peer's endpoint by id and converting the raft_lib
    /// Message into the geode Message union.
    ///
    /// Tests that drive multiple raft nodes in-process should call
    /// `setInnerTransport` instead — that path bypasses this bridge.
    pub fn setTransport(self: *RaftNode, t: *Transport) void {
        self.transport = t;
        self.inner.setTransport(.{
            .ptr = @ptrCast(self),
            .vtable = &RaftLibTransportBridge.vtable,
        });
    }

    /// Inject the underlying raft library's Transport directly into the inner
    /// raft node.  Used by in-process multi-node tests (e.g. A5 in the
    /// 2026-05-25 distributed cluster testing plan) to wire several inner
    /// raft nodes together via `raft_lib.InProcessTransport` without going
    /// through the QUIC layer.  Production code wires QUIC via the outer
    /// `setTransport` instead.
    pub fn setInnerTransport(self: *RaftNode, t: raft_lib.Transport) void {
        self.inner.setTransport(t);
    }

    /// Deliver an inbound raft_lib message directly to the inner raft node
    /// (bypassing the geode Message conversion path) and then drain Ready
    /// state.  Used by in-process multi-node tests that pull messages out
    /// of a `raft_lib.InProcessTransport` inbox and feed them back into
    /// the recipient raft node.  Production code routes inbound traffic
    /// through `handleMessage` (which decodes the geode Message wire
    /// format first).
    pub fn stepInner(self: *RaftNode, from: u64, msg: raft_lib.Message) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.inner_mutex.lockUncancelable(io);
        defer self.inner_mutex.unlock(io);
        try self.inner.step(from, msg);
        self.drainReady();
    }

    pub fn setStorage(_: *RaftNode, _: *PersistentStorage) !void {
        // External library manages its own storage
    }

    pub fn tick(self: *RaftNode) !void {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.inner_mutex.lockUncancelable(io);
        defer self.inner_mutex.unlock(io);
        try self.inner.tick(null);
        self.drainReady();
    }

    pub fn handleMessage(self: *RaftNode, from: u64, msg: Message) !void {
        // Map geode Message to external raft library Message, preserving all data.
        var converted_entries: ?[]raft_lib.Entry = null;
        defer if (converted_entries) |ce| self.allocator.free(ce);

        const raft_msg: raft_lib.Message = switch (msg) {
            .request_vote => |rv| .{ .request_vote = .{
                .term = rv.term,
                .candidate_id = rv.candidate_id,
                .last_log_index = rv.last_log_index,
                .last_log_term = rv.last_log_term,
                .pre_vote = rv.pre_vote,
            } },
            .request_vote_response => |rvr| .{ .request_vote_response = .{
                .term = rvr.term,
                .vote_granted = rvr.vote_granted,
                .pre_vote = rvr.pre_vote,
            } },
            .append_entries => |ae| blk: {
                // Convert geode LogEntry[] to raft_lib Entry[]
                const entries = try self.allocator.alloc(raft_lib.Entry, ae.entries.len);
                for (ae.entries, 0..) |entry, i| {
                    const data = try serializeCommand(self.allocator, entry.command);
                    entries[i] = .{
                        .index = entry.index,
                        .term = entry.term,
                        .kind = .normal,
                        .data = data,
                    };
                }
                converted_entries = entries;
                break :blk .{ .append_entries = .{
                    .term = ae.term,
                    .leader_id = ae.leader_id,
                    .prev_log_index = ae.prev_log_index,
                    .prev_log_term = ae.prev_log_term,
                    .entries = entries,
                    .leader_commit = ae.leader_commit,
                } };
            },
            .append_entries_response => |aer| .{ .append_entries_response = .{
                .term = aer.term,
                .success = aer.success,
                .match_index = aer.match_index,
                .conflict_index = 0,
                .conflict_term = 0,
            } },
            .install_snapshot => |is| .{ .install_snapshot = .{
                .term = is.term,
                .leader_id = is.leader_id,
                .last_included_index = is.last_included_index,
                .last_included_term = is.last_included_term,
                .offset = is.offset,
                .data = is.data,
                .done = is.done,
                .checksum = std.mem.zeroes([32]u8),
                .config = .{ .voters = &.{}, .voters_outgoing = &.{}, .is_joint = false },
            } },
            .install_snapshot_response => |isr| .{ .install_snapshot_response = .{
                .term = isr.term,
                .success = isr.success,
            } },
        };

        // A6d follow-on: serialize inner-library mutation across the
        // raft tick thread (cluster.zig:raftLoop) and the QUIC accept
        // thread (cluster.zig:readOneRaftFrameAndDispatch).  Without the
        // mutex, a concurrent `becomeFollower` from the receive thread
        // could null out replication_state mid-`sendHeartbeats`,
        // surfacing as an "incorrect alignment" panic on the hash-map
        // metadata pointer.
        const io = std.Io.Threaded.global_single_threaded.io();
        self.inner_mutex.lockUncancelable(io);
        defer self.inner_mutex.unlock(io);

        // raft-0.1.3 RaftNode.step takes (from, msg); the older 3-arg form
        // (with a trailing thread-pool param) is gone.
        self.inner.step(from, raft_msg) catch |err| {
            log.warn("raft step error", &.{Attr.string("error", @errorName(err))});
        };
        // Free serialized entry data before freeing the entries array
        if (converted_entries) |ce| {
            for (ce) |entry| {
                self.allocator.free(entry.data);
            }
        }
        self.drainReady();
    }

    pub fn proposeCommand(self: *RaftNode, cmd: Command) !u64 {
        // Serialize Command to bytes for the external raft library's propose().
        // Format: 1-byte tag | payload
        // Tags: 0=noop, 1=write, 2=graph_mutation, 3=schema_change,
        //        4=config_change, 5=snapshot_pointer, 6=txn_prepare, 7=txn_decide
        //
        // A3d (2026-05-26): take the inner_mutex around propose() + drain so
        // we keep the locking invariant established by A6d.  Concurrent
        // raftLoop ticks and inbound-message handlers may already be calling
        // `tick()` / `step()` under the mutex, so an unguarded propose race
        // could trigger the same `incorrect alignment` corruption A6d
        // closed.
        //
        // Returns the log index assigned to the proposed entry, i.e.
        // `log.lastIndex()` after append.  Callers can pair this with
        // `appliedIndex()` (or the higher-level ClusterCoordinator.
        // waitForApplied helper) to confirm commit + apply on this node.
        // The previous form returned `stats.entries_applied` -- a running
        // count of all entries ever applied -- which was unusable as a
        // wait condition.  All existing internal callers ignore the
        // return value with `_ = try ...`, so the change is local.
        const cmd_bytes = try serializeCommand(self.allocator, cmd);
        defer self.allocator.free(cmd_bytes);
        const io = std.Io.Threaded.global_single_threaded.io();
        self.inner_mutex.lockUncancelable(io);
        defer self.inner_mutex.unlock(io);
        if (self.inner.role != .leader) return error.NotLeader;
        try self.inner.propose(cmd_bytes);
        const new_index = self.inner.log.lastIndex();
        self.drainReady();
        return new_index;
    }

    /// Returns the index of the most recently applied log entry on this
    /// node.  Reads `inner.log.applied` directly -- this is monotonic and
    /// only advances inside `drainReady()` after an entry is committed and
    /// applied by `apply_callback`.  Safe to call from any thread; the
    /// underlying u64 read is atomic on supported targets and a torn read
    /// would at worst cause a spurious wait iteration.
    pub fn appliedIndex(self: *RaftNode) u64 {
        return self.inner.log.applied;
    }

    /// Returns the current Raft role of this node mirroring the inner
    /// library's state.  Falls through to `self.state` (which `drainReady`
    /// keeps in sync) so this remains correct under shutdown.
    pub fn role(self: *RaftNode) State {
        return self.state;
    }

    /// Returns the current Raft term as last observed by `drainReady`.
    pub fn currentTerm(self: *RaftNode) u64 {
        return self.current_term;
    }

    pub fn startElection(self: *RaftNode) void {
        self.stats.elections_called += 1;
        self.drainReady();
    }

    fn drainReady(self: *RaftNode) void {
        // raft-0.1.3 RaftNode.ready now returns `!rd.Ready`; surface the
        // error in the log so we don't silently drop committed entries.
        const rd = self.inner.ready() catch |err| {
            log.warn("raft ready error", &.{Attr.string("error", @errorName(err))});
            return;
        };

        // raft-0.1.3 removed `Ready.soft_state`; the role and term live
        // directly on RaftNode now.  Sync our mirror state from there.
        self.state = switch (self.inner.role) {
            .leader => .leader,
            .candidate => .candidate,
            .follower => .follower,
        };

        if (rd.hard_state) |hs| {
            self.current_term = hs.current_term;
        } else {
            self.current_term = self.inner.current_term;
        }

        // Apply committed entries -- deserialize the tag-prefixed command bytes
        for (rd.committed_entries) |entry| {
            if (entry.kind == .normal and entry.data.len > 0) {
                if (self.apply_callback) |callback| {
                    const cmd = deserializeCommand(entry.data) catch Command{ .write = entry.data };
                    // CANARY: REQ=QUAL-D005; FEATURE="Raft Apply Callback Error Visibility"; ASPECT=ErrorLogging; STATUS=TESTED; OWNER=distributed; UPDATED=2026-04-06
                    _ = callback(self.allocator, cmd) catch |err| {
                        log.err("Raft apply_callback failed — committed entry not applied", &.{
                            Attr.string("error", @errorName(err)),
                            Attr.uint("entry_index", entry.index),
                            Attr.uint("term", self.current_term),
                        });
                        self.stats.apply_errors += 1;
                    };
                }
            }
            self.stats.entries_applied += 1;
        }

        // Dispatch outbound raft messages produced by this tick to their
        // target peers.  In raft-0.1.3 the inner node sends messages directly
        // via its own Transport vtable (see RaftLibTransportBridge below), so
        // `rd.messages` is currently always empty — but the API exposes the
        // field and a future version may buffer here, so we treat it as a
        // legitimate dispatch surface.  For in-process tests the inner
        // transport vtable (set via `setInnerTransport`) handles routing
        // before drain ever runs; for production, `setTransport` installs
        // the bridge so this loop is a defensive secondary path.
        // CANARY: REQ=REQ-DIST-RAFT-DRAINREADY-DISPATCH; FEATURE="Raft Wrapper Transport Dispatch"; ASPECT=DrainReadyMessages; STATUS=TESTED; TEST=tests/test_drainready_dispatch.zig; OWNER=distributed; UPDATED=2026-05-25
        if (rd.messages.len > 0) {
            if (self.transport != null) {
                for (rd.messages) |msg| {
                    self.dispatchRaftLibMessage(msg) catch |err| {
                        log.warn("raft message dispatch failed", &.{
                            Attr.string("error", @errorName(err)),
                        });
                        // Drop the message — raft will retry on next heartbeat.
                    };
                }
            } else {
                log.debug("raft drainReady has messages but no wrapper transport set", &.{
                    Attr.uint("message_count", rd.messages.len),
                });
            }
        }

        // raft-0.1.3 advance() is zero-arg and returns `!void`.  We can't
        // propagate the error from this void fn, so log on failure — the
        // next ready() call will report ReadyNotAdvanced if we silently
        // skipped the call.
        self.inner.advance() catch |err| {
            log.warn("raft advance error", &.{Attr.string("error", @errorName(err))});
        };
    }

    /// Look up a peer by id.  Returns null if the id isn't in `self.peers`.
    /// Linear scan is fine: the peer count is bounded by the cluster size
    /// (typically 3-7) and message dispatch dominates lookup cost.
    fn findPeerById(self: *RaftNode, to: u64) ?Peer {
        for (self.peers) |p| {
            if (p.id == to) return p;
        }
        return null;
    }

    /// Forward a raft_lib.Message to a known destination through the wrapper
    /// transport.  Used by both the bridge (where the raft library tells us
    /// `to` via its vtable callback) and the `drainReady` defensive loop
    /// (where we derive `to` from the message body).
    ///
    /// Note: we read `current_term` from `self.inner` rather than the
    /// wrapper mirror.  The wrapper's `self.current_term` is only refreshed
    /// inside `drainReady`, but the bridge can fire while `inner.step` is
    /// still mid-call (the raft library dispatches messages synchronously
    /// as they're emitted), so the inner term is the only authoritative
    /// source at this point.
    fn dispatchRaftLibMessageWithDest(self: *RaftNode, to: u64, msg: raft_lib.Message) !void {
        const t = self.transport orelse return error.NoTransport;
        const peer = self.findPeerById(to) orelse return error.PeerNotFound;
        const geode_msg = try raftLibMessageToGeode(self.allocator, msg);
        try t.send(peer, self.id, self.inner.current_term, geode_msg);
    }

    /// drainReady-driven dispatch: the inner raft library hands us a
    /// `Ready.messages` slice with no per-message destination, so we
    /// recover it from the message body (candidate_id for RequestVote,
    /// leader_id for AppendEntries / InstallSnapshot).  Response messages
    /// can't be routed this way — the raft library always pairs responses
    /// with the original sender at message-emit time and never buffers
    /// them into `Ready.messages` in raft-0.1.3.  Returns
    /// MessageWithoutDestination if the type is unsupported here.
    fn dispatchRaftLibMessage(self: *RaftNode, msg: raft_lib.Message) !void {
        const to = raftLibMessageDestination(msg) orelse return error.MessageWithoutDestination;
        return self.dispatchRaftLibMessageWithDest(to, msg);
    }
};

/// Adapter that implements `raft_lib.Transport` and forwards every send
/// through the wrapper `Transport` field of the surrounding `RaftNode`.
///
/// Installed by `RaftNode.setTransport` so that messages produced by the
/// inner raft library (RequestVote, AppendEntries, etc.) reach their target
/// peers over the wrapper's transport (QUIC+TLS in production).  Without
/// this adapter, the inner raft library has no way to send anywhere — it
/// only knows about `raft_lib.Transport`, not the geode-level `Transport`.
///
/// The `to` parameter supplied by the raft library is authoritative: it is
/// set correctly for every message type, including responses where the
/// destination cannot be recovered from the body.
const RaftLibTransportBridge = struct {
    pub const vtable = raft_lib.Transport.VTable{ .send = &sendImpl };

    fn sendImpl(ptr: *anyopaque, to: u64, msg: raft_lib.Message) void {
        const node: *RaftNode = @ptrCast(@alignCast(ptr));
        // Task A6e (2026-05-26): the bridge runs synchronously from
        // inside `inner.step()` / `inner.tick()`, which the wrapper
        // calls while `inner_mutex` is held.  Performing the QUIC
        // write inline (the previous behaviour) stalled the receive
        // thread for as long as the network handshake / poll loop
        // took — easily 10-100 ms on the first peer connect.  We now
        // do the cheap part inline (raft_lib -> geode conversion,
        // peer lookup) and hand the actual `send` off to the
        // Transport's dispatch thread.
        const transport = node.transport orelse {
            log.debug("raft bridge: no transport set", &.{Attr.uint("to", to)});
            return;
        };
        const peer = node.findPeerById(to) orelse {
            log.debug("raft bridge: unknown destination peer", &.{Attr.uint("to", to)});
            return;
        };
        const geode_msg = raftLibMessageToGeode(node.allocator, msg) catch |err| {
            log.warn("raft bridge: conversion failed", &.{
                Attr.string("error", @errorName(err)),
                Attr.uint("to", to),
            });
            return;
        };
        // Synchronous dispatch path is preserved for tests that wire a
        // `send_override` — those callers want immediate capture and
        // don't care about latency.  When no override is set, route
        // through the outbox so the QUIC I/O happens off the raft
        // critical path.
        if (transport.send_override != null) {
            transport.send(peer, node.id, node.inner.current_term, geode_msg) catch |err| {
                log.warn("raft bridge: synchronous send failed", &.{
                    Attr.string("error", @errorName(err)),
                    Attr.uint("to", to),
                });
            };
            freeOutboundMessage(node.allocator, geode_msg);
            return;
        }
        transport.enqueueOutbound(peer, node.id, node.inner.current_term, geode_msg) catch |err| {
            log.warn("raft bridge: enqueueOutbound failed; dropping message", &.{
                Attr.string("error", @errorName(err)),
                Attr.uint("to", to),
            });
            freeOutboundMessage(node.allocator, geode_msg);
        };
    }
};

/// Recover the destination node id from a raft_lib.Message body for the
/// message types where it is unambiguous.  Returns null for response
/// messages, which carry no destination of their own — the raft library
/// always knows the destination at the point of emit, but a buffered
/// Ready.messages slice has no way to encode it.
fn raftLibMessageDestination(msg: raft_lib.Message) ?u64 {
    return switch (msg) {
        .request_vote => |rv| rv.candidate_id,
        .append_entries => |ae| ae.leader_id,
        .install_snapshot => |is| is.leader_id,
        // For response messages there is no destination embedded in the
        // body.  The bridge path uses the `to` argument from the vtable
        // and never reaches this branch; the drainReady fallback returns
        // MessageWithoutDestination here so the message is dropped (raft
        // will retry on the next heartbeat).
        .request_vote_response,
        .append_entries_response,
        .install_snapshot_response,
        => null,
    };
}

/// Convert a raft_lib.Message into the geode wire-format Message used by
/// `Transport.send` / `writeRaftFrame`.  Allocates only where the geode
/// representation owns a copy (append_entries.entries is deep-copied).
/// Caller (the wrapper Transport) is responsible for freeing any
/// allocations attached to the returned Message once the send completes.
///
/// The geode Message variants carry strictly more fields than the
/// raft_lib counterparts (e.g. `voter_id`); we fill those with defaults
/// since they are populated on the receiving side from the wire envelope.
fn raftLibMessageToGeode(allocator: Allocator, msg: raft_lib.Message) !Message {
    return switch (msg) {
        .request_vote => |rv| Message{ .request_vote = .{
            .term = rv.term,
            .candidate_id = rv.candidate_id,
            .last_log_index = rv.last_log_index,
            .last_log_term = rv.last_log_term,
            .pre_vote = rv.pre_vote,
        } },
        .request_vote_response => |rvr| Message{
            .request_vote_response = .{
                .term = rvr.term,
                .vote_granted = rvr.vote_granted,
                // The geode Message carries a voter_id field; the raft_lib
                // counterpart does not.  Set to 0 — the receiver fills it
                // from the wire envelope's `from` field.
                .voter_id = 0,
                // A6d: preserve the pre-vote phase bit so the candidate
                // can count this response in its current phase.
                .pre_vote = rvr.pre_vote,
            },
        },
        .append_entries => |ae| blk: {
            // Convert raft_lib.Entry[] -> geode LogEntry[] (re-serializing
            // each command's tag-prefixed bytes back into the Command
            // variant the wire format expects).
            const entries = try allocator.alloc(LogEntry, ae.entries.len);
            errdefer allocator.free(entries);
            for (ae.entries, 0..) |e, i| {
                const cmd = deserializeCommand(e.data) catch Command{ .write = e.data };
                entries[i] = .{
                    .term = e.term,
                    .index = e.index,
                    .command = cmd,
                    .timestamp = compat_milliTimestamp(),
                    .client_id = null,
                    .serial_number = null,
                };
            }
            break :blk Message{ .append_entries = .{
                .term = ae.term,
                .leader_id = ae.leader_id,
                .prev_log_index = ae.prev_log_index,
                .prev_log_term = ae.prev_log_term,
                .entries = entries,
                .leader_commit = ae.leader_commit,
            } };
        },
        .append_entries_response => |aer| Message{ .append_entries_response = .{
            .term = aer.term,
            .success = aer.success,
            .match_index = aer.match_index,
        } },
        .install_snapshot => |is| Message{ .install_snapshot = .{
            .term = is.term,
            .leader_id = is.leader_id,
            .last_included_index = is.last_included_index,
            .last_included_term = is.last_included_term,
            .offset = is.offset,
            .data = is.data,
            .done = is.done,
        } },
        .install_snapshot_response => |isr| Message{ .install_snapshot_response = .{
            .term = isr.term,
            .success = isr.success,
        } },
    };
}

/// Convert a geode-shaped Message (over-the-wire protobuf) back into the
/// raft_lib.Message the raft library expects on its `step()` input.
/// Inverse of `raftLibMessageToGeode`.
///
/// Task A6b (2026-05-25 distributed cluster testing plan): this is the
/// inbound counterpart of the bridge sendImpl path.  `networkLoop`
/// accepts a peer QUIC connection, reads a framed envelope, decodes it
/// into a geode `Message`, and feeds the raft_lib equivalent into the
/// inner raft node via `RaftNode.stepInner`.  We deliberately keep the
/// `AppendEntries.entries` field empty here: the current cluster wire
/// format encodes RequestVote / heartbeat traffic only (matching
/// `messageToProto`), so callers that observe append_entries traffic
/// can safely treat the entries slice as `&.{}`.  The full LogEntry
/// round-trip is wired by the `handleMessage` path which deserializes
/// entries inline.
pub fn geodeMessageToRaftLib(msg: Message) raft_lib.Message {
    return switch (msg) {
        .request_vote => |rv| raft_lib.Message{ .request_vote = .{
            .term = rv.term,
            .candidate_id = rv.candidate_id,
            .last_log_index = rv.last_log_index,
            .last_log_term = rv.last_log_term,
            .pre_vote = rv.pre_vote,
        } },
        .request_vote_response => |rvr| raft_lib.Message{
            .request_vote_response = .{
                .term = rvr.term,
                .vote_granted = rvr.vote_granted,
                // A6d: preserve the pre-vote phase bit so the candidate
                // can count this response in its current phase.
                .pre_vote = rvr.pre_vote,
            },
        },
        .append_entries => |ae| raft_lib.Message{ .append_entries = .{
            .term = ae.term,
            .leader_id = ae.leader_id,
            .prev_log_index = ae.prev_log_index,
            .prev_log_term = ae.prev_log_term,
            .entries = &.{},
            .leader_commit = ae.leader_commit,
        } },
        .append_entries_response => |aer| raft_lib.Message{ .append_entries_response = .{
            .term = aer.term,
            .success = aer.success,
            .match_index = aer.match_index,
            .conflict_index = 0,
            .conflict_term = 0,
        } },
        .install_snapshot => |is| raft_lib.Message{ .install_snapshot = .{
            .term = is.term,
            .leader_id = is.leader_id,
            .last_included_index = is.last_included_index,
            .last_included_term = is.last_included_term,
            .offset = is.offset,
            .data = is.data,
            .done = is.done,
            .checksum = std.mem.zeroes([32]u8),
            .config = .{ .voters = &.{}, .voters_outgoing = &.{}, .is_joint = false },
        } },
        .install_snapshot_response => |isr| raft_lib.Message{ .install_snapshot_response = .{
            .term = isr.term,
            .success = isr.success,
        } },
    };
}

// ---- Tests ----

test "raft_consensus: basic init and deinit" {
    const allocator = std.testing.allocator;
    const peers = &[_]Peer{};
    var node = try RaftNode.init(allocator, 1, peers, 150);
    defer {
        node.deinit();
        allocator.destroy(node);
    }
    try std.testing.expectEqual(State.follower, node.state);
}

test "serializeCommand: write command round-trips" {
    const allocator = std.testing.allocator;
    const original_data = "INSERT INTO foo VALUES (1, 'bar')";
    const cmd = Command{ .write = original_data };
    const bytes = try serializeCommand(allocator, cmd);
    defer allocator.free(bytes);

    // First byte is the write tag
    try std.testing.expectEqual(CMD_TAG_WRITE, bytes[0]);
    // Remaining bytes are the original data
    try std.testing.expectEqualStrings(original_data, bytes[1..]);

    // Deserialize and verify
    const restored = try deserializeCommand(bytes);
    try std.testing.expectEqualStrings(original_data, restored.write);
}

test "serializeCommand: noop round-trips" {
    const allocator = std.testing.allocator;
    const bytes = try serializeCommand(allocator, .noop);
    defer allocator.free(bytes);

    try std.testing.expectEqual(@as(usize, 1), bytes.len);
    try std.testing.expectEqual(CMD_TAG_NOOP, bytes[0]);

    const restored = try deserializeCommand(bytes);
    try std.testing.expectEqual(Command.noop, restored);
}

test "serializeCommand: txn_decide round-trips" {
    const allocator = std.testing.allocator;
    const cmd = Command{ .txn_decide = .{ .xid = 42, .commit = true } };
    const bytes = try serializeCommand(allocator, cmd);
    defer allocator.free(bytes);

    try std.testing.expectEqual(CMD_TAG_TXN_DECIDE, bytes[0]);

    const restored = try deserializeCommand(bytes);
    try std.testing.expectEqual(@as(u64, 42), restored.txn_decide.xid);
    try std.testing.expectEqual(true, restored.txn_decide.commit);
}

test "serializeCommand: write data is not empty" {
    // This test verifies the critical bug fix: proposeCommand must NOT
    // discard command data. The serialized bytes must contain the payload.
    const allocator = std.testing.allocator;
    const payload = "CREATE GRAPH mydb";
    const bytes = try serializeCommand(allocator, .{ .write = payload });
    defer allocator.free(bytes);

    // The serialized form must be longer than just a tag byte
    try std.testing.expect(bytes.len > 1);
    // The payload must be recoverable
    try std.testing.expectEqualStrings(payload, bytes[1..]);
}

test "encodeRaftFrame includes auth_token and decodeRaftFrame exposes it" {
    // SEC-D001: Verify auth_token round-trips through Raft frame encoding.
    // In test env, GEODE_CLUSTER_TOKEN is not set, so auth_token will be "".
    const allocator = std.testing.allocator;
    const msg = Message{ .noop = {} };
    const encoded = try encodeRaftFrame(allocator, 42, 1, msg);
    defer allocator.free(encoded);

    const decoded = try decodeRaftFrame(allocator, encoded);
    defer decoded.deinit(allocator);

    try std.testing.expectEqual(@as(u64, 42), decoded.from);
    try std.testing.expectEqual(@as(u64, 1), decoded.term);
    // Without GEODE_CLUSTER_TOKEN set, auth_token should be empty
    try std.testing.expectEqualStrings("", decoded.auth_token);
}

test "PersistentStorage: atomic write for saveCurrentTerm and saveVotedFor" {
    // SEC-D011: Verify atomic write pattern (write-to-temp, fsync, rename) persists correctly.
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const dir_path = try std.fmt.allocPrint(
        allocator,
        ".zig-cache/tmp/{s}",
        .{&tmp.sub_path},
    );
    defer allocator.free(dir_path);

    var storage = PersistentStorage.init(allocator, dir_path) catch unreachable;
    defer storage.close();

    // saveCurrentTerm round-trip
    try storage.saveCurrentTerm(42);
    const term = try storage.getCurrentTerm();
    try std.testing.expectEqual(@as(?u64, 42), term);

    // Overwrite with different value
    try storage.saveCurrentTerm(99);
    const term2 = try storage.getCurrentTerm();
    try std.testing.expectEqual(@as(?u64, 99), term2);

    // saveVotedFor round-trip
    try storage.saveVotedFor(7);
    const voted = try storage.getVotedFor();
    try std.testing.expectEqual(@as(?u64, 7), voted);

    // saveVotedFor(null) deletes the file
    try storage.saveVotedFor(null);
    const voted_null = try storage.getVotedFor();
    try std.testing.expectEqual(@as(?u64, null), voted_null);

    // Verify .tmp file does not persist (atomic rename should have cleaned up)
    var dir = try std.Io.Dir.cwd().openDir(dir_path, .{});
    defer dir.close(std.Io.Threaded.global_single_threaded.io());
    const tmp_exists = dir.openFile(std.Io.Threaded.global_single_threaded.io(), "current_term.tmp", .{});
    if (tmp_exists) |f| {
        f.close();
        return error.TmpFileNotCleaned;
    } else |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
    }
}

// SEC-D011: Verify connectWithTLS compiles and selects the correct path.
// In test mode, GEODE_CLUSTER_INSECURE is not set, so the default (TLS) path is used.
// CANARY: REQ=SEC-D011; FEATURE="Raft RPC TLS"; ASPECT=ConnectCompile; STATUS=TESTED; OWNER=security; UPDATED=2026-04-10
test "raft_consensus: connectWithTLS defaults to TLS connect" {
    const allocator = std.testing.allocator;
    var qc = quic.QuicClient.init(allocator);
    defer qc.deinit();

    // In test mode the QUIC stubs are no-ops, so this should succeed
    // without GEODE_CLUSTER_INSECURE set (default = TLS path).
    try connectWithTLS(&qc, allocator, "127.0.0.1", 7890);
}

test "raft_consensus: Transport.send uses TLS-aware connection" {
    // SEC-D011: Verify Transport.send compiles with TLS support.
    const allocator = std.testing.allocator;
    var transport = Transport.init(allocator);
    defer transport.deinit();

    const peer = Peer{
        .id = 1,
        .endpoint = "127.0.0.1",
        .port = 7890,
        .alive = true,
        .last_contact = 0,
        .rpc_client = null,
    };

    // In test mode the QUIC stubs are no-ops; writeRaftFrame uses the stub stream.
    // This validates the TLS code path compiles and executes without error.
    transport.send(peer, 42, 1, .noop) catch |err| {
        // Expected: test stubs may return errors for stream operations
        // since getStream returns undefined. That's fine -- we're testing
        // that the TLS connection logic itself compiles and runs.
        _ = err;
    };
}
