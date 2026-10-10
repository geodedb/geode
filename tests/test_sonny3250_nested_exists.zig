// SONNY-3250 (round 15, F4; pre-existing): a nested EXISTS or COUNT
// subquery no longer reads an environment that was freed.
//
// `graph_algorithms.countPatternMatches` (the EXISTS and COUNT { } subquery
// counter) built the environment its WHERE is evaluated in, with the
// subquery's node bound, into arrays it freed with a `defer` at the end of
// the block that made them; the WHERE was then evaluated with `ext_env`
// still pointing at them. `evaluateWhereFilter` (the WHERE of a subquery
// with a hop) did the same. A WHERE that holds a nested subquery allocates
// again, gets the freed memory back, and copies the environment onto itself:
// `MATCH (n:C) WHERE EXISTS { MATCH (m:C) WHERE EXISTS { MATCH (m:C) WHERE
// m.v >= 0 } } RETURN count(n)` panicked with "@memcpy arguments alias", a
// use after free any reader could trigger (the round 14 review's F4).
//
// Now the arrays live until the WHERE has been evaluated. Nested EXISTS and
// COUNT at depth 2 and 3, uncorrelated and correlated, with and without a
// hop, through the real gRPC handler; each answer is checked. Run the step
// in Debug and in ReleaseSafe (`-Doptimize=ReleaseSafe`).
//
// CANARY: REQ=REQ-SONNY-3250-NESTED-EXISTS-UAF; FEATURE="ExistsSubquery"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3250_nested_exists.zig; OWNER=execution; UPDATED=2026-09-28

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
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

const Case = struct { q: []const u8, want: i64 };

test "SONNY-3250: nested EXISTS and COUNT subqueries at depth 2 and 3 answer correctly, with no use after free" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("nested");
    // (0)-[:R]->(1)-[:R]->(2)
    try fx.expectRuns(ga, s, "CREATE (:C {v: 0})");
    try fx.expectRuns(ga, s, "CREATE (:C {v: 1})");
    try fx.expectRuns(ga, s, "CREATE (:C {v: 2})");
    try fx.expectRuns(ga, s, "MATCH (a:C {v: 0}), (b:C {v: 1}) CREATE (a)-[:R]->(b)");
    try fx.expectRuns(ga, s, "MATCH (a:C {v: 1}), (b:C {v: 2}) CREATE (a)-[:R]->(b)");
    const cases = [_]Case{
        // The review's repro: depth 2, uncorrelated.
        .{ .q = "MATCH (n:C) WHERE EXISTS { MATCH (m:C) WHERE EXISTS { MATCH (m:C) WHERE m.v >= 0 } } RETURN count(n) AS c", .want = 3 },
        // Depth 3.
        .{ .q = "MATCH (n:C) WHERE EXISTS { MATCH (m:C) WHERE EXISTS { MATCH (k:C) WHERE EXISTS { MATCH (j:C) WHERE j.v >= 0 } } } RETURN count(n) AS c", .want = 3 },
        // Correlated: each level reads the one above.
        .{ .q = "MATCH (n:C) WHERE EXISTS { MATCH (m:C) WHERE m.v = n.v AND EXISTS { MATCH (k:C) WHERE k.v = m.v } } RETURN count(n) AS c", .want = 3 },
        .{ .q = "MATCH (n:C) WHERE EXISTS { MATCH (m:C) WHERE m.v = n.v AND EXISTS { MATCH (k:C) WHERE k.v = m.v AND EXISTS { MATCH (j:C) WHERE j.v = k.v } } } RETURN count(n) AS c", .want = 3 },
        // A nested subquery that is false for every row.
        .{ .q = "MATCH (n:C) WHERE EXISTS { MATCH (m:C) WHERE EXISTS { MATCH (k:C) WHERE k.v > 5 } } RETURN count(n) AS c", .want = 0 },
        // COUNT { } at depth 2 and 3.
        .{ .q = "MATCH (n:C {v: 0}) RETURN COUNT { MATCH (m:C) WHERE COUNT { MATCH (k:C) WHERE k.v >= m.v } > 1 } AS c", .want = 2 },
        .{ .q = "MATCH (n:C {v: 0}) RETURN COUNT { MATCH (m:C) WHERE COUNT { MATCH (k:C) WHERE k.v >= m.v AND COUNT { MATCH (j:C) WHERE j.v = k.v } = 1 } > 1 } AS c", .want = 2 },
        // With a hop (`evaluateWhereFilter`): from (0), (1) has an out-edge
        // to (2), whose value is >= 0.
        .{ .q = "MATCH (n:C) WHERE EXISTS { MATCH (n)-[:R]->(m) WHERE EXISTS { MATCH (m)-[:R]->(k) } } RETURN count(n) AS c", .want = 1 },
        .{ .q = "MATCH (n:C) WHERE EXISTS { MATCH (n)-[:R]->(m) WHERE EXISTS { MATCH (m)-[:R]->(k) WHERE EXISTS { MATCH (j:C) WHERE j.v = k.v } } } RETURN count(n) AS c", .want = 1 },
        .{ .q = "MATCH (n:C) WHERE EXISTS { MATCH (n)-[:R]->(m) WHERE m.v >= 0 AND EXISTS { MATCH (k:C) WHERE k.v = m.v } } RETURN count(n) AS c", .want = 2 },
    };
    var failures: usize = 0;
    // Each several times: the freed arrays were reused by the next
    // allocation, and which one that is varies.
    var round: usize = 0;
    while (round < 5) : (round += 1) {
        for (cases) |c| {
            const got = firstInt(ga, s, c.q) catch |e| blk: {
                std.debug.print("{s}: {s}\n", .{ c.q, @errorName(e) });
                break :blk null;
            };
            const ok = got != null and got.? == c.want;
            if (round == 0 or !ok) std.debug.print("{s} -> {any} (want {d}){s}\n", .{ c.q, got, c.want, if (ok) "" else "  <-- UNEXPECTED" });
            if (!ok) failures += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}
