// CANARY: REQ=REQ-DELETE-MATCH-SET-RESOLUTION; FEATURE="DeleteWhereEvaluation"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_eng3913_where_delete.zig:1; OWNER=crud_operations; UPDATED=2026-08-25
//
// ENG-3913 — `MATCH … [WHERE …] DELETE …` lost data in BOTH directions.
//
// The DELETE executor did not reuse the matching path a `RETURN` of the same
// variables takes; it reconstructed the match set by hand from
// `chains[0].head` and evaluated `WHERE` against a one-entry `Env`. That was
// independently wrong five ways:
//
//   (A) the WHERE `Env` carried NO parameter bindings, so `$param` predicates
//       evaluated to NULL and the DELETE silently deleted NOTHING;
//   (B) the `Env` bound only `chains[0].head.name`, so a cross-variable
//       predicate resolved NULL (no-op), and a hop-node delete target had the
//       HEAD variable's NAME bound to the TARGET's value;
//   (C) the candidate set never traversed relationship hops, so a
//       pattern-restricted DELETE OVER-DELETED — it destroyed nodes that the
//       pattern excludes entirely;
//   (D) the relationship-delete branch had no `where_clause` handling at all,
//       so `WHERE r.w = 1 DELETE r` deleted EVERY matching edge;
//   (E) an evaluation error in the predicate was swallowed into
//       `should_delete = false`, i.e. a silent partial delete.
//
// Every assertion below counts SURVIVORS, not statement status: a DELETE that
// reports success while deleting the wrong rows is exactly the failure mode.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const value_types = geode.value_types;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const Harness = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    session: execution.SessionState,
    ctx: execution.ExecutionContext,

    pub fn init(allocator: std.mem.Allocator) !Harness {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);

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

    pub fn deinit(self: *Harness) void {
        self.session.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.arena.deinit();
        self.tmp.cleanup();
    }

    pub fn exec(self: *Harness, query: []const u8) !execution.ExecutionResult {
        return self.execParams(query, &.{}, &.{});
    }

    pub fn execParams(
        self: *Harness,
        query: []const u8,
        names: []const []const u8,
        values: []const value_types.Value,
    ) !execution.ExecutionResult {
        self.ctx.session_state = &self.session;
        self.ctx.query_param_names = names;
        self.ctx.query_param_values = values;
        defer {
            self.ctx.query_param_names = &.{};
            self.ctx.query_param_values = &.{};
        }
        const aa = self.arena.allocator();
        var parsed = try geode.parseGqlOptions(query, aa, .{});
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    /// Survivor count — the only honest assertion for a delete regression.
    pub fn countRows(self: *Harness, query: []const u8) !usize {
        const res = try self.exec(query);
        return res.rows.len;
    }

    pub fn hasIdProp(self: *Harness, query: []const u8, wanted: i64) !bool {
        const res = try self.exec(query);
        for (res.rows) |row| {
            for (row) |value| {
                switch (value) {
                    .Int => |i| if (i == wanted) return true,
                    else => {},
                }
            }
        }
        return false;
    }
};

test "ENG-3913(A): a $param WHERE predicate deletes exactly the matching rows" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    _ = try h.exec("CREATE GRAPH eng3913_a");
    _ = try h.exec("USE GRAPH eng3913_a");
    _ = try h.exec("CREATE (:D13 {id: 1, tag: 'keep'})");
    _ = try h.exec("CREATE (:D13 {id: 2, tag: 'drop'})");
    _ = try h.exec("CREATE (:D13 {id: 3, tag: 'keep'})");
    _ = try h.exec("CREATE (:D13 {id: 4, tag: 'drop'})");
    try testing.expectEqual(@as(usize, 4), try h.countRows("MATCH (n:D13) RETURN n"));

    const names = [_][]const u8{"t"};
    const values = [_]value_types.Value{.{ .Str = "drop" }};
    _ = try h.execParams("MATCH (n:D13) WHERE n.tag = $t DELETE n", &names, &values);

    // Before the fix this was a silent no-op: the WHERE Env had no parameter
    // bindings, `$t` resolved NULL, and every row was kept.
    try testing.expectEqual(@as(usize, 2), try h.countRows("MATCH (n:D13) RETURN n"));
    try testing.expectEqual(@as(usize, 2), try h.countRows("MATCH (n:D13 {tag: 'keep'}) RETURN n"));
    try testing.expectEqual(@as(usize, 0), try h.countRows("MATCH (n:D13 {tag: 'drop'}) RETURN n"));
    try testing.expect(try h.hasIdProp("MATCH (n:D13) RETURN n.id", 1));
    try testing.expect(try h.hasIdProp("MATCH (n:D13) RETURN n.id", 3));
}

