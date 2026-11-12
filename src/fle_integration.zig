const std = @import("std");
const build_options = @import("build_options");
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
var global_mutex: std.Io.Mutex = std.Io.Mutex.init;

// GAP-0203: Global flag to fast-path skip FLE when no encryption is configured
// CANARY: REQ=REQ-PERF-FLE-SKIP-001; FEATURE="FLESkipOptimization"; ASPECT=GlobalDisable; STATUS=IMPL; OWNER=perf; UPDATED=2026-01-27
var fle_has_encrypted_fields: bool = false;
var fle_catalog_state_checked: bool = false;

/// Check if FLE has any encrypted fields configured. Returns false when no encryption is active,
/// allowing callers to skip all FLE processing for non-encrypted deployments.
pub fn hasEncryptedFields() bool {
    if (!fle_has_encrypted_fields and !fle_catalog_state_checked) {
        global_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer global_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

        if (!fle_has_encrypted_fields and !fle_catalog_state_checked) {
            const catalog = fle_catalog.globalCatalog(std.heap.c_allocator) catch {
                fle_catalog_state_checked = true;
                return fle_has_encrypted_fields;
            };
            fle_has_encrypted_fields = catalog.count() > 0;
            fle_catalog_state_checked = true;
        }
    }
    return fle_has_encrypted_fields;
}

/// Mark that encrypted fields exist (called when encryption is configured)
pub fn setHasEncryptedFields(has_fields: bool) void {
    global_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    fle_has_encrypted_fields = has_fields;
    fle_catalog_state_checked = has_fields;
}

// GAP-0285/S3: Per-thread user role map replaces process-global variable.
// Previous implementation used a single `global_current_user_role` variable
// protected by a mutex, which caused TOCTOU race conditions: concurrent
// connections would overwrite each other's role, enabling cross-tenant FLE
// decryption (CVSS 8.5). Now keyed by thread ID so each connection handler
// thread maintains its own independent role state.
//
// GAP-0844 (deferred secondary): binding tenant/role to the request/execution
// context (`execution.ExecutionContext`) instead of the OS thread would make
// FLE isolation survive a future async / work-stealing executor that moves a
// request across threads mid-flight. We DEFER that here, deliberately, because:
//   (1) Under the current synchronous one-thread-per-connection executor this
//       per-thread model is correct — it is fragility, not a live bug.
//   (2) `execution.g_active_context` (the obvious place to read role/tenant
//       from) is ITSELF a `threadlocal` (execution.zig:521), so merely moving
//       the FLE role/tenant onto it would add churn WITHOUT removing the
//       OS-thread coupling. The fragility only truly disappears when the
//       executor stops being one-thread-per-connection AND the context is
//       passed explicitly (not via a threadlocal) into every FLE consumer
//       (~12 getCurrentUserRole/getCurrentTenantId call sites across
//       graph_store.zig, value_utilities.zig, fle_hooks.zig, rewrite.zig) and
//       the request boundaries in quic_connection_handler.zig / grpc_server.zig
//       set an `fle_user_role: ?[]const u8` on the context. That is a
//       cross-cutting execution-model refactor, out of scope for this gap.
// The PRIMARY GAP-0844 fix (removing the GEODE_CURRENT_ROLE process-global env
// override from getCurrentUserRole) IS applied — see that function below.
// CANARY: REQ=REQ-FLE-ROLE-ISOLATION-001; FEATURE="FLERoleIsolation"; ASPECT=PerThreadRole; STATUS=TESTED; OWNER=security; UPDATED=2026-06-08
var per_thread_roles: std.AutoHashMap(std.Thread.Id, []const u8) = std.AutoHashMap(std.Thread.Id, []const u8).init(std.heap.c_allocator);

/// Set the current user role for RBAC checks (per-thread, safe for concurrent connections).
/// This should be called at the start of a session/transaction.
pub fn setCurrentUserRole(role: ?[]const u8) void {
    global_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
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
    global_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
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
    global_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    return per_thread_tenants.get(std.Thread.getCurrentId()) orelse "default";
}

