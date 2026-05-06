// LSP-SEC-004 / Q-Sev1 — server invalid-params regression suite.
//
// Each test feeds a malformed JSON-RPC notification through
// `Server.handleMessage` and asserts the call returns
// `JsonError.InvalidParams`. Before the LSP-SEC-004 fix, these payloads
// triggered Zig panics from `.?` unwraps.
//
// Scope: notifications only. Request handlers also need to handle bad
// params, but exercising them via handleMessage would invoke sendError
// (which writes JSON-RPC frames to stdout) and is therefore covered by
// e2e tests rather than this unit suite. The same json_helpers
// accessors are used internally, so the bad-shape paths share an
// implementation with the notification handlers.
//
// CANARY: REQ=REQ-LSP-SEC-004; FEATURE="JsonHelpersWired"; ASPECT=SafeUnwrap; STATUS=TESTED; OWNER=lsp; UPDATED=2026-05-06

const std = @import("std");
const testing = std.testing;
const server = @import("server.zig");
const json_helpers = @import("json_helpers.zig");

fn newServer(allocator: std.mem.Allocator) !server.Server {
    return try server.Server.init(allocator);
}

test "LSP-SEC-004: didOpen missing textDocument returns InvalidParams" {
    const allocator = testing.allocator;
    var srv = try newServer(allocator);
    defer srv.deinit();
    const msg =
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{}}
    ;
    try testing.expectError(json_helpers.JsonError.InvalidParams, srv.handleMessage(msg));
}

test "LSP-SEC-004: didOpen missing uri returns InvalidParams" {
    const allocator = testing.allocator;
    var srv = try newServer(allocator);
    defer srv.deinit();
    const msg =
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"text":"x","version":1}}}
    ;
    try testing.expectError(json_helpers.JsonError.InvalidParams, srv.handleMessage(msg));
}

test "LSP-SEC-004: didOpen missing text returns InvalidParams" {
    const allocator = testing.allocator;
    var srv = try newServer(allocator);
    defer srv.deinit();
    const msg =
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///t.gql","version":1}}}
    ;
    try testing.expectError(json_helpers.JsonError.InvalidParams, srv.handleMessage(msg));
}

test "LSP-SEC-004: didOpen wrong-typed version returns InvalidParams" {
    const allocator = testing.allocator;
    var srv = try newServer(allocator);
    defer srv.deinit();
    const msg =
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":"file:///t.gql","text":"x","version":"not_an_int"}}}
    ;
    try testing.expectError(json_helpers.JsonError.InvalidParams, srv.handleMessage(msg));
}

test "LSP-SEC-004: didChange missing contentChanges returns InvalidParams" {
    const allocator = testing.allocator;
    var srv = try newServer(allocator);
    defer srv.deinit();
    const msg =
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///t.gql","version":2}}}
    ;
    try testing.expectError(json_helpers.JsonError.InvalidParams, srv.handleMessage(msg));
}

test "LSP-SEC-004: didChange contentChanges[0] missing text returns InvalidParams" {
    const allocator = testing.allocator;
    var srv = try newServer(allocator);
    defer srv.deinit();
    const msg =
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///t.gql","version":2},"contentChanges":[{}]}}
    ;
    try testing.expectError(json_helpers.JsonError.InvalidParams, srv.handleMessage(msg));
}

test "LSP-SEC-004: didChange wrong-typed version returns InvalidParams" {
    const allocator = testing.allocator;
    var srv = try newServer(allocator);
    defer srv.deinit();
    const msg =
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///t.gql","version":"oops"},"contentChanges":[{"text":"x"}]}}
    ;
    try testing.expectError(json_helpers.JsonError.InvalidParams, srv.handleMessage(msg));
}

test "LSP-SEC-004: didClose missing textDocument returns InvalidParams" {
    const allocator = testing.allocator;
    var srv = try newServer(allocator);
    defer srv.deinit();
    const msg =
        \\{"jsonrpc":"2.0","method":"textDocument/didClose","params":{}}
    ;
    try testing.expectError(json_helpers.JsonError.InvalidParams, srv.handleMessage(msg));
}

test "LSP-SEC-004: didClose missing uri returns InvalidParams" {
    const allocator = testing.allocator;
    var srv = try newServer(allocator);
    defer srv.deinit();
    const msg =
        \\{"jsonrpc":"2.0","method":"textDocument/didClose","params":{"textDocument":{}}}
    ;
    try testing.expectError(json_helpers.JsonError.InvalidParams, srv.handleMessage(msg));
}

test "LSP-SEC-004: didOpen wrong-typed uri returns InvalidParams" {
    const allocator = testing.allocator;
    var srv = try newServer(allocator);
    defer srv.deinit();
    const msg =
        \\{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{"textDocument":{"uri":42,"text":"x","version":1}}}
    ;
    try testing.expectError(json_helpers.JsonError.InvalidParams, srv.handleMessage(msg));
}

test "LSP-SEC-004: didChange contentChanges as object (not array) returns InvalidParams" {
    const allocator = testing.allocator;
    var srv = try newServer(allocator);
    defer srv.deinit();
    const msg =
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///t.gql","version":2},"contentChanges":{}}}
    ;
    try testing.expectError(json_helpers.JsonError.InvalidParams, srv.handleMessage(msg));
}
