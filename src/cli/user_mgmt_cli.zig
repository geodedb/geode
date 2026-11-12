const std = @import("std");
const build_options = @import("build_options");

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
const geode = @import("geode");

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
    printOut("  import <username> --hash <hash> [--algorithm argon2id|blake2b] [--email <e>] [--role <r>]\n", .{});
    printOut("  list                              List all users\n", .{});
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
    printOut("Note: mutating subcommands refuse to run while another process holds the data dir open\n", .{});
    printOut("      (a live server). Use ALTER USER ... SET PASSWORD over the wire, or pass --force.\n", .{});
}

fn printMfaSetupHelp() void {
    printOut("Usage: geode user mfa-setup <username> [options]\n", .{});
    printOut("Generate MFA secret and recovery codes for a user.\n", .{});
    printOut("\nOptions:\n", .{});
    printOut("  --show-uri        Show provisioning URI for authenticator apps\n", .{});
    printOut("  --show-recovery   Show recovery codes\n", .{});
    printOut("  --regenerate      Regenerate new secret and recovery codes\n", .{});
    printOut("  --help, -h        Show this help\n", .{});
}

fn printMfaVerifyHelp() void {
    printOut("Usage: geode user mfa-verify <username> --token <code>\n", .{});
    printOut("Verify a TOTP code for a user.\n", .{});
    printOut("\nOptions:\n", .{});
    printOut("  --token <code>    The 6-digit TOTP code to verify\n", .{});
    printOut("  --help, -h        Show this help\n", .{});
}

fn printMfaToggleHelp() void {
    printOut("Usage: geode user mfa <enable|disable> <username> [options]\n", .{});
    printOut("Enable or disable MFA for a user.\n", .{});
    printOut("\nOptions:\n", .{});
    printOut("  --code <code>     TOTP code for verification (enable only)\n", .{});
    printOut("  --help, -h        Show this help\n", .{});
    printOut("\nExamples:\n", .{});
    printOut("  geode user mfa enable alice --code 123456\n", .{});
    printOut("  geode user mfa disable alice\n", .{});
}

