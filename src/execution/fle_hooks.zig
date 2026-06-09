const std = @import("std");
const fle_integration = @import("../fle_integration.zig");
const logging = @import("logging");
const fle_log = logging.scoped("fle");
const Attr = logging.Attr;

// Field-Level Encryption Execution Hooks
// CANARY: REQ=REQ-FLE-EXECUTION-001; FEATURE="FieldLevelEncryption"; ASPECT=EXECUTION; STATUS=TESTED; TEST=tests/test_tde_kms_integration.zig; OWNER=security; UPDATED=2026-01-28
// CANARY: REQ=REQ-FLE-FAILSECURE-001; FEATURE="FLEFailSecure"; ASPECT=SECURITY; STATUS=TESTED; TEST=src/security/test_fle_enforcement.zig; OWNER=security; UPDATED=2026-01-28

/// GAP-0844 (secondary): resolve the current FLE role, preferring the active
/// ExecutionContext's request-scoped `fle_role` over the per-thread map. The FLE
/// hooks do not receive a context parameter — they read the thread-local active
/// context the same way `decryptPropertyIfNeeded`'s GPS gate does — so the
/// context becomes authoritative wherever one is pushed (the request boundary),
/// while internal/legacy callers with no active context keep the per-thread
/// behavior unchanged. Lazy import avoids the execution ↔ fle_hooks cycle.
fn currentUserRolePreferringContext() ?[]const u8 {
    const exec_mod = @import("../execution.zig");
    if (exec_mod.getActiveContext()) |ctx_ptr| {
        return fle_integration.getCurrentUserRoleCtx(ctx_ptr);
    }
    return fle_integration.getCurrentUserRole();
}

/// Error type for FLE hooks - fail-secure behavior
pub const FLEHookError = error{
    /// Encryption failed and cannot proceed safely
    EncryptionFailed,
    /// Field was marked for encryption but encryption could not be performed
    EncryptionRequired,
    /// Memory allocation failed
    OutOfMemory,
};

/// Helper function to encrypt node property value if needed before storing
/// Returns the potentially encrypted value to store
/// SECURITY: Fails securely - returns error if encryption is required but fails
/// CANARY: REQ=REQ-FLE-FAILSECURE-002; FEATURE="FLEFailSecure"; ASPECT=EncryptionRequired; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28
pub fn encryptPropertyIfNeeded(
    allocator: std.mem.Allocator,
    node_labels: [][]const u8,
    field_name: []const u8,
    plaintext_value: []const u8,
    node_id: u64,
) (FLEHookError || std.mem.Allocator.Error)![]const u8 {
    // Get node type from first label
    if (node_labels.len == 0) {
        return plaintext_value; // No type, cannot check encryption
    }
    const node_type = node_labels[0];

    // Check if this field requires encryption BEFORE attempting encryption
    // This allows us to distinguish between "no encryption needed" and "encryption failed"
    const requires_encryption = fle_integration.fieldRequiresEncryption(node_type, field_name);

    // Create encryption context
    // GAP-0281: Use per-thread tenant_id from fle_integration instead of hardcoded "default"
    const ctx = fle_integration.EncryptionContext{
        .tenant_id = fle_integration.getCurrentTenantId(),
        .schema_name = node_type,
        .allocator = allocator,
        .current_user_role = currentUserRolePreferringContext(),
    };

    const record_id = try std.fmt.allocPrint(allocator, "{d}", .{node_id});
    defer allocator.free(record_id);

    // Try to encrypt - if field is not encrypted, returns original value
    const encrypted_value = fle_integration.encryptFieldIfNeeded(
        ctx,
        node_type,
        field_name,
        plaintext_value,
        record_id,
    ) catch |err| {
        // SECURITY FIX: If encryption is REQUIRED for this field but fails,
        // we MUST NOT write plaintext to disk. Return an error instead.
        if (requires_encryption) {
            std.log.err("SECURITY: Encryption REQUIRED for field {s}.{s} but failed: {}. Refusing to write plaintext.", .{ node_type, field_name, err });
            return FLEHookError.EncryptionRequired;
        }
        // If field doesn't require encryption, this is just a warning
        std.log.warn("FLE encryption check failed for non-encrypted field {s}.{s}: {}", .{ node_type, field_name, err });
        return plaintext_value;
    };

    return encrypted_value;
}

