const std = @import("std");

// CANARY: FLE_KEY_MANAGEMENT - Key Management Types
// CANARY: REQ=REQ-FLE-KEY-001; FEATURE="FieldLevelEncryption"; ASPECT=SECURITY; STATUS=IMPL; OWNER=security; UPDATED=2025-10-15

/// Key identifiers for hierarchical key management
pub const KeyIds = struct {
    tenant: []const u8,
    schema: []const u8,
    field: []const u8,
    version: u16,
};

/// Key metadata stored with wrapped keys
pub const KeyMetadata = struct {
    key_id: []const u8,
    version: u16,
    created_at: i64,
    rotated_at: ?i64 = null,
    algorithm: []const u8, // "AES-256-GCM" or "CHACHA20-POLY1305"
    wrapped_by: []const u8, // Parent key ID
    status: KeyStatus = .active,

    pub const KeyStatus = enum {
        active,
        rotating,
        deprecated,
        destroyed,
    };
};

/// Wrapped key envelope for storage
pub const WrappedKeyEnvelope = struct {
    metadata: KeyMetadata,
    wrapped_key: []u8, // Encrypted key material
    nonce: [12]u8,
    tag: [16]u8,

    pub fn deinit(self: *WrappedKeyEnvelope, allocator: std.mem.Allocator) void {
        allocator.free(self.wrapped_key);
    }
};

/// Key version for rotation tracking
pub const KeyVersion = struct {
    version: u16,
    created_at: i64,
    status: KeyMetadata.KeyStatus,
};

/// Rotation statistics
pub const RotationStats = struct {
    total_records: u64,
    migrated_records: u64,
    progress_percent: f64,
    started_at: i64,
    estimated_completion: ?i64 = null,
};
