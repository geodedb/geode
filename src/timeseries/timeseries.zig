// Thin compatibility wrapper -- delegates to the external timeseries library
// while preserving the public API surface used by Geode consumers.
//
// Upstream: @import("timeseries_lib")  (geode/build.zig wires this)

// CANARY: REQ=REQ-TS-STORE-001; FEATURE="TimeSeriesStore"; ASPECT=Core; STATUS=TESTED; TEST=src/timeseries/timeseries.zig:"ts: insert/order/last/asof"; OWNER=timeseries; UPDATED=2026-04-01
// CANARY: REQ=REQ-TS-INSERT-001; FEATURE="TimeSeriesInsertMany"; ASPECT=DataIngestion; STATUS=TESTED; TEST=src/timeseries/timeseries.zig:"ts: insert/order/last/asof"; OWNER=timeseries; UPDATED=2026-04-01
// CANARY: REQ=REQ-TS-LAST-001; FEATURE="TimeSeriesLast"; ASPECT=Query; STATUS=TESTED; TEST=src/timeseries/timeseries.zig:"ts: insert/order/last/asof"; OWNER=timeseries; UPDATED=2026-04-01
// CANARY: REQ=REQ-TS-VALUEBEFORE-001; FEATURE="TimeSeriesValueBefore"; ASPECT=Query; STATUS=TESTED; TEST=src/timeseries/timeseries.zig:"ts: insert/order/last/asof"; OWNER=timeseries; UPDATED=2026-04-01
// CANARY: REQ=REQ-TS-SAMPLEBY-001; FEATURE="TimeSeriesSampleBy"; ASPECT=Aggregation; STATUS=TESTED; TEST=src/timeseries/timeseries.zig:"ts: sampleBy aggregations"; OWNER=timeseries; UPDATED=2026-04-01
// CANARY: REQ=REQ-TS-TIMEBUCKET-001; FEATURE="TimeSeriesTimeBucketAvg"; ASPECT=Aggregation; STATUS=TESTED; TEST=src/timeseries/timeseries.zig:"ts: timeBucketAvg basic"; OWNER=timeseries; UPDATED=2026-04-01
// CANARY: REQ=REQ-TS-VALUEAT-001; FEATURE="TimeSeriesValueAt"; ASPECT=Query; STATUS=TESTED; TEST=src/timeseries/timeseries.zig:"ts: valueAt and lastValue"; OWNER=timeseries; UPDATED=2026-04-01
// CANARY: REQ=REQ-TS-SERIESKEY-001; FEATURE="TimeSeriesSeriesKey"; ASPECT=Types; STATUS=TESTED; TEST=src/timeseries/timeseries.zig:"ts: insert/order/last/asof"; OWNER=timeseries; UPDATED=2026-04-01
// CANARY: REQ=REQ-TS-POINT-001; FEATURE="TimeSeriesPoint"; ASPECT=Types; STATUS=TESTED; TEST=src/timeseries/timeseries.zig:"ts: insert/order/last/asof"; OWNER=timeseries; UPDATED=2026-04-01
// CANARY: REQ=REQ-TS-PERSIST-001; FEATURE="TimeSeriesPersistence"; ASPECT=StoreConfig; STATUS=IMPL; OWNER=timeseries; UPDATED=2026-04-01
// CANARY: REQ=REQ-TS-PERSIST-002; FEATURE="TimeSeriesLoadFromDisk"; ASPECT=Startup; STATUS=IMPL; OWNER=timeseries; UPDATED=2026-04-01
// CANARY: REQ=REQ-TS-PERSIST-003; FEATURE="TimeSeriesSync"; ASPECT=Shutdown; STATUS=IMPL; OWNER=timeseries; UPDATED=2026-04-01

const ts_lib = @import("timeseries_lib");
const ts_storage = @import("timeseries_storage_lib");
const thread_pool = @import("thread_pool");
const std = @import("std");

// Re-export core store types at the same names the rest of Geode expects.
pub const Point = ts_lib.Point;
pub const PointF64 = ts_lib.PointF64;
pub const SeriesKey = ts_lib.SeriesKey;
pub const Series = ts_lib.Series;

