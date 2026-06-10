// GAP-0820..0824 — LSP "honest non-support" contract.
//
// The accepted completion path for these five gaps (per the gap register) is
// EXPLICIT NON-SUPPORT, not a stub implementation: Geode's LSP server does not
// advertise these capabilities, and it must behave honestly toward a client
// that asks for them anyway —
//
//   - an unadvertised feature REQUEST is answered with JSON-RPC error -32601
//     (MethodNotFound), echoing the request id, so the client fails fast
//     instead of waiting on its read timeout for a reply that never comes; and
//   - an unadvertised NOTIFICATION is silently tolerated (no response, no
//     crash, no error frame), per JSON-RPC 2.0 §5 (a server MUST NOT reply to
//     a notification it does not handle).
//
// This is the inverse-direction guarantee to GAP-0831's capability↔handler
// truthfulness guard: GAP-0831 proves every advertised capability HAS a
// handler; this suite proves the deliberately-UNADVERTISED capabilities have
// NO handler and degrade cleanly. The two together pin the contract from both
// sides so a future refactor cannot silently start advertising (or stop
// honestly rejecting) any of these methods.
//
// Per-gap test blocks:
//   GAP-0820 (Medium): workspace/* family — workspace/symbol,
//     workspace/configuration, workspace/applyEdit are REQUESTS → -32601;
//     workspace/didChangeWorkspaceFolders is a NOTIFICATION → silently
//     tolerated. No `workspace` capability section is advertised.
//   GAP-0821 (Medium): textDocument/rename + textDocument/prepareRename
//     REQUESTS → -32601; `renameProvider` absent from capabilities.
//   GAP-0822 (Medium): textDocument/codeAction REQUEST → -32601;
//     `codeActionProvider` absent.
//   GAP-0823 (Low): textDocument/inlayHint REQUEST → -32601;
//     `inlayHintProvider` absent.
//   GAP-0824 (Low): textDocumentSync advertises NO save support (bare integer
//     `1` = Full sync, no `save`/`willSave`/`willSaveWaitUntil` members);
//     textDocument/willSave + textDocument/didSave NOTIFICATIONS silently
//     tolerated; textDocument/willSaveWaitUntil REQUEST → -32601.
//
// All assertions drive the real `handleMessage` path over a CAPTURING Noop
// transport and inspect the EXACT JSON-RPC frame the production server emitted
// — no mocks, no simulated responses. The notification-tolerance assertions
// PRIME a known result frame, send the notification, then assert the captured
// last frame is UNCHANGED — proving the notification wrote nothing back.
//
// CANARY: REQ=REQ-LSP-CAP-001; FEATURE="HonestNonSupport"; ASPECT=NonSupportContract; STATUS=TESTED; OWNER=lsp; UPDATED=2026-06-09

const std = @import("std");
const testing = std.testing;

const server = @import("lsp_server");
const transport = server.transport_mod;

const METHOD_NOT_FOUND: i64 = -32601;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// A `--no-auth` (allow_unauth = true) server over a capturing Noop transport,
/// driven through `initialize` so the auth gate is open for feature requests.
/// (An unadvertised method must reach the -32601 fallthrough, NOT be turned
/// away by the auth gate, so the session is authenticated first.) Caller
/// deinits the returned Server AND must tear down the global catalog.
fn newCapturingServer(alloc: std.mem.Allocator) !server.Server {
    var srv = try server.Server.initWithTransport(
        alloc,
        transport.Transport.initNoopCapturing(alloc),
        null,
        true, // allow_unauth — synthesize local-admin AuthState on initialize
    );
    errdefer srv.deinit();
    const init_msg =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"rootUri":null}}
    ;
    try srv.handleMessage(init_msg);
    return srv;
}

/// True when the last written frame is a JSON-RPC error with `code` AND its
/// `id` equals the integer `id`. Proves the rejection echoes the request id.
fn lastFrameIsErrorWithCodeAndId(
    alloc: std.mem.Allocator,
    srv: *const server.Server,
    code: i64,
    id: i64,
) !bool {
    const frame = srv.lastWrittenForTest() orelse return false;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, frame, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const id_v = parsed.value.object.get("id") orelse return false;
    if (id_v != .integer or id_v.integer != id) return false;
    const err = parsed.value.object.get("error") orelse return false;
    if (err != .object) return false;
    const c = err.object.get("code") orelse return false;
    if (c != .integer) return false;
    return c.integer == code;
}

