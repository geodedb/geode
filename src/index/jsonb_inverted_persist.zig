const std = @import("std");
const JsonbInvertedIndex = @import("jsonb_inverted.zig").JsonbInvertedIndex;

const JSONB_MAGIC = "GDJB";
const JSONB_VERSION: u16 = 1;

pub fn persistSnapshot(index: *JsonbInvertedIndex, file_path: []const u8) !void {
    const file = try std.fs.cwd().createFile(file_path, .{});
    defer file.close();

    try file.writeAll(JSONB_MAGIC);

    var version_buf: [2]u8 = undefined;
    std.mem.writeInt(u16, &version_buf, JSONB_VERSION, .little);
    try file.writeAll(&version_buf);

    var count_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &count_buf, @intCast(index.paths.count()), .little);
    try file.writeAll(&count_buf);

    var iter = index.paths.iterator();
    while (iter.next()) |entry| {
        const path = entry.key_ptr.*;
        const doc_ids = entry.value_ptr.items;

        var path_len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &path_len_buf, @intCast(path.len), .little);
        try file.writeAll(&path_len_buf);
        try file.writeAll(path);

        var doc_len_buf: [4]u8 = undefined;
        std.mem.writeInt(u32, &doc_len_buf, @intCast(doc_ids.len), .little);
        try file.writeAll(&doc_len_buf);

        for (doc_ids) |doc_id| {
            var doc_id_buf: [8]u8 = undefined;
            std.mem.writeInt(usize, &doc_id_buf, doc_id, .little);
            try file.writeAll(&doc_id_buf);
        }
    }
}

pub fn loadSnapshot(allocator: std.mem.Allocator, file_path: []const u8) !JsonbInvertedIndex {
    const file = try std.fs.cwd().openFile(file_path, .{});
    defer file.close();

    // Read and validate magic number
    var magic: [4]u8 = undefined;
    _ = try file.read(&magic);
    if (!std.mem.eql(u8, &magic, JSONB_MAGIC)) return error.InvalidMagic;

    // Read version
    var version_buf: [2]u8 = undefined;
    _ = try file.read(&version_buf);
    const version = std.mem.readInt(u16, &version_buf, .little);
    if (version != JSONB_VERSION) return error.UnsupportedVersion;

    // Read entry count
    var count_buf: [8]u8 = undefined;
    _ = try file.read(&count_buf);
    const entry_count = std.mem.readInt(u64, &count_buf, .little);

    var index = JsonbInvertedIndex.init(allocator);

    for (0..entry_count) |_| {
        // Read path length
        var path_len_buf: [4]u8 = undefined;
        _ = try file.read(&path_len_buf);
        const path_len = std.mem.readInt(u32, &path_len_buf, .little);

        const path = try allocator.alloc(u8, path_len);
        _ = try file.read(path);

        // Read doc count
        var doc_count_buf: [4]u8 = undefined;
        _ = try file.read(&doc_count_buf);
        const doc_count = std.mem.readInt(u32, &doc_count_buf, .little);

        var doc_list = std.ArrayList(usize).initCapacity(allocator, doc_count) catch return error.OutOfMemory;

        for (0..doc_count) |_| {
            var doc_id_buf: [8]u8 = undefined;
            _ = try file.read(&doc_id_buf);
            const doc_id = std.mem.readInt(usize, &doc_id_buf, .little);
            try doc_list.append(allocator, doc_id);
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
