// MCP input-guards tests
// Covers LSP-SEC-007 (1 MiB cap on every MCP tool query) and GAP-0819
// (chokepoint validator: length, UTF-8, embedded NUL, nested-comment
// depth).
//
// CANARY: REQ=REQ-MCP-SEC-007; FEATURE="QueryLengthCap"; ASPECT=DoSGuard; STATUS=TESTED; OWNER=mcp; UPDATED=2026-05-06
// CANARY: REQ=REQ-MCP-GAP-0819; FEATURE="GqlInputChokepoint"; ASPECT=Sanitization; STATUS=TESTED; OWNER=mcp; UPDATED=2026-05-06

const std = @import("std");
const testing = std.testing;
// Cross-tree access via named module wired by build.zig. The module
// `mcp_input_guards` resolves to src/mcp/input_guards.zig.
const input_guards = @import("mcp_input_guards");

// =============================================================================
// LSP-SEC-007: Length cap
// =============================================================================

test "LSP-SEC-007: rejectIfOversized accepts 50 KiB query" {
    const allocator = testing.allocator;
    const buf = try allocator.alloc(u8, 50 * 1024);
    defer allocator.free(buf);
    @memset(buf, 'a');
    const out = try input_guards.rejectIfOversized(buf);
    try testing.expectEqual(buf.len, out.len);
}

test "LSP-SEC-007: rejectIfOversized accepts at exactly 1 MiB" {
    const allocator = testing.allocator;
    const buf = try allocator.alloc(u8, input_guards.MAX_GQL_TEXT);
    defer allocator.free(buf);
    @memset(buf, 'a');
    _ = try input_guards.rejectIfOversized(buf);
}

test "LSP-SEC-007: rejectIfOversized rejects 1 MiB + 1 byte" {
    const allocator = testing.allocator;
    const buf = try allocator.alloc(u8, input_guards.MAX_GQL_TEXT + 1);
    defer allocator.free(buf);
    @memset(buf, 'a');
    try testing.expectError(input_guards.InputError.QueryTooLarge, input_guards.rejectIfOversized(buf));
}

test "LSP-SEC-007: rejectIfOversized rejects 1.5 MiB" {
    const allocator = testing.allocator;
    const buf = try allocator.alloc(u8, input_guards.MAX_GQL_TEXT + 512 * 1024);
    defer allocator.free(buf);
    @memset(buf, 'a');
    try testing.expectError(input_guards.InputError.QueryTooLarge, input_guards.rejectIfOversized(buf));
}

test "LSP-SEC-007: MAX_GQL_TEXT constant is 1 MiB" {
    try testing.expectEqual(@as(usize, 1024 * 1024), input_guards.MAX_GQL_TEXT);
}

// =============================================================================
// GAP-0819: Chokepoint validator
// =============================================================================

test "GAP-0819: validate rejects empty query" {
    try testing.expectError(input_guards.InputError.QueryEmpty, input_guards.validateAndSanitizeGqlInput(""));
}

test "GAP-0819: validate accepts simple query" {
    const out = try input_guards.validateAndSanitizeGqlInput("MATCH (n) RETURN n");
    try testing.expectEqualStrings("MATCH (n) RETURN n", out);
}

test "GAP-0819: validate accepts UTF-8 multibyte string literal" {
    const out = try input_guards.validateAndSanitizeGqlInput("RETURN 'héllo wörld' AS greeting");
    try testing.expect(out.len > 0);
}

test "GAP-0819: validate rejects invalid UTF-8" {
    // 0x80 is a continuation byte without a valid lead byte → invalid UTF-8.
    const bad = [_]u8{ 'M', 'A', 'T', 'C', 'H', 0x80, 0xff };
    try testing.expectError(input_guards.InputError.InvalidUtf8, input_guards.validateAndSanitizeGqlInput(&bad));
}

test "GAP-0819: validate rejects embedded NUL" {
    const with_nul = [_]u8{ 'R', 'E', 'T', 'U', 'R', 'N', 0, '1' };
    try testing.expectError(input_guards.InputError.EmbeddedNul, input_guards.validateAndSanitizeGqlInput(&with_nul));
}

test "GAP-0819: validate rejects 1.5 MiB payload" {
    const allocator = testing.allocator;
    const buf = try allocator.alloc(u8, input_guards.MAX_GQL_TEXT + 512 * 1024);
    defer allocator.free(buf);
    @memset(buf, 'a');
    try testing.expectError(input_guards.InputError.QueryTooLarge, input_guards.validateAndSanitizeGqlInput(buf));
}

test "GAP-0819: validate rejects deeply nested comments" {
    const allocator = testing.allocator;
    var buf = try std.ArrayList(u8).initCapacity(allocator, 512);
    defer buf.deinit(allocator);
    var i: usize = 0;
    while (i < input_guards.MAX_COMMENT_NEST + 5) : (i += 1) {
        try buf.appendSlice(allocator, "/*");
    }
    try buf.appendSlice(allocator, " RETURN 1 ");
    while (i > 0) : (i -= 1) {
        try buf.appendSlice(allocator, "*/");
    }
    try testing.expectError(input_guards.InputError.NestedCommentTooDeep, input_guards.validateAndSanitizeGqlInput(buf.items));
}

test "GAP-0819: validate accepts shallow nested comments (2 deep)" {
    const out = try input_guards.validateAndSanitizeGqlInput("/* outer /* inner */ */ RETURN 1");
    try testing.expect(out.len > 0);
}

test "GAP-0819: validate ignores comment-like sequences inside strings" {
    // Inside a string literal, /* and */ are just bytes — must not
    // affect depth counting.
    const out = try input_guards.validateAndSanitizeGqlInput("RETURN '/*/*/*/*/*/*' AS x");
    try testing.expect(out.len > 0);
}

test "GAP-0819: validate accepts query with trailing whitespace" {
    const out = try input_guards.validateAndSanitizeGqlInput("RETURN 1\n\n  ");
    try testing.expect(out.len > 0);
}

test "GAP-0819: validate accepts queries up to MAX_GQL_TEXT" {
    const allocator = testing.allocator;
    const buf = try allocator.alloc(u8, input_guards.MAX_GQL_TEXT);
    defer allocator.free(buf);
    // Fill with a valid pattern (just spaces, which are valid UTF-8 ASCII).
    @memset(buf, ' ');
    // Replace start with valid GQL so non-empty + non-NUL is preserved.
    @memcpy(buf[0..10], "RETURN 1; ");
    _ = try input_guards.validateAndSanitizeGqlInput(buf);
}
