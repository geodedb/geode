const std = @import("std");

// E2E: persistent catalog on disk without server; verifies PageManager + StorageCatalog wiring

test "catalog persists to disk via PageManager.initPersistent" {
    const ally = std.testing.allocator;
    var tmp_dir = try std.testing.tmpDir(.{});
    defer tmp_dir.cleanup();
    const path = try tmp_dir.dir.realpathAlloc(ally, ".");
    defer ally.free(path);

    var pm1 = @import("storage_page_manager").PageManager.initPersistent(ally, 4096, path);
    defer pm1.deinit();
    var cat1 = @import("storage_catalog").StorageCatalog.init(ally, &pm1);
    defer cat1.deinit();
    try cat1.load();
    try cat1.createTable("tbl1", &.{});
    try cat1.save();

    var pm2 = @import("storage_page_manager").PageManager.initPersistent(ally, 4096, path);
    defer pm2.deinit();
    var cat2 = @import("storage_catalog").StorageCatalog.init(ally, &pm2);
    defer cat2.deinit();
    try cat2.load();
    const t = cat2.getTable("tbl1") orelse return error.TableMissing;
    try std.testing.expect(std.mem.eql(u8, t.name, "tbl1"));
}
