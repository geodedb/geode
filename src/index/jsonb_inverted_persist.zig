const std = @import("std");
const JsonbInvertedIndex = @import("jsonb_inverted.zig").JsonbInvertedIndex;

const JSONB_MAGIC = "GDJB";
const JSONB_VERSION: u16 = 1;

pub fn persistSnapshot(index: *JsonbInvertedIndex, file_path: []const u8) !void {
    const file = try std.fs.cwd().createFile(file_path, .{});
    defer file.close();

    var writer = file.writer();

    try writer.writeAll(JSONB_MAGIC);
    try writer.writeInt(u16, JSONB_VERSION, .little);
    try writer.writeInt(u64, @intCast(index.paths.count()), .little);

    var iter = index.paths.iterator();
    while (iter.next()) |entry| {
        const path = entry.key_ptr.*;
        const doc_ids = entry.value_ptr.items;

        try writer.writeInt(u32, @intCast(path.len), .little);
        try writer.writeAll(path);
        try writer.writeInt(u32, @intCast(doc_ids.len), .little);

        for (doc_ids) |doc_id| {
            try writer.writeInt(usize, doc_id, .little);
        }
    }
}

pub fn loadSnapshot(allocator: std.mem.Allocator, file_path: []const u8) !JsonbInvertedIndex {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    var reader = file.reader();

    var magic: [4]u8 = undefined;
    try reader.readNoEof(&magic);
    if (!std.mem.eql(u8, &magic, JSONB_MAGIC)) return error.InvalidMagic;

    const version = try reader.readInt(u16, .little);
    if (version != JSONB_VERSION) return error.UnsupportedVersion;

    const entry_count = try reader.readInt(u64, .little);

    var index = JsonbInvertedIndex.init(allocator);

    for (0..entry_count) |_| {
        const path_len = try reader.readInt(u32, .little);
        const path = try allocator.alloc(u8, path_len);
        try reader.readNoEof(path);

        const doc_count = try reader.readInt(u32, .little);
        var doc_list = std.ArrayList(usize).init(allocator);

        for (0..doc_count) |_| {
            const doc_id = try reader.readInt(usize, .little);
            try doc_list.append(doc_id);
        }

        try index.paths.put(path, doc_list);
    }

    return index;
}

test "jsonb index persistence" {
    const allocator = std.testing.allocator;
    var index = JsonbInvertedIndex.init(allocator);
    defer index.deinit();

    const doc = try @import("../types/jsonb.zig").JsonbDocument.fromString(allocator, "{\"key\":\"value\"}");
    defer doc.deinit();

    try index.indexDocument(42, doc);

    try persistSnapshot(&index, "/tmp/test_jsonb.gdjb");

    var loaded = try loadSnapshot(allocator, "/tmp/test_jsonb.gdjb");
    defer loaded.deinit();

    const results = try loaded.queryPath("key", allocator);
    defer allocator.free(results);

    std.testing.expect(results.len == 1) catch unreachable;
    std.testing.expect(results[0] == 42) catch unreachable;
}
