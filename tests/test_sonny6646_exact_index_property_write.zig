// SONNY-6646 (6): a node property write (setNodeProperty,
// setNodePropertiesBatch, a removal) moved the node's exact (label, key,
// value) index entries only after the engine write committed:
//
//   * the old value's entry was removed by a remover that `catch return`ed:
//     hashing a value whose encoding passes 64 bytes allocates, and so does
//     the index key of a property key past ~1 KiB. On a failure the node
//     stayed findable by a value it no longer held.
//   * the new value's entry was added with a `try`, after the commit: on a
//     failure the write was reported failed although it was committed, and
//     the node was not findable by the value it held.
//
// The hashes are computed before the engine write, the new entries are added
// before the commit (and taken back if the write then fails), and the old
// entries are removed after it, without allocating.
//
// A real store with a data directory. One allocation of the store or its
// storage adapter is failed (a one-shot fault), for each allocation a write of a property with a
// 1,100-byte key and a 200-byte value makes in turn, until a write needs
// none of them. After each, the index finds the node by the value it holds
// and by no other: the new value if the write succeeded, the old one if it
// failed.
//
// CANARY: REQ=REQ-SONNY-6646-EXACT-INDEX-PROPERTY-WRITE; FEATURE="StorageIntegrity"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6646_exact_index_property_write.zig; OWNER=storage; UPDATED=2026-11-15

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const G = "g6646x";
const L = "X6646";

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

const Write = enum { set, batch_set, batch_remove };

test "SONNY-6646 (6): a property write moves the node's exact-index entry to the value it holds, whichever allocation fails" {
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
    // The adapter allocates from `global_allocator()` (`smp_allocator`, the
    // fault's child); the graph opened below takes this one for its engine
    // and its exact index, so their allocations are faulted too.
    adapter.allocator = fault.allocator();
    try store.createGraph(G);

    const key = "k" ** 1100;
    var values: [2][200]u8 = undefined;
    @memset(&values[0], 'a');
    @memset(&values[1], 'b');
    const labels = [_][]const u8{L};
    const id = try store.createNodeWithGraph(&labels, G);
    // The value the node holds (null: none).
    var held: ?usize = 0;
    try store.setNodeProperty(id, key, .{ .String = &values[0] });

    var wrong: usize = 0;
    var failures: usize = 0;
    for ([_]Write{ .set, .batch_set, .batch_remove }) |what| {
        var k: usize = 0;
        while (k < 512) : (k += 1) {
            // The state the write starts from, written healthy: value 0.
            if (held == null or held.? != 0) {
                try store.setNodeProperty(id, key, .{ .String = &values[0] });
                held = 0;
            }
            const next: ?usize = switch (what) {
                .set, .batch_set => 1,
                .batch_remove => null,
            };
            fault.arm(k);
            const result = switch (what) {
                .set => store.setNodeProperty(id, key, .{ .String = &values[1] }),
                .batch_set => store.setNodePropertiesBatch(id, &.{.{ .key = key, .value = .{ .String = &values[1] } }}),
                .batch_remove => store.setNodePropertiesBatch(id, &.{.{ .key = key, .value = null }}),
            };
            const induced = fault.disarm();
            if (result) |_| held = next else |_| failures += 1;

            for (0..2) |v| {
                const n = try adapter.countCandidateNodesByLabelAndProperty(G, L, key, .{ .String = &values[v] });
                const want: usize = if (held != null and held.? == v) 1 else 0;
                if (n != want) {
                    wrong += 1;
                    std.debug.print("SONNY-6646 (6): {s}, allocation {d} failing, the write {s}: the index finds the node by value {d} {d} time(s), want {d}\n", .{ @tagName(what), k, if (result) |_| "succeeded" else |_| "failed", v, n, want });
                }
            }
            if (!induced) break;
        }
    }
    try testing.expect(failures > 0);
    try testing.expectEqual(@as(usize, 0), wrong);
}
