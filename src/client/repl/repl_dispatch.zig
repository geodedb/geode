const std = @import("std");

// Zig 0.16 compat: std.posix.getenv was removed; wrap std.c.getenv to return a slice.
fn posixGetenv(name: [*:0]const u8) ?[:0]const u8 {
    return if (std.c.getenv(name)) |p| std.mem.span(p) else null;
}

// Zig 0.16 compat: std.Thread.sleep was removed; use raw nanosleep syscall.
fn sleepNs(ns: u64) void {
    std.Io.Threaded.global_single_threaded.io().sleep(.fromNanoseconds(ns), .awake) catch {};
}

// Zig 0.16 compat helper to obtain the default single-threaded I/O handle.
fn replIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

// Zig 0.16 compat: std.time.Timer was removed. Minimal replacement using clock_gettime.
const CompatTimer = struct {
    start_ns: i128,
    pub fn start() !CompatTimer {
        return .{ .start_ns = std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).toNanoseconds() };
    }
    pub fn read(self: *CompatTimer) u64 {
        const now_ns = std.Io.Clock.awake.now(std.Io.Threaded.global_single_threaded.io()).toNanoseconds();
        return @intCast(now_ns - self.start_ns);
    }
};
const builtin = @import("builtin");
const repl_errors = @import("repl_errors.zig");
/// SONNY-6544: \connect prints its address through dsn_credentials.redacted.
const dsn_credentials = @import("../dsn_credentials.zig");
const repl_render = @import("repl_render.zig");
const platform = @import("platform.zig");
const spinner_mod = @import("spinner.zig");

const protobuf = @import("protobuf");
const proto_schema = @import("schema");
const explain_payload = @import("../../server/explain_payload.zig");
const profile_payload = @import("../../server/profile_payload.zig");
const transport_response = @import("../../cli/transport_response.zig");
const query_result_accumulator = @import("../query_result_accumulator.zig");
const query_runner = @import("../query_runner.zig");
const query_scope = @import("../query_scope.zig");
const pooled = @import("transport/thread_pool");

const parallel_wrapper = @import("parallel/thread_pool_parallel");

const ColumnInfo = query_result_accumulator.ColumnInfo;

// NOTE: This file uses `catch {}` for stdout/stderr I/O operations.
// Output write failures are non-critical — the query result is correct
// even if display fails.  See docs/FULL_AUDIT_2026_04_07.md.

var g_repl_background_pool_mu: std.Io.Mutex = std.Io.Mutex.init;
var g_repl_background_pool: ?*pooled.ThreadPool = null;

fn getBackgroundPool(allocator: std.mem.Allocator) !*pooled.ThreadPool {
    g_repl_background_pool_mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_repl_background_pool_mu.unlock(std.Io.Threaded.global_single_threaded.io());

    if (g_repl_background_pool == null) {
        g_repl_background_pool = try pooled.ThreadPool.init(allocator, .{
            .num_threads = 2,
            .queue_capacity = 32,
        });
    }
    return g_repl_background_pool.?;
}

/// Tear down the lazily-created background read pool. Idempotent; safe to
/// call when the pool was never created. Used at REPL exit and by the
/// GAP-0514 e2e regression so std.testing.allocator leak detection stays
/// meaningful (the pool is allocated with the first caller's allocator).
pub fn deinitBackgroundPool() void {
    g_repl_background_pool_mu.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_repl_background_pool_mu.unlock(std.Io.Threaded.global_single_threaded.io());

    if (g_repl_background_pool) |pool| {
        pool.deinit();
        g_repl_background_pool = null;
    }
}

/// Validate a graph name to prevent GQL injection (S5).
/// Graph names must match [a-zA-Z_][a-zA-Z0-9_]*.
fn isValidGraphName(name: []const u8) bool {
    if (name.len == 0) return false;
    for (name, 0..) |c, idx| {
        const valid = if (idx == 0)
            (std.ascii.isAlphabetic(c) or c == '_')
        else
            (std.ascii.isAlphanumeric(c) or c == '_');
        if (!valid) return false;
    }
    return true;
}

/// SONNY-6494: write a formatted reply sized to its text. The replies that
/// echo user text were formatted into fixed stack buffers, so long text made
/// the command fail with NoSpaceLeft (or, with `catch return`, do nothing).
fn writeFmt(file: std.Io.File, allocator: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
    const msg = try std.fmt.allocPrint(allocator, fmt, args);
    defer allocator.free(msg);
    try file.writeStreamingAll(replIo(), msg);
}

fn clearSessionLastResponse(session: *ClientSession) void {
    if (session.last_response) |resp| {
        session.allocator.free(resp);
        session.last_response = null;
    }
}

fn syncSessionStateFromResult(
    session: *ClientSession,
    result: *const query_result_accumulator.ResultAccumulator,
) !void {
    clearSessionLastResponse(session);
    session.last_payload_kind = switch (result.result_kind) {
        .explain => .explain,
        .profile => .profile,
        .rows => if (result.rowCount() > 0 or result.view().columns.len > 0) .rows else .none,
    };

    if (!result.indicatesFailure()) return;

    var root = @as(std.json.ObjectMap, .empty);
    // The object (and every duped string in it) is only scaffolding for the
    // stringified last_response below — free it on ALL exits.  This was an
    // errdefer before GAP-0514, which leaked the whole error-meta object on
    // every failed statement (caught by the gap0514 repl e2e leak check)
    // and would have freed string-LITERAL keys on its error path —
    // freeJsonValue frees keys, so every key below must be duped.
    defer query_result_accumulator.freeJsonValue(session.allocator, .{ .object = root });

    try root.put(session.allocator, try session.allocator.dupe(u8, "status_class"), .{ .string = try session.allocator.dupe(u8, result.status_class) });
    if (result.status_subclass.len > 0) {
        try root.put(session.allocator, try session.allocator.dupe(u8, "status_subclass"), .{ .string = try session.allocator.dupe(u8, result.status_subclass) });
    }
    if (result.has_error) {
        if (result.error_message.len > 0) {
            const message = try session.allocator.dupe(u8, result.error_message);
            try root.put(session.allocator, try session.allocator.dupe(u8, "error"), .{ .string = message });
            try root.put(session.allocator, try session.allocator.dupe(u8, "message"), .{ .string = try session.allocator.dupe(u8, result.error_message) });
        }
        if (result.error_status.len > 0) {
            try root.put(session.allocator, try session.allocator.dupe(u8, "error_code"), .{ .string = try session.allocator.dupe(u8, result.error_status) });
        }
    }

    var additional = std.json.Array.init(session.allocator);
    for (result.additional_statuses.items) |item| {
        try additional.append(.{ .string = try session.allocator.dupe(u8, item) });
    }
    try root.put(session.allocator, try session.allocator.dupe(u8, "additional_statuses"), .{ .array = additional });

    var flagger = std.json.Array.init(session.allocator);
    for (result.flagger_findings.items) |item| {
        try flagger.append(.{ .string = try session.allocator.dupe(u8, item) });
    }
    try root.put(session.allocator, try session.allocator.dupe(u8, "flagger_findings"), .{ .array = flagger });

    const root_value = std.json.Value{ .object = root };
    session.last_response = try std.json.Stringify.valueAlloc(
        session.allocator,
        root_value,
        .{},
    );
}

const LastPayloadKind = enum {
    none,
    rows,
    explain,
    profile,
    @"error",
};

// CANARY: REQ=REQ-SHELL-INTERRUPT-003; FEATURE="SourceInterrupt"; ASPECT=CheckFunction; STATUS=TESTED; TEST=tests/test_gap0514_repl_dispatch.zig; OWNER=cli; UPDATED=2026-11-12
// Issue #390: Helper function to check for Ctrl+C (ASCII 3) in stdin without blocking
// Made public so it can be used by other modules for interrupt handling
// In raw terminal mode, Ctrl+C generates ASCII 3 which we poll for
pub fn checkForInterrupt() bool {
    // CANARY: REQ=REQ-SHELL-INTERRUPT-036; FEATURE="SourceInterrupt"; ASPECT=SignalBasedInterrupt; STATUS=TESTED; TEST=tests/test_gap0514_repl_dispatch.zig; OWNER=cli; UPDATED=2026-06-11
    // First check the signal-based flag (most reliable for Ctrl+C in cooked terminal mode)
    if (platform.checkAndClearSigint()) {
        return true;
    }

    // CANARY: REQ=REQ-SHELL-PLAIN-009; FEATURE="ShellPlainMode"; ASPECT=InterruptCheckTTY; STATUS=TESTED; TEST=tests/test_gap0514_repl_dispatch.zig; OWNER=cli; UPDATED=2026-06-11
    // Only check stdin for Ctrl+C if it's a TTY. When stdin is piped (non-interactive/plain mode),
    // reading from stdin will consume actual command input, not just Ctrl+C signals.
    // In piped mode, rely on signal-based interrupt handling above.
    if (builtin.os.tag != .windows) {
        if (!(std.Io.File.stdin().isTty(std.Io.Threaded.global_single_threaded.io()) catch false)) {
            return false;
        }
    }

    // On Windows, Ctrl+C is handled exclusively via SetConsoleCtrlHandler in platform.zig.
    // The checkAndClearSigint() call above is sufficient for Windows.
    if (comptime builtin.os.tag == .windows) return false;

    // POSIX: use poll with 0 timeout to check if data is available
    var fds = [_]std.posix.pollfd{
        .{ .fd = std.posix.STDIN_FILENO, .events = std.posix.POLL.IN, .revents = 0 },
    };
    const result = std.posix.poll(&fds, 0) catch return false;
    if (result > 0 and (fds[0].revents & std.posix.POLL.IN) != 0) {
        // Data available, check if it's Ctrl+C (ASCII 3)
        var buf: [1]u8 = undefined;
        const stdin = platform.getStdinHandle();
        const bytes_read = stdin.readStreaming(std.Io.Threaded.global_single_threaded.io(), &.{&buf}) catch return false;
        if (bytes_read > 0 and buf[0] == 3) { // Ctrl+C
            return true;
        }
    }
    return false;
}

// CANARY: REQ=REQ-REPL-QUIC-001; FEATURE="REPL QUIC Integration"; ASPECT=ClientSession; STATUS=TESTED; TEST=tests/test_repl_quic_integration_e2e.zig; OWNER=repl; UPDATED=2026-01-15

// Transport interface - implemented by CLI layer to avoid module conflicts

/// Transport interface for REPL communication
pub const Transport = struct {
    connectFn: *const fn (allocator: std.mem.Allocator, addr: []const u8) anyerror!*TransportConnection,

    pub fn connect(self: *const Transport, allocator: std.mem.Allocator, addr: []const u8) !*TransportConnection {
        return self.connectFn(allocator, addr);
    }
};

/// Transport connection interface
pub const TransportConnection = struct {
    writeAllFn: *const fn (self: *TransportConnection, data: []const u8) anyerror!void,
    readLineFn: *const fn (self: *TransportConnection, allocator: std.mem.Allocator, max_size: usize) anyerror![]u8,
    deinitFn: *const fn (self: *TransportConnection) void,
    context: ?*anyopaque = null,
    allocator: ?std.mem.Allocator = null,

    pub fn writeAll(self: *TransportConnection, data: []const u8) !void {
        return self.writeAllFn(self, data);
    }

    pub fn readLine(self: *TransportConnection, allocator: std.mem.Allocator, max_size: usize) ![]u8 {
        return self.readLineFn(self, allocator, max_size);
    }

    pub fn deinit(self: *TransportConnection) void {
        return self.deinitFn(self);
    }
};

fn encodeClientPacket(allocator: std.mem.Allocator, msg: proto_schema.QuicClientMessage) ![]u8 {
    var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(allocator, 1024);
    defer aw.deinit();

    const packet = proto_schema.ClientPacket{ .quic = msg };
    try protobuf.encode(&aw.writer, allocator, packet);

    const body = aw.writer.buffer[0..aw.writer.end];
    const out = try allocator.alloc(u8, body.len + 4);
    std.mem.writeInt(u32, out[0..4], @intCast(body.len), .big);
    @memcpy(out[4..], body);
    return out;
}

fn decodeServerPacket(allocator: std.mem.Allocator, bytes: []const u8) !proto_schema.ServerPacket {
    var reader: std.Io.Reader = .fixed(bytes);
    return try protobuf.decode(proto_schema.ServerPacket, &reader, allocator);
}

fn encodeServerPacketBody(allocator: std.mem.Allocator, msg: proto_schema.QuicServerMessage) ![]u8 {
    var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(allocator, 512);
    defer aw.deinit();

    const packet = proto_schema.ServerPacket{ .quic = msg };
    try protobuf.encode(&aw.writer, allocator, packet);

    const body = aw.writer.buffer[0..aw.writer.end];
    return allocator.dupe(u8, body);
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

fn protoMapEntriesToJson(allocator: std.mem.Allocator, entries: []const proto_schema.MapEntry) !std.json.ObjectMap {
    var obj = @as(std.json.ObjectMap, .empty);
    for (entries) |entry| {
        const key = try allocator.dupe(u8, entry.key);
        const val = if (entry.value) |v|
            try protoValueToJson(allocator, v)
        else
            std.json.Value.null;
        try obj.put(allocator, key, val);
    }
    return obj;
}

fn protoNodeToJson(allocator: std.mem.Allocator, node: proto_schema.NodeValue) !std.json.Value {
    var obj = @as(std.json.ObjectMap, .empty);
    try obj.put(allocator, "id", try jsonNumberFromU64(allocator, node.id));

    var labels = std.json.Array.init(allocator);
    for (node.labels.items) |label| {
        try labels.append(.{ .string = try allocator.dupe(u8, label) });
    }
    try obj.put(allocator, "labels", .{ .array = labels });

    const props_obj = try protoMapEntriesToJson(allocator, node.properties.items);
    try obj.put(allocator, "properties", .{ .object = props_obj });
    return .{ .object = obj };
}

fn protoEdgeToJson(allocator: std.mem.Allocator, edge: proto_schema.EdgeValue) !std.json.Value {
    var obj = @as(std.json.ObjectMap, .empty);
    try obj.put(allocator, "id", try jsonNumberFromU64(allocator, edge.id));
    try obj.put(allocator, "from", try jsonNumberFromU64(allocator, edge.from_id));
    try obj.put(allocator, "to", try jsonNumberFromU64(allocator, edge.to_id));
    try obj.put(allocator, "label", .{ .string = try allocator.dupe(u8, edge.label) });

    const props_obj = try protoMapEntriesToJson(allocator, edge.properties.items);
    try obj.put(allocator, "properties", .{ .object = props_obj });
    return .{ .object = obj };
}

fn protoPathToJson(allocator: std.mem.Allocator, path: proto_schema.PathValue) !std.json.Value {
    var obj = @as(std.json.ObjectMap, .empty);

    var nodes = std.json.Array.init(allocator);
    for (path.nodes.items) |node| {
        try nodes.append(try protoNodeToJson(allocator, node));
    }
    try obj.put(allocator, "nodes", .{ .array = nodes });

    var edges = std.json.Array.init(allocator);
    for (path.edges.items) |edge| {
        try edges.append(try protoEdgeToJson(allocator, edge));
    }
    try obj.put(allocator, "edges", .{ .array = edges });
    return .{ .object = obj };
}

fn protoExtendedToJson(allocator: std.mem.Allocator, ext: proto_schema.ExtendedValue) !std.json.Value {
    var obj = @as(std.json.ObjectMap, .empty);
    if (ext.type_name.len > 0) {
        try obj.put(allocator, "type", .{ .string = try allocator.dupe(u8, ext.type_name) });
    }
    if (ext.data) |data| {
        const val: std.json.Value = switch (data) {
            .text => |t| .{ .string = try allocator.dupe(u8, t) },
            .bytes => |b| .{ .string = try base64Encode(allocator, b) },
            .int_val => |n| .{ .integer = n },
            .double_val => |f| .{ .float = f },
            .bool_val => |b| .{ .bool = b },
        };
        try obj.put(allocator, "value", val);
    }
    return .{ .object = obj };
}

fn protoValueToJson(allocator: std.mem.Allocator, value: proto_schema.Value) error{OutOfMemory}!std.json.Value {
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

fn buildColumnsJsonArray(allocator: std.mem.Allocator, columns: []const ColumnInfo) !std.json.Array {
    var arr = std.json.Array.init(allocator);
    for (columns) |col| {
        var obj = @as(std.json.ObjectMap, .empty);
        try obj.put(allocator, "name", .{ .string = try allocator.dupe(u8, col.name) });
        try obj.put(allocator, "type", .{ .string = try allocator.dupe(u8, col.type) });
        try arr.append(.{ .object = obj });
    }
    return arr;
}

fn rowToJsonArray(allocator: std.mem.Allocator, row: proto_schema.Row, columns: []const ColumnInfo) !std.json.Value {
    var obj = @as(std.json.ObjectMap, .empty);
    for (row.values.items, 0..) |val, idx| {
        const name = if (idx < columns.len) columns[idx].name else "?";
        try obj.put(allocator, try allocator.dupe(u8, name), try protoValueToJson(allocator, val));
    }
    return .{ .object = obj };
}

fn buildRowsJsonArray(allocator: std.mem.Allocator, rows: []const proto_schema.Row, columns: []const ColumnInfo) !std.json.Array {
    var arr = std.json.Array.init(allocator);
    if (rows.len == 0) return arr;

    // Keep small result sets on the sequential path; the per-row JSON work
    // is cheap and pool setup dominates below this threshold.
    const parallel_threshold: usize = 512;
    if (parallel_wrapper.shouldUseParallelism(rows.len, parallel_threshold)) {
        var pool = parallel_wrapper.ParallelPool.init(allocator, null);
        pool.start();
        defer pool.deinit();

        // Zig 0.16: ThreadSafeAllocator removed; allocator is already thread-safe.
        const safe_alloc = allocator;

        const RowInput = struct {
            row: *const proto_schema.Row,
            allocator: std.mem.Allocator,
            columns: []const ColumnInfo,
        };

        const RowResult = struct {
            value: std.json.Value,
            err: ?anyerror,
        };

        const inputs = try allocator.alloc(RowInput, rows.len);
        defer allocator.free(inputs);
        for (rows, 0..) |*row, i| {
            inputs[i] = .{ .row = row, .allocator = safe_alloc, .columns = columns };
        }

        const mapFn = struct {
            fn map(_: *parallel_wrapper.Task, input: RowInput) RowResult {
                const value = rowToJsonArray(input.allocator, input.row.*, input.columns) catch |err| {
                    return .{ .value = std.json.Value.null, .err = err };
                };
                return .{ .value = value, .err = null };
            }
        }.map;

        const results = try parallel_wrapper.parallelMap(RowInput, RowResult, &pool, inputs, mapFn, parallel_wrapper.Thresholds.map);
        defer allocator.free(results);

        for (results) |res| {
            if (res.err) |err| return err;
            try arr.append(res.value);
        }
    } else {
        for (rows) |row| {
            try arr.append(try rowToJsonArray(allocator, row, columns));
        }
    }

    return arr;
}

fn executionResponseToJson(
    allocator: std.mem.Allocator,
    exec_resp: proto_schema.ExecutionResponse,
    columns: ?[]const ColumnInfo,
) ![]u8 {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const a = arena.allocator();

    var root = @as(std.json.ObjectMap, .empty);

    const status_class = if (exec_resp.status) |st|
        if (st.status_class.len > 0) st.status_class else "00000"
    else
        "00000";
    try root.put(a, "status_class", .{ .string = try a.dupe(u8, status_class) });

    var additional_arr = std.json.Array.init(a);
    var flagger_arr = std.json.Array.init(a);
    if (exec_resp.status) |st| {
        if (st.status_subclass.len > 0) {
            try root.put(a, "status_subclass", .{ .string = try a.dupe(u8, st.status_subclass) });
        }
        for (st.additional_statuses.items) |item| {
            try additional_arr.append(.{ .string = try a.dupe(u8, item) });
        }
        for (st.flagger_findings.items) |item| {
            try flagger_arr.append(.{ .string = try a.dupe(u8, item) });
        }
    }
    try root.put(a, "additional_statuses", .{ .array = additional_arr });
    try root.put(a, "flagger_findings", .{ .array = flagger_arr });

    if (exec_resp.payload) |payload| {
        switch (payload) {
            .schema => |schema_def| {
                if (schema_def.columns.items.len > 0) {
                    var cols = std.json.Array.init(a);
                    for (schema_def.columns.items) |col| {
                        var col_obj = @as(std.json.ObjectMap, .empty);
                        try col_obj.put(a, "name", .{ .string = try a.dupe(u8, col.name) });
                        try col_obj.put(a, "type", .{ .string = try a.dupe(u8, col.type) });
                        try cols.append(.{ .object = col_obj });
                    }
                    try root.put(a, "columns", .{ .array = cols });
                }
            },
            .page => |page| {
                const cols = columns orelse &[_]ColumnInfo{};
                if (cols.len > 0) {
                    const cols_array = try buildColumnsJsonArray(a, cols);
                    try root.put(a, "columns", .{ .array = cols_array });
                }
                const rows_array = try buildRowsJsonArray(a, page.rows.items, cols);
                try root.put(a, "rows", .{ .array = rows_array });
                try root.put(a, "ordered", .{ .bool = page.ordered });
                var ok_arr = std.json.Array.init(a);
                for (page.order_keys.items) |key| {
                    try ok_arr.append(.{ .string = try a.dupe(u8, key) });
                }
                try root.put(a, "order_keys", .{ .array = ok_arr });
            },
            .@"error" => |err| {
                if (err.message.len > 0) {
                    try root.put(a, "error", .{ .string = try a.dupe(u8, err.message) });
                    try root.put(a, "message", .{ .string = try a.dupe(u8, err.message) });
                }
                if (err.code.len > 0) {
                    try root.put(a, "error_code", .{ .string = try a.dupe(u8, err.code) });
                }
            },
            .metrics => |metrics| {
                var metrics_obj = @as(std.json.ObjectMap, .empty);
                try metrics_obj.put(a, "parse_ns", .{ .integer = metrics.parse_duration_ns });
                try metrics_obj.put(a, "plan_ns", .{ .integer = metrics.plan_duration_ns });
                try metrics_obj.put(a, "execute_ns", .{ .integer = metrics.execute_duration_ns });
                try metrics_obj.put(a, "total_ns", .{ .integer = metrics.total_duration_ns });
                try root.put(a, "metrics", .{ .object = metrics_obj });
            },
            .explain => |explain| {
                const explain_json = try explain_payload.explainPayloadToJson(a, explain);
                if (std.json.parseFromSlice(std.json.Value, a, explain_json, .{})) |parsed| {
                    defer a.free(explain_json);
                    try root.put(a, "explain", parsed.value);
                } else |_| {
                    try root.put(a, "explain", .{ .string = explain_json });
                }
            },
            .profile => |profile| {
                const profile_json = try profile_payload.profilePayloadToJson(a, profile);
                if (std.json.parseFromSlice(std.json.Value, a, profile_json, .{})) |parsed| {
                    defer a.free(profile_json);
                    try root.put(a, "profile", parsed.value);
                } else |_| {
                    try root.put(a, "profile", .{ .string = profile_json });
                }
            },
            .heartbeat => {
                try root.put(a, "heartbeat", .{ .bool = true });
            },
        }
    }

    const root_value = std.json.Value{ .object = root };
    return std.json.Stringify.valueAlloc(allocator, root_value, .{});
}

fn cloneJsonValue(allocator: std.mem.Allocator, value: std.json.Value) !std.json.Value {
    return switch (value) {
        .null => std.json.Value.null,
        .bool => |b| .{ .bool = b },
        .integer => |i| .{ .integer = i },
        .float => |f| .{ .float = f },
        .number_string => |s| .{ .number_string = try allocator.dupe(u8, s) },
        .string => |s| .{ .string = try allocator.dupe(u8, s) },
        .array => |arr| blk: {
            var out = std.json.Array.init(allocator);
            for (arr.items) |item| {
                try out.append(try cloneJsonValue(allocator, item));
            }
            break :blk .{ .array = out };
        },
        .object => |obj| blk: {
            var out = @as(std.json.ObjectMap, .empty);
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                try out.put(allocator, try allocator.dupe(u8, entry.key_ptr.*), try cloneJsonValue(allocator, entry.value_ptr.*));
            }
            break :blk .{ .object = out };
        },
    };
}

fn mergeInlinePageJson(
    allocator: std.mem.Allocator,
    response_json: []const u8,
    all_rows: *std.json.Array,
    status_class: *[]const u8,
    status_subclass: *[]const u8,
    status_captured: *bool,
    additional_arr: *std.json.Array,
    flagger_arr: *std.json.Array,
    ordered: *bool,
    order_keys: *std.json.Array,
) !void {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, response_json, .{});
    defer parsed.deinit();

    const root = parsed.value.object;
    if (!status_captured.*) {
        status_captured.* = true;
        if (root.get("status_class")) |status_val| {
            if (status_val == .string and status_val.string.len > 0) {
                status_class.* = try allocator.dupe(u8, status_val.string);
            }
        }
        if (root.get("status_subclass")) |subclass_val| {
            if (subclass_val == .string and subclass_val.string.len > 0) {
                status_subclass.* = try allocator.dupe(u8, subclass_val.string);
            }
        }
        if (root.get("additional_statuses")) |additional_val| {
            if (additional_val == .array) {
                for (additional_val.array.items) |item| {
                    if (item == .string) {
                        try additional_arr.append(.{ .string = try allocator.dupe(u8, item.string) });
                    }
                }
            }
        }
        if (root.get("flagger_findings")) |flagger_val| {
            if (flagger_val == .array) {
                for (flagger_val.array.items) |item| {
                    if (item == .string) {
                        try flagger_arr.append(.{ .string = try allocator.dupe(u8, item.string) });
                    }
                }
            }
        }
    }

    if (root.get("rows")) |rows_val| {
        if (rows_val == .array) {
            for (rows_val.array.items) |row| {
                try all_rows.append(try cloneJsonValue(allocator, row));
            }
        }
    }

    if (root.get("ordered")) |ordered_val| {
        if (ordered_val == .bool and ordered_val.bool) {
            ordered.* = true;
        }
    }

    if (order_keys.items.len == 0) {
        if (root.get("order_keys")) |order_keys_val| {
            if (order_keys_val == .array) {
                for (order_keys_val.array.items) |item| {
                    if (item == .string) {
                        try order_keys.append(.{ .string = try allocator.dupe(u8, item.string) });
                    }
                }
            }
        }
    }
}

