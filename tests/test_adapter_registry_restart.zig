// Bug fix 2026-04-27: regression test for the adapter-restart deadlock
// in `NodePropertyExactIndex.loadFromFile`.  See
// docs/bugs/2026-04-27-adapter-restart-deadlock.md for the full report.
//
// Pre-fix symptom: when a graph was checkpointed and the adapter was
// reopened (loading the persisted property index from disk), the
// reopen path called `NodePropertyExactIndex.loadFromFile`, which
// acquired `self.mutex`, then called `self.clear()`, which tried to
// acquire `self.mutex` AGAIN.  `std.Io.Mutex` is non-reentrant, so
// the test hung forever.  Reproduced 100% in this standalone test
// (and also in the in-source test 93 of the lib_unit_tests binary).
//
// Post-fix: `loadFromFile` calls `clearLocked()` (no inner lock).
// This test passes deterministically (5/5 runs).

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const adapter_mod = geode.graph_storage_adapter;
const StorageAdapter = adapter_mod.StorageAdapter;
const gs = @import("graph_storage");

fn testConfig() gs.GraphConfig {
    return .{
        .page_size = 4096,
        .buffer_pool_pages = 64,
    };
}

test "adapter registry: persistence across restart (standalone reproducer)" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();

    const path = try std.fmt.allocPrint(allocator, ".zig-cache/tmp/{s}", .{&tmp.sub_path});
    defer allocator.free(path);

    {
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        defer adapter.deinit();

        const graph = "persisted_graph";
        const node_id = try adapter.createNode(graph, &[_][]const u8{"Person"});
        try adapter.setNodeProperty(graph, node_id, "name", .{ .String = "Alice" });
        try adapter.checkpointAll();
        try testing.expect(adapter.graphExists(graph));
    }

    {
        const adapter = try StorageAdapter.init(allocator, path, testConfig());
        defer adapter.deinit();

        try testing.expect(adapter.graphExists("persisted_graph"));

        const names = try adapter.listGraphNames(allocator);
        defer {
            for (names) |name| allocator.free(name);
            allocator.free(names);
        }

        var found = false;
        for (names) |name| {
            if (std.mem.eql(u8, name, "persisted_graph")) found = true;
        }
        try testing.expect(found);

        _ = try adapter.getOrCreateGraph("persisted_graph");
        try testing.expectEqual(@as(u64, 1), try adapter.nodeCount("persisted_graph"));
    }
}
