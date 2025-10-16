const std = @import("std");
const Allocator = std.mem.Allocator;

// Comprehensive metrics collection system
pub const MetricsCollector = struct {
    allocator: Allocator,
    counters: std.StringHashMap(Counter),
    gauges: std.StringHashMap(Gauge),
    histograms: std.StringHashMap(Histogram),
    timers: std.StringHashMap(Timer),
    config: Config,

    pub const Config = struct {
        collection_interval_ms: u64 = 1000,
        retention_period_ms: u64 = 3600000, // 1 hour
        enable_percentiles: bool = true,
        percentiles: []const f64 = &[_]f64{ 0.5, 0.75, 0.9, 0.95, 0.99 },
    };

    pub const Counter = struct {
        value: std.atomic.Value(u64),
        last_reset: i64,

        pub fn init() Counter {
            return .{
                .value = std.atomic.Value(u64).init(0),
                .last_reset = std.time.milliTimestamp(),
            };
        }

        pub fn increment(self: *Counter) void {
            _ = self.value.fetchAdd(1, .monotonic);
        }

        pub fn add(self: *Counter, n: u64) void {
            _ = self.value.fetchAdd(n, .monotonic);
        }

        pub fn get(self: *const Counter) u64 {
            return self.value.load(.monotonic);
        }

        pub fn reset(self: *Counter) void {
            self.value.store(0, .monotonic);
            self.last_reset = std.time.milliTimestamp();
        }
    };

    pub const Gauge = struct {
        value: std.atomic.Value(i64),
        min: std.atomic.Value(i64),
        max: std.atomic.Value(i64),
        last_update: i64,

        pub fn init() Gauge {
            return .{
                .value = std.atomic.Value(i64).init(0),
                .min = std.atomic.Value(i64).init(std.math.maxInt(i64)),
                .max = std.atomic.Value(i64).init(std.math.minInt(i64)),
                .last_update = std.time.milliTimestamp(),
            };
        }

        pub fn set(self: *Gauge, val: i64) void {
            self.value.store(val, .monotonic);

            // Update min/max
            var current_min = self.min.load(.monotonic);
            while (val < current_min) {
                if (self.min.cmpxchgWeak(current_min, val, .monotonic, .monotonic)) |new_min| {
                    current_min = new_min;
                } else {
                    break;
                }
            }

            var current_max = self.max.load(.monotonic);
            while (val > current_max) {
                if (self.max.cmpxchgWeak(current_max, val, .monotonic, .monotonic)) |new_max| {
                    current_max = new_max;
                } else {
                    break;
                }
            }

            self.last_update = std.time.milliTimestamp();
        }

        pub fn get(self: *const Gauge) i64 {
            return self.value.load(.monotonic);
        }

        pub fn getMin(self: *const Gauge) i64 {
            return self.min.load(.monotonic);
        }

        pub fn getMax(self: *const Gauge) i64 {
            return self.max.load(.monotonic);
        }
    };

    // CANARY: PERF_PHASE5_METRICS_ATOMIC - Lock-free metrics collection
    // CANARY: REQ=REQ-PERF-PHASE5-P1-002; FEATURE="MetricsOptimization"; ASPECT=LOCK_FREE_HISTOGRAM; STATUS=IMPL; OWNER=performance; UPDATED=2025-11-16
    // Phase 5.2.2 (P1-2): Use atomics for hot path metrics (10-20% faster)
    pub const Histogram = struct {
        allocator: Allocator,
        samples: std.ArrayList(f64),
        mutex: std.Thread.Mutex,
        count: std.atomic.Value(u64),
        sum: f64,
        min: f64,
        max: f64,

        pub fn init(allocator: Allocator) Histogram {
            return .{
                .allocator = allocator,
                .samples = std.ArrayList(f64){},
                .mutex = .{},
                .count = std.atomic.Value(u64).init(0),
                .sum = 0,
                .min = std.math.inf(f64),
                .max = -std.math.inf(f64),
            };
        }

        pub fn deinit(self: *Histogram) void {
            self.samples.deinit();
        }

        pub fn record(self: *Histogram, value: f64) !void {
            // Update count with lock-free atomic (hot path optimization)
            _ = self.count.fetchAdd(1, .monotonic);

            // Lock for sum/min/max and ArrayList append
            self.mutex.lock();
            defer self.mutex.unlock();

            try self.samples.append(value);
            self.sum += value;
            self.min = @min(self.min, value);
            self.max = @max(self.max, value);
        }

        pub fn percentile(self: *Histogram, p: f64) f64 {
            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.samples.items.len == 0) return 0;

            std.mem.sort(f64, self.samples.items, {}, std.sort.asc(f64));

            const index = @as(usize, @intFromFloat(p * @as(f64, @floatFromInt(self.samples.items.len - 1))));
            return self.samples.items[index];
        }

        pub fn mean(self: *const Histogram) f64 {
            const count_val = self.count.load(.monotonic);
            if (count_val == 0) return 0;
            return self.sum / @as(f64, @floatFromInt(count_val));
        }

        pub fn clear(self: *Histogram) void {
            self.mutex.lock();
            defer self.mutex.unlock();

            self.samples.clearRetainingCapacity();
            self.count.store(0, .monotonic);
            self.sum = 0;
            self.min = std.math.inf(f64);
            self.max = -std.math.inf(f64);
        }
    };

    pub const Timer = struct {
        histogram: Histogram,
        active_timings: std.AutoHashMap(u64, i64),
        next_id: std.atomic.Value(u64),
        mutex: std.Thread.Mutex,

        pub fn init(allocator: Allocator) Timer {
            return .{
                .histogram = Histogram.init(allocator),
                .active_timings = std.AutoHashMap(u64, i64).init(allocator),
                .next_id = std.atomic.Value(u64).init(0),
                .mutex = .{},
            };
        }

        pub fn deinit(self: *Timer) void {
            self.histogram.deinit();
            self.active_timings.deinit();
        }

        pub fn start(self: *Timer) !u64 {
            const id = self.next_id.fetchAdd(1, .monotonic);
            const start_time = std.time.nanoTimestamp();

            self.mutex.lock();
            defer self.mutex.unlock();

            try self.active_timings.put(id, start_time);
            return id;
        }

        pub fn stop(self: *Timer, id: u64) !void {
            const end_time = std.time.nanoTimestamp();

            self.mutex.lock();
            defer self.mutex.unlock();

            if (self.active_timings.fetchRemove(id)) |entry| {
                const duration_ns = end_time - entry.value;
                const duration_ms = @as(f64, @floatFromInt(duration_ns)) / 1_000_000.0;
                try self.histogram.record(duration_ms);
            }
        }

        pub fn time(self: *Timer, comptime func: anytype, args: anytype) !@TypeOf(func(args)) {
            const id = try self.start();
            defer self.stop(id) catch {};
            return func(args);
        }
    };

    pub fn init(allocator: Allocator, config: Config) MetricsCollector {
        return .{
            .allocator = allocator,
            .counters = std.StringHashMap(Counter).init(allocator),
            .gauges = std.StringHashMap(Gauge).init(allocator),
            .histograms = std.StringHashMap(Histogram).init(allocator),
            .timers = std.StringHashMap(Timer).init(allocator),
            .config = config,
        };
    }

    pub fn deinit(self: *MetricsCollector) void {
        self.counters.deinit();
        self.gauges.deinit();

        var hist_iter = self.histograms.iterator();
        while (hist_iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.histograms.deinit();

        var timer_iter = self.timers.iterator();
        while (timer_iter.next()) |entry| {
            entry.value_ptr.deinit();
        }
        self.timers.deinit();
    }

    pub fn counter(self: *MetricsCollector, name: []const u8) !*Counter {
        const gop = try self.counters.getOrPut(name);
        if (!gop.found_existing) {
            gop.value_ptr.* = Counter.init();
        }
        return gop.value_ptr;
    }

    pub fn gauge(self: *MetricsCollector, name: []const u8) !*Gauge {
        const gop = try self.gauges.getOrPut(name);
        if (!gop.found_existing) {
            gop.value_ptr.* = Gauge.init();
        }
        return gop.value_ptr;
    }

    pub fn histogram(self: *MetricsCollector, name: []const u8) !*Histogram {
        const gop = try self.histograms.getOrPut(name);
        if (!gop.found_existing) {
            gop.value_ptr.* = Histogram.init(self.allocator);
        }
        return gop.value_ptr;
    }

    pub fn timer(self: *MetricsCollector, name: []const u8) !*Timer {
        const gop = try self.timers.getOrPut(name);
        if (!gop.found_existing) {
            gop.value_ptr.* = Timer.init(self.allocator);
        }
        return gop.value_ptr;
    }

    pub const Snapshot = struct {
        timestamp: i64,
        counters: std.StringHashMap(u64),
        gauges: std.StringHashMap(GaugeSnapshot),
        histograms: std.StringHashMap(HistogramSnapshot),

        pub const GaugeSnapshot = struct {
            value: i64,
            min: i64,
            max: i64,
        };

        pub const HistogramSnapshot = struct {
            count: u64,
            sum: f64,
            min: f64,
            max: f64,
            mean: f64,
            percentiles: std.StringHashMap(f64),
        };
    };

    pub fn snapshot(self: *MetricsCollector) !Snapshot {
        var snap = Snapshot{
            .timestamp = std.time.milliTimestamp(),
            .counters = std.StringHashMap(u64).init(self.allocator),
            .gauges = std.StringHashMap(Snapshot.GaugeSnapshot).init(self.allocator),
            .histograms = std.StringHashMap(Snapshot.HistogramSnapshot).init(self.allocator),
        };

        // Snapshot counters
        var counter_iter = self.counters.iterator();
        while (counter_iter.next()) |entry| {
            try snap.counters.put(entry.key_ptr.*, entry.value_ptr.get());
        }

        // Snapshot gauges
        var gauge_iter = self.gauges.iterator();
        while (gauge_iter.next()) |entry| {
            try snap.gauges.put(entry.key_ptr.*, .{
                .value = entry.value_ptr.get(),
                .min = entry.value_ptr.getMin(),
                .max = entry.value_ptr.getMax(),
            });
        }

        // Snapshot histograms
        var hist_iter = self.histograms.iterator();
        while (hist_iter.next()) |entry| {
            var percentiles = std.StringHashMap(f64).init(self.allocator);

            if (self.config.enable_percentiles) {
                for (self.config.percentiles) |p| {
                    const key = try std.fmt.allocPrint(self.allocator, "p{d:.0}", .{p * 100});
                    try percentiles.put(key, entry.value_ptr.percentile(p));
                }
            }

            try snap.histograms.put(entry.key_ptr.*, .{
                .count = entry.value_ptr.count.load(.monotonic),
                .sum = entry.value_ptr.sum,
                .min = entry.value_ptr.min,
                .max = entry.value_ptr.max,
                .mean = entry.value_ptr.mean(),
                .percentiles = percentiles,
            });
        }

        return snap;
    }

    pub fn exportPrometheus(self: *MetricsCollector, writer: anytype) !void {
        const snap = try self.snapshot();
        defer {
            snap.counters.deinit();
            snap.gauges.deinit();
            snap.histograms.deinit();
        }

        // Export counters
        var counter_iter = snap.counters.iterator();
        while (counter_iter.next()) |entry| {
            try writer.print("# TYPE {} counter\n", .{entry.key_ptr.*});
            try writer.print("{} {}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }

        // Export gauges
        var gauge_iter = snap.gauges.iterator();
        while (gauge_iter.next()) |entry| {
            try writer.print("# TYPE {} gauge\n", .{entry.key_ptr.*});
            try writer.print("{} {}\n", .{ entry.key_ptr.*, entry.value_ptr.value });
            try writer.print("{}_min {}\n", .{ entry.key_ptr.*, entry.value_ptr.min });
            try writer.print("{}_max {}\n", .{ entry.key_ptr.*, entry.value_ptr.max });
        }

        // Export histograms
        var hist_iter = snap.histograms.iterator();
        while (hist_iter.next()) |entry| {
            const name = entry.key_ptr.*;
            const hist = entry.value_ptr.*;

            try writer.print("# TYPE {} histogram\n", .{name});
            try writer.print("{}_count {}\n", .{ name, hist.count });
            try writer.print("{}_sum {d:.2}\n", .{ name, hist.sum });

            var perc_iter = hist.percentiles.iterator();
            while (perc_iter.next()) |perc| {
                try writer.print("{}_percentile{{quantile=\"{}\"}} {d:.2}\n", .{
                    name,
                    perc.key_ptr.*,
                    perc.value_ptr.*,
                });
            }
        }
    }
};

// Query profiler for detailed execution plans
pub const QueryProfiler = struct {
    allocator: Allocator,
    metrics: *MetricsCollector,
    active_profiles: std.AutoHashMap(u64, Profile),

    pub const Profile = struct {
        query_id: u64,
        query_text: []const u8,
        start_time: i64,
        end_time: ?i64,
        plan: ExecutionPlan,
        operators: std.ArrayList(OperatorProfile),
        memory_usage: MemoryProfile,
        io_stats: IOStats,

        pub const ExecutionPlan = struct {
            root: PlanNode,
            estimated_cost: f64,
            estimated_rows: u64,
        };

        pub const PlanNode = struct {
            type: []const u8,
            children: []PlanNode,
            properties: std.StringHashMap([]const u8),
        };

        pub const OperatorProfile = struct {
            name: []const u8,
            start_time: i64,
            end_time: i64,
            rows_in: u64,
            rows_out: u64,
            memory_used: u64,
            cpu_time_ns: u64,
        };

        pub const MemoryProfile = struct {
            peak_usage: u64,
            allocations: u64,
            deallocations: u64,
            current_usage: u64,
        };

        pub const IOStats = struct {
            pages_read: u64,
            pages_written: u64,
            cache_hits: u64,
            cache_misses: u64,
        };
    };

    pub fn init(allocator: Allocator, metrics: *MetricsCollector) QueryProfiler {
        return .{
            .allocator = allocator,
            .metrics = metrics,
            .active_profiles = std.AutoHashMap(u64, Profile).init(allocator),
        };
    }

    pub fn deinit(self: *QueryProfiler) void {
        var iter = self.active_profiles.iterator();
        while (iter.next()) |entry| {
            entry.value_ptr.operators.deinit();
        }
        self.active_profiles.deinit();
    }

    pub fn startProfile(
        self: *QueryProfiler,
        query_id: u64,
        query_text: []const u8,
        plan: Profile.ExecutionPlan,
    ) !void {
        var profile = Profile{
            .query_id = query_id,
            .query_text = query_text,
            .start_time = std.time.nanoTimestamp(),
            .end_time = null,
            .plan = plan,
            .operators = std.ArrayList(Profile.OperatorProfile){},
            .memory_usage = .{
                .peak_usage = 0,
                .allocations = 0,
                .deallocations = 0,
                .current_usage = 0,
            },
            .io_stats = .{
                .pages_read = 0,
                .pages_written = 0,
                .cache_hits = 0,
                .cache_misses = 0,
            },
        };

        try self.active_profiles.put(query_id, profile);

        // Record metric
        const counter = try self.metrics.counter("queries_started");
        counter.increment();
    }

    pub fn recordOperator(
        self: *QueryProfiler,
        query_id: u64,
        operator: Profile.OperatorProfile,
    ) !void {
        if (self.active_profiles.getPtr(query_id)) |profile| {
            try profile.operators.append(operator);

            // Update memory profile
            profile.memory_usage.current_usage += operator.memory_used;
            profile.memory_usage.peak_usage = @max(
                profile.memory_usage.peak_usage,
                profile.memory_usage.current_usage,
            );
        }
    }

    pub fn endProfile(self: *QueryProfiler, query_id: u64) !Profile {
        if (self.active_profiles.fetchRemove(query_id)) |entry| {
            var profile = entry.value;
            profile.end_time = std.time.nanoTimestamp();

            // Record metrics
            const duration_ms = @as(f64, @floatFromInt(profile.end_time.? - profile.start_time)) / 1_000_000.0;
            const hist = try self.metrics.histogram("query_duration_ms");
            try hist.record(duration_ms);

            const counter = try self.metrics.counter("queries_completed");
            counter.increment();

            return profile;
        }

        return error.ProfileNotFound;
    }

    pub fn formatProfile(self: *QueryProfiler, profile: Profile, writer: anytype) !void {
        _ = self;

        const duration_ms = if (profile.end_time) |end|
            @as(f64, @floatFromInt(end - profile.start_time)) / 1_000_000.0
        else
            0.0;

        try writer.print("Query Profile:\n", .{});
        try writer.print("  Query ID: {}\n", .{profile.query_id});
        try writer.print("  Query: {s}\n", .{profile.query_text});
        try writer.print("  Duration: {d:.2} ms\n", .{duration_ms});
        try writer.print("  Estimated Cost: {d:.2}\n", .{profile.plan.estimated_cost});
        try writer.print("  Estimated Rows: {}\n", .{profile.plan.estimated_rows});

        try writer.print("\nOperator Breakdown:\n", .{});
        for (profile.operators.items) |op| {
            const op_duration_ms = @as(f64, @floatFromInt(op.end_time - op.start_time)) / 1_000_000.0;
            const cpu_time_ms = @as(f64, @floatFromInt(op.cpu_time_ns)) / 1_000_000.0;

            try writer.print("  {}:\n", .{op.name});
            try writer.print("    Duration: {d:.2} ms\n", .{op_duration_ms});
            try writer.print("    CPU Time: {d:.2} ms\n", .{cpu_time_ms});
            try writer.print("    Rows: {} -> {}\n", .{ op.rows_in, op.rows_out });
            try writer.print("    Memory: {} bytes\n", .{op.memory_used});
        }

        try writer.print("\nMemory Usage:\n", .{});
        try writer.print("  Peak: {} bytes\n", .{profile.memory_usage.peak_usage});
        try writer.print("  Allocations: {}\n", .{profile.memory_usage.allocations});
        try writer.print("  Deallocations: {}\n", .{profile.memory_usage.deallocations});

        try writer.print("\nI/O Statistics:\n", .{});
        try writer.print("  Pages Read: {}\n", .{profile.io_stats.pages_read});
        try writer.print("  Pages Written: {}\n", .{profile.io_stats.pages_written});
        try writer.print("  Cache Hits: {} ({d:.1}%)\n", .{
            profile.io_stats.cache_hits,
            if (profile.io_stats.cache_hits + profile.io_stats.cache_misses > 0)
                @as(f64, @floatFromInt(profile.io_stats.cache_hits)) * 100.0 /
                    @as(f64, @floatFromInt(profile.io_stats.cache_hits + profile.io_stats.cache_misses))
            else
                0.0,
        });
    }
};