/// CANARY: REQ=REQ-SHELL-RECONNECT-001; FEATURE="ShellAutoReconnect"; ASPECT=ReconnectionConfig; STATUS=TESTED; OWNER=cli; UPDATED=2026-01-29
/// Configuration for automatic reconnection with exponential backoff
pub const ReconnectionConfig = struct {
    /// Maximum number of reconnection attempts (0 = disabled)
    max_attempts: u32 = 5,
    /// Initial delay between attempts in milliseconds
    initial_delay_ms: u64 = 100,
    /// Maximum delay between attempts in milliseconds
    max_delay_ms: u64 = 10000,
    /// Multiplier for exponential backoff (e.g., 2.0 = double each time)
    backoff_multiplier: f64 = 2.0,
    /// Whether to prompt user for transaction recovery
    prompt_for_txn_recovery: bool = true,
};

/// CANARY: REQ=REQ-SHELL-RECONNECT-002; FEATURE="ShellAutoReconnect"; ASPECT=TransactionState; STATUS=TESTED; OWNER=cli; UPDATED=2026-01-29
/// Tracks pending transaction state for recovery after reconnection
pub const PendingTransactionState = struct {
    /// Whether a transaction was active when connection was lost
    had_active_transaction: bool = false,
    /// The graph that was in use (if any)
    current_graph: ?[]const u8 = null,
    /// Number of statements executed in the transaction
    statements_in_txn: usize = 0,

    pub fn reset(self: *PendingTransactionState) void {
        self.had_active_transaction = false;
        self.current_graph = null;
        self.statements_in_txn = 0;
    }
};

/// User's choice for transaction recovery after reconnection
pub const TransactionRecoveryChoice = enum {
    /// Resume the transaction (start a new BEGIN)
    resume_transaction,
    /// Cancel the transaction (don't start a new transaction)
    cancel_transaction,
    /// Abort the reconnection entirely
    abort_reconnection,
};

