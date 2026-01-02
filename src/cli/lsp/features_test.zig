// CANARY: LSP_FEATURES_TESTS
// Test suite for LSP language features

const std = @import("std");
const testing = std.testing;
const protocol = @import("protocol.zig");
const document = @import("document.zig");
const features = @import("features.zig");

test "provideDiagnostics - valid GQL query" {
    const allocator = testing.allocator;
    const text = "MATCH (n:Person) RETURN n";

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    const diagnostics = try features.provideDiagnostics(allocator, doc);
    defer {
        for (diagnostics) |diag| {
            allocator.free(diag.message);
        }
        allocator.free(diagnostics);
    }

    // Valid query should have no diagnostics
    try testing.expectEqual(@as(usize, 0), diagnostics.len);
}

test "provideDiagnostics - invalid GQL query" {
    const allocator = testing.allocator;
    const text = "MATCH INVALID SYNTAX";

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    const diagnostics = try features.provideDiagnostics(allocator, doc);
    defer {
        for (diagnostics) |diag| {
            allocator.free(diag.message);
        }
        allocator.free(diagnostics);
    }

    // Invalid query should have diagnostics
    try testing.expect(diagnostics.len > 0);
    try testing.expect(diagnostics[0].severity != null);
    try testing.expectEqual(protocol.DiagnosticSeverity.Error, diagnostics[0].severity.?);
}

test "provideDiagnostics - empty document" {
    const allocator = testing.allocator;
    const text = "";

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    const diagnostics = try features.provideDiagnostics(allocator, doc);
    defer {
        for (diagnostics) |diag| {
            allocator.free(diag.message);
        }
        allocator.free(diagnostics);
    }

    // Empty document might have diagnostics or not, just ensure it doesn't crash
    _ = diagnostics.len;
}

test "provideDiagnostics - multiple errors" {
    const allocator = testing.allocator;
    const text = "INVALID QUERY WITH MANY ERRORS !!!";

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    const diagnostics = try features.provideDiagnostics(allocator, doc);
    defer {
        for (diagnostics) |diag| {
            allocator.free(diag.message);
        }
        allocator.free(diagnostics);
    }

    // Should have at least one error
    try testing.expect(diagnostics.len > 0);
}

test "provideHover - MATCH keyword" {
    const allocator = testing.allocator;
    const text = "MATCH (n:Person) RETURN n";

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    // Hover over MATCH (line 0, char 2)
    const hover = try features.provideHover(allocator, doc, 0, 2);
    defer if (hover) |h| allocator.free(h.contents.value);

    try testing.expect(hover != null);
    try testing.expectEqual(protocol.MarkupKind.markdown, hover.?.contents.kind);
    try testing.expect(std.mem.indexOf(u8, hover.?.contents.value, "MATCH") != null);
}

test "provideHover - RETURN keyword" {
    const allocator = testing.allocator;
    const text = "MATCH (n) RETURN n";

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    // Hover over RETURN (line 0, char 12)
    const hover = try features.provideHover(allocator, doc, 0, 12);
    defer if (hover) |h| allocator.free(h.contents.value);

    try testing.expect(hover != null);
    try testing.expect(std.mem.indexOf(u8, hover.?.contents.value, "RETURN") != null);
}

test "provideHover - WHERE keyword" {
    const allocator = testing.allocator;
    const text = "MATCH (n) WHERE n.age > 25 RETURN n";

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    // Hover over WHERE (line 0, char 12)
    const hover = try features.provideHover(allocator, doc, 0, 12);
    defer if (hover) |h| allocator.free(h.contents.value);

    try testing.expect(hover != null);
    try testing.expect(std.mem.indexOf(u8, hover.?.contents.value, "WHERE") != null);
}

test "provideHover - count function" {
    const allocator = testing.allocator;
    const text = "RETURN count(n)";

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    // Hover over count (line 0, char 8)
    const hover = try features.provideHover(allocator, doc, 0, 8);
    defer if (hover) |h| allocator.free(h.contents.value);

    try testing.expect(hover != null);
    try testing.expect(std.mem.indexOf(u8, hover.?.contents.value, "count") != null);
}

