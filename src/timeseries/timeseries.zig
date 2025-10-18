const std = @import("std");

/// Time-series data point
pub const Point = struct {
    ts: i64, // Unix timestamp in milliseconds
    value: i64, // Value at this timestamp
};

/// Floating point time-series point for advanced analytics
pub const PointF64 = struct { ts: i64, value: f64 };

/// Series identifier key
pub const SeriesKey = struct { device_id: i64, metric: []const u8 };

/// Time-series data structure
pub const Series = struct {
    key: SeriesKey,
    points: std.ArrayList(Point),

    /// Get the last value in the series
    pub fn lastValue(self: *const Series) ?Point {
        if (self.points.items.len == 0) return null;
        return self.points.items[self.points.items.len - 1];
    }

    /// Get value at specific timestamp (exact or interpolated)
    pub fn valueAt(self: *const Series, ts: i64) ?Point {
        const items = self.points.items;
        if (items.len == 0) return null;

        // Binary search for exact or closest point
        var left: usize = 0;
        var right: usize = items.len;

        while (left < right) {
            const mid = left + (right - left) / 2;
            if (items[mid].ts == ts) {
                return items[mid];
            } else if (items[mid].ts < ts) {
                left = mid + 1;
            } else {
                right = mid;
            }
        }

        // Return closest point before timestamp
        if (left > 0) return items[left - 1];
        return null;
    }
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    by_key: std.AutoHashMap(u128, *Series),

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{ .allocator = allocator, .by_key = std.AutoHashMap(u128, *Series).init(allocator) };
    }

    pub fn deinit(self: *Store) void {
        var it = self.by_key.valueIterator();
        while (it.next()) |sp| {
            const s = sp.*;
            s.points.deinit();
            self.allocator.free(s.key.metric);
            self.allocator.destroy(s);
        }
        self.by_key.deinit();
    }

    fn hashKey(_: *Store, k: SeriesKey) u128 {
        var h = std.hash.Wyhash.init(0);
        h.update(std.mem.asBytes(&k.device_id));
        h.update(k.metric);
        const x = h.final();
        var out: u128 = 0;
        out = (@as(u128, x) << 64) | @as(u128, x ^ 0x9e3779b97f4a7c15);
        return out;
    }

    fn getOrCreateSeries(self: *Store, key: SeriesKey) !*Series {
        const hk = self.hashKey(key);
        if (self.by_key.get(hk)) |sp| return sp;
        const s = try self.allocator.create(Series);
        s.* = .{ .key = .{ .device_id = key.device_id, .metric = try self.allocator.dupe(u8, key.metric) }, .points = std.ArrayList(Point).init(self.allocator) };
        try self.by_key.put(hk, s);
        return s;
    }

    pub fn insertMany(self: *Store, key: SeriesKey, pts: []const Point) !void {
        const s = try self.getOrCreateSeries(key);
        if (pts.len == 0) return;
        try s.points.appendSlice(pts);
        std.sort.pdq(Point, s.points.items, {}, struct {
            fn less(_: void, a: Point, b: Point) bool {
                return if (a.ts == b.ts) a.value < b.value else a.ts < b.ts;
            }
        }.less);
    }

    pub fn last(self: *Store, key: SeriesKey) ?Point {
        const hk = self.hashKey(key);
        if (self.by_key.get(hk)) |sp| {
            const s = sp;
            if (s.points.items.len == 0) return null;
            return s.points.items[s.points.items.len - 1];
        }
        return null;
    }

    pub fn valueBefore(self: *Store, key: SeriesKey, ts: i64) ?Point {
        const hk = self.hashKey(key);
        const sp = self.by_key.get(hk) orelse return null;
        const arr = sp.points.items;
        if (arr.len == 0) return null;
        var lo: usize = 0;
        var hi: usize = arr.len;
        while (lo < hi) {
            const mid = lo + (hi - lo) / 2;
            if (arr[mid].ts <= ts) lo = mid + 1 else hi = mid;
        }
        if (lo == 0) return null;
        return arr[lo - 1];
    }

    pub const Bucket = struct { start_ts: i64, end_ts: i64, count: i64, sum: i128 };

    /// Sample time-series by interval with aggregation
    pub fn sampleBy(
        self: *Store,
        key: SeriesKey,
        interval_ms: i64,
        start_ts: i64,
        end_ts: i64,
        aggregation: enum { avg, sum, min, max, count, first, last },
        allocator: std.mem.Allocator,
    ) ![]const struct { ts: i64, value: ?i64 } {
        if (interval_ms <= 0 or end_ts <= start_ts) return &.{};

        const hk = self.hashKey(key);
        const sp = self.by_key.get(hk) orelse return &.{};
        const n_buckets: usize = @intCast(((end_ts - start_ts) + interval_ms - 1) / interval_ms);

        var buckets = try allocator.alloc(struct {
            start_ts: i64,
            end_ts: i64,
            count: i64,
            sum: i128,
            min: ?i64,
            max: ?i64,
            first: ?Point,
            last: ?Point,
        }, n_buckets);

        // Initialize buckets
        var i: usize = 0;
        while (i < n_buckets) : (i += 1) {
            const s_ts = start_ts + @as(i64, @intCast(i)) * interval_ms;
            buckets[i] = .{
                .start_ts = s_ts,
                .end_ts = s_ts + interval_ms,
                .count = 0,
                .sum = 0,
                .min = null,
                .max = null,
                .first = null,
                .last = null,
            };
        }

        // Fill buckets with data
        for (sp.points.items) |p| {
            if (p.ts < start_ts or p.ts >= end_ts) continue;
            const idx_i64 = (p.ts - start_ts) / interval_ms;
            if (idx_i64 < 0) continue;
            const idx: usize = @intCast(idx_i64);
            if (idx >= n_buckets) continue;

            buckets[idx].count += 1;
            buckets[idx].sum += @as(i128, p.value);

            if (buckets[idx].min == null or p.value < buckets[idx].min.?) {
                buckets[idx].min = p.value;
            }
            if (buckets[idx].max == null or p.value > buckets[idx].max.?) {
                buckets[idx].max = p.value;
            }
            if (buckets[idx].first == null) {
                buckets[idx].first = p;
            }
            buckets[idx].last = p;
        }

        // Generate output based on aggregation type
        var out = try allocator.alloc(struct { ts: i64, value: ?i64 }, n_buckets);
        i = 0;
        while (i < n_buckets) : (i += 1) {
            const b = buckets[i];
            const value: ?i64 = switch (aggregation) {
                .avg => if (b.count == 0) null else @intCast(@divTrunc(b.sum, @as(i128, b.count))),
                .sum => if (b.count == 0) null else @intCast(b.sum),
                .min => b.min,
                .max => b.max,
                .count => b.count,
                .first => if (b.first) |f| f.value else null,
                .last => if (b.last) |l| l.value else null,
            };
            out[i] = .{ .ts = b.start_ts, .value = value };
        }

        return out;
    }

    pub fn timeBucketAvg(self: *Store, key: SeriesKey, bucket_seconds: i64, t0: i64, t1: i64, allocator: std.mem.Allocator) ![]const struct { ts: i64, avg: ?i64 } {
        if (bucket_seconds <= 0 or t1 <= t0) return &.{};
        const hk = self.hashKey(key);
        const sp = self.by_key.get(hk) orelse return &.{};
        const n_buckets: usize = @intCast(((t1 - t0) + bucket_seconds - 1) / bucket_seconds);
        var buckets = try allocator.alloc(Bucket, n_buckets);
        var i: usize = 0;
        while (i < n_buckets) : (i += 1) {
            const s_ts = t0 + @as(i64, @intCast(i)) * bucket_seconds;
            buckets[i] = .{ .start_ts = s_ts, .end_ts = s_ts + bucket_seconds, .count = 0, .sum = 0 };
        }
        for (sp.points.items) |p| {
            if (p.ts < t0 or p.ts >= t1) continue;
            const idx_i64 = (p.ts - t0) / bucket_seconds;
            if (idx_i64 < 0) continue;
            const idx: usize = @intCast(idx_i64);
            if (idx >= n_buckets) continue;
            buckets[idx].count += 1;
            buckets[idx].sum += @as(i128, p.value);
        }
        var out = try allocator.alloc(struct { ts: i64, avg: ?i64 }, n_buckets);
        i = 0;
        while (i < n_buckets) : (i += 1) {
            const b = buckets[i];
            if (b.count == 0) {
                out[i] = .{ .ts = b.start_ts, .avg = null };
            } else {
                const q = @divTrunc(b.sum, @as(i128, b.count));
                const v: i64 = @intCast(q);
                out[i] = .{ .ts = b.start_ts, .avg = v };
            }
        }
        return out;
    }
};

