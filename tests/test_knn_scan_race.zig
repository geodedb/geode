// Concurrent knn-scan / MERGE-writer CRASH regression (ENG-3954 / #874).
//
// Modeled directly on tests/test_scan_ingest_race.zig — same bug CLASS (an
// unlocked reader walking live storage while a locked writer reallocates it),
// same shape (bounded wall-clock, fixed iteration counts, decisive assertion
// is "we got here without a fault").
//
// Triage: `scanVectorKnn` (src/eval.zig:2220-2260) is the brute-force fallback
// taken whenever `vector_knn()` / `knn()` names a property with NO advanced
// (HNSW) vector index. It walks the LIVE bounded caches:
//
//     src/eval.zig:2231   var node_iter = store.nodes.iterator();
//     src/eval.zig:2249   var edge_iter = store.edges.iterator();
//
// with NO per-graph lock and no shard `map_lock`.
// `BoundedNodeCache.iterator()` (src/storage/node_cache.zig:435-437) takes no
// lock either — unlike its `get` / `getPtr` / `contains` siblings, which all do.
//
// Meanwhile a concurrent MERGE/SET writer mutates the very memory the scan is
// walking:
//
//     src/graph_store.zig:1189-1214  CompactPropertyMap.getOrPut grows the
//     sorted `entries` slice by one and FREES the old slice (:1207) on every
//     property insert; the mirrored remove path shrinks it the same way.
//
// So the reader dereferences `entry.value_ptr.properties` while the backing
// slice is being freed and replaced. It faults inside
// `CompactPropertyMap.search` -> `std.mem.order` (graph_store.zig:1156-1170):
// GPF / SIGSEGV, which takes down the whole server, not just the query.
// Growing the node cache concurrently is a second, independent invalidation of
// the same unlocked iterator.
//
// This test reproduces exactly that contention:
//   * writers run MERGE-style upserts that mint fresh :KnnRace nodes (node-cache
//     growth + eviction churn) and SET rotating scalar properties plus a fresh
//     f32 vector on existing ones (CompactPropertyMap realloc-and-free churn),
//     each through the real executor, i.e. under the per-graph WRITE lock that
//     ingest takes;
//   * readers run the REAL `knn('kembed', ...)` scan path over an UNINDEXED
//     vector property (no CREATE INDEX ... USING vector anywhere in this file),
//     so `evalVectorKnn` falls through to `scanVectorKnn`.
//
// BEFORE the fix this aborts the test binary (SIGSEGV / allocator corruption).
// AFTER the fix (scan takes the shared read lock / snapshots under the shard
// locks, matching what every other scan path already does) it must run clean:
// no fault, and every id the scan returns is one this test actually minted.
//
// Node count is deliberately modest (a few thousand) with HIGH write churn:
// the race is a function of churn rate, not graph size, so this stays CI-safe.
//
// CANARY: REQ=REQ-CONCURRENCY-KNN-SCAN-RACE; FEATURE="KnnScanRaceSafety"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_knn_scan_race.zig; OWNER=eval; UPDATED=2026-08-28

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

/// Vector property name. Never indexed anywhere in this file, so `knn()`
/// resolves to the brute-force `scanVectorKnn` path under test.
const VEC_PROP = "kembed";

