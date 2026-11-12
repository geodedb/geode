// SONNY-6270 regression: DROP CONSTRAINT drops the constraint.
//
// DROP CONSTRAINT answered success and removed nothing: the row stayed in
// the catalog, in SHOW CONSTRAINTS and across a restart, and a UNIQUE
// constraint kept refusing writes. It is now the mirror image of DROP INDEX
// (SONNY-1319, SONNY-2795):
//   * it resolves the name in the session's graph's catalog: the graph's own
//     row, else an engine-wide (legacy) row; a row of another graph is not
//     found (ConstraintNotFound), and IF EXISTS makes a missing name a no-op;
//   * the row is removed and the catalog saved under the catalog lock held
//     EXCLUSIVE; a failed save puts the row back and fails the statement, so
//     memory matches disk and the constraint stays enforced;
//   * a dropped constraint stays dropped after a restart;
//   * a UNIQUE / NODE KEY row's bulk fast-path fence (SONNY-2846) is lowered
//     with it, and stays up while another row that applies in the graph
//     remains (an engine-wide one included);
//   * an engine-wide row dropped from one graph is gone in every graph;
//   * authorization is CREATE CONSTRAINT's / DROP INDEX's;
//   * DDL is not transactional here: a ROLLBACK does not bring back a
//     constraint (or an index) dropped inside the transaction;
//   * `db.constraints()` copies the rows under the catalog lock (it read rows
//     the catalog owned after the lock was released, which a real DROP would
//     have turned into a use-after-free).
//
// Real executor, real stores and catalog, real restarts; no mocks.
//
// CANARY: REQ=REQ-SONNY-6270-DROP-CONSTRAINT; FEATURE="SchemaCatalog"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6270_drop_constraint.zig; OWNER=catalog; UPDATED=2026-11-11

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const index_manager = geode.index_manager;
const gps = geode.security.gps;
const principal_mod = geode.security.principal;

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

extern "c" fn chmod(path: [*:0]const u8, mode: c_uint) c_int;
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

fn setMode(buf: []u8, comptime fmt: []const u8, args: anytype, mode: c_uint) !void {
    const path = try std.fmt.bufPrint(buf, fmt, args);
    buf[path.len] = 0;
    if (chmod(buf[0..path.len :0], mode) != 0) return error.ChmodFailed;
}

/// The restart harness of tests/test_sonny2846_unique_constraint_enforcement.zig:
/// `persisted` false is a session with no data directory (in memory).
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

    /// The error `query` was refused with, by name.
    fn refusal(self: *Harness, query: []const u8) ![]const u8 {
        if (self.exec(query)) |_| {
            std.debug.print("{s}: ran; expected a refusal\n", .{query});
            return error.ExpectedRefusal;
        } else |err| return @errorName(err);
    }

    fn expectRefusal(self: *Harness, query: []const u8, expected: []const u8) !void {
        const name = try self.refusal(query);
        if (!std.mem.eql(u8, name, expected)) {
            std.debug.print("{s}: refused with {s}, expected {s}\n", .{ query, name, expected });
            return error.WrongRefusal;
        }
    }

    /// `query` must be refused as a unique violation (23505 on the wire).
    fn expectViolation(self: *Harness, query: []const u8) !void {
        try self.expectRefusal(query, "UniqueConstraintViolation");
    }

    /// The single integer cell `query` returns.
    fn count(self: *Harness, query: []const u8) !i64 {
        const res = self.exec(query) catch |err| {
            std.debug.print("{s}: {s}\n", .{ query, @errorName(err) });
            return err;
        };
        if (res.rows.len != 1 or res.rows[0].len < 1) {
            std.debug.print("{s}: {d} rows\n", .{ query, res.rows.len });
            return error.UnexpectedRows;
        }
        return switch (res.rows[0][0]) {
            .Int => |v| v,
            else => error.UnexpectedValue,
        };
    }

    /// How many rows `query` (SHOW CONSTRAINTS / CALL db.constraints())
    /// returns whose first cell is `name`.
    fn rowsNamed(self: *Harness, query: []const u8, name: []const u8) !usize {
        const res = try self.exec(query);
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

    fn listed(self: *Harness, name: []const u8) !bool {
        return try self.rowsNamed("SHOW CONSTRAINTS", name) > 0;
    }

    fn showCount(self: *Harness) !usize {
        const res = try self.exec("SHOW CONSTRAINTS");
        return res.rows.len;
    }
};

