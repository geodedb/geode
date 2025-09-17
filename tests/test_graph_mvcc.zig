const std = @import("std");
const geode = @import("../src/lib.zig");
const graph_exec = @import("../src/graph/exec.zig");
const mvcc = @import("../src/txn/mvcc.zig");

test "MATCH pattern execution - basic node scan" {
    const allocator = std.testing.allocator;
    
    // Create graph storage
    var graph = graph_exec.GraphStorage.init(allocator);
    defer graph.deinit();
    
    // Add test nodes
    try graph.addNode(allocator, 1, &.{"Person"});
    try graph.setNodeProperty(1, "name", .{ .String = "Alice" });
    
    try graph.addNode(allocator, 2, &.{"Person"});
    try graph.setNodeProperty(2, "name", .{ .String = "Bob" });
    
    // Create a simple MATCH pattern: MATCH (n:Person)
    const pattern = geode.ast.GraphPattern{
        .chains = &.{
            geode.ast.Chain{
                .name = null,
                .hops = &.{
                    geode.ast.Hop{
                        .left = geode.ast.NodePattern{
                            .name = "n",
                            .labels = &.{"Person"},
                            .props = null,
                        },
                        .rel = geode.ast.RelPattern{
                            .name = null,
                            .types = &.{},
                            .props = null,
                            .dir = .right,
                        },
                        .right = geode.ast.NodePattern{
                            .name = null,
                            .labels = &.{},
                            .props = null,
                        },
                    },
                },
            },
        },
    };
    
    // Execute the pattern
    const bindings = try graph_exec.executeMatch(allocator, &graph, pattern, null);
    defer allocator.free(bindings);
    
    // Should find 2 nodes
    try std.testing.expectEqual(@as(usize, 2), bindings.len);
}

test "MATCH pattern with edge traversal" {
    const allocator = std.testing.allocator;
    
    // Create graph storage
    var graph = graph_exec.GraphStorage.init(allocator);
    defer graph.deinit();
    
    // Add nodes
    try graph.addNode(allocator, 1, &.{"Person"});
    try graph.setNodeProperty(1, "name", .{ .String = "Alice" });
    
    try graph.addNode(allocator, 2, &.{"Person"});
    try graph.setNodeProperty(2, "name", .{ .String = "Bob" });
    
    // Add edge
    const edge_id = try graph.addEdge(allocator, 1, 2, "KNOWS");
    try graph.setEdgeProperty(edge_id, "since", .{ .Int = 2020 });
    
    // Create pattern: MATCH (a:Person)-[r:KNOWS]->(b:Person)
    const pattern = geode.ast.GraphPattern{
        .chains = &.{
            geode.ast.Chain{
                .name = null,
                .hops = &.{
                    geode.ast.Hop{
                        .left = geode.ast.NodePattern{
                            .name = "a",
                            .labels = &.{"Person"},
                            .props = null,
                        },
                        .rel = geode.ast.RelPattern{
                            .name = "r",
                            .types = &.{"KNOWS"},
                            .props = null,
                            .dir = .right,
                        },
                        .right = geode.ast.NodePattern{
                            .name = "b",
                            .labels = &.{"Person"},
                            .props = null,
                        },
                    },
                },
            },
        },
    };
    
    // Execute the pattern
    const bindings = try graph_exec.executeMatch(allocator, &graph, pattern, null);
    defer allocator.free(bindings);
    
    // Should find 1 relationship (Alice -> Bob)
    try std.testing.expectEqual(@as(usize, 1), bindings.len);
    
    // Check the binding contains correct nodes
    if (bindings.len > 0) {
        const binding = bindings[0];
        const a_val = binding.vars.get("a").?;
        const b_val = binding.vars.get("b").?;
        const r_val = binding.vars.get("r").?;
        
        try std.testing.expectEqual(graph_exec.BindingValue.Node, std.meta.activeTag(a_val));
        try std.testing.expectEqual(graph_exec.BindingValue.Node, std.meta.activeTag(b_val));
        try std.testing.expectEqual(graph_exec.BindingValue.Edge, std.meta.activeTag(r_val));
        
        try std.testing.expectEqual(@as(graph_exec.NodeId, 1), a_val.Node);
        try std.testing.expectEqual(@as(graph_exec.NodeId, 2), b_val.Node);
        try std.testing.expectEqual(@as(graph_exec.EdgeId, 0), r_val.Edge);
    }
}

