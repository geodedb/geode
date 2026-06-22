// Regression test for the EDGE-phase 40001 ("Write lock acquisition timed
// out") that blocked the full 14.27M-node + edges bulk ingest.
//
// Triage (confirmed live via gdb on the 14.27M graph, PID 1703302):
//
//   * Thread A (checkpoint loop): persistenceLoop -> walCheckpointHook ->
//     saveToFileEx -> StorageAdapter.checkpointAllEx, parked in
//     `Io.RwLock.lockSharedUncancelable` at
//     src/storage/graph_storage_adapter.zig:4554 — the MANIFEST-COUNT phase
//     that, FOR EACH GRAPH EVERY CYCLE, took the per-graph rwlock SHARED only
//     to sum `shard.manifest.node_count`/`edge_count`.
//
//   * Thread B (edge exclusive op = CREATE INDEX ON :Taxon(source_id), and
//     the relationship MERGE): acquireGraphWriteLockCancelable spinning on
//     the bounded `tryLock` re-probe. `std.Io.RwLock.tryLock` FAILS whenever
//     `reader_mask != 0` (RwLock.zig:31).
//
// At 14.27M scale `pending_bulk_ops` stays high post-NODE-ingest, so the
// checkpoint loop fires back-to-back. Its manifest-count SHARED acquire is a
// near-constant recurring reader on the target graph, so the edge's
// exclusive `tryLock` NEVER observes a reader-free instant within its
// 2-minute deadline -> 40001.
//
// Contract pinned here: with one or more SHARED readers acquiring/releasing
// the per-graph rwlock back-to-back (modelling the recurring manifest-count
// reader of the continuous checkpoint loop AND the generic query MATCH read
// path), a writer with a realistic deadline ACQUIRES the per-graph EXCLUSIVE
// lock — it does NOT return error.Deadline (the 40001). A watchdog bounds the
// test so a regression fails loudly instead of hanging CI.
//
// This is stronger than tests/test_graph_write_lock_no_hang.zig (which leaves
// a 150us gap between reader acquires so reader-free instants exist and only
// asserts "no hang within 30s, error.Deadline is fine") and
// tests/test_rwlock_fairness_under_load.zig (which holds the RAW mg.rwlock
// directly, bypassing the writer-preference back-off, and allows a 30s
// budget). Here the readers go through the REAL per-graph adapter read path
// (acquireGraphReadLock — the one query MATCH uses), they are CONTINUOUS, the
// deadline is a tight 3s, and error.Deadline is the FAILURE we reproduce.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const graph_store = geode.graph_store;

fn monoNanos() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    }
    return @as(u64, @intCast(ts.sec)) * 1_000_000_000 + @as(u64, @intCast(ts.nsec));
}

fn sleepNs(ns: u64) void {
    const req = std.os.linux.timespec{
        .sec = @intCast(ns / std.time.ns_per_s),
        .nsec = @intCast(ns % std.time.ns_per_s),
    };
    var rem: std.os.linux.timespec = undefined;
    _ = std.os.linux.nanosleep(&req, &rem);
}

// Module-level adapter handle — set up once, left initialised on exit and
// backed by smp_allocator (NOT the testing allocator) so the leak detector
// is not tripped. Same idiom as tests/test_r6_parallel_ingest_throughput.zig.
var g_adapter_initialized: bool = false;
var g_adapter_path_buf: [256]u8 = undefined;

fn ensureAdapter() !void {
    if (g_adapter_initialized) return;
    const path = try std.fmt.bufPrint(&g_adapter_path_buf, ".zig-cache/tmp/edge_starvation_{d}", .{monoNanos()});
    // initGlobalAdapter wires up the per-graph StorageAdapter as the process
    // global, so the top-level acquireGraphReadLock / acquireGraphWriteLock-
    // Cancelable route through the per-graph rwlock path (where the
    // production 40001 lives), NOT the legacy global-only fallback.
    _ = try graph_store.initGlobalAdapter(std.heap.smp_allocator, path);
    g_adapter_initialized = true;
}

const ReaderChurnCtx = struct {
    graph_name: []const u8,
    stop: *std.atomic.Value(u32),
    // Tiny hold so multiple reader threads overlap their `reader` bits,
    // reproducing the "tryLock never sees reader_mask==0" instant. No gap
    // between release and the next acquire — this is the recurring
    // manifest-count reader of the continuous checkpoint loop.
    hold_ns: u64,
};

// Models the checkpoint loop's recurring manifest-count SHARED acquire AND
// the generic query MATCH read path (acquireGraphReadLock): take the
// per-graph SHARED lock, hold briefly, release, immediately repeat.
fn readerChurn(ctx: *ReaderChurnCtx) void {
    while (ctx.stop.load(.acquire) == 0) {
        const h = graph_store.acquireGraphReadLockTagged(ctx.graph_name, .misc);
        sleepNs(ctx.hold_ns);
        graph_store.releaseGraphLock(h);
        // NO inter-acquire gap: the next acquire races immediately.
    }
}

const WriterCtx = struct {
    graph_name: []const u8,
    deadline_ns: u64,
    acquired: *std.atomic.Value(u32),
    got_deadline: *std.atomic.Value(u32),
    done: *std.atomic.Value(u32),
    elapsed_ns: *u64,
};

