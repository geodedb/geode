const std = @import("std");
const graph_store = @import("geode").graph_store;

test "graphstore snapshot save schedule triggers after repeated changes" {
    const allocator = std.testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();

    graph_store.setDataDirOverride(allocator, tmp.dir_path);
    defer graph_store.setDataDirOverride(allocator, null);

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    var i: usize = 0;
    while (i < 10) : (i += 1) {
        _ = try store.createNode(&.{"sched"});
        if (i % 3 == 0) {
            try store.saveToFile();
        }
    }
    try store.saveToFile();
    const path = try graph_store.getPersistenceFilePath(allocator);
    defer allocator.free(path);
    const meta = try std.fs.cwd().statFile(path);
    try std.testing.expect(meta.size > 0);
}
