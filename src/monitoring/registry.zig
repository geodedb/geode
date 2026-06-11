// CANARY: REQ=REQ-OTEL-LEGACY-DEPRECATED-001; FEATURE="OTel Instrumentation"; ASPECT=Migration; STATUS=EXEMPT; TEST=tests/test_otel_facade_smoke.zig; OWNER=monitoring; UPDATED=2026-04-28
//
// LEGACY SHIM — DEPRECATED. The four metric fields previously exposed
// by this file (query_latency_ms, active_transactions, pathcache_hits,
// pathcache_misses) are now produced by `src/monitoring/otel_metrics.zig`
// per the OTel instrumentation plan. The shim is kept compiling so any
// stale callers don't break the build, but new code MUST import
// otel_metrics directly. Scheduled for deletion after the OTel surface
// is exercised in production. See docs/otel-updates.md §5 for the
// migration table.

const std = @import("std");
pub const MetricKind = enum { counter, gauge, histogram };

pub const Counter = struct {
    value: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    pub fn inc(self: *Counter, delta: u64) void {
        _ = self.value.fetchAdd(delta, .seq_cst);
    }
    pub fn get(self: *Counter) u64 {
        return self.value.load(.seq_cst);
    }
};

pub const Gauge = struct {
    value: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    pub fn set(self: *Gauge, v: i64) void {
        self.value.store(v, .seq_cst);
    }
    pub fn add(self: *Gauge, delta: i64) void {
        _ = self.value.fetchAdd(delta, .seq_cst);
    }
    pub fn get(self: *Gauge) i64 {
        return self.value.load(.seq_cst);
    }
};

pub const Histogram = struct {
    // Fixed buckets (ms): 1,5,10,25,50,100,250,500,1000,2500,5000, +Inf
    buckets: [12]std.atomic.Value(u64) = [_]std.atomic.Value(u64){std.atomic.Value(u64).init(0)} ** 12,
    // GAP-0874: cumulative sum of observed values (ms), Prometheus `_sum`
    // convention. Atomic fetch-add keeps the hot path lock-free, matching
    // the bucket counters.
    sum_ms: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    pub fn observe(self: *Histogram, value_ms: u64) void {
        const edges = [_]u64{ 1, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000 };
        var idx: usize = edges.len; // default +Inf
        var i: usize = 0;
        while (i < edges.len) : (i += 1) {
            if (value_ms <= edges[i]) {
                idx = i;
                break;
            }
        }
        _ = self.buckets[idx].fetchAdd(1, .seq_cst);
        _ = self.sum_ms.fetchAdd(value_ms, .seq_cst);
    }
    pub fn sum(self: *Histogram) u64 {
        return self.sum_ms.load(.seq_cst);
    }
    pub fn snapshot(self: *Histogram, allocator: std.mem.Allocator) ![]u64 {
        var out = try allocator.alloc(u64, self.buckets.len);
        for (self.buckets, 0..) |b, j| out[j] = b.load(.seq_cst);
        return out;
    }
};

pub const Registry = struct {
    query_latency_ms: Histogram = .{},
    active_transactions: Gauge = .{},
    pathcache_hits: Counter = .{},
    pathcache_misses: Counter = .{},

    pub fn init() Registry {
        return .{};
    }

    pub fn exportPrometheus(self: *Registry, w: anytype) !void {
        try w.print("# HELP geode_query_latency_ms Query latency histogram in ms\n", .{});
        try w.print("# TYPE geode_query_latency_ms histogram\n", .{});
        const edges = [_]u64{ 1, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000 };
        var cumulative: u64 = 0;
        var le_buf: [32]u8 = undefined;
        var i: usize = 0;
        while (i < edges.len + 1) : (i += 1) {
            const le_val: []const u8 = if (i < edges.len)
                std.fmt.bufPrint(&le_buf, "{d}", .{edges[i]}) catch unreachable
            else
                "+Inf";
            cumulative += self.query_latency_ms.buckets[i].load(.seq_cst);
            try w.print("geode_query_latency_ms_bucket{{le=\"{s}\"}} {d}\n", .{ le_val, cumulative });
        }
        try w.print("geode_query_latency_ms_count {d}\n", .{cumulative});
        // GAP-0874: real cumulative sum (was hard-coded 0).
        try w.print("geode_query_latency_ms_sum {d}\n", .{self.query_latency_ms.sum()});
        try w.print("# TYPE geode_active_transactions gauge\ngeode_active_transactions {d}\n", .{self.active_transactions.get()});
        const hits = self.pathcache_hits.get();
        const misses = self.pathcache_misses.get();
        try w.print("# TYPE geode_pathcache_requests counter\ngeode_pathcache_hits {d}\ngeode_pathcache_misses {d}\n", .{ hits, misses });
    }
};

// Global registry accessor (feature gated lazy singleton)
var global_registry: ?Registry = null;

pub fn global() *Registry {
    // Monitoring always enabled
    if (global_registry == null) global_registry = Registry.init();
    return &global_registry.?;
}
