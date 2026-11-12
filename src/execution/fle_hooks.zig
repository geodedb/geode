const std = @import("std");
const fle_integration = @import("../fle_integration.zig");
const logging = @import("logging");
const fle_log = logging.scoped("fle");
const Attr = logging.Attr;

// Field-Level Encryption Execution Hooks
// CANARY: REQ=REQ-FLE-EXECUTION-001; FEATURE="FieldLevelEncryption"; ASPECT=EXECUTION; STATUS=TESTED; TEST=tests/test_tde_kms_integration.zig; OWNER=security; UPDATED=2026-01-28
// CANARY: REQ=REQ-FLE-FAILSECURE-001; FEATURE="FLEFailSecure"; ASPECT=SECURITY; STATUS=TESTED; TEST=src/security/test_fle_enforcement.zig; OWNER=security; UPDATED=2026-01-28

// GAP-0852 follow-up: the context-preferring role/tenant helpers used to live
// here as `currentUserRolePreferringContext` / `currentTenantIdPreferringContext`
// (each with its own lazy `@import("../execution.zig")`). They were duplicated
// across four modules and are now consolidated as
// `fle_integration.rolePreferringActiveContext` / `.tenantPreferringActiveContext`.

/// GAP-0854 follow-up: the internal HMAC-chained security graph
/// (`__geode_security`) must NEVER receive an FLE envelope. Its nodes/edges
/// carry common labels (`User`, `Role`, `HAS_ROLE`) that collide with
/// application schema, so a user-configured FLE field such as `('User','email')`
/// would otherwise be encrypted by this execution-layer hook BEFORE the value
/// reaches graph_store — and because the stored bytes are already an FLE
/// envelope, graph_store's own `isSecurityGraphName` guard (which only fires on
/// plaintext input via `isLikelyFleEnvelope`) can no longer undo it. The auth
/// HMAC chain is computed over plaintext, so the rewritten property would brick
/// the next restart. Mirror the graph_store guard at this layer using the
/// single source-of-truth constant. Lazy import avoids a top-level cycle.
fn isSecurityGraph(graph_name: ?[]const u8) bool {
    const name = graph_name orelse return false;
    const graph_store = @import("../graph_store.zig");
    return std.mem.eql(u8, name, graph_store.SECURITY_GRAPH_NAME);
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
    graph_name: ?[]const u8,
    node_labels: [][]const u8,
    field_name: []const u8,
    plaintext_value: []const u8,
    node_id: u64,
) (FLEHookError || std.mem.Allocator.Error)![]const u8 {
    // GAP-0854 follow-up: never FLE-encrypt the internal security graph (see
    // isSecurityGraph). Returning the plaintext here keeps the auth HMAC chain
    // computable and lets graph_store's TDE protect it at rest.
    if (isSecurityGraph(graph_name)) {
        return plaintext_value;
    }
    // Get node type from first label
    if (node_labels.len == 0) {
        return plaintext_value; // No type, cannot check encryption
    }
    const node_type = node_labels[0];

    // Check if this field requires encryption BEFORE attempting encryption
    // This allows us to distinguish between "no encryption needed" and "encryption failed"
    const requires_encryption = fle_integration.fieldRequiresEncryption(node_type, field_name);

    // Create encryption context
    // GAP-0281: tenant_id from FLE context instead of hardcoded "default".
    // GAP-0852: prefer the request-scoped ExecutionContext tenant over the
    // per-thread map so async/work-stealing executors stay tenant-correct.
    const ctx = fle_integration.EncryptionContext{
        .tenant_id = fle_integration.tenantPreferringActiveContext(),
        .schema_name = node_type,
        .allocator = allocator,
        .current_user_role = fle_integration.rolePreferringActiveContext(),
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
            // SONNY-6324: the structured security log (an unloadable FLE
            // catalog makes this the path of every string write).
            fle_log.err("SECURITY: encryption required but failed; refusing to write plaintext", &.{
                Attr.string("type", node_type),
                Attr.string("field", field_name),
                Attr.string("error", @errorName(err)),
            });
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
    graph_name: ?[]const u8,
    edge_type: []const u8,
    field_name: []const u8,
    plaintext_value: []const u8,
    edge_id: u64,
) (FLEHookError || std.mem.Allocator.Error)![]const u8 {
    // GAP-0854 follow-up: never FLE-encrypt the internal security graph (see
    // isSecurityGraph) — security-graph edges such as HAS_ROLE feed the auth
    // HMAC chain and must stay plaintext (TDE protects them at rest).
    if (isSecurityGraph(graph_name)) {
        return plaintext_value;
    }
    // Check if this field requires encryption BEFORE attempting encryption
    const requires_encryption = fle_integration.fieldRequiresEncryption(edge_type, field_name);

    // Create encryption context
    // GAP-0281: tenant_id from FLE context instead of hardcoded "default".
    // GAP-0852: prefer the request-scoped ExecutionContext tenant over the
    // per-thread map (see fle_integration.tenantPreferringActiveContext).
    const ctx = fle_integration.EncryptionContext{
        .tenant_id = fle_integration.tenantPreferringActiveContext(),
        .schema_name = edge_type,
        .allocator = allocator,
        .current_user_role = fle_integration.rolePreferringActiveContext(),
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
            fle_log.err("SECURITY: encryption required for an edge property but failed; refusing to write plaintext", &.{
                Attr.string("type", edge_type),
                Attr.string("field", field_name),
                Attr.string("error", @errorName(err)),
            });
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
    // GAP-0281: tenant_id from FLE context instead of hardcoded "default".
    // GAP-0852: prefer the request-scoped ExecutionContext tenant over the
    // per-thread map (see fle_integration.tenantPreferringActiveContext) — the
    // same active context the GPS gate above already consulted.
    const ctx = fle_integration.EncryptionContext{
        .tenant_id = fle_integration.tenantPreferringActiveContext(),
        .schema_name = node_type,
        .allocator = allocator,
        .current_user_role = fle_integration.rolePreferringActiveContext(),
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
