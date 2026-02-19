const std = @import("std");
const testing = std.testing;
// CANARY: REQ=REQ-QUALITY-GAP-413-003; FEATURE="OrphanedTestRemediation"; ASPECT=AuditFilters; STATUS=TESTED; OWNER=quality; UPDATED=2026-01-30
const audit = @import("audit_bundle");
const filters = audit.filters;
const config = audit.config;

test "sensitive key detection" {
    // Test password-related keys
    try testing.expect(filters.isSensitiveKey(testing.allocator, "password") == .password);
    try testing.expect(filters.isSensitiveKey(testing.allocator, "Password") == .password);
    try testing.expect(filters.isSensitiveKey(testing.allocator, "user_password") == .password);
    try testing.expect(filters.isSensitiveKey(testing.allocator, "passwd") == .password);

    // Test token-related keys
    try testing.expect(filters.isSensitiveKey(testing.allocator, "token") == .token);
    try testing.expect(filters.isSensitiveKey(testing.allocator, "api_key") == .token);
    try testing.expect(filters.isSensitiveKey(testing.allocator, "apikey") == .token);

    // Test JWT
    try testing.expect(filters.isSensitiveKey(testing.allocator, "jwt") == .jwt);
    try testing.expect(filters.isSensitiveKey(testing.allocator, "JWT_TOKEN") == .jwt);

    // Test payment card
    try testing.expect(filters.isSensitiveKey(testing.allocator, "card") == .card);
    try testing.expect(filters.isSensitiveKey(testing.allocator, "credit_card") == .card);
    try testing.expect(filters.isSensitiveKey(testing.allocator, "cc_number") == .card);

    // Test non-sensitive keys
    try testing.expect(filters.isSensitiveKey(testing.allocator, "username") == null);
    try testing.expect(filters.isSensitiveKey(testing.allocator, "user_id") == null);
    try testing.expect(filters.isSensitiveKey(testing.allocator, "timestamp") == null);
}

test "JWT detection" {
    // Valid JWT format
    try testing.expect(filters.isJwt("eyJhbGciOiJIUzI1NiIsInR5cCI6IkpXVCJ9.eyJzdWIiOiIxMjM0NTY3ODkwIiwibmFtZSI6IkpvaG4gRG9lIiwiaWF0IjoxNTE2MjM5MDIyfQ.SflKxwRJSMeKKF2QT4fwpMeJf36POk6yJV_adQssw5c"));

    // Simple valid format
    try testing.expect(filters.isJwt("a.b.c"));
    try testing.expect(filters.isJwt("abc123.def456.ghi789"));

    // Invalid formats
    try testing.expect(!filters.isJwt("a.b")); // Only 2 segments
    try testing.expect(!filters.isJwt("a.b.c.d")); // Too many segments
    try testing.expect(!filters.isJwt("a..c")); // Empty segment
    try testing.expect(!filters.isJwt(".b.c")); // Empty first segment
    try testing.expect(!filters.isJwt("a.b.")); // Empty last segment
    try testing.expect(!filters.isJwt("a.b.c@")); // Invalid character
}

test "PAN (credit card) detection with Luhn" {
    // Valid test card numbers (these are test numbers, not real)
    try testing.expect(filters.isPan("4111 1111 1111 1111")); // Visa test number
    try testing.expect(filters.isPan("4111111111111111")); // Same without spaces
    try testing.expect(filters.isPan("4111-1111-1111-1111")); // With dashes

    // Invalid formats
    try testing.expect(!filters.isPan("4111 1111 1111 1112")); // Fails Luhn
    try testing.expect(!filters.isPan("123")); // Too short
    try testing.expect(!filters.isPan("12345678901234567890")); // Too long
    try testing.expect(!filters.isPan("abcd efgh ijkl mnop")); // Non-numeric
}

test "email detection" {
    // Valid emails
    try testing.expect(filters.isEmail("user@example.com"));
    try testing.expect(filters.isEmail("test.email@domain.org"));
    try testing.expect(filters.isEmail("simple@test.co.uk"));

    // Invalid emails
    try testing.expect(!filters.isEmail("notanemail"));
    try testing.expect(!filters.isEmail("@domain.com")); // No local part
    try testing.expect(!filters.isEmail("user@")); // No domain
    try testing.expect(!filters.isEmail("user@domain")); // No TLD
}

test "phone number detection" {
    // Valid phone numbers
    try testing.expect(filters.isPhone("1234567890"));
    try testing.expect(filters.isPhone("123-456-7890"));
    try testing.expect(filters.isPhone("(123) 456-7890"));
    try testing.expect(filters.isPhone("+1 123 456 7890"));
    try testing.expect(filters.isPhone("123.456.7890.1234")); // Extension

    // Invalid phone numbers
    try testing.expect(!filters.isPhone("123456789")); // Too short
    try testing.expect(!filters.isPhone("12345678901234567")); // Too long
    try testing.expect(!filters.isPhone("abcdefghij")); // Non-numeric
}

test "PEM private key detection" {
    const pem_key = "-----BEGIN PRIVATE KEY-----\nMIIEvQIBADANBgkqhkiG9w0BAQEFAASCBKcwggSjAgEAAoIBAQC8Q7HgL...\n-----END PRIVATE KEY-----";
    try testing.expect(filters.isPemPrivateKey(pem_key));

    const rsa_key = "-----BEGIN RSA PRIVATE KEY-----\nMIIEpAIBAAKCAQEAy8Dbq...\n-----END RSA PRIVATE KEY-----";
    try testing.expect(filters.isPemPrivateKey(rsa_key));

    // Not a private key
    try testing.expect(!filters.isPemPrivateKey("just some text"));
    try testing.expect(!filters.isPemPrivateKey("-----BEGIN CERTIFICATE-----"));
}

