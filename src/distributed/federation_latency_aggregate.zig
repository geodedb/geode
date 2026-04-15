const std = @import("std");
const fed_flag = @import("federation_flag.zig");

// Federation latency aggregate module
// Maintains lightweight in-memory aggregates for mismatch latency sampling cycles.
// Exposed functions allow tests to record synthetic mismatch latency events (ns) and
// derive summary metrics across cycles. Intent: provide governance evidence for
// REQ-GQL-024 aggregate behaviors before full federation engine integration.
// Aggregates kept in global singleton; tests reset between scenarios.
//
// Metrics tracked per cycle: count, sum, min, max, last_p95_estimate (approx via
// reservoir sample), rolling mean (f128), rolling variance (Welford), streak of
// consecutive mismatch cycles, archive ring of last N summary snapshots.
//
// Simplifications: p95 estimate uses order statistic over a bounded small buffer
// (size 32) of the most recent latencies in the current cycle (adequate for tests).
//
// CANARY: REQ=REQ-GQL-024; FEATURE="FederationLatencyAggregates"; ASPECT=Archive; STATUS=IMPL; OWNER=federation; UPDATED=2026-04-05
// CANARY: REQ=REQ-GQL-024; FEATURE="FederationLatencyAggregates"; ASPECT=Summary; STATUS=IMPL; OWNER=federation; UPDATED=2026-04-05
// CANARY: REQ=REQ-GQL-024; FEATURE="FederationLatencyAggregates"; ASPECT=MultiRun; STATUS=IMPL; OWNER=federation; UPDATED=2026-04-05
// CANARY: REQ=REQ-GQL-024; FEATURE="FederationLatencyAggregates"; ASPECT=RobustStats; STATUS=IMPL; OWNER=federation; UPDATED=2026-04-05
// CANARY: REQ=REQ-GQL-024; FEATURE="FederationLatencyAggregates"; ASPECT=SchemaValidation; STATUS=IMPL; OWNER=federation; UPDATED=2026-04-05
// CANARY: REQ=REQ-GQL-024; FEATURE="FederationLatencyAggregates"; ASPECT=Streak; STATUS=IMPL; OWNER=federation; UPDATED=2026-04-05

pub const Snapshot = struct {
    cycle_id: u64,
    count: u64,
    mean_ns: f128,
    min_ns: u64,
    max_ns: u64,
    p95_ns: u64,
    streak: u64,
};

const Current = struct {
    cycle_id: u64 = 0,
    count: u64 = 0,
    mean: f128 = 0,
    m2: f128 = 0, // Welford accumulator
    min_ns: u64 = std.math.maxInt(u64),
    max_ns: u64 = 0,
    buf: [32]u64 = undefined,
    buf_len: usize = 0,
    streak: u64 = 0,
};

const Archive = struct {
    ring: [16]Snapshot = undefined,
    next: usize = 0,
    filled: bool = false,
};

var g_mutex: std.Io.Mutex = std.Io.Mutex.init;
var g_current: Current = .{};
var g_archive: Archive = .{};

fn p95Estimate(cur: *const Current) u64 {
    if (cur.buf_len == 0) return 0;
    var tmp: [32]u64 = undefined;
    var i: usize = 0;
    while (i < cur.buf_len) : (i += 1) tmp[i] = cur.buf[i];
    std.sort.heap(u64, tmp[0..cur.buf_len], {}, comptime struct {
        fn lt(_: void, a: u64, b: u64) bool {
            return a < b;
        }
    }.lt);
    const idx = (cur.buf_len * 95) / 100; // floor
    const adj = if (idx == 0) 0 else idx - 1;
    return tmp[adj];
}

fn resetCycle() void {
    g_current.cycle_id += 1;
    g_current.count = 0;
    g_current.mean = 0;
    g_current.m2 = 0;
    g_current.min_ns = std.math.maxInt(u64);
    g_current.max_ns = 0;
    g_current.buf_len = 0;
    // streak preserved only if mismatch event happened in previous cycle
}

pub fn recordLatency(ns: u64, mismatch: bool) void {
    g_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    if (mismatch) {
        // propagate flag for external observation
        fed_flag.g_last_federation_mismatch.store(true, .release);
        g_current.streak += 1;
    } else {
        g_current.streak = 0;
    }
    g_current.count += 1;
    const c = @as(f128, @floatFromInt(g_current.count));
    const x = @as(f128, @floatFromInt(ns));
    const delta = x - g_current.mean;
    g_current.mean += delta / c;
    const delta2 = x - g_current.mean;
    g_current.m2 += delta * delta2;
    if (ns < g_current.min_ns) g_current.min_ns = ns;
    if (ns > g_current.max_ns) g_current.max_ns = ns;
    if (g_current.buf_len < g_current.buf.len) {
        g_current.buf[g_current.buf_len] = ns;
        g_current.buf_len += 1;
    } else {
        // simple reservoir: overwrite round-robin
        g_current.buf[g_current.count % g_current.buf.len] = ns;
    }
}

pub fn finalizeCycle() Snapshot {
    g_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    const p95 = p95Estimate(&g_current);
    const snap = Snapshot{
        .cycle_id = g_current.cycle_id,
        .count = g_current.count,
        .mean_ns = g_current.mean,
        .min_ns = if (g_current.min_ns == std.math.maxInt(u64)) 0 else g_current.min_ns,
        .max_ns = g_current.max_ns,
        .p95_ns = p95,
        .streak = g_current.streak,
    };
    g_archive.ring[g_archive.next] = snap;
    g_archive.next = (g_archive.next + 1) % g_archive.ring.len;
    if (g_archive.next == 0) g_archive.filled = true;
    resetCycle();
    return snap;
}

