// GAP-0436: Tests for JSONB depth limit guard (CWE-400/674)
const std = @import("std");
const jsonb = @import("jsonb.zig");

test "JSONB: rejects deeply nested input at depth > 64 (GAP-0436)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Build {"a":{"a":{"a": ... }}} 200 levels deep
    var deep: std.ArrayList(u8) = .empty;
    defer deep.deinit(allocator);
    for (0..200) |_| try deep.appendSlice(allocator, "{\"a\":");
    try deep.appendSlice(allocator, "1");
    for (0..200) |_| try deep.append(allocator, '}');

    const result = jsonb.JsonbDocument.fromString(allocator, deep.items);
    try std.testing.expectError(jsonb.JsonbDocument.Error.InvalidJson, result);
}

test "JSONB: accepts normally nested input (depth <= 64) (GAP-0436)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    // 3-level nesting is fine
    const doc = try jsonb.JsonbDocument.fromString(allocator, "{\"a\":{\"b\":{\"c\":1}}}");
    defer allocator.free(doc.data);
}

test "JSONB: accepts input nested exactly at depth 64 (GAP-0436)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Build 64 levels deep — exactly at limit, should succeed
    var at_limit: std.ArrayList(u8) = .empty;
    defer at_limit.deinit(allocator);
    for (0..64) |_| try at_limit.appendSlice(allocator, "{\"a\":");
    try at_limit.appendSlice(allocator, "1");
    for (0..64) |_| try at_limit.append(allocator, '}');

    const doc = try jsonb.JsonbDocument.fromString(allocator, at_limit.items);
    defer allocator.free(doc.data);
}

test "JSONB: rejects input nested at depth 65 (GAP-0436)" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Build 65 levels deep — one beyond limit, should fail
    var over_limit: std.ArrayList(u8) = .empty;
    defer over_limit.deinit(allocator);
    for (0..65) |_| try over_limit.appendSlice(allocator, "{\"a\":");
    try over_limit.appendSlice(allocator, "1");
    for (0..65) |_| try over_limit.append(allocator, '}');

    const result = jsonb.JsonbDocument.fromString(allocator, over_limit.items);
    try std.testing.expectError(jsonb.JsonbDocument.Error.InvalidJson, result);
}
