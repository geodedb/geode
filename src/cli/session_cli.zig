const std = @import("std");

/// SONNY-6544: the printed server goes through dsn_credentials.redacted.
const geode = @import("geode");
const home_dir = @import("security/home_dir.zig");

/// SONNY-6551: the one writer and reader of ~/.geode/credentials.json.
const session_storage = @import("security/session_storage.zig");

// CANARY: REQ=REQ-CLI-SESSION-001; FEATURE="CLISession"; ASPECT=Management; STATUS=TESTED; TEST=tests/test_sonny6554_cli_honesty.zig; OWNER=cli; UPDATED=2026-11-15
// Session CLI commands.
//
// SONNY-6554: geode servers have no session-token authentication: the QUIC
// HELLO carries a user name and a password and nothing else, and a server
// keeps no record of the session ids it issues (SONNY-6551). `validate`
// called any 32-character string valid, `rotate` replaced the saved token
// with random bytes made on the client, `invalidate-all` printed
// "invalidated" and did nothing, and `check-idle` said "active" for any
// saved file. Each is now refused with "not supported by this server";
// `info` (it reads the local saved session file) says that it is local.

// Exit codes for consistency with main CLI
const ExitCode = enum(u8) {
    success = 0,
    general_error = 1,
    usage_error = 2,
};

/// SONNY-6544: the credential store under `<HOME>/.geode`, or exit with what
/// is wrong with HOME (unset, empty or relative). A relative HOME reached
/// `openFileAbsolute`'s absolute-path assert (a Debug panic).
fn credentialStoreOrExit(allocator: std.mem.Allocator) session_storage.CredentialStore {
    return session_storage.CredentialStore.init(allocator) catch |err| {
        home_dir.printError(err);
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
}

/// SONNY-6551: the saved session, read through the one reader; null (with
/// the reason on stderr when a file is there but not read) otherwise. The
/// caller deinits a non-null result.
fn loadSavedSession(allocator: std.mem.Allocator) ?session_storage.CredentialStore.LoadResult {
    var store = credentialStoreOrExit(allocator);
    defer store.deinit();
    var result = store.load() catch |err| {
        std.debug.print("Warning: saved session not loaded: {s}\n", .{@errorName(err)});
        return null;
    };
    switch (result) {
        .loaded => return result,
        .ignored => |why| std.debug.print("Warning: saved session ignored: {s}\n", .{session_storage.ignoredMessage(why)}),
        .none => {},
    }
    result.deinit();
    return null;
}

/// Session command handler - routes to specific session subcommands
pub fn cmdSession(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    if (start_idx >= argv.len) {
        printSessionUsage();
        std.process.exit(@intFromEnum(ExitCode.general_error));
    }

    const subcommand = argv[start_idx];

    if (std.mem.eql(u8, subcommand, "--help") or std.mem.eql(u8, subcommand, "-h")) {
        printSessionUsage();
        // SONNY-6559 (11): success returns through main, which records it.
        return;
    } else if (std.mem.eql(u8, subcommand, "info")) {
        try cmdSessionInfo(allocator, argv, start_idx + 1);
    } else if (unsupportedReason(subcommand)) |why| {
        return refuseUnsupported(subcommand, why, argv, start_idx + 1);
    } else {
        std.debug.print("Error: Unknown session subcommand '{s}'\n", .{subcommand});
        printSessionUsage();
        std.process.exit(@intFromEnum(ExitCode.general_error));
    }
}

/// SONNY-6554: the session subcommands no server supports, and why.
fn unsupportedReason(subcommand: []const u8) ?[]const u8 {
    const Unsupported = struct { name: []const u8, why: []const u8 };
    const table = [_]Unsupported{
        .{ .name = "validate", .why = "session token validation (no server keeps the session ids it issues, so none can say whether a token is valid)" },
        .{ .name = "rotate", .why = "session token rotation (no server accepts a session token, so a new one would be one no server knows; the saved session was not changed)" },
        .{ .name = "invalidate-all", .why = "session invalidation (no server keeps sessions to invalidate; nothing was invalidated)" },
        .{ .name = "check-idle", .why = "session idle tracking (no server tracks session activity)" },
    };
    for (table) |u| {
        if (std.mem.eql(u8, u.name, subcommand)) return u.why;
    }
    return null;
}

/// Help returns (through main, SONNY-6559); the command itself exits 1,
/// so no success is recorded for it.
fn refuseUnsupported(subcommand: []const u8, why: []const u8, argv: [][:0]u8, start_idx: usize) void {
    var i: usize = start_idx;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "-h") or std.mem.eql(u8, argv[i], "--help")) {
            std.debug.print("geode session {s} - not supported by this server: {s}. The command exits 1.\n", .{ subcommand, why });
            return;
        }
    }
    std.debug.print("Error: geode session {s} is not supported by this server: {s} (docs/USER_AUTH.md, 'Saved sessions')\n", .{ subcommand, why });
    std.process.exit(@intFromEnum(ExitCode.general_error));
}

fn printSessionUsage() void {
    std.debug.print("geode session - The local saved session\n" ++
        "\n" ++
        "Usage: geode session <subcommand> [options]\n" ++
        "\n" ++
        "Subcommands:\n" ++
        "  info                Show the local saved session (~/.geode/credentials.json)\n" ++
        "\n" ++
        "validate, rotate, invalidate-all and check-idle are not supported by\n" ++
        "this server (each exits 1). geode servers do not accept session tokens\n" ++
        "yet: the HELLO carries a user name and a password only, and no server\n" ++
        "keeps the session ids it issues, so a session can be neither validated,\n" ++
        "rotated nor invalidated.\n" ++
        "\n" ++
        "Options:\n" ++
        "  -h, --help          Show this help\n" ++
        "\n", .{});
}

fn cmdSessionInfo(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    var i: usize = start_idx;
    while (i < argv.len) : (i += 1) {
        if (std.mem.eql(u8, argv[i], "-h") or std.mem.eql(u8, argv[i], "--help")) {
            std.debug.print("geode session info - Show the local saved session\n" ++
                "\n" ++
                "Usage: geode session info\n" ++
                "\n" ++
                "Reads ~/.geode/credentials.json (written by 'geode auth login --save-session').\n" ++
                "Local only: geode servers do not accept session tokens yet.\n" ++
                "\n" ++
                "Options:\n" ++
                "  -h, --help          Show this help\n" ++
                "\n", .{});
            return;
        }
    }

    var saved = loadSavedSession(allocator) orelse {
        std.debug.print("Error: No saved session found (~/.geode/credentials.json).\n", .{});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    defer saved.deinit();
    const creds = saved.loaded.credentials();

    // SONNY-6554: say what this is: a local file no server accepts.
    std.debug.print("Saved session (local file ~/.geode/credentials.json; geode servers do not accept session tokens yet, so it does not log commands in):\n", .{});
    std.debug.print("  user: {s}\n", .{creds.username});
    std.debug.print("  server: {f}\n", .{geode.dsn_credentials.redacted(creds.server)});
    std.debug.print("  created: {d} (timestamp)\n", .{creds.created_at});
    std.debug.print("  expires: {d} (timestamp)\n", .{creds.expires_at});
    std.debug.print("  token: {s}...\n", .{creds.token[0..@min(16, creds.token.len)]});
}
