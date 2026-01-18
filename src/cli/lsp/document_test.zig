// Module implementation
// Test suite for LSP document management

const std = @import("std");
const testing = std.testing;
const document = @import("document.zig");

test "Document - initialization" {
    const allocator = testing.allocator;
    const text = "MATCH (n:Person)\nRETURN n";

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    try testing.expectEqualStrings("file:///test.gql", doc.uri);
    try testing.expectEqualStrings(text, doc.text);
    try testing.expectEqual(@as(i32, 1), doc.version);
}

test "Document - update text" {
    const allocator = testing.allocator;

    var doc = try document.Document.init(allocator, "file:///test.gql", "old text", 1);
    defer doc.deinit();

    try doc.update("new text", 2);

    try testing.expectEqualStrings("new text", doc.text);
    try testing.expectEqual(@as(i32, 2), doc.version);
}

test "Document - getOffset single line" {
    const allocator = testing.allocator;
    const text = "MATCH (n)";

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    // Line 0, character 0 should be offset 0
    const offset1 = doc.getOffset(0, 0);
    try testing.expect(offset1 != null);
    try testing.expectEqual(@as(usize, 0), offset1.?);

    // Line 0, character 5 should be offset 5
    const offset2 = doc.getOffset(0, 5);
    try testing.expect(offset2 != null);
    try testing.expectEqual(@as(usize, 5), offset2.?);

    // Line 0, character 9 (end of line)
    const offset3 = doc.getOffset(0, 9);
    try testing.expect(offset3 != null);
    try testing.expectEqual(@as(usize, 9), offset3.?);
}

test "Document - getOffset multiple lines" {
    const allocator = testing.allocator;
    const text = "MATCH (n)\nWHERE n.age > 25\nRETURN n";

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    // Line 0, character 0
    const offset1 = doc.getOffset(0, 0);
    try testing.expect(offset1 != null);
    try testing.expectEqual(@as(usize, 0), offset1.?);

    // Line 1, character 0 (after first newline)
    const offset2 = doc.getOffset(1, 0);
    try testing.expect(offset2 != null);
    try testing.expectEqual(@as(usize, 10), offset2.?); // "MATCH (n)\n" = 10 chars

    // Line 2, character 0
    const offset3 = doc.getOffset(2, 0);
    try testing.expect(offset3 != null);
    try testing.expectEqual(@as(usize, 27), offset3.?); // "MATCH (n)\nWHERE n.age > 25\n" = 27
}

test "Document - getOffset out of bounds" {
    const allocator = testing.allocator;
    const text = "MATCH (n)";

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    // Line beyond document
    const offset1 = doc.getOffset(10, 0);
    try testing.expect(offset1 == null);

    // Character beyond line
    const offset2 = doc.getOffset(0, 100);
    try testing.expect(offset2 == null);
}

test "Document - getWordAt start of word" {
    const allocator = testing.allocator;
    const text = "MATCH (person:Person)";

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    // Offset 0 -> "MATCH"
    const word1 = doc.getWordAt(0);
    try testing.expect(word1 != null);
    try testing.expectEqualStrings("MATCH", word1.?);

    // Offset 7 -> "person"
    const word2 = doc.getWordAt(7);
    try testing.expect(word2 != null);
    try testing.expectEqualStrings("person", word2.?);

    // Offset 14 -> "Person"
    const word3 = doc.getWordAt(14);
    try testing.expect(word3 != null);
    try testing.expectEqualStrings("Person", word3.?);
}

test "Document - getWordAt middle of word" {
    const allocator = testing.allocator;
    const text = "RETURN count(n)";

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    // Offset 2 (middle of RETURN) -> "RETURN"
    const word1 = doc.getWordAt(2);
    try testing.expect(word1 != null);
    try testing.expectEqualStrings("RETURN", word1.?);

    // Offset 9 (middle of count) -> "count"
    const word2 = doc.getWordAt(9);
    try testing.expect(word2 != null);
    try testing.expectEqualStrings("count", word2.?);
}

test "Document - getWordAt on whitespace" {
    const allocator = testing.allocator;
    const text = "MATCH   (n)";

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    // Offset 6 (whitespace between MATCH and paren)
    const word = doc.getWordAt(6);
    try testing.expect(word == null);
}

test "Document - getWordAt on punctuation" {
    const allocator = testing.allocator;
    const text = "MATCH (n)";

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    // Offset 6 (opening paren)
    const word = doc.getWordAt(6);
    try testing.expect(word == null);
}

test "Document - getWordAt with underscores" {
    const allocator = testing.allocator;
    const text = "RETURN my_variable";

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    // Offset 10 (middle of my_variable)
    const word = doc.getWordAt(10);
    try testing.expect(word != null);
    try testing.expectEqualStrings("my_variable", word.?);
}

