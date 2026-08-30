// CANARY: REQ=REQ-PERF-MATCH-SET-LABEL-SCAN; FEATURE="MatchSetLabelIndexedScan"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_match_set_label_scan_regression.zig:1; OWNER=engine; UPDATED=2026-04-11
//
// Regression tests for MATCH + SET/REMOVE on single-pattern simple-node queries.
//
// Context: executeMatchQueryImpl's "simple node pattern" branch previously
// iterated the entire `store.nodes` hash map on every MATCH, ignoring the
// label index that executeMultiNodeMatch already used. This turned
// MATCH (n:Label {prop: v}) SET ... into an O(total-live-nodes) operation
// even though the target posting list was tiny.
//
// Symptom: the geodetestlab txn-complex-operations-chunked spec (400 MATCH+SET
// statements against ~300 ComplexOps nodes, preceded by 11 other chunked tests
// that created ~6700 nodes with unrelated labels) took 200+ seconds and
// timed out at the harness's 120s budget. Fresh servers ran the same query
// in ~13 seconds.
//
// These tests exercise the scale-invariance property we want preserved:
// a MATCH + SET against a small label posting list must not get slower
// as unrelated nodes accumulate in the store. We assert two things:
//
//   1. Wall-clock: MATCH + SET against a ~10 Target node posting list
//      completes in well under a threshold even when 5k unrelated nodes
//      exist. The threshold is generous enough not to flake in Debug
//      builds, but tight enough to catch a return to the full-scan path
//      (which was ~600 ms per SET at 6k nodes).
//
//   2. Scaling ratio: 10x more unrelated nodes must not make the query
//      10x slower. The label-indexed path is O(posting list), so adding
//      unrelated nodes changes nothing. If a regression reintroduces the
//      full-scan path, this ratio blows out immediately.
//
// Both tests drive the execution layer directly (not via QUIC) so there
// is no transport overhead and any timing signal comes from the MATCH
// candidate loop itself.

const std = @import("std");

// Zig 0.16 compat: Io.Dir.realpathAlloc removed. Build an absolute path by joining cwd with the relative tmp sub_path.
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

// Zig 0.16 compat helpers for test code
fn compat_milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
fn compat_microTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    }
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1_000);
}
fn compat_nanoTimestamp() i128 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.clock_gettime(.REALTIME, &ts);
    } else {
        _ = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
    }
    return @as(i128, ts.sec) * 1_000_000_000 + @as(i128, ts.nsec);
}
fn compat_sleep(ns: u64) void {
    var req: std.posix.timespec = .{ .sec = 0, .nsec = @intCast(ns) };
    var rem: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.nanosleep(@ptrCast(&req), @ptrCast(&rem));
    } else {
        _ = std.c.nanosleep(&req, &rem);
    }
}

const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;

// Harness uses an internal arena allocator for query execution so that
// pre-existing (non-regression-related) env allocation lifecycles in
// executeMatchQueryImpl do not surface as leaks in std.testing.allocator.
// We keep the outer `allocator` for harness bookkeeping (tmpdir path, etc.)
// and for seeding the global store, where leaks would indicate a real bug.
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
        // Route query allocations through the harness arena. This avoids
        // tangling the pre-existing env_names/env_values lifecycle in
        // executeMatchQueryImpl's simple-node path with std.testing.allocator
        // leak detection. The regression tests here are about wall-clock
        // scaling, not about fixing that unrelated lifecycle.
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }
};

/// Seed the global store with `n_noise` nodes that have unrelated labels,
/// then `n_target` nodes tagged as :Target with a dense `tid` property.
/// Caller owns the target node ids (returned slice) and must free it.
fn seedStore(allocator: std.mem.Allocator, n_noise: usize, n_target: usize) ![]u64 {
    const store = graph_store.getGlobalStore(allocator);

    // Noise nodes mimic the accumulated state from prior geodetestlab
    // transaction tests: a mix of labels with short string properties.
    const noise_labels = [_][]const u8{
        "NoiseA", "NoiseB", "NoiseC", "NoiseD", "NoiseE",
    };

    var i: usize = 0;
    while (i < n_noise) : (i += 1) {
        const lbl_idx = i % noise_labels.len;
        const label_slice = [_][]const u8{noise_labels[lbl_idx]};
        const nid = try store.createNode(&label_slice);
        try store.setNodeProperty(nid, "seq", .{ .Int = @intCast(i) });
        try store.setNodeProperty(nid, "status", .{ .String = "noise" });
    }

    const target_ids = try allocator.alloc(u64, n_target);
    var t: usize = 0;
    while (t < n_target) : (t += 1) {
        const label_slice = [_][]const u8{"Target"};
        target_ids[t] = try store.createNode(&label_slice);
        try store.setNodeProperty(target_ids[t], "tid", .{ .Int = @intCast(t) });
        try store.setNodeProperty(target_ids[t], "value", .{ .Int = 0 });
    }
    return target_ids;
}

/// Run `n_iters` MATCH (:Target {tid: i}) SET n.value = i*10 statements
/// and return the total wall-clock in nanoseconds.
fn runMatchSetLoop(h: *Harness, n_iters: usize) !u64 {
    const start = compat_nanoTimestamp();
    var i: usize = 0;
    while (i < n_iters) : (i += 1) {
        const tid_literal = i % 10; // reuse the first 10 Targets
        var buf: [160]u8 = undefined;
        const q = try std.fmt.bufPrint(&buf, "MATCH (n:Target {{tid: {d}}}) SET n.value = {d}", .{ tid_literal, i });
        var res = try h.runQuery(q);
        res.deinit(h.arena.allocator());
    }
    const end = compat_nanoTimestamp();
    return @intCast(end - start);
}