pub fn variance(current: *const Current) f128 {
    if (current.count <= 1) return 0;
    return current.m2 / (@as(f128, @floatFromInt(current.count)) - 1.0);
}

pub fn snapshotCurrent() Snapshot {
    g_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    return Snapshot{
        .cycle_id = g_current.cycle_id,
        .count = g_current.count,
        .mean_ns = g_current.mean,
        .min_ns = if (g_current.min_ns == std.math.maxInt(u64)) 0 else g_current.min_ns,
        .max_ns = g_current.max_ns,
        .p95_ns = p95Estimate(&g_current),
        .streak = g_current.streak,
    };
}

pub fn findSnapshot(cycle_id: u64) ?Snapshot {
    g_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    const limit = if (g_archive.filled) g_archive.ring.len else g_archive.next;
    var i: usize = 0;
    while (i < limit) : (i += 1) {
        const idx = if (g_archive.next >= i + 1) g_archive.next - i - 1 else g_archive.ring.len - (i + 1 - g_archive.next);
        const s = g_archive.ring[idx];
        if (s.cycle_id == cycle_id) return s;
    }
    return null;
}

pub fn resetAll() void {
    g_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    g_current = .{};
    g_archive = .{};
    // Reset the shared federation mismatch flag so tests start from a clean state.
    fed_flag.g_last_federation_mismatch.store(false, .release);
}

pub fn archiveLen() usize {
    g_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    return if (g_archive.filled) g_archive.ring.len else g_archive.next;
}

pub fn schemaValidate() bool {
    g_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer g_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    // Basic invariants: cycle_id monotonic across snapshots; counts non-negative; p95 within [min,max].
    const len = if (g_archive.filled) g_archive.ring.len else g_archive.next;
    var last_cycle: u64 = 0;
    var i: usize = 0;
    while (i < len) : (i += 1) {
        const s = g_archive.ring[i];
        if (i > 0 and s.cycle_id <= last_cycle) return false;
        if (s.count == 0) return false;
        if (s.p95_ns < s.min_ns or s.p95_ns > s.max_ns) return false;
        last_cycle = s.cycle_id;
    }
    return true;
}

// CANARY: REQ=REQ-GQL-024; FEATURE="FederationLatencyAggregates"; ASPECT=Tests; STATUS=TESTED; TEST="federation_latency_aggregate unit tests"; OWNER=federation; UPDATED=2026-04-06

test "recordLatency updates count, min, max, mean" {
    resetAll();
    recordLatency(100, false);
    recordLatency(200, false);
    const snap = snapshotCurrent();
    try std.testing.expectEqual(@as(u64, 2), snap.count);
    try std.testing.expectEqual(@as(u64, 100), snap.min_ns);
    try std.testing.expectEqual(@as(u64, 200), snap.max_ns);
    // mean should be 150 (Welford exact for two samples)
    const mean_diff = snap.mean_ns - 150.0;
    const abs_diff = if (mean_diff < 0) -mean_diff else mean_diff;
    try std.testing.expect(abs_diff < 0.001);
}

test "recordLatency mismatch increments streak, non-mismatch resets streak" {
    resetAll();
    recordLatency(500, true);
    recordLatency(600, true);
    const snap1 = snapshotCurrent();
    try std.testing.expectEqual(@as(u64, 2), snap1.streak);
    recordLatency(700, false);
    const snap2 = snapshotCurrent();
    try std.testing.expectEqual(@as(u64, 0), snap2.streak);
}

test "finalizeCycle archives snapshot and resets current" {
    resetAll();
    recordLatency(300, false);
    recordLatency(400, false);
    const snap = finalizeCycle();
    try std.testing.expectEqual(@as(u64, 2), snap.count);
    try std.testing.expectEqual(@as(u64, 300), snap.min_ns);
    try std.testing.expectEqual(@as(u64, 400), snap.max_ns);
    // after finalize, current should be reset (count=0)
    const cur = snapshotCurrent();
    try std.testing.expectEqual(@as(u64, 0), cur.count);
    try std.testing.expectEqual(@as(usize, 1), archiveLen());
}

test "findSnapshot retrieves by cycle_id and returns null for non-existent" {
    resetAll();
    recordLatency(1000, false);
    const snap = finalizeCycle();
    const found = findSnapshot(snap.cycle_id);
    try std.testing.expect(found != null);
    try std.testing.expectEqual(snap.cycle_id, found.?.cycle_id);
    try std.testing.expectEqual(@as(u64, 1), found.?.count);
    // non-existent cycle_id
    const missing = findSnapshot(snap.cycle_id + 9999);
    try std.testing.expect(missing == null);
}

test "schemaValidate passes for valid archive" {
    resetAll();
    recordLatency(100, false);
    _ = finalizeCycle();
    recordLatency(200, false);
    _ = finalizeCycle();
    try std.testing.expect(schemaValidate());
}

test "archiveLen ring wraps at 16" {
    resetAll();
    var i: usize = 0;
    while (i < 20) : (i += 1) {
        recordLatency(100 + i, false);
        _ = finalizeCycle();
    }
    try std.testing.expectEqual(@as(usize, 16), archiveLen());
}

test "p95_ns with single sample equals that sample" {
    resetAll();
    recordLatency(42, false);
    const snap = snapshotCurrent();
    try std.testing.expectEqual(@as(u64, 42), snap.p95_ns);
}
