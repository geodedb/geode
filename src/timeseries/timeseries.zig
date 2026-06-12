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
// CANARY: REQ=REQ-TS-PERSIST-001; FEATURE="TimeSeriesPersistence"; ASPECT=StoreConfig; STATUS=TESTED; TEST=tests/ts_durability.zig; OWNER=timeseries; UPDATED=2026-06-10
// CANARY: REQ=REQ-TS-PERSIST-002; FEATURE="TimeSeriesLoadFromDisk"; ASPECT=Startup; STATUS=TESTED; TEST=tests/ts_durability.zig; OWNER=timeseries; UPDATED=2026-06-10
// CANARY: REQ=REQ-TS-PERSIST-003; FEATURE="TimeSeriesSync"; ASPECT=Shutdown; STATUS=TESTED; TEST=tests/ts_durability.zig; OWNER=timeseries; UPDATED=2026-06-10
// CANARY: REQ=REQ-TS-DURABILITY-001; FEATURE="TimeSeriesFailClosedOpen"; ASPECT=Core; STATUS=TESTED; TEST=tests/ts_durability.zig; OWNER=timeseries; UPDATED=2026-06-10
// CANARY: REQ=REQ-TS-RETENTION-002; FEATURE="TimeSeriesRetentionPrune"; ASPECT=Core; STATUS=TESTED; TEST=tests/ts_durability.zig; OWNER=timeseries; UPDATED=2026-06-10
// CANARY: REQ=REQ-TS-TDE-001; FEATURE="TimeSeriesTDE"; ASPECT=Core; STATUS=TESTED; TEST=tests/ts_durability.zig; OWNER=timeseries; UPDATED=2026-06-10

const ts_lib = @import("timeseries_lib");
const ts_storage = @import("timeseries_storage_lib");
const thread_pool = @import("thread_pool");
const std = @import("std");

// Re-export core store types at the same names the rest of Geode expects.
pub const Point = ts_lib.Point;
pub const PointF64 = ts_lib.PointF64;
pub const SeriesKey = ts_lib.SeriesKey;
pub const Series = ts_lib.Series;

/// GAP-0865 (a): durability posture for persistent stores.
///
/// * `.fail_closed` (default): any engine open/load error — including the
///   engine's own fail-closed WAL-replay and segment-verification errors —
///   propagates out of `initWithConfig`. A corrupt or unreadable timeseries
///   directory is surfaced to the operator, never silently replaced by an
///   empty store.
/// * `.best_effort`: explicit opt-in to the legacy soft-fail posture —
///   engine open errors degrade to the non-persistent in-memory store with
///   a warning log. Configure via `GEODE_TS_DURABILITY=best_effort`.
pub const Durability = enum { fail_closed, best_effort };

pub const StoreConfig = struct {
    data_dir: ?[]const u8 = null,
    chunk_config: ChunkConfig = .{},
    /// GAP-0865 (a): see `Durability`. Default is fail-closed.
    durability: Durability = .fail_closed,
    /// GAP-0865 (c): age-based retention in milliseconds. When set, a
    /// retention pass (`runRetention`, plus the throttled opportunistic
    /// pass on ingest) deletes whole expired segments from disk via the
    /// engine's `pruneExpired`. `null` (default) disables retention —
    /// nothing is ever deleted implicitly. Wire from
    /// `GEODE_TS_RETENTION_DAYS` via `retentionMsFromEnv()`.
    retention_max_age_ms: ?i64 = null,
    /// Test seam: overrides the "now" reference used by retention cutoff
    /// math (engine `retention_now_override`). `null` = real clock.
    retention_now_override: ?i64 = null,
    /// GAP-0865 (e): optional AES-256-GCM key for engine-level TDE of every
    /// on-disk timeseries artefact (WAL records, segment blocks TSSEG003,
    /// manifest TSMNF002). Fail-closed on reopen with a wrong/missing key.
    /// Wire from `GEODE_TS_TDE=1` + `GEODE_TDE_KEY` via
    /// `encryptionKeyFromEnv()`.
    encryption_key: ?[32]u8 = null,
};

/// Read the durability posture from `GEODE_TS_DURABILITY`
/// (`best_effort` opts into soft-fail; anything else = fail-closed).
pub fn durabilityFromEnv() Durability {
    const v = std.c.getenv("GEODE_TS_DURABILITY") orelse return .fail_closed;
    const s = std.mem.span(v);
    if (std.mem.eql(u8, s, "best_effort")) return .best_effort;
    return .fail_closed;
}

/// Read the retention window from `GEODE_TS_RETENTION_DAYS` (whole days,
/// > 0). Unset, unparsable, or non-positive values disable retention —
/// an unparsable value is logged so a typo cannot silently disable a
/// configured retention policy.
pub fn retentionMsFromEnv() ?i64 {
    const v = std.c.getenv("GEODE_TS_RETENTION_DAYS") orelse return null;
    const s = std.mem.span(v);
    const days = std.fmt.parseInt(i64, s, 10) catch {
        std.log.scoped(.timeseries).warn(
            "GEODE_TS_RETENTION_DAYS is not a valid integer; retention disabled: '{s}'",
            .{s},
        );
        return null;
    };
    if (days <= 0) return null;
    return days * std.time.ms_per_day;
}

