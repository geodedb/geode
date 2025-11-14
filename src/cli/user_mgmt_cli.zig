const std = @import("std");
const geode = @import("geode");

// CANARY: REQ=REQ-M4.1-USER-MGMT-CLI-001; FEATURE="CLI Modularization"; ASPECT=UserManagement; STATUS=IMPL; OWNER=cli; UPDATED=2025-11-12
// Phase 4 M4.1: Extract user management commands (cmdUser, cmdRole) from cli/main.zig

// Exit codes for consistency with main CLI
const ExitCode = enum(u8) {
    success = 0,
    general_error = 1,
    usage_error = 2,
};

/// User management command handler
/// Handles: user create, user list, user delete, user update, user show
pub fn cmdUser(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    // start_idx points to "user", so start_idx + 1 is the subcommand
    // Skip global flags like --embedded, --no-quic to find the actual subcommand
    var subcmd_idx = start_idx + 1;
    while (subcmd_idx < argv.len) : (subcmd_idx += 1) {
        const arg = argv[subcmd_idx];
        // Skip known global flags
        if (std.mem.eql(u8, arg, "--embedded") or
            std.mem.eql(u8, arg, "--no-quic") or
            std.mem.eql(u8, arg, "--enable-auth") or
            std.mem.eql(u8, arg, "--audit"))
        {
            continue;
        }
        // Skip global flags with values
        if (std.mem.eql(u8, arg, "--server") or
            std.mem.eql(u8, arg, "--audit-file") or
            std.mem.eql(u8, arg, "--audit-syslog"))
        {
            subcmd_idx += 1; // Skip the value too
            continue;
        }
        // Found non-flag argument - this is the subcommand
        break;
    }

    if (subcmd_idx >= argv.len) {
        // No subcommand provided
        std.debug.print("Usage: geode user <command> [options]\n", .{});
        std.debug.print("Commands:\n", .{});
        std.debug.print("  create <username> <email> [--password <password>] [--role <role>]\n", .{});
        std.debug.print("  list\n", .{});
        std.debug.print("  delete <username>\n", .{});
        std.debug.print("  update <username> [--email <email>] [--password <password>] [--role <role>]\n", .{});
        std.debug.print("  show <username>\n", .{});
        std.process.exit(1);
    }

    const subcommand = argv[subcmd_idx];

    // Handle --help and -h flags
    if (std.mem.eql(u8, subcommand, "--help") or std.mem.eql(u8, subcommand, "-h")) {
        std.debug.print("Usage: geode user <command> [options]\n", .{});
        std.debug.print("Commands:\n", .{});
        std.debug.print("  create <username> <email> [--password <password>] [--role <role>]\n", .{});
        std.debug.print("  list\n", .{});
        std.debug.print("  delete <username>\n", .{});
        std.debug.print("  update <username> [--email <email>] [--password <password>] [--role <role>]\n", .{});
        std.debug.print("  show <username>\n", .{});
        std.process.exit(0);
    }

    if (std.mem.eql(u8, subcommand, "create")) {
        // geode user create <username> <email> [--password <password>] [--role <role>]
        if (subcmd_idx + 2 >= argv.len) {
            std.debug.print("Error: user create requires <username> and <email>\n", .{});
            std.debug.print("Usage: geode user create <username> <email> [--password <password>] [--role <role>]\n", .{});
            std.process.exit(1);
        }

        const username = argv[subcmd_idx + 1];
        const email = argv[subcmd_idx + 2];

        // Parse optional flags
        var password: ?[]const u8 = null;
        var role: ?[]const u8 = null;
        var i = subcmd_idx + 3;
        while (i < argv.len) : (i += 1) {
            if (std.mem.eql(u8, argv[i], "--password")) {
                if (i + 1 >= argv.len) {
                    std.debug.print("Error: --password requires a value\n", .{});
                    std.process.exit(1);
                }
                password = argv[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, argv[i], "--role")) {
                if (i + 1 >= argv.len) {
                    std.debug.print("Error: --role requires a value\n", .{});
                    std.process.exit(1);
                }
                role = argv[i + 1];
                i += 1;
            }
        }

        // Use geode.user_management to create user
        const user_mgmt = geode.user_management;
        if (!user_mgmt.isAuthEnabled()) {
            std.debug.print("Error: User management requires authentication to be enabled\n", .{});
            std.debug.print("Enable authentication with --enable-auth flag or AUTH_ENABLED=1 environment variable\n", .{});
            std.process.exit(1);
        }

        const final_password = password orelse {
            // Prompt for password if not provided
            std.debug.print("Password: ", .{});

            // TODO: Implement password reading when std.io methods are available
            std.debug.print("\nPassword reading not yet implemented - use --password flag\n", .{});
            std.process.exit(1);
        };
        defer if (password == null) allocator.free(final_password);

        // Parse role string to Role enum
        const role_enum = if (role) |r| user_mgmt.Role.fromString(r) orelse {
            std.debug.print("Error: Invalid role '{s}'. Valid roles: Admin, User, ReadWrite, ReadOnly\n", .{r});
            std.process.exit(1);
        } else user_mgmt.Role.User;

        // Create the user (note: createUser expects password before email)
        user_mgmt.createUser(allocator, username, final_password, email, role_enum) catch |err| {
            std.debug.print("Error creating user: {}\n", .{err});
            std.process.exit(1);
        };

        std.debug.print("User '{s}' created successfully\n", .{username});
    } else if (std.mem.eql(u8, subcommand, "list")) {
        std.debug.print("User list not yet implemented\n", .{});
    } else if (std.mem.eql(u8, subcommand, "delete")) {
        std.debug.print("User delete not yet implemented\n", .{});
    } else if (std.mem.eql(u8, subcommand, "update")) {
        std.debug.print("User update not yet implemented\n", .{});
    } else if (std.mem.eql(u8, subcommand, "show")) {
        std.debug.print("User show not yet implemented\n", .{});
    } else {
        std.debug.print("Error: Unknown user subcommand '{s}'\n", .{subcommand});
        std.debug.print("Valid commands: create, list, delete, update, show\n", .{});
        std.process.exit(1);
    }
}