test "ts: insert/order/last/asof" {
    const allocator = std.testing.allocator;
    var st = Store.init(allocator);
    defer st.deinit();
    const key = SeriesKey{ .device_id = 1, .metric = "temp" };
    try st.insertMany(key, &.{ .{ .ts = 100, .value = 10 }, .{ .ts = 90, .value = 9 }, .{ .ts = 110, .value = 11 } });
    const l = st.last(key).?;
    try std.testing.expect(l.ts == 110 and l.value == 11);
    const p = st.valueBefore(key, 105).?;
    try std.testing.expect(p.ts == 100 and p.value == 10);
}

test "ts: timeBucketAvg basic" {
    const allocator = std.testing.allocator;
    var st = Store.init(allocator);
    defer st.deinit();
    const key = SeriesKey{ .device_id = 1, .metric = "temp" };
    try st.insertMany(key, &.{ .{ .ts = 0, .value = 10 }, .{ .ts = 5, .value = 20 }, .{ .ts = 10, .value = 30 } });
    const out = try st.timeBucketAvg(key, 10, 0, 20, allocator);
    try std.testing.expect(out.len == 2);
    try std.testing.expect(out[0].ts == 0 and out[0].avg.? == 15);
    try std.testing.expect(out[1].ts == 10 and out[1].avg.? == 30);
}

