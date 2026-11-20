const std = @import("std");

// CANARY: REQ=REQ-GAP-0258-MTLS-CLI-001; FEATURE="mTLS CLI"; ASPECT=MappingRefusedAsUnsupported; STATUS=TESTED; TEST=tests/test_sonny6457_mtls_cli_unsupported.zig; OWNER=cli; UPDATED=2026-11-13
//
// SONNY-6457: `geode mtls map create|list|delete`, `config` and `status`
// kept certificate-to-user mappings in geode_mtls_state.db in the CLI state
// directory and reported success, but nothing on the server read that file
// and the server's certificate-to-user store (src/security/mtls_provider.zig)
// is never populated: a mapping changed nothing, the user was always the one
// that authenticates in HELLO. Every subcommand is refused as unsupported
// until certificate-to-user mapping lands (SONNY-6458).

const ExitCode = enum(u8) {
    success = 0,
    general_error = 1,
};

fn printMtlsUsage() void {
    std.debug.print(
        \\geode mtls - Mutual TLS certificate-to-user mapping
        \\
        \\Certificate-to-user mapping is not supported in this release
        \\(SONNY-6458): the server does not read mappings, so map
        \\create|list|delete, config and status are refused with an error.
        \\
        \\Requiring client certificates is configured on the server:
        \\  GEODE_MTLS_REQUIRED=1 GEODE_MTLS_CLIENT_CA=<CA bundle PEM> geode serve ...
        \\A client then still authenticates as a user (username and password).
        \\
    , .{});
}

/// mTLS CLI command handler: refuses every subcommand (SONNY-6458).
pub fn cmdMtls(allocator: std.mem.Allocator, argv: [][:0]u8, start_idx: usize) !void {
    _ = allocator;
    var sub_idx = start_idx;
    while (sub_idx < argv.len) : (sub_idx += 1) {
        const a = argv[sub_idx];
        if (std.mem.eql(u8, a, "--help") or std.mem.eql(u8, a, "-h")) {
            printMtlsUsage();
            return;
        }
        if (!std.mem.startsWith(u8, a, "--")) break;
    }
    const what: []const u8 = if (sub_idx < argv.len) argv[sub_idx] else "mtls";
    std.debug.print(
        "Error: geode mtls {s} is not supported in this release (SONNY-6458): the server does not read " ++
            "certificate-to-user mappings, so no mapping was created, changed or read. To require client " ++
            "certificates set GEODE_MTLS_REQUIRED=1 and GEODE_MTLS_CLIENT_CA=<CA bundle PEM> on geode serve; " ++
            "clients still authenticate with a username and password.\n",
        .{what},
    );
    std.process.exit(@intFromEnum(ExitCode.general_error));
}
