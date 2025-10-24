const std = @import("std");

// CANARY: REQ=REQ-GQL-046; FEATURE="TDE Key Hierarchy"; ASPECT=Storage; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_046_KeyHierarchy; OWNER=security; UPDATED=2025-09-20

/// Simple hierarchical key derivation for Transparent Data Encryption (TDE).
/// We currently derive distinct data and WAL keys from the master key using
/// domain separated SHA-256(master_key || domain_tag). This is deterministic,
/// stable across process restarts, and ensures distinct keys for different
/// encryption domains without requiring an external KDF dependency.
pub const KeyHierarchy = struct {
    master: [32]u8,
    data_key: [32]u8,
    wal_key: [32]u8,

    pub fn init(master: [32]u8) KeyHierarchy {
        var kh = KeyHierarchy{ .master = master, .data_key = undefined, .wal_key = undefined };
        deriveChildKey(&master, "DATAv1", &kh.data_key);
        deriveChildKey(&master, "WALv1", &kh.wal_key);
        return kh;
    }
};

/// Derive a child key using SHA-256(master || domain) -> 32 bytes.
pub fn deriveChildKey(master: *const [32]u8, domain: []const u8, out: *[32]u8) void {
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(master); // array coerces to slice
    h.update(domain);
    var digest: [32]u8 = undefined;
    h.final(&digest);
    // Copy digest into out
    out.* = digest;
}
