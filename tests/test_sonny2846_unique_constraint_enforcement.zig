// SONNY-2846 / SONNY-3358 regression: UNIQUE constraints are enforced on
// every write path.
//
// `CREATE CONSTRAINT c FOR (n:L) REQUIRE n.p IS UNIQUE` recorded a catalog
// row and nothing ever read it (`validateConstraints` in
// crud_operations.zig had no caller, and the catalog's
// `getConstraintsForLabel` did not even compile): CREATE, MERGE's create,
// SET of a taken value and SET of the constrained label all made duplicates,
// on in-memory and persisted sessions alike.
//
// Now every user statement is checked when it ends, before its writes are
// kept (SQL's rule: a non-deferred constraint holds at the end of each
// statement); a violation fails the statement with
// `UniqueConstraintViolation` (23505), and the statement undo record takes
// all of its changes back. Semantics pinned here:
//   * uniqueness is per graph, label and tenant: two tenants may hold the
//     same value (no cross-tenant existence oracle), one tenant may not;
//   * a NULL or missing property is no conflict (SQL: NULLs are distinct);
//   * values compare as MERGE matches them: 1 = 1.0, '1' <> 1, and strings
//     byte for byte (an NFC and an NFD spelling are two values);
//   * a MERGE that matches the holder is fine, one that creates is checked;
//   * CREATE CONSTRAINT over data that already has duplicates is refused;
//   * an engine-wide (legacy) row applies in every graph, each graph
//     checked on its own;
//   * the check sees nodes that are not resident (a reopened store, in full
//     and in lean index mode);
//   * N writers creating the same value under the transport's graph write
//     lock: exactly one wins;
//   * the storage adapter's bulk write helpers (the QUIC fast paths) refuse
//     to write into a graph that has a UNIQUE constraint.
//
// Real executor, real stores and catalog; no mocks.
//
// CANARY: REQ=REQ-SONNY-2846-UNIQUE-ENFORCEMENT; FEATURE="ConstraintEnforcement"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2846_unique_constraint_enforcement.zig; OWNER=engine; UPDATED=2026-11-11

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const index_manager = geode.index_manager;

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

/// The restart harness of tests/test_sonny2795_drop_index_catalog.zig:
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

    /// `query` must be refused as a unique violation (23505 on the wire).
    fn expectViolation(self: *Harness, query: []const u8) !void {
        const name = try self.refusal(query);
        if (!std.mem.eql(u8, name, "UniqueConstraintViolation")) {
            std.debug.print("{s}: refused with {s}, expected UniqueConstraintViolation\n", .{ query, name });
            return error.WrongRefusal;
        }
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

    fn constraintListed(self: *Harness, name: []const u8) !bool {
        const res = try self.exec("SHOW CONSTRAINTS");
        for (res.rows) |row| {
            if (row.len == 0) continue;
            switch (row[0]) {
                .Str => |s| if (std.mem.eql(u8, s, name)) return true,
                else => {},
            }
        }
        return false;
    }
};

