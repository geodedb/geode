const std = @import("std");
const geode = @import("geode");
const catalog = geode.catalog;

// E2E: persistent catalog on disk without server; verifies Catalog persistence
test "catalog persists to disk via Catalog.init" {
    const allocator = std.testing.allocator;
    var tmp_dir = std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();

    const path = try tmp_dir.dir.realpathAlloc(allocator, ".");
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
