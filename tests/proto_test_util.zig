const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");
const test_ports = @import("test_ports.zig");
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

/// A free UDP port for a QUIC listener (`--listen`): bind port 0, read the
/// port the kernel chose, release it. See tests/test_ports.zig (SONNY-6301);
/// a gRPC, metrics or LSP listener is TCP: use `getRandomTcpPort`.
pub fn getRandomPort() !u16 {
    return test_ports.freeUdpPort();
}

/// A free TCP port for a gRPC (`--listen-grpc`), metrics or LSP listener.
pub fn getRandomTcpPort() !u16 {
    return test_ports.freeTcpPort();
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

    /// Environment for smokes that drive the gRPC listener with the
    /// plaintext HTTP/2 `GrpcProtoClient`. The listener is TLS-required and
    /// fail-closed by default, so without this opt-in it refuses the
    /// connection outright (Debug builds only — see
    /// `grpc_server.shouldAllowGrpcPlaintextFallback`).
    pub fn grpcPlaintext() []const []const u8 {
        return &.{
            "GEODE_GRPC_ALLOW_PLAINTEXT_FALLBACK=1",
            "GEODE_QUIC_PASSIVE_TEARDOWN=1",
        };
    }
};

// ============================================================================
// Server Handle
// ============================================================================

/// SONNY-2394 (GAP-0203): non-reaping liveness probe for a spawned child.
/// `waitid(WNOWAIT)` reports an exited (zombie) child without reaping it, so
/// `ServerHandle.deinit`'s wait still works. True while the process has not
/// exited (running OR stopped).
pub fn processAlive(pid: posix.pid_t) bool {
    if (comptime builtin.os.tag != .linux) return true;
    const linux = std.os.linux;
    var info = std.mem.zeroes(linux.siginfo_t);
    const rc = linux.waitid(.PID, pid, &info, linux.W.EXITED | linux.W.NOHANG | linux.W.NOWAIT, null);
    if (linux.errno(rc) != .SUCCESS) return false; // ECHILD: not a live child of ours
    return info.fields.common.first.piduid.pid == 0; // no exit reported yet
}

pub const ServerHandle = struct {
    allocator: std.mem.Allocator,
    threaded: std.Io.Threaded,
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
        const io = self.threaded.io();
        // CANARY: REQ=REQ-QUIC-HC-057; FEATURE="QUIC High-Concurrency Requests"; ASPECT=StressHarnessTeardown; STATUS=IMPL; TEST=test-quic-high-concurrency-e2e; OWNER=transport; UPDATED=2026-05-26
        //
        // High-fanout failure cases can leave the server's graceful shutdown
        // path waiting on a stuck pool worker after SIGTERM. The E2E harness is
        // isolating a throwaway data dir, so teardown must hard-stop the child
        // and reap it instead of letting a failed stress run hang the build.
        if (self.child.id) |pid| {
            posix.kill(pid, .KILL) catch {};
            _ = self.child.wait(io) catch {};
        }
        self.threaded.deinit();
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
// Use the target-specific clock and sleep backend on Linux and macOS.
fn compat_milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    const rc = if (comptime @import("builtin").os.tag == .linux)
        std.os.linux.clock_gettime(.REALTIME, &ts)
    else
        std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    if (rc != 0) return 0;
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
fn compat_monoNs() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    const rc = if (comptime @import("builtin").os.tag == .linux)
        std.os.linux.clock_gettime(.MONOTONIC, &ts)
    else
        std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    if (rc != 0) return 0;
    const sec: u64 = if (ts.sec < 0) 0 else @intCast(ts.sec);
    const nsec: u64 = if (ts.nsec < 0) 0 else @intCast(ts.nsec);
    return sec * std.time.ns_per_s + nsec;
}
fn compat_sleep(ns: u64) void {
    std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(ns), .awake) catch {};
}

