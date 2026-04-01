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

// GAP-0203: Global flag to fast-path skip FLE when no encryption is configured
// CANARY: REQ=REQ-PERF-FLE-SKIP-001; FEATURE="FLESkipOptimization"; ASPECT=GlobalDisable; STATUS=IMPL; OWNER=perf; UPDATED=2026-01-27
var fle_has_encrypted_fields: bool = false;

/// Check if FLE has any encrypted fields configured. Returns false when no encryption is active,
/// allowing callers to skip all FLE processing for non-encrypted deployments.
pub fn hasEncryptedFields() bool {
    return fle_has_encrypted_fields;
}

/// Mark that encrypted fields exist (called when encryption is configured)
pub fn setHasEncryptedFields(has_fields: bool) void {
    fle_has_encrypted_fields = has_fields;
}

// GAP-0285/S3: Per-thread user role map replaces process-global variable.
// Previous implementation used a single `global_current_user_role` variable
// protected by a mutex, which caused TOCTOU race conditions: concurrent
// connections would overwrite each other's role, enabling cross-tenant FLE
// decryption (CVSS 8.5). Now keyed by thread ID so each connection handler
// thread maintains its own independent role state.
// CANARY: REQ=REQ-FLE-ROLE-ISOLATION-001; FEATURE="FLERoleIsolation"; ASPECT=PerThreadRole; STATUS=TESTED; OWNER=security; UPDATED=2026-04-01
var per_thread_roles: std.AutoHashMap(std.Thread.Id, []const u8) = std.AutoHashMap(std.Thread.Id, []const u8).init(std.heap.c_allocator);

/// Set the current user role for RBAC checks (per-thread, safe for concurrent connections).
/// This should be called at the start of a session/transaction.
pub fn setCurrentUserRole(role: ?[]const u8) void {
    global_mutex.lock();
    defer global_mutex.unlock();
    const tid = std.Thread.getCurrentId();
    if (role) |r| {
        per_thread_roles.put(tid, r) catch {
            // On allocation failure, remove any stale entry (fail-secure: no role = deny)
            _ = per_thread_roles.remove(tid);
        };
    } else {
        _ = per_thread_roles.remove(tid);
    }
}

// GAP-0281: Per-thread tenant_id map for FLE encryption namespace isolation.
// Same pattern as per_thread_roles (GAP-0285/S3): keyed by thread ID so each
// connection handler thread maintains its own tenant_id state.
// CANARY: REQ=REQ-MULTI-TENANT-FLE-002; FEATURE="FLE Multi-Tenancy"; ASPECT=PerThreadTenant; STATUS=IMPL; OWNER=security; UPDATED=2026-04-01
var per_thread_tenants: std.AutoHashMap(std.Thread.Id, []const u8) = std.AutoHashMap(std.Thread.Id, []const u8).init(std.heap.c_allocator);

/// Set the current tenant_id for FLE encryption namespace (per-thread, safe for concurrent connections).
/// Should be called at the start of query execution when session has a tenant_id.
pub fn setCurrentTenantId(tenant_id: ?[]const u8) void {
    global_mutex.lock();
    defer global_mutex.unlock();
    const tid = std.Thread.getCurrentId();
    if (tenant_id) |t| {
        per_thread_tenants.put(tid, t) catch {
            _ = per_thread_tenants.remove(tid);
        };
    } else {
        _ = per_thread_tenants.remove(tid);
    }
}

/// Get the current tenant_id for FLE operations.
/// Returns the per-thread tenant_id if set, otherwise "default".
pub fn getCurrentTenantId() []const u8 {
    global_mutex.lock();
    defer global_mutex.unlock();
    return per_thread_tenants.get(std.Thread.getCurrentId()) orelse "default";
}

