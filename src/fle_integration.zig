const std = @import("std");
const fle_catalog = @import("schema/fle_catalog.zig");
const fle_annotations = @import("schema/annotations.zig");
const fle_aead = @import("fle_aead");
const key_manager_mod = @import("fle_key_manager");
const key_types = @import("fle_key_types");
const blind_index_mod = @import("fle_blind_index");

// Field-Level Encryption Integration Layer
// CANARY: REQ=REQ-FLE-INTEGRATION-001; FEATURE="FieldLevelEncryption"; ASPECT=INTEGRATION; STATUS=TESTED; TEST=tests/test_tde_kms_integration.zig; OWNER=security; UPDATED=2026-01-15

// Re-export modules for external access
pub const catalog_mod = fle_catalog;
pub const fle_aead_mod = fle_aead;

/// Integration layer for field-level encryption
/// This module provides high-level encryption/decryption operations
/// that integrate with the schema catalog, key manager, and blind index

// Global singletons for key management and blind index
var global_key_manager_instance: ?*key_manager_mod.KeyManager = null;
var global_blind_index_instance: ?*blind_index_mod.BlindIndex = null;
var global_mutex: std.Thread.Mutex = .{};

// Global current user role for RBAC (thread-local in multi-threaded env)
var global_current_user_role: ?[]const u8 = null;

/// Set the current user role for RBAC checks
/// This should be called at the start of a session/transaction
pub fn setCurrentUserRole(role: ?[]const u8) void {
    global_mutex.lock();
    defer global_mutex.unlock();
    global_current_user_role = role;
}

/// Get the current user role
/// Checks environment variable GEODE_CURRENT_ROLE first, then falls back to global variable
// P2-3: Use static GPA for env var reading
var role_gpa: std.heap.GeneralPurposeAllocator(.{}) = .{};
var role_gpa_init = false;

pub fn getCurrentUserRole() ?[]const u8 {
    // Check environment variable first (for CLI testing across process boundaries)
    if (!role_gpa_init) {
        role_gpa_init = true;
    }
    if (std.process.getEnvVarOwned(role_gpa.allocator(), "GEODE_CURRENT_ROLE")) |env_role| {
        return env_role;
    } else |_| {
        // Fall back to global variable
        global_mutex.lock();
        defer global_mutex.unlock();
        return global_current_user_role;
    }
}

