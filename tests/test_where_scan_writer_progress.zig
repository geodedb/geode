// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// Concurrency-bottleneck regression: writers must make progress DURING a long
// WHERE-predicate scan over a NON-INDEXED property (where-scan-writer-progress).
//
// Triage (confirmed live): during a sustained MERGE ingest, a concurrent
//   MATCH (n:Probe) WHERE n.someprop = 'target' RETURN n.someprop LIMIT 3
// over a NON-INDEXED property took ~30 s (client timeout) AND stalled the
// ingest to ~0 ops/s for its whole duration. By contrast a point-read by the
// indexed merge key, an O(1) count, and a bare projection LIMIT were all fast
// and non-stalling. So the bottleneck is specifically the WHERE-predicate scan
// over a non-indexed property under concurrent writes — read<->write
// CONTENTION, not the scan path itself (idle WHERE+LIMIT is ~300 ms).
//
// Mechanism: the streaming read path's MATERIALIZE + EVALUATE loop
// (`NodeScanStream.buildNextPage` -> materializeNode/evalPredicate per node,
// iterating until LIMIT matched rows are found, src/server/node_scan_stream.zig)
// runs UNDER the per-graph SHARED read lock the transport handler holds across
// the WHOLE `buildNextPage` call (quic_connection_handler.zig:6793 / :7039,
// `acquireGraphReadLockTagged(.., .misc)`). For a SPARSE non-indexed predicate
// the loop materializes+evaluates MANY nodes before finding LIMIT matches, so
// that single SHARED hold spans the entire O(scanned) scan.
//
// The stall is a writer-preference effect: the periodic checkpoint takes
// `mg.rwlock` EXCLUSIVE (graph_storage_adapter.zig:4372, to drain in-flight
// writers for a race-free snapshot). `std.Io.RwLock` is writer-preferred — once
// that EXCLUSIVE acquire is PENDING (parked behind the scan's long SHARED hold),
// every NEW SHARED acquirer parks behind it too. The ingest apply path takes
// `mg.rwlock` SHARED before its per-shard EXCLUSIVE (bulkInsert*, :2107), so it
// parks behind the pending checkpoint -> ingest drops to ~0 ops/s until the long
// scan finally releases SHARED and the checkpoint completes.
//
// Fix: CHUNK the materialize/evaluate loop's per-graph SHARED hold the same way
// the slot-collection scan chunks the per-shard SHARED hold (commit 1525e5e3):
// release + reacquire the lock per batch of materialized nodes so a pending
// EXCLUSIVE checkpoint interleaves (waits at most one batch), unblocking the
// writers parked behind it. The slot_ids snapshot is immutable and the cursor
// (`next_index`) is monotonic, so releasing between batches never
// re-collects/duplicates; a node deleted across the gap simply fails
// materializeNode and is skipped via the existing catch-continue; we never
// release mid-node so no torn read is exposed. LIMIT early-termination is
// preserved.
//
// This test reproduces the contention on a FRESH temp graph by driving the
// REAL streaming path the handler uses against a SPARSE predicate, alongside a
// checkpointer thread that periodically takes the EXCLUSIVE graph lock (the
// live stall trigger) and a writer pinned to one shard via the same bulk apply
// ingest uses. It asserts BOTH: (a) writer ops advance DURING the scans (>= 5%
// of the unstarved baseline; ~0 before the fix because the writer parks behind
// the pending checkpoint), and (b) every scan returns the correct 3 'target'
// rows.
//
// Deterministic in OUTCOME, wall-clock-bounded, CI-safe. The progress
// assertion is a RATIO (during-scan throughput vs the writer's own unstarved
// baseline), not an absolute op count, so it does not flake on slow/contended
// CI runners.
//
// CANARY: REQ=REQ-CONCURRENCY-WHERE-SCAN-WRITER-PROGRESS; FEATURE="WhereScanWriterProgress"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_where_scan_writer_progress.zig; OWNER=storage; UPDATED=2026-06-20

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
const SEED_NODES: usize = 30_000;
const TARGET_COUNT: usize = 3;

// Pin the writer to a single shard so the contention is undiluted.
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

fn sleepMs(ms: u64) void {
    const req = std.os.linux.timespec{
        .sec = @intCast(ms / 1000),
        .nsec = @intCast((ms % 1000) * std.time.ns_per_ms),
    };
    var rem: std.os.linux.timespec = undefined;
    _ = std.os.linux.nanosleep(&req, &rem);
}

