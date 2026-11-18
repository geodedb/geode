const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;

// GAP-0865: Time-series durability regression suite.
//
// ============================================================================
// INVESTIGATION RECORD (2026-06-10) — engine vs wrapper findings
// ============================================================================
//
// The authoritative gap evidence (docs/optimizing-ts-storage.md) was written
// against the LEGACY ChunkStorage persistence model (best-effort full-series
// snapshotting, chunks.dat/chunk_meta.dat/series_meta.dat). That model is
// GONE: geode's `src/timeseries/timeseries.zig` Store now delegates to the
// external `timeseries-storage` LSM engine (pinned v0.2.3 in build.zig.zon).
//
// What the ENGINE (timeseries-storage v0.2.3) already provides:
//   * WAL-first writes: `Engine.appendPoints` persists to a CRC32C-checksummed
//     WAL (write-through to the file via write(2) per record) BEFORE the
//     memtable insert. WAL replay on `Engine.init` recovers un-flushed points.
//   * Fail-closed open by default: `EngineConfig.wal_recovery = .fail_closed`
//     surfaces WAL checksum/deserialisation errors AND missing/corrupt
//     segments (verifySegments) as init errors instead of silently dropping.
//   * Crash-atomic segment publication: immutable `<id>.tsseg` segments +
//     double-slot manifest (`manifest.a`/`manifest.b`) with atomic publish.
//   * Retention: `EngineConfig.retention_max_age_ms` + `Engine.pruneExpired()`
//     unlinks whole expired segments from disk and the manifest.
//   * TDE: `EngineConfig.encryption_key` (AES-256-GCM) encrypts WAL records,
//     segment blocks (TSSEG003), and the manifest (TSMNF002), fail-closed on
//     wrong/missing key.
//   * Backup: `backup.zig` checkpoint/snapshot/restore helpers.
//
// What GEODE'S WRAPPER + integration was missing (the actual GAP-0865 gaps):
//   (a) Fail-soft swallowing: `graph_storage_adapter.initTimeseriesForGraph`
//       and `src/server/main.zig` caught EVERY init/load error (including
//       corruption surfaced fail-closed by the engine) and degraded to an
//       empty in-memory store with only a log.warn. On a FRESH data dir the
//       server-wide store ALWAYS degraded to memory-only because the engine
//       refuses to mkdir its own data_dir and nothing created
//       `{data_dir}/timeseries` -> error.FileNotFound -> silent fallback.
//   (b) No WAL fsync cadence: the engine's wal_manager opens the WAL with
//       `manual_sync = true`; in the default `.batch` durability mode fsync
//       happens ONLY via the background syncer thread — which geode never
//       started (`startBackgroundSyncer` was never called). Accepted writes
//       were durable against process crash (write-through) but had an
//       unbounded fsync window against power loss.
//   (c) Retention never wired: geode never set `retention_max_age_ms` and
//       never called `pruneExpired()` — expired data was NEVER deleted.
//   (d) Backup: `readPerGraphStoragePayload` (post-GAP-0862) already archives
//       every top-level entry under data_dir recursively, which structurally
//       includes `timeseries/` trees — but nothing verified the TS round-trip
//       (the optimizing-ts-storage.md "GraphStore-only" claim is stale).
//   (e) TDE never wired: the engine's `encryption_key` was always null.
//
// The fixes live in `src/timeseries/timeseries.zig` (StoreConfig.durability /
// retention_max_age_ms / encryption_key, dir auto-create, startBackgroundSyncer,
// flush(), runRetention()), `src/storage/graph_storage_adapter.zig`, and
// `src/server/main.zig` (fail-closed by default, GEODE_TS_DURABILITY=
// best_effort opt-out, GEODE_TS_RETENTION_DAYS, GEODE_TS_TDE=1).
// ============================================================================
//
// CANARY: REQ=REQ-TS-DURABILITY-001; FEATURE="TimeSeriesFailClosedOpen"; ASPECT=Startup; STATUS=TESTED; TEST=tests/ts_durability.zig; OWNER=timeseries; UPDATED=2026-06-10
// CANARY: REQ=REQ-TS-DURABILITY-002; FEATURE="TimeSeriesWalCrashRecovery"; ASPECT=Durability; STATUS=TESTED; TEST=tests/ts_durability.zig; OWNER=timeseries; UPDATED=2026-06-10
// CANARY: REQ=REQ-TS-RETENTION-002; FEATURE="TimeSeriesRetentionPrune"; ASPECT=Lifecycle; STATUS=TESTED; TEST=tests/ts_durability.zig; OWNER=timeseries; UPDATED=2026-06-10
// CANARY: REQ=REQ-TS-BACKUP-001; FEATURE="TimeSeriesBackupRestore"; ASPECT=Backup; STATUS=TESTED; TEST=tests/ts_durability.zig; OWNER=timeseries; UPDATED=2026-06-10
// CANARY: REQ=REQ-TS-TDE-001; FEATURE="TimeSeriesTDE"; ASPECT=Security; STATUS=TESTED; TEST=tests/ts_durability.zig; OWNER=timeseries; UPDATED=2026-06-10