fn unsetDataDirEnv() !?[]u8 {
    const saved: ?[]u8 = if (std.c.getenv("GEODE_DATA_DIR")) |p| try testing.allocator.dupe(u8, std.mem.span(p)) else null;
    _ = unsetenv("GEODE_DATA_DIR");
    return saved;
}

fn restoreDataDirEnv(saved: ?[]u8) void {
    if (saved) |v| {
        const z = testing.allocator.dupeZ(u8, v) catch unreachable;
        defer testing.allocator.free(z);
        _ = setenv("GEODE_DATA_DIR", z, 1);
        testing.allocator.free(v);
    }
}

/// create -> listed -> violation refused -> DROP -> not listed -> the write
/// runs -> a second DROP is not found -> IF EXISTS is a no-op; then every
/// kind the catalog stores.
fn exerciseCore(h: *Harness) !void {
    try h.run("CREATE CONSTRAINT p_id FOR (n:P) REQUIRE n.id IS UNIQUE");
    try testing.expect(try h.listed("p_id"));
    try testing.expectEqual(@as(usize, 1), try h.rowsNamed("CALL db.constraints()", "p_id"));
    try h.run("CREATE (:P {id: 1})");
    try h.expectViolation("CREATE (:P {id: 1})");
    try testing.expect(graph_store.uniqueFenced("default"));

    try h.run("DROP CONSTRAINT p_id");
    try testing.expect(!try h.listed("p_id"));
    try testing.expectEqual(@as(usize, 0), try h.rowsNamed("CALL db.constraints()", "p_id"));
    try testing.expectEqual(@as(usize, 0), try h.showCount());
    // Enforcement stopped: the write it refused runs.
    try h.run("CREATE (:P {id: 1})");
    try testing.expectEqual(@as(i64, 2), try h.count("MATCH (n:P {id: 1}) RETURN count(n) AS c"));
    // The last UNIQUE row of the graph is gone: so is its fence.
    try testing.expect(!graph_store.uniqueFenced("default"));

    // A second DROP: not found, as DROP INDEX answers; IF EXISTS: a no-op.
    try h.expectRefusal("DROP CONSTRAINT p_id", "ConstraintNotFound");
    try h.run("DROP CONSTRAINT IF EXISTS p_id");
    try h.run("DROP CONSTRAINT IF EXISTS never_was");
    try h.expectRefusal("DROP CONSTRAINT never_was", "ConstraintNotFound");

    // The name is free again: CREATE takes it (over duplicate data: refused,
    // as CREATE CONSTRAINT always is).
    try h.expectViolation("CREATE CONSTRAINT p_id FOR (n:P) REQUIRE n.id IS UNIQUE");
    try h.run("CREATE CONSTRAINT p_id FOR (n:P) REQUIRE n.code IS UNIQUE");
    try testing.expect(try h.listed("p_id"));
    try h.run("DROP CONSTRAINT p_id");

    // Every kind the catalog stores drops, and (SONNY-6281) every kind is
    // enforced and holds a count of the graph's fast-path fence.
    try h.run("CREATE CONSTRAINT k_nk FOR (n:K) REQUIRE (n.a, n.b) IS NODE KEY");
    try h.run("CREATE CONSTRAINT k_nn FOR (n:K) REQUIRE n.c IS NOT NULL");
    try h.run("CREATE CONSTRAINT k_ex ON :K ASSERT EXISTS (d)");
    try testing.expectEqual(@as(usize, 3), try h.showCount());
    try testing.expect(graph_store.uniqueFenced("default"));
    try h.run("CREATE (:K {a: 1, b: 1, c: 1, d: 1})");
    try h.expectViolation("CREATE (:K {a: 1, b: 1, c: 1, d: 1})");
    try h.run("DROP CONSTRAINT k_nk");
    try h.run("CREATE (:K {a: 1, b: 1, c: 1, d: 1})");
    // The NOT NULL and EXISTS rows keep the fence up until the last goes.
    try testing.expect(graph_store.uniqueFenced("default"));
    try h.run("DROP CONSTRAINT k_nn");
    try testing.expect(graph_store.uniqueFenced("default"));
    try h.run("DROP CONSTRAINT k_ex");
    try testing.expect(!graph_store.uniqueFenced("default"));
    try testing.expectEqual(@as(usize, 0), try h.showCount());

    // SONNY-6294: a constraint name is one constraint of the graph: a
    // second label under the name is refused (42710). (A catalog written
    // before that rule may hold one name on two labels: DROP removes both,
    // tests/test_sonny6294_drop_index_rules.zig and below.)
    try h.run("CREATE CONSTRAINT twin_u FOR (n:T1) REQUIRE n.id IS UNIQUE");
    try h.expectRefusal("CREATE CONSTRAINT twin_u FOR (n:T2) REQUIRE n.id IS UNIQUE", "ConstraintAlreadyExists");
    try testing.expectEqual(@as(usize, 1), try h.rowsNamed("SHOW CONSTRAINTS", "twin_u"));
    // One name on two labels (a legacy catalog's rows) is one name to DROP:
    // both go, with both fence counts.
    try plantLegacyUniqueRow(h, "T2", "twin_u");
    try testing.expectEqual(@as(usize, 2), try h.rowsNamed("SHOW CONSTRAINTS", "twin_u"));
    try h.run("DROP CONSTRAINT twin_u");
    try testing.expectEqual(@as(usize, 0), try h.showCount());
    try testing.expect(!graph_store.uniqueFenced("default"));
    try testing.expectEqual(@as(u32, 0), h.ctx.catalog.constraints.count());
}