const Shared = struct {
    allocator: std.mem.Allocator,
    adapter: *adapter_mod.StorageAdapter,
    store: *graph_store.GraphStore,
    ctx: execution.ExecutionContext,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    ops_applied: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    writer_err: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    scan_err: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    scan_wrong_rows: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    // Main thread drives a back-to-back scanner thread on/off via this flag.
    scan_active: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    scans_done: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
};

// Writer: tight insert loop via the SAME bulk apply path ingest uses. Each node
// carries someprop='other' (never the target), pinned to TARGET_SHARD. The bulk
// apply takes `mg.rwlock` SHARED before its per-shard EXCLUSIVE, so it parks
// behind any pending EXCLUSIVE checkpoint — the live stall.
fn writerThread(sh: *Shared) void {
    const labels = [_][]const u8{LABEL};
    const props = [_]adapter_mod.StorageAdapter.PropKV{
        .{ .key = PROP, .value = .{ .String = FILLER } },
    };
    while (!sh.stop.load(.acquire)) {
        const reserved = reserveIdOnTargetShard(sh.store);
        _ = sh.adapter.bulkInsertNodeWithReservedId(GRAPH, reserved, &labels, &props) catch {
            sh.writer_err.store(true, .release);
            return;
        };
        _ = sh.ops_applied.fetchAdd(1, .monotonic);
    }
}

// Scanner: while `scan_active`, run the sparse WHERE+LIMIT scan back-to-back so
// the per-graph SHARED read lock is held near-continuously, exactly as a sustained
// stream of such queries would. Records correctness (each scan must return the 3
// 'target' rows) on the shared flags.
fn scannerThread(sh: *Shared) void {
    while (!sh.stop.load(.acquire)) {
        if (!sh.scan_active.load(.acquire)) {
            sleepMs(1);
            continue;
        }
        const matched = runWhereScanOnce(sh.allocator, sh.ctx) catch {
            sh.scan_err.store(true, .release);
            return;
        };
        if (matched != TARGET_COUNT) sh.scan_wrong_rows.store(true, .release);
        _ = sh.scans_done.fetchAdd(1, .monotonic);
    }
}

fn parseQuery(arena: *std.heap.ArenaAllocator, src: []const u8) !*const geode.gql.ast.Query {
    var lx = geode.gql.lexer.Lexer{ .src = src };
    var p = geode.gql.parser.Parser{ .lx = &lx, .arena = arena, .cur = lx.next() };
    const program = try p.parseProgram();
    return &program.statements[0].Query;
}

// Run the WHERE+LIMIT scan EXACTLY as the transport handler does: prepare the
// stream, then materialize pages. `buildNextPage` acquires + releases the
// per-graph SHARED read lock INTERNALLY in chunked batches (the fix under test),
// so — like the real handler after the fix — we do NOT wrap it in an outer lock.
// Returns the number of matched rows (== TARGET_COUNT).
fn runWhereScanOnce(allocator: std.mem.Allocator, ctx: execution.ExecutionContext) !usize {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    // NON-INDEXED-SCAN PREDICATE (must stay a non-seekable shape): the whole
    // point of this regression is a LONG O(scanned) materialize+evaluate scan
    // that holds the per-graph SHARED read lock. The enterprise exact
    // node-property VALUE index (GAP-ENT-0048 / the GAP-ENT-0019 filtered fast
    // path) now serves a `n.someprop = 'target'` EQUALITY via an O(matched)
    // index SEEK (see node_scan_stream `seekIndexedCandidates`) — the scan then
    // finishes in ~1 ms and the contention never materializes (single_scan_ms
    // fell below the 50 ms precondition). Use `<> 'other'`, which the exact-index
    // seek deliberately does NOT cover (it only extracts a seekable
    // `key = <literal>` equality), so the scan falls back to the full
    // materialize+evaluate loop. The result set is identical: only the 3
    // pre-seeded 'target' nodes satisfy `<> 'other'` (the writer only ever adds
    // 'other'), so every scan still returns exactly TARGET_COUNT rows.
    const q = try parseQuery(
        &arena,
        "MATCH (n:Probe) WHERE n.someprop <> 'other' RETURN n.someprop LIMIT 3",
    );
    const prepared = (try node_scan_stream.prepare(aa, q, ctx, &.{}, &.{}, &.{})) orelse
        return error.NotStreamable;
    var stream = prepared;
    defer stream.deinit();

    var matched: usize = 0;
    while (stream.hasRemaining()) {
        var page = try stream.buildNextPage(aa, TARGET_COUNT);
        matched += page.result.rows.len;
        page.result.deinit(aa);
        if (page.final) break;
    }
    return matched;
}