fn printRoleUsage() void {
    printOut("geode role - Role management commands\n", .{});
    printOut("Usage: geode role <command> [options]\n", .{});
    printOut("Commands:\n", .{});
    printOut("  create <rolename> [description] [--permissions <perm1,perm2>]\n", .{});
    printOut("  list                              List all roles\n", .{});
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

/// GAP-0154 FIX: Generate a cryptographically secure random password that
/// meets the password policy (SONNY-6331).
fn generateSecurePassword() !cli_auth.GeneratedPassword {
    return cli_auth.generateSecurePassword();
}

// CANARY: REQ=REQ-SONNY-6358-OFFLINE-PASSWORD-HASH; FEATURE="OfflineAuthStoreSafety"; ASPECT=HashBeforeStore; STATUS=TESTED; TEST=tests/test_sonny6358_offline_password_hash.zig; OWNER=security; UPDATED=2026-11-12
/// SONNY-6358: the `password_hash` an offline command stores for
/// `password`: the server's Argon2id PHC string
/// (`geode_auth.hashPasswordArgon2id`). `user create` and `user update
/// --password` stored the password itself, in the clear, and no login could
/// match it. Exits when it cannot hash (FIPS builds have no Argon2id).
/// Caller frees.
fn hashPasswordOrExit(allocator: std.mem.Allocator, password: []const u8) []const u8 {
    return geode_auth.hashPasswordArgon2id(allocator, password) catch |err| {
        std.debug.print("Error: could not hash the password ({s}); nothing was changed\n", .{@errorName(err)});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
}

/// SONNY-6358: set an existing user's stored password hash through the seam
/// the server's password changes use (`AuthGraphManager.updateUserPassword`:
/// the record, its HMAC and the chain seal, the forced-reset flag cleared and
/// the auth version moved on), signed with the key the chain verified with.
fn setStoredPasswordOrExit(allocator: std.mem.Allocator, mgr: *AuthGraphManager, user_id: u64, username: []const u8, password_hash: []const u8) void {
    const key = cli_auth.changeKey(allocator) catch |err| {
        std.debug.print("Error: no HMAC key to seal the password change for user '{s}' with ({s}); password NOT changed\n", .{ username, @errorName(err) });
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    _ = mgr.updateUserPassword(&key, user_id, password_hash) catch |err| {
        std.debug.print("Error: failed to persist the new password for user '{s}': {s} — password NOT changed\n", .{ username, @errorName(err) });
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
}

/// SONNY-6367: exit, before anything is changed, unless `role` names a
/// built-in role. A custom role carries no privileges (SONNY-6292), so it
/// cannot be given to a user; the offline commands stored a role node of any
/// name and reported it assigned.
fn requireBuiltinRoleOrExit(role: []const u8) void {
    if (cli_auth.builtinRoleName(role) != null) return;
    std.debug.print("Error: '{s}' is not a built-in role (admin, readwrite, user, readonly). A custom role carries no privileges, so it cannot be given to a user; grant per-graph privileges over the wire instead (GRANT READ | WRITE | SCHEMA | ALL ON GRAPH <g> TO <user>). Nothing was changed\n", .{role});
    std.process.exit(@intFromEnum(ExitCode.general_error));
}

/// SONNY-6369: exit, before anything is changed, when `username` is a
/// superuser and `role` is not admin (it would never take effect).
fn requireRoleTakesEffectOrExit(mgr: *AuthGraphManager, username: []const u8, role: []const u8) void {
    cli_auth.requireRoleTakesEffect(mgr, username, role) catch {
        std.debug.print("Error: '{s}' is a superuser: a superuser always holds the admin role, so the role '{s}' would never take effect. Nothing was changed\n", .{ username, role });
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
}

/// SONNY-6367: give a stored user the built-in role `role` (see
/// `cli_auth.assignBuiltinRole`), or exit saying it was not given.
fn assignRoleOrExit(allocator: std.mem.Allocator, mgr: *AuthGraphManager, username: []const u8, role: []const u8) void {
    cli_auth.assignBuiltinRole(allocator, mgr, username, role) catch |err| {
        std.debug.print("Error: could not give user '{s}' the role '{s}': {s} — the role was NOT assigned\n", .{ username, role, @errorName(err) });
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
}

/// SONNY-6367: the role the server resolves for `record` at login
/// (`role_resolver.resolveRoleFromGraph`: its built-in HAS_ROLE edge, admin
/// for a superuser, else none). `user list` printed "user" for everyone.
fn storedRoleName(mgr: *AuthGraphManager, record: anytype) []const u8 {
    return geode.security.role_resolver.resolveRoleFromGraph(mgr.storage.store, record).toString();
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

/// Resolve the data dir the offline auth store will be opened from:
/// `initCliAuthManager`'s chain (SONNY-6345: `cli_auth.resolveCliDataDir`,
/// the server's default directory when there is no --data-dir).
/// Caller owns the result.
fn resolveDataDir(allocator: std.mem.Allocator, data_dir: ?[]const u8) []const u8 {
    return cli_auth.resolveCliDataDir(allocator, data_dir) catch {
        std.debug.print("Error: out of memory resolving the data directory\n", .{});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
}

fn hasFlag(argv: [][:0]u8, flag: []const u8) bool {
    for (argv) |arg| {
        if (std.mem.eql(u8, arg, flag)) return true;
    }
    return false;
}

/// True when `subcommand` writes to the offline auth store.
fn subcommandMutatesAuthStore(subcommand: []const u8) bool {
    const mutating = [_][]const u8{
        "create",      "import",          "delete",         "update",
        "assign-role", "disable",         "enable",         "mfa",
        "mfa-setup",   "change-password", "reset-password",
    };
    for (mutating) |m| {
        if (std.mem.eql(u8, subcommand, m)) return true;
    }
    return false;
}

// CANARY: REQ=REQ-CLI-OFFLINE-AUTH-LOCK-001; FEATURE="OfflineAuthStoreSafety"; ASPECT=LiveServerDetection; STATUS=IMPL; OWNER=cli; UPDATED=2026-07-31
/// Detect whether another live process currently holds the data dir open.
///
/// Bug 731 (adjacent finding): `geode user reset-password --data-dir /data` run
/// against a LIVE server opens a SECOND AuthGraphManager over the same store and
/// re-seals the HMAC chain out-of-process. The running server never sees the
/// write (so the "reset" password is rejected over the network), and the two
/// writers can clobber each other — a corrupted chain fails `verifyChain` at
/// startup and bricks authentication for EVERY user.
///
/// There is no data-dir lock in the tree to reuse (the only file lock is the
/// cluster-mode raft dir), and making the server take one is a startup-behaviour
/// change well outside this fix. Instead this probes `/proc` for another process
/// holding a file open under the data dir — which is exactly the `docker exec`
/// -into-a-live-container case the report describes. Returns the holder's pid,
/// or null when nothing holds it. The probe is best-effort: it returns null
/// (i.e. "no holder detected") on non-Linux, and skips any process whose
/// `/proc/<pid>/fd` is unreadable, so it can miss a holder owned by another
/// user — it never reports a false positive.
fn findDataDirHolderPid(allocator: std.mem.Allocator, data_dir: []const u8) ?std.c.pid_t {
    if (comptime builtin.os.tag != .linux) return null;

    const io = std.Io.Threaded.global_single_threaded.io();

    const abs_dir: []const u8 = blk: {
        if (std.fs.path.isAbsolute(data_dir)) break :blk allocator.dupe(u8, data_dir) catch return null;
        const cwd = std.process.currentPathAlloc(io, allocator) catch return null;
        defer allocator.free(cwd);
        break :blk std.fs.path.join(allocator, &.{ cwd, data_dir }) catch return null;
    };
    defer allocator.free(abs_dir);
    var prefix_len = abs_dir.len;
    while (prefix_len > 0 and abs_dir[prefix_len - 1] == '/') prefix_len -= 1;
    const prefix = abs_dir[0..prefix_len];
    if (prefix.len == 0) return null;

    const self_pid = std.c.getpid();

    var proc_dir = std.Io.Dir.openDirAbsolute(io, "/proc", .{ .iterate = true }) catch return null;
    defer proc_dir.close(io);

    var link_buf: [std.Io.Dir.max_path_bytes]u8 = undefined;
    var path_buf: [64]u8 = undefined;

    var it = proc_dir.iterate();
    while (true) {
        const maybe_entry = it.next(io) catch break;
        const entry = maybe_entry orelse break;
        const pid = std.fmt.parseInt(std.c.pid_t, entry.name, 10) catch continue;
        if (pid == self_pid) continue;

        const fd_path = std.fmt.bufPrint(&path_buf, "/proc/{d}/fd", .{pid}) catch continue;
        var fd_dir = std.Io.Dir.openDirAbsolute(io, fd_path, .{ .iterate = true }) catch continue;
        defer fd_dir.close(io);

        var fd_it = fd_dir.iterate();
        while (true) {
            const maybe_fd = fd_it.next(io) catch break;
            const fd_entry = maybe_fd orelse break;
            const n = fd_dir.readLink(io, fd_entry.name, &link_buf) catch continue;
            const target = link_buf[0..n];
            if (target.len > prefix.len and
                std.mem.startsWith(u8, target, prefix) and
                target[prefix.len] == '/')
            {
                return pid;
            }
        }
    }
    return null;
}

/// Refuse (or, with --force, loudly warn about) an offline auth-store mutation
/// while another process holds the data dir open. See `findDataDirHolderPid`.
fn guardOfflineAuthStoreWrite(
    allocator: std.mem.Allocator,
    data_dir: ?[]const u8,
    subcommand: []const u8,
    force: bool,
) void {
    const resolved = resolveDataDir(allocator, data_dir);
    defer allocator.free(resolved);
    const holder = findDataDirHolderPid(allocator, resolved) orelse return;

    std.debug.print(
        "Error: data dir '{s}' is already open by another process (pid {d}) — refusing to run 'user {s}' offline.\n",
        .{ resolved, holder, subcommand },
    );
    std.debug.print(
        "  An offline auth write against a LIVE server is unsafe: the running server never sees it (the new password is rejected over the network),\n" ++
            "  and the two writers can clobber each other's HMAC chain seal — a corrupted chain fails verification at startup and locks EVERY user out.\n",
        .{},
    );
    std.debug.print(
        "  Use the wire path instead: connect as the user and run  ALTER USER <username> SET PASSWORD '<new password>'  (or stop the server first).\n",
        .{},
    );
    if (!force) {
        std.debug.print("  Pass --force to override (accepting the corruption risk above).\n", .{});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    }
    std.debug.print("  --force given: proceeding anyway.\n", .{});
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

    // Help check ALSO covers `user <subcommand> --help` (e.g. `user create --help`)
    // — we must NOT open the auth store just to print help.
    if (hasHelpFlag(argv, subcmd_idx + 1)) {
        if (std.mem.eql(u8, subcommand, "mfa-setup")) {
            printMfaSetupHelp();
        } else if (std.mem.eql(u8, subcommand, "mfa-verify")) {
            printMfaVerifyHelp();
        } else if (std.mem.eql(u8, subcommand, "mfa")) {
            printMfaToggleHelp();
        } else {
            printUserUsage();
        }
        return;
    }

    // Open graph store for offline auth operations (after help check)
    const data_dir = extractDataDir(argv);
    // Bug 731 (adjacent finding): refuse to mutate the auth store out-of-process
    // while a live server holds the same data dir open.
    if (subcommandMutatesAuthStore(subcommand)) {
        guardOfflineAuthStoreWrite(allocator, data_dir, subcommand, hasFlag(argv, "--force"));
    }
    var mgr = cli_auth.initCliAuthManager(allocator, data_dir) catch |err| {
        std.debug.print("Error: Failed to initialize auth store: {}\n", .{err});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    defer cli_auth.deinitAndSaveCliAuth(allocator, &mgr);
    // SONNY-2798: verify the chain before a change, and seal the change.
    if (subcommandMutatesAuthStore(subcommand)) cli_auth.requireIntactChain(allocator, &mgr, "user", subcommand);

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
        var role_given = false;
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
                role_given = true;
                i += 1;
            } else if (!std.mem.startsWith(u8, argv[i], "--") and password == null and i == subcmd_idx + 3) {
                // Allow password as positional 3rd arg for backward compatibility
                password = argv[i];
                password_is_default = false;
            }
        }

        requireBuiltinRoleOrExit(role);

        // GAP-0154 FIX: Production build password handling
        var generated_pw: cli_auth.GeneratedPassword = .{};
        const final_password: []const u8 = blk: {
            if (password) |pw| {
                // Explicit password provided
                if (pw.len == 0) {
                    std.debug.print("Error: password cannot be empty\n", .{});
                    std.process.exit(@intFromEnum(ExitCode.general_error));
                }
                if (cli_auth.passwordPolicyError(pw)) |reason| {
                    std.debug.print("Error: password does not meet the password policy: {s}\n", .{reason});
                    std.process.exit(@intFromEnum(ExitCode.general_error));
                }
                break :blk pw;
            }
            if (generate_password) {
                // Generate random password
                generated_pw = try generateSecurePassword();
                std.debug.print("Generated password: {s}\n", .{generated_pw.slice()});
                break :blk generated_pw.slice();
            }
            // All builds require explicit password
            std.debug.print("Error: --password or --generate-password is required\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        };

        // SONNY-6358: stored as the server stores it, never the password.
        const password_hash = hashPasswordOrExit(allocator, final_password);
        defer allocator.free(password_hash);

        // Check if user already exists
        if (mgr.storage.getUserByUsername(username)) |existing| {
            // Update existing user
            try mgr.storage.updateUser(existing.id, email, null, null, null, null);
            setStoredPasswordOrExit(allocator, &mgr, existing.id, username, password_hash);
            if (role_given) assignRoleOrExit(allocator, &mgr, username, role);
        } else {
            // Create new user via storage
            const user_id = mgr.next_user_id;
            mgr.next_user_id += 1;
            try mgr.storage.persistUser(user_id, username, email, password_hash, "");
            // SONNY-6367: the role (`user` when none is given, as CREATE
            // USER gives); a role node used to be stored and never assigned.
            assignRoleOrExit(allocator, &mgr, username, role);
        }
        printOut("User '{s}' created successfully\n", .{username});
        return;
    }

    // `user import <username> --hash <hash> [--email <e>] [--algorithm <a>] [--role <r>]`
    // Imports a user with a PRE-COMPUTED password hash rather than a
    // plaintext password. Intended for migrating users from another system
    // (e.g. a legacy store carrying BLAKE2b hashes). The hash is stored
    // verbatim in the __geode_security graph's password_hash column; no
    // re-hashing occurs. This is the offline counterpart to `user create`.
    // CANARY: REQ=REQ-AUTH-USER-IMPORT-001; FEATURE="AdminUserImport"; ASPECT=PrecomputedHashImport; STATUS=TESTED; TEST=geode-test-harness/geodetestlab-cli/specs/authn_blake2b_migration.yml; OWNER=security; UPDATED=2026-05-22
    if (std.mem.eql(u8, subcommand, "import")) {
        if (subcmd_idx + 1 >= argv.len) {
            std.debug.print("Error: user import requires <username> and --hash <hash>\n", .{});
            printUserUsage();
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
        const username = argv[subcmd_idx + 1];
        var hash_value: ?[]const u8 = null;
        var email: []const u8 = "";
        var role: []const u8 = "user";
        var algorithm: []const u8 = "argon2id";

        var i = subcmd_idx + 2;
        while (i < argv.len) : (i += 1) {
            if (std.mem.eql(u8, argv[i], "--hash")) {
                if (i + 1 >= argv.len) {
                    std.debug.print("Error: --hash requires a value\n", .{});
                    std.process.exit(@intFromEnum(ExitCode.usage_error));
                }
                hash_value = argv[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, argv[i], "--email")) {
                if (i + 1 >= argv.len) {
                    std.debug.print("Error: --email requires a value\n", .{});
                    std.process.exit(@intFromEnum(ExitCode.usage_error));
                }
                email = argv[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, argv[i], "--role")) {
                if (i + 1 >= argv.len) {
                    std.debug.print("Error: --role requires a value\n", .{});
                    std.process.exit(@intFromEnum(ExitCode.usage_error));
                }
                role = argv[i + 1];
                i += 1;
            } else if (std.mem.eql(u8, argv[i], "--algorithm")) {
                if (i + 1 >= argv.len) {
                    std.debug.print("Error: --algorithm requires a value\n", .{});
                    std.process.exit(@intFromEnum(ExitCode.usage_error));
                }
                algorithm = argv[i + 1];
                i += 1;
            }
        }

        if (hash_value == null or hash_value.?.len == 0) {
            std.debug.print("Error: user import requires a non-empty --hash <hash>\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
        if (!std.mem.eql(u8, algorithm, "argon2id") and !std.mem.eql(u8, algorithm, "blake2b")) {
            std.debug.print("Error: --algorithm must be 'argon2id' or 'blake2b'\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }

        // FIPS: reject both argon2id and blake2b algorithm imports under FIPS — neither is FIPS-approved
        if (build_options.fips) {
            std.debug.print("Error: user import with '--algorithm {s}' is unavailable under FIPS mode (argon2id and blake2b are not FIPS-approved primitives)\n", .{algorithm});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        }

        requireBuiltinRoleOrExit(role);

        if (mgr.storage.getUserByUsername(username) != null) {
            std.debug.print("Error: user '{s}' already exists; import refuses to overwrite\n", .{username});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        }

        const user_id = mgr.next_user_id;
        mgr.next_user_id += 1;
        mgr.storage.persistUser(user_id, username, email, hash_value.?, "") catch |err| {
            std.debug.print("Error: failed to import user '{s}': {s}\n", .{ username, @errorName(err) });
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };
        assignRoleOrExit(allocator, &mgr, username, role);
        printOut("User '{s}' imported successfully ({s} hash)\n", .{ username, algorithm });
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
            printOut("- {s} (role: {s})\n", .{ record.getUsername(), storedRoleName(&mgr, record.*) });
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
                storedRoleName(&mgr, u),
                if (u.is_active) "active" else "disabled",
            });
        } else {
            // SONNY-6367: it printed made-up details and exited 0.
            std.debug.print("Error: user '{s}' not found\n", .{username});
            std.process.exit(@intFromEnum(ExitCode.general_error));
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
        // SONNY-6352: a removal that fails is reported (it was dropped, and
        // the user reported deleted while it stayed stored).
        const outcome = cli_auth.removeUserByName(&mgr, username) catch |err| {
            std.debug.print("Error: failed to delete user '{s}': {s} — the user was NOT deleted\n", .{ username, @errorName(err) });
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };
        switch (outcome) {
            .removed => printOut("User '{s}' deleted\n", .{username}),
            .not_found => {
                std.debug.print("Error: user '{s}' not found\n", .{username});
                std.process.exit(@intFromEnum(ExitCode.general_error));
            },
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
            if (cli_auth.passwordPolicyError(pw)) |reason| {
                std.debug.print("Error: password does not meet the password policy: {s}\n", .{reason});
                std.process.exit(@intFromEnum(ExitCode.general_error));
            }
        }
        if (new_role) |nr| {
            requireBuiltinRoleOrExit(nr);
            // SONNY-6369: before anything is changed.
            requireRoleTakesEffectOrExit(&mgr, username, nr);
        }

        if (mgr.storage.getUserByUsername(username)) |existing| {
            if (new_email != null) try mgr.storage.updateUser(existing.id, new_email, null, null, null, null);
            // SONNY-6358: the hash, through the resealing seam.
            if (new_password) |pw| {
                const password_hash = hashPasswordOrExit(allocator, pw);
                defer allocator.free(password_hash);
                setStoredPasswordOrExit(allocator, &mgr, existing.id, username, password_hash);
            }
            // SONNY-6367: assigned (a role node used to be stored and never
            // given to the user).
            if (new_role) |nr| assignRoleOrExit(allocator, &mgr, username, nr);
        } else {
            // User doesn't exist - create
            if (new_password == null) {
                std.debug.print("Error: --password is required to create new user\n", .{});
                std.process.exit(@intFromEnum(ExitCode.usage_error));
            }
            const pw = new_password.?;
            if (cli_auth.passwordPolicyError(pw)) |reason| {
                std.debug.print("Error: password does not meet the password policy: {s}\n", .{reason});
                std.process.exit(@intFromEnum(ExitCode.general_error));
            }
            // SONNY-6358: stored as the server stores it, never the password.
            const password_hash = hashPasswordOrExit(allocator, pw);
            defer allocator.free(password_hash);
            const user_id = mgr.next_user_id;
            mgr.next_user_id += 1;
            try mgr.storage.persistUser(user_id, username, new_email orelse "unknown@example.com", password_hash, "");
            assignRoleOrExit(allocator, &mgr, username, new_role orelse "user");
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
        requireBuiltinRoleOrExit(role);
        if (mgr.storage.getUserByUsername(username) == null) {
            std.debug.print("Error: user '{s}' not found; no role was assigned\n", .{username});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        }
        // SONNY-6367: the HAS_ROLE edge, as ALTER USER ... SET ROLE stores
        // it (only a role node was stored, and success printed).
        assignRoleOrExit(allocator, &mgr, username, role);
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
        // SONNY-6367: a missing user is an error (it printed success).
        const existing = mgr.storage.getUserByUsername(username) orelse {
            std.debug.print("Error: user '{s}' not found; nothing was {s}\n", .{ username, if (enable) "enabled" else "disabled" });
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };
        try mgr.storage.updateUser(existing.id, null, null, enable, null, null);
        printOut("User '{s}' {s}\n", .{ username, if (enable) "enabled" else "disabled" });
        return;
    }

    // CANARY: REQ=REQ-MFA-SETUP-REAL-001; FEATURE="MFARealEnrollment"; ASPECT=Security; STATUS=TESTED; TEST=geodetestlab/specs/mfa_comprehensive_security.yml; OWNER=cli; UPDATED=2026-01-29
    if (std.mem.eql(u8, subcommand, "mfa-setup")) {
        // Handle --help flag
        if (hasHelpFlag(argv, subcmd_idx + 1)) {
            printMfaSetupHelp();
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
            printMfaVerifyHelp();
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
            printMfaToggleHelp();
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
        var generated_pw: cli_auth.GeneratedPassword = .{};
        const final_new: []const u8 = blk: {
            if (new_pw) |pw| {
                break :blk pw;
            }
            if (generate_password) {
                generated_pw = try generateSecurePassword();
                std.debug.print("Generated password: {s}\n", .{generated_pw.slice()});
                break :blk generated_pw.slice();
            }
            std.debug.print("Error: --new-password is required\n", .{});
            std.debug.print("Use --new-password <password> or --generate-password\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        };
        if (cli_auth.passwordPolicyError(final_new)) |reason| {
            std.debug.print("Error: password does not meet the password policy: {s}\n", .{reason});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        }
        // Verify old password if provided. Bug 731 (adjacent finding): this
        // used to compare Blake2(stored_field) against Blake2(plaintext), which
        // only ever matched when the stored field WAS the plaintext — see the
        // write below. Verify against the real Argon2id hash instead.
        if (old_pw) |old| {
            if (mgr.storage.getUserByUsername(username)) |existing| {
                const stored = existing.getPasswordHash();
                // SONNY-6367: the login's verifier (a BLAKE2b import too).
                const ok = geode.user_management.verifyPassword(old, stored) catch false;
                if (!ok) {
                    std.debug.print("Error: old password is incorrect\n", .{});
                    std.process.exit(@intFromEnum(ExitCode.general_error));
                }
            }
        }
        // Review-0016 Important-2 (same bug family as reset-password): the
        // success message used to print UNCONDITIONALLY, so a missing /
        // unloadable user silently no-op'd while still reporting success.
        // Report failure honestly with a nonzero exit instead.
        const existing = mgr.storage.getUserByUsername(username) orelse {
            std.debug.print("Error: user '{s}' not found in the auth store — password NOT changed\n", .{username});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };
        // Bug 731 (adjacent finding): this used to pass the PLAINTEXT password
        // straight into the `password_hash` field of `updateUser` — storing the
        // credential in the clear AND leaving the per-record HMAC and chain seal
        // stale, so the next server start failed `verifyChain` with
        // error.AuthChainTampered. Go through the same resealing seam
        // reset-password uses (which also clears password_reset_required).
        const kr_dir = resolveDataDir(allocator, data_dir);
        defer allocator.free(kr_dir);
        var kr = auth_graph_manager_mod.AuthGraphManager.resolveHmacKey(allocator, kr_dir) catch {
            std.debug.print("Error: could not resolve HMAC key (set GEODE_AUTH_HMAC_KEY/GEODE_TDE_KEY or place .geode_hmac_key in the data dir)\n", .{});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };
        const password_hash = try geode_auth.hashPasswordArgon2id(allocator, final_new);
        defer allocator.free(password_hash);
        _ = mgr.updateUserPassword(&kr.key, existing.id, password_hash) catch |err| {
            std.debug.print("Error: failed to persist the new password for user '{s}': {s} — password NOT changed\n", .{ username, @errorName(err) });
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };
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
        var generated_pw: cli_auth.GeneratedPassword = .{};
        const final_new: []const u8 = blk: {
            if (new_pw) |pw| {
                break :blk pw;
            }
            if (generate_password) {
                generated_pw = try generateSecurePassword();
                std.debug.print("Generated password: {s}\n", .{generated_pw.slice()});
                break :blk generated_pw.slice();
            }
            std.debug.print("Error: --new-password is required\n", .{});
            std.debug.print("Use --new-password <password> or --generate-password\n", .{});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        };
        if (cli_auth.passwordPolicyError(final_new)) |reason| {
            std.debug.print("Error: password does not meet the password policy: {s}\n", .{reason});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        }
        // Review-0016 Important-2: `reset-password` is the DOCUMENTED escape
        // hatch for the fail-closed admin-bootstrap refusal (see
        // auth_init_cli.zig and the [startup] breadcrumbs). It used to print
        // "Password reset for user 'X'" UNCONDITIONALLY — even when the user
        // could not be loaded at all — so in exactly the degraded state where
        // the operator needs it, it silently no-op'd while reporting success.
        // Report failure honestly (stderr + nonzero exit) and add an
        // engine-direct diagnostic so the operator can tell "no such user"
        // apart from "records exist on disk but could not be loaded".
        const existing = mgr.storage.getUserByUsername(username) orelse {
            std.debug.print("Error: user '{s}' not found in the auth store — password NOT reset\n", .{username});
            if (auth_graph_manager_mod.persistedSecurityUserCountOnDisk()) |persisted| {
                if (persisted > 0) {
                    std.debug.print("Note: {d} persisted user record(s) exist in __geode_security but could not be loaded — the auth store is degraded or half-bootstrapped. If the store was half-bootstrapped (a crash during first boot), restart the server (or run 'geode auth init') to re-seed the admin; otherwise repair the storage before resetting passwords.\n", .{persisted});
                }
            } else |_| {
                std.debug.print("Note: the storage engine reported an error while checking __geode_security — the auth store looks degraded; repair the storage before resetting passwords.\n", .{});
            }
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };
        // Resolve the HMAC signing key the SAME way the server does so the
        // chain stays single-source-of-truth. Without this, mgr.storage
        // mutates the user record but the per-record HMAC + chain seal
        // never get re-signed, and the next server start fails with
        // error.AuthChainTampered (verifyChain at server_init.zig:314).
        // `resolveDataDir` mirrors initCliAuthManager's data_dir fallback so
        // .geode_hmac_key is found in the default data directory when
        // --data-dir is omitted.
        const resolved_data_dir = resolveDataDir(allocator, data_dir);
        defer allocator.free(resolved_data_dir);
        var kr = auth_graph_manager_mod.AuthGraphManager.resolveHmacKey(allocator, resolved_data_dir) catch {
            std.debug.print("Error: could not resolve HMAC key (set GEODE_AUTH_HMAC_KEY/GEODE_TDE_KEY or place .geode_hmac_key in the data dir)\n", .{});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };
        const password_hash = try geode_auth.hashPasswordArgon2id(allocator, final_new);
        defer allocator.free(password_hash);
        _ = mgr.updateUserPassword(&kr.key, existing.id, password_hash) catch |err| {
            std.debug.print("Error: failed to persist the new password for user '{s}': {s} — password NOT reset\n", .{ username, @errorName(err) });
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };
        // The password_reset_required clear used to be open-coded here, followed
        // by a SECOND updateUserPassword to re-seal — which advanced the durable
        // auth_version twice for one reset (bug 731-4c, in miniature). The clear
        // now lives in AuthGraphManager.updateUserPassword itself (bug 731-4a),
        // so every password-change path — wire, procedure and offline CLI —
        // agrees and one reset performs exactly one durable write.
        if (mgr.storage.getUser(existing.id)) |record| {
            if (record.password_reset_required) {
                std.debug.print("Error: the forced-reset flag survived the password reset for user '{s}' — verify with 'geode user show {s}'\n", .{ username, username });
                std.process.exit(@intFromEnum(ExitCode.general_error));
            }
        } else {
            std.debug.print("Error: user '{s}' vanished from the auth cache mid-reset — verify the reset with 'geode user show {s}'\n", .{ username, username });
            std.process.exit(@intFromEnum(ExitCode.general_error));
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
    // Help / missing-subcommand checks BEFORE opening the auth store —
    // these paths must not require any disk I/O (graph_storage_adapter
    // would otherwise open the default data directory).
    if (start_idx + 1 >= argv.len) {
        std.debug.print("Error: missing role subcommand\n", .{});
        printRoleUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }
    const subcommand = argv[start_idx + 1];
    if (std.mem.eql(u8, subcommand, "--help") or std.mem.eql(u8, subcommand, "-h")) {
        printRoleUsage();
        return;
    }
    if (hasHelpFlag(argv, start_idx + 2)) {
        printRoleUsage();
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
    if (std.mem.eql(u8, subcommand, "create") or std.mem.eql(u8, subcommand, "delete")) {
        cli_auth.requireIntactChain(allocator, &mgr, "role", subcommand);
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

        // SONNY-6367: under a new role id, as CREATE ROLE stores it
        // (`AuthGraphManager.createRole`, idempotent). It took `next_user_id`
        // (the next *user* id) as the role id, which can be an existing
        // role's id: that role's record was overwritten, and the users given
        // it held the new role instead.
        const key = cli_auth.changeKey(allocator) catch |err| {
            std.debug.print("Error: no HMAC key to seal the new role with ({s}); role NOT created\n", .{@errorName(err)});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };
        _ = mgr.createRole(&key, rolename, description) catch |err| {
            std.debug.print("Error: failed to create role '{s}': {s} — role NOT created\n", .{ rolename, @errorName(err) });
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };
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
        // SONNY-6352: a removal that fails is reported (it was dropped).
        const outcome = cli_auth.removeRoleByName(&mgr, rolename) catch |err| {
            std.debug.print("Error: failed to delete role '{s}': {s} — the role was NOT deleted\n", .{ rolename, @errorName(err) });
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };
        printOut("Role '{s}' {s}\n", .{ rolename, if (outcome == .removed) "deleted" else "not found (noop)" });
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