test "Document - getWordAt with numbers" {
    const allocator = testing.allocator;
    const text = "RETURN var123";

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    // Offset 10 (middle of var123)
    const word = doc.getWordAt(10);
    try testing.expect(word != null);
    try testing.expectEqualStrings("var123", word.?);
}

test "Document - empty text" {
    const allocator = testing.allocator;

    var doc = try document.Document.init(allocator, "file:///empty.gql", "", 1);
    defer doc.deinit();

    try testing.expectEqualStrings("", doc.text);

    const offset = doc.getOffset(0, 0);
    try testing.expect(offset != null);
    try testing.expectEqual(@as(usize, 0), offset.?);

    const word = doc.getWordAt(0);
    try testing.expect(word == null);
}

test "DocumentStore - init and deinit" {
    const allocator = testing.allocator;

    var store = document.DocumentStore.init(allocator);
    defer store.deinit();

    // Should be empty initially
    const doc = store.get("file:///test.gql");
    try testing.expect(doc == null);
}

test "DocumentStore - open and get" {
    const allocator = testing.allocator;

    var store = document.DocumentStore.init(allocator);
    defer store.deinit();

    try store.open("file:///test.gql", "MATCH (n) RETURN n", 1);

    const doc = store.get("file:///test.gql");
    try testing.expect(doc != null);
    try testing.expectEqualStrings("file:///test.gql", doc.?.uri);
    try testing.expectEqualStrings("MATCH (n) RETURN n", doc.?.text);
    try testing.expectEqual(@as(i32, 1), doc.?.version);
}

test "DocumentStore - open multiple documents" {
    const allocator = testing.allocator;

    var store = document.DocumentStore.init(allocator);
    defer store.deinit();

    try store.open("file:///test1.gql", "query 1", 1);
    try store.open("file:///test2.gql", "query 2", 1);
    try store.open("file:///test3.gql", "query 3", 1);

    const doc1 = store.get("file:///test1.gql");
    const doc2 = store.get("file:///test2.gql");
    const doc3 = store.get("file:///test3.gql");

    try testing.expect(doc1 != null);
    try testing.expect(doc2 != null);
    try testing.expect(doc3 != null);

    try testing.expectEqualStrings("query 1", doc1.?.text);
    try testing.expectEqualStrings("query 2", doc2.?.text);
    try testing.expectEqualStrings("query 3", doc3.?.text);
}

test "DocumentStore - update existing document" {
    const allocator = testing.allocator;

    var store = document.DocumentStore.init(allocator);
    defer store.deinit();

    try store.open("file:///test.gql", "old text", 1);
    try store.update("file:///test.gql", "new text", 2);

    const doc = store.get("file:///test.gql");
    try testing.expect(doc != null);
    try testing.expectEqualStrings("new text", doc.?.text);
    try testing.expectEqual(@as(i32, 2), doc.?.version);
}

test "DocumentStore - update nonexistent document is silent" {
    const allocator = testing.allocator;

    var store = document.DocumentStore.init(allocator);
    defer store.deinit();

    // Update on nonexistent document should succeed but do nothing
    try store.update("file:///nonexistent.gql", "text", 1);

    // Document still should not exist
    const doc = store.get("file:///nonexistent.gql");
    try testing.expect(doc == null);
}

test "DocumentStore - close document" {
    const allocator = testing.allocator;

    var store = document.DocumentStore.init(allocator);
    defer store.deinit();

    try store.open("file:///test.gql", "some text", 1);

    // Document should exist
    var doc = store.get("file:///test.gql");
    try testing.expect(doc != null);

    // Close the document
    store.close("file:///test.gql");

    // Document should no longer exist
    doc = store.get("file:///test.gql");
    try testing.expect(doc == null);
}

test "DocumentStore - close nonexistent document is safe" {
    const allocator = testing.allocator;

    var store = document.DocumentStore.init(allocator);
    defer store.deinit();

    // Should not crash
    store.close("file:///nonexistent.gql");
}

test "DocumentStore - reopen same URI" {
    const allocator = testing.allocator;

    var store = document.DocumentStore.init(allocator);
    defer store.deinit();

    try store.open("file:///test.gql", "version 1", 1);
    try store.open("file:///test.gql", "version 2", 2);

    const doc = store.get("file:///test.gql");
    try testing.expect(doc != null);
    try testing.expectEqualStrings("version 2", doc.?.text);
    try testing.expectEqual(@as(i32, 2), doc.?.version);
}

test "Document - Windows line endings" {
    const allocator = testing.allocator;
    const text = "MATCH (n)\r\nRETURN n";

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    // Line 1, character 0 (after \r\n)
    const offset = doc.getOffset(1, 0);
    try testing.expect(offset != null);
    try testing.expectEqual(@as(usize, 11), offset.?); // "MATCH (n)\r\n" = 11 chars
}

