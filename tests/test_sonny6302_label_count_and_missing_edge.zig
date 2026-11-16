// SONNY-6302 residuals (4) and (5).
//
//   (4) The label counters are keyed by names joined into one key, built on a
//       512-byte stack buffer and on the heap past it. Adding a node to a
//       label posting bumped the (graph, label) count with a key whose
//       allocation failure was `catch return`ed after the node was in the
//       posting (the count stayed low); removing a label built the
//       (graph, label), (graph, tenant) and (label, property) keys of its
//       counter decrements after the label was gone, with the same
//       `catch return` (the counts stayed high, and SHOW / the LSP still
//       listed the label for the tenant). The key, the entry and the
//       removers' room are now made before the change. The readers
//       (`getNodesByLabel`, `snapshotNodesByLabel`, `getEdgeIdsByType`, the
//       edge-type scan) built their key on the stack only and answered "no
//       such label / type" past 512 bytes: `MATCH (n:L)` found nothing.
//       They look the key up without building it now.
//   (5) `setEdgeProperty` of an edge that does not exist returned success
//       (a no-op); it is `EdgeNotFound` now, as `setEdgePropertiesBatch`.
//
// A real in-memory store whose allocator fails exactly ONE chosen
// allocation (a one-shot fault; `std.testing.FailingAllocator` keeps failing,
// which would make the label write fail as a whole and hide the stale
// counter). Every allocation of `addNodeLabel` and `removeNodeLabel` of a
// 600-byte label on a node of a 600-byte tenant is failed in turn: after
// each, whether the write failed or not, the label's posting, its count and
// the tenant's label listing must agree with the node's labels.
//
// CANARY: REQ=REQ-SONNY-6302-WRITE-ERRORS; FEATURE="GraphStoreFailureAtomicity"; ASPECT=LongNameLabelCounter; STATUS=TESTED; TEST=tests/test_sonny6302_label_count_and_missing_edge.zig; OWNER=storage; UPDATED=2026-11-15

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const graph_store = geode.graph_store;

