// CANARY: REQ=REQ-ENG-3916-EDGE-ID; FEATURE="GraphElementId"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_eng3916_edge_id_projection.zig:1; OWNER=eval; UPDATED=2026-08-25
//
// ENG-3916(b), engine half — two independent expression-layer defects:
//
//   1. `id()` had NO `.Edge` arm. `id(n)` on a node worked, `RETURN r`
//      projected a relationship object carrying that very id, but `id(r)` fell
//      through the switch to Null — so a relationship's identity could not be
//      named in ANY expression (no join key, no dedup key, no ORDER BY).
//
//   2. `toString(NULL)` returned the four-character STRING "null" instead of
//      NULL, in BOTH implementations (types/evaluator_functions.zig and the
//      duplicate in eval/call_handlers.zig). That violates ISO/IEC 39075 null
//      propagation and makes a missing value indistinguishable from a value
//      that literally spells "null": `toString(x) IS NULL` was always false,
//      and `toString(x) = 'null'` was TRUE for a missing x.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
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
        self.ctx.session_state = &self.session;
        const aa = self.arena.allocator();
        var parsed = try geode.parseGqlOptions(query, aa, .{});
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    pub fn scalar(self: *Harness, query: []const u8) !geode.value_types.Value {
        const res = try self.exec(query);
        if (res.rows.len != 1 or res.rows[0].len != 1) return error.UnexpectedShape;
        return res.rows[0][0];
    }
};

test "ENG-3916(b): id(r) returns the relationship's id, matching the projected r" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    _ = try h.exec("CREATE GRAPH eng3916");
    _ = try h.exec("USE GRAPH eng3916");
    _ = try h.exec("CREATE (:E16A {id: 1})");
    _ = try h.exec("CREATE (:E16B {id: 2})");
    _ = try h.exec("MATCH (a:E16A), (b:E16B) CREATE (a)-[:E16R {w: 5}]->(b)");

    // The relationship object a client already gets back from RETURN r is the
    // source of truth for what id(r) must answer.
    const projected = try h.scalar("MATCH ()-[r:E16R]->() RETURN r");
    const edge_id: i64 = switch (projected) {
        .Edge => |e| @intCast(e.id),
        else => return error.ExpectedEdgeProjection,
    };

    const via_id_fn = try h.scalar("MATCH ()-[r:E16R]->() RETURN id(r)");
    switch (via_id_fn) {
        .Int => |i| try testing.expectEqual(edge_id, i),
        // Before the fix this arm was taken: id() had no .Edge case at all.
        .Null => return error.IdOfRelationshipReturnedNull,
        else => return error.UnexpectedIdType,
    }
}

test "ENG-3916(b): toString(id(r)) is the id rendered as digits, not \"null\"" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    _ = try h.exec("CREATE GRAPH eng3916_ts");
    _ = try h.exec("USE GRAPH eng3916_ts");
    _ = try h.exec("CREATE (:T16A {id: 1})");
    _ = try h.exec("CREATE (:T16B {id: 2})");
    _ = try h.exec("MATCH (a:T16A), (b:T16B) CREATE (a)-[:T16R]->(b)");

    const projected = try h.scalar("MATCH ()-[r:T16R]->() RETURN r");
    const edge_id: u64 = switch (projected) {
        .Edge => |e| e.id,
        else => return error.ExpectedEdgeProjection,
    };
    var expected_buf: [32]u8 = undefined;
    const expected = try std.fmt.bufPrint(&expected_buf, "{d}", .{edge_id});

    const rendered = try h.scalar("MATCH ()-[r:T16R]->() RETURN toString(id(r))");
    switch (rendered) {
        .Str => |s| try testing.expectEqualStrings(expected, s),
        .Text => |s| try testing.expectEqualStrings(expected, s),
        else => return error.UnexpectedToStringType,
    }
}

test "ENG-3916(b): toString(NULL) IS NULL — null propagates, it does not stringify" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    _ = try h.exec("CREATE GRAPH eng3916_null");
    _ = try h.exec("USE GRAPH eng3916_null");

    // The value itself.
    const direct = try h.scalar("RETURN toString(null)");
    switch (direct) {
        .Null => {},
        .Str => |s| {
            std.debug.print("toString(null) returned the STRING '{s}'\n", .{s});
            return error.ToStringStringifiedNull;
        },
        .Text => |s| {
            std.debug.print("toString(null) returned the TEXT '{s}'\n", .{s});
            return error.ToStringStringifiedNull;
        },
        else => return error.UnexpectedToStringType,
    }

    // ...and the predicate a caller would actually write.
    const is_null = try h.scalar("RETURN toString(null) IS NULL");
    switch (is_null) {
        .Bool => |b| try testing.expect(b),
        else => return error.UnexpectedPredicateType,
    }

    // A missing property is a missing value, not the text "null".
    _ = try h.exec("CREATE (:N16 {id: 1})");
    const missing = try h.scalar("MATCH (n:N16) RETURN toString(n.absent) IS NULL");
    switch (missing) {
        .Bool => |b| try testing.expect(b),
        else => return error.UnexpectedPredicateType,
    }

    // Non-null arguments are unaffected.
    switch (try h.scalar("RETURN toString(5)")) {
        .Str => |s| try testing.expectEqualStrings("5", s),
        .Text => |s| try testing.expectEqualStrings("5", s),
        else => return error.UnexpectedToStringType,
    }
    switch (try h.scalar("RETURN toString(true)")) {
        .Str => |s| try testing.expectEqualStrings("true", s),
        .Text => |s| try testing.expectEqualStrings("true", s),
        else => return error.UnexpectedToStringType,
    }
}

test "ENG-3916(b): node id() is unchanged, and the non-element arms stay NULL" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();

    _ = try h.exec("CREATE GRAPH eng3916_node");
    _ = try h.exec("USE GRAPH eng3916_node");
    _ = try h.exec("CREATE (:D16A {id: 1})");
    _ = try h.exec("CREATE (:D16B {id: 2})");
    _ = try h.exec("MATCH (a:D16A), (b:D16B) CREATE (a)-[:D16R]->(b)");

    const projected = try h.scalar("MATCH (n:D16A) RETURN n");
    const node_id: i64 = switch (projected) {
        .Node => |n| @intCast(n.id),
        else => return error.ExpectedNodeProjection,
    };
    switch (try h.scalar("MATCH (n:D16A) RETURN id(n)")) {
        .Int => |i| try testing.expectEqual(node_id, i),
        else => return error.UnexpectedIdType,
    }

    // `r.id` is a PROPERTY lookup, and the relationship has no property named
    // `id` — NULL here is correct and is not what ENG-3916 changed. `id(r)` is
    // the way to name the identity.
    switch (try h.scalar("MATCH ()-[r:D16R]->() RETURN r.id")) {
        .Null => {},
        else => return error.ExpectedNullPropertyLookup,
    }

    // A path has no element identity in ISO/IEC 39075 — deliberately NULL.
    switch (try h.scalar("MATCH p = (a:D16A)-[:D16R]->(b:D16B) RETURN id(p)")) {
        .Null => {},
        else => return error.ExpectedNullPathId,
    }
}
