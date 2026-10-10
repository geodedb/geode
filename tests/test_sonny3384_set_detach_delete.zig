// SONNY-3384: `MATCH … SET … DETACH DELETE x RETURN …` runs every clause, or
// is refused.
//
// The query parser took `DELETE` after a SET or a REMOVE, but not `DETACH
// DELETE`: `MATCH (x:Z) WHERE x.k = 0 SET x.z = 5 DETACH DELETE x RETURN …`
// left `DETACH` unparsed, and the rest ran as a statement of its own. The SET
// was applied, the DETACH DELETE silently skipped, and the answer was one row
// of 0 whatever the RETURN asked for. The query now carries the DETACH, and
// its executor (`crud_operations.executeMatchDeleteQuery`) deletes the nodes
// with their edges. A SET or REMOVE before the DELETE is applied first, in
// order, by the write step (SONNY-3042), and the RETURN is computed before
// the delete; a RETURN that holds a deleted element is refused (0A000)
// before anything is written. (On the r12 line such a SET was refused; the
// v0.8.23 reconciliation keeps the v0823 line's in-order write step.)
//
// gRPC in process.
//
// CANARY: REQ=REQ-SONNY-3384-SET-DELETE-RETURN; FEATURE="DELETE in Query"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3384_set_detach_delete.zig; OWNER=engine; UPDATED=2026-09-29

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const grpc = @import("grpc_impl").impl;
const fx = @import("sonny738_r12_grpc_fixture.zig");

const Answer = struct { code: ?[]const u8 = null, rows: usize = 0, first: ?i64 = null };

fn run(ga: std.mem.Allocator, s: []const u8, query: []const u8) !Answer {
    const resp = try fx.execute(ga, s, query);
    switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => |e| return .{ .code = e.code },
        .schema => {},
        else => return .{},
    }
    const req = try fx.encodeProto(ga, schema.PullRequest{ .session_id = s, .page_size = 64 });
    const pull = try fx.decodeProto(schema.PullResponse, ga, try grpc.handlePull(req, ga));
    const presp = pull.response orelse return error.MissingPayload;
    switch (presp.payload orelse return error.MissingPayload) {
        .page => |p| {
            var a: Answer = .{ .rows = p.rows.items.len };
            if (p.rows.items.len > 0 and p.rows.items[0].values.items.len > 0) {
                const v = p.rows.items[0].values.items[0];
                if (v.kind) |k| switch (k) {
                    .int_val => |i| a.first = i.value,
                    else => {},
                };
            }
            return a;
        },
        .@"error" => |e| return .{ .code = e.code },
        else => return error.UnexpectedPayload,
    }
}

fn count(ga: std.mem.Allocator, s: []const u8, query: []const u8) !usize {
    const a = try run(ga, s, query);
    if (a.code) |c| {
        std.debug.print("SONNY-3384: {s} refused {s}\n", .{ query, c });
        return error.QueryFailed;
    }
    return a.rows;
}

test "SONNY-3384: MATCH ... SET ... DETACH DELETE x RETURN ... deletes x with its edges and answers the RETURN" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("s3384");

    for (0..4) |k| {
        const q = try std.fmt.allocPrint(ga, "CREATE (:Z {{k: {d}}})-[:E]->(:ZO {{k: {d}}})", .{ k, k });
        try fx.expectRuns(ga, s, q);
    }

    // The review's Z0: the SET, the DETACH DELETE, the RETURN.
    const z0 = try run(ga, s, "MATCH (x:Z) WHERE x.k = 0 SET x.z = 5 DETACH DELETE x RETURN count(*) AS c");
    if (z0.code) |c| std.debug.print("SONNY-3384 Z0 refused {s}\n", .{c});
    try testing.expect(z0.code == null);
    try testing.expectEqual(@as(usize, 1), z0.rows);
    try testing.expectEqual(@as(?i64, 1), z0.first);
    try testing.expectEqual(@as(usize, 0), try count(ga, s, "MATCH (x:Z {k: 0}) RETURN x"));
    try testing.expectEqual(@as(usize, 0), try count(ga, s, "MATCH (:ZO {k: 0})<-[e:E]-() RETURN e"));
    try testing.expectEqual(@as(usize, 3), try count(ga, s, "MATCH (x:Z) RETURN x"));
    try testing.expectEqual(@as(usize, 4), try count(ga, s, "MATCH (o:ZO) RETURN o"));

    // Without a RETURN, and with REMOVE.
    try fx.expectRuns(ga, s, "MATCH (x:Z) WHERE x.k = 1 REMOVE x.k DETACH DELETE x");
    try testing.expectEqual(@as(usize, 2), try count(ga, s, "MATCH (x:Z) RETURN x"));

    // DELETE (not DETACH) of a node with an edge is still refused.
    const plain = try run(ga, s, "MATCH (x:Z) WHERE x.k = 2 SET x.z = 5 DELETE x RETURN count(*) AS c");
    try testing.expect(plain.code != null);
    try testing.expectEqual(@as(usize, 1), try count(ga, s, "MATCH (x:Z {k: 2}) WHERE x.z IS NULL RETURN x"));

    // A SET on a variable the statement does not delete is applied, in
    // order, before the delete (SONNY-3042's write step; the v0.8.23
    // reconciliation keeps it, where the r12 line refused the statement).
    const other = try run(ga, s, "MATCH (x:Z)-[:E]->(o:ZO) WHERE x.k = 2 SET o.z = 5 DETACH DELETE x RETURN count(*) AS c");
    if (other.code) |c| std.debug.print("SONNY-3384 other refused {s}\n", .{c});
    try testing.expect(other.code == null);
    try testing.expectEqual(@as(?i64, 1), other.first);
    try testing.expectEqual(@as(usize, 0), try count(ga, s, "MATCH (x:Z {k: 2}) RETURN x"));
    try testing.expectEqual(@as(usize, 1), try count(ga, s, "MATCH (o:ZO {k: 2}) WHERE o.z = 5 RETURN o"));

    // A RETURN reads the value the SET wrote (computed before the delete).
    const reads = try run(ga, s, "MATCH (x:Z) WHERE x.k = 3 SET x.z = 5 DETACH DELETE x RETURN x.z AS z");
    if (reads.code) |c| std.debug.print("SONNY-3384 reads refused {s}\n", .{c});
    try testing.expect(reads.code == null);
    try testing.expectEqual(@as(usize, 1), reads.rows);
    try testing.expectEqual(@as(?i64, 5), reads.first);
    try testing.expectEqual(@as(usize, 0), try count(ga, s, "MATCH (x:Z) RETURN x"));

    // A RETURN that holds the deleted element itself is refused, with
    // nothing written.
    try fx.expectRuns(ga, s, "CREATE (:Z {k: 4})-[:E]->(:ZO {k: 4})");
    const holds = try run(ga, s, "MATCH (x:Z) WHERE x.k = 4 SET x.z = 5 DETACH DELETE x RETURN x");
    try testing.expect(holds.code != null);
    try testing.expectEqual(@as(usize, 1), try count(ga, s, "MATCH (x:Z {k: 4}) WHERE x.z IS NULL RETURN x"));

    // SONNY-2694's shape is unchanged.
    try fx.expectRuns(ga, s, "CREATE (:Q {k: 1})");
    const q = try run(ga, s, "MATCH (q:Q) SET q.x = 1 DELETE q RETURN count(*) AS c");
    try testing.expect(q.code == null);
    try testing.expectEqual(@as(?i64, 1), q.first);
    try testing.expectEqual(@as(usize, 0), try count(ga, s, "MATCH (q:Q) RETURN q"));
}
