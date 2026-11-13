const std = @import("std");

// Zig 0.16 compat: std.Thread.sleep was removed; use raw nanosleep.
fn compat_sleepNs(ns: u64) void {
    if (comptime @import("builtin").os.tag == .linux) {
        const req = std.os.linux.timespec{
            .sec = @intCast(ns / std.time.ns_per_s),
            .nsec = @intCast(ns % std.time.ns_per_s),
        };
        std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(@as(i96, req.sec) * std.time.ns_per_s + req.nsec), .awake) catch {};
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

// Zig 0.16 compat: std.posix.getenv was removed; wrap std.c.getenv to return a slice.
fn posixGetenv(name: [*:0]const u8) ?[:0]const u8 {
    return if (std.c.getenv(name)) |p| std.mem.span(p) else null;
}
const Allocator = std.mem.Allocator;
const quic = @import("transport/quic");
const protobuf = @import("protobuf");
const dist_schema = @import("distributed_schema");
const proto_schema = @import("schema");
const graph_store = @import("../graph_store.zig");
const value_convert = @import("value_convert.zig");
const pooled = @import("transport/thread_pool");

const cluster_auth = @import("cluster_auth.zig");
// SEC-D009: Import nonce tracker for replay protection on 2PC messages.
const nonce_tracker = @import("nonce_tracker.zig");

const logging = @import("logging");
const log = logging.scoped("twophase");
const Attr = logging.Attr;

/// SEC-D008 / PERF-D012-D013: Maximum allowed frame size to prevent allocation bombs.
const MAX_FRAME_SIZE: u32 = 16 * 1024 * 1024; // 16 MiB

pub const ParticipantNode = @import("twophase_participant.zig").ParticipantNode;

const fd = protobuf.fd;

/// SEC-D003: Read the cluster token from environment for 2PC message authentication.
/// Returns the token string or empty slice if not set.
fn getClusterToken() []const u8 {
    return posixGetenv("GEODE_CLUSTER_TOKEN") orelse "";
}

/// Two-Phase Commit transaction states
pub const TransactionState = enum {
    active,
    preparing,
    prepared,
    committing,
    committed,
    aborting,
    aborted,
};

/// 2PC message types (protobuf)
pub const MessageType = dist_schema.TwoPhaseMessageType;
/// Participant response to prepare (protobuf)
pub const PrepareResponse = dist_schema.TwoPhaseVote;
/// Operation types (protobuf)
pub const OperationType = dist_schema.OperationType;
pub const Operation = dist_schema.TwoPhaseOperation;
pub const NodeOperation = dist_schema.NodeOperation;
pub const EdgeOperation = dist_schema.EdgeOperation;

/// Undo log entry for rollback
// CANARY: REQ=REQ-DIST-2PC-UNDO-001; FEATURE="2PC Undo Pre-Image Storage"; ASPECT=AtomicRollback; STATUS=TESTED; OWNER=distributed; UPDATED=2026-04-06
pub const UndoEntry = struct {
    operation: Operation,
    timestamp: i64,
    /// Serialized properties captured before the mutation (for UPDATE/DELETE undo).
    /// Stored as MapEntry slices so restore can call applyMapEntriesToNode/Edge directly.
    pre_image_props: ?std.ArrayListUnmanaged(proto_schema.MapEntry) = null,
    /// Labels present on the node before deletion (for DELETE undo node re-creation).
    pre_image_labels: ?std.ArrayListUnmanaged([]const u8) = null,
    /// Graph name for DELETE undo node/edge re-creation.
    pre_image_graph_name: []const u8 = "",

    pub fn deinit(self: *UndoEntry, allocator: Allocator) void {
        self.operation.deinit(allocator);
        if (self.pre_image_props) |*props| {
            for (props.items) |*entry| entry.deinit(allocator);
            props.deinit(allocator);
        }
        if (self.pre_image_labels) |*labels| {
            for (labels.items) |lbl| allocator.free(lbl);
            labels.deinit(allocator);
        }
        if (self.pre_image_graph_name.len > 0) allocator.free(self.pre_image_graph_name);
    }
};

/// Redo log entry for recovery
pub const RedoEntry = struct {
    operation: Operation,
    timestamp: i64,

    pub fn deinit(self: *RedoEntry, allocator: Allocator) void {
        self.operation.deinit(allocator);
    }
};

/// Transaction participant information
pub const Participant = struct {
    id: []const u8,
    endpoint: []const u8,
    state: TransactionState,
    last_message_time: i64,
    prepare_response: ?PrepareResponse,
    undo_log: std.ArrayList(UndoEntry),
    redo_log: std.ArrayList(RedoEntry),
};

pub const IsolationLevel = enum {
    read_uncommitted,
    read_committed,
    repeatable_read,
    serializable,
};

pub const Savepoint = struct {
    name: []const u8,
    operation_index: usize,
    timestamp: i64,
};

// CANARY: REQ=REQ-DIST-2PC-MSG-001; FEATURE="Two-Phase Commit Message Format"; ASPECT=Protocol; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-10
/// 2PC protocol message for network communication
pub const TwoPhaseMessage = dist_schema.TwoPhaseMessage;

/// Response to a 2PC message
pub const TwoPhaseResponse = dist_schema.TwoPhaseResponse;

/// 2PC coordinator/participant runtime configuration.
pub const CoordinatorConfig = struct {
    coordinator_id: []const u8,
    participant_id: ?[]const u8 = null,
    store: ?*graph_store.GraphStore = null,
    default_timeout_ms: u64 = 30_000,
};

/// Transport hook for sending 2PC messages (allows callback-based dispatch)
pub const SendFn = *const fn (
    ctx: ?*anyopaque,
    endpoint: []const u8,
    msg: TwoPhaseMessage,
    timeout_ms: u64,
) anyerror!TwoPhaseResponse;

fn defaultSendMessage(_: ?*anyopaque, endpoint: []const u8, msg: TwoPhaseMessage, timeout_ms: u64) !TwoPhaseResponse {
    return sendMessage(endpoint, msg, timeout_ms);
}

/// Connection pool for 2PC participant connections
pub const TwoPhaseTransport = struct {
    allocator: Allocator,
    connections: std.StringHashMap(ConnectionEntry),
    mutex: std.Io.Mutex,

    pub const ConnectionEntry = struct {
        client: quic.QuicClient,
        stream: ?*quic.QuicClientStream,
        last_used: i64,
        endpoint: []const u8,
    };

    pub fn init(allocator: Allocator) TwoPhaseTransport {
        return .{
            .allocator = allocator,
            .connections = std.StringHashMap(ConnectionEntry).init(allocator),
            .mutex = std.Io.Mutex.init,
        };
    }

    pub fn deinit(self: *TwoPhaseTransport) void {
        var it = self.connections.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.stream) |stream| {
                stream.close();
            }
            entry.value_ptr.client.deinit();
            self.allocator.free(entry.value_ptr.endpoint);
        }
        self.connections.deinit();
    }

    /// Get or create a connection to endpoint (format: "host:port")
    // PERF-D002: Narrow the mutex window so the 5-second QUIC handshake does not
    // block all other 2PC traffic.  Pattern mirrors PERF-D001 in network_transport.
    pub fn getConnection(self: *TwoPhaseTransport, endpoint: []const u8) !*ConnectionEntry {
        // Phase 1: Check cache under lock (fast path).
        {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            if (self.connections.getPtr(endpoint)) |entry| {
                entry.last_used = compat_timestamp();
                return entry;
            }
        }

        // Phase 2: Connect + handshake WITHOUT holding the mutex.
        // Parse endpoint into host and port
        // GAP-0144: Secure TLS connections for 2PC coordination
        // CANARY: REQ=REQ-2PC-TLS-001; FEATURE="2PC TLS"; ASPECT=Security; STATUS=TESTED; TEST=tests/test_sonny6453_cluster_peer_tls.zig; OWNER=distributed; UPDATED=2026-11-13
        const colon_pos = std.mem.indexOf(u8, endpoint, ":") orelse return error.InvalidEndpoint;
        const host = endpoint[0..colon_pos];
        const port_str = endpoint[colon_pos + 1 ..];
        const port = std.fmt.parseInt(u16, port_str, 10) catch return error.InvalidPort;

        // SONNY-6453: the cluster transport configuration raft uses
        // (GEODE_CLUSTER_CA_CERT, or GEODE_CLUSTER_INSECURE in Debug builds);
        // with neither, refused (error.ClusterCaRequired) before dialling.
        // The mutex is NOT held here — the dial + waitForHandshake can take
        // up to 5 seconds and must not stall unrelated 2PC participants.
        var client = quic.QuicClient.init(self.allocator);
        cluster_auth.dialClusterPeer(&client, host, port) catch |err| {
            client.deinit();
            log.err("2PC transport failed to connect", &.{
                Attr.string("endpoint", endpoint),
                Attr.string("error", @errorName(err)),
            });
            return if (err == error.ClusterCaRequired) error.ClusterCaRequired else error.ConnectionFailed;
        };

        client.waitForHandshake(5) catch |err| {
            client.deinit();
            log.err("2PC transport handshake failed", &.{
                Attr.string("endpoint", endpoint),
                Attr.string("error", @errorName(err)),
            });
            return error.HandshakeFailed;
        };

        // Phase 3: Store the new connection under lock.
        // A concurrent caller may have raced us and already inserted an entry for
        // this endpoint.  In that case we discard our freshly-created client and
        // return the existing entry to avoid leaking a connection.
        {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

            if (self.connections.getPtr(endpoint)) |existing| {
                // Another goroutine won the race; clean up ours and use theirs.
                client.deinit();
                existing.last_used = compat_timestamp();
                return existing;
            }

            const entry = ConnectionEntry{
                .client = client,
                .stream = null,
                .last_used = compat_timestamp(),
                .endpoint = try self.allocator.dupe(u8, endpoint),
            };

            try self.connections.put(endpoint, entry);
            return self.connections.getPtr(endpoint).?;
        }
    }

    // CANARY: REQ=REQ-2PC-TIMEOUT-001; FEATURE="2PCTimeout"; ASPECT=Transport; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-10
    /// Send a 2PC message and receive response with timeout handling
    pub fn sendMessage(self: *TwoPhaseTransport, endpoint: []const u8, msg: TwoPhaseMessage, timeout_ms: u64) !TwoPhaseResponse {
        const start_time = compat_milliTimestamp();

        const conn = try self.getConnection(endpoint);

        // Get or create stream
        if (conn.stream == null) {
            conn.stream = try conn.client.openStream(true);
        }
        const stream = conn.stream.?;

        // Check timeout before sending
        const elapsed = compat_milliTimestamp() - start_time;
        if (elapsed >= @as(i64, @intCast(timeout_ms))) {
            log.warn("2PC transport timeout before send", &.{
                Attr.string("endpoint", endpoint),
            });
            return error.Timeout;
        }

        // Encode and send message with length-prefixed protobuf framing
        const frame = try encodeFrame(self.allocator, msg);
        defer self.allocator.free(frame);
        try stream.writeAll(frame);

        const remaining_timeout = timeout_ms - @as(u64, @intCast(@max(0, elapsed)));
        const response_bytes = try readFrame(self.allocator, &conn.client, stream, remaining_timeout);
        defer self.allocator.free(response_bytes);

        var reader: std.Io.Reader = .fixed(response_bytes);
        return protobuf.decode(TwoPhaseResponse, &reader, self.allocator);
    }
};

