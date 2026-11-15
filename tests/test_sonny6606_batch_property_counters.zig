// SONNY-6606 (2): the batch property writes skipped the PERF-C
// label-property counters (`label_properties_by_tenant`).
//
// `GraphStore.applyNodeBatchInMemory`, under both `setNodePropertiesBatch`
// and the write fast path's `setNodePropertiesBatchInMemoryOnly` (the QUIC
// `CREATE (n:L {k: v})` path, `bulkInsertNode*`), wrote the properties into
// the node and the merge index but never bumped the key's counter, as
// `setNodeProperty` does on a new key. `listPropertiesForLabel`, and so the
// LSP's `n.` completion, therefore never listed a key written that way; a
// removal did not drop it either.
//
// CANARY: REQ=REQ-SONNY-6606-BATCH-PROPERTY-COUNTERS; FEATURE="LspIntrospectionIndex"; ASPECT=BatchWritesCountKeys; STATUS=TESTED; TEST=tests/test_sonny6606_batch_property_counters.zig; OWNER=perf; UPDATED=2026-11-15
const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const graph_store = geode.graph_store;

fn has(allocator: std.mem.Allocator, store: *graph_store.GraphStore, label: []const u8, key: []const u8) !bool {
    const keys = try store.listPropertiesForLabelInGraph(allocator, "g6606", null, label);
    defer {
        for (keys) |k| allocator.free(k);
        allocator.free(keys);
    }
    for (keys) |k| if (std.mem.eql(u8, k, key)) return true;
    return false;
}

test "SONNY-6606 (2): batch property writes keep the label-property listing current" {
    const allocator = testing.allocator;
    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    try store.createGraph("g6606");

    const a = try store.createNodeWithGraphAndTenant(&.{ "A6606", "B6606" }, "g6606", "");
    try store.setNodePropertiesBatch(a, &.{
        .{ .key = "batch_k1", .value = .{ .Int = 1 } },
        .{ .key = "batch_k2", .value = .{ .Int = 2 } },
    });
    try testing.expect(try has(allocator, &store, "A6606", "batch_k1"));
    try testing.expect(try has(allocator, &store, "B6606", "batch_k2"));

    // The fast path's in-memory-only twin.
    const b = try store.createNodeWithGraphAndTenant(&.{"A6606"}, "g6606", "");
    try store.setNodePropertiesBatchInMemoryOnly(b, &.{.{ .key = "fast_k", .value = .{ .Int = 3 } }});
    try testing.expect(try has(allocator, &store, "A6606", "fast_k"));

    // A value update counts nothing more: one removal of the last carrier
    // drops the key.
    try store.setNodePropertiesBatch(b, &.{.{ .key = "fast_k", .value = .{ .Int = 4 } }});
    try store.setNodePropertiesBatch(b, &.{.{ .key = "fast_k", .value = null }});
    try testing.expect(!try has(allocator, &store, "A6606", "fast_k"));
    // Another node still carries batch_k1.
    try testing.expect(try has(allocator, &store, "A6606", "batch_k1"));
    try store.setNodePropertiesBatch(a, &.{.{ .key = "batch_k1", .value = null }});
    try testing.expect(!try has(allocator, &store, "A6606", "batch_k1"));
    try testing.expect(!try has(allocator, &store, "B6606", "batch_k1"));
}
