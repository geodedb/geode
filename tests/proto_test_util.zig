const std = @import("std");
const protobuf = @import("protobuf");
const schema = @import("schema");
const quic = @import("transport/quic");
const grpc_client = @import("grpc_client");
const profile_payload = @import("server/profile_payload.zig");

pub const ServerHandle = struct {
    allocator: std.mem.Allocator,
    child: std.process.Child,
    env_map: ?std.process.EnvMap = null,

    pub fn deinit(self: *ServerHandle) void {
        _ = self.child.kill() catch {};
        _ = self.child.wait() catch {};
        if (self.env_map) |*env| {
            env.deinit();
        }
    }
};

pub const DefaultAuth = struct {
    pub const username: []const u8 = "geode";
    pub const password: []const u8 = "geode-test-password";
};

pub fn defaultUsername() []const u8 {
    return DefaultAuth.username;
}

pub fn defaultPassword() []const u8 {
    return DefaultAuth.password;
}

pub fn spawnServer(
    allocator: std.mem.Allocator,
    args: []const []const u8,
    env: ?[]const []const u8,
) !ServerHandle {
    var handle = ServerHandle{
        .allocator = allocator,
        .child = std.process.Child.init(args, allocator),
        .env_map = null,
    };
    handle.child.stdin_behavior = .Ignore;
    handle.child.stdout_behavior = .Ignore;
    handle.child.stderr_behavior = .Ignore;

    handle.env_map = try std.process.getEnvMap(allocator);
    if (handle.env_map) |*map| {
        if (map.get("GEODE_ADMIN_USERNAME") == null) {
            map.put("GEODE_ADMIN_USERNAME", DefaultAuth.username) catch {};
        }
        if (map.get("GEODE_DEFAULT_PASSWORD") == null) {
            map.put("GEODE_DEFAULT_PASSWORD", DefaultAuth.password) catch {};
        }
        if (env) |pairs| {
            for (pairs) |kv| {
                if (std.mem.indexOfScalar(u8, kv, '=')) |eq| {
                    map.put(kv[0..eq], kv[eq + 1 ..]) catch {};
                }
            }
        }
        handle.child.env_map = map;
    }

    try handle.child.spawn();
    return handle;
}

const Addr = struct {
    host: []const u8,
    port: u16,
};

fn parseAddr(addr: []const u8) !Addr {
    const colon = std.mem.lastIndexOfScalar(u8, addr, ':') orelse return error.InvalidAddress;
    const host = addr[0..colon];
    if (host.len == 0) return error.InvalidAddress;
    const port = try std.fmt.parseInt(u16, addr[colon + 1 ..], 10);
    return .{ .host = host, .port = port };
}

pub const TestValue = union(enum) {
    null,
    int: i64,
    double: f64,
    bool: bool,
    string: []const u8,
    node: struct { id: u64, label_count: usize, property_count: usize },
    edge: struct { id: u64, from_id: u64, to_id: u64, label: []const u8 },
    path: struct { node_count: usize, edge_count: usize },
    other,
};

pub fn testValueEqual(a: TestValue, b: TestValue) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .null => true,
        .int => |av| b == .int and b.int == av,
        .double => |av| b == .double and b.double == av,
        .bool => |av| b == .bool and b.bool == av,
        .string => |av| b == .string and std.mem.eql(u8, b.string, av),
        .node => |av| b == .node and b.node.id == av.id and b.node.label_count == av.label_count and b.node.property_count == av.property_count,
        .edge => |av| b == .edge and b.edge.id == av.id and b.edge.from_id == av.from_id and b.edge.to_id == av.to_id and std.mem.eql(u8, b.edge.label, av.label),
        .path => |av| b == .path and b.path.node_count == av.node_count and b.path.edge_count == av.edge_count,
        .other => b == .other,
    };
}

pub fn execResultsEqual(a: ExecResult, b: ExecResult) bool {
    if (a.columns.len != b.columns.len) return false;
    for (a.columns, 0..) |col, i| {
        if (!std.mem.eql(u8, col, b.columns[i])) return false;
    }
    if (a.rows.len != b.rows.len) return false;
    for (a.rows, 0..) |row, i| {
        const brow = b.rows[i];
        if (row.len != brow.len) return false;
        for (row, 0..) |cell, j| {
            if (!testValueEqual(cell, brow[j])) return false;
        }
    }
    if (a.ordered != b.ordered) return false;
    if (a.order_keys.len != b.order_keys.len) return false;
    for (a.order_keys, 0..) |key, i| {
        if (!std.mem.eql(u8, key, b.order_keys[i])) return false;
    }
    return true;
}