test "ts: sampleBy aggregations" {
    const allocator = std.testing.allocator;
    var st = Store.init(allocator);
    defer st.deinit();

    const key = SeriesKey{ .device_id = 1, .metric = "cpu" };
    try st.insertMany(key, &.{
        .{ .ts = 1000, .value = 10 },
        .{ .ts = 2000, .value = 20 },
        .{ .ts = 3000, .value = 30 },
        .{ .ts = 11000, .value = 40 },
        .{ .ts = 12000, .value = 50 },
    });

    // Test AVG aggregation
    const avg_result = try st.sampleBy(key, 10000, 0, 20000, .avg, allocator);
    defer allocator.free(avg_result);
    try std.testing.expect(avg_result.len == 2);
    try std.testing.expect(avg_result[0].value.? == 20); // avg of 10,20,30
    try std.testing.expect(avg_result[1].value.? == 45); // avg of 40,50

    // Test MIN aggregation
    const min_result = try st.sampleBy(key, 10000, 0, 20000, .min, allocator);
    defer allocator.free(min_result);
    try std.testing.expect(min_result[0].value.? == 10);
    try std.testing.expect(min_result[1].value.? == 40);

    // Test MAX aggregation
    const max_result = try st.sampleBy(key, 10000, 0, 20000, .max, allocator);
    defer allocator.free(max_result);
    try std.testing.expect(max_result[0].value.? == 30);
    try std.testing.expect(max_result[1].value.? == 50);

    // Test COUNT aggregation
    const count_result = try st.sampleBy(key, 10000, 0, 20000, .count, allocator);
    defer allocator.free(count_result);
    try std.testing.expect(count_result[0].value.? == 3);
    try std.testing.expect(count_result[1].value.? == 2);
}

test "ts: valueAt and lastValue" {
    const allocator = std.testing.allocator;
    var st = Store.init(allocator);
    defer st.deinit();

    const key = SeriesKey{ .device_id = 1, .metric = "memory" };
    try st.insertMany(key, &.{
        .{ .ts = 1000, .value = 100 },
        .{ .ts = 2000, .value = 200 },
        .{ .ts = 3000, .value = 300 },
    });

    // Test lastValue
    const last = st.last(key).?;
    try std.testing.expect(last.ts == 3000 and last.value == 300);

    // Test valueAt (exact match)
    const hk = st.hashKey(key);
    const series = st.by_key.get(hk).?;
    const exact = series.valueAt(2000).?;
    try std.testing.expect(exact.ts == 2000 and exact.value == 200);

    // Test valueAt (interpolated/closest)
    const closest = series.valueAt(2500).?;
    try std.testing.expect(closest.ts == 2000 and closest.value == 200);
}
