const std = @import("std");
const build_options = @import("build_options");

// CANARY: REQ=REQ-LIB-MIGRATION-MCP-008; FEATURE="External Library Migration"; ASPECT=MCPClient; STATUS=IMPL; OWNER=core; UPDATED=2026-04-14
// GeodeClient now delegates transport/session handling to the sibling
// geode-client-zig package instead of owning a second client stack here.

const geode = @import("geode");
const zig_client = geode.zig_client;
const schema = @import("schema");
const protobuf = @import("protobuf");
const query_runner = geode.query_runner;
const query_results = geode.query_result_accumulator;

/// The node label sets of the session's graph (the schema tool and resource).
pub const schema_labels_query =
    \\MATCH (n)
    \\WITH DISTINCT labels(n) AS labels
    \\RETURN labels
    \\LIMIT 100
;

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

    fn jsonToProtoValue(allocator: std.mem.Allocator, value: std.json.Value) !schema.Value {
        return switch (value) {
            .null => .{ .kind = .{ .null_val = .{} } },
            .bool => |b| .{ .kind = .{ .bool_val = b } },
            .integer => |i| .{ .kind = .{ .int_val = .{ .value = i, .kind = .INT } } },
            .float => |f| .{ .kind = .{ .double_val = .{ .value = f, .kind = .DOUBLE } } },
            .number_string => |v| .{ .kind = .{ .string_val = .{ .value = try allocator.dupe(u8, v), .kind = .STRING } } },
            .string => |v| .{ .kind = .{ .string_val = .{ .value = try allocator.dupe(u8, v), .kind = .STRING } } },
            .array, .object => GeodeClientError.UnsupportedParamType,
        };
    }

    fn parseParamsJson(self: *Self, params_json: ?[]const u8) !std.ArrayList(schema.Param) {
        var params: std.ArrayList(schema.Param) = .empty;
        errdefer {
            for (params.items) |*param| param.deinit(self.allocator);
            params.deinit(self.allocator);
        }
        const text = params_json orelse return params;
        const trimmed = std.mem.trim(u8, text, " \t\r\n");
        if (trimmed.len == 0 or std.mem.eql(u8, trimmed, "null")) return params;

        const parsed = std.json.parseFromSlice(std.json.Value, self.allocator, trimmed, .{}) catch {
            return GeodeClientError.InvalidParams;
        };
        defer parsed.deinit();
        if (parsed.value != .object) return GeodeClientError.InvalidParams;

        var it = parsed.value.object.iterator();
        while (it.next()) |entry| {
            const name = try self.allocator.dupe(u8, entry.key_ptr.*);
            errdefer self.allocator.free(name);
            var value = try jsonToProtoValue(self.allocator, entry.value_ptr.*);
            errdefer value.deinit(self.allocator);
            try params.append(self.allocator, .{ .name = name, .value = value });
        }
        return params;
    }

    // CANARY: REQ=REQ-SONNY-6559-MCP-WIRE-DECODE; FEATURE="MCPBackendTools"; ASPECT=FullResultDecode; STATUS=TESTED; TEST=tests/test_sonny6559_mcp_backend.zig; OWNER=mcp; UPDATED=2026-11-14
    // SONNY-6559 (5, 10): the query is run and its answer decoded as `geode
    // query` does (geode's own wire schema through query_runner, over the
    // client library's framed stream). The client library's decoder keeps a
    // value's scalars only and drops the EXPLAIN/PROFILE payload, so a node,
    // a list (the schema tool's labels) and every plan came back as null or
    // as {"columns":[],"rows":[]}.
    const ProtocolAdapter = struct {
        client: *zig_client.GeodeClient,

        fn send(proto: *query_runner.ProtocolClient, allocator: std.mem.Allocator, msg: schema.QuicClientMessage) !void {
            const self: *@This() = @ptrCast(@alignCast(proto.context));
            var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(allocator, 4096);
            defer aw.deinit();
            try protobuf.encode(&aw.writer, allocator, schema.ClientPacket{ .quic = msg });
            const body = aw.writer.buffer[0..aw.writer.end];
            const framed = try allocator.alloc(u8, body.len + 4);
            defer allocator.free(framed);
            std.mem.writeInt(u32, framed[0..4], @intCast(body.len), .big);
            @memcpy(framed[4..], body);
            try self.client.sendRawFramed(framed);
        }

        fn read(proto: *query_runner.ProtocolClient, allocator: std.mem.Allocator, timeout_secs: u32) !schema.QuicServerMessage {
            const self: *@This() = @ptrCast(@alignCast(proto.context));
            const body = self.client.receiveRawFrame(allocator, @as(u64, timeout_secs) * std.time.ms_per_s) catch |err| switch (err) {
                error.ReceiveTimeout => return error.Timeout,
                else => return err,
            };
            defer allocator.free(body);
            var reader: std.Io.Reader = .fixed(body);
            const packet = try protobuf.decode(schema.ServerPacket, &reader, allocator);
            return packet.quic orelse error.InvalidMessage;
        }
    };

    /// The result as JSON: {"columns":[{name,type}],"rows":[{column:value}]},
    /// with "error":{"code","message"} when the statement failed and
    /// "explain"/"profile" (the plan `geode query --format json` prints)
    /// for EXPLAIN/PROFILE.
    fn resultJson(self: *Self, result: *const query_results.ResultAccumulator) ![]u8 {
        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var root: std.json.ObjectMap = .empty;
        var columns = std.json.Array.init(a);
        for (result.columns.items) |col| {
            var obj: std.json.ObjectMap = .empty;
            try obj.put(a, "name", .{ .string = col.name });
            try obj.put(a, "type", .{ .string = col.type });
            try columns.append(.{ .object = obj });
        }
        var rows = std.json.Array.init(a);
        if (result.rows_json) |rj| {
            for (rj.items) |row| {
                var obj: std.json.ObjectMap = .empty;
                for (row.items, 0..) |value, idx| {
                    const key = if (idx < result.columns.items.len) result.columns.items[idx].name else try std.fmt.allocPrint(a, "col_{d}", .{idx + 1});
                    try obj.put(a, key, value);
                }
                try rows.append(.{ .object = obj });
            }
        }
        try root.put(a, "columns", .{ .array = columns });
        try root.put(a, "rows", .{ .array = rows });
        if (result.result_kind != .rows) {
            if (result.result_payload) |payload| {
                const plan = std.json.parseFromSliceLeaky(std.json.Value, a, payload, .{}) catch std.json.Value{ .string = payload };
                try root.put(a, if (result.result_kind == .explain) "explain" else "profile", plan);
            }
        }
        if (result.indicatesFailure()) {
            var err_obj: std.json.ObjectMap = .empty;
            try err_obj.put(a, "code", .{ .string = if (result.has_error) result.error_status else result.status_class });
            try err_obj.put(a, "message", .{ .string = result.error_message });
            try root.put(a, "error", .{ .object = err_obj });
        }
        return std.json.Stringify.valueAlloc(self.allocator, std.json.Value{ .object = root }, .{});
    }

    pub fn query(self: *Self, gql: []const u8, params: ?[]const u8) ![]u8 {
        try self.ensureConnected();

        const param_list = try self.parseParamsJson(params);
        var adapter = ProtocolAdapter{ .client = &self.client };
        var protocol = query_runner.ProtocolClient{
            .context = &adapter,
            .sendClientMessageFn = ProtocolAdapter.send,
            .readServerMessageFn = ProtocolAdapter.read,
        };
        // collectQuery owns (and frees) the parameter list.
        var result = query_runner.collectQuery(self.allocator, &protocol, .{
            .session_id = self.client.session_id,
            .query_text = gql,
            .format = "json",
            .timeout_secs = 30,
            .params = param_list,
        }) catch |err| {
            self.resetClient() catch {};
            return mapTransportError(err);
        };
        defer result.deinit();
        return self.resultJson(&result);
    }

    /// `query` on `graph` (the session's graph when null). SONNY-6559 (6):
    /// a graph name is a GQL identifier ([A-Za-z_][A-Za-z0-9_]*), checked
    /// by `query_scope` before it is written into the statement.
    pub fn queryIn(self: *Self, graph: ?[]const u8, gql: []const u8) ![]u8 {
        const scoped = try geode.query_scope.prependGraphContextIfNeeded(self.allocator, gql, graph);
        defer if (scoped) |q| self.allocator.free(q);
        return self.query(scoped orelse gql, null);
    }

    pub fn getSchema(self: *Self) ![]u8 {
        return self.query(schema_labels_query, null);
    }

    pub fn explain(self: *Self, gql: []const u8) ![]u8 {
        const explain_query = try std.fmt.allocPrint(self.allocator, "EXPLAIN {s}", .{gql});
        defer self.allocator.free(explain_query);
        return self.query(explain_query, null);
    }

    /// SHOW GRAPHS has no catalog scope in geode (SONNY-6552: the ignored
    /// `catalog` parameter is gone). SONNY-6559 (5): there is no catalogs
    /// tool: geode has no SHOW CATALOGS, and no catalog object to list.
    pub fn listGraphs(self: *Self) ![]u8 {
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
