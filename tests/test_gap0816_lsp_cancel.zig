// GAP-0816 — LSP `$/cancelRequest` handling.
//
// Before this gap the LSP server had no `$/cancelRequest` handler: the
// notification fell through `handleNotification`'s dispatch table and was
// silently ignored, so a client could never cancel a request. LSP 3.17
// §3.17.10 requires the server to answer a cancelled request with JSON-RPC
// error code -32800 (RequestCancelled).
//
// Geode's LSP server processes messages strictly synchronously, one at a
// time, so "cancel an in-flight request" can never race in-process. The
// spec-compliant realization is a cancellation REGISTRY: the
// `$/cancelRequest` notification records the target id, and `handleRequest`
// consults the registry at entry — a registered id is answered with -32800
// and the entry is consumed.
//
// This suite proves:
//   (a) `$/cancelRequest` for an id, followed by the request with that id,
//       yields a JSON-RPC error response with code -32800;
//   (b) cancelling an unknown / already-completed id is a silent no-op (no
//       response is emitted for the cancel notification, and a never-cancelled
//       request still answers normally);
//   (c) a normal request (no prior cancel) answers normally (no -32800);
//   (d) the bounded registry's pure behavior: record/consume/idempotency/FIFO
//       eviction, integer vs string id disambiguation, structured-id rejection.
//
// Tests (a)–(c) drive the real `handleMessage` path over a CAPTURING Noop
// transport (GAP-0816 added `Transport.initNoopCapturing` + the
// `lastWrittenForTest` accessor) so the assertions inspect the EXACT JSON-RPC
// frame the production server emitted — no mocks, no simulated responses.
//
// CANARY: REQ=REQ-LSP-CANCEL-001; FEATURE="CancelRequestRegistry"; ASPECT=EndToEnd; STATUS=TESTED; OWNER=lsp; UPDATED=2026-06-09

const std = @import("std");
const testing = std.testing;

const server = @import("lsp_server");
const transport = server.transport_mod;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

/// A `--no-auth` (allow_unauth = true) server over a capturing Noop transport,
/// driven through `initialize` so the auth gate is open for feature requests.
/// Caller deinits the returned Server AND must tear down the global catalog
/// (publishVerifiedState initializes it with the test allocator).
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

/// Parse the last written frame and return whether it carries a JSON-RPC
/// `error.code` equal to `code`. Returns false when no frame was written or
/// the frame has no error member.
fn lastFrameHasErrorCode(alloc: std.mem.Allocator, srv: *const server.Server, code: i64) !bool {
    const frame = srv.lastWrittenForTest() orelse return false;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, frame, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    const err = parsed.value.object.get("error") orelse return false;
    if (err != .object) return false;
    const c = err.object.get("code") orelse return false;
    if (c != .integer) return false;
    return c.integer == code;
}

/// True when the last written frame carries a `result` member (a normal
/// successful response), false otherwise.
fn lastFrameHasResult(alloc: std.mem.Allocator, srv: *const server.Server) !bool {
    const frame = srv.lastWrittenForTest() orelse return false;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, frame, .{});
    defer parsed.deinit();
    if (parsed.value != .object) return false;
    return parsed.value.object.get("result") != null;
}

// ---------------------------------------------------------------------------
// End-to-end behavior
// ---------------------------------------------------------------------------

test "GAP-0816: cancelled request id answers with JSON-RPC -32800" {
    const alloc = testing.allocator;
    defer @import("geode").execution.tearDownGlobalCatalogForTest();
    var srv = try newCapturingServer(alloc);
    defer srv.deinit();

    // Cancel request id 42 BEFORE it is delivered.
    try srv.handleMessage(
        \\{"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":42}}
    );

    // Now deliver the request with that id. It must be answered with -32800.
    try srv.handleMessage(
        \\{"jsonrpc":"2.0","id":42,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///x.gql"}}}
    );

    try testing.expect(try lastFrameHasErrorCode(alloc, &srv, -32800));
}