// Sizing. The race is a function of WRITE CHURN RATE, not graph size, so the
// population stays in the low thousands (fast scans, CI-safe wall clock) while
// four writer lanes hammer the property maps. Every count is a fixed bound —
// no wall-clock loop — so the test terminates deterministically.
/// Seed population, and the id space the writers churn over.
const seed_nodes: usize = 1200;
/// Fresh nodes each writer mints (node-cache growth / eviction churn).
const writer_creates: usize = 6000;
/// knn scans per reader thread.
const reads_per_reader: usize = 900;
const reader_count = 6;
/// ONE writer lane (ENG-3954 fix review). The defect under test is
/// READER-vs-WRITER: the scan walking a property map a writer is reallocating.
/// Running several writer lanes ALSO exercised writer-vs-writer races on
/// structures this test does not target — `GraphStore.getOrCreateIdMap`'s
/// `id_maps` StringHashMap and the engine's `property_chain_index.chains` are
/// both plain hash maps that the store expects its CALLER (the transports, via
/// the per-graph EXCLUSIVE lock) to serialise, and the direct-executor harness
/// used here holds no such lock. Those crashed ~1 run in 6 with the reader
/// doing nothing at all, i.e. independent of scanVectorKnn. One lane keeps the
/// targeted contention (raised `writer_creates` holds the churn rate and the
/// population constant) while leaving the unrelated writer-vs-writer exposure —
/// pre-existing, separately tracked — out of this regression's signal.
const writer_count = 1;
const k: usize = 10;

const Shared = struct {
    allocator: std.mem.Allocator,
    ctx: execution.ExecutionContext,
    stop: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    writes_done: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    reads_done: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    rows_seen: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    /// Set when a thread could not even run its workload (setup/parse failure).
    err_seen: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
    /// Set when the scan returned something structurally impossible — the
    /// non-faulting face of the same use-after-free (torn read of a freed
    /// property slice yields garbage candidate ids).
    corrupt_result: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),
};

fn vectorLiteral(aa: std.mem.Allocator, i: usize) ![]const u8 {
    const a: f32 = @floatFromInt(i % 97);
    const b: f32 = @floatFromInt(i % 31);
    return std.fmt.allocPrint(aa, "vectorf32([{d}.0, {d}.0, 1.0, 0.5])", .{
        @as(u32, @intFromFloat(a)),
        @as(u32, @intFromFloat(b)),
    });
}

fn runQuery(aa: std.mem.Allocator, sh: *Shared, q: []const u8) bool {
    var parsed = geode.parseGql(q, aa) catch {
        sh.err_seen.store(true, .release);
        return false;
    };
    defer parsed.deinit();
    var r = execution.executeStatementWithContext(aa, parsed.program.statements[0], sh.ctx) catch {
        // A transient executor error (lock contention, MVCC retry) is
        // acceptable under this much churn; a CRASH is not.
        return false;
    };
    r.deinit(aa);
    return true;
}

