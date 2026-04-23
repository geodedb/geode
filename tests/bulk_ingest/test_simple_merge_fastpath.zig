// Simple-MERGE fast-path parity + correctness tests.
//
// Extends the Task 11/12/16 bulk-ingest fast path with the msft-graph
// nodes_*.jsonl hot pattern:
//
//     MERGE (n:L {merge_key: v}) ON CREATE SET n.a = ..., n.b = ..., ...
//
// Exercised cases (all run directly against `bulkMergeNode` — the
// QUIC handler integration is covered by the msft-graph ingest workload):
//
//   1. MERGE hits an existing node — second call returns the same id and
//      does not duplicate the label-index posting entry.
//   2. MERGE creates when missing — first call inserts with label +
//      merge key + ON CREATE SET properties.
//   3. Parity — executor path and bulk path produce semantically identical
//      final GraphStore state.
//   4. Concurrent-MERGE race — 16 threads racing on the SAME merge id
//      result in exactly one node (label-index posting length == 1).

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const adapter_mod = geode.graph_storage_adapter;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const Harness = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    ctx: execution.ExecutionContext,

    pub fn init(allocator: std.mem.Allocator) !Harness {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);

        graph_store.setDataDirOverride(allocator, data_dir);
        _ = graph_store.getGlobalStore(allocator);

        const catalog = try execution.ensureCatalogInstance(allocator);
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .tmp = tmp,
            .data_dir = data_dir,
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    pub fn deinit(self: *Harness) void {
        self.arena.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    pub fn runQuery(self: *Harness, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        return try execution.executeProgramWithContext(self.allocator, &parsed.program, self.ctx);
    }
};

fn findNodeByProperty(
    store: *graph_store.GraphStore,
    key: []const u8,
    expected: []const u8,
) ?*graph_store.Node {
    var it = store.nodes.iterator();
    while (it.next()) |entry| {
        const node = entry.value_ptr;
        if (node.properties.get(key)) |pv| {
            switch (pv) {
                .String => |s| if (std.mem.eql(u8, s, expected)) return node,
                else => {},
            }
        }
    }
    return null;
}

fn labelPostingLen(store: *graph_store.GraphStore, graph_name: []const u8, label: []const u8) usize {
    var buf: [256]u8 = undefined;
    const key = std.fmt.bufPrint(&buf, "{s}:{s}", .{ graph_name, label }) catch return 0;
    const posting = store.label_index.getPtr(key) orelse return 0;
    posting.lock();
    defer posting.unlock();
    return posting.list.items.len;
}

// ----------------------------------------------------------------------
// 1. MERGE hits an existing node.
// ----------------------------------------------------------------------

test "bulkMergeNode returns existing id + does not duplicate posting" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;

    // First call: fresh insert.
    const first_id = try adapter.bulkMergeNode(
        "default",
        "User",
        "node_id",
        .{ .String = "alpha" },
        &.{
            .{ .key = "name", .value = .{ .String = "Alice" } },
        },
        null,
    );

    const store = graph_store.getGlobalStore(testing.allocator);
    try testing.expectEqual(@as(usize, 1), labelPostingLen(store, "default", "User"));

    // Second call with the same merge key: MUST return the same id and
    // must NOT grow the label-posting list.
    const second_id = try adapter.bulkMergeNode(
        "default",
        "User",
        "node_id",
        .{ .String = "alpha" },
        &.{
            // Even with new on-create props, a hit should be a no-op.
            .{ .key = "name", .value = .{ .String = "Bob" } },
        },
        null,
    );
    try testing.expectEqual(first_id, second_id);
    try testing.expectEqual(@as(usize, 1), labelPostingLen(store, "default", "User"));

    // On-match is a no-op: the name stays as it was on first insert.
    const node = store.nodes.getPtr(first_id) orelse return error.NodeMissing;
    const name_pv = node.properties.get("name") orelse return error.MissingName;
    try testing.expectEqualStrings("Alice", name_pv.String);
}

