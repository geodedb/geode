// CANARY: REQ=REQ-AUTH-INIT-CLI-001; FEATURE="AuthInitCLI"; ASPECT=OfflineAuthManagement; STATUS=TESTED; TEST=geodetestlab/specs/auth_chain_cli_offline.yml; OWNER=cli; UPDATED=2026-06-11
//! Offline CLI commands for managing auth chain integrity.
//!
//! Provides:
//! - `geode auth init --data-dir <path>`    Bootstrap admin user into graph store
//! - `geode auth reseal --data-dir <path>`  Recompute HMAC chain
//! - `geode auth verify --data-dir <path>`  Check HMAC chain integrity

const std = @import("std");
const cli_auth = @import("cli_auth_helpers.zig");
const AuthGraphManager = cli_auth.AuthGraphManager;
const auth_graph_manager = @import("auth_graph_manager");
// SONNY-2778: `writeAdminPasswordFile`, shared with the server and SecurityManager.
const geode_auth = @import("geode_auth");

// Zig 0.16 compat: std.process.getEnvVarOwned was removed.  Mirrors the
// shim used in src/server/server_init.zig and src/cli/cli_auth_helpers.zig.
fn getEnvVarOwned(allocator: std.mem.Allocator, name: []const u8) error{ EnvironmentVariableNotFound, OutOfMemory }![]u8 {
    const name_z = allocator.dupeZ(u8, name) catch return error.OutOfMemory;
    defer allocator.free(name_z);
    const ptr = std.c.getenv(name_z) orelse return error.EnvironmentVariableNotFound;
    return allocator.dupe(u8, std.mem.span(ptr));
}

const ExitCode = enum(u8) {
    success = 0,
    general_error = 1,
    usage_error = 2,
};

/// Parse --data-dir from argv starting at start_idx.
fn parseDataDirFlag(argv: [][:0]u8, start_idx: usize) ?[]const u8 {
    var i = start_idx;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--data-dir") and i + 1 < argv.len) {
            return argv[i + 1];
        }
    }
    return null;
}

fn hasHelpFlag(argv: [][:0]u8, start_idx: usize) bool {
    var i = start_idx;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "--help") or std.mem.eql(u8, argv[i], "-h")) return true;
    }
    return false;
}

// -- geode auth init --

/// Whether GEODE_ADMIN_PASSWORD or GEODE_DEFAULT_PASSWORD seeds the admin's
/// password (the bootstrap's precedence). Then no password is generated, and
/// none is written to a file.
fn adminPasswordFromEnv(allocator: std.mem.Allocator) bool {
    for ([_][]const u8{ "GEODE_ADMIN_PASSWORD", "GEODE_DEFAULT_PASSWORD" }) |name| {
        if (getEnvVarOwned(allocator, name)) |value| {
            allocator.free(value);
            return true;
        } else |_| {}
    }
    return false;
}

/// The data directory `initCliAuthManager` resolved (SONNY-6345:
/// `cli_auth.resolveCliDataDir`): a generated password's file goes there
/// (SONNY-2778), and the HMAC key is looked up there.
fn resolvedDir(data_dir: ?[]const u8) ?[]const u8 {
    return cli_auth.resolvedDataDir() orelse data_dir;
}

fn printAuthInitUsage() void {
    std.debug.print(
        "geode auth init - Bootstrap admin user into graph store (offline)\n" ++
            "\n" ++
            "Usage: geode auth init [options]\n" ++
            "\n" ++
            "Options:\n" ++
            "  --data-dir <path>    Data directory (default: GEODE_DATA_DIR, else the server's default: $XDG_STATE_HOME/geode or ~/.local/state/geode)\n" ++
            "  -h, --help           Show this help\n" ++
            "\n" ++
            "Creates the default admin user and HMAC chain root for a fresh install.\n" ++
            "Fails if auth records already exist; use 'geode auth reseal' to recompute.\n" ++
            "\n" ++
            "HMAC key resolution (first match wins):\n" ++
            "  1. GEODE_AUTH_HMAC_KEY env var (64-char hex)\n" ++
            "  2. GEODE_TDE_KEY env var (derived via HKDF)\n" ++
            "  3. .geode_hmac_key file in data directory (32 raw bytes)\n" ++
            "\n" ++
            "Examples:\n" ++
            "  geode auth init --data-dir /var/lib/geode\n" ++
            "  GEODE_AUTH_HMAC_KEY=<hex> geode auth init\n" ++
            "\n",
        .{},
    );
}