const geode = @import("geode");
const ts = geode.timeseries;
const backup = @import("storage/backup");
const graph_store = geode.graph_store;

// ---------------------------------------------------------------------------
// Temp-dir helpers (mirrors tests/test_gap0862_backup_integrity.zig)
// ---------------------------------------------------------------------------

fn uniqueNanos() i128 {
    var t: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = if (comptime @import("builtin").os.tag == .linux)
        std.os.linux.clock_gettime(.MONOTONIC, &t)
    else
        std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &t);
    return @as(i128, t.sec) * 1_000_000_000 + @as(i128, t.nsec);
}

fn cwdAbsAlloc(allocator: std.mem.Allocator) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return allocator.dupe(u8, cwd_buf[0..actual_len]);
}

fn makeTempDir(allocator: std.mem.Allocator, suffix: []const u8) ![]u8 {
    const base = try cwdAbsAlloc(allocator);
    defer allocator.free(base);
    const path = try std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/ts_dur_{s}_{d}", .{ base, suffix, uniqueNanos() });
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().createDirPath(io, path) catch |err| switch (err) {
        error.PathAlreadyExists => {},
        else => return err,
    };
    return path;
}

fn cleanupTempDir(allocator: std.mem.Allocator, dir: []const u8) void {
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().deleteTree(io, dir) catch {};
    allocator.free(dir);
}

/// Count `*.tsseg` segment files under `{data_dir}/timeseries`.
fn countSegments(allocator: std.mem.Allocator, data_dir: []const u8) !usize {
    const io = std.Io.Threaded.global_single_threaded.io();
    const ts_dir_path = try std.fmt.allocPrint(allocator, "{s}/timeseries", .{data_dir});
    defer allocator.free(ts_dir_path);
    var dir = std.Io.Dir.cwd().openDir(io, ts_dir_path, .{ .iterate = true }) catch return 0;
    defer dir.close(io);
    var count: usize = 0;
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".tsseg")) count += 1;
    }
    return count;
}

/// Overwrite the first `n` bytes of every `*.tsseg` under
/// `{data_dir}/timeseries` with 0xFF (destroys the segment magic).
fn corruptSegments(allocator: std.mem.Allocator, data_dir: []const u8) !usize {
    const io = std.Io.Threaded.global_single_threaded.io();
    const ts_dir_path = try std.fmt.allocPrint(allocator, "{s}/timeseries", .{data_dir});
    defer allocator.free(ts_dir_path);
    var dir = try std.Io.Dir.cwd().openDir(io, ts_dir_path, .{ .iterate = true });
    defer dir.close(io);
    var corrupted: usize = 0;
    var iter = dir.iterate();
    while (try iter.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".tsseg")) continue;
        const full = try std.fmt.allocPrint(allocator, "{s}/{s}", .{ ts_dir_path, entry.name });
        defer allocator.free(full);
        const f = try std.Io.Dir.cwd().openFile(io, full, .{ .mode = .read_write });
        defer f.close(io);
        const garbage = [_]u8{0xFF} ** 16;
        try f.writePositionalAll(io, &garbage, 0);
        corrupted += 1;
    }
    return corrupted;
}

