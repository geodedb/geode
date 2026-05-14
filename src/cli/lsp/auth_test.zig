// Task 10 of the LSP permission-aware completion plan.
//
// Tests the `initializeOptions.geode.*` parser. The `verify()` smoke
// test (Task 11) is appended below; full end-to-end coverage of a
// signed bearer lives in Task 12 once the LSP `Server` plumbs the
// existing `AuthProvider` instance into `AuthState`.

const std = @import("std");
const testing = std.testing;
const auth = @import("auth.zig");

test "AuthState.fromInitializeOptions parses geode.authToken" {
    const alloc = testing.allocator;
    const init_opts =
        \\{"geode":{"authToken":"eyJhbGciOi.test.signature","graph":"trade","tenant":"tA"}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, init_opts, .{});
    defer parsed.deinit();
    var state = try auth.AuthState.fromInitializeOptions(alloc, parsed.value);
    defer state.deinit(alloc);
    try testing.expectEqualStrings("eyJhbGciOi.test.signature", state.token);
    try testing.expectEqualStrings("trade", state.graph orelse "");
    try testing.expectEqualStrings("tA", state.tenant_id orelse "");
}

test "AuthState.fromInitializeOptions errors on missing token" {
    const alloc = testing.allocator;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, "{}", .{});
    defer parsed.deinit();
    try testing.expectError(
        auth.AuthError.MissingToken,
        auth.AuthState.fromInitializeOptions(alloc, parsed.value),
    );
}

// ---------------------------------------------------------------------
// Task 11/12: AuthState.verify
//
// Task 11 fail-closed when no verifier is plumbed (covered with `null`
// below). Task 12 lands the verifier vtable wiring so the LSP server
// can pass a real authn.AuthProvider-backed verifier from Task 28's
// `geode serve` path. The positive case here installs an in-test
// stub verifier — we exercise the contract (verify resolves username
// + role on success) without depending on `security/authn.zig`, which
// does not yet compile against Zig 0.16 (see auth.zig's Verifier doc).
// ---------------------------------------------------------------------

test "AuthState.verify rejects empty token" {
    const alloc = testing.allocator;
    var s = auth.AuthState{ .token = try alloc.dupe(u8, "") };
    defer s.deinit(alloc);
    try testing.expectError(auth.AuthError.MissingToken, s.verify(alloc, null));
    try testing.expect(!s.verified);
}

test "AuthState.verify with null verifier rejects any non-empty token" {
    // Fail-closed: no verifier means we have no way to authenticate, so
    // every non-empty token is reported as InvalidToken and the state
    // remains unverified. This is the stdio-LSP path until Task 28
    // plumbs the live verifier through `geode serve`.
    const alloc = testing.allocator;
    var s = auth.AuthState{ .token = try alloc.dupe(u8, "opaque-bearer-stub") };
    defer s.deinit(alloc);
    try testing.expectError(auth.AuthError.InvalidToken, s.verify(alloc, null));
    try testing.expect(!s.verified);
    try testing.expectEqual(@as(usize, 0), s.user.len);
}

// Task 12 stub-verifier positive path. We construct a minimal Verifier
// whose `ctx` carries a (token → outcome) decision table. The LSP server
// in production will install a verifier wrapping
// `authn.AuthProvider.authenticate`; the contract surface here is the
// same — Outcome.ok with a username + optional role name.
const TestVerifierState = struct {
    expected_token: []const u8,
    username: []const u8,
    role: ?[]const u8,
};

fn testVerifierFn(ctx: *anyopaque, token: []const u8) auth.Verifier.Outcome {
    const state: *TestVerifierState = @ptrCast(@alignCast(ctx));
    if (!std.mem.eql(u8, token, state.expected_token)) return .invalid;
    return .{ .ok = .{ .username = state.username, .role = state.role } };
}

test "AuthState.verify resolves username and role through a Verifier stub" {
    const alloc = testing.allocator;
    var state = TestVerifierState{
        .expected_token = "valid-token-xyz",
        .username = "alice",
        .role = "admin",
    };
    const verifier = auth.Verifier{
        .ctx = @ptrCast(&state),
        .verifyFn = testVerifierFn,
    };

    var s = auth.AuthState{ .token = try alloc.dupe(u8, "valid-token-xyz") };
    defer s.deinit(alloc);
    try s.verify(alloc, verifier);

    try testing.expect(s.verified);
    try testing.expectEqualStrings("alice", s.user);
    // "admin" string maps through user_management.Role.fromString.
    const user_management = @import("geode").user_management;
    try testing.expectEqual(user_management.Role.Admin, s.role);
}

test "AuthState.verify with Verifier rejects an unknown token" {
    const alloc = testing.allocator;
    var state = TestVerifierState{
        .expected_token = "valid-token-xyz",
        .username = "alice",
        .role = "admin",
    };
    const verifier = auth.Verifier{
        .ctx = @ptrCast(&state),
        .verifyFn = testVerifierFn,
    };

    var s = auth.AuthState{ .token = try alloc.dupe(u8, "wrong-token") };
    defer s.deinit(alloc);
    try testing.expectError(auth.AuthError.InvalidToken, s.verify(alloc, verifier));
    try testing.expect(!s.verified);
}