/// Global transport instance for 2PC messaging
var global_transport: ?*TwoPhaseTransport = null;
var transport_allocator: ?Allocator = null;

/// Initialize the global 2PC transport
pub fn initTransport(allocator: Allocator) !void {
    if (global_transport != null) return;
    transport_allocator = allocator;
    global_transport = try allocator.create(TwoPhaseTransport);
    global_transport.?.* = TwoPhaseTransport.init(allocator);
}

/// Deinitialize the global 2PC transport
pub fn deinitTransport() void {
    if (global_transport) |transport| {
        transport.deinit();
        if (transport_allocator) |allocator| {
            allocator.destroy(transport);
        }
        global_transport = null;
        transport_allocator = null;
    }
}

fn encodeFrame(allocator: Allocator, msg: anytype) ![]u8 {
    var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(allocator, 512);
    defer aw.deinit();
    try protobuf.encode(&aw.writer, allocator, msg);
    const body = aw.writer.buffer[0..aw.writer.end];
    const framed = try allocator.alloc(u8, body.len + 4);
    std.mem.writeInt(u32, framed[0..4], @intCast(body.len), .big);
    @memcpy(framed[4..], body);
    return framed;
}

fn readExact(
    client: *quic.QuicClient,
    stream: *quic.QuicClientStream,
    buf: []u8,
    deadline_ms: i64,
) !void {
    var offset: usize = 0;
    while (offset < buf.len) {
        if (compat_milliTimestamp() > deadline_ms) return error.Timeout;
        const n = stream.read(buf[offset..]) catch |err| {
            if (err == error.WouldBlock) {
                client.poll(10) catch {};
                compat_sleepNs(5 * std.time.ns_per_ms);
                continue;
            }
            return err;
        };
        if (n == 0) {
            client.poll(10) catch {};
            compat_sleepNs(5 * std.time.ns_per_ms);
            continue;
        }
        offset += n;
    }
}

fn readFrame(
    allocator: Allocator,
    client: *quic.QuicClient,
    stream: *quic.QuicClientStream,
    timeout_ms: u64,
) ![]u8 {
    const deadline = compat_milliTimestamp() + @as(i64, @intCast(timeout_ms));
    var len_buf: [4]u8 = undefined;
    try readExact(client, stream, len_buf[0..], deadline);
    const len = std.mem.readInt(u32, &len_buf, .big);
    if (len == 0) return error.InvalidMessage;
    if (len > MAX_FRAME_SIZE) return error.FrameTooLarge;
    const body = try allocator.alloc(u8, len);
    errdefer allocator.free(body);
    try readExact(client, stream, body, deadline);
    return body;
}

// CANARY: REQ=REQ-DIST-2PC-TRANSPORT-001; FEATURE="Two-Phase Commit Network Transport"; ASPECT=QUICMessaging; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-10
/// Send a 2PC message to a participant endpoint using QUIC transport
fn sendMessage(endpoint: []const u8, msg: TwoPhaseMessage, timeout_ms: u64) !TwoPhaseResponse {
    // Use global transport if available, otherwise fall back to creating a one-shot connection
    if (global_transport) |transport| {
        return transport.sendMessage(endpoint, msg, timeout_ms);
    }

    // GAP-0144: Secure TLS for one-shot 2PC connections
    // CANARY: REQ=REQ-2PC-TLS-002; FEATURE="2PC TLS One-shot"; ASPECT=Security; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-10
    // One-shot connection for when transport not initialized
    // Parse endpoint into host and port
    const colon_pos = std.mem.indexOf(u8, endpoint, ":") orelse return error.InvalidEndpoint;
    const host = endpoint[0..colon_pos];
    const port_str = endpoint[colon_pos + 1 ..];
    const port = std.fmt.parseInt(u16, port_str, 10) catch return error.InvalidPort;

    // Create allocator for this operation
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // SONNY-6453: the cluster transport configuration (see getConnection).
    var client = quic.QuicClient.init(allocator);
    defer client.deinit();

    cluster_auth.dialClusterPeer(&client, host, port) catch |err| {
        log.err("2PC transport one-shot connect failed", &.{
            Attr.string("endpoint", endpoint),
            Attr.string("error", @errorName(err)),
        });
        return if (err == error.ClusterCaRequired) error.ClusterCaRequired else error.ConnectionFailed;
    };

    // Wait for handshake with timeout
    const handshake_timeout: u32 = @intCast(@min(timeout_ms / 1000, 5));
    client.waitForHandshake(if (handshake_timeout == 0) 1 else handshake_timeout) catch |err| {
        log.err("2PC transport handshake failed", &.{
            Attr.string("error", @errorName(err)),
        });
        return error.HandshakeFailed;
    };

    // Open stream
    const stream = try client.openStream(true);
    defer stream.close();

    const frame = try encodeFrame(allocator, msg);
    defer allocator.free(frame);
    try stream.writeAll(frame);

    const response_bytes = readFrame(allocator, &client, stream, timeout_ms) catch |err| {
        log.err("2PC transport read response failed", &.{
            Attr.string("error", @errorName(err)),
        });
        return error.ReadFailed;
    };
    defer allocator.free(response_bytes);

    var reader: std.Io.Reader = .fixed(response_bytes);
    return protobuf.decode(TwoPhaseResponse, &reader, allocator);
}

// CANARY: REQ=REQ-DIST-2PC-UNDO-002; FEATURE="2PC Undo Pre-Image Capture"; ASPECT=NodeCapture; STATUS=TESTED; OWNER=distributed; UPDATED=2026-04-06
/// Capture a node's current properties and labels into pre-image fields on an UndoEntry.
/// Called before applying an UPDATE or DELETE operation so the undo can restore state.
pub fn captureNodePreImage(allocator: Allocator, store: *graph_store.GraphStore, node_id: u64, entry: *UndoEntry) !void {
    const node = store.getNodePtr(node_id) orelse return;

    // Capture properties as MapEntry list
    var props = std.ArrayList(proto_schema.MapEntry).empty;
    errdefer {
        for (props.items) |*e| e.deinit(allocator);
        props.deinit(allocator);
    }
    var prop_it = node.properties.iterator();
    while (prop_it.next()) |kv| {
        const key = try allocator.dupe(u8, kv.key_ptr.*);
        errdefer allocator.free(key);
        var proto_val = try value_convert.propertyValueToProto(allocator, kv.value_ptr.*);
        errdefer proto_val.deinit(allocator);
        try props.append(allocator, .{ .key = key, .value = proto_val });
    }
    entry.pre_image_props = props;

    // Capture labels (for DELETE undo re-creation)
    var labels = std.ArrayList([]const u8).empty;
    errdefer {
        for (labels.items) |lbl| allocator.free(lbl);
        labels.deinit(allocator);
    }
    for (node.labels) |lbl| {
        try labels.append(allocator, try allocator.dupe(u8, lbl));
    }
    entry.pre_image_labels = labels;

    // Capture graph name
    entry.pre_image_graph_name = try allocator.dupe(u8, node.graph_name);
}

// CANARY: REQ=REQ-DIST-2PC-UNDO-003; FEATURE="2PC Undo Pre-Image Capture"; ASPECT=EdgeCapture; STATUS=TESTED; OWNER=distributed; UPDATED=2026-04-06
/// Capture an edge's current properties into pre-image fields on an UndoEntry.
/// Called before applying an UPDATE or DELETE operation so the undo can restore state.
pub fn captureEdgePreImage(allocator: Allocator, store: *graph_store.GraphStore, edge_id: u64, entry: *UndoEntry) !void {
    const edge = store.getEdgePtr(edge_id) orelse return;

    var props = std.ArrayList(proto_schema.MapEntry).empty;
    errdefer {
        for (props.items) |*e| e.deinit(allocator);
        props.deinit(allocator);
    }
    var prop_it = edge.properties.iterator();
    while (prop_it.next()) |kv| {
        const key = try allocator.dupe(u8, kv.key_ptr.*);
        errdefer allocator.free(key);
        var proto_val = try value_convert.propertyValueToProto(allocator, kv.value_ptr.*);
        errdefer proto_val.deinit(allocator);
        try props.append(allocator, .{ .key = key, .value = proto_val });
    }
    entry.pre_image_props = props;

    entry.pre_image_graph_name = try allocator.dupe(u8, edge.graph_name);
}