const key_a = ts.SeriesKey{ .device_id = 1, .metric = "cpu" };

/// Insert points and force a synchronous segment flush.
fn insertAndFlush(st: *ts.Store, key: ts.SeriesKey, pts: []const ts.Point) !void {
    try st.insertMany(key, pts);
    try st.flush();
}

// ---------------------------------------------------------------------------
// (a) Corrupt/truncated TS data must FAIL CLOSED on open by default
// ---------------------------------------------------------------------------

test "GAP-0865a corrupted segment fails closed on open (default durability)" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    const data_dir = try makeTempDir(allocator, "failclosed");
    defer cleanupTempDir(allocator, data_dir);

    // Phase 1: write durable data with at least one sealed segment.
    {
        var st = try ts.Store.initWithConfig(allocator, .{ .data_dir = data_dir });
        defer st.deinit();
        try insertAndFlush(&st, key_a, &.{
            .{ .ts = 100, .value = 1 },
            .{ .ts = 200, .value = 2 },
            .{ .ts = 300, .value = 3 },
        });
    }
    try testing.expect((try countSegments(allocator, data_dir)) >= 1);

    // Phase 2: corrupt every segment (destroy magic bytes).
    try testing.expect((try corruptSegments(allocator, data_dir)) >= 1);

    // Phase 3: default (fail-closed) open must surface an error — NOT a
    // silently-empty store.
    const result = ts.Store.initWithConfig(allocator, .{ .data_dir = data_dir });
    if (result) |st_const| {
        var st = st_const;
        st.deinit();
        return error.CorruptedStoreOpenedSilently;
    } else |_| {
        // Any error is acceptable; the point is that the corruption is
        // surfaced rather than swallowed.
    }
}

test "GAP-0865a best_effort durability degrades to in-memory instead of failing" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    const data_dir = try makeTempDir(allocator, "besteffort");
    defer cleanupTempDir(allocator, data_dir);

    {
        var st = try ts.Store.initWithConfig(allocator, .{ .data_dir = data_dir });
        defer st.deinit();
        try insertAndFlush(&st, key_a, &.{.{ .ts = 100, .value = 1 }});
    }
    _ = try corruptSegments(allocator, data_dir);

    // Explicitly-configured best_effort: open succeeds, degraded to the
    // in-memory store (engine == null), still usable for new writes.
    var st = try ts.Store.initWithConfig(allocator, .{
        .data_dir = data_dir,
        .durability = .best_effort,
    });
    defer st.deinit();
    try testing.expect(st.engine == null);
    try st.insertMany(key_a, &.{.{ .ts = 500, .value = 5 }});
    const l = st.last(key_a) orelse return error.InMemoryWriteLost;
    try testing.expectEqual(@as(i64, 500), l.ts);
}

// ---------------------------------------------------------------------------
// (b) Hard-kill (no deinit, no flush, no sync) must not lose accepted writes
// ---------------------------------------------------------------------------

test "GAP-0865b hard-kill without flush/deinit preserves accepted writes via WAL replay" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    const data_dir = try makeTempDir(allocator, "hardkill");
    defer cleanupTempDir(allocator, data_dir);

    // Phase 1: simulate a hard kill — the store is heap-built with the page
    // allocator and is intentionally NEVER deinit'd / flushed / synced. The
    // only durability the points have is the engine's write-ahead log.
    {
        const crash_alloc = std.heap.page_allocator;
        const st = try crash_alloc.create(ts.Store);
        st.* = try ts.Store.initWithConfig(crash_alloc, .{ .data_dir = data_dir });
        try st.insertMany(key_a, &.{
            .{ .ts = 1000, .value = 10 },
            .{ .ts = 2000, .value = 20 },
            .{ .ts = 3000, .value = 30 },
        });
        // NO st.deinit(), NO st.flush(), NO st.sync() — abandoned, exactly
        // like a killed process (the WAL file content is what survives).
    }

    // Phase 2: re-open and verify WAL replay recovered all three points.
    var st2 = try ts.Store.initWithConfig(allocator, .{ .data_dir = data_dir });
    defer st2.deinit();
    const pts = try st2.queryRange(key_a, 0, 10_000, allocator);
    defer allocator.free(pts);
    try testing.expectEqual(@as(usize, 3), pts.len);
    try testing.expectEqual(@as(i64, 1000), pts[0].ts);
    try testing.expectEqual(@as(i64, 30), pts[2].value);
}

