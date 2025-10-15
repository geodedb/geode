const std = @import("std");
const fle_catalog = @import("schema/catalog.zig");
const fle_annotations = @import("schema/annotations.zig");
const fle_aead = @import("crypto/aead.zig");
const key_manager_mod = @import("keys/manager.zig");
const key_types = @import("keys/types.zig");
const blind_index_mod = @import("index/blind_index.zig");

// CANARY: FLE_INTEGRATION - Field-Level Encryption Integration Layer
// CANARY: REQ=REQ-FLE-INTEGRATION-001; FEATURE="FieldLevelEncryption"; ASPECT=INTEGRATION; STATUS=IMPL; OWNER=security; UPDATED=2025-10-15

/// Integration layer for field-level encryption
/// This module provides high-level encryption/decryption operations
/// that integrate with the schema catalog, key manager, and blind index

// Global singletons for key management and blind index
var global_key_manager_instance: ?*key_manager_mod.KeyManager = null;
var global_blind_index_instance: ?*blind_index_mod.BlindIndex = null;
var global_mutex: std.Thread.Mutex = .{};

pub const EncryptionContext = struct {
    tenant_id: []const u8,
    schema_name: []const u8,
    allocator: std.mem.Allocator,
};

/// Get or create global key manager
fn getGlobalKeyManager(allocator: std.mem.Allocator) !*key_manager_mod.KeyManager {
    global_mutex.lock();
    defer global_mutex.unlock();

    if (global_key_manager_instance) |km| {
        return km;
    }

    const km = try key_manager_mod.KeyManager.init(allocator);
    global_key_manager_instance = km;
    return km;
}

/// Get or create global blind index
fn getGlobalBlindIndex(allocator: std.mem.Allocator) !*blind_index_mod.BlindIndex {
    global_mutex.lock();
    defer global_mutex.unlock();

    if (global_blind_index_instance) |bi| {
        return bi;
    }

    const bi = try allocator.create(blind_index_mod.BlindIndex);
    bi.* = blind_index_mod.BlindIndex.init(allocator);
    global_blind_index_instance = bi;
    return bi;
}

/// Encrypt a field value if encryption is enabled for this field
/// Returns the original value if encryption is not configured
pub fn encryptFieldIfNeeded(
    ctx: EncryptionContext,
    type_name: []const u8,
    field_name: []const u8,
    plaintext: []const u8,
    record_id: []const u8,
) ![]const u8 {
    // 1. Get global catalog
    const catalog = try fle_catalog.globalCatalog(ctx.allocator);

    // 2. Check if field is encrypted
    if (!catalog.isFieldEncrypted(type_name, field_name)) {
        return plaintext;
    }

    // 3. Get field metadata
    const type_meta = catalog.getType(type_name) orelse return plaintext;
    const field_meta = type_meta.getField(field_name) orelse return plaintext;

    if (!field_meta.isEncrypted()) {
        return plaintext;
    }

    // 4. Get FEK from key manager
    const key_manager = try getGlobalKeyManager(ctx.allocator);
    const key_ids = key_types.KeyIds{
        .tenant = ctx.tenant_id,
        .schema = ctx.schema_name,
        .field = field_name,
        .version = 1, // TODO: Support key rotation
    };
    const fek = try key_manager.getFEK(key_ids);

    // 5. Construct AAD
    const aad = try fle_aead.makeAAD(
        ctx.allocator,
        ctx.tenant_id,
        ctx.schema_name,
        field_name,
        record_id,
        key_ids.version,
    );
    defer ctx.allocator.free(aad);

    // 6. Encrypt using AEAD
    const alg = switch (field_meta.encryption.algorithm) {
        .aes256_gcm => fle_aead.Alg.aes256_gcm,
        .chacha20_poly1305 => fle_aead.Alg.chacha20_poly1305,
    };

    var envelope = try fle_aead.encryptField(
        ctx.allocator,
        alg,
        &fek,
        aad,
        plaintext,
        null, // Random nonce
    );
    defer envelope.deinit(ctx.allocator);

    // 7. If searchable, update blind index
    if (field_meta.isSearchable()) {
        const blind_index = try getGlobalBlindIndex(ctx.allocator);
        const bik = try key_manager.getBIK(key_ids);

        try blind_index.put(
            ctx.schema_name,
            field_name,
            bik,
            plaintext,
            record_id,
        );
    }

    // 8. Serialize envelope to bytes and return
    const serialized = try envelope.serialize(ctx.allocator);
    return serialized;
}