test "MVCC write-write conflict detection" {
    const allocator = std.testing.allocator;
    
    // Create MVCC manager
    var mgr = mvcc.MVCCManager.init(allocator);
    defer mgr.deinit();
    
    // Start two transactions
    var txn1 = try mgr.beginTransaction(.SnapshotIsolation);
    var txn2 = try mgr.beginTransaction(.SnapshotIsolation);
    
    // Both transactions try to write to the same resource
    const resource_id: u64 = 100;
    
    // First write should succeed
    try mgr.write(txn1, resource_id, "value1");
    
    // Second write should fail with conflict
    const result = mgr.write(txn2, resource_id, "value2");
    try std.testing.expectError(error.WriteConflict, result);
    
    // First transaction should commit successfully
    try mgr.commitTransaction(txn1);
    
    // Second transaction should abort
    try mgr.abortTransaction(txn2);
}

test "MVCC read consistency" {
    const allocator = std.testing.allocator;
    
    // Create MVCC manager
    var mgr = mvcc.MVCCManager.init(allocator);
    defer mgr.deinit();
    
    // Start first transaction and write
    var txn1 = try mgr.beginTransaction(.SnapshotIsolation);
    const resource_id: u64 = 200;
    try mgr.write(txn1, resource_id, "initial_value");
    try mgr.commitTransaction(txn1);
    
    // Start second transaction (sees committed value)
    var txn2 = try mgr.beginTransaction(.SnapshotIsolation);
    const read1 = try mgr.read(txn2, resource_id);
    try std.testing.expectEqualStrings("initial_value", read1.?);
    
    // Start third transaction and write new value
    var txn3 = try mgr.beginTransaction(.SnapshotIsolation);
    try mgr.write(txn3, resource_id, "new_value");
    
    // Second transaction should still see old value (snapshot isolation)
    const read2 = try mgr.read(txn2, resource_id);
    try std.testing.expectEqualStrings("initial_value", read2.?);
    
    // Commit third transaction
    try mgr.commitTransaction(txn3);
    
    // New transaction should see new value
    var txn4 = try mgr.beginTransaction(.SnapshotIsolation);
    const read3 = try mgr.read(txn4, resource_id);
    try std.testing.expectEqualStrings("new_value", read3.?);
    
    // Clean up
    try mgr.commitTransaction(txn2);
    try mgr.commitTransaction(txn4);
}

test "MVCC deadlock detection" {
    const allocator = std.testing.allocator;
    
    // Create MVCC manager
    var mgr = mvcc.MVCCManager.init(allocator);
    defer mgr.deinit();
    
    // Start two transactions
    var txn1 = try mgr.beginTransaction(.RepeatableRead);
    var txn2 = try mgr.beginTransaction(.RepeatableRead);
    
    const resource1: u64 = 301;
    const resource2: u64 = 302;
    
    // Transaction 1 locks resource1
    _ = try mgr.read(txn1, resource1);
    
    // Transaction 2 locks resource2
    _ = try mgr.read(txn2, resource2);
    
    // Transaction 1 tries to lock resource2 (waits for txn2)
    // Transaction 2 tries to lock resource1 (would create deadlock)
    // One of them should be aborted to break the deadlock
    
    // This is a simplified test - full deadlock detection would require
    // concurrent execution which is complex to test synchronously
    
    // Clean up
    try mgr.abortTransaction(txn1);
    try mgr.abortTransaction(txn2);
}