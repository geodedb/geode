const std = @import("std");

// E2E: basic catalog persistence smoke (create table -> restart -> verify)
// This uses the StorageCatalog API directly to avoid missing DDL front-end.

test "storage catalog persistence across save/load" {
    const allocator = std.testing.allocator;
    var pm = @import("../src/storage/page_manager.zig").PageManager.initInMemory(allocator, 4096);
    defer pm.deinit();

    var cat = @import("../src/storage/catalog.zig").StorageCatalog.init(allocator, &pm);
    defer cat.deinit();

    try cat.load();
    try cat.createTable("t", &.{});
    try cat.save();

    var cat2 = @import("../src/storage/catalog.zig").StorageCatalog.init(allocator, &pm);
    defer cat2.deinit();
    try cat2.load();

    const t = cat2.getTable("t") orelse return error.TableMissing;
    try std.testing.expect(std.mem.eql(u8, t.name, "t"));
}