/// Drive an unadvertised feature REQUEST and assert it is answered with
/// -32601 (MethodNotFound) echoing the request id. `id` is unique per call so
/// the captured frame is unambiguous.
fn expectMethodNotFound(
    alloc: std.mem.Allocator,
    srv: *server.Server,
    method: []const u8,
    id: i64,
) !void {
    const msg = try std.fmt.allocPrint(
        alloc,
        "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"{s}\",\"params\":{{\"textDocument\":{{\"uri\":\"file:///x.gql\"}}}}}}",
        .{ id, method },
    );
    defer alloc.free(msg);
    try srv.handleMessage(msg);
    try testing.expect(try lastFrameIsErrorWithCodeAndId(alloc, srv, METHOD_NOT_FOUND, id));
}

/// Prime a known result frame, send a NOTIFICATION (no id), and assert the
/// captured last frame is UNCHANGED — proving the notification produced no
/// response, did not crash, and did not emit an error frame.
fn expectNotificationSilentlyTolerated(
    alloc: std.mem.Allocator,
    srv: *server.Server,
    notification_json: []const u8,
) !void {
    // Prime: a normal request whose result frame we capture as the baseline.
    // documentSymbol on an unknown doc returns an empty-array result (no error).
    try srv.handleMessage(
        \\{"jsonrpc":"2.0","id":900,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///x.gql"}}}
    );
    const before = srv.lastWrittenForTest() orelse return error.NoBaselineFrame;
    const before_copy = try alloc.dupe(u8, before);
    defer alloc.free(before_copy);

    // The notification must not crash and must write nothing.
    try srv.handleMessage(notification_json);

    const after = srv.lastWrittenForTest() orelse return error.FrameDisappeared;
    // No new frame was written: the last captured frame is byte-for-byte the
    // primed result. (A notification never gets a reply.)
    try testing.expectEqualStrings(before_copy, after);
}

/// Collect advertised capability keys from the exact production builder so the
/// "absence" assertions cannot drift from what `initialize` actually serializes.
fn assertCapabilityAbsent(alloc: std.mem.Allocator, key: []const u8) !void {
    var caps = try server.buildCapabilitiesObject(alloc, .utf16);
    defer server.deinitCapabilitiesObject(alloc, &caps);
    try testing.expect(caps.get(key) == null);
}

// ---------------------------------------------------------------------------
// GAP-0820 — workspace/* family: explicit non-support (capabilities trimmed)
// ---------------------------------------------------------------------------

test "GAP-0820: workspace/* requests -> -32601, notification tolerated, no workspace capability" {
    const alloc = testing.allocator;
    defer @import("geode").execution.tearDownGlobalCatalogForTest();
    var srv = try newCapturingServer(alloc);
    defer srv.deinit();

    // No `workspace` capability section is advertised at all.
    try assertCapabilityAbsent(alloc, "workspace");
    // Nor any of the individual workspace request capabilities.
    try assertCapabilityAbsent(alloc, "workspaceSymbolProvider");
    try assertCapabilityAbsent(alloc, "executeCommandProvider");

    // workspace/* REQUESTS are unadvertised -> -32601.
    try expectMethodNotFound(alloc, &srv, "workspace/symbol", 20);
    try expectMethodNotFound(alloc, &srv, "workspace/configuration", 21);
    try expectMethodNotFound(alloc, &srv, "workspace/applyEdit", 22);
    try expectMethodNotFound(alloc, &srv, "workspace/executeCommand", 23);

    // workspace/didChangeWorkspaceFolders is a NOTIFICATION -> silently tolerated.
    try expectNotificationSilentlyTolerated(alloc, &srv,
        \\{"jsonrpc":"2.0","method":"workspace/didChangeWorkspaceFolders","params":{"event":{"added":[],"removed":[]}}}
    );
}

// ---------------------------------------------------------------------------
// GAP-0821 — rename / prepareRename: explicit non-support
// ---------------------------------------------------------------------------

test "GAP-0821: rename + prepareRename requests -> -32601, renameProvider absent" {
    const alloc = testing.allocator;
    defer @import("geode").execution.tearDownGlobalCatalogForTest();
    var srv = try newCapturingServer(alloc);
    defer srv.deinit();

    try assertCapabilityAbsent(alloc, "renameProvider");

    try expectMethodNotFound(alloc, &srv, "textDocument/rename", 30);
    try expectMethodNotFound(alloc, &srv, "textDocument/prepareRename", 31);
}

// ---------------------------------------------------------------------------
// GAP-0822 — codeAction: explicit non-support
// ---------------------------------------------------------------------------

test "GAP-0822: codeAction request -> -32601, codeActionProvider absent" {
    const alloc = testing.allocator;
    defer @import("geode").execution.tearDownGlobalCatalogForTest();
    var srv = try newCapturingServer(alloc);
    defer srv.deinit();

    try assertCapabilityAbsent(alloc, "codeActionProvider");

    try expectMethodNotFound(alloc, &srv, "textDocument/codeAction", 40);
}
