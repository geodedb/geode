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
        std.process.exit(@intFromEnum(ExitCode.success));
    }

    const data_dir = parseDataDirFlag(argv, start_idx);

    var mgr = cli_auth.initCliAuthManager(allocator, data_dir) catch |err| {
        std.debug.print("Error: Failed to initialize auth store: {s}\n", .{@errorName(err)});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    defer mgr.deinit();

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

    std.debug.print("Admin user created: {s}\nGenerated password: {s}\n", .{ result.username, result.password });
    std.debug.print("WARNING: Change this password immediately after first login.\n", .{});
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
        std.process.exit(@intFromEnum(ExitCode.success));
    }

    const data_dir = parseDataDirFlag(argv, start_idx);

    var mgr = cli_auth.initCliAuthManager(allocator, data_dir) catch |err| {
        std.debug.print("Error: Failed to initialize auth store: {s}\n", .{@errorName(err)});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    defer mgr.deinit();

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
        std.process.exit(@intFromEnum(ExitCode.success));
    }

    const data_dir = parseDataDirFlag(argv, start_idx);

    var mgr = cli_auth.initCliAuthManager(allocator, data_dir) catch |err| {
        std.debug.print("Error: Failed to initialize auth store: {s}\n", .{@errorName(err)});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    defer mgr.deinit();

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
