// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// CANARY: REQ=REQ-ENG-3914-MERGE-CROSS-PATH-RACE; FEATURE="MergeIdempotency"; ASPECT=CrossPathConcurrency; STATUS=TESTED; TEST=tests/test_eng3914_cross_path_merge_race.zig:1; OWNER=storage; UPDATED=2026-08-29
//
// ENG-3914 RC-2 — cross-session MERGE duplication.
//
// RC-1 (the DETERMINISTIC single-threaded duplication) is covered by
// `tests/test_eng3914_merge_idempotency.zig` and was fixed in e53a4519.
// What remains OPEN is a genuine data race between geode's TWO MERGE
// implementations, which use DISJOINT mutual-exclusion schemes:
//
//   bulk path   `StorageAdapter.bulkMergeNodeWithReservedIdMultiPropForTenant`
//               (src/storage/graph_storage_adapter.zig:4427)
//               - serializes same-key writers on the striped
//                 `mg.merge_tuple_locks` table (:4466-4479)
//               - probes under `mg.rwlock` SHARED (:4481-4530) and then
//                 RELEASES it before delegating the insert to
//                 `bulkInsertNodeWithReservedIdForTenant` (:4556), which
//                 re-acquires SHARED on its own (:3562).
//
//   general     `execution.crud_operations.executeMerge`
//   path        (src/execution/crud_operations.zig:3545)
//               - probes via `findFirstMatchingNodeId` (:221)
//               - takes NO tuple lock at all; its mutual exclusion is the
//                 whole-graph `mg.rwlock` EXCLUSIVE that the connection
//                 handler wraps around the statement
//                 (src/server/quic_connection_handler.zig:6977,
//                 `graph_store.acquireGraphWriteLockCancelable`).
//
// bulk-vs-bulk is safe (both take the tuple lock). general-vs-general is
// safe (both take the graph EXCLUSIVE). But bulk-vs-general share NOTHING:
// the bulk writer drops `mg.rwlock` between its probe and its insert, and
// the general writer needs exactly that gap to acquire the EXCLUSIVE. So:
//
//   bulk    : tuple-lock, rwlock SHARED, probe(K) -> MISS, drop rwlock ....
//   general :                                   .... rwlock EXCLUSIVE,
//                                                    probe(K) -> MISS,
//                                                    CREATE(K), drop rwlock
//   bulk    : .................................. INSERT(K)
//
// -> two nodes for one merge key, from two concurrent sessions.
//
// Every test below drives the REAL production entry points: the bulk path
// through `StorageAdapter.bulkMergeNodeWithReservedIdMultiProp`, and the
// general path through `execution.executeStatementWithContext` wrapped in
// the same `graph_store.acquireGraphWriteLockCancelable` /
// `graph_store.releaseGraphLock` pair the QUIC connection handler uses for
// a mutation. No mocks, no simulated store.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const adapter_mod = geode.graph_storage_adapter;

const PropKV = adapter_mod.StorageAdapter.PropKV;

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

fn nowNs() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    }
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

/// The merge key space every concurrent test hammers.
///
/// SIZING RATIONALE (this is what makes the test reliable rather than
/// 1-in-3 flaky): the duplication window for a given merge key exists ONLY
/// while that key is still absent. Once ANY writer has created it, every
/// subsequent MERGE — bulk or general — probes and HITS, and the race is
/// unreachable for that key forever. So iterating the same key N times buys
/// nothing; each DISTINCT key is worth exactly one race opportunity.
///
/// Every worker therefore marches through the SAME `key_count` keys in the
/// SAME order, so all 8 writers converge on each key's first-creation window
/// together, and the run gets `key_count` independent chances to duplicate.
/// (`test_gap0894_single_prop_merge_striping.zig` gives each worker a
/// DISJOINT key range, which is why it cannot expose this defect at all.)
const Key = struct { doc_id: i64, seq: i64 };

const key_count: usize = 256;

/// 32 distinct `docId`s × 8 `seq`s. The shared `docId` is deliberate: it is
/// also the ENG-3914 RC-1 shape (multi-property merge key whose FIRST
/// property is shared across rows), so the composite probe is exercised, not
/// just a trivially discriminating first property.
fn keyAt(i: usize) Key {
    return .{ .doc_id = @intCast(i / 8), .seq = @intCast(i % 8) };
}

const graph_name = "eng3914_xpath";
const label = "XDoc";

/// Cap the per-key duplicate spew so a badly-raced run stays readable.
const max_reported_duplicates: usize = 8;