/// A UNIQUE row of the default graph as a catalog written before
/// SONNY-6294 may hold it (the name already on another label), with the
/// fence count a loaded UNIQUE row raises.
fn plantLegacyUniqueRow(h: *Harness, label: []const u8, name: []const u8) !void {
    const c = h.ctx.catalog;
    const a = c.allocator;
    const props = try a.alloc([]const u8, 1);
    props[0] = try a.dupe(u8, "id");
    const info = geode.catalog.ConstraintInfo{
        .name = try a.dupe(u8, name),
        .constraint_type = .unique,
        .label = try a.dupe(u8, label),
        .properties = props,
        .is_enforced = true,
        .graph = try a.dupe(u8, "default"),
    };
    const key = try std.fmt.allocPrint(a, "default\x1f{s}:{s}", .{ label, name });
    c.rwlock.lockUncancelable(io());
    defer c.rwlock.unlock(io());
    try c.constraints.put(key, info);
    try graph_store.addUniqueFence("default");
}

test "SONNY-6270: DROP CONSTRAINT drops the constraint in an in-memory session" {
    const saved = try unsetDataDirEnv();
    defer restoreDataDirEnv(saved);
    var h = try Harness.init(testing.allocator, false);
    defer h.deinit();
    try exerciseCore(&h);
}

