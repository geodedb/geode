// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6487 item 2: one host:port grammar (docs/DSN.md, "Host
// Specification") for every Geode address. The splitters at
// `geode serve --listen` / `--listen-grpc`, the cluster peer list, the LSP
// and syslog listeners, Kafka brokers, KMS endpoints and the shared test
// client split on the LAST colon and ignored brackets, so `[::1]:4242` kept
// its brackets as the host and a bare `::1:4242` was read as host `::1`;
// several replaced an unparseable port with a default (`--listen` with
// 3141, `--audit-syslog` with 514). They now all use `geode.host_port`, and
// a bad port is an error everywhere.

const std = @import("std");
const geode = @import("geode");
const cli_args = @import("cli_args");
const cluster_bootstrap = @import("cluster_bootstrap");
const host_port = geode.host_port;

const Accept = struct { addr: []const u8, host: []const u8, port: u16, literal: []const u8 };

test "SONNY-6487: host_port.split accepts the documented grammar" {
    for ([_]Accept{
        .{ .addr = "localhost", .host = "localhost", .port = 3141, .literal = "localhost" },
        .{ .addr = "localhost:8443", .host = "localhost", .port = 8443, .literal = "localhost" },
        .{ .addr = "geode-0.geode.svc:4242", .host = "geode-0.geode.svc", .port = 4242, .literal = "geode-0.geode.svc" },
        .{ .addr = "127.0.0.1:0", .host = "127.0.0.1", .port = 0, .literal = "127.0.0.1" },
        .{ .addr = ":9000", .host = "", .port = 9000, .literal = "" },
        .{ .addr = "[::1]", .host = "::1", .port = 3141, .literal = "[::1]" },
        .{ .addr = "[::1]:65535", .host = "::1", .port = 65535, .literal = "[::1]" },
        .{ .addr = "[2001:db8::1]:50051", .host = "2001:db8::1", .port = 50051, .literal = "[2001:db8::1]" },
        .{ .addr = "[fe80::1%eth0]:3141", .host = "fe80::1%eth0", .port = 3141, .literal = "[fe80::1%eth0]" },
        .{ .addr = "[::]:4242", .host = "::", .port = 4242, .literal = "[::]" },
    }) |c| {
        const hp = host_port.split(c.addr, 3141) catch |err| {
            std.debug.print("refused {s}: {s}\n", .{ c.addr, @errorName(err) });
            return err;
        };
        try std.testing.expectEqualStrings(c.host, hp.host);
        try std.testing.expectEqual(c.port, hp.port);
        try std.testing.expectEqualStrings(c.literal, hp.host_literal);
    }
}

test "SONNY-6487: host_port.split refuses bare IPv6, malformed brackets and bad ports" {
    const Refuse = struct { addr: []const u8, err: host_port.Error };
    for ([_]Refuse{
        .{ .addr = "", .err = error.InvalidAddress },
        .{ .addr = "::1", .err = error.InvalidAddress },
        .{ .addr = "::1:4242", .err = error.InvalidAddress },
        .{ .addr = "2001:db8::1", .err = error.InvalidAddress },
        .{ .addr = "[::1", .err = error.InvalidAddress },
        .{ .addr = "[::1]4242", .err = error.InvalidAddress },
        .{ .addr = "::1]:4242", .err = error.InvalidAddress },
        .{ .addr = "[127.0.0.1]:4242", .err = error.InvalidAddress },
        .{ .addr = "[]:4242", .err = error.InvalidAddress },
        .{ .addr = "[::1]:", .err = error.InvalidPort },
        .{ .addr = "host:", .err = error.InvalidPort },
        .{ .addr = "host:http", .err = error.InvalidPort },
        .{ .addr = "host:+80", .err = error.InvalidPort },
        .{ .addr = "host:-1", .err = error.InvalidPort },
        .{ .addr = "host:3_141", .err = error.InvalidPort },
        .{ .addr = "host:65536", .err = error.InvalidPort },
        .{ .addr = "host:000080", .err = error.InvalidPort },
        .{ .addr = "[::1]:70000", .err = error.InvalidPort },
    }) |c| {
        if (host_port.split(c.addr, 3141)) |hp| {
            std.debug.print("accepted '{s}' as host '{s}' port {d}\n", .{ c.addr, hp.host, hp.port });
            return error.TestUnexpectedResult;
        } else |err| {
            std.testing.expectEqual(c.err, err) catch |e| {
                std.debug.print("'{s}'\n", .{c.addr});
                return e;
            };
        }
    }
    // Without a default the port is required.
    try std.testing.expectError(error.InvalidPort, host_port.split("localhost", null));
    try std.testing.expectError(error.InvalidPort, host_port.split("[::1]", null));
}

test "SONNY-6487: host_port.formatAlloc brackets IPv6 hosts so split reads them back" {
    const a = std.testing.allocator;
    for ([_]struct { host: []const u8, want: []const u8 }{
        .{ .host = "::1", .want = "[::1]:4242" },
        .{ .host = "fe80::1%eth0", .want = "[fe80::1%eth0]:4242" },
        .{ .host = "127.0.0.2", .want = "127.0.0.2:4242" },
        .{ .host = "geode-1.geode", .want = "geode-1.geode:4242" },
    }) |c| {
        const s = try host_port.formatAlloc(a, c.host, 4242);
        defer a.free(s);
        try std.testing.expectEqualStrings(c.want, s);
        const back = try host_port.split(s, null);
        try std.testing.expectEqualStrings(c.host, back.host);
        try std.testing.expectEqual(@as(u16, 4242), back.port);
    }
}

