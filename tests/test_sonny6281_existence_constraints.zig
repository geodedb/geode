// SONNY-6281 regression: NOT NULL, EXISTS and the existence half of NODE KEY
// are enforced; CREATE UNIQUE INDEX is refused instead of ignored.
//
// SONNY-2846 enforced UNIQUE (and the uniqueness half of NODE KEY) at the
// end of every statement. The other constraint kinds the parser and catalog
// accept were only recorded: `REQUIRE n.p IS NOT NULL`, the legacy
// `ASSERT EXISTS (p)` and the "every key property present" half of
// `IS NODE KEY`. A write that broke one succeeded. `CREATE UNIQUE INDEX`
// parsed, set a flag nothing read, and created a plain index.
//
// ISO/IEC 39075:2024 has no CREATE CONSTRAINT or CREATE INDEX statement
// (they are Geode extensions in the openCypher form). Its nearest rule is a
// property type declared `NOT NULL` in a graph type, and GQL makes a
// property whose value is null the same as an absent one. So here a
// required property must be present with a non-NULL value:
//   * checked when each statement ends (SQL's rule for a constraint that is
//     not deferred), so CREATE then SET in one statement, or MERGE ... ON
//     CREATE SET, may supply it; a violation fails the statement with
//     `NotNullConstraintViolation` (23502, SQL's not_null_violation) naming
//     the constraint, and the statement's undo record takes all of it back;
//   * on CREATE, MERGE's create, SET of NULL, REMOVE of the property, and
//     SET of the constrained label on a node without it; removing the label
//     is allowed (the node is no longer constrained);
//   * CREATE CONSTRAINT over nodes that lack the property is refused, with
//     how many lack it;
//   * the server's node-writing fast paths decline the graph (they skip the
//     check), as for UNIQUE; the constraint survives a restart and stops
//     applying when dropped;
//   * NODE KEY = both halves: a missing key property is 23502, a duplicate
//     key 23505.
//
// Real executor, stores, adapter and catalog; no mocks.
//
// CANARY: REQ=REQ-SONNY-6281-EXISTENCE-CONSTRAINTS; FEATURE="ConstraintEnforcement"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6281_existence_constraints.zig; OWNER=engine; UPDATED=2026-11-12

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

    /// `query` must be refused with the error named `want` (by name, so this
    /// compiles against an engine that has no such error yet).
    fn expectRefused(self: *Harness, query: []const u8, want: []const u8) !void {
        if (self.exec(query)) |_| {
            std.debug.print("{s}: ran; expected {s}\n", .{ query, want });
            return error.ExpectedRefusal;
        } else |err| {
            if (!std.mem.eql(u8, @errorName(err), want)) {
                std.debug.print("{s}: refused with {s}, expected {s}\n", .{ query, @errorName(err), want });
                return error.WrongRefusal;
            }
        }
    }

    fn expectNotNull(self: *Harness, query: []const u8) !void {
        return self.expectRefused(query, "NotNullConstraintViolation");
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

fn exerciseNotNull(h: *Harness) !void {
    try h.run("CREATE CONSTRAINT p_name FOR (n:P) REQUIRE n.name IS NOT NULL");
    try h.run("CREATE (:P {name: 'a', id: 1})");

    // ---- CREATE without the property, or with NULL, is refused; nothing is written ----
    try h.expectNotNull("CREATE (:P {id: 2})");
    try h.expectNotNull("CREATE (:P {name: null, id: 3})");
    try h.expectNotNull("CREATE (:P:Other {id: 4})");
    try testing.expectEqual(@as(i64, 1), try h.count("MATCH (n:P) RETURN count(n) AS c"));
    try testing.expectEqual(@as(i64, 0), try h.count("MATCH (n:Other) RETURN count(n) AS c"));

    // The wire error is 23502 and names the constraint, its label and
    // property, never a value.
    const info = geode.proto_util.mapError(error.NotNullConstraintViolation);
    try testing.expectEqualStrings("23502", info.code);
    try testing.expect(std.mem.indexOf(u8, info.message, "p_name") != null);
    try testing.expect(std.mem.indexOf(u8, info.message, "name") != null);

    // ---- a multi-element CREATE with one bad node leaves none of its nodes ----
    try h.expectNotNull("CREATE (:P {name: 'b', id: 50}), (:P {id: 51})");
    try testing.expectEqual(@as(i64, 0), try h.count("MATCH (n:P {id: 50}) RETURN count(n) AS c"));

    // ---- the check is at statement end: CREATE then SET in one statement is fine ----
    try h.run("CREATE (n:P {id: 5}) SET n.name = 'late'");
    try testing.expectEqual(@as(i64, 1), try h.count("MATCH (n:P {name: 'late'}) RETURN count(n) AS c"));

    // ---- SET to NULL and REMOVE of the property are refused; the value stays ----
    try h.expectNotNull("MATCH (n:P {id: 1}) SET n.name = null");
    try h.expectNotNull("MATCH (n:P {id: 1}) REMOVE n.name");
    try h.expectNotNull("MATCH (n:P {id: 1}) SET n = {id: 1}");
    try testing.expectEqual(@as(i64, 1), try h.count("MATCH (n:P {id: 1, name: 'a'}) RETURN count(n) AS c"));
    // A new value, or removing another property, is fine.
    try h.run("MATCH (n:P {id: 1}) SET n.name = 'a2'");
    try h.run("MATCH (n:P {id: 1}) REMOVE n.id");
    try testing.expectEqual(@as(i64, 1), try h.count("MATCH (n:P {name: 'a2'}) RETURN count(n) AS c"));

    // ---- adding the label to a node without the property is refused ----
    try h.run("CREATE (:Q {id: 10})");
    try h.expectNotNull("MATCH (n:Q {id: 10}) SET n:P");
    try testing.expectEqual(@as(i64, 0), try h.count("MATCH (n:Q:P) RETURN count(n) AS c"));
    try h.run("MATCH (n:Q {id: 10}) SET n.name = 'q', n:P");
    // ---- removing the label frees the node from the constraint ----
    try h.run("MATCH (n:Q:P {id: 10}) REMOVE n:P");
    try h.run("MATCH (n:Q {id: 10}) REMOVE n.name");

    // ---- MERGE: a match is fine; a create must supply the property ----
    try h.run("MERGE (n:P {name: 'a2'})");
    try h.expectNotNull("MERGE (n:P {id: 77})");
    try testing.expectEqual(@as(i64, 0), try h.count("MATCH (n:P {id: 77}) RETURN count(n) AS c"));
    try h.run("MERGE (n:P {id: 78}) ON CREATE SET n.name = 'made'");
    try testing.expectEqual(@as(i64, 1), try h.count("MATCH (n:P {id: 78, name: 'made'}) RETURN count(n) AS c"));
    try h.expectNotNull("MERGE (n:P {id: 78}) ON MATCH SET n.name = null");

    // ---- other labels and a deleted node are not constrained ----
    try h.run("CREATE (:Free {id: 1})");
    try h.run("MATCH (n:P {id: 78}) DELETE n");

    // ---- the legacy EXISTS form is the same rule ----
    try h.run("CREATE CONSTRAINT x_code ON :X ASSERT EXISTS (code)");
    try h.run("CREATE (:X {code: 'c1'})");
    try h.expectNotNull("CREATE (:X {other: 1})");
    try h.expectNotNull("MATCH (n:X) REMOVE n.code");
    try testing.expectEqual(@as(i64, 1), try h.count("MATCH (n:X {code: 'c1'}) RETURN count(n) AS c"));
}

fn exerciseNodeKey(h: *Harness) !void {
    try h.run("CREATE CONSTRAINT r_key FOR (n:R) REQUIRE (n.a, n.b) IS NODE KEY");
    try h.run("CREATE (:R {a: 1, b: 1})");
    // The existence half: every key property present and not NULL.
    try h.expectNotNull("CREATE (:R {a: 2})");
    try h.expectNotNull("CREATE (:R {a: 2, b: null})");
    try h.expectNotNull("MATCH (n:R {a: 1}) REMOVE n.b");
    // The uniqueness half (SONNY-2846) still holds.
    try h.expectRefused("CREATE (:R {a: 1, b: 1})", "UniqueConstraintViolation");
    try h.run("CREATE (:R {a: 1, b: 2})");
    try testing.expectEqual(@as(i64, 2), try h.count("MATCH (n:R) RETURN count(n) AS c"));
}

fn exerciseCreateOverData(h: *Harness) !void {
    // ---- CREATE CONSTRAINT over nodes lacking the property is refused ----
    try h.run("CREATE (:D {k: 1}), (:D {k: 2}), (:D {other: 1}), (:D {k: null, other: 2})");
    try h.expectNotNull("CREATE CONSTRAINT d_k FOR (n:D) REQUIRE n.k IS NOT NULL");
    try testing.expect(!try h.constraintListed("d_k"));
    // It says how many nodes lack it (2 here), never a value.
    try testing.expect(std.mem.indexOf(u8, geode.proto_util.mapError(error.NotNullConstraintViolation).message, "2 ") != null);
    try h.expectNotNull("CREATE CONSTRAINT d_e ON :D ASSERT EXISTS (k)");
    try h.expectNotNull("CREATE CONSTRAINT d_nk FOR (n:D) REQUIRE (n.k) IS NODE KEY");
    try testing.expect(!try h.constraintListed("d_e"));
    try testing.expect(!try h.constraintListed("d_nk"));
    // Nothing applies: a node without k is still writable.
    try h.run("CREATE (:D {other: 3})");
    // Once the data is clean, the constraint is taken and enforced.
    try h.run("MATCH (n:D) WHERE n.k IS NULL DELETE n");
    try h.run("CREATE CONSTRAINT d_k FOR (n:D) REQUIRE n.k IS NOT NULL");
    try testing.expect(try h.constraintListed("d_k"));
    try h.expectNotNull("CREATE (:D {other: 4})");
}

fn exerciseUniqueIndex(h: *Harness) !void {
    // CREATE UNIQUE INDEX is refused (0A000), not accepted as a plain index:
    // uniqueness is declared with CREATE CONSTRAINT ... IS UNIQUE.
    try h.expectRefused("CREATE UNIQUE INDEX u_idx FOR (n:U) ON (n.id)", "UniqueIndexNotSupported");
    const info = geode.proto_util.mapError(error.UniqueIndexNotSupported);
    try testing.expectEqualStrings("0A000", info.code);
    try testing.expect(std.mem.indexOf(u8, info.message, "IS UNIQUE") != null);
    try testing.expect((try h.ctx.catalog.getIndexInGraph("default", "U", "u_idx")) == null);
    // A plain index is unaffected.
    try h.run("CREATE INDEX plain_idx FOR (n:U) ON (n.id)");
    try testing.expect((try h.ctx.catalog.getIndexInGraph("default", "U", "plain_idx")) != null);
}

fn exerciseAll(h: *Harness) !void {
    try exerciseNotNull(h);
    try exerciseNodeKey(h);
    try exerciseCreateOverData(h);
    try exerciseUniqueIndex(h);
}

test "SONNY-6281: NOT NULL, EXISTS and NODE KEY existence are enforced in an in-memory session; CREATE UNIQUE INDEX is refused" {
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
    try exerciseAll(&h);
}

test "SONNY-6281: existence constraints are enforced in a persisted session, also after a reopen and in lean index mode" {
    var h = try Harness.init(testing.allocator, true);
    defer h.deinit();
    try exerciseAll(&h);

    // ---- the constraints are loaded with the catalog ----
    try h.restart();
    try h.expectNotNull("CREATE (:P {id: 900})");
    try h.expectNotNull("MATCH (n:P {name: 'a2'}) REMOVE n.name");
    try h.expectNotNull("CREATE (:R {b: 9})");
    try h.run("CREATE (:P {name: 'after restart'})");

    graph_store.setLeanIndexingForTest(true);
    defer graph_store.setLeanIndexingForTest(false);
    try h.restart();
    try h.expectNotNull("CREATE (:X {other: 2})");
    try h.run("CREATE (:X {code: 'c2'})");
}

/// `result` must be the fast-path refusal, by name.
fn expectFastPathRefusal(result: anytype) !void {
    if (result) |_| {
        std.debug.print("a bulk write into a graph with an existence constraint ran\n", .{});
        return error.ExpectedRefusal;
    } else |err| try testing.expectEqualStrings("UniqueConstraintFastPathConflict", @errorName(err));
}

test "SONNY-6281: the bulk fast paths decline a graph with an existence constraint, before and after a reopen; DROP CONSTRAINT lifts it" {
    var h = try Harness.init(testing.allocator, true);
    defer h.deinit();
    const PropKV = geode.graph_storage_adapter.StorageAdapter.PropKV;
    const labels = [_][]const u8{"F"};
    const no_name = [_]PropKV{.{ .key = "id", .value = .{ .Int = 1 } }};

    try testing.expect(!geode.bulk_ingest.uniqueConstraintsDeclineFastPath("default"));
    try h.run("CREATE CONSTRAINT f_name FOR (n:F) REQUIRE n.name IS NOT NULL");
    try testing.expect(geode.bulk_ingest.uniqueConstraintsDeclineFastPath("default"));
    {
        const adapter = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
        const lock = graph_store.acquireGraphWriteLock("default");
        defer graph_store.releaseGraphLock(lock);
        try expectFastPathRefusal(adapter.bulkInsertNode("default", &labels, &no_name, null));
        try expectFastPathRefusal(adapter.bulkMergeNode("default", "F", "id", .{ .Int = 1 }, &.{}, null, false));
    }
    try testing.expectEqual(@as(i64, 0), try h.count("MATCH (n:F) RETURN count(n) AS c"));

    // The fence is rebuilt from the catalog at open.
    try h.restart();
    try testing.expect(geode.bulk_ingest.uniqueConstraintsDeclineFastPath("default"));
    try h.expectNotNull("CREATE (:F {id: 1})");

    // Dropped: no longer enforced, and the fast paths may serve the graph.
    try h.run("DROP CONSTRAINT f_name");
    try testing.expect(!geode.bulk_ingest.uniqueConstraintsDeclineFastPath("default"));
    try h.run("CREATE (:F {id: 1})");
    try h.restart();
    try h.run("CREATE (:F {id: 2})");
    try testing.expect(!geode.bulk_ingest.uniqueConstraintsDeclineFastPath("default"));

    // Another graph is not fenced.
    try h.run("CREATE CONSTRAINT f_name2 FOR (n:F) REQUIRE n.name IS NOT NULL");
    try h.run("CREATE GRAPH g6281");
    try testing.expect(!geode.bulk_ingest.uniqueConstraintsDeclineFastPath("g6281"));
    try h.run("USE GRAPH g6281");
    try h.run("CREATE (:F {id: 3})");
}
