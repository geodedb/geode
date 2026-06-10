// GAP-0827 — LSP 3.17 / JSON-RPC 2.0 protocol conformance pack.
//
// The LSP server had feature-level tests but no PROTOCOL CONFORMANCE pack:
// nothing pinned the JSON-RPC 2.0 error-object shape, the LSP 3.17 lifecycle
// ordering (initialize / shutdown / exit gates), or the malformed-request
// rules from the JSON-RPC spec's own worked examples. This pack closes that
// gap and, in doing so, surfaced and FIXED four real defects in
// src/cli/lsp/server.zig (see the per-test notes below).
//
// Every assertion drives the REAL `Server.handleMessage` over a CAPTURING
// Noop transport (the GAP-0816 harness) and inspects the EXACT JSON-RPC frame
// the production server emitted — no mocks, no simulated responses.
//
// Defects found + fixed as part of this gap (all in server.zig):
//   (D1) No pre-initialize lifecycle gate — a feature request before
//        `initialize` was answered by the auth gate's -32002 only by accident
//        of credential state; there was no explicit lifecycle gate, and
//        `shutdown` (auth-exempt) would have dispatched pre-initialize. Added
//        an explicit lifecycle gate keyed on a new `initialize_received` flag.
//   (D2) No double-`initialize` rejection — a second `initialize` re-bound the
//        session. Now rejected with -32600 InvalidRequest.
//   (D3) No post-`shutdown` request rejection — requests after `shutdown` were
//        still dispatched. Now rejected with -32600 InvalidRequest; `exit`
//        after shutdown still flips the clean-exit flag.
//   (D4) Two deferred decode items: (a) a well-formed request whose `id` is a
//        structured type (object/array) was silently dispatched as a
//        notification; now answered -32600 with id null. (b) a -32600
//        bad-request with no recoverable id was dropped; now answered with
//        `"id": null` per the JSON-RPC 2.0 §5 worked example.
//
// CANARY: REQ=REQ-LSP-CONFORMANCE-001; FEATURE="Lsp317ConformancePack"; ASPECT=LifecycleAndJsonRpc; STATUS=TESTED; OWNER=lsp; UPDATED=2026-06-09

const std = @import("std");
const testing = std.testing;

const server = @import("lsp_server");
const transport = server.transport_mod;

// ---------------------------------------------------------------------------
// Helpers — capturing Noop server. The pre-initialize tests need a server that
// has NOT yet seen `initialize`, so we expose two constructors: a raw one
// (no initialize) and an initialized one (`--no-auth`, driven through
// initialize). Intentionally a small local copy of the GAP-0816 harness; only
// the constructors + JSON inspectors are reproduced (not the full helper set),
// staying under the reviewer's "don't make a fifth full copy" bar.
// ---------------------------------------------------------------------------

/// A `--no-auth` capturing server that has NOT been initialized yet. Used by
/// the pre-initialize lifecycle tests.
fn newRawServer(alloc: std.mem.Allocator) !server.Server {
    return server.Server.initWithTransport(
        alloc,
        transport.Transport.initNoopCapturing(alloc),
        null,
        true, // allow_unauth — initialize would synthesize a local-admin session
    );
}

/// A `--no-auth` capturing server driven through `initialize` so the lifecycle
/// + auth gates are open for feature requests.
fn newInitializedServer(alloc: std.mem.Allocator) !server.Server {
    var srv = try newRawServer(alloc);
    errdefer srv.deinit();
    try srv.handleMessage(
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"rootUri":null}}
    );
    return srv;
}

const Frame = struct {
    parsed: std.json.Parsed(std.json.Value),

    fn deinit(self: *Frame) void {
        self.parsed.deinit();
    }
    fn root(self: *const Frame) std.json.Value {
        return self.parsed.value;
    }
};

/// Parse the last written frame. Errors if no frame was written.
fn lastFrame(alloc: std.mem.Allocator, srv: *const server.Server) !Frame {
    const raw = srv.lastWrittenForTest() orelse return error.NoFrameWritten;
    return .{ .parsed = try std.json.parseFromSlice(std.json.Value, alloc, raw, .{}) };
}

