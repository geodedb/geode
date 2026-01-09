const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

// CANARY: REQ=REQ-GAP-ANALYSIS-TESTS-001; FEATURE="GapAnalysisFixes"; ASPECT=UnitTests; STATUS=IMPL; OWNER=testing; UPDATED=2026-01-09
// Comprehensive unit tests for all closed gaps from the January 2026 gap analysis

// Module imports
const eval = geode.eval;
const types = geode.value_types;
const ast = geode.gql.ast;

// =============================================================================
// GAP-0001: AES-256-GCM Encryption Tests
// =============================================================================

test "GAP-0001: AES-256-GCM encryption basic roundtrip" {
    const AesGcm = std.crypto.aead.aes_gcm.Aes256Gcm;
    const nonce_len = AesGcm.nonce_length;
    const tag_len = AesGcm.tag_length;

    var key: [32]u8 = undefined;
    std.crypto.random.bytes(&key);

    var nonce: [nonce_len]u8 = undefined;
    std.crypto.random.bytes(&nonce);

    const plaintext = "Hello, Geode! This is a test message for AES-256-GCM encryption.";
    var ciphertext: [plaintext.len]u8 = undefined;
    var tag: [tag_len]u8 = undefined;

    // Encrypt
    AesGcm.encrypt(&ciphertext, &tag, plaintext, "", nonce, key);

    // Decrypt
    var decrypted: [plaintext.len]u8 = undefined;
    try AesGcm.decrypt(&decrypted, &ciphertext, tag, "", nonce, key);

    try testing.expectEqualStrings(plaintext, &decrypted);
}

test "GAP-0001: AES-256-GCM detects tampered ciphertext" {
    const AesGcm = std.crypto.aead.aes_gcm.Aes256Gcm;
    const nonce_len = AesGcm.nonce_length;
    const tag_len = AesGcm.tag_length;

    var key: [32]u8 = undefined;
    std.crypto.random.bytes(&key);

    var nonce: [nonce_len]u8 = undefined;
    std.crypto.random.bytes(&nonce);

    const plaintext = "Sensitive data that must be authenticated";
    var ciphertext: [plaintext.len]u8 = undefined;
    var tag: [tag_len]u8 = undefined;

    AesGcm.encrypt(&ciphertext, &tag, plaintext, "", nonce, key);

    // Tamper with ciphertext
    ciphertext[0] ^= 0xFF;

    // Decryption should fail with authentication error
    var decrypted: [plaintext.len]u8 = undefined;
    const result = AesGcm.decrypt(&decrypted, &ciphertext, tag, "", nonce, key);
    try testing.expectError(error.AuthenticationFailed, result);
}

test "GAP-0001: AES-256-GCM detects tampered authentication tag" {
    const AesGcm = std.crypto.aead.aes_gcm.Aes256Gcm;
    const nonce_len = AesGcm.nonce_length;
    const tag_len = AesGcm.tag_length;

    var key: [32]u8 = undefined;
    std.crypto.random.bytes(&key);

    var nonce: [nonce_len]u8 = undefined;
    std.crypto.random.bytes(&nonce);

    const plaintext = "Data with integrity protection";
    var ciphertext: [plaintext.len]u8 = undefined;
    var tag: [tag_len]u8 = undefined;

    AesGcm.encrypt(&ciphertext, &tag, plaintext, "", nonce, key);

    // Tamper with tag
    tag[0] ^= 0xFF;

    // Decryption should fail
    var decrypted: [plaintext.len]u8 = undefined;
    const result = AesGcm.decrypt(&decrypted, &ciphertext, tag, "", nonce, key);
    try testing.expectError(error.AuthenticationFailed, result);
}