/// Wait for the gRPC server to be ready by attempting a raw TCP connection.
/// Does NOT do a full QUIC handshake — use for gRPC-only server instances.
pub fn waitForGrpcServerReady(allocator: std.mem.Allocator, addr: []const u8, timeout_ms: u64) !void {
    _ = allocator;
    const parsed = try parseAddr(addr);
    const start = compat_milliTimestamp();
    const deadline = start + @as(i64, @intCast(timeout_ms));
    const io = std.Io.Threaded.global_single_threaded.io();
    while (compat_milliTimestamp() < deadline) {
        const ip_addr = std.Io.net.IpAddress.parse(parsed.host, parsed.port) catch |err| {
            return err;
        };
        const stream = std.Io.net.IpAddress.connect(&ip_addr, io, .{ .mode = .stream }) catch {
            compat_sleep(100 * std.time.ns_per_ms);
            continue;
        };
        stream.close(io);
        return;
    }
    return error.ServerStartupTimeout;
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
    const args = &[_][]const u8{ geode_test_bin.geode_exe, "serve", "--listen", addr };
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

fn isTruthyEnvValue(value: []const u8) bool {
    if (value.len == 0) return false;
    if (std.mem.eql(u8, value, "0")) return false;
    if (std.ascii.eqlIgnoreCase(value, "false")) return false;
    if (std.ascii.eqlIgnoreCase(value, "no")) return false;
    if (std.ascii.eqlIgnoreCase(value, "off")) return false;
    return true;
}

/// True when `args` already carries `flag`, in either the `--flag value` or
/// `--flag=value` spelling.
fn hasFlag(args: []const []const u8, flag: []const u8) bool {
    for (args) |a| {
        if (std.mem.eql(u8, a, flag)) return true;
        if (a.len > flag.len and std.mem.startsWith(u8, a, flag) and a[flag.len] == '=') return true;
    }
    return false;
}

fn envPairsContainTruthy(pairs: ?[]const []const u8, name: []const u8) bool {
    if (pairs) |items| {
        for (items) |kv| {
            const eq = std.mem.indexOfScalar(u8, kv, '=') orelse continue;
            if (std.mem.eql(u8, kv[0..eq], name) and isTruthyEnvValue(kv[eq + 1 ..])) {
                return true;
            }
        }
    }
    return false;
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
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    errdefer threaded.deinit();
    const io = threaded.io();

    // Use the startup environment on every host. /proc/self/environ is
    // Linux-only; reading it on macOS silently gave child servers an empty
    // environment, dropping HOME, PATH and the requested startup diagnostics.
    var map = try std.Io.Threaded.global_single_threaded.environ.process_environ.createMap(allocator);
    errdefer map.deinit();

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

    // CANARY: REQ=REQ-ENG-3921-DATA-DIR-LOCK-004; FEATURE="DataDirLock"; ASPECT=HermeticTestDataDir; STATUS=TESTED; TEST=test-transport-parity; OWNER=storage; UPDATED=2026-08-29
    //
    // ENG-3921: a `geode serve` with neither `--data-dir` nor GEODE_DATA_DIR
    // resolves to `/tmp` (graph_store.getPersistenceFilePath). Every smoke
    // spawned from here therefore used to share ONE on-disk store, and the
    // build runs sibling smokes in parallel — i.e. the harness was relying on
    // exactly the split-brain the data-dir lock now forbids, and a second
    // concurrent smoke is refused with "data directory is locked by pid".
    //
    // Give each TEST PROCESS its own data dir. Per-process (not per-spawn) is
    // deliberate: tests that stop a server and start another one to assert
    // durability still see the same store, while sibling test binaries no
    // longer collide. An explicit `--data-dir` argument or a caller/parent
    // GEODE_DATA_DIR always wins.
    //
    // SONNY-2413: the dir lives under the process's scratch root, which is
    // removed when the test process exits (it used to be `/tmp/geode-test-<pid>`,
    // which nothing ever removed).
    if (map.get("GEODE_DATA_DIR") == null and !hasFlag(args, "--data-dir")) {
        var dir_buf: [192]u8 = undefined;
        const test_data_dir = try std.fmt.bufPrint(&dir_buf, "{s}/data", .{try test_scratch.processRoot()});
        try std.Io.Dir.cwd().createDirPath(io, test_data_dir);
        try map.put("GEODE_DATA_DIR", test_data_dir);
    }

    // CANARY: REQ=REQ-QUIC-HC-024; FEATURE="QUIC High-Concurrency Diagnostics"; ASPECT=ServerStderrPassThrough; STATUS=TESTED; TEST=test-quic-high-concurrency-e2e; OWNER=transport; UPDATED=2026-05-26
    //
    // High-fanout QUIC regressions often show up first as server-side handoff
    // warnings. Keep the default quiet for ordinary tests, but allow focused
    // stress runs to inherit child stderr/stdout without switching to pipes
    // that can block if the server logs heavily.
    const inherit_server_stdio = envPairsContainTruthy(env, "GEODE_TEST_INHERIT_SERVER_STDERR") or blk: {
        if (map.get("GEODE_TEST_INHERIT_SERVER_STDERR")) |value| {
            break :blk isTruthyEnvValue(value);
        }
        break :blk false;
    };

    const child = try std.process.spawn(io, .{
        .argv = args,
        .environ_map = &map,
        // Zig 0.16: SpawnOptions renamed `*_behavior` to bare
        // `stdin` / `stdout` / `stderr` of `StdIo` enum.
        .stdin = .ignore,
        .stdout = if (inherit_server_stdio) .inherit else .ignore,
        .stderr = if (inherit_server_stdio) .inherit else .ignore,
    });

    return ServerHandle{
        .allocator = allocator,
        .threaded = threaded,
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
    /// The schema frame's column types, parallel to `columns` ("ANY" when the
    /// frame left a type empty). SONNY-1221: `execResultsEqual` ignores them.
    column_types: [][]const u8 = &.{},
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
        for (self.column_types) |t| allocator.free(t);
        allocator.free(self.column_types);
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

    var column_types = try allocator.alloc([]const u8, result.columns.items.len);
    var types_done: usize = 0;
    errdefer {
        for (column_types[0..types_done]) |t| allocator.free(t);
        allocator.free(column_types);
    }
    for (result.columns.items) |column| {
        column_types[types_done] = try allocator.dupe(u8, column.type);
        types_done += 1;
    }

    return .{
        .status_class = try allocator.dupe(u8, result.status_class),
        .additional_statuses = try dupeStringSliceList(allocator, result.additional_statuses.items),
        .flagger_findings = try dupeStringSliceList(allocator, result.flagger_findings.items),
        .columns = columns,
        .column_types = column_types,
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
    read_wait_misses: u32 = 0,
    post_write_poll: bool = true,
    /// SONNY-2394 (GAP-0203): the spawned server this client talks to (see
    /// `watchServerLiveness`).
    server_pid: ?posix.pid_t = null,
    /// SONNY-6301: the loopback address the server listens on, set by
    /// `connect`. With no `server_pid`, whether a socket still holds this
    /// UDP port is the liveness signal (the kernel releases a process's
    /// ports when it exits). null (not a loopback IP literal) = plain fixed
    /// per-reply deadlines.
    server_addr: ?std.Io.net.IpAddress = null,
    slow_server_reported: bool = false,
    liveness_checked_ns: u64 = 0,

    // CANARY: REQ=REQ-QUIC-HC-154; FEATURE="QUIC High-Concurrency Diagnostics"; ASPECT=ClientExecutePhaseTiming; STATUS=IMPL; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-05-29
    //
    // E2E ceiling probes need phase timing without changing the wire protocol:
    // request write cost, first-response wait/read cost, and total response
    // read time. The harness aggregates these counters across thousands of
    // clients to localize timeout tails.
    pub const ExecTiming = struct {
        execute_write_start_ns: u64 = 0,
        execute_write_ns: u64 = 0,
        execute_prepare_ns: u64 = 0,
        execute_stream_write_ns: u64 = 0,
        execute_post_write_poll_ns: u64 = 0,
        first_response_wait_ns: u64 = 0,
        first_response_read_ns: u64 = 0,
        response_read_ns: u64 = 0,
        response_messages: u32 = 0,
        timed_out_before_first_response: bool = false,
        total_ns: u64 = 0,
    };

    const MessageWriteTiming = struct {
        total_ns: u64 = 0,
        prepare_ns: u64 = 0,
        stream_write_ns: u64 = 0,
        post_write_poll_ns: u64 = 0,
    };

    pub fn connect(allocator: std.mem.Allocator, addr: []const u8) !QuicProtoClient {
        return connectWithHandshakeTimeout(allocator, addr, 5);
    }

    // CANARY: REQ=REQ-QUIC-HC-031; FEATURE="QUIC High-Concurrency Setup"; ASPECT=HandshakeTimeout; STATUS=IMPL; TEST=test-quic-high-concurrency-e2e; OWNER=transport; UPDATED=2026-05-26
    pub fn connectWithHandshakeTimeout(allocator: std.mem.Allocator, addr: []const u8, handshake_timeout_secs: u32) !QuicProtoClient {
        const parsed = try parseAddr(addr);
        var client = quic.QuicClient.init(allocator);
        errdefer client.deinit();

        client.connectInsecure(parsed.host, parsed.port, true) catch |err| {
            return err;
        };
        try client.waitForHandshake(@max(handshake_timeout_secs, 1));
        const stream = try client.getStream();
        return .{ .allocator = allocator, .client = client, .stream = stream, .server_addr = livenessAddr(parsed) };
    }

    /// SONNY-6301: the server address to probe for liveness, when it is a
    /// loopback IP literal (or `localhost`): every reply wait on such a
    /// client then waits for a live server past its deadline.
    fn livenessAddr(parsed: Addr) ?std.Io.net.IpAddress {
        const ip = if (std.mem.eql(u8, parsed.host, "localhost"))
            std.Io.net.IpAddress{ .ip4 = std.Io.net.Ip4Address.loopback(parsed.port) }
        else
            std.Io.net.IpAddress.parse(parsed.host, parsed.port) catch return null;
        return if (test_ports.isLoopback(ip)) ip else null;
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

    pub fn writeMessage(self: *QuicProtoClient, msg: schema.QuicClientMessage) !void {
        try self.writeMessageTimed(msg, null);
    }

    fn writeMessageTimed(
        self: *QuicProtoClient,
        msg: schema.QuicClientMessage,
        timing: ?*MessageWriteTiming,
    ) !void {
        const start_ns = compat_monoNs();
        var measured = MessageWriteTiming{};
        defer {
            measured.total_ns = compat_monoNs() -| start_ns;
            if (timing) |out| out.* = measured;
        }

        var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(self.allocator, 4096);
        defer aw.deinit();

        const packet = schema.ClientPacket{ .quic = msg };
        try protobuf.encode(&aw.writer, self.allocator, packet);

        const body = aw.writer.buffer[0..aw.writer.end];
        // CANARY: REQ=REQ-QUIC-HC-043; FEATURE="QUIC High-Concurrency Client"; ASPECT=SinglePacketFramedWrites; STATUS=IMPL; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-05-26
        // Keep the length prefix and protobuf body in one stream write. The
        // QUIC stream writer emits one packet per write call for small payloads;
        // splitting the frame doubles the UDP burst during high-fanout query
        // starts and makes the server recover avoidable packet loss.
        const framed = try self.allocator.alloc(u8, 4 + body.len);
        defer self.allocator.free(framed);
        std.mem.writeInt(u32, framed[0..4], @intCast(body.len), .big);
        @memcpy(framed[4..], body);
        const prepared_ns = compat_monoNs();
        measured.prepare_ns = prepared_ns -| start_ns;
        try self.stream.writeAll(framed);
        const stream_written_ns = compat_monoNs();
        measured.stream_write_ns = stream_written_ns -| prepared_ns;
        // CANARY: REQ=REQ-QUIC-HC-041; FEATURE="QUIC High-Concurrency Client"; ASPECT=PostWriteFlush; STATUS=IMPL; TEST=test-quic-high-concurrency-e2e; OWNER=transport; UPDATED=2026-05-26
        // writeStream queues frames on the client endpoint. In high-fanout
        // tests, waiting until the first response read WouldBlock to poll the
        // endpoint can leave hundreds of EXECUTE frames unflushed for one
        // scheduler turn. Poll once after every framed write so request data
        // is visible to the server before the caller waits for a response.
        if (self.post_write_poll) {
            try self.client.poll(0);
            measured.post_write_poll_ns = compat_monoNs() -| stream_written_ns;
        }
    }

    pub fn dumpTransportDiagnostics(self: *QuicProtoClient, worker_id: u32, op: usize) void {
        const conn = self.client.connection orelse {
            std.debug.print(
                "high-concurrency QUIC client diag worker={d} op={d} connection=null\n",
                .{ worker_id, op },
            );
            return;
        };
        const endpoint = self.client.endpoint;
        const cc = conn.rec.getCongestionState();
        var first_retx_pn: u64 = 0;
        var first_retx_stream: u64 = 0;
        var first_retx_off: u64 = 0;
        var first_retx_len: usize = 0;
        var first_retx_attempts: u16 = 0;
        if (conn.app_stream_retx_init) {
            var it = conn.app_stream_retx.iterator();
            while (it.next()) |entry| {
                if (first_retx_len == 0 or entry.key_ptr.* < first_retx_pn) {
                    first_retx_pn = entry.key_ptr.*;
                    first_retx_stream = entry.value_ptr.stream_id;
                    first_retx_off = entry.value_ptr.offset;
                    first_retx_len = entry.value_ptr.data.len;
                    first_retx_attempts = entry.value_ptr.retransmit_count;
                }
            }
        }
        std.debug.print(
            "high-concurrency QUIC client diag worker={d} op={d} local_port={d} stream={d} pn_app_tx={d} stream_send_off={d} conn_send_off={d} retx={d} first_retx_pn={d} first_retx_stream={d} first_retx_off={d} first_retx_len={d} first_retx_attempts={d} pto_active={} pto_count={d} pto_dirty={} endpoint_dirty={d} timers={d} bif={d} cwnd={d} rx_gen={d} tx_credit_gen={d}\n",
            .{
                worker_id,
                op,
                self.client.debugLocalPort(),
                self.stream.stream_id,
                conn.pn_app_tx,
                conn.stream_send_off,
                conn.conn_send_off,
                if (conn.app_stream_retx_init) conn.app_stream_retx.count() else 0,
                first_retx_pn,
                first_retx_stream,
                first_retx_off,
                first_retx_len,
                first_retx_attempts,
                conn.pto_app_active,
                conn.pto_app_count,
                conn.pto_dirty.load(.acquire),
                if (endpoint) |ep| ep.pto_dirty_count.load(.acquire) else 0,
                if (endpoint) |ep| ep.timers.items.len else 0,
                cc.bytes_in_flight,
                cc.cwnd,
                conn.rx_data_generation.load(.acquire),
                conn.tx_credit_generation.load(.acquire),
            },
        );
    }

    fn resetReadWaitMisses(self: *QuicProtoClient) void {
        self.read_wait_misses = 0;
    }

    // CANARY: REQ=REQ-QUIC-HC-005; FEATURE="QUIC High-Concurrency Client Wait"; ASPECT=ProtoReadDeadline; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-05-25
    /// SONNY-2394 (GAP-0203 Fix #4 flake): bind this client to the server
    /// process it talks to. Every reply wait then treats its timeout as a SOFT
    /// deadline: once it expires, the wait continues in 1 s slices for as long
    /// as the server process is alive (running or stopped), up to
    /// `liveness_cap_ns`. A live-but-slow server -- a Debug build doing real
    /// work (first-touch graph creation on COMMIT, Argon2id on HELLO) under
    /// parallel test load -- is waited for instead of failing at a fixed 5 s;
    /// a server that EXITED fails immediately with error.ServerExited; a
    /// genuine hang still fails at the cap.
    ///
    /// SONNY-6301: a client `connect`ed to a loopback address gets the same
    /// behaviour without this call, probing whether the server still holds
    /// its UDP port (`server_addr`). The pid is the more precise signal (a
    /// port can be held by a process other than the server); bind it when
    /// the test has it.
    pub fn watchServerLiveness(self: *QuicProtoClient, pid: posix.pid_t) void {
        self.server_pid = pid;
    }

    /// The longest a reply wait extends past its deadline for a live server.
    /// SONNY-6301: 120 s (was 60 s); minutes, because a loaded Debug server
    /// running Argon2id, CREATE GRAPH or a backup's per-file fsyncs answers
    /// in tens of seconds, and a dead one fails at once regardless.
    pub const liveness_cap_ns: u64 = 120 * std.time.ns_per_s;

    fn livenessBound(self: *const QuicProtoClient) bool {
        return self.server_pid != null or self.server_addr != null;
    }

    /// The bound server is gone: its pid exited or, with no pid, nothing
    /// holds its port any more. An inconclusive port probe is not "gone".
    fn serverGone(self: *const QuicProtoClient) bool {
        if (self.server_pid) |pid| return !processAlive(pid);
        if (self.server_addr) |addr| return test_ports.udpPortHeld(addr) == .free;
        return false;
    }

    const ReadDeadline = struct {
        soft_ns: u64,
        hard_ns: u64,

        fn init(self: *const QuicProtoClient, timeout_ms: u32) ReadDeadline {
            const now = compat_monoNs();
            const soft = now + @as(u64, timeout_ms) * std.time.ns_per_ms;
            return .{ .soft_ns = soft, .hard_ns = if (self.livenessBound()) @max(soft, now + liveness_cap_ns) else soft };
        }
    };

    /// The soft deadline expired: extend it by one slice if the bound server is
    /// still alive and the liveness cap has not been reached.
    fn extendReadDeadline(self: *QuicProtoClient, deadline: *ReadDeadline) !void {
        if (!self.livenessBound()) return error.Timeout;
        if (self.serverGone()) return error.ServerExited;
        const now = compat_monoNs();
        if (now >= deadline.hard_ns) {
            std.debug.print("QuicProtoClient: no reply from a live server within the {d} s liveness cap\n", .{liveness_cap_ns / std.time.ns_per_s});
            return error.Timeout;
        }
        if (!self.slow_server_reported) {
            self.slow_server_reported = true;
            if (self.server_pid) |pid| {
                std.debug.print("QuicProtoClient: server pid {d} is alive but slow; waiting past the reply deadline (cap {d} s)\n", .{ pid, liveness_cap_ns / std.time.ns_per_s });
            } else {
                std.debug.print("QuicProtoClient: server on port {d} is alive but slow; waiting past the reply deadline (cap {d} s)\n", .{ self.server_addr.?.getPort(), liveness_cap_ns / std.time.ns_per_s });
            }
        }
        deadline.soft_ns = @min(now + std.time.ns_per_s, deadline.hard_ns);
    }

    fn waitForReadProgress(self: *QuicProtoClient, deadline: *ReadDeadline) !void {
        // A bound server that has EXITED fails the wait at once (probed at most
        // every 100 ms) instead of burning the rest of the reply deadline.
        if (self.livenessBound()) {
            const now = compat_monoNs();
            if (now -| self.liveness_checked_ns >= 100 * std.time.ns_per_ms) {
                self.liveness_checked_ns = now;
                if (self.serverGone()) return error.ServerExited;
            }
        }
        if (compat_monoNs() >= deadline.soft_ns) try self.extendReadDeadline(deadline);
        // CANARY: REQ=REQ-QUIC-HC-149; FEATURE="High-Concurrency Test Client"; ASPECT=AdaptiveReadPolling; STATUS=IMPL; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-05-29
        //
        // In 1024+ local-client runs, a fixed 1ms poll per WouldBlock makes
        // early responses wait behind the driver. At 4096+ lower-stagger runs,
        // a fixed 100us poll turns thousands of same-process client threads
        // into a CPU storm that can starve the child server. Poll immediately,
        // then use a bounded adaptive park until bytes arrive and reset the
        // miss counter.
        try self.client.poll(0);
        // SONNY-6374: a connection the server closed (a refused admission
        // sends CONNECTION_CLOSE) can deliver nothing more. The stream read
        // reports WouldBlock regardless, so without this check a live
        // server's refusal ran out the whole liveness cap (120 s).
        if (self.client.isClosed()) return error.ConnectionClosed;
        const now_ns = compat_monoNs();
        if (now_ns >= deadline.soft_ns) return self.extendReadDeadline(deadline);
        self.read_wait_misses +|= 1;
        const wait_ns: u64 = if (self.read_wait_misses <= 32)
            100 * std.time.ns_per_us
        else if (self.read_wait_misses <= 128)
            250 * std.time.ns_per_us
        else
            std.time.ns_per_ms;
        compat_sleep(@min(wait_ns, deadline.soft_ns - now_ns));
    }

    pub fn readPacket(self: *QuicProtoClient, allocator: std.mem.Allocator, timeout_ms: u32) !schema.ServerPacket {
        var len_buf: [4]u8 = undefined;
        var total_read: usize = 0;
        var deadline = ReadDeadline.init(self, timeout_ms);

        while (total_read < 4) {
            const n = self.stream.read(len_buf[total_read..]) catch |err| {
                if (err == error.WouldBlock) {
                    try self.waitForReadProgress(&deadline);
                    continue;
                }
                return err;
            };
            if (n == 0) return error.EndOfStream;
            self.resetReadWaitMisses();
            total_read += n;
        }

        const msg_len = std.mem.readInt(u32, &len_buf, .big);
        if (msg_len > 16 * 1024 * 1024) return error.MessageTooLarge;

        const msg_bytes = try allocator.alloc(u8, msg_len);
        defer allocator.free(msg_bytes);

        total_read = 0;
        while (total_read < msg_len) {
            const n = self.stream.read(msg_bytes[total_read..]) catch |err| {
                if (err == error.WouldBlock) {
                    try self.waitForReadProgress(&deadline);
                    continue;
                }
                return err;
            };
            if (n == 0) return error.EndOfStream;
            self.resetReadWaitMisses();
            total_read += n;
        }

        var reader: std.Io.Reader = .fixed(msg_bytes);
        const packet = try protobuf.decode(schema.ServerPacket, &reader, allocator);
        // CANARY: REQ=REQ-QUIC-HC-120; FEATURE="High-Concurrency Test Client"; ASPECT=PostReadAckFlush; STATUS=IMPL; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-05-27
        //
        // Client poll() processes inbound STREAM packets and queues ACK state.
        // High-fanout tests keep completed clients parked at a barrier; without
        // one post-read flush those ACKs can sit until teardown, forcing the
        // server into PTO retransmits for responses the client already read.
        try self.client.poll(0);
        return packet;
    }

    fn drainBytes(self: *QuicProtoClient, len: u64, timeout_ms: u32) !void {
        var remaining: u64 = len;
        var deadline = ReadDeadline.init(self, timeout_ms);
        var buf: [4096]u8 = undefined;

        while (remaining > 0) {
            const chunk: usize = @intCast(@min(remaining, @as(u64, buf.len)));
            const n = self.stream.read(buf[0..chunk]) catch |err| {
                if (err == error.WouldBlock) {
                    try self.waitForReadProgress(&deadline);
                    continue;
                }
                return err;
            };
            if (n == 0) return error.EndOfStream;
            self.resetReadWaitMisses();
            remaining -= n;
        }
    }

    pub fn hello(self: *QuicProtoClient, allocator: std.mem.Allocator, username: []const u8, password: []const u8) !HelloResult {
        return self.helloWithTimeout(allocator, username, password, 5000);
    }

    pub fn helloWithTimeout(self: *QuicProtoClient, allocator: std.mem.Allocator, username: []const u8, password: []const u8, timeout_ms: u32) !HelloResult {
        const req = schema.HelloRequest{
            .username = username,
            .password = password,
            .tenant_id = null,
            .client_name = "geode-test",
            .client_version = "0.0.0",
            .wanted_conformance = "min",
        };
        try self.writeMessage(.{ .hello = req });

        var packet = try self.readPacket(allocator, timeout_ms);
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

    /// GAP-0514: drive the QUIC SAVEPOINT dispatch lane
    /// (quic_connection_handler.zig REQ-TXN-SAVEPOINT-004).
    pub fn savepoint(self: *QuicProtoClient, allocator: std.mem.Allocator, name: []const u8) !bool {
        const req = schema.SavepointRequest{ .name = name, .session_id = "" };
        try self.writeMessage(.{ .savepoint = req });
        var packet = try self.readPacket(allocator, 5000);
        defer packet.deinit(allocator);
        const msg = packet.quic orelse return error.InvalidMessage;
        if (msg != .savepoint) return error.InvalidMessage;
        return msg.savepoint.success;
    }

    /// GAP-0514: drive the QUIC ROLLBACK TO dispatch lane
    /// (quic_connection_handler.zig REQ-TXN-SAVEPOINT-005).
    pub fn rollbackTo(self: *QuicProtoClient, allocator: std.mem.Allocator, name: []const u8) !bool {
        const req = schema.RollbackToRequest{ .name = name, .session_id = "" };
        try self.writeMessage(.{ .rollback_to = req });
        var packet = try self.readPacket(allocator, 5000);
        defer packet.deinit(allocator);
        const msg = packet.quic orelse return error.InvalidMessage;
        if (msg != .rollback_to) return error.InvalidMessage;
        return msg.rollback_to.success;
    }

    /// GAP-0514: HELLO carrying a graph binding — drives the QUIC graph
    /// resolution + graph-RBAC bind lanes (REQ-DSN-GRAPH-BIND-003,
    /// REQ-MULTI-GRAPH-RBAC-WIRE-002).
    pub fn helloWithGraph(
        self: *QuicProtoClient,
        allocator: std.mem.Allocator,
        username: []const u8,
        password: []const u8,
        graph: ?[]const u8,
    ) !HelloResult {
        return self.helloWith(allocator, username, password, graph, null);
    }

    /// HELLO binding a graph and a tenant scope (null: the server's default
    /// graph, an unscoped session). SONNY-2724 drives tenant-scoped QUIC
    /// sessions through it.
    pub fn helloWith(
        self: *QuicProtoClient,
        allocator: std.mem.Allocator,
        username: []const u8,
        password: []const u8,
        graph: ?[]const u8,
        tenant: ?[]const u8,
    ) !HelloResult {
        return self.helloFull(allocator, username, password, graph, tenant, null);
    }

    /// HELLO naming an FLE role (HelloRequest.role; SONNY-6334).
    pub fn helloAs(
        self: *QuicProtoClient,
        allocator: std.mem.Allocator,
        username: []const u8,
        password: []const u8,
        fle_role: []const u8,
    ) !HelloResult {
        return self.helloFull(allocator, username, password, null, null, fle_role);
    }

    fn helloFull(
        self: *QuicProtoClient,
        allocator: std.mem.Allocator,
        username: []const u8,
        password: []const u8,
        graph: ?[]const u8,
        tenant: ?[]const u8,
        fle_role: ?[]const u8,
    ) !HelloResult {
        const req = schema.HelloRequest{
            .username = username,
            .password = password,
            .tenant_id = tenant,
            .client_name = "geode-test",
            .client_version = "0.0.0",
            .wanted_conformance = "min",
            .graph = graph,
            .role = fle_role,
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
        return self.executeAndCollectWithTimeout(allocator, query, params, page_size, 5);
    }

    // CANARY: REQ=REQ-QUIC-HC-023; FEATURE="QUIC High-Concurrency Diagnostics"; ASPECT=ClientExecTimeout; STATUS=TESTED; TEST=test_quic_condition_timedwait_cadence; OWNER=transport; UPDATED=2026-05-26
    pub fn executeAndCollectWithTimeout(
        self: *QuicProtoClient,
        allocator: std.mem.Allocator,
        query: []const u8,
        params: std.ArrayList(schema.Param),
        page_size: u32,
        query_timeout_secs: u32,
    ) !ExecResult {
        return self.executeAndCollectWithTimeoutTiming(allocator, query, params, page_size, query_timeout_secs, null);
    }

    pub fn executeAndCollectWithTimeoutTiming(
        self: *QuicProtoClient,
        allocator: std.mem.Allocator,
        query: []const u8,
        params: std.ArrayList(schema.Param),
        page_size: u32,
        query_timeout_secs: u32,
        timing: ?*ExecTiming,
    ) !ExecResult {
        if (timing) |stats| stats.* = .{};
        const total_start_ns = compat_monoNs();
        try self.ensureHello(allocator);
        const QuicProtocolAdapter = struct {
            client: *QuicProtoClient,
            timing: ?*ExecTiming = null,
            execute_write_done_ns: u64 = 0,
            response_messages: u32 = 0,

            fn sendClientMessage(
                proto: *query_runner.ProtocolClient,
                alloc: std.mem.Allocator,
                msg: schema.QuicClientMessage,
            ) !void {
                _ = alloc;
                const adapter_self: *@This() = @ptrCast(@alignCast(proto.context));
                const write_start_ns = compat_monoNs();
                var write_timing = MessageWriteTiming{};
                try adapter_self.client.writeMessageTimed(msg, &write_timing);
                const write_end_ns = compat_monoNs();
                if (adapter_self.timing) |stats| {
                    switch (msg) {
                        .execute => {
                            stats.execute_write_start_ns = write_start_ns;
                            stats.execute_write_ns +|= write_end_ns -| write_start_ns;
                            stats.execute_prepare_ns +|= write_timing.prepare_ns;
                            stats.execute_stream_write_ns +|= write_timing.stream_write_ns;
                            stats.execute_post_write_poll_ns +|= write_timing.post_write_poll_ns;
                            adapter_self.execute_write_done_ns = write_end_ns;
                        },
                        else => {},
                    }
                }
            }

            fn readServerMessage(
                proto: *query_runner.ProtocolClient,
                alloc: std.mem.Allocator,
                read_timeout_secs: u32,
            ) !schema.QuicServerMessage {
                const adapter_self: *@This() = @ptrCast(@alignCast(proto.context));
                const timeout_ms = @as(u32, @intCast(@max(read_timeout_secs, 1) * 1000));
                while (true) {
                    const read_start_ns = compat_monoNs();
                    const packet = adapter_self.client.readPacket(alloc, timeout_ms) catch |err| {
                        const read_end_ns = compat_monoNs();
                        if (adapter_self.timing) |stats| {
                            stats.response_read_ns +|= read_end_ns -| read_start_ns;
                            if (adapter_self.response_messages == 0 and adapter_self.execute_write_done_ns != 0) {
                                stats.first_response_wait_ns = read_end_ns -| adapter_self.execute_write_done_ns;
                                stats.first_response_read_ns = read_end_ns -| read_start_ns;
                                if (err == error.Timeout) stats.timed_out_before_first_response = true;
                            }
                        }
                        if (err == error.EndOfStream) return error.EndOfStream;
                        return err;
                    };
                    const read_end_ns = compat_monoNs();
                    if (adapter_self.timing) |stats| {
                        stats.response_read_ns +|= read_end_ns -| read_start_ns;
                        if (adapter_self.response_messages == 0 and adapter_self.execute_write_done_ns != 0) {
                            stats.first_response_wait_ns = read_end_ns -| adapter_self.execute_write_done_ns;
                            stats.first_response_read_ns = read_end_ns -| read_start_ns;
                        }
                        stats.response_messages +|= 1;
                    }
                    adapter_self.response_messages +|= 1;
                    const msg = packet.quic orelse return error.InvalidMessage;
                    switch (msg) {
                        .execute, .pull, .hello => return msg,
                        .ping => {},
                        else => {},
                    }
                }
            }
        };

        var adapter = QuicProtocolAdapter{ .client = self, .timing = timing };
        var protocol_client = query_runner.ProtocolClient{
            .context = &adapter,
            .sendClientMessageFn = QuicProtocolAdapter.sendClientMessage,
            .readServerMessageFn = QuicProtocolAdapter.readServerMessage,
        };

        var result = query_runner.collectQuery(allocator, &protocol_client, .{
            .session_id = self.session_id,
            .query_text = query,
            .format = "json",
            .timeout_secs = query_timeout_secs,
            .page_size = page_size,
            .params = params,
        }) catch |err| {
            if (timing) |stats| stats.total_ns = compat_monoNs() -| total_start_ns;
            return err;
        };
        defer result.deinit();
        if (timing) |stats| stats.total_ns = compat_monoNs() -| total_start_ns;

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
            .params = std.ArrayList(schema.Param).empty,
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
    stream: std.Io.net.Stream,
    session_id: []const u8 = "",

    /// SONNY-6301: the socket read/write timeout. It was 5 s, so a loaded
    /// server answering in 6 s failed the test. TCP reports a server that
    /// exited at once (the kernel closes its connections: EOF or reset), so
    /// a long timeout waits only for a live server, the same contract as
    /// `QuicProtoClient.liveness_cap_ns`.
    pub const read_timeout_secs: u32 = @intCast(QuicProtoClient.liveness_cap_ns / std.time.ns_per_s);

    pub fn connect(allocator: std.mem.Allocator, addr: []const u8) !GrpcProtoClient {
        const parsed = try parseAddr(addr);
        const deadline = compat_milliTimestamp() + 10_000;
        var last_err: anyerror = error.ConnectionRefused;
        while (compat_milliTimestamp() < deadline) {
            const stream = grpc_query_transport.connectPlaintext(allocator, parsed.host, parsed.port, read_timeout_secs, .{}) catch |err| {
                last_err = err;
                compat_sleep(100 * std.time.ns_per_ms);
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
        self.stream.close(std.Io.Threaded.global_single_threaded.io());
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

    /// gRPC HELLO carrying a graph binding — mirrors QuicProtoClient.helloWithGraph
    /// for transport-parity tests. Connects with username/password and requests the
    /// named graph in the HelloRequest.
    pub fn helloWithGraph(
        self: *GrpcProtoClient,
        allocator: std.mem.Allocator,
        username: []const u8,
        password: []const u8,
        graph: []const u8,
    ) !HelloResult {
        const resp = try grpc_query_transport.hello(
            allocator,
            self.stream,
            .{
                .username = username,
                .password = password,
                .graph = graph,
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
    return std.ArrayList(schema.Param).empty;
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