// The edge-phase exclusive op (CREATE INDEX / relationship MERGE): acquire
// the per-graph EXCLUSIVE lock with a realistic deadline. Must ACQUIRE; a
// returned error.Deadline IS the 40001 bug.
fn exclusiveAcquirer(ctx: *WriterCtx) void {
    const start = monoNanos();
    const result = graph_store.acquireGraphWriteLockCancelable(
        ctx.graph_name,
        start + ctx.deadline_ns,
    );
    ctx.elapsed_ns.* = monoNanos() - start;
    if (result) |h| {
        ctx.acquired.store(1, .release);
        // Brief critical section like CREATE INDEX's schema apply.
        sleepNs(1 * std.time.ns_per_ms);
        graph_store.releaseGraphLock(h);
    } else |err| {
        if (err == error.Deadline) {
            ctx.got_deadline.store(1, .release);
        } else {
            std.debug.print("exclusive acquirer unexpected error: {s}\n", .{@errorName(err)});
        }
    }
    ctx.done.store(1, .release);
}

test "edge-phase exclusive acquire is not starved by a continuous shared reader (40001)" {
    try ensureAdapter();

    const graph_name = "edge_starvation_g";
    if (graph_store.getGlobalAdapter()) |adapter| {
        _ = adapter.getOrCreateGraph(graph_name) catch |err| switch (err) {
            error.GraphAlreadyExists => {},
            else => return err,
        };
    } else {
        return error.NoGlobalAdapter;
    }

    // Spawn several continuous SHARED readers so their `reader` bits overlap
    // — this is what defeats the exclusive `tryLock` (it only succeeds when
    // reader_mask == 0). One reader with a hold creates frequent but not
    // guaranteed-overlapping windows; multiple guarantee the contention that
    // reproduced the 40001 at 14.27M scale.
    const num_readers = 4;
    var stop_readers = std.atomic.Value(u32).init(0);
    var reader_ctx = ReaderChurnCtx{
        .graph_name = graph_name,
        .stop = &stop_readers,
        .hold_ns = 200 * std.time.ns_per_us,
    };
    var reader_threads: [num_readers]std.Thread = undefined;
    for (&reader_threads) |*t| t.* = try std.Thread.spawn(.{}, readerChurn, .{&reader_ctx});

    // Let the readers reach steady-state continuous contention.
    sleepNs(50 * std.time.ns_per_ms);

    var acquired = std.atomic.Value(u32).init(0);
    var got_deadline = std.atomic.Value(u32).init(0);
    var writer_done = std.atomic.Value(u32).init(0);
    var elapsed_ns: u64 = 0;
    var writer_ctx = WriterCtx{
        .graph_name = graph_name,
        // Realistic deadline (scaled down from the 2-minute production
        // deadline for test speed). With a correct writer-preference the
        // exclusive op wins in milliseconds; the starvation bug burns the
        // entire deadline and returns error.Deadline.
        .deadline_ns = 3 * std.time.ns_per_s,
        .acquired = &acquired,
        .got_deadline = &got_deadline,
        .done = &writer_done,
        .elapsed_ns = &elapsed_ns,
    };
    const t_writer = try std.Thread.spawn(.{}, exclusiveAcquirer, .{&writer_ctx});

    // Watchdog: the writer must finish (acquire or hit its 3s deadline)
    // within a generous bound. We join cleanly either way to avoid a
    // teardown hang.
    const watchdog_deadline = monoNanos() + 10 * std.time.ns_per_s;
    while (monoNanos() < watchdog_deadline and writer_done.load(.acquire) == 0) {
        sleepNs(10 * std.time.ns_per_ms);
    }

    stop_readers.store(1, .release);
    for (&reader_threads) |t| t.join();
    t_writer.join();

    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / 1_000_000.0;

    if (got_deadline.load(.acquire) == 1) {
        std.debug.print(
            "EDGE-PHASE 40001 REGRESSION: the exclusive acquire returned " ++
                "error.Deadline after {d:.1} ms — it was STARVED by the " ++
                "continuous SHARED reader (the checkpoint loop's recurring " ++
                "manifest-count acquire at graph_storage_adapter.zig:4554 / " ++
                "the generic acquireGraphReadLock query-MATCH path). The " ++
                "writer's tryLock never observed a reader-free instant. This " ++
                "is the production 40001 that blocks the edge phase.\n",
            .{elapsed_ms},
        );
        return error.EdgePhaseExclusiveStarved;
    }

    try testing.expect(acquired.load(.acquire) == 1);

    // Stronger than "did not deadline": with a working writer-preference the
    // exclusive op wins as soon as the in-flight readers drain (~one hold
    // cycle), i.e. in milliseconds — NOT by luckily scraping a tryLock near
    // the 3s deadline. A near-deadline acquire would indicate the preference
    // is not actually draining the readers and the fix is fragile.
    if (elapsed_ms > 1500.0) {
        std.debug.print(
            "EDGE-PHASE writer-preference WEAK: the exclusive acquire " ++
                "succeeded but took {d:.1} ms (deadline 3000 ms). It should " ++
                "win in well under a second once readers back off; a " ++
                "near-deadline win means the back-off is not draining the " ++
                "reader set.\n",
            .{elapsed_ms},
        );
        return error.EdgePhaseExclusiveWinTooSlow;
    }
}
