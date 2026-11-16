const std = @import("std");
const geode = @import("geode");
const cli_auth = @import("cli_auth_helpers.zig");
const AuthGraphManager = cli_auth.AuthGraphManager;
const stdio_util = @import("../utils/stdio.zig");

// CANARY: REQ=REQ-QUALITY-GAP-406-006; FEATURE="SafeStdioHandles"; ASPECT=ErrorHandling; STATUS=TESTED; OWNER=quality; UPDATED=2026-01-30
fn printOut(comptime fmt: []const u8, args: anytype) void {
    var buf: [512]u8 = undefined;
    const msg = std.fmt.bufPrint(&buf, fmt, args) catch return;
    const stdout = stdio_util.getStdout() catch return;
    const io = std.Io.Threaded.global_single_threaded.io();
    stdout.writeStreamingAll(io, msg) catch {};
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

/// Policy management command handler
/// Handles: policy create, policy list, policy show, policy delete
pub fn cmdPolicy(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    // Help / missing-subcommand checks BEFORE opening the auth store —
    // these paths must not require disk I/O.
    const subcmd_idx = start_idx + 1;
    if (subcmd_idx >= argv.len) {
        std.debug.print("Error: missing policy subcommand\n", .{});
        printPolicyUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }
    const subcmd = argv[subcmd_idx];
    if (std.mem.eql(u8, subcmd, "--help") or std.mem.eql(u8, subcmd, "-h")) {
        printPolicyUsage();
        return;
    }
    if (hasHelpFlag(argv, subcmd_idx + 1)) {
        printPolicyUsage();
        return;
    }

    // Open graph store for offline auth operations
    const data_dir = extractDataDir(argv);
    var mgr = cli_auth.initCliAuthManager(allocator, data_dir) catch |err| {
        std.debug.print("Error: Failed to initialize auth store: {}\n", .{err});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    defer cli_auth.deinitAndSaveCliAuth(allocator, &mgr);
    // SONNY-2798: verify the chain before a change, and seal the change.
    if (std.mem.eql(u8, subcmd, "create") or std.mem.eql(u8, subcmd, "delete")) {
        cli_auth.requireIntactChain(allocator, &mgr, "policy", subcmd);
    }

    if (std.mem.eql(u8, subcmd, "create")) {
        if (hasHelpFlag(argv, subcmd_idx + 1)) {
            printPolicyUsage();
            return;
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
        // SONNY-2777: a new id from the policy id sequence; it used to be the
        // next user id, which could overwrite a GPS policy's record.
        _ = try cli_auth.createRlsPolicyRecord(&mgr, name, table, condition);
        printOut("RLS policy '{s}' created for table '{s}'\n", .{ name, table });
        return;
    } else if (std.mem.eql(u8, subcmd, "list")) {
        if (hasHelpFlag(argv, subcmd_idx + 1)) {
            printPolicyUsage();
            return;
        }
        // SONNY-2750: RLS records only; GPS policies share the record type.
        var found = false;
        var it = mgr.storage.policyIterator();
        while (it.next()) |record| {
            if (record.effectiveKind() != .rls) continue;
            if (!found) printOut("Policies:\n", .{});
            found = true;
            printOut("- {s} on {s}\n", .{ record.getName(), record.getTable() });
        }
        if (!found) printOut("No policies configured (RLS list)\n", .{});
        return;
    } else if (std.mem.eql(u8, subcmd, "show")) {
        if (subcmd_idx + 1 >= argv.len) {
            std.debug.print("Error: policy show requires <name>\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
        const name = argv[subcmd_idx + 1];
        // Find policy by name
        var found = false;
        var it = mgr.storage.policyIterator();
        while (it.next()) |record| {
            // SONNY-2750: RLS records only.
            if (record.effectiveKind() != .rls) continue;
            if (std.mem.eql(u8, record.getName(), name)) {
                const using = record.getUsingClause() orelse "";
                printOut("Policy: {s}\nTable: {s}\nCondition: {s}\n", .{ record.getName(), record.getTable(), using });
                found = true;
                break;
            }
        }
        if (!found) {
            printOut("Policy '{s}' not found\n", .{name});
        }
        return;
    } else if (std.mem.eql(u8, subcmd, "delete")) {
        if (subcmd_idx + 1 >= argv.len) {
            std.debug.print("Error: policy delete requires <name>\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
        const name = argv[subcmd_idx + 1];
        // SONNY-2750: never a GPS policy of the same name. SONNY-6352: a
        // removal that fails is reported (it was dropped, and the policy
        // reported deleted while it stayed stored), and so is a name with no
        // RLS policy (it was reported deleted too).
        const outcome = cli_auth.removeRlsPolicyByName(&mgr, name) catch |err| {
            std.debug.print("Error: failed to delete policy '{s}': {s} — the policy was NOT deleted\n", .{ name, @errorName(err) });
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };
        printOut("Policy '{s}' {s}\n", .{ name, if (outcome == .removed) "deleted" else "not found (noop)" });
        return;
    }

    std.debug.print("Error: unknown policy subcommand '{s}'\n", .{subcmd});
    printPolicyUsage();
    std.process.exit(@intFromEnum(ExitCode.usage_error));
}

/// Grant permission command handler
/// Handles: grant <permission> [target] [resource] / --to / --resource
pub fn cmdGrant(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    if (hasHelpFlag(argv, start_idx + 1)) {
        printGrantUsage();
        return;
    }

    // SONNY-6586: the permission is the first positional argument (it was
    // argv[start_idx + 1] whatever it was, so `grant --data-dir <dir> ...`
    // took "--data-dir" as the permission).
    var target: ?[]const u8 = null;
    var resource: []const u8 = "";
    var i = start_idx + 1;
    var positional = std.ArrayList([]const u8).empty;
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
        } else if (std.mem.eql(u8, argv[i], "--data-dir") and i + 1 < argv.len) {
            // SONNY-6586: the directory is not a positional (it was taken
            // as the grantee when no --to was given).
            i += 1;
        } else if (!std.mem.startsWith(u8, argv[i], "--")) {
            // The first is the permission, whatever it looks like.
            if (positional.items.len > 0 and isLikelyServerAddress(argv[i])) continue;
            positional.append(allocator, argv[i]) catch {};
        }
    }
    if (positional.items.len == 0) {
        std.debug.print("Error: missing permission to grant\n", .{});
        printGrantUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }
    const permission = positional.items[0];
    const rest = positional.items[1..];
    if (target == null and rest.len > 0) {
        target = rest[rest.len - 1];
    }
    if (resource.len == 0 and rest.len > 1) {
        resource = rest[0];
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

    // SONNY-6586: the auth store (and the data directory's lock) is opened
    // only now, once help and the arguments are handled; --help failed while
    // a server held the directory, or when it did not exist.
    const data_dir = extractDataDir(argv);
    var mgr = cli_auth.initCliAuthManager(allocator, data_dir) catch |err| {
        std.debug.print("Error: Failed to initialize auth store: {}\n", .{err});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    defer cli_auth.deinitAndSaveCliAuth(allocator, &mgr);

    // SONNY-2798: verify the chain before the change.
    cli_auth.requireIntactChain(allocator, &mgr, "grant", permission);

    // Persist the permission grant in the graph store
    // SONNY-3037: a permission id of its own (it took the next user id, so
    // every grant replaced the one before it).
    const perm_id = mgr.storage.nextPermissionId();
    try mgr.storage.persistPermission(perm_id, permission, resource, 0, target);
    printOut("Granted permission '{s}' to '{s}'{s}{s}\n", .{ permission, target.?, if (resource.len > 0) " on resource " else "", if (resource.len > 0) resource else "" });
    // SONNY-2798: exit skips the deferred save; seal and save first.
    cli_auth.deinitAndSaveCliAuth(allocator, &mgr);
    std.process.exit(@intFromEnum(ExitCode.success));
}

/// Revoke permission command handler
/// Handles: revoke <permission> [target] / --from
pub fn cmdRevoke(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    if (hasHelpFlag(argv, start_idx + 1)) {
        printRevokeUsage();
        return;
    }

    // SONNY-6586: the permission is the first positional argument.
    var target: ?[]const u8 = null;
    var resource: []const u8 = "";
    var i = start_idx + 1;
    var positional = std.ArrayList([]const u8).empty;
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
        } else if (std.mem.eql(u8, argv[i], "--data-dir") and i + 1 < argv.len) {
            // SONNY-6586: not a positional (it was taken as the principal).
            i += 1;
        } else if (!std.mem.startsWith(u8, argv[i], "--")) {
            // The first is the permission, whatever it looks like.
            if (positional.items.len > 0 and isLikelyServerAddress(argv[i])) continue;
            positional.append(allocator, argv[i]) catch {};
        }
    }
    if (positional.items.len == 0) {
        std.debug.print("Error: missing permission to revoke\n", .{});
        printRevokeUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }
    const permission = positional.items[0];
    const rest = positional.items[1..];
    if (target == null and rest.len > 0) {
        target = rest[rest.len - 1];
    }
    if (resource.len == 0 and rest.len > 1) {
        resource = rest[0];
    }

    if (target == null) {
        std.debug.print("Error: --from flag is required\n", .{});
        printRevokeUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }

    // SONNY-6586: opened once help and the arguments are handled.
    const data_dir = extractDataDir(argv);
    var mgr = cli_auth.initCliAuthManager(allocator, data_dir) catch |err| {
        std.debug.print("Error: Failed to initialize auth store: {}\n", .{err});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    defer cli_auth.deinitAndSaveCliAuth(allocator, &mgr);

    // SONNY-2798: verify the chain before the change.
    cli_auth.requireIntactChain(allocator, &mgr, "revoke", permission);

    // CANARY: REQ=REQ-SONNY-3037-REVOKE-PRINCIPAL; FEATURE="OfflineAuthStoreSafety"; ASPECT=RevokeMatchesPrincipal; STATUS=TESTED; TEST=tests/test_sonny3037_revoke_principal.zig; OWNER=security; UPDATED=2026-09-27
    // SONNY-3037: the grants of `permission` to `target` (the principal
    // `geode grant` records in the permission's conditions), on `resource`
    // when one is named. It removed the first record with the permission's
    // name, which could be another principal's, and reported success
    // whether or not anything matched.
    var matches = std.ArrayList(u64).empty;
    defer matches.deinit(allocator);
    var it = mgr.storage.permission_cache.iterator();
    while (it.next()) |entry| {
        const record = entry.value_ptr;
        if (!std.mem.eql(u8, record.getName(), permission)) continue;
        const holder = record.getConditions() orelse continue;
        if (!std.mem.eql(u8, holder, target.?)) continue;
        if (resource.len > 0 and !std.mem.eql(u8, record.getResource(), resource)) continue;
        try matches.append(allocator, entry.key_ptr.*);
    }
    if (matches.items.len == 0) {
        std.debug.print("Error: '{s}' holds no grant of permission '{s}'{s}{s}; nothing was revoked.\n", .{ target.?, permission, if (resource.len > 0) " on resource " else "", if (resource.len > 0) resource else "" });
        cli_auth.deinitAndSaveCliAuth(allocator, &mgr);
        std.process.exit(@intFromEnum(ExitCode.general_error));
    }
    for (matches.items) |id| try mgr.storage.removePermission(id);
    printOut("Revoked permission '{s}' from '{s}'{s}{s}\n", .{ permission, target.?, if (resource.len > 0) " on resource " else "", if (resource.len > 0) resource else "" });
    // SONNY-2798: exit skips the deferred save; seal and save first.
    cli_auth.deinitAndSaveCliAuth(allocator, &mgr);
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