pub const StoreConfig = struct {
    data_dir: ?[]const u8 = null,
    chunk_config: ChunkConfig = .{},
};

pub const Store = struct {
    allocator: std.mem.Allocator,
    engine: ?*ts_storage.engine.Engine,
    pool: ?*thread_pool.ThreadPool,
    config: StoreConfig,
    series_cache: std.AutoHashMap(u128, *Series),
    // B0 bug-1 fix: serialize all access to `series_cache` (and the per-series
    // point ArrayLists it owns). Before native `geode.ts.*` GQL ingest landed,
    // the Store was only ever driven single-threaded; the QUIC server's
    // worker-thread pool can now drive concurrent inserts/reads, which raced the
    // unsynchronized cache. This is a NEW leaf-tier mutex below every other
    // geode lock (it touches no other lock). The non-recursive mutex means
    // public methods that call each other do so via private `*Unlocked` helpers
    // while holding the lock — never re-entrantly.
    //
    // Zig 0.16 retired `std.Thread.Mutex`; we use the Io-integrated
    // `std.Io.Mutex` + `std.Io.Threaded.global_single_threaded.io()` pattern
    // used everywhere else in geode (graph_store.zig, schema_provider.zig). The
    // `lockHere()`/`unlockHere()` helpers below keep the call sites readable.
    store_mutex: std.Io.Mutex = std.Io.Mutex.init,

    pub fn init(allocator: std.mem.Allocator) Store {
        return .{
            .allocator = allocator,
            .engine = null,
            .pool = null,
            .config = .{},
            .series_cache = std.AutoHashMap(u128, *Series).init(allocator),
        };
    }

    pub fn initWithConfig(allocator: std.mem.Allocator, config: StoreConfig) !Store {
        if (config.data_dir == null) return init(allocator);

        // We create a dedicated thread pool for the timeseries engine
        const pool_ptr = try allocator.create(thread_pool.ThreadPool);
        errdefer allocator.destroy(pool_ptr);

        pool_ptr.* = try thread_pool.ThreadPool.init(allocator, .{
            .min_threads = 2,
            .max_threads = 4,
            // 2026-06-08 idle-CPU fix: this is the EXT thread_pool (the engine's
            // init signature requires *thread_pool.ThreadPool), so it does NOT
            // inherit geode's wrapper default and would otherwise use the upstream
            // 250µs idle park — 4 workers spinning at ~4000 wakes/s each on an idle
            // server that never touches timeseries (the Store is created
            // unconditionally at startup; see src/server/main.zig). Workers wake on
            // task-submit signal regardless of this timeout, so park long.
            .idle_park_after_ns = 500 * std.time.ns_per_ms,
        });
        errdefer pool_ptr.deinit();

        const data_dir_owned = try std.fmt.allocPrint(allocator, "{s}/timeseries", .{config.data_dir.?});
        // ts_storage.engine.Engine.init may copy/own data_dir on success, but
        // on failure (e.g. error.FileNotFound) the owned slice would leak. The
        // errdefer below frees it on any failure path before Engine.init's
        // ownership transfer; we clear it manually on the success path.
        var data_dir_owned_for_errdefer: ?[]u8 = data_dir_owned;
        errdefer if (data_dir_owned_for_errdefer) |slc| allocator.free(slc);

        const engine_config = ts_storage.engine.Config{
            .data_dir = data_dir_owned,
            .max_memtable_points = config.chunk_config.max_points_per_chunk,
        };

        const engine_ptr = try allocator.create(ts_storage.engine.Engine);
        errdefer allocator.destroy(engine_ptr);

        engine_ptr.* = try ts_storage.engine.Engine.init(allocator, engine_config, pool_ptr);
        // Engine.init succeeded; assume it took ownership of data_dir_owned.
        data_dir_owned_for_errdefer = null;

        return Store{
            .allocator = allocator,
            .engine = engine_ptr,
            .pool = pool_ptr,
            .config = config,
            .series_cache = std.AutoHashMap(u128, *Series).init(allocator),
        };
    }

    pub fn deinit(self: *Store) void {
        var it = self.series_cache.valueIterator();
        while (it.next()) |s_ptr| {
            const s = s_ptr.*;
            s.points.deinit(self.allocator);
            self.allocator.free(s.key.metric);
            self.allocator.destroy(s);
        }
        self.series_cache.deinit();

        if (self.engine) |eng| {
            eng.deinit();
            self.allocator.free(eng.config.data_dir);
            self.allocator.destroy(eng);
            self.engine = null;
        }
        if (self.pool) |p| {
            p.deinit();
            self.allocator.destroy(p);
            self.pool = null;
        }
    }

    pub fn loadFromDisk(self: *Store) !void {
        // Engine's init() already replays WAL and loads segments.
        _ = self;
    }

    pub fn sync(self: *Store) !void {
        if (self.engine) |eng| {
            try eng.sync();
        }
    }

    fn hashKeyStatic(k: SeriesKey) u128 {
        var h1 = std.hash.Wyhash.init(0);
        h1.update(std.mem.asBytes(&k.device_id));
        h1.update(k.metric);
        const x1 = h1.final();
        var h2 = std.hash.Wyhash.init(0x517cc1b727220a95);
        h2.update(std.mem.asBytes(&k.device_id));
        h2.update(k.metric);
        const x2 = h2.final();
        return (@as(u128, x1) << 64) | @as(u128, x2);
    }

    pub fn hashKey(self: *Store, k: SeriesKey) u128 {
        _ = self;
        return hashKeyStatic(k);
    }

    // B0 bug-1 helpers: acquire/release `store_mutex` via the global
    // single-threaded io (the geode-wide std.Io.Mutex idiom).
    fn lockHere(self: *Store) void {
        self.store_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    }
    fn unlockHere(self: *Store) void {
        self.store_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    }

    pub fn insertMany(self: *Store, key: SeriesKey, pts: []const Point) !void {
        if (pts.len == 0) return;
        self.lockHere();
        defer self.unlockHere();

        const sid = self.hashKey(key);

        // Update cache if it exists, or create it
        const series = try self.getOrCreateSeriesUnlocked(key);
        try series.points.appendSlice(self.allocator, pts);

        // Sort the cache array to maintain invariants
        const cmpFn = struct {
            fn less(_: void, a: Point, b: Point) bool {
                return if (a.ts == b.ts) a.value < b.value else a.ts < b.ts;
            }
        }.less;
        std.mem.sort(Point, series.points.items, {}, cmpFn);

        if (self.engine) |eng| {
            const engine_pts = @as([]const ts_storage.types.Point, @ptrCast(pts));
            try eng.appendPoints(sid, engine_pts);
        }
    }

    pub fn last(self: *Store, key: SeriesKey) ?Point {
        self.lockHere();
        defer self.unlockHere();
        return self.lastUnlocked(key);
    }

    fn lastUnlocked(self: *Store, key: SeriesKey) ?Point {
        if (self.engine) |eng| {
            const sid = self.hashKey(key);
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            var iter = eng.queryPoints(arena.allocator(), sid, 0, std.math.maxInt(i64)) catch return null;
            var last_pt: ?ts_storage.types.Point = null;
            while (iter.next()) |pt| {
                last_pt = pt;
            }
            if (last_pt) |p| {
                return Point{ .ts = p.ts, .value = p.value };
            }
            return null;
        } else {
            if (self.series_cache.get(self.hashKey(key))) |s| {
                if (s.points.items.len > 0) return s.points.items[s.points.items.len - 1];
            }
            return null;
        }
    }

    pub fn valueBefore(self: *Store, key: SeriesKey, ts: i64) ?Point {
        self.lockHere();
        defer self.unlockHere();
        return self.valueBeforeUnlocked(key, ts);
    }

    fn valueBeforeUnlocked(self: *Store, key: SeriesKey, ts: i64) ?Point {
        if (self.engine) |eng| {
            const sid = self.hashKey(key);
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();

            var iter = eng.queryPoints(arena.allocator(), sid, 0, ts - 1) catch return null;
            var last_pt: ?ts_storage.types.Point = null;
            while (iter.next()) |pt| {
                last_pt = pt;
            }
            if (last_pt) |p| {
                return Point{ .ts = p.ts, .value = p.value };
            }
            return null;
        } else {
            if (self.series_cache.get(self.hashKey(key))) |s| {
                var last_p: ?Point = null;
                for (s.points.items) |p| {
                    if (p.ts >= ts) break;
                    last_p = p;
                }
                return last_p;
            }
            return null;
        }
    }

    /// Query the points in `[start_ts, end_ts]` — INCLUSIVE of both bounds in
    /// BOTH the durable engine path AND the in-memory cache path (B0 bug-2 fix).
    /// The durable engine (`eng.queryPoints`) is end-inclusive by lib contract;
    /// the in-memory branch was historically end-EXCLUSIVE (`p.ts < end_ts`),
    /// so the same query dropped a boundary point in cache mode but kept it in
    /// durable mode. Both branches now use `p.ts <= end_ts` so the two modes
    /// return identical slices.
    pub fn queryRange(self: *Store, key: SeriesKey, start_ts: i64, end_ts: i64, allocator: std.mem.Allocator) ![]Point {
        self.lockHere();
        defer self.unlockHere();
        return self.queryRangeUnlocked(key, start_ts, end_ts, allocator);
    }

    fn queryRangeUnlocked(self: *Store, key: SeriesKey, start_ts: i64, end_ts: i64, allocator: std.mem.Allocator) ![]Point {
        var points: std.ArrayList(Point) = .empty;
        errdefer points.deinit(allocator);

        if (self.engine) |eng| {
            const sid = self.hashKey(key);
            var iter = try eng.queryPoints(allocator, sid, start_ts, end_ts);

            while (iter.next()) |pt| {
                try points.append(allocator, .{ .ts = pt.ts, .value = pt.value });
            }
        } else {
            if (self.series_cache.get(self.hashKey(key))) |s| {
                for (s.points.items) |p| {
                    if (p.ts >= start_ts and p.ts <= end_ts) {
                        try points.append(allocator, p);
                    }
                }
            }
        }
        return points.toOwnedSlice(allocator);
    }

    pub fn getSeries(self: *Store, key: SeriesKey) ?*Series {
        self.lockHere();
        defer self.unlockHere();
        if (self.series_cache.get(self.hashKey(key))) |s| return s;
        if (self.engine != null) {
            return self.getOrCreateSeriesUnlocked(key) catch null;
        }
        return null;
    }

    /// Public, lock-acquiring wrapper. Internal callers that already hold
    /// `store_mutex` MUST use `getOrCreateSeriesUnlocked` instead to avoid a
    /// re-entrant deadlock on the non-recursive mutex.
    pub fn getOrCreateSeries(self: *Store, key: SeriesKey) !*Series {
        self.lockHere();
        defer self.unlockHere();
        return self.getOrCreateSeriesUnlocked(key);
    }

    fn getOrCreateSeriesUnlocked(self: *Store, key: SeriesKey) !*Series {
        const hk = self.hashKey(key);
        if (self.series_cache.get(hk)) |s| return s;

        const s = try self.allocator.create(Series);
        s.* = .{
            .key = .{
                .device_id = key.device_id,
                .metric = try self.allocator.dupe(u8, key.metric),
            },
            .points = .empty,
        };

        if (self.engine) |eng| {
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            var iter = try eng.queryPoints(arena.allocator(), hk, 0, std.math.maxInt(i64));
            while (iter.next()) |pt| {
                try s.points.append(self.allocator, .{ .ts = pt.ts, .value = pt.value });
            }
        }

        try self.series_cache.put(hk, s);
        return s;
    }

    pub fn timeBucketAvg(
        self: *Store,
        key: SeriesKey,
        bucket_seconds: i64,
        start_ts: i64,
        end_ts: i64,
        allocator: std.mem.Allocator,
    ) ![]ts_lib.store.BucketAvgRow {
        self.lockHere();
        defer self.unlockHere();

        const points = try self.queryRangeUnlocked(key, start_ts, end_ts, allocator);
        defer allocator.free(points);

        var results: std.ArrayList(ts_lib.store.BucketAvgRow) = .empty;
        errdefer results.deinit(allocator);

        if (end_ts <= start_ts) return results.toOwnedSlice(allocator);

        const bucket_ms = bucket_seconds;
        var current_bucket_start = start_ts;
        var pt_idx: usize = 0;

        while (current_bucket_start < end_ts) : (current_bucket_start += bucket_ms) {
            const bucket_end = current_bucket_start + bucket_ms;
            var sum: i128 = 0;
            var count: i64 = 0;

            while (pt_idx < points.len and points[pt_idx].ts < bucket_end) {
                sum += points[pt_idx].value;
                count += 1;
                pt_idx += 1;
            }

            if (count > 0) {
                const avg: i64 = @intCast(@divTrunc(sum, count));
                try results.append(allocator, .{ .ts = current_bucket_start, .avg = avg });
            } else {
                try results.append(allocator, .{ .ts = current_bucket_start, .avg = null });
            }
        }

        return results.toOwnedSlice(allocator);
    }

    pub fn sampleBy(
        self: *Store,
        key: SeriesKey,
        interval_ms: i64,
        start_ts: i64,
        end_ts: i64,
        agg: ts_lib.store.Aggregation,
        allocator: std.mem.Allocator,
    ) ![]ts_lib.store.SampleRow {
        self.lockHere();
        defer self.unlockHere();

        const points = try self.queryRangeUnlocked(key, start_ts, end_ts, allocator);
        defer allocator.free(points);

        var results: std.ArrayList(ts_lib.store.SampleRow) = .empty;
        errdefer results.deinit(allocator);

        if (end_ts <= start_ts) return results.toOwnedSlice(allocator);

        var current_bucket_start = start_ts;
        var pt_idx: usize = 0;

        while (current_bucket_start < end_ts) : (current_bucket_start += interval_ms) {
            const bucket_end = current_bucket_start + interval_ms;

            var sum: i128 = 0;
            var count: i64 = 0;
            var min: i64 = std.math.maxInt(i64);
            var max: i64 = std.math.minInt(i64);
            var first: ?i64 = null;
            var last_val: ?i64 = null;

            while (pt_idx < points.len and points[pt_idx].ts < bucket_end) {
                const val = points[pt_idx].value;
                if (first == null) first = val;
                last_val = val;
                sum += val;
                count += 1;
                if (val < min) min = val;
                if (val > max) max = val;
                pt_idx += 1;
            }

            var result_val: ?i64 = null;
            if (count > 0) {
                switch (agg) {
                    .avg => result_val = @intCast(@divTrunc(sum, count)),
                    .sum => result_val = @intCast(sum),
                    .min => result_val = min,
                    .max => result_val = max,
                    .count => result_val = count,
                    .first => result_val = first,
                    .last => result_val = last_val,
                }
            }

            try results.append(allocator, .{ .ts = current_bucket_start, .value = result_val });
        }

        return results.toOwnedSlice(allocator);
    }
};
pub const ChunkConfig = ts_lib.ChunkConfig;
pub const ChunkStorage = ts_lib.ChunkStorage;

