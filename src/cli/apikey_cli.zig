const std = @import("std");
const api_keys = @import("auth_lib").api_keys;

// CANARY: REQ=REQ-AUTH-APIKEYS-CLI-001; FEATURE="ApiKeyCLI"; ASPECT=RefusedAsUnsupported; STATUS=TESTED; TEST=tests/test_sonny6554_cli_honesty.zig; OWNER=cli; UPDATED=2026-11-15
//
// SONNY-6554: `geode apikey create|list|revoke|revoke-all|check-scope` kept
// keys in geode_apikey_state.db in the CLI state directory and reported
// "API key created", "revoked", "granted"; no server reads that file, and
// no server authenticates an API key (the QUIC and gRPC handshakes take a
// user name and password, or mTLS; SONNY-6291, docs/USER_AUTH.md). A key
// printed by `create` opened nothing, and `revoke` closed nothing. Those
// subcommands are refused as not supported by this server. `validate`
// checks the format of a key string locally and says so.

const API_KEY_VERSION = "gk1";

const ExitCode = enum(u8) {
    success = 0,
    general_error = 1,
    usage_error = 2,
};

const unsupported_why = "API key authentication (no geode server accepts API keys or reads the CLI's key file; nothing was created, listed, revoked or checked). Use a service-account user with a password, or mTLS";

const unsupported = [_][]const u8{ "create", "list", "revoke", "revoke-all", "check-scope" };

fn printUsage() void {
    std.debug.print(
        \\geode apikey - API keys
        \\
        \\Usage: geode apikey validate <api_key>
        \\
        \\  validate <api_key>   Check that a string has the gk1.<id>.<secret> format
        \\                       (local only; no server is asked)
        \\
        \\create, list, revoke, revoke-all and check-scope are not supported by
        \\this server (each exits 1): no geode server accepts API keys
        \\(docs/USER_AUTH.md, "API Key Authentication").
        \\
    , .{});
}

fn hasHelpFlag(argv: [][:0]u8, start_idx: usize) bool {
    for (argv[@min(start_idx, argv.len)..]) |a| {
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) return true;
    }
    return false;
}

/// The first argument after `apikey` that is not a global option.
fn findSubcommandStart(argv: [][:0]u8, start_idx: usize) usize {
    var idx = start_idx + 1;
    while (idx < argv.len) : (idx += 1) {
        const arg = argv[idx];
        if (std.mem.eql(u8, arg, "--audit")) continue;
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

/// `validate`: a format check of the key string, nothing more.
fn handleValidateSubcommand(argv: [][:0]u8, subcmd_idx: usize) void {
    if (hasHelpFlag(argv, subcmd_idx + 1)) {
        std.debug.print("Usage: geode apikey validate <api_key>\nChecks the key's format locally; no geode server accepts API keys.\n", .{});
        return;
    }
    if (subcmd_idx + 1 >= argv.len) {
        std.debug.print("Error: API key is required\n", .{});
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }
    const parsed = api_keys.parseApiKey(argv[subcmd_idx + 1]) catch {
        std.debug.print("Error: invalid API key format (format check only; no geode server accepts API keys)\n", .{});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    };
    if (!std.mem.eql(u8, parsed.prefix, API_KEY_VERSION)) {
        std.debug.print("Error: unsupported API key version (format check only; no geode server accepts API keys)\n", .{});
        std.process.exit(@intFromEnum(ExitCode.general_error));
    }
    std.debug.print("API key format is valid (format check only: no geode server accepts API keys, so it authenticates nothing)\n", .{});
}

pub fn cmdApiKey(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    _ = allocator;
    const subcmd_idx = findSubcommandStart(argv, start_idx);
    if (subcmd_idx >= argv.len) {
        std.debug.print("Error: missing apikey subcommand\n", .{});
        printUsage();
        std.process.exit(@intFromEnum(ExitCode.usage_error));
    }
    const subcommand = argv[subcmd_idx];

    if (std.mem.eql(u8, subcommand, "--help") or std.mem.eql(u8, subcommand, "-h")) {
        printUsage();
        return;
    }
    if (std.mem.eql(u8, subcommand, "validate")) {
        handleValidateSubcommand(argv, subcmd_idx);
        return;
    }
    for (unsupported) |name| {
        if (!std.mem.eql(u8, name, subcommand)) continue;
        if (hasHelpFlag(argv, subcmd_idx + 1)) {
            std.debug.print("geode apikey {s} - not supported by this server: {s}. The command exits 1.\n", .{ name, unsupported_why });
            return;
        }
        std.debug.print("Error: geode apikey {s} is not supported by this server: {s}\n", .{ name, unsupported_why });
        std.process.exit(@intFromEnum(ExitCode.general_error));
    }
    std.debug.print("Error: unknown apikey subcommand '{s}'\n", .{subcommand});
    printUsage();
    std.process.exit(@intFromEnum(ExitCode.usage_error));
}