// CANARY: REQ=REQ-DIST-2PC-UNDO-004; FEATURE="2PC Undo Apply"; ASPECT=AtomicRollback; STATUS=TESTED; OWNER=distributed; UPDATED=2026-04-06
/// Apply an undo operation to rollback a change.
/// - CREATE: deletes the created node/edge.
/// - UPDATE: restores properties from the captured pre-image.
/// - DELETE: re-creates the node/edge from the captured pre-image.
fn applyUndoOperation(store: ?*graph_store.GraphStore, entry: UndoEntry) void {
    const gs = store orelse {
        log.warn("2PC undo skipped: no graph store available", &.{});
        return;
    };

    switch (entry.operation) {
        .node_op => |node_op| switch (node_op.op_type) {
            .CREATE => {
                log.info("2PC undo: deleting created node", &.{
                    Attr.int("node_id", @intCast(node_op.node_id)),
                });
                // SONNY-6302: best-effort like the other undo branches (abort
                // proceeds), but a failed delete is logged as an incomplete
                // undo with its error: the created node remains.
                gs.deleteNodeChecked(node_op.node_id) catch |err| {
                    log.err("2PC undo: failed to delete created node; it remains (undo incomplete)", &.{
                        Attr.int("node_id", @intCast(node_op.node_id)),
                        Attr.string("error", @errorName(err)),
                    });
                };
            },
            .UPDATE => {
                const props = entry.pre_image_props orelse {
                    log.warn("2PC undo for node UPDATE: no pre-image captured, skipping restore", &.{
                        Attr.int("node_id", @intCast(node_op.node_id)),
                    });
                    return;
                };
                log.info("2PC undo: restoring node properties from pre-image", &.{
                    Attr.int("node_id", @intCast(node_op.node_id)),
                    Attr.int("prop_count", @intCast(props.items.len)),
                });
                // Use a scratch allocator for transient proto→PropertyValue conversions.
                var gpa = std.heap.DebugAllocator(.{}){};
                defer _ = gpa.deinit();
                const scratch = gpa.allocator();
                value_convert.applyMapEntriesToNode(gs, scratch, node_op.node_id, props.items) catch |err| {
                    log.err("2PC undo: failed to restore node properties", &.{
                        Attr.int("node_id", @intCast(node_op.node_id)),
                        Attr.string("error", @errorName(err)),
                    });
                };
            },
            .DELETE => {
                const props = entry.pre_image_props orelse {
                    log.warn("2PC undo for node DELETE: no pre-image captured, cannot re-create node", &.{
                        Attr.int("node_id", @intCast(node_op.node_id)),
                    });
                    return;
                };
                const graph_name = if (entry.pre_image_graph_name.len > 0)
                    entry.pre_image_graph_name
                else
                    graph_store.DEFAULT_GRAPH_NAME;

                // Re-create the node with its original labels
                const labels: []const []const u8 = if (entry.pre_image_labels) |lbls| lbls.items else &.{};
                log.info("2PC undo: re-creating deleted node", &.{
                    Attr.int("node_id", @intCast(node_op.node_id)),
                    Attr.int("label_count", @intCast(labels.len)),
                    Attr.int("prop_count", @intCast(props.items.len)),
                });
                gs.createNodeWithId(node_op.node_id, labels, graph_name) catch |err| {
                    log.err("2PC undo: failed to re-create deleted node", &.{
                        Attr.int("node_id", @intCast(node_op.node_id)),
                        Attr.string("error", @errorName(err)),
                    });
                    return;
                };
                var gpa = std.heap.DebugAllocator(.{}){};
                defer _ = gpa.deinit();
                const scratch = gpa.allocator();
                value_convert.applyMapEntriesToNode(gs, scratch, node_op.node_id, props.items) catch |err| {
                    log.err("2PC undo: failed to restore node properties after re-creation", &.{
                        Attr.int("node_id", @intCast(node_op.node_id)),
                        Attr.string("error", @errorName(err)),
                    });
                };
            },
            else => {},
        },
        .edge_op => |edge_op| switch (edge_op.op_type) {
            .CREATE => {
                log.info("2PC undo: deleting created edge", &.{
                    Attr.int("edge_id", @intCast(edge_op.edge_id)),
                });
                gs.deleteEdgeChecked(edge_op.edge_id) catch |err| { // SONNY-6302
                    log.err("2PC undo: failed to delete created edge; it remains (undo incomplete)", &.{
                        Attr.int("edge_id", @intCast(edge_op.edge_id)),
                        Attr.string("error", @errorName(err)),
                    });
                };
            },
            .UPDATE => {
                const props = entry.pre_image_props orelse {
                    log.warn("2PC undo for edge UPDATE: no pre-image captured, skipping restore", &.{
                        Attr.int("edge_id", @intCast(edge_op.edge_id)),
                    });
                    return;
                };
                log.info("2PC undo: restoring edge properties from pre-image", &.{
                    Attr.int("edge_id", @intCast(edge_op.edge_id)),
                    Attr.int("prop_count", @intCast(props.items.len)),
                });
                var gpa = std.heap.DebugAllocator(.{}){};
                defer _ = gpa.deinit();
                const scratch = gpa.allocator();
                value_convert.applyMapEntriesToEdge(gs, scratch, edge_op.edge_id, props.items) catch |err| {
                    log.err("2PC undo: failed to restore edge properties", &.{
                        Attr.int("edge_id", @intCast(edge_op.edge_id)),
                        Attr.string("error", @errorName(err)),
                    });
                };
            },
            .DELETE => {
                const props = entry.pre_image_props orelse {
                    log.warn("2PC undo for edge DELETE: no pre-image captured, cannot re-create edge", &.{
                        Attr.int("edge_id", @intCast(edge_op.edge_id)),
                    });
                    return;
                };
                const graph_name = if (entry.pre_image_graph_name.len > 0)
                    entry.pre_image_graph_name
                else
                    graph_store.DEFAULT_GRAPH_NAME;
                log.info("2PC undo: re-creating deleted edge", &.{
                    Attr.int("edge_id", @intCast(edge_op.edge_id)),
                    Attr.int("prop_count", @intCast(props.items.len)),
                });
                gs.createEdgeWithId(
                    edge_op.edge_id,
                    edge_op.source_id,
                    edge_op.target_id,
                    edge_op.edge_type,
                    graph_name,
                ) catch |err| {
                    log.err("2PC undo: failed to re-create deleted edge", &.{
                        Attr.int("edge_id", @intCast(edge_op.edge_id)),
                        Attr.string("error", @errorName(err)),
                    });
                    return;
                };
                var gpa = std.heap.DebugAllocator(.{}){};
                defer _ = gpa.deinit();
                const scratch = gpa.allocator();
                value_convert.applyMapEntriesToEdge(gs, scratch, edge_op.edge_id, props.items) catch |err| {
                    log.err("2PC undo: failed to restore edge properties after re-creation", &.{
                        Attr.int("edge_id", @intCast(edge_op.edge_id)),
                        Attr.string("error", @errorName(err)),
                    });
                };
            },
            else => {},
        },
    }
}