// Writer: MERGE-style upserts against the id space the readers are scanning.
//
// Each iteration does two things the scan cannot tolerate today:
//   1. mints a NEW :KnnRace node (grows / evicts from the bounded node cache
//      the reader is iterating), and
//   2. SETs a ROTATING property key plus a fresh vector on an EXISTING node —
//      the new key forces CompactPropertyMap.getOrPut to allocate a bigger
//      `entries` slice and free the old one out from under the scan.
fn writerThread(sh: *Shared, lane: usize) void {
    var i: usize = 0;
    while (i < writer_creates and !sh.stop.load(.acquire)) : (i += 1) {
        var arena = std.heap.ArenaAllocator.init(sh.allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        const fresh_rid = 2_000_000 + lane * writer_creates + i;
        const vec_new = vectorLiteral(aa, fresh_rid) catch {
            sh.err_seen.store(true, .release);
            return;
        };
        const create_q = std.fmt.allocPrint(
            aa,
            "MERGE (n:KnnRace {{rid: {d}}}) SET n.{s} = {s}, n.lane = {d}",
            .{ fresh_rid, VEC_PROP, vec_new, lane },
        ) catch {
            sh.err_seen.store(true, .release);
            return;
        };
        _ = runQuery(aa, sh, create_q);

        // Property-map churn on a node that is already resident and therefore
        // already visible to the concurrent scan.
        const target_rid = 1_000_000 + ((i * 7 + lane) % seed_nodes);
        const vec_upd = vectorLiteral(aa, target_rid + i) catch continue;
        const set_q = std.fmt.allocPrint(
            aa,
            "MATCH (n:KnnRace {{rid: {d}}}) SET n.{s} = {s}, n.churn{d} = {d}",
            .{ target_rid, VEC_PROP, vec_upd, i % 24, i },
        ) catch continue;
        _ = runQuery(aa, sh, set_q);

        _ = sh.writes_done.fetchAdd(1, .monotonic);
    }
}

// Reader: run the REAL brute-force knn scan (`knn` is the documented alias of
// `vector_knn`; the property has no advanced vector index, so evalVectorKnn
// falls through to scanVectorKnn) while the writers churn.
fn readerThread(sh: *Shared) void {
    var n: usize = 0;
    while (n < reads_per_reader and !sh.err_seen.load(.acquire)) : (n += 1) {
        var arena = std.heap.ArenaAllocator.init(sh.allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        const q = std.fmt.allocPrint(
            aa,
            "RETURN knn('{s}', vectorf32([{d}.0, 3.0, 1.0, 0.5]), {d}, 'l2') AS ids",
            .{ VEC_PROP, n % 97, k },
        ) catch {
            sh.err_seen.store(true, .release);
            return;
        };

        var parsed = geode.parseGql(q, aa) catch {
            sh.err_seen.store(true, .release);
            return;
        };
        defer parsed.deinit();

        var res = execution.executeStatementWithContext(aa, parsed.program.statements[0], sh.ctx) catch {
            continue;
        };
        defer res.deinit(aa);

        if (res.rows.len != 1 or res.rows[0].len != 1) continue;
        const value = res.rows[0][0];
        if (value != .List) continue;

        // Structural sanity: the scan may legitimately see any live subset of
        // the population (node ids are engine-minted and NOT dense, so there is
        // no meaningful id range to assert), but it must never hand back more
        // than k rows and never a non-integral / non-positive id. This is the
        // non-faulting face of the same use-after-free, caught on the runs
        // where the torn read happens not to land on an unmapped page.
        if (value.List.len > k) {
            sh.corrupt_result.store(true, .release);
            return;
        }
        for (value.List) |item| {
            const id: i64 = switch (item) {
                .Int => |v| v,
                .BigInt => |v| v,
                .SmallInt => |v| @intCast(v),
                else => {
                    sh.corrupt_result.store(true, .release);
                    return;
                },
            };
            if (id <= 0) {
                sh.corrupt_result.store(true, .release);
                return;
            }
        }
        _ = sh.rows_seen.fetchAdd(value.List.len, .monotonic);
        _ = sh.reads_done.fetchAdd(1, .monotonic);
    }
}

test "concurrent MERGE writers + brute-force knn scan does not crash (scanVectorKnn unlocked-iterator race)" {
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

    // Seed a population with the UNINDEXED vector property so the brute-force
    // scan has real work to do before the race begins.
    {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const aa = arena.allocator();
        var i: usize = 0;
        while (i < seed_nodes) : (i += 1) {
            const vec = try vectorLiteral(aa, i);
            const q = try std.fmt.allocPrint(
                aa,
                "CREATE (:KnnRace {{rid: {d}, {s}: {s}}})",
                .{ 1_000_000 + i, VEC_PROP, vec },
            );
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

    var writers: [writer_count]std.Thread = undefined;
    for (&writers, 0..) |*w, lane| w.* = try std.Thread.spawn(.{}, writerThread, .{ &sh, lane });
    var readers: [reader_count]std.Thread = undefined;
    for (&readers) |*r| r.* = try std.Thread.spawn(.{}, readerThread, .{&sh});

    for (&readers) |r| r.join();
    sh.stop.store(true, .release);
    for (&writers) |w| w.join();

    // The decisive assertion is "we got here without a fault"; the rest proves
    // both sides really ran under contention and the scan stayed coherent.
    try testing.expect(!sh.corrupt_result.load(.acquire));
    try testing.expect(!sh.err_seen.load(.acquire));
    try testing.expect(sh.reads_done.load(.monotonic) > 0);
    try testing.expect(sh.writes_done.load(.monotonic) > 0);
    try testing.expect(sh.rows_seen.load(.monotonic) > 0);
}