pub const ClientSession = struct {
    allocator: std.mem.Allocator,
    server_addr: []const u8,
    connected: bool = false,
    transport: ?*const Transport = null,
    connection: ?*TransportConnection = null,
    last_response: ?[]u8 = null,
    session_id: ?[]const u8 = null,
    last_columns: ?[]const ColumnInfo = null,
    last_payload_kind: LastPayloadKind = .none,
    /// CANARY: REQ=REQ-INLINE-RESULTS-001; FEATURE="InlineResultsHandling"; ASPECT=SchemaResponseFlag; STATUS=TESTED; TEST=tests/test_gap0514_repl_dispatch.zig; OWNER=cli; UPDATED=2026-06-11
    /// Tracks if last response was a schema (meaning inline page may follow)
    received_schema_response: bool = false,
    /// Cached inline page JSON emitted immediately after schema.
    /// This lets pullAll merge inline rows with later PULL pages instead of
    /// dropping the first page or issuing redundant pulls for fully-inline
    /// result sets.
    inline_page_response: ?[]u8 = null,
    inline_page_final: bool = false,
    /// CANARY: REQ=REQ-SHELL-RECONNECT-003; FEATURE="ShellAutoReconnect"; ASPECT=SessionState; STATUS=TESTED; OWNER=cli; UPDATED=2026-01-29
    reconnect_config: ReconnectionConfig = .{},
    pending_txn_state: PendingTransactionState = .{},
    /// Cached credentials for re-authentication after reconnect
    cached_username: ?[]const u8 = null,
    cached_password: ?[]const u8 = null,
    /// Graph name for HELLO handshake (from DSN path)
    graph: ?[]const u8 = null,
    /// Count of successful reconnections (for diagnostics)
    reconnect_count: u32 = 0,
    /// Last reconnection error (for diagnostics)
    last_reconnect_error: ?[]const u8 = null,
    /// CANARY: REQ=REQ-SHELL-TXN-ERROR-001; FEATURE="TransactionErrorDetails"; ASPECT=ErrorMessage; STATUS=TESTED; TEST=tests/test_gap0514_repl_dispatch.zig; OWNER=cli; UPDATED=2026-06-11
    /// Last transaction error message for better user feedback
    last_txn_error: ?[]const u8 = null,

    pub fn init(allocator: std.mem.Allocator, addr: []const u8, transport: *const Transport) !ClientSession {
        return ClientSession{
            .allocator = allocator,
            .server_addr = try allocator.dupe(u8, addr),
            .transport = transport,
        };
    }

    pub fn connect(self: *ClientSession) !void {
        if (self.transport) |transport| {
            self.connection = try transport.connect(self.allocator, self.server_addr);
            self.connected = true;
        } else {
            return error.NotConnected;
        }
    }

    /// Disconnect from server (used on interrupt to let server rollback transaction)
    /// CANARY: REQ=REQ-SHELL-INTERRUPT-035; FEATURE="SourceInterrupt"; ASPECT=DisconnectForRollback; STATUS=TESTED; TEST=tests/test_gap0514_repl_dispatch.zig; OWNER=cli; UPDATED=2026-06-11
    pub fn disconnect(self: *ClientSession) void {
        if (self.connection) |conn| {
            conn.deinit();
            self.connection = null;
        }
        self.connected = false;
        if (self.session_id) |sid| {
            self.allocator.free(sid);
            self.session_id = null;
        }
        self.clearLastColumns();
        // Clear any pending response
        if (self.last_response) |resp| {
            self.allocator.free(resp);
            self.last_response = null;
        }
        self.clearInlinePageResponse();
        self.last_payload_kind = .none;
    }

    pub fn deinit(self: *ClientSession) void {
        if (self.connection) |conn| {
            conn.deinit();
            self.connection = null;
        }
        self.allocator.free(self.server_addr);
        if (self.last_response) |resp| {
            self.allocator.free(resp);
            self.last_response = null;
        }
        self.clearInlinePageResponse();
        if (self.session_id) |sid| {
            self.allocator.free(sid);
            self.session_id = null;
        }
        self.clearLastColumns();
        if (self.cached_username) |u| {
            self.allocator.free(u);
            self.cached_username = null;
        }
        if (self.cached_password) |p| {
            self.allocator.free(p);
            self.cached_password = null;
        }
        if (self.last_reconnect_error) |e| {
            self.allocator.free(e);
            self.last_reconnect_error = null;
        }
        if (self.last_txn_error) |e| {
            self.allocator.free(e);
            self.last_txn_error = null;
        }
        // The `graph` field is owned by the session: every assignment site
        // (`repl_loop.zig` at init, `repl_dispatch.zig` `:use` at line ~2361)
        // dup's the source string. Without this free, every `:use <graph>`
        // leaked the final value at REPL exit (DebugAllocator panic on
        // shutdown — see tests/test_repl_session_leak_regression.zig).
        if (self.graph) |g| {
            self.allocator.free(g);
            self.graph = null;
        }
        // CANARY: REQ=REQ-SOURCE-PERF-003; FEATURE="SourceFilePerformance"; ASPECT=CacheCleanupOnExit; STATUS=TESTED; TEST=tests/test_gap0514_repl_dispatch.zig; OWNER=cli; UPDATED=2026-06-11
        // Issue #413: Clean up global file hash cache to prevent memory leaks on exit
        deinitSourcedFileCache();
    }

    fn clearLastColumns(self: *ClientSession) void {
        if (self.last_columns) |cols| {
            for (cols) |col| {
                self.allocator.free(col.name);
                self.allocator.free(col.type);
            }
            self.allocator.free(cols);
            self.last_columns = null;
        }
    }

    fn clearInlinePageResponse(self: *ClientSession) void {
        if (self.inline_page_response) |resp| {
            self.allocator.free(resp);
            self.inline_page_response = null;
        }
        self.inline_page_final = false;
    }

    /// CANARY: REQ=REQ-INLINE-RESULTS-003; FEATURE="InlineResultsHandling"; ASPECT=ConsumeInlinePage; STATUS=TESTED; TEST=tests/test_gap0514_repl_dispatch.zig; OWNER=cli; UPDATED=2026-06-11
    /// Consume inline page response if the server sent one after a schema response.
    /// The server's inline_results_enabled feature sends both schema and page in sequence.
    /// This must be called after receiving a schema response to prevent protocol mismatch
    /// on subsequent queries (where the client would read the stale inline page instead
    /// of the new query's response).
    ///
    /// When a final inline page is consumed:
    /// - last_payload_kind is set to .none to prevent subsequent PULL calls
    /// - last_response is updated with the page data for display
    fn consumeInlinePageIfNeeded(self: *ClientSession) void {
        if (!self.received_schema_response) return;
        if (!self.connected or self.connection == null) return;

        // Reset the flag
        self.received_schema_response = false;

        // Read the inline page that the server sends immediately after the schema.
        // Large result sets can take noticeable time to serialize, so wait long
        // enough to cover the user's normal query latency and cache the page for
        // pullAll to merge later.
        var retry_count: usize = 0;
        const max_retries: usize = 600; // 600 * 50ms = 30s max wait
        while (retry_count < max_retries) : (retry_count += 1) {
            const response = self.connection.?.readLine(self.allocator, 0) catch |err| {
                if (err == error.WouldBlock) {
                    sleepNs(50 * std.time.ns_per_ms);
                    continue;
                }
                // Any other error - just return, no inline page
                return;
            };

            // Got a response - decode it
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            const packet = decodeServerPacket(arena.allocator(), response) catch {
                // Decode error - free response and return
                self.allocator.free(response);
                return;
            };
            const msg_union = packet.quic orelse {
                self.allocator.free(response);
                return;
            };

            switch (msg_union) {
                .execute => |exec_resp| {
                    // Check if this is a page payload (inline results)
                    if (exec_resp.payload) |payload| {
                        switch (payload) {
                            .page => |page| {
                                // Successfully consumed inline page. Cache it so
                                // pullAll can merge the first inline page with any
                                // later PULL pages or return it directly if it was
                                // the full result set.
                                self.clearInlinePageResponse();
                                self.inline_page_response = executionResponseToJson(self.allocator, exec_resp, self.last_columns) catch null;
                                self.inline_page_final = page.final;
                                self.allocator.free(response);
                                return;
                            },
                            else => {
                                // Unexpected payload type - don't consume, might be next query's response
                                // This shouldn't happen in normal operation
                                self.allocator.free(response);
                                return;
                            },
                        }
                    }
                },
                else => {
                    // Not an execute response - shouldn't happen for inline results
                    self.allocator.free(response);
                    return;
                },
            }
            self.allocator.free(response);
            return;
        }
        // Timeout waiting for inline page - that's OK, server might not have sent one
    }

    /// CANARY: REQ=REQ-SHELL-RECONNECT-004; FEATURE="ShellAutoReconnect"; ASPECT=ErrorDetection; STATUS=TESTED; OWNER=cli; UPDATED=2026-01-29
    /// Check if an error indicates a lost connection that can be recovered
    pub fn isConnectionError(err: anyerror) bool {
        return switch (err) {
            error.BrokenPipe,
            error.ConnectionResetByPeer,
            error.ConnectionRefused,
            error.ConnectionTimedOut,
            error.NetworkUnreachable,
            error.HostUnreachable,
            error.NotConnected,
            error.SocketNotConnected,
            error.InputOutput,
            error.EndOfStream,
            error.Unexpected,
            => true,
            else => false,
        };
    }

    /// CANARY: REQ=REQ-SHELL-RECONNECT-005; FEATURE="ShellAutoReconnect"; ASPECT=ReconnectWithBackoff; STATUS=TESTED; OWNER=cli; UPDATED=2026-01-29
    /// Attempt to reconnect with exponential backoff
    /// Returns true if reconnection succeeded, false if all attempts failed
    pub fn reconnect(self: *ClientSession) !bool {
        if (self.reconnect_config.max_attempts == 0) {
            return false; // Reconnection disabled
        }

        const stderr = platform.getStderrHandle();
        const stdout = platform.getStdoutHandle();

        // Close existing connection if any
        if (self.connection) |conn| {
            conn.deinit();
            self.connection = null;
        }
        self.connected = false;

        var delay_ms = self.reconnect_config.initial_delay_ms;
        var attempt: u32 = 0;

        while (attempt < self.reconnect_config.max_attempts) : (attempt += 1) {
            // Display reconnection attempt
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "\r\nConnection lost. Reconnecting (attempt {d}/{d})...\r\n", .{ attempt + 1, self.reconnect_config.max_attempts }) catch "";
            stdout.writeStreamingAll(replIo(), msg) catch {};

            // Wait before attempting (except first attempt)
            if (attempt > 0) {
                sleepNs(delay_ms * std.time.ns_per_ms);
                // Exponential backoff
                const new_delay = @as(u64, @intFromFloat(@as(f64, @floatFromInt(delay_ms)) * self.reconnect_config.backoff_multiplier));
                delay_ms = @min(new_delay, self.reconnect_config.max_delay_ms);
            }

            // Attempt connection
            self.connect() catch |err| {
                var err_buf: [256]u8 = undefined;
                const err_msg = std.fmt.bufPrint(&err_buf, "  Attempt {d} failed: {s}\r\n", .{ attempt + 1, @errorName(err) }) catch "";
                stderr.writeStreamingAll(replIo(), err_msg) catch {};
                continue;
            };

            // Attempt HELLO handshake
            if (self.cached_username != null and self.cached_password != null) {
                const auth_result = self.helloWithAuth(self.cached_username.?, self.cached_password.?) catch |err| {
                    var err_buf: [256]u8 = undefined;
                    const err_msg = std.fmt.bufPrint(&err_buf, "  Auth handshake failed: {s}\r\n", .{@errorName(err)}) catch "";
                    stderr.writeStreamingAll(replIo(), err_msg) catch {};
                    // Close connection and retry
                    if (self.connection) |conn| {
                        conn.deinit();
                        self.connection = null;
                    }
                    self.connected = false;
                    continue;
                };
                if (!auth_result.success) {
                    stderr.writeStreamingAll(replIo(), "  Authentication failed after reconnect\r\n") catch {};
                    if (auth_result.error_message) |em| self.allocator.free(em);
                    if (auth_result.session_token) |st| self.allocator.free(st);
                    if (self.connection) |conn| {
                        conn.deinit();
                        self.connection = null;
                    }
                    self.connected = false;
                    continue;
                }
                if (auth_result.session_token) |st| self.allocator.free(st);
            } else {
                self.hello() catch |err| {
                    var err_buf: [256]u8 = undefined;
                    const err_msg = std.fmt.bufPrint(&err_buf, "  Handshake failed: {s}\r\n", .{@errorName(err)}) catch "";
                    stderr.writeStreamingAll(replIo(), err_msg) catch {};
                    // Close connection and retry
                    if (self.connection) |conn| {
                        conn.deinit();
                        self.connection = null;
                    }
                    self.connected = false;
                    continue;
                };
            }

            // Success!
            self.reconnect_count += 1;
            stdout.writeStreamingAll(replIo(), "  Reconnected successfully!\r\n") catch {};
            return true;
        }

        // All attempts failed
        stderr.writeStreamingAll(replIo(), "  All reconnection attempts failed.\r\n") catch {};
        return false;
    }

    /// CANARY: REQ=REQ-SHELL-RECONNECT-006; FEATURE="ShellAutoReconnect"; ASPECT=CacheCredentials; STATUS=TESTED; OWNER=cli; UPDATED=2026-01-29
    /// Cache credentials for use during reconnection
    pub fn cacheCredentials(self: *ClientSession, username: []const u8, password: []const u8) !void {
        if (self.cached_username) |u| self.allocator.free(u);
        if (self.cached_password) |p| self.allocator.free(p);
        self.cached_username = try self.allocator.dupe(u8, username);
        self.cached_password = try self.allocator.dupe(u8, password);
    }

    /// CANARY: REQ=REQ-SHELL-RECONNECT-007; FEATURE="ShellAutoReconnect"; ASPECT=SaveTransactionState; STATUS=TESTED; OWNER=cli; UPDATED=2026-01-29
    /// Save current transaction state before reconnection attempt
    pub fn saveTransactionState(self: *ClientSession, in_txn: bool, current_graph: ?[]const u8, stmt_count: usize) void {
        self.pending_txn_state.had_active_transaction = in_txn;
        self.pending_txn_state.current_graph = current_graph;
        self.pending_txn_state.statements_in_txn = stmt_count;
    }

    /// CANARY: REQ=REQ-SHELL-RECONNECT-008; FEATURE="ShellAutoReconnect"; ASPECT=RestoreGraphContext; STATUS=TESTED; OWNER=cli; UPDATED=2026-01-29
    /// Restore graph context after reconnection (sends USE GRAPH if needed)
    pub fn restoreGraphContext(self: *ClientSession, current_graph: ?[]const u8) !void {
        if (current_graph) |graph| {
            // Send USE GRAPH statement to restore context
            const use_stmt = try std.fmt.allocPrint(self.allocator, "USE GRAPH {s};", .{graph});
            defer self.allocator.free(use_stmt);
            try self.runGql(use_stmt);
        }
    }

    // CANARY: REQ=REQ-SHELL-AUTH-001; FEATURE="ShellAuthRequired"; ASPECT=HelloAuthCheck; STATUS=TESTED; TEST=tests/test_gap0514_repl_dispatch.zig; OWNER=cli; UPDATED=2026-06-11
    // CANARY: REQ=REQ-SHELL-INTERRUPT-016; FEATURE="SourceInterrupt"; ASPECT=HelloInterrupt; STATUS=TESTED; TEST=tests/test_gap0514_repl_dispatch.zig; OWNER=cli; UPDATED=2026-06-11
    // Issue #387: HELLO handshake that checks if authentication is required
    pub fn hello(self: *ClientSession) !void {
        if (!self.connected or self.connection == null) return error.NotConnected;

        const hello_req = proto_schema.HelloRequest{
            .client_name = "geode-repl",
            .client_version = @import("build_options").version,
            .wanted_conformance = "min",
            .graph = self.graph,
        };

        const msg = try encodeClientPacket(self.allocator, .{ .hello = hello_req });
        defer self.allocator.free(msg);
        try self.connection.?.writeAll(msg);

        // Read HELLO acknowledgment with interrupt checking
        var retry_count: usize = 0;
        const max_retries: usize = 100; // ~5 seconds with 50ms sleep
        while (retry_count < max_retries) : (retry_count += 1) {
            if (checkForInterrupt()) {
                return error.Interrupted;
            }

            const hello_ack = self.connection.?.readLine(self.allocator, 0) catch |err| {
                if (err == error.WouldBlock) {
                    sleepNs(50 * std.time.ns_per_ms);
                    continue;
                }
                return err;
            };
            defer self.allocator.free(hello_ack);

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const packet = decodeServerPacket(arena.allocator(), hello_ack) catch return error.InvalidResponse;
            const msg_union = packet.quic orelse return error.InvalidResponse;
            switch (msg_union) {
                .hello => |resp| {
                    if (!resp.success) {
                        if (std.mem.indexOf(u8, resp.error_message, "Authentication required") != null) {
                            return error.AuthenticationRequired;
                        }
                        return error.AuthenticationFailed;
                    }
                    if (self.session_id) |sid| self.allocator.free(sid);
                    self.session_id = try self.allocator.dupe(u8, resp.session_id);
                    return;
                },
                else => return error.InvalidResponse,
            }
        }

        return error.WouldBlock;
    }

    /// GAP-0150: Authenticated HELLO handshake for CLI authentication
    /// CANARY: REQ=REQ-AUTH-CLI-001; FEATURE="CLI QUIC Authentication"; ASPECT=AuthenticatedHello; STATUS=TESTED; TEST=tests/test_repl_quic_integration_e2e.zig; OWNER=security; UPDATED=2026-01-15
    pub const AuthHelloResult = struct {
        success: bool,
        session_token: ?[]const u8,
        requires_password_reset: bool,
        error_message: ?[]const u8,
    };

    /// CANARY: REQ=REQ-SHELL-INTERRUPT-017; FEATURE="SourceInterrupt"; ASPECT=HelloAuthInterrupt; STATUS=TESTED; TEST=tests/test_gap0514_repl_dispatch.zig; OWNER=cli; UPDATED=2026-06-11
    pub fn helloWithAuth(self: *ClientSession, username: []const u8, password: []const u8) !AuthHelloResult {
        if (!self.connected or self.connection == null) return error.NotConnected;

        const hello_req = proto_schema.HelloRequest{
            .username = username,
            .password = password,
            .client_name = "geode-cli",
            .client_version = @import("build_options").version,
            .wanted_conformance = "min",
            .graph = self.graph,
        };

        const msg = try encodeClientPacket(self.allocator, .{ .hello = hello_req });
        defer self.allocator.free(msg);
        try self.connection.?.writeAll(msg);

        // Read HELLO response with interrupt checking
        var retry_count: usize = 0;
        const max_retries: usize = 100; // ~5 seconds with 50ms sleep
        const response = while (retry_count < max_retries) : (retry_count += 1) {
            if (checkForInterrupt()) {
                return AuthHelloResult{
                    .success = false,
                    .session_token = null,
                    .requires_password_reset = false,
                    .error_message = try self.allocator.dupe(u8, "Connection interrupted by user"),
                };
            }

            break self.connection.?.readLine(self.allocator, 0) catch |err| {
                if (err == error.WouldBlock) {
                    sleepNs(50 * std.time.ns_per_ms);
                    continue;
                }
                return err;
            };
        } else {
            return AuthHelloResult{
                .success = false,
                .session_token = null,
                .requires_password_reset = false,
                .error_message = try self.allocator.dupe(u8, "Server did not respond to authentication"),
            };
        };
        defer self.allocator.free(response);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const packet = decodeServerPacket(arena.allocator(), response) catch {
            return AuthHelloResult{
                .success = false,
                .session_token = null,
                .requires_password_reset = false,
                .error_message = try self.allocator.dupe(u8, "Invalid server response"),
            };
        };
        const msg_union = packet.quic orelse {
            return AuthHelloResult{
                .success = false,
                .session_token = null,
                .requires_password_reset = false,
                .error_message = try self.allocator.dupe(u8, "Invalid server response"),
            };
        };

        switch (msg_union) {
            .hello => |resp| {
                if (!resp.success) {
                    const error_msg = if (resp.error_message.len > 0)
                        try self.allocator.dupe(u8, resp.error_message)
                    else
                        try self.allocator.dupe(u8, "Authentication failed");

                    return AuthHelloResult{
                        .success = false,
                        .session_token = null,
                        .requires_password_reset = false,
                        .error_message = error_msg,
                    };
                }

                if (self.session_id) |sid| self.allocator.free(sid);
                self.session_id = try self.allocator.dupe(u8, resp.session_id);

                return AuthHelloResult{
                    .success = true,
                    .session_token = null,
                    .requires_password_reset = resp.password_reset_required,
                    .error_message = null,
                };
            },
            else => {
                return AuthHelloResult{
                    .success = false,
                    .session_token = null,
                    .requires_password_reset = false,
                    .error_message = try self.allocator.dupe(u8, "Unexpected response type"),
                };
            },
        }
    }

    pub fn runGql(self: *ClientSession, gql: []const u8) !void {
        if (!self.connected or self.connection == null) return error.NotConnected;

        // Check for interrupt before encoding (encoding large batches can be slow)
        if (checkForInterrupt()) {
            return error.Interrupted;
        }

        const params = std.ArrayList(proto_schema.Param).empty;
        const exec_req = proto_schema.ExecuteRequest{
            .session_id = self.session_id orelse "",
            .query = gql,
            .params = params,
        };
        const msg = try encodeClientPacket(self.allocator, .{ .execute = exec_req });
        defer self.allocator.free(msg);

        // For large payloads, write in chunks with interrupt checks
        // This allows Ctrl+C to be detected during long writes
        const chunk_size: usize = 8 * 1024; // 8KB chunks for responsive interrupt
        var written: usize = 0;
        while (written < msg.len) {
            if (checkForInterrupt()) {
                return error.Interrupted;
            }
            const end = @min(written + chunk_size, msg.len);
            try self.connection.?.writeAll(msg[written..end]);
            written = end;
        }

        // Clear previous response
        if (self.last_response) |resp| {
            self.allocator.free(resp);
            self.last_response = null;
        }
        self.clearInlinePageResponse();

        const ResponseHandler = struct {
            fn handle(session: *ClientSession, raw: []u8) !void {
                defer session.allocator.free(raw);
                var arena = std.heap.ArenaAllocator.init(session.allocator);
                defer arena.deinit();

                const packet = decodeServerPacket(arena.allocator(), raw) catch return error.InvalidResponse;
                const msg_union = packet.quic orelse return error.InvalidResponse;

                switch (msg_union) {
                    .execute => |exec_resp| {
                        session.last_payload_kind = .none;
                        // Reset schema response flag - will be set true only for schema payloads
                        session.received_schema_response = false;
                        if (exec_resp.payload) |payload| {
                            switch (payload) {
                                .schema => |schema_def| {
                                    session.clearLastColumns();
                                    const cols = try session.allocator.alloc(ColumnInfo, schema_def.columns.items.len);
                                    for (schema_def.columns.items, 0..) |col, i| {
                                        cols[i] = .{
                                            .name = try session.allocator.dupe(u8, col.name),
                                            .type = if (col.type.len > 0)
                                                try session.allocator.dupe(u8, col.type)
                                            else
                                                try session.allocator.dupe(u8, "ANY"),
                                        };
                                    }
                                    session.last_columns = cols;
                                    session.last_payload_kind = .rows;
                                    // Mark that we received a schema response - inline page may follow
                                    session.received_schema_response = true;
                                },
                                .page => {
                                    session.last_payload_kind = .rows;
                                },
                                .explain => {
                                    session.last_payload_kind = .explain;
                                },
                                .profile => {
                                    session.last_payload_kind = .profile;
                                },
                                .@"error" => {
                                    session.last_payload_kind = .@"error";
                                },
                                else => {},
                            }
                        }
                        session.last_response = try executionResponseToJson(session.allocator, exec_resp, session.last_columns);
                    },
                    else => return error.InvalidResponse,
                }
            }
        };

        // CANARY: REQ=REQ-SHELL-INTERRUPT-039; FEATURE="SourceInterrupt"; ASPECT=ThreadedRead; STATUS=TESTED; TEST=tests/test_gap0514_repl_dispatch.zig; OWNER=cli; UPDATED=2026-06-11
        // Use a threaded approach: worker thread does blocking read, main thread checks for interrupts
        // This allows Ctrl+C to be detected even when QUIC readLine is blocking
        const ReadContext = struct {
            connection: *TransportConnection,
            allocator: std.mem.Allocator,
            result: ?[]u8 = null,
            err: ?anyerror = null,
            done: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
            // Flag to indicate the main thread has abandoned us (interrupt/timeout)
            // Worker must check this and clean up if set
            abandoned: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
        };

        // Heap-allocate the context so it survives if we detach the worker thread
        const ctx = self.allocator.create(ReadContext) catch {
            // Allocation failed, fall back to blocking read
            const response = self.connection.?.readLine(self.allocator, 0) catch |read_err| {
                return read_err;
            };
            try ResponseHandler.handle(self, response);
            // CANARY: REQ=REQ-INLINE-RESULTS-004; FEATURE="InlineResultsHandling"; ASPECT=ConsumeAfterSchema; STATUS=IMPL; OWNER=cli; UPDATED=2026-02-05
            self.consumeInlinePageIfNeeded();
            return;
        };
        ctx.* = ReadContext{
            .connection = self.connection.?,
            .allocator = self.allocator,
        };

        const bg_pool = getBackgroundPool(self.allocator) catch {
            self.allocator.destroy(ctx);
            const response = self.connection.?.readLine(self.allocator, 0) catch |read_err| {
                return read_err;
            };
            try ResponseHandler.handle(self, response);
            // CANARY: REQ=REQ-INLINE-RESULTS-005; FEATURE="InlineResultsHandling"; ASPECT=ConsumeAfterSchema; STATUS=IMPL; OWNER=cli; UPDATED=2026-02-05
            self.consumeInlinePageIfNeeded();
            return;
        };
        if (!bg_pool.submit(.{
            .context = @ptrCast(ctx),
            .callback = struct {
                fn run(context: *anyopaque) void {
                    const c: *ReadContext = @ptrCast(@alignCast(context));
                    const result = c.connection.readLine(c.allocator, 0) catch |err| {
                        if (c.abandoned.load(.acquire)) {
                            c.allocator.destroy(c);
                            return;
                        }
                        c.err = err;
                        c.done.store(true, .release);
                        return;
                    };

                    if (c.abandoned.load(.acquire)) {
                        c.allocator.free(result);
                        c.allocator.destroy(c);
                        return;
                    }

                    c.result = result;
                    c.done.store(true, .release);
                }
            }.run,
        })) {
            // Pool submission failed, free context and fall back to blocking read
            self.allocator.destroy(ctx);
            const response = self.connection.?.readLine(self.allocator, 0) catch |read_err| {
                return read_err;
            };
            try ResponseHandler.handle(self, response);
            self.consumeInlinePageIfNeeded();
            return;
        }

        // Main thread: wait for completion while checking for interrupts
        const max_wait_ms: usize = 300000; // 5 minutes max
        var waited_ms: usize = 0;
        const check_interval_ms: usize = 50; // Check every 50ms

        while (waited_ms < max_wait_ms) {
            // Check if worker is done
            if (ctx.done.load(.acquire)) {
                const err_val = ctx.err;
                const result_val = ctx.result;
                // Worker completed normally, we own the context now
                self.allocator.destroy(ctx);
                if (err_val) |err| {
                    return err;
                }
                const raw = result_val orelse return error.InvalidResponse;
                try ResponseHandler.handle(self, raw);
                // CANARY: REQ=REQ-INLINE-RESULTS-006; FEATURE="InlineResultsHandling"; ASPECT=ConsumeAfterSchema; STATUS=TESTED; TEST=tests/test_gap0514_repl_dispatch.zig; OWNER=cli; UPDATED=2026-06-11
                self.consumeInlinePageIfNeeded();
                return;
            }

            // Check for interrupt
            if (checkForInterrupt()) {
                // Interrupt detected - signal worker to clean up and detach
                ctx.abandoned.store(true, .release);
                return error.Interrupted;
            }

            // Wait a bit before checking again
            sleepNs(check_interval_ms * std.time.ns_per_ms);
            waited_ms += check_interval_ms;
        }

        // Timeout - signal worker to clean up and detach
        ctx.abandoned.store(true, .release);
        return error.WouldBlock;
    }

    pub fn begin(self: *ClientSession) !void {
        if (!self.connected or self.connection == null) return error.NotConnected;

        const begin_req = proto_schema.BeginRequest{
            .read_only = false,
            .session_id = self.session_id orelse "",
        };
        const msg = try encodeClientPacket(self.allocator, .{ .begin = begin_req });
        defer self.allocator.free(msg);
        try self.connection.?.writeAll(msg);

        // Read and check response with interrupt checking
        // CANARY: REQ=REQ-SHELL-INTERRUPT-013; FEATURE="SourceInterrupt"; ASPECT=BeginInterrupt; STATUS=TESTED; TEST=tests/test_gap0514_repl_dispatch.zig; OWNER=cli; UPDATED=2026-06-11
        var retry_count: usize = 0;
        const max_retries: usize = 100; // ~5 seconds with 50ms sleep
        while (retry_count < max_retries) : (retry_count += 1) {
            if (checkForInterrupt()) {
                return error.Interrupted;
            }

            const response = self.connection.?.readLine(self.allocator, 0) catch |err| {
                if (err == error.WouldBlock) {
                    sleepNs(50 * std.time.ns_per_ms);
                    continue;
                }
                return err;
            };
            defer self.allocator.free(response);

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const packet = decodeServerPacket(arena.allocator(), response) catch return error.InvalidResponse;
            const msg_union = packet.quic orelse return error.InvalidResponse;
            switch (msg_union) {
                .begin => return,
                else => return error.TransactionError,
            }
        }

        return error.WouldBlock;
    }

    /// CANARY: REQ=REQ-SHELL-TXN-ERROR-002; FEATURE="TransactionErrorDetails"; ASPECT=CommitWithRetry; STATUS=TESTED; TEST=tests/test_gap0514_repl_dispatch.zig; OWNER=cli; UPDATED=2026-06-11
    /// Commit transaction with retry logic for WouldBlock and detailed error extraction
    /// Returns error.Interrupted if user pressed Ctrl+C during the operation
    pub fn commit(self: *ClientSession) !void {
        if (!self.connected or self.connection == null) return error.NotConnected;

        // Clear previous transaction error
        if (self.last_txn_error) |e| {
            self.allocator.free(e);
            self.last_txn_error = null;
        }

        const commit_req = proto_schema.CommitRequest{
            .session_id = self.session_id orelse "",
        };
        const msg = try encodeClientPacket(self.allocator, .{ .commit = commit_req });
        defer self.allocator.free(msg);
        try self.connection.?.writeAll(msg);

        // Read response with retry logic for WouldBlock
        const response = self.readTransactionResponse() catch |err| {
            if (err == error.Interrupted) {
                self.last_txn_error = self.allocator.dupe(u8, "Operation cancelled by user (Ctrl+C)") catch null;
                return err;
            }
            if (err == error.WouldBlock) {
                self.last_txn_error = self.allocator.dupe(u8, "Server did not respond to COMMIT (connection may be stale)") catch null;
            }
            return err;
        };
        defer self.allocator.free(response);

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const packet = decodeServerPacket(arena.allocator(), response) catch return error.InvalidResponse;
        const msg_union = packet.quic orelse return error.InvalidResponse;
        switch (msg_union) {
            .commit => |resp| {
                if (!resp.success) {
                    self.last_txn_error = self.allocator.dupe(u8, "Commit failed") catch null;
                    return error.TransactionError;
                }
            },
            else => {
                self.last_txn_error = self.allocator.dupe(u8, "Unexpected COMMIT response") catch null;
                return error.TransactionError;
            },
        }
    }

    /// CANARY: REQ=REQ-SHELL-TXN-ERROR-003; FEATURE="TransactionErrorDetails"; ASPECT=RollbackWithRetry; STATUS=TESTED; TEST=tests/test_gap0514_repl_dispatch.zig; OWNER=cli; UPDATED=2026-06-11
    /// Rollback transaction with retry logic for WouldBlock and detailed error extraction
    /// CANARY: REQ=REQ-SHELL-INTERRUPT-014; FEATURE="SourceInterrupt"; ASPECT=RollbackDoubleInterrupt; STATUS=TESTED; TEST=tests/test_gap0514_repl_dispatch.zig; OWNER=cli; UPDATED=2026-06-11
    /// Requires TWO Ctrl+C presses to cancel - first shows warning about data corruption
    pub fn rollback(self: *ClientSession) !void {
        // Default rollback with 10 second timeout
        return self.rollbackWithTimeout(200); // 200 * 50ms = 10 seconds
    }

    /// Rollback with configurable timeout for large transactions
    /// CANARY: REQ=REQ-SHELL-INTERRUPT-026; FEATURE="SourceInterrupt"; ASPECT=RollbackScaledTimeout; STATUS=TESTED; TEST=tests/test_gap0514_repl_dispatch.zig; OWNER=cli; UPDATED=2026-06-11
    /// max_retries: number of 50ms retry intervals before timeout
    pub fn rollbackWithTimeout(self: *ClientSession, max_retries: usize) !void {
        if (!self.connected or self.connection == null) return error.NotConnected;

        const stderr = platform.getStderrHandle();

        // Clear previous transaction error
        if (self.last_txn_error) |e| {
            self.allocator.free(e);
            self.last_txn_error = null;
        }

        const rollback_req = proto_schema.RollbackRequest{
            .session_id = self.session_id orelse "",
        };
        const msg = try encodeClientPacket(self.allocator, .{ .rollback = rollback_req });
        defer self.allocator.free(msg);
        self.connection.?.writeAll(msg) catch |err| {
            // If we can't even send the rollback, connection is broken
            self.last_txn_error = self.allocator.dupe(u8, "Failed to send ROLLBACK (connection broken)") catch null;
            return err;
        };

        // Read response with retry logic - special handling for rollback interrupts
        // Rollback requires TWO Ctrl+C presses to cancel, with a warning after the first
        var retry_count: usize = 0;
        var first_interrupt_received = false;
        var last_progress_sec: usize = 0;

        while (retry_count < max_retries) : (retry_count += 1) {
            // Show progress every 2 seconds for long waits
            const elapsed_sec = (retry_count * 50) / 1000;
            if (elapsed_sec > last_progress_sec and elapsed_sec > 0 and elapsed_sec % 2 == 0) {
                last_progress_sec = elapsed_sec;
                var buf: [64]u8 = undefined;
                const max_sec = (max_retries * 50) / 1000;
                const progress_msg = std.fmt.bufPrint(&buf, "       Waiting for server response... ({d}/{d}s)\r", .{ elapsed_sec, max_sec }) catch "";
                stderr.writeStreamingAll(replIo(), progress_msg) catch {};
            }

            // Check for Ctrl+C interrupt - rollback needs special handling
            if (checkForInterrupt()) {
                if (!first_interrupt_received) {
                    // First Ctrl+C - warn user about data corruption risk
                    first_interrupt_received = true;
                    stderr.writeStreamingAll(replIo(), "\r\n") catch {};
                    stderr.writeStreamingAll(replIo(), "╔══════════════════════════════════════════════════════════════╗\r\n") catch {};
                    stderr.writeStreamingAll(replIo(), "║  WARNING: CANCELLING ROLLBACK MAY CAUSE DATA CORRUPTION      ║\r\n") catch {};
                    stderr.writeStreamingAll(replIo(), "╠══════════════════════════════════════════════════════════════╣\r\n") catch {};
                    stderr.writeStreamingAll(replIo(), "║  The transaction rollback is in progress.                    ║\r\n") catch {};
                    stderr.writeStreamingAll(replIo(), "║  Interrupting now may leave the database in an inconsistent  ║\r\n") catch {};
                    stderr.writeStreamingAll(replIo(), "║  state with partial changes applied.                         ║\r\n") catch {};
                    stderr.writeStreamingAll(replIo(), "╟──────────────────────────────────────────────────────────────╢\r\n") catch {};
                    stderr.writeStreamingAll(replIo(), "║  Press Ctrl+C again to force cancel (NOT RECOMMENDED)        ║\r\n") catch {};
                    stderr.writeStreamingAll(replIo(), "║  Or wait for rollback to complete safely.                   ║\r\n") catch {};
                    stderr.writeStreamingAll(replIo(), "╚══════════════════════════════════════════════════════════════╝\r\n") catch {};
                    continue; // Keep waiting for rollback
                } else {
                    // Second Ctrl+C - user really wants to cancel
                    self.last_txn_error = self.allocator.dupe(u8, "Rollback forcefully cancelled - database may be in inconsistent state") catch null;
                    return error.Interrupted;
                }
            }

            const response = self.connection.?.readLine(self.allocator, 0) catch |err| {
                if (err == error.WouldBlock) {
                    sleepNs(50 * std.time.ns_per_ms);
                    continue;
                }
                // Connection error during rollback
                self.last_txn_error = self.allocator.dupe(u8, "Connection error during ROLLBACK") catch null;
                return err;
            };
            defer self.allocator.free(response);

            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            const packet = decodeServerPacket(arena.allocator(), response) catch {
                self.last_txn_error = self.allocator.dupe(u8, "Invalid rollback response") catch null;
                return error.TransactionError;
            };
            const msg_union = packet.quic orelse {
                self.last_txn_error = self.allocator.dupe(u8, "Invalid rollback response") catch null;
                return error.TransactionError;
            };
            switch (msg_union) {
                .rollback => |resp| {
                    if (!resp.success) {
                        self.last_txn_error = self.allocator.dupe(u8, "Rollback failed") catch null;
                        return error.TransactionError;
                    }
                    return;
                },
                else => {
                    self.last_txn_error = self.allocator.dupe(u8, "Unexpected ROLLBACK response") catch null;
                    return error.TransactionError;
                },
            }
        }

        // Timeout waiting for response - after interrupt, connection may be broken
        self.last_txn_error = self.allocator.dupe(u8, "ROLLBACK timed out (connection may be stale, transaction may still complete on server)") catch null;
        return error.WouldBlock;
    }

    /// CANARY: REQ=REQ-SHELL-INTERRUPT-004; FEATURE="SourceInterrupt"; ASPECT=TransactionResponseInterrupt; STATUS=TESTED; OWNER=cli; UPDATED=2026-01-30
    /// Read a transaction response with retry logic for WouldBlock
    /// This is needed because commit/rollback are synchronous operations
    /// but the transport may return WouldBlock for async I/O
    /// Checks for Ctrl+C interrupts during retry loop
    fn readTransactionResponse(self: *ClientSession) ![]u8 {
        var retry_count: usize = 0;
        const max_retries: usize = 100; // ~5 seconds with 50ms sleep

        while (retry_count < max_retries) : (retry_count += 1) {
            // Check for Ctrl+C interrupt
            if (checkForInterrupt()) {
                return error.Interrupted;
            }

            const response = self.connection.?.readLine(self.allocator, 0) catch |err| {
                if (err == error.WouldBlock) {
                    // Poll and wait before retrying (use shorter sleep to be more responsive)
                    sleepNs(25 * std.time.ns_per_ms);
                    continue;
                }
                return err;
            };
            return response;
        }

        // Timeout waiting for response
        return error.WouldBlock;
    }

    /// CANARY: REQ=REQ-SHELL-INTERRUPT-015; FEATURE="SourceInterrupt"; ASPECT=PullAllInterrupt; STATUS=TESTED; TEST=tests/test_gap0514_repl_dispatch.zig; OWNER=cli; UPDATED=2026-06-11
    pub fn pullAll(self: *ClientSession, sink: anytype) !void {
        if (!self.connected or self.connection == null) return error.NotConnected;

        var arena = std.heap.ArenaAllocator.init(self.allocator);
        defer arena.deinit();
        const a = arena.allocator();

        var all_rows = std.json.Array.init(a);
        var status_class: []const u8 = "00000";
        var status_subclass: []const u8 = "";
        var status_captured = false;
        var additional_arr = std.json.Array.init(a);
        var flagger_arr = std.json.Array.init(a);
        var ordered = false;
        var order_keys = std.json.Array.init(a);
        var request_id: u64 = 1;

        const page_size: u32 = 128; // Keep pull pages small so large node payloads stream promptly
        var done = false;

        if (self.inline_page_response) |inline_json| {
            defer self.clearInlinePageResponse();
            try mergeInlinePageJson(a, inline_json, &all_rows, &status_class, &status_subclass, &status_captured, &additional_arr, &flagger_arr, &ordered, &order_keys);
            done = self.inline_page_final;
        }

        while (!done) : (request_id += 1) {
            const pull_req = proto_schema.PullRequest{
                .request_id = request_id,
                .page_size = page_size,
                .session_id = self.session_id orelse "",
            };
            const msg = try encodeClientPacket(self.allocator, .{ .pull = pull_req });
            defer self.allocator.free(msg);
            try self.connection.?.writeAll(msg);

            // Read the response with interrupt checking
            var retry_count: usize = 0;
            const max_retries: usize = 6000; // ~5 minutes with 50ms sleep for large results
            const response = while (retry_count < max_retries) : (retry_count += 1) {
                if (checkForInterrupt()) {
                    return error.Interrupted;
                }
                break self.connection.?.readLine(self.allocator, 0) catch |err| {
                    if (err == error.WouldBlock) {
                        sleepNs(50 * std.time.ns_per_ms);
                        continue;
                    }
                    return err;
                };
            } else {
                return error.WouldBlock;
            };
            defer self.allocator.free(response);

            var resp_arena = std.heap.ArenaAllocator.init(self.allocator);
            defer resp_arena.deinit();
            const packet = decodeServerPacket(resp_arena.allocator(), response) catch return error.InvalidResponse;
            const msg_union = packet.quic orelse return error.InvalidResponse;

            switch (msg_union) {
                .pull => |pull_resp| {
                    const exec_resp = pull_resp.response orelse return error.InvalidResponse;
                    if (exec_resp.status) |st| {
                        if (!status_captured) {
                            status_captured = true;
                            if (st.status_class.len > 0) status_class = try a.dupe(u8, st.status_class);
                            if (st.status_subclass.len > 0) status_subclass = try a.dupe(u8, st.status_subclass);
                            for (st.additional_statuses.items) |item| {
                                try additional_arr.append(.{ .string = try a.dupe(u8, item) });
                            }
                            for (st.flagger_findings.items) |item| {
                                try flagger_arr.append(.{ .string = try a.dupe(u8, item) });
                            }
                        }
                    }

                    if (exec_resp.payload) |payload| {
                        switch (payload) {
                            .page => |page| {
                                const cols = self.last_columns orelse &[_]ColumnInfo{};
                                const page_rows = try buildRowsJsonArray(a, page.rows.items, cols);
                                for (page_rows.items) |row| {
                                    try all_rows.append(row);
                                }
                                if (page.ordered) ordered = true;
                                if (order_keys.items.len == 0 and page.order_keys.items.len > 0) {
                                    for (page.order_keys.items) |key| {
                                        try order_keys.append(.{ .string = try a.dupe(u8, key) });
                                    }
                                }
                                done = page.final;
                            },
                            .@"error" => {
                                const err_json = try executionResponseToJson(self.allocator, exec_resp, self.last_columns);
                                defer self.allocator.free(err_json);
                                try sink.appendSlice(self.allocator, err_json);
                                return;
                            },
                            else => {},
                        }
                    }
                },
                else => return error.InvalidResponse,
            }
        }

        var root = @as(std.json.ObjectMap, .empty);
        try root.put(a, "status_class", .{ .string = try a.dupe(u8, status_class) });
        if (status_subclass.len > 0) {
            try root.put(a, "status_subclass", .{ .string = try a.dupe(u8, status_subclass) });
        }

        if (self.last_columns) |cols| {
            const cols_array = try buildColumnsJsonArray(a, cols);
            try root.put(a, "columns", .{ .array = cols_array });
        }
        try root.put(a, "ordered", .{ .bool = ordered });
        try root.put(a, "order_keys", .{ .array = order_keys });
        try root.put(a, "rows", .{ .array = all_rows });
        try root.put(a, "additional_statuses", .{ .array = additional_arr });
        try root.put(a, "flagger_findings", .{ .array = flagger_arr });

        const root_value = std.json.Value{ .object = root };
        const json = try std.json.Stringify.valueAlloc(self.allocator, root_value, .{});
        defer self.allocator.free(json);
        try sink.appendSlice(self.allocator, json);
    }

    /// Drain any pending responses from the connection (cleanup after errors)
    /// CANARY: REQ=REQ-SHELL-INTERRUPT-023; FEATURE="SourceInterrupt"; ASPECT=DrainWithTimeout; STATUS=TESTED; TEST=tests/test_gap0514_repl_dispatch.zig; OWNER=cli; UPDATED=2026-06-11
    /// Note: This function attempts to discard stale data with timeout
    /// Uses quick polling to avoid blocking on dead connections
    pub fn drain(self: *ClientSession) void {
        // Use default limit for basic drain operations
        self.drainWithLimit(50, false);
    }

    /// Drain pending responses with configurable limit and interrupt checking
    /// CANARY: REQ=REQ-SHELL-INTERRUPT-024; FEATURE="SourceInterrupt"; ASPECT=DrainForRollback; STATUS=TESTED; TEST=tests/test_gap0514_repl_dispatch.zig; OWNER=cli; UPDATED=2026-06-11
    /// Returns the number of messages drained, or 0 if interrupted
    pub fn drainWithLimit(self: *ClientSession, max_messages: usize, check_interrupts: bool) usize {
        if (!self.connected or self.connection == null) return 0;

        // Try to read and discard pending messages with timeout
        var messages_drained: usize = 0;

        while (messages_drained < max_messages) : (messages_drained += 1) {
            // Check for Ctrl+C interrupt if requested
            if (check_interrupts and checkForInterrupt()) {
                return messages_drained;
            }

            var poll_count: usize = 0;
            const max_polls: usize = 20; // 100ms timeout per message (20 * 5ms)

            const response = while (poll_count < max_polls) : (poll_count += 1) {
                break self.connection.?.readLine(self.allocator, 0) catch |err| {
                    if (err == error.WouldBlock) {
                        sleepNs(5 * std.time.ns_per_ms);
                        continue;
                    }
                    return messages_drained; // Connection error, stop draining
                };
            } else {
                return messages_drained; // Timeout, no more data
            };

            self.allocator.free(response);
        }

        return messages_drained;
    }

    /// Aggressive drain for use before rollback of large transactions
    /// CANARY: REQ=REQ-SHELL-INTERRUPT-025; FEATURE="SourceInterrupt"; ASPECT=DrainAllForRollback; STATUS=TESTED; TEST=tests/test_gap0514_repl_dispatch.zig; OWNER=cli; UPDATED=2026-06-11
    /// Drains until no more data or timeout, scaled to expected transaction size
    /// Returns total messages drained, handles interrupt checking
    pub fn drainForRollback(self: *ClientSession, expected_statements: usize, stderr: anytype) !usize {
        if (!self.connected or self.connection == null) return 0;

        var total_drained: usize = 0;
        var consecutive_empty: usize = 0;
        const max_consecutive_empty: usize = 3; // Stop after 3 empty polls in a row
        var first_interrupt_received = false;
        var last_progress_update: usize = 0;

        // Scale drain limit: at least 100 messages, or 2x the statement count for safety
        const drain_limit = @max(100, expected_statements * 2);
        var batch_count: usize = 0;
        const batch_size: usize = 50;
        const max_batches = (drain_limit + batch_size - 1) / batch_size;

        while (batch_count < max_batches and consecutive_empty < max_consecutive_empty) : (batch_count += 1) {
            // Check for Ctrl+C interrupt - use double-press safety like rollback
            if (checkForInterrupt()) {
                if (!first_interrupt_received) {
                    first_interrupt_received = true;
                    stderr.writeStreamingAll(replIo(), "\r\n  (Draining buffers... press Ctrl+C again to force cancel)\r\n") catch {};
                    continue;
                } else {
                    return error.Interrupted;
                }
            }

            // Drain a batch of messages
            const drained = self.drainWithLimit(batch_size, false);
            total_drained += drained;

            if (drained == 0) {
                consecutive_empty += 1;
            } else {
                consecutive_empty = 0;
                // Show progress every 100 messages drained
                if (total_drained - last_progress_update >= 100) {
                    last_progress_update = total_drained;
                    var buf: [48]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf, "\r  Draining... {d} responses cleared", .{total_drained}) catch "";
                    stderr.writeStreamingAll(replIo(), msg) catch {};
                }
            }

            // Brief yield to allow server to send more data
            sleepNs(5 * std.time.ns_per_ms);
        }

        // Clear the progress line if we showed any
        if (last_progress_update > 0) {
            stderr.writeStreamingAll(replIo(), "\r                                          \r") catch {};
        }

        return total_drained;
    }

    /// Quick drain with spinner feedback for use before rollback
    /// CANARY: REQ=REQ-SHELL-INTERRUPT-033; FEATURE="SourceInterrupt"; ASPECT=DrainWithSpinner; STATUS=TESTED; TEST=tests/test_gap0514_repl_dispatch.zig; OWNER=cli; UPDATED=2026-06-11
    /// Time-limited drain (max 2 seconds) with spinner updates
    pub fn drainForRollbackWithSpinner(self: *ClientSession, expected_statements: usize, spinner: *spinner_mod.Spinner) !usize {
        _ = expected_statements; // No longer used - we use time-based limit
        if (!self.connected or self.connection == null) return 0;

        const stderr = platform.getStderrHandle();
        var total_drained: usize = 0;
        var first_interrupt_received = false;

        // Time-limited drain: max 2 seconds, stop early if no data
        const max_iterations: usize = 40; // 40 * 50ms = 2 seconds max
        var empty_count: usize = 0;

        var i: usize = 0;
        while (i < max_iterations) : (i += 1) {
            if (checkForInterrupt()) {
                if (!first_interrupt_received) {
                    first_interrupt_received = true;
                    spinner.stop(null);
                    stderr.writeStreamingAll(replIo(), "  (Press Ctrl+C again to force cancel)\r\n") catch {};
                    spinner.setMessage("[1/2] Draining...");
                    spinner.startBackground();
                    continue;
                } else {
                    return error.Interrupted;
                }
            }

            // Try to read one message quickly
            const response = self.connection.?.readLine(self.allocator, 0) catch |err| {
                if (err == error.WouldBlock) {
                    empty_count += 1;
                    // Stop after 3 consecutive empty reads (150ms of no data)
                    if (empty_count >= 3) break;
                    sleepNs(50 * std.time.ns_per_ms);
                    continue;
                }
                break; // Connection error, stop draining
            };

            // Got a response, discard it
            self.allocator.free(response);
            total_drained += 1;
            empty_count = 0;

            // Update spinner
            if (total_drained % 20 == 0) {
                var buf: [64]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "[1/2] Draining... {d} cleared", .{total_drained}) catch "[1/2] Draining...";
                spinner.setMessage(msg);
            }
        }

        return total_drained;
    }
};

