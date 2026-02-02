const std = @import("std");
const page_manager = @import("page_manager.zig");
const hybrid_topology = @import("hybrid_topology.zig");

test "HybridEngine: Node Creation and Retrieval" {
    var pm = page_manager.PageManager.initInMemory(std.testing.allocator, 8192);
    defer pm.deinit();

    var topology = hybrid_topology.HybridTopology.init(std.testing.allocator, &pm);
    defer topology.deinit();

    try topology.createNode(100);
    try topology.createNode(200);

    // Check internal index
    try std.testing.expect(topology.node_index.get(100) != null);
    try std.testing.expect(topology.node_index.get(200) != null);
}

test "HybridEngine: Edge Insertion and Traversal (Delta Only)" {
    var pm = page_manager.PageManager.initInMemory(std.testing.allocator, 8192);
    defer pm.deinit();
    var topology = hybrid_topology.HybridTopology.init(std.testing.allocator, &pm);
    defer topology.deinit();

    try topology.createNode(1);

    // Insert 5 edges with varying Txn IDs
    // (n1) -> (n10) @ txn 100
    // (n1) -> (n11) @ txn 100
    // (n1) -> (n12) @ txn 102
    try topology.addEdge(1, 10, 1000, 1, 100);
    try topology.addEdge(1, 11, 1001, 1, 100);
    try topology.addEdge(1, 12, 1002, 1, 102);

    // Scan at txn 101 (Should see 10, 11, NOT 12)
    var it = try topology.getNeighbors(1, 101);

    var seen_10 = false;
    var seen_11 = false;
    var seen_12 = false;

    while (try it.next()) |neighbor| {
        if (neighbor == 10) seen_10 = true;
        if (neighbor == 11) seen_11 = true;
        if (neighbor == 12) seen_12 = true;
    }

    try std.testing.expect(seen_10);
    try std.testing.expect(seen_11);
    try std.testing.expect(!seen_12); // Invisible

    // Scan at txn 200 (Should see all)
    var it2 = try topology.getNeighbors(1, 200);
    while (try it2.next()) |neighbor| {
        if (neighbor == 12) seen_12 = true;
    }
    try std.testing.expect(seen_12);
}

test "HybridEngine: Delta Block Chaining" {
    var pm = page_manager.PageManager.initInMemory(std.testing.allocator, 8192);
    defer pm.deinit();
    var topology = hybrid_topology.HybridTopology.init(std.testing.allocator, &pm);
    defer topology.deinit();

    try topology.createNode(1);

    // Force multiple blocks (capacity is 4 per block)
    // Insert 10 edges
    var i: u64 = 0;
    while (i < 10) : (i += 1) {
        try topology.addEdge(1, 100 + i, 1000 + i, 1, 100);
    }

    // Iterate and count
    var count: usize = 0;
    var it = try topology.getNeighbors(1, 200);
    while (try it.next()) |_| {
        count += 1;
    }

    try std.testing.expectEqual(count, 10);
}
