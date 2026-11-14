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

/// SONNY-6494: what is wrong with an endpoint DSN, in words a user can act
/// on; null when `err` is not about the DSN. SONNY-6531: the one mapping is
/// `zig_quic_bridge.endpointErrorMessage`, shared with the CLI's `--server`
/// and `--dsn`. An IPv6 zone parses but cannot be dialled (`parseEndpoint`).
/// The DSN itself is not part of the message: it may carry a password.
pub const endpointErrorMessage = geode.zig_quic_bridge.endpointErrorMessage;

/// `endpointErrorMessage`, or `fallback` for any other error.
pub fn initErrorMessage(err: anyerror, fallback: []const u8) []const u8 {
    return endpointErrorMessage(err) orelse fallback;
}

/// Parse `endpoint` as geode-client-zig does (since v0.3.17 it refuses
/// port 0 itself, SONNY-6550), name a fragment (`error.DsnFragment`), and
/// refuse an IPv6 zone, which parses but cannot be dialled
/// (`error.Ipv6ZoneUnsupported`). The returned config's host slices
/// `endpoint`.
fn parseEndpoint(allocator: std.mem.Allocator, endpoint: []const u8) !zig_client.config.Config {
    var cfg = zig_client.config.parseDSN(allocator, endpoint) catch |err|
        return geode.zig_quic_bridge.dsnError(err, endpoint);
    errdefer cfg.deinit(allocator);
    if (geode.zig_quic_bridge.isZonedIpv6(cfg.host)) return error.Ipv6ZoneUnsupported;
    try preferUserinfoCredentials(allocator, &cfg, endpoint);
    return cfg;
}

/// SONNY-6550: docs/DSN.md (and the CLI's `--dsn`, SONNY-6551) give a
/// userinfo credential precedence over a `user=` / `pass=` query parameter,
/// per field, with an empty userinfo user name counting as absent.
/// geode-client-zig's `parseDSN` (v0.3.17) lets the query parameter
/// overwrite the userinfo, so put the userinfo's values back.
fn preferUserinfoCredentials(allocator: std.mem.Allocator, cfg: *zig_client.config.Config, endpoint: []const u8) !void {
    const redact = zig_client.config.redact;
    const start = if (redact.schemeEnd(endpoint)) |sep| sep + 3 else 0;
    const authority = try redact.splitAuthority(endpoint[start..]);
    const userinfo = authority.userinfo orelse return;
    const creds = try redact.decodeUserinfo(allocator, userinfo);
    if (creds.username.len > 0) {
        replaceSecret(allocator, &cfg.username, creds.username);
    } else {
        allocator.free(creds.username);
    }
    if (creds.password) |p| replaceSecret(allocator, &cfg.password, p);
}

/// Zero and free the secret in `field`, then store `value` (owned).
fn replaceSecret(allocator: std.mem.Allocator, field: *?[]const u8, value: []u8) void {
    if (field.*) |old| {
        std.crypto.secureZero(u8, @constCast(old));
        allocator.free(old);
    }
    field.* = value;
}

/// SONNY-6494: check an endpoint DSN without building a client (`geode mcp`
/// startup). The error maps through `endpointErrorMessage`.
pub fn checkEndpoint(allocator: std.mem.Allocator, endpoint: []const u8) !void {
    var cfg = try parseEndpoint(allocator, endpoint);
    cfg.deinit(allocator);
}

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

        // SONNY-6484/6494: an IPv6 host must be bracketed and a port is
        // 1-65535; geode-client-zig v0.3.16 refuses the rest of the grammar
        // itself (InvalidDSN, InvalidPort), so geode's own pre-check is gone.
        var cfg = try parseEndpoint(allocator, endpoint_storage);
        errdefer cfg.deinit(allocator);

        // S-5: Warn if DSN contains embedded credentials to discourage credential leakage via logs.
        if (cfg.username != null or cfg.password != null) {
            std.log.warn("MCP endpoint contains embedded credentials. Prefer explicit credential passing for production.", .{});
        }

        // SONNY-6453: a DSN `insecure=true` (insecure_tls_skip_verify,
        // skip_verify) follows the CLI's --insecure-tls-skip-verify rule:
        // refused under production posture (release build or
        // GEODE_ENV=production) unless GEODE_ALLOW_INSECURE_TLS=1, and loud
        // otherwise. stdout is the MCP channel, so both go to the log (stderr).
        if (cfg.insecure) {
            if (geode.zig_quic_bridge.liveInsecurePosture() == .refuse) {
                std.log.warn("MCP endpoint DSN sets insecure=true: refusing to disable TLS certificate verification under production conditions (release build or GEODE_ENV=production). Give the DSN a ca= bundle, or set GEODE_ALLOW_INSECURE_TLS=1 to explicitly accept the risk.", .{});
                return error.InsecureTlsRefused;
            }
            std.log.warn("MCP endpoint DSN sets insecure=true: the server's TLS certificate is NOT verified; this connection is exposed to man-in-the-middle attacks. NOT FOR PRODUCTION.", .{});
        }

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

        var col_obj = @as(std.json.ObjectMap, .empty);
        try col_obj.put(allocator, "name", .{ .string = owned_name });
        try col_obj.put(allocator, "type", .{ .string = owned_type });
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
            var obj = @as(std.json.ObjectMap, .empty);
            try obj.put(allocator, "code", .{ .string = try allocator.dupe(u8, err_info.code) });
            try obj.put(allocator, "message", .{ .string = try allocator.dupe(u8, err_info.message) });
            try obj.put(allocator, "type", .{ .string = try allocator.dupe(u8, err_info.error_type) });
            if (err_info.anchor.len > 0) {
                try obj.put(allocator, "anchor", .{ .string = try allocator.dupe(u8, err_info.anchor) });
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
                var row_obj = @as(std.json.ObjectMap, .empty);
                for (row.values.items, 0..) |value, idx| {
                    if (idx >= column_names.items.len) {
                        const fallback = try std.fmt.allocPrint(allocator, "col_{d}", .{idx + 1});
                        try appendColumnInfo(allocator, column_names, columns_json, fallback, "UNKNOWN");
                    }
                    try row_obj.put(allocator, column_names.items[idx], try protoValueToJson(allocator, value));
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
        var column_names = std.ArrayList([]const u8).empty;
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

        var result_obj = @as(std.json.ObjectMap, .empty);
        try result_obj.put(arena_allocator, "columns", .{ .array = columns_json });
        try result_obj.put(arena_allocator, "rows", .{ .array = rows_json });
        if (error_obj) |obj| {
            try result_obj.put(arena_allocator, "error", .{ .object = obj });
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
    // SONNY-6484: docs/DSN.md requires brackets around an IPv6 host. A bare
    // `::1` is refused (it used to become host `:` port 1, silently); since
    // geode-client-zig v0.3.16 by the library's parser, as InvalidDSN.
    const allocator = std.testing.allocator;

    const client = try GeodeClient.init(allocator, "[::1]");
    defer client.deinit();
    try std.testing.expectEqualStrings("::1", client.endpoint);
    try std.testing.expectEqual(@as(u16, 3141), client.port);

    const with_port = try GeodeClient.init(allocator, "quic://[2001:db8::1]:8443/g");
    defer with_port.deinit();
    try std.testing.expectEqualStrings("2001:db8::1", with_port.endpoint);
    try std.testing.expectEqual(@as(u16, 8443), with_port.port);

    for ([_][]const u8{ "::1", "::1:3141", "quic://2001:db8::1" }) |bare| {
        try std.testing.expectError(error.InvalidDSN, GeodeClient.init(allocator, bare));
    }
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