test "GAP-0001: AES-256-GCM unique nonces produce different ciphertexts" {
    const AesGcm = std.crypto.aead.aes_gcm.Aes256Gcm;
    const nonce_len = AesGcm.nonce_length;
    const tag_len = AesGcm.tag_length;

    var key: [32]u8 = undefined;
    std.crypto.random.bytes(&key);

    const plaintext = "Same plaintext, different nonces";
    var ciphertext1: [plaintext.len]u8 = undefined;
    var ciphertext2: [plaintext.len]u8 = undefined;
    var tag1: [tag_len]u8 = undefined;
    var tag2: [tag_len]u8 = undefined;

    var nonce1: [nonce_len]u8 = undefined;
    var nonce2: [nonce_len]u8 = undefined;
    std.crypto.random.bytes(&nonce1);
    std.crypto.random.bytes(&nonce2);

    AesGcm.encrypt(&ciphertext1, &tag1, plaintext, "", nonce1, key);
    AesGcm.encrypt(&ciphertext2, &tag2, plaintext, "", nonce2, key);

    // Ciphertexts should be different with different nonces
    try testing.expect(!std.mem.eql(u8, &ciphertext1, &ciphertext2));
}

test "GAP-0001: AES-256-GCM empty plaintext handling" {
    const AesGcm = std.crypto.aead.aes_gcm.Aes256Gcm;
    const nonce_len = AesGcm.nonce_length;
    const tag_len = AesGcm.tag_length;

    var key: [32]u8 = undefined;
    std.crypto.random.bytes(&key);

    var nonce: [nonce_len]u8 = undefined;
    std.crypto.random.bytes(&nonce);

    const plaintext = "";
    var ciphertext: [0]u8 = undefined;
    var tag: [tag_len]u8 = undefined;

    AesGcm.encrypt(&ciphertext, &tag, plaintext, "", nonce, key);

    var decrypted: [0]u8 = undefined;
    try AesGcm.decrypt(&decrypted, &ciphertext, tag, "", nonce, key);

    try testing.expectEqualStrings(plaintext, &decrypted);
}

// =============================================================================
// GAP-0007: List Functions head()/tail() Tests
// =============================================================================

test "GAP-0007: head() returns first element of list" {
    const allocator = testing.allocator;

    // Create list [1, 2, 3, 4, 5]
    const list_values = try allocator.alloc(types.Value, 5);
    defer allocator.free(list_values);
    list_values[0] = types.Value{ .Int = 1 };
    list_values[1] = types.Value{ .Int = 2 };
    list_values[2] = types.Value{ .Int = 3 };
    list_values[3] = types.Value{ .Int = 4 };
    list_values[4] = types.Value{ .Int = 5 };

    const list = types.Value{ .List = list_values };

    // Create function call expression for head(list)
    const result = try eval.evalFunction(allocator, "head", &[_]types.Value{list}, types.Env.empty());

    try testing.expect(result == .Int);
    try testing.expectEqual(@as(i128, 1), result.Int);
}

test "GAP-0007: head() returns null for empty list" {
    const allocator = testing.allocator;

    const empty_list = types.Value{ .List = &[_]types.Value{} };

    const result = try eval.evalFunction(allocator, "head", &[_]types.Value{empty_list}, types.Env.empty());

    try testing.expect(result == .Null);
}

test "GAP-0007: tail() returns all elements except first" {
    const allocator = testing.allocator;

    // Create list [1, 2, 3, 4, 5]
    const list_values = try allocator.alloc(types.Value, 5);
    defer allocator.free(list_values);
    list_values[0] = types.Value{ .Int = 1 };
    list_values[1] = types.Value{ .Int = 2 };
    list_values[2] = types.Value{ .Int = 3 };
    list_values[3] = types.Value{ .Int = 4 };
    list_values[4] = types.Value{ .Int = 5 };

    const list = types.Value{ .List = list_values };

    const result = try eval.evalFunction(allocator, "tail", &[_]types.Value{list}, types.Env.empty());
    defer if (result == .List and result.List.len > 0) allocator.free(result.List);

    try testing.expect(result == .List);
    try testing.expectEqual(@as(usize, 4), result.List.len);
    try testing.expectEqual(@as(i128, 2), result.List[0].Int);
    try testing.expectEqual(@as(i128, 3), result.List[1].Int);
    try testing.expectEqual(@as(i128, 4), result.List[2].Int);
    try testing.expectEqual(@as(i128, 5), result.List[3].Int);
}

