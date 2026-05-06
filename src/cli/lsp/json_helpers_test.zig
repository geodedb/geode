// LSP JSON Helpers tests
// Covers LSP-SEC-003 (depth-bomb guard) and LSP-SEC-004/Q-Sev1 (safe accessors).
//
// CANARY: REQ=REQ-LSP-SEC-003; FEATURE="JsonDepthGuard"; ASPECT=DoSGuard; STATUS=TESTED; OWNER=lsp; UPDATED=2026-05-06
// CANARY: REQ=REQ-LSP-SEC-004; FEATURE="JsonHelpers"; ASPECT=SafeUnwrap; STATUS=TESTED; OWNER=lsp; UPDATED=2026-05-06

const std = @import("std");
const testing = std.testing;
const json_helpers = @import("json_helpers.zig");

// =============================================================================
// LSP-SEC-003: Depth and size guards
// =============================================================================

test "LSP-SEC-003: deeply nested objects (200 levels) rejected" {
    const allocator = testing.allocator;
    var buf = try std.ArrayList(u8).initCapacity(allocator, 512);
    defer buf.deinit(allocator);
    var i: usize = 0;
    while (i < 200) : (i += 1) try buf.append(allocator, '{');
    while (i > 0) : (i -= 1) try buf.append(allocator, '}');

    try testing.expectError(json_helpers.JsonError.JsonTooDeep, json_helpers.checkJsonDepth(buf.items));
}

test "LSP-SEC-003: deeply nested arrays (200 levels) rejected" {
    const allocator = testing.allocator;
    var buf = try std.ArrayList(u8).initCapacity(allocator, 512);
    defer buf.deinit(allocator);
    var i: usize = 0;
    while (i < 200) : (i += 1) try buf.append(allocator, '[');
    while (i > 0) : (i -= 1) try buf.append(allocator, ']');

    try testing.expectError(json_helpers.JsonError.JsonTooDeep, json_helpers.checkJsonDepth(buf.items));
}

test "LSP-SEC-003: nesting at exactly MAX_JSON_DEPTH is accepted" {
    const allocator = testing.allocator;
    var buf = try std.ArrayList(u8).initCapacity(allocator, 256);
    defer buf.deinit(allocator);
    var i: usize = 0;
    while (i < json_helpers.MAX_JSON_DEPTH) : (i += 1) try buf.append(allocator, '{');
    while (i > 0) : (i -= 1) try buf.append(allocator, '}');

    try json_helpers.checkJsonDepth(buf.items);
}

test "LSP-SEC-003: nesting one above MAX_JSON_DEPTH rejected" {
    const allocator = testing.allocator;
    var buf = try std.ArrayList(u8).initCapacity(allocator, 256);
    defer buf.deinit(allocator);
    var i: usize = 0;
    while (i < json_helpers.MAX_JSON_DEPTH + 1) : (i += 1) try buf.append(allocator, '{');
    while (i > 0) : (i -= 1) try buf.append(allocator, '}');

    try testing.expectError(json_helpers.JsonError.JsonTooDeep, json_helpers.checkJsonDepth(buf.items));
}

test "LSP-SEC-003: typical LSP initialize payload (~6 levels) accepted" {
    const init_msg =
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{"textDocument":{"hover":{"dynamicRegistration":true}}}}}
    ;
    try json_helpers.checkJsonDepth(init_msg);
}

test "LSP-SEC-003: braces inside string literals do not inflate depth" {
    // 70 `{` chars inside a JSON string. Without the in-string skip
    // logic, this would falsely trigger JsonTooDeep at the 65th open
    // brace.
    const payload =
        \\{"value":"{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{{"}
    ;
    try json_helpers.checkJsonDepth(payload);
}

test "LSP-SEC-003: escaped quote inside string preserves in-string state" {
    // Verifies that `\"` does not exit the string scanner; if it did,
    // the trailing `[[[[[`-style depth would become real and trigger
    // a false negative for valid JSON.
    const payload =
        \\{"a":"escaped \"quote\" here {{{{","b":1}
    ;
    try json_helpers.checkJsonDepth(payload);
}

test "LSP-SEC-003: payload above MAX_JSON_PAYLOAD rejected" {
    const allocator = testing.allocator;
    const oversized_len = json_helpers.MAX_JSON_PAYLOAD + 1;
    const buf = try allocator.alloc(u8, oversized_len);
    defer allocator.free(buf);
    @memset(buf, ' ');
    try testing.expectError(json_helpers.JsonError.JsonTooLarge, json_helpers.checkJsonDepth(buf));
}

test "LSP-SEC-003: empty payload accepted" {
    try json_helpers.checkJsonDepth("");
}

test "LSP-SEC-003: non-JSON garbage is depth-safe (non-bracket chars do not bump)" {
    try json_helpers.checkJsonDepth("not_json_but_under_limit");
}

// =============================================================================
// LSP-SEC-004 / Q-Sev1: safe accessors return InvalidParams on bad shape
// =============================================================================

