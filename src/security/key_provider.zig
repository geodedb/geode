const std = @import("std");

// Key Provider abstraction (skeleton) enabling pluggable key sources (static env, future KMS/HSM).
// CANARY: REQ=REQ-GQL-TDE-003; FEATURE="Key provider abstraction"; ASPECT=SECURITY; STATUS=PARTIAL; TEST=TestCANARY_REQ_GQL_TDE_003_KeyProviderStatic; OWNER=security; UPDATED=2025-09-26

pub const ProviderType = enum {
    StaticEnv,
    MockKms, // deterministic mock for tests & benchmarking
    ExternalKms, // stub external KMS integration (deterministic hash of endpoint+api key)
};

pub const KeyMaterial = struct {
    data_key: [32]u8,
    wal_key: [32]u8,
};

pub const Provider = struct {
    typ: ProviderType,
    // MockKms state (deterministic master seed) - ignored for StaticEnv
    mock_seed: u64 = 0x4b4d535f53454544, // "KMS_SEED"

    pub fn init(typ: ProviderType) Provider {
        return .{ .typ = typ };
    }

    /// Fetch current key material (blocking). For StaticEnv, derives from GEODE_DISK_KEY_HEX.
    pub fn fetch(self: Provider, ally: std.mem.Allocator) !?KeyMaterial {
        _ = ally; // reserved for future allocations
        switch (self.typ) {
            .StaticEnv => return try loadStatic(),
            .MockKms => return self.fetchMockKms(),
            .ExternalKms => return try loadExternalKms(),
        }
    }
};

fn loadStatic() !?KeyMaterial {
    const hex = std.process.getEnvVarOwned(std.heap.page_allocator, "GEODE_DISK_KEY_HEX") catch |e| switch (e) {
        error.EnvironmentVariableNotFound => return null,
        else => return e,
    };
    if (hex.len != 64) {
        std.heap.page_allocator.free(hex);
        return null;
    }
    defer std.heap.page_allocator.free(hex);
    var master: [32]u8 = undefined;
    var i: usize = 0;
    while (i < 32) : (i += 1) {
        master[i] = std.fmt.parseInt(u8, hex[i * 2 .. i * 2 + 2], 16) catch 0;
    }
    const tde = @import("tde_hierarchy");
    const kh = tde.KeyHierarchy.init(master);
    return KeyMaterial{ .data_key = kh.data_key, .wal_key = kh.wal_key };
}

// Deterministic mock KMS: derives two keys from seed using SHA-256(seed || label)
fn derive(seed: u64, label: []const u8, out: *[32]u8) void {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    var seed_buf: [8]u8 = undefined;
    std.mem.writeInt(u64, &seed_buf, seed, .little);
    h.update(&seed_buf);
    h.update(label);
    var digest: [32]u8 = undefined;
    h.final(&digest);
    out.* = digest;
}

fn wrapKey(_: u64, plain: [32]u8) [32]u8 {
    // Mock wrap: XOR with pattern (not secure)
    var wrapped: [32]u8 = undefined;
    for (plain, 0..) |b, i| wrapped[i] = b ^ 0xA5;
    return wrapped;
}

fn unwrapKey(_: u64, wrapped: [32]u8) [32]u8 {
    var plain: [32]u8 = undefined;
    for (wrapped, 0..) |b, i| plain[i] = b ^ 0xA5;
    return plain;
}

fn Provider_fetchMock(self: Provider) KeyMaterial {
    var data_key: [32]u8 = undefined;
    var wal_key: [32]u8 = undefined;
    derive(self.mock_seed, "DATA", &data_key);
    derive(self.mock_seed, "WAL", &wal_key);
    return .{ .data_key = data_key, .wal_key = wal_key };
}

fn fetchMockKms(self: Provider) ?KeyMaterial {
    return Provider_fetchMock(self);
}

