// CANARY: REQ=REQ-FLE-CONCURRENT-RECORDID-001; FEATURE="FLEConcurrentSafety"; ASPECT=RegressionTest; STATUS=TESTED; TEST=tests/test_fle_allocprint_alias_regression.zig; OWNER=security; UPDATED=2026-04-22
//
// Regression test: production panic 2026-04-22 on celebrimbor —
//   "thread panic: @memcpy arguments alias"
//   ArrayList.ensureTotalCapacityPrecise <- drain <- writeAll <- printIntAny
//     <- allocPrint <- getNodeProperty <- loadUserRecordFromNode
//     <- findUserByUsernameInGraph <- lookupPersistentAuthVersion
//     <- isSessionAuthCurrent <- validateSessionAuth
//     <- handleClientMessage (thread-pool)
//
// The FLE encrypt/decrypt paths in graph_store.zig formatted their
// `"node_<id>"` / `"edge_<id>"` record identifier via
// `std.fmt.allocPrint(self.allocator, ...)`. `self.allocator` is shared across
// all QUIC handler threads; under concurrent auth lookups, allocPrint's
// internal ArrayList drain hit an aliasing allocation and the @memcpy inside
// ensureTotalCapacityPrecise panicked.
//
// Fix: format the record ID on a 32-byte stack buffer via `std.fmt.bufPrint`
// — no allocator involvement, no aliasing possible. This test drives the
// patched path under heavy concurrency to guard against future regressions
// that reintroduce allocPrint on the shared store allocator.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const graph_store = geode.graph_store;
const fle_integration = geode.fle_integration;

const ThreadCtx = struct {
    store: *graph_store.GraphStore,
    node_id: u64,
    key: []const u8,
    iterations: usize,
    hit_count: *std.atomic.Value(u64),
};

fn hammerGetNodeProperty(ctx: *ThreadCtx) void {
    var i: usize = 0;
    while (i < ctx.iterations) : (i += 1) {
        if ((ctx.store.getNodePropertyOrError(ctx.node_id, ctx.key) catch @panic("SONNY-6621: unexpected read failure"))) |_| {
            _ = ctx.hit_count.fetchAdd(1, .monotonic);
        }
    }
}

test "REQ-FLE-CONCURRENT-RECORDID-001: concurrent getNodeProperty under FLE does not alias" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Force the FLE slow path (hasEncryptedFields == true) so getNodeProperty
    // enters the record-id formatting branch. decryptFieldIfNeeded will see
    // no matching catalog entry for "TestNode.name" and return the plaintext
    // unchanged — that's fine, we're exercising the allocator path, not the
    // crypto.
    fle_integration.setHasEncryptedFields(true);
    defer fle_integration.setHasEncryptedFields(false);

    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();

    const node_id = try store.createNode(&.{"TestNode"});
    try store.setNodeProperty(node_id, "name", .{ .String = "alice" });

    const thread_count: usize = 8;
    const per_thread_iters: usize = 1000;
    var hit_count = std.atomic.Value(u64).init(0);

    var ctx = ThreadCtx{
        .store = &store,
        .node_id = node_id,
        .key = "name",
        .iterations = per_thread_iters,
        .hit_count = &hit_count,
    };

    var threads: [thread_count]std.Thread = undefined;
    for (&threads) |*t| {
        t.* = try std.Thread.spawn(.{}, hammerGetNodeProperty, .{&ctx});
    }
    for (threads) |t| t.join();

    // Every iteration across every thread should have found the property.
    try testing.expectEqual(
        @as(u64, thread_count * per_thread_iters),
        hit_count.load(.monotonic),
    );
}
