// Test suite for Argon2id password hashing security
// CANARY: REQ=REQ-AUTH-HASH-002; FEATURE="Argon2id_Password_Hashing";
//         ASPECT=TESTING; STATUS=IMPL; OWNER=security; UPDATED=2025-10-16

const std = @import("std");
const testing = std.testing;
const Auth = @import("auth.zig").Auth;

test "Argon2id - same password produces different hashes (random salts)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ally = arena.allocator();

    var auth = try Auth.init(ally, null, null);
    defer auth.deinit();

    const password = "MySecurePassword123!";

    // Hash same password twice
    const hash1 = try auth.hashPassword(password);
    const hash2 = try auth.hashPassword(password);

    // Hashes MUST be different due to random salts
    try testing.expect(!std.mem.eql(u8, hash1, hash2));

    // Both hashes should be PHC format (start with $argon2id$)
    try testing.expect(std.mem.startsWith(u8, hash1, "$argon2id$"));
    try testing.expect(std.mem.startsWith(u8, hash2, "$argon2id$"));

    // Both must verify correctly
    try testing.expect(try auth.verifyPassword(password, hash1));
    try testing.expect(try auth.verifyPassword(password, hash2));
}

test "Argon2id - PHC format parsing and verification" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ally = arena.allocator();

    var auth = try Auth.init(ally, null, null);
    defer auth.deinit();

    const password = "TestPassword456!";
    const hash = try auth.hashPassword(password);

    // Verify PHC format structure: $argon2id$v=19$m=19456,t=2,p=1$salt$hash
    try testing.expect(std.mem.startsWith(u8, hash, "$argon2id$v=19$m=19456,t=2,p=1$"));

    // Count dollar signs (should be 5: prefix, v, params, salt, hash)
    var dollar_count: usize = 0;
    for (hash) |ch| {
        if (ch == '$') dollar_count += 1;
    }
    try testing.expectEqual(@as(usize, 5), dollar_count);

    // Verify correct password succeeds
    try testing.expect(try auth.verifyPassword(password, hash));

    // Verify wrong password fails
    try testing.expect(!try auth.verifyPassword("WrongPassword", hash));
}

test "Argon2id - OWASP parameters (m=19456, t=2, p=1)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ally = arena.allocator();

    var auth = try Auth.init(ally, null, null);
    defer auth.deinit();

    const hash = try auth.hashPassword("password");

    // Extract parameters section from PHC format
    const params_start = std.mem.indexOf(u8, hash, "$m=");
    try testing.expect(params_start != null);

    const params_section = hash[params_start.? ..];
    const params_end = std.mem.indexOf(u8, params_section[1..], "$");
    try testing.expect(params_end != null);

    const params = params_section[0 .. params_end.? + 1];

    // Verify OWASP recommended parameters are present
    try testing.expect(std.mem.indexOf(u8, params, "m=19456") != null);
    try testing.expect(std.mem.indexOf(u8, params, "t=2") != null);
    try testing.expect(std.mem.indexOf(u8, params, "p=1") != null);
}

test "Argon2id - round-trip hashing and verification" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ally = arena.allocator();

    var auth = try Auth.init(ally, null, null);
    defer auth.deinit();

    const test_passwords = [_][]const u8{
        "short",
        "Medium_Length_Pass123!",
        "VeryLongPasswordWithManyCharactersAndSymbols!@#$%^&*()_+-=[]{}|;:',.<>?/~`1234567890",
        "P@ssw0rd!",
        "🔐SecurePass123!", // Unicode
    };

    for (test_passwords) |password| {
        const hash = try auth.hashPassword(password);

        // Correct password verifies
        try testing.expect(try auth.verifyPassword(password, hash));

        // Wrong password fails
        try testing.expect(!try auth.verifyPassword("wrong", hash));
    }
}

test "Argon2id - legacy Blake2b migration support" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ally = arena.allocator();

    var auth = try Auth.init(ally, null, null);
    defer auth.deinit();

    // Simulate legacy Blake2b hash (64 hex chars)
    const password = "legacypassword";

    // Generate what a Blake2b hash would look like
    var legacy_hash_bytes: [32]u8 = undefined;
    const salt = "geode_default_salt_v1";
    std.crypto.hash.blake2.Blake2b256.hash(password ++ salt, &legacy_hash_bytes, .{});

    const legacy_hash = try std.fmt.allocPrint(ally, "{x}", .{std.fmt.fmtSliceHexLower(&legacy_hash_bytes)});

    // Should verify with legacy Blake2b
    try testing.expect(try auth.verifyPassword(password, legacy_hash));

    // Wrong password should fail
    try testing.expect(!try auth.verifyPassword("wrongpassword", legacy_hash));
}