/// 2PC transaction context
pub const Transaction = struct {
    allocator: Allocator,
    id: []const u8,
    coordinator_id: []const u8,
    participants: std.ArrayList(Participant),
    state: TransactionState,
    start_time: i64,
    timeout_ms: u64,
    send_fn: SendFn,
    send_ctx: ?*anyopaque,
    operations: std.ArrayList(Operation),
    isolation_level: IsolationLevel,
    savepoints: std.ArrayList(Savepoint),
    store: ?*graph_store.GraphStore,

    pub fn init(
        allocator: Allocator,
        id: []const u8,
        coordinator_id: []const u8,
        send_fn: SendFn,
        send_ctx: ?*anyopaque,
        timeout_ms: u64,
        store: ?*graph_store.GraphStore,
    ) !Transaction {
        return .{
            .allocator = allocator,
            .id = try allocator.dupe(u8, id),
            .coordinator_id = try allocator.dupe(u8, coordinator_id),
            .participants = .empty,
            .state = .active,
            .start_time = compat_timestamp(),
            .timeout_ms = timeout_ms,
            .send_fn = send_fn,
            .send_ctx = send_ctx,
            .operations = .empty,
            .isolation_level = .read_committed,
            .savepoints = .empty,
            .store = store,
        };
    }

    pub fn deinit(self: *Transaction) void {
        for (self.participants.items) |*participant| {
            self.allocator.free(participant.id);
            self.allocator.free(participant.endpoint);
            for (participant.undo_log.items) |*entry| entry.deinit(self.allocator);
            participant.undo_log.deinit(self.allocator);
            for (participant.redo_log.items) |*entry| entry.deinit(self.allocator);
            participant.redo_log.deinit(self.allocator);
        }
        self.participants.deinit(self.allocator);
        for (self.operations.items) |*op| op.deinit(self.allocator);
        self.operations.deinit(self.allocator);
        for (self.savepoints.items) |sp| self.allocator.free(sp.name);
        self.savepoints.deinit(self.allocator);
        self.allocator.free(self.id);
        self.allocator.free(self.coordinator_id);
    }

    pub fn addParticipant(self: *Transaction, id: []const u8, endpoint: []const u8) !void {
        const participant = Participant{
            .id = try self.allocator.dupe(u8, id),
            .endpoint = try self.allocator.dupe(u8, endpoint),
            .state = .active,
            .last_message_time = compat_timestamp(),
            .prepare_response = null,
            .undo_log = .empty,
            .redo_log = .empty,
        };
        try self.participants.append(self.allocator, participant);
    }

    pub fn addOperation(self: *Transaction, operation: Operation) !void {
        try self.operations.append(self.allocator, operation);
    }

    pub fn createSavepoint(self: *Transaction, name: []const u8) !void {
        const savepoint = Savepoint{
            .name = try self.allocator.dupe(u8, name),
            .operation_index = self.operations.items.len,
            .timestamp = compat_timestamp(),
        };
        try self.savepoints.append(self.allocator, savepoint);
    }

    pub fn rollbackToSavepoint(self: *Transaction, name: []const u8) !void {
        for (self.savepoints.items) |savepoint| {
            if (std.mem.eql(u8, savepoint.name, name)) {
                // Remove operations after savepoint
                for (self.operations.items[savepoint.operation_index..]) |*op| {
                    op.deinit(self.allocator);
                }
                self.operations.shrinkRetainingCapacity(savepoint.operation_index);
                return;
            }
        }
        return error.SavepointNotFound;
    }

    // PERF-D003: Worker context for parallel prepare
    const PrepareWorkerCtx = struct {
        txn: *Transaction,
        idx: usize,
        votes: []bool,
    };

    // PERF-D003: Worker function for parallel prepare
    fn prepareWorker(ctx: PrepareWorkerCtx) void {
        const participant = &ctx.txn.participants.items[ctx.idx];
        // SEC-D009: Include cryptographic nonce for replay protection
        const msg = TwoPhaseMessage{
            .msg_type = .PREPARE,
            .transaction_id = ctx.txn.id,
            .coordinator_id = ctx.txn.coordinator_id,
            .timestamp = compat_timestamp(),
            .operations = ctx.txn.operations,
            .auth_token = getClusterToken(),
            .nonce = nonce_tracker.NonceTracker.generateNonce(),
        };
        var response = ctx.txn.send_fn(ctx.txn.send_ctx, participant.endpoint, msg, ctx.txn.timeout_ms) catch {
            participant.prepare_response = .VOTE_TIMEOUT;
            return;
        };
        defer response.deinit(ctx.txn.allocator);
        participant.prepare_response = response.vote;
        participant.last_message_time = compat_timestamp();
        if (response.vote == .VOTE_COMMIT) {
            ctx.votes[ctx.idx] = true;
        }
    }

    fn runPrepareWorker(ctx: *anyopaque, runtime: *pooled.TaskContext) void {
        _ = runtime;
        const worker_ctx: *PrepareWorkerCtx = @ptrCast(@alignCast(ctx));
        prepareWorker(worker_ctx.*);
    }

    // PERF-D004: Worker context for parallel commit
    const CommitWorkerCtx = struct {
        txn: *Transaction,
        idx: usize,
        /// GAP-0889: per-participant delivery flag — exhausting retries must
        /// not be reported as a successful commit ack.
        delivered: []bool,
    };

    // PERF-D004: Worker function for parallel commit
    fn commitWorker(ctx: CommitWorkerCtx) void {
        const participant = &ctx.txn.participants.items[ctx.idx];
        var ops: std.ArrayList(Operation) = .empty;
        defer ops.deinit(ctx.txn.allocator);
        // SEC-D009: Include cryptographic nonce for replay protection
        const msg = TwoPhaseMessage{
            .msg_type = .COMMIT,
            .transaction_id = ctx.txn.id,
            .coordinator_id = ctx.txn.coordinator_id,
            .timestamp = compat_timestamp(),
            .operations = ops,
            .auth_token = getClusterToken(),
            .nonce = nonce_tracker.NonceTracker.generateNonce(),
        };
        var retries: u32 = 0;
        const max_retries: u32 = 3;
        var last_err: ?anyerror = null;
        var acked = false;
        while (retries < max_retries) : (retries += 1) {
            if (ctx.txn.send_fn(ctx.txn.send_ctx, participant.endpoint, msg, ctx.txn.timeout_ms)) |resp| {
                var owned_resp = resp;
                owned_resp.deinit(ctx.txn.allocator);
                acked = true;
            } else |err| {
                last_err = err;
                const backoff_ms: u64 = @as(u64, 100) << @as(u6, @intCast(retries));
                compat_sleepNs(backoff_ms * std.time.ns_per_ms);
                continue;
            }
            break;
        }
        // GAP-0889: the old code unconditionally marked the participant
        // .committed here — a participant that never received the COMMIT was
        // reported as committed and the coordinator returned success. Leave
        // it in .committing (decision made, delivery unacked) and surface the
        // failure through `delivered` so commit() can report it.
        if (acked) {
            participant.state = .committed;
            ctx.delivered[ctx.idx] = true;
        } else {
            log.warn("2PC COMMIT delivery failed after retries", &.{
                Attr.string("transaction_id", ctx.txn.id),
                Attr.string("participant", participant.endpoint),
                Attr.string("error", if (last_err) |e| @errorName(e) else "unknown"),
                Attr.uint("retries", max_retries),
            });
        }
        participant.last_message_time = compat_timestamp();
    }

    fn runCommitWorker(ctx: *anyopaque, runtime: *pooled.TaskContext) void {
        _ = runtime;
        const worker_ctx: *CommitWorkerCtx = @ptrCast(@alignCast(ctx));
        commitWorker(worker_ctx.*);
    }

    // PERF-D003: Parallel prepare -- contact all participants concurrently
    pub fn prepare(self: *Transaction) !bool {
        self.state = .preparing;
        // CANARY: REQ=REQ-DIST-2PC-001; FEATURE="Two-Phase Commit Messaging"; ASPECT=Prepare; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-10
        const participant_count = self.participants.items.len;
        if (participant_count == 0) {
            self.state = .prepared;
            return true;
        }
        const vote_results = try self.allocator.alloc(bool, participant_count);
        defer self.allocator.free(vote_results);
        for (vote_results) |*v| v.* = false;
        for (self.participants.items) |*participant| {
            participant.state = .preparing;
        }
        const worker_count = @max(@min(participant_count, @as(usize, 16)), 1);
        const pool = try pooled.ThreadPool.init(self.allocator, .{
            .num_threads = worker_count,
            .queue_capacity = @max(participant_count * 2, 4),
        });
        defer pool.deinit();
        var wg = pool.waitGroup();
        const worker_ctxs = try self.allocator.alloc(PrepareWorkerCtx, participant_count);
        defer self.allocator.free(worker_ctxs);
        for (0..participant_count) |idx| {
            worker_ctxs[idx] = .{
                .txn = self,
                .idx = idx,
                .votes = vote_results,
            };
            _ = try pool.submitTask(runPrepareWorker, @ptrCast(&worker_ctxs[idx]), .{
                .wait_group = &wg,
                .backpressure = .block,
                .lane = .blocking,
            });
        }
        wg.wait();
        var all_voted_commit = true;
        for (vote_results) |v| {
            if (!v) {
                all_voted_commit = false;
                break;
            }
        }
        if (!all_voted_commit) {
            self.state = .aborting;
            return false;
        }
        self.state = .prepared;
        return true;
    }

    // PERF-D004: Parallel commit -- contact all participants concurrently
    pub fn commit(self: *Transaction) !void {
        if (self.state != .prepared) {
            return error.InvalidState;
        }
        self.state = .committing;
        // CANARY: REQ=REQ-DIST-2PC-002; FEATURE="Two-Phase Commit Messaging"; ASPECT=Commit; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-10
        const participant_count = self.participants.items.len;
        if (participant_count == 0) {
            self.state = .committed;
            return;
        }
        for (self.participants.items) |*participant| {
            participant.state = .committing;
        }
        const worker_count = @max(@min(participant_count, @as(usize, 16)), 1);
        const pool = try pooled.ThreadPool.init(self.allocator, .{
            .num_threads = worker_count,
            .queue_capacity = @max(participant_count * 2, 4),
        });
        defer pool.deinit();
        var wg = pool.waitGroup();
        // GAP-0889: track per-participant COMMIT delivery so an unreachable
        // participant is surfaced instead of silently reported committed.
        const delivered = try self.allocator.alloc(bool, participant_count);
        defer self.allocator.free(delivered);
        for (delivered) |*d| d.* = false;
        const worker_ctxs = try self.allocator.alloc(CommitWorkerCtx, participant_count);
        defer self.allocator.free(worker_ctxs);
        for (0..participant_count) |idx| {
            worker_ctxs[idx] = .{
                .txn = self,
                .idx = idx,
                .delivered = delivered,
            };
            _ = try pool.submitTask(runCommitWorker, @ptrCast(&worker_ctxs[idx]), .{
                .wait_group = &wg,
                .backpressure = .block,
                .lane = .blocking,
            });
        }
        wg.wait();
        // The commit DECISION stands (2PC point of no return was the prepare
        // vote), so the transaction is committed — but if any participant
        // never acked the COMMIT message, say so instead of lying. The caller
        // (or a future recovery pass) must re-deliver to the unacked
        // participants; their locks are still held on the participant side.
        self.state = .committed;
        for (delivered) |d| {
            if (!d) return error.CommitDeliveryIncomplete;
        }
    }

    pub fn abort(self: *Transaction) !void {
        self.state = .aborting;

        // CANARY: REQ=REQ-DIST-2PC-003; FEATURE="Two-Phase Commit Messaging"; ASPECT=Abort; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-10
        // Send abort messages to all participants
        for (self.participants.items) |*participant| {
            participant.state = .aborting;

            // Create and send abort message
            // SEC-D003: Include cluster token for inter-node authentication
            // SEC-D009: Include cryptographic nonce for replay protection
            var ops: std.ArrayList(Operation) = .empty;
            defer ops.deinit(self.allocator);
            const msg = TwoPhaseMessage{
                .msg_type = .ABORT,
                .transaction_id = self.id,
                .coordinator_id = self.coordinator_id,
                .timestamp = compat_timestamp(),
                .operations = ops,
                .auth_token = getClusterToken(),
                .nonce = nonce_tracker.NonceTracker.generateNonce(),
            };

            // Send abort message (best effort - proceed even if some fail)
            if (self.send_fn(self.send_ctx, participant.endpoint, msg, self.timeout_ms)) |resp| {
                var owned_resp = resp;
                owned_resp.deinit(self.allocator);
            } else |err| {
                // GAP-0889: the comment said "log failure" but nothing was
                // logged — an undeliverable ABORT leaves that participant's
                // locks held until its own timeout. Make it visible.
                log.warn("2PC ABORT delivery failed — participant will release on its own timeout", &.{
                    Attr.string("transaction_id", self.id),
                    Attr.string("participant", participant.endpoint),
                    Attr.string("error", @errorName(err)),
                });
            }

            // Apply undo log to rollback changes
            // Zig 0.16: ArrayList.popOrNull was renamed to pop (returns ?T).
            while (participant.undo_log.pop()) |undo_entry| {
                // Apply undo operation to restore previous state (best-effort)
                applyUndoOperation(self.store, undo_entry);
            }

            participant.state = .aborted;
            participant.last_message_time = compat_timestamp();
        }

        self.state = .aborted;
    }

    pub fn isTimedOut(self: *Transaction) bool {
        const current_time = compat_timestamp();
        const elapsed_ms = @as(u64, @intCast((current_time - self.start_time) * 1000));
        return elapsed_ms > self.timeout_ms;
    }
};

