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

/// The minimum GEODE_MASTER_KEY length in bytes (SONNY-6422).
pub const master_key_min_len: usize = 32;

/// How GEODE_MASTER_KEY is read (GEODE_MASTER_KEY_FORMAT, SONNY-6430).
pub const MasterKeyFormat = enum {
    /// GEODE_MASTER_KEY_FORMAT unset: at least 32 bytes, the first 32 used
    /// as raw bytes. Kept unchanged so every deployment keeps the key its
    /// encrypted fields were written with; a longer value warns at startup.
    legacy,
    /// Exactly 32 bytes, used as they are.
    raw,
    /// Exactly 64 hex characters (either case), decoded to 32 bytes.
    hex,
    /// Standard base64 (padded) of exactly 32 bytes.
    base64,

    /// The format GEODE_MASTER_KEY_FORMAT names; null for an unknown one.
    pub fn parse(name: []const u8) ?MasterKeyFormat {
        if (std.mem.eql(u8, name, "raw")) return .raw;
        if (std.mem.eql(u8, name, "hex")) return .hex;
        if (std.mem.eql(u8, name, "base64")) return .base64;
        return null;
    }
};

/// The format GEODE_MASTER_KEY_FORMAT selects: `.legacy` when it is unset or
/// empty, `error.MasterKeyFormatUnknown` for a name that is not raw, hex or
/// base64.
pub fn masterKeyFormatFromEnv() error{MasterKeyFormatUnknown}!MasterKeyFormat {
    const raw = std.c.getenv("GEODE_MASTER_KEY_FORMAT") orelse return .legacy;
    const name = std.mem.span(raw);
    if (name.len == 0) return .legacy;
    return MasterKeyFormat.parse(name) orelse error.MasterKeyFormatUnknown;
}

pub const MasterKeyParseError = error{ MasterKeyRequired, MasterKeyTooShort, MasterKeyInvalid };

// CANARY: REQ=REQ-SONNY-6430-MASTER-KEY-FORMAT; FEATURE="Key configuration"; ASPECT=ExplicitFormatNoSilentKeyChange; STATUS=TESTED; TEST=tests/test_sonny6430_master_key_format.zig; OWNER=security; UPDATED=2026-11-12
/// The 32-byte FLE master key `value` holds in `format`. Errors name no
/// part of the value. See docs/FIELD_LEVEL_ENCRYPTION.md "Master key format".
pub fn parseMasterKey(value: []const u8, format: MasterKeyFormat) MasterKeyParseError![32]u8 {
    if (value.len == 0) return error.MasterKeyRequired;
    var key: [32]u8 = undefined;
    switch (format) {
        .legacy => {
            if (value.len < master_key_min_len) return error.MasterKeyTooShort;
            @memcpy(&key, value[0..key.len]);
        },
        .raw => {
            if (value.len != key.len) return error.MasterKeyInvalid;
            @memcpy(&key, value);
        },
        .hex => {
            if (value.len != key.len * 2) return error.MasterKeyInvalid;
            _ = std.fmt.hexToBytes(&key, value) catch return error.MasterKeyInvalid;
        },
        .base64 => {
            const dec = std.base64.standard.Decoder;
            const n = dec.calcSizeForSlice(value) catch return error.MasterKeyInvalid;
            if (n != key.len) return error.MasterKeyInvalid;
            dec.decode(&key, value) catch return error.MasterKeyInvalid;
        },
    }
    return key;
}