test "Document - mixed line endings" {
    const allocator = testing.allocator;
    const text = "MATCH (n)\nWHERE x > 5\r\nRETURN n";

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    // Line 0, character 0
    const offset1 = doc.getOffset(0, 0);
    try testing.expectEqual(@as(usize, 0), offset1.?);

    // Line 1, character 0 (after \n)
    const offset2 = doc.getOffset(1, 0);
    try testing.expectEqual(@as(usize, 10), offset2.?);

    // Line 2, character 0 (after \r\n)
    const offset3 = doc.getOffset(2, 0);
    try testing.expectEqual(@as(usize, 23), offset3.?);
}

test "Document - findIdentifierPosition single line" {
    const allocator = testing.allocator;
    const text = "MATCH (person:Person) RETURN person";

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    // Find "person" - should find first occurrence at character 7
    const pos1 = doc.findIdentifierPosition("person");
    try testing.expect(pos1 != null);
    try testing.expectEqual(@as(u32, 0), pos1.?.line);
    try testing.expectEqual(@as(u32, 7), pos1.?.character);

    // Find "Person" - case-insensitive, so also finds "person" first at character 7
    const pos2 = doc.findIdentifierPosition("Person");
    try testing.expect(pos2 != null);
    try testing.expectEqual(@as(u32, 0), pos2.?.line);
    try testing.expectEqual(@as(u32, 7), pos2.?.character);

    // Find "MATCH" at character 0
    const pos3 = doc.findIdentifierPosition("MATCH");
    try testing.expect(pos3 != null);
    try testing.expectEqual(@as(u32, 0), pos3.?.line);
    try testing.expectEqual(@as(u32, 0), pos3.?.character);
}

test "Document - findIdentifierPosition multiple lines" {
    const allocator = testing.allocator;
    const text = "MATCH (n:Person)\nWHERE undefinedVar > 5\nRETURN n";

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    // Find "undefinedVar" on line 1
    const pos = doc.findIdentifierPosition("undefinedVar");
    try testing.expect(pos != null);
    try testing.expectEqual(@as(u32, 1), pos.?.line);
    try testing.expectEqual(@as(u32, 6), pos.?.character); // "WHERE " = 6 chars
}

test "Document - findIdentifierPosition case insensitive" {
    const allocator = testing.allocator;
    const text = "MATCH (myNode:Person) RETURN myNode";

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    // Search with different case
    const pos1 = doc.findIdentifierPosition("MYNODE");
    try testing.expect(pos1 != null);
    try testing.expectEqual(@as(u32, 0), pos1.?.line);
    try testing.expectEqual(@as(u32, 7), pos1.?.character);

    const pos2 = doc.findIdentifierPosition("mynode");
    try testing.expect(pos2 != null);
    try testing.expectEqual(@as(u32, 0), pos2.?.line);
    try testing.expectEqual(@as(u32, 7), pos2.?.character);
}

test "Document - findIdentifierPosition word boundaries" {
    const allocator = testing.allocator;
    const text = "MATCH (node:PersonNode) RETURN node";

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    // "Person" should NOT match "PersonNode" - it's part of a larger word
    const pos1 = doc.findIdentifierPosition("Person");
    try testing.expect(pos1 == null);

    // "PersonNode" should match
    const pos2 = doc.findIdentifierPosition("PersonNode");
    try testing.expect(pos2 != null);
    try testing.expectEqual(@as(u32, 12), pos2.?.character);

    // "node" should match at character 7, not inside PersonNode
    const pos3 = doc.findIdentifierPosition("node");
    try testing.expect(pos3 != null);
    try testing.expectEqual(@as(u32, 7), pos3.?.character);
}

test "Document - findIdentifierPosition not found" {
    const allocator = testing.allocator;
    const text = "MATCH (n:Person) RETURN n";

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    const pos = doc.findIdentifierPosition("undefinedVariable");
    try testing.expect(pos == null);
}

test "Document - findIdentifierPosition empty identifier" {
    const allocator = testing.allocator;
    const text = "MATCH (n) RETURN n";

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    const pos = doc.findIdentifierPosition("");
    try testing.expect(pos == null);
}

test "Document - findIdentifierPosition with underscores" {
    const allocator = testing.allocator;
    const text = "MATCH (my_node:Person) RETURN my_node";

    var doc = try document.Document.init(allocator, "file:///test.gql", text, 1);
    defer doc.deinit();

    const pos = doc.findIdentifierPosition("my_node");
    try testing.expect(pos != null);
    try testing.expectEqual(@as(u32, 0), pos.?.line);
    try testing.expectEqual(@as(u32, 7), pos.?.character);
}