/// Two-Phase Commit Coordinator
pub const Coordinator = struct {
    allocator: Allocator,
    node_id: []const u8,
    transactions: std.StringHashMap(Transaction),
    log_writer: ?*LogWriter,
    default_timeout_ms: u64 = 30_000,
    send_fn: SendFn = defaultSendMessage,
    send_ctx: ?*anyopaque = null,
    store: ?*graph_store.GraphStore = null,

    pub const LogWriter = struct {
        allocator: Allocator,
        file: std.Io.File,

        pub fn writeEntry(self: *LogWriter, entry: LogEntry) !void {
            const framed = try encodeFrame(self.allocator, entry);
            defer self.allocator.free(framed);
            // Zig 0.16: Io.File has no writeAll; stream-append at the current
            // file position (same pattern as raft_persistent.zig).
            try self.file.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), framed);
        }
    };

    pub const LogEntry = struct {
        timestamp: i64,
        transaction_id: []const u8,
        event_type: LogEventType,
        data: []const u8,

        pub const _desc_table = .{
            .timestamp = fd(1, .{ .scalar = .int64 }),
            .transaction_id = fd(2, .{ .scalar = .string }),
            .event_type = fd(3, .{ .@"enum" = {} }),
            .data = fd(4, .{ .scalar = .bytes }),
        };

        pub fn deinit(self: *LogEntry, allocator: Allocator) void {
            protobuf.deinit(allocator, self);
        }
    };

    pub const LogEventType = enum(i32) {
        transaction_start,
        prepare_sent,
        vote_received,
        commit_decision,
        abort_decision,
        transaction_complete,
    };

    pub fn init(allocator: Allocator, node_id: []const u8) Coordinator {
        return .{
            .allocator = allocator,
            .node_id = node_id,
            .transactions = std.StringHashMap(Transaction).init(allocator),
            .log_writer = null,
            // #843: allow env override for harness-driven failure-mode tests.
            // GEODE_2PC_TIMEOUT_MS is parsed once at init; invalid values
            // fall back to the 30_000 ms default.
            .default_timeout_ms = readTimeoutEnv(),
            .send_fn = defaultSendMessage,
            .send_ctx = null,
        };
    }

    fn readTimeoutEnv() u64 {
        if (@import("builtin").os.tag == .windows) return 30_000;
        const name_z: [*:0]const u8 = "GEODE_2PC_TIMEOUT_MS";
        const ptr = std.c.getenv(name_z) orelse return 30_000;
        var len: usize = 0;
        while (ptr[len] != 0) : (len += 1) {}
        const s = ptr[0..len];
        return std.fmt.parseUnsigned(u64, s, 10) catch 30_000;
    }

    pub fn deinit(self: *Coordinator) void {
        var it = self.transactions.iterator();
        while (it.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.transactions.deinit();
    }

    pub fn setSendFn(self: *Coordinator, send_fn: SendFn, send_ctx: ?*anyopaque) void {
        self.send_fn = send_fn;
        self.send_ctx = send_ctx;
    }

    pub fn beginTransaction(self: *Coordinator, transaction_id: []const u8) !*Transaction {
        const txn = try Transaction.init(
            self.allocator,
            transaction_id,
            self.node_id,
            self.send_fn,
            self.send_ctx,
            self.default_timeout_ms,
            self.store,
        );
        try self.transactions.put(txn.id, txn);

        // Log transaction start
        if (self.log_writer) |writer| {
            try writer.writeEntry(.{
                .timestamp = compat_timestamp(),
                .transaction_id = txn.id,
                .event_type = .transaction_start,
                .data = "",
            });
        }

        return self.transactions.getPtr(txn.id).?;
    }

    pub fn executeTransaction(self: *Coordinator, transaction_id: []const u8) !bool {
        const txn = self.transactions.getPtr(transaction_id) orelse return error.TransactionNotFound;

        // Phase 1: Prepare
        const can_commit = try txn.prepare();

        if (self.log_writer) |writer| {
            try writer.writeEntry(.{
                .timestamp = compat_timestamp(),
                .transaction_id = transaction_id,
                .event_type = if (can_commit) .commit_decision else .abort_decision,
                .data = "",
            });
        }

        // Phase 2: Commit or Abort
        if (can_commit) {
            try txn.commit();
        } else {
            try txn.abort();
        }

        if (self.log_writer) |writer| {
            try writer.writeEntry(.{
                .timestamp = compat_timestamp(),
                .transaction_id = transaction_id,
                .event_type = .transaction_complete,
                .data = "",
            });
        }

        // Remove completed transaction to avoid unbounded growth
        if (self.transactions.fetchRemove(transaction_id)) |entry| {
            var removed_txn = entry.value;
            removed_txn.deinit();
        }

        return can_commit;
    }

    pub fn recoverFromLog(self: *Coordinator, log_file: []const u8) !void {
        const file = try std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.io(), log_file, .{});
        defer file.close();

        var buf_reader = std.Io.bufferedReader(file.reader());
        var reader = buf_reader.reader();
        while (true) {
            var len_buf: [4]u8 = undefined;
            const len_read = reader.readAll(&len_buf) catch |err| switch (err) {
                error.EndOfStream => break,
                else => return err,
            };
            if (len_read == 0) break;
            if (len_read < 4) return error.UnexpectedEndOfStream;

            const msg_len = std.mem.readInt(u32, &len_buf, .big);
            if (msg_len > MAX_FRAME_SIZE) return error.FrameTooLarge;
            const msg_buf = try self.allocator.alloc(u8, msg_len);
            defer self.allocator.free(msg_buf);
            const msg_read = try reader.readAll(msg_buf);
            if (msg_read < msg_len) return error.UnexpectedEndOfStream;

            var msg_reader: std.Io.Reader = .fixed(msg_buf);
            var entry = try protobuf.decode(LogEntry, &msg_reader, self.allocator);
            defer entry.deinit(self.allocator);

            // Recover transaction state
            switch (entry.event_type) {
                .transaction_start => {
                    _ = try self.beginTransaction(entry.transaction_id);
                },
                .commit_decision => {
                    if (self.transactions.getPtr(entry.transaction_id)) |txn| {
                        if (txn.state != .committed) {
                            try txn.commit();
                        }
                    }
                },
                .abort_decision => {
                    if (self.transactions.getPtr(entry.transaction_id)) |txn| {
                        if (txn.state != .aborted) {
                            try txn.abort();
                        }
                    }
                },
                else => {},
            }
        }
    }
};

// ParticipantNode extracted to twophase_participant.zig

