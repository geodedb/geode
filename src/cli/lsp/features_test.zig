// Module implementation
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

    const items = try features.provideCompletion(allocator, doc, 0, 3, null);
    defer {
        for (items) |item| {
            // Free insertText if allocated (different from label)
            if (item.insertText) |insert_text| {
                if (!std.mem.eql(u8, insert_text, item.label)) {
                    allocator.free(insert_text);
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

    const items = try features.provideCompletion(allocator, doc, 0, 10, null);
    defer {
        for (items) |item| {
            if (item.insertText) |insert_text| {
                if (!std.mem.eql(u8, insert_text, item.label)) {
                    allocator.free(insert_text);
                }
            }
            if (item.detail) |detail| {
                if (item.kind != .Class) {
                    allocator.free(detail);
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

    const items = try features.provideCompletion(allocator, doc, 0, 20, null);
    defer {
        for (items) |item| {
            if (item.insertText) |insert_text| {
                if (!std.mem.eql(u8, insert_text, item.label)) {
                    allocator.free(insert_text);
                }
            }
            if (item.detail) |detail| {
                if (item.kind != .Class) {
                    allocator.free(detail);
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

    const items = try features.provideCompletion(allocator, doc, 0, 0, null);
    defer {
        for (items) |item| {
            if (item.insertText) |insert_text| {
                if (!std.mem.eql(u8, insert_text, item.label)) {
                    allocator.free(insert_text);
                }
            }
            if (item.detail) |detail| {
                if (item.kind != .Class) {
                    allocator.free(detail);
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

    const items = try features.provideCompletion(allocator, doc, 0, 0, null);
    defer {
        for (items) |item| {
            if (item.insertText) |insert_text| {
                if (!std.mem.eql(u8, insert_text, item.label)) {
                    allocator.free(insert_text);
                }
            }
            if (item.detail) |detail| {
                if (item.kind != .Class) {
                    allocator.free(detail);
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

    const items = try features.provideCompletion(allocator, doc, 0, 0, null);
    defer {
        for (items) |item| {
            if (item.insertText) |insert_text| {
                if (!std.mem.eql(u8, insert_text, item.label)) {
                    allocator.free(insert_text);
                }
            }
            if (item.detail) |detail| {
                if (item.kind != .Class) {
                    allocator.free(detail);
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

test "provideDefinition - finds variable definition in pattern" {
    const allocator = testing.allocator;
    const text = "MATCH (n) RETURN n";

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    // Position 17 is at 'n' in "RETURN n" - should find definition at position 7 (n in "(n)")
    const location = try features.provideDefinition(allocator, doc, 0, 17);
    try testing.expect(location != null);
    try testing.expectEqual(@as(u32, 0), location.?.range.start.line);
    try testing.expectEqual(@as(u32, 7), location.?.range.start.character);
}

test "provideDefinition - returns null for keywords" {
    const allocator = testing.allocator;
    const text = "MATCH (n) RETURN n";

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    // Position 0 is at 'M' in "MATCH" - keywords should return null
    const location = try features.provideDefinition(allocator, doc, 0, 0);
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

test "provideFormattingWithOptions - folds property maps with multiple properties" {
    const allocator = testing.allocator;
    const text = "CREATE (:Person {name: 'Alice', age: 30, city: 'NYC'})";

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    const options = features.FormattingOptions{
        .fold_property_maps = true,
        .indent_size = 4,
        .min_properties_to_fold = 2,
    };
    const formatted = try features.provideFormattingWithOptions(allocator, doc, options);
    defer if (formatted) |f| allocator.free(f);

    try testing.expect(formatted != null);
    // Should fold properties onto separate lines
    try testing.expect(std.mem.indexOf(u8, formatted.?, "name: 'Alice',\n") != null);
    try testing.expect(std.mem.indexOf(u8, formatted.?, "age: 30,\n") != null);
    try testing.expect(std.mem.indexOf(u8, formatted.?, "city: 'NYC'\n") != null);
}

test "provideFormattingWithOptions - does not fold with fold disabled" {
    const allocator = testing.allocator;
    const text = "CREATE (:Person {name: 'Alice', age: 30})";

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    const options = features.FormattingOptions{
        .fold_property_maps = false,
    };
    const formatted = try features.provideFormattingWithOptions(allocator, doc, options);
    defer if (formatted) |f| allocator.free(f);

    try testing.expect(formatted != null);
    // With folding disabled, properties stay on one line
    try testing.expect(std.mem.indexOf(u8, formatted.?, "{name: 'Alice', age: 30}") != null);
}

test "provideFormattingWithOptions - does not fold single property" {
    const allocator = testing.allocator;
    const text = "CREATE (:Person {name: 'Alice'})";

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    const options = features.FormattingOptions{
        .fold_property_maps = true,
        .min_properties_to_fold = 2,
    };
    const formatted = try features.provideFormattingWithOptions(allocator, doc, options);
    defer if (formatted) |f| allocator.free(f);

    try testing.expect(formatted != null);
    // Single property should not be folded
    try testing.expect(std.mem.indexOf(u8, formatted.?, "{name: 'Alice'}") != null);
}

test "provideFormattingWithOptions - respects min properties to fold" {
    const allocator = testing.allocator;
    const text = "CREATE (:Person {name: 'Alice', age: 30})";

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    // Require 3 properties to fold (we have 2)
    const options = features.FormattingOptions{
        .fold_property_maps = true,
        .min_properties_to_fold = 3,
    };
    const formatted = try features.provideFormattingWithOptions(allocator, doc, options);
    defer if (formatted) |f| allocator.free(f);

    try testing.expect(formatted != null);
    // 2 properties should not be folded when min is 3
    try testing.expect(std.mem.indexOf(u8, formatted.?, "{name: 'Alice', age: 30}") != null);
}

test "provideFormatting - adds blank lines between statements" {
    const allocator = testing.allocator;
    const text = "CREATE (:A {x: 1}); CREATE (:B {y: 2}); MATCH (n) RETURN n;";

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    // Disable folding to make output predictable
    const options = features.FormattingOptions{
        .fold_property_maps = false,
    };
    const formatted = try features.provideFormattingWithOptions(allocator, doc, options);
    defer if (formatted) |f| allocator.free(f);

    try testing.expect(formatted != null);
    // Should have blank lines between statements (double newline after semicolon)
    try testing.expect(std.mem.indexOf(u8, formatted.?, ";\n\nCREATE") != null);
    try testing.expect(std.mem.indexOf(u8, formatted.?, ";\n\nMATCH") != null);
}

// ============================================================================
// Comprehensive Formatter Tests (based on testing/shell/*.gql patterns)
// ============================================================================

test "provideFormattingWithOptions - CASE WHEN ELSE END indentation" {
    const allocator = testing.allocator;
    // Test CASE expression from comprehensive_test.gql Section 11
    const text =
        \\RETURN CASE WHEN 5 > 3 THEN 'greater' ELSE 'less' END AS simple_case;
    ;

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    const options = features.FormattingOptions{
        .fold_property_maps = false,
        .indent_size = 4,
    };
    const formatted = try features.provideFormattingWithOptions(allocator, doc, options);
    defer if (formatted) |f| allocator.free(f);

    try testing.expect(formatted != null);
    // CASE should be preserved with keywords uppercased
    try testing.expect(std.mem.indexOf(u8, formatted.?, "CASE") != null);
    try testing.expect(std.mem.indexOf(u8, formatted.?, "WHEN") != null);
    try testing.expect(std.mem.indexOf(u8, formatted.?, "THEN") != null);
    try testing.expect(std.mem.indexOf(u8, formatted.?, "ELSE") != null);
    try testing.expect(std.mem.indexOf(u8, formatted.?, "END") != null);
}

test "provideFormattingWithOptions - multi-line CASE expression" {
    const allocator = testing.allocator;
    // Test nested CASE from comprehensive_test.gql Section 11.2
    const text =
        \\RETURN CASE
        \\    WHEN 10 > 20 THEN 'a'
        \\    WHEN 10 > 5 THEN 'b'
        \\    ELSE 'c'
        \\END AS nested_case;
    ;

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    const options = features.FormattingOptions{
        .fold_property_maps = false,
        .indent_size = 4,
    };
    const formatted = try features.provideFormattingWithOptions(allocator, doc, options);
    defer if (formatted) |f| allocator.free(f);

    try testing.expect(formatted != null);
    // WHEN lines should be indented (contain leading spaces before WHEN)
    try testing.expect(std.mem.indexOf(u8, formatted.?, "    WHEN") != null);
    try testing.expect(std.mem.indexOf(u8, formatted.?, "    ELSE") != null);
}

test "provideFormattingWithOptions - WITH clause chaining" {
    const allocator = testing.allocator;
    // Pattern from enterprise_test.gql Section 2.1
    const text =
        \\MATCH (e:Employee)
        \\WITH e ORDER BY e.salary DESC LIMIT 3
        \\RETURN e.name AS top_earner, e.salary AS salary, e.department AS dept;
    ;

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    const options = features.FormattingOptions{
        .fold_property_maps = false,
    };
    const formatted = try features.provideFormattingWithOptions(allocator, doc, options);
    defer if (formatted) |f| allocator.free(f);

    try testing.expect(formatted != null);
    // WITH, ORDER BY, LIMIT should be preserved
    try testing.expect(std.mem.indexOf(u8, formatted.?, "WITH e") != null);
    try testing.expect(std.mem.indexOf(u8, formatted.?, "ORDER BY") != null);
    try testing.expect(std.mem.indexOf(u8, formatted.?, "LIMIT 3") != null);
}

test "provideFormattingWithOptions - OPTIONAL MATCH pattern" {
    const allocator = testing.allocator;
    // Pattern from test_fixes.gql
    const text =
        \\MATCH (n:SocialUser)
        \\OPTIONAL MATCH (n)-[r:FRIEND]-()
        \\WITH n, count(r) AS connections
        \\RETURN n.name AS user, connections ORDER BY connections DESC;
    ;

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    const options = features.FormattingOptions{
        .fold_property_maps = false,
    };
    const formatted = try features.provideFormattingWithOptions(allocator, doc, options);
    defer if (formatted) |f| allocator.free(f);

    try testing.expect(formatted != null);
    // OPTIONAL MATCH should start on new line
    try testing.expect(std.mem.indexOf(u8, formatted.?, "\nOPTIONAL MATCH") != null);
}

test "provideFormattingWithOptions - GROUP BY and HAVING" {
    const allocator = testing.allocator;
    // Pattern from enterprise_test.gql Section 3
    const text =
        \\MATCH (e:Employee)
        \\RETURN e.department AS dept, avg(e.salary) AS avg_sal
        \\GROUP BY e.department
        \\HAVING avg(e.salary) > 85000
        \\ORDER BY avg_sal DESC;
    ;

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    const options = features.FormattingOptions{
        .fold_property_maps = false,
    };
    const formatted = try features.provideFormattingWithOptions(allocator, doc, options);
    defer if (formatted) |f| allocator.free(f);

    try testing.expect(formatted != null);
    // GROUP and HAVING should start on new lines
    try testing.expect(std.mem.indexOf(u8, formatted.?, "\nGROUP BY") != null);
    try testing.expect(std.mem.indexOf(u8, formatted.?, "\nHAVING") != null);
    try testing.expect(std.mem.indexOf(u8, formatted.?, "\nORDER BY") != null);
}

test "provideFormattingWithOptions - UNION queries" {
    const allocator = testing.allocator;
    // Pattern from comprehensive_test.gql Section 19
    const text =
        \\MATCH (p:Person) WHERE p.age < 30 RETURN p.name AS name
        \\UNION
        \\MATCH (p:Person) WHERE p.name STARTS WITH 'A' RETURN p.name AS name;
    ;

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    const options = features.FormattingOptions{
        .fold_property_maps = false,
    };
    const formatted = try features.provideFormattingWithOptions(allocator, doc, options);
    defer if (formatted) |f| allocator.free(f);

    try testing.expect(formatted != null);
    // UNION should start on new line
    try testing.expect(std.mem.indexOf(u8, formatted.?, "\nUNION\n") != null);
}

test "provideFormattingWithOptions - CREATE with multiple properties folded" {
    const allocator = testing.allocator;
    // Pattern from enterprise_test.gql
    const text = "CREATE (e1:Employee {id: 'EMP001', name: 'Alice Johnson', department: 'Engineering', salary: 95000, hire_date: '2020-03-15'});";

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    const options = features.FormattingOptions{
        .fold_property_maps = true,
        .indent_size = 4,
        .min_properties_to_fold = 2,
    };
    const formatted = try features.provideFormattingWithOptions(allocator, doc, options);
    defer if (formatted) |f| allocator.free(f);

    try testing.expect(formatted != null);
    // Properties should be folded onto separate lines
    try testing.expect(std.mem.indexOf(u8, formatted.?, "id: 'EMP001',\n") != null);
    try testing.expect(std.mem.indexOf(u8, formatted.?, "name: 'Alice Johnson',\n") != null);
    try testing.expect(std.mem.indexOf(u8, formatted.?, "department: 'Engineering',\n") != null);
}

test "provideFormattingWithOptions - relationship with properties" {
    const allocator = testing.allocator;
    // Pattern from comprehensive_test.gql Section 14
    const text = "MATCH (a:Person {name: 'Alice'}), (b:Person {name: 'Bob'}) CREATE (a)-[:KNOWS {since: 2020}]->(b);";

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    const options = features.FormattingOptions{
        .fold_property_maps = false,
    };
    const formatted = try features.provideFormattingWithOptions(allocator, doc, options);
    defer if (formatted) |f| allocator.free(f);

    try testing.expect(formatted != null);
    // Relationship pattern should be preserved
    try testing.expect(std.mem.indexOf(u8, formatted.?, "-[:KNOWS {since: 2020}]->") != null);
}

test "provideFormattingWithOptions - variable-length path pattern" {
    const allocator = testing.allocator;
    // Pattern from comprehensive_test.gql Section 15
    const text =
        \\MATCH path = (a:Person)-[:KNOWS*1..3]->(b:Person)
        \\WHERE a.name = 'Alice'
        \\RETURN a.name AS start, b.name AS end, length(path) AS hops;
    ;

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    const options = features.FormattingOptions{
        .fold_property_maps = false,
    };
    const formatted = try features.provideFormattingWithOptions(allocator, doc, options);
    defer if (formatted) |f| allocator.free(f);

    try testing.expect(formatted != null);
    // Variable-length pattern should be preserved
    try testing.expect(std.mem.indexOf(u8, formatted.?, "[:KNOWS*1..3]") != null);
}

test "provideFormattingWithOptions - aggregation with GROUP BY" {
    const allocator = testing.allocator;
    // Pattern from comprehensive_test.gql Section 18
    const text =
        \\MATCH (p:Person)-[:WORKS_FOR]->(c:Company)
        \\RETURN c.name AS company, count(p) AS employees
        \\GROUP BY c.name
        \\ORDER BY employees DESC;
    ;

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    const options = features.FormattingOptions{
        .fold_property_maps = false,
    };
    const formatted = try features.provideFormattingWithOptions(allocator, doc, options);
    defer if (formatted) |f| allocator.free(f);

    try testing.expect(formatted != null);
    try testing.expect(std.mem.indexOf(u8, formatted.?, "count(p)") != null);
    try testing.expect(std.mem.indexOf(u8, formatted.?, "\nGROUP BY c.name") != null);
}

test "provideFormattingWithOptions - collect function with GROUP BY" {
    const allocator = testing.allocator;
    // Pattern from comprehensive_test.gql Section 18.6
    const text =
        \\MATCH (p:Person)-[:WORKS_FOR]->(c:Company {name: 'TechCorp'})
        \\RETURN c.name AS company, collect(p.name) AS employees
        \\GROUP BY c.name;
    ;

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    const options = features.FormattingOptions{
        .fold_property_maps = false,
    };
    const formatted = try features.provideFormattingWithOptions(allocator, doc, options);
    defer if (formatted) |f| allocator.free(f);

    try testing.expect(formatted != null);
    try testing.expect(std.mem.indexOf(u8, formatted.?, "collect(p.name)") != null);
}

test "provideFormattingWithOptions - SET and REMOVE operations" {
    const allocator = testing.allocator;
    // Pattern from comprehensive_test.gql Section 20
    const text =
        \\MATCH (p:Person {name: 'Alice'}) SET p.nickname = 'Ali' RETURN p.name, p.nickname;
    ;

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    const options = features.FormattingOptions{
        .fold_property_maps = false,
    };
    const formatted = try features.provideFormattingWithOptions(allocator, doc, options);
    defer if (formatted) |f| allocator.free(f);

    try testing.expect(formatted != null);
    // SET should start on new line
    try testing.expect(std.mem.indexOf(u8, formatted.?, "\nSET p.nickname") != null);
}

test "provideFormattingWithOptions - CREATE GRAPH and USE GRAPH" {
    const allocator = testing.allocator;
    // Pattern from comprehensive_test.gql Section 12
    const text =
        \\CREATE GRAPH IF NOT EXISTS test_comprehensive;
        \\USE GRAPH test_comprehensive;
    ;

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    const options = features.FormattingOptions{
        .fold_property_maps = false,
    };
    const formatted = try features.provideFormattingWithOptions(allocator, doc, options);
    defer if (formatted) |f| allocator.free(f);

    try testing.expect(formatted != null);
    // CREATE GRAPH and USE GRAPH should be preserved
    try testing.expect(std.mem.indexOf(u8, formatted.?, "CREATE GRAPH IF NOT EXISTS") != null);
    try testing.expect(std.mem.indexOf(u8, formatted.?, "USE GRAPH") != null);
}

test "provideFormattingWithOptions - vector operations" {
    const allocator = testing.allocator;
    // Pattern from comprehensive_test.gql Section 26
    const text =
        \\RETURN vectorf32('[1.0, 2.0, 3.0]') AS vec;
        \\RETURN vector_l2(vectorf32('[1.0, 0.0]'), vectorf32('[0.0, 1.0]')) AS l2_distance;
    ;

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    const options = features.FormattingOptions{
        .fold_property_maps = false,
    };
    const formatted = try features.provideFormattingWithOptions(allocator, doc, options);
    defer if (formatted) |f| allocator.free(f);

    try testing.expect(formatted != null);
    // Vector functions should be preserved (lowercase)
    try testing.expect(std.mem.indexOf(u8, formatted.?, "vectorf32(") != null);
    try testing.expect(std.mem.indexOf(u8, formatted.?, "vector_l2(") != null);
}

test "provideFormattingWithOptions - INDEX and CONSTRAINT operations" {
    const allocator = testing.allocator;
    // Pattern from comprehensive_test.gql Section 29-30
    const text =
        \\CREATE INDEX IF NOT EXISTS idx_person_name FOR (p:Person) ON (p.name);
        \\CREATE CONSTRAINT IF NOT EXISTS unique_person_email FOR (p:Person) REQUIRE p.email IS UNIQUE;
    ;

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    const options = features.FormattingOptions{
        .fold_property_maps = false,
    };
    const formatted = try features.provideFormattingWithOptions(allocator, doc, options);
    defer if (formatted) |f| allocator.free(f);

    try testing.expect(formatted != null);
    try testing.expect(std.mem.indexOf(u8, formatted.?, "CREATE INDEX") != null);
    try testing.expect(std.mem.indexOf(u8, formatted.?, "CREATE CONSTRAINT") != null);
}

test "provideFormattingWithOptions - DETACH DELETE" {
    const allocator = testing.allocator;
    // Pattern from comprehensive_test.gql
    const text = "MATCH (n) DETACH DELETE n;";

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    const options = features.FormattingOptions{
        .fold_property_maps = false,
    };
    const formatted = try features.provideFormattingWithOptions(allocator, doc, options);
    defer if (formatted) |f| allocator.free(f);

    try testing.expect(formatted != null);
    // DETACH should be preserved
    try testing.expect(std.mem.indexOf(u8, formatted.?, "DETACH DELETE") != null);
}

test "provideFormattingWithOptions - comment preservation with statements" {
    const allocator = testing.allocator;
    // Pattern from test_fixes.gql
    const text =
        \\-- Setup
        \\CREATE GRAPH IF NOT EXISTS test_fix;
        \\USE GRAPH test_fix;
        \\
        \\-- Clean any previous data
        \\MATCH (n) DETACH DELETE n;
    ;

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    const options = features.FormattingOptions{
        .fold_property_maps = false,
    };
    const formatted = try features.provideFormattingWithOptions(allocator, doc, options);
    defer if (formatted) |f| allocator.free(f);

    try testing.expect(formatted != null);
    // Comments should be preserved
    try testing.expect(std.mem.indexOf(u8, formatted.?, "-- Setup") != null);
    try testing.expect(std.mem.indexOf(u8, formatted.?, "-- Clean any previous data") != null);
}

test "provideFormattingWithOptions - comment groups stay together" {
    const allocator = testing.allocator;
    // Multiple consecutive comments should NOT have blank lines between them
    const text =
        \\CREATE (n:Node);
        \\-- ============================================================================
        \\-- SECTION 11: SET OPERATIONS EDGE CASES
        \\-- ============================================================================
        \\-- 11.1 UNION with empty set
        \\MATCH (x) RETURN x;
    ;

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    const options = features.FormattingOptions{
        .fold_property_maps = false,
    };
    const formatted = try features.provideFormattingWithOptions(allocator, doc, options);
    defer if (formatted) |f| allocator.free(f);

    try testing.expect(formatted != null);
    // Comment group should stay together - no extra blank lines between comments
    // Look for consecutive comment lines
    const comment_block =
        \\-- ============================================================================
        \\-- SECTION 11: SET OPERATIONS EDGE CASES
        \\-- ============================================================================
        \\-- 11.1 UNION with empty set
    ;
    try testing.expect(std.mem.indexOf(u8, formatted.?, comment_block) != null);
}

test "provideFormattingWithOptions - blank line before comment after code" {
    const allocator = testing.allocator;
    // A comment after code should have a blank line before it
    const text =
        \\CREATE (n:Node);
        \\-- This is a comment
        \\MATCH (x) RETURN x;
    ;

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    const options = features.FormattingOptions{
        .fold_property_maps = false,
    };
    const formatted = try features.provideFormattingWithOptions(allocator, doc, options);
    defer if (formatted) |f| allocator.free(f);

    try testing.expect(formatted != null);
    // There should be a blank line before the comment (after code)
    // Look for: ";\n\n-- This is a comment"
    try testing.expect(std.mem.indexOf(u8, formatted.?, ";\n\n-- This is a comment") != null);
}

test "provideFormattingWithOptions - multi-pattern MATCH" {
    const allocator = testing.allocator;
    // Pattern from comprehensive_test.gql Section 15.9
    const text =
        \\MATCH (p:Person)-[:WORKS_FOR]->(c:Company), (p)-[:PURCHASED]->(pr:Product)
        \\RETURN p.name AS person, c.name AS employer, pr.name AS purchased;
    ;

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    const options = features.FormattingOptions{
        .fold_property_maps = false,
    };
    const formatted = try features.provideFormattingWithOptions(allocator, doc, options);
    defer if (formatted) |f| allocator.free(f);

    try testing.expect(formatted != null);
    // Multiple patterns should be preserved
    try testing.expect(std.mem.indexOf(u8, formatted.?, "-[:WORKS_FOR]->") != null);
    try testing.expect(std.mem.indexOf(u8, formatted.?, "-[:PURCHASED]->") != null);
}

test "provideFormattingWithOptions - list predicates" {
    const allocator = testing.allocator;
    // Pattern from comprehensive_test.gql Section 7
    const text =
        \\RETURN all(x IN [1, 2, 3] WHERE x > 0) AS all_positive;
        \\RETURN any(x IN [1, 2, 3] WHERE x > 2) AS any_greater;
    ;

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    const options = features.FormattingOptions{
        .fold_property_maps = false,
    };
    const formatted = try features.provideFormattingWithOptions(allocator, doc, options);
    defer if (formatted) |f| allocator.free(f);

    try testing.expect(formatted != null);
    // List predicates should be preserved
    try testing.expect(std.mem.indexOf(u8, formatted.?, "all(x IN [1, 2, 3]") != null);
    try testing.expect(std.mem.indexOf(u8, formatted.?, "any(x IN [1, 2, 3]") != null);
}

test "provideFormattingWithOptions - date functions" {
    const allocator = testing.allocator;
    // Pattern from comprehensive_test.gql Section 9
    const text =
        \\RETURN datetime() AS current_datetime;
        \\RETURN date() AS current_date;
        \\RETURN date('2024-01-15') AS parsed_date;
    ;

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    const options = features.FormattingOptions{
        .fold_property_maps = false,
    };
    const formatted = try features.provideFormattingWithOptions(allocator, doc, options);
    defer if (formatted) |f| allocator.free(f);

    try testing.expect(formatted != null);
    // Date functions should be preserved (lowercase)
    try testing.expect(std.mem.indexOf(u8, formatted.?, "datetime()") != null);
    try testing.expect(std.mem.indexOf(u8, formatted.?, "date()") != null);
}

test "provideFormattingWithOptions - shortestPath function" {
    const allocator = testing.allocator;
    // Pattern from comprehensive_test.gql Section 28
    const text =
        \\MATCH path = shortestPath((a:Person {name: 'Alice'})-[:KNOWS*]->(b:Person {name: 'Diana'}))
        \\RETURN path, length(path) AS hops;
    ;

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    const options = features.FormattingOptions{
        .fold_property_maps = false,
    };
    const formatted = try features.provideFormattingWithOptions(allocator, doc, options);
    defer if (formatted) |f| allocator.free(f);

    try testing.expect(formatted != null);
    // shortestPath function should be preserved
    try testing.expect(std.mem.indexOf(u8, formatted.?, "shortestPath(") != null);
}

test "provideFormattingWithOptions - complex CASE with multiple conditions" {
    const allocator = testing.allocator;
    // Pattern from comprehensive_test.gql Section 11.3
    const text =
        \\RETURN CASE
        \\    WHEN 5 > 10 THEN 'too high'
        \\    WHEN 5 < 0 THEN 'negative'
        \\    WHEN 5 >= 0 AND 5 <= 10 THEN 'in range'
        \\    ELSE 'unknown'
        \\END AS range_case;
    ;

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    const options = features.FormattingOptions{
        .fold_property_maps = false,
        .indent_size = 4,
    };
    const formatted = try features.provideFormattingWithOptions(allocator, doc, options);
    defer if (formatted) |f| allocator.free(f);

    try testing.expect(formatted != null);
    // WHEN clauses should be indented inside CASE
    try testing.expect(std.mem.indexOf(u8, formatted.?, "    WHEN 5 > 10 THEN") != null);
    try testing.expect(std.mem.indexOf(u8, formatted.?, "    WHEN 5 < 0 THEN") != null);
    try testing.expect(std.mem.indexOf(u8, formatted.?, "    ELSE 'unknown'") != null);
}