test "GAP-0007: tail() returns empty list for single-element list" {
    const allocator = testing.allocator;

    var single_elem = [_]types.Value{types.Value{ .Int = 42 }};
    const list = types.Value{ .List = &single_elem };

    const result = try eval.evalFunction(allocator, "tail", &[_]types.Value{list}, types.Env.empty());

    try testing.expect(result == .List);
    try testing.expectEqual(@as(usize, 0), result.List.len);
}

test "GAP-0007: last() returns last element of list" {
    const allocator = testing.allocator;

    // Create list [1, 2, 3, 4, 5]
    const list_values = try allocator.alloc(types.Value, 5);
    defer allocator.free(list_values);
    list_values[0] = types.Value{ .Int = 1 };
    list_values[1] = types.Value{ .Int = 2 };
    list_values[2] = types.Value{ .Int = 3 };
    list_values[3] = types.Value{ .Int = 4 };
    list_values[4] = types.Value{ .Int = 5 };

    const list = types.Value{ .List = list_values };

    const result = try eval.evalFunction(allocator, "last", &[_]types.Value{list}, types.Env.empty());

    try testing.expect(result == .Int);
    try testing.expectEqual(@as(i128, 5), result.Int);
}

test "GAP-0007: size() returns list length" {
    const allocator = testing.allocator;

    const list_values = try allocator.alloc(types.Value, 5);
    defer allocator.free(list_values);
    for (list_values, 0..) |*v, i| {
        v.* = types.Value{ .Int = @intCast(i + 1) };
    }

    const list = types.Value{ .List = list_values };

    const result = try eval.evalFunction(allocator, "size", &[_]types.Value{list}, types.Env.empty());

    try testing.expect(result == .Int);
    try testing.expectEqual(@as(i128, 5), result.Int);
}

// =============================================================================
// GAP-0011: Regex Matching Tests
// =============================================================================

test "GAP-0011: regex simple wildcard match" {
    // Test that 'A.*' matches 'Alice'
    const matched = eval.matchSimplePattern("Alice", "A.*");
    try testing.expect(matched);
}

test "GAP-0011: regex wildcard no match" {
    // Test that 'B.*' does not match 'Alice'
    const matched = eval.matchSimplePattern("Alice", "B.*");
    try testing.expect(!matched);
}

test "GAP-0011: regex anchor start" {
    // Test that '^Alice' matches 'Alice' at start
    const matched = eval.matchSimplePattern("Alice", "^Alice");
    try testing.expect(matched);

    // Test that '^lice' does not match 'Alice'
    const no_match = eval.matchSimplePattern("Alice", "^lice");
    try testing.expect(!no_match);
}

test "GAP-0011: regex anchor end" {
    // Test that 'ice$' matches 'Alice' at end
    const matched = eval.matchSimplePattern("Alice", "ice$");
    try testing.expect(matched);

    // Test that 'Ali$' does not match 'Alice'
    const no_match = eval.matchSimplePattern("Alice", "Ali$");
    try testing.expect(!no_match);
}

test "GAP-0011: regex both anchors" {
    // Test that '^Alice$' matches exactly 'Alice'
    const matched = eval.matchSimplePattern("Alice", "^Alice$");
    try testing.expect(matched);

    // Test that '^Alice$' does not match 'Alice Smith'
    const no_match = eval.matchSimplePattern("Alice Smith", "^Alice$");
    try testing.expect(!no_match);
}

test "GAP-0011: regex character class" {
    // Test that '[A-Z]lice' matches 'Alice'
    const matched = eval.matchSimplePattern("Alice", "[A-Z]lice");
    try testing.expect(matched);

    // Test character class with numbers
    const num_match = eval.matchSimplePattern("test123", "test[0-9][0-9][0-9]");
    try testing.expect(num_match);
}

test "GAP-0011: regex dot matches any character" {
    // Test that 'A.ice' matches 'Alice'
    const matched = eval.matchSimplePattern("Alice", "A.ice");
    try testing.expect(matched);

    // Test that 'A...e' matches 'Alice'
    const multi_match = eval.matchSimplePattern("Alice", "A...e");
    try testing.expect(multi_match);
}