fn seedGraph(adapter: *adapter_mod.StorageAdapter, store: *graph_store.GraphStore, n: usize) !void {
    const labels = [_][]const u8{LABEL};
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const reserved = reserveIdOnTargetShard(store);
        const val: []const u8 = if (i >= n - TARGET_COUNT) TARGET else FILLER;
        const props = [_]adapter_mod.StorageAdapter.PropKV{
            .{ .key = PROP, .value = .{ .String = val } },
        };
        _ = try adapter.bulkInsertNodeWithReservedId(GRAPH, reserved, &labels, &props);
    }
}

test "writers make progress during a sparse WHERE-predicate scan (read<->write contention)" {
    const allocator = testing.allocator;

    execution.cleanupCatalogInstance();
    graph_store.deinitGlobalStore();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    graph_store.setDataDirOverride(allocator, data_dir);
    defer graph_store.setDataDirOverride(allocator, null);
    const store = graph_store.getGlobalStore(allocator);
    defer graph_store.deinitGlobalStore();

    const catalog = try execution.ensureCatalogInstance(allocator);
    defer execution.cleanupCatalogInstance();
    const ctx = execution.ExecutionContext{ .catalog = catalog };

    const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterUnavailable;
    _ = try adapter.getOrCreateGraph(GRAPH);

    // Seed a large population on TARGET_SHARD; only the LAST 3 nodes carry the
    // target value, so the WHERE scan must materialize+evaluate the whole
    // posting list before finding its 3 matches — the worst-case sparse scan.
    try seedGraph(adapter, store, SEED_NODES);

    var sh = Shared{ .allocator = allocator, .adapter = adapter, .store = store, .ctx = ctx };

    const mg = try adapter.lookupManagedGraph(GRAPH);
    const io = std.Io.Threaded.global_single_threaded.io();

    var writer = try std.Thread.spawn(.{}, writerThread, .{&sh});
    var scanner = try std.Thread.spawn(.{}, scannerThread, .{&sh});
    defer {
        sh.stop.store(true, .release);
        writer.join();
        scanner.join();
    }

    // Warm up the writer.
    {
        var spins: usize = 0;
        while (sh.ops_applied.load(.monotonic) < 50 and spins < 100_000) : (spins += 1) {
            std.atomic.spinLoopHint();
        }
    }
    try testing.expect(!sh.writer_err.load(.acquire));

    // ---- DECISIVE SIGNAL: EXCLUSIVE-acquire latency under a sustained scan ----
    //
    // The live stall is a writer-PREFERENCE effect: the periodic checkpoint takes
    // `mg.rwlock` EXCLUSIVE (via `lockUncancelable`); while that EXCLUSIVE acquire
    // is parked behind the scan's SHARED hold it forces every NEW SHARED acquirer
    // (the ingest apply) to queue behind it -> ingest stalls until the scan
    // releases. So the EXCLUSIVE-acquire latency under a sustained scan IS the
    // stall the ingest suffers. We measure it directly: with the scanner hammering
    // the WHERE scan, time how long ONE EXCLUSIVE acquire takes.
    //
    //   RED (unchunked): the scan holds SHARED for the WHOLE O(scanned) scan
    //     (~tens of ms .. seconds), so the EXCLUSIVE waits ~a full scan.
    //   GREEN (chunked): the scan releases SHARED every batch, so the EXCLUSIVE
    //     slots in within ~one batch (sub-ms .. low-ms).
    //
    // Also confirm the scan is genuinely long (so RED really would block for a
    // long time) by timing one scan with no EXCLUSIVE contention.
    sh.scan_active.store(true, .release);

    // Time one full scan (single-scan duration = the worst-case RED stall).
    const scan_t0 = nowNs();
    const before_scans = sh.scans_done.load(.monotonic);
    while (sh.scans_done.load(.monotonic) == before_scans) {
        if (sh.scan_err.load(.acquire)) break;
        std.atomic.spinLoopHint();
    }
    const single_scan_ns = nowNs() - scan_t0;
    try testing.expect(!sh.scan_err.load(.acquire));

    // Worst EXCLUSIVE-acquire latency observed over a window spanning MORE than
    // one full scan, attempting back-to-back so at least one acquire begins
    // MID-scan (while a SHARED hold is in progress). RED (one unbroken SHARED
    // hold per scan): an acquire that begins mid-scan waits the REST of the scan
    // (~seconds). GREEN (chunked): every acquire slots in within ~one batch.
    var worst_excl_ns: u64 = 0;
    {
        // Span at least 1.2 scans so a mid-scan acquire is guaranteed.
        const excl_deadline = nowNs() + single_scan_ns + single_scan_ns / 5;
        while (nowNs() < excl_deadline) {
            if (sh.scan_err.load(.acquire)) break;
            const e0 = nowNs();
            mg.rwlock.lockUncancelable(io);
            const e1 = nowNs();
            std.atomic.spinLoopHint();
            mg.rwlock.unlock(io);
            const excl_ns = e1 - e0;
            if (excl_ns > worst_excl_ns) worst_excl_ns = excl_ns;
        }
    }

    // ---- Secondary signal: writer keeps progressing during the scan ----
    // Measure over a HALF-scan window (the scanner is still hammering) to keep
    // total test runtime bounded.
    const window_ns = single_scan_ns / 2;
    const ops_before = sh.ops_applied.load(.monotonic);
    const dur_start = nowNs();
    while (nowNs() - dur_start < window_ns) std.atomic.spinLoopHint();
    const ops_during = sh.ops_applied.load(.monotonic) - ops_before;

    sh.scan_active.store(false, .release);
    // Let the in-flight scan finish so the SHARED lock is free for the baseline.
    sleepMs(10);
    try testing.expect(!sh.writer_err.load(.acquire));
    try testing.expect(!sh.scan_err.load(.acquire));
    try testing.expect(!sh.scan_wrong_rows.load(.acquire)); // correctness

    // Baseline: writer's unstarved throughput over the same window, scanner idle.
    const base_before = sh.ops_applied.load(.monotonic);
    {
        const base_deadline = nowNs() + window_ns;
        while (nowNs() < base_deadline) std.atomic.spinLoopHint();
    }
    const baseline_ops = sh.ops_applied.load(.monotonic) - base_before;
    try testing.expect(!sh.writer_err.load(.acquire));

    std.debug.print(
        "where-scan-writer-progress: single_scan_ms={d} worst_excl_ms={d} ops_during={d} baseline={d}\n",
        .{ single_scan_ns / std.time.ns_per_ms, worst_excl_ns / std.time.ns_per_ms, ops_during, baseline_ops },
    );

    // The scan must genuinely be long (else the test proves nothing).
    try testing.expect(single_scan_ns >= 50 * std.time.ns_per_ms);

    // DECISIVE: under the sustained WHERE scan, an EXCLUSIVE acquire (the
    // checkpoint that the ingest stalls behind) completes in well under a quarter
    // of one full scan. RED (unbroken SHARED hold) ~= a full scan; GREEN (chunked)
    // is bounded by one batch — far below scan/4. This is the read<->write
    // contention the fix removes.
    try testing.expect(worst_excl_ns * 4 < single_scan_ns);

    // Secondary: the writer is not starved — its during-scan throughput is at
    // least 25% of its unstarved baseline.
    try testing.expect(baseline_ops >= 20);
    try testing.expect(ops_during * 4 >= baseline_ops);
}