pub const EncryptionContext = struct {
    tenant_id: []const u8,
    schema_name: []const u8,
    allocator: std.mem.Allocator,
    current_user_role: ?[]const u8 = null, // User's current role for RBAC checks
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

// GAP-0083: Key rotation support
// CANARY: REQ=REQ-FLE-ROTATION-002; FEATURE="FLEKeyRotation"; ASPECT=KeyManagement; STATUS=TESTED; TEST=geodetestlab/specs/fle_rotation.yml; OWNER=security; UPDATED=2026-01-10

/// Get the current key version for a field
/// Returns 1 if no rotation has occurred, otherwise returns the current version
pub fn getCurrentKeyVersion(ctx: EncryptionContext, field_name: []const u8) !u16 {
    const key_manager = try getGlobalKeyManager(ctx.allocator);
    const key_path = try std.fmt.allocPrint(ctx.allocator, "{s}:{s}:{s}", .{
        ctx.tenant_id,
        ctx.schema_name,
        field_name,
    });
    defer ctx.allocator.free(key_path);

    // Get version from key manager (defaults to 1 if not set)
    return key_manager.key_versions.get(key_path) orelse 1;
}

/// Rotate the FLE key for a field to a new version
/// New encryptions will use the new version; old versions remain readable
/// Returns the new key version
pub fn rotateFieldKey(
    allocator: std.mem.Allocator,
    tenant_id: []const u8,
    schema_name: []const u8,
    field_name: []const u8,
) !u16 {
    const key_manager = try getGlobalKeyManager(allocator);
    return key_manager.rotateFEK(tenant_id, schema_name, field_name);
}

/// Re-encrypt a single field value from old version to current version
/// Used during key rotation migration
pub fn reEncryptField(
    ctx: EncryptionContext,
    type_name: []const u8,
    field_name: []const u8,
    encrypted_data: []const u8,
    record_id: []const u8,
) ![]const u8 {
    // Decrypt with old key version (embedded in envelope)
    const plaintext = try decryptFieldIfNeeded(ctx, type_name, field_name, encrypted_data, record_id, false);
    defer if (!std.mem.eql(u8, plaintext.ptr, encrypted_data.ptr)) {
        // Only free if we allocated new memory (decryption happened)
        ctx.allocator.free(plaintext);
    };

    // Re-encrypt with current version
    return encryptFieldIfNeeded(ctx, type_name, field_name, plaintext, record_id);
}

/// Get key rotation status for a field
pub const RotationStatus = struct {
    current_version: u16,
    records_at_current: u64,
    records_at_older: u64,
    fully_rotated: bool,
};

/// Check rotation status - in real implementation would scan encrypted data versions
pub fn getRotationStatus(
    ctx: EncryptionContext,
    field_name: []const u8,
) !RotationStatus {
    const current_version = try getCurrentKeyVersion(ctx, field_name);

    // In a real implementation, this would scan the storage to count
    // records at each key version. For now, return conservative estimate.
    return RotationStatus{
        .current_version = current_version,
        .records_at_current = 0, // Would be populated by storage scan
        .records_at_older = if (current_version > 1) 1 else 0, // Conservative
        .fully_rotated = current_version == 1, // Only true if never rotated
    };
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

    // 4. Get FEK from key manager using current version
    // GAP-0083: Support key rotation - use getCurrentKeyVersion to get latest
    // CANARY: REQ=REQ-FLE-ROTATION-001; FEATURE="FLEKeyRotation"; ASPECT=Encryption; STATUS=TESTED; TEST=geodetestlab/specs/fle_rotation.yml; OWNER=security; UPDATED=2026-01-10
    const key_manager = try getGlobalKeyManager(ctx.allocator);
    const current_version = try getCurrentKeyVersion(ctx, field_name);
    const key_ids = key_types.KeyIds{
        .tenant = ctx.tenant_id,
        .schema = ctx.schema_name,
        .field = field_name,
        .version = current_version,
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
        // If field is searchable, throw error (search operations require privilege)
        // If field is not searchable, return redacted placeholder (projection only)
        if (catalog.isFieldSearchable(type_name, field_name)) {
            return fle_aead.Error.SearchNotPermitted;
        }
        // Return redacted placeholder for non-searchable fields
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

    // 3. Check RBAC - user must have READ_PLAINTEXT privilege to search encrypted fields
    if (!canReadPlaintext(ctx, type_name, field_name)) {
        return fle_aead.Error.SearchNotPermitted;
    }

    // 4. Get BIK from key manager
    const key_manager = try getGlobalKeyManager(ctx.allocator);
    const key_ids = key_types.KeyIds{
        .tenant = ctx.tenant_id,
        .schema = ctx.schema_name,
        .field = field_name,
        .version = 1,
    };
    const bik = try key_manager.getBIK(key_ids);

    // 5. Get blind index
    const blind_index = try getGlobalBlindIndex(ctx.allocator);

    // 6. Lookup record IDs
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

    // For encrypted+searchable fields, empty to_roles means deny by default
    // For non-searchable encrypted fields, empty to_roles allows access (backward compat)
    if (field_meta.visibility.to_roles.len == 0) {
        if (field_meta.isSearchable() and field_meta.isEncrypted()) {
            // Searchable encrypted fields require explicit grant
            return false;
        }
        // Non-searchable fields allow access if no restrictions configured
        return true;
    }

    // Get user role from context or global state
    const user_role = ctx.current_user_role orelse getCurrentUserRole() orelse return false;

    // Check if user's role is in the allowed roles list
    for (field_meta.visibility.to_roles) |allowed_role| {
        if (std.mem.eql(u8, user_role, allowed_role)) {
            return true; // User has required role
        }
    }

    // User's role not in allowed list
    return false;
}

/// Check property access permissions during evaluation
/// This should be called when accessing node properties during WHERE clause evaluation
/// For searchable encrypted fields, it enforces RBAC by throwing SearchNotPermitted
/// Returns the value (decrypted if necessary and permitted)
pub fn checkPropertyAccess(
    allocator: std.mem.Allocator,
    type_name: []const u8,
    field_name: []const u8,
    value_str: []const u8,
    node_id: u64,
) ![]const u8 {
    // Create encryption context with correct schema
    const ctx = EncryptionContext{
        .tenant_id = "default",
        .schema_name = type_name, // Use actual type name, not "default"
        .allocator = allocator,
        .current_user_role = getCurrentUserRole(),
    };

    // Check if field is encrypted
    const catalog = try fle_catalog.globalCatalog(allocator);
    if (!catalog.isFieldEncrypted(type_name, field_name)) {
        return value_str; // Not encrypted, return as-is
    }

    // Format record ID - must match encryption format
    const record_id = try std.fmt.allocPrint(allocator, "{d}", .{node_id});
    defer allocator.free(record_id);

    // Decrypt and check RBAC
    return try decryptFieldIfNeeded(
        ctx,
        type_name,
        field_name,
        value_str,
        record_id,
        true, // Check RBAC - will throw SearchNotPermitted for searchable fields
    );
}

// CANARY: REQ=REQ-FLE-PREDICATE-HELPERS-001; FEATURE="FLE Predicate Rewriting"; ASPECT=Helpers; STATUS=TESTED; TEST=geodetestlab/specs/fle_comprehensive_security.yml; OWNER=security; UPDATED=2026-01-09
/// Check if a field is encrypted according to the FLE catalog
pub fn isFieldEncrypted(ctx: EncryptionContext, type_name: []const u8, field_name: []const u8) bool {
    const catalog = fle_catalog.globalCatalog(ctx.allocator) catch return false;
    return catalog.isFieldEncrypted(type_name, field_name);
}

/// Check if an encrypted field is searchable (has blind index)
pub fn isFieldSearchable(ctx: EncryptionContext, type_name: []const u8, field_name: []const u8) bool {
    const catalog = fle_catalog.globalCatalog(ctx.allocator) catch return false;
    return catalog.isFieldSearchable(type_name, field_name);
}

/// Compute blind index hash for a value
/// Used for predicate rewriting to enable equality search on encrypted fields
pub fn computeBlindIndex(
    ctx: EncryptionContext,
    type_name: []const u8,
    field_name: []const u8,
    plaintext_value: []const u8,
) ![]const u8 {
    _ = type_name;

    // Get BIK from key manager
    const key_manager = try getGlobalKeyManager(ctx.allocator);
    const key_ids = key_types.KeyIds{
        .tenant = ctx.tenant_id,
        .schema = ctx.schema_name,
        .field = field_name,
        .version = 1,
    };
    const bik = try key_manager.getBIK(key_ids);

    // Get blind index
    const blind_index = try getGlobalBlindIndex(ctx.allocator);

    // Compute hash
    return try blind_index.computeHash(bik, plaintext_value);
}

test "FLE integration placeholder" {
    const testing = std.testing;

    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    defer fle_catalog.resetGlobalCatalog(allocator);

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
