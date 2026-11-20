// SONNY-6433 item 2 (the SONNY-3245 remainder): MERGE keys and FOR ...
// CREATE ... RETURN.
//
//   1. A MERGE whose pattern gives a property the null value is refused
//      with 22004 (data exception: null value not allowed, ISO/IEC
//      39075:2024 22.x status codes) and writes nothing. A null property
//      value is absent (SONNY-3245: CREATE and SET), and `k = null` is
//      Unknown (ISO 19.x <comparison predicate>), so the pattern can match
//      no node; MERGE (a Geode extension) created a node without the key
//      every time instead, one more on each run.
//   2. A MERGE on a list-valued key matches the node it created: the second
//      run of `MERGE (n:L {k: [1, 2]})` made a duplicate every time.
//   3. `FOR u IN [...] CREATE ... RETURN u` returns u (it returned null).
//
// Through the real gRPC handlers in process.
//
// CANARY: REQ=REQ-SONNY-6433-MERGE-KEYS; FEATURE="MergeStatement"; ASPECT=NullAndListKeys; STATUS=TESTED; TEST=tests/test_sonny6433_merge_keys.zig; OWNER=engine; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const schema = @import("schema");
const grpc = @import("grpc_impl").impl;
const fx = @import("sonny738_r12_grpc_fixture.zig");

/// Every row's first column as an integer (a non-integer reads as -1).
fn columnInts(ga: std.mem.Allocator, s: []const u8, q: []const u8) ![]i64 {
    const resp = try fx.execute(ga, s, q);
    switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => |e| {
            std.debug.print("{s}: {s} {s}\n", .{ q, e.code, e.message });
            return error.QueryFailed;
        },
        .schema => {},
        else => return &.{},
    }
    var out: std.ArrayList(i64) = .empty;
    while (true) {
        const req = try fx.encodeProto(ga, schema.PullRequest{ .session_id = s, .page_size = 64 });
        const pull = try fx.decodeProto(schema.PullResponse, ga, try grpc.handlePull(req, ga));
        const presp = pull.response orelse return error.MissingPayload;
        switch (presp.payload orelse return error.MissingPayload) {
            .page => |p| {
                for (p.rows.items) |row| {
                    const v: i64 = if (row.values.items.len == 0) -1 else if (row.values.items[0].kind) |k| switch (k) {
                        .int_val => |x| x.value,
                        else => -1,
                    } else -1;
                    try out.append(ga, v);
                }
                if (p.final) break;
            },
            .@"error" => |e| {
                std.debug.print("{s}: {s} {s}\n", .{ q, e.code, e.message });
                return error.QueryFailed;
            },
            else => return error.UnexpectedPayload,
        }
    }
    return out.items;
}

fn expectInt(ga: std.mem.Allocator, s: []const u8, q: []const u8, want: i64) !void {
    const rows = try columnInts(ga, s, q);
    const got: i64 = if (rows.len == 0) -1 else rows[0];
    if (got != want) std.debug.print("'{s}' answers {d}; expected {d}\n", .{ q, got, want });
    try testing.expectEqual(want, got);
}

