const std = @import("std");

// kms.zig - KMS provider abstraction scaffold
// CANARY: REQ=REQ-GQL-SEC-KMS-001; FEATURE="KMSProviderScaffold"; ASPECT=SECURITY; STATUS=STUB; TEST=tests/test_kms_scaffold.zig; OWNER=security; UPDATED=2025-09-26

pub const MasterKeyId = []const u8;

pub const WrappedKey = struct {
    key_id: MasterKeyId,
    ciphertext: []u8,
};

pub const KMSProvider = struct {
    /// Returns a stable master key identifier (e.g., ARN or UUID)
    pub fn fetchActiveMasterKey(self: *KMSProvider, allocator: *std.mem.Allocator) !MasterKeyId {
        _ = self;
        _ = allocator;
        return "local-dev-master-key"; // placeholder
    }

    /// Wrap a plaintext data key (encrypt under master key)
    pub fn wrapDataKey(self: *KMSProvider, allocator: *std.mem.Allocator, plaintext: []const u8) !WrappedKey {
        var buf = try allocator.alloc(u8, plaintext.len);
        // Simple XOR placeholder (DO NOT USE IN PROD) - replaced by real envelope encryption
        for (plaintext, 0..) |b, i| buf[i] = b ^ 0xAA;
        return .{ .key_id = try self.fetchActiveMasterKey(allocator), .ciphertext = buf };
    }

    /// Unwrap (decrypt) a wrapped data key
    pub fn unwrapDataKey(self: *KMSProvider, ciphertext: []const u8, allocator: *std.mem.Allocator) ![]u8 {
        _ = self; // unused in scaffold
        var buf = try allocator.alloc(u8, ciphertext.len);
        for (ciphertext, 0..) |b, i| buf[i] = b ^ 0xAA;
        return buf;
    }
};

// Factory for default provider (local dev mock)
pub fn defaultProvider() KMSProvider {
    return KMSProvider{};
}

test "kms scaffold wrap/unwrap roundtrip" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = &gpa.allocator;
    var provider = defaultProvider();
    const plaintext = "0123456789abcdef";
    const wrapped = try provider.wrapDataKey(alloc, plaintext);
    defer alloc.free(wrapped.ciphertext);
    const unwrapped = try provider.unwrapDataKey(wrapped.ciphertext, alloc);
    defer alloc.free(unwrapped);
    try std.testing.expect(std.mem.eql(u8, plaintext, unwrapped));
}