// CANARY: REQ=REQ-SONNY-6422-ENV-KEY-FAIL-CLOSED; FEATURE="Key configuration"; ASPECT=MasterKeyMinimumLength; STATUS=TESTED; TEST=tests/test_sonny6422_env_key_fail_closed.zig; OWNER=security; UPDATED=2026-11-12
/// The FLE master key from GEODE_MASTER_KEY, read in the format
/// GEODE_MASTER_KEY_FORMAT names (`parseMasterKey`). Unset, the value is
/// used as raw bytes and only its first 32 bytes count (the legacy reading,
/// unchanged).
///
/// SONNY-6422: a shorter value is `error.MasterKeyTooShort`. It used to be
/// hashed with SHA-256 into a key, so a 3-character value was accepted as a
/// working master key. An empty value is unset (`MasterKeyRequired`); it was
/// hashed into the same constant key for every deployment.
///
/// SONNY-6430: a 64-hex-character value gave a key of 32 hex characters
/// (128 bits) with no word that the rest was ignored. The full-entropy
/// readings are opt-in through GEODE_MASTER_KEY_FORMAT, never applied to a
/// value that already works: that would change the key existing encrypted
/// fields were written with and make them unreadable.
pub fn loadMasterKeyFromEnv(allocator: std.mem.Allocator) ![32]u8 {
    const format = try masterKeyFormatFromEnv();
    if (getEnvVarOwned(allocator, "GEODE_MASTER_KEY")) |env_key| {
        defer {
            cb.secureZero(env_key);
            allocator.free(env_key);
        }
        if (env_key.len == 0) return Error.MasterKeyRequired;
        // The caller reports the error (`geode serve` refuses to start).
        return parseMasterKey(env_key, format);
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

// CANARY: REQ=REQ-SONNY-6435-MASTER-KEY-CHECK; FEATURE="Key configuration"; ASPECT=KeyCheckValue; STATUS=TESTED; TEST=tests/test_sonny6435_master_key_check.zig; OWNER=security; UPDATED=2026-11-12
/// SONNY-6435: the file, in the data directory beside the FLE catalog, that
/// records which master key the directory's encrypted fields use.
pub const master_key_check_file_name = "fle_master_key.kcv";
const master_key_check_header = "geode-fle-master-key-check v1 ";
pub const master_key_check_file_len = master_key_check_header.len + 64 + 1;

/// The key check value of a 32-byte master key: HMAC-SHA256 of a fixed label
/// under a key HKDF-derived from the master key. Identifies the key without
/// revealing it, and is not usable as any key FLE derives.
pub fn masterKeyCheckValue(master_key: [32]u8) ![32]u8 {
    var subkey: [32]u8 = undefined;
    defer cb.secureZero(&subkey);
    try cb.Kdf.hkdf(.sha256, &master_key, "", "geode-fle-master-key-check-v1", &subkey);
    var kcv: [32]u8 = undefined;
    _ = try cb.Mac.hmac(.sha256, &subkey, "GEODE FLE master key check value", &kcv);
    return kcv;
}

/// The check file's contents for `master_key`: one text line.
pub fn encodeMasterKeyCheck(master_key: [32]u8) ![master_key_check_file_len]u8 {
    var out: [master_key_check_file_len]u8 = undefined;
    @memcpy(out[0..master_key_check_header.len], master_key_check_header);
    const hex = std.fmt.bytesToHex(try masterKeyCheckValue(master_key), .lower);
    @memcpy(out[master_key_check_header.len..][0..64], &hex);
    out[out.len - 1] = '\n';
    return out;
}

/// Whether the check file contents `recorded` were written for
/// `master_key`. `error.MasterKeyCheckCorrupt` for contents that are not a
/// check file.
pub fn masterKeyCheckMatches(recorded: []const u8, master_key: [32]u8) !bool {
    const body = std.mem.trimEnd(u8, recorded, "\r\n");
    if (body.len != master_key_check_header.len + 64 or !std.mem.startsWith(u8, body, master_key_check_header)) {
        return error.MasterKeyCheckCorrupt;
    }
    var stored: [32]u8 = undefined;
    _ = std.fmt.hexToBytes(&stored, body[master_key_check_header.len..]) catch return error.MasterKeyCheckCorrupt;
    const expected = try masterKeyCheckValue(master_key);
    return cb.timingSafeEql(&stored, &expected);
}

pub fn initFromEnv(allocator: std.mem.Allocator) !*KeyManager {
    return KeyManager.init(allocator, try loadMasterKeyFromEnv(allocator));
}

pub fn currentKeyVersion(manager: *KeyManager, key_path: []const u8) u16 {
    return manager.key_versions.get(key_path) orelse 1;
}

/// SONNY-6463: the fle KeyManager's own stats type (an anonymous struct
/// declared there; one declared here is a different type, so this did not
/// compile once a caller, the inline test, used it).
pub fn cacheStats(manager: *KeyManager) @typeInfo(@TypeOf(KeyManager.cacheStats)).@"fn".return_type.? {
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
    try cb.Csprng.bytes(&new_trk);

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
    try cb.Csprng.bytes(&new_master);

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