test "provideHover - distance function" {
    const allocator = testing.allocator;
    const text = "RETURN distance(v1, v2, 'L2')";

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    // Hover over distance (line 0, char 10)
    const hover = try features.provideHover(allocator, doc, 0, 10);
    defer if (hover) |h| allocator.free(h.contents.value);

    try testing.expect(hover != null);
    try testing.expect(std.mem.indexOf(u8, hover.?.contents.value, "distance") != null);
    try testing.expect(std.mem.indexOf(u8, hover.?.contents.value, "FLOAT") != null);
}

test "provideHover - INTEGER type" {
    const allocator = testing.allocator;
    const text = "CREATE (n:Person {age: INTEGER})";

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    // Hover over INTEGER (line 0, char 26)
    const hover = try features.provideHover(allocator, doc, 0, 26);
    defer if (hover) |h| allocator.free(h.contents.value);

    try testing.expect(hover != null);
    try testing.expect(std.mem.indexOf(u8, hover.?.contents.value, "INTEGER") != null);
}

test "provideHover - VECTOR type" {
    const allocator = testing.allocator;
    const text = "CREATE (n {embedding: VECTOR})";

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    // Hover over VECTOR (line 0, char 25)
    const hover = try features.provideHover(allocator, doc, 0, 25);
    defer if (hover) |h| allocator.free(h.contents.value);

    try testing.expect(hover != null);
    try testing.expect(std.mem.indexOf(u8, hover.?.contents.value, "VECTOR") != null);
    try testing.expect(std.mem.indexOf(u8, hover.?.contents.value, "HNSW") != null or
        std.mem.indexOf(u8, hover.?.contents.value, "embedding") != null);
}

test "provideHover - on whitespace returns null" {
    const allocator = testing.allocator;
    const text = "MATCH   (n)";

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    // Hover over whitespace (line 0, char 6)
    const hover = try features.provideHover(allocator, doc, 0, 6);
    defer if (hover) |h| allocator.free(h.contents.value);

    try testing.expect(hover == null);
}

test "provideHover - on unknown word returns null" {
    const allocator = testing.allocator;
    const text = "MATCH (unknownword)";

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    // Hover over unknownword (line 0, char 10)
    const hover = try features.provideHover(allocator, doc, 0, 10);
    defer if (hover) |h| allocator.free(h.contents.value);

    try testing.expect(hover == null);
}

test "provideCompletion - returns keywords" {
    const allocator = testing.allocator;
    const text = "MAT";

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    const items = try features.provideCompletion(allocator, doc, 0, 3);
    defer {
        for (items) |item| {
            if (item.insertText) |insert_text| {
                if (!std.mem.eql(u8, insert_text, item.label)) {
                    allocator.free(insert_text);
                }
            }
        }
        allocator.free(items);
    }

    // Should include MATCH keyword
    var found_match = false;
    for (items) |item| {
        if (std.mem.eql(u8, item.label, "MATCH")) {
            found_match = true;
            try testing.expectEqual(protocol.CompletionItemKind.Keyword, item.kind.?);
            break;
        }
    }
    try testing.expect(found_match);
}

test "provideCompletion - returns functions" {
    const allocator = testing.allocator;
    const text = "RETURN cou";

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    const items = try features.provideCompletion(allocator, doc, 0, 10);
    defer {
        for (items) |item| {
            if (item.insertText) |insert_text| {
                if (!std.mem.eql(u8, insert_text, item.label)) {
                    allocator.free(insert_text);
                }
            }
        }
        allocator.free(items);
    }

    // Should include count function
    var found_count = false;
    for (items) |item| {
        if (std.mem.eql(u8, item.label, "count")) {
            found_count = true;
            try testing.expectEqual(protocol.CompletionItemKind.Function, item.kind.?);
            try testing.expect(std.mem.indexOf(u8, item.insertText.?, "count()") != null);
            break;
        }
    }
    try testing.expect(found_count);
}