/// Get the current user role for FLE RBAC checks.
///
/// GAP-0844: the per-thread role map is the SINGLE source of truth. The old
/// implementation read the process-global env var `GEODE_CURRENT_ROLE` BEFORE
/// the per-thread map, which let one process-wide env var silently override the
/// authenticated role of EVERY connection in a shared multi-tenant process —
/// a cross-tenant FLE isolation hole that bypassed the per-thread isolation
/// GAP-0285 established. The env var was only ever a crutch for the old
/// subprocess-spawning CLI test path (eliminated by the unified-binary
/// architecture); tests that need to set a role out-of-band use the per-thread
/// `setCurrentUserRole` setter directly. The override is removed entirely.
pub fn getCurrentUserRole() ?[]const u8 {
    global_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    return per_thread_roles.get(std.Thread.getCurrentId());
}

/// GAP-0844 (secondary): context-preferring FLE role reader.
///
/// Prefers the request-scoped `ctx.fle_role` (set at the request boundary
/// alongside `setCurrentUserRole`), falling back to the per-thread map via
/// `getCurrentUserRole()` when the context carries no role. This makes the
/// EXECUTION CONTEXT — not the OS thread — authoritative wherever a context is
/// threaded, so FLE role isolation survives a future async / work-stealing
/// executor that moves a request across threads mid-flight.
///
/// `ctx` is `anytype` (rather than the concrete `execution.ExecutionContext`)
/// purely to avoid a fle_integration ↔ execution import cycle; the only field it
/// reads is `fle_role`. `getCurrentUserRole()` (the per-thread reader) is left
/// untouched so the ~12 existing per-thread call sites keep their behavior.
pub fn getCurrentUserRoleCtx(ctx: anytype) ?[]const u8 {
    const T = @TypeOf(ctx);
    if (comptime @typeInfo(T) == .pointer) {
        if (comptime @hasField(@typeInfo(T).pointer.child, "fle_role")) {
            if (ctx.fle_role) |r| return r;
        }
    } else if (comptime @hasField(T, "fle_role")) {
        if (ctx.fle_role) |r| return r;
    }
    return getCurrentUserRole();
}

/// GAP-0852: context-preferring FLE tenant reader (analog of `getCurrentUserRoleCtx`).
///
/// Prefers the request-scoped `ctx.tenant_id` (set at the request boundary
/// alongside `setCurrentTenantId`) over the per-thread tenant map. This makes
/// the EXECUTION CONTEXT — not the OS thread — authoritative for the FLE
/// encryption namespace wherever a context is threaded, so tenant isolation
/// survives a future async / work-stealing executor that moves a request across
/// threads mid-flight.
///
/// SECURITY (GAP-0852): when a context is present and carries a non-null
/// `tenant_id`, that tenant is used verbatim — the value NEVER silently
/// collapses to the `"default"` namespace. Only a genuinely contextless caller
/// (no context, or a context whose `tenant_id` is null) falls through to the
/// per-thread map (and its documented `"default"` fallback) — that path serves
/// internal/startup callers that legitimately have no tenant. Mixing a wrong
/// tenant into the AAD/key-id namespace causes decryption to fail closed, so a
/// stale per-thread tenant can never expose another tenant's plaintext.
///
/// `ctx` is `anytype` (rather than the concrete `execution.ExecutionContext`)
/// purely to avoid a fle_integration ↔ execution import cycle; the only field it
/// reads is `tenant_id`. `getCurrentTenantId()` (the per-thread reader) is left
/// untouched so the legacy per-thread call sites keep their behavior.
/// CANARY: REQ=REQ-MULTI-TENANT-FLE-003; FEATURE="FLE Multi-Tenancy"; ASPECT=ContextTenant; STATUS=TESTED; TEST=tests/test_gap0852_fle_request_context.zig; OWNER=security; UPDATED=2026-06-09
pub fn getCurrentTenantIdCtx(ctx: anytype) []const u8 {
    const T = @TypeOf(ctx);
    if (comptime @typeInfo(T) == .pointer) {
        if (comptime @hasField(@typeInfo(T).pointer.child, "tenant_id")) {
            if (ctx.tenant_id) |t| return t;
        }
    } else if (comptime @hasField(T, "tenant_id")) {
        if (ctx.tenant_id) |t| return t;
    }
    return getCurrentTenantId();
}