test "SONNY-6433: MERGE with a null key is refused with 22004 and writes nothing" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("s6433n");

    _ = try fx.expectRefused(ga, s, "MERGE (n:MN6433 {k: null})", "22004");
    _ = try fx.expectRefused(ga, s, "MERGE (n:MN6433 {k: null})", "22004");
    _ = try fx.expectRefused(ga, s, "MERGE (n:MN6433 {k: 1, j: null})", "22004");
    _ = try fx.expectRefused(ga, s, "MERGE (n:MN6433 {k: 1 + null})", "22004");
    try expectInt(ga, s, "MATCH (n:MN6433) RETURN count(n) AS c", 0);

    // A later clause's null key: the earlier clause writes nothing either.
    _ = try fx.expectRefused(ga, s, "MERGE (a:MA6433 {k: 1}) MERGE (b:MA6433 {k: null})", "22004");
    try expectInt(ga, s, "MATCH (n:MA6433) RETURN count(n) AS c", 0);

    // A relationship key.
    _ = try fx.expectRefused(ga, s, "MERGE (a:MR6433 {k: 1})-[:MRT6433 {w: null}]->(b:MR6433 {k: 2})", "22004");
    try expectInt(ga, s, "MATCH (n:MR6433) RETURN count(n) AS c", 0);
    try fx.expectRuns(ga, s, "CREATE (:MR6433 {k: 1}), (:MR6433 {k: 2})");
    _ = try fx.expectRefused(ga, s, "MATCH (a:MR6433 {k: 1}), (b:MR6433 {k: 2}) MERGE (a)-[:MRT6433 {w: null}]->(b)", "22004");
    try expectInt(ga, s, "MATCH ()-[r:MRT6433]->() RETURN count(r) AS c", 0);

    // Control: ON CREATE SET to null is a SET (the property is absent), not a key.
    try fx.expectRuns(ga, s, "MERGE (n:MC6433 {k: 1}) ON CREATE SET n.j = null");
    try fx.expectRuns(ga, s, "MERGE (n:MC6433 {k: 1}) ON CREATE SET n.j = null");
    try expectInt(ga, s, "MATCH (n:MC6433) RETURN count(n) AS c", 1);
}

test "SONNY-6433: MERGE on a list-valued key matches the node it created" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("s6433l");

    inline for (0..3) |_| try fx.expectRuns(ga, s, "MERGE (n:ML6433 {k: [1, 2]})");
    try expectInt(ga, s, "MATCH (n:ML6433) RETURN count(n) AS c", 1);
    // An inline list property in MATCH compares the same way.
    try expectInt(ga, s, "MATCH (n:ML6433 {k: [1, 2]}) RETURN count(n) AS c", 1);
    try fx.expectRuns(ga, s, "MERGE (n:ML6433 {k: [2, 1]})");
    try expectInt(ga, s, "MATCH (n:ML6433) RETURN count(n) AS c", 2);

    inline for (0..2) |_| try fx.expectRuns(ga, s, "MERGE (n:MS6433 {k: ['a', 'b'], j: 1})");
    try expectInt(ga, s, "MATCH (n:MS6433) RETURN count(n) AS c", 1);

    inline for (0..2) |_| try expectInt(ga, s, "MERGE (n:MX6433 {k: [1, 2]}) RETURN size(n.k) AS c", 2);
    try expectInt(ga, s, "MATCH (n:MX6433) RETURN count(n) AS c", 1);

    // A list-valued relationship key.
    try fx.expectRuns(ga, s, "CREATE (:MLE6433 {k: 1}), (:MLE6433 {k: 2})");
    inline for (0..2) |_| try fx.expectRuns(ga, s, "MATCH (a:MLE6433 {k: 1}), (b:MLE6433 {k: 2}) MERGE (a)-[:MLR6433 {w: [3, 4]}]->(b)");
    try expectInt(ga, s, "MATCH ()-[r:MLR6433]->() RETURN count(r) AS c", 1);
}

test "SONNY-6433: FOR u IN [...] CREATE ... RETURN u returns u" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("s6433f");

    const rows = try columnInts(ga, s, "FOR u IN [1, 2, 3] CREATE (:FU6433 {v: u}) RETURN u");
    if (rows.len != 3 or rows[0] != 1 or rows[1] != 2 or rows[2] != 3) std.debug.print("FOR ... RETURN u answered {any}\n", .{rows});
    try testing.expectEqualSlices(i64, &.{ 1, 2, 3 }, rows);
    try expectInt(ga, s, "MATCH (n:FU6433) RETURN count(n) AS c", 3);

    const vs = try columnInts(ga, s, "FOR u IN [4, 5] CREATE (n:FV6433 {v: u}) RETURN n.v AS v");
    try testing.expectEqualSlices(i64, &.{ 4, 5 }, vs);
}
