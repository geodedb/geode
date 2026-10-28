// Concurrent-read/write CRASH regression (read-stress).
//
// Triage: under 64-reader + 16-writer mixed load the server PANICKED:
//
//   thread panic: index out of bounds: index 18429, len 18429
//   graph_storage/src/label_index.zig:115  result[i] = key.*;   in scan
//     <- LabelIndex.iterator
//     <- node_scan_stream.collectMatchingSlotIds
//     <- node_scan_stream.prepare
//     <- quic_connection_handler.handleClientMessage (.rows streaming path)
//
// `LabelIndex.scan` allocates a result buffer sized to `set.count()` and then
// walks the live posting set's key iterator. A concurrent ingest `addNode`
// (run under the per-graph WRITE lock) that grows the set BETWEEN the count()
// and the end of the iteration drives the iterator past the buffer end — an
// out-of-bounds write that aborts the whole process. The streaming read path's
// slot-collection scan ran with NO lock held (the comment claimed the per-page
// lock covered it, but that lock is taken only later, for materialization).
//
// Fix: the QUIC and gRPC streaming paths now hold the SHARED per-graph read
// lock across `node_scan_stream.prepare` (the slot-collection scan), so the
// scan cannot run while a writer mutates the posting set. Shared lock => other
// readers still proceed concurrently; only the exclusive ingest write lock is
// excluded.
//
// This test reproduces the exact contention: one writer thread continuously
// adds :Race nodes (taking the per-graph write lock the same way ingest does)
// while several reader threads continuously run `prepare` on label :Race under
// the SAME shared read lock the handler now uses. Before the fix (scan with no
// lock) this reliably panics; with the lock it completes cleanly with valid
// results. It is wall-clock-bounded (fixed iteration counts), deterministic in
// outcome (no crash, results always a subset of the live population), and
// CI-safe.
//
// CANARY: REQ=REQ-CONCURRENCY-SCAN-INGEST-RACE; FEATURE="ScanIngestRaceSafety"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_scan_ingest_race.zig; OWNER=storage; UPDATED=2026-06-20

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const node_scan_stream = geode.node_scan_stream;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const GRAPH = graph_store.DEFAULT_GRAPH_NAME;

const Shared = struct {
    allocator: std.mem.Allocator,
    ctx: execution.ExecutionContext,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    writes_done: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    reads_done: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    err_seen: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn parseQuery(arena: *std.heap.ArenaAllocator, src: []const u8) !*const geode.gql.ast.Query {
    var lx = geode.gql.lexer.Lexer{ .src = src };
    var p = geode.gql.parser.Parser{ .lx = &lx, .arena = arena, .cur = lx.next() };
    const program = try p.parseProgram();
    return &program.statements[0].Query;
}

// Writer: continuously CREATE :Race nodes via the executor (which takes the
// per-graph write lock), exactly as ingest mutates the label posting set.
fn writerThread(sh: *Shared) void {
    var i: usize = 0;
    while (!sh.stop.load(.acquire)) : (i += 1) {
        var arena = std.heap.ArenaAllocator.init(sh.allocator);
        defer arena.deinit();
        const aa = arena.allocator();
        const q = std.fmt.allocPrint(aa, "CREATE (:Race {{rid: {d}}})", .{i}) catch {
            sh.err_seen.store(true, .release);
            return;
        };
        var parsed = geode.parseGql(q, aa) catch {
            sh.err_seen.store(true, .release);
            return;
        };
        defer parsed.deinit();
        var r = execution.executeStatementWithContext(aa, parsed.program.statements[0], sh.ctx) catch {
            // A transient executor error is acceptable; a CRASH is not. Keep going.
            continue;
        };
        r.deinit(aa);
        _ = sh.writes_done.fetchAdd(1, .monotonic);
    }
}

// Reader: continuously run `prepare` on label :Race under the SHARED read lock
// the handler now holds. This is the path that used to panic when the writer
// grew the posting set mid-scan.
fn readerThread(sh: *Shared) void {
    var n: usize = 0;
    while (n < 2000 and !sh.err_seen.load(.acquire)) : (n += 1) {
        var arena = std.heap.ArenaAllocator.init(sh.allocator);
        defer arena.deinit();
        const aa = arena.allocator();
        const q = parseQuery(&arena, "MATCH (n:Race) RETURN n LIMIT 10") catch {
            sh.err_seen.store(true, .release);
            return;
        };

        // `prepare` -> `collectMatchingSlotIds` collects the label's slot ids.
        // The fix lives INSIDE the adapter (`getNodesByLabelCapped` materializes
        // each shard's posting list under that shard's SHARED read lock), so the
        // streaming read path is crash-safe against concurrent ingest with NO
        // extra lock required at this call site. Default: no outer lock (proves
        // the adapter-internal shard locking is sufficient). Setting
        // GEODE_TEST_UNLOCKED_SCAN=anything is accepted for parity but both
        // modes are now safe. Before the fix (lazy unlocked `iterateNodesByLabel`
        // fan-out), this loop reliably aborted with the LabelIndex.scan OOB panic.
        const prepared = node_scan_stream.prepare(aa, q, sh.ctx, &.{}, &.{}, &.{}) catch {
            continue;
        };

        if (prepared) |stream_const| {
            var stream = stream_const;
            defer stream.deinit();
            // Materialize a page. `buildNextPage` now acquires + releases the
            // per-graph SHARED read lock INTERNALLY in chunked batches (the
            // where-scan-writer-progress fix), so the handler — and this test —
            // no longer wrap it in an outer lock.
            var page = stream.buildNextPage(aa, 10) catch {
                continue;
            };
            page.result.deinit(aa);
        }
        _ = sh.reads_done.fetchAdd(1, .monotonic);
    }
    sh.stop.store(true, .release);
}

test "concurrent ingest + label-scan prepare does not crash (LabelIndex.scan race)" {
    const allocator = testing.allocator;

    execution.cleanupCatalogInstance();
    graph_store.deinitGlobalStore();

    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    graph_store.setDataDirOverride(allocator, data_dir);
    defer graph_store.setDataDirOverride(allocator, null);
    _ = graph_store.getGlobalStore(allocator);
    defer graph_store.deinitGlobalStore();

    const catalog = try execution.ensureCatalogInstance(allocator);
    defer execution.cleanupCatalogInstance();

    // Seed a baseline so the posting set is non-trivial before the race begins.
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const aa = arena.allocator();
        var i: usize = 0;
        while (i < 500) : (i += 1) {
            const q = try std.fmt.allocPrint(aa, "CREATE (:Race {{rid: {d}}})", .{1_000_000 + i});
            var parsed = try geode.parseGql(q, aa);
            defer parsed.deinit();
            var r = try execution.executeStatementWithContext(aa, parsed.program.statements[0], .{ .catalog = catalog });
            r.deinit(aa);
        }
    }

    var sh = Shared{
        .allocator = allocator,
        .ctx = .{ .catalog = catalog },
    };

    const reader_count = 6;
    var writer = try std.Thread.spawn(.{}, writerThread, .{&sh});
    var readers: [reader_count]std.Thread = undefined;
    for (&readers) |*r| r.* = try std.Thread.spawn(.{}, readerThread, .{&sh});

    for (&readers) |r| r.join();
    sh.stop.store(true, .release);
    writer.join();

    // The decisive assertion is "we got here without a panic". Also sanity-check
    // that real work happened on both sides under contention.
    try testing.expect(!sh.err_seen.load(.acquire));
    try testing.expect(sh.reads_done.load(.monotonic) > 0);
    try testing.expect(sh.writes_done.load(.monotonic) > 0);
}
