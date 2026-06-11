/// Federation merge helpers: cloning, serialization, and proto I/O utilities.
///
/// Extracted from federation.zig to reduce file size.  All public symbols are
/// re-exported by federation.zig so callers need not change their imports.
const std = @import("std");

// Zig 0.16 compat: std.time.milliTimestamp/timestamp/microTimestamp removed.
fn compat_milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
fn compat_timestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec);
}
fn compat_microTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1_000);
}
const protocol = @import("../protocol.zig");
const quic = @import("transport/quic");
const schema = @import("schema");
const protobuf = @import("protobuf");
const proto_util = @import("../server/proto_util.zig");
const value_utilities = @import("../execution/value_utilities.zig");

const result_utils = @import("result_utils.zig");

/// SEC-D008 / PERF-D014: Maximum allowed frame size to prevent allocation bombs.
const MAX_FRAME_SIZE: u32 = 16 * 1024 * 1024; // 16 MiB

// ---------------------------------------------------------------------------
// Binding-row helpers — delegated to result_utils.zig
// ---------------------------------------------------------------------------

pub const freeBindingRow = result_utils.freeBindingRow;
pub const cloneBindingRow = result_utils.cloneBindingRow;

// ---------------------------------------------------------------------------
// Schema helpers — delegated to result_utils.zig
// ---------------------------------------------------------------------------

pub const freeSchema = result_utils.freeSchema;
pub const cloneSchema = result_utils.cloneSchema;

// ---------------------------------------------------------------------------
// Order metadata helpers
// ---------------------------------------------------------------------------

pub fn cloneOrderKeys(allocator: std.mem.Allocator, keys: []const []const u8) ![]const []const u8 {
    var cloned = try allocator.alloc([]const u8, keys.len);
    errdefer {
        for (cloned) |key| allocator.free(key);
        allocator.free(cloned);
    }
    for (keys, 0..) |k, i| {
        cloned[i] = try allocator.dupe(u8, k);
    }
    return cloned;
}

pub fn cloneOrderDirs(allocator: std.mem.Allocator, dirs: []const bool) ![]const bool {
    const cloned = try allocator.alloc(bool, dirs.len);
    std.mem.copyForwards(bool, cloned, dirs);
    return cloned;
}

// ---------------------------------------------------------------------------
// QueryResults clone
// ---------------------------------------------------------------------------

const federation = @import("federation.zig");
const QueryResults = federation.QueryResults;

pub fn cloneQueryResults(allocator: std.mem.Allocator, results: QueryResults) !QueryResults {
    var rows = try allocator.alloc(protocol.BindingRow, results.rows.len);
    var idx: usize = 0;
    errdefer {
        for (rows[0..idx]) |row| freeBindingRow(allocator, row);
        allocator.free(rows);
    }
    for (results.rows) |row| {
        rows[idx] = try cloneBindingRow(allocator, row);
        idx += 1;
    }

    const schema_copy = try cloneSchema(allocator, results.schema);
    errdefer freeSchema(allocator, schema_copy);

    const order_keys = if (results.order_keys.len > 0) try cloneOrderKeys(allocator, results.order_keys) else &.{};
    errdefer if (order_keys.len > 0) {
        for (order_keys) |k| allocator.free(k);
        allocator.free(order_keys);
    };

    const order_dirs = if (results.order_dirs.len > 0) try cloneOrderDirs(allocator, results.order_dirs) else &.{};
    errdefer if (order_dirs.len > 0) allocator.free(order_dirs);

    return QueryResults{
        .rows = rows,
        .schema = schema_copy,
        .execution_time_ms = results.execution_time_ms,
        .ordered = results.ordered,
        .order_keys = order_keys,
        .order_dirs = order_dirs,
        .nulls_first = results.nulls_first,
    };
}

// ---------------------------------------------------------------------------
// Proto I/O utilities for federated query execution
// ---------------------------------------------------------------------------

