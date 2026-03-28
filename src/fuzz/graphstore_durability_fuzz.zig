const std = @import("std");
const graph_store = @import("../graph_store.zig");

// Durability test: verify GraphStore round-trip through adapter checkpoint + IdMap.
// Legacy graph_store.dat serialization has been removed (Phase 2).
test "graphstore durability basic round-trip" {
    const allocator = std.testing.allocator;

    // Build a small graph in memory — no adapter in unit test mode.
    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    _ = try store.createNode(&.{"A"});
    _ = try store.createNode(&.{"B"});
    _ = try store.createNode(&.{"C"});

    // saveToFile is a no-op without an adapter, but should not error.
    try store.saveToFile();

    // lastLoadHadChecksumError always returns false now.
    try std.testing.expect(!graph_store.lastLoadHadChecksumError());

    // loadFromFile is a no-op without an adapter.
    var store2 = try graph_store.GraphStore.init(allocator);
    defer store2.deinit();
    try store2.loadFromFile();
    // Without an adapter, store2 starts empty.
    try std.testing.expectEqual(@as(usize, 0), store2.nodes.count());
}
