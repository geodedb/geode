// CANARY: LSP_SERVER_TESTS
// Integration tests for LSP server components

const std = @import("std");
const testing = std.testing;
const protocol = @import("protocol.zig");
const server = @import("server.zig");

test "ServerCapabilities - default values" {
    const caps = server.ServerCapabilities{};

    try testing.expectEqual(@as(i32, 1), caps.textDocumentSync);
    try testing.expect(caps.hoverProvider);
    try testing.expect(caps.definitionProvider);
    try testing.expect(caps.documentFormattingProvider);
    try testing.expect(caps.completionProvider != null);
}

test "ServerCapabilities - completion trigger characters" {
    const caps = server.ServerCapabilities{};

    try testing.expect(caps.completionProvider != null);
    const triggers = caps.completionProvider.?.triggerCharacters;
    try testing.expectEqual(@as(usize, 3), triggers.len);
    try testing.expectEqualStrings(".", triggers[0]);
    try testing.expectEqualStrings(":", triggers[1]);
    try testing.expectEqualStrings("$", triggers[2]);
}

test "Server - initialization" {
    const allocator = testing.allocator;

    var srv = server.Server.init(allocator);
    defer srv.deinit();

    try testing.expect(!srv.initialized);
    try testing.expect(!srv.shutdown_requested);
}

test "Server - document lifecycle" {
    const allocator = testing.allocator;

    var srv = server.Server.init(allocator);
    defer srv.deinit();

    // Open a document
    try srv.documents.open("file:///test.gql", "MATCH (n) RETURN n", 1);

    // Document should be in store
    const doc = srv.documents.get("file:///test.gql");
    try testing.expect(doc != null);
    try testing.expectEqualStrings("MATCH (n) RETURN n", doc.?.text);

    // Update the document
    try srv.documents.update("file:///test.gql", "MATCH (n) WHERE n.age > 25 RETURN n", 2);

    // Document should be updated
    const updated_doc = srv.documents.get("file:///test.gql");
    try testing.expect(updated_doc != null);
    try testing.expectEqualStrings("MATCH (n) WHERE n.age > 25 RETURN n", updated_doc.?.text);
    try testing.expectEqual(@as(i32, 2), updated_doc.?.version);

    // Close the document
    srv.documents.close("file:///test.gql");

    // Document should be removed
    const closed_doc = srv.documents.get("file:///test.gql");
    try testing.expect(closed_doc == null);
}

test "Server - multiple documents" {
    const allocator = testing.allocator;

    var srv = server.Server.init(allocator);
    defer srv.deinit();

    // Open multiple documents
    try srv.documents.open("file:///test1.gql", "query 1", 1);
    try srv.documents.open("file:///test2.gql", "query 2", 1);
    try srv.documents.open("file:///test3.gql", "query 3", 1);

    // All should be accessible
    try testing.expect(srv.documents.get("file:///test1.gql") != null);
    try testing.expect(srv.documents.get("file:///test2.gql") != null);
    try testing.expect(srv.documents.get("file:///test3.gql") != null);

    // Close one
    srv.documents.close("file:///test2.gql");

    // Others should still be accessible
    try testing.expect(srv.documents.get("file:///test1.gql") != null);
    try testing.expect(srv.documents.get("file:///test2.gql") == null);
    try testing.expect(srv.documents.get("file:///test3.gql") != null);
}

test "Server - state transitions" {
    const allocator = testing.allocator;

    var srv = server.Server.init(allocator);
    defer srv.deinit();

    // Initially not initialized
    try testing.expect(!srv.initialized);
    try testing.expect(!srv.shutdown_requested);

    // Simulate initialization
    srv.initialized = true;
    try testing.expect(srv.initialized);

    // Simulate shutdown request
    srv.shutdown_requested = true;
    try testing.expect(srv.shutdown_requested);
}
