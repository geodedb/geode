// SONNY-6606 (6): an LSP principal whose verifier reports no role (an API
// key with no scopes, a session with no role) kept `AuthState.role`'s
// default, `.ReadOnly`: a read grant on every graph nobody gave it. It is
// now `.None` (no global permission; per-graph grants only), the fail-closed
// default a user with no stored role has everywhere else (2026-10).
//
// CANARY: REQ=REQ-SONNY-6606-LSP-ROLE-DEFAULT; FEATURE="Embedded LSP"; ASPECT=NoRoleIsNone; STATUS=TESTED; TEST=tests/test_sonny6606_lsp_role_default.zig; OWNER=lsp; UPDATED=2026-11-15
const std = @import("std");
const testing = std.testing;
const lsp_server = @import("lsp_server");
const auth = lsp_server.auth_mod_export;

const Stub = struct {
    role: ?[]const u8,

    fn verify(ctx: *anyopaque, token: []const u8) auth.Verifier.Outcome {
        _ = token;
        const self: *Stub = @ptrCast(@alignCast(ctx));
        return .{ .ok = .{ .username = "tok6606", .role = self.role } };
    }
};

fn verifiedRole(role: ?[]const u8) !@TypeOf(@as(auth.AuthState, undefined).role) {
    var stub = Stub{ .role = role };
    var state = auth.AuthState{ .token = try testing.allocator.dupe(u8, "sonny6606-token") };
    defer state.deinit(testing.allocator);
    try state.verify(testing.allocator, .{ .ctx = &stub, .verifyFn = Stub.verify });
    try testing.expect(state.verified);
    return state.role;
}

test "SONNY-6606 (6): a verified LSP principal with no role or an unknown one is None, not ReadOnly" {
    try testing.expect((try verifiedRole(null)) == .None);
    try testing.expect((try verifiedRole("none")) == .None);
    try testing.expect((try verifiedRole("superuser6606")) == .None);
    try testing.expect((try verifiedRole("readonly")) == .ReadOnly);
    try testing.expect((try verifiedRole("admin")) == .Admin);
}
