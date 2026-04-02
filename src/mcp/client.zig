const std = @import("std");
const build_options = @import("build_options");

// CANARY: REQ=REQ-LIB-MIGRATION-MCP-008; FEATURE="External Library Migration"; ASPECT=MCPClient; STATUS=EXEMPT; OWNER=core; UPDATED=2026-01-24
// GeodeClient - QUIC connection management for MCP server integration

const protobuf = @import("protobuf");
const schema = @import("schema");
const spice_wrapper = @import("parallel/spice");
const geode = @import("geode");
const query_runner = geode.query_runner;

// Import quic_transport through the parent module to ensure module resolution
const quic_transport = @import("mod.zig").quic_transport;

const ColumnInfo = struct {
    name: []const u8,
    type: []const u8,
};

pub const GeodeClientError = error{
    ConnectionFailed,
    HandshakeFailed,
    QueryFailed,
    InvalidResponse,
    NotConnected,
    StreamError,
    Timeout,
    OutOfMemory,
    ServerError,
};

/// GeodeClient manages a QUIC connection to the Geode server
/// Uses lazy connection - connects on first request
pub const GeodeClient = struct {
    allocator: std.mem.Allocator,
    endpoint: []const u8,
    port: u16,
    quic_client: ?quic_transport.QuicClient,
    stream: ?*quic_transport.QuicClientStream,
    connected: bool,
    handshake_done: bool,
    session_id: ?[]const u8,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, endpoint: []const u8) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        // Parse endpoint (host:port)
        var host: []const u8 = endpoint;
        var port: u16 = 3141;

        if (std.mem.lastIndexOfScalar(u8, endpoint, ':')) |colon| {
            host = endpoint[0..colon];
            port = std.fmt.parseInt(u16, endpoint[colon + 1 ..], 10) catch 3141;
        }

        self.* = Self{
            .allocator = allocator,
            .endpoint = try allocator.dupe(u8, host),
            .port = port,
            .quic_client = null,
            .stream = null,
            .connected = false,
            .handshake_done = false,
            .session_id = null,
        };

        return self;
    }

    pub fn deinit(self: *Self) void {
        self.disconnect();
        if (self.session_id) |sid| {
            self.allocator.free(sid);
        }
        self.allocator.free(self.endpoint);
        self.allocator.destroy(self);
    }

    fn disconnect(self: *Self) void {
        if (self.stream) |s| {
            s.deinit();
            self.stream = null;
        }
        if (self.quic_client) |*client| {
            client.deinit();
            self.quic_client = null;
        }
        self.connected = false;
        self.handshake_done = false;
        if (self.session_id) |sid| {
            self.allocator.free(sid);
            self.session_id = null;
        }
    }

    /// Ensure connection is established (lazy connect)
    fn ensureConnected(self: *Self) !void {
        if (self.connected and self.handshake_done) return;

        // Disconnect any partial state
        self.disconnect();

        // Initialize QUIC client
        self.quic_client = quic_transport.QuicClient.init(self.allocator);

        // Connect with insecure mode for local development (TODO: support TLS config) // #473
        self.quic_client.?.connectInsecure(self.endpoint, self.port, true) catch |err| {
            self.disconnect();
            std.debug.print("[MCP-CLIENT] Connection failed to {s}:{d}: {}\n", .{ self.endpoint, self.port, err });
            return GeodeClientError.ConnectionFailed;
        };

        // Wait for handshake
        self.quic_client.?.waitForHandshake(5) catch |err| {
            self.disconnect();
            std.debug.print("[MCP-CLIENT] Handshake failed: {}\n", .{err});
            return GeodeClientError.HandshakeFailed;
        };

        // Open bidirectional stream
        self.stream = self.quic_client.?.getStream() catch |err| {
            self.disconnect();
            std.debug.print("[MCP-CLIENT] Stream open failed: {}\n", .{err});
            return GeodeClientError.StreamError;
        };

        // Send HELLO (protobuf) and wait for acknowledgment
        const hello_req = schema.HelloRequest{
            .username = "",
            .password = "",
            .tenant_id = null,
            .client_name = "geode-mcp",
            .client_version = build_options.version,
            .wanted_conformance = "min",
        };
        self.writeProtoMessage(.{ .hello = hello_req }) catch |err| {
            self.disconnect();
            std.debug.print("[MCP-CLIENT] HELLO send failed: {}\n", .{err});
            return GeodeClientError.StreamError;
        };

        var hello_packet = self.readProtoMessage(self.allocator, 5000) catch |err| {
            self.disconnect();
            std.debug.print("[MCP-CLIENT] HELLO response failed: {}\n", .{err});
            return GeodeClientError.StreamError;
        };
        defer hello_packet.deinit(self.allocator);

        const hello_resp_msg = hello_packet.quic orelse return GeodeClientError.InvalidResponse;

        if (hello_resp_msg != .hello or !hello_resp_msg.hello.success) {
            self.disconnect();
            return GeodeClientError.HandshakeFailed;
        }

        if (hello_resp_msg.hello.session_id.len > 0) {
            self.session_id = try self.allocator.dupe(u8, hello_resp_msg.hello.session_id);
        }

        self.connected = true;
        self.handshake_done = true;
    }

    fn writeProtoMessage(self: *Self, msg: schema.QuicClientMessage) !void {
        const stream = self.stream orelse return GeodeClientError.NotConnected;
        var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(self.allocator, 4096);
        defer aw.deinit();

        const packet = schema.ClientPacket{ .quic = msg };
        try protobuf.encode(&aw.writer, self.allocator, packet);
        const body = aw.writer.buffer[0..aw.writer.end];

        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, @intCast(body.len), .big);
        try stream.writeAll(&len_buf);
        try stream.writeAll(body);
    }

    fn readProtoMessage(self: *Self, allocator: std.mem.Allocator, timeout_ms: u32) !schema.ServerPacket {
        const stream = self.stream orelse return GeodeClientError.NotConnected;

        var len_buf: [4]u8 = undefined;
        var total_read: usize = 0;
        var attempts: usize = 0;
        const max_attempts = @max(@as(usize, 1), timeout_ms / 10);

        while (total_read < 4) {
            const n = stream.read(len_buf[total_read..]) catch |err| {
                if (err == error.WouldBlock) {
                    attempts += 1;
                    if (attempts > max_attempts) return GeodeClientError.Timeout;
                    self.quic_client.?.poll(1) catch {};
                    std.Thread.sleep(10 * std.time.ns_per_ms);
                    continue;
                }
                return err;
            };
            if (n == 0) return GeodeClientError.StreamError;
            total_read += n;
        }

        const msg_len = std.mem.readInt(u32, &len_buf, .big);
        if (msg_len > 16 * 1024 * 1024) return GeodeClientError.InvalidResponse;

        const msg_bytes = try allocator.alloc(u8, msg_len);
        defer allocator.free(msg_bytes);

        total_read = 0;
        attempts = 0;
        while (total_read < msg_len) {
            const n = stream.read(msg_bytes[total_read..]) catch |err| {
                if (err == error.WouldBlock) {
                    attempts += 1;
                    if (attempts > max_attempts) return GeodeClientError.Timeout;
                    self.quic_client.?.poll(1) catch {};
                    std.Thread.sleep(10 * std.time.ns_per_ms);
                    continue;
                }
                return err;
            };
            if (n == 0) return GeodeClientError.StreamError;
            total_read += n;
        }

        var reader: std.Io.Reader = .fixed(msg_bytes);
        return try protobuf.decode(schema.ServerPacket, &reader, allocator);
    }

    fn jsonNumberFromU64(allocator: std.mem.Allocator, value: u64) !std.json.Value {
        if (value <= @as(u64, std.math.maxInt(i64))) {
            return .{ .integer = @intCast(value) };
        }
        const num_str = try std.fmt.allocPrint(allocator, "{d}", .{value});
        return .{ .number_string = num_str };
    }

    fn base64Encode(allocator: std.mem.Allocator, bytes: []const u8) ![]u8 {
        const out = try allocator.alloc(u8, std.base64.standard.Encoder.calcSize(bytes.len));
        _ = std.base64.standard.Encoder.encode(out, bytes);
        return out;
    }

    fn protoMapEntriesToJson(allocator: std.mem.Allocator, entries: []const schema.MapEntry) anyerror!std.json.ObjectMap {
        var obj = std.json.ObjectMap.init(allocator);
        for (entries) |entry| {
            const key = try allocator.dupe(u8, entry.key);
            const val = if (entry.value) |v|
                try protoValueToJson(allocator, v)
            else
                std.json.Value.null;
            try obj.put(key, val);
        }
        return obj;
    }

    fn protoNodeToJson(allocator: std.mem.Allocator, node: schema.NodeValue) !std.json.Value {
        var obj = std.json.ObjectMap.init(allocator);
        try obj.put("id", try jsonNumberFromU64(allocator, node.id));

        var labels = std.json.Array.init(allocator);
        for (node.labels.items) |label| {
            try labels.append(.{ .string = try allocator.dupe(u8, label) });
        }
        try obj.put("labels", .{ .array = labels });

        const props_obj = try protoMapEntriesToJson(allocator, node.properties.items);
        try obj.put("properties", .{ .object = props_obj });
        return .{ .object = obj };
    }

    fn protoEdgeToJson(allocator: std.mem.Allocator, edge: schema.EdgeValue) !std.json.Value {
        var obj = std.json.ObjectMap.init(allocator);
        try obj.put("id", try jsonNumberFromU64(allocator, edge.id));
        try obj.put("from_id", try jsonNumberFromU64(allocator, edge.from_id));
        try obj.put("to_id", try jsonNumberFromU64(allocator, edge.to_id));
        try obj.put("label", .{ .string = try allocator.dupe(u8, edge.label) });

        const props_obj = try protoMapEntriesToJson(allocator, edge.properties.items);
        try obj.put("properties", .{ .object = props_obj });
        return .{ .object = obj };
    }

    fn protoPathToJson(allocator: std.mem.Allocator, path: schema.PathValue) !std.json.Value {
        var obj = std.json.ObjectMap.init(allocator);
        var nodes = std.json.Array.init(allocator);
        for (path.nodes.items) |node| {
            try nodes.append(try protoNodeToJson(allocator, node));
        }
        try obj.put("nodes", .{ .array = nodes });

        var edges = std.json.Array.init(allocator);
        for (path.edges.items) |edge| {
            try edges.append(try protoEdgeToJson(allocator, edge));
        }
        try obj.put("edges", .{ .array = edges });
        return .{ .object = obj };
    }

    fn protoExtendedToJson(allocator: std.mem.Allocator, ext: schema.ExtendedValue) !std.json.Value {
        var obj = std.json.ObjectMap.init(allocator);
        if (ext.type_name.len > 0) {
            try obj.put("type", .{ .string = try allocator.dupe(u8, ext.type_name) });
        }
        if (ext.data) |data| {
            const val: std.json.Value = switch (data) {
                .text => |t| .{ .string = try allocator.dupe(u8, t) },
                .bytes => |b| .{ .string = try base64Encode(allocator, b) },
                .int_val => |n| .{ .integer = n },
                .double_val => |f| .{ .float = f },
                .bool_val => |b| .{ .bool = b },
            };
            try obj.put("value", val);
        }
        return .{ .object = obj };
    }

    fn protoValueToJson(allocator: std.mem.Allocator, value: schema.Value) anyerror!std.json.Value {
        const kind = value.kind orelse return std.json.Value.null;
        return switch (kind) {
            .null_val => std.json.Value.null,
            .int_val => |v| .{ .integer = v.value },
            .double_val => |v| .{ .float = v.value },
            .bool_val => |b| .{ .bool = b },
            .string_val => |v| .{ .string = try allocator.dupe(u8, v.value) },
            .decimal_val => |v| blk: {
                const repr = if (v.orig_repr.len > 0) v.orig_repr else v.coeff;
                break :blk .{ .string = try allocator.dupe(u8, repr) };
            },
            .bytes_val => |v| .{ .string = try base64Encode(allocator, v.value) },
            .list_val => |v| blk: {
                var arr = std.json.Array.init(allocator);
                for (v.values.items) |item| {
                    try arr.append(try protoValueToJson(allocator, item));
                }
                break :blk .{ .array = arr };
            },
            .map_val => |v| blk: {
                const obj = try protoMapEntriesToJson(allocator, v.entries.items);
                break :blk .{ .object = obj };
            },
            .node_val => |v| try protoNodeToJson(allocator, v),
            .edge_val => |v| try protoEdgeToJson(allocator, v),
            .path_val => |v| try protoPathToJson(allocator, v),
            .ext_val => |v| try protoExtendedToJson(allocator, v),
        };
    }

    fn ensureColumnInfoCount(allocator: std.mem.Allocator, columns: *std.ArrayList(ColumnInfo), value_count: usize) !void {
        while (columns.items.len < value_count) {
            const idx = columns.items.len + 1;
            const name = try std.fmt.allocPrint(allocator, "col_{d}", .{idx});
            const typ = try allocator.dupe(u8, "UNKNOWN");
            try columns.append(allocator, .{ .name = name, .type = typ });
        }
    }

    fn buildColumnsJsonArray(allocator: std.mem.Allocator, columns: []const ColumnInfo) !std.json.Array {
        var arr = std.json.Array.init(allocator);
        for (columns) |col| {
            var obj = std.json.ObjectMap.init(allocator);
            try obj.put("name", .{ .string = try allocator.dupe(u8, col.name) });
            try obj.put("type", .{ .string = try allocator.dupe(u8, col.type) });
            try arr.append(.{ .object = obj });
        }
        return arr;
    }

    fn rowToJsonObject(allocator: std.mem.Allocator, row: schema.Row, columns: []const ColumnInfo) !std.json.Value {
        var obj = std.json.ObjectMap.init(allocator);
        for (row.values.items, 0..) |val, idx| {
            const name = if (idx < columns.len)
                columns[idx].name
            else
                try std.fmt.allocPrint(allocator, "col_{d}", .{idx + 1});
            try obj.put(try allocator.dupe(u8, name), try protoValueToJson(allocator, val));
        }
        return .{ .object = obj };
    }

    fn buildRowsJsonArray(allocator: std.mem.Allocator, rows: []const schema.Row, columns: []const ColumnInfo) !std.json.Array {
        var arr = std.json.Array.init(allocator);
        if (rows.len == 0) return arr;

        // Use a higher threshold to avoid spice parallelMap memory corruption
        // on smaller result sets (see proto_util.zig buildDataPage fix)
        const parallel_threshold: usize = 512;
        if (spice_wrapper.shouldUseParallelism(rows.len, parallel_threshold)) {
            var pool = spice_wrapper.SpicePool.init(allocator, null);
            pool.start();
            defer pool.deinit();

            var ts_alloc = std.heap.ThreadSafeAllocator{ .child_allocator = allocator };
            const safe_alloc = ts_alloc.allocator();

            const RowInput = struct { row: *const schema.Row, allocator: std.mem.Allocator, columns: []const ColumnInfo };
            const RowResult = struct { value: std.json.Value, err: ?anyerror };

            const inputs = try allocator.alloc(RowInput, rows.len);
            defer allocator.free(inputs);
            for (rows, 0..) |*row, i| inputs[i] = .{ .row = row, .allocator = safe_alloc, .columns = columns };

            const mapFn = struct {
                fn map(_: *spice_wrapper.Task, input: RowInput) RowResult {
                    const value = rowToJsonObject(input.allocator, input.row.*, input.columns) catch |err| {
                        return .{ .value = std.json.Value.null, .err = err };
                    };
                    return .{ .value = value, .err = null };
                }
            }.map;

            const results = try spice_wrapper.parallelMap(RowInput, RowResult, &pool, inputs, mapFn, spice_wrapper.Thresholds.map);
            defer allocator.free(results);

            for (results) |r| {
                if (r.err) |err| return err;
                try arr.append(r.value);
            }
            return arr;
        }

        for (rows) |row| {
            try arr.append(try rowToJsonObject(allocator, row, columns));
        }
        return arr;
    }

    /// Execute a GQL query and return JSON output derived from protobuf responses.
    pub fn query(self: *Self, gql: []const u8, params: ?[]const u8) ![]u8 {
        try self.ensureConnected();

        const session_id = self.session_id orelse "";
        var param_list = try parseParamsJson(self.allocator, params);
        const McpProtocolAdapter = struct {
            client: *Self,

            fn sendClientMessage(
                proto: *query_runner.ProtocolClient,
                alloc: std.mem.Allocator,
                msg: schema.QuicClientMessage,
            ) !void {
                _ = alloc;
                const adapter_self: *@This() = @ptrCast(@alignCast(proto.context));
                try adapter_self.client.writeProtoMessage(msg);
            }

            fn readServerMessage(
                proto: *query_runner.ProtocolClient,
                alloc: std.mem.Allocator,
                timeout_secs: u32,
            ) !schema.QuicServerMessage {
                const adapter_self: *@This() = @ptrCast(@alignCast(proto.context));
                const timeout_ms = @as(u32, @intCast(@max(timeout_secs, 1) * 1000));
                while (true) {
                    var packet = adapter_self.client.readProtoMessage(alloc, timeout_ms) catch |err| switch (err) {
                        GeodeClientError.StreamError => return error.EndOfStream,
                        else => return err,
                    };
                    const msg = packet.quic orelse return GeodeClientError.InvalidResponse;
                    switch (msg) {
                        .execute, .pull, .hello => return msg,
                        .ping => {},
                        else => {},
                    }
                }
            }
        };

        var adapter = McpProtocolAdapter{ .client = self };
        var protocol_client = query_runner.ProtocolClient{
            .context = &adapter,
            .sendClientMessageFn = McpProtocolAdapter.sendClientMessage,
            .readServerMessageFn = McpProtocolAdapter.readServerMessage,
        };

        var result = try query_runner.collectQuery(self.allocator, &protocol_client, .{
            .session_id = session_id,
            .query_text = gql,
            .format = "json",
            .timeout_secs = 5,
            .page_size = query_runner.default_page_size,
            .params = param_list,
        });
        defer result.deinit();

        var out: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(self.allocator, 4096);
        defer out.deinit();
        _ = try result.render(out.writer, out.writer);
        return try self.allocator.dupe(u8, out.writer.buffer[0..out.writer.end]);
    }

    /// Get database schema information
    pub fn getSchema(self: *Self) ![]u8 {
        // Query to get node labels, relationship types, and properties
        const schema_query =
            \\MATCH (n)
            \\WITH DISTINCT labels(n) AS labels
            \\RETURN labels
            \\LIMIT 100
        ;

        return self.query(schema_query, null) catch |err| {
            // If query fails, return a minimal schema
            if (err == GeodeClientError.ConnectionFailed or err == GeodeClientError.NotConnected) {
                return try self.allocator.dupe(u8,
                    \\{"error": "Unable to connect to Geode server", "suggestion": "Ensure geode serve is running on the configured endpoint"}
                );
            }
            return err;
        };
    }

    /// Explain a GQL query plan
    pub fn explain(self: *Self, gql: []const u8) ![]u8 {
        const explain_query = try std.fmt.allocPrint(self.allocator, "EXPLAIN {s}", .{gql});
        defer self.allocator.free(explain_query);
        return self.query(explain_query, null);
    }

    /// List available catalogs
    pub fn listCatalogs(self: *Self) ![]u8 {
        // Use SHOW CATALOGS or equivalent query
        return self.query("SHOW CATALOGS", null) catch |err| {
            if (err == GeodeClientError.ConnectionFailed or err == GeodeClientError.NotConnected) {
                return try self.allocator.dupe(u8, "{\"catalogs\": [\"default\"], \"note\": \"Server unavailable, showing defaults\"}");
            }
            return err;
        };
    }

    /// List available graphs in a catalog
    pub fn listGraphs(self: *Self, catalog: ?[]const u8) ![]u8 {
        _ = catalog;
        // Use SHOW GRAPHS or equivalent query
        return self.query("SHOW GRAPHS", null) catch |err| {
            if (err == GeodeClientError.ConnectionFailed or err == GeodeClientError.NotConnected) {
                return try self.allocator.dupe(u8, "{\"graphs\": [\"default\"], \"note\": \"Server unavailable, showing defaults\"}");
            }
            return err;
        };
    }

    /// Get database statistics
    pub fn getStats(self: *Self) ![]u8 {
        const stats_query =
            \\MATCH (n)
            \\RETURN count(n) AS node_count
        ;
        return self.query(stats_query, null) catch |err| {
            if (err == GeodeClientError.ConnectionFailed or err == GeodeClientError.NotConnected) {
                return try self.allocator.dupe(u8, "{\"node_count\": 0, \"relationship_count\": 0, \"note\": \"Server unavailable\"}");
            }
            return err;
        };
    }

    /// Get server configuration
    pub fn getConfig(self: *Self) ![]u8 {
        // Return server info as JSON
        return try self.allocator.dupe(u8, std.fmt.comptimePrint(
            \\{{"version": "{s}", "gql_compliance": "ISO/IEC 39075:2024", "transport": "QUIC+TLS"}}
        , .{build_options.version}));
    }

    /// Check if client is currently connected
    pub fn isConnected(self: *Self) bool {
        return self.connected and self.handshake_done;
    }

    /// Reconnect to the server
    pub fn reconnect(self: *Self) !void {
        self.disconnect();
        try self.ensureConnected();
    }
};

