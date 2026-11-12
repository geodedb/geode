// SONNY-6292: `GRANT ROLE <custom role> TO <user>` (and
// `geode.auth.user_assign_role(<user>, <custom role>)`) answered "assigned
// custom role ..." and recorded the name in an in-memory side-table
// (`auth_dispatch.g_custom_role_members`) that:
//   (1) DROP ROLE did not clear, so a role re-created under the same name
//       silently went back to its old members;
//   (2) was never saved, so it was gone at the next start;
//   (3) nothing read for authorization: a custom role carries no
//       privileges (CREATE ROLE stores a name and a description; GRANT
//       ... ON GRAPH grants to users), so the statement reported a grant
//       that conferred nothing;
//   (4) was read through a slice returned after its lock was released.
//
// The ticket's second option is taken: a custom role cannot be granted to a
// user. The statement is refused with 0A000 (feature not supported) and
// changes nothing; the side-table is gone, so there is no membership to go
// stale, to lose at restart, or to read unlocked. Built-in roles are granted
// as before.
//
// The statements run through the real executor (`executeStatementWithContext`,
// authorization on, an Admin caller).
//
// CANARY: REQ=REQ-SONNY-6292-CUSTOM-ROLE-GRANT-REFUSED; FEATURE="GQL Auth DDL"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6292_custom_role_membership.zig; OWNER=security; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const harness = @import("node_scan_stream_harness.zig");

const user_mgmt = geode.user_management;
const execution = geode.execution;
const auth_dispatch = geode.auth_dispatch;

const World = struct {
    h: harness.Harness,
    auth_was: bool,

    fn init(self: *World) !void {
        harness.silenceEngineLogs();
        self.h = try harness.Harness.init(testing.allocator);
        self.auth_was = user_mgmt.isAuthEnabled();
        user_mgmt.setAuthEnabled(true);
        user_mgmt.deinitUserStore();
        try user_mgmt.initUserStore(testing.allocator);
        try user_mgmt.createUserWithHash(testing.allocator, "dave", "not_a_real_hash", "dave@example.com", .ReadOnly, false);
        auth_dispatch.deinitCustomRoleStore();
        self.h.ctx.role = .Admin;
        self.h.ctx.user = "root6292";
    }

    fn deinit(self: *World) void {
        auth_dispatch.deinitCustomRoleStore();
        user_mgmt.deinitUserStore();
        user_mgmt.setAuthEnabled(self.auth_was);
        self.h.deinit();
    }

    /// Run `query`; column 0 of the first row (or "" when there is none),
    /// copied into `out`.
    fn run(self: *World, query: []const u8, out: []u8) ![]const u8 {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var parsed = try geode.parseGqlOptions(query, a, .{});
        defer parsed.deinit();
        const result = try execution.executeStatementWithContext(a, parsed.program.statements[0], self.h.ctx);
        if (result.rows.len == 0 or result.rows[0].len == 0 or result.rows[0][0] != .Str) return out[0..0];
        const s = result.rows[0][0].Str;
        const n = @min(s.len, out.len);
        @memcpy(out[0..n], s[0..n]);
        return out[0..n];
    }

    fn expectRuns(self: *World, query: []const u8) !void {
        var buf: [256]u8 = undefined;
        _ = self.run(query, &buf) catch |err| {
            std.debug.print("{s}: {s}\n", .{ query, @errorName(err) });
            return err;
        };
    }

    /// The statement is refused as not supported (0A000 on the wire).
    fn expectNotSupported(self: *World, query: []const u8) !void {
        var buf: [256]u8 = undefined;
        if (self.run(query, &buf)) |status| {
            std.debug.print("{s}: ran, answered \"{s}\"; expected a 0A000 refusal\n", .{ query, status });
            return error.ExpectedRefusal;
        } else |err| {
            const info = geode.proto_util.mapError(err);
            if (!std.mem.eql(u8, info.code, "0A000")) std.debug.print("{s}: {s} ({s} {s})\n", .{ query, @errorName(err), info.code, info.message });
            try testing.expectEqualStrings("0A000", info.code);
        }
    }

    /// dave's effective permissions, as SHOW PERMISSIONS FOR lists them.
    fn davePermissions(self: *World) !usize {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        const a = arena.allocator();
        var parsed = try geode.parseGqlOptions("SHOW PERMISSIONS FOR dave", a, .{});
        defer parsed.deinit();
        const result = try execution.executeStatementWithContext(a, parsed.program.statements[0], self.h.ctx);
        return result.rows.len;
    }
};

test "SONNY-6292: GRANT ROLE <custom role> is refused as not supported and confers nothing; the procedure route too" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    const perms_before = try w.davePermissions();

    try w.expectRuns("CREATE ROLE auditors6292 SET DESCRIPTION 'reads the audit log'");
    try w.expectNotSupported("GRANT ROLE auditors6292 TO dave");
    try w.expectNotSupported("CALL geode.auth.user_assign_role('dave', 'auditors6292')");
    try w.expectNotSupported("ALTER USER dave SET ROLE auditors6292");

    // Nothing changed: dave keeps its built-in role and its permissions.
    try testing.expectEqual(user_mgmt.Role.ReadOnly, user_mgmt.getUser("dave").?.role);
    try testing.expectEqual(perms_before, try w.davePermissions());
}

test "SONNY-6292: a role dropped and re-created under the same name has no members" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();

    try w.expectRuns("CREATE ROLE ops6292");
    try w.expectNotSupported("GRANT ROLE ops6292 TO dave");
    try w.expectRuns("DROP ROLE ops6292");
    try w.expectRuns("CREATE ROLE ops6292");
    // Before the fix the side-table still listed dave under ops6292 here.
    // Now a grant of it is refused, with or without an earlier drop.
    try w.expectNotSupported("GRANT ROLE ops6292 TO dave");
    try testing.expectEqual(user_mgmt.Role.ReadOnly, user_mgmt.getUser("dave").?.role);
}

test "SONNY-6292: built-in roles are still granted, and an unknown role is still an error" {
    var w: World = undefined;
    try w.init();
    defer w.deinit();

    try w.expectRuns("GRANT ROLE readwrite TO dave");
    try testing.expectEqual(user_mgmt.Role.ReadWrite, user_mgmt.getUser("dave").?.role);
    var buf: [256]u8 = undefined;
    try testing.expectError(error.UnknownRole, w.run("GRANT ROLE nosuchrole6292 TO dave", &buf));
    try testing.expectEqual(user_mgmt.Role.ReadWrite, user_mgmt.getUser("dave").?.role);
}