/// High-level 2PC coordinator wrapper used by DistributedCoordinator.
pub const TwoPCCoordinator = struct {
    pub const Stats = struct {
        active_transactions: usize = 0,
        total_transactions: usize = 0,
        committed_transactions: usize = 0,
        aborted_transactions: usize = 0,
    };

    allocator: Allocator,
    coordinator_id: []const u8,
    participant_id: []const u8,
    coordinator: Coordinator,
    participant: ParticipantNode,
    resource_manager: ParticipantNode.ResourceManager,
    default_timeout_ms: u64,
    send_message_callback: ?*const fn ([]const u8, MessageType, []const u8) void = null,
    enable_coordinator: bool = true,
    enable_participant: bool = true,
    stats: Stats = .{},
    /// SEC-D009: Nonce tracker for replay protection on incoming 2PC messages.
    twophase_nonce_tracker: nonce_tracker.NonceTracker,

    pub fn init(allocator: Allocator, config: CoordinatorConfig) !TwoPCCoordinator {
        const coord_id = try allocator.dupe(u8, config.coordinator_id);
        const participant_id = try allocator.dupe(u8, config.participant_id orelse config.coordinator_id);
        var coordinator = Coordinator.init(allocator, coord_id);
        coordinator.default_timeout_ms = config.default_timeout_ms;
        coordinator.store = config.store;

        var result = TwoPCCoordinator{
            .allocator = allocator,
            .coordinator_id = coord_id,
            .participant_id = participant_id,
            .coordinator = coordinator,
            .participant = undefined,
            .resource_manager = ParticipantNode.ResourceManager.init(allocator),
            .default_timeout_ms = config.default_timeout_ms,
            .send_message_callback = null,
            .enable_coordinator = true,
            .enable_participant = true,
            .stats = .{},
            .twophase_nonce_tracker = try nonce_tracker.NonceTracker.init(allocator, 10_000),
        };
        result.participant = if (config.store) |store|
            ParticipantNode.initWithStore(allocator, participant_id, &result.resource_manager, store)
        else
            ParticipantNode.init(allocator, participant_id, &result.resource_manager);
        return result;
    }

    pub fn deinit(self: *TwoPCCoordinator) void {
        self.twophase_nonce_tracker.deinit();
        self.coordinator.deinit();
        self.participant.deinit();
        self.resource_manager.deinit();
        self.allocator.free(self.coordinator_id);
        self.allocator.free(self.participant_id);
    }

    /// Enable/disable coordinator and participant features independently.
    pub fn enableFeatures(self: *TwoPCCoordinator, coordinator_enabled: bool, participant_enabled: bool) void {
        self.enable_coordinator = coordinator_enabled;
        self.enable_participant = participant_enabled;
    }

    /// Set callback for sending outbound 2PC messages (used by higher-level coordinators).
    pub fn setSendMessageCallback(self: *TwoPCCoordinator, callback: *const fn ([]const u8, MessageType, []const u8) void) void {
        self.send_message_callback = callback;
    }

    /// Periodic maintenance (timeouts).
    pub fn tick(self: *TwoPCCoordinator) !void {
        if (!self.enable_coordinator) return;

        var to_abort: std.ArrayList([]const u8) = .empty;
        defer to_abort.deinit(self.allocator);

        var it = self.coordinator.transactions.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.isTimedOut()) {
                try to_abort.append(self.allocator, entry.key_ptr.*);
            }
        }

        for (to_abort.items) |transaction_id| {
            _ = try self.abortTransaction(transaction_id);
        }
    }

    /// Handle inbound 2PC messages (participant side).
    // SEC-D003: Validate cluster token on incoming 2PC messages.
    pub fn handleMessage(self: *TwoPCCoordinator, from: []const u8, message_type: MessageType, payload: []const u8) !void {
        if (!self.enable_participant) return;

        var reader: std.Io.Reader = .fixed(payload);
        var msg = protobuf.decode(TwoPhaseMessage, &reader, self.allocator) catch |err| {
            log.err("2PC handleMessage decode failed", &.{Attr.string("error", @errorName(err))});
            return err;
        };
        defer msg.deinit(self.allocator);

        // SEC-D003: Always validate auth_token on 2PC messages.
        // Reject any message without a valid token regardless of whether env var is set.
        if (!cluster_auth.validateClusterToken(msg.auth_token)) {
            log.warn("2PC message rejected: invalid or missing cluster token", &.{
                Attr.string("from", from),
                Attr.string("txn_id", msg.transaction_id),
            });
            return error.AuthFailed;
        }

        // SEC-D009: Validate nonce to prevent replay attacks on 2PC messages.
        if (!self.twophase_nonce_tracker.checkAndRecord(msg.nonce)) {
            log.warn("2PC message rejected: replay or missing nonce", &.{
                Attr.string("from", from),
                Attr.string("txn_id", msg.transaction_id),
                Attr.uint("nonce", msg.nonce),
            });
            return error.ReplayDetected;
        }

        const response: ?TwoPhaseResponse = switch (message_type) {
            .PREPARE => blk: {
                const vote = try self.participant.handlePrepare(&msg, payload);
                break :blk TwoPhaseResponse{
                    .msg_type = .PREPARE_RESPONSE,
                    .transaction_id = msg.transaction_id,
                    .participant_id = self.participant_id,
                    .vote = vote,
                    .timestamp = compat_timestamp(),
                };
            },
            .COMMIT => blk: {
                try self.participant.handleCommit(msg.transaction_id);
                break :blk TwoPhaseResponse{
                    .msg_type = .COMMIT_RESPONSE,
                    .transaction_id = msg.transaction_id,
                    .participant_id = self.participant_id,
                    .vote = .VOTE_COMMIT,
                    .timestamp = compat_timestamp(),
                };
            },
            .ABORT => blk: {
                try self.participant.handleAbort(msg.transaction_id);
                break :blk TwoPhaseResponse{
                    .msg_type = .ABORT_RESPONSE,
                    .transaction_id = msg.transaction_id,
                    .participant_id = self.participant_id,
                    .vote = .VOTE_ABORT,
                    .timestamp = compat_timestamp(),
                };
            },
            else => return error.UnsupportedMessage,
        };

        if (response) |resp| {
            if (self.send_message_callback) |callback| {
                var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(self.allocator, 128);
                defer aw.deinit();
                try protobuf.encode(&aw.writer, self.allocator, resp);
                const payload_bytes = try self.allocator.dupe(u8, aw.writer.buffer[0..aw.writer.end]);
                defer self.allocator.free(payload_bytes);
                callback(from, resp.msg_type, payload_bytes);
            }
        }
    }

    /// Begin a distributed transaction with a set of participants.
    pub fn beginTransaction(self: *TwoPCCoordinator, transaction_id: []const u8, participants: []const []const u8) !bool {
        if (!self.enable_coordinator) return false;

        const txn = try self.coordinator.beginTransaction(transaction_id);
        for (participants) |endpoint| {
            try txn.addParticipant(endpoint, endpoint);
        }
        self.stats.total_transactions += 1;
        self.stats.active_transactions = self.coordinator.transactions.count();
        return true;
    }

    /// Commit a distributed transaction.
    pub fn commitTransaction(self: *TwoPCCoordinator, transaction_id: []const u8) !bool {
        if (!self.enable_coordinator) return false;

        const committed = try self.coordinator.executeTransaction(transaction_id);
        if (committed) {
            self.stats.committed_transactions += 1;
        } else {
            self.stats.aborted_transactions += 1;
        }
        self.stats.active_transactions = self.coordinator.transactions.count();
        return committed;
    }

    /// Abort a distributed transaction.
    pub fn abortTransaction(self: *TwoPCCoordinator, transaction_id: []const u8) !bool {
        if (!self.enable_coordinator) return false;

        if (self.coordinator.transactions.getPtr(transaction_id)) |txn| {
            try txn.abort();
            if (self.coordinator.transactions.fetchRemove(transaction_id)) |entry| {
                entry.value.deinit();
            }
            self.stats.aborted_transactions += 1;
            self.stats.active_transactions = self.coordinator.transactions.count();
            return true;
        }
        return false;
    }

    pub fn getStats(self: *TwoPCCoordinator) Stats {
        var stats = self.stats;
        stats.active_transactions = self.coordinator.transactions.count();
        return stats;
    }
};

// ---------------------------------------------------------------------------
// Tests
// ---------------------------------------------------------------------------

const testing = std.testing;

fn stubSend(_: ?*anyopaque, _: []const u8, _: TwoPhaseMessage, _: u64) anyerror!TwoPhaseResponse {
    return error.ConnectionRefused;
}

test "applyUndoOperation deletes created node" {
    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();

    // Create a node in the store that the undo should remove.
    try store.createNodeWithId(42, &.{}, graph_store.DEFAULT_GRAPH_NAME);
    try testing.expect(store.getNodePtr(42) != null);

    // Build an undo entry representing a CREATE node operation.
    const undo = UndoEntry{
        .operation = .{
            .node_op = .{
                .op_type = .CREATE,
                .node_id = 42,
                .label = "",
                .graph_name = "",
                .properties = .empty,
            },
        },
        .timestamp = compat_timestamp(),
    };

    applyUndoOperation(&store, undo);

    // The node should have been deleted.
    try testing.expect(store.getNodePtr(42) == null);
}

test "applyUndoOperation deletes created edge" {
    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();

    // Create source and target nodes, then an edge.
    try store.createNodeWithId(1, &.{}, graph_store.DEFAULT_GRAPH_NAME);
    try store.createNodeWithId(2, &.{}, graph_store.DEFAULT_GRAPH_NAME);
    try store.createEdgeWithId(100, 1, 2, "KNOWS", graph_store.DEFAULT_GRAPH_NAME);
    try testing.expect(store.getEdgePtr(100) != null);

    const undo = UndoEntry{
        .operation = .{
            .edge_op = .{
                .op_type = .CREATE,
                .edge_id = 100,
                .source_id = 1,
                .target_id = 2,
                .edge_type = "",
                .graph_name = "",
                .properties = .empty,
            },
        },
        .timestamp = compat_timestamp(),
    };

    applyUndoOperation(&store, undo);

    // The edge should have been deleted.
    try testing.expect(store.getEdgePtr(100) == null);
}

test "applyUndoOperation without store does not crash" {
    const undo = UndoEntry{
        .operation = .{
            .node_op = .{
                .op_type = .CREATE,
                .node_id = 99,
                .label = "",
                .graph_name = "",
                .properties = .empty,
            },
        },
        .timestamp = 0,
    };

    // Should complete without error even when store is null.
    applyUndoOperation(null, undo);
}

