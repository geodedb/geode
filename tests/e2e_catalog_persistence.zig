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

// E2E: basic catalog persistence smoke (create schema/index -> restart -> verify)
test "catalog persistence across save/load" {
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

        try cat.addSchema("public");
        try cat.addGraph("g1");

        const cols = [_][]const u8{"id"};
        const info = catalog.IndexInfo{
            .name = "t_idx",
            .index_type = "btree",
            .table_name = "t",
            .columns = @as([][]const u8, @constCast(cols[0..])),
        };
        try cat.addIndex(info);
    }

    const cat2 = try catalog.Catalog.init(allocator, data_dir);
    defer {
        cat2.deinit();
        allocator.destroy(cat2);
    }

    try std.testing.expect(cat2.hasSchema("public"));
    try std.testing.expect(cat2.hasGraph("g1"));
    const idx = try cat2.getIndex("t", "t_idx");
    try std.testing.expect(idx != null);
}
