const std = @import("std");
const bo = @import("build_options");

pub const MetricKind = enum { counter, gauge, histogram };

pub const Counter = struct {
    value: std.atomic.Value(u64) = std.atomic.Value(u64).init(0),
    pub fn inc(self: *Counter, delta: u64) void {
        _ = self.value.fetchAdd(delta, .SeqCst);
    }
    pub fn get(self: *Counter) u64 {
        return self.value.load(.SeqCst);
    }
};

pub const Gauge = struct {
    value: std.atomic.Value(i64) = std.atomic.Value(i64).init(0),
    pub fn set(self: *Gauge, v: i64) void {
        self.value.store(v, .SeqCst);
    }
    pub fn add(self: *Gauge, delta: i64) void {
        _ = self.value.fetchAdd(delta, .SeqCst);
    }
    pub fn get(self: *Gauge) i64 {
        return self.value.load(.SeqCst);
    }
};

pub const Histogram = struct {
    // Fixed buckets (ms): 1,5,10,25,50,100,250,500,1000,2500,5000, +Inf
    buckets: [12]std.atomic.Value(u64) = [_]std.atomic.Value(u64){std.atomic.Value(u64).init(0)} ** 12,
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
        _ = self.buckets[idx].fetchAdd(1, .SeqCst);
    }
    pub fn snapshot(self: *Histogram, allocator: std.mem.Allocator) ![]u64 {
        var out = try allocator.alloc(u64, self.buckets.len);
        for (self.buckets, 0..) |b, j| out[j] = b.load(.SeqCst);
        return out;
    }
};

pub const Registry = struct {
    query_latency_ms: Histogram = .{},
    active_transactions: Gauge = .{},
    wal_bytes_written: Counter = .{},
    pathcache_hits: Counter = .{},
    pathcache_misses: Counter = .{},

    pub fn init() Registry {
        return .{};
    }

    pub fn exportPrometheus(self: *Registry, w: anytype) !void {
        if (!bo.feature_monitoring) return; // feature gated
        try w.print("# HELP geode_query_latency_ms Query latency histogram in ms\n", .{});
        try w.print("# TYPE geode_query_latency_ms histogram\n", .{});
        const edges = [_]u64{ 1, 5, 10, 25, 50, 100, 250, 500, 1000, 2500, 5000 };
        var cumulative: u64 = 0;
        var i: usize = 0;
        while (i < edges.len + 1) : (i += 1) {
            const le_val: []const u8 = if (i < edges.len) blk: {
                var buf: [32]u8 = undefined;
                const len = std.fmt.formatIntBuf(&buf, edges[i], 10, .lower, .{});
                break :blk buf[0..len];
            } else "+Inf";
            cumulative += self.query_latency_ms.buckets[i].load(.SeqCst);
            try w.print("geode_query_latency_ms_bucket{{le=\"{s}\"}} {d}\n", .{ le_val, cumulative });
        }
        try w.print("geode_query_latency_ms_count {d}\n", .{cumulative});
        const sum_placeholder: u64 = 0; // not tracking sum yet
        try w.print("geode_query_latency_ms_sum {d}\n", .{sum_placeholder});
        try w.print("# TYPE geode_active_transactions gauge\ngeode_active_transactions {d}\n", .{self.active_transactions.get()});
        try w.print("# TYPE geode_wal_bytes_written counter\ngeode_wal_bytes_written {d}\n", .{self.wal_bytes_written.get()});
        const hits = self.pathcache_hits.get();
        const misses = self.pathcache_misses.get();
        try w.print("# TYPE geode_pathcache_requests counter\ngeode_pathcache_hits {d}\ngeode_pathcache_misses {d}\n", .{ hits, misses });
    }
};

// Global registry accessor (feature gated lazy singleton)
var global_registry: ?Registry = null;

pub fn global() *Registry {
    if (!bo.feature_monitoring) @panic("Monitoring feature disabled (build with -Dfeature-monitoring=true)");
    if (global_registry == null) global_registry = Registry.init();
    return &global_registry.?;
}