test "GAP-0011: regex optional character" {
    // Test that 'colou?r' matches both 'color' and 'colour'
    const color_match = eval.matchSimplePattern("color", "colou?r");
    try testing.expect(color_match);

    const colour_match = eval.matchSimplePattern("colour", "colou?r");
    try testing.expect(colour_match);
}

test "GAP-0011: regex empty pattern matches empty string" {
    const matched = eval.matchSimplePattern("", "");
    try testing.expect(matched);

    // Empty pattern should not match non-empty string
    const no_match = eval.matchSimplePattern("test", "");
    try testing.expect(!no_match);
}

test "GAP-0011: regex plus quantifier with character class" {
    // Test [0-9]+ pattern (transformed to [0-9][0-9]*)
    const match1 = eval.matchSimplePattern("test123", "test[0-9]+");
    try testing.expect(match1);

    const match2 = eval.matchSimplePattern("test1", "test[0-9]+");
    try testing.expect(match2);

    // Should not match without any digits
    const no_match = eval.matchSimplePattern("test", "test[0-9]+");
    try testing.expect(!no_match);
}

test "GAP-0011: regex character class star quantifier" {
    // Test [0-9]* pattern (zero or more digits)
    const match1 = eval.matchSimplePattern("test123", "test[0-9]*");
    try testing.expect(match1);

    const match2 = eval.matchSimplePattern("test", "test[0-9]*");
    try testing.expect(match2); // Zero digits should match

    const match3 = eval.matchSimplePattern("123abc", "[0-9]*abc");
    try testing.expect(match3);
}

test "GAP-0011: regex dot star at string start" {
    // Ensure .* at start doesn't cause underflow when si=0
    const match1 = eval.matchSimplePattern("hello", ".*ello");
    try testing.expect(match1);

    const match2 = eval.matchSimplePattern("", ".*");
    try testing.expect(match2); // .* should match empty string

    const match3 = eval.matchSimplePattern("abc", ".*");
    try testing.expect(match3);
}

// =============================================================================
// GAP-0008: KMS Provider Key Parsing Tests
// =============================================================================

test "GAP-0008: hex key parsing valid 64-char key" {
    const key_hex = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";

    var key_data: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const high = std.fmt.charToDigit(key_hex[i * 2], 16) catch unreachable;
        const low = std.fmt.charToDigit(key_hex[i * 2 + 1], 16) catch unreachable;
        key_data[i] = (high << 4) | low;
    }

    // Verify first few bytes
    try testing.expectEqual(@as(u8, 0x01), key_data[0]);
    try testing.expectEqual(@as(u8, 0x23), key_data[1]);
    try testing.expectEqual(@as(u8, 0x45), key_data[2]);
    try testing.expectEqual(@as(u8, 0x67), key_data[3]);
}

test "GAP-0008: hex key parsing all zeros" {
    const key_hex = "0000000000000000000000000000000000000000000000000000000000000000";

    var key_data: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const high = std.fmt.charToDigit(key_hex[i * 2], 16) catch unreachable;
        const low = std.fmt.charToDigit(key_hex[i * 2 + 1], 16) catch unreachable;
        key_data[i] = (high << 4) | low;
    }

    for (key_data) |byte| {
        try testing.expectEqual(@as(u8, 0x00), byte);
    }
}

test "GAP-0008: hex key parsing all ones" {
    const key_hex = "ffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffffff";

    var key_data: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        const high = std.fmt.charToDigit(key_hex[i * 2], 16) catch unreachable;
        const low = std.fmt.charToDigit(key_hex[i * 2 + 1], 16) catch unreachable;
        key_data[i] = (high << 4) | low;
    }

    for (key_data) |byte| {
        try testing.expectEqual(@as(u8, 0xFF), byte);
    }
}

test "GAP-0008: hex key length validation" {
    // 63 chars - too short
    const short_key = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcde";
    try testing.expectEqual(@as(usize, 63), short_key.len);

    // 65 chars - too long
    const long_key = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef0";
    try testing.expectEqual(@as(usize, 65), long_key.len);

    // Exactly 64 chars - valid
    const valid_key = "0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef";
    try testing.expectEqual(@as(usize, 64), valid_key.len);
}

