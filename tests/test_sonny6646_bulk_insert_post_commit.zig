// SONNY-6646 (5): the bulk reserved-id node insert (the QUIC bulk CREATE /
// MERGE fast path) copied the node's properties into the in-memory store
// AFTER its engine transaction committed. A failure there returned an error
// for a node that was committed: the client was told the CREATE failed, the
// node was there (in the engine, and in memory without some of its
// properties), and a retry made a second one.
//
// The copy is made before the commit now; a failure in it takes the node
// back out of the in-memory store and aborts the engine transaction, so a
// failed insert leaves no node anywhere.
//
// A real store with a data directory. One store allocation is failed (a
// one-shot fault), for each allocation the insert makes in turn, until an
// insert needs none of them. After each: a failed insert left no node in
// memory or in the engine, and the one that succeeded left exactly one node,
// holding every property in memory.
//
// CANARY: REQ=REQ-SONNY-6646-BULK-INSERT-POST-COMMIT; FEATURE="StorageIntegrity"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6646_bulk_insert_post_commit.zig; OWNER=storage; UPDATED=2026-11-15

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const graph_storage_adapter = geode.graph_storage_adapter;
const PropKV = graph_storage_adapter.StorageAdapter.PropKV;
const G = "g6646";
const L = "B6646";

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

/// Fails allocation number `fail_at` (counting from arming) and no other.
const OneShotFail = struct {
    child: std.mem.Allocator,
    count: usize = 0,
    fail_at: ?usize = null,
    induced: bool = false,

    fn allocator(self: *OneShotFail) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
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

test "SONNY-6646 (5): a failed bulk reserved-id insert leaves no node, in memory or in the engine" {
    const allocator = testing.allocator;
    execution.cleanupCatalogInstance();
    graph_store.deinitGlobalStore();
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);
    var fault = OneShotFail{ .child = std.heap.smp_allocator };
    graph_store.setTestGlobalStoreAllocator(fault.allocator());
    graph_store.setDataDirOverride(allocator, data_dir);
    defer {
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, null);
        graph_store.setTestGlobalStoreAllocator(null);
    }
    const store = graph_store.getGlobalStore(allocator);
    const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
    _ = try adapter.getOrCreateGraph(G);

    const labels = [_][]const u8{L};
    const props = [_]PropKV{
        .{ .key = "a", .value = .{ .String = "alpha-6646" } },
        .{ .key = "b", .value = .{ .String = "beta-6646" } },
        .{ .key = "c", .value = .{ .Int = 6646 } },
    };

    var wrong: usize = 0;
    var failures: usize = 0;
    var inserted: ?u64 = null;
    var k: usize = 0;
    while (k < 256) : (k += 1) {
        const reserved = store.reserveNodeId();
        fault.count = 0;
        fault.fail_at = k;
        fault.induced = false;
        const result = adapter.bulkInsertNodeWithReservedIdForTenant(G, reserved, &labels, &props, graph_store.DEFAULT_TENANT_ID);
        fault.fail_at = null;

        const want: usize = if (result) |_| 1 else |_| 0;
        if (result) |id| inserted = id else |_| failures += 1;
        const in_memory: usize = if (store.getNodesByLabel(G, L)) |ids| ids.len else 0;
        const in_engine = try adapter.countNodesByLabel(G, L);
        const node_present = store.getNodePtr(reserved) != null;
        var props_held: usize = 0;
        if (store.getNodePtr(reserved)) |node| {
            for (props) |kv| {
                if (node.properties.get(kv.key) != null) props_held += 1;
            }
        }
        const ok = in_memory == want and in_engine == want and node_present == (want == 1) and
            (want == 0 or props_held == props.len);
        if (!ok) {
            wrong += 1;
            std.debug.print("SONNY-6646 (5): store allocation {d} failing, the insert {s}: {d} nodes in memory, {d} in the engine (want {d}); the node is in memory: {}, holding {d}/{d} properties\n", .{ k, if (result) |_| "succeeded" else |_| "failed", in_memory, in_engine, want, node_present, props_held, props.len });
        }
        if (!fault.induced or inserted != null) break;
    }
    try testing.expect(failures > 0);
    try testing.expect(inserted != null);
    try testing.expectEqual(@as(usize, 0), wrong);
}