/// Sense-reversing barrier used to REALIGN every writer on each key.
///
/// Without it the workers drift apart within a few keys (a general-path
/// writer holding the whole-graph EXCLUSIVE advances far slower than a bulk
/// writer holding only a stripe), and once writer A is at key 200 while
/// writer B is at key 5 they never share a first-creation window again — the
/// race becomes unobservable even though the defect is fully present. The
/// barrier keeps all `n` writers converging on the SAME key at the SAME
/// time, which is exactly the production shape being reproduced: several
/// live sessions MERGE-ing overlapping id ranges at once.
///
/// `abort` lets a worker that hit an unexpected error stop doing work while
/// STILL participating in every remaining barrier, so a failure can never
/// deadlock the other workers.
const Barrier = struct {
    n: u32,
    count: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    generation: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
    abort: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),

    fn wait(self: *Barrier) void {
        const gen = self.generation.load(.acquire);
        if (self.count.fetchAdd(1, .acq_rel) + 1 == self.n) {
            self.count.store(0, .release);
            _ = self.generation.fetchAdd(1, .acq_rel);
            return;
        }
        var spins: usize = 0;
        const deadline = nowNs() + 120 * std.time.ns_per_s;
        while (self.generation.load(.acquire) == gen) {
            spins += 1;
            if (spins >= 4096) {
                spins = 0;
                std.Thread.yield() catch {};
                if (nowNs() > deadline) {
                    // Safety valve: never wedge the test binary.
                    self.abort.store(1, .release);
                    return;
                }
            } else {
                std.atomic.spinLoopHint();
            }
        }
    }

    fn aborted(self: *Barrier) bool {
        return self.abort.load(.acquire) != 0;
    }
};

/// Global-singleton harness: global store + global StorageAdapter + catalog,
/// all rooted at a throwaway data dir. Mirrors `Harness` in
/// `tests/test_eng3914_merge_idempotency.zig`; the difference is that this
/// one also hands out the SAME global adapter to the bulk path, which is
/// what makes the two MERGE implementations collide on one graph.
const Harness = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    session: execution.SessionState,
    ctx: execution.ExecutionContext,
    catalog: @TypeOf(@as(execution.ExecutionContext, undefined).catalog),
    adapter: *adapter_mod.StorageAdapter,

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
        const adapter = graph_store.getGlobalAdapter() orelse return error.NoGlobalAdapter;

        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .tmp = tmp,
            .data_dir = data_dir,
            .session = execution.SessionState.init(allocator),
            .ctx = execution.ExecutionContext{ .catalog = catalog },
            .catalog = catalog,
            .adapter = adapter,
        };
    }

    pub fn deinit(self: *Harness) void {
        self.session.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.arena.deinit();
        self.tmp.cleanup();
    }

    pub fn exec(self: *Harness, query: []const u8) !execution.ExecutionResult {
        self.ctx.session_state = &self.session;
        const aa = self.arena.allocator();
        var parsed = try geode.parseGqlOptions(query, aa, .{});
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    pub fn countRows(self: *Harness, query: []const u8) !usize {
        const res = try self.exec(query);
        return res.rows.len;
    }

    pub fn setUpGraph(self: *Harness) !void {
        _ = try self.exec("CREATE GRAPH " ++ graph_name);
        _ = try self.exec("USE GRAPH " ++ graph_name);
        _ = try self.adapter.getOrCreateGraph(graph_name);
    }

    /// One row per distinct merge key, and the total must equal the number
    /// of distinct keys that were MERGEd. Both assertions are needed: the
    /// total alone can hide a duplicate that a per-key `LIMIT`-less MATCH
    /// would surface, and the per-key check alone cannot see stray rows.
    pub fn assertOneNodePerKey(self: *Harness, keys: []const Key) !void {
        var failures: usize = 0;
        for (keys) |k| {
            const q = try std.fmt.allocPrint(
                self.arena.allocator(),
                "MATCH (n:" ++ label ++ " {{docId: {d}, seq: {d}}}) RETURN n",
                .{ k.doc_id, k.seq },
            );
            const n = try self.countRows(q);
            if (n != 1) {
                if (failures < max_reported_duplicates) {
                    std.debug.print(
                        "  DUPLICATE merge key {{docId: {d}, seq: {d}}} -> {d} nodes (expected 1)\n",
                        .{ k.doc_id, k.seq, n },
                    );
                }
                failures += 1;
            }
        }
        const total = try self.countRows("MATCH (n:" ++ label ++ ") RETURN n");
        if (failures != 0 or total != keys.len) {
            std.debug.print(
                "  {d}/{d} merge keys duplicated; TOTAL :{s} nodes = {d} (expected {d} — one per distinct merge key)\n",
                .{ failures, keys.len, label, total, keys.len },
            );
        }
        if (failures != 0) return error.MergeKeyDuplicated;
        try testing.expectEqual(keys.len, total);
    }
};

// ---------------------------------------------------------------------------
// production-faithful single-statement drivers
// ---------------------------------------------------------------------------

