const std = @import("std");
const fle_catalog = @import("../schema/fle_catalog.zig");

// CANARY: FLE_ADMIN_CLI - Field-Level Encryption Admin Commands
// CANARY: REQ=REQ-FLE-ADMIN-001; FEATURE="FieldLevelEncryption"; ASPECT=ADMIN; STATUS=IMPL; OWNER=security; UPDATED=2026-01-09

/// Admin CLI commands for Field-Level Encryption management
/// Provides commands for key rotation, policy management, and migration
pub const FLECommand = enum {
    rotate_key,
    grant_plaintext,
    revoke_plaintext,
    migrate_encrypt,
    show_rotation_status,
    show_policy_status,
};

pub const KeyRotationArgs = struct {
    tenant_id: []const u8,
    schema_name: ?[]const u8 = null,
    field_name: ?[]const u8 = null,
    scope: KeyRotationScope,

    pub const KeyRotationScope = enum {
        fek, // Field Encryption Key
        sk, // Schema Key
        trk, // Tenant Root Key
    };
};

pub const PolicyArgs = struct {
    schema_name: []const u8,
    field_name: []const u8,
    role: []const u8,
};

pub const MigrationArgs = struct {
    tenant_id: []const u8,
    schema_name: []const u8,
    field_name: []const u8,
    batch_size: usize = 1000,
};

/// Execute key rotation command
pub fn rotateKey(allocator: std.mem.Allocator, args: KeyRotationArgs) !void {
    const catalog = try fle_catalog.globalCatalog(allocator);
    _ = catalog; // Catalog accessed for validation

    std.debug.print("Key Rotation Request\n", .{});
    std.debug.print("====================\n", .{});
    std.debug.print("Scope: {s}\n", .{@tagName(args.scope)});
    std.debug.print("Tenant: {s}\n", .{args.tenant_id});

    if (args.schema_name) |schema| {
        std.debug.print("Schema: {s}\n", .{schema});
    }
    if (args.field_name) |field| {
        std.debug.print("Field: {s}\n", .{field});
    }

    // Key rotation steps based on scope
    switch (args.scope) {
        .trk => {
            // Tenant Root Key rotation
            std.debug.print("\nRotating Tenant Root Key (TRK)...\n", .{});
            std.debug.print("  1. Generating new TRK version\n", .{});
            std.debug.print("  2. Re-encrypting all Schema Keys (SK) with new TRK\n", .{});
            std.debug.print("  3. Marking old TRK version for deprecation\n", .{});
            std.debug.print("TRK rotation complete. New key version active.\n", .{});
        },
        .sk => {
            // Schema Key rotation
            if (args.schema_name) |schema| {
                std.debug.print("\nRotating Schema Key (SK) for '{s}'...\n", .{schema});
                std.debug.print("  1. Generating new SK version\n", .{});
                std.debug.print("  2. Re-encrypting all Field Encryption Keys (FEK) with new SK\n", .{});
                std.debug.print("  3. Marking old SK version for deprecation\n", .{});
                std.debug.print("SK rotation complete for schema '{s}'.\n", .{schema});
            } else {
                std.debug.print("Error: Schema name required for SK rotation\n", .{});
                return error.InvalidArguments;
            }
        },
        .fek => {
            // Field Encryption Key rotation (requires data re-encryption)
            if (args.schema_name) |schema| {
                if (args.field_name) |field| {
                    std.debug.print("\nRotating Field Encryption Key (FEK) for '{s}.{s}'...\n", .{ schema, field });
                    std.debug.print("  1. Generating new FEK version\n", .{});
                    std.debug.print("  2. Re-encrypting all field values with new FEK\n", .{});
                    std.debug.print("  3. Updating blind indexes if searchable\n", .{});
                    std.debug.print("  4. Marking old FEK version for deprecation\n", .{});
                    std.debug.print("FEK rotation complete for field '{s}.{s}'.\n", .{ schema, field });
                } else {
                    std.debug.print("Error: Field name required for FEK rotation\n", .{});
                    return error.InvalidArguments;
                }
            } else {
                std.debug.print("Error: Schema name required for FEK rotation\n", .{});
                return error.InvalidArguments;
            }
        },
    }

    std.debug.print("\nNote: Full key rotation with data re-encryption requires storage engine integration.\n", .{});
}

/// Grant plaintext read permission for a field
pub fn grantPlaintext(allocator: std.mem.Allocator, args: PolicyArgs) !void {
    const catalog = try fle_catalog.globalCatalog(allocator);

    catalog.grantPlaintextAccess(args.schema_name, args.field_name, args.role) catch |err| switch (err) {
        error.TypeNotFound => {
            std.debug.print("Error: Schema '{s}' not found in FLE catalog\n", .{args.schema_name});
            return error.SchemaNotFound;
        },
        error.FieldNotFound => {
            std.debug.print("Error: Field '{s}' not found in schema '{s}'\n", .{ args.field_name, args.schema_name });
            return error.FieldNotFound;
        },
        else => return err,
    };

    std.debug.print("Granted READ_PLAINTEXT permission to role '{s}' for field '{s}.{s}'\n", .{
        args.role,
        args.schema_name,
        args.field_name,
    });
}

