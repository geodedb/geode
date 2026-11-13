// SONNY-6453 item 3: an MCP endpoint DSN with `insecure=true` follows the
// CLI rule for skipping TLS verification.
//
// Before: `geode mcp` parsed `insecure=true` (or `insecure_tls_skip_verify`,
// `skip_verify`) from its endpoint DSN and turned certificate verification
// off silently, in any build. Now it is refused under production posture (a
// release build or GEODE_ENV=production, unless GEODE_ALLOW_INSECURE_TLS=1),
// exactly like `--insecure-tls-skip-verify` on the CLI, and warns otherwise.
//
// Drives the real `geode_mcp.client.GeodeClient.init` (the DSN parse and
// client construction the MCP server uses); no connection is needed for the
// decision. This Debug test binary sets GEODE_ENV=production to get
// production posture.
//
// CANARY: REQ=REQ-SEC-MCP-INSECURE-DSN-001; FEATURE="InsecureTlsFlagGate"; ASPECT=McpDsn; STATUS=TESTED; TEST=tests/test_sonny6453_mcp_insecure_dsn.zig; OWNER=security; UPDATED=2026-11-13

const std = @import("std");
const geode_mcp = @import("geode_mcp");

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

fn resetPostureEnv() void {
    _ = unsetenv("GEODE_ENV");
    _ = unsetenv("GEODE_ALLOW_INSECURE_TLS");
}

const insecure_dsns = [_][]const u8{
    "127.0.0.1:3141?insecure=true",
    "quic://127.0.0.1:3141?insecure_tls_skip_verify=true",
    "127.0.0.1:3141?skip_verify=1",
};

test "SONNY-6453: MCP refuses a DSN insecure=true under production posture" {
    const a = std.testing.allocator;
    defer resetPostureEnv();
    resetPostureEnv();
    _ = setenv("GEODE_ENV", "production", 1);
    for (insecure_dsns) |dsn| {
        if (geode_mcp.client.GeodeClient.init(a, dsn)) |client| {
            client.deinit();
            std.debug.print("  {s}: accepted under GEODE_ENV=production\n", .{dsn});
            return error.InsecureDsnAccepted;
        } else |err| try std.testing.expectEqual(error.InsecureTlsRefused, err);
    }
}

test "SONNY-6453: MCP allows a DSN insecure=true with the explicit override or in a Debug dev posture" {
    const a = std.testing.allocator;
    defer resetPostureEnv();
    {
        resetPostureEnv();
        _ = setenv("GEODE_ENV", "production", 1);
        _ = setenv("GEODE_ALLOW_INSECURE_TLS", "1", 1);
        const client = try geode_mcp.client.GeodeClient.init(a, insecure_dsns[0]);
        client.deinit();
    }
    {
        resetPostureEnv();
        const client = try geode_mcp.client.GeodeClient.init(a, insecure_dsns[0]);
        client.deinit();
    }
    // A verified DSN is not affected by production posture.
    {
        resetPostureEnv();
        _ = setenv("GEODE_ENV", "production", 1);
        const client = try geode_mcp.client.GeodeClient.init(a, "127.0.0.1:3141");
        client.deinit();
    }
}