/// GAP-0852 follow-up: single source of truth for "resolve the FLE role,
/// preferring the active ExecutionContext's request-scoped role over the
/// per-thread map." Previously this 5-line body was copy-pasted into
/// `src/execution/fle_hooks.zig`, `src/execution/value_utilities.zig`,
/// `src/graph_store.zig`, and `src/planner/rewrite.zig` (each with its own lazy
/// `@import("execution.zig")` to dodge the cycle). Consolidated here next to
/// `getCurrentUserRoleCtx` — `checkPropertyAccess` already proves the lazy
/// function-body import of execution works inside this module, so every migrated
/// site now calls this instead. Wherever a request context is pushed (the request
/// boundary), the context becomes authoritative; contextless internal/legacy
/// callers keep the per-thread behavior. Fail-secure: with neither a context role
/// nor a per-thread role, returns null so plaintext access is denied.
/// CANARY: REQ=REQ-FLE-ROLE-ISOLATION-003; FEATURE="FLERoleIsolation"; ASPECT=ContextRole; STATUS=TESTED; TEST=tests/test_gap0852_fle_request_context.zig; OWNER=security; UPDATED=2026-06-09
pub fn rolePreferringActiveContext() ?[]const u8 {
    const exec_mod = @import("execution.zig");
    if (exec_mod.getActiveContext()) |ctx_ptr| {
        return getCurrentUserRoleCtx(ctx_ptr);
    }
    return getCurrentUserRole();
}

/// GAP-0852 follow-up: single source of truth for "resolve the FLE tenant,
/// preferring the active ExecutionContext's request-scoped tenant over the
/// per-thread map" (analog of `rolePreferringActiveContext`). Consolidates the
/// `currentTenantIdPreferringContext` copies from `src/execution/fle_hooks.zig`
/// and `src/execution/value_utilities.zig`. When a context is present and carries
/// a tenant, that tenant is used verbatim; the per-thread map (and its documented
/// `"default"`) is reached ONLY for genuinely contextless internal callers
/// (startup hydration, legacy paths). Fail-secure: a wrong tenant in the
/// AAD/key-id namespace makes decryption fail rather than expose another tenant's
/// plaintext.
/// CANARY: REQ=REQ-MULTI-TENANT-FLE-004; FEATURE="FLE Multi-Tenancy"; ASPECT=ContextTenant; STATUS=TESTED; TEST=tests/test_gap0852_fle_request_context.zig; OWNER=security; UPDATED=2026-06-09
pub fn tenantPreferringActiveContext() []const u8 {
    const exec_mod = @import("execution.zig");
    if (exec_mod.getActiveContext()) |ctx_ptr| {
        return getCurrentTenantIdCtx(ctx_ptr);
    }
    return getCurrentTenantId();
}

/// Clear all per-thread FLE state (tenant_id and role) for the current thread.
/// MUST be called in the connection handler's defer block to prevent stale
/// state from leaking into a subsequent connection that reuses the same thread.
/// GAP-0285: Prevents cross-tenant FLE decryption when threads are reused.
/// CANARY: REQ=REQ-FLE-ROLE-ISOLATION-002; FEATURE="FLERoleIsolation"; ASPECT=ThreadCleanup; STATUS=TESTED; OWNER=security; UPDATED=2026-04-05
pub fn clearCurrentThreadState() void {
    global_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
    const tid = std.Thread.getCurrentId();
    _ = per_thread_roles.remove(tid);
    _ = per_thread_tenants.remove(tid);
}

pub const EncryptionContext = struct {
    tenant_id: []const u8,
    schema_name: []const u8,
    allocator: std.mem.Allocator,
    current_user_role: ?[]const u8 = null, // User's current role for RBAC checks
};

/// Get or create global key manager
fn getGlobalKeyManager(allocator: std.mem.Allocator) !*key_manager_mod.KeyManager {
    global_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    if (global_key_manager_instance) |km| {
        return km;
    }

    const km = try key_manager_mod.initFromEnv(allocator);
    global_key_manager_instance = km;
    return km;
}