// Re-export the external library's full namespace so advanced consumers
// (e.g. DTW, matrix profile, features) can reach sub-modules.
pub const lib = ts_lib;

// ---------------------------------------------------------------------------
// Tests -- verify that the external library types work through this wrapper.
// ---------------------------------------------------------------------------

//const std = @import("std");

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
    defer allocator.free(out);
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
    const series = st.series_cache.get(hk).?;
    const exact = series.valueAt(2000).?;
    try std.testing.expect(exact.ts == 2000 and exact.value == 200);

    // Test valueAt (interpolated/closest)
    const closest = series.valueAt(2500).?;
    try std.testing.expect(closest.ts == 2000 and closest.value == 200);
}

// ---------------------------------------------------------------------------
// GAP-0284: SUM/FIRST/LAST aggregation tests
// ---------------------------------------------------------------------------

test "ts: sampleBy SUM aggregation" {
    const allocator = std.testing.allocator;
    var st = Store.init(allocator);
    defer st.deinit();

    const key = SeriesKey{ .device_id = 2, .metric = "bytes" };
    try st.insertMany(key, &.{
        .{ .ts = 1000, .value = 10 },
        .{ .ts = 2000, .value = 20 },
        .{ .ts = 3000, .value = 30 },
        .{ .ts = 11000, .value = 40 },
        .{ .ts = 12000, .value = 50 },
    });

    const result = try st.sampleBy(key, 10000, 0, 20000, .sum, allocator);
    defer allocator.free(result);

    // Bucket [0, 10000): points 10+20+30 = 60
    // Bucket [10000, 20000): points 40+50 = 90
    try std.testing.expect(result.len == 2);
    try std.testing.expectEqual(@as(i64, 60), result[0].value.?);
    try std.testing.expectEqual(@as(i64, 90), result[1].value.?);
}

