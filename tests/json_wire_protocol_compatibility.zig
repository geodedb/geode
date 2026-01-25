const std = @import("std");
const testing = std.testing;
const json = @import("json");

// CANARY: REQ=REQ-LIB-MIGRATION-JSON-COMPAT-001; FEATURE="JSON Library Migration"; ASPECT=WireProtocolCompatibility; STATUS=TESTED; OWNER=protocol; UPDATED=2026-01-24
// Wire protocol compatibility tests for JSON library migration Phase 6
// These tests validate that migrated JSON encoding produces semantically correct output

const protocol = @import("geode").protocol;

/// Required fields for SCHEMA response
const SCHEMA_REQUIRED_FIELDS = [_][]const u8{ "status_class", "result" };
const SCHEMA_RESULT_REQUIRED = [_][]const u8{ "type", "columns" };

/// Required fields for BINDINGS response
const BINDINGS_REQUIRED_FIELDS = [_][]const u8{ "status_class", "result" };
const BINDINGS_RESULT_REQUIRED = [_][]const u8{ "type", "ordered", "rows", "final" };

/// Required fields for ERROR response
const ERROR_REQUIRED_FIELDS = [_][]const u8{ "status_class", "result" };
const ERROR_RESULT_REQUIRED = [_][]const u8{ "type", "code", "message" };

/// Helper to check if JSON object has a field
fn hasField(obj: std.json.ObjectMap, name: []const u8) bool {
    return obj.get(name) != null;
}

/// Helper to validate all required fields are present
fn validateRequiredFields(obj: std.json.ObjectMap, required: []const []const u8) !void {
    for (required) |field| {
        if (!hasField(obj, field)) {
            std.debug.print("Missing required field: {s}\n", .{field});
            return error.MissingRequiredField;
        }
    }
}

/// Helper to get nested object
fn getNestedObject(obj: std.json.ObjectMap, key: []const u8) !std.json.ObjectMap {
    const val = obj.get(key) orelse return error.MissingKey;
    if (val != .object) return error.NotAnObject;
    return val.object;
}

test "wire protocol: SCHEMA frame JSON structure" {
    const allocator = testing.allocator;

    // Build a schema frame
    const cols = [_]protocol.SchemaCol{
        .{ .name = "id", .type = "INTEGER" },
        .{ .name = "name", .type = "STRING" },
    };

    const output = try protocol.buildSchemaLine(allocator, &cols, &.{}, &.{});
    defer allocator.free(output);

    // Parse and validate JSON structure
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, output, .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    // Validate top-level required fields
    try validateRequiredFields(root, &SCHEMA_REQUIRED_FIELDS);

    // Validate result object
    const result = try getNestedObject(root, "result");
    try validateRequiredFields(result, &SCHEMA_RESULT_REQUIRED);

    // Validate type field value
    const type_val = result.get("type") orelse return error.MissingType;
    try testing.expectEqualStrings("SCHEMA", type_val.string);

    // Validate columns array
    const columns_val = result.get("columns") orelse return error.MissingColumns;
    try testing.expect(columns_val == .array);
    try testing.expectEqual(@as(usize, 2), columns_val.array.items.len);

    // Validate first column structure
    const first_col = columns_val.array.items[0];
    try testing.expect(first_col == .object);
    try testing.expect(hasField(first_col.object, "name"));
    try testing.expect(hasField(first_col.object, "type"));
}

test "wire protocol: BINDINGS frame JSON structure" {
    const allocator = testing.allocator;

    // Build a bindings frame with sample row data
    const rows_json = "[{\"id\":1,\"name\":\"Alice\"}]";
    const output = try protocol.buildBindingsLine(allocator, false, &.{}, rows_json, true, &.{}, &.{});
    defer allocator.free(output);

    // Parse and validate JSON structure
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, output, .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    // Validate top-level required fields
    try validateRequiredFields(root, &BINDINGS_REQUIRED_FIELDS);

    // Validate result object
    const result = try getNestedObject(root, "result");
    try validateRequiredFields(result, &BINDINGS_RESULT_REQUIRED);

    // Validate type field value
    const type_val = result.get("type") orelse return error.MissingType;
    try testing.expectEqualStrings("BINDINGS", type_val.string);

    // Validate final field is boolean true
    const final_val = result.get("final") orelse return error.MissingFinal;
    try testing.expect(final_val == .bool);
    try testing.expect(final_val.bool == true);

    // Validate rows is an array with one element
    const rows_val = result.get("rows") orelse return error.MissingRows;
    try testing.expect(rows_val == .array);
    try testing.expectEqual(@as(usize, 1), rows_val.array.items.len);
}

test "wire protocol: ERROR frame JSON structure" {
    const allocator = testing.allocator;

    // Build an error frame
    const output = try protocol.buildErrorLine(allocator, "42000", "Syntax error", "SELECT * FORM table");
    defer allocator.free(output);

    // Parse and validate JSON structure
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, output, .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    // Validate top-level required fields
    try validateRequiredFields(root, &ERROR_REQUIRED_FIELDS);

    // Validate result object
    const result = try getNestedObject(root, "result");
    try validateRequiredFields(result, &ERROR_RESULT_REQUIRED);

    // Validate type field value
    const type_val = result.get("type") orelse return error.MissingType;
    try testing.expectEqualStrings("ERROR", type_val.string);

    // Validate error code
    const code_val = result.get("code") orelse return error.MissingCode;
    try testing.expectEqualStrings("42000", code_val.string);

    // Validate error message
    const message_val = result.get("message") orelse return error.MissingMessage;
    try testing.expectEqualStrings("Syntax error", message_val.string);
}

