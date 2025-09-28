const std = @import("std");
const interval_tree = @import("interval_tree.zig");

const INTERVAL_MAGIC = "GDIR";
const INTERVAL_VERSION: u16 = 1;

pub fn persistSnapshot(comptime T: type, tree: *interval_tree.IntervalTree(T), file_path: []const u8) !void {
    const file = try std.fs.cwd().createFile(file_path, .{});
    defer file.close();

    try file.writeAll(INTERVAL_MAGIC);
    var buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &buf, INTERVAL_VERSION, .little);
    try file.writeAll(&buf);
    std.mem.writeInt(u16, &buf, @intCast(@sizeOf(T)), .little);
    try file.writeAll(&buf);

    const count = countNodes(tree.root);
    var count_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &count_buf, count, .little);
    try file.writeAll(&count_buf);

    try writeNodesFile(T, file, tree.root);
}

pub fn loadSnapshot(comptime T: type, allocator: std.mem.Allocator, file_path: []const u8) !interval_tree.IntervalTree(T) {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    // Read and validate magic number
    var magic: [4]u8 = undefined;
    _ = try file.read(&magic);
    if (!std.mem.eql(u8, &magic, INTERVAL_MAGIC)) return error.InvalidMagic;

    // Read version
    var version_buf: [2]u8 = undefined;
    _ = try file.read(&version_buf);
    const version = std.mem.readInt(u16, &version_buf, .little);
    if (version != INTERVAL_VERSION) return error.UnsupportedVersion;

    // Read type size
    var type_size_buf: [2]u8 = undefined;
    _ = try file.read(&type_size_buf);
    const type_size = std.mem.readInt(u16, &type_size_buf, .little);
    if (type_size != @sizeOf(T)) return error.TypeMismatch;

    // Read count
    var count_buf: [8]u8 = undefined;
    _ = try file.read(&count_buf);
    const count = std.mem.readInt(u64, &count_buf, .little);

    var tree = interval_tree.IntervalTree(T).init(allocator);

    for (0..count) |i| {
        _ = i;

        // Read flags
        var flags: [3]u8 = undefined;
        _ = try file.read(&flags);
        const has_lower = flags[0] != 0;
        const has_upper = flags[1] != 0;
        const bounds_code = flags[2];
        const bounds = std.meta.intToEnum(@import("../types/range.zig").Range(T).Bounds, bounds_code) catch return error.InvalidBounds;

        var lower: ?T = null;
        var upper: ?T = null;

        if (has_lower) {
            lower = try readValueFile(T, file);
        }
        if (has_upper) {
            upper = try readValueFile(T, file);
        }

        // Read data
        var data_buf: [8]u8 = undefined;
        _ = try file.read(&data_buf);
        const data = std.mem.readInt(usize, &data_buf, .little);

        const range_val = try @import("../types/range.zig").Range(T).init(lower, upper, bounds);
        try tree.insert(range_val, data);
    }

    return tree;
}

fn countNodes(node: anytype) u64 {
    if (node == null) return 0;
    return 1 + countNodes(node.?.left) + countNodes(node.?.right);
}

fn writeNodesFile(comptime T: type, file: std.fs.File, node: anytype) !void {
    if (node == null) return;
    const n = node.?;

    var flags: [3]u8 = undefined;
    flags[0] = if (n.interval.lower != null) 1 else 0;
    flags[1] = if (n.interval.upper != null) 1 else 0;
    flags[2] = @intFromEnum(n.interval.bounds);
    try file.writeAll(&flags);

    if (n.interval.lower) |l| {
        try writeValueFile(T, file, l);
    }
    if (n.interval.upper) |u| {
        try writeValueFile(T, file, u);
    }

    var data_buf: [8]u8 = undefined;
    std.mem.writeInt(usize, &data_buf, n.data, .little);
    try file.writeAll(&data_buf);

    try writeNodesFile(T, file, n.left);
    try writeNodesFile(T, file, n.right);
}

fn readValueFile(comptime T: type, file: std.fs.File) !T {
    return switch (@typeInfo(T)) {
        .int => {
            var buf: [@sizeOf(T)]u8 = undefined;
            _ = try file.read(&buf);
            return std.mem.readInt(T, &buf, .little);
        },
        .float => {
            var buf: [@sizeOf(T)]u8 = undefined;
            _ = try file.read(&buf);
            const IntType = std.meta.Int(.unsigned, @bitSizeOf(T));
            const int_val = std.mem.readInt(IntType, &buf, .little);
            return @bitCast(int_val);
        },
        else => @compileError("Unsupported type for interval tree persistence"),
    };
}

fn writeValueFile(comptime T: type, file: std.fs.File, value: T) !void {
    return switch (@typeInfo(T)) {
        .int => {
            var buf: [@sizeOf(T)]u8 = undefined;
            std.mem.writeInt(T, &buf, value, .little);
            try file.writeAll(&buf);
        },
        .float => {
            var buf: [@sizeOf(T)]u8 = undefined;
            const IntType = std.meta.Int(.unsigned, @bitSizeOf(T));
            std.mem.writeInt(IntType, &buf, @bitCast(value), .little);
            try file.writeAll(&buf);
        },
        else => @compileError("Unsupported type for interval tree persistence"),
    };
}

test "interval tree persistence" {
    const allocator = std.testing.allocator;

    var tree = interval_tree.IntIntervalTree.init(allocator);
    defer tree.deinit();

    const r1 = try @import("../types/range.zig").IntRange.init(1, 5, .inclusive_exclusive);
    try tree.insert(r1, 100);

    try persistSnapshot(i32, &tree, "/tmp/test_interval.gdir");

    var loaded_tree = try loadSnapshot(i32, allocator, "/tmp/test_interval.gdir");
    defer loaded_tree.deinit();

    const results = try loaded_tree.queryContains(3, allocator);
    defer allocator.free(results);

    std.testing.expect(results.len == 1) catch unreachable;
    std.testing.expect(results[0] == 100) catch unreachable;
}
