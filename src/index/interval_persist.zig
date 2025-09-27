const std = @import("std");
const interval_tree = @import("interval_tree.zig");

const INTERVAL_MAGIC = "GDIR";
const INTERVAL_VERSION: u16 = 1;

pub fn persistSnapshot(comptime T: type, tree: *interval_tree.IntervalTree(T), file_path: []const u8) !void {
    const file = try std.fs.cwd().createFile(file_path, .{});
    defer file.close();

    var writer = file.writer();

    try writer.writeAll(INTERVAL_MAGIC);
    try writer.writeInt(u16, INTERVAL_VERSION, .little);
    try writer.writeInt(u16, @sizeOf(T), .little);

    const count = countNodes(tree.root);
    try writer.writeInt(u64, count, .little);

    try writeNodes(T, writer, tree.root);
}

pub fn loadSnapshot(comptime T: type, allocator: std.mem.Allocator, file_path: []const u8) !interval_tree.IntervalTree(T) {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    var reader = file.reader();

    var magic: [4]u8 = undefined;
    try reader.readNoEof(&magic);
    if (!std.mem.eql(u8, &magic, INTERVAL_MAGIC)) return error.InvalidMagic;

    const version = try reader.readInt(u16, .little);
    if (version != INTERVAL_VERSION) return error.UnsupportedVersion;

    const type_size = try reader.readInt(u16, .little);
    if (type_size != @sizeOf(T)) return error.TypeMismatch;

    const count = try reader.readInt(u64, .little);

    var tree = interval_tree.IntervalTree(T).init(allocator);

    for (0..count) |i| {
        _ = i;
        const has_lower = (try reader.readByte()) != 0;
        const has_upper = (try reader.readByte()) != 0;
        const bounds_code = try reader.readByte();
        const bounds = std.meta.intToEnum(@import("../types/range.zig").Range(T).Bounds, bounds_code) catch return error.InvalidBounds;

        var lower: ?T = null;
        var upper: ?T = null;

        if (has_lower) {
            lower = try readValue(T, reader);
        }
        if (has_upper) {
            upper = try readValue(T, reader);
        }

        const data = try reader.readInt(usize, .little);

        const range_val = try @import("../types/range.zig").Range(T).init(lower, upper, bounds);
        try tree.insert(range_val, data);
    }

    return tree;
}

fn countNodes(node: anytype) u64 {
    if (node == null) return 0;
    return 1 + countNodes(node.?.left) + countNodes(node.?.right);
}

fn writeNodes(comptime T: type, writer: anytype, node: anytype) !void {
    if (node == null) return;
    const n = node.?;

    try writer.writeByte(if (n.interval.lower != null) 1 else 0);
    try writer.writeByte(if (n.interval.upper != null) 1 else 0);
    try writer.writeByte(@intFromEnum(n.interval.bounds));

    if (n.interval.lower) |l| {
        try writeValue(T, writer, l);
    }
    if (n.interval.upper) |u| {
        try writeValue(T, writer, u);
    }

    try writer.writeInt(usize, n.data, .little);

    try writeNodes(T, writer, n.left);
    try writeNodes(T, writer, n.right);
}

fn readValue(comptime T: type, reader: anytype) !T {
    return switch (@typeInfo(T)) {
        .Int => try reader.readInt(T, .little),
        .Float => @bitCast(try reader.readInt(std.meta.Int(.unsigned, @bitSizeOf(T)), .little)),
        else => @compileError("Unsupported type for interval tree persistence"),
    };
}

fn writeValue(comptime T: type, writer: anytype, value: T) !void {
    return switch (@typeInfo(T)) {
        .Int => writer.writeInt(T, value, .little),
        .Float => writer.writeInt(std.meta.Int(.unsigned, @bitSizeOf(T)), @bitCast(value), .little),
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
