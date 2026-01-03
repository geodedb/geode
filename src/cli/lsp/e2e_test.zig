// CANARY: LSP_E2E_TESTS
// End-to-end workflow tests for LSP server

const std = @import("std");
const testing = std.testing;
const protocol = @import("protocol.zig");
const document = @import("document.zig");
const features = @import("features.zig");
const server = @import("server.zig");

test "E2E - complete document lifecycle with diagnostics" {
    const allocator = testing.allocator;

    var srv = server.Server.init(allocator);
    defer srv.deinit();

    // 1. Open a document with valid GQL
    try srv.documents.open("file:///test.gql", "MATCH (n:Person) RETURN n", 1);

    const doc1 = srv.documents.get("file:///test.gql");
    try testing.expect(doc1 != null);

    // Get diagnostics - should be empty for valid query
    const diag1 = try features.provideDiagnostics(allocator, doc1.?);
    defer {
        for (diag1) |d| allocator.free(d.message);
        allocator.free(diag1);
    }
    try testing.expectEqual(@as(usize, 0), diag1.len);

    // 2. Update document with invalid GQL
    try srv.documents.update("file:///test.gql", "INVALID SYNTAX", 2);

    const doc2 = srv.documents.get("file:///test.gql");
    try testing.expect(doc2 != null);

    // Get diagnostics - should have errors
    const diag2 = try features.provideDiagnostics(allocator, doc2.?);
    defer {
        for (diag2) |d| allocator.free(d.message);
        allocator.free(diag2);
    }
    try testing.expect(diag2.len > 0);

    // 3. Fix the document
    try srv.documents.update("file:///test.gql", "MATCH (n) RETURN n", 3);

    const doc3 = srv.documents.get("file:///test.gql");
    try testing.expect(doc3 != null);

    // Diagnostics should be clear again
    const diag3 = try features.provideDiagnostics(allocator, doc3.?);
    defer {
        for (diag3) |d| allocator.free(d.message);
        allocator.free(diag3);
    }
    try testing.expectEqual(@as(usize, 0), diag3.len);

    // 4. Close the document
    srv.documents.close("file:///test.gql");
    try testing.expect(srv.documents.get("file:///test.gql") == null);
}

test "E2E - hover on different elements" {
    const allocator = testing.allocator;

    var srv = server.Server.init(allocator);
    defer srv.deinit();

    const text = "MATCH (p:Person) WHERE p.age > 25 RETURN count(p)";
    try srv.documents.open("file:///test.gql", text, 1);

    const doc = srv.documents.get("file:///test.gql");
    try testing.expect(doc != null);

    // Hover over MATCH
    const hover1 = try features.provideHover(allocator, doc.?, 0, 2);
    defer if (hover1) |h| allocator.free(h.contents.value);
    try testing.expect(hover1 != null);
    try testing.expect(std.mem.indexOf(u8, hover1.?.contents.value, "MATCH") != null);

    // Hover over WHERE
    const hover2 = try features.provideHover(allocator, doc.?, 0, 19);
    defer if (hover2) |h| allocator.free(h.contents.value);
    try testing.expect(hover2 != null);
    try testing.expect(std.mem.indexOf(u8, hover2.?.contents.value, "WHERE") != null);

    // Hover over count
    const hover3 = try features.provideHover(allocator, doc.?, 0, 41);
    defer if (hover3) |h| allocator.free(h.contents.value);
    try testing.expect(hover3 != null);
    try testing.expect(std.mem.indexOf(u8, hover3.?.contents.value, "count") != null);

    srv.documents.close("file:///test.gql");
}

test "E2E - completion workflow" {
    const allocator = testing.allocator;

    var srv = server.Server.init(allocator);
    defer srv.deinit();

    // User typing a query
    try srv.documents.open("file:///test.gql", "M", 1);

    const doc = srv.documents.get("file:///test.gql");
    try testing.expect(doc != null);

    // Get completions
    const items = try features.provideCompletion(allocator, doc.?, 0, 1);
    defer {
        for (items) |item| {
            if (item.insertText) |text| {
                if (!std.mem.eql(u8, text, item.label)) {
                    allocator.free(text);
                }
            }
            // Free detail if allocated (not for types which use comptime strings)
            if (item.detail) |detail| {
                if (item.kind != .Class) {
                    allocator.free(detail);
                }
            }
        }
        allocator.free(items);
    }

    // Should include MATCH and MERGE
    var found_match = false;
    var found_merge = false;
    for (items) |item| {
        if (std.mem.eql(u8, item.label, "MATCH")) found_match = true;
        if (std.mem.eql(u8, item.label, "MERGE")) found_merge = true;
    }
    try testing.expect(found_match);
    try testing.expect(found_merge);

    srv.documents.close("file:///test.gql");
}

