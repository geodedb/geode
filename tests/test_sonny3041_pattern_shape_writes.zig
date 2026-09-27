// SONNY-3041 regression: a SET or REMOVE on a comma pattern, or after an
// OPTIONAL MATCH, wrote nothing.
//
// `MATCH (a:G), (q:Q) WHERE a.i = 5 AND q.i = 0 SET a.x = 1 RETURN count(*)`
// returned 1 and set nothing, and `MATCH (n:G) OPTIONAL MATCH (n)-[:R]->(x)
// SET n.y = 1 RETURN count(*)` returned 10 and set nothing: the executors of
// those shapes (executeMultiNodeMatch, executeMatchWithOptionalPatterns) never
// read the SET or REMOVE clauses. Nothing stopped an executor from being
// handed a write it does not apply.
//
// A SET or REMOVE on these shapes now goes through the one write step: the
// rows are read as any read reads them, and the SET and REMOVE applied to the
// elements each row binds, by id, once per row (a SET that reads what it
// writes sees the rows before it). A SET on an OPTIONAL MATCH variable that
// did not bind writes nothing for that row. And a structural guard makes a
// silent drop impossible: every executor declares the write clauses it
// applies, and refuses (0A000) a statement that carries one it does not.
//
// CANARY: REQ=REQ-SONNY-3041-PATTERN-SHAPE-WRITES; FEATURE="WriteStep"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3041_pattern_shape_writes.zig; OWNER=engine; UPDATED=2026-09-27

const std = @import("std");
const testing = std.testing;
const linux = std.os.linux;
const geode = @import("geode");
const h = @import("sonny738_write_harness.zig");

const Case = h.Case;

const x5 = [_]h.Check{.{ .query = "MATCH (n:G) WHERE n.x = 1 RETURN n.i", .want = &.{"5"} }};

const comma_cases = [_]Case{
    // The ticket's statements.
    .{ .write = "MATCH (a:G), (q:Q) WHERE a.i = 5 AND q.i = 0 SET a.x = 1", .checks = &x5 },
    .{ .write = "MATCH (a:G), (q:Q) WHERE a.i = 5 AND q.i = 0 SET a.x = 1 RETURN count(*) AS c", .want = &.{"1"}, .checks = &x5 },
    .{ .write = "MATCH (a:G), (q:Q) WHERE a.i = 5 AND q.i = 0 REMOVE a.t RETURN count(*) AS c", .want = &.{"1"}, .checks = &.{
        .{ .query = "MATCH (n:G) WHERE n.t IS NULL RETURN n.i", .want = &.{"5"} },
    } },
    // Both variables, a value from the other one, and labels.
    .{ .write = "MATCH (a:G), (q:Q) WHERE a.i = 5 SET q.x = a.i RETURN count(*) AS c", .want = &.{"4"}, .checks = &.{
        .{ .query = "MATCH (q:Q) WHERE q.x = 5 RETURN q.i", .want = &.{ "0", "1", "2", "3" } },
    } },
    .{ .write = "MATCH (a:G), (q:Q) WHERE a.i = 5 AND q.i = 0 SET a:Hit, q:Hit", .checks = &.{
        .{ .query = "MATCH (n:Hit) RETURN n.i", .want = &.{ "0", "5" } },
    } },
    // Once per row: each G is in 4 rows.
    .{ .write = "MATCH (a:G), (q:Q) WHERE a.i >= 8 SET a.c = coalesce(a.c, 0) + 1 RETURN count(*) AS c", .want = &.{"8"}, .checks = &.{
        .{ .query = "MATCH (n:G) WHERE n.c IS NOT NULL RETURN n.i, n.c", .want = &.{ "8|4", "9|4" } },
    } },
    // The RETURN sees what was written.
    .{ .write = "MATCH (a:G), (q:Q) WHERE a.i = 5 AND q.i = 0 SET a.x = 1 RETURN a.i, a.x", .want = &.{"5|1"}, .checks = &x5 },
};

test "SONNY-3041: a SET or REMOVE on a comma pattern writes every matched row" {
    try h.runCases("comma pattern", &comma_cases);
}

const optional_cases = [_]Case{
    // The ticket's statements.
    .{ .write = "MATCH (n:G) OPTIONAL MATCH (n)-[:R]->(x:X) SET n.y = 1 RETURN count(*) AS c", .want = &.{"10"}, .checks = &.{
        .{ .query = "MATCH (n:G) WHERE n.y = 1 RETURN count(*) AS c", .want = &.{"10"} },
    } },
    .{ .write = "MATCH (n:G) OPTIONAL MATCH (n)-[:R]->(x:X) REMOVE n.t", .checks = &.{
        .{ .query = "MATCH (n:G) WHERE n.t IS NULL RETURN count(*) AS c", .want = &.{"10"} },
    } },
    // The optional variable.
    .{ .write = "MATCH (n:G) WHERE n.i >= 7 OPTIONAL MATCH (n)-[:R]->(x:X) SET x.x = 1 RETURN count(*) AS c", .want = &.{"3"}, .checks = &.{
        .{ .query = "MATCH (x:X) WHERE x.x = 1 RETURN x.j", .want = &.{ "7", "8", "9" } },
    } },
    // An optional variable that did not bind: nothing to write on that row.
    .{ .write = "MATCH (n:G) WHERE n.i < 2 OPTIONAL MATCH (n)-[:NOPE]->(y) SET n.y = 1, y.y = 1 RETURN count(*) AS c", .want = &.{"2"}, .checks = &.{
        .{ .query = "MATCH (n) WHERE n.y = 1 RETURN n.i", .want = &.{ "0", "1" } },
    } },
};

