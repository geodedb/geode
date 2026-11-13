// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6487 item 2: the CLI's QUIC client address resolution
// (src/client/quic_endpoint_host.zig) looked a host name up for IPv4 only,
// so a name with only an IPv6 address failed with NoAddressReturned, and it
// passed an IPv6 literal through to geode-client-zig, whose endpoint binds
// IPv4 (0.0.0.0:0) and formats the dial address without brackets: the
// connection then failed with a bare InvalidAddress. It now looks up both
// families, prefers IPv4 (the only family the client library can reach),
// and refuses an IPv6-only destination with Ipv6EndpointUnsupported.
// Real resolver (/etc/hosts), no lookup substitution.

const std = @import("std");
const endpoint_host = @import("quic_endpoint_host");

fn hostsFileNames(name: []const u8) bool {
    var buf: [16 * 1024]u8 = undefined;
    const io = std.Io.Threaded.global_single_threaded.io();
    const text = std.Io.Dir.cwd().readFile(io, "/etc/hosts", &buf) catch return false;
    var lines = std.mem.tokenizeScalar(u8, text, '\n');
    while (lines.next()) |line| {
        var fields = std.mem.tokenizeAny(u8, line, " \t");
        const ip = fields.next() orelse continue;
        if (ip[0] == '#') continue;
        while (fields.next()) |f| if (std.mem.eql(u8, f, name)) return true;
    }
    return false;
}

test "SONNY-6487: localhost resolves to its IPv4 address first" {
    const resolved = try endpoint_host.resolveAlloc(std.testing.allocator, "localhost");
    defer std.testing.allocator.free(resolved);
    const address = try std.Io.net.IpAddress.parseIp4(resolved, 0);
    try std.testing.expectEqual(@as(u8, 127), address.ip4.bytes[0]);
}

test "SONNY-6487: an IPv6 literal is refused with the reason, not passed to an IPv4-only endpoint" {
    for ([_][]const u8{ "::1", "[::1]", "2001:db8::1", "fe80::1%lo" }) |host| {
        try std.testing.expectError(error.Ipv6EndpointUnsupported, endpoint_host.resolveAlloc(std.testing.allocator, host));
    }
    const v4 = try endpoint_host.resolveAlloc(std.testing.allocator, "127.0.0.1");
    defer std.testing.allocator.free(v4);
    try std.testing.expectEqualStrings("127.0.0.1", v4);
}

test "SONNY-6487: a name with only an IPv6 address is found and refused with the reason" {
    if (!hostsFileNames("ip6-localhost")) {
        std.debug.print("SKIP: /etc/hosts has no ip6-localhost entry\n", .{});
        return error.SkipZigTest;
    }
    try std.testing.expectError(error.Ipv6EndpointUnsupported, endpoint_host.resolveAlloc(std.testing.allocator, "ip6-localhost"));
}