const PARAM_MAX_SIZE: usize = 1 * 1024 * 1024;
const PARAM_MAX_DEPTH: usize = 64;

fn parseParamsJson(allocator: std.mem.Allocator, params_json: ?[]const u8) !std.ArrayList(schema.Param) {
    var params = std.ArrayList(schema.Param){};
    if (params_json == null) return params;

    const trimmed = std.mem.trim(u8, params_json.?, " \t\r\n");
    if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "null")) {
        return params;
    }
    if (trimmed.len > PARAM_MAX_SIZE) return error.ParamsTooLarge;

    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, trimmed, .{});
    defer parsed.deinit();

    if (parsed.value != .object) return error.InvalidParams;

    var it = parsed.value.object.iterator();
    while (it.next()) |entry| {
        const name = try allocator.dupe(u8, entry.key_ptr.*);
        const value = try jsonToProtoValue(allocator, entry.value_ptr.*, 0);
        try params.append(allocator, .{ .name = name, .value = value });
    }

    return params;
}

fn jsonToProtoValue(allocator: std.mem.Allocator, value: std.json.Value, depth: usize) !schema.Value {
    if (depth > PARAM_MAX_DEPTH) return error.ParamsTooDeep;
    return switch (value) {
        .null => .{ .kind = .{ .null_val = .{} } },
        .bool => |b| .{ .kind = .{ .bool_val = b } },
        .integer => |i| .{ .kind = .{ .int_val = .{ .value = i, .kind = .INT } } },
        .float => |f| .{ .kind = .{ .double_val = .{ .value = f, .kind = .DOUBLE } } },
        .number_string => |s| .{ .kind = .{ .string_val = .{ .value = try allocator.dupe(u8, s), .kind = .STRING } } },
        .string => |s| .{ .kind = .{ .string_val = .{ .value = try allocator.dupe(u8, s), .kind = .STRING } } },
        .array => |arr| blk: {
            var values = std.ArrayList(schema.Value).initCapacity(allocator, arr.items.len) catch return error.OutOfMemory;
            for (arr.items) |item| {
                try values.append(allocator, try jsonToProtoValue(allocator, item, depth + 1));
            }
            break :blk .{ .kind = .{ .list_val = .{ .values = values } } };
        },
        .object => |obj| blk: {
            var entries = std.ArrayList(schema.MapEntry).initCapacity(allocator, obj.count()) catch return error.OutOfMemory;
            var it = obj.iterator();
            while (it.next()) |entry| {
                const key = try allocator.dupe(u8, entry.key_ptr.*);
                const val = try jsonToProtoValue(allocator, entry.value_ptr.*, depth + 1);
                try entries.append(allocator, .{ .key = key, .value = val });
            }
            break :blk .{ .kind = .{ .map_val = .{ .entries = entries } } };
        },
    };
}