/// Bulk MERGE path, exactly as the QUIC bulk-MERGE fast path calls it.
fn bulkMerge(adapter: *adapter_mod.StorageAdapter, k: Key) !u64 {
    const merge_props = [_]PropKV{
        .{ .key = "docId", .value = .{ .Int = k.doc_id } },
        .{ .key = "seq", .value = .{ .Int = k.seq } },
    };
    const on_create = [_]PropKV{
        .{ .key = "origin", .value = .{ .String = "bulk" } },
    };
    const store = graph_store.getGlobalStore(graph_store.global_allocator());
    const res = try adapter.bulkMergeNodeWithReservedIdMultiProp(
        graph_name,
        store.reserveNodeId(),
        label,
        &merge_props,
        &on_create,
        false, // ON CREATE SET semantics — no on-match apply
    );
    return res.id;
}

/// General MERGE path, executed under the SAME whole-graph EXCLUSIVE write
/// lock the QUIC connection handler takes for a mutation
/// (src/server/quic_connection_handler.zig:6977). This is the production
/// mutual-exclusion contract for `executeMerge`, reproduced verbatim.
fn generalMerge(
    ctx: *execution.ExecutionContext,
    session: *execution.SessionState,
    arena: *std.heap.ArenaAllocator,
    k: Key,
) !void {
    const aa = arena.allocator();
    const q = try std.fmt.allocPrint(
        aa,
        "MERGE (n:" ++ label ++ " {{docId: {d}, seq: {d}}}) ON CREATE SET n.origin = 'general'",
        .{ k.doc_id, k.seq },
    );
    var parsed = try geode.parseGqlOptions(q, aa, .{});
    defer parsed.deinit();

    ctx.session_state = session;

    const deadline = nowNs() + 60 * std.time.ns_per_s;
    const handle = try graph_store.acquireGraphWriteLockCancelable(graph_name, deadline);
    defer graph_store.releaseGraphLock(handle);

    _ = try execution.executeStatementWithContext(aa, parsed.program.statements[0], ctx.*);
}

// ---------------------------------------------------------------------------
// T0 — control: the two paths must AGREE about what a merge key resolves to
// ---------------------------------------------------------------------------

test "ENG-3914 T0 control: bulk and general MERGE probes resolve the SAME node (sequential)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.setUpGraph();

    // bulk creates, general must MATCH it (not create a second one).
    const k1 = Key{ .doc_id = 1, .seq = 1 };
    const bulk_id = try bulkMerge(h.adapter, k1);
    try testing.expect(bulk_id != 0);
    try generalMerge(&h.ctx, &h.session, &h.arena, k1);

    // general creates, bulk must MATCH it (and return the same node id).
    const k2 = Key{ .doc_id = 2, .seq = 2 };
    try generalMerge(&h.ctx, &h.session, &h.arena, k2);
    const bulk_id2 = try bulkMerge(h.adapter, k2);
    const general_rows = try h.countRows(
        "MATCH (n:" ++ label ++ " {docId: 2, seq: 2}) RETURN n",
    );
    try testing.expectEqual(@as(usize, 1), general_rows);
    try testing.expect(bulk_id2 != 0);

    try h.assertOneNodePerKey(&[_]Key{ k1, k2 });
}

// ---------------------------------------------------------------------------
// T1 — regression guard: bulk-vs-bulk on the SAME key
// ---------------------------------------------------------------------------

