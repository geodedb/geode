// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// FIX #1 regression: a server-side node scan MUST stop iterating and RELEASE
// its per-graph SHARED read lock when the driving client's stream/connection
// closes OR a query deadline passes — instead of running the whole O(N) scan to
// completion (the "96 lingering scans at 1074% CPU holding read locks" pathology
// observed at 14.27M scale under concurrent analytical reads + the edge phase).
//
// Mechanism under test: `NodeScanStream.buildNextPage` / `buildCountPage`
// iterate an immutable `slot_ids` snapshot under the per-graph SHARED read lock
// (chunked per batch). Without cancellation a lingering scan keeps materializing
// + re-acquiring the SHARED lock long after its client is gone, burning CPU and
// adding lock churn that the edge phase's exclusive acquirers contend with.
//
// Contract pinned here:
//   (a) CANCEL TOKEN: a scan whose `cancel_token` is set returns final=true on
//       the next page WITHOUT materializing the rest of the slot list (it stops
//       at the next batch boundary), and leaves NO read lock held (a subsequent
//       EXCLUSIVE acquire succeeds immediately).
//   (b) DEADLINE: a scan whose `deadline_mono_ns` is already in the past behaves
//       the same — stops, releases, final=true.
//   (c) A scan with NO cancel/deadline still returns the correct full result
//       (the cancellation hooks must not change normal scan semantics).
//
// Driven against the REAL streaming path on a fresh temp graph, exactly as the
// transport handler drives it (prepare → buildNextPage pages; no outer lock).
//
// CANARY: REQ=REQ-CONCURRENCY-SCAN-CANCELLATION; FEATURE="ScanCancellation"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_scan_cancellation.zig; OWNER=transport; UPDATED=2026-06-23

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const adapter_mod = geode.graph_storage_adapter;
const sharded_store = geode.sharded_store;
const node_scan_stream = geode.node_scan_stream;

const GRAPH = graph_store.DEFAULT_GRAPH_NAME;
const LABEL = "Probe";
const PROP = "someprop";
const FILLER = "other";
const TARGET = "target";
// Large enough that an uncancelled sparse scan materializes MANY nodes — so a
// cancelled scan that stops early materializes provably fewer.
const SEED_NODES: usize = 20_000;
const TARGET_COUNT: usize = 3;
const TARGET_SHARD: usize = 0;

fn reserveIdOnTargetShard(store: *graph_store.GraphStore) u64 {
    while (true) {
        const id = store.reserveNodeId();
        if (sharded_store.shardIndex(id) == TARGET_SHARD) return id;
    }
}

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

fn nowNs() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn parseQuery(arena: *std.heap.ArenaAllocator, src: []const u8) !*const geode.gql.ast.Query {
    var lx = geode.gql.lexer.Lexer{ .src = src };
    var p = geode.gql.parser.Parser{ .lx = &lx, .arena = arena, .cur = lx.next() };
    const program = try p.parseProgram();
    return &program.statements[0].Query;
}

fn seedGraph(adapter: *adapter_mod.StorageAdapter, store: *graph_store.GraphStore, n: usize) !void {
    const labels = [_][]const u8{LABEL};
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const reserved = reserveIdOnTargetShard(store);
        // Only the LAST TARGET_COUNT nodes carry the target value, so a sparse
        // WHERE scan must materialize the whole posting list to find them.
        const val: []const u8 = if (i >= n - TARGET_COUNT) TARGET else FILLER;
        const props = [_]adapter_mod.StorageAdapter.PropKV{
            .{ .key = PROP, .value = .{ .String = val } },
        };
        _ = try adapter.bulkInsertNodeWithReservedId(GRAPH, reserved, &labels, &props);
    }
}

const TestEnv = struct {
    allocator: std.mem.Allocator,
    data_dir: []u8,
    ctx: execution.ExecutionContext,
    adapter: *adapter_mod.StorageAdapter,
    store: *graph_store.GraphStore,

    fn setup(allocator: std.mem.Allocator, tmp_sub_path: []const u8) !TestEnv {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        const data_dir = try tmpDirRealpathAlloc(allocator, tmp_sub_path);
        graph_store.setDataDirOverride(allocator, data_dir);
        const store = graph_store.getGlobalStore(allocator);
        const catalog = try execution.ensureCatalogInstance(allocator);
        const ctx = execution.ExecutionContext{ .catalog = catalog };
        const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterUnavailable;
        _ = try adapter.getOrCreateGraph(GRAPH);
        return .{
            .allocator = allocator,
            .data_dir = data_dir,
            .ctx = ctx,
            .adapter = adapter,
            .store = store,
        };
    }

    fn teardown(self: *TestEnv) void {
        graph_store.deinitGlobalStore();
        execution.cleanupCatalogInstance();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
    }
};