// ----------------------------------------------------------------------
// 2. MERGE creates missing node + writes ON CREATE SET props.
// ----------------------------------------------------------------------

test "bulkMergeNode inserts label + merge key + all ON CREATE props" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
    const node_id = try adapter.bulkMergeNode(
        "default",
        "User",
        "node_id",
        .{ .String = "beta" },
        &.{
            .{ .key = "name", .value = .{ .String = "Alice" } },
            .{ .key = "email", .value = .{ .String = "a@b.c" } },
            .{ .key = "age", .value = .{ .Int = 30 } },
        },
        null,
    );

    const store = graph_store.getGlobalStore(testing.allocator);
    const node = store.nodes.getPtr(node_id) orelse return error.NodeMissing;

    // Label exists.
    try testing.expectEqual(@as(usize, 1), node.labels.len);
    try testing.expectEqualStrings("User", node.labels[0]);

    // Merge key was written as a node property.
    const node_id_prop = node.properties.get("node_id") orelse return error.MissingNodeId;
    try testing.expectEqualStrings("beta", node_id_prop.String);

    // All ON CREATE SET values landed.
    const name_prop = node.properties.get("name") orelse return error.MissingName;
    try testing.expectEqualStrings("Alice", name_prop.String);
    const email_prop = node.properties.get("email") orelse return error.MissingEmail;
    try testing.expectEqualStrings("a@b.c", email_prop.String);
    const age_prop = node.properties.get("age") orelse return error.MissingAge;
    try testing.expectEqual(@as(i64, 30), age_prop.Int);

    // Store marked dirty.
    try testing.expect(store.isDirty());

    // Label posting has exactly one entry.
    try testing.expectEqual(@as(usize, 1), labelPostingLen(store, "default", "User"));
}

// ----------------------------------------------------------------------
// 3. Parity: executor path + bulk path produce semantically identical
//    final GraphStore state.
// ----------------------------------------------------------------------

test "bulkMergeNode parity with executor path" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // Path A: executor path.
    var r = try h.runQuery(
        "MERGE (n:User {node_id: 'exec-abc'}) ON CREATE SET n.name = 'Alice', n.age = 30",
    );
    r.deinit(testing.allocator);

    // Path B: bulk path.
    const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
    _ = try adapter.bulkMergeNode(
        "default",
        "User",
        "node_id",
        .{ .String = "bulk-xyz" },
        &.{
            .{ .key = "name", .value = .{ .String = "Alice" } },
            .{ .key = "age", .value = .{ .Int = 30 } },
        },
        null,
    );

    const store = graph_store.getGlobalStore(testing.allocator);
    const exec_node = findNodeByProperty(store, "node_id", "exec-abc") orelse
        return error.ExecutorNodeMissing;
    const bulk_node = findNodeByProperty(store, "node_id", "bulk-xyz") orelse
        return error.BulkNodeMissing;

    // Labels identical.
    try testing.expectEqual(@as(usize, 1), exec_node.labels.len);
    try testing.expectEqual(@as(usize, 1), bulk_node.labels.len);
    try testing.expectEqualStrings("User", exec_node.labels[0]);
    try testing.expectEqualStrings("User", bulk_node.labels[0]);

    // Properties identical.
    const exec_name = exec_node.properties.get("name") orelse return error.MissingExecName;
    const bulk_name = bulk_node.properties.get("name") orelse return error.MissingBulkName;
    try testing.expectEqualStrings(exec_name.String, bulk_name.String);

    const exec_age = exec_node.properties.get("age") orelse return error.MissingExecAge;
    const bulk_age = bulk_node.properties.get("age") orelse return error.MissingBulkAge;
    try testing.expectEqual(exec_age.Int, bulk_age.Int);

    // Both nodes are indexed under the "User" label.
    try testing.expectEqual(@as(usize, 2), labelPostingLen(store, "default", "User"));
}

