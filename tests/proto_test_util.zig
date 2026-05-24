const std = @import("std");
const builtin = @import("builtin");
const protobuf = @import("protobuf");
const schema = @import("schema");
const quic = @import("transport/quic");
const geode = @import("geode");
const profile_payload = geode.profile_payload;
const grpc_query_transport = geode.grpc_query_transport;
const query_runner = geode.query_runner;
const query_result_accumulator = geode.query_result_accumulator;
const posix = std.posix;

// ============================================================================
// Progress Indicators
// ============================================================================

/// Print test start message with flush
pub fn testStart(comptime name: []const u8) void {
    std.debug.print("[TEST] {s}...", .{name});
}

/// Print test success with checkmark
pub fn testPass() void {
    std.debug.print(" ✓\n", .{});
}

/// Print test failure with X
pub fn testFail() void {
    std.debug.print(" ✗\n", .{});
}

/// Print test skip with dash
pub fn testSkip() void {
    std.debug.print(" -\n", .{});
}

/// Print test warning
pub fn testWarn() void {
    std.debug.print(" ⚠\n", .{});
}

/// Print progress message during test
pub fn progress(comptime fmt: []const u8, args: anytype) void {
    std.debug.print("  " ++ fmt ++ "\n", args);
}

// ============================================================================
// Port Randomization
// ============================================================================

/// Get a random available port by binding to port 0 and reading the assigned port.
/// This uses UDP to avoid leaving a connection in TIME_WAIT state.
///
/// Zig 0.16 retired the `std.posix.socket` / `bind` / `getsockname`
/// wrappers; the supported path here is to use `std.os.linux.*`
/// directly (same pattern src/cli/cli_dispatcher.zig:1267 uses for
/// UDP probe traffic).
pub fn getRandomPort() !u16 {
    const linux = std.os.linux;

    const sock_rc = linux.socket(linux.AF.INET, linux.SOCK.DGRAM, 0);
    if (@as(isize, @bitCast(sock_rc)) < 0) return error.SocketCreateFailed;
    const sock_fd: i32 = @intCast(sock_rc);
    defer _ = linux.close(sock_fd);

    var addr = linux.sockaddr.in{
        .family = linux.AF.INET,
        .port = 0, // Let OS assign a port
        .addr = 0, // INADDR_ANY
    };
    const bind_rc = linux.bind(sock_fd, @ptrCast(&addr), @sizeOf(linux.sockaddr.in));
    if (@as(isize, @bitCast(bind_rc)) < 0) return error.BindFailed;

    var bound_addr: linux.sockaddr.in = undefined;
    var addr_len: linux.socklen_t = @sizeOf(linux.sockaddr.in);
    const gsn_rc = linux.getsockname(sock_fd, @ptrCast(&bound_addr), &addr_len);
    if (@as(isize, @bitCast(gsn_rc)) < 0) return error.GetsocknameFailed;

    // Port is in network byte order, convert to host
    return std.mem.bigToNative(u16, bound_addr.port);
}

/// Format an address string with the given port
pub fn formatAddr(allocator: std.mem.Allocator, port: u16) ![]u8 {
    return std.fmt.allocPrint(allocator, "127.0.0.1:{d}", .{port});
}

// ============================================================================
// Test Environment Configuration
// ============================================================================

/// Standard test environment variables
pub const TestEnv = struct {
    /// Get standard test environment variables (empty by default).
    pub fn standard() []const []const u8 {
        return &.{};
    }
};

// ============================================================================
// Server Handle
// ============================================================================

