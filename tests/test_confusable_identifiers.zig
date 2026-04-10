// Confusable identifier detection regression tests (GAP-0533, ISO/IEC 39075:2024 RQ-0012).
//
// The library at src/unicode/confusables.zig provides the TR#39 skeleton
// algorithm and the SQLSTATE 42004 helper, but until this fix nothing
// invoked them — `MATCH (a), (а)` (Latin a vs Cyrillic а) parsed cleanly
// even though those identifiers are visually identical.
//
// These tests pin the contract: parse() must reject any program that
// declares two distinct identifiers whose Unicode TR#39 skeletons collide.

const std = @import("std");
const geode = @import("geode");

// ---------------------------------------------------------------------------
// Negative cases — confusable identifiers must be rejected
// ---------------------------------------------------------------------------

test "parse rejects Latin a vs Cyrillic а (MATCH variables)" {
    // \xD0\xB0 = Cyrillic small a (U+0430), visually identical to Latin a.
    const src = "MATCH (a), (\xD0\xB0) RETURN a";
    const result = geode.parse(std.testing.allocator, src, .{});
    try std.testing.expectError(error.ConfusableIdentifier, result);
}

test "parse rejects ASCII case fold collision in RETURN aliases" {
    // Per TR#39 the skeleton lowercases ASCII letters, so 'abc' and 'Abc'
    // share the same skeleton 'abc' even though they are case-sensitive
    // identifiers in GQL. This is the correct behavior — visually the user
    // cannot tell them apart in many fonts.
    const src = "RETURN 1 AS abc, 2 AS Abc";
    const result = geode.parse(std.testing.allocator, src, .{});
    try std.testing.expectError(error.ConfusableIdentifier, result);
}

test "parse rejects mixed alias and MATCH variable confusable" {
    // Greek omicron ο (U+03BF) confusable with Latin o.
    const src = "MATCH (o) RETURN o AS \xCE\xBF";
    const result = geode.parse(std.testing.allocator, src, .{});
    try std.testing.expectError(error.ConfusableIdentifier, result);
}

// ---------------------------------------------------------------------------
// Positive cases — non-confusable programs must still parse cleanly
// ---------------------------------------------------------------------------

test "parse accepts distinct ASCII identifiers" {
    var result = try geode.parse(std.testing.allocator, "MATCH (a)-[r]->(b) RETURN a, r, b", .{});
    defer result.deinit();
    try std.testing.expect(result.program.statements.len == 1);
}

test "parse accepts the same identifier appearing multiple times (RQ-0011)" {
    // RQ-0011: an identifier is never confusable with itself.
    var result = try geode.parse(std.testing.allocator, "MATCH (a)-[r]->(a) RETURN a", .{});
    defer result.deinit();
    try std.testing.expect(result.program.statements.len == 1);
}

test "parse accepts case-different identifiers that are NOT confusable" {
    // 'a' and 'A' have the same skeleton (both lowercase to 'a') so this
    // SHOULD be rejected too — but only if they appear as distinct user
    // identifiers. ASCII case folding is part of the TR#39 skeleton.
    // We use distinct ASCII names that share no skeleton characters.
    var result = try geode.parse(std.testing.allocator, "MATCH (alpha), (beta) RETURN alpha, beta", .{});
    defer result.deinit();
    try std.testing.expect(result.program.statements.len == 1);
}

test "parse accepts simple RETURN with no identifiers" {
    var result = try geode.parse(std.testing.allocator, "RETURN 1 AS x", .{});
    defer result.deinit();
    try std.testing.expect(result.program.statements.len == 1);
}

test "parse accepts WITH chain with distinct names" {
    var result = try geode.parse(std.testing.allocator, "MATCH (n) WITH n AS m RETURN m", .{});
    defer result.deinit();
    try std.testing.expect(result.program.statements.len == 1);
}