// Confirm the per-graph EXCLUSIVE lock can be acquired promptly — i.e. the scan
// is NOT holding the SHARED read lock. Returns the acquire latency in ns.
fn timeExclusiveAcquire() u64 {
    const t0 = nowNs();
    const h = graph_store.acquireGraphWriteLockCancelable(GRAPH, nowNs() + 2 * std.time.ns_per_s) catch {
        return std.math.maxInt(u64);
    };
    const dt = nowNs() - t0;
    graph_store.releaseGraphLock(h);
    return dt;
}

test "scan stops + releases the read lock when the cancel token is set" {
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = try TestEnv.setup(allocator, &tmp.sub_path);
    defer env.teardown();

    try seedGraph(env.adapter, env.store, SEED_NODES);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const q = try parseQuery(&arena, "MATCH (n:Probe) WHERE n.someprop = 'target' RETURN n.someprop LIMIT 3");
    const prepared = (try node_scan_stream.prepare(aa, q, env.ctx, &.{}, &.{}, &.{})) orelse
        return error.NotStreamable;
    var stream = prepared;
    defer stream.deinit();

    // Simulate the client stream having closed: set the cancel token BEFORE the
    // first page. The scan must not chew through all 20k slots.
    var cancel = std.atomic.Value(bool).init(true);
    stream.cancel_token = &cancel;

    node_scan_stream.resetNodesMaterializedTotal();

    var page = try stream.buildNextPage(aa, TARGET_COUNT);
    defer page.result.deinit(aa);

    // The page must be FINAL (the stream is terminating because its client is
    // gone) so the handler tears the stream down instead of paging forever.
    try testing.expect(page.final);

    // It must NOT have materialized the whole posting list. With a batch size of
    // 512 a cancelled scan stops within ~one batch; assert well under the seed
    // count to prove it short-circuited rather than scanning to completion.
    const materialized = node_scan_stream.getNodesMaterializedTotal();
    if (materialized >= SEED_NODES) {
        std.debug.print(
            "SCAN-CANCEL REGRESSION: cancelled scan materialized {d} nodes " ++
                "(seed {d}) — it ran to completion instead of stopping at the " ++
                "next batch boundary. A lingering scan keeps burning CPU + read " ++
                "locks after its client disconnects.\n",
            .{ materialized, SEED_NODES },
        );
        return error.CancelledScanDidNotStop;
    }

    // And it must have RELEASED the SHARED read lock: a writer can acquire the
    // per-graph EXCLUSIVE lock immediately.
    const excl_ns = timeExclusiveAcquire();
    if (excl_ns == std.math.maxInt(u64)) {
        std.debug.print("SCAN-CANCEL REGRESSION: EXCLUSIVE acquire timed out — the cancelled scan left the SHARED read lock held.\n", .{});
        return error.CancelledScanLeftLockHeld;
    }
}

test "scan stops + releases the read lock when the deadline has passed" {
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = try TestEnv.setup(allocator, &tmp.sub_path);
    defer env.teardown();

    try seedGraph(env.adapter, env.store, SEED_NODES);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const q = try parseQuery(&arena, "MATCH (n:Probe) WHERE n.someprop = 'target' RETURN n.someprop LIMIT 3");
    const prepared = (try node_scan_stream.prepare(aa, q, env.ctx, &.{}, &.{}, &.{})) orelse
        return error.NotStreamable;
    var stream = prepared;
    defer stream.deinit();

    // Deadline already in the past → the scan must bail at the first batch.
    stream.deadline_mono_ns = nowNs() -| std.time.ns_per_s;

    node_scan_stream.resetNodesMaterializedTotal();
    var page = try stream.buildNextPage(aa, TARGET_COUNT);
    defer page.result.deinit(aa);

    try testing.expect(page.final);
    const materialized = node_scan_stream.getNodesMaterializedTotal();
    try testing.expect(materialized < SEED_NODES);

    const excl_ns = timeExclusiveAcquire();
    try testing.expect(excl_ns != std.math.maxInt(u64));
}

test "uncancelled scan still returns the correct full result" {
    const allocator = testing.allocator;
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var env = try TestEnv.setup(allocator, &tmp.sub_path);
    defer env.teardown();

    try seedGraph(env.adapter, env.store, SEED_NODES);

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const q = try parseQuery(&arena, "MATCH (n:Probe) WHERE n.someprop = 'target' RETURN n.someprop LIMIT 3");
    const prepared = (try node_scan_stream.prepare(aa, q, env.ctx, &.{}, &.{}, &.{})) orelse
        return error.NotStreamable;
    var stream = prepared;
    defer stream.deinit();
    // No cancel token, no deadline → normal semantics.

    var matched: usize = 0;
    while (stream.hasRemaining()) {
        var page = try stream.buildNextPage(aa, TARGET_COUNT);
        matched += page.result.rows.len;
        page.result.deinit(aa);
        if (page.final) break;
    }
    try testing.expectEqual(TARGET_COUNT, matched);
}
