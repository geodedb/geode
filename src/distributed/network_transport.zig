const std = @import("std");
const quic = @import("../transport/quic.zig");

// CANARY: REQ=REQ-GQL-041; FEATURE="Cluster Networking"; ASPECT=InterNodeMessaging; STATUS=TESTED; TEST=e2e_distributed_cluster; OWNER=distributed; UPDATED=2025-09-25

pub const ClusterMessageType = enum(u8) {
    append_entries,
    append_entries_response,
    request_vote,
    request_vote_response,
    install_snapshot,
    install_snapshot_response,
    heartbeat,
    client_request,
    client_response,
};

pub const ClusterMessage = struct {
    msg_type: ClusterMessageType,
    source_node: u32,
    dest_node: u32,
    term: u64,
    payload: []const u8,
};

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
        
        // Serialize message with length-prefix framing
        var buffer = std.ArrayList(u8).init(self.allocator);
        defer buffer.deinit();
        
        // Frame: u32 length | u8 msg_type | payload
        const payload_len = @sizeOf(ClusterMessage) - @sizeOf([]const u8) + msg.payload.len;
        try buffer.writer().writeInt(u32, @intCast(payload_len), .little);
        try buffer.writer().writeByte(@intFromEnum(msg.msg_type));
        try buffer.writer().writeInt(u32, msg.source_node, .little);
        try buffer.writer().writeInt(u32, msg.dest_node, .little);
        try buffer.writer().writeInt(u64, msg.term, .little);
        try buffer.writer().writeAll(msg.payload);
        
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
        if (data.len < 13) return error.InvalidMessage; // Min size check
        
        var reader = std.io.fixedBufferStream(data);
        const len = try reader.reader().readInt(u32, .little);
        const msg_type_byte = try reader.reader().readByte();
        const source = try reader.reader().readInt(u32, .little);
        const dest = try reader.reader().readInt(u32, .little);
        const term = try reader.reader().readInt(u64, .little);
        
        const payload_start = 13;
        if (data.len < payload_start + len - 13) return error.TruncatedMessage;
        
        const msg = ClusterMessage{
            .msg_type = @enumFromInt(msg_type_byte),
            .source_node = source,
            .dest_node = dest,
            .term = term,
            .payload = data[payload_start..payload_start + len - 13],
        };
        
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