const BulkOnlyCtx = struct {
    adapter: *adapter_mod.StorageAdapter,
    barrier: *Barrier,
    err: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

fn bulkOnlyWorker(ctx: *BulkOnlyCtx) void {
    var i: usize = 0;
    while (i < key_count) : (i += 1) {
        ctx.barrier.wait();
        if (ctx.barrier.aborted()) continue;
        _ = bulkMerge(ctx.adapter, keyAt(i)) catch {
            ctx.err.store(1, .release);
            ctx.barrier.abort.store(1, .release);
            continue;
        };
    }
}

test "ENG-3914 T1: concurrent SAME-KEY bulk MERGE yields exactly one node per key" {
    // Regression guard for the striped `merge_tuple_locks` path
    // (graph_storage_adapter.zig:4466). GAP-0894's suite gives every worker a
    // DISJOINT key range, so it never proves the tuple lock actually
    // serializes a CONTENDED key. This one does: all 8 workers march through
    // the SAME 256 keys in the SAME order, colliding on each key's
    // first-creation window.
    //
    // Expected to PASS both before and after the RC-2 fix — bulk-vs-bulk is
    // already covered by the tuple lock. It is here so a fix that replaces or
    // weakens the striping cannot regress the case it does handle.
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.setUpGraph();

    const workers = 8;

    var barrier = Barrier{ .n = workers };
    var ctxs: [workers]BulkOnlyCtx = undefined;
    var threads: [workers]std.Thread = undefined;
    for (0..workers) |i| {
        ctxs[i] = .{ .adapter = h.adapter, .barrier = &barrier };
    }
    for (0..workers) |i| {
        threads[i] = try std.Thread.spawn(.{}, bulkOnlyWorker, .{&ctxs[i]});
    }
    for (threads) |t| t.join();

    for (ctxs, 0..) |c, i| {
        if (c.err.load(.acquire) != 0) {
            std.debug.print("bulk worker {d} reported an error\n", .{i});
            return error.WorkerError;
        }
    }

    // The striping must have actually engaged — otherwise this test would be
    // green for the wrong reason (e.g. an accidental global exclusive).
    const mg = try h.adapter.getOrCreateGraph(graph_name);
    try testing.expect(mg.merge_tuple_lock_acquired_total.load(.monotonic) > 0);

    var expected: [key_count]Key = undefined;
    for (0..key_count) |i| expected[i] = keyAt(i);
    try h.assertOneNodePerKey(&expected);
}

// ---------------------------------------------------------------------------
// T2 — THE RED TEST: bulk path vs general path on the SAME key
// ---------------------------------------------------------------------------

const CrossPathCtx = struct {
    adapter: *adapter_mod.StorageAdapter,
    catalog: @TypeOf(@as(execution.ExecutionContext, undefined).catalog),
    allocator: std.mem.Allocator,
    use_general_path: bool,
    barrier: *Barrier,
    err: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

/// Pin a worker's session to the target graph through the real `USE GRAPH`
/// statement, the same way a client session does.
fn useGraph(
    exec_ctx: execution.ExecutionContext,
    arena: *std.heap.ArenaAllocator,
) !void {
    const aa = arena.allocator();
    var parsed = try geode.parseGqlOptions("USE GRAPH " ++ graph_name, aa, .{});
    defer parsed.deinit();
    _ = try execution.executeStatementWithContext(aa, parsed.program.statements[0], exec_ctx);
}

fn crossPathWorker(ctx: *CrossPathCtx) void {
    // Each simulated session owns its own SessionState + arena, exactly like
    // a distinct QUIC connection. The catalog and the global store/adapter
    // are shared process-wide, as in the server.
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    var session = execution.SessionState.init(ctx.allocator);
    defer session.deinit();
    var exec_ctx = execution.ExecutionContext{ .catalog = ctx.catalog };
    exec_ctx.session_state = &session;

    if (ctx.use_general_path) {
        useGraph(exec_ctx, &arena) catch {
            ctx.err.store(1, .release);
            ctx.barrier.abort.store(1, .release);
        };
    }

    // The barrier realigns every worker on each key, so all 8 sessions enter
    // the SAME key's first-creation window together. A worker that already
    // failed still participates (doing no work) so nobody deadlocks.
    var i: usize = 0;
    while (i < key_count) : (i += 1) {
        ctx.barrier.wait();
        if (ctx.barrier.aborted()) continue;
        const k = keyAt(i);
        if (ctx.use_general_path) {
            generalMerge(&exec_ctx, &session, &arena, k) catch {
                ctx.err.store(1, .release);
                ctx.barrier.abort.store(1, .release);
                continue;
            };
        } else {
            _ = bulkMerge(ctx.adapter, k) catch {
                ctx.err.store(1, .release);
                ctx.barrier.abort.store(1, .release);
                continue;
            };
        }
    }
}

test "ENG-3914 T2 regression: cross-path bulk/general MERGE of the SAME key must not duplicate" {
    // THE ENG-3914 RC-2 REPRODUCER.
    //
    // The bulk MERGE writer drops `mg.rwlock` SHARED between its probe
    // (graph_storage_adapter.zig:4481-4530) and its insert (:4556), and holds
    // only the striped tuple lock across that gap. The general MERGE writer
    // (crud_operations.zig:3545) never touches that tuple lock — it relies
    // solely on the whole-graph EXCLUSIVE `mg.rwlock` the connection handler
    // takes (quic_connection_handler.zig:6977). Nothing is shared between the
    // two, so a general-path CREATE can land entirely inside the bulk-path
    // probe→insert gap and both writers mint a node for one merge key.
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.setUpGraph();

    const bulk_workers = 6;
    const general_workers = 6;
    const workers = bulk_workers + general_workers;

    var barrier = Barrier{ .n = workers };
    var ctxs: [workers]CrossPathCtx = undefined;
    var threads: [workers]std.Thread = undefined;

    for (0..workers) |i| {
        ctxs[i] = .{
            .adapter = h.adapter,
            .catalog = h.catalog,
            .allocator = testing.allocator,
            .use_general_path = i >= bulk_workers,
            .barrier = &barrier,
        };
    }
    for (0..workers) |i| {
        threads[i] = try std.Thread.spawn(.{}, crossPathWorker, .{&ctxs[i]});
    }

    for (threads) |t| t.join();

    for (ctxs, 0..) |c, i| {
        if (c.err.load(.acquire) != 0) {
            std.debug.print(
                "cross-path worker {d} ({s}) reported an error\n",
                .{ i, if (c.use_general_path) "general" else "bulk" },
            );
            return error.WorkerError;
        }
    }

    // ONE node per distinct merge key. Anything else is the cross-path race.
    var expected: [key_count]Key = undefined;
    for (0..key_count) |i| expected[i] = keyAt(i);
    try h.assertOneNodePerKey(&expected);
}

// ---------------------------------------------------------------------------
// T2b — single-property variant of the same cross-path race
// ---------------------------------------------------------------------------

/// Same sizing rationale as `key_count`: one race opportunity per DISTINCT
/// key. Offset away from the multi-prop key space purely for readability.
const single_key_count: usize = 256;

fn singleKeyAt(i: usize) i64 {
    return @intCast(10_000 + i);
}

const SingleCtx = struct {
    adapter: *adapter_mod.StorageAdapter,
    catalog: @TypeOf(@as(execution.ExecutionContext, undefined).catalog),
    allocator: std.mem.Allocator,
    use_general_path: bool,
    barrier: *Barrier,
    err: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

fn singleBulkMerge(adapter: *adapter_mod.StorageAdapter, doc_id: i64) !u64 {
    const on_create = [_]PropKV{.{ .key = "origin", .value = .{ .String = "bulk" } }};
    const store = graph_store.getGlobalStore(graph_store.global_allocator());
    const res = try adapter.bulkMergeNodeWithReservedId(
        graph_name,
        store.reserveNodeId(),
        label,
        "docId",
        .{ .Int = doc_id },
        &on_create,
        false,
    );
    return res.id;
}

fn singleGeneralMerge(
    ctx: *execution.ExecutionContext,
    session: *execution.SessionState,
    arena: *std.heap.ArenaAllocator,
    doc_id: i64,
) !void {
    const aa = arena.allocator();
    const q = try std.fmt.allocPrint(
        aa,
        "MERGE (n:" ++ label ++ " {{docId: {d}}}) ON CREATE SET n.origin = 'general'",
        .{doc_id},
    );
    var parsed = try geode.parseGqlOptions(q, aa, .{});
    defer parsed.deinit();
    ctx.session_state = session;

    const deadline = nowNs() + 60 * std.time.ns_per_s;
    const handle = try graph_store.acquireGraphWriteLockCancelable(graph_name, deadline);
    defer graph_store.releaseGraphLock(handle);

    _ = try execution.executeStatementWithContext(aa, parsed.program.statements[0], ctx.*);
}

fn singleCrossPathWorker(ctx: *SingleCtx) void {
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    var session = execution.SessionState.init(ctx.allocator);
    defer session.deinit();
    var exec_ctx = execution.ExecutionContext{ .catalog = ctx.catalog };
    exec_ctx.session_state = &session;

    if (ctx.use_general_path) {
        useGraph(exec_ctx, &arena) catch {
            ctx.err.store(1, .release);
            ctx.barrier.abort.store(1, .release);
        };
    }

    var i: usize = 0;
    while (i < single_key_count) : (i += 1) {
        ctx.barrier.wait();
        if (ctx.barrier.aborted()) continue;
        const doc_id = singleKeyAt(i);
        if (ctx.use_general_path) {
            singleGeneralMerge(&exec_ctx, &session, &arena, doc_id) catch {
                ctx.err.store(1, .release);
                ctx.barrier.abort.store(1, .release);
                continue;
            };
        } else {
            _ = singleBulkMerge(ctx.adapter, doc_id) catch {
                ctx.err.store(1, .release);
                ctx.barrier.abort.store(1, .release);
                continue;
            };
        }
    }
}

test "ENG-3914 T2b regression: cross-path SINGLE-property MERGE of the SAME key must not duplicate" {
    // Same race, single-property merge key — the GAP-0894 striping path
    // (graph_storage_adapter.zig:4269, probe :4321-4362, insert :4380).
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try h.setUpGraph();

    const bulk_workers = 6;
    const general_workers = 6;
    const workers = bulk_workers + general_workers;

    var barrier = Barrier{ .n = workers };
    var ctxs: [workers]SingleCtx = undefined;
    var threads: [workers]std.Thread = undefined;

    for (0..workers) |i| {
        ctxs[i] = .{
            .adapter = h.adapter,
            .catalog = h.catalog,
            .allocator = testing.allocator,
            .use_general_path = i >= bulk_workers,
            .barrier = &barrier,
        };
    }
    for (0..workers) |i| {
        threads[i] = try std.Thread.spawn(.{}, singleCrossPathWorker, .{&ctxs[i]});
    }

    for (threads) |t| t.join();

    for (ctxs, 0..) |c, i| {
        if (c.err.load(.acquire) != 0) {
            std.debug.print(
                "single-prop cross-path worker {d} ({s}) reported an error\n",
                .{ i, if (c.use_general_path) "general" else "bulk" },
            );
            return error.WorkerError;
        }
    }

    var failures: usize = 0;
    for (0..single_key_count) |i| {
        const doc_id = singleKeyAt(i);
        const q = try std.fmt.allocPrint(
            h.arena.allocator(),
            "MATCH (n:" ++ label ++ " {{docId: {d}}}) RETURN n",
            .{doc_id},
        );
        const n = try h.countRows(q);
        if (n != 1) {
            if (failures < max_reported_duplicates) {
                std.debug.print(
                    "  DUPLICATE merge key {{docId: {d}}} -> {d} nodes (expected 1)\n",
                    .{ doc_id, n },
                );
            }
            failures += 1;
        }
    }
    const total = try h.countRows("MATCH (n:" ++ label ++ ") RETURN n");
    if (failures != 0 or total != single_key_count) {
        std.debug.print(
            "  {d}/{d} merge keys duplicated; TOTAL :{s} nodes = {d} (expected {d})\n",
            .{ failures, single_key_count, label, total, single_key_count },
        );
    }
    if (failures != 0) return error.MergeKeyDuplicated;
    try testing.expectEqual(single_key_count, total);
}

// ---------------------------------------------------------------------------
// T3 (RC-3, group-commit late apply) — DELIBERATELY NOT IMPLEMENTED HERE
// ---------------------------------------------------------------------------
//
// RC-3 is real: `ShardedCoordinator.awaitOp`
// (src/storage/group_commit.zig:617; wait loop :622-624) parks on
// `std.Io.futexWaitUncancelable` with NO deadline and no cancellation, and
// `submit` (:634) is just `submitNoWait` + `awaitOp`. An op that has been
// enqueued WILL be applied, whatever the submitter does afterwards.
//
// It is not reproducible as a unit test in this file, for three specific
// reasons — recorded here so nobody re-litigates it:
//
//   1. There is no abandonment path BELOW the transport. `awaitOp` has no
//      early return at all, so a caller inside this process cannot abandon
//      an in-flight op the way production does. The abandonment in the bug
//      report happens one layer up, when the QUIC handler's per-request
//      deadline fires and the CLIENT retries on a new connection. Faking it
//      here by calling `submitNoWait` and simply not awaiting would be
//      testing a sequence no production code path can execute.
//
//   2. A late-applied MERGE op self-heals, so "late apply" alone is not
//      observable as duplication. Both merge variants
//      (`bulk_merge_node` / `bulk_merge_node_props`, :233 / :250) probe at
//      APPLY time, not at submit time. If a successor statement created the
//      key while the op sat in the shard queue, the delayed apply probes,
//      HITS, and returns the successor's node id. The only way a late apply
//      duplicates is if its probe→insert straddles the successor's create —
//      which is exactly RC-2, already covered by T2/T2b above.
//
//   3. The shard worker cannot be stalled at the point that would matter
//      without editing production code. Holding `mg.rwlock` EXCLUSIVE stalls
//      the worker BEFORE its probe, which produces case (2) — a clean match.
//      Stalling it BETWEEN probe and insert needs an injection hook that does
//      not exist, and adding one would mean modifying production code, which
//      is out of scope for a reproduction-test change.
//
// Where RC-3 IS observable: at the harness/integration layer, with a real
// server and two connections, where a client request can actually time out
// while its op stays queued. See
// `../geode-test-harness/geodetestlab-cli/specs/merge_cross_session_idempotency.yml`
// for the two-connection cross-session shape; a timeout-specific spec is the
// right home for RC-3 and is called out in the ENG-3914 fix plan.

// ---------------------------------------------------------------------------
// T2c/T2d — RC-3: the graph-CREATION window
// ---------------------------------------------------------------------------
//
// A THIRD way the two MERGE implementations can lose their shared mutual
// exclusion, distinct from RC-2's probe→insert gap: they can end up on two
// DIFFERENT locks entirely.
//
//   bulk path    `bulkMergeNodeWithReservedIdMultiPropForTenant` opens with
//                `self.getOrCreateGraph(graph_name)` — it MATERIALIZES the
//                `ManagedGraph` and then locks it (tuple lock → `mg.rwlock`
//                SHARED across probe→insert, the RC-2 contract).
//
//   general path the connection handler calls
//                `graph_store.acquireGraphWriteLockCancelable(graph_name, …)`.
//                Before this fix, an adapter that had not materialized
//                `graph_name` YET answered `error.GraphNotFound`, and that was
//                treated as "legacy store, no per-graph rwlock exists" — so the
//                acquire escalated to the GLOBAL store lock EXCLUSIVE.
//
// The bulk path never touches the global store lock. So for as long as the
// graph was unmaterialized, the two writers excluded each other on NOTHING and
// both completed probe→create for the same key. Every session starts at the
// same first key, so the observable symptom is exactly one duplicate, on the
// FIRST key, on a fresh data dir — reproduced at the wire level in 5 of 15
// runs (4 bulk + 4 general `geode query --batch` sessions, 8 shared keys).
//
// Fix: `acquireGraphWriteLockCancelable` materializes the graph (the SAME
// `getOrCreateGraph` the bulk path uses) and takes the normal per-graph path.
// The legacy global-exclusive escalation is now reached only when there is NO
// adapter at all.

/// The graph the writers race to materialize: `default` on a fresh store,
/// the production shape (the first statements of a fresh server). Each test
/// asserts the precondition that the adapter does not know it yet.
///
/// SONNY-3122: this was a dedicated name no harness step creates. The write
/// lock no longer creates a graph that exists nowhere (a session can only be
/// on a graph that existed when it bound it, so one that is gone was
/// dropped, and creating it again brought a dropped graph back); it
/// materializes the default graph and a graph the engine knows but has not
/// opened.
const window_graph_name = graph_store.DEFAULT_GRAPH_NAME;

fn bulkMergeWindow(adapter: *adapter_mod.StorageAdapter, k: Key) !u64 {
    const merge_props = [_]PropKV{
        .{ .key = "docId", .value = .{ .Int = k.doc_id } },
        .{ .key = "seq", .value = .{ .Int = k.seq } },
    };
    const on_create = [_]PropKV{
        .{ .key = "origin", .value = .{ .String = "bulk" } },
    };
    const store = graph_store.getGlobalStore(graph_store.global_allocator());
    const res = try adapter.bulkMergeNodeWithReservedIdMultiProp(
        window_graph_name,
        store.reserveNodeId(),
        label,
        &merge_props,
        &on_create,
        false,
    );
    return res.id;
}

/// General MERGE against `window_graph_name`, under the same write-lock pair
/// the connection handler uses. The session's current graph is what routes
/// `executeMerge` to that graph, mirroring a client that ran `USE GRAPH`.
fn generalMergeWindow(
    ctx: *execution.ExecutionContext,
    session: *execution.SessionState,
    arena: *std.heap.ArenaAllocator,
    k: Key,
) !void {
    const aa = arena.allocator();
    const q = try std.fmt.allocPrint(
        aa,
        "MERGE (n:" ++ label ++ " {{docId: {d}, seq: {d}}}) ON CREATE SET n.origin = 'general'",
        .{ k.doc_id, k.seq },
    );
    var parsed = try geode.parseGqlOptions(q, aa, .{});
    defer parsed.deinit();

    ctx.session_state = session;

    const deadline = nowNs() + 60 * std.time.ns_per_s;
    const handle = try graph_store.acquireGraphWriteLockCancelable(window_graph_name, deadline);
    defer graph_store.releaseGraphLock(handle);

    _ = try execution.executeStatementWithContext(aa, parsed.program.statements[0], ctx.*);
}

const CreationWindowCtx = struct {
    adapter: *adapter_mod.StorageAdapter,
    catalog: @TypeOf(@as(execution.ExecutionContext, undefined).catalog),
    allocator: std.mem.Allocator,
    use_general_path: bool,
    barrier: *Barrier,
    key_total: usize,
    err: std.atomic.Value(u32) = std.atomic.Value(u32).init(0),
};

fn creationWindowWorker(ctx: *CreationWindowCtx) void {
    var arena = std.heap.ArenaAllocator.init(ctx.allocator);
    defer arena.deinit();
    var session = execution.SessionState.init(ctx.allocator);
    defer session.deinit();
    session.graph = ctx.allocator.dupe(u8, window_graph_name) catch {
        ctx.err.store(1, .release);
        ctx.barrier.abort.store(1, .release);
        return;
    };
    var exec_ctx = execution.ExecutionContext{ .catalog = ctx.catalog };
    exec_ctx.session_state = &session;

    var i: usize = 0;
    while (i < ctx.key_total) : (i += 1) {
        ctx.barrier.wait();
        if (ctx.barrier.aborted()) continue;
        const k = keyAt(i);
        if (ctx.use_general_path) {
            generalMergeWindow(&exec_ctx, &session, &arena, k) catch {
                ctx.err.store(1, .release);
                ctx.barrier.abort.store(1, .release);
                continue;
            };
        } else {
            _ = bulkMergeWindow(ctx.adapter, k) catch {
                ctx.err.store(1, .release);
                ctx.barrier.abort.store(1, .release);
                continue;
            };
        }
    }
}

// CANARY: REQ=REQ-ENG-3914-MERGE-CROSS-PATH-RACE; FEATURE="MergeIdempotency"; ASPECT=CreationWindowLockUnification; STATUS=TESTED; TEST=tests/test_eng3914_cross_path_merge_race.zig; OWNER=storage; UPDATED=2026-08-30
test "ENG-3914 T2d regression: an UNMATERIALIZED graph must still lock PER-GRAPH, never the global exclusive" {
    // Deterministic statement of the RC-3 contract — no race needed. The two
    // MERGE implementations are mutually exclusive only if they lock the SAME
    // object, so this asserts (a) the write-lock acquire returns a per-graph
    // handle for a graph the adapter has not materialized, and (b) that handle
    // names the very `ManagedGraph` the bulk path reaches via
    // `getOrCreateGraph`.
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    // Precondition: the adapter genuinely does not know this graph yet, so
    // this test really is exercising the creation window.
    try testing.expectError(error.GraphNotFound, h.adapter.lookupManagedGraph(window_graph_name));

    const deadline = nowNs() + 60 * std.time.ns_per_s;
    const handle = try graph_store.acquireGraphWriteLockCancelable(window_graph_name, deadline);
    // RED pre-fix: `managed_graph == null` and `global_lock_is_exclusive == true`
    // (the legacy global-exclusive escalation the bulk path never participates in).
    try testing.expect(handle.managed_graph != null);
    try testing.expect(!handle.global_lock_is_exclusive);
    const locked_mg = handle.managed_graph.?;
    graph_store.releaseGraphLock(handle);

    // The bulk MERGE fast path resolves its graph with `getOrCreateGraph`; the
    // handle above must be the SAME ManagedGraph, i.e. the same `mg.rwlock`.
    const bulk_mg = try h.adapter.getOrCreateGraph(window_graph_name);
    try testing.expectEqual(locked_mg, bulk_mg);

    // Non-cancelable sibling honours the same contract.
    const h2 = graph_store.acquireGraphWriteLock(window_graph_name);
    defer graph_store.releaseGraphLock(h2);
    try testing.expect(h2.managed_graph != null);
    try testing.expect(!h2.global_lock_is_exclusive);
    try testing.expectEqual(bulk_mg, h2.managed_graph.?);
}

// CANARY: REQ=REQ-ENG-3914-MERGE-CROSS-PATH-RACE; FEATURE="MergeIdempotency"; ASPECT=CreationWindowConcurrency; STATUS=TESTED; TEST=tests/test_eng3914_cross_path_merge_race.zig; OWNER=storage; UPDATED=2026-08-30
test "ENG-3914 T2c regression: cross-path MERGE racing the graph-CREATION window must not duplicate" {
    // The window exists exactly ONCE per store lifetime (the first write to a
    // not-yet-materialized graph), so the whole scenario is re-run against a
    // fresh store each round to make the one-shot race observable. The wire
    // repro duplicated in 5 of 15 rounds with 8 shared keys.
    const rounds = 10;
    const t2c_keys = 8;
    const bulk_workers = 3;
    const general_workers = 3;
    const workers = bulk_workers + general_workers;

    var round: usize = 0;
    while (round < rounds) : (round += 1) {
        var h = try Harness.init(testing.allocator);
        defer h.deinit();
        // Deliberately NO setUpGraph(): `window_graph_name` must not exist yet.
        try testing.expectError(error.GraphNotFound, h.adapter.lookupManagedGraph(window_graph_name));

        var barrier = Barrier{ .n = workers };
        var ctxs: [workers]CreationWindowCtx = undefined;
        var threads: [workers]std.Thread = undefined;

        for (0..workers) |i| {
            ctxs[i] = .{
                .adapter = h.adapter,
                .catalog = h.catalog,
                .allocator = testing.allocator,
                .use_general_path = i >= bulk_workers,
                .barrier = &barrier,
                .key_total = t2c_keys,
            };
        }
        for (0..workers) |i| {
            threads[i] = try std.Thread.spawn(.{}, creationWindowWorker, .{&ctxs[i]});
        }
        for (threads) |t| t.join();

        for (ctxs, 0..) |c, i| {
            if (c.err.load(.acquire) != 0) {
                std.debug.print(
                    "creation-window worker {d} ({s}) errored in round {d}\n",
                    .{ i, if (c.use_general_path) "general" else "bulk", round },
                );
                return error.WorkerError;
            }
        }

        // Read back from the window graph, not the session default.
        h.session.graph = try testing.allocator.dupe(u8, window_graph_name);

        var expected: [t2c_keys]Key = undefined;
        for (0..t2c_keys) |i| expected[i] = keyAt(i);
        h.assertOneNodePerKey(&expected) catch |err| {
            std.debug.print("  (round {d} of {d})\n", .{ round, rounds });
            return err;
        };
    }
}
