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

// CANARY: REQ=REQ-SONNY-6586-OFFLINE-GRANT-RULE; FEATURE="OfflineAuthStoreSafety"; ASPECT=GrantMatchesOnlineGrant; STATUS=TESTED; TEST=tests/test_sonny6586_offline_grant_rule.zig; OWNER=security; UPDATED=2026-11-15
// SONNY-6586: offline `geode grant` / `geode revoke` are the online
// `GRANT <privilege> ON GRAPH <graph> TO <user>` / `REVOKE ...`: the same
// rule (geode.security.graph_grant_rules: READ, WRITE, SCHEMA or ALL on one
// named graph, to a user that exists) and the same GraphGrant records,
// stored by the same AuthGraphManager write-through the server uses and
// loads at startup. They stored a free-form Permission record (any name,
// the principal in its conditions) that no authorization path reads, and
// their one rule was hard-coded: `admin` only to a principal named "admin".
// `admin` is a role: `geode user assign-role <user> admin`. The authority
// here is the data directory itself, as for every offline auth command (it
// runs only while no server holds the directory).

const grant_rules = geode.security.graph_grant_rules;

const GrantArgs = struct {
    privilege: []const u8,
    user: []const u8,
    graph: []const u8,
};

/// `<privilege> [<graph>] <user> | --to/--from <user> | --graph <graph>`.
/// A usage error exits 2.
fn parseGrantArgs(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize, comptime is_grant: bool) !GrantArgs {
    const user_flag = if (is_grant) "--to" else "--from";
    var user: ?[]const u8 = null;
    var graph: []const u8 = "";
    var positional = std.ArrayList([]const u8).empty;
    defer positional.deinit(allocator);
    var i = start_idx + 1;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], user_flag) and i + 1 < argv.len) {
            user = argv[i + 1];
            i += 1;
        } else if ((std.mem.eql(u8, argv[i], "--graph") or std.mem.eql(u8, argv[i], "--resource")) and i + 1 < argv.len) {
            graph = argv[i + 1];
            i += 1;
        } else if (std.mem.eql(u8, argv[i], "--server") and i + 1 < argv.len) {
            i += 1;
        } else if (std.mem.eql(u8, argv[i], "--data-dir") and i + 1 < argv.len) {
            // The directory is not a positional (it was taken as the user).
            i += 1;
        } else if (!std.mem.startsWith(u8, argv[i], "--")) {
            // The first is the privilege, whatever it looks like.
            if (positional.items.len > 0 and isLikelyServerAddress(argv[i])) continue;
            try positional.append(allocator, argv[i]);
        }
    }
    if (positional.items.len == 0) {
        std.debug.print("Error: missing permission to {s}\n", .{if (is_grant) "grant" else "revoke"});
        if (is_grant) printGrantUsage() else printRevokeUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }
    const rest = positional.items[1..];
    if (user == null and rest.len > 0) user = rest[rest.len - 1];
    if (graph.len == 0 and rest.len > 1) graph = rest[0];
    if (user == null) {
        if (is_grant) {
            std.debug.print("Error: target user or role required (--to <target>)\n", .{});
            printGrantUsage();
        } else {
            std.debug.print("Error: --from flag is required\n", .{});
            printRevokeUsage();
        }
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }
    return .{ .privilege = positional.items[0], .user = user.?, .graph = graph };
}

/// The action codes of `args`, by the online rule; anything else exits 2.
fn grantActions(args: GrantArgs, comptime is_grant: bool) []const u8 {
    const verb = if (is_grant) "grant" else "revoke";
    const done = if (is_grant) "granted" else "revoked";
    const actions = grant_rules.actionsOf(args.privilege) orelse {
        if (std.ascii.eqlIgnoreCase(args.privilege, "admin")) {
            std.debug.print("Error: 'admin' is not a privilege: admin is a role. Give or take it with 'geode user assign-role <user> <role>' (GRANT ROLE admin TO <user>); nothing was {s}.\n", .{done});
        } else {
            std.debug.print("Error: unknown privilege '{s}': geode {s} takes READ, WRITE, SCHEMA or ALL on one graph, as GRANT <privilege> ON GRAPH <graph> TO <user>; nothing was {s}.\n", .{ args.privilege, verb, done });
        }
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    };
    grant_rules.checkGraph(args.graph, is_grant) catch |err| {
        switch (err) {
            error.GlobalPrivilegeNotSupported => std.debug.print("Error: geode {s} needs a graph (--graph <name>): a privilege is held per graph; global privilege is the user's role (geode user assign-role). Nothing was {s}.\n", .{ verb, done }),
            error.GrantWildcardNotSupported => std.debug.print("Error: there is no grant on every graph ('*'): grant on one graph, or give the user a built-in role (geode user assign-role); nothing was granted.\n", .{}),
        }
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    };
    return actions;
}