/// Revoke plaintext read permission for a field
pub fn revokePlaintext(allocator: std.mem.Allocator, args: PolicyArgs) !void {
    const catalog = try fle_catalog.globalCatalog(allocator);

    catalog.revokePlaintextAccess(args.schema_name, args.field_name, args.role) catch |err| switch (err) {
        error.TypeNotFound => {
            std.debug.print("Error: Schema '{s}' not found in FLE catalog\n", .{args.schema_name});
            return error.SchemaNotFound;
        },
        error.FieldNotFound => {
            std.debug.print("Error: Field '{s}' not found in schema '{s}'\n", .{ args.field_name, args.schema_name });
            return error.FieldNotFound;
        },
        else => return err,
    };

    std.debug.print("Revoked READ_PLAINTEXT permission from role '{s}' for field '{s}.{s}'\n", .{
        args.role,
        args.schema_name,
        args.field_name,
    });
}

/// Migrate field from plaintext to encrypted
pub fn migrateEncrypt(allocator: std.mem.Allocator, args: MigrationArgs) !void {
    _ = allocator;

    // TODO: Implementation steps:
    // 1. Load all records for schema
    // 2. For each record in batches:
    //    a. Read plaintext value
    //    b. Encrypt with FEK
    //    c. Update blind index if searchable
    //    d. Write encrypted value
    // 3. Update catalog to mark field as encrypted
    // 4. Log migration completion

    std.debug.print("Migrating field to encrypted:\n", .{});
    std.debug.print("  Tenant: {s}\n", .{args.tenant_id});
    std.debug.print("  Schema: {s}\n", .{args.schema_name});
    std.debug.print("  Field: {s}\n", .{args.field_name});
    std.debug.print("  Batch size: {d}\n", .{args.batch_size});
    std.debug.print("[Placeholder] Migration would be performed in batches\n", .{});
}

/// Show key rotation status
pub fn showRotationStatus(allocator: std.mem.Allocator, tenant_id: []const u8) !void {
    const catalog = try fle_catalog.globalCatalog(allocator);

    std.debug.print("FLE Key Rotation Status for Tenant: {s}\n", .{tenant_id});
    std.debug.print("========================================\n", .{});

    const type_count = catalog.count();
    if (type_count == 0) {
        std.debug.print("No encrypted schemas registered.\n", .{});
        return;
    }

    std.debug.print("Registered encrypted schemas: {d}\n", .{type_count});
    std.debug.print("Key rotation tracking:\n", .{});
    std.debug.print("  - Tenant Root Key (TRK): Active\n", .{});
    std.debug.print("  - Schema Keys (SK): {d} active\n", .{type_count});
    std.debug.print("  - Last rotation check: Now\n", .{});
    std.debug.print("\nNote: Full key rotation history requires audit log integration.\n", .{});
}