test "Argon2id - invalid PHC format handling" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ally = arena.allocator();

    var auth = try Auth.init(ally, null, null);
    defer auth.deinit();

    const invalid_hashes = [_][]const u8{
        "",                                    // Empty
        "plaintext",                           // Not hashed
        "$argon2id$invalid",                   // Malformed PHC
        "$bcrypt$2a$10$salt$hash",            // Wrong algorithm
        "not_hex_not_phc",                    // Neither hex nor PHC
    };

    for (invalid_hashes) |bad_hash| {
        const result = auth.verifyPassword("password", bad_hash);
        try testing.expectError(error.InvalidHashFormat, result);
    }
}

test "Argon2id - timing resistance (constant-time verification)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ally = arena.allocator();

    var auth = try Auth.init(ally, null, null);
    defer auth.deinit();

    const password = "TimingTest123!";
    const hash = try auth.hashPassword(password);

    // Measure verification time for correct password
    const correct_times = 100;
    var correct_durations: [correct_times]u64 = undefined;

    var i: usize = 0;
    while (i < correct_times) : (i += 1) {
        const start = std.time.nanoTimestamp();
        _ = try auth.verifyPassword(password, hash);
        const end = std.time.nanoTimestamp();
        correct_durations[i] = @intCast(end - start);
    }

    // Measure verification time for wrong password (early mismatch)
    const wrong_password = "WrongPassword123!";
    var wrong_durations: [correct_times]u64 = undefined;

    i = 0;
    while (i < correct_times) : (i += 1) {
        const start = std.time.nanoTimestamp();
        _ = try auth.verifyPassword(wrong_password, hash);
        const end = std.time.nanoTimestamp();
        wrong_durations[i] = @intCast(end - start);
    }

    // Calculate average times
    var correct_sum: u64 = 0;
    var wrong_sum: u64 = 0;
    for (correct_durations) |d| correct_sum += d;
    for (wrong_durations) |d| wrong_sum += d;

    const correct_avg = correct_sum / correct_times;
    const wrong_avg = wrong_sum / correct_times;

    // Timing should be similar (within 20% variance)
    // The Argon2id computation dominates, making comparison timing negligible
    const diff = if (correct_avg > wrong_avg)
        correct_avg - wrong_avg
    else
        wrong_avg - correct_avg;

    const variance_pct = (diff * 100) / correct_avg;

    std.debug.print("Correct avg: {}ns, Wrong avg: {}ns, Variance: {}%\n",
        .{ correct_avg, wrong_avg, variance_pct });

    // Variance should be <20% (Argon2id computation dominates)
    try testing.expect(variance_pct < 20);
}

test "Argon2id - performance baseline (100-500ms per OWASP)" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ally = arena.allocator();

    var auth = try Auth.init(ally, null, null);
    defer auth.deinit();

    const password = "PerformanceTest123!";

    // Measure hashing time
    const start = std.time.milliTimestamp();
    const hash = try auth.hashPassword(password);
    const end = std.time.milliTimestamp();

    const duration_ms = end - start;

    std.debug.print("Argon2id hashing took: {}ms\n", .{duration_ms});

    // OWASP recommends 100-500ms per hash for good security/UX balance
    // We'll accept 50-1000ms to account for system variations
    try testing.expect(duration_ms >= 50);
    try testing.expect(duration_ms <= 1000);

    // Verify the hash works
    try testing.expect(try auth.verifyPassword(password, hash));
}

test "Argon2id - salt uniqueness across multiple hashes" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const ally = arena.allocator();

    var auth = try Auth.init(ally, null, null);
    defer auth.deinit();

    const password = "SaltTest123!";
    var salt_set = std.StringHashMap(void).init(ally);

    // Generate 100 hashes and extract salts
    var i: usize = 0;
    while (i < 100) : (i += 1) {
        const hash = try auth.hashPassword(password);

        // Extract salt from PHC format: $argon2id$v=19$m=19456,t=2,p=1$SALT$hash
        const salt_start_idx = std.mem.lastIndexOf(u8, hash[0..hash.len-64], "$");
        try testing.expect(salt_start_idx != null);

        const salt = hash[salt_start_idx.? + 1 .. hash.len - 64 - 1];

        // All salts must be unique
        const result = try salt_set.getOrPut(salt);
        try testing.expect(!result.found_existing);
    }

    // Verify we got 100 unique salts
    try testing.expectEqual(@as(usize, 100), salt_set.count());
}