/// Bootstrap admin user into graph store (offline).
pub fn cmdAuthInit(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    if (hasHelpFlag(argv, start_idx)) {
        printAuthInitUsage();
        return;
    }

    const data_dir = parseDataDirFlag(argv, start_idx);

    // SONNY-6345: init bootstraps a store, so it creates the data directory
    // (as `geode serve` does, GAP-0909) before the data-dir lock is taken in
    // it; the server's default directory does not exist before first use.
    {
        const dir = cli_auth.resolveCliDataDir(allocator, data_dir) catch |err| {
            std.debug.print("Error: Failed to resolve the data directory: {s}\n", .{@errorName(err)});
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };
        defer allocator.free(dir);
        cli_auth.graph_store.ensureDataDir(dir) catch |err| {
            std.debug.print("Error: Failed to create the data directory {s}: {s}\n", .{ dir, @errorName(err) });
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };
    }

    var mgr = cli_auth.initCliAuthManager(allocator, data_dir) catch |err| {
        std.debug.print("Error: Failed to initialize auth store: {s}\n", .{@errorName(err)});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    defer cli_auth.deinitAndSaveCliAuth(allocator, &mgr);
    // SONNY-2798: a store that already has records must verify (the
    // bootstrap below refuses it anyway; this says why when it is tampered).
    cli_auth.requireIntactChain(allocator, &mgr, "auth", "init");

    // Resolve HMAC key
    const kr = auth_graph_manager.AuthGraphManager.resolveHmacKey(allocator, resolvedDir(data_dir)) catch |err| {
        std.debug.print("Error: Failed to resolve HMAC key: {s}\n", .{@errorName(err)});
        std.debug.print("Set GEODE_AUTH_HMAC_KEY or GEODE_TDE_KEY, or create .geode_hmac_key in the data directory.\n", .{});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };

    // Check if records already exist
    if (mgr.hasAuthRecords()) {
        std.debug.print("Error: Auth records already exist. Use 'geode auth reseal' to recompute chain.\n", .{});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    }

    // SONNY-2778: a generated password is written to a new file only. When
    // something is already at the path, refuse now, before the admin is
    // created with a password that could not be recorded.
    if (!adminPasswordFromEnv(allocator)) {
        const dir_path = resolvedDir(data_dir).?;
        if (geode_auth.adminPasswordFilePresent(dir_path)) {
            std.debug.print(
                "Error: {s}/.geode_admin_password already exists. The generated admin password is written to a new file,\n" ++
                    "and an existing file (or symbolic link) at that path is never overwritten. Read it and remove it,\n" ++
                    "or set GEODE_ADMIN_PASSWORD, then re-run 'geode auth init'. The admin user was not created.\n",
                .{dir_path},
            );
            std.process.exit(@intFromEnum(ExitCode.general_error));
        }
    }

    // Bootstrap
    const result = mgr.bootstrapDefaultAdmin(&kr.key) catch |err| {
        if (err == error.PersistedAdminExists) {
            // Persisted-credential precedence (2026-07-01 incident guard):
            // the in-memory load saw no records, but the engine still holds
            // persisted :User records on disk. Refuse to re-seed — the
            // persisted credential wins over any env password.
            std.debug.print(
                "Error: Persisted admin records exist on disk (in-memory load was empty).\n" ++
                    "Refusing to re-seed the admin credential from the environment.\n" ++
                    "Run 'geode auth verify' to check chain health, or rotate via 'geode user reset-password'.\n",
                .{},
            );
            std.process.exit(@intFromEnum(ExitCode.general_error));
        }
        std.debug.print("Error: Failed to bootstrap admin user: {s}\n", .{@errorName(err)});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    // GAP-0514 Phase 6: BootstrapResult strings are caller-owned (username is
    // duped, password is env-duped or generated) — free them or the
    // DebugAllocator reports a leak on every `geode auth init`.
    defer allocator.free(result.username);
    defer allocator.free(result.password);

    // Issue #819 (CWE-200 information disclosure / CWE-538 file/dir info
    // exposure): never echo the bootstrap password to stdout.  Mirror the
    // server-init path -- when neither `GEODE_ADMIN_PASSWORD` nor
    // `GEODE_DEFAULT_PASSWORD` is set, write the generated value to
    // `<data_dir>/.geode_admin_password` at mode 0o600 and surface only a
    // pointer.  When an env var seeded the password the operator already
    // has the plaintext; we just confirm the user was created.
    if (adminPasswordFromEnv(allocator)) {
        std.debug.print(
            "Admin user created: {s}\n" ++
                "Password sourced from GEODE_ADMIN_PASSWORD / GEODE_DEFAULT_PASSWORD env (not echoed).\n" ++
                "WARNING: Rotate this password immediately after first login.\n",
            .{result.username},
        );
        return;
    }

    // No env-supplied password: the data directory initCliAuthManager used,
    // so the pointer message matches the file we write.
    const pw_dir_path = resolvedDir(data_dir).?;

    // SONNY-2778: O_CREAT|O_EXCL|O_NOFOLLOW, mode 0600, never over an
    // existing file (`geode_auth.writeAdminPasswordFile`). It truncated
    // whatever was at the path, keeping its mode and following a symlink.
    // The check before the bootstrap refuses an occupied path; this refuses
    // one that appeared since.
    if (geode_auth.writeAdminPasswordFile(allocator, pw_dir_path, result.password)) |pw_path| {
        defer allocator.free(pw_path);
        std.debug.print(
            "Admin user created: {s}\n" ++
                "Bootstrap password written to: {s} (mode 0600, read once; rotate immediately).\n" ++
                "WARNING: Move this file to secure storage and delete after first login.\n",
            .{ result.username, pw_path },
        );
    } else |err| {
        std.debug.print(
            "Error: Failed to create bootstrap password file {s}/.geode_admin_password: {s}\n" ++
                "An existing file (or symbolic link) at that path is never overwritten. Remove it after reading it, then rotate\n" ++
                "the admin password via 'geode user reset-password', or set GEODE_ADMIN_PASSWORD before re-running 'geode auth init'.\n",
            .{ pw_dir_path, @errorName(err) },
        );
        std.process.exit(@intFromEnum(ExitCode.general_error));
    }
}

// -- geode auth reseal --

fn printAuthResealUsage() void {
    std.debug.print(
        "geode auth reseal - Recompute HMAC chain (offline)\n" ++
            "\n" ++
            "Usage: geode auth reseal [options]\n" ++
            "\n" ++
            "Options:\n" ++
            "  --data-dir <path>    Data directory (default: GEODE_DATA_DIR, else the server's default: $XDG_STATE_HOME/geode or ~/.local/state/geode)\n" ++
            "  --accept-legacy-policy <id>\n" ++
            "                       Sign this policy record although it has no kind and\n" ++
            "                       its HMAC does not verify (repeat for each record)\n" ++
            "  --drop-legacy-policy <id>\n" ++
            "                       Delete this policy record, which has no kind and whose\n" ++
            "                       HMAC does not verify (repeat for each record)\n" ++
            "  -h, --help           Show this help\n" ++
            "\n" ++
            "Recomputes all per-record HMACs and the chain root hash.\n" ++
            "Use after legitimate manual intervention (e.g. direct graph edits).\n" ++
            "A policy record written before record kinds existed, whose HMAC does not\n" ++
            "verify, is refused: it may have been planted, and GPS would load it by its\n" ++
            "shape. Check each one, then drop it or accept it by id.\n" ++
            "\n" ++
            "Examples:\n" ++
            "  geode auth reseal --data-dir /var/lib/geode\n" ++
            "\n",
        .{},
    );
}

/// Recompute HMAC chain after legitimate manual intervention.
pub fn cmdAuthReseal(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    if (hasHelpFlag(argv, start_idx)) {
        printAuthResealUsage();
        return;
    }

    const data_dir = parseDataDirFlag(argv, start_idx);

    var mgr = cli_auth.initCliAuthManager(allocator, data_dir) catch |err| {
        std.debug.print("Error: Failed to initialize auth store: {s}\n", .{@errorName(err)});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    defer cli_auth.deinitAndSaveCliAuth(allocator, &mgr);

    // Resolve HMAC key
    const kr = auth_graph_manager.AuthGraphManager.resolveHmacKey(allocator, resolvedDir(data_dir)) catch |err| {
        std.debug.print("Error: Failed to resolve HMAC key: {s}\n", .{@errorName(err)});
        std.debug.print("Set GEODE_AUTH_HMAC_KEY or GEODE_TDE_KEY, or create .geode_hmac_key in the data directory.\n", .{});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };

    // SONNY-2791: the operator's decisions for the policy records that have no
    // kind and whose HMAC does not verify: sign (accept) or delete (drop).
    var accept: std.ArrayList(u64) = .empty;
    defer accept.deinit(allocator);
    var drop: std.ArrayList(u64) = .empty;
    defer drop.deinit(allocator);
    var ai = start_idx;
    while (ai < argv.len) : (ai += 1) {
        const list = if (std.mem.eql(u8, argv[ai], "--accept-legacy-policy"))
            &accept
        else if (std.mem.eql(u8, argv[ai], "--drop-legacy-policy"))
            &drop
        else
            continue;
        if (ai + 1 >= argv.len) {
            std.debug.print("Error: {s} requires a policy record id\n", .{argv[ai]});
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        }
        const id = std.fmt.parseInt(u64, argv[ai + 1], 10) catch {
            std.debug.print("Error: {s} takes a policy record id, not '{s}'\n", .{ argv[ai], argv[ai + 1] });
            std.process.exit(@intFromEnum(ExitCode.usage_error));
        };
        try list.append(allocator, id);
        ai += 1;
    }

    // Seal chain (SONNY-2791: refusing unsigned legacy policy records)
    mgr.resealChain(&kr.key, .{ .accept = accept.items, .drop = drop.items }) catch |err| {
        if (err == error.UnsignedLegacyPolicyRecord) {
            std.debug.print("Error: refusing to reseal: policy records without a kind do not verify and may have been planted (their ids are in the log). Check each one, then re-run with --drop-legacy-policy <id> (delete it) or --accept-legacy-policy <id> (sign it).\n", .{});
        } else if (err == error.ConflictingLegacyPolicyDecision) {
            std.debug.print("Error: a policy record id is given to both --accept-legacy-policy and --drop-legacy-policy\n", .{});
        } else {
            std.debug.print("Error: Failed to reseal chain: {s}\n", .{@errorName(err)});
        }
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };

    const record_count = mgr.countAuthRecords();
    std.debug.print("HMAC chain resealed successfully ({d} records).\n", .{record_count});
}

// -- geode auth verify --

fn printAuthVerifyUsage() void {
    std.debug.print(
        "geode auth verify - Check HMAC chain integrity (offline)\n" ++
            "\n" ++
            "Usage: geode auth verify [options]\n" ++
            "\n" ++
            "Options:\n" ++
            "  --data-dir <path>    Data directory (default: GEODE_DATA_DIR, else the server's default: $XDG_STATE_HOME/geode or ~/.local/state/geode)\n" ++
            "  -h, --help           Show this help\n" ++
            "\n" ++
            "Verifies per-record HMACs and the chain root hash.\n" ++
            "Exits 0 on success, 1 on integrity failure or when the data directory has no auth state.\n" ++
            "\n" ++
            "Examples:\n" ++
            "  geode auth verify --data-dir /var/lib/geode\n" ++
            "\n",
        .{},
    );
}

/// Check HMAC chain integrity without starting the server.
pub fn cmdAuthVerify(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    if (hasHelpFlag(argv, start_idx)) {
        printAuthVerifyUsage();
        return;
    }

    const data_dir = parseDataDirFlag(argv, start_idx);

    // CANARY: REQ=REQ-SONNY-6345-AUTH-VERIFY-NO-STATE; FEATURE="OfflineAuthStoreSafety"; ASPECT=VerifyCreatesNothing; STATUS=TESTED; TEST=tests/test_sonny6345_auth_cli_and_grant.zig; OWNER=security; UPDATED=2026-11-12
    // SONNY-6345: a directory with no security graph has no auth state to
    // verify. Opening it created the directory, the registry, a lock file
    // and `__geode_security`, and reported "0 records, integrity OK"
    // (exit 0). It is checked first, reading the registry only, and
    // reported as a failure with nothing created.
    const resolved = cli_auth.resolveCliDataDir(allocator, data_dir) catch |err| {
        std.debug.print("Error: Failed to resolve the data directory: {s}\n", .{@errorName(err)});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    // SONNY-6359: it leaked (initCliAuthManager keeps its own copy).
    defer allocator.free(resolved);
    const has_state = cli_auth.hasAuthState(allocator, resolved) catch |err| {
        std.debug.print("Error: Failed to read the graph registry in {s}: {s}\n", .{ resolved, @errorName(err) });
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    if (!has_state) {
        std.debug.print(
            "Error: no auth state in {s}: it has no __geode_security graph, so there is no HMAC chain to verify. Nothing was created.\n" ++
                "Pass the server's --data-dir (or set GEODE_DATA_DIR), or bootstrap one with 'geode auth init'.\n",
            .{resolved},
        );
        std.process.exit(@intFromEnum(ExitCode.general_error));
    }

    var mgr = cli_auth.initCliAuthManager(allocator, resolved) catch |err| {
        std.debug.print("Error: Failed to initialize auth store: {s}\n", .{@errorName(err)});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    // CANARY: REQ=REQ-SONNY-6359-AUTH-VERIFY-SAVES-NOTHING; FEATURE="OfflineAuthStoreSafety"; ASPECT=VerifyReadOnlyTeardown; STATUS=TESTED; TEST=tests/test_sonny6359_auth_residuals.zig; OWNER=security; UPDATED=2026-11-12
    // SONNY-6359: a verify changes nothing, so it does not take the save path
    // of a changing command (seal, saveIfDirty).
    defer cli_auth.deinitCliAuthWithoutSaving(allocator, &mgr);

    // SONNY-3035: an empty store (no records, no chain root) verifies with
    // no key; otherwise the key is looked up, never generated: a key made up
    // now cannot verify an existing chain, and verifying wrote it.
    if (mgr.countAuthRecords() == 0 and (try mgr.storage.loadChainRoot()) == null) {
        std.debug.print("HMAC chain verified: 0 records, integrity OK.\n", .{});
        return;
    }
    const kr = auth_graph_manager.AuthGraphManager.resolveExistingHmacKey(allocator, resolved) catch |err| {
        std.debug.print("Error: Failed to resolve HMAC key: {s}\n", .{@errorName(err)});
        std.debug.print("Set GEODE_AUTH_HMAC_KEY or GEODE_TDE_KEY, or place the store's .geode_hmac_key in the data directory.\n", .{});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };

    // Verify chain
    mgr.verifyChain(&kr.key) catch |err| {
        std.debug.print("HMAC chain verification FAILED: {s}\n", .{@errorName(err)});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };

    const record_count = mgr.countAuthRecords();
    std.debug.print("HMAC chain verified: {d} records, integrity OK.\n", .{record_count});
}

// -- Tests --

test "parseDataDirFlag returns null when no --data-dir" {
    // Empty argv slice
    const argv: [][:0]u8 = &.{};
    try std.testing.expectEqual(@as(?[]const u8, null), parseDataDirFlag(argv, 0));
}

test "hasHelpFlag detects --help" {
    const buf1: [:0]u8 = @constCast("--help");
    var argv = [_][:0]u8{buf1};
    try std.testing.expect(hasHelpFlag(&argv, 0));
}

test "hasHelpFlag detects -h" {
    const buf1: [:0]u8 = @constCast("-h");
    var argv = [_][:0]u8{buf1};
    try std.testing.expect(hasHelpFlag(&argv, 0));
}

test "hasHelpFlag returns false when absent" {
    const buf1: [:0]u8 = @constCast("--data-dir");
    const buf2: [:0]u8 = @constCast("/tmp");
    var argv = [_][:0]u8{ buf1, buf2 };
    try std.testing.expect(!hasHelpFlag(&argv, 0));
}
