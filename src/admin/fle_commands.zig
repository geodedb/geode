const std = @import("std");

const fle_catalog = @import("../schema/fle_catalog.zig");
const master_key_check = @import("../keys/master_key_check.zig");

// Field-Level Encryption Admin Commands
// CANARY: REQ=REQ-FLE-ADMIN-001; FEATURE="FieldLevelEncryption"; ASPECT=ADMIN; STATUS=TESTED; TEST=tests/test_sonny6321_fle_admin_cli.zig; OWNER=security; UPDATED=2026-11-16
// SONNY-6386: rotateKey no longer fabricates a rotation (it refuses as
// unsupported, REQ-SONNY-6386-FLE-ROTATE-UNSUPPORTED). SONNY-6321:
// grant/revoke/show and the command dispatcher are executed against a
// persisted catalog; migrateEncrypt (in process, without the store) refuses
// and points at the server (SONNY-6688).

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

// CANARY: REQ=REQ-SONNY-6386-FLE-ROTATE-UNSUPPORTED; FEATURE="FieldLevelEncryption"; ASPECT=RotateKeyRefusedAsUnsupported; STATUS=TESTED; TEST=tests/test_sonny6386_fle_rotate_key_unsupported.zig; OWNER=security; UPDATED=2026-11-12
/// Message for every FLE key-rotation entry point until real rotation
/// (new key version persisted, wrapped keys rewrapped, field values and
/// blind indexes re-encrypted) exists: story SONNY-6387.
pub const rotation_unsupported_message =
    "FLE key rotation is not supported in this release (SONNY-6387): no key was rotated, rewrapped or re-encrypted.";

/// Key rotation request. SONNY-6386: this printed "TRK/SK/FEK rotation
/// complete. New key version active." without touching any key. The
/// arguments are still validated (a missing schema or field is
/// InvalidArguments); a well-formed request is refused with
/// error.Unsupported until SONNY-6387 implements rotation.
pub fn rotateKey(allocator: std.mem.Allocator, args: KeyRotationArgs) !void {
    _ = allocator;
    switch (args.scope) {
        .trk => {},
        .sk => if (args.schema_name == null) {
            std.debug.print("Error: Schema name required for SK rotation\n", .{});
            return error.InvalidArguments;
        },
        .fek => {
            if (args.schema_name == null) {
                std.debug.print("Error: Schema name required for FEK rotation\n", .{});
                return error.InvalidArguments;
            }
            if (args.field_name == null) {
                std.debug.print("Error: Field name required for FEK rotation\n", .{});
                return error.InvalidArguments;
            }
        },
    }
    std.debug.print("Error: {s}\n", .{rotation_unsupported_message});
    return error.Unsupported;
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
        // SONNY-6324: it used to report success with the grant unsaved.
        error.FleCatalogNotPersisted => {
            std.debug.print("Error: the grant could not be saved to the FLE catalog and was not applied. Fix the data directory and retry\n", .{});
            return err;
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
        // SONNY-6324: it used to report success with the revoke unsaved.
        error.FleRevokeNotPersisted => {
            std.debug.print("Error: the revoke could not be saved to the FLE catalog; role '{s}' keeps READ_PLAINTEXT on '{s}.{s}' in the catalog file. Fix the data directory and retry\n", .{ args.role, args.schema_name, args.field_name });
            return err;
        },
        else => return err,
    };

    std.debug.print("Revoked READ_PLAINTEXT permission from role '{s}' for field '{s}.{s}'\n", .{
        args.role,
        args.schema_name,
        args.field_name,
    });
}

// CANARY: REQ=REQ-FLE-MIGRATE-001; FEATURE="FieldLevelEncryption"; ASPECT=Migration; STATUS=TESTED; TEST=tests/test_sonny6688_fle_migrate_encrypt.zig; OWNER=security; UPDATED=2026-11-16
// CANARY: REQ=REQ-FLE-BATCH-001; FEATURE="FLE Batch Re-encryption"; ASPECT=ProgressTracking; STATUS=TESTED; TEST=tests/test_sonny6688_fle_migrate_encrypt.zig; OWNER=security; UPDATED=2026-11-16
// CANARY: REQ=REQ-FLE-STORAGE-001; FEATURE="FLE Storage Callback"; ASPECT=StorageIntegration; STATUS=TESTED; TEST=tests/test_sonny6688_fle_migrate_encrypt.zig; OWNER=security; UPDATED=2026-11-16
/// SONNY-6688: the migration of a field's stored plaintext runs in the
/// server that owns the store: `CALL geode.fle.migrateEncrypt` (batched,
/// resumable, through the graph store; `execution/fle_migration.zig`),
/// which `geode fle migrate-encrypt` sends. In process, without that store,
/// this validates the request (the master key check first, then the schema
/// and field) and refuses: there is no store here to migrate. It used a
/// storage callback no caller set, and encrypted under an identity readers
/// do not use (SONNY-6321).
pub const migration_needs_server_message =
    "FLE migrate-encrypt runs in the server that owns the data: use `geode fle migrate-encrypt <tenant> <schema> <field> [batch_size] --server <host:port>` or CALL geode.fle.migrateEncrypt; nothing was read or encrypted here.";