test "ENG-3913(B): a cross-variable predicate deletes only the pattern's target variable" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    _ = try h.exec("CREATE GRAPH eng3913_b");
    _ = try h.exec("USE GRAPH eng3913_b");
    _ = try h.exec("CREATE (:BA {id: 1})");
    _ = try h.exec("CREATE (:BA {id: 2})");
    _ = try h.exec("CREATE (:BB {id: 10, tag: 'yes'})");
    _ = try h.exec("CREATE (:BB {id: 11, tag: 'no'})");
    _ = try h.exec("MATCH (a:BA {id: 1}), (b:BB {id: 10}) CREATE (a)-[:BR]->(b)");
    _ = try h.exec("MATCH (a:BA {id: 2}), (b:BB {id: 11}) CREATE (a)-[:BR]->(b)");

    // `WHERE b.tag = 'yes' DELETE a` must remove BA#1 and NOTHING else. Before
    // the fix `b` was unbound (only the head variable was in the Env), so the
    // predicate was NULL and nothing at all was deleted.
    _ = try h.exec("MATCH (a:BA)-[:BR]->(b:BB) WHERE b.tag = 'yes' DETACH DELETE a");

    try testing.expectEqual(@as(usize, 1), try h.countRows("MATCH (n:BA) RETURN n"));
    try testing.expect(try h.hasIdProp("MATCH (n:BA) RETURN n.id", 2));
    // Both endpoints of the other side survive untouched.
    try testing.expectEqual(@as(usize, 2), try h.countRows("MATCH (n:BB) RETURN n"));
}

test "ENG-3913(B): a hop node is deletable as the DELETE target" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    _ = try h.exec("CREATE GRAPH eng3913_hop");
    _ = try h.exec("USE GRAPH eng3913_hop");
    _ = try h.exec("CREATE (:HA {id: 1})");
    _ = try h.exec("CREATE (:HB {id: 10, tag: 'yes'})");
    _ = try h.exec("CREATE (:HB {id: 11, tag: 'no'})");
    _ = try h.exec("MATCH (a:HA {id: 1}), (b:HB {id: 10}) CREATE (a)-[:HR]->(b)");
    _ = try h.exec("MATCH (a:HA {id: 1}), (b:HB {id: 11}) CREATE (a)-[:HR]->(b)");

    // `b` is a HOP node. The predicate is over `b` itself; only HB#10 goes.
    _ = try h.exec("MATCH (a:HA)-[:HR]->(b:HB) WHERE b.tag = 'yes' DETACH DELETE b");

    try testing.expectEqual(@as(usize, 1), try h.countRows("MATCH (n:HB) RETURN n"));
    try testing.expect(try h.hasIdProp("MATCH (n:HB) RETURN n.id", 11));
    try testing.expectEqual(@as(usize, 1), try h.countRows("MATCH (n:HA) RETURN n"));
}