test "Transaction.abort applies undo log via store" {
    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();

    // Create a node that the abort should undo.
    try store.createNodeWithId(77, &.{}, graph_store.DEFAULT_GRAPH_NAME);
    try testing.expect(store.getNodePtr(77) != null);

    var txn = try Transaction.init(
        testing.allocator,
        "txn-abort-test",
        "coord-1",
        stubSend,
        null,
        30_000,
        &store,
    );
    defer txn.deinit();

    // Add a participant and push an undo entry representing node creation.
    try txn.addParticipant("p1", "localhost:9999");
    try txn.participants.items[0].undo_log.append(testing.allocator, .{
        .operation = .{
            .node_op = .{
                .op_type = .CREATE,
                .node_id = 77,
                .label = "",
                .graph_name = "",
                .properties = .empty,
            },
        },
        .timestamp = compat_timestamp(),
    });

    // Abort the transaction -- this should apply undo and delete node 77.
    try txn.abort();

    try testing.expect(store.getNodePtr(77) == null);
    try testing.expect(txn.state == .aborted);
}

test "getClusterToken returns empty when env not set" {
    // In test environment GEODE_CLUSTER_TOKEN is not set
    const token = getClusterToken();
    try testing.expectEqualStrings("", token);
}

test "prepare message includes auth_token field" {
    // Verify that the TwoPhaseMessage struct accepts auth_token field
    var ops: std.ArrayList(Operation) = .empty;
    defer ops.deinit(testing.allocator);
    const msg = TwoPhaseMessage{
        .msg_type = .PREPARE,
        .transaction_id = "txn-test",
        .coordinator_id = "coord-test",
        .timestamp = 12345,
        .operations = ops,
        .auth_token = "test-token-value",
    };
    try testing.expectEqualStrings("test-token-value", msg.auth_token);
}

/// A participant response the caller owns: `prepareWorker` and `commit` free
/// what `send` returns with the transaction's allocator (testing.allocator in
/// these tests), so its strings are allocated, not literals (SONNY-6459).
fn stubResponse(vote: dist_schema.TwoPhaseVote) !TwoPhaseResponse {
    const a = testing.allocator;
    const transaction_id = try a.dupe(u8, "txn-init-test");
    errdefer a.free(transaction_id);
    return TwoPhaseResponse{
        .msg_type = .PREPARE_RESPONSE,
        .transaction_id = transaction_id,
        .participant_id = try a.dupe(u8, "p1"),
        .vote = vote,
        .timestamp = 0,
    };
}

fn stubSendCommit(_: ?*anyopaque, _: []const u8, _: TwoPhaseMessage, _: u64) anyerror!TwoPhaseResponse {
    return stubResponse(.VOTE_COMMIT);
}

fn stubSendAbort(_: ?*anyopaque, _: []const u8, _: TwoPhaseMessage, _: u64) anyerror!TwoPhaseResponse {
    return stubResponse(.VOTE_ABORT);
}

test "Transaction.init creates valid initial state" {
    var txn = try Transaction.init(
        testing.allocator,
        "txn-init-test",
        "coord-1",
        stubSend,
        null,
        5000,
        null,
    );
    defer txn.deinit();

    try testing.expectEqualStrings("txn-init-test", txn.id);
    try testing.expectEqualStrings("coord-1", txn.coordinator_id);
    try testing.expectEqual(TransactionState.active, txn.state);
    try testing.expectEqual(@as(u64, 5000), txn.timeout_ms);
    try testing.expectEqual(@as(usize, 0), txn.participants.items.len);
    try testing.expectEqual(@as(usize, 0), txn.operations.items.len);
    try testing.expectEqual(@as(usize, 0), txn.savepoints.items.len);
    try testing.expectEqual(IsolationLevel.read_committed, txn.isolation_level);
    try testing.expect(txn.store == null);
}

test "Transaction.prepare transitions to prepared when all vote commit" {
    var txn = try Transaction.init(
        testing.allocator,
        "txn-prep-ok",
        "coord-1",
        stubSendCommit,
        null,
        5000,
        null,
    );
    defer txn.deinit();

    try txn.addParticipant("p1", "localhost:9001");

    const can_commit = try txn.prepare();
    try testing.expect(can_commit);
    try testing.expectEqual(TransactionState.prepared, txn.state);
}

test "Transaction.prepare transitions to aborting when participant votes abort" {
    var txn = try Transaction.init(
        testing.allocator,
        "txn-prep-abort",
        "coord-1",
        stubSendAbort,
        null,
        5000,
        null,
    );
    defer txn.deinit();

    try txn.addParticipant("p1", "localhost:9001");

    const can_commit = try txn.prepare();
    try testing.expect(!can_commit);
    try testing.expectEqual(TransactionState.aborting, txn.state);
}

test "Transaction.prepare transitions to aborting on send failure" {
    var txn = try Transaction.init(
        testing.allocator,
        "txn-prep-fail",
        "coord-1",
        stubSend, // stubSend returns ConnectionRefused
        null,
        5000,
        null,
    );
    defer txn.deinit();

    try txn.addParticipant("p1", "localhost:9001");

    const can_commit = try txn.prepare();
    try testing.expect(!can_commit);
    try testing.expectEqual(TransactionState.aborting, txn.state);
}

test "Transaction.commit transitions from prepared to committed" {
    var txn = try Transaction.init(
        testing.allocator,
        "txn-commit-ok",
        "coord-1",
        stubSendCommit,
        null,
        5000,
        null,
    );
    defer txn.deinit();

    try txn.addParticipant("p1", "localhost:9001");

    // Must prepare first
    const can_commit = try txn.prepare();
    try testing.expect(can_commit);

    try txn.commit();
    try testing.expectEqual(TransactionState.committed, txn.state);
}

test "Transaction.commit rejects non-prepared state" {
    var txn = try Transaction.init(
        testing.allocator,
        "txn-commit-bad",
        "coord-1",
        stubSend,
        null,
        5000,
        null,
    );
    defer txn.deinit();

    // Transaction is in 'active' state, not 'prepared'
    const result = txn.commit();
    try testing.expectError(error.InvalidState, result);
}

test "Transaction.addParticipant and createSavepoint" {
    var txn = try Transaction.init(
        testing.allocator,
        "txn-misc",
        "coord-1",
        stubSend,
        null,
        5000,
        null,
    );
    defer txn.deinit();

    try txn.addParticipant("p1", "localhost:9001");
    try txn.addParticipant("p2", "localhost:9002");
    try testing.expectEqual(@as(usize, 2), txn.participants.items.len);
    try testing.expectEqualStrings("p1", txn.participants.items[0].id);
    try testing.expectEqualStrings("p2", txn.participants.items[1].id);

    try txn.createSavepoint("sp1");
    try testing.expectEqual(@as(usize, 1), txn.savepoints.items.len);
    try testing.expectEqualStrings("sp1", txn.savepoints.items[0].name);
}

test "Transaction.rollbackToSavepoint removes operations after savepoint" {
    var txn = try Transaction.init(
        testing.allocator,
        "txn-rollback",
        "coord-1",
        stubSend,
        null,
        5000,
        null,
    );
    defer txn.deinit();

    // Add an operation, create savepoint, add another operation
    try txn.addOperation(.{
        .node_op = .{
            .op_type = .CREATE,
            .node_id = 1,
            .label = "",
            .graph_name = "",
            .properties = .empty,
        },
    });
    try txn.createSavepoint("sp1");
    try txn.addOperation(.{
        .node_op = .{
            .op_type = .CREATE,
            .node_id = 2,
            .label = "",
            .graph_name = "",
            .properties = .empty,
        },
    });

    try testing.expectEqual(@as(usize, 2), txn.operations.items.len);

    try txn.rollbackToSavepoint("sp1");
    try testing.expectEqual(@as(usize, 1), txn.operations.items.len);
}

test "Transaction.rollbackToSavepoint returns error for unknown savepoint" {
    var txn = try Transaction.init(
        testing.allocator,
        "txn-rollback-bad",
        "coord-1",
        stubSend,
        null,
        5000,
        null,
    );
    defer txn.deinit();

    const result = txn.rollbackToSavepoint("nonexistent");
    try testing.expectError(error.SavepointNotFound, result);
}

test "2PC nonce generation produces nonzero distinct values" {
    // SEC-D009: Verify that nonce generation works for 2PC messages.
    const n1 = nonce_tracker.NonceTracker.generateNonce();
    const n2 = nonce_tracker.NonceTracker.generateNonce();
    try testing.expect(n1 != 0);
    try testing.expect(n2 != 0);
    try testing.expect(n1 != n2);
}

test "TwoPCCoordinator.handleMessage rejects replayed nonce" {
    // SEC-D009: Verify replay detection on the receive side.
    const ally = testing.allocator;
    var coord = try TwoPCCoordinator.init(ally, .{
        .coordinator_id = "coord-replay",
    });
    defer coord.deinit();

    // Build a valid 2PC PREPARE message with a specific nonce.
    var ops: std.ArrayList(Operation) = .empty;
    defer ops.deinit(ally);
    const msg = TwoPhaseMessage{
        .msg_type = .PREPARE,
        .transaction_id = "txn-replay",
        .coordinator_id = "coord-remote",
        .timestamp = 12345,
        .operations = ops,
        .auth_token = "",
        .nonce = 42,
    };

    // Encode the message to protobuf bytes.
    var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(ally, 256);
    defer aw.deinit();
    try protobuf.encode(&aw.writer, ally, msg);
    const payload = aw.writer.buffer[0..aw.writer.end];

    // First call should succeed (nonce 42 is new).
    // It may return an error from participant handling but NOT ReplayDetected.
    const first_result = coord.handleMessage("remote-node", .PREPARE, payload);
    if (first_result) |_| {} else |err| {
        try testing.expect(err != error.ReplayDetected);
    }

    // Second call with the same payload (same nonce 42) should be rejected as replay.
    const second_result = coord.handleMessage("remote-node", .PREPARE, payload);
    try testing.expectError(error.ReplayDetected, second_result);
}