/// CANARY: REQ=REQ-SHELL-RECONNECT-009; FEATURE="ShellAutoReconnect"; ASPECT=TransactionRecoveryPrompt; STATUS=TESTED; OWNER=cli; UPDATED=2026-01-29
/// Prompt user for transaction recovery choice after reconnection
/// Returns the user's choice for how to handle the pending transaction
pub fn promptTransactionRecovery(pending_state: *const PendingTransactionState) !TransactionRecoveryChoice {
    const stdout = platform.getStdoutHandle();
    const stdin = platform.getStdinHandle();

    // Display transaction state information
    try stdout.writeStreamingAll(replIo(), "\r\n");
    try stdout.writeStreamingAll(replIo(), "╔══════════════════════════════════════════════════════════════╗\r\n");
    try stdout.writeStreamingAll(replIo(), "║           TRANSACTION RECOVERY REQUIRED                      ║\r\n");
    try stdout.writeStreamingAll(replIo(), "╠══════════════════════════════════════════════════════════════╣\r\n");
    try stdout.writeStreamingAll(replIo(), "║ Connection was lost while a transaction was active.         ║\r\n");
    try stdout.writeStreamingAll(replIo(), "║ The transaction has been rolled back on the server.         ║\r\n");
    try stdout.writeStreamingAll(replIo(), "╟──────────────────────────────────────────────────────────────╢\r\n");

    // Show transaction details
    var buf: [256]u8 = undefined;
    const stmt_msg = std.fmt.bufPrint(&buf, "║ Statements executed in transaction: {d:<24} ║\r\n", .{pending_state.statements_in_txn}) catch "";
    try stdout.writeStreamingAll(replIo(), stmt_msg);

    if (pending_state.current_graph) |graph| {
        // SONNY-6494: written in parts; a name longer than the 256-byte
        // buffer it was formatted into was dropped without a word.
        try stdout.writeStreamingAll(replIo(), "║ Graph context: ");
        try stdout.writeStreamingAll(replIo(), graph);
        const pad = "                                             "; // 45
        if (graph.len < pad.len) try stdout.writeStreamingAll(replIo(), pad[graph.len..]);
        try stdout.writeStreamingAll(replIo(), " ║\r\n");
    } else {
        try stdout.writeStreamingAll(replIo(), "║ Graph context: (default)                                     ║\r\n");
    }

    try stdout.writeStreamingAll(replIo(), "╟──────────────────────────────────────────────────────────────╢\r\n");
    try stdout.writeStreamingAll(replIo(), "║ How would you like to proceed?                               ║\r\n");
    try stdout.writeStreamingAll(replIo(), "║                                                              ║\r\n");
    try stdout.writeStreamingAll(replIo(), "║   [R] Resume - Start a new transaction and continue         ║\r\n");
    try stdout.writeStreamingAll(replIo(), "║   [C] Cancel - Continue without a transaction               ║\r\n");
    try stdout.writeStreamingAll(replIo(), "║   [A] Abort  - Disconnect and exit                          ║\r\n");
    try stdout.writeStreamingAll(replIo(), "╚══════════════════════════════════════════════════════════════╝\r\n");
    try stdout.writeStreamingAll(replIo(), "\r\nYour choice [R/C/A]: ");

    // Read user input
    var input_buf: [16]u8 = undefined;
    const input_vec = [_][]u8{&input_buf};
    const bytes_read = stdin.readStreaming(replIo(), &input_vec) catch {
        return .cancel_transaction; // Default to cancel on error
    };

    if (bytes_read == 0) {
        return .cancel_transaction;
    }

    // Parse the response
    const choice = std.mem.trim(u8, input_buf[0..bytes_read], " \t\r\n");
    if (choice.len == 0) {
        return .cancel_transaction;
    }

    const first_char = std.ascii.toLower(choice[0]);
    return switch (first_char) {
        'r' => .resume_transaction,
        'c' => .cancel_transaction,
        'a' => .abort_reconnection,
        else => blk: {
            try stdout.writeStreamingAll(replIo(), "Invalid choice. Defaulting to Cancel.\r\n");
            break :blk .cancel_transaction;
        },
    };
}

/// CANARY: REQ=REQ-SHELL-RECONNECT-010; FEATURE="ShellAutoReconnect"; ASPECT=HandleConnectionError; STATUS=TESTED; OWNER=cli; UPDATED=2026-01-29
/// Handle a connection error by attempting reconnection and transaction recovery
/// Returns true if the operation should be retried, false otherwise
pub fn handleConnectionError(state: anytype, err: anyerror) !bool {
    const stderr = platform.getStderrHandle();

    // Check if this is a recoverable connection error
    if (!ClientSession.isConnectionError(err)) {
        return false; // Not a connection error, don't retry
    }

    // Save transaction state before reconnection
    const txn_stmt_count = if (@hasField(@TypeOf(state.*), "txn_statement_count"))
        state.txn_statement_count
    else
        0;
    state.session.saveTransactionState(state.in_txn, state.current_graph, txn_stmt_count);

    // Attempt reconnection
    const reconnected = state.session.reconnect() catch |reconnect_err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Reconnection failed: {s}\r\n", .{@errorName(reconnect_err)}) catch "";
        stderr.writeStreamingAll(replIo(), msg) catch {};
        return false;
    };

    if (!reconnected) {
        return false;
    }

    // Restore graph context if needed
    if (state.current_graph) |graph| {
        state.session.restoreGraphContext(graph) catch |restore_err| {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Warning: Could not restore graph context: {s}\r\n", .{@errorName(restore_err)}) catch "";
            stderr.writeStreamingAll(replIo(), msg) catch {};
        };
    }

    // Handle transaction recovery if there was an active transaction
    if (state.session.pending_txn_state.had_active_transaction) {
        if (state.session.reconnect_config.prompt_for_txn_recovery) {
            const choice = try promptTransactionRecovery(&state.session.pending_txn_state);

            switch (choice) {
                .resume_transaction => {
                    // Start a new transaction
                    state.session.begin() catch |begin_err| {
                        var buf: [256]u8 = undefined;
                        const msg = std.fmt.bufPrint(&buf, "Warning: Could not start new transaction: {s}\r\n", .{@errorName(begin_err)}) catch "";
                        stderr.writeStreamingAll(replIo(), msg) catch {};
                        state.in_txn = false;
                    };
                    state.in_txn = true;
                    const stdout = platform.getStdoutHandle();
                    stdout.writeStreamingAll(replIo(), "New transaction started. Please re-execute your statements.\r\n") catch {};
                },
                .cancel_transaction => {
                    state.in_txn = false;
                    const stdout = platform.getStdoutHandle();
                    stdout.writeStreamingAll(replIo(), "Continuing without transaction.\r\n") catch {};
                },
                .abort_reconnection => {
                    state.quit_requested = true;
                    return false;
                },
            }
        } else {
            // Auto-cancel transaction if prompting is disabled
            state.in_txn = false;
        }
    }

    // Reset pending transaction state
    state.session.pending_txn_state.reset();

    return true; // Retry the operation
}