pub const ExecResult = struct {
    status_class: []const u8,
    additional_statuses: [][]const u8,
    flagger_findings: [][]const u8,
    columns: [][]const u8,
    rows: [][]TestValue,
    ordered: bool,
    order_keys: [][]const u8,
    error_code: ?[]const u8 = null,
    error_message: ?[]const u8 = null,

    pub fn deinit(self: *ExecResult, allocator: std.mem.Allocator) void {
        allocator.free(self.status_class);
        for (self.additional_statuses) |s| allocator.free(s);
        allocator.free(self.additional_statuses);
        for (self.flagger_findings) |s| allocator.free(s);
        allocator.free(self.flagger_findings);
        for (self.columns) |c| allocator.free(c);
        allocator.free(self.columns);
        for (self.rows) |row| {
            for (row) |cell| {
                switch (cell) {
                    .string => |s| allocator.free(s),
                    .edge => |e| allocator.free(e.label),
                    else => {},
                }
            }
            allocator.free(row);
        }
        allocator.free(self.rows);
        for (self.order_keys) |k| allocator.free(k);
        allocator.free(self.order_keys);
        if (self.error_code) |c| allocator.free(c);
        if (self.error_message) |m| allocator.free(m);
    }
};

pub const HelloResult = struct {
    success: bool,
    session_id: []const u8,
    error_message: []const u8,
    capabilities: [][]const u8,

    pub fn deinit(self: *HelloResult, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.error_message);
        for (self.capabilities) |c| allocator.free(c);
        allocator.free(self.capabilities);
    }
};

pub const BeginResult = struct {
    session_id: []const u8,
    tx_id: []const u8,

    pub fn deinit(self: *BeginResult, allocator: std.mem.Allocator) void {
        allocator.free(self.session_id);
        allocator.free(self.tx_id);
    }
};