pub fn buildParams(allocator: std.mem.Allocator, values: []const protocol.Value) !std.ArrayList(schema.Param) {
    var params = std.ArrayList(schema.Param).init(allocator);
    try params.ensureTotalCapacity(allocator, values.len);
    for (values, 0..) |val, idx| {
        const name = try std.fmt.allocPrint(allocator, "p{d}", .{idx + 1});
        const proto_val = try proto_util.valueToProto(allocator, val);
        try params.append(allocator, schema.Param{ .name = name, .value = proto_val });
    }
    return params;
}

pub fn freeParams(allocator: std.mem.Allocator, params: *std.ArrayList(schema.Param)) void {
    for (params.items) |*p| {
        p.deinit(allocator);
    }
    params.deinit(allocator);
}

pub fn appendPageRows(
    allocator: std.mem.Allocator,
    page: schema.DataPage,
    rows: *std.ArrayList(protocol.BindingRow),
) !void {
    for (page.rows.items) |row| {
        var cols = try allocator.alloc(protocol.BindingValue, row.values.items.len);
        errdefer {
            for (cols) |v| value_utilities.freeValue(allocator, v);
            allocator.free(cols);
        }
        for (row.values.items, 0..) |val, idx| {
            cols[idx] = try proto_util.protoValueToValue(allocator, val, 0);
        }
        try rows.append(allocator, .{ .cols = cols });
    }
}

pub fn captureOrderMeta(
    allocator: std.mem.Allocator,
    page: schema.DataPage,
    ordered: *bool,
    order_keys: *std.ArrayList([]const u8),
) !void {
    if (page.ordered) ordered.* = true;
    if (order_keys.items.len == 0 and page.order_keys.items.len > 0) {
        for (page.order_keys.items) |key| {
            try order_keys.append(allocator, try allocator.dupe(u8, key));
        }
    }
}

pub fn writeProtoMessage(allocator: std.mem.Allocator, stream: *quic.QuicClientStream, msg: schema.QuicClientMessage) !void {
    var aw: std.Io.Writer.Allocating = try std.Io.Writer.Allocating.initCapacity(allocator, 4096);
    defer aw.deinit();

    const packet = schema.ClientPacket{ .quic = msg };
    try protobuf.encode(&aw.writer, allocator, packet);

    const written = aw.writer.buffer[0..aw.writer.end];
    var len_buf: [4]u8 = undefined;
    std.mem.writeInt(u32, &len_buf, @intCast(written.len), .big);
    try stream.writeAll(&len_buf);
    try stream.writeAll(written);
}

