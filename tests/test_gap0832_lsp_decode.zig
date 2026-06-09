// GAP-0832 — validated decode for the LSP JSON-RPC request envelope.
//
// Residual unsafe field access (SEC-004 follow-up) lived in two places in
// src/cli/lsp/server.zig:
//
//   1. `handleMessage`: `parsed.value.object` panicked when the JSON-RPC
//      root was not an object (e.g. a bare array / string / number / null),
//      and `m.string` panicked when a `method` member was present but not a
//      string (e.g. `"method": 42`).
//   2. `handleFormatting`: `text_doc.object.get("uri").string` unwrapped the
//      textDocument / uri chain with no type checks — a non-object
//      textDocument or a non-string uri panicked.
//
// This suite proves the cluster is fixed:
//   - the pure `decodeEnvelope` validator returns the right DecodeResult
//     variant (and a JSON-RPC -32600-eligible bad_request) for every
//     malformed shape, instead of crashing;
//   - the end-to-end `handleMessage` path tolerates each malformed payload
//     (no panic, clean return) over a Noop transport;
//   - the authenticated `textDocument/formatting` request answers cleanly
//     (no panic) on a malformed params shape.
//
// Before the fix these payloads triggered Zig panics from `.object` /
// `.string` field access on the wrong active union tag.
//
// CANARY: REQ=REQ-LSP-SEC-004; FEATURE="EnvelopeValidatedDecode"; ASPECT=SafeUnwrap; STATUS=TESTED; OWNER=lsp; UPDATED=2026-06-09

const std = @import("std");
const testing = std.testing;

const server = @import("lsp_server");
const transport = server.transport_mod;

// ---------------------------------------------------------------------------
// Pure validator: decodeEnvelope
// ---------------------------------------------------------------------------

fn parse(allocator: std.mem.Allocator, text: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, text, .{});
}

test "GAP-0832: non-object root decodes to bad_request (no panic)" {
    const alloc = testing.allocator;

    inline for (.{
        "[]",
        "42",
        "\"hello\"",
        "true",
        "null",
    }) |payload| {
        var parsed = try parse(alloc, payload);
        defer parsed.deinit();
        const result = server.Server.decodeEnvelope(parsed.value);
        switch (result) {
            .bad_request => |id| try testing.expect(id == null),
            else => return error.TestUnexpectedResult,
        }
    }
}