pub const QuicProtoClient = struct {
    allocator: std.mem.Allocator,
    client: quic.QuicClient,
    stream: *quic.QuicClientStream,
    session_id: []const u8 = "",

    pub fn connect(allocator: std.mem.Allocator, addr: []const u8) !QuicProtoClient {
        const parsed = try parseAddr(addr);
        var client = quic.QuicClient.init(allocator);
        errdefer client.deinit();

        client.connectInsecure(parsed.host, parsed.port, true) catch |err| {
            return err;
        };
        try client.waitForHandshake(5);
        const stream = try client.getStream();
        return .{ .allocator = allocator, .client = client, .stream = stream };
    }

    pub fn deinit(self: *QuicProtoClient) void {
        self.stream.deinit();
        self.client.deinit();
        if (self.session_id.len > 0) {
            self.allocator.free(self.session_id);
        }
    }

    fn ensureHello(self: *QuicProtoClient, allocator: std.mem.Allocator) !void {
        if (self.session_id.len > 0) return;
        var hello_result = try self.hello(allocator, defaultUsername(), defaultPassword());
        defer hello_result.deinit(allocator);
        if (!hello_result.success) return error.AuthenticationFailed;
    }

    fn writeMessage(self: *QuicProtoClient, msg: schema.QuicClientMessage) !void {
        var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(self.allocator, 4096);
        defer aw.deinit();

        const packet = schema.ClientPacket{ .quic = msg };
        try protobuf.encode(&aw.writer, self.allocator, packet);

        const body = aw.writer.buffer[0..aw.writer.end];
        var len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &len_buf, @intCast(body.len), .big);
        try self.stream.writeAll(&len_buf);
        try self.stream.writeAll(body);
    }

    fn readPacket(self: *QuicProtoClient, allocator: std.mem.Allocator, timeout_ms: u32) !schema.ServerPacket {
        var len_buf: [4]u8 = undefined;
        var total_read: usize = 0;
        var attempts: usize = 0;
        const max_attempts = @max(@as(usize, 1), timeout_ms / 10);

        while (total_read < 4) {
            const n = self.stream.read(len_buf[total_read..]) catch |err| {
                if (err == error.WouldBlock) {
                    attempts += 1;
                    if (attempts > max_attempts) return error.Timeout;
                    try self.client.poll(1);
                    std.Thread.sleep(10 * std.time.ns_per_ms);
                    continue;
                }
                return err;
            };
            if (n == 0) return error.EndOfStream;
            total_read += n;
        }

        const msg_len = std.mem.readInt(u32, &len_buf, .big);
        if (msg_len > 16 * 1024 * 1024) return error.MessageTooLarge;

        const msg_bytes = try allocator.alloc(u8, msg_len);
        defer allocator.free(msg_bytes);

        total_read = 0;
        attempts = 0;
        while (total_read < msg_len) {
            const n = self.stream.read(msg_bytes[total_read..]) catch |err| {
                if (err == error.WouldBlock) {
                    attempts += 1;
                    if (attempts > max_attempts) return error.Timeout;
                    try self.client.poll(1);
                    std.Thread.sleep(10 * std.time.ns_per_ms);
                    continue;
                }
                return err;
            };
            if (n == 0) return error.EndOfStream;
            total_read += n;
        }

        var reader: std.Io.Reader = .fixed(msg_bytes);
        return try protobuf.decode(schema.ServerPacket, &reader, allocator);
    }

    pub fn hello(self: *QuicProtoClient, allocator: std.mem.Allocator, username: []const u8, password: []const u8) !HelloResult {
        const req = schema.HelloRequest{
            .username = username,
            .password = password,
            .tenant_id = null,
            .client_name = "geode-test",
            .client_version = "0.0.0",
            .wanted_conformance = "min",
        };
        try self.writeMessage(.{ .hello = req });

        var packet = try self.readPacket(allocator, 5000);
        defer packet.deinit(allocator);

        const msg = packet.quic orelse return error.InvalidMessage;
        if (msg != .hello) return error.InvalidMessage;

        const resp = msg.hello;
        const session_id = try allocator.dupe(u8, resp.session_id);
        const error_message = try allocator.dupe(u8, resp.error_message);
        var caps = try allocator.alloc([]const u8, resp.capabilities.items.len);
        for (resp.capabilities.items, 0..) |cap, i| {
            caps[i] = try allocator.dupe(u8, cap);
        }
        if (self.session_id.len > 0) self.allocator.free(self.session_id);
        self.session_id = try self.allocator.dupe(u8, session_id);
        return .{
            .success = resp.success,
            .session_id = session_id,
            .error_message = error_message,
            .capabilities = caps,
        };
    }

    pub fn ping(self: *QuicProtoClient, allocator: std.mem.Allocator) !bool {
        try self.writeMessage(.{ .ping = .{} });
        var packet = try self.readPacket(allocator, 2000);
        defer packet.deinit(allocator);
        const msg = packet.quic orelse return error.InvalidMessage;
        if (msg != .ping) return error.InvalidMessage;
        return msg.ping.ok;
    }

    pub fn cdcDiagnostics(self: *QuicProtoClient, allocator: std.mem.Allocator) !schema.CdcDiagnosticsResponse {
        try self.ensureHello(allocator);
        try self.writeMessage(.{ .cdc_diag = .{} });
        var packet = try self.readPacket(allocator, 5000);
        defer packet.deinit(allocator);
        const msg = packet.quic orelse return error.InvalidMessage;
        if (msg != .cdc_diag) return error.InvalidMessage;
        return try copyCdcDiagnostics(allocator, msg.cdc_diag);
    }

    pub fn begin(self: *QuicProtoClient, allocator: std.mem.Allocator) !BeginResult {
        const req = schema.BeginRequest{ .read_only = false, .session_id = "" };
        try self.writeMessage(.{ .begin = req });
        var packet = try self.readPacket(allocator, 5000);
        defer packet.deinit(allocator);
        const msg = packet.quic orelse return error.InvalidMessage;
        if (msg != .begin) return error.InvalidMessage;
        return .{
            .session_id = try allocator.dupe(u8, msg.begin.session_id),
            .tx_id = try allocator.dupe(u8, msg.begin.tx_id),
        };
    }

    pub fn commit(self: *QuicProtoClient, allocator: std.mem.Allocator) !bool {
        const req = schema.CommitRequest{ .session_id = "" };
        try self.writeMessage(.{ .commit = req });
        var packet = try self.readPacket(allocator, 5000);
        defer packet.deinit(allocator);
        const msg = packet.quic orelse return error.InvalidMessage;
        if (msg != .commit) return error.InvalidMessage;
        return msg.commit.success;
    }

    pub fn rollback(self: *QuicProtoClient, allocator: std.mem.Allocator) !bool {
        const req = schema.RollbackRequest{ .session_id = "" };
        try self.writeMessage(.{ .rollback = req });
        var packet = try self.readPacket(allocator, 5000);
        defer packet.deinit(allocator);
        const msg = packet.quic orelse return error.InvalidMessage;
        if (msg != .rollback) return error.InvalidMessage;
        return msg.rollback.success;
    }

    fn copyStatus(allocator: std.mem.Allocator, status: schema.Status) !struct {
        status_class: []const u8,
        additional: [][]const u8,
        flagger: [][]const u8,
    } {
        const status_class = try allocator.dupe(u8, status.status_class);
        var additional = try allocator.alloc([]const u8, status.additional_statuses.items.len);
        for (status.additional_statuses.items, 0..) |s, i| {
            additional[i] = try allocator.dupe(u8, s);
        }
        var flagger = try allocator.alloc([]const u8, status.flagger_findings.items.len);
        for (status.flagger_findings.items, 0..) |s, i| {
            flagger[i] = try allocator.dupe(u8, s);
        }
        return .{ .status_class = status_class, .additional = additional, .flagger = flagger };
    }

    fn copyCdcDiagnostics(
        allocator: std.mem.Allocator,
        diag: schema.CdcDiagnosticsResponse,
    ) !schema.CdcDiagnosticsResponse {
        var snapshots = std.ArrayList(schema.CdcMalformedSnapshot).initCapacity(allocator, diag.malformed_snapshots.items.len) catch return error.OutOfMemory;
        errdefer snapshots.deinit(allocator);
        for (diag.malformed_snapshots.items) |snap| {
            try snapshots.append(allocator, snap);
        }

        var hashes = std.ArrayList(schema.CdcMalformedHash).initCapacity(allocator, diag.malformed_hashes.items.len) catch return error.OutOfMemory;
        errdefer {
            for (hashes.items) |*item| item.deinit(allocator);
            hashes.deinit(allocator);
        }
        for (diag.malformed_hashes.items) |hash| {
            const entry = schema.CdcMalformedHash{
                .count = hash.count,
                .hash = hash.hash,
                .ts_ms = hash.ts_ms,
                .prefix_hex = if (hash.prefix_hex.len > 0) try allocator.dupe(u8, hash.prefix_hex) else "",
            };
            try hashes.append(allocator, entry);
        }

        const version = if (diag.version.len > 0) try allocator.dupe(u8, diag.version) else "";

        return schema.CdcDiagnosticsResponse{
            .malformed_change_records = diag.malformed_change_records,
            .total_change_attempts = diag.total_change_attempts,
            .malformed_ratio = diag.malformed_ratio,
            .guardrail_warn_triggered = diag.guardrail_warn_triggered,
            .guardrail_abort_triggered = diag.guardrail_abort_triggered,
            .first_warn_ts_ms = diag.first_warn_ts_ms,
            .first_abort_ts_ms = diag.first_abort_ts_ms,
            .guardrail_epoch = diag.guardrail_epoch,
            .uptime_ms = diag.uptime_ms,
            .backpressure = diag.backpressure,
            .config = if (diag.config) |cfg| cfg else null,
            .engine = if (diag.engine) |eng| eng else null,
            .malformed_snapshots = snapshots,
            .malformed_hashes = hashes,
            .version = version,
            .timestamp_ms = diag.timestamp_ms,
        };
    }

    fn valueToTest(allocator: std.mem.Allocator, val: schema.Value) !TestValue {
        if (val.kind) |k| switch (k) {
            .null_val => return .null,
            .int_val => |i| return .{ .int = i.value },
            .double_val => |d| return .{ .double = d.value },
            .bool_val => |b| return .{ .bool = b },
            .string_val => |s| return .{ .string = try allocator.dupe(u8, s.value) },
            .node_val => |n| return .{ .node = .{ .id = n.id, .label_count = n.labels.items.len, .property_count = n.properties.items.len } },
            .edge_val => |e| return .{ .edge = .{ .id = e.id, .from_id = e.from_id, .to_id = e.to_id, .label = try allocator.dupe(u8, e.label) } },
            .path_val => |p| return .{ .path = .{ .node_count = p.nodes.items.len, .edge_count = p.edges.items.len } },
            else => return .other,
        };
        return .null;
    }

    fn appendRows(
        allocator: std.mem.Allocator,
        rows_list: *std.array_list.Managed([]TestValue),
        page: schema.DataPage,
    ) !void {
        for (page.rows.items) |row| {
            var out_row = try allocator.alloc(TestValue, row.values.items.len);
            for (row.values.items, 0..) |v, i| {
                out_row[i] = try valueToTest(allocator, v);
            }
            try rows_list.append( out_row);
        }
    }

    pub fn executeAndCollect(
        self: *QuicProtoClient,
        allocator: std.mem.Allocator,
        query: []const u8,
        params: std.ArrayList(schema.Param),
        page_size: u32,
    ) !ExecResult {
        try self.ensureHello(allocator);
        var params_list = params;
        defer {
            for (params_list.items) |*param| {
                param.deinit(allocator);
            }
            params_list.deinit(allocator);
        }

        const req = schema.ExecuteRequest{
            .session_id = self.session_id,
            .query = query,
            .params = params_list,
        };
        try self.writeMessage(.{ .execute = req });

        var columns = std.array_list.Managed([]const u8).init(allocator);
        errdefer {
            for (columns.items) |c| allocator.free(c);
            columns.deinit();
        }

        var rows = std.array_list.Managed([]TestValue).init(allocator);
        errdefer {
            for (rows.items) |row| {
                for (row) |cell| {
                    switch (cell) {
                        .string => |s| allocator.free(s),
                        .edge => |e| allocator.free(e.label),
                        else => {},
                    }
                }
                allocator.free(row);
            }
            rows.deinit();
        }

        var ordered = false;
        var order_keys = std.array_list.Managed([]const u8).init(allocator);
        errdefer {
            for (order_keys.items) |k| allocator.free(k);
            order_keys.deinit();
        }

        var status_class: []const u8 = try allocator.dupe(u8, "");
        var additional_statuses: [][]const u8 = try allocator.alloc([]const u8, 0);
        var flagger_findings: [][]const u8 = try allocator.alloc([]const u8, 0);
        var error_code: ?[]const u8 = null;
        var error_message: ?[]const u8 = null;

        var schema_received = false;
        while (!schema_received and error_code == null) {
            var packet = try self.readPacket(allocator, 5000);
            defer packet.deinit(allocator);

            const msg = packet.quic orelse return error.InvalidMessage;
            if (msg != .execute) return error.InvalidMessage;
            const exec_resp = msg.execute;
            const status = try copyStatus(allocator, exec_resp.status.?);
            allocator.free(status_class);
            allocator.free(additional_statuses);
            allocator.free(flagger_findings);
            status_class = status.status_class;
            additional_statuses = status.additional;
            flagger_findings = status.flagger;

            if (exec_resp.payload) |payload| switch (payload) {
                .schema => |schema_def| {
                    for (schema_def.columns.items) |col| {
                        try columns.append( try allocator.dupe(u8, col.name));
                    }
                    schema_received = true;
                },
                .page => |p| {
                    ordered = ordered or p.ordered;
                    if (order_keys.items.len == 0 and p.order_keys.items.len > 0) {
                        for (p.order_keys.items) |k| try order_keys.append( try allocator.dupe(u8, k));
                    }
                    try appendRows(allocator, &rows, p);
                    if (!p.final) {
                        schema_received = true;
                    }
                },
                .@"error" => |e| {
                    error_code = try allocator.dupe(u8, e.code);
                    error_message = try allocator.dupe(u8, e.message);
                },
                else => {},
            };
        }

        if (error_code == null) {
            var done = false;
            var request_id: u64 = 1;
            while (!done) : (request_id += 1) {
                const pull_req = schema.PullRequest{ .request_id = request_id, .page_size = page_size, .session_id = self.session_id };
                try self.writeMessage(.{ .pull = pull_req });

                var packet = try self.readPacket(allocator, 5000);
                defer packet.deinit(allocator);

                const msg = packet.quic orelse return error.InvalidMessage;
                const exec_resp = switch (msg) {
                    .pull => |p| p.response orelse return error.InvalidMessage,
                    .execute => |e| e,
                    else => return error.InvalidMessage,
                };

                if (exec_resp.payload) |payload| switch (payload) {
                    .page => |p| {
                        ordered = ordered or p.ordered;
                        if (order_keys.items.len == 0 and p.order_keys.items.len > 0) {
                            for (p.order_keys.items) |k| try order_keys.append( try allocator.dupe(u8, k));
                        }
                        try appendRows(allocator, &rows, p);
                        if (p.final) done = true;
                    },
                    .@"error" => |e| {
                        error_code = try allocator.dupe(u8, e.code);
                        error_message = try allocator.dupe(u8, e.message);
                        done = true;
                    },
                    else => {},
                };
            }
        }

        return .{
            .status_class = status_class,
            .additional_statuses = additional_statuses,
            .flagger_findings = flagger_findings,
            .columns = try columns.toOwnedSlice(),
            .rows = try rows.toOwnedSlice(),
            .ordered = ordered,
            .order_keys = try order_keys.toOwnedSlice(),
            .error_code = error_code,
            .error_message = error_message,
        };
    }

    pub fn executeProfileJson(
        self: *QuicProtoClient,
        allocator: std.mem.Allocator,
        query: []const u8,
    ) ![]u8 {
        try self.ensureHello(allocator);
        const req = schema.ExecuteRequest{
            .session_id = self.session_id,
            .query = query,
            .params = std.ArrayList(schema.Param){},
        };
        try self.writeMessage(.{ .execute = req });

        var packet = try self.readPacket(allocator, 5000);
        defer packet.deinit(allocator);
        const msg = packet.quic orelse return error.InvalidMessage;
        if (msg != .execute) return error.InvalidMessage;
        const exec_resp = msg.execute;
        if (exec_resp.payload) |payload| switch (payload) {
            .profile => |prof| return try profile_payload.profilePayloadToJson(allocator, prof),
            else => {},
        };
        return error.InvalidResponse;
    }
};

