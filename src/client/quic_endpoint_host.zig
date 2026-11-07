// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 CodePros
// CANARY: REQ=REQ-CLI-DNS-5077; FEATURE="CLI QUIC hostname resolution"; ASPECT=HostnameResolution; STATUS=TESTED; TEST=tests/test_5077_quic_endpoint_host.zig; OWNER=cli; UPDATED=2026-11-07

const std = @import("std");

/// Resolve the transport address without changing the caller's TLS peer name.
/// The Zig client's QUIC endpoint binds IPv4, so hostname lookups select IPv4.
/// Existing IP literals retain their representation and require no DNS query.
/// The caller owns the returned address; the original host remains unchanged.
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
    if (std.Io.net.IpAddress.parse(host, 0)) |_| {
        return allocator.dupe(u8, host);
    } else |_| {}
    if (std.Io.net.IpAddress.parseLiteral(host)) |_| {
        return allocator.dupe(u8, host);
    } else |_| {}

    const name = try std.Io.net.HostName.init(host);
    var storage: [16]std.Io.net.HostName.LookupResult = undefined;
    var results: std.Io.Queue(std.Io.net.HostName.LookupResult) = .init(&storage);
    // The standard resolver honours hosts/resolver configuration. Its API
    // guarantees this synchronous lookup cannot block on a queue of 16 items.
    try name.lookup(io, &results, .{ .port = 0, .family = .ip4 });
    while (results.getOne(io)) |result| switch (result) {
        .address => |address| switch (address) {
            .ip4 => |ip| return std.fmt.allocPrint(allocator, "{d}.{d}.{d}.{d}", .{
                ip.bytes[0], ip.bytes[1], ip.bytes[2], ip.bytes[3],
            }),
            .ip6 => continue,
        },
        .canonical_name => continue,
    } else |err| switch (err) {
        error.Canceled => return error.Canceled,
        error.Closed => return error.NoAddressReturned,
    }
}