// ---------------------------------------------------------------------------
// (c) Retention must actually delete expired data from disk and queries
// ---------------------------------------------------------------------------

test "GAP-0865c retention pass deletes expired segments from disk and queries" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    const data_dir = try makeTempDir(allocator, "retention");
    defer cleanupTempDir(allocator, data_dir);

    // now=1_000_000ms, max_age=1_000ms -> cutoff=999_000ms.
    var st = try ts.Store.initWithConfig(allocator, .{
        .data_dir = data_dir,
        .retention_max_age_ms = 1_000,
        .retention_now_override = 1_000_000,
    });
    defer st.deinit();

    // Old segment: entirely before the cutoff.
    try insertAndFlush(&st, key_a, &.{
        .{ .ts = 100, .value = 1 },
        .{ .ts = 200, .value = 2 },
    });
    // New segment: entirely after the cutoff.
    try insertAndFlush(&st, key_a, &.{
        .{ .ts = 999_500, .value = 95 },
        .{ .ts = 999_900, .value = 99 },
    });

    const before = try countSegments(allocator, data_dir);
    try testing.expect(before >= 2);

    const removed = try st.runRetention();
    try testing.expect(removed >= 1);

    // Disk: expired segment file(s) unlinked.
    const after = try countSegments(allocator, data_dir);
    try testing.expect(after < before);

    // Queries: expired points gone, fresh points intact.
    const old_pts = try st.queryRange(key_a, 0, 998_999, allocator);
    defer allocator.free(old_pts);
    try testing.expectEqual(@as(usize, 0), old_pts.len);

    const new_pts = try st.queryRange(key_a, 999_000, 1_000_000, allocator);
    defer allocator.free(new_pts);
    try testing.expectEqual(@as(usize, 2), new_pts.len);
    try testing.expectEqual(@as(i64, 999_500), new_pts[0].ts);
}

test "GAP-0865c retention disabled by default — runRetention is a no-op" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    const data_dir = try makeTempDir(allocator, "noretention");
    defer cleanupTempDir(allocator, data_dir);

    var st = try ts.Store.initWithConfig(allocator, .{ .data_dir = data_dir });
    defer st.deinit();
    try insertAndFlush(&st, key_a, &.{.{ .ts = 100, .value = 1 }});

    const removed = try st.runRetention();
    try testing.expectEqual(@as(u32, 0), removed);

    const pts = try st.queryRange(key_a, 0, 1_000, allocator);
    defer allocator.free(pts);
    try testing.expectEqual(@as(usize, 1), pts.len);
}

// ---------------------------------------------------------------------------
// (d) Backup -> wipe -> restore must round-trip time-series points
// ---------------------------------------------------------------------------

fn initAdapterForDir(allocator: std.mem.Allocator, data_dir: []const u8) !void {
    graph_store.deinitGlobalStore();
    graph_store.deinitGlobalAdapter();
    graph_store.setDataDirOverride(allocator, data_dir);
    _ = try graph_store.initGlobalAdapter(allocator, data_dir);
}

fn resetGlobalStorage(allocator: std.mem.Allocator) void {
    graph_store.deinitGlobalStore();
    graph_store.deinitGlobalAdapter();
    graph_store.setDataDirOverride(allocator, null);
}