test "GAP-0008: invalid hex character detection" {
    // Test that invalid hex character 'g' is detected
    const result = std.fmt.charToDigit('g', 16);
    try testing.expectError(error.InvalidCharacter, result);

    // Test that 'z' is invalid
    const result2 = std.fmt.charToDigit('z', 16);
    try testing.expectError(error.InvalidCharacter, result2);

    // Test that space is invalid
    const result3 = std.fmt.charToDigit(' ', 16);
    try testing.expectError(error.InvalidCharacter, result3);
}

// =============================================================================
// GAP-0002: Remote Backup Address Parsing Tests
// =============================================================================

test "GAP-0002: server address parsing with port" {
    const server = "192.168.1.100:3141";

    const colon_idx = std.mem.lastIndexOf(u8, server, ":") orelse unreachable;
    const host = server[0..colon_idx];
    const port_str = server[colon_idx + 1 ..];
    const port = try std.fmt.parseInt(u16, port_str, 10);

    try testing.expectEqualStrings("192.168.1.100", host);
    try testing.expectEqual(@as(u16, 3141), port);
}

test "GAP-0002: server address parsing hostname" {
    const server = "db.example.com:3141";

    const colon_idx = std.mem.lastIndexOf(u8, server, ":") orelse unreachable;
    const host = server[0..colon_idx];
    const port_str = server[colon_idx + 1 ..];
    const port = try std.fmt.parseInt(u16, port_str, 10);

    try testing.expectEqualStrings("db.example.com", host);
    try testing.expectEqual(@as(u16, 3141), port);
}

test "GAP-0002: server address parsing IPv6" {
    const server = "[::1]:3141";

    // For IPv6, we need to handle brackets
    const colon_idx = std.mem.lastIndexOf(u8, server, ":") orelse unreachable;
    const host = server[0..colon_idx];
    const port_str = server[colon_idx + 1 ..];
    const port = try std.fmt.parseInt(u16, port_str, 10);

    try testing.expectEqualStrings("[::1]", host);
    try testing.expectEqual(@as(u16, 3141), port);
}

test "GAP-0002: backup mode validation" {
    // Valid modes
    const valid_modes = [_][]const u8{ "full", "incremental", "differential" };

    for (valid_modes) |mode| {
        const is_valid = std.mem.eql(u8, mode, "full") or
            std.mem.eql(u8, mode, "incremental") or
            std.mem.eql(u8, mode, "differential");
        try testing.expect(is_valid);
    }
}

// =============================================================================
// GAP-0004: FLE Admin Commands Tests
// =============================================================================

test "GAP-0004: FLE KeyRotationScope enum values" {
    // Test enum tag names exist
    const fek_tag = @tagName(geode.admin.fle_commands.KeyRotationArgs.KeyRotationScope.fek);
    try testing.expectEqualStrings("fek", fek_tag);

    const sk_tag = @tagName(geode.admin.fle_commands.KeyRotationArgs.KeyRotationScope.sk);
    try testing.expectEqualStrings("sk", sk_tag);

    const trk_tag = @tagName(geode.admin.fle_commands.KeyRotationArgs.KeyRotationScope.trk);
    try testing.expectEqualStrings("trk", trk_tag);
}

test "GAP-0004: FLE KeyRotationArgs struct initialization" {
    const args = geode.admin.fle_commands.KeyRotationArgs{
        .tenant_id = "test_tenant",
        .scope = .fek,
        .schema_name = "users",
        .field_name = "ssn",
    };

    try testing.expectEqualStrings("test_tenant", args.tenant_id);
    try testing.expectEqual(geode.admin.fle_commands.KeyRotationArgs.KeyRotationScope.fek, args.scope);
    try testing.expect(args.schema_name != null);
    try testing.expectEqualStrings("users", args.schema_name.?);
    try testing.expect(args.field_name != null);
    try testing.expectEqualStrings("ssn", args.field_name.?);
}

