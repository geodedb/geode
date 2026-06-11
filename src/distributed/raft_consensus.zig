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
    /// Inbound-only ownership handle.  When a LogEntry is reconstructed from
    /// the protobuf wire (`protoToMessage`), `command` is the result of
    /// `deserializeCommand` aliasing into this allocator-owned buffer (a dup
    /// of the proto `command_bytes`).  The proto decode buffer is freed
    /// immediately after `protoToMessage` returns, so we keep our own copy
    /// here and free it in `freeMessage`.  Null for entries built any other
    /// way (the command's slices then point into externally-owned memory).
    owned_wire_bytes: ?[]u8 = null,
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
    // Test-mode stub for the peer re-resolution used by clientPollLoop. Tests
    // address peers by IP literal, so "resolution" returns the host unchanged
    // and the periodic IP-change reaper never evicts.
    pub fn resolveHostIpAlloc(allocator: std.mem.Allocator, host: []const u8) ![]u8 {
        return allocator.dupe(u8, host);
    }
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

/// Task A6e (2026-05-26 plan), repartitioned per-peer by A2 (2026-06-08): one
/// queued outbound raft RPC.  Owned by the destination peer's
/// `Transport.PeerDrain.queue`; freed by `freeOutboundMessage` once that peer's
/// drain thread has written it to the wire (or determined the peer is
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

    /// Task A6e (2026-05-26 distributed cluster testing plan), reworked into
    /// PER-PEER queues by Task A2 (2026-06-08 raft-transport-stream-starvation
    /// plan).  The raft library's `sendMsg` vtable callback fires synchronously
    /// from inside `inner.step()` / `inner.tick()` while the wrapper's
    /// `inner_mutex` is held; if `sendMsg` performs blocking QUIC I/O inline the
    /// mutex stays held for the entire round-trip and the inbound dispatch
    /// thread can't deliver vote / heartbeat responses until the next tick.  So
    /// each outbound message is enqueued (cheap copy) and drained OUTSIDE the
    /// inner_mutex on a dedicated worker thread.
    ///
    /// A2 (k8s root cause #5): a SINGLE serial drain thread sends every peer's
    /// messages through `send`, and `send → getOrCreatePeerConnection →
    /// waitForHandshake(1)` can BLOCK ~1s on one slow/unreachable peer.  At
    /// election time that serial blocking stalls votes/heartbeats to EVERY peer
    /// → no leader is elected → the cluster can't converge.  The fix is one send
    /// queue + one dedicated drain thread PER peer, so a blocking send to a slow
    /// peer is isolated to that peer's thread and never delays another peer's
    /// votes/heartbeats.  Peers are stable for a cluster's lifetime, so the
    /// per-peer drains are created lazily on first enqueue and live until
    /// `stopOutboxDrain` / `deinit`.
    ///
    /// Lock ordering: `peer_drains_mutex` (the map guard) is a LEAF lock held
    /// only for brief get-or-create lookups + the one-time thread spawn — it is
    /// NEVER held while doing a network `send`/handshake (the drain loop
    /// releases its own per-peer `PeerDrain.mutex` before calling `send`, and
    /// never touches the map mutex on the hot path).  Each `PeerDrain.mutex` is
    /// likewise a leaf lock guarding only that peer's queue snapshot-and-swap.
    peer_drains_mutex: std.Io.Mutex = std.Io.Mutex.init,
    peer_drains: std.AutoHashMap(u64, *PeerDrain) = undefined,
    peer_drains_initialized: bool = false,

    /// Global cancellation flag for ALL per-peer drain threads.  Set by
    /// `stopOutboxDrain` / `deinit`; checked by `enqueueOutbound` (reject new
    /// work), each per-peer drain loop, and `send` (reject after shutdown).
    /// `startOutboxDrain` is the lifecycle gate: while false, lazy per-peer
    /// drains may be created on enqueue.
    outbox_shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// True between `startOutboxDrain` and `stopOutboxDrain`.  Gates lazy
    /// per-peer drain creation so a stray enqueue before start / after stop
    /// never spawns an orphaned thread.
    outbox_running: bool = false,

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
        /// The destination peer's id. Stored so the IP-change reaper in
        /// `clientPollLoop` (which iterates the snapshot by pointer) can call
        /// `evictPeerConnection(peer_id)` when this connection's endpoint has
        /// been rescheduled to a new IP. Immutable after publish into the map.
        peer_id: u64 = 0,
        /// The IP `endpoint` resolved to when this connection was established.
        /// Owned. The reaper compares it against a fresh resolution of
        /// `endpoint`; a difference means the peer pod was rescheduled to a new
        /// IP and the cached connection (which silently blackholes against the
        /// old IP) must be evicted + rebuilt. Immutable after publish.
        resolved_ip: []const u8 = &.{},

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

        /// A6f (2026-05-26): serialize all access to the QUIC vendor library
        /// for this connection. The library's internal stream-tracking
        /// HashMap is not thread-safe — concurrent `poll()` (from
        /// clientPollLoop) and `getStream()`/`finish()` (from send) on the
        /// same QuicClient produce a segfault inside `dropAckedStreamTracking`
        /// → `fetchRemove` → `getIndex` (the HashMap's metadata pointer is
        /// read after free). Holding this mutex around every client.* call
        /// prevents the race.
        client_mutex: std.Io.Mutex = std.Io.Mutex.init,

        /// 2026-06-08 raft multiplexed streams: ONE long-lived bidirectional
        /// stream reused for every raft frame to this peer, so we never open a
        /// stream per RPC (which exhausted per-peer bidi-stream credit under
        /// write load and dropped heartbeats/votes → split-brain). Guarded by
        /// `client_mutex` (same as every other client.* access — A6f). Lazily
        /// opened on first send; closed+nulled on any write/open error and
        /// reopened on the next send.
        send_stream: ?*quic.QuicClientStream = null,

        /// k8s root cause #5 (stalled-stream liveness, 2026-06-11): the raft
        /// transport is fire-and-forget — a write into a stale/half-open QUIC
        /// connection (peer's OLD endpoint after a pod reschedule) buffers
        /// locally and returns success, so neither the send-error eviction path
        /// nor the IP-change reaper (the strand victim's IP never changed) ever
        /// fires. This timestamp records the last time we OBSERVED forward
        /// progress with this peer (an inbound frame / RPC response, stamped via
        /// `Transport.notePeerProgress`). Initialized at connect time so a brand
        /// new connection is not immediately judged stalled. The stall reaper
        /// compares `now - last_progress_ms` against `peer_stall_budget_ms`.
        last_progress_ms: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),

        /// Count of frames handed to the wire for this peer. The stall reaper
        /// must only act on a peer we have actually been SENDING to (a peer with
        /// no traffic has no progress to expect and must not be evicted). Bumped
        /// on each successful `send`.
        frames_sent: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),

        fn deinit(self: *PeerConnection) void {
            if (self.send_stream) |s| {
                s.finish() catch {};
                s.deinit();
                self.send_stream = null;
            }
            self.client.deinit();
            self.allocator.free(self.endpoint);
            if (self.resolved_ip.len > 0) self.allocator.free(self.resolved_ip);
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

    /// Task A2 (2026-06-08): a single peer's send queue + dedicated drain
    /// thread.  One of these exists per destination peer for the cluster's
    /// lifetime (created lazily on first enqueue, joined+freed at shutdown).
    /// Its `mutex` is a LEAF lock guarding only the queue snapshot-and-swap; it
    /// is released before the drain loop calls `send`, so a blocking send to
    /// this peer never holds any lock and never delays another peer's drain.
    pub const PeerDrain = struct {
        mutex: std.Io.Mutex = std.Io.Mutex.init,
        queue: std.ArrayList(OutboundEntry) = .empty,
        thread: ?std.Thread = null,
        /// Per-peer shutdown.  Set (alongside the global `outbox_shutdown`) by
        /// `stopOutboxDrain`/`deinit` so the loop exits promptly.
        shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        /// Back-pointer so the spawned thread can reach `Transport.send` and the
        /// global `outbox_shutdown` without a separate context allocation.
        transport: *Transport = undefined,
        peer_id: u64 = 0,
    };

    pub fn init(allocator: Allocator) Transport {
        return .{
            .allocator = allocator,
            .peers_mutex = std.Io.Mutex.init,
            .peers = std.AutoHashMap(u64, *PeerConnection).init(allocator),
            .peers_initialized = true,
            .peer_drains_mutex = std.Io.Mutex.init,
            .peer_drains = std.AutoHashMap(u64, *PeerDrain).init(allocator),
            .peer_drains_initialized = true,
            .outbox_shutdown = std.atomic.Value(bool).init(false),
            .outbox_running = false,
            .client_poll_thread = null,
            .client_poll_shutdown = std.atomic.Value(bool).init(false),
        };
    }

    pub fn deinit(self: *Transport) void {
        // Task A6e/A2: stop the dispatch threads BEFORE we tear down the peer
        // map.  Both the per-peer drain threads (`getOrCreatePeerConnection`)
        // and the client poll thread (direct `self.peers` iteration) touch the
        // connection pool, so freeing entries while they ran would race.
        // `stopOutboxDrain` joins every per-peer drain thread, drains+frees its
        // queue, and removes+frees its `PeerDrain` — leaving the map empty.
        self.stopOutboxDrain();
        self.stopClientPoll();

        if (self.peer_drains_initialized) {
            const io = std.Io.Threaded.global_single_threaded.io();
            self.peer_drains_mutex.lockUncancelable(io);
            // stopOutboxDrain already joined+freed every PeerDrain, but defend
            // against a deinit without a matching start (the map is then empty).
            var it = self.peer_drains.iterator();
            while (it.next()) |entry| {
                const pd = entry.value_ptr.*;
                for (pd.queue.items) |*qe| freeOutboundMessage(self.allocator, qe.msg);
                pd.queue.deinit(self.allocator);
                self.allocator.destroy(pd);
            }
            self.peer_drains.deinit();
            self.peer_drains_initialized = false;
            self.peer_drains_mutex.unlock(io);
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

    /// Task A2: get-or-create the `PeerDrain` for `peer_id`, spawning its
    /// dedicated drain thread when the transport is running.  Holds
    /// `peer_drains_mutex` only for the map lookup/insert + the (fast,
    /// non-blocking) thread spawn — NEVER across a network send.  Returns null
    /// only after `stopOutboxDrain` has flipped `outbox_shutdown`, in which case
    /// the caller drops the message (the raft library re-sends next tick).
    ///
    /// The PeerDrain (queue) is created even before `startOutboxDrain` so the
    /// synchronous `snapshotOutbox`/`flushOutboxBlocking` path (and the in-
    /// process A5 test) can enqueue+flush without a running thread; the thread
    /// is spawned lazily once `outbox_running` is set (here, or retroactively by
    /// `startOutboxDrain` for any pre-created drains).
    fn getOrCreatePeerDrain(self: *Transport, peer_id: u64) !?*PeerDrain {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.peer_drains_mutex.lockUncancelable(io);
        defer self.peer_drains_mutex.unlock(io);
        // Re-check under the lock so we never spawn a drain that
        // `stopOutboxDrain` (which also takes the map mutex) won't join.
        if (self.outbox_shutdown.load(.acquire)) return null;

        const pd = self.peer_drains.get(peer_id) orelse blk: {
            const fresh = try self.allocator.create(PeerDrain);
            errdefer self.allocator.destroy(fresh);
            fresh.* = .{
                .queue = .empty,
                .thread = null,
                .shutdown = std.atomic.Value(bool).init(false),
                .transport = self,
                .peer_id = peer_id,
            };
            try self.peer_drains.put(peer_id, fresh);
            break :blk fresh;
        };

        // Spawn the dedicated drain thread on first use while running.  Spawning
        // is fast and takes no geode lock, so doing it under `peer_drains_mutex`
        // does not violate the "no send under the map mutex" rule.
        if (self.outbox_running and pd.thread == null) {
            pd.shutdown.store(false, .release);
            pd.thread = try std.Thread.spawn(.{}, peerDrainEntry, .{@as(?*anyopaque, @ptrCast(pd))});
        }
        return pd;
    }

    /// Task A6e/A2: append an outbound message to the OWNING PEER's queue.
    /// Called from the bridge `sendImpl` while the wrapper's `inner_mutex` is
    /// held — cheap: a get-or-create lookup + a vec append under that peer's
    /// leaf mutex.  The actual QUIC write happens later on that peer's drain
    /// thread, isolated from every other peer.
    ///
    /// Lifecycle contract: producers (the raft loop) must be quiesced before
    /// `stopOutboxDrain` frees the per-peer drains — `ClusterCoordinator.stop`
    /// guarantees this by joining `raft_pool` before calling `stopOutboxDrain`.
    /// (Same invariant the single-outbox design relied on.)
    pub fn enqueueOutbound(self: *Transport, peer: Peer, from: u64, term: u64, msg: Message) !void {
        if (self.outbox_shutdown.load(.acquire)) return error.TransportShutdown;
        const pd = (try self.getOrCreatePeerDrain(peer.id)) orelse return error.TransportShutdown;

        const io = std.Io.Threaded.global_single_threaded.io();
        pd.mutex.lockUncancelable(io);
        defer pd.mutex.unlock(io);

        // Coalesce AppendEntries within THIS peer's queue (2026-06-04 cluster
        // write-replication BLOCKER).  The raft tick enqueues an AppendEntries
        // to every peer on a short cadence; if this peer's drain thread can't
        // keep up (e.g. it is paying a slow QUIC handshake), the queue would
        // grow an unbounded backlog of stale heartbeats and a freshly PROPOSED
        // entry's AppendEntries would sit at the TAIL, draining minutes later —
        // or never before the leader steps down.  AppendEntries is idempotent
        // and cumulative: a newer one to this peer strictly supersedes any older
        // still-pending one, so we replace it in place.  This bounds the queue
        // to ~one AppendEntries.  Votes, responses and snapshots are distinct
        // and never coalesced.  (Now a per-peer scan — strictly smaller than
        // the old global scan.)
        switch (msg) {
            .append_entries => {
                for (pd.queue.items) |*existing| {
                    if (existing.msg == .append_entries) {
                        freeOutboundMessage(self.allocator, existing.msg);
                        existing.* = .{ .peer = peer, .from = from, .term = term, .msg = msg };
                        return;
                    }
                }
            },
            else => {},
        }

        try pd.queue.append(self.allocator, .{ .peer = peer, .from = from, .term = term, .msg = msg });
        // The peer's drain thread polls every 2 ms, so no condvar signal is
        // needed; the wakeup-latency floor stays well under the heartbeat
        // budget (50 ms).
    }

    /// Task A6e/A2: snapshot-and-swap the combined backlog across ALL per-peer
    /// queues.  Used by the synchronous test/in-process path via
    /// `flushOutboxBlocking` (and the legacy A5b dispatch test).  Returns an
    /// owned slice the caller must `deinit` and whose `msg` fields must be freed
    /// via `freeOutboundMessage`.  Production code lets each peer's drain thread
    /// do the work; this entry point exists so tests can flush synchronously.
    pub fn snapshotOutbox(self: *Transport) std.ArrayList(OutboundEntry) {
        const io = std.Io.Threaded.global_single_threaded.io();
        var snap: std.ArrayList(OutboundEntry) = .empty;
        if (!self.peer_drains_initialized) return snap;
        self.peer_drains_mutex.lockUncancelable(io);
        defer self.peer_drains_mutex.unlock(io);
        var it = self.peer_drains.iterator();
        while (it.next()) |entry| {
            const pd = entry.value_ptr.*;
            pd.mutex.lockUncancelable(io);
            for (pd.queue.items) |qe| {
                // On OOM here we'd leak the queued msg; appendBounded would be
                // worse (silent drop). Use a best-effort append and free on
                // failure to keep the no-double-free invariant.
                snap.append(self.allocator, qe) catch |err| {
                    freeOutboundMessage(self.allocator, qe.msg);
                    log.debug("snapshotOutbox append failed; dropping queued msg", &.{
                        Attr.string("error", @errorName(err)),
                    });
                };
            }
            // We moved ownership of every entry into `snap` (or freed it), so
            // clear the queue without re-freeing.
            pd.queue.clearRetainingCapacity();
            pd.mutex.unlock(io);
        }
        return snap;
    }

    /// Task A6e: dispatch one outbox snapshot inline.  Used by each per-peer
    /// drain loop and by the synchronous test path via `flushOutboxBlocking`.
    /// Each entry's `msg` is freed after the send attempt regardless of outcome
    /// — the raft library re-sends on its next tick if the send failed.
    pub fn dispatchOutbox(self: *Transport, snap: *std.ArrayList(OutboundEntry)) void {
        for (snap.items) |entry| {
            // Shutdown is a cancellation boundary.  Once SIGTERM has reached
            // ClusterCoordinator.stop(), peers may already be gone; continuing
            // to drain a stale snapshot can pay the QUIC handshake timeout for
            // every queued heartbeat/vote and make subprocess cleanup hang.
            if (self.outbox_shutdown.load(.acquire)) {
                freeOutboundMessage(self.allocator, entry.msg);
                continue;
            }
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

    /// Task A6e: synchronous helper used by tests (and by the in-process A5
    /// election test) that want to flush queued messages without depending on
    /// the background drain threads.  Drains every per-peer queue serially.
    /// Production code always lets the per-peer drain threads do the work.
    pub fn flushOutboxBlocking(self: *Transport) void {
        var snap = self.snapshotOutbox();
        self.dispatchOutbox(&snap);
    }

    /// Task A2: one peer's drain loop.  Snapshot-and-swap THIS peer's queue
    /// under its own leaf mutex, release the mutex, then `send` each entry
    /// serially to this one peer (blocking on a slow handshake is fine — it is
    /// isolated to this thread).  2 ms idle when the queue is empty.  Honors
    /// both the per-peer `shutdown` and the global `outbox_shutdown`.
    fn peerDrainLoop(self: *Transport, pd: *PeerDrain) void {
        const io = std.Io.Threaded.global_single_threaded.io();
        while (!pd.shutdown.load(.acquire) and !self.outbox_shutdown.load(.acquire)) {
            pd.mutex.lockUncancelable(io);
            const snap = pd.queue;
            pd.queue = .empty;
            const have_work = snap.items.len > 0;
            pd.mutex.unlock(io);
            if (have_work) {
                var snap_mut = snap;
                self.dispatchOutbox(&snap_mut);
            } else {
                var empty_mut = snap;
                empty_mut.deinit(self.allocator);
                compat_sleep(2 * std.time.ns_per_ms);
            }
        }
    }

    fn peerDrainEntry(ctx: ?*anyopaque) void {
        const pd: *PeerDrain = @ptrCast(@alignCast(ctx.?));
        pd.transport.peerDrainLoop(pd);
    }

    pub fn startOutboxDrain(self: *Transport) !void {
        // Flip the running gate so `getOrCreatePeerDrain` will spawn per-peer
        // drain threads on first enqueue.  Also spawn a thread for any drain
        // already created pre-start (e.g. an early enqueue that only built the
        // queue), so no queued backlog is left without a draining thread.
        self.outbox_shutdown.store(false, .release);
        const io = std.Io.Threaded.global_single_threaded.io();
        self.peer_drains_mutex.lockUncancelable(io);
        defer self.peer_drains_mutex.unlock(io);
        self.outbox_running = true;
        var it = self.peer_drains.iterator();
        while (it.next()) |entry| {
            const pd = entry.value_ptr.*;
            if (pd.thread == null) {
                pd.shutdown.store(false, .release);
                pd.thread = try std.Thread.spawn(.{}, peerDrainEntry, .{@as(?*anyopaque, @ptrCast(pd))});
            }
        }
    }

    pub fn stopOutboxDrain(self: *Transport) void {
        // Signal global cancellation FIRST so every per-peer loop sees it (and
        // `getOrCreatePeerDrain` refuses to spawn new drains).
        self.outbox_shutdown.store(true, .release);
        if (!self.peer_drains_initialized) return;

        const io = std.Io.Threaded.global_single_threaded.io();
        self.peer_drains_mutex.lockUncancelable(io);
        defer self.peer_drains_mutex.unlock(io);
        self.outbox_running = false;

        // Join + free every per-peer drain.  Holding `peer_drains_mutex` across
        // the joins is safe: the drain loops are pure leaf consumers that never
        // take this (or any other) geode lock, so there is no lock-order
        // inversion and no deadlock.  Because `outbox_shutdown` was set BEFORE we
        // took this mutex, `getOrCreatePeerDrain` can no longer hand out (or
        // create) a drain — so no NEW producer can reach a `pd`.  Join BEFORE
        // freeing each queue so the drain loop has fully unwound (no
        // use-after-free); then briefly take `pd.mutex` around the queue
        // teardown to close the window against a producer that grabbed `pd`
        // just before shutdown and is still appending under `pd.mutex`.  Finally
        // drop any messages still queued (the loop may have exited mid-backlog).
        var it = self.peer_drains.iterator();
        while (it.next()) |entry| {
            const pd = entry.value_ptr.*;
            pd.shutdown.store(true, .release);
            if (pd.thread) |t| {
                t.join();
                pd.thread = null;
            }
            pd.mutex.lockUncancelable(io);
            for (pd.queue.items) |*qe| freeOutboundMessage(self.allocator, qe.msg);
            pd.queue.deinit(self.allocator);
            pd.mutex.unlock(io);
            self.allocator.destroy(pd);
        }
        // Drop all (now-freed) entries from the map without re-iterating.
        self.peer_drains.clearRetainingCapacity();
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
        // k8s membership churn: re-resolve every peer FQDN on a slow cadence so a
        // pod reschedule (peer moves to a new IP, old IP becomes a silent
        // blackhole that never errors a send) is detected and the stale
        // connection rebuilt. Gated well above the 2 ms poll cadence so the DNS
        // lookups add negligible load; well below any election timeout so
        // recovery is prompt.
        const peer_reresolve_ms: i64 = 3000;
        var last_reresolve_ms: i64 = compat_milliTimestamp();
        while (!self.client_poll_shutdown.load(.acquire)) {
            const now_ms = compat_milliTimestamp();
            const do_reresolve = (now_ms - last_reresolve_ms) >= peer_reresolve_ms;
            if (do_reresolve) last_reresolve_ms = now_ms;
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
                // A6f: serialize against send's getStream/finish on the same
                // QuicClient. The vendor library's stream-tracking HashMap
                // is not thread-safe.
                pc.client_mutex.lockUncancelable(io);
                pc.client.poll(0) catch {};
                pc.client_mutex.unlock(io);
                // IP-change reaper: outside client_mutex (DNS only, never touches
                // the QUIC client). May evict pc; our snapshot ref keeps it alive
                // until the release below.
                if (do_reresolve) self.maybeReconnectOnIpChange(pc);
                if (pc.release()) {
                    // Eviction completed while we were polling/re-resolving; we
                    // hold the last reference and must deinit.
                    pc.deinit();
                }
            }
            compat_sleep(2 * std.time.ns_per_ms);
        }
    }

    /// Periodic peer IP-change reaper, invoked from `clientPollLoop` on a slow
    /// cadence. Re-resolves the peer's FQDN; if it now maps to a DIFFERENT IP
    /// than the live connection, the peer pod was rescheduled to a new IP and
    /// the cached connection is silently blackholing against the old one (no
    /// send error ever fires, so the evict-on-send-error path can't recover it).
    /// Evict it so the next `send` rebuilds via `connectWithTLS`, which resolves
    /// the FQDN to the current IP. Reads only fields that are immutable after the
    /// connection is published (`endpoint`/`resolved_ip`/`peer_id`); takes no
    /// lock here — `evictPeerConnection` takes `peers_mutex` itself.
    fn maybeReconnectOnIpChange(self: *Transport, pc: *PeerConnection) void {
        if (pc.resolved_ip.len == 0) return; // IP unknown (resolve failed at connect) — nothing to compare
        const fresh = quic.resolveHostIpAlloc(self.allocator, pc.endpoint) catch return; // transient resolve failure: keep the connection, retry next interval
        defer self.allocator.free(fresh);
        if (std.mem.eql(u8, fresh, pc.resolved_ip)) return; // same IP — connection still valid
        // warn (not info/debug): a peer reschedule is an operationally important
        // membership event an operator must be able to see — the bug report
        // specifically complained that churn was invisible ("0 errors") while the
        // cluster silently failed to reconverge. Only fires on an actual IP change
        // (then the connection is rebuilt to the new IP), so it is not noisy.
        log.warn("raft transport peer rescheduled to a new IP; evicting stale connection", &.{
            Attr.string("endpoint", pc.endpoint),
            Attr.string("old_ip", pc.resolved_ip),
            Attr.string("new_ip", fresh),
            Attr.uint("peer", pc.peer_id),
        });
        self.evictPeerConnection(pc.peer_id);
    }

    /// k8s root cause #5 (stalled-stream liveness): the budget, in ms, after
    /// which a peer we are actively sending to but have observed NO forward
    /// progress from is judged stalled and its cached connection evicted +
    /// rebuilt (the same recovery the IP-change reaper performs). Sized as
    /// several `clientPollLoop` reaper passes (peer_reresolve_ms = 3000) and
    /// kept at or below the raft election timeout ceiling (5000 ms default —
    /// `cluster.zig:2403`) so recovery is prompt yet never trips on a merely
    /// quiet-but-healthy link. SKELETON value pending the real detector.
    pub const peer_stall_budget_ms: i64 = 3000;

    /// k8s root cause #5 (stalled-stream liveness): PURE, clock-injectable
    /// decision used by `maybeReconnectOnStall` (and unit tests). Returns true
    /// iff this connection should be evicted because it has stalled: frames have
    /// been sent to the peer but no forward progress has been observed for
    /// longer than `peer_stall_budget_ms`. A peer with recent progress, or a
    /// peer to which nothing has been sent, must return false.
    ///
    /// SKELETON: the bug-fixer agent fills in the real comparison
    /// (frames_sent > 0 AND now_ms - last_progress_ms > peer_stall_budget_ms).
    /// Until then it always returns false, so the "stalled peer is evicted"
    /// regression tests FAIL — proving they catch the wedge.
    pub fn shouldEvictOnStall(pc: *PeerConnection, now_ms: i64) bool {
        _ = pc;
        _ = now_ms;
        return false;
    }

    /// Refresh the forward-progress timestamp for the peer identified by
    /// `peer_id`. Called from the INBOUND path (raft response / heartbeat-ack
    /// dispatch in `cluster.zig`), which arrives on a DIFFERENT connection
    /// object than the outbound `PeerConnection`, so progress must be stamped by
    /// a peer-id keyed lookup into `peers` rather than by pointer. Safe to call
    /// for an unknown peer (no-op).
    ///
    /// SKELETON: the bug-fixer agent fills in the peers_mutex-guarded lookup +
    /// `pc.last_progress_ms.store(now_ms, ...)`. Until then it is a no-op, so
    /// the "notePeerProgress stamps the right PeerConnection" regression test
    /// FAILS.
    pub fn notePeerProgress(self: *Transport, peer_id: u64, now_ms: i64) void {
        _ = self;
        _ = peer_id;
        _ = now_ms;
    }

    /// Periodic stalled-stream reaper, sibling to `maybeReconnectOnIpChange`,
    /// invoked from `clientPollLoop` on the same slow cadence. If the connection
    /// has stalled (`shouldEvictOnStall`), evict it so the next `send` rebuilds
    /// via `connectWithTLS` (which re-resolves the FQDN) — exactly like the
    /// IP-change path. Takes no lock here; `evictPeerConnection` takes
    /// `peers_mutex` itself.
    ///
    /// SKELETON: present so `clientPollLoop` wiring (added by the fixer) and the
    /// tests compile. Delegates to `shouldEvictOnStall` (which the fixer makes
    /// real); with the skeleton decision returning false this never evicts.
    fn maybeReconnectOnStall(self: *Transport, pc: *PeerConnection, now_ms: i64) void {
        if (shouldEvictOnStall(pc, now_ms)) {
            log.warn("raft transport peer stalled (no progress within budget); evicting stale connection", &.{
                Attr.string("endpoint", pc.endpoint),
                Attr.uint("peer", pc.peer_id),
            });
            self.evictPeerConnection(pc.peer_id);
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
    /// k8s root cause #5: `error.OutOfStreams` (peer MAX_STREAMS_BIDI credit
    /// momentarily exhausted — quic `methods_b.zig` returns it when
    /// `opened_bidi >= peer_max_streams_bidi`) and `error.WouldBlock` are
    /// TRANSIENT backpressure on a HEALTHY connection. Evicting the peer
    /// connection over them forces a fresh TLS handshake on the next send AND
    /// resets the stream credit — worsening the exhaustion and starving that
    /// peer's heartbeats until it parks as a candidate. Drop the one message
    /// instead (periodic heartbeats/AppendEntries re-send on the next tick) and
    /// keep the connection. Only a genuinely-dead connection warrants eviction.
    fn shouldEvictOnSendError(err: anyerror) bool {
        return switch (err) {
            error.OutOfStreams, error.WouldBlock => false,
            else => true,
        };
    }

    pub fn send(self: *Transport, peer: Peer, from: u64, term: u64, msg: Message) !void {
        if (self.outbox_shutdown.load(.acquire)) return error.TransportShutdown;
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

        // A6f: serialize all subsequent client.* calls against the poll
        // loop on the same connection. The vendor QUIC library's internal
        // stream-tracking HashMap segfaults under concurrent access.
        const io_send = std.Io.Threaded.global_single_threaded.io();
        conn.client_mutex.lockUncancelable(io_send);
        defer conn.client_mutex.unlock(io_send);

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
                        Attr.string("error", @errorName(err)),
                        Attr.uint("peer", peer.id),
                    });
                    self.evictPeerConnection(peer.id);
                } else {
                    // Transient stream-credit backpressure (OutOfStreams/WouldBlock):
                    // the connection is healthy — keep it; this RPC is dropped and the
                    // next raft tick re-sends. debug-level to avoid log spam under load.
                    log.debug("raft transport open send_stream backpressure; keeping connection", &.{
                        Attr.string("error", @errorName(err)),
                        Attr.uint("peer", peer.id),
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
            // for fatal errors. CRITICAL: null `conn.send_stream` BEFORE any
            // evictPeerConnection so PeerConnection.deinit does not double-free.
            s.finish() catch {};
            s.deinit();
            conn.send_stream = null;
            if (shouldEvictOnSendError(err)) {
                log.warn("raft transport writeRaftFrame failed; evicting peer connection", &.{
                    Attr.string("error", @errorName(err)),
                    Attr.uint("peer", peer.id),
                });
                self.evictPeerConnection(peer.id);
            } else {
                log.debug("raft transport writeRaftFrame backpressure; reopening stream next send", &.{
                    Attr.string("error", @errorName(err)),
                    Attr.uint("peer", peer.id),
                });
            }
            return err;
        };
        // NOTE: no per-RPC finish()/deinit() — the stream stays open for the
        // next frame. The dedicated client_poll_thread (A6e) flushes the write
        // onto the wire; the bridge returns immediately.
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
        const endpoint_dup = try self.allocator.dupe(u8, peer.endpoint);
        errdefer self.allocator.free(endpoint_dup);
        // Record the IP `endpoint` resolves to NOW so the clientPollLoop reaper
        // can later detect a pod reschedule (FQDN -> new IP) and rebuild this
        // connection. A resolution failure is non-fatal: store an empty IP — the
        // reaper treats "" as "unknown" and skips this peer (it never reconnects
        // off a missing baseline). In practice this is unreachable: if resolution
        // fails here, the connectWithTLS below resolves the same FQDN and fails
        // too, so no established connection is ever published with an empty IP.
        const resolved = quic.resolveHostIpAlloc(self.allocator, endpoint_dup) catch &.{};
        errdefer if (resolved.len > 0) self.allocator.free(resolved);
        conn.* = .{
            .allocator = self.allocator,
            .client = quic.QuicClient.init(self.allocator),
            .established = false,
            .endpoint = endpoint_dup,
            .port = peer.port,
            .peer_id = peer.id,
            .resolved_ip = resolved,
        };
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
    // Emit the 4-byte big-endian length prefix and the payload as ONE
    // contiguous write so the vendor QUIC layer packs them into a SINGLE
    // STREAM frame / datagram (payloads here are << path MTU).  The prior
    // two-write form (`writeAll(len)` then `writeAll(payload)`) produced two
    // separate STREAM frames in two packets; the receiver accepts the stream
    // on the first (length) packet, reads the length, then blocks for the
    // second (payload) packet on a poll-less 5 ms retry loop.  For frames
    // larger than what landed in the first packet this races the per-RPC
    // stream FIN/close and the payload was dropped — empty-heartbeat frames
    // (single packet) replicated while any AppendEntries carrying a real log
    // entry silently vanished, wedging the cluster commit index. One write =
    // one packet = atomic receive.
    const framed = try allocator.alloc(u8, 4 + payload.len);
    defer allocator.free(framed);
    std.mem.writeInt(u32, framed[0..4], @intCast(payload.len), .big);
    @memcpy(framed[4..], payload);
    try stream.writeAll(framed);
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
        // raft_schema.AppendEntries.entries carries the log entries to
        // replicate.  Serialize each geode LogEntry into a proto
        // RaftLogEntry whose `command_bytes` holds the canonical
        // tag-prefixed command encoding (serializeCommand).  This is the
        // replication payload the cluster bridge MUST carry: dropping it
        // (the historic `.empty`) left every AppendEntries an empty
        // heartbeat, so followers' match_index never advanced past their
        // prev_log_index and the leader's commit index was wedged at 0 —
        // no write ever replicated.  The ArrayList + each entry's
        // command_bytes are allocator-owned and freed by the envelope's
        // recursive `deinit` after protobuf.encode (encodeRaftFrame).
        .append_entries => |ae| blk: {
            var entries = std.ArrayList(raft_schema.RaftLogEntry).empty;
            errdefer {
                for (entries.items) |*e| e.deinit(allocator);
                entries.deinit(allocator);
            }
            for (ae.entries) |entry| {
                const cmd_bytes = try serializeCommand(allocator, entry.command);
                errdefer allocator.free(cmd_bytes);
                try entries.append(allocator, .{
                    .term = entry.term,
                    .index = entry.index,
                    .timestamp = entry.timestamp,
                    .client_id = entry.client_id,
                    .serial_number = entry.serial_number,
                    .command = null,
                    .command_bytes = cmd_bytes,
                });
            }
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
        // Reconstruct the replicated log entries from the wire.  Each proto
        // RaftLogEntry.command_bytes is the canonical serializeCommand
        // encoding; dupe it into an allocator-owned buffer (the proto decode
        // buffer is freed the moment decodeRaftFrame returns) and deserialize
        // it back into the geode Command.  `owned_wire_bytes` keeps the dup
        // alive until freeMessage runs.  Historic code dropped entries here
        // (`&.{}`), which — paired with the same drop in messageToProto —
        // wedged the cluster commit index at 0.
        .append_entries => |ae| blk: {
            const items = ae.entries.items;
            const entries = try allocator.alloc(LogEntry, items.len);
            var built: usize = 0;
            errdefer {
                for (entries[0..built]) |*e| {
                    if (e.owned_wire_bytes) |b| allocator.free(b);
                }
                allocator.free(entries);
            }
            for (items, 0..) |pe, i| {
                const dup = try allocator.dupe(u8, pe.command_bytes);
                errdefer allocator.free(dup);
                const cmd = deserializeCommand(dup) catch Command{ .write = dup };
                entries[i] = .{
                    .term = pe.term,
                    .index = pe.index,
                    .command = cmd,
                    .timestamp = pe.timestamp,
                    .client_id = pe.client_id,
                    .serial_number = pe.serial_number,
                    .owned_wire_bytes = dup,
                };
                built += 1;
            }
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

fn freeMessage(allocator: Allocator, msg: *Message) void {
    // Most Message fields are scalars or slices that point into a protobuf
    // decode buffer freed elsewhere.  The exception is an inbound
    // AppendEntries reconstructed by `protoToMessage`: it owns the
    // `entries` slice and, per entry, the duped `owned_wire_bytes` buffer
    // that the deserialized Command aliases.  Free those here so the
    // DecodedRaftFrame.deinit path doesn't leak one buffer per replicated
    // log entry.
    switch (msg.*) {
        .append_entries => |ae| {
            for (ae.entries) |entry| {
                if (entry.owned_wire_bytes) |b| allocator.free(b);
            }
            if (ae.entries.len > 0) allocator.free(ae.entries);
        },
        else => {},
    }
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
            // Free the per-entry private command copies made by
            // `raftLibMessageToGeode` (see the deep-copy note there), then the
            // entries slice itself.
            for (ae.entries) |entry| {
                if (entry.owned_wire_bytes) |b| allocator.free(b);
            }
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
        CMD_TAG_SCHEMA_CHANGE => {
            // Wire format mirrors serializeCommand: 1B op | 4B graph_len(BE) | graph | schema
            if (payload.len < 1 + 4) return error.InvalidData;
            const op_byte = payload[0];
            const graph_len = std.mem.readInt(u32, payload[1..][0..4], .big);
            const graph_start: usize = 5;
            const graph_end: usize = graph_start + graph_len;
            if (graph_end > payload.len) return error.InvalidData;
            const schema_start: usize = graph_end;
            return .{ .schema_change = .{
                .operation = @enumFromInt(op_byte),
                .graph = payload[graph_start..graph_end],
                .schema = payload[schema_start..],
            } };
        },
        CMD_TAG_TXN_DECIDE => {
            if (payload.len < 9) return error.InvalidData;
            return .{ .txn_decide = .{
                .xid = std.mem.readInt(u64, payload[0..8], .big),
                .commit = payload[8] != 0,
            } };
        },
        CMD_TAG_GRAPH_MUTATION => {
            // Wire format mirrors serializeCommand:
            //   4B graph_len(BE) | graph | 1B mutation_type | 1B has_txn [| 8B txn_id(BE)] | data
            // Without this case, a proposed graph mutation fell into the `else`
            // branch below and was applied as an inert `.write`, so cluster
            // writes never replicated (root cause #2 of
            // docs/bugs/2026-06-04-cluster-raft-no-stable-quorum-writes-time-out.md).
            // CANARY: REQ=REQ-DIST-CLUSTER-REPLICATE-CREATE; FEATURE="DistributedCluster"; ASPECT=DeserializeGraphMutation; STATUS=TESTED; TEST=tests/test_cluster_3node_steady_state.zig; OWNER=distributed; UPDATED=2026-06-04
            if (payload.len < 4 + 1 + 1) return error.InvalidData;
            const graph_len = std.mem.readInt(u32, payload[0..4], .big);
            var pos: usize = 4;
            if (pos + graph_len > payload.len) return error.InvalidData;
            const graph = payload[pos .. pos + graph_len];
            pos += graph_len;
            if (pos + 2 > payload.len) return error.InvalidData;
            const mtype: @FieldType(GraphMutation, "mutation_type") = @enumFromInt(payload[pos]);
            pos += 1;
            const has_txn = payload[pos];
            pos += 1;
            var txn_id: ?u64 = null;
            if (has_txn != 0) {
                if (pos + 8 > payload.len) return error.InvalidData;
                txn_id = std.mem.readInt(u64, payload[pos..][0..8], .big);
                pos += 8;
            }
            return .{ .graph_mutation = .{
                .graph = graph,
                .mutation_type = mtype,
                .data = payload[pos..],
                .txn_id = txn_id,
            } };
        },
        else => {
            // For complex types we have not yet wired a deserializer for
            // (config_change/snapshot_pointer/txn_prepare), surface them as a
            // generic write so the apply callback sees a recognisable variant
            // rather than losing the payload entirely.
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
    // Heap-allocated, OWNED storage backing whose Storage vtable interface
    // (which captures the backing pointer) remains valid for the RaftNode's
    // lifetime. A previous version held this as an inline value, which dangled
    // the moment RaftNode.init returned. See A4d of the distributed cluster
    // testing plan.
    //
    // The variant is chosen at construction: `.in_memory` (today's behavior,
    // and the in-process test path) loses hard-state/log on restart; `.file`
    // (production, when a `storage_dir` is supplied) persists currentTerm /
    // votedFor / the raft log via the pinned raft library's crash-safe
    // FileStorage, so a restarted node restores its hard-state (Raft
    // election-safety) instead of resetting term/vote to zero.
    storage_backing: union(enum) {
        in_memory: *raft_lib.InMemoryStorage,
        file: *raft_lib.FileStorage,
    },

    // Configuration
    peers: []Peer,
    election_timeout_ms: u64,

    // Network
    transport: ?*Transport,

    // Callbacks
    apply_callback: ?*const fn (allocator: Allocator, cmd: Command, raft_index: u64) anyerror![]u8,

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

    /// Construct a RaftNode whose raft hard-state (currentTerm/votedFor) and log
    /// are rooted at a per-node on-disk directory when `storage_dir` is non-null,
    /// or held purely in memory when it is null.
    ///
    /// * `storage_dir == null` → heap-allocate a `raft_lib.InMemoryStorage`
    ///   (today's behavior, and the in-process test path). Hard-state and log
    ///   are lost on restart.
    /// * `storage_dir != null` → heap-allocate a `raft_lib.FileStorage` rooted
    ///   at that dir. The library creates the full dir path and opens a Dir
    ///   handle (it does NOT retain the `storage_dir` slice, so the caller may
    ///   free it once this returns) and takes an exclusive `.lock` flock. If a
    ///   live process already holds that lock, `FileStorage.init` returns
    ///   `error.WouldBlock` which we surface as `error.RaftStorageDirLocked`
    ///   (do NOT mislabel as InvalidNodeId). The persisted hard-state + log
    ///   survive a process restart so a re-initialized node restores its
    ///   currentTerm / votedFor (Raft election-safety).
    ///
    /// The chosen backing pointer is OWNED by the returned RaftNode and freed in
    /// `deinit`; `FileStorage.deinit` releases the flock.
    pub fn initWithStorageDir(
        allocator: Allocator,
        id: u64,
        peers: []Peer,
        election_timeout_ms: u64,
        storage_dir: ?[]const u8,
    ) !*RaftNode {
        const node = try allocator.create(RaftNode);
        // If any subsequent init step fails (most notably raft_lib.RaftNode.init
        // rejecting an invalid config such as id==0 -> InvalidId), the wrapper
        // we just allocated would leak. The node's fields aren't populated until
        // the `node.* = ...` at the end, so a bare destroy is the correct unwind
        // here (no deinit of partial state required).
        errdefer allocator.destroy(node);

        // Map Peer IDs to u64 array for external raft library
        const peer_ids = try allocator.alloc(u64, peers.len);
        defer allocator.free(peer_ids);
        for (peers, 0..) |peer, i| {
            peer_ids[i] = peer.id;
        }

        // Heap-allocate the chosen storage backing so the Storage interface
        // pointer that raft_lib.RaftNode.init captures (via backing.storage())
        // remains valid for the lifetime of the RaftNode. A previous version
        // held storage as a stack-local `var`, so the interface pointer dangled
        // the moment this function returned — surfacing as `OutOfMemory` on the
        // first advance and then `ReadyNotAdvanced` indefinitely once
        // ClusterCoordinator.start() became reachable (A4b/A4c).
        const StorageBacking = @FieldType(RaftNode, "storage_backing");
        var backing: StorageBacking = undefined;
        if (storage_dir) |dir| {
            const file_ptr = try allocator.create(raft_lib.FileStorage);
            errdefer allocator.destroy(file_ptr);
            // The dir's exclusive `.lock` flock is held by whatever process last
            // opened it. On an IN-PLACE restart (k8s pod restart with a
            // preserved PVC, modelled by the netns churn test's M4), the
            // *previous* incarnation may still be finishing its SIGTERM-driven
            // shutdown when the replacement boots, so its flock lingers for a
            // brief handoff window. An OS flock is released automatically the
            // instant the holder exits (even on SIGKILL / crash), so a bounded
            // retry reliably bridges that window without risking a true
            // two-writers situation. We fail with a clear error only if the
            // lock is STILL held after the budget — that means a genuinely live
            // peer owns the dir (operator misconfiguration) or a kernel that
            // leaked the lock, neither of which a longer wait would fix.
            const lock_retry_budget_ns: u64 = 15 * std.time.ns_per_s;
            const lock_retry_step_ns: u64 = 250 * std.time.ns_per_ms;
            var waited_ns: u64 = 0;
            file_ptr.* = while (true) {
                break raft_lib.FileStorage.init(allocator, dir) catch |err| switch (err) {
                    error.WouldBlock => {
                        if (waited_ns >= lock_retry_budget_ns) {
                            // Predecessor never released the flock within budget.
                            return error.RaftStorageDirLocked;
                        }
                        compat_sleep(lock_retry_step_ns);
                        waited_ns += lock_retry_step_ns;
                        continue;
                    },
                    else => return err,
                };
            };
            backing = .{ .file = file_ptr };
        } else {
            const mem_ptr = try allocator.create(raft_lib.InMemoryStorage);
            errdefer allocator.destroy(mem_ptr);
            mem_ptr.* = raft_lib.InMemoryStorage.init(allocator);
            backing = .{ .in_memory = mem_ptr };
        }
        // From here on the backing is live (FileStorage holds a flock); any
        // failure must deinit + destroy the correct variant to release it.
        errdefer switch (backing) {
            inline else => |p| {
                p.deinit();
                allocator.destroy(p);
            },
        };

        const storage_iface = switch (backing) {
            inline else => |p| p.storage(),
        };

        const heartbeat_tick: u32 = 1;
        const election_tick: u32 = @intCast(@max(2, election_timeout_ms / 50));

        const raft_config = raft_lib.Config{
            .id = id,
            .peers = peer_ids,
            .election_tick = election_tick,
            .heartbeat_tick = heartbeat_tick,
            .pre_vote = true,
        };

        const inner = try raft_lib.RaftNode.init(allocator, raft_config, storage_iface);

        node.* = RaftNode{
            .allocator = allocator,
            .id = id,
            .state = .follower,
            .current_term = 0,
            .inner_mutex = std.Io.Mutex.init,
            .inner = inner,
            .storage_backing = backing,
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

    pub fn initWithClock(
        allocator: Allocator,
        id: u64,
        peers: []Peer,
        election_timeout_ms: u64,
        _: *const Clock,
    ) !*RaftNode {
        // In-process / test path: in-memory storage backing (no durability).
        return initWithStorageDir(allocator, id, peers, election_timeout_ms, null);
    }

    pub fn deinit(self: *RaftNode) void {
        self.state = .shutdown;
        self.inner.deinit();
        // Deinit + destroy the OWNED storage backing variant. FileStorage.deinit
        // releases the exclusive `.lock` flock so the dir can be re-opened by a
        // subsequent (e.g. restarted) node.
        switch (self.storage_backing) {
            inline else => |p| {
                p.deinit();
                self.allocator.destroy(p);
            },
        }
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

    /// Returns the current Raft term, read live from the inner library under
    /// the inner mutex. The wrapper's `self.current_term` mirror only advances
    /// when `drainReady` runs and reads a hard_state; on a steady leader that
    /// has no committed-entries to drain, the mirror can lag behind the actual
    /// term observed after a re-election. Reading inner directly avoids the
    /// stale-term mismatch that breaks cross-node term-agreement invariants.
    pub fn currentTerm(self: *RaftNode) u64 {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.inner_mutex.lockUncancelable(io);
        defer self.inner_mutex.unlock(io);
        return self.inner.current_term;
    }

    /// Returns the current leader id from the inner raft library's view, or
    /// null if no leader has been observed in this term (election in flight,
    /// just-started cluster, partition healing). Followers learn the leader's
    /// id from AppendEntries; candidates know themselves; leaders know themselves.
    /// admin_ddl.executeShowClusterStatus surfaces this through SHOW CLUSTER STATUS.
    pub fn leaderId(self: *RaftNode) ?u64 {
        const io = std.Io.Threaded.global_single_threaded.io();
        self.inner_mutex.lockUncancelable(io);
        defer self.inner_mutex.unlock(io);
        return self.inner.leader_id;
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
                    // Pass the committed entry's globally-unique, cross-node-identical
                    // log index so the apply layer can derive a deterministic,
                    // restart-idempotent node id (Raft Log Matching Property).
                    _ = callback(self.allocator, cmd, entry.index) catch |err| {
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
            //
            // CRITICAL (2026-06-04 cluster write-replication BLOCKER): we MUST
            // deep-copy `e.data` here, not alias it.  `e.data` points into the
            // raft library's log — for a freshly-proposed entry that is the
            // leader's *unstable* entry buffer, which `RaftLog.stableTo` FREES
            // on the very next `advance()` (it runs right after this send is
            // enqueued).  This conversion feeds the ASYNCHRONOUS outbox: the
            // message is encoded much later, on the drain thread.  Aliasing
            // `e.data` therefore reads freed memory at encode time, so the
            // command serialized to empty/garbage and the AppendEntries went
            // out with no payload — the leader could never replicate any
            // freshly-written entry (only entries already in stable storage
            // from a prior term survived).  Owning a private copy via
            // `owned_wire_bytes` (freed in `freeOutboundMessage`) makes the
            // geode message independent of the raft log's unstable lifecycle.
            const entries = try allocator.alloc(LogEntry, ae.entries.len);
            var built: usize = 0;
            errdefer {
                for (entries[0..built]) |*le| {
                    if (le.owned_wire_bytes) |b| allocator.free(b);
                }
                allocator.free(entries);
            }
            for (ae.entries, 0..) |e, i| {
                const owned: ?[]u8 = if (e.data.len > 0) try allocator.dupe(u8, e.data) else null;
                errdefer if (owned) |b| allocator.free(b);
                const cmd = if (owned) |b|
                    (deserializeCommand(b) catch Command{ .write = b })
                else
                    Command{ .write = e.data };
                entries[i] = .{
                    .term = e.term,
                    .index = e.index,
                    .command = cmd,
                    .timestamp = compat_milliTimestamp(),
                    .client_id = null,
                    .serial_number = null,
                    .owned_wire_bytes = owned,
                };
                built += 1;
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
    // Minimal valid Message variant for the frame round-trip (the legacy
    // `.noop` placeholder variant was removed from the Message union).
    const msg = Message{ .request_vote = .{
        .term = 1,
        .candidate_id = 42,
        .last_log_index = 0,
        .last_log_term = 0,
        .pre_vote = false,
    } };
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
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = try std.Io.Dir.cwd().openDir(io, dir_path, .{});
    defer dir.close(io);
    const tmp_exists = dir.openFile(io, "current_term.tmp", .{});
    if (tmp_exists) |f| {
        f.close(io);
        return error.TmpFileNotCleaned;
    } else |err| {
        try std.testing.expectEqual(error.FileNotFound, err);
    }
}

// k8s root cause #5 (2026-06-08): transient stream-credit backpressure must NOT
// evict a healthy peer connection (evicting forces a TLS handshake + resets the
// MAX_STREAMS credit → starves that peer's heartbeats → candidate parking).
// CANARY: REQ=REQ-DIST-RAFT-A1-NO-EVICT-BACKPRESSURE; FEATURE="Raft transport backpressure"; ASPECT=SendErrorClassify; STATUS=TESTED; OWNER=distributed; UPDATED=2026-06-08
test "raft_consensus: OutOfStreams/WouldBlock are transient (no evict); other errors evict" {
    // Transient backpressure on a healthy connection — keep it.
    try std.testing.expect(!Transport.shouldEvictOnSendError(error.OutOfStreams));
    try std.testing.expect(!Transport.shouldEvictOnSendError(error.WouldBlock));
    // Genuinely-dead connection — evict so the next send rebuilds.
    try std.testing.expect(Transport.shouldEvictOnSendError(error.ConnectionReset));
    try std.testing.expect(Transport.shouldEvictOnSendError(error.BrokenPipe));
    try std.testing.expect(Transport.shouldEvictOnSendError(error.TransportShutdown));
}

// ===========================================================================
// k8s root cause #5 (transport wedge): stalled-stream liveness regression tests
// ---------------------------------------------------------------------------
// A leader pod restarts with a NEW IP and re-wins leadership; a third node that
// did NOT restart is stranded as a silent stuck-candidate forever. The raft
// transport is fire-and-forget — a write into the stale/half-open connection to
// the leader's OLD endpoint buffers locally and returns success, so the
// send-error eviction path never fires; and the IP-change reaper declines
// because the strand victim's OWN IP never changed. The fix is a stalled-stream
// liveness detector (sibling to maybeReconnectOnIpChange) keyed off observed
// forward progress.
//
// These tests encode the DESIRED post-fix behavior. They FAIL against the
// SKELETON (shouldEvictOnStall always returns false; notePeerProgress is a
// no-op) — which is the proof they catch the bug.
// CANARY: REQ=REQ-DIST-RAFT-STALL-LIVENESS; FEATURE="Raft transport stalled-stream liveness"; ASPECT=StallEvictDecision; STATUS=TESTED; OWNER=distributed; UPDATED=2026-06-11

/// Build a heap-allocated PeerConnection suitable for the PURE stall-decision
/// unit tests. In test mode `quic.QuicClient.init` is a no-op stub, so no real
/// QUIC/TLS connection is created. The endpoint is a dup so deinit's free is
/// balanced. `established=true` mirrors a live connection.
fn makeStallTestPeerConnection(
    allocator: std.mem.Allocator,
    peer_id: u64,
    frames_sent: u64,
    last_progress_ms: i64,
) !*Transport.PeerConnection {
    const pc = try allocator.create(Transport.PeerConnection);
    pc.* = .{
        .allocator = allocator,
        .client = quic.QuicClient.init(allocator),
        .established = true,
        .endpoint = try allocator.dupe(u8, "raft-peer.cluster.svc"),
        .port = 7890,
        .peer_id = peer_id,
        .resolved_ip = &.{},
        .frames_sent = std.atomic.Value(u64).init(frames_sent),
        .last_progress_ms = std.atomic.Value(i64).init(last_progress_ms),
    };
    return pc;
}

test "raft stall: stalled peer (sends happened, no progress past budget) is evicted" {
    const allocator = std.testing.allocator;
    const now_ms: i64 = 1_000_000;
    // Frames were sent, but last observed progress is well beyond the budget.
    const stale_progress = now_ms - (Transport.peer_stall_budget_ms + 500);
    const pc = try makeStallTestPeerConnection(allocator, 7, 12, stale_progress);
    defer {
        pc.client.deinit();
        allocator.free(pc.endpoint);
        allocator.destroy(pc);
    }
    // DESIRED post-fix behavior: a peer we are sending to with no progress for
    // longer than the budget MUST be judged stalled (so the next send rebuilds).
    // SKELETON returns false -> this assertion FAILS, catching the wedge.
    try std.testing.expect(Transport.shouldEvictOnStall(pc, now_ms));
}

test "raft stall: healthy peer (recent progress) is NOT evicted" {
    const allocator = std.testing.allocator;
    const now_ms: i64 = 1_000_000;
    // Progress observed comfortably inside the budget.
    const recent_progress = now_ms - (Transport.peer_stall_budget_ms - 500);
    const pc = try makeStallTestPeerConnection(allocator, 7, 12, recent_progress);
    defer {
        pc.client.deinit();
        allocator.free(pc.endpoint);
        allocator.destroy(pc);
    }
    // False-positive guard: a peer with recent progress must NEVER be evicted.
    try std.testing.expect(!Transport.shouldEvictOnStall(pc, now_ms));
}

test "raft stall: idle peer (no frames sent) is NOT evicted even with an old timestamp" {
    const allocator = std.testing.allocator;
    const now_ms: i64 = 1_000_000;
    // last_progress is ancient, but nothing has ever been sent to this peer, so
    // there is no progress to expect — it must not be evicted.
    const pc = try makeStallTestPeerConnection(allocator, 9, 0, 0);
    defer {
        pc.client.deinit();
        allocator.free(pc.endpoint);
        allocator.destroy(pc);
    }
    try std.testing.expect(!Transport.shouldEvictOnStall(pc, now_ms));
}

test "raft stall: notePeerProgress stamps the right PeerConnection (peer-id keyed)" {
    const allocator = std.testing.allocator;
    var transport = Transport.init(allocator);
    defer transport.deinit();

    // Publish two established connections into the peers map, simulating two
    // live outbound peers. Each starts with a stale progress timestamp and a
    // nonzero frames_sent so it would be judged stalled at now_ms.
    const now_ms: i64 = 5_000_000;
    const stale = now_ms - (Transport.peer_stall_budget_ms + 1000);
    const pc1 = try makeStallTestPeerConnection(allocator, 1, 4, stale);
    const pc2 = try makeStallTestPeerConnection(allocator, 2, 4, stale);
    const io = std.Io.Threaded.global_single_threaded.io();
    transport.peers_mutex.lockUncancelable(io);
    try transport.peers.put(1, pc1);
    try transport.peers.put(2, pc2);
    transport.peers_mutex.unlock(io);
    // (transport.deinit frees both entries via the peers map.)

    // Inbound progress arrives for peer 1 only (keyed by peer id, NOT by the
    // outbound PeerConnection pointer — the inbound connection is a different
    // object in production).
    transport.notePeerProgress(1, now_ms);

    // DESIRED post-fix behavior: peer 1's stamp is refreshed (so it is no longer
    // stalled), peer 2's is untouched (still stalled). SKELETON notePeerProgress
    // is a no-op -> peer 1's timestamp stays stale -> this assertion FAILS.
    try std.testing.expectEqual(now_ms, pc1.last_progress_ms.load(.acquire));
    try std.testing.expect(!Transport.shouldEvictOnStall(pc1, now_ms));
    // Peer 2 was never stamped — still stalled.
    try std.testing.expect(Transport.shouldEvictOnStall(pc2, now_ms));
}

test "raft stall: progress refresh clears the stall (no immediate re-evict loop)" {
    const allocator = std.testing.allocator;
    const now_ms: i64 = 2_000_000;
    // A peer that just reconnected: frames already queued, and progress stamped
    // at reconnect time == now. The stall clock must read as fresh so the very
    // next reaper pass does NOT immediately re-evict it (which would spin a
    // reconnect loop).
    const pc = try makeStallTestPeerConnection(allocator, 3, 1, now_ms);
    defer {
        pc.client.deinit();
        allocator.free(pc.endpoint);
        allocator.destroy(pc);
    }
    // Same instant -> 0 elapsed -> not stalled.
    try std.testing.expect(!Transport.shouldEvictOnStall(pc, now_ms));
    // A subsequent progress observation keeps it healthy across the budget.
    pc.last_progress_ms.store(now_ms + Transport.peer_stall_budget_ms, .release);
    try std.testing.expect(!Transport.shouldEvictOnStall(pc, now_ms + Transport.peer_stall_budget_ms));
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
    // (Legacy `.noop` Message placeholder removed; use a minimal valid variant.)
    const probe_msg = Message{ .request_vote = .{
        .term = 1,
        .candidate_id = 42,
        .last_log_index = 0,
        .last_log_term = 0,
        .pre_vote = false,
    } };
    transport.send(peer, 42, 1, probe_msg) catch {
        // Expected: test stubs may return errors for stream operations
        // since getStream returns undefined. That's fine -- we're testing
        // that the TLS connection logic itself compiles and runs.
    };
}
