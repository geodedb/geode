const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const graph_store = geode.graph_store;
const datasets = @import("query_datasets");

test "seedPerson(500) creates exactly 500 LT_Person nodes with unique lt_id" {
    graph_store.deinitGlobalStore();
    defer graph_store.deinitGlobalStore();

    try datasets.seedPerson(testing.allocator, "default", 500);
    const store = graph_store.getWritableGlobalStore(testing.allocator);

    var count: usize = 0;
    var seen_ids = std.AutoHashMap(i64, void).init(testing.allocator);
    defer seen_ids.deinit();

    var iter = store.nodes.iterator();
    while (iter.next()) |entry| {
        const node = entry.value_ptr;
        for (node.labels) |label| {
            if (std.mem.eql(u8, label, "LT_Person")) {
                count += 1;
                const lt_id = node.properties.get("lt_id") orelse continue;
                try testing.expect(!seen_ids.contains(lt_id.Int));
                try seen_ids.put(lt_id.Int, {});
                break;
            }
        }
    }
    try testing.expectEqual(@as(usize, 500), count);
}

test "seedPerson is deterministic across runs" {
    graph_store.deinitGlobalStore();
    defer graph_store.deinitGlobalStore();
    try datasets.seedPerson(testing.allocator, "default", 10);
    const first_run = graph_store.getWritableGlobalStore(testing.allocator).nodes.count();

    graph_store.deinitGlobalStore();
    try datasets.seedPerson(testing.allocator, "default", 10);
    const second_run = graph_store.getWritableGlobalStore(testing.allocator).nodes.count();

    try testing.expectEqual(first_run, second_run);
}
