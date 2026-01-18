const std = @import("std");
const fle_integration = @import("../fle_integration.zig");

// Field-Level Encryption Execution Hooks
// CANARY: REQ=REQ-FLE-EXECUTION-001; FEATURE="FieldLevelEncryption"; ASPECT=EXECUTION; STATUS=TESTED; TEST=tests/test_tde_kms_integration.zig; OWNER=security; UPDATED=2026-01-15

/// Helper function to encrypt node property value if needed before storing
/// Returns the potentially encrypted value to store
pub fn encryptPropertyIfNeeded(
    allocator: std.mem.Allocator,
    node_labels: [][]const u8,
    field_name: []const u8,
    plaintext_value: []const u8,
    node_id: u64,
) ![]const u8 {
    // Get node type from first label
    if (node_labels.len == 0) {
        return plaintext_value; // No type, cannot check encryption
    }
    const node_type = node_labels[0];

    // Create encryption context
    const ctx = fle_integration.EncryptionContext{
        .tenant_id = "default",
        .schema_name = node_type,
        .allocator = allocator,
        .current_user_role = fle_integration.getCurrentUserRole(),
    };

    const record_id = try std.fmt.allocPrint(allocator, "{d}", .{node_id});

    // Try to encrypt - if field is not encrypted, returns original value
    const encrypted_value = fle_integration.encryptFieldIfNeeded(
        ctx,
        node_type,
        field_name,
        plaintext_value,
        record_id,
    ) catch |err| {
        // If encryption fails, log and return original value
        std.debug.print("Warning: Failed to encrypt field {s}.{s}: {}\n", .{ node_type, field_name, err });
        return plaintext_value;
    };

    return encrypted_value;
}

/// Helper function to encrypt edge property value if needed before storing
/// Returns the potentially encrypted value to store
pub fn encryptEdgePropertyIfNeeded(
    allocator: std.mem.Allocator,
    edge_type: []const u8,
    field_name: []const u8,
    plaintext_value: []const u8,
    edge_id: u64,
) ![]const u8 {
    // Create encryption context
    const ctx = fle_integration.EncryptionContext{
        .tenant_id = "default",
        .schema_name = edge_type,
        .allocator = allocator,
        .current_user_role = fle_integration.getCurrentUserRole(),
    };

    const record_id = try std.fmt.allocPrint(allocator, "edge_{d}", .{edge_id});

    // Try to encrypt - if field is not encrypted, returns original value
    const encrypted_value = fle_integration.encryptFieldIfNeeded(
        ctx,
        edge_type,
        field_name,
        plaintext_value,
        record_id,
    ) catch |err| {
        // If encryption fails, log and return original value
        std.debug.print("Warning: Failed to encrypt edge property {s}.{s}: {}\n", .{ edge_type, field_name, err });
        return plaintext_value;
    };

    return encrypted_value;
}

/// Helper function to decrypt field value if needed when reading
/// Returns decrypted value for authorized users, "[REDACTED]" for others
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

    // Create encryption context
    const ctx = fle_integration.EncryptionContext{
        .tenant_id = "default",
        .schema_name = node_type,
        .allocator = allocator,
        .current_user_role = fle_integration.getCurrentUserRole(),
    };

    // Try to decrypt - handles RBAC and returns "[REDACTED]" if unauthorized
    const decrypted_value = fle_integration.decryptFieldIfNeeded(
        ctx,
        node_type,
        field_name,
        stored_value,
        try std.fmt.allocPrint(allocator, "{d}", .{node_id}),
        true, // check_rbac = true
    ) catch |err| {
        // If decryption fails, return "[REDACTED]" for safety
        std.debug.print("Warning: Failed to decrypt field {s}.{s}: {}\n", .{ node_type, field_name, err });
        return try allocator.dupe(u8, "[REDACTED]");
    };

    return decrypted_value;
}
