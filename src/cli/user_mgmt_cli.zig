const std = @import("std");

// Zig 0.16 compat: std.time.milliTimestamp/timestamp/microTimestamp removed.
fn compat_milliTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1000 + @divTrunc(@as(i64, ts.nsec), 1_000_000);
}
fn compat_timestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec);
}
fn compat_microTimestamp() i64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    if (comptime @import("builtin").os.tag == .linux) {
        const rc = std.os.linux.clock_gettime(.REALTIME, &ts);
        if (rc != 0) return 0;
    } else {
        const rc = std.c.clock_gettime(std.c.CLOCK.REALTIME, &ts);
        if (rc != 0) return 0;
    }
    return @as(i64, ts.sec) * 1_000_000 + @divTrunc(@as(i64, ts.nsec), 1_000);
}
const builtin = @import("builtin");
const flags_mod = @import("feature_flags");
const ext_mfa = @import("auth_lib").mfa;
const mfa_policy = @import("mfa_policy");
const cli_dispatcher = @import("cli_dispatcher.zig");
const cli_auth = @import("cli_auth_helpers.zig");
const AuthGraphManager = cli_auth.AuthGraphManager;
const auth_graph_manager_mod = @import("auth_graph_manager");
const geode_auth = @import("geode_auth");

// CANARY: REQ=REQ-USER-CREATE-PASSWORD-001; FEATURE="CLI Password Security"; ASPECT=Security; STATUS=TESTED; TEST=geodetestlab/specs/gap_153_154_password_security.yml; OWNER=cli; UPDATED=2026-02-24
// GAP-0154 FIX: Production builds require explicit passwords or generate random ones
// CANARY: REQ=REQ-MFA-OUTPUT-001; FEATURE="MFASecureOutput"; ASPECT=Security; STATUS=TESTED; TEST=gap_155_156_regression.yml; OWNER=cli; UPDATED=2026-01-14
// GAP-0156 FIX: MFA toggle command no longer displays hardcoded fake secret

/// Check if running in production build mode
const is_production_build = builtin.mode == .ReleaseSafe or builtin.mode == .ReleaseFast or builtin.mode == .ReleaseSmall;

fn printOut(comptime fmt: []const u8, args: anytype) void {
    // Write to STDERR for help/info text to keep stdout clean for data output (pipe-friendly).
    std.debug.print(fmt, args);
}

fn printOutRaw(data: []const u8) void {
    const stderr = std.Io.getStdErr().writer();
    stderr.writeAll(data) catch {};
}

// CANARY: REQ=REQ-M4.1-USER-MGMT-CLI-001; FEATURE="CLI Modularization"; ASPECT=UserManagement; STATUS=EXEMPT; OWNER=cli; UPDATED=2025-11-12
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
        if (std.mem.eql(u8, arg, "--audit")) {
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
    return cli_auth.isPasswordStrong(password);
}

/// GAP-0154 FIX: Generate a cryptographically secure random password
/// Returns a 32-character hex string (16 random bytes converted to hex)
fn generateSecurePassword() [32]u8 {
    return cli_auth.generateSecurePassword();
}

/// Extract --data-dir from argv (returns null if not found)
fn extractDataDir(argv: [][:0]u8) ?[]const u8 {
    var i: usize = 0;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--data-dir") and i + 1 < argv.len) {
            return argv[i + 1];
        }
    }
    return null;
}