test "SONNY-6270: DROP CONSTRAINT is saved; a dropped constraint stays dropped after a restart, in the default and in a named graph" {
    var h = try Harness.init(testing.allocator, true);
    defer h.deinit();
    try exerciseCore(&h);

    try h.run("CREATE CONSTRAINT durable_u FOR (n:Du) REQUIRE n.id IS UNIQUE");
    try h.run("CREATE CONSTRAINT kept_u FOR (n:Du) REQUIRE n.code IS UNIQUE");
    try h.run("CREATE (:Du {id: 1, code: 'a'})");
    try h.restart();
    try testing.expect(try h.listed("durable_u"));
    try h.expectViolation("CREATE (:Du {id: 1})");

    try h.run("DROP CONSTRAINT durable_u");
    try h.restart();
    try testing.expect(!try h.listed("durable_u"));
    try testing.expect(try h.listed("kept_u"));
    try h.run("CREATE (:Du {id: 1})");
    try h.expectViolation("CREATE (:Du {code: 'a'})");
    try h.expectRefusal("DROP CONSTRAINT durable_u", "ConstraintNotFound");
    // kept_u still applies: the fence is up after the reload.
    try testing.expect(graph_store.uniqueFenced("default"));

    // In a named graph (the SONNY-1319 graph-scoped row).
    try h.run("CREATE GRAPH g6270");
    try h.run("USE GRAPH g6270");
    try h.run("CREATE CONSTRAINT graph_u FOR (n:Gu) REQUIRE n.id IS UNIQUE");
    try h.run("CREATE (:Gu {id: 1})");
    try h.expectViolation("CREATE (:Gu {id: 1})");
    try testing.expect(graph_store.uniqueFenced("g6270"));
    try h.run("DROP CONSTRAINT graph_u");
    try testing.expect(!graph_store.uniqueFenced("g6270"));
    try h.restart();
    try h.run("USE GRAPH g6270");
    try testing.expect(!try h.listed("graph_u"));
    try h.run("CREATE (:Gu {id: 1})");
    try testing.expectEqual(@as(i64, 2), try h.count("MATCH (n:Gu {id: 1}) RETURN count(n) AS c"));
    try testing.expect(!graph_store.uniqueFenced("g6270"));
}

test "SONNY-6270: a constraint is dropped only from its own graph" {
    var h = try Harness.init(testing.allocator, true);
    defer h.deinit();

    try h.run("CREATE CONSTRAINT own_u FOR (n:O) REQUIRE n.id IS UNIQUE");
    try h.run("CREATE (:O {id: 1})");
    try h.run("CREATE GRAPH g6270w");
    try h.run("USE GRAPH g6270w");
    // From another graph: not found, and IF EXISTS drops nothing.
    try h.expectRefusal("DROP CONSTRAINT own_u", "ConstraintNotFound");
    try h.run("DROP CONSTRAINT IF EXISTS own_u");
    try h.run("USE GRAPH default");
    try testing.expect(try h.listed("own_u"));
    try h.expectViolation("CREATE (:O {id: 1})");
    try testing.expect(graph_store.uniqueFenced("default"));
    try h.restart();
    try testing.expect(try h.listed("own_u"));
    try h.expectViolation("CREATE (:O {id: 1})");
}

/// `result` must be the fast-path refusal (by name).
fn expectFastPathRefusal(result: anytype) !void {
    if (result) |_| {
        std.debug.print("a bulk write into a UNIQUE-constrained graph ran\n", .{});
        return error.ExpectedRefusal;
    } else |err| try testing.expectEqualStrings("UniqueConstraintFastPathConflict", @errorName(err));
}

fn bulkInsert(graph: []const u8, label: []const u8, id: i64) !u64 {
    const adapter = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    const PropKV = geode.graph_storage_adapter.StorageAdapter.PropKV;
    const props = [_]PropKV{.{ .key = "id", .value = .{ .Int = id } }};
    const labels = [_][]const u8{label};
    const lock = graph_store.acquireGraphWriteLock(graph);
    defer graph_store.releaseGraphLock(lock);
    return adapter.bulkInsertNode(graph, &labels, &props, null);
}

