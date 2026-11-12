const std = @import("std");
const geode = @import("geode");
const fle_commands = geode.fle_commands;

/// FLE command handler
pub fn cmdFLE(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    // Ensure global catalog is cleaned up when command exits
    defer geode.fle_integration.catalog_mod.resetGlobalCatalog(allocator);

    if (start_idx + 1 >= argv.len) {
        printFLEUsage();
        return;
    }

    const subcmd = argv[start_idx + 1];

    if (std.mem.eql(u8, subcmd, "-h") or std.mem.eql(u8, subcmd, "--help")) {
        printFLEUsage();
        return;
    }

    if (std.mem.eql(u8, subcmd, "rotate-key")) {
        return handleRotateKey(allocator, argv, start_idx + 2);
    } else if (std.mem.eql(u8, subcmd, "show-rotation")) {
        return handleShowRotation(allocator, argv, start_idx + 2);
    } else if (std.mem.eql(u8, subcmd, "show-policy")) {
        return handleShowPolicy(allocator, argv, start_idx + 2);
    } else if (std.mem.eql(u8, subcmd, "grant-plaintext")) {
        return handleGrantPlaintext(allocator, argv, start_idx + 2);
    } else if (std.mem.eql(u8, subcmd, "migrate-encrypt")) {
        return handleMigrateEncrypt(allocator, argv, start_idx + 2);
    } else {
        std.debug.print("Error: unknown FLE subcommand '{s}'\n", .{subcmd});
        printFLEUsage();
        return error.UnknownSubcommand;
    }
}

fn printFLEUsage() void {
    std.debug.print("geode fle - Field-Level Encryption management\n" ++
        "\n" ++
        "Usage: geode fle <subcommand> [args...]\n" ++
        "\n" ++
        "Subcommands:\n" ++
        "  rotate-key <tenant> <scope> [args...]         not supported in this release (SONNY-6387):\n" ++
        "                                                refused with an error; no key is rotated\n" ++
        "     Scopes:\n" ++
        "       fek <schema> <field>    Field Encryption Key\n" ++
        "       sk <schema>             Schema Key\n" ++
        "       trk                     Tenant Root Key\n" ++
        "  show-rotation <tenant>                        Show key rotation status\n" ++
        "  show-policy <schema>                          Show encryption policy for schema\n" ++
        "  grant-plaintext <schema> <field> <role>       Grant READ_PLAINTEXT privilege\n" ++
        "  migrate-encrypt <tenant> <schema> <field> [batch_size]  Migrate plaintext to encrypted\n" ++
        "\n" ++
        "Examples:\n" ++
        "  geode fle show-rotation default\n" ++
        "  geode fle show-policy Person\n" ++
        "  geode fle grant-plaintext Person ssn pii_reader\n" ++
        "\n", .{});
}

// SONNY-6386: this built a throwaway in-memory KeyManager from
// GEODE_MASTER_KEY, bumped a version in it, printed "Rotated FEK ... to
// version N" / "Rewrapped SK/TRK" and exited 0. Nothing was persisted and no
// field value was re-encrypted. Rotation is refused as unsupported until
// SONNY-6387 (fle_commands.rotateKey).
fn handleRotateKey(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    if (start_idx + 1 >= argv.len) {
        std.debug.print("Error: rotate-key requires: <tenant> <scope> [args...]\n", .{});
        return error.InvalidArguments;
    }

    const tenant = argv[start_idx];
    const scope = std.meta.stringToEnum(fle_commands.KeyRotationArgs.KeyRotationScope, argv[start_idx + 1]) orelse {
        std.debug.print("Error: unknown scope '{s}' (expected: fek, sk, trk)\n", .{argv[start_idx + 1]});
        return error.InvalidArguments;
    };
    try fle_commands.rotateKey(allocator, .{
        .tenant_id = tenant,
        .scope = scope,
        .schema_name = if (start_idx + 2 < argv.len) argv[start_idx + 2] else null,
        .field_name = if (start_idx + 3 < argv.len) argv[start_idx + 3] else null,
    });
}

