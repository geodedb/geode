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
const transport = @import("transport.zig");

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

// Task 13: when started with `--no-auth` the server must accept an
// `initialize` request that ships no `initializationOptions.geode`
// block, synthesize a local-admin AuthState from $USER, and open the
// gate so subsequent textDocument requests are served.
//
// We drive the public `handleMessage` with a JSON-RPC `initialize`
// frame rather than poking the private `handleInitialize` — same
// pattern `server_invalid_params_test.zig` uses. The Transport's
// write side does fire (it buffers the response to stdout's framer),
// but we don't read it back; our assertions look at the gate's state
// after the request lands.
//
// CANARY: REQ=REQ-LSP-AUTH-NOAUTH-001; FEATURE="LspPermissionAwareCompletion"; ASPECT=NoAuthBind; STATUS=TESTED; TEST=src/cli/lsp/server_auth_test.zig; OWNER=lsp; UPDATED=2026-05-14
test "Server with allow_unauth synthesizes a local AuthState on initialize without token" {
    const alloc = testing.allocator;

    // publishVerifiedState reaches ensureCatalogInstance which initializes
    // the process-global catalog with this test's allocator. The
    // singleton outlives the test, so without an explicit teardown the
    // testing allocator's leak detector flags the catalog + its data_dir
    // dupe. Tear it down WITHIN this test (deferred to fire AFTER
    // srv.deinit) so the bucket metadata is still in scope.
    defer @import("geode").execution.tearDownGlobalCatalogForTest();

    // Use a noop transport — `handleMessage(initialize)` below sends
    // the LSP `initialize` response via `transport.writeMessage`. With
    // the default stdio transport that write lands on process stdout,
    // which under `zig build test --listen=-` IS the test-runner
    // protocol pipe; the stray LSP headers corrupt the framing and
    // deadlock the runner. NoopTransport drops the write so the
    // protocol stream stays clean. Test still asserts on Server state
    // post-call (no observation of the dropped response needed).
    var srv = try server.Server.initWithTransport(alloc, transport.Transport.initNoop(alloc), null, true);
    defer srv.deinit();

    // Pre-condition: the gate is closed because initialize has not
    // run yet.
    try testing.expect(!srv.isMethodAllowed("textDocument/completion"));

    // An `initialize` request that ships NO `initializationOptions` —
    // exactly what a terminal LSP client (neovim, helix, VS Code over
    // stdio) sends when it has no JWT to forward.
    const init_msg =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"rootUri":null}}
    ;
    try srv.handleMessage(init_msg);

    // Post-condition 1: auth is populated and verified as Admin.
    try testing.expect(srv.auth != null);
    const a = srv.auth.?;
    try testing.expect(a.verified);
    try testing.expectEqual(@as(@TypeOf(a.role), .Admin), a.role);
    try testing.expect(a.user.len > 0);

    // Post-condition 2: gate is open for normal LSP requests.
    try testing.expect(srv.isMethodAllowed("textDocument/completion"));
    try testing.expect(srv.isMethodAllowed("textDocument/hover"));

    // Post-condition 3: SchemaProvider + ExecutionContext are wired up
    // the same way the verified-token path wires them — completion
    // handlers in Task 17+ can read both unconditionally.
    try testing.expect(srv.schema != null);
    try testing.expect(srv.exec_context != null);
}

// Task 13: even when the client omits its token, the default stdio
// path (allow_unauth=false) MUST stay fail-closed. This is the safety
// belt for Task 28's TCP listener, which is required to construct
// the Server with allow_unauth=false regardless of any CLI flag.
test "Server without allow_unauth rejects initialize that omits the geode auth block" {
    const alloc = testing.allocator;
    // Use noop transport — even though this test EXPECTS bindSession
    // to reject the request, the rejection path still calls
    // `respondInitializeError` which writes a JSON-RPC error response
    // through the transport. On stdio that lands on the test-runner
    // protocol pipe under `zig build test --listen=-` and corrupts
    // the framing. NoopTransport drops the write; the test still
    // asserts on `srv.auth == null` and `isMethodAllowed == false`.
    var srv = try server.Server.initWithTransport(alloc, transport.Transport.initNoop(alloc), null, false);
    defer srv.deinit();

    const init_msg =
        \\{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"capabilities":{},"rootUri":null}}
    ;
    try srv.handleMessage(init_msg);

    // bindSession returned MissingToken; respondInitializeError sent
    // -32002. Server.auth stays null and the gate stays closed.
    try testing.expect(srv.auth == null);
    try testing.expect(!srv.isMethodAllowed("textDocument/completion"));
}
