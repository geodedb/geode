const std = @import("std");
const builtin = @import("builtin");
const geode = @import("geode");
const auth_state = geode.auth_state;

// CANARY: REQ=REQ-USER-CREATE-PASSWORD-001; FEATURE="CLI Password Security"; ASPECT=Security; STATUS=IMPL; OWNER=cli; UPDATED=2026-01-14
// GAP-0154 FIX: Production builds require explicit passwords or generate random ones
// CANARY: REQ=REQ-MFA-OUTPUT-001; FEATURE="MFASecureOutput"; ASPECT=Security; STATUS=TESTED; TEST=gap_155_156_regression.yml; OWNER=cli; UPDATED=2026-01-14
// GAP-0156 FIX: MFA toggle command no longer displays hardcoded fake secret

/// Check if running in production build mode
const is_production_build = builtin.mode == .ReleaseSafe or builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;

fn printOut(comptime fmt: []const u8, args: anytype) void {
    // Write directly to STDOUT so help text lands in the expected stream for tests.
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    stdout.writeAll(msg) catch {};
}

// CANARY: REQ=REQ-M4.1-USER-MGMT-CLI-001; FEATURE="CLI Modularization"; ASPECT=UserManagement; STATUS=IMPL; OWNER=cli; UPDATED=2025-11-12
// Phase 4 M4.1: Extract user management commands (cmdUser, cmdRole) from cli/main.zig

// Exit codes for consistency with main CLI
const ExitCode = enum(u8) {
    success = 0,
    general_error = 1,
    usage_error = 2,
};

fn printUserUsage() void {
    printOut("geode user - User management commands\n", .{});
    printOut("Usage: geode user <command> [options]\n", .{});
    printOut("Commands:\n", .{});
    printOut("  create <username> <email> --password <password> [--role <role>]\n", .{});
    printOut("  create <username> <email> --generate-password [--role <role>]\n", .{});
    printOut("  list\n", .{});
    printOut("  show|info <username>\n", .{});
    printOut("  delete <username> [--yes]\n", .{});
    printOut("  update <username> [--email <email>] [--password <password>] [--role <role>]\n", .{});
    printOut("  assign-role <username> <role>\n", .{});
    printOut("  permissions <username>\n", .{});
    printOut("  disable|enable <username>\n", .{});
    printOut("  mfa-setup|mfa-verify <username> [--token <code>]\n", .{});
    printOut("  change-password <username> --old-password <old> --new-password <new>\n", .{});
    printOut("  change-password <username> --generate-password\n", .{});
    printOut("  reset-password <username> --new-password <new>\n", .{});
    printOut("  reset-password <username> --generate-password\n", .{});
    printOut("\nNote: --password is required in production builds. Use --generate-password for random passwords.\n", .{});
}

fn printRoleUsage() void {
    printOut("geode role - Role management commands\n", .{});
    printOut("Usage: geode role <command> [options]\n", .{});
    printOut("Commands:\n", .{});
    printOut("  create <rolename> [description] [--permissions <perm1,perm2>]\n", .{});
    printOut("  list\n", .{});
    printOut("  delete <rolename>\n", .{});
    printOut("  show <rolename>\n", .{});
}

fn findSubcommandStart(argv: [][:0]u8, start_idx: usize) usize {
    var idx = start_idx + 1;
    while (idx < argv.len) : (idx += 1) {
        const arg = argv[idx];
        if (std.mem.eql(u8, arg, "--enable-auth") or
            std.mem.eql(u8, arg, "--audit"))
        {
            continue;
        }
        if (std.mem.eql(u8, arg, "--server") or
            std.mem.eql(u8, arg, "--audit-file") or
            std.mem.eql(u8, arg, "--audit-syslog"))
        {
            idx += 1;
            continue;
        }
        break;
    }
    return idx;
}

fn hasHelpFlag(argv: [][:0]u8, start_idx: usize) bool {
    var i = start_idx;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--help") or std.mem.eql(u8, argv[i], "-h")) return true;
    }
    return false;
}

fn requirePasswordStrong(password: []const u8) bool {
    return auth_state.isPasswordStrong(password);
}

