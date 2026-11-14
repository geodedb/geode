// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6484 (1): IPv6 literals in client addresses (`--server`, `--dsn`,
// the MCP endpoint DSN). docs/DSN.md: an IPv6 address MUST be bracketed,
// `[::1]`, `[::1]:3141`, `[fe80::1%eth0]:3141`. Before the fix
// `parseHostPort` split on the LAST colon, so `[::1]:3141` gave the host
// `[::1]` (brackets kept, never resolvable) and a bare `::1` gave the host
// `:` and port 1; the MCP endpoint parser (geode-client-zig `parseDSN`) did
// the same with a bare `::1`. A bare (unbracketed) IPv6 literal is now
// refused, not misread (by geode-client-zig itself since v0.3.16).

const std = @import("std");
const bridge = @import("zig_quic_bridge");

const Case = struct { addr: []const u8, host: []const u8, port: u16 };

test "SONNY-6484: parseHostPort accepts hostnames, IPv4 and bracketed IPv6 with or without a port" {
    const cases = [_]Case{
        .{ .addr = "localhost", .host = "localhost", .port = 3141 },
        .{ .addr = "localhost:8443", .host = "localhost", .port = 8443 },
        .{ .addr = "127.0.0.1:3141", .host = "127.0.0.1", .port = 3141 },
        .{ .addr = ":9000", .host = "127.0.0.1", .port = 9000 },
        .{ .addr = "[::1]", .host = "::1", .port = 3141 },
        .{ .addr = "[::1]:3141", .host = "::1", .port = 3141 },
        .{ .addr = "[2001:db8::1]:50051", .host = "2001:db8::1", .port = 50051 },
        .{ .addr = "[fe80::1%eth0]:3141", .host = "fe80::1%eth0", .port = 3141 },
        .{ .addr = "[::ffff:192.0.2.1]:7", .host = "::ffff:192.0.2.1", .port = 7 },
    };
    for (cases) |c| {
        const hp = try bridge.parseHostPort(c.addr, 3141);
        std.testing.expectEqualStrings(c.host, hp.host) catch |err| {
            std.debug.print("addr {s}\n", .{c.addr});
            return err;
        };
        try std.testing.expectEqual(c.port, hp.port);
    }
}

test "SONNY-6484: parseHostPort refuses a bare IPv6 literal and malformed brackets instead of misreading them" {
    for ([_][]const u8{
        "::1", // was host ":" port 1
        "::1:3141", // ambiguous: address or port?
        "2001:db8::1",
        "fe80::1%eth0",
        "[::1", // unterminated
        "[::1]3141", // junk after the bracket
        "[::1]:", // empty port
        "[::1]:70000", // port out of range
        "[not-an-ip]:3141",
        "[]:3141",
        "[127.0.0.1]:3141", // brackets are for IPv6 only
        "localhost:http",
        "localhost:0", // SONNY-6494: no server can be dialled on port 0
        "[::1]:0",
    }) |addr| {
        if (bridge.parseHostPort(addr, 3141)) |hp| {
            std.debug.print("accepted {s} as host '{s}' port {d}\n", .{ addr, hp.host, hp.port });
            return error.TestUnexpectedResult;
        } else |_| {}
    }
}

test "SONNY-6484: the MCP endpoint DSN parser refuses a bare IPv6 host" {
    // SONNY-6494: geode's own pre-check (checkDsnHost) is gone; the MCP
    // endpoint goes straight to geode-client-zig's parseDSN, which since
    // v0.3.16 refuses an unbracketed IPv6 host itself.
    const parseDSN = bridge.zig_client.config.parseDSN;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{
        "localhost",
        "localhost:3141",
        "quic://localhost:3141/g?page_size=5",
        "quic://user:pa:ss@localhost:3141",
        "[::1]",
        "[::1]:3141",
        "quic://[::1]:3141/social?insecure=true",
        "grpc://admin:secret@[2001:db8::1]:50051",
        "quic://[fe80::1%eth0]:3141",
        "localhost:3141?hello_name=a:b:c",
    }) |dsn| {
        _ = parseDSN(arena.allocator(), dsn) catch |err| {
            std.debug.print("refused {s}: {s}\n", .{ dsn, @errorName(err) });
            return err;
        };
    }
    for ([_][]const u8{
        "::1",
        "::1:3141",
        "quic://::1:3141",
        "quic://user:pw@2001:db8::1/graph",
        "grpc://[::1",
        "quic://[::1]x",
    }) |dsn| {
        try std.testing.expectError(error.InvalidDSN, parseDSN(arena.allocator(), dsn));
    }
}