test "ts: sampleBy FIRST aggregation" {
    const allocator = std.testing.allocator;
    var st = Store.init(allocator);
    defer st.deinit();

    const key = SeriesKey{ .device_id = 2, .metric = "bytes" };
    try st.insertMany(key, &.{
        .{ .ts = 1000, .value = 10 },
        .{ .ts = 2000, .value = 20 },
        .{ .ts = 3000, .value = 30 },
        .{ .ts = 11000, .value = 40 },
        .{ .ts = 12000, .value = 50 },
    });

    const result = try st.sampleBy(key, 10000, 0, 20000, .first, allocator);
    defer allocator.free(result);

    // Bucket [0, 10000): first point value = 10
    // Bucket [10000, 20000): first point value = 40
    try std.testing.expect(result.len == 2);
    try std.testing.expectEqual(@as(i64, 10), result[0].value.?);
    try std.testing.expectEqual(@as(i64, 40), result[1].value.?);
}

test "ts: sampleBy LAST aggregation" {
    const allocator = std.testing.allocator;
    var st = Store.init(allocator);
    defer st.deinit();

    const key = SeriesKey{ .device_id = 2, .metric = "bytes" };
    try st.insertMany(key, &.{
        .{ .ts = 1000, .value = 10 },
        .{ .ts = 2000, .value = 20 },
        .{ .ts = 3000, .value = 30 },
        .{ .ts = 11000, .value = 40 },
        .{ .ts = 12000, .value = 50 },
    });

    const result = try st.sampleBy(key, 10000, 0, 20000, .last, allocator);
    defer allocator.free(result);

    // Bucket [0, 10000): last point value = 30
    // Bucket [10000, 20000): last point value = 50
    try std.testing.expect(result.len == 2);
    try std.testing.expectEqual(@as(i64, 30), result[0].value.?);
    try std.testing.expectEqual(@as(i64, 50), result[1].value.?);
}