test "provideCompletion - returns types" {
    const allocator = testing.allocator;
    const text = "CREATE (n {prop: INT";

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    const items = try features.provideCompletion(allocator, doc, 0, 20);
    defer {
        for (items) |item| {
            if (item.insertText) |insert_text| {
                if (!std.mem.eql(u8, insert_text, item.label)) {
                    allocator.free(insert_text);
                }
            }
        }
        allocator.free(items);
    }

    // Should include INTEGER type
    var found_integer = false;
    for (items) |item| {
        if (std.mem.eql(u8, item.label, "INTEGER")) {
            found_integer = true;
            try testing.expectEqual(protocol.CompletionItemKind.Class, item.kind.?);
            break;
        }
    }
    try testing.expect(found_integer);
}

test "provideCompletion - includes all major keywords" {
    const allocator = testing.allocator;
    const text = "";

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    const items = try features.provideCompletion(allocator, doc, 0, 0);
    defer {
        for (items) |item| {
            if (item.insertText) |insert_text| {
                if (!std.mem.eql(u8, insert_text, item.label)) {
                    allocator.free(insert_text);
                }
            }
        }
        allocator.free(items);
    }

    // Should have 100+ items (keywords + functions + types)
    try testing.expect(items.len >= 100);

    // Check for some key keywords
    const expected_keywords = [_][]const u8{ "MATCH", "CREATE", "RETURN", "WHERE", "ORDER", "LIMIT" };
    for (expected_keywords) |keyword| {
        var found = false;
        for (items) |item| {
            if (std.mem.eql(u8, item.label, keyword)) {
                found = true;
                break;
            }
        }
        try testing.expect(found);
    }
}

test "provideCompletion - includes common functions" {
    const allocator = testing.allocator;
    const text = "";

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    const items = try features.provideCompletion(allocator, doc, 0, 0);
    defer {
        for (items) |item| {
            if (item.insertText) |insert_text| {
                if (!std.mem.eql(u8, insert_text, item.label)) {
                    allocator.free(insert_text);
                }
            }
        }
        allocator.free(items);
    }

    // Check for common functions
    const expected_functions = [_][]const u8{ "count", "sum", "avg", "distance", "similarity" };
    for (expected_functions) |func| {
        var found = false;
        for (items) |item| {
            if (std.mem.eql(u8, item.label, func)) {
                found = true;
                try testing.expectEqual(protocol.CompletionItemKind.Function, item.kind.?);
                break;
            }
        }
        try testing.expect(found);
    }
}

test "provideCompletion - includes common types" {
    const allocator = testing.allocator;
    const text = "";

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    const items = try features.provideCompletion(allocator, doc, 0, 0);
    defer {
        for (items) |item| {
            if (item.insertText) |insert_text| {
                if (!std.mem.eql(u8, insert_text, item.label)) {
                    allocator.free(insert_text);
                }
            }
        }
        allocator.free(items);
    }

    // Check for common types
    const expected_types = [_][]const u8{ "INTEGER", "FLOAT", "STRING", "BOOLEAN", "VECTOR" };
    for (expected_types) |typ| {
        var found = false;
        for (items) |item| {
            if (std.mem.eql(u8, item.label, typ)) {
                found = true;
                try testing.expectEqual(protocol.CompletionItemKind.Class, item.kind.?);
                break;
            }
        }
        try testing.expect(found);
    }
}

test "provideDefinition - returns null (not implemented)" {
    const allocator = testing.allocator;
    const text = "MATCH (n) RETURN n";

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    const location = try features.provideDefinition(allocator, doc, 0, 17);
    try testing.expect(location == null);
}

test "provideFormatting - formats with newlines before keywords" {
    const allocator = testing.allocator;
    const text = "MATCH (n) RETURN n";

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    const formatted = try features.provideFormatting(allocator, doc);
    defer if (formatted) |f| allocator.free(f);
    // Formatter adds newlines before clause keywords like RETURN
    try testing.expect(formatted != null);
    try testing.expectEqualStrings("MATCH (n)\nRETURN n\n", formatted.?);
}