test "SONNY-3041: a SET or REMOVE after an OPTIONAL MATCH writes every matched row" {
    try h.runCases("OPTIONAL MATCH", &optional_cases);
}

// ---------------------------------------------------------------------------
// The guard: one structural check, every executor.

fn readFile(allocator: std.mem.Allocator, path: []const u8) ![]u8 {
    var pathz: [4096]u8 = undefined;
    @memcpy(pathz[0..path.len], path);
    pathz[path.len] = 0;
    const rc = linux.open(@ptrCast(&pathz), .{ .ACCMODE = .RDONLY }, 0);
    if (@as(isize, @bitCast(rc)) < 0) return error.FileNotFound;
    const fd: i32 = @intCast(rc);
    defer _ = linux.close(fd);
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    var chunk: [8192]u8 = undefined;
    while (true) {
        const n_signed: isize = @bitCast(linux.read(fd, &chunk, chunk.len));
        if (n_signed < 0) return error.ReadFailed;
        if (n_signed == 0) break;
        try buf.appendSlice(allocator, chunk[0..@intCast(n_signed)]);
    }
    return buf.toOwnedSlice(allocator);
}

/// The body of `fn <name>(` in `source`, up to the next top-level `}`.
fn fnBody(source: []const u8, name: []const u8) ?[]const u8 {
    var needle_buf: [128]u8 = undefined;
    const needle = std.fmt.bufPrint(&needle_buf, "fn {s}(", .{name}) catch return null;
    const at = std.mem.indexOf(u8, source, needle) orelse return null;
    const end = std.mem.indexOfPos(u8, source, at, "\n}\n") orelse return null;
    return source[at..end];
}

test "SONNY-3041: every executor that reads a pattern refuses a write clause it does not apply" {
    const allocator = testing.allocator;

    // Each classification of the guard: a write the executor applies is
    // accepted, any other is refused.
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const Probe = struct { src: []const u8, sets: bool };
    const probes = [_]Probe{
        .{ .src = "MATCH (n:G) RETURN n", .sets = true },
        .{ .src = "MATCH (n:G) SET n.x = 1", .sets = true },
        .{ .src = "MATCH (n:G) REMOVE n.t", .sets = true },
        .{ .src = "MATCH (n:G) CREATE (:Z)", .sets = false },
        .{ .src = "MATCH (n:G) MERGE (:M)", .sets = false },
        .{ .src = "MATCH (q:Q) SET q.x = 1 DELETE q", .sets = false },
    };
    // (Checked at compile time so the file still builds, and fails here,
    // where the guard does not exist.)
    if (comptime @hasDecl(geode.execution, "refuseUnappliedWrites")) {
        for (probes) |p| {
            var parsed = try geode.parseGql(p.src, aa);
            defer parsed.deinit();
            const q = parsed.program.statements[0].Query;
            const reads_only = geode.execution.refuseUnappliedWrites(q, .{});
            const set_remove = geode.execution.refuseUnappliedWrites(q, .{ .set = true, .remove = true });
            const writes_anything = q.set_clauses.len != 0 or q.remove_clauses.len != 0 or q.create_pattern != null or q.merge_statement != null or q.delete_items.len != 0;
            if (writes_anything) {
                try testing.expectError(error.WriteClauseNotApplied, reads_only);
            } else try reads_only;
            if (p.sets) try set_remove else try testing.expectError(error.WriteClauseNotApplied, set_remove);
        }
    } else return error.GuardMissing;

    // Every executor that reads a pattern for a query calls the guard.
    const source = try readFile(allocator, "src/execution/match_operations.zig");
    defer allocator.free(source);
    const executors = [_][]const u8{
        "executeMatchQueryImpl",
        "executeMultiNodeMatch",
        "executeMultiChainRelationshipMatch",
        "executeMatchWithOptionalPatterns",
    };
    for (executors) |name| {
        const body = fnBody(source, name) orelse {
            std.debug.print("executor {s} not found\n", .{name});
            return error.ExecutorMissing;
        };
        if (std.mem.indexOf(u8, body, "refuseUnappliedWrites(") == null) {
            std.debug.print("executor {s} does not call the write guard\n", .{name});
            return error.ExecutorUnguarded;
        }
    }
    // And so do the chain's executors, for the parts after a WITH.
    const chain = try readFile(allocator, "src/execution/query_execution.zig");
    defer allocator.free(chain);
    for ([_][]const u8{ "executeQueryWithBindingsImpl", "executeQueryChain" }) |name| {
        const body = fnBody(chain, name) orelse return error.ExecutorMissing;
        if (std.mem.indexOf(u8, body, "refuseUnappliedWrites(") == null and std.mem.indexOf(u8, body, "refuseChainedWrites(") == null) {
            std.debug.print("chain executor {s} does not call the write guard\n", .{name});
            return error.ExecutorUnguarded;
        }
    }
}