/// Helper function to encrypt edge property value if needed before storing
/// Returns the potentially encrypted value to store
/// SECURITY: Fails securely - returns error if encryption is required but fails
/// CANARY: REQ=REQ-FLE-FAILSECURE-003; FEATURE="FLEFailSecure"; ASPECT=EdgeEncryptionRequired; STATUS=TESTED; OWNER=security; UPDATED=2026-01-28
pub fn encryptEdgePropertyIfNeeded(
    allocator: std.mem.Allocator,
    edge_type: []const u8,
    field_name: []const u8,
    plaintext_value: []const u8,
    edge_id: u64,
) (FLEHookError || std.mem.Allocator.Error)![]const u8 {
    // Check if this field requires encryption BEFORE attempting encryption
    const requires_encryption = fle_integration.fieldRequiresEncryption(edge_type, field_name);

    // Create encryption context
    // GAP-0281: Use per-thread tenant_id from fle_integration instead of hardcoded "default"
    const ctx = fle_integration.EncryptionContext{
        .tenant_id = fle_integration.getCurrentTenantId(),
        .schema_name = edge_type,
        .allocator = allocator,
        .current_user_role = currentUserRolePreferringContext(),
    };

    const record_id = try std.fmt.allocPrint(allocator, "edge_{d}", .{edge_id});
    defer allocator.free(record_id);

    // Try to encrypt - if field is not encrypted, returns original value
    const encrypted_value = fle_integration.encryptFieldIfNeeded(
        ctx,
        edge_type,
        field_name,
        plaintext_value,
        record_id,
    ) catch |err| {
        // SECURITY FIX: If encryption is REQUIRED for this field but fails,
        // we MUST NOT write plaintext to disk. Return an error instead.
        if (requires_encryption) {
            std.log.err("SECURITY: Encryption REQUIRED for edge property {s}.{s} but failed: {}. Refusing to write plaintext.", .{ edge_type, field_name, err });
            return FLEHookError.EncryptionRequired;
        }
        // If field doesn't require encryption, this is just a warning
        std.log.warn("FLE encryption check failed for non-encrypted edge property {s}.{s}: {}", .{ edge_type, field_name, err });
        return plaintext_value;
    };

    return encrypted_value;
}

/// Helper function to decrypt field value if needed when reading
/// Returns decrypted value for authorized users, "[REDACTED]" for others
/// CANARY: REQ=REQ-GPS-FLE-001; FEATURE="GPS FLE Enforcement"; ASPECT=DecryptFieldGate; STATUS=TESTED; TEST=tests/test_gps_fle_enforcement.zig; OWNER=security; UPDATED=2026-05-20
/// CANARY: REQ=REQ-GPS-INVARIANT-001; FEATURE="GPS Fail-Open Catalog"; ASPECT=FLEDecryptHookLocalRoleCheck; STATUS=COMPLETE; OWNER=security; UPDATED=2026-05-20
pub fn decryptPropertyIfNeeded(
    allocator: std.mem.Allocator,
    node_labels: [][]const u8,
    field_name: []const u8,
    stored_value: []const u8,
    node_id: u64,
) ![]const u8 {
    // Get node type from first label
    if (node_labels.len == 0) {
        return stored_value; // No type, cannot check encryption
    }
    const node_type = node_labels[0];

    // CANARY: REQ=REQ-GPS-FLE-001; FEATURE="GPS FLE Enforcement"; ASPECT=DecryptFieldGate; STATUS=TESTED; TEST=tests/test_gps_fle_enforcement.zig; OWNER=security; UPDATED=2026-05-20
    // Phase 5 task 5-3: GPS mandatory gate before any FLE decrypt-on-read.
    // When an active ExecutionContext is present and carries a principal, we
    // consult gps.decide(.decrypt_field) before allowing the field to be
    // decrypted.  Admin is allowed unconditionally; other principals require
    // an explicit Policy row with action = .decrypt_field.
    // If no active context / no principal (legacy paths, internal callers) we
    // skip the GPS check so that existing callers (graph_store, value_utilities)
    // that don't set a context continue to work. This preserves backward
    // compatibility while adding the gate for all request-scoped paths.
    // Lazy imports avoid a circular dependency: execution.zig imports fle_hooks.zig
    // at the top level; importing it back at the top of this file would cycle.
    {
        const exec_mod = @import("../execution.zig");
        const gps_mod = @import("../security/gps.zig");
        if (exec_mod.getActiveContext()) |ctx_ptr| {
            if (ctx_ptr.principal) |princ| {
                const gps_req = gps_mod.DecisionRequest{
                    .principal = princ,
                    .action = .decrypt_field,
                    .resource = .{ .metadata = .{ .kind = "fle_field" } },
                };
                const decision = try gps_mod.decide(allocator, &gps_req);
                if (decision.kind != .allow) {
                    fle_log.warn("GPS denied decrypt_field", &.{
                        Attr.string("node_type", node_type),
                        Attr.string("field", field_name),
                        Attr.string("reason", decision.reason_code),
                    });
                    return try allocator.dupe(u8, "[REDACTED]");
                }
            }
        }
    }

    // Create encryption context
    // GAP-0281: Use per-thread tenant_id from fle_integration instead of hardcoded "default"
    const ctx = fle_integration.EncryptionContext{
        .tenant_id = fle_integration.getCurrentTenantId(),
        .schema_name = node_type,
        .allocator = allocator,
        .current_user_role = currentUserRolePreferringContext(),
    };

    // Try to decrypt - handles RBAC and returns "[REDACTED]" if unauthorized
    const decrypt_record_id = try std.fmt.allocPrint(allocator, "{d}", .{node_id});
    defer allocator.free(decrypt_record_id);
    const decrypted_value = fle_integration.decryptFieldIfNeeded(
        ctx,
        node_type,
        field_name,
        stored_value,
        decrypt_record_id,
        true, // check_rbac = true
    ) catch |err| {
        // If decryption fails, return "[REDACTED]" for safety
        fle_log.warn("failed to decrypt field", &.{
            Attr.string("node_type", node_type),
            Attr.string("field", field_name),
            Attr.string("error", @errorName(err)),
        });
        return try allocator.dupe(u8, "[REDACTED]");
    };

    return decrypted_value;
}