test "sparse WHERE-predicate scan returns the correct rows under concurrent ingest" {
    const allocator = testing.allocator;

    execution.cleanupCatalogInstance();
    graph_store.deinitGlobalStore();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    graph_store.setDataDirOverride(allocator, data_dir);
    defer graph_store.setDataDirOverride(allocator, null);
    const store = graph_store.getGlobalStore(allocator);
    defer graph_store.deinitGlobalStore();

    const catalog = try execution.ensureCatalogInstance(allocator);
    defer execution.cleanupCatalogInstance();
    const ctx = execution.ExecutionContext{ .catalog = catalog };

    const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterUnavailable;
    _ = try adapter.getOrCreateGraph(GRAPH);

    const seed: usize = 10_000;
    try seedGraph(adapter, store, seed);

    var sh = Shared{ .allocator = allocator, .adapter = adapter, .store = store, .ctx = ctx };

    var writer = try std.Thread.spawn(.{}, writerThread, .{&sh});
    defer {
        sh.stop.store(true, .release);
        writer.join();
    }

    // Every run must return exactly the 3 pre-seeded 'target' rows — the writer
    // only ever adds 'other' nodes, so the matched set is stable under ingest.
    var n: usize = 0;
    while (n < 4) : (n += 1) {
        const matched = try runWhereScanOnce(allocator, ctx);
        try testing.expectEqual(TARGET_COUNT, matched);
    }
    try testing.expect(!sh.writer_err.load(.acquire));
}
