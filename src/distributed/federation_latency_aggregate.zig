const std = @import("std");
const fed_flag = @import("src/distributed/federation_flag.zig");

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
// CANARY: REQ=REQ-GQL-024; FEATURE="FederationLatencyAggregates"; ASPECT=Archive; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_FedLatencyArchive; OWNER=federation; UPDATED=2025-09-26
// CANARY: REQ=REQ-GQL-024; FEATURE="FederationLatencyAggregates"; ASPECT=Summary; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_FedLatencySummary; OWNER=federation; UPDATED=2025-09-26
// CANARY: REQ=REQ-GQL-024; FEATURE="FederationLatencyAggregates"; ASPECT=MultiRun; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_FedLatencyMultiRun; OWNER=federation; UPDATED=2025-09-26
// CANARY: REQ=REQ-GQL-024; FEATURE="FederationLatencyAggregates"; ASPECT=RobustStats; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_FedLatencyRobustStats; OWNER=federation; UPDATED=2025-09-26
// CANARY: REQ=REQ-GQL-024; FEATURE="FederationLatencyAggregates"; ASPECT=SchemaValidation; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_FedLatencySchemaValidation; OWNER=federation; UPDATED=2025-09-26
// CANARY: REQ=REQ-GQL-024; FEATURE="FederationLatencyAggregates"; ASPECT=Streak; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_024_FedLatencyStreak; OWNER=federation; UPDATED=2025-09-26

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
    if (mismatch) {
        // propagate flag for external observation
        fed_flag.g_last_federation_mismatch = true;
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
    g_current = .{};
    g_archive = .{};
}

pub fn archiveLen() usize {
    return if (g_archive.filled) g_archive.ring.len else g_archive.next;
}

pub fn schemaValidate() bool {
    // Basic invariants: cycle_id monotonic across snapshots; counts non-negative; p95 within [min,max].
    const len = archiveLen();
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