/// The id of `username`, or exit 1 saying it does not exist.
fn grantUserId(allocator: std.mem.Allocator, mgr: *AuthGraphManager, username: []const u8, comptime done: []const u8) !u64 {
    return (try mgr.findUserIdByName(username)) orelse {
        std.debug.print("Error: user '{s}' does not exist; nothing was {s}.\n", .{ username, done });
        cli_auth.deinitCliAuthWithoutSaving(allocator, mgr);
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
}

/// Grant command handler: `geode grant <privilege> --graph <graph> --to <user>`.
pub fn cmdGrant(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    if (hasHelpFlag(argv, start_idx + 1)) {
        printGrantUsage();
        return;
    }
    const args = try parseGrantArgs(allocator, argv, start_idx, true);
    const actions = grantActions(args, true);

    // SONNY-6586: the auth store (and the data directory's lock) is opened
    // only now, once help and the arguments are handled.
    const data_dir = extractDataDir(argv);
    var mgr = cli_auth.initCliAuthManager(allocator, data_dir) catch |err| {
        std.debug.print("Error: Failed to initialize auth store: {}\n", .{err});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    defer cli_auth.deinitAndSaveCliAuth(allocator, &mgr);
    // SONNY-2798: verify the chain before the change.
    cli_auth.requireIntactChain(allocator, &mgr, "grant", args.privilege);

    const uid = try grantUserId(allocator, &mgr, args.user, "granted");
    const key = try cli_auth.changeKey(allocator);
    // Every action or none (the write-through takes back what it added).
    mgr.grantGraphPermissionsWriteThrough(&key, null, uid, args.graph, actions) catch |err| {
        std.debug.print("Error: the grant could not be stored ({s}); nothing was granted.\n", .{@errorName(err)});
        cli_auth.deinitCliAuthWithoutSaving(allocator, &mgr);
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    printOut("Granted {s} on {s} to {s}\n", .{ grant_rules.canonicalName(args.privilege), args.graph, args.user });
    // SONNY-2798: exit skips the deferred save; seal and save first.
    cli_auth.deinitAndSaveCliAuth(allocator, &mgr);
    std.process.exit(@intFromEnum(ExitCode.success));
}

/// Revoke command handler: `geode revoke <privilege> --graph <graph> --from <user>`.
pub fn cmdRevoke(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    if (hasHelpFlag(argv, start_idx + 1)) {
        printRevokeUsage();
        return;
    }
    const args = try parseGrantArgs(allocator, argv, start_idx, false);
    const actions = grantActions(args, false);

    const data_dir = extractDataDir(argv);
    var mgr = cli_auth.initCliAuthManager(allocator, data_dir) catch |err| {
        std.debug.print("Error: Failed to initialize auth store: {}\n", .{err});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    defer cli_auth.deinitAndSaveCliAuth(allocator, &mgr);
    // SONNY-2798: verify the chain before the change.
    cli_auth.requireIntactChain(allocator, &mgr, "revoke", args.privilege);

    const uid = try grantUserId(allocator, &mgr, args.user, "revoked");
    const key = try cli_auth.changeKey(allocator);
    // CANARY: REQ=REQ-SONNY-3037-REVOKE-PRINCIPAL; FEATURE="OfflineAuthStoreSafety"; ASPECT=RevokeMatchesPrincipal; STATUS=TESTED; TEST=tests/test_sonny6586_offline_grant_rule.zig; OWNER=security; UPDATED=2026-11-15
    // SONNY-3037: the named user's grant only, and a user that holds none
    // is refused with nothing changed.
    var held = false;
    for (actions) |action| {
        const was = mgr.revokeGraphPermissionWriteThrough(&key, null, uid, args.graph, action) catch |err| {
            // What was revoked before this action is saved below.
            std.debug.print("Error: the revoke could not be stored ({s}); revoke again.\n", .{@errorName(err)});
            cli_auth.deinitAndSaveCliAuth(allocator, &mgr);
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };
        held = held or was;
    }
    if (!held) {
        std.debug.print("Error: '{s}' holds no {s} grant on {s}; nothing was revoked.\n", .{ args.user, grant_rules.canonicalName(args.privilege), args.graph });
        cli_auth.deinitCliAuthWithoutSaving(allocator, &mgr);
        std.process.exit(@intFromEnum(ExitCode.general_error));
    }
    printOut("Revoked {s} on {s} from {s}\n", .{ grant_rules.canonicalName(args.privilege), args.graph, args.user });
    // SONNY-2798: exit skips the deferred save; seal and save first.
    cli_auth.deinitAndSaveCliAuth(allocator, &mgr);
    std.process.exit(@intFromEnum(ExitCode.success));
}

// CANARY: REQ=REQ-SONNY-6647-PRUNE-LEGACY-PERMISSIONS; FEATURE="OfflineAuthStoreSafety"; ASPECT=PruneInertPermissionRecords; STATUS=TESTED; TEST=tests/test_sonny6647_user_permissions.zig; OWNER=security; UPDATED=2026-11-15
/// `geode auth prune-legacy-permissions [--dry-run] [--data-dir <dir>]`
/// (SONNY-6647): the Permission records in __geode_security, which the
/// offline `geode grant` stored before SONNY-6586 (a free-form name, the
/// grantee in its conditions). No authorization path reads them: per-graph
/// privileges are GraphGrant records and global privilege is the role.
/// `--dry-run` lists them; otherwise they are removed and the chain sealed.
pub fn cmdAuthPruneLegacyPermissions(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    if (hasHelpFlag(argv, start_idx)) {
        printPruneUsage();
        return;
    }
    var dry_run = false;
    for (argv[start_idx..]) |a| {
        if (std.mem.eql(u8, a, "--dry-run")) dry_run = true;
    }
    const data_dir = extractDataDir(argv);
    var mgr = cli_auth.initCliAuthManager(allocator, data_dir) catch |err| {
        std.debug.print("Error: Failed to initialize auth store: {}\n", .{err});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    defer cli_auth.deinitAndSaveCliAuth(allocator, &mgr);

    var ids = std.ArrayList(u64).empty;
    defer ids.deinit(allocator);
    var it = mgr.storage.permission_cache.iterator();
    while (it.next()) |entry| try ids.append(allocator, entry.key_ptr.*);
    std.mem.sort(u64, ids.items, {}, std.sort.asc(u64));

    if (ids.items.len == 0) {
        printOut("No legacy permission records.\n", .{});
        cli_auth.deinitCliAuthWithoutSaving(allocator, &mgr);
        std.process.exit(@intFromEnum(ExitCode.success));
    }
    for (ids.items) |id| {
        const record = mgr.storage.permission_cache.get(id).?;
        const holder = record.getConditions() orelse "";
        printOut("  {s} (to '{s}'{s}{s})\n", .{ record.getName(), holder, if (record.getResource().len > 0) ", resource " else "", record.getResource() });
    }
    if (dry_run) {
        printOut("{d} legacy permission records; none is read by any authorization path. Run without --dry-run to remove them.\n", .{ids.items.len});
        cli_auth.deinitCliAuthWithoutSaving(allocator, &mgr);
        std.process.exit(@intFromEnum(ExitCode.success));
    }
    // SONNY-2798: verify the chain before the change; the change is sealed.
    cli_auth.requireIntactChain(allocator, &mgr, "auth", "prune-legacy-permissions");
    for (ids.items) |id| {
        mgr.storage.removePermission(id) catch |err| {
            std.debug.print("Error: could not remove permission record {d} ({s}); the records removed before it are saved.\n", .{ id, @errorName(err) });
            cli_auth.deinitAndSaveCliAuth(allocator, &mgr);
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };
    }
    printOut("Removed {d} legacy permission records.\n", .{ids.items.len});
    cli_auth.deinitAndSaveCliAuth(allocator, &mgr);
    std.process.exit(@intFromEnum(ExitCode.success));
}

fn printPruneUsage() void {
    printOut("geode auth prune-legacy-permissions - Remove the Permission records the offline geode grant stored before SONNY-6586\n", .{});
    printOut("Usage: geode auth prune-legacy-permissions [--dry-run] [--data-dir <dir>]\n", .{});
    printOut("No authorization path reads these records; --dry-run lists them.\n", .{});
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
    printOut("geode grant - Grant a privilege on one graph (offline; as GRANT <privilege> ON GRAPH <graph> TO <user>)\n", .{});
    printOut("Usage: geode grant <READ|WRITE|SCHEMA|ALL> --graph <graph> --to <user> [--data-dir <dir>]\n", .{});
    printOut("Admin is a role, not a privilege: geode user assign-role <user> admin\n", .{});
    printOut("Examples:\n", .{});
    printOut("  geode grant READ --graph sales --to alice\n", .{});
    printOut("  geode grant ALL --graph sales --to alice\n", .{});
}

fn printRevokeUsage() void {
    printOut("geode revoke - Revoke a privilege on one graph (offline; as REVOKE <privilege> ON GRAPH <graph> FROM <user>)\n", .{});
    printOut("Usage: geode revoke <READ|WRITE|SCHEMA|ALL> --graph <graph> --from <user> [--data-dir <dir>]\n", .{});
    printOut("Examples:\n", .{});
    printOut("  geode revoke WRITE --graph sales --from alice\n", .{});
}
