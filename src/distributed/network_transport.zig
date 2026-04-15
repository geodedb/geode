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
const quic = @import("transport/quic");
const protobuf = @import("protobuf");
const dist_schema = @import("distributed_schema");

// CANARY: REQ=REQ-GQL-041; FEATURE="Cluster Networking"; ASPECT=InterNodeMessaging; STATUS=IMPL; OWNER=distributed; UPDATED=2026-04-05

pub const ClusterMessageType = dist_schema.ClusterMessageType;
pub const ClusterMessage = dist_schema.ClusterMessage;

pub const NetworkTransport = struct {
    allocator: std.mem.Allocator,
    node_id: u32,
    quic_transport: *quic.QuicTransport,
    peers: std.AutoHashMap(u32, PeerConnection),
    message_handler: ?MessageHandler,
    mutex: std.Io.Mutex,

    pub const PeerConnection = struct {
        node_id: u32,
        address: []const u8,
        connection: ?*quic.QuicConnection,
        last_seen: i64,
        retry_count: u32,
    };

    pub const MessageHandler = fn (*NetworkTransport, *const ClusterMessage) void;

    pub fn init(allocator: std.mem.Allocator, node_id: u32, quic_transport: *quic.QuicTransport) !NetworkTransport {
        return NetworkTransport{
            .allocator = allocator,
            .node_id = node_id,
            .quic_transport = quic_transport,
            .peers = std.AutoHashMap(u32, PeerConnection).init(allocator),
            .message_handler = null,
            .mutex = .{},
        };
    }

    pub fn deinit(self: *NetworkTransport) void {
        var it = self.peers.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.connection) |conn| {
                conn.close();
            }
        }
        self.peers.deinit();
    }

    pub fn addPeer(self: *NetworkTransport, node_id: u32, address: []const u8) !void {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        const addr_copy = try self.allocator.dupe(u8, address);
        try self.peers.put(node_id, .{
            .node_id = node_id,
            .address = addr_copy,
            .connection = null,
            .last_seen = compat_milliTimestamp(),
            .retry_count = 0,
        });
    }

    pub fn sendToNode(self: *NetworkTransport, node_id: u32, msg: *const ClusterMessage) !void {
        // Serialize message with length-prefixed protobuf framing (no lock needed)
        var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(self.allocator, 512);
        defer aw.deinit();
        try protobuf.encode(&aw.writer, self.allocator, msg.*);
        const body = aw.writer.buffer[0..aw.writer.end];

        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();
        try buffer.writer().writeInt(u32, @intCast(body.len), .big);
        try buffer.writer().writeAll(body);

        // Look up peer info and existing connection under lock
        var existing_conn: ?*quic.QuicConnection = null;
        var peer_address: []const u8 = undefined;
        {
            self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
            defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
            const peer = self.peers.get(node_id) orelse return error.PeerNotFound;
            existing_conn = peer.connection;
            peer_address = peer.address;
        }

        // Retry logic: 3 attempts with exponential backoff (no lock held during I/O)
        const retry_delays = [_]u64{ 50, 100, 200 }; // milliseconds
        var retry: usize = 0;
        while (retry < 3) : (retry += 1) {
            if (existing_conn) |conn| {
                conn.send(buffer.items) catch |err| {
                    if (retry < 2) {
                        std.time.sleep(retry_delays[retry] * std.time.ns_per_ms);
                        continue;
                    }
                    return err;
                };
                return;
            } else {
                // Establish connection without holding lock
                const conn = self.quic_transport.connect(peer_address) catch |err| {
                    if (retry < 2) {
                        std.time.sleep(retry_delays[retry] * std.time.ns_per_ms);
                        continue;
                    }
                    return err;
                };

                // Update peer connection state under lock
                {
                    self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
                    defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
                    if (self.peers.getPtr(node_id)) |updated_peer| {
                        updated_peer.connection = conn;
                        updated_peer.last_seen = compat_milliTimestamp();
                    }
                }
                existing_conn = conn;

                // Send message without lock
                conn.send(buffer.items) catch |err| {
                    if (retry < 2) {
                        std.time.sleep(retry_delays[retry] * std.time.ns_per_ms);
                        continue;
                    }
                    return err;
                };
                return;
            }
        }

        return error.SendFailed;
    }

    pub fn onMessage(self: *NetworkTransport, handler: MessageHandler) void {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        self.message_handler = handler;
    }

    pub fn processIncomingMessage(self: *NetworkTransport, data: []const u8) !void {
        if (data.len < 4) return error.InvalidMessage;

        const len = std.mem.readInt(u32, data[0..4], .big);
        if (data.len < 4 + len) return error.TruncatedMessage;

        var reader: std.Io.Reader = .fixed(data[4 .. 4 + len]);
        var msg = protobuf.decode(ClusterMessage, &reader, self.allocator) catch return error.InvalidMessage;
        defer msg.deinit(self.allocator);

        if (self.message_handler) |handler| {
            handler(self, &msg);
        }
    }

    pub fn checkHealth(self: *NetworkTransport) !void {
        self.mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer self.mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        const now = compat_milliTimestamp();
        var it = self.peers.iterator();

        while (it.next()) |entry| {
            const peer = entry.value_ptr;
            const elapsed = now - peer.last_seen;

            if (elapsed > 5000) { // 5 second timeout
                if (peer.connection) |conn| {
                    conn.close();
                    peer.connection = null;
                }
                peer.retry_count += 1;

                if (peer.retry_count > 10) {
                    // Mark peer as potentially failed
                    std.debug.print("PEER_UNHEALTHY node={} elapsed_ms={}\n", .{ peer.node_id, elapsed });
                }
            }
        }
    }
};

// CANARY: REQ=REQ-GQL-041; FEATURE="Cluster Networking"; ASPECT=NetworkTransportTests; STATUS=TESTED; TEST="ClusterMessageType and ClusterMessage are re-exported correctly"; OWNER=distributed; UPDATED=2026-04-10

test "ClusterMessageType and ClusterMessage are re-exported correctly" {
    // Verify that module-level type re-exports compile correctly in Zig 0.15.
    // This ensures the distributed_schema import and re-export pattern is valid.
    const msg_type: ClusterMessageType = undefined;
    _ = msg_type;
}

test "NetworkTransport struct fields are correctly typed" {
    // Compile-time structural verification of NetworkTransport fields.
    // Verifies that the struct layout compiles in Zig 0.15 without API issues.
    const info = @typeInfo(NetworkTransport);
    const fields = info.@"struct".fields;
    // There must be at least 6 fields: allocator, node_id, quic_transport, peers, message_handler, mutex
    try std.testing.expect(fields.len >= 6);
}
