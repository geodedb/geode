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
// Task 11: AuthState.verify
//
// The Geode codebase does not ship a JWT module. The QUIC server's auth
// path runs through `security.authn.AuthProvider` (API-key or
// session-token), and validation requires an `AuthProvider` instance
// bound to the live user store. That instance is not reachable from
// AuthState directly — Task 12 wires it in via the LSP `Server`.
//
// For Task 11 the load-bearing invariant is the empty-token reject; the
// positive path is deferred to Task 12 where the full LSP session test
// exercises a real `AuthProvider`.
// ---------------------------------------------------------------------

test "AuthState.verify rejects empty token" {
    const alloc = testing.allocator;
    var s = auth.AuthState{ .token = try alloc.dupe(u8, "") };
    defer s.deinit(alloc);
    try testing.expectError(auth.AuthError.MissingToken, s.verify(alloc));
    try testing.expect(!s.verified);
}

test "AuthState.verify leaves verified=false on non-empty unverifiable token" {
    // Until Task 12 plumbs an AuthProvider, every non-empty token is
    // rejected as InvalidToken. The state must remain unverified and no
    // user/role mutation should leak through.
    const alloc = testing.allocator;
    var s = auth.AuthState{ .token = try alloc.dupe(u8, "opaque-bearer-stub") };
    defer s.deinit(alloc);
    try testing.expectError(auth.AuthError.InvalidToken, s.verify(alloc));
    try testing.expect(!s.verified);
    try testing.expectEqual(@as(usize, 0), s.user.len);
}