/// Assert the last frame is a JSON-RPC error response with the exact `code`.
/// Also verifies the JSON-RPC error-object shape: integer `code` + string
/// `message`, and a present `id` member.
fn expectErrorCode(alloc: std.mem.Allocator, srv: *const server.Server, code: i64) !void {
    var f = try lastFrame(alloc, srv);
    defer f.deinit();
    const obj = f.root().object;
    try testing.expectEqualStrings("2.0", obj.get("jsonrpc").?.string);
    try testing.expect(obj.get("id") != null); // id member always present (may be null)
    const err = obj.get("error") orelse return error.NoErrorMember;
    try testing.expect(err == .object);
    const c = err.object.get("code") orelse return error.NoCode;
    try testing.expect(c == .integer); // code MUST be an integer
    try testing.expectEqual(code, c.integer);
    const msg = err.object.get("message") orelse return error.NoMessage;
    try testing.expect(msg == .string); // message MUST be a string
    try testing.expect(msg.string.len > 0);
}

/// True when the last frame is a successful response (has a `result` member).
fn lastFrameHasResult(alloc: std.mem.Allocator, srv: *const server.Server) !bool {
    var f = try lastFrame(alloc, srv);
    defer f.deinit();
    if (f.root() != .object) return false;
    return f.root().object.get("result") != null;
}

/// Read the integer `id` of the last frame. Errors if absent or non-integer.
fn lastFrameIntId(alloc: std.mem.Allocator, srv: *const server.Server) !i64 {
    var f = try lastFrame(alloc, srv);
    defer f.deinit();
    const id = f.root().object.get("id") orelse return error.NoId;
    if (id != .integer) return error.IdNotInteger;
    return id.integer;
}

/// True when the last frame's `id` member is JSON null.
fn lastFrameIdIsNull(alloc: std.mem.Allocator, srv: *const server.Server) !bool {
    var f = try lastFrame(alloc, srv);
    defer f.deinit();
    const id = f.root().object.get("id") orelse return false;
    return id == .null;
}

// ===========================================================================
// Lifecycle ordering
// ===========================================================================

test "GAP-0827: request before initialize -> -32002 ServerNotInitialized (D1)" {
    const alloc = testing.allocator;
    // No catalog/store teardown needed: initialize is never processed, so the
    // session (and its global store/catalog) are never bound.
    var srv = try newRawServer(alloc);
    defer srv.deinit();

    // A feature request before initialize MUST be -32002 (server not
    // initialized) — the LIFECYCLE gate, distinct from the auth gate.
    try srv.handleMessage(
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///x.gql"}}}
    );
    try expectErrorCode(alloc, &srv, -32002);
    try testing.expectEqual(@as(i64, 2), try lastFrameIntId(alloc, &srv));

    // `shutdown` before initialize is ALSO a lifecycle error (-32002), even
    // though it is auth-exempt — pre-fix it would have dispatched.
    try srv.handleMessage(
        \\{"jsonrpc":"2.0","id":3,"method":"shutdown"}
    );
    try expectErrorCode(alloc, &srv, -32002);
    try testing.expectEqual(@as(i64, 3), try lastFrameIntId(alloc, &srv));
}

test "GAP-0827: notifications other than exit are dropped pre-initialize (D1)" {
    const alloc = testing.allocator;
    var srv = try newRawServer(alloc);
    defer srv.deinit();

    // A didOpen before initialize must be dropped (no response, no state
    // change). We can't observe "no response" directly other than: no error
    // frame was written, and the document was NOT opened.
    try srv.handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///pre.gql","languageId":"gql","version":1,"text":"RETURN 1"}}}
    );
    try testing.expect(srv.documents.get("file:///pre.gql") == null);
    // No frame should have been written by the dropped notification.
    try testing.expect(srv.lastWrittenForTest() == null);

    // `exit` before initialize IS honored (clean bail-out of a half-open
    // session): it flips the run-loop termination flag.
    try srv.handleMessage(
        \\{"jsonrpc":"2.0","method":"exit"}
    );
    try testing.expect(srv.shutdown_requested);
}