/// Read the timeseries TDE key. Opt-in via `GEODE_TS_TDE=1` (or `true`);
/// when enabled the 32-byte key comes from `GEODE_TDE_KEY` (64 hex chars,
/// the same variable the rest of geode's TDE uses). FAIL-CLOSED: when
/// `GEODE_TS_TDE` is set but the key is missing/invalid this returns an
/// error rather than silently writing plaintext.
pub fn encryptionKeyFromEnv() error{InvalidTsTdeKey}!?[32]u8 {
    const flag = std.c.getenv("GEODE_TS_TDE") orelse return null;
    const fs = std.mem.span(flag);
    const enabled = std.mem.eql(u8, fs, "1") or std.ascii.eqlIgnoreCase(fs, "true");
    if (!enabled) return null;

    const key_env = std.c.getenv("GEODE_TDE_KEY") orelse {
        std.log.scoped(.timeseries).err("GEODE_TS_TDE is set but GEODE_TDE_KEY is missing", .{});
        return error.InvalidTsTdeKey;
    };
    const key_hex = std.mem.span(key_env);
    if (key_hex.len != 64) {
        std.log.scoped(.timeseries).err("GEODE_TDE_KEY must be 64 hex chars for timeseries TDE", .{});
        return error.InvalidTsTdeKey;
    }
    var key: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&key, key_hex) catch {
        std.log.scoped(.timeseries).err("GEODE_TDE_KEY contains invalid hex", .{});
        return error.InvalidTsTdeKey;
    };
    return key;
}

