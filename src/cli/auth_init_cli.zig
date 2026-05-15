// CANARY: REQ=REQ-AUTH-INIT-CLI-001; FEATURE="AuthInitCLI"; ASPECT=OfflineAuthManagement; STATUS=IMPL; OWNER=cli; UPDATED=2026-02-24
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

fn printAuthInitUsage() void {
    std.debug.print(
        "geode auth init - Bootstrap admin user into graph store (offline)\n" ++
            "\n" ++
            "Usage: geode auth init [options]\n" ++
            "\n" ++
            "Options:\n" ++
            "  --data-dir <path>    Data directory (default: GEODE_DATA_DIR env or ./data)\n" ++
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

    var mgr = cli_auth.initCliAuthManager(allocator, data_dir) catch |err| {
        std.debug.print("Error: Failed to initialize auth store: {s}\n", .{@errorName(err)});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    defer cli_auth.deinitAndSaveCliAuth(allocator, &mgr);

    // Resolve HMAC key
    const kr = auth_graph_manager.AuthGraphManager.resolveHmacKey(allocator, data_dir) catch |err| {
        std.debug.print("Error: Failed to resolve HMAC key: {s}\n", .{@errorName(err)});
        std.debug.print("Set GEODE_AUTH_HMAC_KEY or GEODE_TDE_KEY, or create .geode_hmac_key in the data directory.\n", .{});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };

    // Check if records already exist
    if (mgr.hasAuthRecords()) {
        std.debug.print("Error: Auth records already exist. Use 'geode auth reseal' to recompute chain.\n", .{});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    }

    // Bootstrap
    const result = mgr.bootstrapDefaultAdmin(&kr.key) catch |err| {
        std.debug.print("Error: Failed to bootstrap admin user: {s}\n", .{@errorName(err)});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };

    // Issue #819 (CWE-200 information disclosure / CWE-538 file/dir info
    // exposure): never echo the bootstrap password to stdout.  Mirror the
    // server-init path -- when neither `GEODE_ADMIN_PASSWORD` nor
    // `GEODE_DEFAULT_PASSWORD` is set, write the generated value to
    // `<data_dir>/.geode_admin_password` at mode 0o600 and surface only a
    // pointer.  When an env var seeded the password the operator already
    // has the plaintext; we just confirm the user was created.
    const admin_env_present = blk_env: {
        if (getEnvVarOwned(allocator, "GEODE_ADMIN_PASSWORD")) |env_pw| {
            allocator.free(env_pw);
            break :blk_env true;
        } else |_| {}
        if (getEnvVarOwned(allocator, "GEODE_DEFAULT_PASSWORD")) |env_pw| {
            allocator.free(env_pw);
            break :blk_env true;
        } else |_| {}
        break :blk_env false;
    };

    if (admin_env_present) {
        std.debug.print(
            "Admin user created: {s}\n" ++
                "Password sourced from GEODE_ADMIN_PASSWORD / GEODE_DEFAULT_PASSWORD env (not echoed).\n" ++
                "WARNING: Rotate this password immediately after first login.\n",
            .{result.username},
        );
        return;
    }

    // No env-supplied password.  Resolve the same data_dir that
    // initCliAuthManager used (--data-dir flag → GEODE_DATA_DIR →
    // /var/lib/geode) so the pointer message matches the file we write.
    const env_dir_owned: ?[]u8 = if (data_dir == null)
        (getEnvVarOwned(allocator, "GEODE_DATA_DIR") catch null)
    else
        null;
    defer if (env_dir_owned) |d| allocator.free(d);

    const pw_dir: []const u8 = if (data_dir) |d|
        d
    else if (env_dir_owned) |d|
        d
    else
        "/var/lib/geode";

    const pw_path = std.fmt.allocPrint(allocator, "{s}/.geode_admin_password", .{pw_dir}) catch {
        std.debug.print(
            "Error: Failed to allocate bootstrap password file path; rotate via 'geode user reset-password'.\n",
            .{},
        );
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    defer allocator.free(pw_path);

    const io_pw = std.Io.Threaded.global_single_threaded.io();
    if (std.Io.Dir.cwd().createFile(io_pw, pw_path, .{
        .truncate = true,
        .permissions = std.Io.File.Permissions.fromMode(0o600),
    })) |file| {
        defer file.close(io_pw);
        file.writeStreamingAll(io_pw, result.password) catch |err| {
            std.debug.print(
                "Error: Failed to write bootstrap password file at {s}: {s}\n" ++
                    "Use 'geode user reset-password' after setting GEODE_ADMIN_PASSWORD to recover.\n",
                .{ pw_path, @errorName(err) },
            );
            std.process.exit(@intFromEnum(ExitCode.general_error));
        };
        std.debug.print(
            "Admin user created: {s}\n" ++
                "Bootstrap password written to: {s} (mode 0600, read once; rotate immediately).\n" ++
                "WARNING: Move this file to secure storage and delete after first login.\n",
            .{ result.username, pw_path },
        );
    } else |err| {
        std.debug.print(
            "Error: Failed to create bootstrap password file at {s}: {s}\n" ++
                "Set GEODE_ADMIN_PASSWORD before re-running 'geode auth init', or rotate via 'geode user reset-password'.\n",
            .{ pw_path, @errorName(err) },
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
            "  --data-dir <path>    Data directory (default: GEODE_DATA_DIR env or ./data)\n" ++
            "  -h, --help           Show this help\n" ++
            "\n" ++
            "Recomputes all per-record HMACs and the chain root hash.\n" ++
            "Use after legitimate manual intervention (e.g. direct graph edits).\n" ++
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
    const kr = auth_graph_manager.AuthGraphManager.resolveHmacKey(allocator, data_dir) catch |err| {
        std.debug.print("Error: Failed to resolve HMAC key: {s}\n", .{@errorName(err)});
        std.debug.print("Set GEODE_AUTH_HMAC_KEY or GEODE_TDE_KEY, or create .geode_hmac_key in the data directory.\n", .{});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };

    // Seal chain
    mgr.sealChain(&kr.key) catch |err| {
        std.debug.print("Error: Failed to reseal chain: {s}\n", .{@errorName(err)});
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
            "  --data-dir <path>    Data directory (default: GEODE_DATA_DIR env or ./data)\n" ++
            "  -h, --help           Show this help\n" ++
            "\n" ++
            "Verifies per-record HMACs and the chain root hash.\n" ++
            "Exits 0 on success, 1 on integrity failure.\n" ++
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

    var mgr = cli_auth.initCliAuthManager(allocator, data_dir) catch |err| {
        std.debug.print("Error: Failed to initialize auth store: {s}\n", .{@errorName(err)});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    defer cli_auth.deinitAndSaveCliAuth(allocator, &mgr);

    // Resolve HMAC key
    const kr = auth_graph_manager.AuthGraphManager.resolveHmacKey(allocator, data_dir) catch |err| {
        std.debug.print("Error: Failed to resolve HMAC key: {s}\n", .{@errorName(err)});
        std.debug.print("Set GEODE_AUTH_HMAC_KEY or GEODE_TDE_KEY, or create .geode_hmac_key in the data directory.\n", .{});
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