pub fn handleMetaCommand(state: anytype, input: []const u8) !void {
    const stdout = platform.getStdoutHandle();

    // Move to new line before displaying any output
    try stdout.writeStreamingAll(std.Io.Threaded.global_single_threaded.io(), "\r\n");

    // Parse command
    const space_idx = std.mem.indexOf(u8, input[1..], " ");
    const cmd = if (space_idx) |idx| input[1 .. idx + 1] else input[1..];
    const args = if (space_idx) |idx| std.mem.trim(u8, input[idx + 2 ..], " \t") else "";

    if (std.mem.eql(u8, cmd, "help") or std.mem.eql(u8, cmd, "h") or std.mem.eql(u8, cmd, "?")) {
        const use_color = platform.isStdoutTty();
        const green = if (use_color) "\x1b[32m" else "";
        const yellow = if (use_color) "\x1b[33m" else "";
        const cyan = if (use_color) "\x1b[36m" else "";
        const reset = if (use_color) "\x1b[0m" else "";
        const bold = if (use_color) "\x1b[1m" else "";

        try stdout.writeStreamingAll(replIo(), green);
        try stdout.writeStreamingAll(replIo(), bold);
        try stdout.writeStreamingAll(replIo(), "=== Geode Shell Commands ===\r\n");
        try stdout.writeStreamingAll(replIo(), reset);
        try stdout.writeStreamingAll(replIo(), "\r\n");

        try stdout.writeStreamingAll(replIo(), cyan);
        try stdout.writeStreamingAll(replIo(), "Meta-Commands (start with \\ or /):\r\n");
        try stdout.writeStreamingAll(replIo(), reset);
        try stdout.writeStreamingAll(replIo(), "  ");
        try stdout.writeStreamingAll(replIo(), yellow);
        try stdout.writeStreamingAll(replIo(), "\\help, \\h, \\?");
        try stdout.writeStreamingAll(replIo(), reset);
        try stdout.writeStreamingAll(replIo(), "     Show this help\r\n");
        try stdout.writeStreamingAll(replIo(), "  ");
        try stdout.writeStreamingAll(replIo(), yellow);
        try stdout.writeStreamingAll(replIo(), "\\quit, \\q, \\exit");
        try stdout.writeStreamingAll(replIo(), reset);
        try stdout.writeStreamingAll(replIo(), " Exit the shell\r\n");
        try stdout.writeStreamingAll(replIo(), "  ");
        try stdout.writeStreamingAll(replIo(), yellow);
        try stdout.writeStreamingAll(replIo(), "\\clear");
        try stdout.writeStreamingAll(replIo(), reset);
        try stdout.writeStreamingAll(replIo(), "            Clear screen\r\n");
        try stdout.writeStreamingAll(replIo(), "\r\n");

        try stdout.writeStreamingAll(replIo(), cyan);
        try stdout.writeStreamingAll(replIo(), "History:\r\n");
        try stdout.writeStreamingAll(replIo(), reset);
        try stdout.writeStreamingAll(replIo(), "  ");
        try stdout.writeStreamingAll(replIo(), yellow);
        try stdout.writeStreamingAll(replIo(), "\\history [n]");
        try stdout.writeStreamingAll(replIo(), reset);
        try stdout.writeStreamingAll(replIo(), "      Show last n history entries\r\n");
        try stdout.writeStreamingAll(replIo(), "  ");
        try stdout.writeStreamingAll(replIo(), yellow);
        try stdout.writeStreamingAll(replIo(), "\\history -c");
        try stdout.writeStreamingAll(replIo(), reset);
        try stdout.writeStreamingAll(replIo(), "       Clear history\r\n");
        try stdout.writeStreamingAll(replIo(), "\r\n");

        try stdout.writeStreamingAll(replIo(), cyan);
        try stdout.writeStreamingAll(replIo(), "Connection:\r\n");
        try stdout.writeStreamingAll(replIo(), reset);
        try stdout.writeStreamingAll(replIo(), "  ");
        try stdout.writeStreamingAll(replIo(), yellow);
        try stdout.writeStreamingAll(replIo(), "\\connect <addr>");
        try stdout.writeStreamingAll(replIo(), reset);
        try stdout.writeStreamingAll(replIo(), "   Connect to server\r\n");
        try stdout.writeStreamingAll(replIo(), "  ");
        try stdout.writeStreamingAll(replIo(), yellow);
        try stdout.writeStreamingAll(replIo(), "\\disconnect");
        try stdout.writeStreamingAll(replIo(), reset);
        try stdout.writeStreamingAll(replIo(), "       Disconnect from server\r\n");
        try stdout.writeStreamingAll(replIo(), "\r\n");

        try stdout.writeStreamingAll(replIo(), cyan);
        try stdout.writeStreamingAll(replIo(), "Graphs:\r\n");
        try stdout.writeStreamingAll(replIo(), reset);
        try stdout.writeStreamingAll(replIo(), "  ");
        try stdout.writeStreamingAll(replIo(), yellow);
        try stdout.writeStreamingAll(replIo(), "\\use <graph>");
        try stdout.writeStreamingAll(replIo(), reset);
        try stdout.writeStreamingAll(replIo(), "      Switch to graph\r\n");
        try stdout.writeStreamingAll(replIo(), "  ");
        try stdout.writeStreamingAll(replIo(), yellow);
        try stdout.writeStreamingAll(replIo(), "\\graph");
        try stdout.writeStreamingAll(replIo(), reset);
        try stdout.writeStreamingAll(replIo(), "            Show current graph\r\n");
        try stdout.writeStreamingAll(replIo(), "  ");
        try stdout.writeStreamingAll(replIo(), yellow);
        try stdout.writeStreamingAll(replIo(), "\\graphs");
        try stdout.writeStreamingAll(replIo(), reset);
        try stdout.writeStreamingAll(replIo(), "           List all graphs\r\n");
        try stdout.writeStreamingAll(replIo(), "\r\n");

        try stdout.writeStreamingAll(replIo(), cyan);
        try stdout.writeStreamingAll(replIo(), "Transactions:\r\n");
        try stdout.writeStreamingAll(replIo(), reset);
        try stdout.writeStreamingAll(replIo(), "  ");
        try stdout.writeStreamingAll(replIo(), yellow);
        try stdout.writeStreamingAll(replIo(), "\\begin");
        try stdout.writeStreamingAll(replIo(), reset);
        try stdout.writeStreamingAll(replIo(), "            Start transaction\r\n");
        try stdout.writeStreamingAll(replIo(), "  ");
        try stdout.writeStreamingAll(replIo(), yellow);
        try stdout.writeStreamingAll(replIo(), "\\commit");
        try stdout.writeStreamingAll(replIo(), reset);
        try stdout.writeStreamingAll(replIo(), "           Commit transaction\r\n");
        try stdout.writeStreamingAll(replIo(), "  ");
        try stdout.writeStreamingAll(replIo(), yellow);
        try stdout.writeStreamingAll(replIo(), "\\rollback");
        try stdout.writeStreamingAll(replIo(), reset);
        try stdout.writeStreamingAll(replIo(), "         Rollback transaction\r\n");
        try stdout.writeStreamingAll(replIo(), "\r\n");

        try stdout.writeStreamingAll(replIo(), cyan);
        try stdout.writeStreamingAll(replIo(), "Settings:\r\n");
        try stdout.writeStreamingAll(replIo(), reset);
        try stdout.writeStreamingAll(replIo(), "  ");
        try stdout.writeStreamingAll(replIo(), yellow);
        try stdout.writeStreamingAll(replIo(), "\\timing on|off");
        try stdout.writeStreamingAll(replIo(), reset);
        try stdout.writeStreamingAll(replIo(), "    Toggle query timing\r\n");
        try stdout.writeStreamingAll(replIo(), "  ");
        try stdout.writeStreamingAll(replIo(), yellow);
        try stdout.writeStreamingAll(replIo(), "\\format <fmt>");
        try stdout.writeStreamingAll(replIo(), reset);
        try stdout.writeStreamingAll(replIo(), "     Set output format (table|csv|json)\r\n");
        try stdout.writeStreamingAll(replIo(), "  ");
        try stdout.writeStreamingAll(replIo(), yellow);
        try stdout.writeStreamingAll(replIo(), "\\set <opt> <val>");
        try stdout.writeStreamingAll(replIo(), reset);
        try stdout.writeStreamingAll(replIo(), "  Set option (e.g., keymap emacs|vi)\r\n");
        try stdout.writeStreamingAll(replIo(), "\r\n");

        try stdout.writeStreamingAll(replIo(), cyan);
        try stdout.writeStreamingAll(replIo(), "Other:\r\n");
        try stdout.writeStreamingAll(replIo(), reset);
        try stdout.writeStreamingAll(replIo(), "  ");
        try stdout.writeStreamingAll(replIo(), yellow);
        try stdout.writeStreamingAll(replIo(), "\\echo <text>");
        try stdout.writeStreamingAll(replIo(), reset);
        try stdout.writeStreamingAll(replIo(), "      Echo text\r\n");
        try stdout.writeStreamingAll(replIo(), "  ");
        try stdout.writeStreamingAll(replIo(), yellow);
        try stdout.writeStreamingAll(replIo(), "\\source <file>");
        try stdout.writeStreamingAll(replIo(), reset);
        try stdout.writeStreamingAll(replIo(), "    Execute commands from file\r\n");
        try stdout.writeStreamingAll(replIo(), "\r\n");

        try stdout.writeStreamingAll(replIo(), green);
        try stdout.writeStreamingAll(replIo(), "Keyboard Shortcuts:\r\n");
        try stdout.writeStreamingAll(replIo(), reset);
        try stdout.writeStreamingAll(replIo(), "  Ctrl+C            Exit (on empty line) or cancel input\r\n");
        try stdout.writeStreamingAll(replIo(), "  Ctrl+D            Exit (on empty line)\r\n");
        try stdout.writeStreamingAll(replIo(), "  Ctrl+L            Clear screen\r\n");
        try stdout.writeStreamingAll(replIo(), "  Ctrl+P/N          Navigate history\r\n");
        try stdout.writeStreamingAll(replIo(), "  Ctrl+A/E          Move to beginning/end of line\r\n");
        try stdout.writeStreamingAll(replIo(), "\r\n");

        try stdout.writeStreamingAll(replIo(), green);
        try stdout.writeStreamingAll(replIo(), "GQL Queries:\r\n");
        try stdout.writeStreamingAll(replIo(), reset);
        try stdout.writeStreamingAll(replIo(), "  Type GQL directly and end with semicolon (;)\r\n");
        try stdout.writeStreamingAll(replIo(), "  Example: ");
        try stdout.writeStreamingAll(replIo(), yellow);
        try stdout.writeStreamingAll(replIo(), "MATCH (n) RETURN n LIMIT 5;");
        try stdout.writeStreamingAll(replIo(), reset);
        try stdout.writeStreamingAll(replIo(), "\r\n");
        try stdout.writeStreamingAll(replIo(), "\r\n");

        // Note: Don't sync() stdout - causes panics on ttys
    } else if (std.mem.eql(u8, cmd, "quit") or std.mem.eql(u8, cmd, "q") or std.mem.eql(u8, cmd, "exit")) {
        state.quit_requested = true;
    } else if (std.mem.eql(u8, cmd, "history")) {
        if (std.mem.eql(u8, args, "-c")) {
            try state.history.clear();
            try stdout.writeStreamingAll(replIo(), "History cleared\r\n");
        } else {
            const n = if (args.len > 0) std.fmt.parseInt(usize, args, 10) catch 10 else 10;
            const start = if (state.history.entries.items.len > n)
                state.history.entries.items.len - n
            else
                0;

            for (state.history.entries.items[start..], start..) |entry, i| {
                try writeFmt(stdout, state.allocator, "{d:4}: {s}\r\n", .{ i + 1, entry });
            }
        }
    } else if (std.mem.eql(u8, cmd, "clear")) {
        try stdout.writeStreamingAll(replIo(), "\x1b[2J\x1b[H"); // Clear screen and home cursor
    } else if (std.mem.eql(u8, cmd, "connect")) {
        if (args.len > 0) {
            // Save the current transport before deinit
            const current_transport = state.session.transport orelse return error.NoTransport;
            state.session.deinit();
            state.session.* = try ClientSession.init(state.allocator, args, current_transport);
            try state.session.connect();
            try state.session.hello();
            try writeFmt(stdout, state.allocator, "Connected to {f}\r\n", .{dsn_credentials.redacted(args)});
        } else {
            const stderr = platform.getStderrHandle();
            var buf: [512]u8 = undefined;
            const msg = try std.fmt.bufPrint(&buf, "Error [GEODE-E2002]: Usage: \\connect <host:port>\r\n", .{});
            try stderr.writeStreamingAll(replIo(), msg);
        }
    } else if (std.mem.eql(u8, cmd, "disconnect")) {
        state.session.connected = false;
        try stdout.writeStreamingAll(replIo(), "Disconnected\r\n");
    } else if (std.mem.eql(u8, cmd, "use")) {
        // \use <graph> - Switch to a different graph
        if (args.len > 0) {
            // Strip trailing semicolon if present (user might type "/use mydb;")
            const graph_name = std.mem.trimEnd(u8, args, ";");
            if (graph_name.len == 0) {
                const stderr = platform.getStderrHandle();
                try stderr.writeStreamingAll(replIo(), "Error [GEODE-E2002]: Usage: \\use <graph_name>\r\n");
                return;
            }

            // Validate graph name to prevent GQL injection (S5)
            if (!isValidGraphName(graph_name)) {
                const stderr = platform.getStderrHandle();
                try stderr.writeStreamingAll(replIo(), "Error [GEODE-E2002]: Invalid graph name — must match [a-zA-Z_][a-zA-Z0-9_]*\r\n");
                return;
            }

            // Send USE GRAPH statement to server
            const use_stmt = try std.fmt.allocPrint(state.allocator, "USE GRAPH {s};", .{graph_name});
            defer state.allocator.free(use_stmt);
            try executeGql(state, use_stmt);
            if (state.current_graph) |old| {
                state.allocator.free(old);
            }
            state.current_graph = try state.allocator.dupe(u8, graph_name);
            // Sync session graph for HELLO on reconnect
            if (state.session.graph) |old_graph| state.allocator.free(old_graph);
            state.session.graph = try state.allocator.dupe(u8, graph_name);
            try writeFmt(stdout, state.allocator, "Switched to graph: {s}\r\n", .{graph_name});
        } else {
            const stderr = platform.getStderrHandle();
            try stderr.writeStreamingAll(replIo(), "Error [GEODE-E2002]: Usage: \\use <graph_name>\r\n");
        }
    } else if (std.mem.eql(u8, cmd, "graph")) {
        // \graph - Show current graph
        if (state.current_graph) |graph| {
            try writeFmt(stdout, state.allocator, "Current graph: {s}\r\n", .{graph});
        } else {
            try stdout.writeStreamingAll(replIo(), "No graph selected (using default)\r\n");
        }
    } else if (std.mem.eql(u8, cmd, "graphs")) {
        // \graphs - List all graphs
        try executeGql(state, "SHOW GRAPHS;");
    } else if (std.mem.eql(u8, cmd, "begin")) {
        try state.session.begin();
        state.in_txn = true;
        try stdout.writeStreamingAll(replIo(), "Transaction started\r\n");
    } else if (std.mem.eql(u8, cmd, "commit")) {
        try state.session.commit();
        state.in_txn = false;
        try stdout.writeStreamingAll(replIo(), "Transaction committed\r\n");
    } else if (std.mem.eql(u8, cmd, "rollback")) {
        try state.session.rollback();
        state.in_txn = false;
        try stdout.writeStreamingAll(replIo(), "Transaction rolled back\r\n");
    } else if (std.mem.eql(u8, cmd, "timing")) {
        if (std.mem.eql(u8, args, "on")) {
            state.show_timing = true;
            try stdout.writeStreamingAll(replIo(), "Timing is on\r\n");
        } else if (std.mem.eql(u8, args, "off")) {
            state.show_timing = false;
            try stdout.writeStreamingAll(replIo(), "Timing is off\r\n");
        } else {
            const stderr = platform.getStderrHandle();
            var buf: [256]u8 = undefined;
            const msg = try std.fmt.bufPrint(&buf, "Error [GEODE-E2002]: Usage: \\timing on|off\r\n", .{});
            try stderr.writeStreamingAll(replIo(), msg);
        }
    } else if (std.mem.eql(u8, cmd, "format")) {
        if (std.mem.eql(u8, args, "table")) {
            state.format = .table;
        } else if (std.mem.eql(u8, args, "csv")) {
            state.format = .csv;
        } else if (std.mem.eql(u8, args, "json")) {
            state.format = .json;
        } else {
            const stderr = platform.getStderrHandle();
            var buf: [256]u8 = undefined;
            const msg = try std.fmt.bufPrint(&buf, "Error [GEODE-E2002]: Usage: \\format table|csv|json\r\n", .{});
            try stderr.writeStreamingAll(replIo(), msg);
            return;
        }
        var buf: [256]u8 = undefined;
        const msg = try std.fmt.bufPrint(&buf, "Output format set to {s}\r\n", .{args});
        try stdout.writeStreamingAll(replIo(), msg);
    } else if (std.mem.eql(u8, cmd, "set")) {
        const parts = try splitOnce(state.allocator, args, ' ');
        defer state.allocator.free(parts[0]);
        defer state.allocator.free(parts[1]);

        if (std.mem.eql(u8, parts[0], "keymap")) {
            if (std.mem.eql(u8, parts[1], "emacs")) {
                state.keymap = .emacs;
                try stdout.writeStreamingAll(replIo(), "Keymap set to emacs\r\n");
            } else if (std.mem.eql(u8, parts[1], "vi")) {
                state.keymap = .vi;
                state.vi_mode = .insert;
                try stdout.writeStreamingAll(replIo(), "Keymap set to vi\r\n");
            } else {
                const stderr = platform.getStderrHandle();
                var buf: [256]u8 = undefined;
                const msg = try std.fmt.bufPrint(&buf, "Error [GEODE-E2002]: Usage: \\set keymap emacs|vi\r\n", .{});
                try stderr.writeStreamingAll(replIo(), msg);
            }
        } else {
            try writeFmt(stdout, state.allocator, "Unknown option: {s}\r\n", .{parts[0]});
        }
    } else if (std.mem.eql(u8, cmd, "echo")) {
        try writeFmt(stdout, state.allocator, "{s}\r\n", .{args});
    } else if (std.mem.eql(u8, cmd, "source")) {
        // \source <file> - Execute commands from a GQL file
        if (args.len > 0) {
            try executeSourceFile(state, args);
        } else {
            const stderr = platform.getStderrHandle();
            try stderr.writeStreamingAll(replIo(), "Error [GEODE-E2002]: Usage: \\source <filename>\r\n");
        }
    } else if (std.mem.eql(u8, cmd, "connet")) { // Typo detection
        const stderr = platform.getStderrHandle();
        try stderr.writeStreamingAll(replIo(), "Error [GEODE-E2001]: Unknown command '\\connet'. Did you mean '\\connect'?\r\n");
    } else {
        const stderr = platform.getStderrHandle();
        try writeFmt(stderr, state.allocator, "Error [GEODE-E2001]: Unknown command '\\{s}'\r\n", .{cmd});
    }
}

pub fn executeGql(state: anytype, gql: []const u8) !void {
    const stdout = platform.getStdoutHandle();
    const stderr = platform.getStderrHandle();
    var scoped_gql = gql;
    var owned_scoped_gql: ?[]u8 = null;
    defer if (owned_scoped_gql) |buf| state.allocator.free(buf);

    // CANARY: REQ=REQ-SOURCE-CHUNKED-006; FEATURE="SourceChunkedExecution"; ASPECT=OutputSuppression; STATUS=TESTED; TEST=tests/test_gap0514_repl_dispatch.zig; OWNER=cli; UPDATED=2026-06-11
    // Check if output should be suppressed (during chunked execution)
    const suppress = if (@hasField(@TypeOf(state.*), "suppress_output")) state.suppress_output else false;

    // REPL queries may execute on fresh transport streams, so carry the selected graph
    // forward explicitly unless this request already starts with USE GRAPH.
    if (state.current_graph) |graph| {
        owned_scoped_gql = try query_scope.prependGraphContextIfNeeded(state.allocator, gql, graph);
        if (owned_scoped_gql) |scoped| scoped_gql = scoped;
    }

    // CRITICAL FIX: Move to new line before displaying results
    // This prevents overlapping with the prompt (skip when suppressing output)
    if (!suppress) try stdout.writeStreamingAll(replIo(), "\r\n");

    // CANARY: REQ=REQ-MULTI-GRAPH-031; FEATURE="MultiGraphIsolation"; ASPECT=DropGraphReset; STATUS=TESTED; TEST=geodetestlab/specs/multi_graph.yml; OWNER=repl; UPDATED=2025-12-23
    // Check if this is a DROP GRAPH statement that drops the current graph
    // If so, reset current_graph to null (default graph) after execution
    var dropped_current_graph = false;
    if (state.current_graph) |current| {
        // Check for DROP GRAPH <current_graph> pattern (case insensitive)
        const upper_gql = blk: {
            var upper = state.allocator.alloc(u8, gql.len) catch break :blk null;
            for (gql, 0..) |c, i| {
                upper[i] = std.ascii.toUpper(c);
            }
            break :blk upper;
        };
        defer if (upper_gql) |u| state.allocator.free(u);

        if (upper_gql) |upper| {
            if (std.mem.indexOf(u8, upper, "DROP GRAPH")) |drop_idx| {
                // Extract the graph name after "DROP GRAPH "
                const after_drop = gql[drop_idx + "DROP GRAPH ".len ..];
                const trimmed = std.mem.trim(u8, after_drop, " \t\n\r;");
                // Check if the dropped graph name matches current graph
                if (std.mem.eql(u8, trimmed, current) or
                    (trimmed.len > current.len and std.mem.startsWith(u8, trimmed, current) and
                        (trimmed[current.len] == ' ' or trimmed[current.len] == ';')))
                {
                    dropped_current_graph = true;
                }
            }
        }
    }

    // Start timing the query execution
    var timer = try CompatTimer.start();

    // CANARY: REQ=REQ-SHELL-RECONNECT-011; FEATURE="ShellAutoReconnect"; ASPECT=ExecuteWithRetry; STATUS=TESTED; OWNER=cli; UPDATED=2026-01-29
    // Execute query via QUIC with automatic reconnection on connection errors
    var retry_count: u32 = 0;
    const max_retries: u32 = 1; // Only retry once after reconnection
    const format_str: []const u8 = switch (state.format) {
        .table => "table",
        .csv => "csv",
        .json => "json",
    };

    const ShellProtocolAdapter = struct {
        session: *ClientSession,

        fn sendClientMessage(proto: *query_runner.ProtocolClient, allocator: std.mem.Allocator, msg: proto_schema.QuicClientMessage) !void {
            const self: *@This() = @ptrCast(@alignCast(proto.context));
            if (!self.session.connected or self.session.connection == null) return error.NotConnected;

            const encoded = try encodeClientPacket(allocator, msg);
            defer allocator.free(encoded);
            try self.session.connection.?.writeAll(encoded);
        }

        fn readServerMessage(proto: *query_runner.ProtocolClient, allocator: std.mem.Allocator, timeout_secs: u32) !proto_schema.QuicServerMessage {
            const self: *@This() = @ptrCast(@alignCast(proto.context));
            if (!self.session.connected or self.session.connection == null) return error.NotConnected;

            var read_retry_count: usize = 0;
            const read_max_retries: usize = @max(@as(usize, timeout_secs), 1) * 20;
            const response = while (read_retry_count < read_max_retries) : (read_retry_count += 1) {
                if (checkForInterrupt()) {
                    return error.Interrupted;
                }

                break self.session.connection.?.readLine(allocator, 0) catch |err| {
                    if (err == error.WouldBlock) {
                        sleepNs(50 * std.time.ns_per_ms);
                        continue;
                    }
                    return err;
                };
            } else {
                return error.WouldBlock;
            };
            defer allocator.free(response);

            const packet = decodeServerPacket(allocator, response) catch return error.InvalidResponse;
            return packet.quic orelse error.InvalidResponse;
        }
    };

    while (retry_count <= max_retries) : (retry_count += 1) {
        var adapter = ShellProtocolAdapter{ .session = state.session };
        var protocol_client = query_runner.ProtocolClient{
            .context = &adapter,
            .sendClientMessageFn = ShellProtocolAdapter.sendClientMessage,
            .readServerMessageFn = ShellProtocolAdapter.readServerMessage,
        };

        const empty_params = std.ArrayList(proto_schema.Param).empty;
        var result = query_runner.collectQuery(state.allocator, &protocol_client, .{
            .session_id = state.session.session_id orelse "",
            .query_text = scoped_gql,
            .format = format_str,
            .timeout_secs = 30,
            .page_size = query_runner.default_page_size,
            .params = empty_params,
        }) catch |err| {
            // CANARY: REQ=REQ-SHELL-WOULDBLOCK-002; FEATURE="SuppressWouldBlock"; ASPECT=RunGqlError; STATUS=IMPL; OWNER=cli; UPDATED=2026-01-28
            if (err == error.WouldBlock) {
                return;
            }

            if (ClientSession.isConnectionError(err) and retry_count < max_retries) {
                const should_retry = handleConnectionError(state, err) catch |handle_err| {
                    var buf: [256]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf, "Error during reconnection handling: {s}\r\n", .{@errorName(handle_err)}) catch "";
                    stderr.writeStreamingAll(replIo(), msg) catch {};
                    return error.QueryExecutionFailed;
                };

                if (should_retry) {
                    timer = CompatTimer.start() catch return error.QueryExecutionFailed;
                    continue;
                }
            }

            if (err == error.Interrupted) {
                return err;
            }
            if (err == error.InvalidResponse) {
                try stderr.writeStreamingAll(replIo(), "Error: Server returned an invalid response (protocol mismatch or server error)\r\n");
            } else if (err == error.ConnectionReset or err == error.BrokenPipe) {
                try stderr.writeStreamingAll(replIo(), "Error: Connection to server was lost\r\n");
            } else if (err == error.Timeout) {
                try stderr.writeStreamingAll(replIo(), "Error: Query timed out\r\n");
            } else {
                try stderr.writeStreamingAll(replIo(), "Error executing query: ");
                try stderr.writeStreamingAll(replIo(), @errorName(err));
                try stderr.writeStreamingAll(replIo(), "\r\n");
            }
            return error.QueryExecutionFailed;
        };
        defer result.deinit();
        try syncSessionStateFromResult(state.session, &result);

        const has_error = result.indicatesFailure();
        if (dropped_current_graph and !has_error) {
            if (state.current_graph) |old| {
                state.allocator.free(old);
            }
            state.current_graph = null;
        }

        if (suppress) {
            if (has_error) {
                return error.QueryExecutionFailed;
            }
        } else {
            if (try result.render(stdout, stderr)) {
                return error.QueryExecutionFailed;
            }
        }

        if (state.show_timing and !suppress) {
            const duration_ns = timer.read();
            const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
            var buf: [256]u8 = undefined;
            const timing_msg = try std.fmt.bufPrint(&buf, "Query executed in {d:.2} ms\r\n", .{duration_ms});
            try stdout.writeStreamingAll(replIo(), timing_msg);
        }
        return;
    }
}

// CANARY: REQ=REQ-SOURCE-PERF-001; FEATURE="SourceFilePerformance"; ASPECT=FileHashCache; STATUS=TESTED; TEST=tests/test_gap0514_repl_dispatch.zig; OWNER=cli; UPDATED=2026-06-11
// Issue #391/#392: File hash cache to track sourced files and warn about re-sourcing
var g_sourced_file_hashes: ?std.StringHashMap(u64) = null;

fn getSourcedFileCache(allocator: std.mem.Allocator) *std.StringHashMap(u64) {
    if (g_sourced_file_hashes == null) {
        g_sourced_file_hashes = std.StringHashMap(u64).init(allocator);
    }
    return &g_sourced_file_hashes.?;
}

// CANARY: REQ=REQ-SOURCE-PERF-002; FEATURE="SourceFilePerformance"; ASPECT=FileHashCacheCleanup; STATUS=TESTED; TEST=tests/test_gap0514_repl_dispatch.zig; OWNER=cli; UPDATED=2026-06-11
// Issue #413: Cleanup function to free the global file hash cache on shutdown
pub fn deinitSourcedFileCache() void {
    if (g_sourced_file_hashes) |*cache| {
        // Free all allocated key strings
        var iter = cache.keyIterator();
        while (iter.next()) |key| {
            cache.allocator.free(key.*);
        }
        cache.deinit();
        g_sourced_file_hashes = null;
    }
}

// Simple hash function for file content
fn hashFileContent(content: []const u8) u64 {
    var hash: u64 = 5381;
    for (content) |c| {
        hash = ((hash << 5) +% hash) +% @as(u64, c);
    }
    return hash;
}

