const std = @import("std");
const fle_integration = @import("../fle_integration.zig");
const logging = @import("logging");
const fle_log = logging.scoped("fle");
const Attr = logging.Attr;

// Field-Level Encryption Execution Hooks
// CANARY: REQ=REQ-FLE-EXECUTION-001; FEATURE="FieldLevelEncryption"; ASPECT=EXECUTION; STATUS=TESTED; TEST=tests/test_sonny6321_tde_fle_cases.zig; OWNER=security; UPDATED=2026-11-12
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
    // SONNY-6335: the one encryption identity (fle_integration.recordIdentity).
    const encrypted_value = fle_integration.encryptStoredString(
        allocator,
        .node,
        node_type,
        field_name,
        plaintext_value,
        node_id,
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
    // SONNY-6335: the one encryption identity (fle_integration.recordIdentity).
    const encrypted_value = fle_integration.encryptStoredString(
        allocator,
        .edge,
        edge_type,
        field_name,
        plaintext_value,
        edge_id,
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
