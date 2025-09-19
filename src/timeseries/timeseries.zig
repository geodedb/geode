const std = @import("std");

pub const Point = struct { ts: i64, value: i64 };

pub const SeriesKey = struct { device_id: i64, metric: []const u8 };

pub const Series = struct {
    key: SeriesKey,
    points: std.ArrayList(Point),
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

    pub fn timeBucketAvg(self: *Store, key: SeriesKey, bucket_seconds: i64, t0: i64, t1: i64, ally: std.mem.Allocator) ![]const struct { ts: i64, avg: ?i64 } {
        if (bucket_seconds <= 0 or t1 <= t0) return &.{};
        const hk = self.hashKey(key);
        const sp = self.by_key.get(hk) orelse return &.{};
        const n_buckets: usize = @intCast(((t1 - t0) + bucket_seconds - 1) / bucket_seconds);
        var buckets = try ally.alloc(Bucket, n_buckets);
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
        var out = try ally.alloc(struct { ts: i64, avg: ?i64 }, n_buckets);
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
    const ally = std.testing.allocator;
    var st = Store.init(ally);
    defer st.deinit();
    const key = SeriesKey{ .device_id = 1, .metric = "temp" };
    try st.insertMany(key, &.{ .{ .ts = 100, .value = 10 }, .{ .ts = 90, .value = 9 }, .{ .ts = 110, .value = 11 } });
    const l = st.last(key).?;
    try std.testing.expect(l.ts == 110 and l.value == 11);
    const p = st.valueBefore(key, 105).?;
    try std.testing.expect(p.ts == 100 and p.value == 10);
}

test "ts: timeBucketAvg basic" {
    const ally = std.testing.allocator;
    var st = Store.init(ally);
    defer st.deinit();
    const key = SeriesKey{ .device_id = 1, .metric = "temp" };
    try st.insertMany(key, &.{ .{ .ts = 0, .value = 10 }, .{ .ts = 5, .value = 20 }, .{ .ts = 10, .value = 30 } });
    const out = try st.timeBucketAvg(key, 10, 0, 20, ally);
    try std.testing.expect(out.len == 2);
    try std.testing.expect(out[0].ts == 0 and out[0].avg.? == 15);
    try std.testing.expect(out[1].ts == 10 and out[1].avg.? == 30);
}