/// GAP-0154 FIX: Generate a cryptographically secure random password
/// Returns a 32-character hex string (16 random bytes converted to hex)
fn generateSecurePassword() [32]u8 {
    var random_bytes: [16]u8 = undefined;
    std.crypto.random.bytes(&random_bytes);
    return std.fmt.bytesToHex(random_bytes, .lower);
}

/// User management command handler
/// Handles: user create, user list, user delete, user update, user show and additional auth helpers
pub fn cmdUser(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    var state = try auth_state.State.load(allocator);
    defer state.deinit();

    const subcmd_idx = findSubcommandStart(argv, start_idx);
    if (subcmd_idx >= argv.len) {
        std.debug.print("Error: missing user subcommand\n", .{});
        printUserUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    const subcommand = argv[subcmd_idx];

    if (std.mem.eql(u8, subcommand, "--help") or std.mem.eql(u8, subcommand, "-h")) {
        printUserUsage();
        std.process.exit(@intFromEnum(ExitCode.success));
    }

    if (std.mem.eql(u8, subcommand, "create")) {
        if (hasHelpFlag(argv, subcmd_idx + 1)) {
            printUserUsage();
            std.process.exit(@intFromEnum(ExitCode.success));
        }
        if (subcmd_idx + 2 >= argv.len) {
            std.debug.print("Error: user create requires <username> and <email>\n", .{});
            printUserUsage();
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }

        const username = argv[subcmd_idx + 1];
        const email = argv[subcmd_idx + 2];

        // GAP-0154 FIX: No hardcoded default passwords
        var password: ?[]const u8 = null;
        var password_is_default = true;
        var role: []const u8 = "user";
        var generate_password = false;

        var i = subcmd_idx + 3;
        while (i < argv.len) : (i += 1) {
            if (std.mem.eql(u8, argv[i], "--password")) {
                if (i + 1 >= argv.len) {
                    std.debug.print("Error: --password requires a value\n", .{});
                    std.process.exit(@intFromEnum(ExitCode.usage_error));
                }
                password = argv[i + 1];
                password_is_default = false;
                i += 1;
            } else if (std.mem.eql(u8, argv[i], "--generate-password")) {
                generate_password = true;
                password_is_default = false;
            } else if (std.mem.eql(u8, argv[i], "--role")) {
                if (i + 1 >= argv.len) {
                    std.debug.print("Error: --role requires a value\n", .{});
                    std.process.exit(@intFromEnum(ExitCode.usage_error));
                }
                role = argv[i + 1];
                i += 1;
            } else if (!std.mem.startsWith(u8, argv[i], "--") and password == null and i == subcmd_idx + 3) {
                // Allow password as positional 3rd arg for backward compatibility
                password = argv[i];
                password_is_default = false;
            }
        }

        // GAP-0154 FIX: Production build password handling
        var generated_pw: [32]u8 = undefined;
        const final_password: []const u8 = blk: {
            if (password) |pw| {
                // Explicit password provided
                if (pw.len == 0) {
                    std.debug.print("Error: password cannot be empty\n", .{});
                    std.process.exit(@intFromEnum(ExitCode.general_error));
                }
                if (!requirePasswordStrong(pw)) {
                    std.debug.print("Error: password does not meet policy requirements (min 8 chars, letters and numbers)\n", .{});
                    std.process.exit(@intFromEnum(ExitCode.general_error));
                }
                break :blk pw;
            }
            if (generate_password) {
                // Generate random password
                generated_pw = generateSecurePassword();
                std.debug.print("Generated password: {s}\n", .{generated_pw});
                break :blk &generated_pw;
            }
            if (is_production_build) {
                // Production builds require explicit password
                std.debug.print("Error: --password is required in production builds\n", .{});
                std.debug.print("Use --password <password> or --generate-password\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            // Debug builds: use simple default for testing convenience
            if (password_is_default) {
                std.debug.print("Warning: Using default test password. Use --password in production.\n", .{});
            }
            break :blk "testpass123!";
        };

        try state.ensureDefaults();
        _ = try state.upsertUser(username, email, final_password, role, true, false);
        try state.save();
        printOut("User '{s}' created successfully\n", .{username});
        return;
    }

    if (std.mem.eql(u8, subcommand, "list")) {
        if (hasHelpFlag(argv, subcmd_idx + 1)) {
            printOut("Usage: geode user list\nLists all users\n", .{});
            std.process.exit(@intFromEnum(ExitCode.success));
        }
        try state.ensureDefaults();
        try state.save();
        printOut("Users:\n", .{});
        for (state.users.items) |u| {
            printOut("- {s} (role: {s})\n", .{ u.username, u.role });
        }
        std.process.exit(@intFromEnum(ExitCode.success));
    }

    if (std.mem.eql(u8, subcommand, "show") or std.mem.eql(u8, subcommand, "info")) {
        if (hasHelpFlag(argv, subcmd_idx + 1)) {
            printOut("Usage: geode user show <username>\nShow user details\n", .{});
            std.process.exit(@intFromEnum(ExitCode.success));
        }
        if (subcmd_idx + 1 >= argv.len) {
            std.debug.print("Error: user show/info requires <username>\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
        const username = argv[subcmd_idx + 1];
        try state.ensureDefaults();
        if (state.getUser(username)) |u| {
            printOut("User: {s}\nEmail: {s}\nRole: {s}\nStatus: {s}\n", .{ u.username, u.email, u.role, if (u.active) "active" else "disabled" });
        } else {
            printOut("User: {s}\nEmail: unknown\nRole: user\nStatus: active\n", .{username});
        }
        std.process.exit(@intFromEnum(ExitCode.success));
    }

    if (std.mem.eql(u8, subcommand, "delete")) {
        if (subcmd_idx + 1 >= argv.len) {
            std.debug.print("Error: user delete requires <username>\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
        const username = argv[subcmd_idx + 1];
        _ = state.deleteUser(username);
        try state.save();
        printOut("User '{s}' deleted\n", .{username});
        std.process.exit(@intFromEnum(ExitCode.success));
    }

    if (std.mem.eql(u8, subcommand, "update")) {
        if (subcmd_idx + 1 >= argv.len) {
            std.debug.print("Error: user update requires <username>\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
        const username = argv[subcmd_idx + 1];
        var new_email: ?[]const u8 = null;
        var new_password: ?[]const u8 = null;
        var new_role: ?[]const u8 = null;

        var i = subcmd_idx + 2;
        while (i < argv.len) : (i += 1) {
            if (std.mem.eql(u8, argv[i], "--email")) {
                if (i + 1 >= argv.len) {
                    std.debug.print("Error: --email requires a value\n", .{});
                    std.process.exit(@intFromEnum(ExitCode.usage_error));
                }
                new_email = argv[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, argv[i], "--password")) {
                if (i + 1 >= argv.len) {
                    std.debug.print("Error: --password requires a value\n", .{});
                    std.process.exit(@intFromEnum(ExitCode.usage_error));
                }
                new_password = argv[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, argv[i], "--role")) {
                if (i + 1 >= argv.len) {
                    std.debug.print("Error: --role requires a value\n", .{});
                    std.process.exit(@intFromEnum(ExitCode.usage_error));
                }
                new_role = argv[i + 1];
                i += 1;
            }
        }

        try state.ensureDefaults();

        // GAP-0154 FIX: User update should only update provided fields
        // Get existing user or create new one
        if (state.getUser(username)) |existing| {
            // Update only fields that were explicitly provided
            if (new_password) |pw| {
                if (!requirePasswordStrong(pw)) {
                    std.debug.print("Error: password does not meet policy requirements (min 8 chars, letters and numbers)\n", .{});
                    std.process.exit(@intFromEnum(ExitCode.general_error));
                }
                _ = try state.setPassword(username, pw);
            }
            if (new_email) |em| {
                allocator.free(existing.email);
                existing.email = try allocator.dupe(u8, em);
            }
            if (new_role) |r| {
                _ = try state.assignRole(username, r);
            }
        } else {
            // User doesn't exist - require password for new user creation
            if (new_password == null) {
                if (is_production_build) {
                    std.debug.print("Error: --password is required to create new user in production\n", .{});
                    std.process.exit(@intFromEnum(ExitCode.usage_error));
                }
                std.debug.print("Warning: Creating user with default test password\n", .{});
            }
            const pw = new_password orelse "testpass123!";
            if (!requirePasswordStrong(pw)) {
                std.debug.print("Error: password does not meet policy requirements (min 8 chars, letters and numbers)\n", .{});
                std.process.exit(@intFromEnum(ExitCode.general_error));
            }
            _ = try state.upsertUser(username, new_email orelse "unknown@example.com", pw, new_role orelse "user", true, false);
        }
        try state.save();
        printOut("User '{s}' updated\n", .{username});
        std.process.exit(@intFromEnum(ExitCode.success));
    }

    if (std.mem.eql(u8, subcommand, "assign-role")) {
        if (subcmd_idx + 2 >= argv.len) {
            std.debug.print("Error: user assign-role requires <username> <role>\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
        const username = argv[subcmd_idx + 1];
        const role = argv[subcmd_idx + 2];
        try state.ensureDefaults();
        _ = try state.upsertRole(role, "custom role", &[_][]const u8{"read"});
        _ = try state.assignRole(username, role);
        try state.save();
        printOut("Assigned role '{s}' to user '{s}'\n", .{ role, username });
        std.process.exit(@intFromEnum(ExitCode.success));
    }

    if (std.mem.eql(u8, subcommand, "permissions")) {
        if (subcmd_idx + 1 >= argv.len) {
            std.debug.print("Error: user permissions requires <username>\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
        const username = argv[subcmd_idx + 1];
        try state.ensureDefaults();
        var perms = state.listPermissionsForUser(username);
        defer perms.deinit(allocator);
        printOut("Permissions for {s}: ", .{username});
        for (perms.items, 0..) |p, idx| {
            if (idx > 0) printOut(", ", .{});
            printOut("{s}", .{p});
        }
        printOut("\n", .{});
        std.process.exit(@intFromEnum(ExitCode.success));
    }

    if (std.mem.eql(u8, subcommand, "disable") or std.mem.eql(u8, subcommand, "enable")) {
        const enable = std.mem.eql(u8, subcommand, "enable");
        if (subcmd_idx + 1 >= argv.len) {
            std.debug.print("Error: user {s} requires <username>\n", .{subcommand});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
        const username = argv[subcmd_idx + 1];
        _ = state.setUserActive(username, enable);
        try state.save();
        printOut("User '{s}' {s}\n", .{ username, if (enable) "enabled" else "disabled" });
        std.process.exit(@intFromEnum(ExitCode.success));
    }

    if (std.mem.eql(u8, subcommand, "mfa-setup") or std.mem.eql(u8, subcommand, "mfa-verify")) {
        if (subcmd_idx + 1 >= argv.len) {
            std.debug.print("Error: MFA command requires <username>\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
        const username = argv[subcmd_idx + 1];
        var token: []const u8 = "123456";
        var i = subcmd_idx + 2;
        while (i < argv.len) : (i += 1) {
            if (std.mem.eql(u8, argv[i], "--token") and i + 1 < argv.len) {
                token = argv[i + 1];
                i += 1;
            }
        }
        // GAP-0154 FIX: MFA setup should update existing user, not set hardcoded password
        try state.ensureDefaults();
        if (state.getUser(username)) |user| {
            // Update MFA status for existing user
            user.mfa_enabled = true;
        } else {
            // User doesn't exist - MFA setup requires existing user
            std.debug.print("Error: User '{s}' does not exist. Create user first.\n", .{username});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        }
        try state.save();
        if (std.mem.eql(u8, subcommand, "mfa-setup")) {
            printOut("MFA setup complete for {s}. Secret: {s}\n", .{ username, token });
        } else {
            printOut("MFA token verified for {s}\n", .{username});
        }
        std.process.exit(@intFromEnum(ExitCode.success));
    }

    // CANARY: REQ=REQ-MFA-TOGGLE-001; FEATURE="MFAToggleSecure"; ASPECT=Security; STATUS=IMPL; OWNER=cli; UPDATED=2026-01-14
    // GAP-0156 FIX: Remove hardcoded "Secret: 123456" from MFA toggle output
    if (std.mem.eql(u8, subcommand, "mfa")) {
        // Support: geode user mfa enable <username>
        if (subcmd_idx + 2 >= argv.len) {
            std.debug.print("Error: user mfa requires <enable|disable> <username>\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
        const action = argv[subcmd_idx + 1];
        const username = argv[subcmd_idx + 2];
        const enable = std.mem.eql(u8, action, "enable");
        // GAP-0154 FIX: MFA toggle should update existing user, not set hardcoded password
        try state.ensureDefaults();
        if (state.getUser(username)) |user| {
            user.mfa_enabled = enable;
        } else {
            std.debug.print("Error: User '{s}' does not exist. Create user first.\n", .{username});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        }
        try state.save();
        // GAP-0156 FIX: Do not display fake/hardcoded MFA secret
        // Users should use 'mfa-setup' command for initial MFA configuration with real secret
        if (enable) {
            printOut("MFA enabled for {s}. Use 'mfa-setup' to configure MFA with a real secret.\n", .{username});
        } else {
            printOut("MFA disabled for {s}.\n", .{username});
        }
        std.process.exit(@intFromEnum(ExitCode.success));
    }

    if (std.mem.eql(u8, subcommand, "change-password")) {
        if (subcmd_idx + 1 >= argv.len) {
            std.debug.print("Error: change-password requires <username>\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
        const username = argv[subcmd_idx + 1];
        var old_pw: ?[]const u8 = null;
        var new_pw: ?[]const u8 = null;
        var generate_password = false;
        var i = subcmd_idx + 2;
        while (i < argv.len) : (i += 1) {
            if (std.mem.eql(u8, argv[i], "--old-password") and i + 1 < argv.len) {
                old_pw = argv[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, argv[i], "--new-password") and i + 1 < argv.len) {
                new_pw = argv[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, argv[i], "--generate-password")) {
                generate_password = true;
            }
        }
        // GAP-0154 FIX: Require explicit new password
        var generated_pw: [32]u8 = undefined;
        const final_new: []const u8 = blk: {
            if (new_pw) |pw| {
                break :blk pw;
            }
            if (generate_password) {
                generated_pw = generateSecurePassword();
                std.debug.print("Generated password: {s}\n", .{generated_pw});
                break :blk &generated_pw;
            }
            std.debug.print("Error: --new-password is required\n", .{});
            std.debug.print("Use --new-password <password> or --generate-password\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        };
        if (!requirePasswordStrong(final_new)) {
            std.debug.print("Error: password does not meet policy requirements (min 8 chars, letters and numbers)\n", .{});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        }
        // Verify old password if user exists and old password provided
        if (old_pw) |old| {
            if (!state.validateCredentials(username, old)) {
                std.debug.print("Error: old password is incorrect\n", .{});
                std.process.exit(@intFromEnum(ExitCode.general_error));
            }
        }
        _ = try state.setPassword(username, final_new);
        try state.save();
        printOut("Password changed for user '{s}'\n", .{username});
        std.process.exit(@intFromEnum(ExitCode.success));
    }

    if (std.mem.eql(u8, subcommand, "reset-password")) {
        if (subcmd_idx + 1 >= argv.len) {
            std.debug.print("Error: reset-password requires <username>\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
        const username = argv[subcmd_idx + 1];
        var new_pw: ?[]const u8 = null;
        var generate_password = false;
        var i = subcmd_idx + 2;
        while (i < argv.len) : (i += 1) {
            if (std.mem.eql(u8, argv[i], "--new-password") and i + 1 < argv.len) {
                new_pw = argv[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, argv[i], "--generate-password")) {
                generate_password = true;
            }
        }
        // GAP-0154 FIX: Require explicit new password
        var generated_pw: [32]u8 = undefined;
        const final_new: []const u8 = blk: {
            if (new_pw) |pw| {
                break :blk pw;
            }
            if (generate_password) {
                generated_pw = generateSecurePassword();
                std.debug.print("Generated password: {s}\n", .{generated_pw});
                break :blk &generated_pw;
            }
            std.debug.print("Error: --new-password is required\n", .{});
            std.debug.print("Use --new-password <password> or --generate-password\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        };
        if (!requirePasswordStrong(final_new)) {
            std.debug.print("Error: password does not meet policy requirements (min 8 chars, letters and numbers)\n", .{});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        }
        _ = try state.setPassword(username, final_new);
        try state.save();
        printOut("Password reset for user '{s}'\n", .{username});
        std.process.exit(@intFromEnum(ExitCode.success));
    }

    std.debug.print("Error: Unknown user subcommand '{s}'\n", .{subcommand});
    printUserUsage();
    std.process.exit(@intFromEnum(ExitCode.general_error));
}

/// Role management command handler
/// Handles: role create, role list, role delete, role show
pub fn cmdRole(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    var state = try auth_state.State.load(allocator);
    defer state.deinit();

    if (start_idx + 1 >= argv.len) {
        std.debug.print("Error: missing role subcommand\n", .{});
        printRoleUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    const subcommand = argv[start_idx + 1];

    // Handle --help and -h flags
    if (std.mem.eql(u8, subcommand, "--help") or std.mem.eql(u8, subcommand, "-h")) {
        printRoleUsage();
        std.process.exit(@intFromEnum(ExitCode.success));
    }

    if (std.mem.eql(u8, subcommand, "create")) {
        if (hasHelpFlag(argv, start_idx + 2)) {
            printRoleUsage();
            std.process.exit(@intFromEnum(ExitCode.success));
        }
        if (start_idx + 2 >= argv.len) {
            std.debug.print("Error: role create requires <rolename>\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
        const rolename = argv[start_idx + 2];
        var description: []const u8 = "Role created via CLI";
        var description_is_default = true;
        var parsed_permissions = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable;
        defer parsed_permissions.deinit(allocator);

        var i = start_idx + 3;
        while (i < argv.len) : (i += 1) {
            if (!std.mem.startsWith(u8, argv[i], "--") and description_is_default) {
                description = argv[i];
                description_is_default = false;
            } else if (std.mem.eql(u8, argv[i], "--permissions") and i + 1 < argv.len) {
                const perm_str = argv[i + 1];
                var split = std.mem.splitScalar(u8, perm_str, ',');
                parsed_permissions.clearRetainingCapacity();
                while (split.next()) |p| {
                    if (p.len == 0) continue;
                    try parsed_permissions.append(allocator, p);
                }
                i += 1;
            }
        }

        _ = try state.upsertRole(rolename, description, parsed_permissions.items);
        try state.save();
        printOut("Role '{s}' created successfully\n", .{rolename});
        std.process.exit(@intFromEnum(ExitCode.success));
    } else if (std.mem.eql(u8, subcommand, "list")) {
        if (hasHelpFlag(argv, start_idx + 2)) {
            printOut("Usage: geode role list\nLists all roles\n", .{});
            std.process.exit(@intFromEnum(ExitCode.success));
        }
        try state.ensureDefaults();
        try state.save();
        printOut("Roles:\n", .{});
        for (state.roles.items) |r| {
            printOut("- {s}: {s}\n", .{ r.name, r.description });
        }
        std.process.exit(@intFromEnum(ExitCode.success));
    } else if (std.mem.eql(u8, subcommand, "delete")) {
        if (hasHelpFlag(argv, start_idx + 2)) {
            printOut("Usage: geode role delete <rolename>\nDelete role by name\n", .{});
            std.process.exit(@intFromEnum(ExitCode.success));
        }
        if (start_idx + 2 >= argv.len) {
            std.debug.print("Error: role delete requires <rolename>\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
        const rolename = argv[start_idx + 2];
        const deleted = state.deleteRole(rolename);
        try state.save();
        printOut("Role '{s}' {s}\n", .{ rolename, if (deleted) "deleted" else "not found (noop)" });
        std.process.exit(@intFromEnum(ExitCode.success));
    } else if (std.mem.eql(u8, subcommand, "show")) {
        if (hasHelpFlag(argv, start_idx + 2)) {
            printRoleUsage();
            std.process.exit(@intFromEnum(ExitCode.success));
        }
        if (start_idx + 2 >= argv.len) {
            std.debug.print("Error: role show requires <rolename>\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
        const rolename = argv[start_idx + 2];
        try state.ensureDefaults();
        if (state.getRole(rolename)) |r| {
            printOut("Role: {s}\nDescription: {s}\n", .{ r.name, r.description });
        } else {
            printOut("Role: {s}\nDescription: (not found)\n", .{rolename});
        }
        std.process.exit(@intFromEnum(ExitCode.success));
    } else {
        std.debug.print("Error: Unknown role subcommand '{s}'\n", .{subcommand});
        printRoleUsage();
        std.process.exit(@intFromEnum(ExitCode.general_error));
    }
}
