const std = @import("std");

// CANARY: REQ=REQ-CLI-AUTHN-001; FEATURE="CLIAuthn"; ASPECT=RefusedAsUnsupported; STATUS=TESTED; TEST=tests/test_sonny6554_cli_honesty.zig; OWNER=cli; UPDATED=2026-11-15
//
// SONNY-6554: `geode authn config` wrote anonymous / MFA path rules to
// geode_authn_state.db in the CLI state directory, a file no server reads;
// `test-access` evaluated a path against that file ("Access allowed");
// `stepup-check` answered from a hard-coded `admin:` prefix, not the
// server's step-up classification (GAP-0884, OperationClass); `stepup-mark`
// printed "Session elevated successfully" and did nothing. Every subcommand
// is refused as not supported by this server.

const ExitCode = enum(u8) {
    success = 0,
    general_error = 1,
};

const Unsupported = struct { name: []const u8, why: []const u8 };

const subcommands = [_]Unsupported{
    .{ .name = "config", .why = "per-path anonymous access and MFA rules (no server reads them; nothing was configured)" },
    .{ .name = "test-access", .why = "per-path access rules (no server has them, so no access decision can be shown)" },
    .{ .name = "stepup-check", .why = "a client-side step-up check (the server decides step-up from the statement it runs, GAP-0884; the CLI cannot ask it)" },
    .{ .name = "stepup-mark", .why = "session elevation (no server keeps sessions to elevate; nothing was elevated)" },
};

fn printAuthnUsage() void {
    std.debug.print(
        \\geode authn - Authentication provider configuration (not supported by this server)
        \\
        \\Every subcommand (config, test-access, stepup-check, stepup-mark) is
        \\refused and exits 1: no geode server reads per-path access or MFA
        \\rules from the CLI, and none keeps a session to elevate. MFA (TOTP) is
        \\configured per user (geode user mfa-*); step-up is decided by the
        \\server for each statement (docs/USER_AUTH.md).
        \\
    , .{});
}

/// Authn command handler: refuses every subcommand (SONNY-6554).
pub fn cmdAuthn(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    _ = allocator;
    if (start_idx >= argv.len) {
        printAuthnUsage();
        std.process.exit(@intFromEnum(ExitCode.general_error));
    }
    const subcommand = argv[start_idx];
    if (std.mem.eql(u8, subcommand, "--help") or std.mem.eql(u8, subcommand, "-h")) {
        printAuthnUsage();
        // SONNY-6559 (11): success returns through main, which records it.
        return;
    }
    for (subcommands) |s| {
        if (!std.mem.eql(u8, s.name, subcommand)) continue;
        for (argv[start_idx + 1 ..]) |a| {
            if (std.mem.eql(u8, a, "-h") or std.mem.eql(u8, a, "--help")) {
                std.debug.print("geode authn {s} - not supported by this server: {s}. The command exits 1.\n", .{ s.name, s.why });
                return;
            }
        }
        std.debug.print("Error: geode authn {s} is not supported by this server: {s}\n", .{ s.name, s.why });
        std.process.exit(@intFromEnum(ExitCode.general_error));
    }
    std.debug.print("Error: Unknown authn subcommand '{s}'\n", .{subcommand});
    printAuthnUsage();
    std.process.exit(@intFromEnum(ExitCode.general_error));
}