test "GAP-0832: non-string method decodes to bad_request, preserving a valid id" {
    const alloc = testing.allocator;
    const payload =
        \\{"jsonrpc":"2.0","id":7,"method":42,"params":{}}
    ;
    var parsed = try parse(alloc, payload);
    defer parsed.deinit();
    const result = server.Server.decodeEnvelope(parsed.value);
    switch (result) {
        .bad_request => |id| {
            try testing.expect(id != null);
            try testing.expect(id.? == .integer);
            try testing.expectEqual(@as(i64, 7), id.?.integer);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "GAP-0832: missing method decodes to drop (server ignores responses)" {
    const alloc = testing.allocator;
    const payload =
        \\{"jsonrpc":"2.0","id":1,"result":{"ok":true}}
    ;
    var parsed = try parse(alloc, payload);
    defer parsed.deinit();
    const result = server.Server.decodeEnvelope(parsed.value);
    try testing.expect(result == .drop);
}

test "GAP-0832: well-formed request decodes to envelope with id" {
    const alloc = testing.allocator;
    const payload =
        \\{"jsonrpc":"2.0","id":5,"method":"shutdown","params":{}}
    ;
    var parsed = try parse(alloc, payload);
    defer parsed.deinit();
    const result = server.Server.decodeEnvelope(parsed.value);
    switch (result) {
        .envelope => |env| {
            try testing.expectEqualStrings("shutdown", env.method);
            try testing.expect(env.id != null);
            try testing.expectEqual(@as(i64, 5), env.id.?.integer);
            try testing.expect(env.params != null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "GAP-0832: well-formed notification decodes to envelope without id" {
    const alloc = testing.allocator;
    const payload =
        \\{"jsonrpc":"2.0","method":"initialized","params":{}}
    ;
    var parsed = try parse(alloc, payload);
    defer parsed.deinit();
    const result = server.Server.decodeEnvelope(parsed.value);
    switch (result) {
        .envelope => |env| {
            try testing.expectEqualStrings("initialized", env.method);
            try testing.expect(env.id == null);
        },
        else => return error.TestUnexpectedResult,
    }
}

test "GAP-0832: structured (object/array/bool) id is normalized to null" {
    const alloc = testing.allocator;
    // An object id is not a valid JSON-RPC id (must be String|Number|Null);
    // it MUST NOT be echoed back as a response id.
    const payload =
        \\{"jsonrpc":"2.0","id":{"evil":true},"method":42}
    ;
    var parsed = try parse(alloc, payload);
    defer parsed.deinit();
    const result = server.Server.decodeEnvelope(parsed.value);
    switch (result) {
        .bad_request => |id| try testing.expect(id == null),
        else => return error.TestUnexpectedResult,
    }
}

test "GAP-0832: string id survives decode (correlatable error response)" {
    const alloc = testing.allocator;
    const payload =
        \\{"jsonrpc":"2.0","id":"req-1","method":42}
    ;
    var parsed = try parse(alloc, payload);
    defer parsed.deinit();
    const result = server.Server.decodeEnvelope(parsed.value);
    switch (result) {
        .bad_request => |id| {
            try testing.expect(id != null);
            try testing.expect(id.? == .string);
            try testing.expectEqualStrings("req-1", id.?.string);
        },
        else => return error.TestUnexpectedResult,
    }
}

// ---------------------------------------------------------------------------
// End-to-end: handleMessage tolerates the malformed envelope cluster
// ---------------------------------------------------------------------------

fn newNoopServer(alloc: std.mem.Allocator) !server.Server {
    return server.Server.initWithTransport(alloc, transport.Transport.initNoop(alloc), null, false);
}

test "GAP-0832: handleMessage does not panic on a non-object root" {
    const alloc = testing.allocator;
    var srv = try newNoopServer(alloc);
    defer srv.deinit();
    // Bare array root. Pre-fix: `parsed.value.object` panicked.
    try srv.handleMessage("[1,2,3]");
}

test "GAP-0832: handleMessage does not panic on a non-string method" {
    const alloc = testing.allocator;
    var srv = try newNoopServer(alloc);
    defer srv.deinit();
    // Pre-fix: `m.string` panicked. A request id is present so the server
    // emits a JSON-RPC -32600 error response (dropped by Noop transport).
    const msg =
        \\{"jsonrpc":"2.0","id":9,"method":99,"params":{}}
    ;
    try srv.handleMessage(msg);
}

test "GAP-0832: handleMessage drops a response object (no method) without error" {
    const alloc = testing.allocator;
    var srv = try newNoopServer(alloc);
    defer srv.deinit();
    const msg =
        \\{"jsonrpc":"2.0","id":3,"result":{"ok":true}}
    ;
    try srv.handleMessage(msg);
}

test "GAP-0832: handleMessage does not panic on a bare scalar root" {
    const alloc = testing.allocator;
    var srv = try newNoopServer(alloc);
    defer srv.deinit();
    try srv.handleMessage("\"just a string\"");
    try srv.handleMessage("12345");
    try srv.handleMessage("null");
}

// ---------------------------------------------------------------------------
// End-to-end: authenticated formatting request tolerates malformed params
// ---------------------------------------------------------------------------

test "GAP-0832: authenticated formatting with malformed params does not panic" {
    const alloc = testing.allocator;

    // publishVerifiedState reaches ensureCatalogInstance which initializes
    // the process-global catalog with this test's allocator; tear it down
    // within the test (deferred to fire AFTER srv.deinit) so the leak
    // detector stays clean. Mirrors server_auth_test.zig.
    defer @import("geode").execution.tearDownGlobalCatalogForTest();

    var srv = try server.Server.initWithTransport(alloc, transport.Transport.initNoop(alloc), null, true);
    defer srv.deinit();

    // Bind a local-admin session so the auth gate opens for the formatting
    // request below.
    const init_msg =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{},"rootUri":null}}
    ;
    try srv.handleMessage(init_msg);
    try testing.expect(srv.isMethodAllowed("textDocument/formatting"));

    // 1) textDocument present but not an object. Pre-fix:
    //    `text_doc.object.get(...)` panicked.
    try srv.handleMessage(
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/formatting","params":{"textDocument":42}}
    );

    // 2) textDocument is an object but uri is not a string. Pre-fix:
    //    `uri.string` panicked.
    try srv.handleMessage(
        \\{"jsonrpc":"2.0","id":3,"method":"textDocument/formatting","params":{"textDocument":{"uri":99}}}
    );

    // 3) params is not an object at all. Pre-fix: `p.object.get(...)`
    //    panicked.
    try srv.handleMessage(
        \\{"jsonrpc":"2.0","id":4,"method":"textDocument/formatting","params":[]}
    );

    // 4) well-formed shape for a document that does not exist returns a
    //    null result, not a crash.
    try srv.handleMessage(
        \\{"jsonrpc":"2.0","id":5,"method":"textDocument/formatting","params":{"textDocument":{"uri":"file:///nope.gql"}}}
    );
}
