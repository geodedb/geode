const std = @import("std");
const cb = @import("crypto_backend");

// Zig 0.16 compat: std.crypto.random removed. Use getrandom syscall.
fn compat_fillRandom(buf: []u8) void {
    if (comptime @import("builtin").os.tag == .linux) {
        _ = std.os.linux.getrandom(buf.ptr, buf.len, 0);
    } else {
        std.c.arc4random_buf(buf.ptr, buf.len);
    }
}

// Zig 0.16 compat: std.process.getEnvVarOwned was removed.
fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) error{ EnvironmentVariableNotFound, OutOfMemory }![]u8 {
    const name_z = allocator.dupeZ(u8, name) catch return error.OutOfMemory;
    defer allocator.free(name_z);
    const ptr = std.c.getenv(name_z) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, std.mem.span(ptr));
}

const fle = @import("fle_lib");
const types = @import("fle_key_types");
const fle_aead = @import("fle_aead");
const hkdf = @import("fle_hkdf");

// Direct externalization of the FLE key manager. Geode-specific behavior is
// limited to environment-based master-key loading and explicit rewrap helpers.
pub const Error = fle.key_manager.Error;
pub const KeyManager = fle.KeyManager;

pub fn loadMasterKeyFromEnv(allocator: std.mem.Allocator) ![32]u8 {
    var master_key: [32]u8 = undefined;
    if (getEnvVarOwned(allocator, "GEODE_MASTER_KEY")) |env_key| {
        defer {
            cb.secureZero(env_key);
            allocator.free(env_key);
        }
        if (env_key.len >= master_key.len) {
            @memcpy(&master_key, env_key[0..master_key.len]);
        } else {
            _ = try cb.Hash.digest(.sha256, env_key, &master_key);
        }
        return master_key;
    } else |_| {
        std.log.err(
            "SECURITY CRITICAL: GEODE_MASTER_KEY environment variable is REQUIRED. " ++
                "FLE cannot operate without a properly configured master key. " ++
                "Set GEODE_MASTER_KEY to a 32+ byte secret value.",
            .{},
        );
        return Error.MasterKeyRequired;
    }
}

pub fn initFromEnv(allocator: std.mem.Allocator) !*KeyManager {
    return KeyManager.init(allocator, try loadMasterKeyFromEnv(allocator));
}

pub fn currentKeyVersion(manager: *KeyManager, key_path: []const u8) u16 {
    return manager.key_versions.get(key_path) orelse 1;
}

pub fn cacheStats(manager: *KeyManager) struct { hits: u64, misses: u64 } {
    return manager.cacheStats();
}

fn wrapKey(
    allocator: std.mem.Allocator,
    key_to_wrap: []const u8,
    wrapping_key: []const u8,
) !fle_aead.EnvelopeV1 {
    const aad = try fle_aead.makeAAD(allocator, "system", "sys", "key_wrap", "0", 1);
    defer allocator.free(aad);

    return fle_aead.encryptField(allocator, .aes256_gcm, wrapping_key, aad, key_to_wrap, 1);
}

fn unwrapKey(
    allocator: std.mem.Allocator,
    envelope: fle_aead.EnvelopeV1,
    wrapping_key: []const u8,
) ![]u8 {
    const aad = try fle_aead.makeAAD(allocator, "system", "sys", "key_wrap", "0", 1);
    defer allocator.free(aad);

    return fle_aead.decryptField(allocator, wrapping_key, aad, envelope);
}

pub fn rewrapSchemaKey(
    allocator: std.mem.Allocator,
    manager: *KeyManager,
    tenant: []const u8,
    schema: []const u8,
) !void {
    var old_trk = try hkdf.deriveTRK(&manager.master_key, tenant);
    defer cb.secureZero(&old_trk);

    var sk = try hkdf.deriveSK(&old_trk, schema);
    defer cb.secureZero(&sk);

    var wrapped_sk = try wrapKey(allocator, &sk, &old_trk);
    defer wrapped_sk.deinit(allocator);

    const unwrapped_sk = try unwrapKey(allocator, wrapped_sk, &old_trk);
    defer {
        cb.secureZero(unwrapped_sk);
        allocator.free(unwrapped_sk);
    }

    var new_trk: [32]u8 = undefined;
    compat_fillRandom(&new_trk);

    var rewrapped_sk = try wrapKey(allocator, unwrapped_sk, &new_trk);
    defer rewrapped_sk.deinit(allocator);

    manager.clearCache();
}

pub fn rewrapTenantRootKey(
    allocator: std.mem.Allocator,
    manager: *KeyManager,
    tenant: []const u8,
) !void {
    var trk = try hkdf.deriveTRK(&manager.master_key, tenant);
    defer cb.secureZero(&trk);

    var wrapped_trk = try wrapKey(allocator, &trk, &manager.master_key);
    defer wrapped_trk.deinit(allocator);

    const unwrapped_trk = try unwrapKey(allocator, wrapped_trk, &manager.master_key);
    defer {
        cb.secureZero(unwrapped_trk);
        allocator.free(unwrapped_trk);
    }

    var new_master: [32]u8 = undefined;
    compat_fillRandom(&new_master);

    var rewrapped_trk = try wrapKey(allocator, unwrapped_trk, &new_master);
    defer rewrapped_trk.deinit(allocator);

    manager.clearCache();
}

test "currentKeyVersion defaults to one" {
    const master_key: [32]u8 = [_]u8{0x42} ** 32;
    const manager = try KeyManager.init(std.testing.allocator, master_key);
    defer manager.deinit();

    try std.testing.expectEqual(@as(u16, 1), currentKeyVersion(manager, "tenant:schema:field"));
}

test "direct key manager FEK derivation remains cached" {
    const master_key: [32]u8 = [_]u8{0x24} ** 32;
    const manager = try KeyManager.init(std.testing.allocator, master_key);
    defer manager.deinit();

    const ids = types.KeyIds{
        .tenant = "tenant1",
        .schema = "Person",
        .field = "ssn",
        .version = 1,
    };

    const fek1 = try manager.getFEK(ids);
    const fek2 = try manager.getFEK(ids);

    try std.testing.expectEqualSlices(u8, &fek1, &fek2);
    const stats = cacheStats(manager);
    try std.testing.expectEqual(@as(u64, 1), stats.hits);
    try std.testing.expectEqual(@as(u64, 1), stats.misses);
}