test "ts: sampleBy SUM/FIRST/LAST with empty bucket" {
    const allocator = std.testing.allocator;
    var st = Store.init(allocator);
    defer st.deinit();

    const key = SeriesKey{ .device_id = 3, .metric = "gap" };
    // Points only in first bucket, second bucket empty
    try st.insertMany(key, &.{
        .{ .ts = 100, .value = 5 },
        .{ .ts = 200, .value = 15 },
    });

    const sum_result = try st.sampleBy(key, 1000, 0, 2000, .sum, allocator);
    defer allocator.free(sum_result);
    try std.testing.expect(sum_result.len == 2);
    try std.testing.expectEqual(@as(i64, 20), sum_result[0].value.?);
    try std.testing.expect(sum_result[1].value == null); // empty bucket

    const first_result = try st.sampleBy(key, 1000, 0, 2000, .first, allocator);
    defer allocator.free(first_result);
    try std.testing.expectEqual(@as(i64, 5), first_result[0].value.?);
    try std.testing.expect(first_result[1].value == null);

    const last_result = try st.sampleBy(key, 1000, 0, 2000, .last, allocator);
    defer allocator.free(last_result);
    try std.testing.expectEqual(@as(i64, 15), last_result[0].value.?);
    try std.testing.expect(last_result[1].value == null);
}