test "wire protocol: EXPLAIN frame JSON structure" {
    const allocator = testing.allocator;

    // Build an explain frame
    const explain_json = "{\"plan\":\"TableScan\",\"cost\":100}";
    const output = try protocol.buildExplainLine(allocator, explain_json, &.{});
    defer allocator.free(output);

    // Parse and validate JSON structure
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, output, .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    // Validate top-level structure
    try testing.expect(hasField(root, "status_class"));
    try testing.expect(hasField(root, "result"));

    // Validate result object has type EXPLAIN
    const result = try getNestedObject(root, "result");
    const type_val = result.get("type") orelse return error.MissingType;
    try testing.expectEqualStrings("EXPLAIN", type_val.string);

    // Validate json payload is embedded
    try testing.expect(hasField(result, "json"));
}

test "wire protocol: PROFILE frame JSON structure" {
    const allocator = testing.allocator;

    // Build a profile frame
    const profile_json = "{\"ops\":[],\"total_time_ns\":1000}";
    const output = try protocol.buildProfileLine(allocator, profile_json, &.{});
    defer allocator.free(output);

    // Parse and validate JSON structure
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, output, .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    // Validate top-level structure
    try testing.expect(hasField(root, "status_class"));
    try testing.expect(hasField(root, "result"));

    // Validate result object has type PROFILE
    const result = try getNestedObject(root, "result");
    const type_val = result.get("type") orelse return error.MissingType;
    try testing.expectEqualStrings("PROFILE", type_val.string);

    // Validate json payload is embedded
    try testing.expect(hasField(result, "json"));
}

test "wire protocol: CDC_CONTROL frame JSON structure" {
    const allocator = testing.allocator;

    // Build a CDC control frame
    const output = try protocol.buildCdcControlLine(allocator, "start", "ok", 12345);
    defer allocator.free(output);

    // Parse and validate JSON structure
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, output, .{});
    defer parsed.deinit();

    const root = parsed.value.object;

    // Validate top-level structure
    try testing.expect(hasField(root, "status_class"));
    try testing.expect(hasField(root, "result"));

    // Validate result object
    const result = try getNestedObject(root, "result");
    const type_val = result.get("type") orelse return error.MissingType;
    try testing.expectEqualStrings("CDC_CONTROL", type_val.string);

    // Validate CDC-specific fields
    try testing.expect(hasField(result, "action"));
    try testing.expect(hasField(result, "status"));
    try testing.expect(hasField(result, "guardrail_epoch"));
}

test "wire protocol: JSON output is valid RFC 8259" {
    const allocator = testing.allocator;

    // Test various frame types produce valid JSON
    const test_cases = [_]struct { name: []const u8, json: []const u8 }{
        .{ .name = "schema", .json = try protocol.buildSchemaLine(allocator, &.{}, &.{}, &.{}) },
        .{ .name = "bindings", .json = try protocol.buildBindingsLine(allocator, false, &.{}, "[]", true, &.{}, &.{}) },
        .{ .name = "error", .json = try protocol.buildErrorLine(allocator, "00000", "OK", "") },
    };
    defer for (test_cases) |tc| allocator.free(tc.json);

    for (test_cases) |tc| {
        // Validate each output parses as valid JSON
        var parsed = std.json.parseFromSlice(std.json.Value, allocator, tc.json, .{}) catch |err| {
            std.debug.print("Failed to parse {s} frame as JSON: {any}\n", .{ tc.name, err });
            return err;
        };
        parsed.deinit();
    }
}

test "wire protocol: special character escaping" {
    const allocator = testing.allocator;

    // Test that special characters are properly escaped
    const special_message = "Error with \"quotes\" and \\backslash and\nnewline";
    const output = try protocol.buildErrorLine(allocator, "42000", special_message, "");
    defer allocator.free(output);

    // Should parse without error (proper escaping)
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, output, .{});
    defer parsed.deinit();

    // Verify the message was preserved correctly
    const result = try getNestedObject(parsed.value.object, "result");
    const message_val = result.get("message") orelse return error.MissingMessage;
    try testing.expectEqualStrings(special_message, message_val.string);
}

test "wire protocol: Unicode handling" {
    const allocator = testing.allocator;

    // Test Unicode characters in messages
    const unicode_message = "Error: \u{4e2d}\u{6587} \u{1f600} \u{00e9}";
    const output = try protocol.buildErrorLine(allocator, "42000", unicode_message, "");
    defer allocator.free(output);

    // Should parse without error
    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, output, .{});
    defer parsed.deinit();

    // Verify Unicode was preserved
    const result = try getNestedObject(parsed.value.object, "result");
    const message_val = result.get("message") orelse return error.MissingMessage;
    try testing.expectEqualStrings(unicode_message, message_val.string);
}

test "wire protocol: empty arrays and objects" {
    const allocator = testing.allocator;

    // Test empty columns array
    const output = try protocol.buildSchemaLine(allocator, &.{}, &.{}, &.{});
    defer allocator.free(output);

    var parsed = try std.json.parseFromSlice(std.json.Value, allocator, output, .{});
    defer parsed.deinit();

    const result = try getNestedObject(parsed.value.object, "result");
    const columns_val = result.get("columns") orelse return error.MissingColumns;
    try testing.expect(columns_val == .array);
    try testing.expectEqual(@as(usize, 0), columns_val.array.items.len);
}