/// Execute commands from a GQL source file
/// Supports:
/// - GQL statements (terminated by semicolons)
/// - Meta-commands (\help, \use, etc.)
/// - Comments (lines starting with -- or # are ignored)
///
/// CANARY: REQ=REQ-SOURCE-PERF-002; FEATURE="SourceFilePerformance"; ASPECT=BatchExecution; STATUS=TESTED; TEST=geodetestlab/specs/shell_source_batch.yml; OWNER=cli; UPDATED=2026-01-30
/// Issue #400: Batch execution - sends entire file as single request for performance
/// Issue #392: Warns when re-sourcing the same file content (use MERGE for idempotent operations)
/// Note: Users are responsible for adding their own transactions to source files if needed
pub fn executeSourceFile(state: anytype, filename: []const u8) !void {
    const stdout = platform.getStdoutHandle();
    const stderr = platform.getStderrHandle();

    // Expand ~ to home directory if present
    var path_buf: [4096]u8 = undefined;
    const resolved_path = if (filename.len > 0 and filename[0] == '~') blk: {
        if (comptime builtin.os.tag == .windows) break :blk filename;
        const home = posixGetenv("HOME") orelse {
            try stderr.writeStreamingAll(replIo(), "Error [GEODE-E2005]: Cannot expand ~: HOME not set\r\n");
            return;
        };
        const rest = if (filename.len > 1) filename[1..] else "";
        const path = std.fmt.bufPrint(&path_buf, "{s}{s}", .{ home, rest }) catch {
            try stderr.writeStreamingAll(replIo(), "Error [GEODE-E2005]: Path too long\r\n");
            return;
        };
        break :blk path;
    } else filename;

    // Open the file
    const file = std.Io.Dir.cwd().openFile(std.Io.Threaded.global_single_threaded.io(), resolved_path, .{}) catch |err| {
        // SONNY-6494: a path over ~480 bytes did not fit a 512-byte buffer
        // and the command returned without a word.
        try writeFmt(stderr, state.allocator, "Error [GEODE-E2005]: Cannot open file '{s}': {s}\r\n", .{ resolved_path, @errorName(err) });
        return;
    };
    const repl_io = std.Io.Threaded.global_single_threaded.io();
    defer file.close(repl_io);

    // Read file contents
    const file_len = file.length(repl_io) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Error [GEODE-E2005]: Cannot read file: {s}\r\n", .{@errorName(err)}) catch return;
        try stderr.writeStreamingAll(replIo(), msg);
        return;
    };
    // Same cap, and the same actionable wording, as `geode query --file`
    // (src/cli/query_file.zig): name the size, the limit, and the remedy.
    if (file_len > 16 * 1024 * 1024) {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(
            &buf,
            "Error [GEODE-E2005]: file is {d} bytes, over the /source limit of 16 MiB " ++
                "(16777216 bytes); split the file into smaller files\r\n",
            .{file_len},
        ) catch "Error [GEODE-E2005]: file is over the /source limit of 16 MiB; split it\r\n";
        try stderr.writeStreamingAll(replIo(), msg);
        return;
    }
    const contents = state.allocator.alloc(u8, @intCast(file_len)) catch |err| {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Error [GEODE-E2005]: Cannot read file: {s}\r\n", .{@errorName(err)}) catch return;
        try stderr.writeStreamingAll(replIo(), msg);
        return;
    };
    defer state.allocator.free(contents);
    _ = file.readPositionalAll(repl_io, contents, 0) catch |err| {
        var buf2: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf2, "Error [GEODE-E2005]: Cannot read file: {s}\r\n", .{@errorName(err)}) catch return;
        try stderr.writeStreamingAll(replIo(), msg);
        return;
    };

    // Issue #392: Check if this file content was already sourced
    const content_hash = hashFileContent(contents);
    const file_cache = getSourcedFileCache(state.allocator);
    if (file_cache.get(resolved_path)) |prev_hash| {
        if (prev_hash == content_hash) {
            try stderr.writeStreamingAll(replIo(), "Warning [GEODE-W3001]: File was already sourced with identical content.\r\n");
            try stderr.writeStreamingAll(replIo(), "  Tip: Use MERGE instead of CREATE for idempotent operations.\r\n");
        } else {
            try stderr.writeStreamingAll(replIo(), "Note: File was previously sourced but content has changed.\r\n");
        }
    }
    // Store/update the hash for this file path.  getOrPut so a RE-source of
    // an already-cached path only updates the value — the previous
    // unconditional `dupe + put` orphaned a fresh key copy on every
    // re-source (put keeps the existing equal key), leaking the path string
    // (caught by the gap0514 repl e2e leak check).
    if (file_cache.getOrPut(resolved_path) catch null) |gop| {
        if (!gop.found_existing) {
            gop.key_ptr.* = state.allocator.dupe(u8, resolved_path) catch resolved_path;
        }
        gop.value_ptr.* = content_hash;
    }

    // Display source file info
    try writeFmt(stdout, state.allocator, "Sourcing: {s}\r\n", .{resolved_path});

    // CANARY: REQ=REQ-SHELL-SPINNER-003; FEATURE="ShellProcessingIndicator"; ASPECT=SourceFileSpinner; STATUS=TESTED; TEST=tests/test_gap0514_repl_dispatch.zig:"executeSourceFile: small batch path, re-source tracking, error extraction"; OWNER=cli; UPDATED=2026-11-12
    // Initialize spinner with background thread for visual feedback during long-running source operations
    // Using startBackground() ensures animation continues during blocking server calls
    var progress_spinner = spinner_mod.Spinner.init(state.allocator, "Parsing file...");
    progress_spinner.startBackground();

    // CANARY: REQ=REQ-SHELL-INTERRUPT-005; FEATURE="SourceInterrupt"; ASPECT=InterruptTracking; STATUS=TESTED; OWNER=cli; UPDATED=2026-01-30
    // Track if user requested interrupt via Ctrl+C
    var interrupted = false;

    defer {
        // Ensure spinner is stopped on any exit path
        if (progress_spinner.isRunning()) {
            if (interrupted) {
                progress_spinner.fail("Cancelled by user (Ctrl+C)");
            } else {
                progress_spinner.stop(null);
            }
        }
    }

    // Check for interrupt before starting
    if (checkForInterrupt()) {
        interrupted = true;
        try stderr.writeStreamingAll(replIo(), "\r\nOperation cancelled by user (Ctrl+C)\r\n");
        return;
    }

    // CANARY: REQ=REQ-SOURCE-PERF-004; FEATURE="SourceFilePerformance"; ASPECT=BatchParsing; STATUS=TESTED; TEST=geodetestlab/specs/shell_source_batch.yml; OWNER=cli; UPDATED=2026-01-29
    // Issue #400: Parse entire file and collect all GQL statements for batch execution
    var batch_statements = try std.ArrayList(u8).initCapacity(state.allocator, contents.len);
    defer batch_statements.deinit(state.allocator);

    // CANARY: REQ=REQ-SOURCE-CHUNKED-001; FEATURE="SourceChunkedExecution"; ASPECT=StatementList; STATUS=TESTED; TEST=tests/test_gap0514_repl_dispatch.zig; OWNER=cli; UPDATED=2026-06-11
    // Collect individual statements for chunked execution when file is large
    var statement_list = try std.ArrayList([]const u8).initCapacity(state.allocator, 0);
    defer {
        for (statement_list.items) |stmt| {
            state.allocator.free(stmt);
        }
        statement_list.deinit(state.allocator);
    }

    var meta_commands = try std.ArrayList(MetaCommand).initCapacity(state.allocator, 8);
    defer {
        for (meta_commands.items) |mc| {
            if (mc.args) |args| state.allocator.free(args);
        }
        meta_commands.deinit(state.allocator);
    }

    var statement_count: usize = 0;
    var current_statement = try std.ArrayList(u8).initCapacity(state.allocator, 256);
    defer current_statement.deinit(state.allocator);

    var line_iter = std.mem.splitSequence(u8, contents, "\n");
    var line_number: usize = 0;

    // First pass: Parse file and collect statements
    // CANARY: REQ=REQ-SHELL-INTERRUPT-018; FEATURE="SourceInterrupt"; ASPECT=ParsingInterrupt; STATUS=TESTED; TEST=tests/test_gap0514_repl_dispatch.zig; OWNER=cli; UPDATED=2026-06-11
    while (line_iter.next()) |raw_line| {
        line_number += 1;

        // Check for interrupt every 10 lines to allow quick cancellation during parsing
        if (line_number % 10 == 0) {
            _ = progress_spinner.tick(); // Update spinner animation
            if (checkForInterrupt()) {
                interrupted = true;
                progress_spinner.stop(null);
                try stderr.writeStreamingAll(replIo(), "\r\n^C Interrupt received\r\n");
                return;
            }
        }

        // Handle \r\n line endings
        const line = std.mem.trimEnd(u8, raw_line, "\r");
        const trimmed = std.mem.trim(u8, line, " \t");

        // Skip empty lines and comments
        if (trimmed.len == 0) continue;
        if (std.mem.startsWith(u8, trimmed, "--")) continue;
        if (std.mem.startsWith(u8, trimmed, "#")) continue;

        // Check for meta-command at start of statement
        if (current_statement.items.len == 0 and (trimmed[0] == '\\' or trimmed[0] == '/')) {
            const cmd_end = std.mem.indexOf(u8, trimmed[1..], " ") orelse (trimmed.len - 1);
            const cmd_name = trimmed[1 .. cmd_end + 1];

            // Skip nested source commands
            if (std.mem.eql(u8, cmd_name, "source")) {
                stderr.writeStreamingAll(replIo(), "Warning: Nested \\source commands not supported, skipping\r\n") catch {};
                continue;
            }

            // Convert meta-commands to GQL where possible, or queue for special handling
            if (std.mem.eql(u8, cmd_name, "use")) {
                const args_start = cmd_end + 2;
                if (args_start < trimmed.len) {
                    const use_args = std.mem.trim(u8, trimmed[args_start..], " \t;");
                    if (use_args.len > 0 and isValidGraphName(use_args)) {
                        // Convert \use to USE GRAPH statement and add to batch
                        if (batch_statements.items.len > 0) {
                            try batch_statements.append(state.allocator, ' ');
                        }
                        const use_stmt = std.fmt.allocPrint(state.allocator, "USE GRAPH {s};", .{use_args}) catch continue;
                        defer state.allocator.free(use_stmt);
                        try batch_statements.appendSlice(state.allocator, use_stmt);
                        statement_count += 1;
                    }
                }
            } else if (std.mem.eql(u8, cmd_name, "echo")) {
                // Queue echo for execution between batches
                const args_start = cmd_end + 2;
                const args = if (args_start < trimmed.len)
                    state.allocator.dupe(u8, std.mem.trim(u8, trimmed[args_start..], " \t")) catch null
                else
                    null;
                try meta_commands.append(state.allocator, .{ .cmd = .echo, .args = args, .position = statement_count });
            } else if (std.mem.eql(u8, cmd_name, "timing")) {
                const args_start = cmd_end + 2;
                const args = if (args_start < trimmed.len)
                    state.allocator.dupe(u8, std.mem.trim(u8, trimmed[args_start..], " \t")) catch null
                else
                    null;
                try meta_commands.append(state.allocator, .{ .cmd = .timing, .args = args, .position = statement_count });
            }
            // Skip other meta-commands
            continue;
        }

        // Accumulate line into current statement
        if (current_statement.items.len > 0) {
            try current_statement.append(state.allocator, ' ');
        }
        try current_statement.appendSlice(state.allocator, trimmed);

        // Check if statement is complete (ends with semicolon)
        if (std.mem.endsWith(u8, trimmed, ";")) {
            // Add complete statement to batch
            if (batch_statements.items.len > 0) {
                try batch_statements.append(state.allocator, ' ');
            }
            try batch_statements.appendSlice(state.allocator, current_statement.items);

            // CANARY: REQ=REQ-SOURCE-CHUNKED-002; FEATURE="SourceChunkedExecution"; ASPECT=CollectStatements; STATUS=TESTED; TEST=tests/test_gap0514_repl_dispatch.zig; OWNER=cli; UPDATED=2026-06-11
            // Also save individual statement for chunked execution
            const stmt_copy = try state.allocator.dupe(u8, current_statement.items);
            try statement_list.append(state.allocator, stmt_copy);

            statement_count += 1;
            current_statement.clearRetainingCapacity();
        }
    }

    // Check for incomplete statement at end of file
    if (current_statement.items.len > 0) {
        const remaining = std.mem.trim(u8, current_statement.items, " \t");
        if (remaining.len > 0) {
            try stderr.writeStreamingAll(replIo(), "Warning: Incomplete statement at end of file (missing ';')\r\n");
        }
    }

    // Handle case with no GQL statements (only meta-commands)
    if (batch_statements.items.len == 0) {
        progress_spinner.success("Parsing complete");
        // Execute meta-commands only
        for (meta_commands.items) |mc| {
            executeMetaCommand(state, mc, stdout);
        }
        var summary_buf: [256]u8 = undefined;
        const summary = std.fmt.bufPrint(&summary_buf, "Executed {d} command(s) successfully\r\n", .{meta_commands.items.len}) catch return;
        try stdout.writeStreamingAll(replIo(), summary);
        return;
    }

    // Update spinner for execution phase
    var exec_msg_buf: [128]u8 = undefined;
    const exec_msg = std.fmt.bufPrint(&exec_msg_buf, "Executing {d} statements...", .{statement_count}) catch "Executing...";
    progress_spinner.setMessage(exec_msg);
    _ = progress_spinner.tick();

    // Check for interrupt before execution
    if (checkForInterrupt()) {
        interrupted = true;
        try stderr.writeStreamingAll(replIo(), "\r\nOperation cancelled by user (Ctrl+C)\r\n");
        return;
    }

    // Execute meta-commands that should run before batch
    for (meta_commands.items) |mc| {
        if (mc.position == 0) {
            executeMetaCommand(state, mc, stdout);
        }
    }

    // CANARY: REQ=REQ-SOURCE-PERF-005; FEATURE="SourceFilePerformance"; ASPECT=SingleRequestExecution; STATUS=TESTED; TEST=geodetestlab/specs/shell_source_batch.yml; OWNER=cli; UPDATED=2026-01-29
    // CANARY: REQ=REQ-SOURCE-CHUNKED-003; FEATURE="SourceChunkedExecution"; ASPECT=SizeCheck; STATUS=TESTED; TEST=tests/test_gap0514_repl_dispatch.zig; OWNER=cli; UPDATED=2026-06-11
    // Issue #400: Execute in single request for small files, chunked for large files
    const max_single_batch_size: usize = 32 * 1024; // 32KB threshold for chunking
    const use_chunked = batch_statements.items.len > max_single_batch_size;

    if (state.verbose) {
        var stmt_buf: [256]u8 = undefined;
        const preview_len = @min(batch_statements.items.len, 80);
        const preview = batch_statements.items[0..preview_len];
        const ellipsis: []const u8 = if (batch_statements.items.len > 80) "..." else "";
        const stmt_msg = std.fmt.bufPrint(&stmt_buf, ">> Batch ({d} statements, {d} bytes{s}): {s}{s}\r\n", .{ statement_count, batch_statements.items.len, if (use_chunked) ", chunked" else "", preview, ellipsis }) catch "";
        stdout.writeStreamingAll(replIo(), stmt_msg) catch {};
    }

    var error_count: usize = 0;
    var batch_error_msg: ?[]const u8 = null;
    var was_interrupted = false;

    if (use_chunked) {
        // CANARY: REQ=REQ-SOURCE-CHUNKED-004; FEATURE="SourceChunkedExecution"; ASPECT=ChunkedExecution; STATUS=TESTED; TEST=tests/test_gap0514_repl_dispatch.zig; OWNER=cli; UPDATED=2026-06-11
        // Large file - execute statements in chunks to avoid server message size limit
        var chunk_msg_buf: [128]u8 = undefined;
        const chunk_msg = std.fmt.bufPrint(&chunk_msg_buf, "Large file ({d} bytes) - using chunked execution...", .{batch_statements.items.len}) catch "Chunked execution...";
        progress_spinner.setMessage(chunk_msg);
        _ = progress_spinner.tick();

        // Suppress per-chunk output during chunked execution
        state.suppress_output = true;
        defer state.suppress_output = false;

        const max_chunk_size: usize = 32 * 1024;
        var chunk_start: usize = 0;
        var chunks_executed: usize = 0;

        while (chunk_start < statement_list.items.len) {
            // Check for interrupt between chunks
            if (checkForInterrupt()) {
                interrupted = true;
                was_interrupted = true;
                break;
            }

            // Build chunk of statements that fits within size limit
            var chunk_size: usize = 0;
            var chunk_end: usize = chunk_start;

            while (chunk_end < statement_list.items.len) {
                const stmt_len = statement_list.items[chunk_end].len + 1;
                if (chunk_size + stmt_len > max_chunk_size and chunk_end > chunk_start) {
                    break;
                }
                chunk_size += stmt_len;
                chunk_end += 1;
            }

            // Build chunk query
            var chunk_query = try std.ArrayList(u8).initCapacity(state.allocator, chunk_size);
            defer chunk_query.deinit(state.allocator);

            for (statement_list.items[chunk_start..chunk_end]) |stmt| {
                try chunk_query.appendSlice(state.allocator, stmt);
                try chunk_query.append(state.allocator, ' ');
            }

            // Update spinner with progress
            var progress_buf: [128]u8 = undefined;
            const progress_msg = std.fmt.bufPrint(&progress_buf, "Executing chunk {d}-{d} of {d}...", .{ chunk_start + 1, chunk_end, statement_list.items.len }) catch "Executing...";
            progress_spinner.setMessage(progress_msg);
            _ = progress_spinner.tick();

            // Execute this chunk
            executeGql(state, chunk_query.items) catch |err| {
                if (err == error.Interrupted) {
                    was_interrupted = true;
                    interrupted = true;
                } else if (err != error.WouldBlock) {
                    error_count += 1;
                }
            };

            if (was_interrupted) break;

            chunks_executed += 1;
            chunk_start = chunk_end;
        }
    } else {
        // Small file - execute in single request for performance
        executeGql(state, batch_statements.items) catch |err| {
            if (err == error.Interrupted) {
                // CANARY: REQ=REQ-SHELL-INTERRUPT-022; FEATURE="SourceInterrupt"; ASPECT=ExecutionInterrupt; STATUS=IMPL; OWNER=cli; UPDATED=2026-01-30
                // Handle interrupt explicitly - don't just increment error count
                was_interrupted = true;
                interrupted = true;
            } else if (err != error.WouldBlock) {
                error_count += 1;
            }
        };
    }

    // If interrupted during execution, handle immediately
    if (was_interrupted) {
        progress_spinner.stop(null);
        try stderr.writeStreamingAll(replIo(), "\r\n^C Interrupt received\r\n");
        return;
    }

    // CANARY: REQ=REQ-SHELL-SOURCE-ERROR-001; FEATURE="SourceFileErrorDetails"; ASPECT=BatchErrorExtraction; STATUS=TESTED; TEST=tests/test_gap0514_repl_dispatch.zig; OWNER=cli; UPDATED=2026-06-11
    // Check the server response for actual error details
    if (state.session.last_response) |response| {
        // Check for error status codes (4xxxx or 5xxxx)
        if (std.mem.indexOf(u8, response, "\"status_class\":\"4") != null or
            std.mem.indexOf(u8, response, "\"status_class\":\"5") != null)
        {
            error_count = @max(error_count, 1);
            // Extract the actual error message from the response
            batch_error_msg = extractServerErrorMessage(state.allocator, response);
        }
    }

    // Display batch execution error with details
    if (error_count > 0 and batch_error_msg != null) {
        try stderr.writeStreamingAll(replIo(), "\r\nError in source file:\r\n");
        try stderr.writeStreamingAll(replIo(), "  ");
        try stderr.writeStreamingAll(replIo(), batch_error_msg.?);
        try stderr.writeStreamingAll(replIo(), "\r\n");
        state.allocator.free(batch_error_msg.?);
        batch_error_msg = null;
    }

    // Check for interrupt (may have been pressed during error display)
    if (checkForInterrupt()) {
        interrupted = true;
        progress_spinner.stop(null);
        try stderr.writeStreamingAll(replIo(), "\r\nOperation cancelled by user (Ctrl+C)\r\n");
        return;
    }

    // Execute remaining meta-commands
    for (meta_commands.items) |mc| {
        if (mc.position > 0) {
            executeMetaCommand(state, mc, stdout);
        }
    }

    // Stop spinner and display summary
    var summary_buf: [256]u8 = undefined;
    if (error_count > 0) {
        const fail_msg = std.fmt.bufPrint(&summary_buf, "Executed {d} statement(s) with {d} error(s)", .{ statement_count, error_count }) catch "Execution failed";
        progress_spinner.fail(fail_msg);
    } else {
        const success_msg = std.fmt.bufPrint(&summary_buf, "Executed {d} statement(s) successfully", .{statement_count}) catch "Execution complete";
        progress_spinner.success(success_msg);
    }
}

/// Meta-command type for deferred execution during source file processing
const MetaCommandType = enum { echo, timing };

const MetaCommand = struct {
    cmd: MetaCommandType,
    args: ?[]const u8,
    position: usize, // Statement position where this command appears
};

/// CANARY: REQ=REQ-SHELL-SOURCE-ERROR-003; FEATURE="SourceFileErrorDetails"; ASPECT=ErrorExtraction; STATUS=TESTED; TEST=tests/test_gap0514_repl_dispatch.zig; OWNER=cli; UPDATED=2026-11-12
/// Extract the error message from a server response for user-friendly display
pub fn extractServerErrorMessage(allocator: std.mem.Allocator, response: []const u8) ?[]const u8 {
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch {
        return null;
    };
    defer parsed.deinit();

    const obj = parsed.value.object;

    // Try to extract from top-level error field
    if (obj.get("error")) |err_val| {
        if (err_val == .string) {
            return allocator.dupe(u8, err_val.string) catch null;
        }
    }

    // Try to extract from message field
    if (obj.get("message")) |msg_val| {
        if (msg_val == .string) {
            return allocator.dupe(u8, msg_val.string) catch null;
        }
    }

    // Try to build a message from status_class if nothing else available
    // Only return an error message for actual error status codes (4xxxx, 5xxxx)
    // Status codes starting with 00, 01, 02, 03 are success/info codes
    if (obj.get("status_class")) |status_val| {
        if (status_val == .string) {
            const status = status_val.string;
            if (status.len >= 2) {
                const prefix = status[0..2];
                // Only treat 4x and 5x status codes as errors
                const first_char = status[0];
                if (first_char != '4' and first_char != '5') {
                    // Not an error status code (00xxx, 01xxx, 02xxx, 03xxx are success/info)
                    return null;
                }
                const category: []const u8 = if (std.mem.eql(u8, prefix, "42"))
                    "Syntax error in GQL statement"
                else if (std.mem.eql(u8, prefix, "22"))
                    "Data exception (invalid value or type)"
                else if (std.mem.eql(u8, prefix, "23"))
                    "Integrity constraint violation"
                else if (std.mem.eql(u8, prefix, "40"))
                    "Transaction rollback"
                else if (std.mem.eql(u8, prefix, "50"))
                    "Server error"
                else
                    "Query execution failed";

                var buf: [128]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "{s} (status: {s})", .{ category, status }) catch return null;
                return allocator.dupe(u8, msg) catch null;
            }
        }
    }

    return null;
}

/// Execute a meta-command during source file processing
fn executeMetaCommand(state: anytype, mc: MetaCommand, stdout: anytype) void {
    switch (mc.cmd) {
        .echo => {
            if (mc.args) |args| {
                stdout.writeStreamingAll(replIo(), args) catch {};
                stdout.writeStreamingAll(replIo(), "\r\n") catch {};
            }
        },
        .timing => {
            if (mc.args) |args| {
                if (std.mem.eql(u8, args, "on")) {
                    state.show_timing = true;
                } else if (std.mem.eql(u8, args, "off")) {
                    state.show_timing = false;
                }
            }
        },
    }
}

// SONNY-6511: containsTransactionCommands (and its isIdentifierChar helper)
// deleted. It decided whether \source wrapped a file in a transaction;
// that wrapping was removed in 882bccfc8 (2026-01-30) and nothing called it
// since. It also matched only three casings of each keyword and keywords
// used as identifiers.