test "E2E - multi-line document navigation" {
    const allocator = testing.allocator;

    var srv = server.Server.init(allocator);
    defer srv.deinit();

    const text =
        \\MATCH (p:Person)
        \\WHERE p.age > 25
        \\RETURN p.name
    ;

    try srv.documents.open("file:///test.gql", text, 1);

    const doc = srv.documents.get("file:///test.gql");
    try testing.expect(doc != null);

    // Hover on line 0 (MATCH)
    const hover1 = try features.provideHover(allocator, doc.?, 0, 2);
    defer if (hover1) |h| allocator.free(h.contents.value);
    try testing.expect(hover1 != null);
    try testing.expect(std.mem.indexOf(u8, hover1.?.contents.value, "MATCH") != null);

    // Hover on line 1 (WHERE)
    const hover2 = try features.provideHover(allocator, doc.?, 1, 2);
    defer if (hover2) |h| allocator.free(h.contents.value);
    try testing.expect(hover2 != null);
    try testing.expect(std.mem.indexOf(u8, hover2.?.contents.value, "WHERE") != null);

    // Hover on line 2 (RETURN)
    const hover3 = try features.provideHover(allocator, doc.?, 2, 2);
    defer if (hover3) |h| allocator.free(h.contents.value);
    try testing.expect(hover3 != null);
    try testing.expect(std.mem.indexOf(u8, hover3.?.contents.value, "RETURN") != null);

    srv.documents.close("file:///test.gql");
}

test "E2E - vector search query workflow" {
    const allocator = testing.allocator;

    var srv = server.Server.init(allocator);
    defer srv.deinit();

    const text = "RETURN distance([1.0, 2.0], [3.0, 4.0], 'L2')";
    try srv.documents.open("file:///vector.gql", text, 1);

    const doc = srv.documents.get("file:///vector.gql");
    try testing.expect(doc != null);

    // Get diagnostics - should be valid
    const diag = try features.provideDiagnostics(allocator, doc.?);
    defer {
        for (diag) |d| allocator.free(d.message);
        allocator.free(diag);
    }
    try testing.expectEqual(@as(usize, 0), diag.len);

    // Hover over distance function
    const hover = try features.provideHover(allocator, doc.?, 0, 10);
    defer if (hover) |h| allocator.free(h.contents.value);
    try testing.expect(hover != null);
    try testing.expect(std.mem.indexOf(u8, hover.?.contents.value, "distance") != null);

    srv.documents.close("file:///vector.gql");
}

test "E2E - complex query with multiple features" {
    const allocator = testing.allocator;

    var srv = server.Server.init(allocator);
    defer srv.deinit();

    const text =
        \\MATCH (p:Person)-[:KNOWS]->(f:Person)
        \\WHERE p.age > 25 AND f.age < 50
        \\RETURN p.name, f.name, count(*) AS connections
        \\ORDER BY connections DESC
        \\LIMIT 10
    ;

    try srv.documents.open("file:///complex.gql", text, 1);

    const doc = srv.documents.get("file:///complex.gql");
    try testing.expect(doc != null);

    // Diagnostics should be clean for valid query
    const diag = try features.provideDiagnostics(allocator, doc.?);
    defer {
        for (diag) |d| allocator.free(d.message);
        allocator.free(diag);
    }
    try testing.expectEqual(@as(usize, 0), diag.len);

    // Test hover on different lines
    const hover_match = try features.provideHover(allocator, doc.?, 0, 2);
    defer if (hover_match) |h| allocator.free(h.contents.value);
    try testing.expect(hover_match != null);

    const hover_where = try features.provideHover(allocator, doc.?, 1, 2);
    defer if (hover_where) |h| allocator.free(h.contents.value);
    try testing.expect(hover_where != null);

    const hover_return = try features.provideHover(allocator, doc.?, 2, 2);
    defer if (hover_return) |h| allocator.free(h.contents.value);
    try testing.expect(hover_return != null);

    const hover_order = try features.provideHover(allocator, doc.?, 3, 2);
    defer if (hover_order) |h| allocator.free(h.contents.value);
    try testing.expect(hover_order != null);

    const hover_limit = try features.provideHover(allocator, doc.?, 4, 2);
    defer if (hover_limit) |h| allocator.free(h.contents.value);
    try testing.expect(hover_limit != null);

    srv.documents.close("file:///complex.gql");
}