/// Get or create global blind index
fn getGlobalBlindIndex(allocator: std.mem.Allocator) !*blind_index_mod.BlindIndex {
    global_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    if (global_blind_index_instance) |bi| {
        return bi;
    }

    const bi = try allocator.create(blind_index_mod.BlindIndex);
    bi.* = blind_index_mod.BlindIndex.init(allocator);
    global_blind_index_instance = bi;
    return bi;
}

/// Tear down the process-global FLE key manager and blind index, freeing all
/// memory they own and clearing the singletons so the next access re-initializes
/// from the environment. Production never calls this (the singletons live for the
/// process lifetime); it exists so leak-checked unit tests that actually exercise
/// the encrypt path (which lazily instantiates these globals on the test
/// allocator) can release that memory deterministically. Safe to call when no
/// global has been created — it is a no-op in that case.
pub fn resetGlobalKeyStateForTesting() void {
    global_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer global_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    if (global_key_manager_instance) |km| {
        km.deinit();
        global_key_manager_instance = null;
    }
    if (global_blind_index_instance) |bi| {
        const alloc = bi.allocator;
        bi.deinit();
        alloc.destroy(bi);
        global_blind_index_instance = null;
    }
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
    if (!hasEncryptedFields()) {
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
    if (!hasEncryptedFields()) {
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
    // FIPS fail-close: ChaCha20-Poly1305 is not an approved AEAD under FIPS 140-3.
    // AES-256-GCM is the only permitted path. Reject ChaCha selection at runtime.
    // CANARY: REQ=REQ-FIPS-CHACHA-FAILCLOSE-001; FEATURE="FIPSFailClose"; ASPECT=FLEEncrypt; STATUS=IMPL; OWNER=security; UPDATED=2026-06-24
    if (build_options.fips and field_meta.encryption.algorithm == .chacha20_poly1305) {
        return error.FipsUnsupported;
    }
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
    if (!hasEncryptedFields()) {
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
            // fle v0.1.7 (98dd8af) dropped the never-raised SearchNotPermitted
            // from its aead.Error set; this is geode's own authz semantic
            // (see value_types / execution / eval EvalError.SearchNotPermitted).
            return error.SearchNotPermitted;
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

    // FIPS fail-close: reject decryption of ChaCha20-Poly1305 ciphertext under FIPS.
    // alg_id=2 corresponds to chacha20_poly1305 in the fle envelope format.
    // AES-256-GCM (alg_id=1) is the only approved AEAD path.
    // CANARY: REQ=REQ-FIPS-CHACHA-FAILCLOSE-002; FEATURE="FIPSFailClose"; ASPECT=FLEDecrypt; STATUS=IMPL; OWNER=security; UPDATED=2026-06-24
    if (build_options.fips and envelope.alg_id == @intFromEnum(fle_aead.Alg.chacha20_poly1305)) {
        return error.FipsUnsupported;
    }

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
        // fle v0.1.7 (98dd8af) dropped the never-raised SearchNotPermitted from
        // its aead.Error set; raise geode's own error (handled downstream).
        return error.SearchNotPermitted;
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
    // Create encryption context with correct schema.
    // GAP-0281: tenant_id from FLE context instead of hardcoded "default".
    // GAP-0852: prefer the active ExecutionContext's request-scoped tenant/role
    // over the per-thread map so WHERE-clause FLE access checks stay correct
    // under a future async / work-stealing executor. The execution import is
    // lazy (function-body) to avoid a fle_integration ↔ execution top-level
    // cycle; when no context is active (internal/legacy callers) we fall back to
    // the per-thread readers verbatim.
    const role_and_tenant = blk: {
        const exec_mod = @import("execution.zig");
        if (exec_mod.getActiveContext()) |ctx_ptr| {
            break :blk .{ getCurrentUserRoleCtx(ctx_ptr), getCurrentTenantIdCtx(ctx_ptr) };
        }
        break :blk .{ getCurrentUserRole(), getCurrentTenantId() };
    };
    const ctx = EncryptionContext{
        .tenant_id = role_and_tenant[1],
        .schema_name = type_name, // Use actual type name, not "default"
        .allocator = allocator,
        .current_user_role = role_and_tenant[0],
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

test "FLE integration placeholder" {
    const testing = std.testing;

    var gpa = std.heap.DebugAllocator(.{}){};
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

// GAP-0285: Verify that clearCurrentThreadState removes stale per-thread role and tenant entries.
test "clearCurrentThreadState removes per-thread role and tenant" {
    const testing = std.testing;

    // Set per-thread state (simulates a connection handler setting FLE context)
    setCurrentUserRole("admin");
    setCurrentTenantId("acme-corp");

    // Verify state is set
    try testing.expectEqualStrings("acme-corp", getCurrentTenantId());
    // getCurrentUserRole may read env var first; check per_thread_roles directly
    {
        global_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer global_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        try testing.expect(per_thread_roles.get(std.Thread.getCurrentId()) != null);
    }

    // Simulate connection handler defer block calling clearCurrentThreadState
    clearCurrentThreadState();

    // After cleanup: tenant should fall back to "default", role should be null
    try testing.expectEqualStrings("default", getCurrentTenantId());
    {
        global_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer global_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        try testing.expect(per_thread_roles.get(std.Thread.getCurrentId()) == null);
        try testing.expect(per_thread_tenants.get(std.Thread.getCurrentId()) == null);
    }
}

// GAP-0844: The process-global env var GEODE_CURRENT_ROLE must NOT override the
// per-thread role in the production getCurrentUserRole() path. Previously
// getCurrentUserRole() read GEODE_CURRENT_ROLE *before* the per-thread map, so a
// single process-wide env var could mask every connection's authenticated role
// — a cross-tenant FLE isolation hole in a shared multi-tenant process. The
// per-thread map (set on HELLO, cleared on close) is now the single source of
// truth. This test sets the env var to a different value than the per-thread
// role and asserts the per-thread role wins.
// CANARY: REQ=REQ-FLE-ROLE-ISOLATION-003; FEATURE="FLERoleIsolation"; ASPECT=NoEnvOverride; STATUS=TESTED; OWNER=security; UPDATED=2026-06-08
test "GAP-0844: GEODE_CURRENT_ROLE env does not override per-thread role" {
    const testing = std.testing;

    // Set the dangerous process-global override to a value that, under the old
    // behavior, would mask whatever the per-thread map says.
    const set_rc = setenvForTest("GEODE_CURRENT_ROLE", "env_admin");
    try testing.expectEqual(@as(c_int, 0), set_rc);
    defer _ = unsetenvForTest("GEODE_CURRENT_ROLE");

    // Authenticated connection role established via the per-thread setter
    // (the same API the QUIC HELLO path uses).
    setCurrentUserRole("tenant_user");
    defer clearCurrentThreadState();

    // The per-thread role MUST win. The env var must be ignored entirely in the
    // production path.
    const role = getCurrentUserRole() orelse return error.RoleNotSet;
    try testing.expectEqualStrings("tenant_user", role);

    // And with NO per-thread role set, the env var must NOT resurrect a role:
    // getCurrentUserRole() falls through to the (empty) per-thread map and
    // returns null, NOT "env_admin". Fail-secure: no role = deny.
    clearCurrentThreadState();
    try testing.expect(getCurrentUserRole() == null);
}

// libc setenv/unsetenv shims for the GAP-0844 env-override test. std.posix.setenv
// was removed in Zig 0.16; std.c provides the non-allocating libc entry points.
extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;
fn setenvForTest(name: [*:0]const u8, value: [*:0]const u8) c_int {
    return setenv(name, value, 1);
}
fn unsetenvForTest(name: [*:0]const u8) c_int {
    return unsetenv(name);
}

// #813 / GAP-0886a: REQ-FLE-ENFORCE-030 — the fle_has_encrypted_fields
// fast-path flag MUST read true once the schema has encrypted fields;
// otherwise encryptFieldIfNeeded() silently skips encryption (fail-open).
// Two mechanisms guarantee the invariant:
//   1. Explicit set: the `CALL geode.fle.configureField` dispatch calls
//      setHasEncryptedFields(true) right after catalog.configureField
//      (src/execution/storage_dispatch.zig).
//   2. Lazy self-heal: hasEncryptedFields() consults catalog.count() > 0 when
//      the flag is unset and unchecked — covering any path that populates the
//      catalog WITHOUT the explicit setter (e.g. persisted-catalog boot load).
// This test exercises mechanism 2 (the one a code reviewer can't see at the
// dispatch call site) plus the explicit-setter round-trip.
// CANARY: REQ=REQ-FLE-ENFORCE-030; FEATURE="FLEEnforcement"; ASPECT=GlobalFlagSkipDisabled; STATUS=TESTED; TEST=src/fle_integration.zig; OWNER=security; UPDATED=2026-06-10
test "GAP-0886: hasEncryptedFields reflects catalog state (flag self-heal + setter)" {
    const testing = std.testing;

    // Isolate catalog persistence: point GEODE_DATA_DIR at a tmp dir so
    // configureField's saveCatalog never touches a real data dir and the lazy
    // path never loads a real persisted catalog from /tmp.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    // std.Io.Dir has no realpath in Zig 0.16; TmpDir.sub_path is relative to
    // `.zig-cache/tmp`, so reconstruct the absolute path from getcwd (same
    // pattern as tests/test_gap0854_fle_chain.zig).
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    var cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    while (cwd_len > 0 and cwd_buf[cwd_len - 1] == 0) : (cwd_len -= 1) {}
    const data_dir = try std.fmt.allocPrint(
        testing.allocator,
        "{s}/.zig-cache/tmp/{s}",
        .{ cwd_buf[0..cwd_len], &tmp.sub_path },
    );
    defer testing.allocator.free(data_dir);
    const data_dir_z = try testing.allocator.dupeZ(u8, data_dir);
    defer testing.allocator.free(data_dir_z);
    try testing.expectEqual(@as(c_int, 0), setenvForTest("GEODE_DATA_DIR", data_dir_z.ptr));
    defer _ = unsetenvForTest("GEODE_DATA_DIR");

    // Clean global FLE state; restore it for sibling tests in this binary.
    fle_catalog.resetGlobalCatalog(testing.allocator);
    setHasEncryptedFields(false);
    defer {
        fle_catalog.resetGlobalCatalog(testing.allocator);
        setHasEncryptedFields(false);
    }

    // Explicit-setter round-trip while the catalog is still empty
    // (mirrors the storage_dispatch configureField call site).
    setHasEncryptedFields(true);
    try testing.expect(hasEncryptedFields());
    setHasEncryptedFields(false);
    try testing.expect(!hasEncryptedFields()); // empty catalog → lazy check stays false

    // Populate the catalog WITHOUT calling setHasEncryptedFields — simulating
    // a path that configures encryption while bypassing the dispatch setter.
    const catalog = try fle_catalog.globalCatalog(testing.allocator);
    try catalog.configureField("Gap0886Type", .{
        .field_name = "ssn",
        .encryption = .{ .enabled = true },
    });

    // Force the "never explicitly set" state: unset AND unchecked.
    {
        global_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer global_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        fle_has_encrypted_fields = false;
        fle_catalog_state_checked = false;
    }

    // INVARIANT under test: the lazy self-heal must observe the configured
    // field and flip the flag — no silent encryption skip.
    try testing.expect(hasEncryptedFields());
}

// GAP-0515: Thread reuse isolation regression test.
//
// The earlier test covers the single direction (set → clear → empty). The
// attack surface GAP-0515 flagged is specifically the thread-pool reuse
// case: connection handler thread T runs for tenant A, cleanup fires,
// then the same thread T is immediately reused for tenant B. Nothing
// from tenant A's FLE context must survive into tenant B's execution
// — including after B's own cleanup, a hypothetical C must likewise
// see a clean slate. Also verifies that a redundant second clear is
// idempotent (defer blocks can fire twice in some error paths).
test "GAP-0515: thread reuse isolates FLE context across connections" {
    const testing = std.testing;
    const tid = std.Thread.getCurrentId();

    // --- Connection 1 (tenant "alpha", role "admin") ---
    setCurrentUserRole("admin");
    setCurrentTenantId("alpha");
    try testing.expectEqualStrings("alpha", getCurrentTenantId());
    {
        global_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer global_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        const r = per_thread_roles.get(tid) orelse return error.RoleNotSet;
        try testing.expectEqualStrings("admin", r);
    }

    // Simulated defer block: clear state on connection close.
    clearCurrentThreadState();

    // --- Connection 2 reuses the same thread (tenant "beta", role "user") ---
    // On entry the state MUST be clean — no leak from connection 1.
    try testing.expectEqualStrings("default", getCurrentTenantId());
    {
        global_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer global_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        try testing.expect(per_thread_roles.get(tid) == null);
    }

    setCurrentUserRole("user");
    setCurrentTenantId("beta");

    // Reading back must return connection 2's values, not connection 1's.
    try testing.expectEqualStrings("beta", getCurrentTenantId());
    {
        global_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer global_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        const r = per_thread_roles.get(tid) orelse return error.RoleNotSet;
        try testing.expectEqualStrings("user", r);
        // And crucially: the old "admin" / "alpha" values are gone.
        try testing.expect(!std.mem.eql(u8, r, "admin"));
    }

    // --- Connection 2 cleanup ---
    clearCurrentThreadState();

    // Idempotency: double-clear must not panic or leave state in a bad
    // shape. The QUIC handler's errdefer path can fire in addition to the
    // defer, so the function must tolerate being called twice.
    clearCurrentThreadState();

    // After the double-clear, state is empty. A fresh connection 3 on
    // the same thread starts from the same clean slate.
    try testing.expectEqualStrings("default", getCurrentTenantId());
    {
        global_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
        defer global_mutex.unlock(std.Io.Threaded.global_single_threaded.io());
        try testing.expect(per_thread_roles.get(tid) == null);
        try testing.expect(per_thread_tenants.get(tid) == null);
    }
}

// =============================================================================
// FIPS FAIL-CLOSE TESTS (Task 8)
//
// These tests assert the fail-close invariant for ChaCha20-Poly1305 under FIPS:
//   - Under -Dfips=true:  selecting ChaCha20-Poly1305 returns error.FipsUnsupported
//   - Under -Dfips=false: ChaCha20-Poly1305 compiles and is reachable (no gate)
//   - AES-256-GCM works in both modes
//
// CANARY: REQ=REQ-FIPS-CHACHA-FAILCLOSE-001; FEATURE="FIPSFailClose"; ASPECT=FLETests; STATUS=TESTED; OWNER=security; UPDATED=2026-06-24
// =============================================================================

// Helper: configure a field with the given algorithm in an isolated catalog, set up a
// minimal key-manager env, and call encryptFieldIfNeeded. Returns the error (or void on
// success). Caller owns cleanup of catalog state.
fn configureAndEncrypt(
    allocator: std.mem.Allocator,
    alg: fle_annotations.EncryptionConfig.Algorithm,
) !void {
    // Point to a tmp data dir to avoid polluting the real catalog on disk.
    var tmp = std.testing.tmpDir(.{});
    defer tmp.cleanup();
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    var cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    while (cwd_len > 0 and cwd_buf[cwd_len - 1] == 0) : (cwd_len -= 1) {}
    const data_dir = try std.fmt.allocPrint(
        allocator,
        "{s}/.zig-cache/tmp/{s}",
        .{ cwd_buf[0..cwd_len], &tmp.sub_path },
    );
    defer allocator.free(data_dir);
    const data_dir_z = try allocator.dupeZ(u8, data_dir);
    defer allocator.free(data_dir_z);
    _ = setenvForTest("GEODE_DATA_DIR", data_dir_z.ptr);
    defer _ = unsetenvForTest("GEODE_DATA_DIR");

    // Reset global catalog + key-manager state for isolation.
    fle_catalog.resetGlobalCatalog(allocator);
    setHasEncryptedFields(false);
    resetGlobalKeyStateForTesting();
    defer {
        fle_catalog.resetGlobalCatalog(allocator);
        setHasEncryptedFields(false);
        resetGlobalKeyStateForTesting();
    }

    // Configure the catalog with the requested algorithm.
    const catalog = try fle_catalog.globalCatalog(allocator);
    try catalog.configureField("FipsTestType", .{
        .field_name = "secret",
        .encryption = .{ .enabled = true, .algorithm = alg },
    });
    setHasEncryptedFields(true);

    // Point key manager at a dummy env (no real KMS needed — we expect
    // failure before the key-fetch for the ChaCha path under FIPS).
    _ = setenvForTest("GEODE_MASTER_KEY", "deadbeef00112233445566778899aabbccddeeff00112233445566778899aabb");
    defer _ = unsetenvForTest("GEODE_MASTER_KEY");

    const ctx = EncryptionContext{
        .tenant_id = "test_tenant",
        .schema_name = "FipsTestType",
        .allocator = allocator,
    };

    // encryptFieldIfNeeded will fail-close with FipsUnsupported before key fetch.
    const result = encryptFieldIfNeeded(ctx, "FipsTestType", "secret", "plaintext_value", "rec_1");
    if (result) |ciphertext| {
        // On success (non-FIPS path), free the allocated ciphertext.
        // encryptFieldIfNeeded returns the original plaintext slice (no alloc)
        // when the field is not in the catalog, but returns an allocated envelope
        // when encryption succeeds. Free only if it differs from the input.
        if (ciphertext.ptr != "plaintext_value".ptr) {
            allocator.free(ciphertext);
        }
    } else |err| {
        return err;
    }
}

// Task 8: Under FIPS, selecting ChaCha20-Poly1305 for FLE must return FipsUnsupported.
// CANARY: REQ=REQ-FIPS-CHACHA-FAILCLOSE-001; FEATURE="FIPSFailClose"; ASPECT=FLEEncryptRejectChaCha; STATUS=TESTED; OWNER=security; UPDATED=2026-06-24
test "FIPS-Task8: ChaCha20-Poly1305 FLE encrypt returns FipsUnsupported under FIPS" {
    if (!build_options.fips) return error.SkipZigTest; // FIPS gate: only runs under -Dfips=true

    const err = configureAndEncrypt(std.testing.allocator, .chacha20_poly1305);
    try std.testing.expectError(error.FipsUnsupported, err);
}

// Task 8: Under FIPS, AES-256-GCM FLE must still be reachable (no false positive).
// The key-manager env is minimal (dummy key), so the test will fail at key fetch —
// but NOT at the FIPS gate. The absence of FipsUnsupported confirms AES-GCM is
// approved and passes the FIPS check.
// CANARY: REQ=REQ-FIPS-CHACHA-FAILCLOSE-001; FEATURE="FIPSFailClose"; ASPECT=FLEEncryptAesGcmAllowed; STATUS=TESTED; OWNER=security; UPDATED=2026-06-24
test "FIPS-Task8: AES-256-GCM FLE encrypt is NOT blocked by FIPS gate" {
    if (!build_options.fips) return error.SkipZigTest; // FIPS gate: only runs under -Dfips=true

    const err = configureAndEncrypt(std.testing.allocator, .aes256_gcm);
    // AES-GCM must NOT produce FipsUnsupported. It may produce other errors
    // (key-fetch, catalog) but the FIPS fail-close must NOT trigger.
    if (err) |_| {
        // Succeeded without error — fine.
    } else |e| {
        try std.testing.expect(e != error.FipsUnsupported);
    }
}

// Task 8: Under non-FIPS (-Dfips=false), ChaCha20-Poly1305 path is reachable and
// must NOT be blocked by the FIPS gate.
// CANARY: REQ=REQ-FIPS-CHACHA-FAILCLOSE-001; FEATURE="FIPSFailClose"; ASPECT=FLEEncryptChaChaAllowedNonFips; STATUS=TESTED; OWNER=security; UPDATED=2026-06-24
test "FIPS-Task8: ChaCha20-Poly1305 FLE is NOT gated under non-FIPS build" {
    if (build_options.fips) return error.SkipZigTest; // Non-FIPS gate: only runs under -Dfips=false

    const err = configureAndEncrypt(std.testing.allocator, .chacha20_poly1305);
    // Under non-FIPS, ChaCha20 must NOT be blocked. It may produce other errors
    // (key-fetch) but the FIPS gate must not fire.
    if (err) |_| {
        // Succeeded without error — fine.
    } else |e| {
        // Must not be FipsUnsupported.
        try std.testing.expect(e != error.FipsUnsupported);
    }
}