// escapeJsonString removed - JSON library handles escaping automatically

// =============================================================================
// Tests
// =============================================================================

test "GeodeClient initialization" {
    const allocator = std.testing.allocator;

    const client = try GeodeClient.init(allocator, "localhost:3141");
    defer client.deinit();

    try std.testing.expectEqualStrings("localhost", client.endpoint);
    try std.testing.expectEqual(@as(u16, 3141), client.port);
    try std.testing.expect(!client.connected);
}

test "GeodeClient endpoint parsing" {
    const allocator = std.testing.allocator;

    // Test with port
    const client1 = try GeodeClient.init(allocator, "127.0.0.1:8443");
    defer client1.deinit();
    try std.testing.expectEqualStrings("127.0.0.1", client1.endpoint);
    try std.testing.expectEqual(@as(u16, 8443), client1.port);

    // Test without port (default)
    const client2 = try GeodeClient.init(allocator, "geode.local");
    defer client2.deinit();
    try std.testing.expectEqualStrings("geode.local", client2.endpoint);
    try std.testing.expectEqual(@as(u16, 3141), client2.port);
}

test "JSON library handles escaping" {
    const allocator = std.testing.allocator;

    // Verify JSON library properly escapes special characters
    const TestMessage = struct { text: []const u8 };
    const message = TestMessage{ .text = "say \"hello\"\nworld" };
    const result = try std.json.Stringify.valueAlloc(allocator, message, .{});
    defer allocator.free(result);

    // Should contain escaped quotes and newline
    try std.testing.expect(std.mem.indexOf(u8, result, "\\\"hello\\\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\\n") != null);
}