test "TwoPCCoordinator.handleMessage rejects zero nonce" {
    // SEC-D009: A zero nonce indicates an uninitialized or legacy frame and should be rejected.
    const ally = testing.allocator;
    var coord = try TwoPCCoordinator.init(ally, .{
        .coordinator_id = "coord-zero",
    });
    defer coord.deinit();

    var ops: std.ArrayList(Operation) = .empty;
    defer ops.deinit(ally);
    const msg = TwoPhaseMessage{
        .msg_type = .PREPARE,
        .transaction_id = "txn-zero",
        .coordinator_id = "coord-remote",
        .timestamp = 12345,
        .operations = ops,
        .auth_token = "",
        .nonce = 0,
    };

    var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(ally, 256);
    defer aw.deinit();
    try protobuf.encode(&aw.writer, ally, msg);
    const payload = aw.writer.buffer[0..aw.writer.end];

    const r = coord.handleMessage("remote-node", .PREPARE, payload);
    try testing.expectError(error.ReplayDetected, r);
}

// CANARY: REQ=REQ-DIST-2PC-UNDO-005; FEATURE="2PC Undo Pre-Image Tests"; ASPECT=TestCoverage; STATUS=TESTED; OWNER=distributed; UPDATED=2026-04-06
test "applyUndoOperation UPDATE node restores pre-image properties" {
    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();

    // Create a node and set an initial property (pre-image state).
    try store.createNodeWithId(200, &.{"Person"}, graph_store.DEFAULT_GRAPH_NAME);
    try store.setNodeProperty(200, "name", .{ .String = "Alice" });
    try store.setNodeProperty(200, "age", .{ .Int = 30 });

    // Simulate that the operation mutated the properties (post-image in store now).
    try store.setNodeProperty(200, "name", .{ .String = "AliceModified" });
    try store.setNodeProperty(200, "age", .{ .Int = 99 });

    // Build an undo entry for UPDATE with pre-image = original values.
    // UndoEntry owns its strings (`deinit` frees them), so they are
    // allocated here, not literals (SONNY-6459).
    var pre_props = std.ArrayList(proto_schema.MapEntry).empty;
    const name_val = proto_schema.Value{ .kind = .{ .string_val = .{ .value = try testing.allocator.dupe(u8, "Alice"), .kind = .STRING } } };
    const age_val = proto_schema.Value{ .kind = .{ .int_val = .{ .value = 30, .kind = .INT } } };
    try pre_props.append(testing.allocator, .{ .key = try testing.allocator.dupe(u8, "name"), .value = name_val });
    try pre_props.append(testing.allocator, .{ .key = try testing.allocator.dupe(u8, "age"), .value = age_val });

    var undo = UndoEntry{
        .operation = .{
            .node_op = .{
                .op_type = .UPDATE,
                .node_id = 200,
                .label = try testing.allocator.dupe(u8, "Person"),
                .graph_name = "",
                .properties = .empty,
            },
        },
        .timestamp = compat_timestamp(),
        .pre_image_props = pre_props,
    };
    defer undo.deinit(testing.allocator);

    applyUndoOperation(&store, undo);

    // Properties should be restored to pre-image values.
    const name_pv = store.getNodeProperty(200, "name") orelse return error.PropertyMissing;
    try testing.expectEqualStrings("Alice", name_pv.String);
    const age_pv = store.getNodeProperty(200, "age") orelse return error.PropertyMissing;
    try testing.expectEqual(@as(i64, 30), age_pv.Int);
}

test "applyUndoOperation DELETE node re-creates node from pre-image" {
    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();

    // Create a node, set properties, capture pre-image, then delete.
    try store.createNodeWithId(201, &.{"Car"}, graph_store.DEFAULT_GRAPH_NAME);
    try store.setNodeProperty(201, "model", .{ .String = "Sedan" });

    // Build undo entry for DELETE with pre-image.
    var pre_props = std.ArrayList(proto_schema.MapEntry).empty;
    const model_val = proto_schema.Value{ .kind = .{ .string_val = .{ .value = try testing.allocator.dupe(u8, "Sedan"), .kind = .STRING } } };
    try pre_props.append(testing.allocator, .{ .key = try testing.allocator.dupe(u8, "model"), .value = model_val });

    var pre_labels = std.ArrayList([]const u8).empty;
    try pre_labels.append(testing.allocator, try testing.allocator.dupe(u8, "Car"));

    var undo = UndoEntry{
        .operation = .{
            .node_op = .{
                .op_type = .DELETE,
                .node_id = 201,
                .label = try testing.allocator.dupe(u8, "Car"),
                .graph_name = try testing.allocator.dupe(u8, graph_store.DEFAULT_GRAPH_NAME),
                .properties = .empty,
            },
        },
        .timestamp = compat_timestamp(),
        .pre_image_props = pre_props,
        .pre_image_labels = pre_labels,
        .pre_image_graph_name = try testing.allocator.dupe(u8, graph_store.DEFAULT_GRAPH_NAME),
    };
    defer undo.deinit(testing.allocator);

    // Delete the node to simulate the operation that needs to be undone.
    store.deleteNode(201);
    try testing.expect(store.getNodePtr(201) == null);

    // Apply undo -- should re-create the node.
    applyUndoOperation(&store, undo);

    try testing.expect(store.getNodePtr(201) != null);
    const model_pv = store.getNodeProperty(201, "model") orelse return error.PropertyMissing;
    try testing.expectEqualStrings("Sedan", model_pv.String);
}

test "captureNodePreImage captures properties and labels" {
    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();

    try store.createNodeWithId(300, &.{"Widget"}, graph_store.DEFAULT_GRAPH_NAME);
    try store.setNodeProperty(300, "color", .{ .String = "blue" });
    try store.setNodeProperty(300, "count", .{ .Int = 5 });

    var undo = UndoEntry{
        .operation = .{
            .node_op = .{
                .op_type = .UPDATE,
                .node_id = 300,
                .label = try testing.allocator.dupe(u8, "Widget"),
                .graph_name = try testing.allocator.dupe(u8, graph_store.DEFAULT_GRAPH_NAME),
                .properties = .empty,
            },
        },
        .timestamp = compat_timestamp(),
    };
    defer undo.deinit(testing.allocator);

    try captureNodePreImage(testing.allocator, &store, 300, &undo);

    // Pre-image should have 2 properties captured.
    try testing.expect(undo.pre_image_props != null);
    try testing.expectEqual(@as(usize, 2), undo.pre_image_props.?.items.len);

    // Labels should be captured.
    try testing.expect(undo.pre_image_labels != null);
    try testing.expectEqual(@as(usize, 1), undo.pre_image_labels.?.items.len);
    try testing.expectEqualStrings("Widget", undo.pre_image_labels.?.items[0]);

    // Graph name should be captured.
    try testing.expectEqualStrings(graph_store.DEFAULT_GRAPH_NAME, undo.pre_image_graph_name);
}

test "captureEdgePreImage captures edge properties" {
    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();

    try store.createNodeWithId(1, &.{}, graph_store.DEFAULT_GRAPH_NAME);
    try store.createNodeWithId(2, &.{}, graph_store.DEFAULT_GRAPH_NAME);
    try store.createEdgeWithId(400, 1, 2, "LIKES", graph_store.DEFAULT_GRAPH_NAME);
    try store.setEdgeProperty(400, "since", .{ .Int = 2020 });

    var undo = UndoEntry{
        .operation = .{
            .edge_op = .{
                .op_type = .UPDATE,
                .edge_id = 400,
                .source_id = 1,
                .target_id = 2,
                .edge_type = try testing.allocator.dupe(u8, "LIKES"),
                .graph_name = try testing.allocator.dupe(u8, graph_store.DEFAULT_GRAPH_NAME),
                .properties = .empty,
            },
        },
        .timestamp = compat_timestamp(),
    };
    defer undo.deinit(testing.allocator);

    try captureEdgePreImage(testing.allocator, &store, 400, &undo);

    try testing.expect(undo.pre_image_props != null);
    try testing.expectEqual(@as(usize, 1), undo.pre_image_props.?.items.len);
    try testing.expectEqualStrings("since", undo.pre_image_props.?.items[0].key);
}

test "applyUndoOperation UPDATE node without pre-image logs warning and is no-op" {
    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();

    try store.createNodeWithId(500, &.{}, graph_store.DEFAULT_GRAPH_NAME);
    try store.setNodeProperty(500, "x", .{ .Int = 42 });

    const undo = UndoEntry{
        .operation = .{
            .node_op = .{
                .op_type = .UPDATE,
                .node_id = 500,
                .label = "",
                .graph_name = "",
                .properties = .empty,
            },
        },
        .timestamp = compat_timestamp(),
        // No pre_image_props — should log warning and leave property intact.
    };

    applyUndoOperation(&store, undo);

    // Property should be unchanged since no pre-image was available.
    const x_pv = store.getNodeProperty(500, "x") orelse return error.PropertyMissing;
    try testing.expectEqual(@as(i64, 42), x_pv.Int);
}