pub const GrpcProtoClient = struct {
    allocator: std.mem.Allocator,
    client: grpc_client.GrpcClient,
    session_id: []const u8 = "",

    pub fn connect(allocator: std.mem.Allocator, addr: []const u8) !GrpcProtoClient {
        const parsed = try parseAddr(addr);
        const client = try grpc_client.GrpcClient.init(allocator, parsed.host, parsed.port);
        return .{ .allocator = allocator, .client = client };
    }

    pub fn deinit(self: *GrpcProtoClient) void {
        self.client.deinit();
        if (self.session_id.len > 0) {
            self.allocator.free(self.session_id);
        }
    }

    fn ensureHello(self: *GrpcProtoClient, allocator: std.mem.Allocator) !void {
        if (self.session_id.len > 0) return;
        var hello_result = try self.hello(allocator, defaultUsername(), defaultPassword());
        defer hello_result.deinit(allocator);
        if (!hello_result.success) return error.AuthenticationFailed;
    }

    fn encodePacket(allocator: std.mem.Allocator, msg: schema.QuicClientMessage) ![]u8 {
        var aw: std.Io.Writer.Allocating = std.Io.Writer.Allocating.initCapacity(allocator, 1024) catch return error.OutOfMemory;
        errdefer aw.deinit();
        const packet = schema.ClientPacket{ .quic = msg };
        try protobuf.encode(&aw.writer, allocator, packet);
        const out = try allocator.dupe(u8, aw.writer.buffer[0..aw.writer.end]);
        aw.deinit();
        return out;
    }

    fn decodePacket(allocator: std.mem.Allocator, bytes: []const u8) !schema.ServerPacket {
        var reader: std.Io.Reader = .fixed(bytes);
        return protobuf.decode(schema.ServerPacket, &reader, allocator);
    }

    fn call(self: *GrpcProtoClient, msg: schema.QuicClientMessage) !schema.ServerPacket {
        const req_bytes = try encodePacket(self.allocator, msg);
        defer self.allocator.free(req_bytes);
        const resp_bytes = try self.client.call("Packet", req_bytes, .none);
        defer self.allocator.free(resp_bytes);
        return decodePacket(self.allocator, resp_bytes);
    }

    pub fn hello(self: *GrpcProtoClient, allocator: std.mem.Allocator, username: []const u8, password: []const u8) !HelloResult {
        var packet = try self.call(.{ .hello = .{
            .username = username,
            .password = password,
            .client_name = "grpc-test",
            .client_version = "1.0",
            .wanted_conformance = "test",
        } });
        defer packet.deinit(allocator);

        const msg = packet.quic orelse return error.InvalidResponse;
        if (msg != .hello) return error.InvalidResponse;
        const resp = msg.hello;

        const session_id = try allocator.dupe(u8, resp.session_id);
        if (self.session_id.len > 0) allocator.free(self.session_id);
        self.session_id = try allocator.dupe(u8, resp.session_id);

        var caps = try allocator.alloc([]const u8, resp.capabilities.items.len);
        for (resp.capabilities.items, 0..) |cap, i| {
            caps[i] = try allocator.dupe(u8, cap);
        }

        return .{
            .success = resp.success,
            .session_id = session_id,
            .error_message = try allocator.dupe(u8, resp.error_message),
            .capabilities = caps,
        };
    }

    fn valueToTest(allocator: std.mem.Allocator, val: schema.Value) !TestValue {
        if (val.kind) |k| switch (k) {
            .null_val => return .null,
            .int_val => |i| return .{ .int = i.value },
            .double_val => |d| return .{ .double = d.value },
            .bool_val => |b| return .{ .bool = b },
            .string_val => |s| return .{ .string = try allocator.dupe(u8, s.value) },
            .node_val => |n| return .{ .node = .{ .id = n.id, .label_count = n.labels.items.len, .property_count = n.properties.items.len } },
            .edge_val => |e| return .{ .edge = .{ .id = e.id, .from_id = e.from_id, .to_id = e.to_id, .label = try allocator.dupe(u8, e.label) } },
            .path_val => |p| return .{ .path = .{ .node_count = p.nodes.items.len, .edge_count = p.edges.items.len } },
            else => return .other,
        };
        return .null;
    }

    fn appendRows(
        allocator: std.mem.Allocator,
        rows_list: *std.array_list.Managed([]TestValue),
        page: schema.DataPage,
    ) !void {
        for (page.rows.items) |row| {
            var out_row = try allocator.alloc(TestValue, row.values.items.len);
            for (row.values.items, 0..) |v, i| {
                out_row[i] = try valueToTest(allocator, v);
            }
            try rows_list.append( out_row);
        }
    }

    pub fn executeAndCollect(
        self: *GrpcProtoClient,
        allocator: std.mem.Allocator,
        query: []const u8,
        params: std.ArrayList(schema.Param),
        page_size: u32,
    ) !ExecResult {
        try self.ensureHello(allocator);
        var params_list = params;
        defer {
            for (params_list.items) |*param| {
                param.deinit(allocator);
            }
            params_list.deinit(allocator);
        }

        var packet = try self.call(.{ .execute = .{
            .session_id = self.session_id,
            .query = query,
            .params = params_list,
        } });
        defer packet.deinit(allocator);

        const msg = packet.quic orelse return error.InvalidResponse;
        if (msg != .execute) return error.InvalidResponse;
        const exec_resp = msg.execute;

        var columns = std.array_list.Managed([]const u8).init(allocator);
        errdefer {
            for (columns.items) |c| allocator.free(c);
            columns.deinit();
        }

        var rows = std.array_list.Managed([]TestValue).init(allocator);
        errdefer {
            for (rows.items) |row| {
                for (row) |cell| {
                    switch (cell) {
                        .string => |s| allocator.free(s),
                        .edge => |e| allocator.free(e.label),
                        else => {},
                    }
                }
                allocator.free(row);
            }
            rows.deinit();
        }

        var ordered = false;
        var order_keys = std.array_list.Managed([]const u8).init(allocator);
        errdefer {
            for (order_keys.items) |k| allocator.free(k);
            order_keys.deinit();
        }

        var status_class: []const u8 = "00000";
        var additional_statuses = std.array_list.Managed([]const u8).init(allocator);
        errdefer {
            for (additional_statuses.items) |s| allocator.free(s);
            additional_statuses.deinit();
        }
        var flagger_findings = std.array_list.Managed([]const u8).init(allocator);
        errdefer {
            for (flagger_findings.items) |s| allocator.free(s);
            flagger_findings.deinit();
        }

        var error_code: ?[]const u8 = null;
        var error_message: ?[]const u8 = null;

        if (exec_resp.status) |status| {
            status_class = try allocator.dupe(u8, status.status_class);
            for (status.additional_statuses.items) |s| {
                try additional_statuses.append( try allocator.dupe(u8, s));
            }
            for (status.flagger_findings.items) |s| {
                try flagger_findings.append( try allocator.dupe(u8, s));
            }
        } else {
            status_class = try allocator.dupe(u8, "00000");
        }

        if (exec_resp.payload) |payload| switch (payload) {
            .schema => |schema_def| {
                for (schema_def.columns.items) |col| {
                    try columns.append( try allocator.dupe(u8, col.name));
                }
            },
            .@"error" => |err| {
                error_code = try allocator.dupe(u8, err.code);
                error_message = try allocator.dupe(u8, err.message);
            },
            else => {},
        };

        // Pull pages
        var request_id: u64 = 1;
        var done = false;
        while (!done and error_code == null) : (request_id += 1) {
            var pull_packet = try self.call(.{ .pull = .{
                .request_id = request_id,
                .page_size = page_size,
                .session_id = self.session_id,
            } });
            defer pull_packet.deinit(allocator);

            const pull_msg = pull_packet.quic orelse return error.InvalidResponse;
            if (pull_msg != .pull) return error.InvalidResponse;
            const pull_resp = pull_msg.pull;
            const pull_exec = pull_resp.response orelse break;

            if (pull_exec.payload) |payload| switch (payload) {
                .page => |page| {
                    ordered = ordered or page.ordered;
                    if (page.order_keys.items.len > 0 and order_keys.items.len == 0) {
                        for (page.order_keys.items) |k| {
                            try order_keys.append( try allocator.dupe(u8, k));
                        }
                    }
                    try appendRows(allocator, &rows, page);
                    if (page.final) done = true;
                },
                .@"error" => |err| {
                    error_code = try allocator.dupe(u8, err.code);
                    error_message = try allocator.dupe(u8, err.message);
                },
                else => {},
            };
        }

        return .{
            .status_class = status_class,
            .additional_statuses = try allocator.dupe([]const u8, additional_statuses.items),
            .flagger_findings = try allocator.dupe([]const u8, flagger_findings.items),
            .columns = try allocator.dupe([]const u8, columns.items),
            .rows = try allocator.dupe([]TestValue, rows.items),
            .ordered = ordered,
            .order_keys = try allocator.dupe([]const u8, order_keys.items),
            .error_code = error_code,
            .error_message = error_message,
        };
    }
};