test "SONNY-6270: the fast-path fence stays up while another UNIQUE row applies, and comes down with the last one" {
    var h = try Harness.init(testing.allocator, true);
    defer h.deinit();

    try h.run("CREATE CONSTRAINT a_u FOR (n:A) REQUIRE n.id IS UNIQUE");
    try h.run("CREATE CONSTRAINT b_u FOR (n:B) REQUIRE n.id IS UNIQUE");
    try h.run("CREATE (:B {id: 1})");
    try testing.expect(geode.bulk_ingest.uniqueConstraintsDeclineFastPath("default"));

    // One of two dropped: the fence stays, the other is enforced.
    try h.run("DROP CONSTRAINT a_u");
    try testing.expect(graph_store.uniqueFenced("default"));
    try testing.expect(geode.bulk_ingest.uniqueConstraintsDeclineFastPath("default"));
    try expectFastPathRefusal(bulkInsert("default", "B", 1));
    try h.expectViolation("CREATE (:B {id: 1})");
    try testing.expectEqual(@as(i64, 1), try h.count("MATCH (n:B {id: 1}) RETURN count(n) AS c"));

    // SONNY-6281: a NOT NULL row holds a count too, so with it in place
    // the last UNIQUE row's drop leaves the fence up.
    try h.run("MATCH (n:B) SET n.name = 'b'");
    try h.run("CREATE CONSTRAINT b_nn FOR (n:B) REQUIRE n.name IS NOT NULL");
    try h.run("DROP CONSTRAINT b_u");
    try testing.expect(graph_store.uniqueFenced("default"));
    try h.run("DROP CONSTRAINT b_nn");

    // The last row dropped: the fast paths serve the graph again.
    try testing.expect(!graph_store.uniqueFenced("default"));
    try testing.expect(!geode.bulk_ingest.uniqueConstraintsDeclineFastPath("default"));
    _ = try bulkInsert("default", "B", 1);
    try testing.expectEqual(@as(i64, 2), try h.count("MATCH (n:B {id: 1}) RETURN count(n) AS c"));

    // Fences are per graph: dropping in g leaves default's alone.
    try h.run("CREATE CONSTRAINT d_u FOR (n:D) REQUIRE n.id IS UNIQUE");
    try h.run("CREATE GRAPH g6270f");
    try h.run("USE GRAPH g6270f");
    try h.run("CREATE CONSTRAINT d_u FOR (n:D) REQUIRE n.id IS UNIQUE");
    try h.run("DROP CONSTRAINT d_u");
    try testing.expect(!graph_store.uniqueFenced("g6270f"));
    try testing.expect(graph_store.uniqueFenced("default"));
    try h.run("USE GRAPH default");
    try testing.expect(try h.listed("d_u"));

    // After a restart the fences are what the catalog holds.
    try h.restart();
    try testing.expect(graph_store.uniqueFenced("default"));
    try testing.expect(!graph_store.uniqueFenced("g6270f"));
}