test "GAP-0865d backup -> wipe -> restore round-trips time-series points" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    defer resetGlobalStorage(allocator);

    const data_dir = try makeTempDir(allocator, "bk_data");
    defer cleanupTempDir(allocator, data_dir);
    try initAdapterForDir(allocator, data_dir);

    // Seed graph-store side (the backup engine checkpoints it) ...
    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    store.data_dir = data_dir;
    const node = try store.createNode(&.{"Sensor"});
    try store.setNodeProperty(node, "name", .{ .String = "thermo-1" });
    try store.saveToFile();

    // ... and the server-wide time-series store at {data_dir}/timeseries
    // (the same layout src/server/main.zig uses for the global store).
    {
        var tstore = try ts.Store.initWithConfig(allocator, .{ .data_dir = data_dir });
        defer tstore.deinit();
        try insertAndFlush(&tstore, key_a, &.{
            .{ .ts = 100, .value = 11 },
            .{ .ts = 200, .value = 22 },
            .{ .ts = 300, .value = 33 },
        });
    }

    const backup_dir = try makeTempDir(allocator, "bk_backups");
    defer cleanupTempDir(allocator, backup_dir);

    var mgr = try backup.BackupManager.init(allocator, backup_dir, .{}, &store);
    defer mgr.deinit();
    const meta = try mgr.createFullBackup();
    try testing.expect(meta.size_bytes > 0);

    // Wipe the original data dir entirely (disaster), restore elsewhere.
    const io = std.Io.Threaded.global_single_threaded.io();
    std.Io.Dir.cwd().deleteTree(io, data_dir) catch {};

    const restore_dir = try makeTempDir(allocator, "bk_restore");
    defer cleanupTempDir(allocator, restore_dir);
    var restored_side = try mgr.restoreInto(restore_dir, meta.timestamp + 1, .{});
    restored_side.deinit();

    // Open a fresh TS store over the restored tree: all points must be back.
    var restored = try ts.Store.initWithConfig(allocator, .{ .data_dir = restore_dir });
    defer restored.deinit();
    const pts = try restored.queryRange(key_a, 0, 1_000, allocator);
    defer allocator.free(pts);
    try testing.expectEqual(@as(usize, 3), pts.len);
    try testing.expectEqual(@as(i64, 11), pts[0].value);
    try testing.expectEqual(@as(i64, 33), pts[2].value);
}

// ---------------------------------------------------------------------------
// (e) TDE: encrypted TS artefacts reopen with the key, fail closed without
// ---------------------------------------------------------------------------

test "GAP-0865e TDE round-trip: reopen with key succeeds, without key fails closed" {
    // SONNY-6770: Linux-only (raw syscalls or /proc); skipped on macOS.
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    const data_dir = try makeTempDir(allocator, "tde");
    defer cleanupTempDir(allocator, data_dir);

    const key: [32]u8 = .{0xA5} ** 32;

    {
        var st = try ts.Store.initWithConfig(allocator, .{
            .data_dir = data_dir,
            .encryption_key = key,
        });
        defer st.deinit();
        try insertAndFlush(&st, key_a, &.{
            .{ .ts = 100, .value = 7 },
            .{ .ts = 200, .value = 8 },
        });
    }

    // Reopen WITH the key: data present.
    {
        var st = try ts.Store.initWithConfig(allocator, .{
            .data_dir = data_dir,
            .encryption_key = key,
        });
        defer st.deinit();
        const pts = try st.queryRange(key_a, 0, 1_000, allocator);
        defer allocator.free(pts);
        try testing.expectEqual(@as(usize, 2), pts.len);
    }

    // Reopen WITHOUT the key: must fail closed (never silently empty).
    const result = ts.Store.initWithConfig(allocator, .{ .data_dir = data_dir });
    if (result) |st_const| {
        var st = st_const;
        st.deinit();
        return error.EncryptedStoreOpenedWithoutKey;
    } else |_| {}

    // Reopen with a WRONG key: must also fail closed.
    var wrong_key = key;
    wrong_key[0] ^= 0xff;
    const wrong_result = ts.Store.initWithConfig(allocator, .{
        .data_dir = data_dir,
        .encryption_key = wrong_key,
    });
    if (wrong_result) |st_const| {
        var st = st_const;
        st.deinit();
        return error.EncryptedStoreOpenedWithWrongKey;
    } else |_| {}
}
