// SONNY-6457 item 2: `geode query --client-cert --client-key` presents the
// client certificate.
//
// The CLI (query, shell/REPL, backup, tenant, MCP) connects through
// src/client/zig_quic_bridge.zig and the geode-client-zig library. Before the
// fix the library put the client certificate path in the vendor config's
// `cert_path`, which turns the QUIC endpoint into a SERVER, and never loaded
// the certificate into `inline_client_cert_der` / `inline_client_priv_key`,
// so `geode query` could not present a certificate at all.
//
// Spawns the geode this build emitted with GEODE_MTLS_REQUIRED=1 and a client
// CA bundle, then runs the real `geode query` binary with --ca-cert (the
// server is verified, not skipped):
//   accepted: --client-cert/--client-key in the client CA bundle
//   rejected: a client certificate not in the bundle, and no certificate.

const std = @import("std");
const builtin = @import("builtin");
const geode_test_bin = @import("geode_test_bin");
const util = @import("proto_test_util.zig");
const fixtures = @import("sonny6457_mtls_fixtures.zig");

const marker = "sonny6457-mtls-ok";

const Outcome = enum { accepted, rejected };

fn runQuery(a: std.mem.Allocator, addr: []const u8, server_ca: []const u8, cert: ?[]const u8, key: ?[]const u8, want: Outcome) !Outcome {
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(a);
    try argv.appendSlice(a, &.{ geode_test_bin.geode_exe, "query", "--server", addr, "--ca-cert", server_ca, "--user", util.defaultUsername(), "--password", util.defaultPassword() });
    if (cert) |c| try argv.appendSlice(a, &.{ "--client-cert", c });
    if (key) |k| try argv.appendSlice(a, &.{ "--client-key", k });
    try argv.append(a, "RETURN '" ++ marker ++ "' AS m");
    const result = try std.process.run(a, threaded.io(), .{ .argv = argv.items });
    defer a.free(result.stdout);
    defer a.free(result.stderr);
    const ok = result.term == .exited and result.term.exited == 0 and
        std.mem.indexOf(u8, result.stdout, marker) != null;
    const got: Outcome = if (ok) .accepted else .rejected;
    if (got != want) std.debug.print("    geode query: term={any}\n    stdout: {s}\n    stderr: {s}\n", .{ result.term, result.stdout, result.stderr });
    return got;
}

test "SONNY-6457: geode query --client-cert presents the certificate to an mTLS-required server" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = std.testing.allocator;
    var fx = try fixtures.make();
    defer fx.deinit();
    var server = try fixtures.startMtlsServer(a, &fx, "cli");
    defer server.deinit();

    const Case = struct { name: []const u8, cert: ?[]const u8, key: ?[]const u8, want: Outcome };
    const cases = [_]Case{
        .{ .name = "--client-cert in the client CA bundle", .cert = fx.pinned_cert, .key = fx.pinned_key, .want = .accepted },
        .{ .name = "--client-cert not in the bundle", .cert = fx.stray_cert, .key = fx.stray_key, .want = .rejected },
        .{ .name = "no --client-cert", .cert = null, .key = null, .want = .rejected },
    };
    var failures: usize = 0;
    for (cases) |c| {
        const got = try runQuery(a, server.addr, fx.server_ca, c.cert, c.key, c.want);
        if (got != c.want) {
            failures += 1;
            std.debug.print("  {s}: expected {s}, got {s}\n", .{ c.name, @tagName(c.want), @tagName(got) });
        }
    }
    if (failures != 0) return error.CliClientCertMatrixMismatch;
}
