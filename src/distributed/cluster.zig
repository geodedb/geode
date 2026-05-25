const std = @import("std");

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

// Zig 0.16 compat: std.Thread.sleep was removed; use raw linux nanosleep.
fn compat_sleepNs(ns: u64) void {
    if (comptime @import("builtin").os.tag == .linux) {
        const req = std.os.linux.timespec{
            .sec = @intCast(ns / std.time.ns_per_s),
            .nsec = @intCast(ns % std.time.ns_per_s),
        };
        var rem: std.os.linux.timespec = undefined;
        _ = std.os.linux.nanosleep(&req, &rem);
    } else {
        // POSIX fallback via libc nanosleep.
        const req = std.c.timespec{
            .sec = @intCast(ns / std.time.ns_per_s),
            .nsec = @intCast(ns % std.time.ns_per_s),
        };
        var rem: std.c.timespec = undefined;
        _ = std.c.nanosleep(&req, &rem);
    }
}

// Zig 0.16 compat: std.process.getEnvVarOwned was removed.
fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) error{ EnvironmentVariableNotFound, OutOfMemory }![]u8 {
    const name_z = allocator.dupeZ(u8, name) catch return error.OutOfMemory;
    defer allocator.free(name_z);
    const ptr = std.c.getenv(name_z) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, std.mem.span(ptr));
}

const Allocator = std.mem.Allocator;
const raft_consensus = @import("raft_consensus.zig");
const RaftNode = raft_consensus.RaftNode;
const graph_store = @import("../graph_store.zig");
const dist_schema = @import("distributed_schema");
const protobuf = @import("protobuf");
const fd = protobuf.fd;
const quic = @import("transport/quic");
const pooled = @import("transport/thread_pool");
const NonceTracker = @import("nonce_tracker.zig").NonceTracker;

const cluster_auth = @import("cluster_auth.zig");
const raft_apply = @import("raft_apply.zig");

const logging = @import("logging");
const log = logging.scoped("cluster");
const Attr = logging.Attr;

pub const cluster_health = @import("cluster_health.zig");
pub const HealthMonitor = cluster_health.HealthMonitor;

fn envFlagEnabled(allocator: std.mem.Allocator, name: []const u8) bool {
    const raw = getEnvVarOwned(allocator, name) catch return false;
    defer allocator.free(raw);
    if (raw.len == 0) return false;
    if (raw[0] == '0') return false;
    if (std.ascii.eqlIgnoreCase(raw, "false")) return false;
    if (std.ascii.eqlIgnoreCase(raw, "off")) return false;
    return true;
}

const MessageType = enum(i32) {
    READ = 0,
    WRITE = 1,
    UPDATE = 2,
    DELETE = 3,
    JOIN_CLUSTER = 4,
    LEAVE_CLUSTER = 5,
    REPLICATE_DATA = 6,
    FAILOVER_REQUEST = 7,
};