test "GAP-0816: cancellation is consumed — a second same-id request answers normally" {
    const alloc = testing.allocator;
    defer @import("geode").execution.tearDownGlobalCatalogForTest();
    var srv = try newCapturingServer(alloc);
    defer srv.deinit();

    try srv.handleMessage(
        \\{"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":7}}
    );
    // First delivery: cancelled (-32800).
    try srv.handleMessage(
        \\{"jsonrpc":"2.0","id":7,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///x.gql"}}}
    );
    try testing.expect(try lastFrameHasErrorCode(alloc, &srv, -32800));

    // Second delivery reusing id 7: the entry was consumed, so it answers
    // normally (documentSymbol on an unknown doc returns an empty array result).
    try srv.handleMessage(
        \\{"jsonrpc":"2.0","id":7,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///x.gql"}}}
    );
    try testing.expect(!try lastFrameHasErrorCode(alloc, &srv, -32800));
    try testing.expect(try lastFrameHasResult(alloc, &srv));
}

test "GAP-0816: cancelling an unknown id is a silent no-op" {
    const alloc = testing.allocator;
    defer @import("geode").execution.tearDownGlobalCatalogForTest();
    var srv = try newCapturingServer(alloc);
    defer srv.deinit();

    // Cancel an id that is never delivered. The notification produces NO
    // response of its own (a notification never gets a reply), and the
    // server does not error.
    try srv.handleMessage(
        \\{"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":999}}
    );
    // The only frame ever written so far is the initialize result; the cancel
    // notification added nothing. Assert no error frame was produced.
    try testing.expect(!try lastFrameHasErrorCode(alloc, &srv, -32800));

    // A different, never-cancelled request answers normally.
    try srv.handleMessage(
        \\{"jsonrpc":"2.0","id":100,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///x.gql"}}}
    );
    try testing.expect(!try lastFrameHasErrorCode(alloc, &srv, -32800));
    try testing.expect(try lastFrameHasResult(alloc, &srv));
}

test "GAP-0816: malformed $/cancelRequest params are a silent no-op" {
    const alloc = testing.allocator;
    defer @import("geode").execution.tearDownGlobalCatalogForTest();
    var srv = try newCapturingServer(alloc);
    defer srv.deinit();

    // Missing id, non-object params, structured id — each must be ignored
    // without crashing and without affecting a later normal request.
    try srv.handleMessage(
        \\{"jsonrpc":"2.0","method":"$/cancelRequest","params":{}}
    );
    try srv.handleMessage(
        \\{"jsonrpc":"2.0","method":"$/cancelRequest","params":[]}
    );
    try srv.handleMessage(
        \\{"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":{"evil":true}}}
    );
    // The structured-id cancel must NOT have registered any id, so a request
    // with id 5 answers normally.
    try srv.handleMessage(
        \\{"jsonrpc":"2.0","id":5,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///x.gql"}}}
    );
    try testing.expect(!try lastFrameHasErrorCode(alloc, &srv, -32800));
    try testing.expect(try lastFrameHasResult(alloc, &srv));
}

test "GAP-0816: string-id cancellation answers with -32800" {
    const alloc = testing.allocator;
    defer @import("geode").execution.tearDownGlobalCatalogForTest();
    var srv = try newCapturingServer(alloc);
    defer srv.deinit();

    try srv.handleMessage(
        \\{"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":"req-abc"}}
    );
    try srv.handleMessage(
        \\{"jsonrpc":"2.0","id":"req-abc","method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///x.gql"}}}
    );
    try testing.expect(try lastFrameHasErrorCode(alloc, &srv, -32800));
}

// ---------------------------------------------------------------------------
// Pure registry unit tests (no transport)
// ---------------------------------------------------------------------------

test "GAP-0816: registry record/consume round-trip" {
    var reg = server.CancelRegistry{};
    const id: std.json.Value = .{ .integer = 1 };
    try testing.expect(!reg.consume(id)); // nothing registered yet
    reg.cancel(id);
    try testing.expect(reg.consume(id)); // first consume hits
    try testing.expect(!reg.consume(id)); // consumed — second misses
}

test "GAP-0816: integer id and string id do not alias" {
    var reg = server.CancelRegistry{};
    reg.cancel(.{ .integer = 1 });
    // The string id "1" must NOT be considered cancelled by the integer 1.
    try testing.expect(!reg.consume(.{ .string = "1" }));
    // The integer 1 is still registered.
    try testing.expect(reg.consume(.{ .integer = 1 }));
}

test "GAP-0816: cancel is idempotent (no double slot)" {
    var reg = server.CancelRegistry{};
    reg.cancel(.{ .integer = 9 });
    reg.cancel(.{ .integer = 9 });
    reg.cancel(.{ .integer = 9 });
    try testing.expect(reg.consume(.{ .integer = 9 }));
    // Only one slot was ever used, so a second consume misses.
    try testing.expect(!reg.consume(.{ .integer = 9 }));
}

test "GAP-0816: structured id is never recorded" {
    var reg = server.CancelRegistry{};
    // An array Value is not a valid JSON-RPC id (must be String|Number|Null);
    // normalizeId must reject it so it is never recorded or consumed.
    const arr = std.json.Value{ .array = std.json.Array.init(testing.allocator) };
    reg.cancel(arr);
    try testing.expect(!reg.consume(arr));
}

test "GAP-0816: FIFO eviction bounds the registry" {
    var reg = server.CancelRegistry{};
    const cap = server.CancelRegistry.capacity;
    // Fill the ring exactly, then add one more — the oldest (id 0) is evicted.
    var i: i64 = 0;
    while (i < cap + 1) : (i += 1) {
        reg.cancel(.{ .integer = i });
    }
    // id 0 was evicted; ids 1..cap survive.
    try testing.expect(!reg.consume(.{ .integer = 0 }));
    try testing.expect(reg.consume(.{ .integer = 1 }));
    try testing.expect(reg.consume(.{ .integer = cap }));
}