/// Minimum interval between opportunistic retention passes triggered from
/// the ingest path (GAP-0865 (c)). Keeps the prune scan off the per-insert
/// hot path while guaranteeing retention runs on any actively-ingesting
/// store without operator intervention.
const auto_prune_interval_ms: i64 = 60_000;

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
    // GAP-0865 (c): wall-clock ms of the last opportunistic retention pass
    // run from the ingest path. Guarded by `store_mutex`.
    last_auto_prune_ms: i64 = 0,

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

        // GAP-0865 (a): the durability posture decides what an engine
        // open/load failure means. Fail-closed (default) propagates the
        // error — corrupt on-disk state must be surfaced, never silently
        // replaced with an empty store. Best-effort is the explicit opt-in
        // to the legacy degrade-to-memory behaviour.
        return initDurable(allocator, config) catch |err| switch (config.durability) {
            .fail_closed => err,
            .best_effort => blk: {
                std.log.scoped(.timeseries).warn(
                    "timeseries engine open failed ({s}); best_effort configured — degrading to non-persistent in-memory store",
                    .{@errorName(err)},
                );
                break :blk init(allocator);
            },
        };
    }

    fn initDurable(allocator: std.mem.Allocator, config: StoreConfig) !Store {
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

        // GAP-0865 (a): the engine deliberately refuses to mkdir its own
        // data_dir; create `{data_dir}/timeseries` (and parents) here so a
        // FRESH directory opens durably instead of error.FileNotFound. This
        // closes the trap where a brand-new server silently degraded to a
        // memory-only store because nothing ever created the subdirectory.
        try std.Io.Dir.cwd().createDirPath(std.Io.Threaded.global_single_threaded.io(), data_dir_owned);

        const engine_config = ts_storage.engine.Config{
            .data_dir = data_dir_owned,
            .max_memtable_points = config.chunk_config.max_points_per_chunk,
            // GAP-0865 (c): age-based retention window; pruned via
            // `runRetention` / the throttled ingest-path pass.
            .retention_max_age_ms = config.retention_max_age_ms,
            .retention_now_override = config.retention_now_override,
            // GAP-0865 (e): engine-level TDE (WAL + segments + manifest).
            .encryption_key = config.encryption_key,
        };

        const engine_ptr = try allocator.create(ts_storage.engine.Engine);
        errdefer allocator.destroy(engine_ptr);

        engine_ptr.* = try ts_storage.engine.Engine.init(allocator, engine_config, pool_ptr);
        // Engine.init succeeded; assume it took ownership of data_dir_owned.
        data_dir_owned_for_errdefer = null;
        errdefer {
            engine_ptr.deinit();
            allocator.free(engine_ptr.config.data_dir);
        }

        // GAP-0865 (b): in the default `.batch` durability mode the engine's
        // WAL is opened with manual_sync=true — WAL records are written
        // through to the file per append (crash-safe against process death)
        // but fsync'd ONLY by this background syncer (power-loss window
        // bounded by wal_sync_interval_ms, default 100ms). Geode previously
        // never started it, leaving the fsync window unbounded. The engine
        // is at its final heap address here, as the API requires.
        try engine_ptr.startBackgroundSyncer();

        return Store{
            .allocator = allocator,
            .engine = engine_ptr,
            .pool = pool_ptr,
            .config = config,
            .series_cache = std.AutoHashMap(u128, *Series).init(allocator),
        };
    }

    pub fn deinit(self: *Store) void {
        self.invalidateSeriesCacheUnlocked();
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

    /// GAP-0865: force a synchronous memtable flush — on return any
    /// accepted points have been sealed into an on-disk segment and the
    /// manifest published. No-op for the in-memory store.
    pub fn flush(self: *Store) !void {
        self.lockHere();
        defer self.unlockHere();
        if (self.engine) |eng| try eng.flush();
    }

    /// GAP-0865 (c): run a retention pass. Flushes the memtable (so freshly
    /// accepted-but-unflushed old points become prunable segments), then
    /// deletes every whole segment older than the configured
    /// `retention_max_age_ms` from disk and the manifest via the engine's
    /// `pruneExpired`. Returns the number of segments removed. A no-op
    /// (returns 0) when retention is not configured or the store is
    /// in-memory.
    ///
    /// Lock note: `store_mutex` is geode's tier-7 leaf lock; the engine's
    /// internal `mu` is library-internal and is already taken under
    /// `store_mutex` by every existing call path (appendPoints/queryPoints),
    /// so flush/pruneExpired here introduce no new ordering edge.
    pub fn runRetention(self: *Store) !u32 {
        self.lockHere();
        defer self.unlockHere();
        const eng = self.engine orelse return 0;
        if (self.config.retention_max_age_ms == null) return 0;
        try eng.flush();
        const removed = try eng.pruneExpired();
        if (removed > 0) self.refreshSeriesCacheUnlocked(eng);
        return removed;
    }

    /// Tear down every hydrated series (points + key memory). ONLY safe
    /// from `deinit` — external `getSeries` holders would dangle otherwise.
    fn invalidateSeriesCacheUnlocked(self: *Store) void {
        var it = self.series_cache.valueIterator();
        while (it.next()) |s_ptr| {
            const s = s_ptr.*;
            s.points.deinit(self.allocator);
            self.allocator.free(s.key.metric);
            self.allocator.destroy(s);
        }
        self.series_cache.clearRetainingCapacity();
    }

    /// Re-hydrate every cached series from the engine after a retention
    /// prune, IN PLACE: the `*Series` allocations handed out by `getSeries`
    /// stay valid (only the points array is rebuilt — the same mutation
    /// class `insertMany` already performs on cached series). On a refresh
    /// error the series is left EMPTY (conservative: an empty cache entry
    /// can never serve pruned points; the engine remains the source of
    /// truth for `queryRange`/`last`). Caller must hold `store_mutex`.
    fn refreshSeriesCacheUnlocked(self: *Store, eng: *ts_storage.engine.Engine) void {
        var it = self.series_cache.iterator();
        while (it.next()) |entry| {
            const s = entry.value_ptr.*;
            s.points.clearRetainingCapacity();
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            var iter = eng.queryPoints(arena.allocator(), entry.key_ptr.*, 0, std.math.maxInt(i64)) catch {
                continue;
            };
            while (iter.next()) |pt| {
                s.points.append(self.allocator, .{ .ts = pt.ts, .value = pt.value }) catch break;
            }
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

            // GAP-0865 (c): opportunistic retention on the ingest path,
            // throttled to once per `auto_prune_interval_ms`, so a
            // configured retention window actually deletes expired
            // segments on a live server without a dedicated scheduler.
            // Prune-only (no forced flush): natural memtable rotation
            // seals segments; un-flushed points are pruned on a later
            // pass once their segment ages out. Errors are recorded, not
            // propagated — an ingest must not fail because a concurrent
            // prune hit a transient I/O error.
            if (self.config.retention_max_age_ms != null) {
                const now_ns = std.Io.Clock.Timestamp.now(
                    std.Io.Threaded.global_single_threaded.io(),
                    .real,
                ).raw.nanoseconds;
                const now_ms: i64 = @intCast(@divTrunc(now_ns, std.time.ns_per_ms));
                if (now_ms - self.last_auto_prune_ms >= auto_prune_interval_ms) {
                    self.last_auto_prune_ms = now_ms;
                    const removed = eng.pruneExpired() catch |err| blk: {
                        std.log.scoped(.timeseries).warn(
                            "opportunistic retention prune failed: {s}",
                            .{@errorName(err)},
                        );
                        break :blk 0;
                    };
                    if (removed > 0) self.refreshSeriesCacheUnlocked(eng);
                }
            }
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
            // Engine contract: every allocation for the returned iterator is
            // made on the arena passed to queryPoints and is reclaimed by
            // freeing that arena (the iterator has no deinit). Passing the
            // caller's raw allocator here leaked the iterator's heap/slice
            // allocations on every durable-path queryRange (found by the
            // GAP-0865 durability suite under std.testing.allocator).
            var arena = std.heap.ArenaAllocator.init(self.allocator);
            defer arena.deinit();
            var iter = try eng.queryPoints(arena.allocator(), sid, start_ts, end_ts);

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
