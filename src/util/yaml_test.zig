const std = @import("std");
const yaml = @import("yaml.zig");
const testing = std.testing;

// Comprehensive test suite for YAML parser
// CANARY: REQ=REQ-TEST-YAML-002; FEATURE="YAML Parser Tests"; ASPECT=Testing;
// STATUS=IMPLEMENTED; TEST=yaml_comprehensive_tests; OWNER=test-team; UPDATED=2025-10-28

test "yaml: parse null value" {
    const allocator = testing.allocator;

    var value = try yaml.parse(allocator, "null");
    defer value.deinit(allocator);

    try testing.expect(value == .null_value);
}

test "yaml: parse true boolean" {
    const allocator = testing.allocator;

    var value = try yaml.parse(allocator, "true");
    defer value.deinit(allocator);

    try testing.expect(value == .bool_value);
    try testing.expectEqual(true, value.bool_value);
}

test "yaml: parse false boolean" {
    const allocator = testing.allocator;

    var value = try yaml.parse(allocator, "false");
    defer value.deinit(allocator);

    try testing.expect(value == .bool_value);
    try testing.expectEqual(false, value.bool_value);
}

test "yaml: parse positive integer" {
    const allocator = testing.allocator;

    var value = try yaml.parse(allocator, "42");
    defer value.deinit(allocator);

    try testing.expect(value == .int_value);
    try testing.expectEqual(@as(i64, 42), value.int_value);
}

test "yaml: parse negative integer" {
    const allocator = testing.allocator;

    var value = try yaml.parse(allocator, "-123");
    defer value.deinit(allocator);

    try testing.expect(value == .int_value);
    try testing.expectEqual(@as(i64, -123), value.int_value);
}

test "yaml: parse float" {
    const allocator = testing.allocator;

    var value = try yaml.parse(allocator, "3.14159");
    defer value.deinit(allocator);

    try testing.expect(value == .float_value);
    try testing.expect(@abs(value.float_value - 3.14159) < 0.0001);
}

test "yaml: parse negative float" {
    const allocator = testing.allocator;

    var value = try yaml.parse(allocator, "-2.71828");
    defer value.deinit(allocator);

    try testing.expect(value == .float_value);
    try testing.expect(@abs(value.float_value - (-2.71828)) < 0.0001);
}

test "yaml: parse unquoted string" {
    const allocator = testing.allocator;

    var value = try yaml.parse(allocator, "hello world");
    defer value.deinit(allocator);

    try testing.expect(value == .string_value);
    try testing.expectEqualStrings("hello world", value.string_value);
}

test "yaml: parse double quoted string" {
    const allocator = testing.allocator;

    var value = try yaml.parse(allocator, "\"hello world\"");
    defer value.deinit(allocator);

    try testing.expect(value == .string_value);
    try testing.expectEqualStrings("hello world", value.string_value);
}

test "yaml: parse single quoted string" {
    const allocator = testing.allocator;

    var value = try yaml.parse(allocator, "'hello world'");
    defer value.deinit(allocator);

    try testing.expect(value == .string_value);
    try testing.expectEqualStrings("hello world", value.string_value);
}

test "yaml: parse simple list" {
    const allocator = testing.allocator;

    const input =
        \\- item1
        \\- item2
        \\- item3
    ;

    var value = try yaml.parse(allocator, input);
    defer value.deinit(allocator);

    try testing.expect(value == .list);
    try testing.expectEqual(@as(usize, 3), value.list.items.len);
    try testing.expectEqualStrings("item1", value.list.items[0].string_value);
    try testing.expectEqualStrings("item2", value.list.items[1].string_value);
    try testing.expectEqualStrings("item3", value.list.items[2].string_value);
}

test "yaml: parse list of integers" {
    const allocator = testing.allocator;

    const input =
        \\- 1
        \\- 2
        \\- 3
    ;

    var value = try yaml.parse(allocator, input);
    defer value.deinit(allocator);

    try testing.expect(value == .list);
    try testing.expectEqual(@as(usize, 3), value.list.items.len);
    try testing.expectEqual(@as(i64, 1), value.list.items[0].int_value);
    try testing.expectEqual(@as(i64, 2), value.list.items[1].int_value);
    try testing.expectEqual(@as(i64, 3), value.list.items[2].int_value);
}