/// Fails allocation number `fail_at` (counting from arming) and no other.
const OneShotFail = struct {
    child: std.mem.Allocator,
    count: usize = 0,
    fail_at: ?usize = null,
    induced: bool = false,

    fn allocator(self: *OneShotFail) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn arm(self: *OneShotFail, k: usize) void {
        self.count = 0;
        self.fail_at = k;
        self.induced = false;
    }

    fn disarm(self: *OneShotFail) bool {
        self.fail_at = null;
        return self.induced;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *OneShotFail = @ptrCast(@alignCast(ctx));
        if (self.fail_at) |k| {
            defer self.count += 1;
            if (self.count == k) {
                self.induced = true;
                return null;
            }
        }
        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *OneShotFail = @ptrCast(@alignCast(ctx));
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *OneShotFail = @ptrCast(@alignCast(ctx));
        return self.child.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *OneShotFail = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

const G = "default";

fn hasLabel(store: *graph_store.GraphStore, id: u64, label: []const u8) !bool {
    const node = store.getNodePtr(id) orelse return error.NodeMissing;
    for (node.labels) |l| if (std.mem.eql(u8, l, label)) return true;
    return false;
}

fn postingHas(store: *graph_store.GraphStore, id: u64, label: []const u8) bool {
    const ids = store.getNodesByLabel(G, label) orelse return false;
    return std.mem.indexOfScalar(u64, ids, id) != null;
}

fn tenantLists(store: *graph_store.GraphStore, tenant: []const u8, label: []const u8) !bool {
    const labels = try store.listNodeLabels(testing.allocator, tenant);
    defer {
        for (labels) |l| testing.allocator.free(l);
        testing.allocator.free(labels);
    }
    for (labels) |l| if (std.mem.eql(u8, l, label)) return true;
    return false;
}

/// The label's posting, count and tenant listing agree with the node.
/// Returns how many disagree.
fn disagreements(store: *graph_store.GraphStore, id: u64, tenant: []const u8, label: []const u8, what: []const u8, k: usize, failed: bool) !usize {
    const has = try hasLabel(store, id, label);
    const posting = postingHas(store, id, label);
    const count = store.countNodesByLabel(G, label, null);
    const listed = try tenantLists(store, tenant, label);
    const want: usize = if (has) 1 else 0;
    if (posting == has and count == want and listed == has) return 0;
    std.debug.print("SONNY-6302 {s}, allocation {d} failing ({s}): node has the label {}, posting {}, count {d}, tenant lists it {}\n", .{ what, k, if (failed) "failed" else "succeeded", has, posting, count, listed });
    return 1;
}

test "SONNY-6302 (4): a label write of a long label and tenant keeps its counters exact whichever allocation fails" {
    var fault = OneShotFail{ .child = testing.allocator };
    var store = try graph_store.GraphStore.init(fault.allocator());
    defer store.deinit();

    const long_label = "L" ** 600;
    const long_tenant = "t" ** 600;
    var base = [_][]const u8{"Base6302"};
    const id = try store.createNodeWithGraphAndTenant(&base, G, long_tenant);
    try store.setNodeProperty(id, "p6302", .{ .Int = 1 });

    var wrong: usize = 0;
    var failures: usize = 0;
    inline for (.{ "addNodeLabel", "removeNodeLabel" }) |what| {
        var k: usize = 0;
        while (k < 512) : (k += 1) {
            // The state the write starts from, written healthy.
            const adding = comptime std.mem.eql(u8, what, "addNodeLabel");
            if (adding) {
                if (try hasLabel(&store, id, long_label)) try store.removeNodeLabel(id, long_label);
            } else {
                if (!try hasLabel(&store, id, long_label)) try store.addNodeLabel(id, long_label);
            }
            wrong += try disagreements(&store, id, long_tenant, long_label, "before " ++ what, k, false);

            fault.arm(k);
            const result = if (adding) store.addNodeLabel(id, long_label) else store.removeNodeLabel(id, long_label);
            const induced = fault.disarm();
            const failed = if (result) |_| false else |_| true;
            if (failed) failures += 1;
            wrong += try disagreements(&store, id, long_tenant, long_label, what, k, failed);
            if (!induced) break;
        }
    }
    try testing.expect(failures > 0);
    try testing.expectEqual(@as(usize, 0), wrong);
}

test "SONNY-6302 (5): setEdgeProperty of an edge that does not exist is EdgeNotFound" {
    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();
    var labels = [_][]const u8{"E6302"};
    const a = try store.createNodeWithGraph(&labels, G);
    const b = try store.createNodeWithGraph(&labels, G);
    const e = try store.createEdgeWithGraph(a, b, "R6302", G);
    try store.setEdgeProperty(e, "w", .{ .Int = 1 });
    try testing.expectError(error.EdgeNotFound, store.setEdgeProperty(e + 1000, "w", .{ .Int = 1 }));
    try testing.expectError(error.EdgeNotFound, store.setEdgePropertiesBatch(e + 1000, &.{.{ .key = "w", .value = .{ .Int = 1 } }}));
}

test "SONNY-6302 (4): a label or relationship type whose key passes 512 bytes is found by the index readers" {
    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();
    const long_label = "M" ** 700;
    const long_type = "T" ** 700;
    var labels = [_][]const u8{long_label};
    const a = try store.createNodeWithGraph(&labels, G);
    const b = try store.createNodeWithGraph(&labels, G);
    const e = try store.createEdgeWithGraph(a, b, long_type, G);

    const ids = store.getNodesByLabel(G, long_label) orelse return error.LabelPostingNotFound;
    try testing.expectEqual(@as(usize, 2), ids.len);
    const copy = (try store.snapshotNodesByLabel(testing.allocator, G, long_label)) orelse return error.LabelPostingNotFound;
    defer testing.allocator.free(copy);
    try testing.expectEqual(@as(usize, 2), copy.len);
    const edges = store.getEdgeIdsByType(G, long_type) orelse return error.EdgeTypePostingNotFound;
    try testing.expectEqual(@as(usize, 1), edges.len);
    try testing.expectEqual(e, edges[0]);
}