/// Get the current user role.
/// Checks environment variable GEODE_CURRENT_ROLE first (non-allocating via std.posix.getenv),
/// then falls back to per-thread role state.
/// P4 fix: uses std.posix.getenv instead of getEnvVarOwned to avoid heap allocation leak.
pub fn getCurrentUserRole() ?[]const u8 {
    // Check environment variable first (for CLI testing across process boundaries).
    // std.posix.getenv returns a slice into the process environment block -- no allocation.
    if (std.posix.getenv("GEODE_CURRENT_ROLE")) |env_role| {
        return env_role;
    }
    // Fall back to per-thread role
    global_mutex.lock();
    defer global_mutex.unlock();
    return per_thread_roles.get(std.Thread.getCurrentId());
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

    const km = try key_manager_mod.initFromEnv(allocator);
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
    return key_manager_mod.currentKeyVersion(key_manager, key_path);
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

/// Check if a field requires encryption according to the FLE catalog
/// This is used by fail-secure logic to determine if encryption failure should abort writes
/// CANARY: REQ=REQ-FLE-FAILSECURE-004; FEATURE="FLEFailSecure"; ASPECT=EncryptionCheck; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28
pub fn fieldRequiresEncryption(type_name: []const u8, field_name: []const u8) bool {
    // Fast path - if no encrypted fields are configured globally, nothing requires encryption
    if (!fle_has_encrypted_fields) {
        return false;
    }

    // Use c_allocator for catalog lookup to avoid page_allocator usage in runtime paths.
    const allocator = std.heap.c_allocator;

    // Get global catalog - FAIL-SECURE: if we can't access catalog, assume encryption IS required
    // This prevents bypassing encryption by causing catalog errors
    const catalog = fle_catalog.globalCatalog(allocator) catch {
        std.log.warn("SECURITY: Cannot access FLE catalog - assuming field {s}.{s} requires encryption (fail-secure)", .{ type_name, field_name });
        return true; // FAIL-SECURE: Assume encryption required on catalog error
    };

    // Check if type exists
    const type_meta = catalog.getType(type_name) orelse {
        return false; // Type not in catalog = not configured for encryption
    };

    // Check if field is marked as encrypted
    const field_meta = type_meta.getField(field_name) orelse {
        return false; // Field not in catalog = not configured for encryption
    };

    return field_meta.isEncrypted();
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
    // GAP-0203: Fast path - skip all FLE processing when no encryption is configured
    if (!fle_has_encrypted_fields) {
        return plaintext;
    }

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
        key_ids.version,
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
    // GAP-0203: Fast path - skip all FLE processing when no encryption is configured
    // CANARY: REQ=REQ-PERF-FLE-SKIP-002; FEATURE="FLESkipOptimization"; ASPECT=DecryptFastPath; STATUS=IMPL; OWNER=perf; UPDATED=2026-01-27
    if (!fle_has_encrypted_fields) {
        return data;
    }

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
/// SECURITY FIX: Fail-secure on catalog errors (deny access instead of grant)
/// CANARY: REQ=REQ-FLE-FAILSECURE-005; FEATURE="FLEFailSecure"; ASPECT=CatalogErrorDenyAccess; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28
fn canReadPlaintext(
    ctx: EncryptionContext,
    type_name: []const u8,
    field_name: []const u8,
) bool {
    // Get global catalog
    // SECURITY FIX: On catalog error, DENY access (fail-secure)
    // Previous behavior returned true, allowing access on catalog errors - INSECURE!
    const catalog = fle_catalog.globalCatalog(ctx.allocator) catch {
        std.log.warn("SECURITY: Cannot access FLE catalog for {s}.{s} - denying plaintext access (fail-secure)", .{ type_name, field_name });
        return false; // FAIL-SECURE: Deny access on catalog error
    };

    // Get field metadata
    // If type/field not in catalog, it's not FLE-protected, so allow access
    const type_meta = catalog.getType(type_name) orelse return true;
    const field_meta = type_meta.getField(field_name) orelse return true;

    // SECURITY FIX: Empty to_roles means NO ONE can read plaintext (fail-secure).
    // Previously, non-searchable encrypted fields with empty visibility allowed access,
    // which violated the principle of least privilege and failed the locked-field test.
    if (field_meta.visibility.to_roles.len == 0) {
        if (field_meta.isEncrypted()) {
            // Empty visibility on an encrypted field = locked to nobody
            return false;
        }
        // Non-encrypted fields with no restrictions allow access (not FLE-protected)
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
    // GAP-0281: Use per-thread tenant_id instead of hardcoded "default"
    const ctx = EncryptionContext{
        .tenant_id = getCurrentTenantId(),
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