/// Decrypt a field value if it's encrypted
/// Returns the original value if it's not an encrypted envelope
pub fn decryptFieldIfNeeded(
    ctx: EncryptionContext,
    type_name: []const u8,
    field_name: []const u8,
    data: []const u8,
    record_id: []const u8,
    check_rbac: bool,
) ![]const u8 {
    // 1. Get global catalog
    const catalog = try fle_catalog.globalCatalog(ctx.allocator);

    // 2. Check if field is encrypted
    if (!catalog.isFieldEncrypted(type_name, field_name)) {
        return data;
    }

    // 3. If RBAC check required, verify access
    if (check_rbac and !canReadPlaintext(ctx, type_name, field_name)) {
        // Return redacted placeholder
        return try ctx.allocator.dupe(u8, "[REDACTED]");
    }

    // Check if data looks like an encrypted envelope (minimum size check)
    if (data.len < 35) {
        // Not an encrypted envelope, return as-is
        return data;
    }

    // 4. Try to parse envelope
    var envelope = fle_aead.EnvelopeV1.deserialize(ctx.allocator, data) catch |err| {
        // If deserialization fails, assume it's plaintext (not yet encrypted)
        if (err == fle_aead.Error.InvalidEnvelope) {
            return data;
        }
        return err;
    };
    defer envelope.deinit(ctx.allocator);

    // 5. Get FEK from key manager
    const key_manager = try getGlobalKeyManager(ctx.allocator);
    const key_ids = key_types.KeyIds{
        .tenant = ctx.tenant_id,
        .schema = ctx.schema_name,
        .field = field_name,
        .version = envelope.key_version,
    };
    const fek = try key_manager.getFEK(key_ids);

    // 6. Construct AAD (must match encryption)
    const aad = try fle_aead.makeAAD(
        ctx.allocator,
        ctx.tenant_id,
        ctx.schema_name,
        field_name,
        record_id,
        envelope.key_version,
    );
    defer ctx.allocator.free(aad);

    // 7. Decrypt
    const plaintext = try fle_aead.decryptField(
        ctx.allocator,
        &fek,
        aad,
        envelope,
    );

    // 8. Return plaintext
    return plaintext;
}

/// Check if a field value matches a query value using blind index
/// Returns a list of record IDs that match the query value
pub fn lookupEncryptedField(
    ctx: EncryptionContext,
    type_name: []const u8,
    field_name: []const u8,
    query_value: []const u8,
) !?[]const []const u8 {
    // 1. Get global catalog
    const catalog = try fle_catalog.globalCatalog(ctx.allocator);

    // 2. Check if field is searchable
    if (!catalog.isFieldSearchable(type_name, field_name)) {
        return null; // Not searchable, fall back to full scan
    }

    // 3. Get BIK from key manager
    const key_manager = try getGlobalKeyManager(ctx.allocator);
    const key_ids = key_types.KeyIds{
        .tenant = ctx.tenant_id,
        .schema = ctx.schema_name,
        .field = field_name,
        .version = 1,
    };
    const bik = try key_manager.getBIK(key_ids);

    // 4. Get blind index
    const blind_index = try getGlobalBlindIndex(ctx.allocator);

    // 5. Lookup record IDs
    const record_ids = try blind_index.lookup(
        ctx.schema_name,
        field_name,
        bik,
        query_value,
    );

    return record_ids;
}

/// Check if a field value matches a query value using blind index (legacy API)
/// Returns true if the field is searchable and matches, false otherwise
pub fn matchesEncryptedField(
    ctx: EncryptionContext,
    type_name: []const u8,
    field_name: []const u8,
    encrypted_value: []const u8,
    query_value: []const u8,
) !bool {
    _ = encrypted_value; // Not used in this implementation

    const record_ids_opt = try lookupEncryptedField(ctx, type_name, field_name, query_value);

    if (record_ids_opt) |record_ids| {
        // If we got results, it means the field is searchable and has matches
        return record_ids.len > 0;
    }

    // Field is not searchable, return false (fall back to full scan)
    return false;
}

/// Helper to construct AAD (Additional Authenticated Data) for AEAD
fn makeAAD(
    allocator: std.mem.Allocator,
    tenant_id: []const u8,
    schema_name: []const u8,
    field_name: []const u8,
    record_id: []const u8,
    version: u16,
) ![]const u8 {
    return try std.fmt.allocPrint(
        allocator,
        "{s}\x1f{s}\x1f{s}\x1f{s}\x1f{d}",
        .{ tenant_id, schema_name, field_name, record_id, version },
    );
}

/// Check RBAC permission to read plaintext for a field
fn canReadPlaintext(
    ctx: EncryptionContext,
    type_name: []const u8,
    field_name: []const u8,
) bool {
    // Get global catalog
    const catalog = fle_catalog.globalCatalog(ctx.allocator) catch return true;

    // Get field metadata
    const type_meta = catalog.getType(type_name) orelse return true;
    const field_meta = type_meta.getField(field_name) orelse return true;

    // If no visibility config, allow access
    if (field_meta.visibility.to_roles.len == 0) {
        return true;
    }

    // TODO: Get current user/role from session context
    // For now, we don't have session context in EncryptionContext
    // This will need to be enhanced when RBAC session management is added
    // For testing purposes, allow all reads
    // In production, this should:
    // 1. Get current user/role from ctx (need to add to EncryptionContext)
    // 2. Check if user's role is in field_meta.visibility.to_roles
    // 3. Return true if authorized, false otherwise

    return true; // Allow all for now - will fail RBAC test as expected
}

test "FLE integration placeholder" {
    const testing = std.testing;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    const ctx = EncryptionContext{
        .tenant_id = "tenant1",
        .schema_name = "myschema",
        .allocator = allocator,
    };

    // Test that placeholder functions don't crash
    const result = try encryptFieldIfNeeded(ctx, "Person", "ssn", "123-45-6789", "node_1");
    try testing.expectEqualStrings("123-45-6789", result);

    const decrypt_result = try decryptFieldIfNeeded(ctx, "Person", "ssn", "123-45-6789", "node_1", false);
    try testing.expectEqualStrings("123-45-6789", decrypt_result);

    const match_result = try matchesEncryptedField(ctx, "Person", "ssn", "encrypted", "123-45-6789");
    try testing.expect(!match_result);
}
