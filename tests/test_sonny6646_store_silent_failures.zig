// SONNY-6646: GraphStore readers that answered a failure as an empty result.
//
//   (3) `countNodesByLabel` (with and without a tenant) and
//       `countEdgesByTypeForGraph` built their (graph, name) key on a 512-byte
//       stack buffer and on the heap past it, and `catch return 0`ed the
//       allocation: a label or type with a long key counted 0 whenever that
//       allocation failed. They look the key up without building it now.
//   (4) `getEdgesByType` answered every failure (the result list, the graph
//       name copy, an engine read) as "no edges", and skipped a graph whose
//       posting could not be copied. It returns the error now.
//
// A real in-memory store whose allocator (or the allocator passed to the
// reader) fails exactly ONE chosen allocation, for each allocation in turn
// until the call needs none of them. Every answer must be either the right
// one or an error; a wrong answer counts as a failure of the test.
//
// CANARY: REQ=REQ-SONNY-6646-STORE-SILENT-FAILURES; FEATURE="GraphStoreFailureAtomicity"; ASPECT=ReaderErrors; STATUS=TESTED; TEST=tests/test_sonny6646_store_silent_failures.zig; OWNER=storage; UPDATED=2026-11-15

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

/// `getEdgesByType` as an error union (it returned a bare slice before the
/// fix; this compiles against either).
fn edgesByType(store: *graph_store.GraphStore, a: std.mem.Allocator, edge_type: []const u8, tenant: ?[]const u8, graph: ?[]const u8) ![]u64 {
    return store.getEdgesByType(a, edge_type, tenant, graph);
}

test "SONNY-6646 (3): a label or type count of a long key is exact whichever allocation fails" {
    var fault = OneShotFail{ .child = testing.allocator };
    var store = try graph_store.GraphStore.init(fault.allocator());
    defer store.deinit();

    const long_label = "C" ** 600;
    const long_type = "Y" ** 600;
    const tenant = "t6646";
    var labels = [_][]const u8{long_label};
    const a = try store.createNodeWithGraphAndTenant(&labels, G, tenant);
    const b = try store.createNodeWithGraphAndTenant(&labels, G, tenant);
    _ = try store.createEdgeWithGraph(a, b, long_type, G);

    var wrong: usize = 0;
    var k: usize = 0;
    while (k < 64) : (k += 1) {
        fault.arm(k);
        const by_label = store.countNodesByLabel(G, long_label, null);
        const by_tenant = store.countNodesByLabel(G, long_label, tenant);
        const by_type = store.countEdgesByTypeForGraph(G, long_type);
        const induced = fault.disarm();
        if (by_label != 2 or by_tenant != 2 or by_type != 1) {
            std.debug.print("SONNY-6646 (3): allocation {d} failing: label count {d} (want 2), tenant count {d} (want 2), type count {d} (want 1)\n", .{ k, by_label, by_tenant, by_type });
            wrong += 1;
        }
        if (!induced) break;
    }
    try testing.expectEqual(@as(usize, 0), wrong);
}

test "SONNY-6646 (4): getEdgesByType answers all the edges or an error whichever allocation fails" {
    var store = try graph_store.GraphStore.init(testing.allocator);
    defer store.deinit();
    try store.createGraph("g2");

    var labels = [_][]const u8{"E6646"};
    const a = try store.createNodeWithGraph(&labels, G);
    const b = try store.createNodeWithGraph(&labels, G);
    const c = try store.createNodeWithGraph(&labels, "g2");
    const d = try store.createNodeWithGraph(&labels, "g2");
    _ = try store.createEdgeWithGraph(a, b, "R6646", G);
    _ = try store.createEdgeWithGraph(b, a, "R6646", G);
    _ = try store.createEdgeWithGraph(c, d, "R6646", "g2");

    var fault = OneShotFail{ .child = testing.allocator };
    var wrong: usize = 0;
    var errors: usize = 0;
    // One graph (2 edges), every graph (3), and every graph for a tenant.
    const cases = [_]struct { graph: ?[]const u8, tenant: ?[]const u8, want: usize }{
        .{ .graph = G, .tenant = null, .want = 2 },
        .{ .graph = null, .tenant = null, .want = 3 },
        .{ .graph = null, .tenant = graph_store.DEFAULT_TENANT_ID, .want = 3 },
    };
    for (cases) |cs| {
        var k: usize = 0;
        while (k < 64) : (k += 1) {
            fault.arm(k);
            const result = edgesByType(&store, fault.allocator(), "R6646", cs.tenant, cs.graph);
            const induced = fault.disarm();
            if (result) |ids| {
                defer testing.allocator.free(ids);
                if (ids.len != cs.want) {
                    std.debug.print("SONNY-6646 (4): graph {?s}, allocation {d} failing: {d} edges, want {d}\n", .{ cs.graph, k, ids.len, cs.want });
                    wrong += 1;
                }
            } else |err| {
                try testing.expectEqual(error.OutOfMemory, err);
                errors += 1;
            }
            if (!induced) break;
        }
    }
    try testing.expect(errors > 0);
    try testing.expectEqual(@as(usize, 0), wrong);
}

test "SONNY-6646: addNodeLabelNoSave leaks nothing whichever allocation fails" {
    // The undo of a REMOVE n:L. It copied the label, then allocated the
    // node's new label array; when that failed the copy leaked
    // (std.testing.allocator reports the leak).
    var fault = OneShotFail{ .child = testing.allocator };
    var store = try graph_store.GraphStore.init(fault.allocator());
    defer store.deinit();
    var labels = [_][]const u8{"A6646n"};
    const id = try store.createNodeWithGraph(&labels, G);

    var failures: usize = 0;
    var k: usize = 0;
    while (k < 64) : (k += 1) {
        fault.arm(k);
        const result = store.addNodeLabelNoSave(id, "B6646n");
        const induced = fault.disarm();
        if (result) |_| {
            // Back to one label for the next attempt.
            try store.removeNodeLabel(id, "B6646n");
        } else |_| failures += 1;
        if (!induced) break;
    }
    try testing.expect(failures > 0);
}
