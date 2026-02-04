const std = @import("std");

// CANARY: REQ=REQ-LIB-MIGRATION-MCP-008; FEATURE="External Library Migration"; ASPECT=MCPClient; STATUS=EXEMPT; OWNER=core; UPDATED=2026-01-24
// GeodeClient - QUIC connection management for MCP server integration

const protobuf = @import("protobuf");
const schema = @import("schema");
const spice_wrapper = @import("parallel/spice");

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

        // Connect with insecure mode for local development (TODO: support TLS config)
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
            .client_version = "0.19.0",
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

        if (spice_wrapper.shouldUseParallelism(rows.len, spice_wrapper.Thresholds.map)) {
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
        defer {
            for (param_list.items) |*param| {
                param.deinit(self.allocator);
            }
            param_list.deinit(self.allocator);
        }

        const exec_req = schema.ExecuteRequest{
            .session_id = session_id,
            .query = gql,
            .params = param_list,
        };
        try self.writeProtoMessage(.{ .execute = exec_req });

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        const ResultKind = enum { none, rows, explain, profile, metrics, heartbeat };

        var columns_info = std.ArrayList(ColumnInfo).initCapacity(a, 0) catch return error.OutOfMemory;
        var rows = std.json.Array.init(a);
        var ordered = false;
        var order_keys = std.json.Array.init(a);
        var additional_statuses = std.json.Array.init(a);
        var flagger_findings = std.json.Array.init(a);

        var status_class: []const u8 = "00000";
        var status_subclass: ?[]const u8 = null;
        var error_code: ?[]const u8 = null;
        var error_message: ?[]const u8 = null;
        var result_kind: ResultKind = .none;
        var explain_value: ?std.json.Value = null;
        var profile_value: ?std.json.Value = null;
        var metrics_value: ?std.json.Value = null;

        var schema_received = false;
        while (!schema_received and error_code == null) {
            var packet = try self.readProtoMessage(self.allocator, 5000);
            defer packet.deinit(self.allocator);
            const msg = packet.quic orelse return GeodeClientError.InvalidResponse;
            if (msg != .execute) return GeodeClientError.InvalidResponse;

            const exec_resp = msg.execute;
            if (exec_resp.status) |status| {
                if (status.status_class.len > 0) {
                    status_class = try a.dupe(u8, status.status_class);
                }
                if (status.status_subclass.len > 0) {
                    status_subclass = try a.dupe(u8, status.status_subclass);
                }
                for (status.additional_statuses.items) |item| {
                    try additional_statuses.append(.{ .string = try a.dupe(u8, item) });
                }
                for (status.flagger_findings.items) |item| {
                    try flagger_findings.append(.{ .string = try a.dupe(u8, item) });
                }
            }

            if (exec_resp.payload) |payload| switch (payload) {
                .schema => |schema_def| {
                    for (schema_def.columns.items) |col| {
                        try columns_info.append(a, .{
                            .name = try a.dupe(u8, col.name),
                            .type = try a.dupe(u8, col.type),
                        });
                    }
                    result_kind = .rows;
                    schema_received = true;
                },
                .page => |p| {
                    if (columns_info.items.len == 0) return GeodeClientError.InvalidResponse;
                    ordered = ordered or p.ordered;
                    if (p.order_keys.items.len > 0 and order_keys.items.len == 0) {
                        for (p.order_keys.items) |k| try order_keys.append(.{ .string = try a.dupe(u8, k) });
                    }
                    var max_vals: usize = columns_info.items.len;
                    for (p.rows.items) |row| {
                        max_vals = @max(max_vals, row.values.items.len);
                    }
                    try ensureColumnInfoCount(a, &columns_info, max_vals);
                    const page_rows = try buildRowsJsonArray(a, p.rows.items, columns_info.items);
                    for (page_rows.items) |row_val| {
                        try rows.append(row_val);
                    }
                    result_kind = .rows;
                    schema_received = true;
                },
                .@"error" => |e| {
                    error_code = try a.dupe(u8, e.code);
                    error_message = try a.dupe(u8, e.message);
                },
                .explain => |expl| {
                    if (std.json.parseFromSlice(std.json.Value, a, expl.json_payload, .{})) |parsed| {
                        explain_value = parsed.value;
                    } else |_| {
                        explain_value = .{ .string = try a.dupe(u8, expl.json_payload) };
                    }
                    result_kind = .explain;
                    schema_received = true;
                },
                .profile => |profile| {
                    if (std.json.parseFromSlice(std.json.Value, a, profile.json_payload, .{})) |parsed| {
                        profile_value = parsed.value;
                    } else |_| {
                        profile_value = .{ .string = try a.dupe(u8, profile.json_payload) };
                    }
                    result_kind = .profile;
                    schema_received = true;
                },
                .metrics => |metrics| {
                    var metrics_obj = std.json.ObjectMap.init(a);
                    try metrics_obj.put("parse_ns", .{ .integer = metrics.parse_duration_ns });
                    try metrics_obj.put("plan_ns", .{ .integer = metrics.plan_duration_ns });
                    try metrics_obj.put("execute_ns", .{ .integer = metrics.execute_duration_ns });
                    try metrics_obj.put("total_ns", .{ .integer = metrics.total_duration_ns });
                    metrics_value = .{ .object = metrics_obj };
                    result_kind = .metrics;
                    schema_received = true;
                },
                .heartbeat => |_| {
                    result_kind = .heartbeat;
                    schema_received = true;
                },
            };
        }

        if (error_code == null and result_kind == .rows) {
            var done = false;
            var request_id: u64 = 1;
            while (!done) : (request_id += 1) {
                const pull_req = schema.PullRequest{ .request_id = request_id, .page_size = 0, .session_id = session_id };
                try self.writeProtoMessage(.{ .pull = pull_req });

                var packet = try self.readProtoMessage(self.allocator, 5000);
                defer packet.deinit(self.allocator);

                const msg = packet.quic orelse return GeodeClientError.InvalidResponse;
                const exec_resp = switch (msg) {
                    .pull => |p| p.response orelse return GeodeClientError.InvalidResponse,
                    .execute => |e| e,
                    else => return GeodeClientError.InvalidResponse,
                };

                if (exec_resp.status) |status| {
                    if (status.status_class.len > 0) {
                        status_class = try a.dupe(u8, status.status_class);
                    }
                    if (status.status_subclass.len > 0) {
                        status_subclass = try a.dupe(u8, status.status_subclass);
                    }
                    for (status.additional_statuses.items) |item| {
                        try additional_statuses.append(.{ .string = try a.dupe(u8, item) });
                    }
                    for (status.flagger_findings.items) |item| {
                        try flagger_findings.append(.{ .string = try a.dupe(u8, item) });
                    }
                }

                if (exec_resp.payload) |payload| switch (payload) {
                    .page => |p| {
                        ordered = ordered or p.ordered;
                        if (p.order_keys.items.len > 0 and order_keys.items.len == 0) {
                            for (p.order_keys.items) |k| try order_keys.append(.{ .string = try a.dupe(u8, k) });
                        }
                        var max_vals: usize = columns_info.items.len;
                        for (p.rows.items) |row| {
                            max_vals = @max(max_vals, row.values.items.len);
                        }
                        try ensureColumnInfoCount(a, &columns_info, max_vals);
                        const page_rows = try buildRowsJsonArray(a, p.rows.items, columns_info.items);
                        for (page_rows.items) |row_val| {
                            try rows.append(row_val);
                        }
                        if (p.final) done = true;
                    },
                    .@"error" => |e| {
                        error_code = try a.dupe(u8, e.code);
                        error_message = try a.dupe(u8, e.message);
                        done = true;
                    },
                    else => {},
                };
            }
        }

        if (error_code) |code| {
            const msg = error_message orelse "error";
            var err_obj = std.json.ObjectMap.init(a);
            try err_obj.put("status_class", .{ .string = try a.dupe(u8, status_class) });
            if (status_subclass) |sub| {
                try err_obj.put("status_subclass", .{ .string = try a.dupe(u8, sub) });
            }
            try err_obj.put("error", .{ .string = try a.dupe(u8, msg) });
            try err_obj.put("error_code", .{ .string = try a.dupe(u8, code) });
            try err_obj.put("additional_statuses", .{ .array = additional_statuses });
            try err_obj.put("flagger_findings", .{ .array = flagger_findings });
            const err_val = std.json.Value{ .object = err_obj };
            return try std.json.Stringify.valueAlloc(self.allocator, err_val, .{});
        }

        var root_obj = std.json.ObjectMap.init(a);
        try root_obj.put("status_class", .{ .string = status_class });
        if (status_subclass) |sub| {
            try root_obj.put("status_subclass", .{ .string = try a.dupe(u8, sub) });
        }
        try root_obj.put("additional_statuses", .{ .array = additional_statuses });
        try root_obj.put("flagger_findings", .{ .array = flagger_findings });

        switch (result_kind) {
            .explain => if (explain_value) |val| try root_obj.put("explain", val),
            .profile => if (profile_value) |val| try root_obj.put("profile", val),
            .metrics => if (metrics_value) |val| try root_obj.put("metrics", val),
            .heartbeat => try root_obj.put("heartbeat", .{ .bool = true }),
            .rows, .none => {
                const cols_array = try buildColumnsJsonArray(a, columns_info.items);
                try root_obj.put("columns", .{ .array = cols_array });
                try root_obj.put("rows", .{ .array = rows });
                try root_obj.put("ordered", .{ .bool = ordered });
                try root_obj.put("order_keys", .{ .array = order_keys });
            },
        }

        const root_val = std.json.Value{ .object = root_obj };
        return try std.json.Stringify.valueAlloc(self.allocator, root_val, .{});
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
        return try self.allocator.dupe(u8,
            \\{"version": "0.19.0", "gql_compliance": "ISO/IEC 39075:2024", "transport": "QUIC+TLS"}
        );
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