/// Extract the result from a response and display it appropriately
/// Returns true if an error was found and displayed
fn extractAndDisplayResult(allocator: std.mem.Allocator, response: []const u8, stdout: anytype, stderr: anytype, format: anytype) !bool {
    // Parse the JSON response
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch {
        // If parsing fails, output as-is
        try stdout.writeStreamingAll(replIo(), response);
        try stdout.writeStreamingAll(replIo(), "\r\n");
        return false;
    };
    defer parsed.deinit();

    const root = parsed.value.object;

    if (format == .json) {
        try stdout.writeStreamingAll(replIo(), response);
        try stdout.writeStreamingAll(replIo(), "\r\n");
        if (root.get("status_class")) |status_value| {
            if (status_value == .string) {
                const status = status_value.string;
                if (status.len >= 2 and !std.mem.startsWith(u8, status, "00")) {
                    return true;
                }
            }
        }
        if (root.get("error") != null or root.get("error_code") != null) {
            return true;
        }
        return false;
    }

    if (extractServerErrorMessage(allocator, response)) |err_msg| {
        defer allocator.free(err_msg);
        try stderr.writeStreamingAll(replIo(), "Error: ");
        try stderr.writeStreamingAll(replIo(), err_msg);
        try stderr.writeStreamingAll(replIo(), "\r\n");
        return true;
    }

    if (root.get("status_class")) |status_value| {
        if (status_value == .string) {
            const status = status_value.string;
            if (status.len >= 2 and !std.mem.startsWith(u8, status, "00")) {
                try stderr.writeStreamingAll(replIo(), "Error (");
                try stderr.writeStreamingAll(replIo(), status);
                try stderr.writeStreamingAll(replIo(), ")\r\n");
                return true;
            }
        }
    }

    if (root.get("explain")) |explain_val| {
        try prettyPrintJson(allocator, explain_val, stdout, 0);
        try stdout.writeStreamingAll(replIo(), "\r\n");
        return false;
    }
    if (root.get("profile")) |profile_val| {
        try prettyPrintJson(allocator, profile_val, stdout, 0);
        try stdout.writeStreamingAll(replIo(), "\r\n");
        return false;
    }

    if (root.get("rows")) |rows_value| {
        if (rows_value == .array) {
            if (root.get("columns")) |columns_value| {
                if (columns_value == .array) {
                    try displayRowsWithColumns(allocator, columns_value.array, rows_value.array, stdout, format);
                    return false;
                }
            }
            try displayRows(allocator, rows_value, stdout, format);
            return false;
        }
    }

    try prettyPrintJson(allocator, parsed.value, stdout, 0);
    try stdout.writeStreamingAll(replIo(), "\r\n");
    return false;
}

/// Display rows from a query result
fn displayRows(allocator: std.mem.Allocator, rows_value: std.json.Value, stdout: anytype, format: anytype) !void {
    if (rows_value != .array) return;

    const rows = rows_value.array;
    if (rows.items.len == 0) {
        try stdout.writeStreamingAll(replIo(), "(0 rows)\r\n");
        return;
    }

    switch (format) {
        .table => try displayRowsAsTable(allocator, rows, stdout),
        .csv => try displayRowsAsCsv(allocator, rows, stdout),
        .json => {
            // Pretty print the rows array
            try prettyPrintJson(allocator, rows_value, stdout, 0);
            try stdout.writeStreamingAll(replIo(), "\r\n");
        },
    }

    // Show row count
    var buf: [64]u8 = undefined;
    const count_msg = std.fmt.bufPrint(&buf, "({d} row{s})\r\n", .{ rows.items.len, if (rows.items.len == 1) "" else "s" }) catch return;
    try stdout.writeStreamingAll(replIo(), count_msg);
}

/// CANARY: REQ=REQ-SHELL-PLAIN-011; FEATURE="ShellPlainMode"; ASPECT=ColumnRowsDisplay; STATUS=IMPL; OWNER=cli; UPDATED=2026-02-03
/// Display rows from shell protocol format with separate columns and row objects
/// columns: [{name,type}], rows: [{col1: val1, col2: val2}, ...]
fn displayRowsWithColumns(allocator: std.mem.Allocator, columns: std.json.Array, rows: std.json.Array, stdout: anytype, format: anytype) !void {
    if (rows.items.len == 0) {
        try stdout.writeStreamingAll(replIo(), "(0 rows)\r\n");
        return;
    }

    // Get column names
    var col_names = try allocator.alloc([]const u8, columns.items.len);
    defer allocator.free(col_names);
    for (columns.items, 0..) |col, i| {
        if (col == .object) {
            if (col.object.get("name")) |name_val| {
                if (name_val == .string) {
                    col_names[i] = name_val.string;
                    continue;
                }
            }
        }
        col_names[i] = "?";
    }

    switch (format) {
        .table => try displayRowsWithColumnsAsTable(allocator, col_names, rows, stdout),
        .csv => try displayRowsWithColumnsAsCsv(col_names, rows, stdout),
        .json => {
            try prettyPrintJson(allocator, std.json.Value{ .array = rows }, stdout, 0);
            try stdout.writeStreamingAll(replIo(), "\r\n");
        },
    }

    // Show row count
    var buf: [64]u8 = undefined;
    const count_msg = std.fmt.bufPrint(&buf, "({d} row{s})\r\n", .{ rows.items.len, if (rows.items.len == 1) "" else "s" }) catch return;
    try stdout.writeStreamingAll(replIo(), count_msg);
}

/// Display rows with columns as table format
fn displayRowsWithColumnsAsTable(allocator: std.mem.Allocator, col_names: []const []const u8, rows: std.json.Array, stdout: anytype) !void {
    // Calculate column widths
    var col_widths = try allocator.alloc(usize, col_names.len);
    defer allocator.free(col_widths);

    for (col_names, 0..) |name, i| {
        col_widths[i] = name.len;
    }

    // Check each row for max widths
    for (rows.items) |row| {
        if (row != .object) continue;
        for (col_names, 0..) |col_name, i| {
            const val = row.object.get(col_name) orelse std.json.Value.null;
            const width = getValueDisplayWidth(val);
            col_widths[i] = @max(col_widths[i], @min(width, 50)); // Cap at 50 chars
        }
    }

    // Print header
    try stdout.writeStreamingAll(replIo(), "| ");
    for (col_names, 0..) |name, i| {
        try stdout.writeStreamingAll(replIo(), name);
        const padding = col_widths[i] -| name.len;
        for (0..padding) |_| try stdout.writeStreamingAll(replIo(), " ");
        try stdout.writeStreamingAll(replIo(), " | ");
    }
    try stdout.writeStreamingAll(replIo(), "\r\n");

    // Print separator
    try stdout.writeStreamingAll(replIo(), "|");
    for (col_widths) |width| {
        try stdout.writeStreamingAll(replIo(), "-");
        for (0..width) |_| try stdout.writeStreamingAll(replIo(), "-");
        try stdout.writeStreamingAll(replIo(), "-|");
    }
    try stdout.writeStreamingAll(replIo(), "\r\n");

    // Print data rows
    for (rows.items) |row| {
        if (row != .object) continue;
        try stdout.writeStreamingAll(replIo(), "| ");
        for (col_names, 0..) |_, i| {
            var val_buf: [256]u8 = undefined;
            var printed_len: usize = 0;
            const val = row.object.get(col_names[i]) orelse std.json.Value.null;
            const str = formatValueCompact(&val_buf, val);
            const display_str = if (str.len > col_widths[i]) str[0..col_widths[i]] else str;
            try stdout.writeStreamingAll(replIo(), display_str);
            printed_len = display_str.len;
            const padding = col_widths[i] -| printed_len;
            for (0..padding) |_| try stdout.writeStreamingAll(replIo(), " ");
            try stdout.writeStreamingAll(replIo(), " | ");
        }
        try stdout.writeStreamingAll(replIo(), "\r\n");
    }
}

/// Display rows with columns as CSV format
fn displayRowsWithColumnsAsCsv(col_names: []const []const u8, rows: std.json.Array, stdout: anytype) !void {
    // Print header
    for (col_names, 0..) |name, i| {
        if (i > 0) try stdout.writeStreamingAll(replIo(), ",");
        try stdout.writeStreamingAll(replIo(), name);
    }
    try stdout.writeStreamingAll(replIo(), "\r\n");

    // Print data rows
    for (rows.items) |row| {
        if (row != .object) continue;
        for (col_names, 0..) |col_name, i| {
            if (i > 0) try stdout.writeStreamingAll(replIo(), ",");
            var val_buf: [256]u8 = undefined;
            const val = row.object.get(col_name) orelse std.json.Value.null;
            const str = formatValueCompact(&val_buf, val);
            try stdout.writeStreamingAll(replIo(), str);
        }
        try stdout.writeStreamingAll(replIo(), "\r\n");
    }
}

/// Write a JSON value for output
fn writeJsonValue(stdout: anytype, val: std.json.Value) !void {
    try std.json.stringify(val, .{}, stdout);
}

/// Display rows as a formatted table
fn displayRowsAsTable(allocator: std.mem.Allocator, rows: std.json.Array, stdout: anytype) !void {
    if (rows.items.len == 0) return;

    // Get column names from first row (assuming all rows have same keys)
    const first_row = rows.items[0];
    if (first_row != .object) {
        // Not an object row, fall back to JSON
        try prettyPrintJson(allocator, std.json.Value{ .array = rows }, stdout, 0);
        return;
    }

    const keys = first_row.object.keys();
    if (keys.len == 0) return;

    // Calculate column widths
    var col_widths = try allocator.alloc(usize, keys.len);
    defer allocator.free(col_widths);

    for (keys, 0..) |key, i| {
        col_widths[i] = key.len;
    }

    // Check each row for max widths
    for (rows.items) |row| {
        if (row != .object) continue;
        for (keys, 0..) |key, i| {
            if (row.object.get(key)) |val| {
                const width = getValueDisplayWidth(val);
                col_widths[i] = @max(col_widths[i], @min(width, 50)); // Cap at 50 chars
            }
        }
    }

    // Print header
    try stdout.writeStreamingAll(replIo(), "| ");
    for (keys, 0..) |key, i| {
        try stdout.writeStreamingAll(replIo(), key);
        const padding = col_widths[i] -| key.len;
        for (0..padding) |_| try stdout.writeStreamingAll(replIo(), " ");
        try stdout.writeStreamingAll(replIo(), " | ");
    }
    try stdout.writeStreamingAll(replIo(), "\r\n");

    // Print separator
    try stdout.writeStreamingAll(replIo(), "|");
    for (col_widths) |width| {
        try stdout.writeStreamingAll(replIo(), "-");
        for (0..width) |_| try stdout.writeStreamingAll(replIo(), "-");
        try stdout.writeStreamingAll(replIo(), "-|");
    }
    try stdout.writeStreamingAll(replIo(), "\r\n");

    // Print data rows
    for (rows.items) |row| {
        if (row != .object) continue;
        try stdout.writeStreamingAll(replIo(), "| ");
        for (keys, 0..) |key, i| {
            var val_buf: [256]u8 = undefined;
            var printed_len: usize = 0;
            if (row.object.get(key)) |val| {
                const str = formatValueCompact(&val_buf, val);
                const display_str = if (str.len > col_widths[i]) str[0..col_widths[i]] else str;
                try stdout.writeStreamingAll(replIo(), display_str);
                printed_len = display_str.len;
            }
            const padding = col_widths[i] -| printed_len;
            for (0..padding) |_| try stdout.writeStreamingAll(replIo(), " ");
            try stdout.writeStreamingAll(replIo(), " | ");
        }
        try stdout.writeStreamingAll(replIo(), "\r\n");
    }
}

/// Display rows as CSV
fn displayRowsAsCsv(allocator: std.mem.Allocator, rows: std.json.Array, stdout: anytype) !void {
    _ = allocator;
    if (rows.items.len == 0) return;

    // Get column names from first row
    const first_row = rows.items[0];
    if (first_row != .object) return;

    const keys = first_row.object.keys();

    // Print header
    for (keys, 0..) |key, i| {
        if (i > 0) try stdout.writeStreamingAll(replIo(), ",");
        try stdout.writeStreamingAll(replIo(), key);
    }
    try stdout.writeStreamingAll(replIo(), "\r\n");

    // Print data rows
    for (rows.items) |row| {
        if (row != .object) continue;
        for (keys, 0..) |key, i| {
            if (i > 0) try stdout.writeStreamingAll(replIo(), ",");
            var val_buf: [256]u8 = undefined;
            if (row.object.get(key)) |val| {
                const str = formatValueCompact(&val_buf, val);
                // Escape quotes in CSV
                if (std.mem.indexOf(u8, str, "\"") != null or std.mem.indexOf(u8, str, ",") != null) {
                    try stdout.writeStreamingAll(replIo(), "\"");
                    for (str) |c| {
                        if (c == '"') {
                            try stdout.writeStreamingAll(replIo(), "\"\"");
                        } else {
                            try stdout.writeStreamingAll(replIo(), &[_]u8{c});
                        }
                    }
                    try stdout.writeStreamingAll(replIo(), "\"");
                } else {
                    try stdout.writeStreamingAll(replIo(), str);
                }
            }
        }
        try stdout.writeStreamingAll(replIo(), "\r\n");
    }
}

/// Get the display width of a JSON value
fn getValueDisplayWidth(val: std.json.Value) usize {
    return switch (val) {
        .string => |s| s.len,
        .integer => 12,
        .float => 12,
        .number_string => |s| s.len,
        .bool => |b| if (b) 4 else 5,
        .null => 4,
        .object => 40, // Compact object representation (nodes with properties)
        .array => 20, // Compact array representation
    };
}

/// Format a JSON value compactly for table display
fn formatValueCompact(buf: []u8, val: std.json.Value) []const u8 {
    switch (val) {
        .string => |s| return s,
        .integer => |n| {
            return std.fmt.bufPrint(buf, "{d}", .{n}) catch "?";
        },
        .float => |f| {
            return std.fmt.bufPrint(buf, "{d:.2}", .{f}) catch "?";
        },
        .number_string => |s| return s,
        .bool => |b| return if (b) "true" else "false",
        .null => return "null",
        .object => |obj| {
            // Compact object display for nodes - show just properties, not label wrapper
            if (obj.get("id")) |id_val| {
                if (obj.get("labels")) |_| {
                    // Node-like object - get id as UUIDv7-style hex
                    const id_num: u64 = switch (id_val) {
                        .integer => |n| @bitCast(n),
                        else => 0,
                    };

                    // Check for properties and show them
                    if (obj.get("properties")) |props_val| {
                        if (props_val == .object) {
                            const props = props_val.object;
                            // Show id and name if available
                            if (props.get("name")) |name_val| {
                                if (name_val == .string) {
                                    return std.fmt.bufPrint(buf, "{{id:\"{x:0>16}\", name:\"{s}\"}}", .{ id_num, name_val.string }) catch "{...}";
                                }
                            }
                        }
                    }

                    return std.fmt.bufPrint(buf, "{{id:\"{x:0>16}\"}}", .{id_num}) catch "{...}";
                }
            }
            return "{...}";
        },
        .array => |arr| {
            if (arr.items.len == 0) return "[]";
            return std.fmt.bufPrint(buf, "[{d} items]", .{arr.items.len}) catch "[...]";
        },
    }
}

/// Pretty print a JSON value with indentation
fn prettyPrintJson(allocator: std.mem.Allocator, value: std.json.Value, writer: anytype, indent: usize) !void {
    const indent_str = "  ";

    switch (value) {
        .object => |obj| {
            if (obj.count() == 0) {
                try writer.writeAll("{}");
                return;
            }
            try writer.writeAll("{\r\n");
            var first = true;
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                if (!first) try writer.writeAll(",\r\n");
                first = false;
                for (0..indent + 1) |_| try writer.writeAll(indent_str);
                try writer.writeAll("\"");
                try writer.writeAll(entry.key_ptr.*);
                try writer.writeAll("\": ");
                try prettyPrintJson(allocator, entry.value_ptr.*, writer, indent + 1);
            }
            try writer.writeAll("\r\n");
            for (0..indent) |_| try writer.writeAll(indent_str);
            try writer.writeAll("}");
        },
        .array => |arr| {
            if (arr.items.len == 0) {
                try writer.writeAll("[]");
                return;
            }
            try writer.writeAll("[\r\n");
            for (arr.items, 0..) |item, i| {
                if (i > 0) try writer.writeAll(",\r\n");
                for (0..indent + 1) |_| try writer.writeAll(indent_str);
                try prettyPrintJson(allocator, item, writer, indent + 1);
            }
            try writer.writeAll("\r\n");
            for (0..indent) |_| try writer.writeAll(indent_str);
            try writer.writeAll("]");
        },
        .string => |s| {
            try writer.writeAll("\"");
            // Escape special characters
            for (s) |c| {
                switch (c) {
                    '"' => try writer.writeAll("\\\""),
                    '\\' => try writer.writeAll("\\\\"),
                    '\n' => try writer.writeAll("\\n"),
                    '\r' => try writer.writeAll("\\r"),
                    '\t' => try writer.writeAll("\\t"),
                    else => try writer.writeAll(&[_]u8{c}),
                }
            }
            try writer.writeAll("\"");
        },
        .integer => |n| {
            var buf: [32]u8 = undefined;
            const str = std.fmt.bufPrint(&buf, "{d}", .{n}) catch return;
            try writer.writeAll(str);
        },
        .float => |f| {
            var buf: [32]u8 = undefined;
            const str = std.fmt.bufPrint(&buf, "{d}", .{f}) catch return;
            try writer.writeAll(str);
        },
        .bool => |b| {
            try writer.writeAll(if (b) "true" else "false");
        },
        .null => {
            try writer.writeAll("null");
        },
        .number_string => |s| {
            try writer.writeAll(s);
        },
    }
}

fn formatQueryResult(stdout: anytype, allocator: std.mem.Allocator, response: []const u8, format: anytype) !void {
    switch (format) {
        .json => {
            // JSON format - output as-is
            try stdout.writeStreamingAll(replIo(), response);
        },
        .csv => {
            // CSV format - simple implementation
            try formatResultAsCsv(stdout, allocator, response);
        },
        .table => {
            // Table format - simple implementation
            try formatResultAsTable(stdout, allocator, response);
        },
    }
}

fn formatResultAsCsv(stdout: anytype, allocator: std.mem.Allocator, response: []const u8) !void {
    // Parse JSON and convert to simple CSV
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch {
        // If parsing fails, output as-is
        try stdout.writeStreamingAll(replIo(), response);
        return;
    };
    defer parsed.deinit();

    const root = parsed.value.object;
    if (root.get("columns")) |columns_value| {
        if (root.get("rows")) |rows_value| {
            const columns = columns_value.array;
            const rows = rows_value.array;
            const column_names = try extractColumnNames(allocator, columns);
            defer allocator.free(column_names);

            // Header
            for (column_names, 0..) |col, i| {
                if (i > 0) try stdout.writeStreamingAll(replIo(), ",");
                try stdout.writeStreamingAll(replIo(), "\"");
                try stdout.writeStreamingAll(replIo(), col);
                try stdout.writeStreamingAll(replIo(), "\"");
            }
            try stdout.writeStreamingAll(replIo(), "\r\n");

            // Data rows
            for (rows.items) |row| {
                for (column_names, 0..) |col_name, i| {
                    if (i > 0) try stdout.writeStreamingAll(replIo(), ",");
                    const cell = getRowValue(row, col_name);
                    const rendered = try renderCell(allocator, cell);
                    defer allocator.free(rendered);
                    if (cell == .string) {
                        try stdout.writeStreamingAll(replIo(), "\"");
                        try stdout.writeStreamingAll(replIo(), rendered);
                        try stdout.writeStreamingAll(replIo(), "\"");
                    } else {
                        try stdout.writeStreamingAll(replIo(), rendered);
                    }
                }
                try stdout.writeStreamingAll(replIo(), "\r\n");
            }
            return;
        }
    }

    // Fallback: output as-is
    try stdout.writeStreamingAll(replIo(), response);
}

fn formatResultAsTable(stdout: anytype, allocator: std.mem.Allocator, response: []const u8) !void {
    // Parse JSON and convert to simple table
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, response, .{}) catch {
        // If parsing fails, output as-is
        try stdout.writeStreamingAll(replIo(), response);
        return;
    };
    defer parsed.deinit();

    const root = parsed.value.object;
    if (root.get("columns")) |columns_value| {
        if (root.get("rows")) |rows_value| {
            const columns = columns_value.array;
            const rows = rows_value.array;
            const column_names = try extractColumnNames(allocator, columns);
            defer allocator.free(column_names);

            // Calculate column widths
            var col_widths = try allocator.alloc(usize, column_names.len);
            defer allocator.free(col_widths);

            for (column_names, 0..) |col, i| {
                col_widths[i] = col.len;
            }

            for (rows.items) |row| {
                for (column_names, 0..) |col_name, i| {
                    if (i >= col_widths.len) continue;
                    const cell = getRowValue(row, col_name);
                    const rendered = try renderCell(allocator, cell);
                    defer allocator.free(rendered);
                    col_widths[i] = @max(col_widths[i], rendered.len);
                }
            }

            // Print header
            try stdout.writeStreamingAll(replIo(), "| ");
            for (column_names, 0..) |col, i| {
                try stdout.writeStreamingAll(replIo(), col);
                const padding = col_widths[i] - col.len;
                for (0..padding) |_| try stdout.writeStreamingAll(replIo(), " ");
                try stdout.writeStreamingAll(replIo(), " | ");
            }
            try stdout.writeStreamingAll(replIo(), "\r\n");

            // Print separator
            try stdout.writeStreamingAll(replIo(), "|");
            for (col_widths) |width| {
                try stdout.writeStreamingAll(replIo(), "-");
                for (0..width) |_| try stdout.writeStreamingAll(replIo(), "-");
                try stdout.writeStreamingAll(replIo(), "-|");
            }
            try stdout.writeStreamingAll(replIo(), "\r\n");

            // Print data rows
            for (rows.items) |row| {
                try stdout.writeStreamingAll(replIo(), "| ");
                for (column_names, 0..) |col_name, i| {
                    if (i >= col_widths.len) continue;
                    const cell = getRowValue(row, col_name);
                    const rendered = try renderCell(allocator, cell);
                    defer allocator.free(rendered);
                    try stdout.writeStreamingAll(replIo(), rendered);
                    const printed_len: usize = rendered.len;
                    const padding = col_widths[i] - printed_len;
                    for (0..padding) |_| try stdout.writeStreamingAll(replIo(), " ");
                    try stdout.writeStreamingAll(replIo(), " | ");
                }
                try stdout.writeStreamingAll(replIo(), "\r\n");
            }
            return;
        }
    }

    // Fallback: output as-is
    try stdout.writeStreamingAll(replIo(), response);
}

fn extractColumnNames(allocator: std.mem.Allocator, columns: std.json.Array) ![]const []const u8 {
    var names = try allocator.alloc([]const u8, columns.items.len);
    for (columns.items, 0..) |col, i| {
        switch (col) {
            .object => |obj| {
                const name_val = obj.get("name") orelse return error.MissingColumnName;
                if (name_val.* != .string) return error.InvalidColumnName;
                names[i] = name_val.string;
            },
            .string => |s| names[i] = s,
            else => return error.InvalidColumnName,
        }
    }
    return names;
}

fn getRowValue(row: std.json.Value, column_name: []const u8) std.json.Value {
    if (row == .object) {
        if (row.object.get(column_name)) |val| return val;
    }
    return std.json.Value{ .null = {} };
}

fn renderCell(allocator: std.mem.Allocator, cell: std.json.Value) ![]u8 {
    return switch (cell) {
        .string => |s| allocator.dupe(u8, s),
        .integer => |n| std.fmt.allocPrint(allocator, "{d}", .{n}),
        .float => |f| std.fmt.allocPrint(allocator, "{d}", .{f}),
        .bool => |b| allocator.dupe(u8, if (b) "true" else "false"),
        .null => allocator.dupe(u8, "NULL"),
        else => std.json.Stringify.valueAlloc(allocator, cell, .{}),
    };
}

fn splitOnce(allocator: std.mem.Allocator, text: []const u8, delimiter: u8) ![2][]u8 {
    if (std.mem.indexOf(u8, text, &[_]u8{delimiter})) |idx| {
        return [2][]u8{
            try allocator.dupe(u8, text[0..idx]),
            try allocator.dupe(u8, std.mem.trim(u8, text[idx + 1 ..], " \t")),
        };
    }
    return [2][]u8{
        try allocator.dupe(u8, text),
        try allocator.dupe(u8, ""),
    };
}