fn handleShowRotation(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    if (start_idx >= argv.len) {
        std.debug.print("Error: show-rotation requires: <tenant>\n", .{});
        return error.InvalidArguments;
    }
    const tenant = argv[start_idx];
    try fle_commands.showRotationStatus(allocator, tenant);
}

fn handleShowPolicy(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    if (start_idx >= argv.len) {
        std.debug.print("Error: show-policy requires: <schema>\n", .{});
        return error.InvalidArguments;
    }
    const schema = argv[start_idx];
    try fle_commands.showPolicyStatus(allocator, schema);
}

fn handleGrantPlaintext(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    if (start_idx + 2 >= argv.len) {
        std.debug.print("Error: grant-plaintext requires: <schema> <field> <role>\n", .{});
        return error.InvalidArguments;
    }
    const schema = argv[start_idx];
    const field = argv[start_idx + 1];
    const role = argv[start_idx + 2];

    // SONNY-6274: with no data directory the FLE catalog is in memory, so the
    // grant would end with this process. It used to land in a shared /tmp file.
    if (!geode.fle_integration.catalog_mod.isPersisted()) {
        std.debug.print("Error: grant-plaintext needs GEODE_DATA_DIR set to the server's data directory (the FLE catalog lives there)\n", .{});
        return error.InvalidArguments;
    }
    const catalog = try geode.fle_integration.catalog_mod.globalCatalog(allocator);
    catalog.grantPlaintextAccess(schema, field, role) catch |err| {
        std.debug.print("\n❌ Error: Failed to grant privilege: {any}\n", .{err});
        return err;
    };
    std.debug.print("\n✓ Privilege granted successfully\n", .{});
}

// CANARY: REQ=REQ-FLE-MIGRATE-CLI-001; FEATURE="FLEMigrateCLI"; ASPECT=CLI; STATUS=IMPL; OWNER=security; UPDATED=2026-11-12
// GAP-0147 FIX: Properly delegate to fle_commands.migrateEncrypt with full validation
fn handleMigrateEncrypt(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    if (start_idx + 2 >= argv.len) {
        std.debug.print("Error: migrate-encrypt requires: <tenant> <schema> <field> [batch_size]\n", .{});
        return error.InvalidArguments;
    }

    const tenant = argv[start_idx];
    const schema = argv[start_idx + 1];
    const field = argv[start_idx + 2];

    // Parse optional batch_size parameter (default: 1000)
    var batch_size: usize = 1000;
    if (start_idx + 3 < argv.len) {
        batch_size = std.fmt.parseInt(usize, argv[start_idx + 3], 10) catch {
            std.debug.print("Error: Invalid batch_size '{s}' - must be a positive integer\n", .{argv[start_idx + 3]});
            return error.InvalidArguments;
        };
        if (batch_size == 0) {
            std.debug.print("Error: batch_size must be greater than 0\n", .{});
            return error.InvalidArguments;
        }
    }

    // Build migration arguments
    const args = fle_commands.MigrationArgs{
        .tenant_id = tenant,
        .schema_name = schema,
        .field_name = field,
        .batch_size = batch_size,
    };

    // GAP-0147: Call the actual fle_commands implementation
    fle_commands.migrateEncrypt(allocator, args) catch |err| {
        switch (err) {
            error.SchemaNotFound => {
                std.debug.print("\n❌ Migration failed: Schema '{s}' not found in FLE catalog\n", .{schema});
                std.debug.print("Hint: Ensure the schema has FLE annotations defined.\n", .{});
            },
            error.FieldNotFound => {
                std.debug.print("\n❌ Migration failed: Field '{s}' not found in schema '{s}'\n", .{ field, schema });
                std.debug.print("Hint: Check field name and ensure encryption is configured.\n", .{});
            },
            else => {
                std.debug.print("\n❌ Migration failed: {any}\n", .{err});
            },
        }
        return err;
    };
}
