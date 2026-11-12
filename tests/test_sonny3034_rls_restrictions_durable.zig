// SONNY-3034 regression: the restrictions `geode.rls.*` adds survive a
// restart, and their removal does too.
//
// `geode.rls.add_deny_policy` (a label deny for a user) and
// `geode.rls.add_attribute_policy` (a row property that must equal the
// caller's ABAC attribute) changed the in-memory RLS engines only: a server
// restart dropped every one, so a deny an operator added stopped applying
// with no warning, and in a cluster the restriction applied on one node
// only. They are now stored in `__geode_security`, sealed like the other
// security records, loaded back at startup, and refused in cluster mode
// (no replication slice: `cluster.gateUnreplicatedWrite`).
//
// The test runs the real server: it adds both kinds of restriction, checks
// that they apply to a user over QUIC, restarts the server on the same data
// directory, checks that they still apply (and are listed), removes them,
// restarts again, and checks that they are gone.
//
// CANARY: REQ=REQ-SONNY-3034-RLS-RESTRICTIONS-DURABLE; FEATURE="RLS deny-policy procedure"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3034_rls_restrictions_durable.zig; OWNER=security; UPDATED=2026-11-12

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const util = @import("proto_test_util.zig");

const binary_path = "./zig-out/bin/geode";
const bob_pw = "Correct Horse Battery Staple Seven";

fn skipWithoutBinary() !void {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    std.Io.Dir.cwd().access(std.Io.Threaded.global_single_threaded.io(), binary_path, .{}) catch return error.SkipZigTest;
}

const Server = struct {
    proc: util.ServerHandle,
    addr: []const u8,

    fn start(allocator: std.mem.Allocator, data_dir: []const u8) !Server {
        const port = try util.getRandomPort();
        const addr = try util.formatAddr(allocator, port);
        errdefer allocator.free(addr);
        var proc = try util.spawnServer(allocator, &.{ binary_path, "serve", "--listen", addr, "--data-dir", data_dir }, util.TestEnv.standard());
        errdefer proc.deinit();
        try util.waitForServerReady(allocator, addr, 30000);
        return .{ .proc = proc, .addr = addr };
    }

    fn stop(self: *Server, allocator: std.mem.Allocator) void {
        self.proc.deinit();
        allocator.free(self.addr);
    }
};

/// Run `query` as `user`; the rows, or an error naming the refusal.
fn rowsAs(allocator: std.mem.Allocator, addr: []const u8, user: []const u8, password: []const u8, query: []const u8) !usize {
    var client = try util.QuicProtoClient.connect(allocator, addr);
    defer client.deinit();
    var h = try client.hello(allocator, user, password);
    defer h.deinit(allocator);
    if (!h.success) {
        std.debug.print("HELLO as {s} refused: {s}\n", .{ user, h.error_message });
        return error.HelloRefused;
    }
    var r = try client.executeAndCollect(allocator, query, util.emptyParams(), 10);
    defer r.deinit(allocator);
    if (r.error_code) |c| {
        std.debug.print("`{s}` as {s}: {s} {?s}\n", .{ query, user, c, r.error_message });
        return error.QueryRefused;
    }
    return r.rows.len;
}

fn asAdmin(allocator: std.mem.Allocator, addr: []const u8, query: []const u8) !usize {
    return rowsAs(allocator, addr, util.defaultUsername(), util.defaultPassword(), query);
}

const secret_q = "MATCH (s:Secret3034) RETURN s.v AS v";
const doc_q = "MATCH (d:Doc3034) RETURN d.dept AS dept";

/// What bob sees: the Secret3034 rows and the Doc3034 rows.
fn bobSees(allocator: std.mem.Allocator, addr: []const u8) ![2]usize {
    return .{
        try rowsAs(allocator, addr, "bob", bob_pw, secret_q),
        try rowsAs(allocator, addr, "bob", bob_pw, doc_q),
    };
}

test "SONNY-3034: geode.rls deny and attribute policies, and their removal, survive a server restart" {
    try skipWithoutBinary();
    const allocator = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir_buf: [96]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&dir_buf, "/tmp/geode-sonny3034-{d}", .{try util.getRandomPort()});
    std.Io.Dir.cwd().deleteTree(io, data_dir) catch {};
    try std.Io.Dir.cwd().createDirPath(io, data_dir);
    defer std.Io.Dir.cwd().deleteTree(io, data_dir) catch {};

    // 1. Data, a user, and the two restrictions.
    {
        var s = try Server.start(allocator, data_dir);
        defer s.stop(allocator);
        _ = try asAdmin(allocator, s.addr, "CREATE USER bob SET PASSWORD '" ++ bob_pw ++ "' ROLE readwrite");
        _ = try asAdmin(allocator, s.addr, "CREATE (:Secret3034 {v: 1})");
        _ = try asAdmin(allocator, s.addr, "CREATE (:Doc3034 {dept: 'eng'})");
        try testing.expectEqual([2]usize{ 1, 1 }, try bobSees(allocator, s.addr));

        _ = try asAdmin(allocator, s.addr, "CALL geode.rls.add_deny_policy('default', 'Secret3034', 'bob')");
        _ = try asAdmin(allocator, s.addr, "CALL geode.rls.add_attribute_policy('default', 'Doc3034', 'dept', 'department')");
        try testing.expectEqual([2]usize{ 0, 0 }, try bobSees(allocator, s.addr));
    }

    // 2. After a restart they still apply, and the deny is listed.
    {
        var s = try Server.start(allocator, data_dir);
        defer s.stop(allocator);
        const seen = try bobSees(allocator, s.addr);
        if (seen[0] != 0 or seen[1] != 0) {
            std.debug.print("after a restart bob sees {d} Secret3034 row(s) (deny) and {d} Doc3034 row(s) (attribute policy); both were restricted before it\n", .{ seen[0], seen[1] });
            return error.RestrictionLostAtRestart;
        }
        try testing.expectEqual(@as(usize, 1), try asAdmin(allocator, s.addr, "CALL geode.rls.list_deny_policies()"));

        _ = try asAdmin(allocator, s.addr, "CALL geode.rls.remove_deny_policy('default', 'Secret3034', 'bob')");
        _ = try asAdmin(allocator, s.addr, "CALL geode.rls.remove_attribute_policy('default', 'Doc3034', 'dept', 'department')");
        try testing.expectEqual([2]usize{ 1, 1 }, try bobSees(allocator, s.addr));
    }

    // 3. After another restart the removed restrictions stay removed.
    {
        var s = try Server.start(allocator, data_dir);
        defer s.stop(allocator);
        const seen = try bobSees(allocator, s.addr);
        if (seen[0] != 1 or seen[1] != 1) {
            std.debug.print("after a restart bob sees {d} Secret3034 and {d} Doc3034 row(s); the removed restrictions came back\n", .{ seen[0], seen[1] });
            return error.RemovedRestrictionCameBack;
        }
        try testing.expectEqual(@as(usize, 0), try asAdmin(allocator, s.addr, "CALL geode.rls.list_deny_policies()"));
    }
}