pub const ServerHandle = struct {
    allocator: std.mem.Allocator,
    child: std.process.Child,
    // Zig 0.16: std.process.EnvMap → std.process.Environ.Map.  Same
    // role (mutable child-process env override), different module path.
    env_map: ?std.process.Environ.Map = null,
    port: u16 = 0,
    addr: []const u8 = "",

    pub fn deinit(self: *ServerHandle) void {
        // Zig 0.16: kill/wait take an Io parameter.  proto_test_util is
        // a synchronous test helper — the process-global single-threaded
        // io vtable is the right fit (same shape every other stdio site
        // in this repo uses).
        const io = std.Io.Threaded.global_single_threaded.io();
        self.child.kill(io);
        _ = self.child.wait(io) catch {};
        if (self.env_map) |*env| {
            env.deinit();
        }
        if (self.addr.len > 0) {
            self.allocator.free(self.addr);
        }
    }

    /// Get the server address for connecting
    pub fn getAddr(self: *const ServerHandle) []const u8 {
        return self.addr;
    }

    /// Get the server port
    pub fn getPort(self: *const ServerHandle) u16 {
        return self.port;
    }
};

// Zig 0.16: std.time.milliTimestamp / std.time.sleep were removed.
// Same compat shim shape src/security/authn.zig uses — linux-only
// clock_gettime + nanosleep through std.os.linux.
fn compat_milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
    if (rc != 0) return 0;
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
fn compat_sleep(ns: u64) void {
    const sec: i64 = @intCast(ns / std.time.ns_per_s);
    const nsec: i64 = @intCast(ns % std.time.ns_per_s);
    var ts: std.posix.timespec = .{ .sec = sec, .nsec = nsec };
    _ = std.os.linux.nanosleep(&ts, null);
}

/// Wait for server to be ready by attempting to connect
pub fn waitForServerReady(allocator: std.mem.Allocator, addr: []const u8, timeout_ms: u64) !void {
    const start = compat_milliTimestamp();
    const deadline = start + @as(i64, @intCast(timeout_ms));

    while (compat_milliTimestamp() < deadline) {
        // Try to connect
        var client = QuicProtoClient.connect(allocator, addr) catch {
            // Connection failed, wait a bit and retry
            compat_sleep(100 * std.time.ns_per_ms);
            continue;
        };
        client.deinit();
        return; // Successfully connected
    }

    return error.ServerStartupTimeout;
}

/// Spawn a server with a random port and wait for it to be ready
pub fn spawnServerRandom(
    allocator: std.mem.Allocator,
    env: ?[]const []const u8,
) !ServerHandle {
    const port = try getRandomPort();
    const addr = try formatAddr(allocator, port);
    errdefer allocator.free(addr);

    progress("Starting server on port {d}...", .{port});

    var handle = try spawnServerWithAddr(allocator, addr, env);
    handle.port = port;
    handle.addr = addr;

    // Wait for server to be ready
    waitForServerReady(allocator, addr, 10000) catch |err| {
        handle.deinit();
        return err;
    };

    progress("Server ready on {s}", .{addr});
    return handle;
}