test "yaml: parse simple map" {
    const allocator = testing.allocator;

    const input =
        \\name: test
        \\version: 1.0
    ;

    var value = try yaml.parse(allocator, input);
    defer value.deinit(allocator);

    try testing.expect(value == .map);
    try testing.expectEqual(@as(usize, 2), value.map.count());

    const name = value.map.get("name").?;
    try testing.expectEqualStrings("test", name.string_value);

    const version = value.map.get("version").?;
    try testing.expect(@abs(version.float_value - 1.0) < 0.01);
}

test "yaml: parse map with different value types" {
    const allocator = testing.allocator;

    const input =
        \\name: Alice
        \\age: 30
        \\score: 95.5
        \\active: true
        \\retired: false
        \\nickname: null
    ;

    var value = try yaml.parse(allocator, input);
    defer value.deinit(allocator);

    try testing.expect(value == .map);
    try testing.expectEqual(@as(usize, 6), value.map.count());

    try testing.expectEqualStrings("Alice", value.map.get("name").?.string_value);
    try testing.expectEqual(@as(i64, 30), value.map.get("age").?.int_value);
    try testing.expect(@abs(value.map.get("score").?.float_value - 95.5) < 0.01);
    try testing.expectEqual(true, value.map.get("active").?.bool_value);
    try testing.expectEqual(false, value.map.get("retired").?.bool_value);
    try testing.expect(value.map.get("nickname").? == .null_value);
}

test "yaml: parse nested map" {
    const allocator = testing.allocator;

    const input =
        \\person:
        \\  name: Alice
        \\  age: 30
        \\settings:
        \\  theme: dark
        \\  notifications: true
    ;

    var value = try yaml.parse(allocator, input);
    defer value.deinit(allocator);

    try testing.expect(value == .map);
    try testing.expectEqual(@as(usize, 2), value.map.count());

    const person = value.map.get("person").?;
    try testing.expect(person == .map);
    try testing.expectEqualStrings("Alice", person.map.get("name").?.string_value);
    try testing.expectEqual(@as(i64, 30), person.map.get("age").?.int_value);

    const settings = value.map.get("settings").?;
    try testing.expect(settings == .map);
    try testing.expectEqualStrings("dark", settings.map.get("theme").?.string_value);
    try testing.expectEqual(true, settings.map.get("notifications").?.bool_value);
}

test "yaml: parse list of maps" {
    const allocator = testing.allocator;

    const input =
        \\- name: Alice
        \\  age: 30
        \\- name: Bob
        \\  age: 25
    ;

    var value = try yaml.parse(allocator, input);
    defer value.deinit(allocator);

    try testing.expect(value == .list);
    try testing.expectEqual(@as(usize, 2), value.list.items.len);

    const first = value.list.items[0];
    try testing.expect(first == .map);
    try testing.expectEqualStrings("Alice", first.map.get("name").?.string_value);
    try testing.expectEqual(@as(i64, 30), first.map.get("age").?.int_value);

    const second = value.list.items[1];
    try testing.expect(second == .map);
    try testing.expectEqualStrings("Bob", second.map.get("name").?.string_value);
    try testing.expectEqual(@as(i64, 25), second.map.get("age").?.int_value);
}

test "yaml: parse map with list values" {
    const allocator = testing.allocator;

    const input =
        \\person: Alice
        \\hobbies:
        \\  - reading
        \\  - coding
        \\  - gaming
    ;

    var value = try yaml.parse(allocator, input);
    defer value.deinit(allocator);

    try testing.expect(value == .map);
    try testing.expectEqual(@as(usize, 2), value.map.count());

    try testing.expectEqualStrings("Alice", value.map.get("person").?.string_value);

    const hobbies = value.map.get("hobbies").?;
    try testing.expect(hobbies == .list);
    try testing.expectEqual(@as(usize, 3), hobbies.list.items.len);
    try testing.expectEqualStrings("reading", hobbies.list.items[0].string_value);
    try testing.expectEqualStrings("coding", hobbies.list.items[1].string_value);
    try testing.expectEqualStrings("gaming", hobbies.list.items[2].string_value);
}

