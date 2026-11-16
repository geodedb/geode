// SONNY-6601 (2): a bulk reserved-id node insert that fails leaves no entry
// in the graph's exact property index.
//
// `StorageAdapter.bulkInsertNodeWithReservedIdForTenant` (the QUIC bulk
// CREATE / MERGE fast path) adds each property to the exact (label, key,
// value) index as it writes it, before the engine transaction commits. A
// failure after that (the next property, the node record, the in-memory
// copy) aborts the transaction and gives the engine slot back, but the
// entries stayed: the index named a node that does not exist, under a slot
// the next insert reuses.
//
// A real store with a data directory. One allocation of the store (its
// in-memory copy of the node, made after the index entries) is failed (a
// one-shot fault), for each allocation the insert makes in turn, until an
// insert needs none of them. After a failed insert the posting of
// every property it carried must be empty; after the one that succeeds it
// holds exactly that node.
//
// CANARY: REQ=REQ-SONNY-6601-BULK-INSERT-INDEX-ABORT; FEATURE="StorageIntegrity"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6601_bulk_insert_index_abort.zig; OWNER=storage; UPDATED=2026-11-15

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const graph_storage_adapter = geode.graph_storage_adapter;
const PropKV = graph_storage_adapter.StorageAdapter.PropKV;
const G = "g6601";

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

test "SONNY-6601 (2): an aborted bulk reserved-id insert leaves no exact-index entry" {
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

    const labels = [_][]const u8{"B6601"};
    const props = [_]PropKV{
        .{ .key = "a", .value = .{ .String = "alpha-6601" } },
        .{ .key = "b", .value = .{ .String = "beta-6601" } },
        .{ .key = "c", .value = .{ .Int = 6601 } },
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
        for (props) |kv| {
            const n = try adapter.countCandidateNodesByLabelAndProperty(G, "B6601", kv.key, kv.value);
            if (n != want) {
                wrong += 1;
                std.debug.print("SONNY-6601 (2): store allocation {d} failing, the insert {s}: posting of {s} holds {d}, want {d}\n", .{ k, if (want == 1) "succeeded" else "failed", kv.key, n, want });
            }
        }
        if (!fault.induced or inserted != null) break;
    }
    try testing.expect(failures > 0);
    try testing.expect(inserted != null);
    try testing.expectEqual(@as(usize, 0), wrong);
}