// Core regression: with many noise nodes but only 10 :Target nodes, a burst
// of MATCH + SET queries must complete in a budget that is only sane if the
// label index is actually used to enumerate candidates.
test "REGRESSION: MATCH+SET stays fast with noise nodes (label-indexed scan)" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    const target_ids = try seedStore(allocator, 5_000, 10);
    defer allocator.free(target_ids);

    const elapsed_ns = try runMatchSetLoop(&h, 50);
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_ms;

    // Budget: Debug builds are ~10x slower than Release. Pre-fix, this loop
    // took 30+ seconds at 5000 noise nodes. With the label-indexed path, it
    // runs in ~100 ms even in Debug. 5000 ms is an order-of-magnitude guard
    // rail that catches regressions while tolerating Debug slop and shared
    // CI hosts.
    if (elapsed_ms > 5_000.0) {
        std.debug.print(
            "MATCH+SET regression: 50 iterations took {d:.1} ms with 5000 noise nodes; " ++
                "label-indexed path is likely broken (full-scan fallback suspected)\n",
            .{elapsed_ms},
        );
        return error.MatchSetRegressionDetected;
    }

    // Sanity-check: the writes actually landed. Re-read one of the targets.
    var res = try h.runQuery("MATCH (n:Target {tid: 0}) RETURN n.value");
    defer res.deinit(h.arena.allocator());
    try std.testing.expectEqual(@as(usize, 1), res.rows.len);
}

// Scale-invariance: doubling/tenfolding the noise population must not cause
// a proportional slowdown. The label index keeps MATCH candidate enumeration
// dependent on the :Target posting list (tiny) instead of the full store.
test "REGRESSION: MATCH+SET scales sub-linearly in noise population" {
    const allocator = std.testing.allocator;

    const iters: usize = 30;

    // Small run: 500 noise nodes.
    const small_elapsed_ns = blk: {
        var h = try Harness.init(allocator);
        defer h.deinit();
        const ids = try seedStore(allocator, 500, 10);
        allocator.free(ids);
        break :blk try runMatchSetLoop(&h, iters);
    };

    // Large run: 5000 noise nodes (10x).
    const large_elapsed_ns = blk: {
        var h = try Harness.init(allocator);
        defer h.deinit();
        const ids = try seedStore(allocator, 5_000, 10);
        allocator.free(ids);
        break :blk try runMatchSetLoop(&h, iters);
    };

    const small_ms = @as(f64, @floatFromInt(small_elapsed_ns)) / std.time.ns_per_ms;
    const large_ms = @as(f64, @floatFromInt(large_elapsed_ns)) / std.time.ns_per_ms;

    // We expect large_ms ≈ small_ms. Allow up to 5x slack to absorb measurement
    // noise on busy CI hosts (the pre-fix behaviour showed ~10x slowdown,
    // matching the 10x noise increase, so 5x still distinguishes the cases).
    // Guard against division by zero on extremely fast runs.
    const baseline_ms = @max(small_ms, 1.0);
    const ratio = large_ms / baseline_ms;
    // Timing-ratio assertion: skip on contended runners (CI, and the local
    // pre-push gate's 4-shard oversubscription, which exports CI=1 exactly so
    // perf-ratio tests opt out) — same idiom as
    // test_edge_popular_parent_throughput.zig. The 5000ms absolute guard rail
    // in the previous test still catches a real full-scan fallback there.
    if (std.c.getenv("CI") == null and std.c.getenv("GITLAB_CI") == null) {
        if (ratio > 5.0) {
            std.debug.print(
                "MATCH+SET scale-invariance regression: 500 nodes={d:.1}ms 5000 nodes={d:.1}ms ratio={d:.2} " ++
                    "(expected <=5x; linear full-scan fallback suspected)\n",
                .{ small_ms, large_ms, ratio },
            );
            return error.MatchSetScalingRegression;
        }
    }
}

// Parallel regression for MATCH + REMOVE which previously shared the same
// full-scan path. Verify it also benefits from the label-indexed candidate
// enumeration.
test "REGRESSION: MATCH+REMOVE stays fast with noise nodes (label-indexed scan)" {
    const allocator = std.testing.allocator;
    var h = try Harness.init(allocator);
    defer h.deinit();

    const target_ids = try seedStore(allocator, 5_000, 10);
    defer allocator.free(target_ids);

    const start = compat_nanoTimestamp();
    var i: usize = 0;
    while (i < 50) : (i += 1) {
        const tid_literal = i % 10;
        var buf: [160]u8 = undefined;
        const q = try std.fmt.bufPrint(&buf, "MATCH (n:Target {{tid: {d}}}) REMOVE n.value", .{tid_literal});
        var res = try h.runQuery(q);
        res.deinit(h.arena.allocator());
    }
    const elapsed_ns = compat_nanoTimestamp() - start;
    const elapsed_ms = @as(f64, @floatFromInt(elapsed_ns)) / std.time.ns_per_ms;

    if (elapsed_ms > 5_000.0) {
        std.debug.print(
            "MATCH+REMOVE regression: 50 iterations took {d:.1} ms with 5000 noise nodes\n",
            .{elapsed_ms},
        );
        return error.MatchRemoveRegressionDetected;
    }
}