// ---------------------------------------------------------------------------
// GAP-0285: valueAt and timeBucketAvg dedicated tests
// ---------------------------------------------------------------------------

test "ts: valueAt — before first timestamp returns null" {
    const allocator = std.testing.allocator;
    var st = Store.init(allocator);
    defer st.deinit();

    const key = SeriesKey{ .device_id = 4, .metric = "val" };
    try st.insertMany(key, &.{
        .{ .ts = 5000, .value = 50 },
        .{ .ts = 6000, .value = 60 },
    });

    const hk = st.hashKey(key);
    const series = st.series_cache.get(hk).?;

    // Timestamp before all points — binary search finds nothing before
    const result = series.valueAt(1000);
    try std.testing.expect(result == null);
}

test "ts: valueAt — after last timestamp returns last-before point" {
    const allocator = std.testing.allocator;
    var st = Store.init(allocator);
    defer st.deinit();

    const key = SeriesKey{ .device_id = 4, .metric = "val" };
    try st.insertMany(key, &.{
        .{ .ts = 1000, .value = 10 },
        .{ .ts = 2000, .value = 20 },
        .{ .ts = 3000, .value = 30 },
    });

    const hk = st.hashKey(key);
    const series = st.series_cache.get(hk).?;

    // Timestamp after all points — returns last point (closest before)
    const result = series.valueAt(9999).?;
    try std.testing.expectEqual(@as(i64, 3000), result.ts);
    try std.testing.expectEqual(@as(i64, 30), result.value);
}

