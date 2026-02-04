const std = @import("std");
const quic = @import("../transport/quic_msquic.zig");
const protobuf = @import("protobuf");
const dist_schema = @import("distributed_schema");

// CANARY: REQ=REQ-GQL-041; FEATURE="Cluster Networking"; ASPECT=InterNodeMessaging; STATUS=TESTED; TEST=e2e_distributed_cluster; OWNER=distributed; UPDATED=2025-09-25

pub const ClusterMessageType = dist_schema.ClusterMessageType;
pub const ClusterMessage = dist_schema.ClusterMessage;

pub const NetworkTransport = struct {
    allocator: std.mem.Allocator,
    node_id: u32,
    quic_transport: *quic.QuicTransport,
    peers: std.AutoHashMap(u32, PeerConnection),
    message_handler: ?MessageHandler,
    mutex: std.Thread.Mutex,

    const PeerConnection = struct {
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
        self.mutex.lock();
        defer self.mutex.unlock();

        const addr_copy = try self.allocator.dupe(u8, address);
        try self.peers.put(node_id, .{
            .node_id = node_id,
            .address = addr_copy,
            .connection = null,
            .last_seen = std.time.milliTimestamp(),
            .retry_count = 0,
        });
    }

    pub fn sendToNode(self: *NetworkTransport, node_id: u32, msg: *const ClusterMessage) !void {
        self.mutex.lock();
        defer self.mutex.unlock();

        const peer = self.peers.get(node_id) orelse return error.PeerNotFound;

        // Serialize message with length-prefixed protobuf framing
        var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(self.allocator, 512);
        defer aw.deinit();
        try protobuf.encode(&aw.writer, self.allocator, msg.*);
        const body = aw.writer.buffer[0..aw.writer.end];

        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();
        try buffer.writer().writeInt(u32, @intCast(body.len), .big);
        try buffer.writer().writeAll(body);

        // Retry logic: 3 attempts with exponential backoff
        const retry_delays = [_]u64{ 50, 100, 200 }; // milliseconds
        var retry: usize = 0;
        while (retry < 3) : (retry += 1) {
            if (peer.connection) |conn| {
                conn.send(buffer.items) catch |err| {
                    if (retry < 2) {
                        std.time.sleep(retry_delays[retry] * std.time.ns_per_ms);
                        continue;
                    }
                    return err;
                };
                return;
            } else {
                // Establish connection
                const conn = self.quic_transport.connect(peer.address) catch |err| {
                    if (retry < 2) {
                        std.time.sleep(retry_delays[retry] * std.time.ns_per_ms);
                        continue;
                    }
                    return err;
                };

                // Update peer connection
                var updated_peer = self.peers.getPtr(node_id).?;
                updated_peer.connection = conn;
                updated_peer.last_seen = std.time.milliTimestamp();

                // Send message
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
        self.mutex.lock();
        defer self.mutex.unlock();
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
        self.mutex.lock();
        defer self.mutex.unlock();

        const now = std.time.milliTimestamp();
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