pub fn migrateEncrypt(allocator: std.mem.Allocator, args: MigrationArgs) !void {
    // SONNY-6442: before anything else, refuse a GEODE_MASTER_KEY other than
    // the one this data directory's encrypted fields were written with (as
    // `geode serve` does at startup), and record it where none is.
    if (try master_key_check.fleDataDir(allocator)) |dir| {
        defer allocator.free(dir);
        try master_key_check.verifyOrRecord(allocator, dir, .fle_cli);
    }
    const catalog = try fle_catalog.globalCatalog(allocator);
    if (!catalog.hasType(args.schema_name)) {
        std.debug.print("Error: Schema '{s}' not found in FLE catalog\n", .{args.schema_name});
        return error.SchemaNotFound;
    }
    const field_meta = (try catalog.copyFieldMetadata(allocator, args.schema_name, args.field_name)) orelse {
        std.debug.print("Error: Field '{s}' not found in schema '{s}'\n", .{ args.field_name, args.schema_name });
        return error.FieldNotFound;
    };
    fle_catalog.freeFieldCopy(allocator, field_meta);
    std.debug.print("Error: {s}\n", .{migration_needs_server_message});
    return error.Unsupported;
}

/// Show key rotation status
pub fn showRotationStatus(allocator: std.mem.Allocator, tenant_id: []const u8) !void {
    const catalog = try fle_catalog.globalCatalog(allocator);

    std.debug.print("FLE Key Rotation Status for Tenant: {s}\n", .{tenant_id});
    std.debug.print("========================================\n", .{});

    const type_count = catalog.count();
    if (type_count == 0) {
        std.debug.print("No encrypted schemas registered.\n", .{});
        std.debug.print("Key rotation: not supported in this release (SONNY-6387); no rotation has been performed.\n", .{});
        return;
    }

    std.debug.print("Registered encrypted schemas: {d}\n", .{type_count});
    // SONNY-6386: this printed "TRK: Active" and "Last rotation check: Now",
    // which nothing measured. No rotation exists to report.
    std.debug.print("Key rotation: not supported in this release (SONNY-6387); no rotation has been performed.\n", .{});
}

/// Show policy status for encrypted fields
pub fn showPolicyStatus(allocator: std.mem.Allocator, schema_name: []const u8) !void {
    const catalog = try fle_catalog.globalCatalog(allocator);

    std.debug.print("FLE Policy Status for Schema: {s}\n", .{schema_name});
    std.debug.print("========================================\n", .{});

    // SONNY-6327: copies made under the catalog mutex, owned here.
    const fields = (try catalog.copyTypeFields(allocator, schema_name)) orelse {
        std.debug.print("Schema '{s}' not found in FLE catalog.\n", .{schema_name});
        std.debug.print("To register a schema, use encrypted field annotations.\n", .{});
        return;
    };
    defer fle_catalog.freeFieldCopies(allocator, fields);
    std.debug.print("Encrypted fields:\n", .{});

    var encrypted_count: usize = 0;
    for (fields) |*field_meta| {
        const field_name = field_meta.field_name;

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
    std.debug.print("    not supported in this release (SONNY-6387); refused with an error\n\n", .{});
    std.debug.print("  geode fle grant-plaintext <schema> <field> <role>\n", .{});
    std.debug.print("    Grant plaintext read permission to a role\n\n", .{});
    std.debug.print("  geode fle revoke-plaintext <schema> <field> <role>\n", .{});
    std.debug.print("    Revoke plaintext read permission from a role\n\n", .{});
    std.debug.print("  geode fle migrate-encrypt <tenant> <schema> <field> [batch_size]\n", .{});
    std.debug.print("    run against the server (--server); see `geode fle --help`\n\n", .{});
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