fn parse(allocator: std.mem.Allocator, src: []const u8) !std.json.Parsed(std.json.Value) {
    return std.json.parseFromSlice(std.json.Value, allocator, src, .{});
}

test "LSP-SEC-004: getObject on missing key returns InvalidParams" {
    const allocator = testing.allocator;
    var p = try parse(allocator, "{\"a\":1}");
    defer p.deinit();
    try testing.expectError(json_helpers.JsonError.InvalidParams, json_helpers.getObject(p.value, "missing"));
}

test "LSP-SEC-004: getObject on non-object value returns InvalidParams" {
    const allocator = testing.allocator;
    var p = try parse(allocator, "{\"a\":1}");
    defer p.deinit();
    try testing.expectError(json_helpers.JsonError.InvalidParams, json_helpers.getObject(p.value, "a"));
}

test "LSP-SEC-004: getObject on present object key succeeds" {
    const allocator = testing.allocator;
    var p = try parse(allocator, "{\"x\":{\"y\":2}}");
    defer p.deinit();
    const inner = try json_helpers.getObject(p.value, "x");
    const v = inner.get("y") orelse return error.TestUnexpectedNull;
    try testing.expectEqual(@as(i64, 2), v.integer);
}

test "LSP-SEC-004: getString on missing key returns InvalidParams" {
    const allocator = testing.allocator;
    var p = try parse(allocator, "{\"a\":1}");
    defer p.deinit();
    try testing.expectError(json_helpers.JsonError.InvalidParams, json_helpers.getString(p.value.object, "missing"));
}

test "LSP-SEC-004: getString on integer value returns InvalidParams" {
    const allocator = testing.allocator;
    var p = try parse(allocator, "{\"a\":1}");
    defer p.deinit();
    try testing.expectError(json_helpers.JsonError.InvalidParams, json_helpers.getString(p.value.object, "a"));
}

test "LSP-SEC-004: getString on present string returns the slice" {
    const allocator = testing.allocator;
    var p = try parse(allocator, "{\"a\":\"hello\"}");
    defer p.deinit();
    const s = try json_helpers.getString(p.value.object, "a");
    try testing.expectEqualStrings("hello", s);
}

test "LSP-SEC-004: getInteger on missing key returns InvalidParams" {
    const allocator = testing.allocator;
    var p = try parse(allocator, "{\"a\":\"x\"}");
    defer p.deinit();
    try testing.expectError(json_helpers.JsonError.InvalidParams, json_helpers.getInteger(p.value.object, "b"));
}

test "LSP-SEC-004: getInteger on string value returns InvalidParams" {
    const allocator = testing.allocator;
    var p = try parse(allocator, "{\"a\":\"x\"}");
    defer p.deinit();
    try testing.expectError(json_helpers.JsonError.InvalidParams, json_helpers.getInteger(p.value.object, "a"));
}

test "LSP-SEC-004: getInteger on integer value returns it" {
    const allocator = testing.allocator;
    var p = try parse(allocator, "{\"a\":42}");
    defer p.deinit();
    const v = try json_helpers.getInteger(p.value.object, "a");
    try testing.expectEqual(@as(i64, 42), v);
}

test "LSP-SEC-004: getOptionalString on missing key returns null" {
    const allocator = testing.allocator;
    var p = try parse(allocator, "{\"a\":1}");
    defer p.deinit();
    const v = try json_helpers.getOptionalString(p.value.object, "missing");
    try testing.expect(v == null);
}

test "LSP-SEC-004: getOptionalString on json-null returns null" {
    const allocator = testing.allocator;
    var p = try parse(allocator, "{\"a\":null}");
    defer p.deinit();
    const v = try json_helpers.getOptionalString(p.value.object, "a");
    try testing.expect(v == null);
}

test "LSP-SEC-004: getOptionalString on integer returns InvalidParams" {
    const allocator = testing.allocator;
    var p = try parse(allocator, "{\"a\":1}");
    defer p.deinit();
    try testing.expectError(json_helpers.JsonError.InvalidParams, json_helpers.getOptionalString(p.value.object, "a"));
}

test "LSP-SEC-004: castI32 within bounds succeeds" {
    try testing.expectEqual(@as(i32, 42), try json_helpers.castI32(42));
    try testing.expectEqual(@as(i32, -1), try json_helpers.castI32(-1));
}

test "LSP-SEC-004: castI32 above i32 max returns InvalidParams" {
    try testing.expectError(json_helpers.JsonError.InvalidParams, json_helpers.castI32(@as(i64, std.math.maxInt(i32)) + 1));
}

test "LSP-SEC-004: castU32 negative returns InvalidParams" {
    try testing.expectError(json_helpers.JsonError.InvalidParams, json_helpers.castU32(-1));
}

test "LSP-SEC-004: castU32 within bounds succeeds" {
    try testing.expectEqual(@as(u32, 42), try json_helpers.castU32(42));
}