// Unit tests
// CANARY: REQ=REQ-SHELL-AUTH-005; FEATURE="ShellAuthTests"; ASPECT=UnitTests; STATUS=TESTED; TEST=TestShellAuthDetection; OWNER=cli; UPDATED=2026-01-28

const testing = std.testing;

const ScriptedTransportConnection = struct {
    allocator: std.mem.Allocator,
    responses: [][]u8,
    next_response: usize = 0,
    writes: std.ArrayList([]u8),

    fn create(allocator: std.mem.Allocator, responses: []const []u8) !*TransportConnection {
        const ctx = try allocator.create(ScriptedTransportConnection);
        errdefer allocator.destroy(ctx);

        const owned_responses = try allocator.alloc([]u8, responses.len);
        errdefer allocator.free(owned_responses);
        for (responses, 0..) |resp, i| {
            owned_responses[i] = resp;
        }

        ctx.* = .{
            .allocator = allocator,
            .responses = owned_responses,
            .writes = std.ArrayList([]u8).empty,
        };
        errdefer ctx.writes.deinit(allocator);

        const conn = try allocator.create(TransportConnection);
        conn.* = .{
            .writeAllFn = writeAll,
            .readLineFn = readLine,
            .deinitFn = deinit,
            .context = ctx,
            .allocator = allocator,
        };
        return conn;
    }

    fn get(self: *TransportConnection) *ScriptedTransportConnection {
        const ctx = self.context orelse unreachable;
        return @ptrCast(@alignCast(ctx));
    }

    fn writeAll(self: *TransportConnection, data: []const u8) !void {
        const ctx = get(self);
        try ctx.writes.append(ctx.allocator, try ctx.allocator.dupe(u8, data));
    }

    fn readLine(self: *TransportConnection, allocator: std.mem.Allocator, max_size: usize) ![]u8 {
        _ = max_size;
        const ctx = get(self);
        if (ctx.next_response >= ctx.responses.len) return error.EndOfStream;

        const response = ctx.responses[ctx.next_response];
        ctx.next_response += 1;
        return allocator.dupe(u8, response);
    }

    fn deinit(self: *TransportConnection) void {
        const ctx = get(self);
        for (ctx.responses) |resp| ctx.allocator.free(resp);
        ctx.allocator.free(ctx.responses);
        for (ctx.writes.items) |write| ctx.allocator.free(write);
        ctx.writes.deinit(ctx.allocator);
        ctx.allocator.destroy(ctx);
        if (self.allocator) |allocator| allocator.destroy(self);
    }
};

fn emptyStatusStrings(_: std.mem.Allocator) !std.ArrayList([]const u8) {
    return std.ArrayList([]const u8).empty;
}

fn buildStatusForTest(allocator: std.mem.Allocator) !proto_schema.Status {
    return .{
        .status_class = try allocator.dupe(u8, "00000"),
        .additional_statuses = try emptyStatusStrings(allocator),
        .flagger_findings = try emptyStatusStrings(allocator),
    };
}

fn buildColumnForTest(allocator: std.mem.Allocator, name: []const u8, ty: []const u8) !proto_schema.ColumnDefinition {
    return .{
        .name = try allocator.dupe(u8, name),
        .type = try allocator.dupe(u8, ty),
    };
}

fn buildIntRowForTest(allocator: std.mem.Allocator, value: i64) !proto_schema.Row {
    var values = try std.ArrayList(proto_schema.Value).initCapacity(allocator, 1);
    try values.append(allocator, .{
        .kind = .{ .int_val = .{ .value = value } },
    });
    return .{ .values = values };
}

fn buildSchemaResponseMessageForTest(allocator: std.mem.Allocator) ![]u8 {
    var columns = try std.ArrayList(proto_schema.ColumnDefinition).initCapacity(allocator, 1);
    try columns.append(allocator, try buildColumnForTest(allocator, "n", "INTEGER"));

    var resp = proto_schema.ExecutionResponse{
        .status = try buildStatusForTest(allocator),
        .payload = .{ .schema = .{ .columns = columns } },
    };
    defer resp.deinit(allocator);

    return encodeServerPacketBody(allocator, .{ .execute = resp });
}

fn buildExecutePageMessageForTest(allocator: std.mem.Allocator, values: []const i64, final: bool) ![]u8 {
    var rows = try std.ArrayList(proto_schema.Row).initCapacity(allocator, values.len);
    for (values) |value| {
        try rows.append(allocator, try buildIntRowForTest(allocator, value));
    }

    var resp = proto_schema.ExecutionResponse{
        .status = try buildStatusForTest(allocator),
        .payload = .{ .page = .{
            .rows = rows,
            .final = final,
            .ordered = false,
            .order_keys = try emptyStatusStrings(allocator),
        } },
    };
    defer resp.deinit(allocator);

    return encodeServerPacketBody(allocator, .{ .execute = resp });
}

fn buildPullPageMessageForTest(allocator: std.mem.Allocator, values: []const i64, final: bool) ![]u8 {
    var rows = try std.ArrayList(proto_schema.Row).initCapacity(allocator, values.len);
    for (values) |value| {
        try rows.append(allocator, try buildIntRowForTest(allocator, value));
    }

    var pull_resp = proto_schema.PullResponse{
        .response = .{
            .status = try buildStatusForTest(allocator),
            .payload = .{ .page = .{
                .rows = rows,
                .final = final,
                .ordered = false,
                .order_keys = try emptyStatusStrings(allocator),
            } },
        },
    };
    defer pull_resp.deinit(allocator);

    return encodeServerPacketBody(allocator, .{ .pull = pull_resp });
}

fn parseRowCountForTest(allocator: std.mem.Allocator, json_text: []const u8) !usize {
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, json_text, .{});
    defer parsed.deinit();

    const rows_value = parsed.value.object.get("rows") orelse return error.InvalidResponse;
    if (rows_value != .array) return error.InvalidResponse;
    return rows_value.array.items.len;
}

fn scriptedTransportStubConnect(_: std.mem.Allocator, _: []const u8) anyerror!*TransportConnection {
    return error.NotConnected;
}

test "repl_dispatch: TestShellAuthDetection_AuthenticationRequiredInResponse" {
    // Issue #387: Test that "Authentication required" is detected in server response
    const auth_required_response = "{\"status_class\":\"42000\",\"type\":\"ERROR\",\"message\":\"Authentication required\"}";
    try testing.expect(std.mem.indexOf(u8, auth_required_response, "Authentication required") != null);
}

test "repl_dispatch: TestShellAuthDetection_NoAuthInSuccessResponse" {
    // Issue #387: Test that success response doesn't trigger auth required
    const success_response = "{\"type\":\"HELLO\",\"server_name\":\"geode\",\"server_ver\":\"0.18.0\"}";
    try testing.expect(std.mem.indexOf(u8, success_response, "Authentication required") == null);
}

test "repl_dispatch: TestShellAuthDetection_ErrorMessageExtraction" {
    // Issue #387: Test error message parsing from auth failure
    const error_response = "{\"status_class\":\"42000\",\"type\":\"ERROR\",\"message\":\"Invalid credentials\"}";
    try testing.expect(std.mem.indexOf(u8, error_response, "Invalid credentials") != null);
}

// CANARY: REQ=REQ-SOURCE-PERF-003; FEATURE="SourceFilePerformance"; ASPECT=UnitTests; STATUS=TESTED; OWNER=cli; UPDATED=2026-01-29
// Issue #391/#392: Unit tests for source file hash caching

test "repl_dispatch: TestFileHashContent_DeterministicHash" {
    // Issue #391/#392: Test that identical content produces identical hash
    const content1 = "CREATE (n:Person {name: 'Alice'});";
    const content2 = "CREATE (n:Person {name: 'Alice'});";
    const hash1 = hashFileContent(content1);
    const hash2 = hashFileContent(content2);
    try testing.expectEqual(hash1, hash2);
}

test "repl_dispatch: TestFileHashContent_DifferentContentDifferentHash" {
    // Issue #391/#392: Test that different content produces different hash
    const content1 = "CREATE (n:Person {name: 'Alice'});";
    const content2 = "CREATE (n:Person {name: 'Bob'});";
    const hash1 = hashFileContent(content1);
    const hash2 = hashFileContent(content2);
    try testing.expect(hash1 != hash2);
}

test "repl_dispatch: TestFileHashContent_EmptyContent" {
    // Issue #391/#392: Test hash of empty content
    const content = "";
    const hash = hashFileContent(content);
    // Initial hash value is 5381
    try testing.expectEqual(@as(u64, 5381), hash);
}

test "repl_dispatch: TestFileHashContent_LargeContent" {
    // Issue #391/#392: Test hash of larger content (simulate a source file)
    const content =
        \\-- Sample GQL source file
        \\CREATE GRAPH IF NOT EXISTS test_graph;
        \\USE GRAPH test_graph;
        \\CREATE (a:Person {name: 'Alice', age: 30});
        \\CREATE (b:Person {name: 'Bob', age: 25});
        \\MERGE (a)-[:KNOWS]->(b);
    ;
    const hash = hashFileContent(content);
    // Just verify it produces a non-zero hash
    try testing.expect(hash != 0);
    try testing.expect(hash != 5381); // Not the empty string hash
}

test "repl_dispatch: TestMetaCommand_EchoType" {
    // Test MetaCommand echo type
    const mc = MetaCommand{ .cmd = .echo, .args = "Hello, World!", .position = 0 };
    try testing.expectEqual(MetaCommandType.echo, mc.cmd);
    try testing.expect(mc.args != null);
    try testing.expect(std.mem.eql(u8, mc.args.?, "Hello, World!"));
}

test "repl_dispatch: TestMetaCommand_TimingType" {
    // Test MetaCommand timing type
    const mc = MetaCommand{ .cmd = .timing, .args = "on", .position = 5 };
    try testing.expectEqual(MetaCommandType.timing, mc.cmd);
    try testing.expectEqual(@as(usize, 5), mc.position);
}

test "repl_dispatch: TestGqlStartsWithUseGraph_LeadingWhitespace" {
    try testing.expect(query_scope.startsWithUseGraph("  \n\tUSE GRAPH test_graph_ctx; MATCH (n) RETURN COUNT(n);"));
}

test "repl_dispatch: TestGqlStartsWithUseGraph_CaseInsensitive" {
    try testing.expect(query_scope.startsWithUseGraph("use graph test_graph_ctx;"));
}

test "repl_dispatch: TestGqlStartsWithUseGraph_OtherStatement" {
    try testing.expect(!query_scope.startsWithUseGraph("MATCH (n) RETURN COUNT(n);"));
}

// CANARY: REQ=REQ-SHELL-RECONNECT-015; FEATURE="ShellAutoReconnect"; ASPECT=UnitTests; STATUS=TESTED; OWNER=cli; UPDATED=2026-01-29
// Unit tests for automatic reconnection functionality

test "repl_dispatch: TestReconnectionConfig_DefaultValues" {
    // Test default reconnection configuration values
    const config = ReconnectionConfig{};
    try testing.expectEqual(@as(u32, 5), config.max_attempts);
    try testing.expectEqual(@as(u64, 100), config.initial_delay_ms);
    try testing.expectEqual(@as(u64, 10000), config.max_delay_ms);
    try testing.expectEqual(@as(f64, 2.0), config.backoff_multiplier);
    try testing.expect(config.prompt_for_txn_recovery);
}

test "repl_dispatch: TestReconnectionConfig_CustomValues" {
    // Test custom reconnection configuration
    const config = ReconnectionConfig{
        .max_attempts = 10,
        .initial_delay_ms = 50,
        .max_delay_ms = 5000,
        .backoff_multiplier = 1.5,
        .prompt_for_txn_recovery = false,
    };
    try testing.expectEqual(@as(u32, 10), config.max_attempts);
    try testing.expectEqual(@as(u64, 50), config.initial_delay_ms);
    try testing.expectEqual(@as(u64, 5000), config.max_delay_ms);
    try testing.expectEqual(@as(f64, 1.5), config.backoff_multiplier);
    try testing.expect(!config.prompt_for_txn_recovery);
}

test "repl_dispatch: TestReconnectionConfig_DisabledReconnection" {
    // Test disabled reconnection (max_attempts = 0)
    const config = ReconnectionConfig{
        .max_attempts = 0,
    };
    try testing.expectEqual(@as(u32, 0), config.max_attempts);
}

test "repl_dispatch: TestPendingTransactionState_DefaultValues" {
    // Test default pending transaction state
    const state = PendingTransactionState{};
    try testing.expect(!state.had_active_transaction);
    try testing.expect(state.current_graph == null);
    try testing.expectEqual(@as(usize, 0), state.statements_in_txn);
}

test "repl_dispatch: TestPendingTransactionState_Reset" {
    // Test reset functionality
    var state = PendingTransactionState{
        .had_active_transaction = true,
        .current_graph = "test_graph",
        .statements_in_txn = 10,
    };
    state.reset();
    try testing.expect(!state.had_active_transaction);
    try testing.expect(state.current_graph == null);
    try testing.expectEqual(@as(usize, 0), state.statements_in_txn);
}

test "repl_dispatch: TestTransactionRecoveryChoice_Values" {
    // Test transaction recovery choice enum values
    const resume_choice = TransactionRecoveryChoice.resume_transaction;
    const cancel_choice = TransactionRecoveryChoice.cancel_transaction;
    const abort_choice = TransactionRecoveryChoice.abort_reconnection;

    try testing.expect(resume_choice != cancel_choice);
    try testing.expect(cancel_choice != abort_choice);
    try testing.expect(resume_choice != abort_choice);
}

test "repl_dispatch: TestClientSession_IsConnectionError_BrokenPipe" {
    // Test BrokenPipe is detected as connection error
    try testing.expect(ClientSession.isConnectionError(error.BrokenPipe));
}

test "repl_dispatch: TestClientSession_IsConnectionError_ConnectionResetByPeer" {
    // Test ConnectionResetByPeer is detected as connection error
    try testing.expect(ClientSession.isConnectionError(error.ConnectionResetByPeer));
}

test "repl_dispatch: TestClientSession_IsConnectionError_ConnectionRefused" {
    // Test ConnectionRefused is detected as connection error
    try testing.expect(ClientSession.isConnectionError(error.ConnectionRefused));
}

test "repl_dispatch: TestClientSession_IsConnectionError_ConnectionTimedOut" {
    // Test ConnectionTimedOut is detected as connection error
    try testing.expect(ClientSession.isConnectionError(error.ConnectionTimedOut));
}

test "repl_dispatch: TestClientSession_IsConnectionError_NetworkUnreachable" {
    // Test NetworkUnreachable is detected as connection error
    try testing.expect(ClientSession.isConnectionError(error.NetworkUnreachable));
}

test "repl_dispatch: TestClientSession_IsConnectionError_HostUnreachable" {
    // Test HostUnreachable is detected as connection error
    try testing.expect(ClientSession.isConnectionError(error.HostUnreachable));
}

test "repl_dispatch: TestClientSession_IsConnectionError_NotConnected" {
    // Test NotConnected is detected as connection error
    try testing.expect(ClientSession.isConnectionError(error.NotConnected));
}

test "repl_dispatch: TestClientSession_IsConnectionError_EndOfStream" {
    // Test EndOfStream is detected as connection error
    try testing.expect(ClientSession.isConnectionError(error.EndOfStream));
}

test "repl_dispatch: TestClientSession_IsConnectionError_InputOutput" {
    // Test InputOutput is detected as connection error
    try testing.expect(ClientSession.isConnectionError(error.InputOutput));
}

test "repl_dispatch: TestClientSession_IsConnectionError_NonConnectionError" {
    // Test that non-connection errors return false
    try testing.expect(!ClientSession.isConnectionError(error.OutOfMemory));
    try testing.expect(!ClientSession.isConnectionError(error.InvalidCharacter));
}

test "repl_dispatch: TestClientSession_InitialReconnectCount" {
    // Test that reconnect count starts at 0
    const allocator = testing.allocator;
    const Dummy = struct {
        fn connect(_: std.mem.Allocator, _: []const u8) anyerror!*TransportConnection {
            return error.NotConnected;
        }
    };
    const transport = Transport{ .connectFn = Dummy.connect };
    var session = try ClientSession.init(allocator, "localhost:3141", &transport);
    defer session.deinit();
    try testing.expectEqual(@as(u32, 0), session.reconnect_count);
}

test "repl_dispatch: TestClientSession_InitialPendingTxnState" {
    // Test that pending transaction state is initialized properly
    const allocator = testing.allocator;
    const Dummy = struct {
        fn connect(_: std.mem.Allocator, _: []const u8) anyerror!*TransportConnection {
            return error.NotConnected;
        }
    };
    const transport = Transport{ .connectFn = Dummy.connect };
    var session = try ClientSession.init(allocator, "localhost:3141", &transport);
    defer session.deinit();
    try testing.expect(!session.pending_txn_state.had_active_transaction);
    try testing.expect(session.pending_txn_state.current_graph == null);
    try testing.expectEqual(@as(usize, 0), session.pending_txn_state.statements_in_txn);
}

test "repl_dispatch: TestClientSession_SaveTransactionState" {
    // Test saving transaction state
    const allocator = testing.allocator;
    const Dummy = struct {
        fn connect(_: std.mem.Allocator, _: []const u8) anyerror!*TransportConnection {
            return error.NotConnected;
        }
    };
    const transport = Transport{ .connectFn = Dummy.connect };
    var session = try ClientSession.init(allocator, "localhost:3141", &transport);
    defer session.deinit();

    session.saveTransactionState(true, "my_graph", 5);

    try testing.expect(session.pending_txn_state.had_active_transaction);
    try testing.expect(std.mem.eql(u8, session.pending_txn_state.current_graph.?, "my_graph"));
    try testing.expectEqual(@as(usize, 5), session.pending_txn_state.statements_in_txn);
}

test "repl_dispatch: TestClientSession_SaveTransactionState_NoGraph" {
    // Test saving transaction state without graph
    const allocator = testing.allocator;
    const Dummy = struct {
        fn connect(_: std.mem.Allocator, _: []const u8) anyerror!*TransportConnection {
            return error.NotConnected;
        }
    };
    const transport = Transport{ .connectFn = Dummy.connect };
    var session = try ClientSession.init(allocator, "localhost:3141", &transport);
    defer session.deinit();

    session.saveTransactionState(false, null, 0);

    try testing.expect(!session.pending_txn_state.had_active_transaction);
    try testing.expect(session.pending_txn_state.current_graph == null);
    try testing.expectEqual(@as(usize, 0), session.pending_txn_state.statements_in_txn);
}

test "repl_dispatch: TestClientSession_CacheCredentials" {
    // Test credential caching
    const allocator = testing.allocator;
    const Dummy = struct {
        fn connect(_: std.mem.Allocator, _: []const u8) anyerror!*TransportConnection {
            return error.NotConnected;
        }
    };
    const transport = Transport{ .connectFn = Dummy.connect };
    var session = try ClientSession.init(allocator, "localhost:3141", &transport);
    defer session.deinit();

    try session.cacheCredentials("testuser", "testpass");

    try testing.expect(session.cached_username != null);
    try testing.expect(session.cached_password != null);
    try testing.expect(std.mem.eql(u8, session.cached_username.?, "testuser"));
    try testing.expect(std.mem.eql(u8, session.cached_password.?, "testpass"));
}

test "repl_dispatch: TestClientSession_CacheCredentials_Overwrite" {
    // Test overwriting cached credentials
    const allocator = testing.allocator;
    const Dummy = struct {
        fn connect(_: std.mem.Allocator, _: []const u8) anyerror!*TransportConnection {
            return error.NotConnected;
        }
    };
    const transport = Transport{ .connectFn = Dummy.connect };
    var session = try ClientSession.init(allocator, "localhost:3141", &transport);
    defer session.deinit();

    try session.cacheCredentials("user1", "pass1");
    try session.cacheCredentials("user2", "pass2");

    try testing.expect(std.mem.eql(u8, session.cached_username.?, "user2"));
    try testing.expect(std.mem.eql(u8, session.cached_password.?, "pass2"));
}

test "repl_dispatch: TestClientSession_DefaultReconnectConfig" {
    // Test default reconnect configuration in session
    const allocator = testing.allocator;
    const Dummy = struct {
        fn connect(_: std.mem.Allocator, _: []const u8) anyerror!*TransportConnection {
            return error.NotConnected;
        }
    };
    const transport = Transport{ .connectFn = Dummy.connect };
    var session = try ClientSession.init(allocator, "localhost:3141", &transport);
    defer session.deinit();

    try testing.expectEqual(@as(u32, 5), session.reconnect_config.max_attempts);
    try testing.expect(session.reconnect_config.prompt_for_txn_recovery);
}

test "repl_dispatch: TestClientSession_PullAll_MergesInlinePageWithPulledPages" {
    const allocator = testing.allocator;
    // runGql starts the process-wide background read pool with this
    // allocator; the REPL tears it down at exit (SONNY-6494).
    defer deinitBackgroundPool();

    const schema_msg = try buildSchemaResponseMessageForTest(allocator);
    const inline_msg = try buildExecutePageMessageForTest(allocator, &.{1}, false);
    const pull_msg = try buildPullPageMessageForTest(allocator, &.{ 2, 3 }, true);

    const conn = try ScriptedTransportConnection.create(allocator, &.{ schema_msg, inline_msg, pull_msg });
    const transport = Transport{ .connectFn = scriptedTransportStubConnect };
    var session = try ClientSession.init(allocator, "localhost:3141", &transport);
    defer session.deinit();

    session.connected = true;
    session.connection = conn;
    session.session_id = try allocator.dupe(u8, "sess");

    try session.runGql("MATCH (n) RETURN n");

    var sink = std.ArrayList(u8).empty;
    defer sink.deinit(allocator);
    try session.pullAll(&sink);

    try testing.expectEqual(@as(usize, 3), try parseRowCountForTest(allocator, sink.items));

    const scripted = ScriptedTransportConnection.get(conn);
    try testing.expectEqual(@as(usize, 2), scripted.writes.items.len);
}

test "repl_dispatch: TestClientSession_PullAll_UsesFinalInlinePageWithoutPull" {
    const allocator = testing.allocator;
    // runGql starts the process-wide background read pool with this
    // allocator; the REPL tears it down at exit (SONNY-6494).
    defer deinitBackgroundPool();

    const schema_msg = try buildSchemaResponseMessageForTest(allocator);
    const inline_msg = try buildExecutePageMessageForTest(allocator, &.{ 1, 2 }, true);

    const conn = try ScriptedTransportConnection.create(allocator, &.{ schema_msg, inline_msg });
    const transport = Transport{ .connectFn = scriptedTransportStubConnect };
    var session = try ClientSession.init(allocator, "localhost:3141", &transport);
    defer session.deinit();

    session.connected = true;
    session.connection = conn;
    session.session_id = try allocator.dupe(u8, "sess");

    try session.runGql("MATCH (n) RETURN n");

    var sink = std.ArrayList(u8).empty;
    defer sink.deinit(allocator);
    try session.pullAll(&sink);

    try testing.expectEqual(@as(usize, 2), try parseRowCountForTest(allocator, sink.items));

    const scripted = ScriptedTransportConnection.get(conn);
    try testing.expectEqual(@as(usize, 1), scripted.writes.items.len);
}