test "GeodeClient endpoint parsing with IPv6" {
    const allocator = std.testing.allocator;

    // IPv6 address without port (uses default)
    const client = try GeodeClient.init(allocator, "::1");
    defer client.deinit();
    try std.testing.expectEqualStrings("::1", client.endpoint);
    try std.testing.expectEqual(@as(u16, 3141), client.port);
}

test "GeodeClient isConnected initially false" {
    const allocator = std.testing.allocator;

    const client = try GeodeClient.init(allocator, "localhost:3141");
    defer client.deinit();

    try std.testing.expect(!client.isConnected());
}

test "GeodeClient getConfig returns valid JSON" {
    const allocator = std.testing.allocator;

    const client = try GeodeClient.init(allocator, "localhost:3141");
    defer client.deinit();

    const config = try client.getConfig();
    defer allocator.free(config);

    // Verify it contains expected fields
    try std.testing.expect(std.mem.indexOf(u8, config, "version") != null);
    try std.testing.expect(std.mem.indexOf(u8, config, "gql_compliance") != null);
    try std.testing.expect(std.mem.indexOf(u8, config, "QUIC+TLS") != null);
}

test "JSON library unicode passthrough" {
    const allocator = std.testing.allocator;

    // Verify JSON library handles unicode correctly
    const TestMessage = struct { text: []const u8 };
    const message = TestMessage{ .text = "Hello 世界 🌍" };
    const result = try std.json.Stringify.valueAlloc(allocator, message, .{});
    defer allocator.free(result);

    // Unicode should be present in output
    try std.testing.expect(std.mem.indexOf(u8, result, "Hello 世界 🌍") != null);
}