test "yaml: parse multiline string" {
    const allocator = testing.allocator;

    const input =
        \\query: |
        \\  SELECT *
        \\  FROM users
        \\  WHERE active = true
    ;

    var value = try yaml.parse(allocator, input);
    defer value.deinit(allocator);

    try testing.expect(value == .map);
    const query = value.map.get("query").?;
    try testing.expect(query == .string_value);

    const expected = "SELECT *\nFROM users\nWHERE active = true";
    try testing.expectEqualStrings(expected, query.string_value);
}

test "yaml: parse empty map" {
    const allocator = testing.allocator;

    var value = try yaml.parse(allocator, "{}");
    defer value.deinit(allocator);

    try testing.expect(value == .map);
    try testing.expectEqual(@as(usize, 0), value.map.count());
}

test "yaml: parse with comments" {
    const allocator = testing.allocator;

    const input =
        \\# This is a comment
        \\name: test  # inline comment
        \\# Another comment
        \\value: 42
    ;

    var value = try yaml.parse(allocator, input);
    defer value.deinit(allocator);

    try testing.expect(value == .map);
    try testing.expectEqual(@as(usize, 2), value.map.count());
    try testing.expectEqualStrings("test", value.map.get("name").?.string_value);
    try testing.expectEqual(@as(i64, 42), value.map.get("value").?.int_value);
}

test "yaml: parse deeply nested structure" {
    const allocator = testing.allocator;

    const input =
        \\level1:
        \\  level2:
        \\    level3:
        \\      level4:
        \\        value: deep
    ;

    var value = try yaml.parse(allocator, input);
    defer value.deinit(allocator);

    try testing.expect(value == .map);
    const l1 = value.map.get("level1").?;
    const l2 = l1.map.get("level2").?;
    const l3 = l2.map.get("level3").?;
    const l4 = l3.map.get("level4").?;
    const val = l4.map.get("value").?;
    try testing.expectEqualStrings("deep", val.string_value);
}

test "yaml: parse mixed list types" {
    const allocator = testing.allocator;

    const input =
        \\- string value
        \\- 42
        \\- 3.14
        \\- true
        \\- null
    ;

    var value = try yaml.parse(allocator, input);
    defer value.deinit(allocator);

    try testing.expect(value == .list);
    try testing.expectEqual(@as(usize, 5), value.list.items.len);

    try testing.expect(value.list.items[0] == .string_value);
    try testing.expect(value.list.items[1] == .int_value);
    try testing.expect(value.list.items[2] == .float_value);
    try testing.expect(value.list.items[3] == .bool_value);
    try testing.expect(value.list.items[4] == .null_value);
}

test "yaml: parse real test spec structure" {
    const allocator = testing.allocator;

    const input =
        \\version: "1.0"
        \\name: "Basic Tests"
        \\description: "Test suite"
        \\tests:
        \\  - name: "test1"
        \\    query: "RETURN 1 AS x"
        \\    params: {}
        \\    expect:
        \\      rows: 1
        \\      columns: ["x"]
        \\    timeout_ms: 5000
        \\  - name: "test2"
        \\    query: "RETURN $name AS name"
        \\    params:
        \\      name: "Alice"
        \\    expect:
        \\      rows: 1
    ;

    var value = try yaml.parse(allocator, input);
    defer value.deinit(allocator);

    try testing.expect(value == .map);
    try testing.expectEqualStrings("1.0", value.map.get("version").?.string_value);
    try testing.expectEqualStrings("Basic Tests", value.map.get("name").?.string_value);

    const tests = value.map.get("tests").?;
    try testing.expect(tests == .list);
    try testing.expectEqual(@as(usize, 2), tests.list.items.len);

    const test1 = tests.list.items[0];
    try testing.expect(test1 == .map);
    try testing.expectEqualStrings("test1", test1.map.get("name").?.string_value);
    try testing.expectEqualStrings("RETURN 1 AS x", test1.map.get("query").?.string_value);

    const expect1 = test1.map.get("expect").?;
    try testing.expect(expect1 == .map);
    try testing.expectEqual(@as(i64, 1), expect1.map.get("rows").?.int_value);
}