// External KMS stub: deterministically derive keys from env (GEODE_KMS_ENDPOINT + GEODE_KMS_API_KEY)
// This is a placeholder until real network KMS binding is implemented.
fn loadExternalKms() !?KeyMaterial {
    const endpoint = std.process.getEnvVarOwned(std.heap.page_allocator, "GEODE_KMS_ENDPOINT") catch |e| switch (e) {
        error.EnvironmentVariableNotFound => return null,
        else => return e,
    };
    defer std.heap.page_allocator.free(endpoint);
    const api_key = std.process.getEnvVarOwned(std.heap.page_allocator, "GEODE_KMS_API_KEY") catch |e| switch (e) {
        error.EnvironmentVariableNotFound => return null,
        else => return e,
    };
    defer std.heap.page_allocator.free(api_key);

    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(endpoint);
    h.update(api_key);
    var digest: [32]u8 = undefined;
    h.final(&digest);

    // Derive two keys: DATA = H(digest||"DATA"), WAL = H(digest||"WAL")
    var data_key: [32]u8 = undefined;
    var wal_key: [32]u8 = undefined;
    deriveDigest(&digest, "DATA", &data_key);
    deriveDigest(&digest, "WAL", &wal_key);
    return KeyMaterial{ .data_key = data_key, .wal_key = wal_key };
}

fn deriveDigest(base: *const [32]u8, label: []const u8, out: *[32]u8) void {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(base);
    h.update(label);
    var dig: [32]u8 = undefined;
    h.final(&dig);
    out.* = dig;
}

// CANARY: REQ=REQ-GQL-TDE-005; FEATURE="ExternalKmsStub"; ASPECT=SECURITY; STATUS=PARTIAL; TEST=TestCANARY_REQ_GQL_TDE_005_ExternalKmsStub; OWNER=security; UPDATED=2025-09-26

// CANARY: REQ=REQ-GQL-TDE-004; FEATURE="MockKMSProvider"; ASPECT=SECURITY; STATUS=PARTIAL; TEST=TestCANARY_REQ_GQL_TDE_004_MockKMS; OWNER=security; UPDATED=2025-09-26

// Basic static env provider unit test placeholder (ensures graceful null when unset)
// (Full CANARY test added via tests harness referencing this module.)

test "key provider static env absent returns null" {
    // Ensure variable not set (ignore error if not present)
    _ = std.os.unsetenvZ("GEODE_DISK_KEY_HEX") catch {};
    const p = Provider.init(.StaticEnv);
    const km = try p.fetch(std.heap.page_allocator);
    try std.testing.expect(km == null);
}

// CANARY: REQ=REQ-GQL-TDE-004; FEATURE="MockKMSProvider"; ASPECT=TEST; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_TDE_004_MockKMS; OWNER=security; UPDATED=2025-09-26
test "mock kms deterministic and distinct seeds differ" {
    var p1 = Provider.init(.MockKms);
    const km1 = (try p1.fetch(std.heap.page_allocator)).?;
    const km2 = (try p1.fetch(std.heap.page_allocator)).?; // repeat fetch, should be identical
    try std.testing.expect(std.mem.eql(u8, &km1.data_key, &km2.data_key));
    try std.testing.expect(std.mem.eql(u8, &km1.wal_key, &km2.wal_key));
    // Different seed => different keys
    var p2 = Provider{ .typ = .MockKms, .mock_seed = 0xDEADBEEFCAFEBABE };
    const km3 = (try p2.fetch(std.heap.page_allocator)).?;
    try std.testing.expect(!std.mem.eql(u8, &km1.data_key, &km3.data_key));
    try std.testing.expect(!std.mem.eql(u8, &km1.wal_key, &km3.wal_key));
}

test "external kms stub deterministic" {
    // Ensure env set
    std.os.setenvZ("GEODE_KMS_ENDPOINT", "https://kms.example.local") catch {};
    std.os.setenvZ("GEODE_KMS_API_KEY", "abc123") catch {};
    const p = Provider.init(.ExternalKms);
    const km1 = (try p.fetch(std.heap.page_allocator)).?;
    const km2 = (try p.fetch(std.heap.page_allocator)).?;
    try std.testing.expect(std.mem.eql(u8, &km1.data_key, &km2.data_key));
    try std.testing.expect(std.mem.eql(u8, &km1.wal_key, &km2.wal_key));

    // Change API key -> different derivation
    std.os.setenvZ("GEODE_KMS_API_KEY", "def456") catch {};
    const km3 = (try p.fetch(std.heap.page_allocator)).?;
    try std.testing.expect(!std.mem.eql(u8, &km1.data_key, &km3.data_key));
    try std.testing.expect(!std.mem.eql(u8, &km1.wal_key, &km3.wal_key));
}
