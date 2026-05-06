// GAP-0056 — server textDocument/definition wiring tests.
//
// Asserts that Server.computeDefinition wires through to
// features.provideDefinition for variables defined and referenced in
// the same document, and returns null for keywords.
//
// CANARY: REQ=REQ-LSP-GOTODEF-001; FEATURE="GoToDefinitionWired"; ASPECT=VariableLookup; STATUS=TESTED; OWNER=lsp; UPDATED=2026-05-06

const std = @import("std");
const testing = std.testing;
const server = @import("server.zig");

test "GAP-0056: computeDefinition resolves aliased node defined-then-referenced" {
    const allocator = testing.allocator;
    var srv = try server.Server.init(allocator);
    defer srv.deinit();

    const uri = "file:///gap0056.gql";
    const text = "MATCH (n) RETURN n";
    try srv.documents.open(uri, text, 1);

    // Cursor at character 17 — the second `n` (in `RETURN n`).
    // Expected: definition resolves to character 7 (the `n` inside `(n)`).
    const location = try srv.computeDefinition(uri, 0, 17);
    try testing.expect(location != null);
    try testing.expectEqualStrings(uri, location.?.uri);
    try testing.expectEqual(@as(u32, 0), location.?.range.start.line);
    try testing.expectEqual(@as(u32, 7), location.?.range.start.character);
}

test "GAP-0056: computeDefinition returns null for keyword" {
    const allocator = testing.allocator;
    var srv = try server.Server.init(allocator);
    defer srv.deinit();

    const uri = "file:///gap0056.gql";
    try srv.documents.open(uri, "MATCH (n) RETURN n", 1);

    // Cursor at character 0 — `M` in `MATCH`. Keyword has no user-code definition.
    const location = try srv.computeDefinition(uri, 0, 0);
    try testing.expect(location == null);
}

test "GAP-0056: computeDefinition returns null for unknown document" {
    const allocator = testing.allocator;
    var srv = try server.Server.init(allocator);
    defer srv.deinit();

    const location = try srv.computeDefinition("file:///never_opened.gql", 0, 0);
    try testing.expect(location == null);
}

test "GAP-0056: computeDefinition with relationship alias" {
    const allocator = testing.allocator;
    var srv = try server.Server.init(allocator);
    defer srv.deinit();

    const uri = "file:///rel.gql";
    const text = "MATCH (a)-[r]->(b) RETURN r";
    try srv.documents.open(uri, text, 1);

    // Cursor at the second `r` (in `RETURN r`).
    const idx_of_return_r: u32 = @intCast(std.mem.indexOf(u8, text, "RETURN r").? + "RETURN ".len);
    const location = try srv.computeDefinition(uri, 0, idx_of_return_r);
    try testing.expect(location != null);
}
