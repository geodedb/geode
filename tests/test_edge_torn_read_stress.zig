// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// PHASE 4 (edge-engine-direct): focused STRESS for the borrowed-slice torn-read
// SEGV fix. Many short rounds of {concurrent batched append to a hot source +
// repeated traverse} so an intermittent use-after-free / torn-count surfaces
// quickly (the headline throughput file runs the same scenario ONCE at K=5000;
// this runs it ROUNDS times at a smaller K to amortize per-round setup and hit
// the realloc/resize race window many times under the testing allocator).
//
// CANARY: REQ=REQ-CONCURRENCY-EDGE-TORN-READ; FEATURE="EdgeTornReadSafe"; ASPECT=Regression+Stress; STATUS=TESTED; TEST=tests/test_edge_torn_read_stress.zig; OWNER=storage; UPDATED=2026-06-24

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const graph_storage = @import("graph_storage");

const execution = geode.execution;
const graph_store = geode.graph_store;
const adapter_mod = geode.graph_storage_adapter;
const group_commit = geode.group_commit;

const GRAPH = graph_store.DEFAULT_GRAPH_NAME;
const LABEL = "Taxon";
const PARENT_OF = "PARENT_OF";

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;

const Env = struct {
    allocator: std.mem.Allocator,
    data_dir: []u8,
    adapter: *adapter_mod.StorageAdapter,
    store: *graph_store.GraphStore,

    fn setup(allocator: std.mem.Allocator, tmp_sub_path: []const u8) !Env {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        _ = setenv("GEODE_WAL_SYNC", "deferred", 1);
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
        var actual_len = cwd_len;
        while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
        const data_dir = try std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
        graph_store.setDataDirOverride(allocator, data_dir);
        const store = graph_store.getGlobalStore(allocator);
        _ = try execution.ensureCatalogInstance(allocator);
        const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterUnavailable;
        _ = try adapter.getOrCreateGraph(GRAPH);
        return .{ .allocator = allocator, .data_dir = data_dir, .adapter = adapter, .store = store };
    }

    fn teardown(self: *Env) void {
        group_commit.shutdownAllCoordinators();
        group_commit.setEnabledForTest(false);
        graph_store.deinitGlobalStore();
        execution.cleanupCatalogInstance();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
    }
};

fn makeNode(env: *Env, sid: []const u8) !u64 {
    const labels = [_][]const u8{LABEL};
    const props = [_]adapter_mod.StorageAdapter.PropKV{.{ .key = "source_id", .value = .{ .String = sid } }};
    const id = env.store.reserveNodeId();
    return env.adapter.bulkInsertNodeWithReservedId(GRAPH, id, &labels, &props);
}

fn outDegree(env: *Env, src: u64, rel: []const u8) usize {
    const outgoing = env.store.getOutgoingEdgeIds(src) orelse return 0;
    var n: usize = 0;
    for (outgoing) |eid| {
        const e = env.store.getEdgeHydrated(eid) orelse continue;
        if (!std.mem.eql(u8, e.graph_name, GRAPH)) continue;
        if (!std.mem.eql(u8, e.label, rel)) continue;
        n += 1;
    }
    return n;
}

const TornReadCtx = struct {
    env: *Env,
    src: u64,
    stop: *std.atomic.Value(bool),
    err: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn tornReader(ctx: *TornReadCtx) void {
    var last: usize = 0;
    while (!ctx.stop.load(.acquire)) {
        const h = graph_store.acquireGraphReadLockTagged(GRAPH, .misc);
        const n = outDegree(ctx.env, ctx.src, PARENT_OF);
        graph_store.releaseGraphLock(h);
        if (n < last) ctx.err.store(true, .release);
        last = n;
        std.atomic.spinLoopHint();
    }
}

test "PHASE4 torn-read STRESS: many rounds of concurrent append + traverse stay UAF/torn-free" {
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = try Env.setup(allocator, &tmp.sub_path);
    defer env.teardown();

    group_commit.setEnabledForTest(true);
    const coord = try group_commit.getOrStartCoordinator(env.allocator, env.adapter, GRAPH);

    const ROUNDS: usize = 12;
    const K: usize = 1_500;
    var round: usize = 0;
    while (round < ROUNDS) : (round += 1) {
        var name_buf: [32]u8 = undefined;
        const src = try makeNode(&env, std.fmt.bufPrint(&name_buf, "hot{d}", .{round}) catch unreachable);
        const children = try allocator.alloc(u64, K);
        defer allocator.free(children);
        for (children, 0..) |*c, i| {
            var buf: [32]u8 = undefined;
            c.* = try makeNode(&env, std.fmt.bufPrint(&buf, "tc{d}_{d}", .{ round, i }) catch unreachable);
        }

        var stop = std.atomic.Value(bool).init(false);
        var rctx = TornReadCtx{ .env = &env, .src = src, .stop = &stop };
        var readers: [4]std.Thread = undefined;
        for (&readers) |*t| t.* = try std.Thread.spawn(.{}, tornReader, .{&rctx});

        const ops = try allocator.alloc(group_commit.ApplyOp, K);
        defer allocator.free(ops);
        for (children, 0..) |child, i| {
            ops[i] = .{ .bulk_merge_edge = .{ .source_id = src, .target_id = child, .rel_type = PARENT_OF, .props = &.{}, .result = .{} } };
            try coord.submitNoWait(&ops[i]);
        }
        for (ops) |*op| _ = try coord.awaitOp(op);

        stop.store(true, .release);
        for (&readers) |t| t.join();

        try testing.expect(!rctx.err.load(.acquire));
        try testing.expectEqual(K, outDegree(&env, src, PARENT_OF));
    }
}

test {
    std.testing.refAllDecls(@This());
}