/// Spawn a server with a specific address
pub fn spawnServerWithAddr(
    allocator: std.mem.Allocator,
    addr: []const u8,
    env: ?[]const []const u8,
) !ServerHandle {
    const args = &[_][]const u8{ "./zig-out/bin/geode", "serve", "--listen", addr };
    return spawnServer(allocator, args, env);
}

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
    // Zig 0.16 retired `std.process.Child.init` + `Child.spawn` in favor
    // of the free function `std.process.spawn(io, SpawnOptions)`.
    // `EnvMap` / `getEnvMap` were renamed to `Environ.Map` /
    // `Environ.createMap`.  Same behavior: snapshot the parent's env,
    // optionally overlay the test defaults + caller-supplied KVs, then
    // hand the map to the child via `SpawnOptions.environ_map`.
    const io = std.Io.Threaded.global_single_threaded.io();

    // Zig 0.16: build the child env map from /proc/self/environ
    // (NUL-separated key=value entries from the parent process's
    // address space).  std.posix.environ was retired in 0.16 and
    // std.c.environ would require link_libc on every test target
    // that pulls in proto_test_util.zig — too invasive.  Reading
    // /proc/self/environ is stdlib-only, linux-specific (which the
    // tests here are anyway: `quic-smoke-strict` and
    // `transport-parity-smokes` only run on the linux CI image).
    var map = std.process.Environ.Map.init(allocator);
    errdefer map.deinit();

    {
        // Reuse the outer `io` rather than shadowing it.
        var environ_file = std.Io.Dir.cwd().openFile(io, "/proc/self/environ", .{ .mode = .read_only }) catch null;
        if (environ_file) |*f| {
            defer f.close(io);
            // Bounded read; this proc file is tiny in practice.
            var buf: [64 * 1024]u8 = undefined;
            const n = f.readPositionalAll(io, &buf, 0) catch 0;
            const data = buf[0..n];
            var start: usize = 0;
            for (data, 0..) |c, i| {
                if (c != 0) continue;
                if (i > start) {
                    const entry = data[start..i];
                    if (std.mem.indexOfScalar(u8, entry, '=')) |eq| {
                        try map.put(entry[0..eq], entry[eq + 1 ..]);
                    }
                }
                start = i + 1;
            }
        }
    }

    if (map.get("GEODE_ADMIN_USERNAME") == null) {
        map.put("GEODE_ADMIN_USERNAME", DefaultAuth.username) catch {};
    }
    if (map.get("GEODE_ADMIN_PASSWORD") == null) {
        map.put("GEODE_ADMIN_PASSWORD", DefaultAuth.password) catch {};
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

    const child = try std.process.spawn(io, .{
        .argv = args,
        .environ_map = &map,
        // Zig 0.16: SpawnOptions renamed `*_behavior` to bare
        // `stdin` / `stdout` / `stderr` of `StdIo` enum.
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });

    return ServerHandle{
        .allocator = allocator,
        .child = child,
        .env_map = map,
    };
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

fn dupeStringSliceList(allocator: std.mem.Allocator, items: []const []const u8) ![][]const u8 {
    var out = try allocator.alloc([]const u8, items.len);
    errdefer {
        for (out[0..items.len]) |item| allocator.free(item);
        allocator.free(out);
    }
    for (items, 0..) |item, idx| {
        out[idx] = try allocator.dupe(u8, item);
    }
    return out;
}

fn jsonValueToU64(value: std.json.Value) !u64 {
    return switch (value) {
        .integer => |num| std.math.cast(u64, num) orelse return error.InvalidResultJson,
        .number_string => |num| try std.fmt.parseInt(u64, num, 10),
        .string => |num| try std.fmt.parseInt(u64, num, 10),
        else => error.InvalidResultJson,
    };
}

fn jsonValueToTest(allocator: std.mem.Allocator, value: std.json.Value) !TestValue {
    return switch (value) {
        .null => .null,
        .bool => |flag| .{ .bool = flag },
        .integer => |num| .{ .int = num },
        .float => |num| .{ .double = num },
        .number_string => |num| blk: {
            if (std.fmt.parseInt(i64, num, 10)) |parsed| {
                break :blk .{ .int = parsed };
            } else |_| {
                break :blk .{ .string = try allocator.dupe(u8, num) };
            }
        },
        .string => |text| .{ .string = try allocator.dupe(u8, text) },
        .array => .other,
        .object => |obj| blk: {
            if (obj.get("labels")) |labels_val| {
                const props_val = obj.get("properties") orelse return .other;
                const id_val = obj.get("id") orelse return .other;
                if (labels_val != .array or props_val != .object) return .other;
                break :blk .{ .node = .{
                    .id = try jsonValueToU64(id_val),
                    .label_count = labels_val.array.items.len,
                    .property_count = props_val.object.count(),
                } };
            }
            if (obj.get("label")) |label_val| {
                const from_id_val = obj.get("from_id") orelse return .other;
                const to_id_val = obj.get("to_id") orelse return .other;
                const id_val = obj.get("id") orelse return .other;
                if (label_val != .string) return .other;
                break :blk .{ .edge = .{
                    .id = try jsonValueToU64(id_val),
                    .from_id = try jsonValueToU64(from_id_val),
                    .to_id = try jsonValueToU64(to_id_val),
                    .label = try allocator.dupe(u8, label_val.string),
                } };
            }
            if (obj.get("nodes")) |nodes_val| {
                const edges_val = obj.get("edges") orelse return .other;
                if (nodes_val != .array or edges_val != .array) return .other;
                break :blk .{ .path = .{
                    .node_count = nodes_val.array.items.len,
                    .edge_count = edges_val.array.items.len,
                } };
            }
            break :blk .other;
        },
    };
}

fn execResultFromAccumulator(
    allocator: std.mem.Allocator,
    result: *const query_result_accumulator.ResultAccumulator,
) !ExecResult {
    const row_count = if (result.rows_json) |rows_json| rows_json.items.len else 0;
    var rows = try allocator.alloc([]TestValue, row_count);
    errdefer {
        for (rows[0..row_count]) |row| {
            for (row) |cell| {
                switch (cell) {
                    .string => |text| allocator.free(text),
                    .edge => |edge| allocator.free(edge.label),
                    else => {},
                }
            }
            allocator.free(row);
        }
        allocator.free(rows);
    }

    if (result.rows_json) |rows_json| {
        for (rows_json.items, 0..) |row_values, row_idx| {
            rows[row_idx] = try allocator.alloc(TestValue, row_values.items.len);
            for (row_values.items, 0..) |value, col_idx| {
                rows[row_idx][col_idx] = try jsonValueToTest(allocator, value);
            }
        }
    }

    var columns = try allocator.alloc([]const u8, result.columns.items.len);
    errdefer {
        for (columns[0..result.columns.items.len]) |column| allocator.free(column);
        allocator.free(columns);
    }
    for (result.columns.items, 0..) |column, idx| {
        columns[idx] = try allocator.dupe(u8, column.name);
    }

    return .{
        .status_class = try allocator.dupe(u8, result.status_class),
        .additional_statuses = try dupeStringSliceList(allocator, result.additional_statuses.items),
        .flagger_findings = try dupeStringSliceList(allocator, result.flagger_findings.items),
        .columns = columns,
        .rows = rows,
        .ordered = result.ordered,
        .order_keys = try dupeStringSliceList(allocator, result.order_keys.items),
        .error_code = if (result.has_error and result.error_status.len > 0) try allocator.dupe(u8, result.error_status) else null,
        .error_message = if (result.has_error and result.error_message.len > 0) try allocator.dupe(u8, result.error_message) else null,
    };
}

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

pub const BackupResult = struct {
    success: bool,
    message: []const u8,
    backup_id: []const u8,
    backup_type: []const u8,
    size_bytes: u64,
    compression: []const u8,
    checksum: []const u8,

    pub fn deinit(self: *BackupResult, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        allocator.free(self.backup_id);
        allocator.free(self.backup_type);
        allocator.free(self.compression);
        allocator.free(self.checksum);
    }
};

pub const RestoreResult = struct {
    success: bool,
    message: []const u8,
    restore_dir: []const u8,
    target_time: []const u8,
    restore_timestamp: u64,

    pub fn deinit(self: *RestoreResult, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        allocator.free(self.restore_dir);
        allocator.free(self.target_time);
    }
};

pub const UploadBackupResult = struct {
    success: bool,
    message: []const u8,
    upload_path: []const u8,

    pub fn deinit(self: *UploadBackupResult, allocator: std.mem.Allocator) void {
        allocator.free(self.message);
        allocator.free(self.upload_path);
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

    fn drainBytes(self: *QuicProtoClient, len: u64, timeout_ms: u32) !void {
        var remaining: u64 = len;
        var attempts: usize = 0;
        const max_attempts = @max(@as(usize, 1), timeout_ms / 10);
        var buf: [4096]u8 = undefined;

        while (remaining > 0) {
            const chunk: usize = @intCast(@min(remaining, @as(u64, buf.len)));
            const n = self.stream.read(buf[0..chunk]) catch |err| {
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
            remaining -= n;
        }
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

    pub fn cdcControl(self: *QuicProtoClient, allocator: std.mem.Allocator, action: []const u8) !schema.CdcControlResponse {
        try self.ensureHello(allocator);
        const req = schema.CdcControlRequest{ .action = action };
        try self.writeMessage(.{ .cdc_ctrl = req });
        var packet = try self.readPacket(allocator, 5000);
        defer packet.deinit(allocator);
        const msg = packet.quic orelse return error.InvalidMessage;
        if (msg != .cdc_ctrl) return error.InvalidMessage;
        const resp = msg.cdc_ctrl;
        return .{
            .success = resp.success,
            .status = try allocator.dupe(u8, resp.status),
            .guardrail_epoch = resp.guardrail_epoch,
        };
    }

    pub fn backup(self: *QuicProtoClient, allocator: std.mem.Allocator, backup_type: []const u8, compress: bool) !BackupResult {
        try self.ensureHello(allocator);
        const req = schema.BackupRequest{ .backup_type = backup_type, .compress = compress };
        try self.writeMessage(.{ .backup = req });
        var packet = try self.readPacket(allocator, 10000);
        defer packet.deinit(allocator);
        const msg = packet.quic orelse return error.InvalidMessage;
        if (msg != .backup) return error.InvalidMessage;
        const resp = msg.backup;
        if (resp.success and resp.size_bytes > 0) {
            try self.drainBytes(resp.size_bytes, 10000);
        }
        return .{
            .success = resp.success,
            .message = try allocator.dupe(u8, resp.message),
            .backup_id = try allocator.dupe(u8, resp.backup_id),
            .backup_type = try allocator.dupe(u8, resp.backup_type),
            .size_bytes = resp.size_bytes,
            .compression = try allocator.dupe(u8, resp.compression),
            .checksum = try allocator.dupe(u8, resp.checksum),
        };
    }

    pub fn restore(self: *QuicProtoClient, allocator: std.mem.Allocator, target_time: ?[]const u8, confirm: bool) !RestoreResult {
        try self.ensureHello(allocator);
        const req = schema.RestoreRequest{ .target_time = target_time orelse "", .confirm = confirm };
        try self.writeMessage(.{ .restore = req });
        var packet = try self.readPacket(allocator, 10000);
        defer packet.deinit(allocator);
        const msg = packet.quic orelse return error.InvalidMessage;
        if (msg != .restore) return error.InvalidMessage;
        const resp = msg.restore;
        return .{
            .success = resp.success,
            .message = try allocator.dupe(u8, resp.message),
            .restore_dir = try allocator.dupe(u8, resp.restore_dir),
            .target_time = try allocator.dupe(u8, resp.target_time),
            .restore_timestamp = resp.restore_timestamp,
        };
    }

    pub fn uploadBackup(self: *QuicProtoClient, allocator: std.mem.Allocator, size_bytes: u64, checksum: []const u8) !UploadBackupResult {
        try self.ensureHello(allocator);
        const req = schema.UploadBackupRequest{ .size_bytes = size_bytes, .checksum = checksum };
        try self.writeMessage(.{ .upload_backup = req });
        var packet = try self.readPacket(allocator, 5000);
        defer packet.deinit(allocator);
        const msg = packet.quic orelse return error.InvalidMessage;
        if (msg != .upload_backup) return error.InvalidMessage;
        const resp = msg.upload_backup;
        return .{
            .success = resp.success,
            .message = try allocator.dupe(u8, resp.message),
            .upload_path = try allocator.dupe(u8, resp.upload_path),
        };
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
            try rows_list.append(out_row);
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
        const QuicProtocolAdapter = struct {
            client: *QuicProtoClient,

            fn sendClientMessage(
                proto: *query_runner.ProtocolClient,
                alloc: std.mem.Allocator,
                msg: schema.QuicClientMessage,
            ) !void {
                _ = alloc;
                const adapter_self: *@This() = @ptrCast(@alignCast(proto.context));
                try adapter_self.client.writeMessage(msg);
            }

            fn readServerMessage(
                proto: *query_runner.ProtocolClient,
                alloc: std.mem.Allocator,
                timeout_secs: u32,
            ) !schema.QuicServerMessage {
                const adapter_self: *@This() = @ptrCast(@alignCast(proto.context));
                const timeout_ms = @as(u32, @intCast(@max(timeout_secs, 1) * 1000));
                while (true) {
                    const packet = adapter_self.client.readPacket(alloc, timeout_ms) catch |err| {
                        if (err == error.EndOfStream) return error.EndOfStream;
                        return err;
                    };
                    const msg = packet.quic orelse return error.InvalidMessage;
                    switch (msg) {
                        .execute, .pull, .hello => return msg,
                        .ping => {},
                        else => {},
                    }
                }
            }
        };

        var adapter = QuicProtocolAdapter{ .client = self };
        var protocol_client = query_runner.ProtocolClient{
            .context = &adapter,
            .sendClientMessageFn = QuicProtocolAdapter.sendClientMessage,
            .readServerMessageFn = QuicProtocolAdapter.readServerMessage,
        };

        var result = try query_runner.collectQuery(allocator, &protocol_client, .{
            .session_id = self.session_id,
            .query_text = query,
            .format = "json",
            .timeout_secs = 5,
            .page_size = page_size,
            .params = params,
        });
        defer result.deinit();

        return try execResultFromAccumulator(allocator, &result);
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
    stream: std.net.Stream,
    session_id: []const u8 = "",

    pub fn connect(allocator: std.mem.Allocator, addr: []const u8) !GrpcProtoClient {
        const parsed = try parseAddr(addr);
        const deadline = std.time.milliTimestamp() + 10_000;
        var last_err: anyerror = error.ConnectionRefused;
        while (std.time.milliTimestamp() < deadline) {
            const stream = grpc_query_transport.connectPlaintext(allocator, parsed.host, parsed.port, 5, .{}) catch |err| {
                last_err = err;
                std.time.sleep(100 * std.time.ns_per_ms);
                continue;
            };
            return .{
                .allocator = allocator,
                .stream = stream,
            };
        }
        return last_err;
    }

    pub fn deinit(self: *GrpcProtoClient) void {
        self.stream.close();
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

    pub fn hello(self: *GrpcProtoClient, allocator: std.mem.Allocator, username: []const u8, password: []const u8) !HelloResult {
        const resp = try grpc_query_transport.hello(
            allocator,
            self.stream,
            .{
                .username = username,
                .password = password,
            },
            .{},
        );
        defer {
            var resp_copy = resp;
            resp_copy.deinit(allocator);
        }

        grpc_query_transport.drainUnaryStream(allocator, self.stream, .{});

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
            try rows_list.append(out_row);
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
        var adapter = grpc_query_transport.StreamingQueryAdapter{ .stream = self.stream };
        var transport = adapter.asTransport();

        var result = try query_runner.collectQueryWithTransport(allocator, &transport, .{
            .session_id = self.session_id,
            .query_text = query,
            .format = "json",
            .timeout_secs = 5,
            .page_size = page_size,
            .params = params,
        });
        defer result.deinit();

        return try execResultFromAccumulator(allocator, &result);
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
        try list_values.append(.{ .kind = .{ .int_val = .{ .value = v, .kind = .INT } } });
    }
    return .{
        .name = try allocator.dupe(u8, name),
        .value = .{ .kind = .{ .list_val = .{ .values = list_values } } },
    };
}