test "GAP-0827: double initialize -> -32600 InvalidRequest (D2)" {
    const alloc = testing.allocator;
    defer @import("geode").execution.tearDownGlobalCatalogForTest();
    defer @import("geode").graph_store.deinitGlobalStore();
    var srv = try newInitializedServer(alloc);
    defer srv.deinit();

    // The first initialize (in newInitializedServer) succeeded. A second one
    // is an InvalidRequest per LSP 3.17 (initialize sent exactly once).
    try srv.handleMessage(
        \\{"jsonrpc":"2.0","id":2,"method":"initialize","params":{"capabilities":{},"rootUri":null}}
    );
    try expectErrorCode(alloc, &srv, -32600);
    try testing.expectEqual(@as(i64, 2), try lastFrameIntId(alloc, &srv));
}

test "GAP-0827: shutdown -> null result; post-shutdown request -> -32600; exit -> clean (D3)" {
    const alloc = testing.allocator;
    defer @import("geode").execution.tearDownGlobalCatalogForTest();
    defer @import("geode").graph_store.deinitGlobalStore();
    var srv = try newInitializedServer(alloc);
    defer srv.deinit();

    // shutdown returns a result of null.
    try srv.handleMessage(
        \\{"jsonrpc":"2.0","id":2,"method":"shutdown"}
    );
    {
        var f = try lastFrame(alloc, &srv);
        defer f.deinit();
        const obj = f.root().object;
        try testing.expectEqual(@as(i64, 2), obj.get("id").?.integer);
        const result = obj.get("result") orelse return error.NoResult;
        try testing.expect(result == .null);
        try testing.expect(obj.get("error") == null);
    }
    // The run loop is NOT yet terminated by shutdown (only exit does that).
    try testing.expect(!srv.shutdown_requested);

    // A request after shutdown is rejected with -32600 InvalidRequest.
    try srv.handleMessage(
        \\{"jsonrpc":"2.0","id":3,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///x.gql"}}}
    );
    try expectErrorCode(alloc, &srv, -32600);
    try testing.expectEqual(@as(i64, 3), try lastFrameIntId(alloc, &srv));

    // A second shutdown after shutdown is also a post-shutdown request -> -32600.
    try srv.handleMessage(
        \\{"jsonrpc":"2.0","id":4,"method":"shutdown"}
    );
    try expectErrorCode(alloc, &srv, -32600);

    // exit after shutdown sets the clean-exit flag.
    try srv.handleMessage(
        \\{"jsonrpc":"2.0","method":"exit"}
    );
    try testing.expect(srv.shutdown_requested);
}

// ===========================================================================
// JSON-RPC method dispatch
// ===========================================================================

test "GAP-0827: unknown method -> -32601 MethodNotFound with echoed id" {
    const alloc = testing.allocator;
    defer @import("geode").execution.tearDownGlobalCatalogForTest();
    defer @import("geode").graph_store.deinitGlobalStore();
    var srv = try newInitializedServer(alloc);
    defer srv.deinit();

    try srv.handleMessage(
        \\{"jsonrpc":"2.0","id":42,"method":"textDocument/thisDoesNotExist","params":{}}
    );
    try expectErrorCode(alloc, &srv, -32601);
    try testing.expectEqual(@as(i64, 42), try lastFrameIntId(alloc, &srv));
}

test "GAP-0827: notification with unknown method -> no response" {
    const alloc = testing.allocator;
    defer @import("geode").execution.tearDownGlobalCatalogForTest();
    defer @import("geode").graph_store.deinitGlobalStore();
    var srv = try newInitializedServer(alloc);
    defer srv.deinit();

    // The last frame BEFORE the unknown notification is the initialize result.
    // After dispatching an unknown notification, the last frame must be
    // unchanged (no new frame written) — a notification never gets a reply.
    const before = srv.lastWrittenForTest();
    try testing.expect(before != null);
    const before_dup = try alloc.dupe(u8, before.?);
    defer alloc.free(before_dup);

    try srv.handleMessage(
        \\{"jsonrpc":"2.0","method":"$/thisNotificationIsUnknown","params":{"foo":1}}
    );
    const after = srv.lastWrittenForTest() orelse return error.FrameVanished;
    try testing.expectEqualStrings(before_dup, after);
}

// ===========================================================================
// JSON-RPC error-object shape (covered structurally by expectErrorCode, this
// test pins it explicitly against a representative error).
// ===========================================================================

test "GAP-0827: error responses carry integer code + non-empty string message" {
    const alloc = testing.allocator;
    defer @import("geode").execution.tearDownGlobalCatalogForTest();
    defer @import("geode").graph_store.deinitGlobalStore();
    var srv = try newInitializedServer(alloc);
    defer srv.deinit();

    try srv.handleMessage(
        \\{"jsonrpc":"2.0","id":77,"method":"no/such/method"}
    );
    // expectErrorCode asserts the full shape (jsonrpc 2.0, id present, error
    // object with integer code + string message).
    try expectErrorCode(alloc, &srv, -32601);
}

// ===========================================================================
// Deferred decode items (D4)
// ===========================================================================

test "GAP-0827: pure decodeEnvelope — structured id on a valid-method request -> bad_request null (D4a)" {
    const alloc = testing.allocator;
    // method is a VALID string but id is an object: per JSON-RPC §4 this is a
    // malformed request, NOT a notification. decodeEnvelope must return
    // bad_request with a null id (never echo the structured value).
    const payload =
        \\{"jsonrpc":"2.0","id":{"evil":true},"method":"textDocument/hover","params":{}}
    ;
    var parsed = try std.json.parseFromSlice(std.json.Value, alloc, payload, .{});
    defer parsed.deinit();
    const result = server.Server.decodeEnvelope(parsed.value);
    switch (result) {
        .bad_request => |id| try testing.expect(id == null),
        else => return error.TestUnexpectedResult,
    }

    // Array id, valid method — same outcome.
    const payload2 =
        \\{"jsonrpc":"2.0","id":[1,2],"method":"shutdown"}
    ;
    var parsed2 = try std.json.parseFromSlice(std.json.Value, alloc, payload2, .{});
    defer parsed2.deinit();
    switch (server.Server.decodeEnvelope(parsed2.value)) {
        .bad_request => |id| try testing.expect(id == null),
        else => return error.TestUnexpectedResult,
    }

    // Sanity: an ABSENT id with a valid method is still a notification
    // (envelope, id == null) — we must not have broken the notification path.
    const payload3 =
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
    ;
    var parsed3 = try std.json.parseFromSlice(std.json.Value, alloc, payload3, .{});
    defer parsed3.deinit();
    switch (server.Server.decodeEnvelope(parsed3.value)) {
        .envelope => |env| {
            try testing.expectEqualStrings("initialized", env.method);
            try testing.expect(env.id == null);
        },
        else => return error.TestUnexpectedResult,
    }

    // Sanity: an explicit `"id": null` with a valid method stays a valid
    // request id (null is a legal JSON-RPC id) — envelope, id == .null.
    const payload4 =
        \\{"jsonrpc":"2.0","id":null,"method":"shutdown"}
    ;
    var parsed4 = try std.json.parseFromSlice(std.json.Value, alloc, payload4, .{});
    defer parsed4.deinit();
    switch (server.Server.decodeEnvelope(parsed4.value)) {
        .envelope => |env| {
            try testing.expect(env.id != null);
            try testing.expect(env.id.? == .null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "GAP-0827: handleMessage — structured-id request answers -32600 with id null (D4a)" {
    const alloc = testing.allocator;
    defer @import("geode").execution.tearDownGlobalCatalogForTest();
    defer @import("geode").graph_store.deinitGlobalStore();
    var srv = try newInitializedServer(alloc);
    defer srv.deinit();

    // A well-formed request (valid method) whose id is an object must be
    // answered -32600 with id null — NOT silently dropped as a notification.
    try srv.handleMessage(
        \\{"jsonrpc":"2.0","id":{"evil":true},"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///x.gql"},"position":{"line":0,"character":0}}}
    );
    try expectErrorCode(alloc, &srv, -32600);
    try testing.expect(try lastFrameIdIsNull(alloc, &srv));
}

test "GAP-0827: handleMessage — bad request with no valid id answers id null (D4b)" {
    const alloc = testing.allocator;
    var srv = try newRawServer(alloc);
    defer srv.deinit();

    // A non-object root is an Invalid Request with no recoverable id. Per the
    // JSON-RPC 2.0 §5 worked example it MUST still be answered with id null.
    // Pre-fix this was silently dropped.
    try srv.handleMessage("[1,2,3]");
    try expectErrorCode(alloc, &srv, -32600);
    try testing.expect(try lastFrameIdIsNull(alloc, &srv));

    // A bare scalar root — same rule.
    try srv.handleMessage("42");
    try expectErrorCode(alloc, &srv, -32600);
    try testing.expect(try lastFrameIdIsNull(alloc, &srv));

    // A request with a non-string method and no id is also a bad_request with
    // id null.
    try srv.handleMessage(
        \\{"jsonrpc":"2.0","method":99}
    );
    try expectErrorCode(alloc, &srv, -32600);
    try testing.expect(try lastFrameIdIsNull(alloc, &srv));
}

test "GAP-0827: handleMessage — a response object (no method) is still dropped" {
    const alloc = testing.allocator;
    var srv = try newRawServer(alloc);
    defer srv.deinit();

    // A JSON-RPC RESPONSE (no `method`, has `result`) is something an LSP
    // server never consumes — it must be dropped, NOT answered with -32600.
    // No frame should be written.
    try srv.handleMessage(
        \\{"jsonrpc":"2.0","id":5,"result":{"ok":true}}
    );
    try testing.expect(srv.lastWrittenForTest() == null);
}

// ===========================================================================
// $/cancelRequest smoke (full coverage lives in test_gap0816_lsp_cancel.zig;
// one assertion here for the pack's completeness)
// ===========================================================================

test "GAP-0827: $/cancelRequest for an unknown in-flight id is a no-op" {
    const alloc = testing.allocator;
    defer @import("geode").execution.tearDownGlobalCatalogForTest();
    defer @import("geode").graph_store.deinitGlobalStore();
    var srv = try newInitializedServer(alloc);
    defer srv.deinit();

    const before = srv.lastWrittenForTest().?;
    const before_dup = try alloc.dupe(u8, before);
    defer alloc.free(before_dup);

    // Cancel an id that has no in-flight request. The notification produces no
    // response of its own (no new frame), and does not error.
    try srv.handleMessage(
        \\{"jsonrpc":"2.0","method":"$/cancelRequest","params":{"id":314159}}
    );
    const after = srv.lastWrittenForTest().?;
    try testing.expectEqualStrings(before_dup, after);
}

// ===========================================================================
// Document lifecycle tolerance
// ===========================================================================

test "GAP-0827: didOpen/didChange/didClose sequence tolerated; didChange on unopened doc tolerated" {
    const alloc = testing.allocator;
    defer @import("geode").execution.tearDownGlobalCatalogForTest();
    defer @import("geode").graph_store.deinitGlobalStore();
    var srv = try newInitializedServer(alloc);
    defer srv.deinit();

    // didChange for an unopened document must be tolerated (no crash/error).
    try srv.handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///ghost.gql","version":2},"contentChanges":[{"text":"RETURN 1"}]}}
    );

    // A normal open/change/close sequence.
    try srv.handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///seq.gql","languageId":"gql","version":1,"text":"RETURN 1"}}}
    );
    try testing.expect(srv.documents.get("file:///seq.gql") != null);

    try srv.handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///seq.gql","version":2},"contentChanges":[{"text":"RETURN 2"}]}}
    );
    const doc = srv.documents.get("file:///seq.gql") orelse return error.DocMissing;
    try testing.expectEqualStrings("RETURN 2", doc.text);

    try srv.handleMessage(
        \\{"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{"uri":"file:///seq.gql"}}}
    );
    try testing.expect(srv.documents.get("file:///seq.gql") == null);

    // After all that, a feature request still answers normally.
    try srv.handleMessage(
        \\{"jsonrpc":"2.0","id":50,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///seq.gql"}}}
    );
    try testing.expect(try lastFrameHasResult(alloc, &srv));
}
