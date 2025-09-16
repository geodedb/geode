const std = @import("std");
const catalog = @import("../src/storage/catalog.zig");
const page_manager = @import("../src/storage/page_manager.zig");

test "storage catalog persistence" {
    var pm = page_manager.PageManager.initInMemory(std.testing.allocator, 4096);
    defer pm.deinit();
    
    var cat = catalog.StorageCatalog.init(std.testing.allocator, &pm);
    defer cat.deinit();
    
    // Load empty catalog
    try cat.load();
    try std.testing.expect(cat.tables.count() == 0);
    
    // Create a table
    const columns = [_]catalog.StorageCatalog.TableMetadata.ColumnMetadata{
        .{ .name = "id", .type_name = "INTEGER", .nullable = false, .default_value = null, .ordinal_position = 1 },
        .{ .name = "name", .type_name = "TEXT", .nullable = true, .default_value = null, .ordinal_position = 2 },
    };
    
    try cat.createTable("users", &columns);
    try std.testing.expect(cat.tables.count() == 1);
    
    // Verify table exists
    const table_meta = cat.getTable("users");
    try std.testing.expect(table_meta != null);
    try std.testing.expect(std.mem.eql(u8, table_meta.?.name, "users"));
    try std.testing.expect(table_meta.?.columns.len == 2);
    
    // Create an index
    const index_columns = [_][]const u8{"id"};
    try cat.createIndex("users_pk", "users", &index_columns, true);
    
    // Verify index exists
    const index_meta = cat.getIndex("users_pk");
    try std.testing.expect(index_meta != null);
    try std.testing.expect(std.mem.eql(u8, index_meta.?.name, "users_pk"));
    try std.testing.expect(index_meta.?.unique == true);
}