test "SONNY-6270: an engine-wide (legacy) row dropped from one graph is gone in every graph, and the fences follow" {
    var h = try Harness.init(testing.allocator, true);
    defer h.deinit();

    try h.run("CREATE GRAPH g6270l");
    // An engine-wide row (what a catalog written before rows carried a graph
    // loads as) applies in every graph; registered as the catalog load does.
    const props = [_][]const u8{"k"};
    try h.ctx.catalog.addConstraint(.{
        .name = "legacy_u",
        .constraint_type = .unique,
        .label = "Legacy",
        .properties = @constCast(props[0..]),
        .is_enforced = true,
        .graph = geode.catalog.ENGINE_WIDE_GRAPH,
    });
    try graph_store.addUniqueFence(geode.catalog.ENGINE_WIDE_GRAPH);
    // g6270l also has a UNIQUE row of its own.
    try h.run("USE GRAPH g6270l");
    try h.run("CREATE CONSTRAINT own_l FOR (n:Own) REQUIRE n.id IS UNIQUE");
    try h.run("USE GRAPH default");
    try h.run("CREATE (:Legacy {k: 1})");
    try h.expectViolation("CREATE (:Legacy {k: 1})");
    try testing.expect(graph_store.uniqueFenced("default"));

    // Dropped from g6270l (it is in g6270l's catalog too): gone everywhere.
    try h.run("USE GRAPH g6270l");
    try testing.expect(try h.listed("legacy_u"));
    try h.run("DROP CONSTRAINT legacy_u");
    try testing.expect(!try h.listed("legacy_u"));
    try h.run("CREATE (:Legacy {k: 1})");
    try h.run("CREATE (:Legacy {k: 1})");
    // g6270l keeps its own row's fence; default has none left.
    try testing.expect(graph_store.uniqueFenced("g6270l"));
    try h.run("USE GRAPH default");
    try testing.expect(!try h.listed("legacy_u"));
    try testing.expect(!graph_store.uniqueFenced("default"));
    try h.run("CREATE (:Legacy {k: 1})");
    try testing.expectEqual(@as(i64, 2), try h.count("MATCH (n:Legacy {k: 1}) RETURN count(n) AS c"));

    try h.restart();
    try testing.expect(!try h.listed("legacy_u"));
    try testing.expect(!graph_store.uniqueFenced("default"));
    try testing.expect(graph_store.uniqueFenced("g6270l"));
    try h.run("CREATE (:Legacy {k: 1})");
}

test "SONNY-6270: a DROP CONSTRAINT whose catalog save fails is refused; the constraint stays, enforced, before and after a restart" {
    // Root writes through a read-only mode: nothing to test.
    if (std.os.linux.geteuid() == 0) return error.SkipZigTest;
    var h = try Harness.init(testing.allocator, true);
    defer h.deinit();

    try h.run("CREATE CONSTRAINT ro_u FOR (n:Ro) REQUIRE n.id IS UNIQUE");
    try h.run("CREATE (:Ro {id: 1})");
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

    const refused = try h.refusal("DROP CONSTRAINT ro_u");
    try testing.expect(!std.mem.eql(u8, refused, "ConstraintNotFound"));
    // Memory matches disk: the row is there and enforced, its fence up.
    try testing.expect(try h.listed("ro_u"));
    try testing.expect(graph_store.uniqueFenced("default"));

    try setMode(&buf, "{s}", .{dir}, 0o700);
    try setMode(&buf, "{s}/geode_catalog.dat", .{dir}, 0o600);
    restored = true;
    try h.expectViolation("CREATE (:Ro {id: 1})");

    try h.restart();
    try testing.expect(try h.listed("ro_u"));
    try h.expectViolation("CREATE (:Ro {id: 1})");
    try h.run("DROP CONSTRAINT ro_u");
    try h.restart();
    try testing.expect(!try h.listed("ro_u"));
    try h.run("CREATE (:Ro {id: 1})");
}

/// Run `op` on its own thread while the test holds `catalog.rwlock` (shared
/// or exclusive per `exclusive`). Returns whether `op` finished while the
/// lock was still held (tests/test_sonny2795_drop_index_catalog.zig).
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

fn runQuery(h: *Harness, query: []const u8) !void {
    try h.run(query);
}

/// `query` on a session and arena of its own (for another thread).
fn queryOnOwnSession(catalog: *geode.catalog.Catalog, query: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var session = execution.SessionState.init(std.heap.smp_allocator);
    defer session.deinit();
    const ctx = execution.ExecutionContext{ .catalog = catalog, .session_state = &session };
    var parsed = try geode.parseGqlOptions(query, aa, .{});
    defer parsed.deinit();
    _ = try execution.executeStatementWithContext(aa, parsed.program.statements[0], ctx);
}

