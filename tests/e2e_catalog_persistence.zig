const std = @import("std");
const catalog = @import("../src/schema/catalog.zig");

// E2E: basic catalog persistence smoke (create schema/index -> restart -> verify)
test "catalog persistence across save/load" {
    const allocator = std.testing.allocator;

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    const data_dir = try tmp.dir.realpathAlloc(allocator, ".");
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