test "E2E - rapid document updates" {
    const allocator = testing.allocator;

    var srv = server.Server.init(allocator);
    defer srv.deinit();

    try srv.documents.open("file:///rapid.gql", "M", 1);

    // Simulate rapid typing
    try srv.documents.update("file:///rapid.gql", "MA", 2);
    try srv.documents.update("file:///rapid.gql", "MAT", 3);
    try srv.documents.update("file:///rapid.gql", "MATC", 4);
    try srv.documents.update("file:///rapid.gql", "MATCH", 5);
    try srv.documents.update("file:///rapid.gql", "MATCH ", 6);
    try srv.documents.update("file:///rapid.gql", "MATCH (", 7);
    try srv.documents.update("file:///rapid.gql", "MATCH (n", 8);
    try srv.documents.update("file:///rapid.gql", "MATCH (n)", 9);

    const doc = srv.documents.get("file:///rapid.gql");
    try testing.expect(doc != null);
    try testing.expectEqualStrings("MATCH (n)", doc.?.text);
    try testing.expectEqual(@as(i32, 9), doc.?.version);

    srv.documents.close("file:///rapid.gql");
}

test "E2E - concurrent documents" {
    const allocator = testing.allocator;

    var srv = server.Server.init(allocator);
    defer srv.deinit();

    // Open multiple documents
    try srv.documents.open("file:///doc1.gql", "MATCH (a) RETURN a", 1);
    try srv.documents.open("file:///doc2.gql", "MATCH (b) RETURN b", 1);
    try srv.documents.open("file:///doc3.gql", "MATCH (c) RETURN c", 1);

    // Work with doc2
    const doc2 = srv.documents.get("file:///doc2.gql");
    try testing.expect(doc2 != null);

    const hover = try features.provideHover(allocator, doc2.?, 0, 2);
    defer if (hover) |h| allocator.free(h.contents.value);
    try testing.expect(hover != null);

    // Update doc1 while doc2 is being used
    try srv.documents.update("file:///doc1.gql", "MATCH (a) WHERE a.id = 1 RETURN a", 2);

    // doc2 should be unchanged
    const doc2_after = srv.documents.get("file:///doc2.gql");
    try testing.expect(doc2_after != null);
    try testing.expectEqualStrings("MATCH (b) RETURN b", doc2_after.?.text);

    // Close all
    srv.documents.close("file:///doc1.gql");
    srv.documents.close("file:///doc2.gql");
    srv.documents.close("file:///doc3.gql");
}

test "E2E - error recovery" {
    const allocator = testing.allocator;

    var srv = server.Server.init(allocator);
    defer srv.deinit();

    // Start with invalid query
    try srv.documents.open("file:///error.gql", "INVALID SYNTAX !!!", 1);

    const doc1 = srv.documents.get("file:///error.gql");
    try testing.expect(doc1 != null);

    // Should have errors
    const diag1 = try features.provideDiagnostics(allocator, doc1.?);
    defer {
        for (diag1) |d| allocator.free(d.message);
        allocator.free(diag1);
    }
    try testing.expect(diag1.len > 0);

    // Fix incrementally
    try srv.documents.update("file:///error.gql", "MATCH", 2);
    try srv.documents.update("file:///error.gql", "MATCH (", 3);
    try srv.documents.update("file:///error.gql", "MATCH (n", 4);
    try srv.documents.update("file:///error.gql", "MATCH (n)", 5);
    try srv.documents.update("file:///error.gql", "MATCH (n) RETURN n", 6);

    const doc2 = srv.documents.get("file:///error.gql");
    try testing.expect(doc2 != null);

    // Should be valid now
    const diag2 = try features.provideDiagnostics(allocator, doc2.?);
    defer {
        for (diag2) |d| allocator.free(d.message);
        allocator.free(diag2);
    }
    try testing.expectEqual(@as(usize, 0), diag2.len);

    srv.documents.close("file:///error.gql");
}