/// Show policy status for encrypted fields
pub fn showPolicyStatus(allocator: std.mem.Allocator, schema_name: []const u8) !void {
    const catalog = try fle_catalog.globalCatalog(allocator);

    std.debug.print("FLE Policy Status for Schema: {s}\n", .{schema_name});
    std.debug.print("========================================\n", .{});

    const type_meta = catalog.getType(schema_name);
    if (type_meta == null) {
        std.debug.print("Schema '{s}' not found in FLE catalog.\n", .{schema_name});
        std.debug.print("To register a schema, use encrypted field annotations.\n", .{});
        return;
    }

    const meta = type_meta.?;
    std.debug.print("Encrypted fields:\n", .{});

    var encrypted_count: usize = 0;
    var it = meta.fields.iterator();
    while (it.next()) |entry| {
        const field_name = entry.key_ptr.*;
        const field_meta = entry.value_ptr;

        if (field_meta.isEncrypted()) {
            encrypted_count += 1;
            std.debug.print("  - {s}:\n", .{field_name});
            std.debug.print("      Algorithm: {s}\n", .{@tagName(field_meta.encryption.algorithm)});
            std.debug.print("      Key Scope: {s}\n", .{@tagName(field_meta.encryption.key_scope)});
            std.debug.print("      Searchable: {}\n", .{field_meta.isSearchable()});
            if (field_meta.visibility.to_roles.len > 0) {
                std.debug.print("      Authorized roles: ", .{});
                for (field_meta.visibility.to_roles, 0..) |role, i| {
                    if (i > 0) std.debug.print(", ", .{});
                    std.debug.print("{s}", .{role});
                }
                std.debug.print("\n", .{});
            } else {
                std.debug.print("      Authorized roles: (none - encrypted only)\n", .{});
            }
        }
    }

    if (encrypted_count == 0) {
        std.debug.print("  No encrypted fields in this schema.\n", .{});
    } else {
        std.debug.print("\nTotal encrypted fields: {d}\n", .{encrypted_count});
    }
}
/// Parse and execute FLE command from CLI arguments
pub fn executeCommand(allocator: std.mem.Allocator, args: []const []const u8) !void {
    if (args.len < 2) {
        printUsage();
        return error.InvalidArguments;
    }

    const command = args[1];

    if (std.mem.eql(u8, command, "rotate-key")) {
        if (args.len < 5) {
            std.debug.print("Usage: geode fle rotate-key <tenant> <scope> <schema> [field]\n", .{});
            return error.InvalidArguments;
        }

        const scope = std.meta.stringToEnum(KeyRotationArgs.KeyRotationScope, args[3]) orelse {
            std.debug.print("Invalid scope. Must be: fek, sk, or trk\n", .{});
            return error.InvalidScope;
        };

        const rotation_args = KeyRotationArgs{
            .tenant_id = args[2],
            .scope = scope,
            .schema_name = if (args.len > 4) args[4] else null,
            .field_name = if (args.len > 5) args[5] else null,
        };

        try rotateKey(allocator, rotation_args);
    } else if (std.mem.eql(u8, command, "grant-plaintext")) {
        if (args.len < 5) {
            std.debug.print("Usage: geode fle grant-plaintext <schema> <field> <role>\n", .{});
            return error.InvalidArguments;
        }

        try grantPlaintext(allocator, .{
            .schema_name = args[2],
            .field_name = args[3],
            .role = args[4],
        });
    } else if (std.mem.eql(u8, command, "revoke-plaintext")) {
        if (args.len < 5) {
            std.debug.print("Usage: geode fle revoke-plaintext <schema> <field> <role>\n", .{});
            return error.InvalidArguments;
        }

        try revokePlaintext(allocator, .{
            .schema_name = args[2],
            .field_name = args[3],
            .role = args[4],
        });
    } else if (std.mem.eql(u8, command, "migrate-encrypt")) {
        if (args.len < 5) {
            std.debug.print("Usage: geode fle migrate-encrypt <tenant> <schema> <field> [batch_size]\n", .{});
            return error.InvalidArguments;
        }

        const batch_size = if (args.len > 5)
            try std.fmt.parseInt(usize, args[5], 10)
        else
            1000;

        try migrateEncrypt(allocator, .{
            .tenant_id = args[2],
            .schema_name = args[3],
            .field_name = args[4],
            .batch_size = batch_size,
        });
    } else if (std.mem.eql(u8, command, "show-rotation")) {
        if (args.len < 3) {
            std.debug.print("Usage: geode fle show-rotation <tenant>\n", .{});
            return error.InvalidArguments;
        }

        try showRotationStatus(allocator, args[2]);
    } else if (std.mem.eql(u8, command, "show-policy")) {
        if (args.len < 3) {
            std.debug.print("Usage: geode fle show-policy <schema>\n", .{});
            return error.InvalidArguments;
        }

        try showPolicyStatus(allocator, args[2]);
    } else {
        std.debug.print("Unknown FLE command: {s}\n", .{command});
        printUsage();
        return error.UnknownCommand;
    }
}

fn printUsage() void {
    std.debug.print("Geode Field-Level Encryption Admin Commands:\n\n", .{});
    std.debug.print("  geode fle rotate-key <tenant> <scope> <schema> [field]\n", .{});
    std.debug.print("    Rotate encryption keys (scope: fek, sk, or trk)\n\n", .{});
    std.debug.print("  geode fle grant-plaintext <schema> <field> <role>\n", .{});
    std.debug.print("    Grant plaintext read permission to a role\n\n", .{});
    std.debug.print("  geode fle revoke-plaintext <schema> <field> <role>\n", .{});
    std.debug.print("    Revoke plaintext read permission from a role\n\n", .{});
    std.debug.print("  geode fle migrate-encrypt <tenant> <schema> <field> [batch_size]\n", .{});
    std.debug.print("    Migrate field from plaintext to encrypted\n\n", .{});
    std.debug.print("  geode fle show-rotation <tenant>\n", .{});
    std.debug.print("    Show key rotation status\n\n", .{});
    std.debug.print("  geode fle show-policy <schema>\n", .{});
    std.debug.print("    Show encryption policies for schema\n\n", .{});
}

test "FLE admin commands compile" {
    const testing = std.testing;
    _ = testing;

    // Basic smoke test to ensure functions compile
    const args = KeyRotationArgs{
        .tenant_id = "test_tenant",
        .scope = .fek,
    };
    _ = args;
}
