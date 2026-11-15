// SONNY-6607 (1): a read whose adjacency list or node property cannot be
// read fails; it never answers as if the node had no edges or the property
// were absent.
//
// `getOutgoingEdgeIds` / `getIncomingEdgeIds` returned null both for a node
// with no edges and for one whose evicted adjacency list could not be
// rebuilt (the hydrate's error), so a traversal took an unreadable node for
// a dead end. The MATCH fast paths over a bounded cache read node properties
// engine-direct and dropped a row whose read failed (`catch continue`), or
// read a failed tenant tag as the default tenant's (`catch null`).
//
// A real store with a data directory, the real gRPC handlers in process
// (`sonny738_r12_grpc_fixture.zig`), every adjacency list evicted and its
// rebuild made to fail (`BodyFault.adjacencyOn`): each traversal fails or
// answers exactly the healthy answer. (The fast paths' engine-direct
// property reads use the statement's internal scratch arena, which no test
// seam reaches; they are converted by inspection.)
//
// CANARY: REQ=REQ-SONNY-6607-ADJACENCY-PROPERTY-READ-FAILURE; FEATURE="StorageIntegrity"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6607_adjacency_property_read_failure.zig; OWNER=execution; UPDATED=2026-11-15

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const grpc = @import("grpc_impl").impl;
const fx = @import("sonny738_r12_grpc_fixture.zig");
const BodyFault = @import("sonny6594_body_fault.zig").BodyFault;

fn appendValue(ga: std.mem.Allocator, out: *std.ArrayList(u8), v: schema.Value) !void {
    const k = v.kind orelse return out.appendSlice(ga, "null");
    switch (k) {
        .null_val => try out.appendSlice(ga, "null"),
        .int_val => |i| try out.print(ga, "{d}", .{i.value}),
        .double_val => |d| try out.print(ga, "{d:.6}", .{d.value}),
        .bool_val => |b| try out.print(ga, "{}", .{b}),
        .string_val => |s| try out.appendSlice(ga, s.value),
        else => try out.appendSlice(ga, "?"),
    }
}

/// The answer as text, or null when the statement failed.
fn answer(ga: std.mem.Allocator, s: []const u8, query: []const u8) !?[]const u8 {
    const resp = try fx.execute(ga, s, query);
    switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => return null,
        else => {},
    }
    var out: std.ArrayList(u8) = .empty;
    while (true) {
        const req = try fx.encodeProto(ga, schema.PullRequest{ .session_id = s, .page_size = 256 });
        const pull = try fx.decodeProto(schema.PullResponse, ga, try grpc.handlePull(req, ga));
        const presp = pull.response orelse return error.MissingPayload;
        switch (presp.payload orelse return error.MissingPayload) {
            .page => |p| {
                for (p.rows.items) |row| {
                    for (row.values.items) |v| {
                        try appendValue(ga, &out, v);
                        try out.append(ga, ',');
                    }
                    try out.append(ga, ';');
                }
                if (p.final) return out.items;
            },
            .@"error" => return null,
            else => return error.UnexpectedPayload,
        }
    }
}

const traversals = [_][]const u8{
    "MATCH (a:Q6607)-[r:M6607]->(b:Q6607) RETURN a.i, b.i ORDER BY a.i",
    "MATCH (a:Q6607)<-[r:M6607]-(b:Q6607) RETURN a.i, b.i ORDER BY a.i",
    "MATCH (a:Q6607 {i: 0})-[:M6607*1..4]->(b:Q6607) RETURN b.i ORDER BY b.i",
    "MATCH p = shortestPath((a:Q6607 {i: 0})-[:M6607*]->(b:Q6607 {i: 4})) RETURN length(p)",
    "MATCH (a:Q6607) RETURN a.i, COUNT { (a)-[:M6607]->() } AS c ORDER BY a.i",
    "MATCH (s:Q6607 {i: 0}) CALL algo.bfs.stream(s, {maxDepth: 4}) YIELD path RETURN length(path) AS d ORDER BY d",
    "MATCH (s:Q6607 {i: 0}) CALL algo.dfs.stream(s, {maxDepth: 4}) YIELD path RETURN length(path) AS d ORDER BY d",
    "CALL algo.betweenness.stream() YIELD node, score RETURN count(node) AS c, sum(score) AS s",
    "CALL algo.pagerank.stream() YIELD node, score RETURN count(node) AS c, sum(score) AS s",
};

test "SONNY-6607 (1): a traversal whose adjacency list cannot be read fails, never takes the node for a dead end" {
    var f: fx.Fixture = undefined;
    try f.initWith(.{ .bounded_caches = true });
    defer f.deinit();
    const ga = f.ga();
    var fault: BodyFault = undefined;
    fault.init(f.st);
    const s = try f.session("a6607");
    try fx.expectRuns(ga, s, "CREATE (:Q6607 {i: 0})-[:M6607]->(:Q6607 {i: 1})-[:M6607]->(:Q6607 {i: 2})-[:M6607]->(:Q6607 {i: 3})-[:M6607]->(:Q6607 {i: 4})");

    var wrong: usize = 0;
    for (traversals) |q| {
        const want = (try answer(ga, s, q)) orelse {
            std.debug.print("SONNY-6607 (1) healthy run failed: {s}\n", .{q});
            return error.HealthyRunFailed;
        };
        try fault.evictAdjacency();
        fault.adjacencyOn();
        const got = try answer(ga, s, q);
        const induced = fault.off();
        if (got) |g| {
            if (!std.mem.eql(u8, g, want)) {
                wrong += 1;
                std.debug.print("SONNY-6607 (1) WRONG (adjacency read failed: {}): {s}\n    got  '{s}'\n    want '{s}'\n", .{ induced, q, g, want });
            }
        } else std.debug.print("SONNY-6607 (1) failed (adjacency read failed: {}): {s}\n", .{ induced, q });
    }
    try testing.expectEqual(@as(usize, 0), wrong);
}