test "ts: valueAt — exact match returns exact point" {
    const allocator = std.testing.allocator;
    var st = Store.init(allocator);
    defer st.deinit();

    const key = SeriesKey{ .device_id = 4, .metric = "val" };
    try st.insertMany(key, &.{
        .{ .ts = 1000, .value = 10 },
        .{ .ts = 2000, .value = 20 },
        .{ .ts = 3000, .value = 30 },
    });

    const hk = st.hashKey(key);
    const series = st.series_cache.get(hk).?;

    // Exact match on first, middle, and last
    const first = series.valueAt(1000).?;
    try std.testing.expectEqual(@as(i64, 1000), first.ts);
    try std.testing.expectEqual(@as(i64, 10), first.value);

    const mid = series.valueAt(2000).?;
    try std.testing.expectEqual(@as(i64, 2000), mid.ts);
    try std.testing.expectEqual(@as(i64, 20), mid.value);

    const end = series.valueAt(3000).?;
    try std.testing.expectEqual(@as(i64, 3000), end.ts);
    try std.testing.expectEqual(@as(i64, 30), end.value);
}

test "ts: valueAt — empty series returns null" {
    const allocator = std.testing.allocator;
    var st = Store.init(allocator);
    defer st.deinit();

    const key = SeriesKey{ .device_id = 5, .metric = "empty" };
    // Create the series with zero points. insertMany short-circuits on
    // empty slices, so go straight through getOrCreateSeries to ensure
    // an empty-points series object exists in the cache.
    const series = try st.getOrCreateSeries(key);
    const result = series.valueAt(1000);
    try std.testing.expect(result == null);
}

test "ts: timeBucketAvg — empty range returns empty" {
    const allocator = std.testing.allocator;
    var st = Store.init(allocator);
    defer st.deinit();

    const key = SeriesKey{ .device_id = 6, .metric = "empty_range" };
    try st.insertMany(key, &.{
        .{ .ts = 100, .value = 10 },
    });

    // end <= start → should return empty slice
    const result = try st.timeBucketAvg(key, 10, 100, 100, allocator);
    try std.testing.expectEqual(@as(usize, 0), result.len);

    // Also test reversed range
    const result2 = try st.timeBucketAvg(key, 10, 200, 100, allocator);
    try std.testing.expectEqual(@as(usize, 0), result2.len);
}

test "ts: timeBucketAvg — single-point bucket" {
    const allocator = std.testing.allocator;
    var st = Store.init(allocator);
    defer st.deinit();

    const key = SeriesKey{ .device_id = 6, .metric = "single" };
    try st.insertMany(key, &.{
        .{ .ts = 5, .value = 42 },
    });

    // One bucket [0, 10) containing one point with value 42
    const result = try st.timeBucketAvg(key, 10, 0, 10, allocator);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 1), result.len);
    try std.testing.expectEqual(@as(i64, 0), result[0].ts);
    try std.testing.expectEqual(@as(i64, 42), result[0].avg.?);
}

