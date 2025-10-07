const std = @import("std");
const testing = std.testing;
const evaluator_functions = @import("types/evaluator_functions.zig");
const heap = @import("storage/heap.zig");

test "substring function basic" {
    const allocator = testing.allocator;

    // substring('hello world', 1, 5) - SQL uses 1-based indexing
    const str = heap.Value{ .Str = "hello world" };
    const start = heap.Value{ .Int = 1 }; // 1-based index
    const len = heap.Value{ .Int = 5 };

    const result = try evaluator_functions.substring(allocator, str, start, len);
    defer allocator.free(result.Text);
    try testing.expect(result == .Text);
    try testing.expectEqualStrings("hello", result.Text);
}

test "substring function with out of bounds" {
    const allocator = testing.allocator;

    // substring('test', 10, 5) - should return empty
    const str = heap.Value{ .Str = "test" };
    const start = heap.Value{ .Int = 10 };
    const len = heap.Value{ .Int = 5 };

    const result = try evaluator_functions.substring(allocator, str, start, len);
    defer allocator.free(result.Text);
    try testing.expect(result == .Text);
    try testing.expectEqualStrings("", result.Text);
}

test "replace function" {
    const allocator = testing.allocator;

    // replace('hello world', 'world', 'geode')
    const str = heap.Value{ .Str = "hello world" };
    const search = heap.Value{ .Str = "world" };
    const replacement = heap.Value{ .Str = "geode" };

    const result = try evaluator_functions.replace(allocator, str, search, replacement);
    defer allocator.free(result.Text);
    try testing.expect(result == .Text);
    try testing.expectEqualStrings("hello geode", result.Text);
}

test "trim function" {
    const allocator = testing.allocator;

    // trim('  hello  ')
    const str = heap.Value{ .Str = "  hello  " };

    const result = try evaluator_functions.trim(allocator, str);
    defer allocator.free(result.Text);
    try testing.expect(result == .Text);
    try testing.expectEqualStrings("hello", result.Text);
}

test "upper function" {
    const allocator = testing.allocator;

    // upper('hello World')
    const str = heap.Value{ .Str = "hello World" };

    const result = try evaluator_functions.upper(allocator, str);
    defer allocator.free(result.Text);
    try testing.expect(result == .Text);
    try testing.expectEqualStrings("HELLO WORLD", result.Text);
}

test "lower function" {
    const allocator = testing.allocator;

    // lower('HELLO World')
    const str = heap.Value{ .Str = "HELLO World" };

    const result = try evaluator_functions.lower(allocator, str);
    defer allocator.free(result.Text);
    try testing.expect(result == .Text);
    try testing.expectEqualStrings("hello world", result.Text);
}

test "length_chars function" {
    const str = heap.Value{ .Str = "hello world" };

    const result = try evaluator_functions.length_chars(str);
    try testing.expect(result == .Int);
    try testing.expectEqual(@as(i64, 11), result.Int);
}

test "string function with empty string" {
    const allocator = testing.allocator;

    const empty = heap.Value{ .Str = "" };

    // Test length of empty string
    const len_result = try evaluator_functions.length_chars(empty);
    try testing.expect(len_result == .Int);
    try testing.expectEqual(@as(i64, 0), len_result.Int);

    // Test trim of empty string
    const trim_result = try evaluator_functions.trim(allocator, empty);
    defer allocator.free(trim_result.Text);
    try testing.expect(trim_result == .Text);
    try testing.expectEqualStrings("", trim_result.Text);
}

test "substring without length parameter" {
    const allocator = testing.allocator;

    // substring('hello world', 7) - should return 'world' (1-based indexing)
    const str = heap.Value{ .Str = "hello world" };
    const start = heap.Value{ .Int = 7 }; // Position 7 is 'w' in 1-based indexing

    const result = try evaluator_functions.substring(allocator, str, start, null);
    defer allocator.free(result.Text);
    try testing.expect(result == .Text);
    try testing.expectEqualStrings("world", result.Text);
}
