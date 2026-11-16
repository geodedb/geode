// SONNY-6601 (3): an auto-commit engine write that fails, and whose abort
// graph-storage cannot undo, quarantines its graph.
//
// The adapter's auto-commit writes (`mg.engine.addLabel`, `removeLabel`,
// `addEdge`, `removeEdge`, `removeEdgeProperty`: outside a statement
// transaction on the shard) leave the abort to graph-storage, which ends a
// failed write with `abortFailedWrite`. When that abort cannot undo the
// write (`abort_not_undone`, e.g. `journal_full`: the undo journal could not
// grow), the shard refuses every later write, commit and checkpoint, but the
// caller only gets the write's own error. geode returned it and kept serving
// the graph from memory beside a refused shard; the statement path
// quarantines it (58000 AbortNotUndone) until a restart.
//
// Real failures: the graph's engine allocates through a fault allocator
// that fails every allocation from the k-th on, for each k in turn, during
// one auto-commit write, until the write needs none of them. Whenever a
// shard of the graph is left refusing writes, the graph must be quarantined.
//
// CANARY: REQ=REQ-SONNY-6601-AUTOCOMMIT-ABORT-QUARANTINE; FEATURE="TransactionManagement"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6601_autocommit_abort_quarantine.zig; OWNER=storage; UPDATED=2026-11-15

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const G = "g6601ac";

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

/// Fails every allocation from number `fail_from` (counting from arming) on.
const FailFrom = struct {
    child: std.mem.Allocator,
    count: usize = 0,
    fail_from: ?usize = null,
    induced: bool = false,

    fn allocator(self: *FailFrom) std.mem.Allocator {
        return .{ .ptr = self, .vtable = &.{ .alloc = alloc, .resize = resize, .remap = remap, .free = free } };
    }

    fn arm(self: *FailFrom, k: usize) void {
        self.count = 0;
        self.fail_from = k;
        self.induced = false;
    }

    fn disarm(self: *FailFrom) bool {
        self.fail_from = null;
        return self.induced;
    }

    fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ret_addr: usize) ?[*]u8 {
        const self: *FailFrom = @ptrCast(@alignCast(ctx));
        if (self.fail_from) |k| {
            defer self.count += 1;
            if (self.count >= k) {
                self.induced = true;
                return null;
            }
        }
        return self.child.rawAlloc(len, alignment, ret_addr);
    }

    fn resize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) bool {
        const self: *FailFrom = @ptrCast(@alignCast(ctx));
        if (self.fail_from != null and new_len > memory.len) return false;
        return self.child.rawResize(memory, alignment, new_len, ret_addr);
    }

    fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ret_addr: usize) ?[*]u8 {
        const self: *FailFrom = @ptrCast(@alignCast(ctx));
        if (self.fail_from != null and new_len > memory.len) return null;
        return self.child.rawRemap(memory, alignment, new_len, ret_addr);
    }

    fn free(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ret_addr: usize) void {
        const self: *FailFrom = @ptrCast(@alignCast(ctx));
        self.child.rawFree(memory, alignment, ret_addr);
    }
};

const Write = enum { add_label, remove_label, add_edge };

test "SONNY-6601 (3): an auto-commit write whose abort graph-storage cannot undo quarantines the graph" {
    const allocator = testing.allocator;
    var poisoned_total: usize = 0;
    var unquarantined: usize = 0;

    for ([_]Write{ .add_label, .remove_label, .add_edge }) |what| {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        var tmp = std.testing.tmpDir(.{});
        defer tmp.cleanup();
        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        defer allocator.free(data_dir);
        graph_store.setDataDirOverride(allocator, data_dir);
        defer {
            graph_store.deinitGlobalStore();
            graph_store.setDataDirOverride(allocator, null);
        }
        const store = graph_store.getGlobalStore(allocator);
        const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
        // The adapter allocates from `global_allocator()` (`smp_allocator`,
        // the fault's child); the graph opened below takes this one for its
        // engine.
        var fault = FailFrom{ .child = std.heap.smp_allocator };
        const prev_allocator = adapter.allocator;
        adapter.allocator = fault.allocator();
        defer adapter.allocator = prev_allocator;
        try store.createGraph(G);
        const mg = adapter.engines.get(G) orelse return error.NoGraph;

        var labels = [_][]const u8{"A6601"};
        const a = try store.createNodeWithGraph(&labels, G);
        const b = try store.createNodeWithGraph(&labels, G);

        var k: usize = 0;
        while (k < 4096) : (k += 1) {
            // The state the write starts from, written healthy.
            if (what == .remove_label) store.addNodeLabel(a, "R6601") catch {};
            fault.arm(k);
            const result = switch (what) {
                .add_label => store.addNodeLabel(a, "R6601"),
                .remove_label => store.removeNodeLabel(a, "R6601"),
                .add_edge => if (store.createEdgeWithGraph(a, b, "E6601", G)) |_| {} else |err| err,
            };
            const induced = fault.disarm();

            var poisoned = false;
            for (mg.engine.shards) |shard| {
                if (shard.abort_not_undone != null) poisoned = true;
            }
            if (poisoned) {
                poisoned_total += 1;
                const q = mg.quarantine.load(.acquire);
                if (q == 0) {
                    unquarantined += 1;
                    std.debug.print("SONNY-6601 (3): {s}, allocations from {d} failing: the write {s}, a shard refuses writes (abort not undone), the graph is not quarantined\n", .{ @tagName(what), k, if (result) |_| "succeeded" else |_| "failed" });
                }
                break; // the shard refuses everything from here on
            }
            if (result) |_| {
                if (what == .add_label) store.removeNodeLabel(a, "R6601") catch {};
            } else |_| {}
            if (!induced) break;
        }
    }
    std.debug.print("SONNY-6601 (3): {d} write(s) left a shard refusing writes, {d} without a quarantine\n", .{ poisoned_total, unquarantined });
    try testing.expect(poisoned_total > 0);
    try testing.expectEqual(@as(usize, 0), unquarantined);
}