test "ENG-3913(C): a pattern-restricted DELETE does not destroy nodes the pattern excludes" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    _ = try h.exec("CREATE GRAPH eng3913_c");
    _ = try h.exec("USE GRAPH eng3913_c");
    _ = try h.exec("CREATE (:CA {id: 1, tag: 'linked'})");
    _ = try h.exec("CREATE (:CA {id: 2, tag: 'isolated'})");
    _ = try h.exec("CREATE (:CB {id: 10})");
    _ = try h.exec("MATCH (a:CA {id: 1}), (b:CB {id: 10}) CREATE (a)-[:CR]->(b)");
    try testing.expectEqual(@as(usize, 2), try h.countRows("MATCH (n:CA) RETURN n"));

    // CA#2 has NO :CR edge, so the pattern cannot match it. Before the fix the
    // candidate set was "every node carrying the head label" and CA#2 was
    // destroyed — verified data loss with no WHERE clause in sight.
    _ = try h.exec("MATCH (a:CA)-[:CR]->(b:CB) DETACH DELETE a");

    try testing.expectEqual(@as(usize, 1), try h.countRows("MATCH (n:CA) RETURN n"));
    try testing.expect(try h.hasIdProp("MATCH (n:CA) RETURN n.id", 2));
}

test "ENG-3913(D): WHERE on a relationship variable deletes only the matching edge" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    _ = try h.exec("CREATE GRAPH eng3913_d");
    _ = try h.exec("USE GRAPH eng3913_d");
    _ = try h.exec("CREATE (:DA {id: 1})");
    _ = try h.exec("CREATE (:DA {id: 2})");
    _ = try h.exec("MATCH (a:DA {id: 1}), (b:DA {id: 2}) CREATE (a)-[:DR {w: 1}]->(b)");
    _ = try h.exec("MATCH (a:DA {id: 1}), (b:DA {id: 2}) CREATE (a)-[:DR {w: 2}]->(b)");
    try testing.expectEqual(@as(usize, 2), try h.countRows("MATCH ()-[r:DR]->() RETURN r"));

    // Before the fix the relationship branch ignored the WHERE clause entirely
    // and deleted 100% of the :DR edges.
    _ = try h.exec("MATCH ()-[r:DR]->() WHERE r.w = 1 DELETE r");

    try testing.expectEqual(@as(usize, 1), try h.countRows("MATCH ()-[r:DR]->() RETURN r"));
    try testing.expectEqual(@as(usize, 1), try h.countRows("MATCH ()-[r:DR]->() WHERE r.w = 2 RETURN r"));
    try testing.expectEqual(@as(usize, 0), try h.countRows("MATCH ()-[r:DR]->() WHERE r.w = 1 RETURN r"));
    // Both endpoints survive an edge-only DELETE.
    try testing.expectEqual(@as(usize, 2), try h.countRows("MATCH (n:DA) RETURN n"));
}

test "ENG-3913(E): a predicate that fails to evaluate never silently deletes; DELETE and RETURN agree" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    _ = try h.exec("CREATE GRAPH eng3913_e");
    _ = try h.exec("USE GRAPH eng3913_e");
    _ = try h.exec("CREATE (:EA {id: 1, tag: 'x'})");
    _ = try h.exec("CREATE (:EA {id: 2, tag: 'y'})");

    // The contract this pins: the DELETE row set is EXACTLY the row set a
    // RETURN of the same variables produces, error behaviour included. The old
    // executor had its own `catch { should_delete = false; }` arm, so a DELETE
    // could quietly diverge from what the user could see.
    //
    // (i) A predicate the evaluator REFUSES surfaces as an error from both.
    try testing.expectError(
        error.InListRequiresList,
        h.exec("MATCH (n:EA) WHERE n.tag IN 'x' RETURN n"),
    );
    try testing.expectError(
        error.InListRequiresList,
        h.exec("MATCH (n:EA) WHERE n.tag IN 'x' DELETE n"),
    );
    try testing.expectEqual(@as(usize, 2), try h.countRows("MATCH (n:EA) RETURN n"));

    // (ii) Predicate classes the shared evaluator treats as non-matching select
    // NO rows for RETURN, and must therefore delete NOTHING. (That the engine
    // drops these rows rather than raising is an evaluator-wide behaviour, not
    // a DELETE behaviour — the point here is that DELETE no longer has its own
    // divergent swallow.)
    try testing.expectEqual(@as(usize, 0), try h.countRows("MATCH (n:EA) WHERE n.id / 0 = 1 RETURN n"));
    _ = try h.exec("MATCH (n:EA) WHERE n.id / 0 = 1 DELETE n");
    try testing.expectEqual(@as(usize, 2), try h.countRows("MATCH (n:EA) RETURN n"));

    try testing.expectEqual(@as(usize, 0), try h.countRows("MATCH (n:EA) WHERE banana(n.id) = 1 RETURN n"));
    _ = try h.exec("MATCH (n:EA) WHERE banana(n.id) = 1 DELETE n");
    try testing.expectEqual(@as(usize, 2), try h.countRows("MATCH (n:EA) RETURN n"));
}

