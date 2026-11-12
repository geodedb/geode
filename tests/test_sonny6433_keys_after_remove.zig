// SONNY-6433 item 1: a removed property is gone from keys() and properties().
//
// `REMOVE n.p` (and `SET n.p = null`, which removes it through the same
// chokepoint) writes a null tombstone into the node's or relationship's
// stored property chain (`StorageAdapter.removeNodeProperty`,
// `setEdgeProperty(.., .null)`). The read paths that rebuild an entity from
// the chain (`getAllNodeProperties` / `getAllEdgeProperties` and the
// zero-copy hydration scans) copied the tombstone into the property map, so
// `n.p` read null while keys(n) and properties(n) still listed p. ISO/IEC
// 39075:2024 13.4 <remove statement> General Rules: "the property PN is
// removed from the property set" of the element.
//
// Through the real gRPC handlers in process, with the production (bounded)
// caches so every read rebuilds the element from storage.
//
// CANARY: REQ=REQ-SONNY-6433-KEYS-AFTER-REMOVE; FEATURE="PropertyStorage"; ASPECT=RemovedPropertyAbsent; STATUS=TESTED; TEST=tests/test_sonny6433_keys_after_remove.zig; OWNER=storage; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const schema = @import("schema");
const grpc = @import("grpc_impl").impl;
const fx = @import("sonny738_r12_grpc_fixture.zig");

/// The first column of the first row as an integer (the query must run).
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
    if (got != want) std.debug.print("'{s}' answers {d}; expected {d}\n", .{ q, got, want });
    try testing.expectEqual(want, got);
}

fn checkRemoved(opts: fx.Fixture.Options) !void {
    var f: fx.Fixture = undefined;
    try f.initWith(opts);
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("s6433k");

    try fx.expectRuns(ga, s, "CREATE (:K6433 {k: 1, p: 2, q: 3})");
    try expectInt(ga, s, "MATCH (n:K6433) RETURN size(keys(n)) AS c", 3);

    try fx.expectRuns(ga, s, "MATCH (n:K6433) REMOVE n.p");
    try expectInt(ga, s, "MATCH (n:K6433) WHERE n.p IS NULL RETURN count(n) AS c", 1);
    try expectInt(ga, s, "MATCH (n:K6433) RETURN size(keys(n)) AS c", 2);
    try expectInt(ga, s, "MATCH (n:K6433) RETURN size(keys(properties(n))) AS c", 2);
    try expectInt(ga, s, "MATCH (n:K6433) WHERE 'p' IN keys(n) RETURN count(n) AS c", 0);

    try fx.expectRuns(ga, s, "MATCH (n:K6433) SET n.q = null");
    try expectInt(ga, s, "MATCH (n:K6433) RETURN size(keys(n)) AS c", 1);

    // Setting it again brings the key back.
    try fx.expectRuns(ga, s, "MATCH (n:K6433) SET n.p = 7");
    try expectInt(ga, s, "MATCH (n:K6433) RETURN size(keys(n)) AS c", 2);
    try expectInt(ga, s, "MATCH (n:K6433) RETURN n.p AS c", 7);

    try fx.expectRuns(ga, s, "CREATE (:KE6433)-[:KR6433 {w: 1, z: 2}]->(:KE6433)");
    try expectInt(ga, s, "MATCH ()-[r:KR6433]->() RETURN size(keys(r)) AS c", 2);
    try fx.expectRuns(ga, s, "MATCH ()-[r:KR6433]->() REMOVE r.z");
    try expectInt(ga, s, "MATCH ()-[r:KR6433]->() WHERE r.z IS NULL RETURN count(r) AS c", 1);
    try expectInt(ga, s, "MATCH ()-[r:KR6433]->() RETURN size(keys(r)) AS c", 1);
    try expectInt(ga, s, "MATCH ()-[r:KR6433]->() RETURN size(keys(properties(r))) AS c", 1);
    try fx.expectRuns(ga, s, "MATCH ()-[r:KR6433]->() SET r.w = null");
    try expectInt(ga, s, "MATCH ()-[r:KR6433]->() RETURN size(keys(r)) AS c", 0);
}

test "SONNY-6433: keys() and properties() omit a removed property (bounded caches)" {
    try checkRemoved(.{ .bounded_caches = true });
}

test "SONNY-6433: keys() and properties() omit a removed property (unbounded caches)" {
    try checkRemoved(.{});
}
