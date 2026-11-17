// SONNY-2795 regression: the engine index catalog's DROP INDEX, its readers,
// the global index manager's allocator, and in-memory sessions.
//
//   (1) DROP INDEX removed the catalog row in memory and never saved the
//       catalog, so the dropped index came back after a restart. Now it saves
//       as CREATE INDEX does, and a failed save refuses the statement with the
//       row still in place (memory matches disk).
//   (2) DROP INDEX removed and freed the row without the catalog lock, and
//       the vector-index readers on the write and knn paths
//       (`armVectorDimGuard`, `ensureAdvancedVectorIndexForProperty`) walked
//       the index map without it, so a reader could hold a row DROP INDEX was
//       freeing. Each now takes the catalog rwlock (DROP exclusive, readers
//       shared). The proofs are deterministic, not timing races: the test
//       holds the lock and checks the other side waits for it.
//   (3) CREATE INDEX (`ensureAdvancedRuntimeIndex`) and `armVectorDimGuard`
//       created the process-global index manager with the caller's
//       allocator, a per-request arena, which the manager then outlived.
//   (4) A session with no data directory read and wrote its catalog at the
//       shared /tmp/geode_catalog.dat, so every such session, test or
//       process shared one catalog file and a fresh session loaded whatever
//       an earlier one left there. It is now purely in memory.
//
// Real executor, real persisted store and catalog, real restarts; no mocks.
//
// CANARY: REQ=REQ-SONNY-2795-DROP-INDEX-CATALOG; FEATURE="SchemaCatalog"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2795_drop_index_catalog.zig; OWNER=catalog; UPDATED=2026-11-11

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const index_manager = geode.index_manager;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn sleepMs(ms: u64) void {
    io().sleep(.fromNanoseconds(@as(i96, ms) * std.time.ns_per_ms), .awake) catch {};
}

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