test "ENG-3913: plain (non-DETACH) DELETE of a still-connected node still errors" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    _ = try h.exec("CREATE GRAPH eng3913_f");
    _ = try h.exec("USE GRAPH eng3913_f");
    _ = try h.exec("CREATE (:FA {id: 1})");
    _ = try h.exec("CREATE (:FB {id: 10})");
    _ = try h.exec("MATCH (a:FA {id: 1}), (b:FB {id: 10}) CREATE (a)-[:FR]->(b)");

    try testing.expectError(
        error.NodeHasEdges,
        h.exec("MATCH (a:FA)-[:FR]->(b:FB) DELETE a"),
    );
    try testing.expectEqual(@as(usize, 1), try h.countRows("MATCH (n:FA) RETURN n"));
    try testing.expectEqual(@as(usize, 1), try h.countRows("MATCH ()-[r:FR]->() RETURN r"));
}

test "ENG-3913: an unqualified label DELETE still removes every row of that label" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    _ = try h.exec("CREATE GRAPH eng3913_g");
    _ = try h.exec("USE GRAPH eng3913_g");
    _ = try h.exec("CREATE (:GA {id: 1})");
    _ = try h.exec("CREATE (:GA {id: 2})");
    _ = try h.exec("CREATE (:GB {id: 3})");

    _ = try h.exec("MATCH (n:GA) DELETE n");

    try testing.expectEqual(@as(usize, 0), try h.countRows("MATCH (n:GA) RETURN n"));
    try testing.expectEqual(@as(usize, 1), try h.countRows("MATCH (n:GB) RETURN n"));
}

test "ENG-3913: an inline-property DELETE still removes exactly the matching rows" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    _ = try h.exec("CREATE GRAPH eng3913_h");
    _ = try h.exec("USE GRAPH eng3913_h");
    _ = try h.exec("CREATE (:HP {id: 1, tag: 'a'})");
    _ = try h.exec("CREATE (:HP {id: 2, tag: 'b'})");
    _ = try h.exec("CREATE (:HP {id: 3, tag: 'a'})");

    _ = try h.exec("MATCH (n:HP {tag: 'a'}) DELETE n");

    try testing.expectEqual(@as(usize, 1), try h.countRows("MATCH (n:HP) RETURN n"));
    try testing.expect(try h.hasIdProp("MATCH (n:HP) RETURN n.id", 2));
}

test "ENG-3913: a $param inline property in the pattern deletes exactly the matching rows" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    _ = try h.exec("CREATE GRAPH eng3913_i");
    _ = try h.exec("USE GRAPH eng3913_i");
    _ = try h.exec("CREATE (:IP {id: 1, tag: 'a'})");
    _ = try h.exec("CREATE (:IP {id: 2, tag: 'b'})");

    const names = [_][]const u8{"t"};
    const values = [_]value_types.Value{.{ .Str = "a" }};
    _ = try h.execParams("MATCH (n:IP {tag: $t}) DELETE n", &names, &values);

    try testing.expectEqual(@as(usize, 1), try h.countRows("MATCH (n:IP) RETURN n"));
    try testing.expect(try h.hasIdProp("MATCH (n:IP) RETURN n.id", 2));
}