/// A reader on its own thread, own session and arena: `CALL
/// db.constraints()` / SHOW CONSTRAINTS in a loop, every row checked to be
/// one of the names the writer uses (a row read out of freed memory is not).
const Reader = struct {
    catalog: *geode.catalog.Catalog,
    query: []const u8,
    stop: *std.atomic.Value(bool),
    bad: ?[]const u8 = null,
    failed: ?anyerror = null,
    reads: usize = 0,

    fn go(self: *Reader) void {
        var session = execution.SessionState.init(std.heap.smp_allocator);
        defer session.deinit();
        const ctx = execution.ExecutionContext{ .catalog = self.catalog, .session_state = &session };
        while (!self.stop.load(.acquire)) {
            var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
            defer arena.deinit();
            const aa = arena.allocator();
            var parsed = geode.parseGqlOptions(self.query, aa, .{}) catch |err| {
                self.failed = err;
                return;
            };
            defer parsed.deinit();
            const res = execution.executeStatementWithContext(aa, parsed.program.statements[0], ctx) catch |err| {
                self.failed = err;
                return;
            };
            for (res.rows) |row| {
                const ok = switch (row[0]) {
                    .Str => |s| std.mem.startsWith(u8, s, "race_u_") and s.len == "race_u_".len + 1,
                    else => false,
                };
                if (!ok) {
                    self.bad = "a row that is no constraint the writer made";
                    return;
                }
            }
            self.reads += 1;
        }
    }
};