/// The behaviour every session type must have: CREATE, MERGE, SET, NULLs,
/// equality, statement atomicity, composite keys, CREATE CONSTRAINT over
/// duplicates, delete-then-recreate.
fn exerciseCore(h: *Harness) !void {
    try h.run("CREATE CONSTRAINT p_id FOR (n:P) REQUIRE n.id IS UNIQUE");
    try h.run("CREATE (:P {id: 1, name: 'first'})");

    // ---- CREATE of a taken value is refused, and nothing is written ----
    try h.expectViolation("CREATE (:P {id: 1, name: 'second'})");
    try testing.expectEqual(@as(i64, 1), try h.count("MATCH (n:P {id: 1}) RETURN count(n) AS c"));
    try testing.expectEqual(@as(i64, 0), try h.count("MATCH (n:P {name: 'second'}) RETURN count(n) AS c"));

    // The wire error is 23505 and names the constraint, never the value or
    // the holder's other properties.
    const info = geode.proto_util.mapError(error.UniqueConstraintViolation);
    try testing.expectEqualStrings("23505", info.code);
    try testing.expect(std.mem.indexOf(u8, info.message, "p_id") != null);
    try testing.expect(std.mem.indexOf(u8, info.message, "first") == null);

    // ---- a multi-element CREATE that violates leaves none of its nodes ----
    try h.expectViolation("CREATE (:P {id: 50, name: 'row1'}), (:P {id: 51, name: 'row2'}), (:P {id: 1, name: 'row3'})");
    try testing.expectEqual(@as(i64, 0), try h.count("MATCH (n:P) WHERE n.id IN [50, 51] RETURN count(n) AS c"));
    // Two new nodes of one statement conflict with each other.
    try h.expectViolation("CREATE (:P {id: 7}), (:P {id: 7})");
    try testing.expectEqual(@as(i64, 0), try h.count("MATCH (n:P {id: 7}) RETURN count(n) AS c"));

    // ---- NULL and missing are no conflict ----
    try h.run("CREATE (:P {name: 'no id a'})");
    try h.run("CREATE (:P {name: 'no id b'})");
    try h.run("CREATE (:P {id: null, name: 'null id a'})");
    try h.run("CREATE (:P {id: null, name: 'null id b'})");

    // ---- equality is MERGE's: 1 = 1.0, '1' <> 1, 1.5 = 1.50 ----
    try h.expectViolation("CREATE (:P {id: 1.0})");
    try h.run("CREATE (:P {id: '1'})");
    try h.run("CREATE (:P {id: 1.5})");
    try h.expectViolation("CREATE (:P {id: 1.50})");
    // NFC 'é' (U+00E9) and NFD 'é' (e + U+0301) are two values to MERGE, so
    // to UNIQUE as well; the same bytes twice are one.
    try h.run("CREATE (:P {id: '\u{00E9}'})");
    try h.run("CREATE (:P {id: 'e\u{0301}'})");
    try h.expectViolation("CREATE (:P {id: '\u{00E9}'})");

    // ---- SET of a taken value is refused, and the old value stays ----
    try h.run("CREATE (:P {id: 2})");
    try h.expectViolation("MATCH (n:P {id: 2}) SET n.id = 1");
    try testing.expectEqual(@as(i64, 1), try h.count("MATCH (n:P {id: 2}) RETURN count(n) AS c"));
    // A swap ends with no duplicate: allowed (checked at statement end).
    try h.run("CREATE (:P {id: 3})");
    try h.run("MATCH (a:P {id: 2}), (b:P {id: 3}) SET a.id = 3, b.id = 2");
    try testing.expectEqual(@as(i64, 1), try h.count("MATCH (n:P {id: 2}) RETURN count(n) AS c"));
    try testing.expectEqual(@as(i64, 1), try h.count("MATCH (n:P {id: 3}) RETURN count(n) AS c"));

    // ---- SET adding the constrained label is refused ----
    try h.run("CREATE (:Q {id: 1})");
    try h.expectViolation("MATCH (n:Q {id: 1}) SET n:P");
    try testing.expectEqual(@as(i64, 0), try h.count("MATCH (n:Q:P) RETURN count(n) AS c"));
    try h.run("CREATE (:Q {id: 900})");
    try h.run("MATCH (n:Q {id: 900}) SET n:P");

    // ---- MERGE: matching the holder is fine, creating a duplicate is not ----
    try h.run("MERGE (n:P {id: 1})");
    try testing.expectEqual(@as(i64, 1), try h.count("MATCH (n:P {id: 1}) RETURN count(n) AS c"));
    try h.run("MERGE (n:P {id: 4})");
    try testing.expectEqual(@as(i64, 1), try h.count("MATCH (n:P {id: 4}) RETURN count(n) AS c"));
    // No node has {id: 1, name: 'other'}, so MERGE creates one: refused.
    try h.expectViolation("MERGE (n:P {id: 1, name: 'other'})");
    // ON CREATE SET of a taken value: refused, and the created node is gone.
    try h.expectViolation("MERGE (n:P {code: 'z'}) ON CREATE SET n.id = 1");
    try testing.expectEqual(@as(i64, 0), try h.count("MATCH (n:P {code: 'z'}) RETURN count(n) AS c"));

    // ---- delete, then the value is free again ----
    try h.run("MATCH (n:P {id: 4}) DELETE n");
    try h.run("CREATE (:P {id: 4})");

    // ---- a composite UNIQUE: the tuple is the key; NULL in it is no conflict ----
    try h.run("CREATE CONSTRAINT r_ab ON :R ASSERT (a, b) IS UNIQUE");
    try h.run("CREATE (:R {a: 1, b: 1})");
    try h.run("CREATE (:R {a: 1, b: 2})");
    try h.expectViolation("CREATE (:R {a: 1, b: 1})");
    try h.expectViolation("CREATE (:R {a: 1.0, b: 1})");
    try h.run("CREATE (:R {a: 1})");
    try h.run("CREATE (:R {a: 1})");

    // ---- CREATE CONSTRAINT over existing duplicates is refused ----
    try h.run("CREATE (:D {k: 1}), (:D {k: 1}), (:D {k: 2}), (:D {k: 2.0}), (:D {k: 3}), (:D {name: 'x'}), (:D {name: 'y'})");
    try h.expectViolation("CREATE CONSTRAINT d_k FOR (n:D) REQUIRE n.k IS UNIQUE");
    try testing.expect(!try h.constraintListed("d_k"));
    // The refusal says how many groups of nodes share a value (2 here).
    try testing.expect(std.mem.indexOf(u8, geode.proto_util.mapError(error.UniqueConstraintViolation).message, "2 groups") != null);
    // The constraint does not exist: duplicates are still writable.
    try h.run("CREATE (:D {k: 3})");
    // A clean label takes the constraint.
    try h.run("CREATE (:E {k: 1}), (:E {k: 2}), (:E {name: 'no k'})");
    try h.run("CREATE CONSTRAINT e_k FOR (n:E) REQUIRE n.k IS UNIQUE");
    try testing.expect(try h.constraintListed("e_k"));
    try h.expectViolation("CREATE (:E {k: 2})");
}