pub fn readProtoMessage(
    allocator: std.mem.Allocator,
    stream: *quic.QuicClientStream,
    client: *quic.QuicClient,
    timeout_ms: u32,
) !schema.QuicServerMessage {
    var len_buf: [4]u8 = undefined;
    var total_read: usize = 0;
    const start = compat_milliTimestamp();
    while (total_read < len_buf.len) {
        const n = stream.read(len_buf[total_read..]) catch |err| switch (err) {
            error.WouldBlock => {
                if (compat_milliTimestamp() - start > timeout_ms) return error.Timeout;
                try client.poll(5);
                std.Thread.sleep(5 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        if (n == 0) return error.EndOfStream;
        total_read += n;
    }

    const msg_len = std.mem.readInt(u32, &len_buf, .big);
    if (msg_len == 0) return error.InvalidMessage;
    if (msg_len > MAX_FRAME_SIZE) return error.FrameTooLarge;
    const msg_bytes = try allocator.alloc(u8, msg_len);
    defer allocator.free(msg_bytes);

    total_read = 0;
    while (total_read < msg_len) {
        const n = stream.read(msg_bytes[total_read..]) catch |err| switch (err) {
            error.WouldBlock => {
                if (compat_milliTimestamp() - start > timeout_ms) return error.Timeout;
                try client.poll(5);
                std.Thread.sleep(5 * std.time.ns_per_ms);
                continue;
            },
            else => return err,
        };
        if (n == 0) return error.EndOfStream;
        total_read += n;
    }

    var reader: std.Io.Reader = .fixed(msg_bytes);
    const packet = try protobuf.decode(schema.ServerPacket, &reader, allocator);
    return packet.quic orelse error.InvalidMessage;
}

// ---------------------------------------------------------------------------
// Row hashing for deduplication
// ---------------------------------------------------------------------------

/// Hash a binding row into an allocated hex string for use as a deduplication key.
/// The hash covers all column values by their raw byte representation.
pub fn hashRow(allocator: std.mem.Allocator, row: protocol.BindingRow) ![]u8 {
    var hasher = std.hash.Wyhash.init(0);
    for (row.cols) |binding| {
        hasher.update(std.mem.asBytes(&binding));
    }
    const hash_value = hasher.final();
    return try std.fmt.allocPrint(allocator, "{x}", .{hash_value});
}

// ---------------------------------------------------------------------------
// Unit tests — pure helpers only (no QUIC stream or protobuf I/O)
// ---------------------------------------------------------------------------

// CANARY: REQ=REQ-DIST-FEDERATION-MERGE-001; FEATURE="Distributed Federation Merge"; ASPECT=CloneOrderKeys; STATUS=TESTED; TEST="cloneOrderKeys: deep-clone 2-element slice, values match and pointers differ"; OWNER=dist; UPDATED=2026-04-10
test "cloneOrderKeys: deep-clone 2-element slice, values match and pointers differ" {
    const allocator = std.testing.allocator;

    const orig = [_][]const u8{ "alpha", "beta" };
    const cloned = try cloneOrderKeys(allocator, &orig);
    defer {
        for (cloned) |k| allocator.free(k);
        allocator.free(cloned);
    }

    try std.testing.expectEqual(@as(usize, 2), cloned.len);
    try std.testing.expectEqualStrings("alpha", cloned[0]);
    try std.testing.expectEqualStrings("beta", cloned[1]);

    // Pointers must differ — these are independent heap copies.
    try std.testing.expect(orig[0].ptr != cloned[0].ptr);
    try std.testing.expect(orig[1].ptr != cloned[1].ptr);
}

// CANARY: REQ=REQ-DIST-FEDERATION-MERGE-002; FEATURE="Distributed Federation Merge"; ASPECT=CloneOrderDirs; STATUS=TESTED; TEST="cloneOrderDirs: copy 2-element bool slice, values match"; OWNER=dist; UPDATED=2026-04-10
test "cloneOrderDirs: copy 2-element bool slice, values match" {
    const allocator = std.testing.allocator;

    const orig = [_]bool{ true, false };
    const cloned = try cloneOrderDirs(allocator, &orig);
    defer allocator.free(cloned);

    try std.testing.expectEqual(@as(usize, 2), cloned.len);
    try std.testing.expectEqual(true, cloned[0]);
    try std.testing.expectEqual(false, cloned[1]);
}

// CANARY: REQ=REQ-DIST-FEDERATION-MERGE-003; FEATURE="Distributed Federation Merge"; ASPECT=HashRowDeterminism; STATUS=TESTED; TEST="hashRow: same row produces same hash, different row produces different hash"; OWNER=dist; UPDATED=2026-04-10
test "hashRow: same row produces same hash, different row produces different hash" {
    const allocator = std.testing.allocator;

    const cols_a = [_]protocol.BindingValue{.{ .Int = 42 }};
    const cols_b = [_]protocol.BindingValue{.{ .Int = 99 }};

    const row_a = protocol.BindingRow{ .cols = &cols_a };
    const row_b = protocol.BindingRow{ .cols = &cols_b };

    const h1 = try hashRow(allocator, row_a);
    defer allocator.free(h1);
    const h2 = try hashRow(allocator, row_a);
    defer allocator.free(h2);
    const h3 = try hashRow(allocator, row_b);
    defer allocator.free(h3);

    // Determinism: same row must hash identically.
    try std.testing.expectEqualStrings(h1, h2);
    // Discrimination: different rows must produce different hashes.
    try std.testing.expect(!std.mem.eql(u8, h1, h3));
}
