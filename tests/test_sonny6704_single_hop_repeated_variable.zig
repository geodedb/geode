// SONNY-6704 regression: a one-hop pattern that names ONE variable at both
// ends, MATCH (a)-[r:S]->(a), denotes one node (ISO/IEC 39075:2024 4.11, 16.7:
// one variable names one element), so only an edge that leaves and returns to
// the same node matches. The single-hop traversal and its aggregate path never
// checked it (GAP-0912 did so for variable-length patterns only), so the
// pattern matched every S edge: the read answered the other edges' start nodes,
// count(*) counted them, and SET wrote them (SONNY-3242 item 3).
//
// SONNY-6705 regression (same ticket family): SET a = b with a node or
// relationship on the right replaces a's properties with b's; any other
// non-map value is refused with 22G03 and a is left untouched. It used to
// clear every property of a and report success.
//
// Real gRPC handlers in process, every statement shape: read, count, SET,
// REMOVE, incoming and undirected directions.
//
// CANARY: REQ=REQ-SONNY-6704-SINGLE-HOP-REPEATED-VAR; FEATURE="RepeatedPatternVariable"; ASPECT=SingleHopEndpointUnify; STATUS=TESTED; TEST=tests/test_sonny6704_single_hop_repeated_variable.zig; OWNER=engine; UPDATED=2026-11-17

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

fn expectInt(ga: std.mem.Allocator, s: []const u8, q: []const u8, want: i64) !void {
    const got = (try firstInt(ga, s, q)) orelse -1;
    if (got != want) std.debug.print("{s}: got {d}, expected {d}\n", .{ q, got, want });
    try testing.expectEqual(want, got);
}

test "SONNY-6704: a one-hop pattern naming one variable at both ends matches only a loop" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("s6704");

    // 1 -S-> 2 (no loop), 3 -S-> 3 (a self-loop).
    try fx.expectRuns(ga, s, "CREATE (:N6704 {i: 1})-[:S6704]->(:N6704 {i: 2})");
    try fx.expectRuns(ga, s, "CREATE (c:N6704 {i: 3})-[:S6704]->(c)");

    // Sanity: three S-less nodes and two edges exist.
    try expectInt(ga, s, "MATCH (a:N6704)-[r:S6704]->(b) RETURN count(*) AS c", 2);

    // Read, aggregate and a projected node each see ONE row: the loop.
    try expectInt(ga, s, "MATCH (a:N6704)-[r:S6704]->(a) RETURN count(*) AS c", 1);
    try expectInt(ga, s, "MATCH (a:N6704)-[r:S6704]->(a) RETURN a.i AS i", 3);
    try expectInt(ga, s, "MATCH (a)-[r:S6704]->(a) RETURN count(*) AS c", 1);
    // Both ends labelled.
    try expectInt(ga, s, "MATCH (a:N6704)-[r:S6704]->(a:N6704) RETURN count(*) AS c", 1);
    // Incoming and undirected directions.
    try expectInt(ga, s, "MATCH (a:N6704)<-[r:S6704]-(a) RETURN count(*) AS c", 1);
    try expectInt(ga, s, "MATCH (a:N6704)-[r:S6704]-(a) RETURN count(*) AS c", 1);
    // A different variable at each end still matches both edges.
    try expectInt(ga, s, "MATCH (a:N6704)-[r:S6704]->(b:N6704) RETURN count(*) AS c", 2);
    // A multi-hop cycle through one variable already worked: keep it so.
    try expectInt(ga, s, "MATCH (a:N6704)-[:S6704]->(b)-[:S6704]->(a) RETURN count(*) AS c", 1);

    // Writes: only the loop's node is written.
    try fx.expectRuns(ga, s, "MATCH (a:N6704)-[r:S6704]->(a) SET a.s = 1");
    try expectInt(ga, s, "MATCH (a:N6704) RETURN count(a.s) AS c", 1);
    try expectInt(ga, s, "MATCH (a:N6704) WHERE a.s = 1 RETURN a.i AS i", 3);
    try fx.expectRuns(ga, s, "MATCH (a:N6704)-[r:S6704]->(a) SET r.w = 5");
    try expectInt(ga, s, "MATCH (a:N6704)-[r:S6704]->(b) RETURN count(r.w) AS c", 1);
    try fx.expectRuns(ga, s, "MATCH (a:N6704)-[r:S6704]->(a) REMOVE a.s");
    try expectInt(ga, s, "MATCH (a:N6704) RETURN count(a.s) AS c", 0);
}

test "SONNY-6705: SET a = b copies a node's properties; a non-map value is refused, not a wipe" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("s6705");

    try fx.expectRuns(ga, s, "CREATE (:A6705 {k: 1, p: 1}), (:B6705 {k: 5, w: 6})");

    // A map replaces (baseline, was already right).
    try fx.expectRuns(ga, s, "MATCH (a:A6705) SET a = {q: 2}");
    try expectInt(ga, s, "MATCH (a:A6705) RETURN a.q AS q", 2);
    try expectInt(ga, s, "MATCH (a:A6705) RETURN count(a.p) AS c", 0);

    // A node on the right copies its properties and drops a's own.
    try fx.expectRuns(ga, s, "MATCH (a:A6705), (b:B6705) SET a = b");
    try expectInt(ga, s, "MATCH (a:A6705) RETURN a.k AS k", 5);
    try expectInt(ga, s, "MATCH (a:A6705) RETURN a.w AS w", 6);
    try expectInt(ga, s, "MATCH (a:A6705) RETURN count(a.q) AS c", 0);
    // b is untouched.
    try expectInt(ga, s, "MATCH (b:B6705) RETURN b.k AS k", 5);

    // Any other non-map value is refused and leaves a alone.
    _ = try fx.expectRefused(ga, s, "MATCH (a:A6705) SET a = 5", "22G03");
    _ = try fx.expectRefused(ga, s, "MATCH (a:A6705) SET a = 'x'", "22G03");
    _ = try fx.expectRefused(ga, s, "MATCH (a:A6705) SET a = null", "22G03");
    try expectInt(ga, s, "MATCH (a:A6705) RETURN a.k AS k", 5);
    try expectInt(ga, s, "MATCH (a:A6705) RETURN a.w AS w", 6);

    // A relationship's properties copy onto a node as well.
    try fx.expectRuns(ga, s, "CREATE (:C6705)-[:R6705 {z: 9}]->(:C6705)");
    try fx.expectRuns(ga, s, "MATCH (a:A6705), (:C6705)-[r:R6705]->(:C6705) SET a = r");
    try expectInt(ga, s, "MATCH (a:A6705) RETURN a.z AS z", 9);
    try expectInt(ga, s, "MATCH (a:A6705) RETURN count(a.k) AS c", 0);
}