test "SONNY-2846: UNIQUE is enforced on CREATE, MERGE and SET in an in-memory session" {
    const saved_env: ?[]u8 = if (std.c.getenv("GEODE_DATA_DIR")) |p| try testing.allocator.dupe(u8, std.mem.span(p)) else null;
    defer if (saved_env) |v| {
        const z = testing.allocator.dupeZ(u8, v) catch unreachable;
        defer testing.allocator.free(z);
        _ = setenv("GEODE_DATA_DIR", z, 1);
        testing.allocator.free(v);
    };
    _ = unsetenv("GEODE_DATA_DIR");

    var h = try Harness.init(testing.allocator, false);
    defer h.deinit();
    try exerciseCore(&h);
}

test "SONNY-2846: UNIQUE is enforced on CREATE, MERGE and SET in a persisted session, also after a reopen (full and lean index mode)" {
    var h = try Harness.init(testing.allocator, true);
    defer h.deinit();
    try exerciseCore(&h);

    // ---- cold store: the holder is not resident after a reopen ----
    try h.restart();
    try h.expectViolation("CREATE (:P {id: 1})");
    try h.expectViolation("MATCH (n:P {id: 2}) SET n.id = 3");
    try h.run("CREATE (:P {id: 1000})");

    // ---- the same in lean index mode, where the exact index cannot answer ----
    graph_store.setLeanIndexingForTest(true);
    defer graph_store.setLeanIndexingForTest(false);
    try h.restart();
    try h.expectViolation("CREATE (:P {id: 1})");
    try h.expectViolation("CREATE (:P {id: 1000})");
    try h.expectViolation("CREATE (:R {a: 1, b: 2})");
    try h.run("CREATE (:P {id: 1001})");
}