/// The store-level restart harness of tests/test_sonny1319_graph_scoped_catalog.zig.
/// `data_dir == null` is a session with no data directory (in memory).
const Harness = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    tmp: ?std.testing.TmpDir,
    data_dir: ?[]u8,
    session: execution.SessionState,
    ctx: execution.ExecutionContext,

    fn init(allocator: std.mem.Allocator, persisted: bool) !Harness {
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();

        var tmp: ?std.testing.TmpDir = null;
        var data_dir: ?[]u8 = null;
        errdefer if (tmp) |*t| t.cleanup();
        errdefer if (data_dir) |d| allocator.free(d);
        if (persisted) {
            tmp = std.testing.tmpDir(.{});
            data_dir = try tmpDirRealpathAlloc(allocator, &tmp.?.sub_path);
        }

        graph_store.setDataDirOverride(allocator, data_dir);
        _ = graph_store.getGlobalStore(allocator);
        const catalog = try execution.ensureCatalogInstance(allocator);

        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .tmp = tmp,
            .data_dir = data_dir,
            .session = execution.SessionState.init(allocator),
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    fn deinit(self: *Harness) void {
        self.session.deinit();
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        if (self.data_dir) |d| self.allocator.free(d);
        self.arena.deinit();
        if (self.tmp) |*t| t.cleanup();
    }

    fn restart(self: *Harness) !void {
        self.session.deinit();
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();

        _ = graph_store.getGlobalStore(self.allocator);
        const catalog = try execution.ensureCatalogInstance(self.allocator);
        self.session = execution.SessionState.init(self.allocator);
        self.ctx = execution.ExecutionContext{ .catalog = catalog };
    }

    fn exec(self: *Harness, query: []const u8) !execution.ExecutionResult {
        self.ctx.session_state = &self.session;
        const aa = self.arena.allocator();
        var parsed = try geode.parseGqlOptions(query, aa, .{});
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    fn run(self: *Harness, query: []const u8) !void {
        _ = self.exec(query) catch |err| {
            std.debug.print("{s}: {s}\n", .{ query, @errorName(err) });
            return err;
        };
    }

    fn refusal(self: *Harness, query: []const u8) ![]const u8 {
        if (self.exec(query)) |_| {
            std.debug.print("{s}: ran; expected a refusal\n", .{query});
            return error.ExpectedRefusal;
        } else |err| return @errorName(err);
    }

    /// How many SHOW INDEXES rows name `name`.
    fn indexes(self: *Harness, name: []const u8) !usize {
        const res = try self.exec("SHOW INDEXES");
        var n: usize = 0;
        for (res.rows) |row| {
            if (row.len == 0) continue;
            switch (row[0]) {
                .Str => |s| if (std.mem.eql(u8, s, name)) {
                    n += 1;
                },
                else => {},
            }
        }
        return n;
    }
};

/// Run `op` on its own thread while the test holds `catalog.rwlock` (shared
/// or exclusive per `exclusive`). Returns whether `op` finished while the
/// lock was still held; then releases the lock and joins. An `op` that takes
/// the conflicting lock cannot finish in the window — deterministically — and
/// one that ignores the lock finishes in milliseconds.
fn finishedWhileLockHeld(
    catalog: anytype,
    exclusive: bool,
    comptime op: anytype,
    args: anytype,
) !bool {
    const Runner = struct {
        done: std.atomic.Value(bool) = .init(false),
        failed: ?anyerror = null,

        fn go(self: *@This(), a: @TypeOf(args)) void {
            @call(.auto, op, a) catch |err| {
                self.failed = err;
            };
            self.done.store(true, .release);
        }
    };

    if (exclusive) catalog.rwlock.lockUncancelable(io()) else catalog.rwlock.lockSharedUncancelable(io());
    var held = true;
    defer if (held) {
        if (exclusive) catalog.rwlock.unlock(io()) else catalog.rwlock.unlockShared(io());
    };

    var runner: Runner = .{};
    const t = try std.Thread.spawn(.{}, Runner.go, .{ &runner, args });

    // 2 s is orders of magnitude longer than any `op` here takes unlocked.
    var waited: u64 = 0;
    while (waited < 2000 and !runner.done.load(.acquire)) : (waited += 10) sleepMs(10);
    const finished = runner.done.load(.acquire);

    if (exclusive) catalog.rwlock.unlock(io()) else catalog.rwlock.unlockShared(io());
    held = false;
    t.join();
    if (runner.failed) |err| {
        std.debug.print("op under the catalog-lock check failed: {s}\n", .{@errorName(err)});
        return err;
    }
    return finished;
}

extern "c" fn chmod(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

fn setMode(buf: []u8, comptime fmt: []const u8, args: anytype, mode: c_uint) !void {
    const path = try std.fmt.bufPrint(buf, fmt, args);
    buf[path.len] = 0;
    if (chmod(buf[0..path.len :0], mode) != 0) return error.ChmodFailed;
}

const SHARED_TMP_CATALOG = "/tmp/geode_catalog.dat";

/// The shared file's bytes, or null when it does not exist.
fn readSharedTmpCatalog(allocator: std.mem.Allocator) !?[]u8 {
    return std.Io.Dir.cwd().readFileAlloc(io(), SHARED_TMP_CATALOG, allocator, .limited(64 * 1024 * 1024)) catch |err| switch (err) {
        error.FileNotFound => null,
        else => err,
    };
}

// (4) first: it needs a store with no data directory, and must run before
// any HNSW index exists (see the note on the last test).
test "SONNY-2795 (4): a session with no data directory keeps its catalog in memory, not in /tmp/geode_catalog.dat" {
    // A unique index name: whatever else on this machine uses the shared
    // file, only this run writes this name.
    var name_buf: [64]u8 = undefined;
    var rnd: [8]u8 = undefined;
    io().random(&rnd);
    const idx_name = try std.fmt.bufPrint(&name_buf, "sonny2795_mem_{x}", .{std.mem.readInt(u64, &rnd, .little)});

    // No data directory: neither the override nor GEODE_DATA_DIR.
    const saved_env: ?[]u8 = if (std.c.getenv("GEODE_DATA_DIR")) |p| try testing.allocator.dupe(u8, std.mem.span(p)) else null;
    defer if (saved_env) |v| {
        const z = testing.allocator.dupeZ(u8, v) catch unreachable;
        defer testing.allocator.free(z);
        _ = setenv("GEODE_DATA_DIR", z, 1);
        testing.allocator.free(v);
    };
    _ = unsetenv("GEODE_DATA_DIR");

    // Hygiene for a run against an engine that still writes the shared file:
    // put back what was there if (and only if) this run's index reached it.
    const before = try readSharedTmpCatalog(testing.allocator);
    defer if (before) |b| testing.allocator.free(b);
    defer {
        if (readSharedTmpCatalog(testing.allocator) catch null) |after| {
            defer testing.allocator.free(after);
            if (std.mem.indexOf(u8, after, idx_name) != null) {
                if (before) |b| {
                    if (std.Io.Dir.cwd().createFile(io(), SHARED_TMP_CATALOG, .{})) |f| {
                        defer f.close(io());
                        f.writeStreamingAll(io(), b) catch {};
                    } else |_| {}
                } else {
                    std.Io.Dir.cwd().deleteFile(io(), SHARED_TMP_CATALOG) catch {};
                }
            }
        }
    }

    var h = try Harness.init(testing.allocator, false);
    defer h.deinit();

    // A fresh in-memory session starts empty, whatever the shared file holds.
    try testing.expectEqual(@as(u32, 0), h.ctx.catalog.indexes.count());

    var create_buf: [128]u8 = undefined;
    try h.run(try std.fmt.bufPrint(&create_buf, "CREATE INDEX {s} FOR (n:Mem2795) ON (n.k)", .{idx_name}));
    try testing.expectEqual(@as(usize, 1), try h.indexes(idx_name));

    // A new in-memory session is a new, empty catalog: nothing carried over
    // through a shared file.
    try h.restart();
    try testing.expectEqual(@as(usize, 0), try h.indexes(idx_name));
    try testing.expectEqual(@as(u32, 0), h.ctx.catalog.indexes.count());
}

test "SONNY-2795 (1): DROP INDEX is saved; a dropped index stays dropped after a restart" {
    var h = try Harness.init(testing.allocator, true);
    defer h.deinit();

    try h.run("CREATE INDEX durable_idx FOR (n:D2795) ON (n.k)");
    try h.run("CREATE INDEX kept_idx FOR (n:D2795) ON (n.j)");
    try h.restart();
    try testing.expectEqual(@as(usize, 1), try h.indexes("durable_idx"));

    try h.run("DROP INDEX durable_idx");
    try testing.expectEqual(@as(usize, 0), try h.indexes("durable_idx"));
    try h.restart();
    try testing.expectEqual(@as(usize, 0), try h.indexes("durable_idx"));
    try testing.expectEqual(@as(usize, 1), try h.indexes("kept_idx"));
    try testing.expectEqualStrings("IndexNotFound", try h.refusal("DROP INDEX durable_idx"));

    // In a named graph too (the SONNY-1319 graph-scoped row).
    try h.run("CREATE GRAPH g2795");
    try h.run("USE GRAPH g2795");
    try h.run("CREATE INDEX graph_idx FOR (n:D2795) ON (n.k)");
    try h.run("DROP INDEX graph_idx");
    try h.restart();
    try h.run("USE GRAPH g2795");
    try testing.expectEqual(@as(usize, 0), try h.indexes("graph_idx"));
}

test "SONNY-2795 (1): a DROP INDEX whose catalog save fails is refused, and the index stays" {
    // Root writes through a read-only mode: nothing to test.
    if (std.os.linux.geteuid() == 0) return error.SkipZigTest;
    var h = try Harness.init(testing.allocator, true);
    defer h.deinit();

    try h.run("CREATE INDEX ro_idx FOR (n:R2795) ON (n.k)");
    const dir = h.data_dir.?;

    // The catalog file and its directory read-only: every save fails.
    var buf: [std.fs.max_path_bytes + 1]u8 = undefined;
    try setMode(&buf, "{s}/geode_catalog.dat", .{dir}, 0o400);
    try setMode(&buf, "{s}", .{dir}, 0o500);
    var restored = false;
    defer if (!restored) {
        setMode(&buf, "{s}", .{dir}, 0o700) catch {};
        setMode(&buf, "{s}/geode_catalog.dat", .{dir}, 0o600) catch {};
    };

    const refused = try h.refusal("DROP INDEX ro_idx");
    try testing.expect(!std.mem.eql(u8, refused, "IndexNotFound"));
    // Memory matches disk: the row is still there.
    try testing.expectEqual(@as(usize, 1), try h.indexes("ro_idx"));

    try setMode(&buf, "{s}", .{dir}, 0o700);
    try setMode(&buf, "{s}/geode_catalog.dat", .{dir}, 0o600);
    restored = true;

    try h.restart();
    try testing.expectEqual(@as(usize, 1), try h.indexes("ro_idx"));
    try h.run("DROP INDEX ro_idx");
    try h.restart();
    try testing.expectEqual(@as(usize, 0), try h.indexes("ro_idx"));
}

fn dropIndex(h: *Harness, query: []const u8) !void {
    try h.run(query);
}

test "SONNY-2795 (2): DROP INDEX waits for a reader holding the catalog lock" {
    var h = try Harness.init(testing.allocator, true);
    defer h.deinit();

    try h.run("CREATE INDEX locked_idx FOR (n:L2795) ON (n.k)");

    // A reader holds the catalog shared (as SHOW INDEXES and the planner do
    // while they read a row): DROP INDEX must not remove and free the row
    // until the reader is done.
    const finished = try finishedWhileLockHeld(h.ctx.catalog, false, dropIndex, .{ &h, "DROP INDEX locked_idx" });
    try testing.expect(!finished);
    // ...and then it does drop it.
    try testing.expectEqual(@as(usize, 0), try h.indexes("locked_idx"));
}

fn armGuard(allocator: std.mem.Allocator, label: []const u8, property: []const u8) !void {
    const labels = [_][]const u8{label};
    try execution.statement_dispatcher.armVectorDimGuard(allocator, &labels, property);
}

fn ensureVectorIndex(allocator: std.mem.Allocator, property: []const u8) !void {
    try execution.statement_dispatcher.ensureAdvancedVectorIndexForProperty(allocator, property);
}

// SONNY-2795 (remaining): a DROP INDEX landing between the knn path's copy
// of the catalog row (`ensureAdvancedVectorIndexForProperty`) and its build
// found no runtime index to tear down, and the build then left one, with its
// dimension pin, and no catalog row until the next DROP or restart. The
// build now reads the row again under the shared catalog lock and tears down
// what it built when the row is gone.
//
// A lock-wait proof, not a timing race: the test holds the global index
// manager mutex, which the build takes right after its copy (creating or
// finding the manager) and DROP INDEX never takes. The DROP runs to
// completion while the build waits there; then the build is let go.
fn dropOnThread(h: *Harness, done: *std.atomic.Value(bool)) void {
    var r = h.exec("DROP INDEX v2795race") catch |err| {
        std.debug.print("DROP INDEX failed: {s}\n", .{@errorName(err)});
        return;
    };
    r.deinit(h.arena.allocator());
    done.store(true, .release);
}

fn ensureOnThread(allocator: std.mem.Allocator, failed: *?anyerror) void {
    ensureVectorIndex(allocator, "emb_race") catch |err| {
        failed.* = err;
    };
}

fn dropBetweenCopyAndBuild(h: *Harness) !void {
    try h.run("CREATE INDEX v2795race ON V2795R (emb_race) USING vector WITH (metric = 'l2')");
    try h.restart();
    // After the restart only the catalog row is there; the knn path builds
    // the runtime index from it on first use.
    try testing.expectEqual(@as(usize, 1), try h.indexes("v2795race"));

    index_manager.global_index_manager_mutex.lockUncancelable(io());
    var held = true;
    defer if (held) index_manager.global_index_manager_mutex.unlock(io());

    var failed: ?anyerror = null;
    const builder = try std.Thread.spawn(.{}, ensureOnThread, .{ h.allocator, &failed });
    // The builder copies the row under the shared catalog lock, releases
    // it, and waits for the manager mutex. 500 ms is orders of magnitude
    // longer than that copy takes.
    sleepMs(500);
    var dropped = std.atomic.Value(bool).init(false);
    const dropper = try std.Thread.spawn(.{}, dropOnThread, .{ h, &dropped });
    dropper.join();
    try testing.expect(dropped.load(.acquire));
    try testing.expectEqual(@as(usize, 0), try h.indexes("v2795race"));

    index_manager.global_index_manager_mutex.unlock(io());
    held = false;
    builder.join();
    if (failed) |err| return err;

    const mgr = index_manager.getGlobalIndexManager() orelse return error.NoIndexManager;
    try testing.expect(!mgr.hasAdvancedVectorIndexForProperty("emb_race"));
    try testing.expect(!mgr.vector_dim_registry.contains("default\x1fv2795race"));
}

// One harness for every HNSW phase, and last in the file: the hnsw library
// keeps a worker pool alive across index lifetimes, so a later test's store
// re-init would tear global state out from under parked pool threads
// (tests/test_eng3912_dim_pinning.zig, tests/test_sonny1319_graph_scoped_catalog.zig).
test "SONNY-2795 (3)+(2): the global index manager does not adopt a request allocator; vector readers take the catalog lock" {
    var h = try Harness.init(testing.allocator, true);
    defer h.deinit();
    const arena_ptr: *anyopaque = @ptrCast(&h.arena);

    // ---- (3) CREATE INDEX (ensureAdvancedRuntimeIndex) ----
    try testing.expect(index_manager.getGlobalIndexManager() == null);
    try h.run("CREATE INDEX v2795 ON V2795 (emb) USING vector WITH (metric = 'l2')");
    {
        const mgr = index_manager.getGlobalIndexManager() orelse return error.NoIndexManager;
        // The executor's allocator is the per-request arena; the manager is
        // process-lifetime.
        try testing.expect(mgr.allocator.ptr != arena_ptr);
        try testing.expect(mgr.allocator.vtable == std.heap.smp_allocator.vtable);
    }

    // ---- (3) armVectorDimGuard, the first to need the manager after a restart ----
    try h.restart();
    try testing.expect(index_manager.getGlobalIndexManager() == null);
    try armGuard(h.arena.allocator(), "V2795", "emb");
    {
        const mgr = index_manager.getGlobalIndexManager() orelse return error.NoIndexManager;
        try testing.expect(mgr.allocator.ptr != arena_ptr);
        try testing.expect(mgr.allocator.vtable == std.heap.smp_allocator.vtable);
    }

    // ---- (2) armVectorDimGuard reads the catalog under its lock ----
    // A writer (DROP INDEX) holds the catalog exclusive: the guard must wait,
    // not walk rows that are being freed.
    try h.restart();
    try testing.expect(!try finishedWhileLockHeld(h.ctx.catalog, true, armGuard, .{ h.allocator, "V2795", "emb" }));
    // ...and then it arms the guard from the row.
    {
        const mgr = index_manager.getGlobalIndexManager() orelse return error.NoIndexManager;
        try testing.expect(mgr.vector_dim_registry.contains("default\x1fv2795"));
    }

    // ---- (2) the knn path's lazy rebuild reads the catalog under its lock ----
    try h.restart();
    try testing.expect(!try finishedWhileLockHeld(h.ctx.catalog, true, ensureVectorIndex, .{ h.allocator, "emb" }));
    {
        const mgr = index_manager.getGlobalIndexManager() orelse return error.NoIndexManager;
        try testing.expect(mgr.hasAdvancedVectorIndexForProperty("emb"));
    }

    // SONNY-2795 (remaining): a DROP INDEX between the knn path's catalog
    // copy and its build.
    try dropBetweenCopyAndBuild(&h);

    // A dropped vector index is gone after a restart, and the rebuild does
    // not bring it back.
    try h.run("DROP INDEX v2795");
    try h.restart();
    try testing.expectEqual(@as(usize, 0), try h.indexes("v2795"));
    try ensureVectorIndex(h.allocator, "emb");
    if (index_manager.getGlobalIndexManager()) |mgr| {
        try testing.expect(!mgr.hasAdvancedVectorIndexForProperty("emb"));
    }
}
