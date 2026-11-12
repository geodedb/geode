// SONNY-3125 regression: a node that several matched rows share is written
// once per row, each write reading what the row before it wrote. The hop and
// multi-chain writers read the shared node's copy from before the statement,
// so `SET c.n = c.n + 1` over N rows left n = 1 instead of N.
//
// Already fixed by 984754d2 (SONNY-3240, SONNY-3242): every SET and REMOVE
// runs in the write step (`applySetRemoveOverRows`), one row at a time,
// re-reading the element by id. This pins it.
//
// Star patterns through the real gRPC handlers in process: one hop each way,
// two hops, two chains (a cartesian product), a chain and a hop, with and
// without a RETURN, and a REMOVE beside the SET.
//
// CANARY: REQ=REQ-SONNY-3125-SHARED-NODE-SET; FEATURE="SetClauseSemantics"; ASPECT=PerRowReread; STATUS=TESTED; TEST=tests/test_sonny3125_shared_node_set.zig; OWNER=engine; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const schema = @import("schema");
const grpc = @import("grpc_impl").impl;
const fx = @import("sonny738_r12_grpc_fixture.zig");

fn firstInt(ga: std.mem.Allocator, s: []const u8, q: []const u8) !?i64 {
    const resp = try fx.execute(ga, s, q);
    switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => |e| {
            std.debug.print("{s}: {s} {s}\n", .{ q, e.code, e.message });
            return error.QueryFailed;
        },
        .schema => {},
        else => return null,
    }
    const req = try fx.encodeProto(ga, schema.PullRequest{ .session_id = s, .page_size = 8 });
    const pull = try fx.decodeProto(schema.PullResponse, ga, try grpc.handlePull(req, ga));
    const presp = pull.response orelse return error.MissingPayload;
    switch (presp.payload orelse return error.MissingPayload) {
        .page => |p| {
            if (p.rows.items.len == 0 or p.rows.items[0].values.items.len == 0) return null;
            const k = p.rows.items[0].values.items[0].kind orelse return null;
            return switch (k) {
                .int_val => |x| x.value,
                else => null,
            };
        },
        .@"error" => |e| {
            std.debug.print("{s}: {s} {s}\n", .{ q, e.code, e.message });
            return error.QueryFailed;
        },
        else => return error.UnexpectedPayload,
    }
}

fn expectCount(ga: std.mem.Allocator, s: []const u8, what: []const u8, want: i64) !void {
    const got = (try firstInt(ga, s, "MATCH (c:C3125) RETURN c.n AS n")) orelse -1;
    if (got != want) std.debug.print("{s}: c.n = {d}; expected {d}\n", .{ what, got, want });
    try testing.expectEqual(want, got);
}

test "SONNY-3125: a SET reading a node that N rows share is applied N times" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("s3125");

    // A centre with three leaves; each leaf has one child.
    try fx.expectRuns(ga, s, "CREATE (:C3125 {n: 0})");
    inline for (.{ 1, 2, 3 }) |i| {
        // Named middle node: an unnamed one shared by two hops of a CREATE
        // path was created twice (SONNY-3245).
        try fx.expectRuns(ga, s, std.fmt.comptimePrint("MATCH (c:C3125) CREATE (c)-[:E3125]->(l:L3125 {{i: {d}}})-[:F3125]->(:K3125 {{i: {d}}})", .{ i, i }));
    }

    try fx.expectRuns(ga, s, "MATCH (c:C3125)-[:E3125]->(l:L3125) SET c.n = c.n + 1");
    try expectCount(ga, s, "one hop, out", 3);

    try fx.expectRuns(ga, s, "MATCH (l:L3125)<-[:E3125]-(c:C3125) SET c.n = c.n + 1");
    try expectCount(ga, s, "one hop, in", 6);

    try fx.expectRuns(ga, s, "MATCH (c:C3125)-[:E3125]->(:L3125)-[:F3125]->(k:K3125) SET c.n = c.n + 1");
    try expectCount(ga, s, "two hops", 9);

    try fx.expectRuns(ga, s, "MATCH (c:C3125), (l:L3125) SET c.n = c.n + 1");
    try expectCount(ga, s, "two chains", 12);

    try fx.expectRuns(ga, s, "MATCH (c:C3125), (l:L3125)-[:F3125]->(k:K3125) SET c.n = c.n + 1");
    try expectCount(ga, s, "a chain and a hop", 15);

    // With a RETURN: the last row sees every increment.
    const max = (try firstInt(ga, s, "MATCH (c:C3125)-[:E3125]->(l:L3125) SET c.n = c.n + 1 RETURN max(c.n) AS m")) orelse -1;
    try testing.expectEqual(@as(i64, 18), max);
    try expectCount(ga, s, "with a RETURN", 18);

    // A REMOVE beside the SET, on the leaves; the centre still counts rows.
    try fx.expectRuns(ga, s, "MATCH (c:C3125)-[:E3125]->(l:L3125) SET c.n = c.n + 1 REMOVE l.i");
    try expectCount(ga, s, "beside a REMOVE", 21);
}