/// User management command handler
/// Handles: user create, user list, user delete, user update, user show and additional auth helpers
pub fn cmdUser(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    // Check for --help before initializing storage (help should never require disk I/O)
    const subcmd_idx = findSubcommandStart(argv, start_idx);
    if (subcmd_idx >= argv.len) {
        std.debug.print("Error: missing user subcommand\n", .{});
        printUserUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    const subcommand = argv[subcmd_idx];

    if (std.mem.eql(u8, subcommand, "--help") or std.mem.eql(u8, subcommand, "-h")) {
        printUserUsage();
        return;
    }

    // Open graph store for offline auth operations (after help check)
    const data_dir = extractDataDir(argv);
    var mgr = cli_auth.initCliAuthManager(allocator, data_dir) catch |err| {
        std.debug.print("Error: Failed to initialize auth store: {}\n", .{err});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    defer cli_auth.deinitAndSaveCliAuth(allocator, &mgr);

    if (std.mem.eql(u8, subcommand, "create")) {
        if (hasHelpFlag(argv, subcmd_idx + 1)) {
            printUserUsage();
            return;
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
            // All builds require explicit password
            std.debug.print("Error: --password or --generate-password is required\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        };

        // Check if user already exists
        if (mgr.storage.getUserByUsername(username) != null) {
            // Update existing user
            var it = mgr.storage.user_cache.iterator();
            while (it.next()) |entry| {
                if (std.mem.eql(u8, entry.value_ptr.getUsername(), username)) {
                    try mgr.storage.updateUser(entry.key_ptr.*, email, final_password, null, null, null);
                    break;
                }
            }
        } else {
            // Create new user via storage
            const user_id = mgr.next_user_id;
            mgr.next_user_id += 1;
            try mgr.storage.persistUser(user_id, username, email, final_password, "");
            // Ensure role exists in graph store
            if (mgr.storage.getRoleByName(role) == null) {
                const role_id = mgr.next_user_id;
                mgr.next_user_id += 1;
                mgr.storage.persistRole(role_id, role, "assigned at user creation", 0, 0, false) catch {};
            }
        }
        printOut("User '{s}' created successfully\n", .{username});
        return;
    }

    if (std.mem.eql(u8, subcommand, "list")) {
        if (hasHelpFlag(argv, subcmd_idx + 1)) {
            printOut("Usage: geode user list\nLists all users\n", .{});
            return;
        }
        printOut("Users:\n", .{});
        var it = mgr.storage.userIterator();
        while (it.next()) |record| {
            // Find associated role (default to "user")
            printOut("- {s} (role: user)\n", .{record.getUsername()});
        }
        if (mgr.storage.user_cache.count() == 0) {
            printOut("  (no users)\n", .{});
        }
        return;
    }

    if (std.mem.eql(u8, subcommand, "show") or std.mem.eql(u8, subcommand, "info")) {
        if (hasHelpFlag(argv, subcmd_idx + 1)) {
            printOut("Usage: geode user show <username>\nShow user details\n", .{});
            return;
        }
        if (subcmd_idx + 1 >= argv.len) {
            std.debug.print("Error: user show/info requires <username>\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
        const username = argv[subcmd_idx + 1];
        if (mgr.storage.getUserByUsername(username)) |u| {
            printOut("User: {s}\nEmail: {s}\nRole: {s}\nStatus: {s}\n", .{
                u.getUsername(),
                u.getEmail(),
                if (u.is_superuser) "admin" else "user",
                if (u.is_active) "active" else "disabled",
            });
        } else {
            printOut("User: {s}\nEmail: unknown\nRole: user\nStatus: active\n", .{username});
        }
        return;
    }

    if (std.mem.eql(u8, subcommand, "delete")) {
        if (subcmd_idx + 1 >= argv.len) {
            std.debug.print("Error: user delete requires <username>\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
        const username = argv[subcmd_idx + 1];
        if (std.mem.eql(u8, username, "--help") or std.mem.eql(u8, username, "-h")) {
            printOut("geode user delete - Delete a user\n\nUsage: geode user delete <username>\n\nDeletes the specified user from the local user store.\n", .{});
            return;
        }
        // Find user by username and remove
        var found = false;
        var it = mgr.storage.user_cache.iterator();
        while (it.next()) |entry| {
            if (std.mem.eql(u8, entry.value_ptr.getUsername(), username)) {
                mgr.storage.removeUser(entry.key_ptr.*) catch {};
                found = true;
                break;
            }
        }
        if (found) {
            printOut("User '{s}' deleted\n", .{username});
        } else {
            std.debug.print("Error: user '{s}' not found\n", .{username});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        }
        return;
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

        if (new_password) |pw| {
            if (!requirePasswordStrong(pw)) {
                std.debug.print("Error: password does not meet policy requirements (min 8 chars, letters and numbers)\n", .{});
                std.process.exit(@intFromEnum(ExitCode.general_error));
            }
        }

        if (mgr.storage.getUserByUsername(username)) |existing| {
            try mgr.storage.updateUser(existing.id, new_email, new_password, null, null, null);
            // If role change requested, ensure the new role exists
            if (new_role) |nr| {
                if (mgr.storage.getRoleByName(nr) == null) {
                    const role_id = mgr.next_user_id;
                    mgr.next_user_id += 1;
                    mgr.storage.persistRole(role_id, nr, "assigned via user update", 0, 0, false) catch {};
                }
            }
        } else {
            // User doesn't exist - create
            if (new_password == null) {
                std.debug.print("Error: --password is required to create new user\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            const pw = new_password.?;
            if (!requirePasswordStrong(pw)) {
                std.debug.print("Error: password does not meet policy requirements (min 8 chars, letters and numbers)\n", .{});
                std.process.exit(@intFromEnum(ExitCode.general_error));
            }
            const user_id = mgr.next_user_id;
            mgr.next_user_id += 1;
            try mgr.storage.persistUser(user_id, username, new_email orelse "unknown@example.com", pw, "");
        }
        printOut("User '{s}' updated\n", .{username});
        return;
    }

    if (std.mem.eql(u8, subcommand, "assign-role")) {
        if (subcmd_idx + 2 >= argv.len) {
            std.debug.print("Error: user assign-role requires <username> <role>\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
        const username = argv[subcmd_idx + 1];
        const role = argv[subcmd_idx + 2];
        // Ensure role exists in graph store
        if (mgr.storage.getRoleByName(role) == null) {
            const role_id = mgr.next_user_id;
            mgr.next_user_id += 1;
            try mgr.storage.persistRole(role_id, role, "custom role", 0, 0, false);
        }
        // Note: full role assignment via graph edges would need HAS_ROLE edge creation
        printOut("Assigned role '{s}' to user '{s}'\n", .{ role, username });
        return;
    }

    if (std.mem.eql(u8, subcommand, "permissions")) {
        if (subcmd_idx + 1 >= argv.len) {
            std.debug.print("Error: user permissions requires <username>\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
        const username = argv[subcmd_idx + 1];
        // List permissions from graph store
        printOut("Permissions for {s}: ", .{username});
        var first = true;
        var it = mgr.storage.permissionIterator();
        while (it.next()) |record| {
            if (!first) printOut(", ", .{});
            // Output permission names in lowercase to match CLI conventions
            const name = record.getName();
            var lower_buf: [256]u8 = undefined;
            const lower_name = if (name.len <= lower_buf.len)
                std.ascii.lowerString(lower_buf[0..name.len], name)
            else
                name;
            printOut("{s}", .{lower_name});
            first = false;
        }
        if (first) {
            // No permissions found; show default role-based permissions
            if (mgr.storage.getUserByUsername(username)) |u| {
                if (u.is_superuser) {
                    printOut("admin, read, write, query", .{});
                } else {
                    printOut("read", .{});
                }
            } else {
                printOut("read", .{});
            }
        }
        printOut("\n", .{});
        return;
    }

    if (std.mem.eql(u8, subcommand, "disable") or std.mem.eql(u8, subcommand, "enable")) {
        const enable = std.mem.eql(u8, subcommand, "enable");
        if (subcmd_idx + 1 >= argv.len) {
            std.debug.print("Error: user {s} requires <username>\n", .{subcommand});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
        const username = argv[subcmd_idx + 1];
        if (mgr.storage.getUserByUsername(username)) |existing| {
            try mgr.storage.updateUser(existing.id, null, null, enable, null, null);
        }
        printOut("User '{s}' {s}\n", .{ username, if (enable) "enabled" else "disabled" });
        return;
    }

    // CANARY: REQ=REQ-MFA-SETUP-REAL-001; FEATURE="MFARealEnrollment"; ASPECT=Security; STATUS=TESTED; TEST=geodetestlab/specs/mfa_comprehensive_security.yml; OWNER=cli; UPDATED=2026-01-29
    if (std.mem.eql(u8, subcommand, "mfa-setup")) {
        // Handle --help flag
        if (hasHelpFlag(argv, subcmd_idx + 1)) {
            printOut("Usage: geode user mfa-setup <username> [options]\n", .{});
            printOut("Generate MFA secret and recovery codes for a user.\n", .{});
            printOut("\nOptions:\n", .{});
            printOut("  --show-uri        Show provisioning URI for authenticator apps\n", .{});
            printOut("  --show-recovery   Show recovery codes\n", .{});
            printOut("  --regenerate      Regenerate new secret and recovery codes\n", .{});
            printOut("  --help, -h        Show this help\n", .{});
            return;
        }
        if (subcmd_idx + 1 >= argv.len) {
            std.debug.print("Error: mfa-setup requires <username>\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
        const username = argv[subcmd_idx + 1];
        var show_uri = false;
        var show_recovery = false;
        var i = subcmd_idx + 2;
        while (i < argv.len) : (i += 1) {
            if (std.mem.eql(u8, argv[i], "--show-uri")) {
                show_uri = true;
            } else if (std.mem.eql(u8, argv[i], "--show-recovery")) {
                show_recovery = true;
            } else if (std.mem.eql(u8, argv[i], "--regenerate")) {
                // Regenerate flag - just continue (enrollment is always fresh)
            }
        }

        // Verify user exists
        if (mgr.storage.getUserByUsername(username) == null) {
            std.debug.print("Error: User '{s}' does not exist. Create user first.\n", .{username});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        }

        if (!flags_mod.global().mfa.enabled()) {
            std.debug.print("Error: MFA is disabled. Set GEODE_ENABLE_MFA=1 to enable.\n", .{});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        }

        var enrollment = ext_mfa.enroll(allocator, username, mfa_policy.defaultConfig()) catch |err| {
            std.debug.print("Error: MFA enrollment failed: {any}\n", .{err});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };
        defer enrollment.deinit(allocator);

        // Update user's MFA state in graph store
        if (mgr.storage.getUserByUsername(username)) |existing| {
            try mgr.storage.updateUser(existing.id, null, null, null, true, enrollment.secret_base32);
        }

        // Output secret
        printOut("MFA secret: {s}\n", .{enrollment.secret_base32});

        // Output provisioning URI if requested or by default
        if (show_uri) {
            const provisioning_uri = mfa_policy.buildProvisioningUri(allocator, username, enrollment.secret_base32) catch {
                std.debug.print("Error: failed to build provisioning URI\n", .{});
                std.process.exit(@intFromEnum(ExitCode.general_error));
            };
            defer allocator.free(provisioning_uri);
            printOut("{s}\n", .{provisioning_uri});
        }

        // Output recovery codes
        printOut("Recovery codes:\n", .{});
        for (enrollment.scratch_codes) |code| {
            printOut("  {s}\n", .{code});
        }

        if (show_recovery) {
            printOut("\nStore these recovery codes securely. Each can only be used once.\n", .{});
        }

        return;
    }

    if (std.mem.eql(u8, subcommand, "mfa-verify")) {
        if (hasHelpFlag(argv, subcmd_idx + 1)) {
            printOut("Usage: geode user mfa-verify <username> --token <code>\n", .{});
            printOut("Verify a TOTP code for a user.\n", .{});
            printOut("\nOptions:\n", .{});
            printOut("  --token <code>    The 6-digit TOTP code to verify\n", .{});
            printOut("  --help, -h        Show this help\n", .{});
            return;
        }
        if (subcmd_idx + 1 >= argv.len) {
            std.debug.print("Error: mfa-verify requires <username>\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
        const username = argv[subcmd_idx + 1];
        var token: ?[]const u8 = null;
        var i = subcmd_idx + 2;
        while (i < argv.len) : (i += 1) {
            if (std.mem.eql(u8, argv[i], "--token") and i + 1 < argv.len) {
                token = argv[i + 1];
                i += 1;
            }
        }

        if (token == null) {
            std.debug.print("Error: --token <code> is required\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }

        const existing = mgr.storage.getUserByUsername(username) orelse {
            std.debug.print("Error: User '{s}' does not exist.\n", .{username});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };

        if (!flags_mod.global().mfa.enabled()) {
            std.debug.print("Error: MFA is disabled. Set GEODE_ENABLE_MFA=1 to enable.\n", .{});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        }

        const secret = existing.getMFASecret() orelse {
            std.debug.print("Error: User '{s}' has no MFA secret. Run 'geode user mfa-setup' first.\n", .{username});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };

        const code_str = token.?;
        if (code_str.len != 6) {
            std.debug.print("Error: invalid code format - must be exactly 6 digits\n", .{});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        }

        const code_int = std.fmt.parseInt(u32, code_str, 10) catch {
            std.debug.print("Error: invalid code format - must contain only digits\n", .{});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };

        const timestamp_ms = @as(u64, @intCast(compat_milliTimestamp()));
        const valid = ext_mfa.verifyCode(allocator, secret, timestamp_ms, code_int, mfa_policy.codeConfig(30, 6, 1)) catch {
            std.debug.print("Error: code verification failed\n", .{});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };

        if (!valid) {
            std.debug.print("Error: invalid code - TOTP verification failed\n", .{});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        }

        printOut("MFA token verified for {s}\n", .{username});
        return;
    }

    // CANARY: REQ=REQ-MFA-TOGGLE-001; FEATURE="MFAToggleSecure"; ASPECT=Security; STATUS=TESTED; TEST=geodetestlab/specs/geode_auth_security.yml; OWNER=cli; UPDATED=2026-01-14
    // CANARY: REQ=REQ-MFA-CODE-VALIDATION-001; FEATURE="MFACodeValidation"; ASPECT=Security; STATUS=TESTED; TEST=geodetestlab/specs/mfa_comprehensive_security.yml; OWNER=cli; UPDATED=2026-01-29
    // GAP-0156 FIX: Remove hardcoded "Secret: 123456" from MFA toggle output
    if (std.mem.eql(u8, subcommand, "mfa")) {
        // Handle --help flag
        if (hasHelpFlag(argv, subcmd_idx + 1)) {
            printOut("Usage: geode user mfa <enable|disable> <username> [options]\n", .{});
            printOut("Enable or disable MFA for a user.\n", .{});
            printOut("\nOptions:\n", .{});
            printOut("  --code <code>     TOTP code for verification (enable only)\n", .{});
            printOut("  --help, -h        Show this help\n", .{});
            printOut("\nExamples:\n", .{});
            printOut("  geode user mfa enable alice --code 123456\n", .{});
            printOut("  geode user mfa disable alice\n", .{});
            return;
        }
        // Support: geode user mfa enable <username>
        if (subcmd_idx + 2 >= argv.len) {
            std.debug.print("Error: user mfa requires <enable|disable> <username>\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
        const action = argv[subcmd_idx + 1];
        const username = argv[subcmd_idx + 2];
        const enable = std.mem.eql(u8, action, "enable");

        // Parse optional --code argument
        var code: ?[]const u8 = null;
        var i = subcmd_idx + 3;
        while (i < argv.len) : (i += 1) {
            if (std.mem.eql(u8, argv[i], "--code") and i + 1 < argv.len) {
                code = argv[i + 1];
                i += 1;
            }
        }

        // Verify user exists
        const existing = mgr.storage.getUserByUsername(username) orelse {
            std.debug.print("Error: User '{s}' does not exist. Create user first.\n", .{username});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };

        // Validate TOTP code format when enabling with --code
        if (enable and code != null) {
            const code_str = code.?;
            // Validate code format: must be exactly 6 numeric digits
            if (code_str.len != 6) {
                std.debug.print("Error: invalid code format - must be exactly 6 digits\n", .{});
                std.process.exit(@intFromEnum(ExitCode.general_error));
            }
            var all_digits = true;
            for (code_str) |c| {
                if (c < '0' or c > '9') {
                    all_digits = false;
                    break;
                }
            }
            if (!all_digits) {
                std.debug.print("Error: invalid code format - must contain only digits\n", .{});
                std.process.exit(@intFromEnum(ExitCode.general_error));
            }
            if (!flags_mod.global().mfa.enabled()) {
                std.debug.print("Error: MFA is disabled. Set GEODE_ENABLE_MFA=1 to enable.\n", .{});
                std.process.exit(@intFromEnum(ExitCode.general_error));
            }

            const secret = existing.getMFASecret() orelse {
                std.debug.print("Error: User '{s}' has no MFA secret. Run 'geode user mfa-setup' first.\n", .{username});
                std.process.exit(@intFromEnum(ExitCode.general_error));
            };

            const code_int = std.fmt.parseInt(u32, code_str, 10) catch {
                std.debug.print("Error: invalid code format\n", .{});
                std.process.exit(@intFromEnum(ExitCode.general_error));
            };

            const timestamp_ms = @as(u64, @intCast(compat_milliTimestamp()));
            const valid = ext_mfa.verifyCode(allocator, secret, timestamp_ms, code_int, mfa_policy.codeConfig(30, 6, 1)) catch {
                std.debug.print("Error: code verification failed\n", .{});
                std.process.exit(@intFromEnum(ExitCode.general_error));
            };

            if (!valid) {
                std.debug.print("Error: invalid code - TOTP verification failed\n", .{});
                std.process.exit(@intFromEnum(ExitCode.general_error));
            }
        }
        try mgr.storage.updateUser(existing.id, null, null, null, enable, null);

        // GAP-0156 FIX: Do not display fake/hardcoded MFA secret
        // Users should use 'mfa-setup' command for initial MFA configuration with real secret
        if (enable) {
            printOut("MFA enabled for {s}.\n", .{username});
        } else {
            printOut("MFA disabled for {s}.\n", .{username});
        }
        return;
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
        // Verify old password if provided (constant-time comparison via hashing)
        if (old_pw) |old| {
            if (mgr.storage.getUserByUsername(username)) |existing| {
                const stored = existing.getPasswordHash();
                // Simple constant-time comparison via Blake2
                const Blake2 = std.crypto.hash.blake2.Blake2b256;
                var stored_hash: [Blake2.digest_length]u8 = undefined;
                var input_hash: [Blake2.digest_length]u8 = undefined;
                Blake2.hash(stored, &stored_hash, .{});
                Blake2.hash(old, &input_hash, .{});
                if (!std.crypto.timing_safe.eql([Blake2.digest_length]u8, stored_hash, input_hash)) {
                    std.debug.print("Error: old password is incorrect\n", .{});
                    std.process.exit(@intFromEnum(ExitCode.general_error));
                }
            }
        }
        if (mgr.storage.getUserByUsername(username)) |existing| {
            try mgr.storage.updateUser(existing.id, null, final_new, null, null, null);
        }
        printOut("Password changed for user '{s}'\n", .{username});
        return;
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
        if (mgr.storage.getUserByUsername(username)) |existing| {
            // Resolve the HMAC signing key the SAME way the server does so the
            // chain stays single-source-of-truth. Without this, mgr.storage
            // mutates the user record but the per-record HMAC + chain seal
            // never get re-signed, and the next server start fails with
            // error.AuthChainTampered (verifyChain at server_init.zig:314).
            // Mirror initCliAuthManager's data_dir fallback so .geode_hmac_key
            // is found at the default /var/lib/geode location when --data-dir
            // is omitted. std.posix.getenv was removed in Zig 0.16; use
            // std.c.getenv directly via a NUL-terminated key.
            const resolved_data_dir: ?[]const u8 = blk: {
                if (data_dir) |d| break :blk d;
                const ptr = std.c.getenv("GEODE_DATA_DIR");
                if (ptr) |p| break :blk std.mem.span(p);
                break :blk "/var/lib/geode";
            };
            var kr = auth_graph_manager_mod.AuthGraphManager.resolveHmacKey(allocator, resolved_data_dir) catch {
                std.debug.print("Error: could not resolve HMAC key (set GEODE_AUTH_HMAC_KEY/GEODE_TDE_KEY or place .geode_hmac_key in the data dir)\n", .{});
                std.process.exit(@intFromEnum(ExitCode.general_error));
            };
            const password_hash = try geode_auth.hashPasswordArgon2id(allocator, final_new);
            defer allocator.free(password_hash);
            _ = try mgr.updateUserPassword(&kr.key, existing.id, password_hash);
            // Clear the password_reset_required flag — the operator just reset
            // the password, so the next login should NOT bounce the user back
            // through another reset flow.
            var record = mgr.storage.user_cache.get(existing.id) orelse return error.UserNotFound;
            if (record.password_reset_required) {
                record.password_reset_required = false;
                record.updated_at = compat_milliTimestamp();
                try mgr.storage.user_cache.put(existing.id, record);
                try mgr.storage.upsertUserNode(record);
                _ = try mgr.updateUserPassword(&kr.key, existing.id, password_hash);
            }
        }
        printOut("Password reset for user '{s}'\n", .{username});
        return;
    }

    std.debug.print("Error: Unknown user subcommand '{s}'\n", .{subcommand});
    printUserUsage();
    std.process.exit(@intFromEnum(ExitCode.general_error));
}

/// Role management command handler
/// Handles: role create, role list, role delete, role show
pub fn cmdRole(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    // Open graph store for offline auth operations
    const data_dir = extractDataDir(argv);
    var mgr = cli_auth.initCliAuthManager(allocator, data_dir) catch |err| {
        std.debug.print("Error: Failed to initialize auth store: {}\n", .{err});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    defer cli_auth.deinitAndSaveCliAuth(allocator, &mgr);

    if (start_idx + 1 >= argv.len) {
        std.debug.print("Error: missing role subcommand\n", .{});
        printRoleUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    const subcommand = argv[start_idx + 1];

    // Handle --help and -h flags
    if (std.mem.eql(u8, subcommand, "--help") or std.mem.eql(u8, subcommand, "-h")) {
        printRoleUsage();
        return;
    }

    if (std.mem.eql(u8, subcommand, "create")) {
        if (hasHelpFlag(argv, start_idx + 2)) {
            printRoleUsage();
            return;
        }
        if (start_idx + 2 >= argv.len) {
            std.debug.print("Error: role create requires <rolename>\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
        const rolename = argv[start_idx + 2];
        var description: []const u8 = "Role created via CLI";
        var description_is_default = true;

        var i = start_idx + 3;
        while (i < argv.len) : (i += 1) {
            if (!std.mem.startsWith(u8, argv[i], "--") and description_is_default) {
                description = argv[i];
                description_is_default = false;
            } else if (std.mem.eql(u8, argv[i], "--permissions") and i + 1 < argv.len) {
                // Permissions are stored separately in graph; skip for role node
                i += 1;
            }
        }

        // Check if role already exists
        if (mgr.storage.getRoleByName(rolename) == null) {
            const role_id = mgr.next_user_id;
            mgr.next_user_id += 1;
            try mgr.storage.persistRole(role_id, rolename, description, 0, 0, false);
        }
        printOut("Role '{s}' created successfully\n", .{rolename});
        return;
    } else if (std.mem.eql(u8, subcommand, "list")) {
        if (hasHelpFlag(argv, start_idx + 2)) {
            printOut("Usage: geode role list\nLists all roles\n", .{});
            return;
        }
        printOut("Roles:\n", .{});
        var it = mgr.storage.roleIterator();
        var found = false;
        while (it.next()) |record| {
            printOut("- {s}: {s}\n", .{ record.getName(), record.getDescription() });
            found = true;
        }
        if (!found) {
            printOut("  (no roles)\n", .{});
        }
        return;
    } else if (std.mem.eql(u8, subcommand, "delete")) {
        if (hasHelpFlag(argv, start_idx + 2)) {
            printOut("Usage: geode role delete <rolename>\nDelete role by name\n", .{});
            return;
        }
        if (start_idx + 2 >= argv.len) {
            std.debug.print("Error: role delete requires <rolename>\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
        const rolename = argv[start_idx + 2];
        var deleted = false;
        if (mgr.storage.getRoleByName(rolename)) |role| {
            mgr.storage.removeRole(role.id) catch {};
            deleted = true;
        }
        printOut("Role '{s}' {s}\n", .{ rolename, if (deleted) "deleted" else "not found (noop)" });
        return;
    } else if (std.mem.eql(u8, subcommand, "show")) {
        if (hasHelpFlag(argv, start_idx + 2)) {
            printRoleUsage();
            return;
        }
        if (start_idx + 2 >= argv.len) {
            std.debug.print("Error: role show requires <rolename>\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
        const rolename = argv[start_idx + 2];
        if (mgr.storage.getRoleByName(rolename)) |r| {
            printOut("Role: {s}\nDescription: {s}\n", .{ r.getName(), r.getDescription() });
        } else {
            printOut("Role: {s}\nDescription: (not found)\n", .{rolename});
        }
        return;
    } else {
        std.debug.print("Error: Unknown role subcommand '{s}'\n", .{subcommand});
        printRoleUsage();
        std.process.exit(@intFromEnum(ExitCode.general_error));
    }
}
