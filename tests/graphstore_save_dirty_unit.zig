const std = @import("std");
const graph_store = @import("geode").graph_store;

// Unit test: exercise GraphStore dirty/save behavior.
test "graphstore saveIfDirty respects clean state" {
    const gpa = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    graph_store.setDataDirOverride(gpa, tmp.dir_path);
    defer graph_store.setDataDirOverride(gpa, null);

    var store = try graph_store.GraphStore.init(gpa);
    defer store.deinit();

    try std.testing.expect(!store.isDirty());
    store.saveIfDirty();
    try std.testing.expect(!store.isDirty());

    _ = try store.createNode(&.{ "A" });
    try std.testing.expect(store.isDirty());

    try store.saveToFile();
    try std.testing.expect(!store.isDirty());
}
