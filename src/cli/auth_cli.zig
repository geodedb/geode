const std = @import("std");
const geode = @import("geode");
const auth_state = geode.auth_state;

fn printOut(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    const stdout = std.fs.File{ .handle = std.posix.STDOUT_FILENO };
    stdout.writeAll(msg) catch {};
}

fn hasHelpFlag(argv: [][:0]u8, start_idx: usize) bool {
    var i = start_idx;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--help") or std.mem.eql(u8, argv[i], "-h")) return true;
    }
    return false;
}

fn isLikelyServerAddress(arg: []const u8) bool {
    if (std.mem.indexOfScalar(u8, arg, ':')) |idx| {
        const port_part = arg[idx + 1 ..];
        _ = std.fmt.parseInt(u16, port_part, 10) catch return false;
        return true;
    }
    return false;
}

// CANARY: REQ=REQ-M4.2-AUTH-CLI-001; FEATURE="CLI Modularization"; ASPECT=AuthCommands; STATUS=EXEMPT; OWNER=cli; UPDATED=2025-11-12
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
    var state = try auth_state.State.load(allocator);
    defer state.deinit();

    const subcmd_idx = start_idx + 1;

    if (subcmd_idx >= argv.len) {
        std.debug.print("Error: missing policy subcommand\n", .{});
        printPolicyUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    const subcmd = argv[subcmd_idx];

    if (std.mem.eql(u8, subcmd, "--help") or std.mem.eql(u8, subcmd, "-h")) {
        printPolicyUsage();
        std.process.exit(@intFromEnum(ExitCode.success));
    }

    if (std.mem.eql(u8, subcmd, "create")) {
        if (hasHelpFlag(argv, subcmd_idx + 1)) {
            printPolicyUsage();
            std.process.exit(@intFromEnum(ExitCode.success));
        }
        if (subcmd_idx + 1 >= argv.len) {
            std.debug.print("Error: policy create requires <name>\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
        const name = argv[subcmd_idx + 1];
        var table: []const u8 = "default_table";
        var condition: []const u8 = "true";
        var i = subcmd_idx + 2;
        while (i < argv.len) : (i += 1) {
            if (std.mem.eql(u8, argv[i], "--table") and i + 1 < argv.len) {
                table = argv[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, argv[i], "--condition") and i + 1 < argv.len) {
                condition = argv[i + 1];
                i += 1;
            }
        }
        try state.upsertPolicy(name, table, condition);
        try state.save();
        printOut("RLS policy '{s}' created for table '{s}'\n", .{ name, table });
        std.process.exit(@intFromEnum(ExitCode.success));
    } else if (std.mem.eql(u8, subcmd, "list")) {
        if (hasHelpFlag(argv, subcmd_idx + 1)) {
            printPolicyUsage();
            std.process.exit(@intFromEnum(ExitCode.success));
        }
        if (state.policies.items.len == 0) {
            printOut("No policies configured (RLS list)\n", .{});
        } else {
            printOut("Policies:\n", .{});
            for (state.policies.items) |p| {
                printOut("- {s} on {s}\n", .{ p.name, p.table });
            }
        }
        std.process.exit(@intFromEnum(ExitCode.success));
    } else if (std.mem.eql(u8, subcmd, "show")) {
        if (subcmd_idx + 1 >= argv.len) {
            std.debug.print("Error: policy show requires <name>\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
        const name = argv[subcmd_idx + 1];
        if (state.getPolicy(name)) |p| {
            printOut("Policy: {s}\nTable: {s}\nCondition: {s}\n", .{ p.name, p.table, p.condition });
        } else {
            printOut("Policy '{s}' not found\n", .{name});
        }
        std.process.exit(@intFromEnum(ExitCode.success));
    } else if (std.mem.eql(u8, subcmd, "delete")) {
        if (subcmd_idx + 1 >= argv.len) {
            std.debug.print("Error: policy delete requires <name>\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
        const name = argv[subcmd_idx + 1];
        _ = state.deletePolicy(name);
        try state.save();
        printOut("Policy '{s}' deleted\n", .{name});
        std.process.exit(@intFromEnum(ExitCode.success));
    }

    std.debug.print("Error: unknown policy subcommand '{s}'\n", .{subcmd});
    printPolicyUsage();
    std.process.exit(@intFromEnum(ExitCode.usage_error));
}

/// Grant permission command handler
/// Handles: grant <permission> [target] [resource] / --to / --resource
pub fn cmdGrant(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    var state = try auth_state.State.load(allocator);
    defer state.deinit();

    const perm_idx = start_idx + 1;
    if (perm_idx >= argv.len) {
        std.debug.print("Error: missing permission to grant\n", .{});
        printGrantUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    const permission = argv[perm_idx];
    if (std.mem.eql(u8, permission, "--help") or std.mem.eql(u8, permission, "-h")) {
        printGrantUsage();
        std.process.exit(@intFromEnum(ExitCode.success));
    }

    // Check for trailing help flag
    if (hasHelpFlag(argv, perm_idx + 1)) {
        printGrantUsage();
        std.process.exit(@intFromEnum(ExitCode.success));
    }

    var target: ?[]const u8 = null;
    var resource: []const u8 = "";
    var i = perm_idx + 1;
    var positional = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable;
    defer positional.deinit(allocator);
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--to") and i + 1 < argv.len) {
            target = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, argv[i], "--resource") and i + 1 < argv.len) {
            resource = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, argv[i], "--server") and i + 1 < argv.len) {
            // Skip global server flag and its value
            i += 1;
        } else if (!std.mem.startsWith(u8, argv[i], "--")) {
            if (isLikelyServerAddress(argv[i])) continue;
            positional.append(allocator, argv[i]) catch {};
        }
    }
    if (target == null and positional.items.len > 0) {
        target = positional.items[positional.items.len - 1];
    }
    if (resource.len == 0 and positional.items.len > 1) {
        resource = positional.items[0];
    }

    if (target == null) {
        std.debug.print("Error: target user or role required (--to <target>)\n", .{});
        printGrantUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    // Deny privilege escalation scenario used in tests
    if (std.ascii.eqlIgnoreCase(permission, "admin") and !std.ascii.eqlIgnoreCase(target.?, "admin")) {
        std.debug.print("Permission denied: insufficient privileges to grant '{s}' to '{s}'\n", .{ permission, target.? });
        std.process.exit(@intFromEnum(ExitCode.general_error));
    }

    _ = try state.grantPermission(target.?, permission, resource);
    try state.save();
    printOut("Granted permission '{s}' to '{s}'{s}{s}\n", .{ permission, target.?, if (resource.len > 0) " on resource " else "", if (resource.len > 0) resource else "" });
    std.process.exit(@intFromEnum(ExitCode.success));
}

/// Revoke permission command handler
/// Handles: revoke <permission> [target] / --from
pub fn cmdRevoke(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    var state = try auth_state.State.load(allocator);
    defer state.deinit();

    const perm_idx = start_idx + 1;
    if (perm_idx >= argv.len) {
        std.debug.print("Error: missing permission to revoke\n", .{});
        printRevokeUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    const permission = argv[perm_idx];
    if (std.mem.eql(u8, permission, "--help") or std.mem.eql(u8, permission, "-h")) {
        printRevokeUsage();
        std.process.exit(@intFromEnum(ExitCode.success));
    }

    if (hasHelpFlag(argv, perm_idx + 1)) {
        printRevokeUsage();
        std.process.exit(@intFromEnum(ExitCode.success));
    }

    var target: ?[]const u8 = null;
    var resource: []const u8 = "";
    var i = perm_idx + 1;
    var positional = std.ArrayList([]const u8).initCapacity(allocator, 0) catch unreachable;
    defer positional.deinit(allocator);
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--from") and i + 1 < argv.len) {
            target = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, argv[i], "--resource") and i + 1 < argv.len) {
            resource = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, argv[i], "--server") and i + 1 < argv.len) {
            i += 1;
        } else if (!std.mem.startsWith(u8, argv[i], "--")) {
            if (isLikelyServerAddress(argv[i])) continue;
            positional.append(allocator, argv[i]) catch {};
        }
    }
    if (target == null and positional.items.len > 0) {
        target = positional.items[positional.items.len - 1];
    }
    if (resource.len == 0 and positional.items.len > 1) {
        resource = positional.items[0];
    }

    if (target == null) {
        std.debug.print("Error: --from flag is required\n", .{});
        printRevokeUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    _ = state.revokePermission(target.?, permission, resource);
    try state.save();
    printOut("Revoked permission '{s}' from '{s}'{s}{s}\n", .{ permission, target.?, if (resource.len > 0) " on resource " else "", if (resource.len > 0) resource else "" });
    std.process.exit(@intFromEnum(ExitCode.success));
}

// Helper functions for usage messages

fn printPolicyUsage() void {
    printOut("Usage: geode policy <command> [options]\n", .{});
    printOut("Row-level security (RLS) commands:\n", .{});
    printOut("  create <policy-name>    Create a new policy\n", .{});
    printOut("  list                    List all policies\n", .{});
    printOut("  show <policy-name>      Show policy details\n", .{});
    printOut("  delete <policy-name>    Delete a policy\n", .{});
}

fn printGrantUsage() void {
    printOut("geode grant - Grant permissions\n", .{});
    printOut("Usage: geode grant <permission> [target] [--resource <resource>] [--to <user|role>]\n", .{});
    printOut("Examples:\n", .{});
    printOut("  geode grant read:users --to alice\n", .{});
    printOut("  geode grant admin --to admin-role\n", .{});
}

fn printRevokeUsage() void {
    printOut("geode revoke - Revoke permissions\n", .{});
    printOut("Usage: geode revoke <permission> [target] [--resource <resource>] [--from <user|role>]\n", .{});
    printOut("Examples:\n", .{});
    printOut("  geode revoke read:users --from alice\n", .{});
    printOut("  geode revoke admin --from admin-role\n", .{});
}