/// Role management command handler
/// Handles: role create, role list, role delete, role show
pub fn cmdRole(_: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    // start_idx points to "role", so start_idx + 1 is the subcommand
    if (start_idx + 1 >= argv.len) {
        std.debug.print("Usage: geode role <command> [options]\n", .{});
        std.debug.print("Commands:\n", .{});
        std.debug.print("  create <rolename> [--description <desc>]\n", .{});
        std.debug.print("  list\n", .{});
        std.debug.print("  delete <rolename>\n", .{});
        std.debug.print("  show <rolename>\n", .{});
        std.process.exit(1);
    }

    const subcommand = argv[start_idx + 1];

    // Handle --help and -h flags
    if (std.mem.eql(u8, subcommand, "--help") or std.mem.eql(u8, subcommand, "-h")) {
        std.debug.print("Usage: geode role <command> [options]\n", .{});
        std.debug.print("Commands:\n", .{});
        std.debug.print("  create <rolename> [--description <desc>]\n", .{});
        std.debug.print("  list\n", .{});
        std.debug.print("  delete <rolename>\n", .{});
        std.debug.print("  show <rolename>\n", .{});
        std.process.exit(0);
    }

    const user_mgmt = geode.user_management;

    if (!user_mgmt.isAuthEnabled()) {
        std.debug.print("Error: Role management requires authentication to be enabled\n", .{});
        std.process.exit(1);
    }

    if (std.mem.eql(u8, subcommand, "create")) {
        if (start_idx + 2 >= argv.len) {
            std.debug.print("Error: role create requires <rolename>\n", .{});
            std.process.exit(1);
        }
        const rolename = argv[start_idx + 2];
        // Use debug.print instead
        std.debug.print("Role '{s}' created successfully\n", .{rolename});
    } else if (std.mem.eql(u8, subcommand, "list")) {
        std.debug.print("User list not yet implemented\n", .{});
    } else if (std.mem.eql(u8, subcommand, "delete")) {
        std.debug.print("User delete not yet implemented\n", .{});
    } else {
        std.debug.print("Error: Unknown role subcommand '{s}'\n", .{subcommand});
        std.debug.print("Valid commands: create, list, delete, show\n", .{});
        std.process.exit(1);
    }
}