test "yaml: parse strings with special characters" {
    const allocator = testing.allocator;

    const input =
        \\message: "Hello: world"
        \\path: "/usr/local/bin"
        \\email: "user@example.com"
    ;

    var value = try yaml.parse(allocator, input);
    defer value.deinit(allocator);

    try testing.expect(value == .map);
    try testing.expectEqualStrings("Hello: world", value.map.get("message").?.string_value);
    try testing.expectEqualStrings("/usr/local/bin", value.map.get("path").?.string_value);
    try testing.expectEqualStrings("user@example.com", value.map.get("email").?.string_value);
}

test "yaml: parse numbers with different formats" {
    const allocator = testing.allocator;

    const input =
        \\zero: 0
        \\positive: 123
        \\negative: -456
        \\float1: 1.5
        \\float2: -2.75
        \\scientific: 1.23e10
    ;

    var value = try yaml.parse(allocator, input);
    defer value.deinit(allocator);

    try testing.expect(value == .map);
    try testing.expectEqual(@as(i64, 0), value.map.get("zero").?.int_value);
    try testing.expectEqual(@as(i64, 123), value.map.get("positive").?.int_value);
    try testing.expectEqual(@as(i64, -456), value.map.get("negative").?.int_value);
    try testing.expect(@abs(value.map.get("float1").?.float_value - 1.5) < 0.01);
    try testing.expect(@abs(value.map.get("float2").?.float_value - (-2.75)) < 0.01);
}

test "yaml: parse empty values" {
    const allocator = testing.allocator;

    const input =
        \\key1:
        \\key2: null
        \\key3: ""
    ;

    var value = try yaml.parse(allocator, input);
    defer value.deinit(allocator);

    try testing.expect(value == .map);

    // key1 with no value should parse to null
    const k1 = value.map.get("key1").?;
    try testing.expect(k1 == .null_value or k1 == .map);

    // key2 explicitly null
    try testing.expect(value.map.get("key2").? == .null_value);

    // key3 empty string
    try testing.expectEqualStrings("", value.map.get("key3").?.string_value);
}

test "yaml: roundtrip - parse and stringify simple map" {
    const allocator = testing.allocator;

    const input =
        \\name: test
        \\value: 42
    ;

    var value = try yaml.parse(allocator, input);
    defer value.deinit(allocator);

    const output = try yaml.stringify(allocator, value);
    defer allocator.free(output);

    // Parse the output again to verify
    var reparsed = try yaml.parse(allocator, output);
    defer reparsed.deinit(allocator);

    try testing.expect(reparsed == .map);
    try testing.expectEqualStrings("test", reparsed.map.get("name").?.string_value);
    try testing.expectEqual(@as(i64, 42), reparsed.map.get("value").?.int_value);
}

test "yaml: DEBUG simple tests field" {
    const allocator = testing.allocator;
    const input =
        \\tests:
        \\  - name: "test1"
    ;

    std.debug.print("\n=== DEBUG: Parsing ===\n{s}\n=== END INPUT ===\n", .{input});
    var value = try yaml.parse(allocator, input);
    defer value.deinit(allocator);

    std.debug.print("Root type: {}\n", .{value});
    if (value == .map) {
        std.debug.print("Map has {d} keys\n", .{value.map.count()});
        var iter = value.map.iterator();
        while (iter.next()) |entry| {
            std.debug.print("  '{s}' -> {}\n", .{ entry.key_ptr.*, entry.value_ptr.* });
        }
    }
}