test "email masking" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const masked = try filters.maskEmail(allocator, "user@example.com");
    defer allocator.free(masked);

    try testing.expectEqualStrings("***@example.com", masked);
}

test "phone masking" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const masked = try filters.maskPhone(allocator, "123-456-7890");
    defer allocator.free(masked);

    try testing.expectEqualStrings("123***7890", masked);
}

test "metadata filtering and redaction" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    // Create test filter config
    const allow_fields = try allocator.alloc([]const u8, 2);
    allow_fields[0] = try allocator.dupe(u8, "actor_id");
    allow_fields[1] = try allocator.dupe(u8, "action");
    defer {
        for (allow_fields) |field| allocator.free(field);
        allocator.free(allow_fields);
    }

    const deny_patterns = try allocator.alloc([]const u8, 1);
    deny_patterns[0] = try allocator.dupe(u8, "secret");
    defer {
        for (deny_patterns) |pattern| allocator.free(pattern);
        allocator.free(deny_patterns);
    }

    const filter_config = config.FiltersConfig{
        .default_deny = true,
        .allow_fields = allow_fields,
        .deny_key_patterns = deny_patterns,
        .pii_mode = .mask,
        .pci_mode = true,
    };

    // Create test metadata
    var metadata_obj = std.json.ObjectMap.init(allocator);
    defer metadata_obj.deinit();

    try metadata_obj.put("actor_id", std.json.Value{ .string = "test-user" }); // Should be allowed
    try metadata_obj.put("password", std.json.Value{ .string = "secret123" }); // Should be redacted
    try metadata_obj.put("unknown_field", std.json.Value{ .string = "value" }); // Should be filtered out
    try metadata_obj.put("secret_data", std.json.Value{ .string = "sensitive" }); // Should be redacted

    const metadata = std.json.Value{ .object = metadata_obj };

    // CANARY: REQ=REQ-QUALITY-GAP-413-013; FEATURE="OrphanedTestRemediation"; ASPECT=ConstCorrectness; STATUS=TESTED; OWNER=quality; UPDATED=2026-01-30
    var filtered = try filters.filterAndRedactMetadata(allocator, metadata, &filter_config);
    defer if (filtered) |*f| {
        if (f.* == .object) {
            var obj_mut = &f.object;
            var iter = obj_mut.iterator();
            while (iter.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeJsonValue(allocator, entry.value_ptr.*);
            }
            obj_mut.deinit();
        }
    };

    try testing.expect(filtered != null);
    if (filtered) |f| {
        try testing.expect(f == .object);
        const obj = f.object;

        // Should contain allowed field
        try testing.expect(obj.contains("actor_id"));

        // Should contain redacted sensitive fields
        if (obj.get("password")) |password_value| {
            try testing.expectEqualStrings("[REDACTED]", password_value.string);
        }

        // Should not contain unknown field
        try testing.expect(!obj.contains("unknown_field"));
    }
}

fn freeJsonValue(allocator: std.mem.Allocator, value: std.json.Value) void {
    // CANARY: REQ=REQ-QUALITY-GAP-413-014; FEATURE="OrphanedTestRemediation"; ASPECT=ConstCorrectness; STATUS=TESTED; OWNER=quality; UPDATED=2026-01-30
    // Note: In Zig 0.15, ArrayHashMap.deinit requires mutable self, but Value fields are const when captured.
    // We copy to var to get mutability. This is safe because we own the values being freed.
    var val = value;
    switch (val) {
        .number_string => |ns| allocator.free(ns),
        .string => |s| allocator.free(s),
        .array => |*arr| {
            for (arr.items) |item| {
                freeJsonValue(allocator, item);
            }
            // Array in json.Value doesn't have managed allocator in Zig 0.15
            arr.deinit();
        },
        .object => |*obj| {
            var iter = obj.iterator();
            while (iter.next()) |entry| {
                allocator.free(entry.key_ptr.*);
                freeJsonValue(allocator, entry.value_ptr.*);
            }
            obj.deinit();
        },
        else => {},
    }
}

test "redaction tokens" {
    try testing.expectEqualStrings("[REDACTED]", filters.RedactionToken.password.toString());
    try testing.expectEqualStrings("[REDACTED_TOKEN]", filters.RedactionToken.token.toString());
    try testing.expectEqualStrings("[REDACTED_JWT]", filters.RedactionToken.jwt.toString());
    try testing.expectEqualStrings("[REDACTED_PAN]", filters.RedactionToken.card.toString());
    try testing.expectEqualStrings("[REDACTED_CVV]", filters.RedactionToken.cvv.toString());
    try testing.expectEqualStrings("[REDACTED_SSN]", filters.RedactionToken.ssn.toString());
    try testing.expectEqualStrings("[REDACTED_IBAN]", filters.RedactionToken.iban.toString());
    try testing.expectEqualStrings("[REDACTED_PK]", filters.RedactionToken.private_key.toString());
    try testing.expectEqualStrings("[REDACTED_EMAIL]", filters.RedactionToken.email.toString());
    try testing.expectEqualStrings("[REDACTED_PHONE]", filters.RedactionToken.phone.toString());
}