test "ts: timeBucketAvg — bucket with no points returns null avg" {
    const allocator = std.testing.allocator;
    var st = Store.init(allocator);
    defer st.deinit();

    const key = SeriesKey{ .device_id = 6, .metric = "sparse" };
    try st.insertMany(key, &.{
        .{ .ts = 5, .value = 100 },
        // gap: no points in [10, 20)
        .{ .ts = 25, .value = 200 },
    });

    const result = try st.timeBucketAvg(key, 10, 0, 30, allocator);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqual(@as(i64, 100), result[0].avg.?); // bucket [0,10)
    try std.testing.expect(result[1].avg == null); // bucket [10,20) — empty
    try std.testing.expectEqual(@as(i64, 200), result[2].avg.?); // bucket [20,30)
}

test "ts: timeBucketAvg — boundary: point exactly at bucket start" {
    const allocator = std.testing.allocator;
    var st = Store.init(allocator);
    defer st.deinit();

    const key = SeriesKey{ .device_id = 6, .metric = "boundary" };
    try st.insertMany(key, &.{
        .{ .ts = 0, .value = 10 },
        .{ .ts = 10, .value = 20 },
        .{ .ts = 20, .value = 30 },
    });

    // Buckets: [0,10), [10,20), [20,30)
    // ts=0 in bucket 0, ts=10 in bucket 1, ts=20 in bucket 2
    const result = try st.timeBucketAvg(key, 10, 0, 30, allocator);
    defer allocator.free(result);
    try std.testing.expectEqual(@as(usize, 3), result.len);
    try std.testing.expectEqual(@as(i64, 10), result[0].avg.?);
    try std.testing.expectEqual(@as(i64, 20), result[1].avg.?);
    try std.testing.expectEqual(@as(i64, 30), result[2].avg.?);
}

// ---------------------------------------------------------------------------
// GAP-0292: Persistence round-trip test via wrapper
// ---------------------------------------------------------------------------

test "ts: persist-restart-query via StoreConfig" {
    const allocator = std.testing.allocator;

    const pid = if (@import("builtin").os.tag == .linux) std.os.linux.getpid() else 0;
    var path_buf: [128]u8 = undefined;
    const test_dir = std.fmt.bufPrint(&path_buf, "/tmp/geode_ts_persist_{d}", .{pid}) catch unreachable;
    const tio = std.Io.Threaded.global_single_threaded.io();
    // Ensure a clean directory exists for this PID's persistence test —
    // ts_storage.engine.Engine.init requires both the parent data_dir AND
    // its internal /timeseries subdir to exist before construction.
    std.Io.Dir.cwd().deleteTree(tio, test_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(tio, test_dir);
    var ts_subdir_buf: [192]u8 = undefined;
    const ts_subdir = std.fmt.bufPrint(&ts_subdir_buf, "{s}/timeseries", .{test_dir}) catch unreachable;
    try std.Io.Dir.cwd().createDirPath(tio, ts_subdir);
    defer std.Io.Dir.cwd().deleteTree(tio, test_dir) catch {};

    const key = SeriesKey{ .device_id = 7, .metric = "voltage" };

    // Phase 1: insert and deinit (flush to disk).
    {
        var st = try Store.initWithConfig(allocator, .{
            .data_dir = test_dir,
            .chunk_config = .{ .max_points_per_chunk = 10 },
        });
        defer st.deinit();

        try st.insertMany(key, &.{
            .{ .ts = 100, .value = 220 },
            .{ .ts = 200, .value = 221 },
            .{ .ts = 300, .value = 219 },
        });
    }

    // Phase 2: reload and verify.
    {
        var st2 = try Store.initWithConfig(allocator, .{
            .data_dir = test_dir,
            .chunk_config = .{ .max_points_per_chunk = 10 },
        });
        defer st2.deinit();

        try st2.loadFromDisk();

        const last = st2.last(key);
        try std.testing.expect(last != null);
        try std.testing.expectEqual(@as(i64, 300), last.?.ts);
        try std.testing.expectEqual(@as(i64, 219), last.?.value);
    }
}

test "ts: StoreConfig re-export available" {
    // Verify that StoreConfig, ChunkConfig, ChunkStorage are accessible through the wrapper.
    const cfg = StoreConfig{ .data_dir = null };
    try std.testing.expect(cfg.data_dir == null);
    const cc = ChunkConfig{};
    try std.testing.expect(cc.retention_days == 30);
}