test "SONNY-6270: DROP CONSTRAINT waits for a catalog reader; db.constraints() and SHOW CONSTRAINTS copy rows under the catalog lock" {
    var h = try Harness.init(testing.allocator, true);
    defer h.deinit();

    // DROP removes and frees under the lock held EXCLUSIVE: it waits for a
    // reader holding it shared (as SHOW CONSTRAINTS does while it reads).
    try h.run("CREATE CONSTRAINT locked_u FOR (n:Lk) REQUIRE n.id IS UNIQUE");
    try testing.expect(!try finishedWhileLockHeld(h.ctx.catalog, false, runQuery, .{ &h, "DROP CONSTRAINT locked_u" }));
    try testing.expect(!try h.listed("locked_u"));

    // db.constraints() reads the rows under the lock: it waits for a writer.
    try h.run("CREATE CONSTRAINT locked_u FOR (n:Lk) REQUIRE n.id IS UNIQUE");
    try testing.expect(!try finishedWhileLockHeld(h.ctx.catalog, true, queryOnOwnSession, .{ h.ctx.catalog, "CALL db.constraints()" }));
    try h.run("DROP CONSTRAINT locked_u");

    // Readers against a CREATE/DROP loop: every row a reader returns is a
    // copy taken while the row existed (a borrowed row read after a DROP
    // freed it would show the allocator's freed-memory pattern).
    for ([_][]const u8{ "CALL db.constraints()", "SHOW CONSTRAINTS" }) |query| {
        var stop = std.atomic.Value(bool).init(false);
        var readers: [3]Reader = undefined;
        var threads: [3]std.Thread = undefined;
        for (&readers, &threads) |*r, *t| {
            r.* = .{ .catalog = h.ctx.catalog, .query = query, .stop = &stop };
            t.* = try std.Thread.spawn(.{}, Reader.go, .{r});
        }
        var round: usize = 0;
        while (round < 60) : (round += 1) {
            var cbuf: [96]u8 = undefined;
            var dbuf: [64]u8 = undefined;
            const c = round % 10;
            try h.run(try std.fmt.bufPrint(&cbuf, "CREATE CONSTRAINT race_u_{d} FOR (n:Race{d}) REQUIRE n.id IS UNIQUE", .{ c, c }));
            try h.run(try std.fmt.bufPrint(&dbuf, "DROP CONSTRAINT race_u_{d}", .{c}));
        }
        stop.store(true, .release);
        for (threads) |t| t.join();
        for (readers) |r| {
            if (r.failed) |err| return err;
            if (r.bad) |msg| {
                std.debug.print("{s}: {s}\n", .{ query, msg });
                return error.ReaderSawFreedRow;
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), try h.showCount());
}

test "SONNY-6270: DDL is not transactional: a ROLLBACK does not bring back a dropped constraint, as it does not bring back a dropped index" {
    var h = try Harness.init(testing.allocator, true);
    defer h.deinit();

    try h.run("CREATE CONSTRAINT tx_u FOR (n:Tx) REQUIRE n.id IS UNIQUE");
    try h.run("CREATE INDEX tx_idx FOR (n:Tx) ON (n.k)");
    try h.run("CREATE (:Tx {id: 1})");

    try h.run("START TRANSACTION");
    try h.run("DROP INDEX tx_idx");
    try h.run("DROP CONSTRAINT tx_u");
    try h.run("ROLLBACK");

    try testing.expectEqual(@as(usize, 0), try h.rowsNamed("SHOW INDEXES", "tx_idx"));
    try testing.expect(!try h.listed("tx_u"));
    try h.run("CREATE (:Tx {id: 1})");
    try h.restart();
    try testing.expect(!try h.listed("tx_u"));

    // DDL in a START TRANSACTION body is refused, for both.
    try h.run("CREATE CONSTRAINT tx_u FOR (n:Tx) REQUIRE n.code IS UNIQUE");
    try h.run("CREATE INDEX tx_idx FOR (n:Tx) ON (n.k)");
    try h.expectRefusal("START TRANSACTION { DROP INDEX tx_idx }", "UnsupportedStatementInTransactionBody");
    try h.expectRefusal("START TRANSACTION { DROP CONSTRAINT tx_u }", "UnsupportedStatementInTransactionBody");
    try testing.expect(try h.listed("tx_u"));
}

fn testPrincipal(role: []const u8, roles_buf: *[1][]const u8) principal_mod.Principal {
    roles_buf[0] = role;
    return .{
        .user_id = 6270,
        .username = "drop_constraint_user",
        .session_id = null,
        .tenant_id = null,
        .active_graph = null,
        .roles = roles_buf,
        .custom_roles = &.{},
        .auth_method = .password,
        .auth_version = 1,
        .mfa_state = .none,
        .elevation_until = null,
        .api_key_id = null,
        .certificate_subject = null,
        .risk_context = principal_mod.RiskContext.unknown,
        .attributes = principal_mod.AttributeMap.emptySentinel(),
        .source = .test_harness,
    };
}

test "SONNY-6270: a user without the schema permission cannot drop a constraint" {
    var h = try Harness.init(testing.allocator, true);
    defer h.deinit();
    const allow_was = gps.isInsecureAllowAll();
    gps.setInsecureAllowAll(false);
    defer gps.setInsecureAllowAll(allow_was);

    try h.run("CREATE CONSTRAINT authz_u FOR (n:Az) REQUIRE n.id IS UNIQUE");
    try h.run("CREATE (:Az {id: 1})");

    var rw_roles: [1][]const u8 = undefined;
    const rw = testPrincipal("ReadWrite", &rw_roles);
    h.ctx.principal = &rw;
    // Refused before the name is looked up: a missing name answers the same.
    try h.expectRefusal("DROP CONSTRAINT authz_u", "Unauthorized");
    try h.expectRefusal("DROP CONSTRAINT IF EXISTS authz_u", "Unauthorized");
    try h.expectRefusal("DROP CONSTRAINT no_such_u", "Unauthorized");
    h.ctx.principal = null;
    try testing.expect(try h.listed("authz_u"));
    try h.expectViolation("CREATE (:Az {id: 1})");

    var admin_roles: [1][]const u8 = undefined;
    const admin = testPrincipal("Admin", &admin_roles);
    h.ctx.principal = &admin;
    try h.run("DROP CONSTRAINT authz_u");
    h.ctx.principal = null;
    try testing.expect(!try h.listed("authz_u"));
}
