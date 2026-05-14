// CANARY: REQ=REQ-LSP-AUTH-GATE-001; FEATURE="LspPermissionAwareCompletion"; ASPECT=AuthGate; STATUS=TESTED; TEST=src/cli/lsp/server_auth_test.zig; OWNER=lsp; UPDATED=2026-05-14
//
// Task 12 of the LSP permission-aware completion plan. Covers the
// session-bind + auth-gate contract on `Server`:
//
//   1. `Server.isMethodAllowed("initialize")` and `"shutdown"` always
//      return true (the two LSP methods exempt from the gate).
//   2. Every other method returns false until `Server.auth.verified ==
//      true`. That field is set by `handleInitialize` after
//      `AuthState.verify` succeeds.
//   3. A `Server` constructed with `initWithAuth(null, false)` (the
//      stdio default) cannot transition any non-init method to true.
//   4. A `Server` with a hand-built verified AuthState DOES transition
//      the gate to open.
//
// We exercise the gate via the public `isMethodAllowed` helper rather
// than driving JSON-RPC through the real stdio transport — the
// Transport refactor lands in Task 25, and Task 29 will replay full
// initialize → completion sequences through the embedded transport
// once that lands.

const std = @import("std");
const testing = std.testing;
const server = @import("server.zig");
const auth = @import("auth.zig");

test "Server.isMethodAllowed exempts initialize and shutdown by default" {
    const alloc = testing.allocator;
    var srv = try server.Server.init(alloc);
    defer srv.deinit();

    try testing.expect(srv.isMethodAllowed("initialize"));
    try testing.expect(srv.isMethodAllowed("shutdown"));
}

test "Server.isMethodAllowed rejects non-init requests pre-auth" {
    const alloc = testing.allocator;
    var srv = try server.Server.init(alloc);
    defer srv.deinit();

    try testing.expect(!srv.isMethodAllowed("textDocument/completion"));
    try testing.expect(!srv.isMethodAllowed("textDocument/hover"));
    try testing.expect(!srv.isMethodAllowed("textDocument/definition"));
    try testing.expect(!srv.isMethodAllowed("textDocument/formatting"));
    try testing.expect(!srv.isMethodAllowed("textDocument/documentSymbol"));
    try testing.expect(!srv.isMethodAllowed("textDocument/references"));
    try testing.expect(!srv.isMethodAllowed("textDocument/signatureHelp"));
    try testing.expect(!srv.isMethodAllowed("textDocument/semanticTokens/full"));
}

test "Server.isMethodAllowed rejects unverified auth state" {
    const alloc = testing.allocator;
    var srv = try server.Server.init(alloc);
    defer srv.deinit();

    // Install an AuthState manually with verified=false — simulating
    // the state right after fromInitializeOptions but before verify
    // (which Task 12's handleInitialize would call). The gate must
    // still reject.
    srv.auth = auth.AuthState{
        .token = try alloc.dupe(u8, "opaque"),
        .user = "",
        .verified = false,
    };

    try testing.expect(!srv.isMethodAllowed("textDocument/completion"));
}

test "Server.isMethodAllowed opens the gate after a successful verify" {
    const alloc = testing.allocator;
    var srv = try server.Server.init(alloc);
    defer srv.deinit();

    // Hand-build a verified AuthState. Production code (Task 12's
    // handleInitialize) constructs the same shape after
    // AuthState.verify returns; here we shortcut to keep this test
    // focused on the gate's "is verified" predicate. The
    // `verifier`-backed path is covered by auth_test.zig's positive
    // test ("AuthState.verify resolves username and role through a
    // Verifier stub").
    srv.auth = auth.AuthState{
        .token = try alloc.dupe(u8, "opaque"),
        .user = try alloc.dupe(u8, "alice"),
        .role = .Admin,
        .verified = true,
    };

    try testing.expect(srv.isMethodAllowed("textDocument/completion"));
    try testing.expect(srv.isMethodAllowed("textDocument/hover"));
    // initialize and shutdown remain exempt regardless of auth state.
    try testing.expect(srv.isMethodAllowed("initialize"));
    try testing.expect(srv.isMethodAllowed("shutdown"));
}

test "Server.initWithAuth stores verifier and allow_unauth flag" {
    const alloc = testing.allocator;

    // No verifier, no allow_unauth — the default stdio path. The gate
    // must remain closed.
    var srv1 = try server.Server.initWithAuth(alloc, null, false);
    defer srv1.deinit();
    try testing.expect(srv1.verifier == null);
    try testing.expect(!srv1.allow_unauth);
    try testing.expect(!srv1.isMethodAllowed("textDocument/completion"));

    // allow_unauth = true with no verifier — Task 13 will land the
    // bindUnauthSession path; Task 12 just asserts the flag is held.
    var srv2 = try server.Server.initWithAuth(alloc, null, true);
    defer srv2.deinit();
    try testing.expect(srv2.allow_unauth);
}