test "SONNY-6487: the client address parser refuses a signed or underscored port" {
    for ([_][]const u8{ "localhost:+80", "localhost:3_141", "[::1]:+80" }) |addr| {
        if (geode.zig_quic_bridge.parseHostPort(addr, 3141)) |hp| {
            std.debug.print("accepted '{s}' as port {d}\n", .{ addr, hp.port });
            return error.TestUnexpectedResult;
        } else |_| {}
    }
    const hp = try geode.zig_quic_bridge.parseHostPort(":9000", 3141);
    try std.testing.expectEqualStrings("127.0.0.1", hp.host);
}

test "SONNY-6487: --listen resolves bracketed IPv6, host-only and port-only forms and refuses bad ports" {
    const Ok = struct { listen: []const u8, address: []const u8, port: u16 };
    for ([_]Ok{
        .{ .listen = "[::1]:0", .address = "[::1]", .port = 0 },
        .{ .listen = "[::]:3141", .address = "[::]", .port = 3141 },
        .{ .listen = "[::1]", .address = "[::1]", .port = 3141 },
        .{ .listen = "127.0.0.1:3150", .address = "127.0.0.1", .port = 3150 },
        .{ .listen = "3150", .address = "0.0.0.0", .port = 3150 },
        .{ .listen = ":3150", .address = "0.0.0.0", .port = 3150 },
        // Was: not a number, so 0.0.0.0:3141 -- every interface.
        .{ .listen = "localhost", .address = "localhost", .port = 3141 },
        .{ .listen = "127.0.0.2", .address = "127.0.0.2", .port = 3141 },
    }) |c| {
        const r = cli_args.resolveQuicListen(c.listen) catch |err| {
            std.debug.print("refused {s}: {s}\n", .{ c.listen, @errorName(err) });
            return err;
        };
        try std.testing.expectEqualStrings(c.address, r.address);
        try std.testing.expectEqual(c.port, r.port);
    }
    for ([_][]const u8{ "127.0.0.1:quic", "127.0.0.1:70000", "127.0.0.1:", "0.0.0.0:+1", "70000" }) |bad| {
        try std.testing.expectError(error.InvalidQuicListenPort, cli_args.resolveQuicListen(bad));
    }
    for ([_][]const u8{ "::1", "::1:3141", "[::1", "[localhost]:3141", "" }) |bad| {
        try std.testing.expectError(error.InvalidQuicListenAddress, cli_args.resolveQuicListen(bad));
    }
}

test "SONNY-6487: --listen-grpc parses brackets and keeps refusing IPv6 (grpc-zig binds IPv4 only)" {
    const ok = try cli_args.resolveGrpcBind("127.0.0.1:50051", null);
    try std.testing.expectEqualStrings("127.0.0.1", ok.address);
    try std.testing.expectEqual(@as(u16, 50051), ok.port);
    for ([_][]const u8{ "[::1]:50051", "::1:50051", "[::]:50051", "grpc.example:50051" }) |v6| {
        try std.testing.expectError(error.GrpcListenAddressNotIpv4, cli_args.resolveGrpcBind(v6, null));
    }
    for ([_][]const u8{ "127.0.0.1:+80", "127.0.0.1:", "127.0.0.1:grpc", "[::1]:x", "1_000" }) |bad| {
        try std.testing.expectError(error.InvalidGrpcListenPort, cli_args.resolveGrpcBind(bad, null));
    }
    // A port alone binds the QUIC listener's IPv4 address; beside an IPv6
    // QUIC listener it is refused, not widened to 0.0.0.0 (SONNY-6494).
    const same = try cli_args.resolveGrpcBind("50051", "127.0.0.2:3141");
    try std.testing.expectEqualStrings("127.0.0.2", same.address);
    try std.testing.expectError(error.GrpcPortOnlyListenNotIpv4, cli_args.resolveGrpcBind("50051", "[::1]:3141"));
}

test "SONNY-6487: cluster peer specs with bracketed IPv6 hosts are loopback, not DNS names" {
    const specs = [_][]const u8{ "[::1]:4242", "127.0.0.1:4243" };
    const id = cluster_bootstrap.computeSelfIdentity(&specs, "");
    try std.testing.expect(!id.any_dns_peer);
    const dns = [_][]const u8{ "[::1]:4242", "geode-1.geode:4242" };
    try std.testing.expect(cluster_bootstrap.computeSelfIdentity(&dns, "").any_dns_peer);
}

test "SONNY-6487: cluster peer specs parse with the shared grammar" {
    const P = struct { spec: []const u8, host: []const u8, port: u16 };
    for ([_]P{
        .{ .spec = "[::1]:4242", .host = "::1", .port = 4242 },
        .{ .spec = "[fd00::5]:14244", .host = "fd00::5", .port = 14244 },
        .{ .spec = "127.0.0.2:4242", .host = "127.0.0.2", .port = 4242 },
        .{ .spec = "geode-0.geode:4242", .host = "geode-0.geode", .port = 4242 },
    }) |c| {
        const hp = try cluster_bootstrap.parsePeerSpec(c.spec);
        try std.testing.expectEqualStrings(c.host, hp.host);
        try std.testing.expectEqual(c.port, hp.port);
    }
    for ([_][]const u8{ "::1:4242", "[::1]", "127.0.0.1", ":4242", "127.0.0.1:99999", "127.0.0.1:+1", "[::1]:x" }) |bad| {
        try std.testing.expectError(error.InvalidPeerSpec, cluster_bootstrap.parsePeerSpec(bad));
    }
}