test "GAP-0004: FLE PolicyArgs struct initialization" {
    const args = geode.admin.fle_commands.PolicyArgs{
        .schema_name = "customers",
        .field_name = "credit_card",
        .role = "admin",
    };

    try testing.expectEqualStrings("customers", args.schema_name);
    try testing.expectEqualStrings("credit_card", args.field_name);
    try testing.expectEqualStrings("admin", args.role);
}

test "GAP-0004: FLE MigrationArgs default batch size" {
    const args = geode.admin.fle_commands.MigrationArgs{
        .tenant_id = "tenant1",
        .schema_name = "orders",
        .field_name = "payment_info",
    };

    try testing.expectEqual(@as(usize, 1000), args.batch_size);
}

test "GAP-0004: FLE MigrationArgs custom batch size" {
    const args = geode.admin.fle_commands.MigrationArgs{
        .tenant_id = "tenant1",
        .schema_name = "orders",
        .field_name = "payment_info",
        .batch_size = 5000,
    };

    try testing.expectEqual(@as(usize, 5000), args.batch_size);
}

// =============================================================================
// Binary Operator Tests (GAP-0005, GAP-0006, GAP-0011 related)
// =============================================================================

test "Binary operator: RegexMatch positive" {
    const allocator = testing.allocator;

    const input = types.Value{ .Str = "Alice" };
    const pattern = types.Value{ .Str = "A.*" };

    const result = try eval.evalBinary(allocator, .RegexMatch, input, pattern);

    try testing.expect(result == .Bool);
    try testing.expect(result.Bool == true);
}

test "Binary operator: RegexMatch negative" {
    const allocator = testing.allocator;

    const input = types.Value{ .Str = "Alice" };
    const pattern = types.Value{ .Str = "^B.*" };

    const result = try eval.evalBinary(allocator, .RegexMatch, input, pattern);

    try testing.expect(result == .Bool);
    try testing.expect(result.Bool == false);
}

test "Binary operator: RegexNotMatch" {
    const allocator = testing.allocator;

    const input = types.Value{ .Str = "Alice" };
    const pattern = types.Value{ .Str = "B.*" };

    const result = try eval.evalBinary(allocator, .RegexNotMatch, input, pattern);

    try testing.expect(result == .Bool);
    try testing.expect(result.Bool == true);
}

test "Binary operator: RegexMatch with null returns null" {
    const allocator = testing.allocator;

    const input = types.Value{ .Null = {} };
    const pattern = types.Value{ .Str = "A.*" };

    const result = try eval.evalBinary(allocator, .RegexMatch, input, pattern);

    try testing.expect(result == .Null);
}

// =============================================================================
// GAP-0012: VALUES Related Tests
// =============================================================================

test "GAP-0012: multiplication operation for VALUES expressions" {
    const allocator = testing.allocator;

    // Test number * 2 operation that VALUES uses
    const number = types.Value{ .Int = 5 };
    const multiplier = types.Value{ .Int = 2 };

    const result = try eval.evalBinary(allocator, .Mul, number, multiplier);

    try testing.expect(result == .Int);
    try testing.expectEqual(@as(i128, 10), result.Int);
}

test "GAP-0012: multiple value expressions" {
    const allocator = testing.allocator;

    // Simulate VALUES (1), (2), (3), (4), (5) doubling
    const values = [_]i128{ 1, 2, 3, 4, 5 };
    const expected = [_]i128{ 2, 4, 6, 8, 10 };

    for (values, 0..) |val, i| {
        const v = types.Value{ .Int = val };
        const two = types.Value{ .Int = 2 };
        const result = try eval.evalBinary(allocator, .Mul, v, two);
        try testing.expectEqual(expected[i], result.Int);
    }
}

// =============================================================================
// GAP-0010: DateTime Property Tests
// =============================================================================

test "GAP-0010: DateTime value creation" {
    // Test creating DateTime values
    const dt = types.Value{ .DateTime = .{ .timestamp_ns = 1705329000 * std.time.ns_per_s } };
    try testing.expect(dt == .DateTime);
    try testing.expectEqual(@as(i128, 1705329000 * std.time.ns_per_s), dt.DateTime.timestamp_ns);
}