pub fn emptyParams() std.ArrayList(schema.Param) {
    return std.ArrayList(schema.Param){};
}

pub fn makeIntParam(allocator: std.mem.Allocator, name: []const u8, value: i64) !schema.Param {
    return .{
        .name = try allocator.dupe(u8, name),
        .value = .{ .kind = .{ .int_val = .{ .value = value, .kind = .INT } } },
    };
}

pub fn makeBoolParam(allocator: std.mem.Allocator, name: []const u8, value: bool) !schema.Param {
    return .{
        .name = try allocator.dupe(u8, name),
        .value = .{ .kind = .{ .bool_val = value } },
    };
}

pub fn makeStringParam(allocator: std.mem.Allocator, name: []const u8, value: []const u8) !schema.Param {
    return .{
        .name = try allocator.dupe(u8, name),
        .value = .{ .kind = .{ .string_val = .{ .value = try allocator.dupe(u8, value), .kind = .STRING } } },
    };
}

pub fn makeIntListParam(allocator: std.mem.Allocator, name: []const u8, values: []const i64) !schema.Param {
    var list_values = std.ArrayList(schema.Value).initCapacity(allocator, values.len) catch return error.OutOfMemory;
    for (values) |v| {
        try list_values.append( .{ .kind = .{ .int_val = .{ .value = v, .kind = .INT } } });
    }
    return .{
        .name = try allocator.dupe(u8, name),
        .value = .{ .kind = .{ .list_val = .{ .values = list_values } } },
    };
}
