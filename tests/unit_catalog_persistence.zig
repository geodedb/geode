const std = @import("std");
const catalog = @import("../src/schema/catalog.zig");


// Zig 0.16 compat: Io.Dir.realpathAlloc removed. Build an absolute path by joining cwd with the relative tmp sub_path.
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

test "catalog persistence with GraphStore backing" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    {
        const cat = try catalog.Catalog.init(allocator, data_dir);
        defer {
            cat.deinit();
            allocator.destroy(cat);
        }

        try std.testing.expectEqual(@as(usize, 0), cat.schemas.count());

        try cat.addSchema("public");

        const index_columns = [_][]const u8{"id"};
        const index_info = catalog.IndexInfo{
            .name = "users_pk",
            .index_type = "btree",
            .table_name = "users",
            .columns = @as([][]const u8, @constCast(index_columns[0..])),
        };
        try cat.addIndex(index_info);
    }

    const cat2 = try catalog.Catalog.init(allocator, data_dir);
    defer {
        cat2.deinit();
        allocator.destroy(cat2);
    }

    try std.testing.expect(cat2.hasSchema("public"));
    const index_meta = try cat2.getIndex("users", "users_pk");
    try std.testing.expect(index_meta != null);
    try std.testing.expectEqualStrings("users_pk", index_meta.?.name);
    try std.testing.expectEqualStrings("users", index_meta.?.table_name);
}
