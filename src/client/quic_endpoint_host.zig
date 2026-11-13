// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 CodePros
// CANARY: REQ=REQ-CLI-DNS-5077; FEATURE="CLI QUIC hostname resolution"; ASPECT=HostnameResolution; STATUS=TESTED; TEST=tests/test_5077_quic_endpoint_host.zig; OWNER=cli; UPDATED=2026-11-13

const std = @import("std");
const isIpv6Literal = @import("host_port.zig").isIpv6Literal;

/// Resolve the transport address without changing the caller's TLS peer name.
/// SONNY-6487: a host name is looked up in both address families and the
/// first IPv4 address wins: geode-client-zig binds its QUIC endpoint to
/// 0.0.0.0:0 and formats the dial address without brackets, so it can reach
/// only IPv4. An IPv6 literal, or a name with only IPv6 addresses, is refused
/// with `error.Ipv6EndpointUnsupported` instead of failing later as a bare
/// InvalidAddress. An IPv4 literal keeps its representation and needs no DNS
/// query. The caller owns the returned address; the original host remains
/// unchanged.
pub fn resolveAlloc(allocator: std.mem.Allocator, host: []const u8) ![]u8 {
    // Supply an allocator without changing process-wide signal handlers. The
    // global single-threaded Io uses a failing allocator, and transient
    // Threaded.init instances would install/restore global signal handlers.
    var threaded: std.Io.Threaded = .init_single_threaded;
    threaded.allocator = allocator;
    defer threaded.deinit();
    return resolveWithIoAlloc(allocator, threaded.io(), host);
}

pub fn resolveWithIoAlloc(allocator: std.mem.Allocator, io: std.Io, host: []const u8) ![]u8 {
    if (std.Io.net.Ip4Address.parse(host, 0)) |_| {
        return allocator.dupe(u8, host);
    } else |_| {}
    const unbracketed = if (host.len >= 2 and host[0] == '[' and host[host.len - 1] == ']') host[1 .. host.len - 1] else host;
    if (isIpv6Literal(unbracketed)) return error.Ipv6EndpointUnsupported;

    const name = try std.Io.net.HostName.init(host);
    var storage: [32]std.Io.net.HostName.LookupResult = undefined;
    var results: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&storage);
    // The standard resolver honours hosts/resolver configuration. Its API
    // guarantees this synchronous lookup cannot block on a queue of 32 items.
    try name.lookup(io, &results, .{ .port = 0, .family = null });
    var saw_ip6 = false;
    while (results.getOne(io)) |result| switch (result) {
        .address => |address| switch (address) {
            .ip4 => |ip| return std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}", .{
                ip.bytes[0], ip.bytes[1], ip.bytes[2], ip.bytes[3],
            }),
            .ip6 => saw_ip6 = true,
        },
        .canonical_name => continue,
    } else |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.Closed => return if (saw_ip6) error.Ipv6EndpointUnsupported else error.NoAddressReturned,
    }
}
