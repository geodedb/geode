// SPDX-License-Identifier: Apache-2.0
const std = @import("std");
const endpoint_host = @import("quic_endpoint_host");

const DnsProbe = struct {
    var calls: usize = 0;
    var correct_name: bool = false;
    var correct_family: bool = false;
    var fail: bool = false;

    fn lookup(userdata: ?*anyopaque, name: std.Io.net.HostName, results: *std.Io.Queue(std.Io.net.HostName.LookupResult), options: std.Io.net.HostName.LookupOptions) std.Io.net.HostName.LookupError!void {
        const threaded: *std.Io.Threaded = @ptrCast(@alignCast(userdata.?));
        const io = threaded.io();
        defer results.close(io);
        calls += 1;
        correct_name = std.mem.eql(u8, name.bytes, "geode.local");
        correct_family = options.family == .ip4;
        if (fail) return error.UnknownHostName;
        results.putOne(io, .{ .address = .{ .ip4 = .{ .bytes = .{ 192, 0, 2, 18 }, .port = options.port } } }) catch |err| switch (err) {
            error.Canceled => return error.Canceled,
            error.Closed => unreachable,
        };
    }
};

test "service_hostname_uses_dns_instead_of_ip_parsing" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var io = threaded.io();
    var vtable = io.vtable.*;
    vtable.netLookup = DnsProbe.lookup;
    io.vtable = &vtable;
    DnsProbe.calls = 0;
    DnsProbe.fail = false;
    const resolved = try endpoint_host.resolveWithIoAlloc(std.testing.allocator, io, "geode.local");
    defer std.testing.allocator.free(resolved);
    try std.testing.expectEqualStrings("192.0.2.18", resolved);
    try std.testing.expectEqual(@as(usize, 1), DnsProbe.calls);
    try std.testing.expect(DnsProbe.correct_name and DnsProbe.correct_family);
}

test "dns_failure_is_returned_without_selecting_a_local_address" {
    var threaded = std.Io.Threaded.init(std.testing.allocator, .{});
    defer threaded.deinit();
    var io = threaded.io();
    var vtable = io.vtable.*;
    vtable.netLookup = DnsProbe.lookup;
    io.vtable = &vtable;
    DnsProbe.calls = 0;
    DnsProbe.fail = true;
    defer DnsProbe.fail = false;
    try std.testing.expectError(error.UnknownHostName, endpoint_host.resolveWithIoAlloc(std.testing.allocator, io, "geode.local"));
    try std.testing.expectEqual(@as(usize, 1), DnsProbe.calls);
}

test "ip_literals_remain_owned_and_unchanged" {
    for ([_][]const u8{ "127.0.0.1", "192.0.2.18", "::1", "[::1]" }) |host| {
        const resolved = try endpoint_host.resolveAlloc(std.testing.allocator, host);
        defer std.testing.allocator.free(resolved);
        try std.testing.expectEqualStrings(host, resolved);
        try std.testing.expect(resolved.ptr != host.ptr);
    }
}

test "localhost_resolves_to_an_ipv4_transport_address_without_rewriting_the_name" {
    const host = "localhost";
    const resolved = try endpoint_host.resolveAlloc(std.testing.allocator, host);
    defer std.testing.allocator.free(resolved);
    const address = try std.Io.net.IpAddress.parseIp4(resolved, 0);
    try std.testing.expectEqual(@as(u8, 127), address.ip4.bytes[0]);
    try std.testing.expectEqualStrings("localhost", host);
}

test "invalid_hostnames_are_rejected_without_a_transport_fallback" {
    for ([_][]const u8{ "", "bad host", "-invalid.local" }) |host| {
        try std.testing.expectError(error.InvalidHostName, endpoint_host.resolveAlloc(std.testing.allocator, host));
    }
}