test "SONNY-2846: uniqueness is per tenant and per graph; an engine-wide (legacy) row applies in every graph" {
    var h = try Harness.init(testing.allocator, true);
    defer h.deinit();

    try h.run("CREATE CONSTRAINT t_id FOR (n:T) REQUIRE n.id IS UNIQUE");

    // Two tenants may hold the same value; one tenant may not hold it twice.
    h.ctx.tenant_id = "tenant_a";
    try h.run("CREATE (:T {id: 1})");
    h.ctx.tenant_id = "tenant_b";
    try h.run("CREATE (:T {id: 1})");
    try h.expectViolation("CREATE (:T {id: 1})");
    h.ctx.tenant_id = "tenant_a";
    try h.expectViolation("CREATE (:T {id: 1})");
    h.ctx.tenant_id = null;

    // The row is the default graph's: another graph is not constrained.
    try h.run("CREATE GRAPH g2846");
    try h.run("USE GRAPH g2846");
    try h.run("CREATE (:T {id: 5})");
    try h.run("CREATE (:T {id: 5})");
    try h.run("USE GRAPH default");

    // An engine-wide row (what a catalog written before rows carried a graph
    // loads as) applies in every graph, each graph checked separately.
    const props = [_][]const u8{"k"};
    try h.ctx.catalog.addConstraint(.{
        .name = "legacy_u",
        .constraint_type = .unique,
        .label = "Legacy",
        .properties = @constCast(props[0..]),
        .is_enforced = true,
        .graph = geode.catalog.ENGINE_WIDE_GRAPH,
    });
    try h.run("CREATE (:Legacy {k: 1})");
    try h.expectViolation("CREATE (:Legacy {k: 1})");
    try h.run("USE GRAPH g2846");
    try h.run("CREATE (:Legacy {k: 1})");
    try h.expectViolation("CREATE (:Legacy {k: 1})");
    try h.run("USE GRAPH default");
}

const Racer = struct {
    catalog: *geode.catalog.Catalog,
    query: []const u8,
    start: *std.atomic.Value(bool),
    outcome: ?anyerror = null,
    ok: bool = false,

    fn go(self: *Racer) void {
        var arena = std.heap.ArenaAllocator.init(std.heap.smp_allocator);
        defer arena.deinit();
        const aa = arena.allocator();
        var session = execution.SessionState.init(std.heap.smp_allocator);
        defer session.deinit();
        const ctx = execution.ExecutionContext{ .catalog = self.catalog, .session_state = &session };
        var parsed = geode.parseGqlOptions(self.query, aa, .{}) catch |err| {
            self.outcome = err;
            return;
        };
        defer parsed.deinit();
        while (!self.start.load(.acquire)) std.atomic.spinLoopHint();
        // The transport's protocol for a program that changes the store:
        // the graph's write lock, held across the whole statement.
        const lock = graph_store.acquireGraphWriteLock("default");
        defer graph_store.releaseGraphLock(lock);
        if (execution.executeStatementWithContext(aa, parsed.program.statements[0], ctx)) |_| {
            self.ok = true;
        } else |err| self.outcome = err;
    }
};

test "SONNY-2846: N writers creating the same value at once: exactly one succeeds" {
    var h = try Harness.init(testing.allocator, true);
    defer h.deinit();
    try h.run("CREATE CONSTRAINT c_id FOR (n:C) REQUIRE n.id IS UNIQUE");

    const writers = 8;
    var round: usize = 0;
    while (round < 20) : (round += 1) {
        var qbuf: [64]u8 = undefined;
        const query = try std.fmt.bufPrint(&qbuf, "CREATE (:C {{id: {d}}})", .{round});
        var start = std.atomic.Value(bool).init(false);
        var racers: [writers]Racer = undefined;
        var threads: [writers]std.Thread = undefined;
        for (&racers, &threads) |*r, *t| {
            r.* = .{ .catalog = h.ctx.catalog, .query = query, .start = &start };
            t.* = try std.Thread.spawn(.{}, Racer.go, .{r});
        }
        start.store(true, .release);
        for (threads) |t| t.join();

        var wins: usize = 0;
        for (racers) |r| {
            if (r.ok) {
                wins += 1;
            } else if (r.outcome) |err| {
                if (err != error.UniqueConstraintViolation) {
                    std.debug.print("round {d}: a writer failed with {s}\n", .{ round, @errorName(err) });
                    return err;
                }
            }
        }
        try testing.expectEqual(@as(usize, 1), wins);
        var cbuf: [96]u8 = undefined;
        try testing.expectEqual(@as(i64, 1), try h.count(try std.fmt.bufPrint(&cbuf, "MATCH (n:C {{id: {d}}}) RETURN count(n) AS c", .{round})));
    }
}

