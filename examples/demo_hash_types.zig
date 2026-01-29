const std = @import("std");
const geode = @import("geode");

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const hash_module = geode.types.hash;

    std.debug.print("\n=== Geode Hash Types Demo ===\n\n", .{});

    // Demonstrate Blake2b-256
    {
        std.debug.print("1. Blake2b-256 Hash:\n", .{});
        const data = "Hello, Geode!";
        const h = try hash_module.hash(allocator, .BLAKE2B_256, data, null, null);
        defer allocator.free(h.digest);

        std.debug.print("   Input: \"{s}\"\n", .{data});
        std.debug.print("   Algorithm: {s}\n", .{hash_module.algName(h.alg)});
        std.debug.print("   Digest ({} bytes): ", .{h.digest.len});
        for (h.digest) |byte| {
            std.debug.print("{x:0>2}", .{byte});
        }
        std.debug.print("\n\n", .{});
    }

    // Demonstrate Blake2b-512
    {
        std.debug.print("2. Blake2b-512 Hash:\n", .{});
        const data = "Graph Database";
        const h = try hash_module.hash(allocator, .BLAKE2B_512, data, null, null);
        defer allocator.free(h.digest);

        std.debug.print("   Input: \"{s}\"\n", .{data});
        std.debug.print("   Algorithm: {s}\n", .{hash_module.algName(h.alg)});
        std.debug.print("   Digest ({} bytes): ", .{h.digest.len});
        for (h.digest[0..32]) |byte| { // Show first 32 bytes
            std.debug.print("{x:0>2}", .{byte});
        }
        std.debug.print("...\n\n", .{});
    }

    // Demonstrate Blake2s-256
    {
        std.debug.print("3. Blake2s-256 Hash:\n", .{});
        const data = "Compact hash";
        const h = try hash_module.hash(allocator, .BLAKE2S_256, data, null, null);
        defer allocator.free(h.digest);

        std.debug.print("   Input: \"{s}\"\n", .{data});
        std.debug.print("   Algorithm: {s}\n", .{hash_module.algName(h.alg)});
        std.debug.print("   Digest ({} bytes): ", .{h.digest.len});
        for (h.digest[0..16]) |byte| { // Show first 16 bytes
            std.debug.print("{x:0>2}", .{byte});
        }
        std.debug.print("...\n\n", .{});
    }

    // Demonstrate Argon2id password hashing
    {
        std.debug.print("4. Argon2id Password Hashing:\n", .{});
        const password = "SecurePassword123!";
        const salt = "RandomSalt123456"; // In real use, generate random salt

        // Use different presets
        const presets = [_]struct {
            name: []const u8,
            params: geode.storage.heap.Argon2Params,
        }{
            .{ .name = "Interactive", .params = hash_module.Argon2Presets.interactive },
            .{ .name = "Moderate", .params = hash_module.Argon2Presets.moderate },
            .{ .name = "OWASP", .params = hash_module.Argon2Presets.owasp },
        };

        for (presets) |preset| {
            const h = try hash_module.hash(allocator, .ARGON2ID, password, salt, preset.params);
            defer allocator.free(h.digest);
            defer if (h.salt) |s| allocator.free(s);

            std.debug.print("   Preset: {s}\n", .{preset.name});
            std.debug.print("     Iterations: {}\n", .{preset.params.iterations});
            std.debug.print("     Memory: {} KB\n", .{preset.params.memory_kb});
            std.debug.print("     Parallelism: {}\n", .{preset.params.parallelism});
            std.debug.print("     Hash: ", .{});
            for (h.digest[0..16]) |byte| {
                std.debug.print("{x:0>2}", .{byte});
            }
            std.debug.print("...\n", .{});
        }
        std.debug.print("\n", .{});
    }

    // Demonstrate KDF functions
    {
        std.debug.print("5. Key Derivation Functions (KDF):\n", .{});

        // Blake2b KDF
        const key = "MasterKey";
        const context = "user-auth-v1";

        const blake2b_kdf = try hash_module.blake2bKdf(allocator, 32, context, key);
        defer allocator.free(blake2b_kdf);

        std.debug.print("   Blake2b KDF:\n", .{});
        std.debug.print("     Context: \"{s}\"\n", .{context});
        std.debug.print("     Derived key (32 bytes): ", .{});
        for (blake2b_kdf[0..16]) |byte| {
            std.debug.print("{x:0>2}", .{byte});
        }
        std.debug.print("...\n", .{});

        // Blake2s KDF
        const blake2s_kdf = try hash_module.blake2sKdf(allocator, 16, context, key);
        defer allocator.free(blake2s_kdf);

        std.debug.print("   Blake2s KDF:\n", .{});
        std.debug.print("     Context: \"{s}\"\n", .{context});
        std.debug.print("     Derived key (16 bytes): ", .{});
        for (blake2s_kdf) |byte| {
            std.debug.print("{x:0>2}", .{byte});
        }
        std.debug.print("\n\n", .{});
    }

    // Demonstrate constant-time comparison
    {
        std.debug.print("6. Secure Hash Comparison:\n", .{});
        const h1 = try hash_module.hash(allocator, .BLAKE2B_256, "data", null, null);
        defer allocator.free(h1.digest);

        const h2 = try hash_module.hash(allocator, .BLAKE2B_256, "data", null, null);
        defer allocator.free(h2.digest);

        const h3 = try hash_module.hash(allocator, .BLAKE2B_256, "different", null, null);
        defer allocator.free(h3.digest);

        std.debug.print("   h1 == h2 (same data): {}\n", .{hash_module.equals(h1, h2)});
        std.debug.print("   h1 == h3 (different data): {}\n", .{hash_module.equals(h1, h3)});
        std.debug.print("   (Using constant-time comparison)\n", .{});
    }

    std.debug.print("\n=== Demo Complete ===\n", .{});
}