// Protobuf-encodable message for distributed operations
const Message = struct {
    msg_type: MessageType = .READ,
    key: ?[]const u8 = null,
    client_id: ?[]const u8 = null,
    data: ?[]const u8 = null,
    /// SEC-D002: Cluster authentication token for JOIN_CLUSTER and other operations.
    auth_token: []const u8 = "",

    pub const _desc_table = .{
        .msg_type = fd(1, .{ .@"enum" = {} }),
        .key = fd(2, .{ .scalar = .string }),
        .client_id = fd(3, .{ .scalar = .string }),
        .data = fd(4, .{ .scalar = .bytes }),
        .auth_token = fd(5, .{ .scalar = .string }),
    };

    pub fn deinit(self: *Message, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

const ResponseStatus = enum(i32) {
    OK = 0,
    ABORTED = 1,
    ERR = 2,
    REDIRECT = 3,
};

const Response = struct {
    status: ResponseStatus = .OK,
    data: ?[]const u8 = null,
    leader_id: ?u64 = null,

    pub const _desc_table = .{
        .status = fd(1, .{ .@"enum" = {} }),
        .data = fd(2, .{ .scalar = .bytes }),
        .leader_id = fd(3, .{ .scalar = .uint64 }),
    };

    pub fn deinit(self: *Response, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

const ReplicationPayload = struct {
    shard_id: u64 = 0,
    snapshot: []const u8 = "",

    pub const _desc_table = .{
        .shard_id = fd(1, .{ .scalar = .uint64 }),
        .snapshot = fd(2, .{ .scalar = .bytes }),
    };

    pub fn deinit(self: *ReplicationPayload, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

/// SEC-D012: Minimal join response that does not leak full cluster topology.
const JoinResponsePayload = struct {
    assigned_node_id: u64 = 0,
    node_count: u32 = 0,
    success: bool = false,

    pub const _desc_table = .{
        .assigned_node_id = fd(1, .{ .scalar = .uint64 }),
        .node_count = fd(2, .{ .scalar = .uint32 }),
        .success = fd(3, .{ .scalar = .bool }),
    };

    pub fn deinit(_: *@This(), _: Allocator) void {}
};

/// SEC-D009: Replay protection guard for Raft frames.
const ReplayGuard = struct {
    mutex: std.Io.Mutex = std.Io.Mutex.init,
    entries: std.AutoHashMap(u128, i64), // key = (from << 64) | term, value = timestamp
    max_entries: usize,
    window_ms: i64,

    fn init(allocator: Allocator, max_entries: usize, window_ms: i64) ReplayGuard {
        return .{
            .entries = std.AutoHashMap(u128, i64).init(allocator),
            .max_entries = max_entries,
            .window_ms = window_ms,
        };
    }

    fn deinit(self: *ReplayGuard) void {
        self.entries.deinit();
    }

    /// Returns true if this (from, term) pair is fresh (not a replay).
    fn check(self: *ReplayGuard, from: u64, term: u64) bool {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        const now = compat_milliTimestamp();
        const key: u128 = (@as(u128, from) << 64) | @as(u128, term);
        if (self.entries.get(key)) |prev_ts| {
            if (now - prev_ts < self.window_ms) return false; // replay
        }
        // Evict oldest if full
        if (self.entries.count() >= self.max_entries) {
            var oldest_key: u128 = 0;
            var oldest_ts: i64 = std.math.maxInt(i64);
            var it = self.entries.iterator();
            while (it.next()) |entry| {
                if (entry.value_ptr.* < oldest_ts) {
                    oldest_ts = entry.value_ptr.*;
                    oldest_key = entry.key_ptr.*;
                }
            }
            _ = self.entries.remove(oldest_key);
        }
        self.entries.put(key, now) catch return true; // allow on OOM
        return true;
    }
};

const NodeInfoProto = struct {
    id: u64 = 0,
    endpoint: []const u8 = "",

    pub const _desc_table = .{
        .id = fd(1, .{ .scalar = .uint64 }),
        .endpoint = fd(2, .{ .scalar = .string }),
    };

    pub fn deinit(self: *NodeInfoProto, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

const TxnMetadata = struct {
    client_id: []const u8 = "",
    timestamp: i64 = 0,
    msg_type: MessageType = .READ,

    pub const _desc_table = .{
        .client_id = fd(1, .{ .scalar = .string }),
        .timestamp = fd(2, .{ .scalar = .int64 }),
        .msg_type = fd(3, .{ .@"enum" = {} }),
    };

    pub fn deinit(self: *TxnMetadata, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

const TopologyNode = struct {
    id: u64 = 0,
    endpoint: []const u8 = "",
    state: []const u8 = "",

    pub const _desc_table = .{
        .id = fd(1, .{ .scalar = .uint64 }),
        .endpoint = fd(2, .{ .scalar = .string }),
        .state = fd(3, .{ .scalar = .string }),
    };

    pub fn deinit(self: *TopologyNode, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

const TopologyShard = struct {
    id: u64 = 0,
    primary_node: u64 = 0,
    replica_count: u32 = 0,
    size_bytes: u64 = 0,

    pub const _desc_table = .{
        .id = fd(1, .{ .scalar = .uint64 }),
        .primary_node = fd(2, .{ .scalar = .uint64 }),
        .replica_count = fd(3, .{ .scalar = .uint32 }),
        .size_bytes = fd(4, .{ .scalar = .uint64 }),
    };

    pub fn deinit(self: *TopologyShard, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

const TopologyPayload = struct {
    nodes: std.ArrayList(TopologyNode),
    shards: std.ArrayList(TopologyShard),

    pub const _desc_table = .{
        .nodes = fd(1, .{ .repeated = .{ .submessage = {} } }),
        .shards = fd(2, .{ .repeated = .{ .submessage = {} } }),
    };

    pub fn deinit(self: *TopologyPayload, allocator: std.mem.Allocator) void {
        protobuf.deinit(allocator, self);
    }
};

// Distributed cluster coordinator
pub const ClusterCoordinator = struct {
    allocator: Allocator,
    node_id: u64,
    raft: *RaftNode,
    store: *graph_store.GraphStore,
    replication_factor: u32,
    sharding_strategy: ShardingStrategy,
    failover_config: FailoverConfig,
    cluster_state: ClusterState,
    network_transport: NetworkTransport,
    health_monitor: HealthMonitor,
    /// SEC-D009: Nonce tracker for Raft frame replay protection.
    raft_nonce_tracker: NonceTracker,
    /// SEC-D009: Replay guard for (from, term) deduplication.
    replay_guard: ReplayGuard,
    message_callback: ?*const fn (*ClusterCoordinator, *const Message) void = null,
    // PERF-D006: Connection semaphore to limit concurrent cluster threads
    active_connections: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    /// Maximum simultaneous inbound peer connections (sourced from
    /// Config.max_connections at init time).  PERF-D006.
    max_connections: u32 = 100,

    // === Cluster bootstrap state (Task A3/A3b/A3c of 2026-05-25 plan) ===
    // Mirrored from Config so background loops can read them without
    // re-touching the Config struct.  All three are stored by reference;
    // the caller is responsible for keeping the backing memory alive for
    // the lifetime of the coordinator.
    /// Address `networkLoop` binds the intra-cluster listener to.
    listen_address: []const u8 = "0.0.0.0",
    /// Port `networkLoop` binds the intra-cluster listener to.
    cluster_port: u16 = 4242,
    /// Pre-shared token validated on every inbound cluster connection.
    /// Empty string disables the auth check (used by A3f).
    cluster_token: []const u8 = "",
    /// Cluster name, used for OTel attributes and operator-facing logs.
    cluster_name: []const u8 = "geode-cluster",

    // QUAL-D004: Shutdown signal and pool handles for graceful stop.
    shutdown: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    raft_pool: ?*pooled.ThreadPool = null,
    network_pool: ?*pooled.ThreadPool = null,
    health_pool: ?*pooled.ThreadPool = null,
    replication_pool: ?*pooled.ThreadPool = null,
    connection_pool: ?*pooled.ThreadPool = null,

    // Helper to access replication map
    fn replication_map(self: *ClusterCoordinator) std.AutoHashMap(u64, []u64) {
        return self.cluster_state.replication_map;
    }

    const Self = @This();

    pub const ShardingStrategy = enum {
        hash_based,
        range_based,
        graph_based,
        custom,
    };

    pub const FailoverConfig = struct {
        auto_failover: bool = true,
        failover_timeout_ms: u64 = 5000,
        min_replicas: u32 = 2,
        max_failover_attempts: u32 = 3,
        backoff_multiplier: f32 = 1.5,
    };

    pub const ClusterState = struct {
        nodes: std.ArrayList(NodeInfo),
        shards: std.ArrayList(ShardInfo),
        replication_map: std.AutoHashMap(u64, []u64),
        leader_node: ?u64,
        cluster_version: u64,
        topology_version: u64,
    };

    pub const NodeInfo = struct {
        id: u64,
        endpoint: []const u8,
        state: NodeState,
        role: NodeRole,
        capacity: NodeCapacity,
        last_heartbeat: i64,
        metadata: std.StringHashMap([]const u8),
    };

    pub const NodeState = enum {
        joining,
        active,
        leaving,
        failed,
        maintenance,
    };

    pub const NodeRole = enum {
        leader,
        follower,
        candidate,
        observer,
    };

    pub const NodeCapacity = struct {
        cpu_cores: u32,
        memory_gb: u32,
        storage_gb: u32,
        network_mbps: u32,
        current_load: f32,
    };

    pub const ShardInfo = struct {
        id: u64,
        primary_node: u64,
        replica_nodes: []u64,
        key_range: KeyRange,
        size_bytes: u64,
        record_count: u64,
    };

    pub const KeyRange = struct {
        start: []const u8,
        end: []const u8,

        pub fn contains(self: KeyRange, key: []const u8) bool {
            return std.mem.order(u8, key, self.start) != .lt and
                std.mem.order(u8, key, self.end) != .gt;
        }
    };

    pub const NetworkTransport = struct {
        allocator: Allocator,
        quic_server: ?quic.QuicTransport,
        connections: std.AutoHashMap(u64, Connection),
        message_queue: MessageQueue,
        /// Task A3c (2026-05-25 plan): cap on simultaneous inbound peer
        /// connections, sourced from `Config.max_connections`.  Mirrors the
        /// coordinator-level field for callers that only have a pointer to
        /// the transport.
        max_connections: u32 = 256,

        pub const Connection = struct {
            stream: *quic.QuicStream,
            node_id: u64,
            last_activity: i64,
            pending_requests: std.ArrayList(PendingRequest),
        };

        pub const PendingRequest = struct {
            id: u64,
            timeout: i64,
            callback: *const fn (response: Response) void,
        };

        pub const MessageQueue = struct {
            incoming: std.ArrayList(IncomingMessage),
            outgoing: std.ArrayList(OutgoingMessage),
            mutex: std.Io.Mutex,
        };

        pub const IncomingMessage = struct {
            from: u64,
            data: []const u8,
            received_at: i64,
        };

        pub const OutgoingMessage = struct {
            to: u64,
            data: []const u8,
            priority: u32,
            retry_count: u32,
        };
    };

    pub fn init(
        allocator: Allocator,
        node_id: u64,
        config: Config,
    ) !ClusterCoordinator {
        const peers = try resolvePeers(allocator, config.peers);
        // RaftNode.init() already returns a heap-owned *RaftNode (it does the
        // create() inside).  The previous code double-allocated by calling
        // allocator.create(RaftNode) and then assigning raft.* = init(...),
        // which doesn't even type-check (init returns a pointer, not a
        // value).  As with resolvePeers above, this path was never reached
        // from production until the A3 test forced full type resolution.
        const raft = try RaftNode.init(
            allocator,
            node_id,
            peers,
            config.election_timeout_ms,
        );

        const store = graph_store.getGlobalStore(allocator);

        // Wire the Raft apply callback so committed entries are routed to
        // the graph store.  The module-level store reference must be set
        // before the raft node starts ticking.
        raft_apply.setGlobalStore(store);
        raft.apply_callback = &raft_apply.applyCallbackFn;

        return ClusterCoordinator{
            .allocator = allocator,
            .node_id = node_id,
            .raft = raft,
            .store = store,
            .replication_factor = config.replication_factor,
            .sharding_strategy = config.sharding_strategy,
            .failover_config = config.failover_config,
            .cluster_state = try initClusterState(allocator),
            .network_transport = try initNetworkTransport(allocator, config),
            .health_monitor = try initHealthMonitor(allocator, config),
            .raft_nonce_tracker = try NonceTracker.init(allocator, 10000),
            .replay_guard = ReplayGuard.init(allocator, 1024, 30_000),
            // Task A3/A3b/A3c: mirror cluster bootstrap fields from Config
            // so networkLoop and the auth path can read them without
            // re-touching the Config struct.
            .max_connections = config.max_connections,
            .listen_address = config.listen_address,
            .cluster_port = config.cluster_port,
            .cluster_token = config.cluster_token,
            .cluster_name = config.cluster_name,
        };
    }

    pub fn deinit(self: *ClusterCoordinator) void {
        self.stop();
        self.raft_nonce_tracker.deinit();
        self.replay_guard.deinit();
        // resolvePeers duped each peer.endpoint into self.allocator; raft's
        // own deinit doesn't reclaim them, so free them here before the
        // backing slice goes away.
        for (self.raft.peers) |peer| {
            if (peer.endpoint.len > 0) self.allocator.free(peer.endpoint);
        }
        self.allocator.free(self.raft.peers);
        self.raft.deinit();
        self.allocator.destroy(self.raft);
        for (self.cluster_state.nodes.items) |*node| {
            if (node.endpoint.len > 0) {
                self.allocator.free(node.endpoint);
            }
            var meta_it = node.metadata.iterator();
            while (meta_it.next()) |entry| {
                self.allocator.free(entry.key_ptr.*);
                self.allocator.free(entry.value_ptr.*);
            }
            node.metadata.deinit();
        }
        self.cluster_state.nodes.deinit(self.allocator);
        for (self.cluster_state.shards.items) |shard| {
            if (shard.replica_nodes.len > 0) {
                self.allocator.free(shard.replica_nodes);
            }
        }
        self.cluster_state.shards.deinit(self.allocator);
        self.cluster_state.replication_map.deinit();

        var conn_it = self.network_transport.connections.iterator();
        while (conn_it.next()) |entry| {
            entry.value_ptr.pending_requests.deinit(self.allocator);
        }
        self.network_transport.connections.deinit();
        for (self.network_transport.message_queue.incoming.items) |msg| {
            if (msg.data.len > 0) {
                self.allocator.free(msg.data);
            }
        }
        for (self.network_transport.message_queue.outgoing.items) |msg| {
            if (msg.data.len > 0) {
                self.allocator.free(msg.data);
            }
        }
        self.network_transport.message_queue.incoming.deinit(self.allocator);
        self.network_transport.message_queue.outgoing.deinit(self.allocator);
        if (self.network_transport.quic_server) |*server| {
            server.deinit();
        }

        self.health_monitor.health_checks.deinit(self.allocator);
    }

    // QUAL-D004: start() spawns background threads and returns immediately.
    // Call stop() (or deinit()) to signal shutdown and join all threads.
    pub fn start(self: *ClusterCoordinator) !void {
        self.shutdown.store(false, .release);
        self.connection_pool = try pooled.ThreadPool.init(self.allocator, .{
            .num_threads = 4,
            .queue_capacity = 128,
        });
        errdefer {
            self.connection_pool.?.deinit();
            self.connection_pool = null;
        }
        self.raft_pool = try startLoopPool(self, runRaftLoop);
        errdefer {
            self.raft_pool.?.deinit();
            self.raft_pool = null;
        }
        self.network_pool = try startLoopPool(self, runNetworkLoop);
        errdefer {
            self.network_pool.?.deinit();
            self.network_pool = null;
        }
        self.health_pool = try startLoopPool(self, runHealthLoop);
        errdefer {
            self.health_pool.?.deinit();
            self.health_pool = null;
        }
        self.replication_pool = try startLoopPool(self, runReplicationLoop);
        errdefer {
            self.replication_pool.?.deinit();
            self.replication_pool = null;
        }
    }

    pub fn stop(self: *ClusterCoordinator) void {
        // Signal shutdown FIRST so every loop sees `shutdown == true` on its
        // next check.  networkLoop polls inside accept() (50ms slices) so it
        // exits within one polling cycle; the other loops sleep-poll on
        // `shutdown` between work units.
        self.shutdown.store(true, .release);

        // Join the worker threads BEFORE destroying the QUIC server.  An
        // earlier revision tore down `quic_server` while the network thread
        // was still inside `waitForAccepted`, which races with that thread's
        // `orderedRemove(0)` on `endpoint.accepted` and segfaults under the
        // bootstrap tests (A4b reproducer).  Pool.deinit() blocks until the
        // worker thread returns, so doing it first means the network loop
        // has fully unwound by the time we touch the server.
        if (self.raft_pool) |pool| {
            pool.deinit();
            self.raft_pool = null;
        }
        if (self.network_pool) |pool| {
            pool.deinit();
            self.network_pool = null;
        }
        if (self.health_pool) |pool| {
            pool.deinit();
            self.health_pool = null;
        }
        if (self.replication_pool) |pool| {
            pool.deinit();
            self.replication_pool = null;
        }
        if (self.connection_pool) |pool| {
            pool.deinit();
            self.connection_pool = null;
        }

        // Now that no thread can still be in accept(), it is safe to free
        // the QUIC server.  deinit() is the only place that ever destroys
        // it; networkLoop only reads `quic_server.?` while it holds a
        // reference to the same pointer this code is about to free.
        if (self.network_transport.quic_server) |*server| {
            server.deinit();
            self.network_transport.quic_server = null;
        }
    }

    fn raftLoop(self: *ClusterCoordinator) !void {
        while (!self.shutdown.load(.acquire)) {
            try self.raft.tick();
            compat_sleepNs(10 * std.time.ns_per_ms);
        }
    }

    fn networkLoop(self: *ClusterCoordinator) !void {
        // Initialize (or reuse) QUIC server transport.
        //
        // Task A3b (2026-05-25 plan): bind to `self.listen_address` and
        // `self.cluster_port` from the Config instead of the hardcoded
        // `0.0.0.0:quic.DEFAULT_PORT`.  Without this fix, two coordinators
        // on one host both race to grab port 3141 and one of them fails
        // EADDRINUSE — which is exactly the case the harness multi-node
        // smoke tests want to cover.
        if (self.network_transport.quic_server == null) {
            const qt = try quic.QuicTransport.init(self.allocator, .{
                .address = self.listen_address,
                .port = self.cluster_port,
            });
            self.network_transport.quic_server = qt;
            try self.network_transport.quic_server.?.listen();
        }

        while (!self.shutdown.load(.acquire)) {
            const conn = self.network_transport.quic_server.?.accept() catch |err| switch (err) {
                error.WouldBlock => continue,
                else => {
                    if (self.shutdown.load(.acquire)) break;
                    log.err("Accept failed", &.{Attr.string("error", @errorName(err))});
                    continue;
                },
            };

            // PERF-D006: Connection semaphore - reject if at capacity
            if (self.active_connections.load(.acquire) >= self.max_connections) {
                log.warn("Connection limit reached, rejecting new connection", &.{
                    Attr.uint("active", self.active_connections.load(.acquire)),
                    Attr.uint("max", self.max_connections),
                });
                // Connection will be cleaned up when it goes out of scope
                continue;
            }

            if (self.connection_pool) |pool| {
                const ctx = try self.allocator.create(ConnectionTaskCtx);
                errdefer self.allocator.destroy(ctx);
                ctx.* = .{
                    .allocator = self.allocator,
                    .coordinator = self,
                    .conn = conn,
                };
                if (!pool.submit(.{
                    .context = @ptrCast(ctx),
                    .callback = runConnectionTask,
                })) {
                    self.allocator.destroy(ctx);
                    log.warn("Connection pool saturated, dropping cluster connection", &.{});
                }
            }
        }
    }

    fn healthLoop(self: *ClusterCoordinator) !void {
        while (!self.shutdown.load(.acquire)) {
            for (self.cluster_state.nodes.items) |*node| {
                if (node.id == self.node_id) continue;

                const health_status = try self.checkNodeHealth(node);
                try self.updateHealthStatus(node.id, health_status);

                if (health_status == .unhealthy) {
                    try self.handleNodeFailure(node.id);
                }
            }

            compat_sleepNs(self.health_monitor.check_interval_ms * std.time.ns_per_ms);
        }
    }

    fn replicationLoop(self: *ClusterCoordinator) !void {
        while (!self.shutdown.load(.acquire)) {
            if (self.raft.state == .leader) {
                try self.performReplication();
            }
            compat_sleepNs(100 * std.time.ns_per_ms);
        }
    }

    const ConnectionTaskCtx = struct {
        allocator: Allocator,
        coordinator: *ClusterCoordinator,
        conn: *quic.QuicConnection,
    };

    fn startLoopPool(self: *ClusterCoordinator, callback: *const fn (*anyopaque) void) !*pooled.ThreadPool {
        const pool = try pooled.ThreadPool.init(self.allocator, .{
            .num_threads = 1,
            .queue_capacity = 4,
        });
        errdefer pool.deinit();
        try pool.submitBlocking(.{
            .context = @ptrCast(self),
            .callback = callback,
        });
        return pool;
    }

    fn runRaftLoop(ctx: *anyopaque) void {
        const self: *ClusterCoordinator = @ptrCast(@alignCast(ctx));
        self.raftLoop() catch |err| {
            log.err("Raft loop failed", &.{Attr.string("error", @errorName(err))});
        };
    }

    fn runNetworkLoop(ctx: *anyopaque) void {
        const self: *ClusterCoordinator = @ptrCast(@alignCast(ctx));
        self.networkLoop() catch |err| {
            log.err("Network loop failed", &.{Attr.string("error", @errorName(err))});
        };
    }

    fn runHealthLoop(ctx: *anyopaque) void {
        const self: *ClusterCoordinator = @ptrCast(@alignCast(ctx));
        self.healthLoop() catch |err| {
            log.err("Health loop failed", &.{Attr.string("error", @errorName(err))});
        };
    }

    fn runReplicationLoop(ctx: *anyopaque) void {
        const self: *ClusterCoordinator = @ptrCast(@alignCast(ctx));
        self.replicationLoop() catch |err| {
            log.err("Replication loop failed", &.{Attr.string("error", @errorName(err))});
        };
    }

    fn runConnectionTask(ctx: *anyopaque) void {
        const task_ctx: *ConnectionTaskCtx = @ptrCast(@alignCast(ctx));
        defer task_ctx.allocator.destroy(task_ctx);
        task_ctx.coordinator.handleQuicConnection(task_ctx.conn) catch |err| {
            log.err("Cluster connection handler failed", &.{Attr.string("error", @errorName(err))});
        };
    }

    fn handleQuicConnection(self: *ClusterCoordinator, conn: *quic.QuicConnection) !void {
        // PERF-D006: Track active connections
        _ = self.active_connections.fetchAdd(1, .release);
        defer _ = self.active_connections.fetchSub(1, .release);

        // Accept a single stream (simple model for now)
        const stream = try conn.acceptStream();
        // Stream/connection cleanup handled by transport on deinit (no explicit close)
        while (true) {
            const frame_res = raft_consensus.readRaftFrame(self.allocator, stream) catch |err| switch (err) {
                error.EndOfStream => break,
                error.WouldBlock => {
                    compat_sleepNs(200 * std.time.ns_per_us);
                    continue;
                },
                else => return err,
            };
            defer frame_res.deinit(self.allocator);

            // SEC-D001: Always validate cluster token on incoming Raft frames.
            // Reject frames without valid token regardless of whether env var is set.
            if (!cluster_auth.validateClusterToken(frame_res.auth_token)) {
                log.warn("Raft frame rejected: invalid or missing cluster token", &.{
                    Attr.uint("from", frame_res.from),
                });
                continue;
            }

            // SEC-D009: Validate nonce to prevent replay attacks.
            if (!self.raft_nonce_tracker.checkAndRecord(frame_res.nonce)) {
                log.warn("Raft frame rejected: replay or missing nonce", &.{
                    Attr.uint("from", frame_res.from),
                    Attr.uint("nonce", frame_res.nonce),
                });
                continue;
            }

            // SEC-D009: Reject replayed frames
            if (!self.replay_guard.check(frame_res.from, frame_res.term)) {
                log.warn("Rejected replayed Raft frame", &.{
                    Attr.uint("from", frame_res.from),
                    Attr.uint("term", frame_res.term),
                });
                continue;
            }

            self.raft.handleMessage(frame_res.from, frame_res.body) catch |e| {
                log.err("Raft handleMessage error", &.{
                    Attr.string("error", @errorName(e)),
                });
            };
        }
    }

    fn handleClusterMessage(self: *ClusterCoordinator, msg: Message) !Response {
        // Route based on message type
        return self.handleShardQuery(msg);
    }

    fn handleJoinCluster(self: *ClusterCoordinator, msg: Message) !Response {
        // SEC-D002: Always validate cluster token before revealing topology.
        // Reject join requests without valid token regardless of whether env var is set.
        if (!cluster_auth.validateClusterToken(msg.auth_token)) {
            log.warn("JOIN_CLUSTER rejected: invalid or missing cluster token", &.{
                Attr.string("client_id", msg.client_id orelse "unknown"),
            });
            return Response{
                .status = .ERR,
                .data = null,
            };
        }

        if (self.raft.state != .leader) {
            return Response{
                .status = .REDIRECT,
                .leader_id = self.cluster_state.leader_node,
            };
        }

        const node_info = try parseNodeInfo(self.allocator, msg.data orelse return error.InvalidNodeInfo);
        try self.cluster_state.nodes.append(node_info);

        // Trigger rebalancing
        try self.rebalanceShards();

        return Response{
            .status = .OK,
            .data = try self.serializeMinimalJoinResponse(node_info.id),
        };
    }

    fn handleNodeFailure(self: *ClusterCoordinator, failed_node: u64) !void {
        log.warn("Node detected as failed", &.{
            Attr.uint("node_id", failed_node),
        });

        if (!self.failover_config.auto_failover) return;

        // Find shards affected by the failure
        for (self.cluster_state.shards.items) |*shard| {
            if (shard.primary_node == failed_node) {
                try self.promoteReplica(shard);
            }

            // Remove from replica list
            const new_replicas = try self.allocator.alloc(u64, shard.replica_nodes.len - 1);
            var idx: usize = 0;
            for (shard.replica_nodes) |replica| {
                if (replica != failed_node) {
                    new_replicas[idx] = replica;
                    idx += 1;
                }
            }
            shard.replica_nodes = new_replicas;
        }

        // Update cluster state
        for (self.cluster_state.nodes.items, 0..) |*node, i| {
            if (node.id == failed_node) {
                node.state = .failed;
                _ = self.cluster_state.nodes.swapRemove(i);
                break;
            }
        }

        // Trigger re-replication to maintain replication factor
        try self.ensureReplicationFactor();
    }

    fn promoteReplica(self: *ClusterCoordinator, shard: *ShardInfo) !void {
        if (shard.replica_nodes.len == 0) {
            return error.NoReplicasAvailable;
        }

        // Choose the most up-to-date replica
        var best_replica: u64 = shard.replica_nodes[0];
        var best_lag: u64 = std.math.maxInt(u64);

        for (shard.replica_nodes) |replica| {
            const lag = try self.getReplicationLag(replica, shard.id);
            if (lag < best_lag) {
                best_lag = lag;
                best_replica = replica;
            }
        }

        log.info("Promoting replica to primary for shard", &.{
            Attr.uint("replica_id", best_replica),
            Attr.uint("shard_id", shard.id),
        });
        shard.primary_node = best_replica;

        // Remove from replica list
        const new_replicas = try self.allocator.alloc(u64, shard.replica_nodes.len - 1);
        var idx: usize = 0;
        for (shard.replica_nodes) |replica| {
            if (replica != best_replica) {
                new_replicas[idx] = replica;
                idx += 1;
            }
        }
        shard.replica_nodes = new_replicas;
    }

    fn ensureReplicationFactor(self: *ClusterCoordinator) !void {
        for (self.cluster_state.shards.items) |*shard| {
            const current_replicas = shard.replica_nodes.len + 1; // +1 for primary

            if (current_replicas < self.replication_factor) {
                const needed = self.replication_factor - current_replicas;
                const available_nodes = try self.getAvailableNodes(shard);

                if (available_nodes.len < needed) {
                    log.warn("Insufficient nodes to maintain replication factor for shard", &.{
                        Attr.uint("shard_id", shard.id),
                    });
                    continue;
                }

                // Add new replicas
                const new_replicas = try self.allocator.alloc(u64, shard.replica_nodes.len + needed);
                // Zig 0.16: std.mem.copy was removed; use @memcpy.
                @memcpy(new_replicas[0..shard.replica_nodes.len], shard.replica_nodes);

                for (0..needed) |i| {
                    new_replicas[shard.replica_nodes.len + i] = available_nodes[i];
                    try self.startReplication(shard.id, available_nodes[i]);
                }

                self.allocator.free(shard.replica_nodes);
                shard.replica_nodes = new_replicas;
            }
        }
    }

    fn performReplication(self: *ClusterCoordinator) !void {
        for (self.cluster_state.shards.items) |shard| {
            if (shard.primary_node != self.node_id) continue;

            for (shard.replica_nodes) |replica| {
                try self.replicateShardToNode(shard.id, replica);
            }
        }
    }

    fn replicateShardToNode(self: *ClusterCoordinator, shard_id: u64, node_id: u64) !void {
        // Checkpoint adapter storage before snapshotting.
        try self.store.saveToFile();
        // Serialize all nodes and edges as JSON-lines for replication.
        const snapshot = try self.store.serializeSnapshot(self.allocator);

        var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(self.allocator, 256);
        defer aw.deinit();
        const payload_msg = ReplicationPayload{
            .shard_id = shard_id,
            .snapshot = snapshot,
        };
        try protobuf.encode(&aw.writer, self.allocator, payload_msg);
        const payload = try self.allocator.dupe(u8, aw.writer.buffer[0..aw.writer.end]);
        defer self.allocator.free(payload);

        const msg = Message{
            .msg_type = .REPLICATE_DATA,
            .data = payload,
        };

        try self.sendToNode(node_id, msg);
    }

    // Helper functions
    // NOTE: `Peer` is a module-level type in raft_consensus.zig (not nested
    // inside RaftNode), so the qualified reference is `raft_consensus.Peer`,
    // not `RaftNode.Peer`.  Previously this miscoded reference compiled only
    // because `init` is never called from the main library — the type check
    // was lazily deferred.  The first test that actually constructs a
    // ClusterCoordinator (tests/test_cluster_coordinator_config.zig, A3)
    // forced the compiler to resolve the symbol.
    fn resolvePeers(allocator: Allocator, peer_configs: []const PeerConfig) ![]raft_consensus.Peer {
        var peers = try allocator.alloc(raft_consensus.Peer, peer_configs.len);
        for (peer_configs, 0..) |config, i| {
            peers[i] = .{
                .id = config.id,
                .endpoint = try allocator.dupe(u8, config.address),
                .port = config.port,
                .alive = true,
                .last_contact = compat_milliTimestamp(),
                .rpc_client = null,
            };
        }
        return peers;
    }

    fn initClusterState(allocator: Allocator) !ClusterState {
        // Zig 0.16 std.ArrayList is now unmanaged by default — there is no
        // `init(allocator)` on Aligned(T, null).  The previous code only
        // type-checked because ClusterCoordinator.init was never invoked
        // from production.  The A3 test changed that.  We use `.empty` for
        // the unmanaged ArrayLists; AutoHashMap is still managed in 0.16
        // so its `.init(allocator)` survives.
        return ClusterState{
            .nodes = .empty,
            .shards = .empty,
            .replication_map = std.AutoHashMap(u64, []u64).init(allocator),
            .leader_node = null,
            .cluster_version = 1,
            .topology_version = 1,
        };
    }

    fn findNodeEndpoint(self: *ClusterCoordinator, node_id: u64) ![]const u8 {
        for (self.cluster_state.nodes.items) |node| {
            if (node.id == node_id) return node.endpoint;
        }
        return error.NodeNotFound;
    }

    fn initNetworkTransport(allocator: Allocator, config: Config) !NetworkTransport {
        // Task A3c (2026-05-25 plan): consume Config — previously this
        // function threw the argument away with `_ = config;`, which meant
        // there was no way to plumb operator-controlled limits down to the
        // transport layer.  We currently only need `max_connections` here;
        // future tasks (A3f auth, etc.) can grow this struct as needed.
        return NetworkTransport{
            .allocator = allocator,
            .quic_server = null,
            .connections = std.AutoHashMap(u64, NetworkTransport.Connection).init(allocator),
            .message_queue = .{
                .incoming = .empty,
                .outgoing = .empty,
                .mutex = std.Io.Mutex.init,
            },
            .max_connections = config.max_connections,
        };
    }

    fn initHealthMonitor(allocator: Allocator, config: Config) !HealthMonitor {
        return HealthMonitor.init(allocator, config.health_check_interval_ms, config.unhealthy_threshold);
    }

    fn checkNodeHealth(self: *ClusterCoordinator, node: *NodeInfo) !HealthMonitor.HealthStatus {
        _ = self;
        return HealthMonitor.evaluateNodeHealth(node.last_heartbeat);
    }

    fn updateHealthStatus(self: *ClusterCoordinator, node_id: u64, status: HealthMonitor.HealthStatus) !void {
        try self.health_monitor.updateHealthStatus(node_id, status);
    }

    // CANARY: REQ=REQ-DIST-CLUSTER-001; FEATURE="DistributedCluster"; ASPECT=ReplicationLag; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-01
    fn getReplicationLag(self: *ClusterCoordinator, node_id: u64, shard_id: u64) !u64 {
        // Calculate replication lag based on node health check latency
        // In a real implementation, this would compare snapshot generations between primary and replica
        for (self.cluster_state.shards.items) |*shard| {
            if (shard.id == shard_id) {
                // Check if node is a replica for this shard
                for (shard.replica_nodes) |replica| {
                    if (replica == node_id) {
                        return self.health_monitor.estimateReplicationLag(node_id, shard.size_bytes);
                    }
                }
            }
        }
        // Node is not a replica for this shard
        return 0;
    }

    fn getAvailableNodes(self: *ClusterCoordinator, shard: *ShardInfo) ![]u64 {
        // Zig 0.16: std.ArrayList is unmanaged — pass allocator to every op.
        var available: std.ArrayList(u64) = .empty;
        defer available.deinit(self.allocator);

        for (self.cluster_state.nodes.items) |node| {
            if (node.state != .active) continue;
            if (node.id == shard.primary_node) continue;

            var is_replica = false;
            for (shard.replica_nodes) |replica| {
                if (replica == node.id) {
                    is_replica = true;
                    break;
                }
            }
            if (is_replica) continue;

            try available.append(self.allocator, node.id);
        }

        return available.toOwnedSlice(self.allocator);
    }

    // CANARY: REQ=REQ-DIST-CLUSTER-002; FEATURE="DistributedCluster"; ASPECT=Replication; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-01
    fn startReplication(self: *ClusterCoordinator, shard_id: u64, node_id: u64) !void {
        log.info("Starting replication of shard to node", &.{
            Attr.uint("shard_id", shard_id),
            Attr.uint("node_id", node_id),
        });

        // Find the shard and add the node as a replica
        for (self.cluster_state.shards.items) |*shard| {
            if (shard.id == shard_id) {
                // Check if node is already a replica
                for (shard.replica_nodes) |replica| {
                    if (replica == node_id) {
                        log.info("Node is already a replica for shard", &.{
                            Attr.uint("node_id", node_id),
                            Attr.uint("shard_id", shard_id),
                        });
                        return;
                    }
                }

                // Add node as a replica (create new slice with additional node)
                const new_replicas = try self.allocator.alloc(u64, shard.replica_nodes.len + 1);
                @memcpy(new_replicas[0..shard.replica_nodes.len], shard.replica_nodes);
                new_replicas[shard.replica_nodes.len] = node_id;

                // Free old replica list and update
                if (shard.replica_nodes.len > 0) {
                    self.allocator.free(shard.replica_nodes);
                }
                shard.replica_nodes = new_replicas;

                log.info("Added node as replica for shard", &.{
                    Attr.uint("node_id", node_id),
                    Attr.uint("shard_id", shard_id),
                    Attr.uint("total_replicas", new_replicas.len),
                });
                return;
            }
        }

        log.warn("Shard not found for replication", &.{
            Attr.uint("shard_id", shard_id),
        });
    }

    // CANARY: REQ=REQ-DIST-CLUSTER-003; FEATURE="DistributedCluster"; ASPECT=Rebalance; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-01
    fn rebalanceShards(self: *ClusterCoordinator) !void {
        const node_count = self.cluster_state.nodes.items.len;
        if (node_count == 0) {
            log.warn("No nodes available for rebalancing", &.{});
            return;
        }

        log.info("Rebalancing shards across nodes", &.{
            Attr.uint("node_count", node_count),
        });

        // Calculate target shards per node
        const shard_count = self.cluster_state.shards.items.len;
        const target_per_node = (shard_count + node_count - 1) / node_count; // Round up

        // Count current shards per node
        var shards_per_node = std.AutoHashMap(u64, usize).init(self.allocator);
        defer shards_per_node.deinit();

        for (self.cluster_state.shards.items) |shard| {
            const entry = try shards_per_node.getOrPut(shard.primary_node);
            if (!entry.found_existing) {
                entry.value_ptr.* = 0;
            }
            entry.value_ptr.* += 1;
        }

        // Find overloaded and underloaded nodes
        var moves_needed: usize = 0;
        for (self.cluster_state.nodes.items) |node| {
            const current = shards_per_node.get(node.id) orelse 0;
            if (current > target_per_node) {
                moves_needed += current - target_per_node;
            }
        }

        log.info("Rebalance analysis", &.{
            Attr.uint("shard_count", shard_count),
            Attr.uint("node_count", node_count),
            Attr.uint("target_per_node", target_per_node),
            Attr.uint("moves_needed", moves_needed),
        });
    }

    // CANARY: REQ=REQ-DIST-CLUSTER-004; FEATURE="DistributedCluster"; ASPECT=Topology; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-01
    fn serializeClusterTopology(self: *ClusterCoordinator) ![]const u8 {
        var nodes = std.ArrayList(TopologyNode).init(self.allocator);
        defer nodes.deinit(self.allocator);

        for (self.cluster_state.nodes.items) |node| {
            try nodes.append(self.allocator, TopologyNode{
                .id = node.id,
                .endpoint = node.endpoint,
                .state = @tagName(node.state),
            });
        }

        var shards = std.ArrayList(TopologyShard).init(self.allocator);
        defer shards.deinit(self.allocator);

        for (self.cluster_state.shards.items) |shard| {
            try shards.append(self.allocator, TopologyShard{
                .id = shard.id,
                .primary_node = shard.primary_node,
                .replica_count = @intCast(shard.replica_nodes.len),
                .size_bytes = shard.size_bytes,
            });
        }

        const payload = TopologyPayload{
            .nodes = nodes,
            .shards = shards,
        };

        var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(self.allocator, 256);
        defer aw.deinit();
        try protobuf.encode(&aw.writer, self.allocator, payload);
        const body = aw.writer.buffer[0..aw.writer.end];
        return self.allocator.dupe(u8, body);
    }

    /// SEC-D012: Build a minimal join response that reveals only the assigned
    /// node ID, the current node count, and a success flag -- no topology.
    fn serializeMinimalJoinResponse(self: *ClusterCoordinator, assigned_id: u64) ![]const u8 {
        const payload = JoinResponsePayload{
            .assigned_node_id = assigned_id,
            .node_count = @intCast(self.cluster_state.nodes.items.len),
            .success = true,
        };
        var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(self.allocator, 64);
        defer aw.deinit();
        try protobuf.encode(&aw.writer, self.allocator, payload);
        return self.allocator.dupe(u8, aw.writer.buffer[0..aw.writer.end]);
    }

    fn parseNodeInfo(allocator: Allocator, data: []const u8) !NodeInfo {
        var reader: std.Io.Reader = .fixed(data);
        var parsed = protobuf.decode(NodeInfoProto, &reader, allocator) catch |e| {
            log.warn("parseNodeInfo protobuf error", &.{
                Attr.string("error", @errorName(e)),
            });
            return error.InvalidNodeInfo;
        };
        defer parsed.deinit(allocator);

        const endpoint_val = if (parsed.endpoint.len > 0) parsed.endpoint else "unknown:0";
        const endpoint_copy = try allocator.dupe(u8, endpoint_val);
        return NodeInfo{
            .id = parsed.id,
            .endpoint = endpoint_copy,
            .state = .joining,
            .role = .follower,
            .capacity = .{
                .cpu_cores = 8,
                .memory_gb = 16,
                .storage_gb = 100,
                .network_mbps = 1000,
                .current_load = 0.0,
            },
            .last_heartbeat = compat_milliTimestamp(),
            .metadata = std.StringHashMap([]const u8).init(allocator),
        };
    }

    // CANARY: REQ=REQ-GQL-020; FEATURE="Cluster QUIC Messaging"; ASPECT=SendToNode; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-05
    pub fn sendToNode(self: *ClusterCoordinator, node_id: u64, msg: Message) !void {
        const endpoint = try self.findNodeEndpoint(node_id);
        const colon_idx = std.mem.lastIndexOf(u8, endpoint, ":") orelse return error.InvalidAddress;
        const host = endpoint[0..colon_idx];
        const port = try std.fmt.parseInt(u16, endpoint[colon_idx + 1 ..], 10);

        var client = quic.QuicClient.init(self.allocator);
        defer client.deinit();

        // GAP-0737 / SEC-INFRA-01 (2026-04-16): route through the single
        // cluster_auth.isInsecureModeAllowed() chokepoint so release builds
        // refuse the flag automatically.  The old envFlagEnabled path would
        // honour the env var in any build mode.
        const allow_insecure = cluster_auth.isInsecureModeAllowed();
        if (allow_insecure) {
            log.warn("SECURITY WARNING: Cluster TLS verification disabled via GEODE_CLUSTER_INSECURE (Debug build only)", &.{});
            _ = client.connectInsecure(host, port, true) catch |err| return err;
        } else {
            const ca_path = getEnvVarOwned(self.allocator, "GEODE_CLUSTER_CA_CERT") catch null;
            defer if (ca_path) |p| self.allocator.free(p);

            if (ca_path) |path| {
                try client.connectEx(host, port, path, null, null);
            } else {
                try client.connect(host, port);
            }
        }
        _ = client.waitForHandshake(10) catch |err| return err;

        var stream = try client.openStream(true);
        defer stream.deinit();

        var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(self.allocator, 256);
        defer aw.deinit();
        try protobuf.encode(&aw.writer, self.allocator, msg);
        const body = aw.writer.buffer[0..aw.writer.end];

        const framed = try self.allocator.alloc(u8, body.len + 4);
        defer self.allocator.free(framed);
        std.mem.writeInt(u32, framed[0..4], @intCast(body.len), .big);
        @memcpy(framed[4..], body);

        try stream.writeAll(framed);
    }

    // CANARY: REQ=REQ-GQL-021; FEATURE="Cluster Message Handler"; ASPECT=OnMessage; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-05
    pub fn onMessage(self: *ClusterCoordinator, callback: fn (*ClusterCoordinator, *const Message) void) void {
        self.message_callback = callback;
    }

    fn handleLeaveCluster(self: *ClusterCoordinator, msg: Message) !Response {
        _ = self;
        _ = msg;
        return Response{ .status = .OK };
    }

    fn handleReplicateData(self: *ClusterCoordinator, msg: Message) !Response {
        _ = self;
        _ = msg;
        return Response{ .status = .OK };
    }

    fn handleShardQuery(self: *ClusterCoordinator, msg: Message) !Response {
        // CANARY: REQ=REQ-GQL-2PC-005; FEATURE="Distributed Query Processing"; ASPECT=Distributed; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-05

        // Determine if this is a read-only or write query
        const is_write = try self.isWriteQuery(msg);

        if (!is_write) {
            // Simple read query - route to appropriate shard
            const shard_id = try self.determineTargetShard(msg);
            return self.forwardToShard(shard_id, msg);
        }

        // Distributed write using 2PC
        const affected_shards = try self.determineAffectedShards(msg);

        // Generate transaction ID
        const xid = try self.generateTransactionId();

        // Phase 1: Prepare
        var prepare_votes = std.ArrayList(bool).init(self.allocator);
        defer prepare_votes.deinit();

        const write_set = try self.serializeWriteSet(msg);
        defer self.allocator.free(write_set);
        const metadata = try self.serializeMetadata(msg);
        defer self.allocator.free(metadata);

        for (affected_shards) |shard_id| {
            const prepare_msg = raft_consensus.TxnPrepare{
                .xid = xid,
                .shard_id = shard_id,
                .write_set = write_set,
                .metadata = metadata,
            };

            // Send prepare through Raft consensus
            const vote = try self.sendPrepareToShard(shard_id, prepare_msg);
            try prepare_votes.append(vote);
        }

        // Check if all shards voted to commit
        var can_commit = true;
        for (prepare_votes.items) |vote| {
            if (!vote) {
                can_commit = false;
                break;
            }
        }

        // Phase 2: Decide
        const decide_msg = raft_consensus.TxnDecide{
            .xid = xid,
            .commit = can_commit,
        };

        for (affected_shards) |shard_id| {
            try self.sendDecideToShard(shard_id, decide_msg);
        }

        return Response{
            .status = if (can_commit) .OK else .ABORTED,
            .data = try std.fmt.allocPrint(self.allocator, "Transaction {} {s}", .{ xid, if (can_commit) "committed" else "aborted" }),
        };
    }

    fn isWriteQuery(self: *ClusterCoordinator, msg: Message) !bool {
        _ = self;
        // Parse message to determine if it's a write operation
        // For now, simple heuristic based on message type
        return msg.msg_type == .WRITE or msg.msg_type == .DELETE or msg.msg_type == .UPDATE;
    }

    fn determineTargetShard(self: *ClusterCoordinator, msg: Message) !u64 {
        // Hash-based sharding for reads
        const key = msg.key orelse return error.MissingKey;
        const hash = std.hash.Fnv1a_64.hash(key);
        return hash % self.cluster_state.shards.items.len;
    }

    fn determineAffectedShards(self: *ClusterCoordinator, msg: Message) ![]u64 {
        // For writes, determine all affected shards
        var shards = std.ArrayList(u64).init(self.allocator);

        // Simple case: single shard
        const primary_shard = try self.determineTargetShard(msg);
        try shards.append(primary_shard);

        // Add replica shards if configured
        if (self.replication_map.get(primary_shard)) |replicas| {
            for (replicas) |replica| {
                try shards.append(replica);
            }
        }

        return shards.toOwnedSlice();
    }

    fn generateTransactionId(self: *ClusterCoordinator) !u64 {
        // Generate unique transaction ID
        const timestamp: u64 = @intCast(compat_milliTimestamp());
        const node_part = self.node_id << 48;
        const counter = self.incrementTxCounter();
        return node_part | (timestamp << 16) | counter;
    }

    fn incrementTxCounter(self: *ClusterCoordinator) u16 {
        _ = self;
        // Thread-safe counter increment (simplified)
        const counter = struct {
            var value: std.atomic.Atomic(u16) = std.atomic.Atomic(u16).init(0);
        };
        return counter.value.fetchAdd(1, .Monotonic);
    }

    fn serializeWriteSet(self: *ClusterCoordinator, msg: Message) ![]const u8 {
        const write_set = msg.data orelse return error.MissingWriteSet;
        var reader: std.Io.Reader = .fixed(write_set);
        var decoded = protobuf.decode(dist_schema.TwoPhaseMessage, &reader, self.allocator) catch |err| {
            log.err("Invalid 2PC write set payload", &.{Attr.string("error", @errorName(err))});
            return error.InvalidWriteSet;
        };
        defer decoded.deinit(self.allocator);
        return self.allocator.dupe(u8, write_set);
    }

    fn serializeMetadata(self: *ClusterCoordinator, msg: Message) ![]const u8 {
        const metadata = TxnMetadata{
            .client_id = msg.client_id orelse "",
            .timestamp = compat_milliTimestamp(),
            .msg_type = msg.msg_type,
        };
        var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(self.allocator, 128);
        defer aw.deinit();
        try protobuf.encode(&aw.writer, self.allocator, metadata);
        const body = aw.writer.buffer[0..aw.writer.end];
        return self.allocator.dupe(u8, body);
    }

    fn sendPrepareToShard(self: *ClusterCoordinator, shard_id: u64, prepare: raft_consensus.TxnPrepare) !bool {
        _ = shard_id;
        // Send prepare message through Raft
        const command = raft_consensus.Command{ .txn_prepare = prepare };
        _ = try self.raft.proposeCommand(command);

        // Wait for response (simplified - in production would be async)
        if (self.raft.pending_responses.get(prepare.xid)) |response| {
            return response.prepare_result orelse false;
        }
        return false;
    }

    fn sendDecideToShard(self: *ClusterCoordinator, shard_id: u64, decide: raft_consensus.TxnDecide) !void {
        _ = shard_id;
        // Send decide message through Raft
        const command = raft_consensus.Command{ .txn_decide = decide };
        _ = try self.raft.proposeCommand(command);
    }

    fn forwardToShard(self: *ClusterCoordinator, shard_id: u64, msg: Message) !Response {
        _ = self;
        _ = shard_id;
        _ = msg;
        // Forward read query to shard
        return Response{ .status = .OK };
    }

    fn handleFailoverRequest(self: *ClusterCoordinator, msg: Message) !Response {
        _ = self;
        _ = msg;
        return Response{ .status = .OK };
    }

    pub const Config = struct {
        peers: []const PeerConfig,
        election_timeout_ms: u64 = 5000,
        replication_factor: u32 = 3,
        sharding_strategy: ShardingStrategy = .hash_based,
        failover_config: FailoverConfig = .{},
        health_check_interval_ms: u64 = 1000,
        unhealthy_threshold: u32 = 3,

        // === Cluster bootstrap configuration (Task A3 of 2026-05-25 plan) ===
        // These fields let multiple coordinator processes co-exist on one host
        // (different cluster_port values) and authenticate inter-node traffic
        // (cluster_token).  All five are stored by reference — the caller
        // owns the backing memory.

        /// Address this node binds its intra-cluster listener to. Used by
        /// `networkLoop`.  Defaults to all interfaces so a vanilla single-node
        /// dev run still accepts loopback peers without extra config.
        listen_address: []const u8 = "0.0.0.0",
        /// Port this node binds its intra-cluster listener to.  Defaults to
        /// 4242 so it does NOT collide with the QUIC client port (3141) when
        /// a coordinator is started in the same process as a client-facing
        /// QUIC server, and so the harness can place 3 nodes on one host at
        /// 4242 / 4243 / 4244.
        cluster_port: u16 = 4242,
        /// Pre-shared token validated on every inbound cluster connection.
        /// Empty string disables the auth check (single-node dev mode).
        /// Stored by reference — caller owns the lifetime.
        cluster_token: []const u8 = "",
        /// Cluster name (for OTel attributes and operator-facing logs).
        cluster_name: []const u8 = "geode-cluster",
        /// Maximum simultaneous inbound connections from peers.  Mirrored
        /// into `ClusterCoordinator.max_connections` so the existing PERF-D006
        /// connection-semaphore in `networkLoop` reads it without going
        /// back to the Config.
        max_connections: u32 = 256,
    };

    pub const PeerConfig = struct {
        id: u64,
        address: []const u8,
        port: u16,
    };
};

// ---------------------------------------------------------------------------
// Unit tests
// ---------------------------------------------------------------------------
const testing = std.testing;

test "Message struct carries auth_token field" {
    // SEC-D002: Verify the Message struct includes auth_token for JOIN_CLUSTER authentication.
    const msg = Message{
        .msg_type = .JOIN_CLUSTER,
        .key = null,
        .client_id = "test-node",
        .data = null,
        .auth_token = "my-secret-token",
    };
    try testing.expectEqualStrings("my-secret-token", msg.auth_token);
    try testing.expectEqual(MessageType.JOIN_CLUSTER, msg.msg_type);
}

test "Message auth_token defaults to empty" {
    const msg = Message{};
    try testing.expectEqualStrings("", msg.auth_token);
}

test "SEC-D012: minimal join response has no topology" {
    // JoinResponsePayload must carry exactly 3 fields: assigned_node_id, node_count, success.
    // It must NOT contain endpoint, shard, or any other topology detail.
    const info = @typeInfo(JoinResponsePayload);
    const fields = info.@"struct".fields;
    try testing.expectEqual(@as(usize, 3), fields.len);

    // Verify the exact field names
    try testing.expectEqualStrings("assigned_node_id", fields[0].name);
    try testing.expectEqualStrings("node_count", fields[1].name);
    try testing.expectEqualStrings("success", fields[2].name);

    // Verify defaults are safe (no information leak)
    const payload = JoinResponsePayload{};
    try testing.expectEqual(@as(u64, 0), payload.assigned_node_id);
    try testing.expectEqual(@as(u32, 0), payload.node_count);
    try testing.expectEqual(false, payload.success);
}

test "SEC-D009: ReplayGuard rejects duplicate within window" {
    var guard = ReplayGuard.init(testing.allocator, 16, 30_000);
    defer guard.deinit();

    // First call should be accepted (fresh)
    try testing.expect(guard.check(1, 10));

    // Identical (from, term) within the window must be rejected
    try testing.expect(!guard.check(1, 10));

    // Different (from, term) pair should be accepted
    try testing.expect(guard.check(2, 10));
    try testing.expect(guard.check(1, 11));
}