// ----------------------------------------------------------------------
// 4. Concurrent MERGE race — 16 threads racing on the SAME id yield
//    exactly one node.
// ----------------------------------------------------------------------

const race_thread_count: usize = 16;

const RaceWorkerCtx = struct {
    adapter: *adapter_mod.StorageAdapter,
    ids: [race_thread_count]u64 = [_]u64{0} ** race_thread_count,
    tid: usize = 0,
    errored: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    barrier: *std.atomic.Value(u32),
    ready_count: *std.atomic.Value(u32),
};

fn concurrentMergeWorker(ctx: *RaceWorkerCtx) void {
    // Signal ready, then busy-wait for the go signal so all 16 threads
    // enter `bulkMergeNode` within a narrow window.
    _ = ctx.ready_count.fetchAdd(1, .acq_rel);
    while (ctx.barrier.load(.acquire) == 0) std.Thread.yield() catch {};

    // Take the per-graph write lock for the insert phase: this mirrors
    // what the QUIC handler does for the MERGE fast path (Phase 2 of
    // the two-phase split).  Under the write lock the lookupMergeCandidate
    // probe + insert is atomic from the caller's perspective, so the
    // 15 losing threads see the winning insert on their re-probe.
    const deadline = monoNanosNow() + 30 * std.time.ns_per_s;
    const handle = graph_store.acquireGraphWriteLockCancelable("default", deadline) catch {
        _ = ctx.errored.fetchAdd(1, .monotonic);
        return;
    };
    defer graph_store.releaseGraphLock(handle);

    const id = ctx.adapter.bulkMergeNode(
        "default",
        "U",
        "id",
        .{ .String = "X" },
        &.{},
        null,
    ) catch {
        _ = ctx.errored.fetchAdd(1, .monotonic);
        return;
    };
    ctx.ids[ctx.tid] = id;
}

fn monoNanosNow() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(std.os.linux.CLOCK.MONOTONIC, &ts);
    const sec = @as(u64, @intCast(ts.sec));
    const nsec = @as(u64, @intCast(ts.nsec));
    return sec * std.time.ns_per_s + nsec;
}

test "concurrent MERGE on same key inserts exactly one node" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
    const store = graph_store.getGlobalStore(testing.allocator);

    var ctxs: [race_thread_count]RaceWorkerCtx = undefined;
    var barrier = std.atomic.Value(u32).init(0);
    var ready_count = std.atomic.Value(u32).init(0);

    for (&ctxs, 0..) |*c, i| {
        c.* = .{
            .adapter = adapter,
            .tid = i,
            .barrier = &barrier,
            .ready_count = &ready_count,
        };
    }

    var threads: [race_thread_count]std.Thread = undefined;
    for (&threads, 0..) |*t, i| {
        t.* = try std.Thread.spawn(.{}, concurrentMergeWorker, .{&ctxs[i]});
    }

    // Wait for all threads to reach the barrier, then release them.
    while (ready_count.load(.acquire) < race_thread_count) std.Thread.yield() catch {};
    barrier.store(1, .release);

    for (threads) |t| t.join();

    // Invariants:
    //   * No thread errored (every call completed cleanly).
    //   * Exactly one posting-list entry under (default, U).
    //   * All 16 returned ids are identical.
    var error_total: u32 = 0;
    for (ctxs) |c| error_total += c.errored.load(.monotonic);
    try testing.expectEqual(@as(u32, 0), error_total);

    try testing.expectEqual(@as(usize, 1), labelPostingLen(store, "default", "U"));

    const first_id = ctxs[0].ids[0];
    try testing.expect(first_id != 0);
    for (ctxs) |c| {
        try testing.expectEqual(first_id, c.ids[c.tid]);
    }

    // The single inserted node is the one we resolve via the merge index.
    var verify_id: u64 = undefined;
    const res = store.lookupMergeCandidate(
        "default",
        "U",
        "id",
        .{ .String = "X" },
        &verify_id,
    );
    try testing.expect(res == .found);
    try testing.expectEqual(first_id, verify_id);
}