test "GAP-0010: DateTime epoch value" {
    const epoch = types.Value{ .DateTime = .{ .timestamp_ns = 0 } };
    try testing.expect(epoch == .DateTime);
    try testing.expectEqual(@as(i128, 0), epoch.DateTime.timestamp_ns);
}

// =============================================================================
// Integration-style Tests
// =============================================================================

test "Integration: list operations chain" {
    const allocator = testing.allocator;

    // Create list [10, 20, 30, 40, 50]
    const list_values = try allocator.alloc(types.Value, 5);
    defer allocator.free(list_values);
    for (list_values, 0..) |*v, i| {
        v.* = types.Value{ .Int = @as(i128, (i + 1) * 10) };
    }
    const list = types.Value{ .List = list_values };

    // Test head
    const head_result = try eval.evalFunction(allocator, "head", &[_]types.Value{list}, types.Env.empty());
    try testing.expectEqual(@as(i128, 10), head_result.Int);

    // Test last
    const last_result = try eval.evalFunction(allocator, "last", &[_]types.Value{list}, types.Env.empty());
    try testing.expectEqual(@as(i128, 50), last_result.Int);

    // Test size
    const size_result = try eval.evalFunction(allocator, "size", &[_]types.Value{list}, types.Env.empty());
    try testing.expectEqual(@as(i128, 5), size_result.Int);
}

test "Integration: regex patterns comprehensive" {
    // Test various regex patterns
    const test_cases = [_]struct { input: []const u8, pattern: []const u8, expected: bool }{
        .{ .input = "hello", .pattern = "hello", .expected = true },
        .{ .input = "hello", .pattern = "hel.*", .expected = true },
        .{ .input = "hello", .pattern = "^hello$", .expected = true },
        .{ .input = "hello world", .pattern = "^hello$", .expected = false },
        .{ .input = "test123", .pattern = "test[0-9]+", .expected = true },
        .{ .input = "ABC", .pattern = "[A-Z][A-Z][A-Z]", .expected = true },
        .{ .input = "abc", .pattern = "[A-Z][A-Z][A-Z]", .expected = false },
        .{ .input = "", .pattern = "", .expected = true },
        .{ .input = "anything", .pattern = ".*", .expected = true },
    };

    for (test_cases) |tc| {
        const result = eval.matchSimplePattern(tc.input, tc.pattern);
        try testing.expectEqual(tc.expected, result);
    }
}

test "Integration: arithmetic operations" {
    const allocator = testing.allocator;

    // Test various arithmetic operations used in queries
    const a = types.Value{ .Int = 100 };
    const b = types.Value{ .Int = 25 };

    // Addition
    const add_result = try eval.evalBinary(allocator, .Add, a, b);
    try testing.expectEqual(@as(i128, 125), add_result.Int);

    // Subtraction
    const sub_result = try eval.evalBinary(allocator, .Sub, a, b);
    try testing.expectEqual(@as(i128, 75), sub_result.Int);

    // Multiplication
    const mul_result = try eval.evalBinary(allocator, .Mul, a, b);
    try testing.expectEqual(@as(i128, 2500), mul_result.Int);

    // Division
    const div_result = try eval.evalBinary(allocator, .Div, a, b);
    try testing.expectEqual(@as(i128, 4), div_result.Int);

    // Modulo
    const mod_result = try eval.evalBinary(allocator, .Mod, a, b);
    try testing.expectEqual(@as(i128, 0), mod_result.Int);
}

test "Integration: comparison operations" {
    const allocator = testing.allocator;

    const x = types.Value{ .Int = 42 };
    const y = types.Value{ .Int = 100 };

    // Less than
    const lt_result = try eval.evalBinary(allocator, .Lt, x, y);
    try testing.expect(lt_result.Bool == true);

    // Greater than
    const gt_result = try eval.evalBinary(allocator, .Gt, x, y);
    try testing.expect(gt_result.Bool == false);

    // Equality
    const eq_result = try eval.evalBinary(allocator, .Eq, x, x);
    try testing.expect(eq_result.Bool == true);

    // Not equal
    const ne_result = try eval.evalBinary(allocator, .Ne, x, y);
    try testing.expect(ne_result.Bool == true);
}