/// `result` must be the fast-path refusal (by name, so this compiles against
/// an engine that has no such error).
fn expectFastPathRefusal(result: anytype) !void {
    if (result) |_| {
        std.debug.print("a bulk write into a UNIQUE-constrained graph ran\n", .{});
        return error.ExpectedRefusal;
    } else |err| try testing.expectEqualStrings("UniqueConstraintFastPathConflict", @errorName(err));
}

test "SONNY-2846: the adapter's bulk write helpers (the QUIC fast paths) do not write into a graph with a UNIQUE constraint" {
    var h = try Harness.init(testing.allocator, true);
    defer h.deinit();
    if (comptime !@hasDecl(geode.bulk_ingest, "uniqueConstraintsDeclineFastPath")) {
        std.debug.print("bulk_ingest has no UNIQUE fast-path gate\n", .{});
        return error.FastPathGateMissing;
    } else try exerciseFastPaths(&h);
}

fn exerciseFastPaths(h: *Harness) !void {
    const adapter = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    const PropKV = geode.graph_storage_adapter.StorageAdapter.PropKV;

    try h.run("CREATE (:F {id: 1})");
    // Before the constraint, the fast paths may serve the graph.
    try testing.expect(!geode.bulk_ingest.uniqueConstraintsDeclineFastPath("default"));
    try h.run("CREATE CONSTRAINT f_id FOR (n:F) REQUIRE n.id IS UNIQUE");
    // The handler's gate now sends every node write to the executor...
    try testing.expect(geode.bulk_ingest.uniqueConstraintsDeclineFastPath("default"));

    // ...and a write that passed the gate before the constraint existed is
    // refused under the graph lock, before anything is written.
    const dup = [_]PropKV{.{ .key = "id", .value = .{ .Int = 1 } }};
    const labels = [_][]const u8{"F"};
    {
        const lock = graph_store.acquireGraphWriteLock("default");
        defer graph_store.releaseGraphLock(lock);
        try expectFastPathRefusal(adapter.bulkInsertNode("default", &labels, &dup, null));
        try expectFastPathRefusal(adapter.bulkMergeNode("default", "F", "code", .{ .String = "zz" }, &dup, null, false));
    }
    try expectFastPathRefusal(adapter.bulkMergeNodeWithReservedId("default", 0, "F", "code", .{ .String = "zz" }, &dup, false));
    const mp = [_]PropKV{ .{ .key = "code", .value = .{ .String = "zz" } }, .{ .key = "id", .value = .{ .Int = 1 } } };
    try expectFastPathRefusal(adapter.bulkMergeNodeWithReservedIdMultiProp("default", 0, "F", &mp, &.{}, false));
    try expectFastPathRefusal(adapter.bulkInsertNodeWithReservedId("default", 0, &labels, &dup));
    try testing.expectEqual(@as(i64, 1), try h.count("MATCH (n:F {id: 1}) RETURN count(n) AS c"));
    try testing.expectEqual(@as(i64, 0), try h.count("MATCH (n:F {code: 'zz'}) RETURN count(n) AS c"));

    // Another graph is not fenced.
    try h.run("CREATE GRAPH g2846f");
    try testing.expect(!geode.bulk_ingest.uniqueConstraintsDeclineFastPath("g2846f"));
}
