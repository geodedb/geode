// CANARY: REQ=REQ-SONNY-6647-REVOKE-NOT-HELD; FEATURE="GQL Auth DDL"; ASPECT=RevokeOfNothingRefused; STATUS=TESTED; TEST=tests/test_sonny6647_revoke_not_held.zig; OWNER=security; UPDATED=2026-11-15
//
// SONNY-6647 item 1: `REVOKE <privilege> ON GRAPH <graph> FROM <user>`
// (geode.auth.revoke) answered "Revoked ..." whether or not the user held
// the privilege on the graph: the revoke loop ignored what each revoke
// returned. Offline `geode revoke` refuses that case (SONNY-6586). Online it
// is now refused too, with SQLSTATE 42704 and nothing changed; a revoke of
// ALL succeeds when the user held any of the three.
//
// A real `geode serve`, as the bootstrap admin over QUIC.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const util = @import("proto_test_util.zig");

const user = "u6647";
const graph = "g6647";

const Want = union(enum) { ok, sqlstate: []const u8 };

fn run(a: std.mem.Allocator, c: *util.QuicProtoClient, q: []const u8, want: Want) !void {
    var r = try c.executeAndCollect(a, q, util.emptyParams(), 100);
    defer r.deinit(a);
    switch (want) {
        .ok => if (r.error_code) |code| {
            std.debug.print("SONNY-6647: `{s}` failed: {s} {s}\n", .{ q, code, r.error_message orelse "" });
            return error.TestUnexpectedResult;
        },
        .sqlstate => |s| {
            const code = r.error_code orelse {
                std.debug.print("SONNY-6647: `{s}` succeeded; want SQLSTATE {s}\n", .{ q, s });
                return error.TestUnexpectedResult;
            };
            if (!std.mem.eql(u8, code, s)) {
                std.debug.print("SONNY-6647: `{s}` answered {s} {s}; want {s}\n", .{ q, code, r.error_message orelse "", s });
                return error.TestUnexpectedResult;
            }
        },
    }
}

test "SONNY-6647 (1): an online REVOKE of a privilege the user does not hold on the graph is refused" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = testing.allocator;
    var server = try util.spawnServerRandom(a, util.TestEnv.standard());
    defer server.deinit();
    var c = try util.QuicProtoClient.connect(a, server.getAddr());
    defer c.deinit();
    {
        var h = try c.hello(a, util.defaultUsername(), util.defaultPassword());
        defer h.deinit(a);
        try testing.expect(h.success);
    }

    try run(a, &c, "CREATE USER " ++ user ++ " SET PASSWORD 'Correct Horse Battery Staple 6647'", .ok);
    // Never granted.
    try run(a, &c, "REVOKE READ ON GRAPH " ++ graph ++ " FROM " ++ user, .{ .sqlstate = "42704" });
    try run(a, &c, "REVOKE ALL ON GRAPH " ++ graph ++ " FROM " ++ user, .{ .sqlstate = "42704" });
    // The legacy '*' revoke, with no such grant.
    try run(a, &c, "CALL geode.auth.revoke('READ', '" ++ user ++ "', '*')", .{ .sqlstate = "42704" });

    try run(a, &c, "GRANT READ ON GRAPH " ++ graph ++ " TO " ++ user, .ok);
    // Held on another graph only.
    try run(a, &c, "REVOKE READ ON GRAPH other6647 FROM " ++ user, .{ .sqlstate = "42704" });
    // Held: revoked; then no longer held.
    try run(a, &c, "REVOKE READ ON GRAPH " ++ graph ++ " FROM " ++ user, .ok);
    try run(a, &c, "REVOKE READ ON GRAPH " ++ graph ++ " FROM " ++ user, .{ .sqlstate = "42704" });

    // ALL succeeds when any of the three is held, and takes them all.
    try run(a, &c, "GRANT WRITE ON GRAPH " ++ graph ++ " TO " ++ user, .ok);
    try run(a, &c, "REVOKE ALL ON GRAPH " ++ graph ++ " FROM " ++ user, .ok);
    try run(a, &c, "REVOKE WRITE ON GRAPH " ++ graph ++ " FROM " ++ user, .{ .sqlstate = "42704" });
}
