const std = @import("std");
const geode = @import("geode");

// CANARY: REQ=REQ-M4.2-AUTH-CLI-001; FEATURE="CLI Modularization"; ASPECT=AuthCommands; STATUS=IMPL; OWNER=cli; UPDATED=2025-11-12
// Phase 4 M4.2: Extract authentication and policy commands (cmdPolicy, cmdGrant, cmdRevoke) from cli/main.zig

// Exit codes for consistency with main CLI
const ExitCode = enum(u8) {
    success = 0,
    general_error = 1,
    usage_error = 2,
};

/// Policy management command handler
/// Handles: policy create, policy list, policy show, policy delete
pub fn cmdPolicy(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    _ = allocator;
    // start_idx points to "policy", so start_idx + 1 is the subcommand
    const subcmd_idx = start_idx + 1;

    // Check for missing subcommand
    if (subcmd_idx >= argv.len) {
        std.debug.print("Error: missing policy subcommand\n", .{});
        printPolicyUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    const subcmd = argv[subcmd_idx];

    // Check for help flag
    if (std.mem.eql(u8, subcmd, "--help") or std.mem.eql(u8, subcmd, "-h")) {
        printPolicyUsage();
        std.process.exit(@intFromEnum(ExitCode.success));
    }

    // Handle policy subcommands
    if (std.mem.eql(u8, subcmd, "create") or
        std.mem.eql(u8, subcmd, "list") or
        std.mem.eql(u8, subcmd, "show") or
        std.mem.eql(u8, subcmd, "delete"))
    {

        // Check for help flag after subcommand
        if (subcmd_idx + 1 < argv.len) {
            const arg = argv[subcmd_idx + 1];
            if (std.mem.eql(u8, arg, "--help") or std.mem.eql(u8, arg, "-h")) {
                printPolicyUsage();
                std.process.exit(@intFromEnum(ExitCode.success));
            }
        }

        std.debug.print("Policy command '{s}' executed successfully (placeholder)\n", .{subcmd});
        std.process.exit(@intFromEnum(ExitCode.success));
    } else {
        std.debug.print("Error: unknown policy subcommand '{s}'\n", .{subcmd});
        printPolicyUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }
}

/// Grant permission command handler
/// Handles: grant <permission> --to <user/role>
pub fn cmdGrant(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    _ = allocator;
    // start_idx points to "grant", so start_idx + 1 is the permission
    const perm_idx = start_idx + 1;

    // Check for missing permission
    if (perm_idx >= argv.len) {
        std.debug.print("Error: missing permission to grant\n", .{});
        printGrantUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    const permission = argv[perm_idx];

    // Check for help flag
    if (std.mem.eql(u8, permission, "--help") or std.mem.eql(u8, permission, "-h")) {
        printGrantUsage();
        std.process.exit(@intFromEnum(ExitCode.success));
    }

    // Parse --to flag
    var to_target: ?[]const u8 = null;
    var i = perm_idx + 1;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--to")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --to requires a target (user or role)\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            to_target = argv[i + 1];
            break;
        }
    }

    if (to_target == null) {
        std.debug.print("Error: --to flag is required\n", .{});
        printGrantUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    std.debug.print("Granted permission '{s}' to '{s}' (placeholder)\n", .{ permission, to_target.? });
    std.process.exit(@intFromEnum(ExitCode.success));
}

/// Revoke permission command handler
/// Handles: revoke <permission> --from <user/role>
pub fn cmdRevoke(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    _ = allocator;
    // start_idx points to "revoke", so start_idx + 1 is the permission
    const perm_idx = start_idx + 1;

    // Check for missing permission
    if (perm_idx >= argv.len) {
        std.debug.print("Error: missing permission to revoke\n", .{});
        printRevokeUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    const permission = argv[perm_idx];

    // Check for help flag
    if (std.mem.eql(u8, permission, "--help") or std.mem.eql(u8, permission, "-h")) {
        printRevokeUsage();
        std.process.exit(@intFromEnum(ExitCode.success));
    }

    // Parse --from flag
    var from_target: ?[]const u8 = null;
    var i = perm_idx + 1;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--from")) {
            if (i + 1 >= argv.len) {
                std.debug.print("Error: --from requires a target (user or role)\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            from_target = argv[i + 1];
            break;
        }
    }

    if (from_target == null) {
        std.debug.print("Error: --from flag is required\n", .{});
        printRevokeUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    std.debug.print("Revoked permission '{s}' from '{s}' (placeholder)\n", .{ permission, from_target.? });
    std.process.exit(@intFromEnum(ExitCode.success));
}

// Helper functions for usage messages

fn printPolicyUsage() void {
    std.debug.print("Usage: geode policy <command> [options]\n", .{});
    std.debug.print("Commands:\n", .{});
    std.debug.print("  create <policy-name>    Create a new policy\n", .{});
    std.debug.print("  list                    List all policies\n", .{});
    std.debug.print("  show <policy-name>      Show policy details\n", .{});
    std.debug.print("  delete <policy-name>    Delete a policy\n", .{});
}

fn printGrantUsage() void {
    std.debug.print("Usage: geode grant <permission> --to <user|role>\n", .{});
    std.debug.print("Examples:\n", .{});
    std.debug.print("  geode grant read:users --to alice\n", .{});
    std.debug.print("  geode grant admin --to admin-role\n", .{});
}

fn printRevokeUsage() void {
    std.debug.print("Usage: geode revoke <permission> --from <user|role>\n", .{});
    std.debug.print("Examples:\n", .{});
    std.debug.print("  geode revoke read:users --from alice\n", .{});
    std.debug.print("  geode revoke admin --from admin-role\n", .{});
}
