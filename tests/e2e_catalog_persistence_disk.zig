const std = @import("std");
const geode = @import("geode");

// Zig 0.16 compat: Io.Dir.realpathAlloc removed. Build an absolute path by joining cwd with the relative tmp sub_path.
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const catalog = geode.catalog;

// E2E: persistent catalog on disk without server; verifies Catalog persistence
test "catalog persists to disk via Catalog.init" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const path = try tmpDirRealpathAlloc(allocator, &tmp_dir.sub_path);
    defer allocator.free(path);

    {
        const cat1 = try catalog.Catalog.init(allocator, path);
        defer {
            cat1.deinit();
            allocator.destroy(cat1);
        }

        try cat1.addSchema("s1");
        try cat1.addGraph("g1");
    }

    const cat2 = try catalog.Catalog.init(allocator, path);
    defer {
        cat2.deinit();
        allocator.destroy(cat2);
    }

    try std.testing.expect(cat2.hasSchema("s1"));
    try std.testing.expect(cat2.hasGraph("g1"));
}
