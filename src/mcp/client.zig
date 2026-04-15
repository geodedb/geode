const std = @import("std");
const build_options = @import("build_options");

// CANARY: REQ=REQ-LIB-MIGRATION-MCP-008; FEATURE="External Library Migration"; ASPECT=MCPClient; STATUS=IMPL; OWNER=core; UPDATED=2026-04-14
// GeodeClient now delegates transport/session handling to the sibling
// geode-client-zig package instead of owning a second client stack here.

const geode = @import("geode");
const zig_client = geode.zig_client;

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
    InvalidParams,
    UnsupportedParamType,
};

pub const GeodeClient = struct {
    allocator: std.mem.Allocator,
    endpoint_storage: []u8,
    endpoint: []const u8,
    port: u16,
    cfg: zig_client.config.Config,
    client: zig_client.GeodeClient,
    connected: bool,

    const Self = @This();

    pub fn init(allocator: std.mem.Allocator, endpoint: []const u8) !*Self {
        const self = try allocator.create(Self);
        errdefer allocator.destroy(self);

        const endpoint_storage = try allocator.dupe(u8, endpoint);
        errdefer allocator.free(endpoint_storage);

        var cfg = try zig_client.config.parseDSN(allocator, endpoint_storage);
        errdefer cfg.deinit(allocator);

        const client = try zig_client.GeodeClient.initFromConfig(allocator, cfg);

        self.* = .{
            .allocator = allocator,
            .endpoint_storage = endpoint_storage,
            .endpoint = cfg.host,
            .port = cfg.port,
            .cfg = cfg,
            .client = client,
            .connected = false,
        };
        return self;
    }

    pub fn deinit(self: *Self) void {
        self.client.deinit();
        self.cfg.deinit(self.allocator);
        self.allocator.free(self.endpoint_storage);
        self.allocator.destroy(self);
    }

    fn resetClient(self: *Self) !void {
        self.client.deinit();
        self.client = try zig_client.GeodeClient.initFromConfig(self.allocator, self.cfg);
        self.connected = false;
    }

    fn mapTransportError(err: anyerror) GeodeClientError {
        return switch (err) {
            error.AuthenticationFailed => GeodeClientError.HandshakeFailed,
            error.InvalidResponse, error.InvalidMessage => GeodeClientError.InvalidResponse,
            error.NotConnected, error.NoStream => GeodeClientError.NotConnected,
            error.ReceiveTimeout, error.ConnectionTimeout => GeodeClientError.Timeout,
            error.WriteError => GeodeClientError.StreamError,
            error.OutOfMemory => GeodeClientError.OutOfMemory,
            else => GeodeClientError.ConnectionFailed,
        };
    }

    fn ensureConnected(self: *Self) !void {
        if (self.connected) return;

        self.client.connect() catch |err| {
            self.resetClient() catch {};
            return mapTransportError(err);
        };
        self.client.sendHello() catch |err| {
            self.resetClient() catch {};
            return mapTransportError(err);
        };

        self.connected = true;
    }

    fn protoValueToJson(allocator: std.mem.Allocator, value: zig_client.proto.Value) !std.json.Value {
        if (value.null_val) return std.json.Value.null;
        if (value.int_val) |v| return .{ .integer = v };
        if (value.double_val) |v| return .{ .float = v };
        if (value.bool_val) |v| return .{ .bool = v };
        if (value.string_val) |v| return .{ .string = try allocator.dupe(u8, v) };
        return std.json.Value.null;
    }

    fn jsonToProtoValue(allocator: std.mem.Allocator, value: std.json.Value) !zig_client.proto.Value {
        return switch (value) {
            .null => zig_client.proto.Value.initNull(),
            .bool => |v| zig_client.proto.Value.initBool(v),
            .integer => |v| zig_client.proto.Value.initInt(v),
            .float => |v| zig_client.proto.Value.initDouble(v),
            .number_string => |v| zig_client.proto.Value.initString(try allocator.dupe(u8, v)),
            .string => |v| zig_client.proto.Value.initString(try allocator.dupe(u8, v)),
            .array, .object => GeodeClientError.UnsupportedParamType,
        };
    }

    fn deinitOwnedExecuteRequest(allocator: std.mem.Allocator, execute: *zig_client.proto.ExecuteRequest) void {
        for (execute.params.items) |*param| {
            if (param.name.len > 0) allocator.free(param.name);
            var value = param.value;
            value.deinit(allocator);
        }
        execute.params.deinit(allocator);
    }

    fn appendParamsJson(self: *Self, execute: *zig_client.proto.ExecuteRequest, params_json: ?[]const u8) !void {
        if (params_json == null) return;

        const trimmed = std.mem.trim(u8, params_json.?, " \t\r\n");
        if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "null")) return;

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, trimmed, .{}) catch {
            return GeodeClientError.InvalidParams;
        };
        defer parsed.deinit();

        if (parsed.value != .object) return GeodeClientError.InvalidParams;

        var it = parsed.value.object.iterator();
        while (it.next()) |entry| {
            const name = try self.allocator.dupe(u8, entry.key_ptr.*);
            errdefer self.allocator.free(name);

            const value = try jsonToProtoValue(self.allocator, entry.value_ptr.*);
            errdefer {
                var owned_value = value;
                owned_value.deinit(self.allocator);
            }

            try execute.addParam(self.allocator, name, value);
        }
    }

    fn appendColumnInfo(
        allocator: std.mem.Allocator,
        column_names: *std.ArrayList([]const u8),
        columns_json: *std.json.Array,
        name: []const u8,
        col_type: []const u8,
    ) !void {
        const owned_name = try allocator.dupe(u8, name);
        const owned_type = try allocator.dupe(u8, col_type);

        try column_names.append(allocator, owned_name);

        var col_obj = std.json.ObjectMap.init(allocator);
        try col_obj.put("name", .{ .string = owned_name });
        try col_obj.put("type", .{ .string = owned_type });
        try columns_json.append(.{ .object = col_obj });
    }

    fn appendExecutionResponse(
        allocator: std.mem.Allocator,
        exec: zig_client.proto.ExecutionResponse,
        column_names: *std.ArrayList([]const u8),
        columns_json: *std.json.Array,
        rows_json: *std.json.Array,
        error_obj: *?std.json.ObjectMap,
    ) !bool {
        if (exec.err) |err_info| {
            var obj = std.json.ObjectMap.init(allocator);
            try obj.put("code", .{ .string = try allocator.dupe(u8, err_info.code) });
            try obj.put("message", .{ .string = try allocator.dupe(u8, err_info.message) });
            try obj.put("type", .{ .string = try allocator.dupe(u8, err_info.error_type) });
            if (err_info.anchor.len > 0) {
                try obj.put("anchor", .{ .string = try allocator.dupe(u8, err_info.anchor) });
            }
            error_obj.* = obj;
            return false;
        }

        if (exec.schema) |schema| {
            for (schema.columns.items) |col| {
                try appendColumnInfo(allocator, column_names, columns_json, col.name, col.col_type);
            }
        }

        if (exec.page) |page| {
            for (page.rows.items) |row| {
                var row_obj = std.json.ObjectMap.init(allocator);
                for (row.values.items, 0..) |value, idx| {
                    if (idx >= column_names.items.len) {
                        const fallback = try std.fmt.allocPrint(allocator, "col_{d}", .{idx + 1});
                        try appendColumnInfo(allocator, column_names, columns_json, fallback, "UNKNOWN");
                    }
                    try row_obj.put(column_names.items[idx], try protoValueToJson(allocator, value));
                }
                try rows_json.append(.{ .object = row_obj });
            }
            return !page.final;
        }

        return exec.schema != null;
    }

    fn collectQueryJson(self: *Self) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();

        const arena_allocator = arena.allocator();
        var column_names = std.ArrayList([]const u8){};
        var columns_json = std.json.Array.init(arena_allocator);
        var rows_json = std.json.Array.init(arena_allocator);
        var error_obj: ?std.json.ObjectMap = null;
        var timeout_ms: u64 = 30_000;

        while (true) {
            var response = self.client.receiveProto(timeout_ms) catch |err| {
                self.resetClient() catch {};
                return mapTransportError(err);
            };
            defer response.deinit(self.allocator);

            const expect_more = if (response.execute) |exec|
                try appendExecutionResponse(
                    arena_allocator,
                    exec,
                    &column_names,
                    &columns_json,
                    &rows_json,
                    &error_obj,
                )
            else if (response.pull) |pull|
                if (pull.response) |exec|
                    try appendExecutionResponse(
                        arena_allocator,
                        exec,
                        &column_names,
                        &columns_json,
                        &rows_json,
                        &error_obj,
                    )
                else
                    false
            else
                return GeodeClientError.InvalidResponse;

            if (!expect_more) break;
            timeout_ms = 5_000;
        }

        var result_obj = std.json.ObjectMap.init(arena_allocator);
        try result_obj.put("columns", .{ .array = columns_json });
        try result_obj.put("rows", .{ .array = rows_json });
        if (error_obj) |obj| {
            try result_obj.put("error", .{ .object = obj });
        }

        const encoded = try std.json.Stringify.valueAlloc(arena_allocator, std.json.Value{ .object = result_obj }, .{});
        return try self.allocator.dupe(u8, encoded);
    }

    pub fn query(self: *Self, gql: []const u8, params: ?[]const u8) ![]u8 {
        try self.ensureConnected();

        var execute = zig_client.proto.ExecuteRequest{
            .session_id = self.client.session_id,
            .query = gql,
            .request_id = try self.client.generateRequestId(),
        };
        defer deinitOwnedExecuteRequest(self.allocator, &execute);

        try self.appendParamsJson(&execute, params);

        self.client.sendProto(.{ .execute = execute }) catch |err| {
            self.resetClient() catch {};
            return mapTransportError(err);
        };

        return try self.collectQueryJson();
    }

    pub fn getSchema(self: *Self) ![]u8 {
        const schema_query =
            \\MATCH (n)
            \\WITH DISTINCT labels(n) AS labels
            \\RETURN labels
            \\LIMIT 100
        ;
        return self.query(schema_query, null);
    }

    pub fn explain(self: *Self, gql: []const u8) ![]u8 {
        const explain_query = try std.fmt.allocPrint(self.allocator, "EXPLAIN {s}", .{gql});
        defer self.allocator.free(explain_query);
        return self.query(explain_query, null);
    }

    pub fn listCatalogs(self: *Self) ![]u8 {
        return self.query("SHOW CATALOGS", null);
    }

    pub fn listGraphs(self: *Self, catalog: ?[]const u8) ![]u8 {
        _ = catalog;
        return self.query("SHOW GRAPHS", null);
    }

    pub fn getStats(self: *Self) ![]u8 {
        return self.query("MATCH (n) RETURN count(n) AS node_count", null);
    }

    pub fn getConfig(self: *Self) ![]u8 {
        return try std.fmt.allocPrint(
            self.allocator,
            \\{{"version":"{s}","gql_compliance":"ISO/IEC 39075:2024","transport":"{s}"}}
        ,
            .{ build_options.version, self.cfg.transport.toString() },
        );
    }

    pub fn isConnected(self: *Self) bool {
        return self.connected;
    }

    pub fn reconnect(self: *Self) !void {
        try self.resetClient();
        try self.ensureConnected();
    }
};

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

    const client1 = try GeodeClient.init(allocator, "127.0.0.1:8443");
    defer client1.deinit();
    try std.testing.expectEqualStrings("127.0.0.1", client1.endpoint);
    try std.testing.expectEqual(@as(u16, 8443), client1.port);

    const client2 = try GeodeClient.init(allocator, "geode.local");
    defer client2.deinit();
    try std.testing.expectEqualStrings("geode.local", client2.endpoint);
    try std.testing.expectEqual(@as(u16, 3141), client2.port);
}

test "GeodeClient endpoint parsing with IPv6" {
    const allocator = std.testing.allocator;

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

    try std.testing.expect(std.mem.indexOf(u8, config, "version") != null);
    try std.testing.expect(std.mem.indexOf(u8, config, "gql_compliance") != null);
    try std.testing.expect(std.mem.indexOf(u8, config, "transport") != null);
}
