// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2026 CodePros
// CANARY: REQ=REQ-NET-HOSTPORT-6487; FEATURE="Shared host:port parser"; ASPECT=AddressGrammar; STATUS=TESTED; TEST=tests/test_sonny6487_host_port.zig; OWNER=transport; UPDATED=2026-11-13

//! The one `host:port` grammar every Geode address uses (client `--server`,
//! `geode serve --listen`/`--listen-grpc`, cluster peers, the LSP and syslog
//! listeners, Kafka brokers, KMS endpoints). docs/DSN.md, "Host
//! Specification":
//!
//!   host | host:port | :port | [ipv6] | [ipv6]:port
//!
//! An IPv6 address is always bracketed and may carry a zone
//! (`[fe80::1%eth0]:3141`); the brackets are stripped from `host`. An
//! unbracketed host with more than one colon (a bare IPv6 literal such as
//! `::1`) is refused: splitting it on the last colon read `::1` as host `:`
//! port 1. A port is 1-5 ASCII digits in 0..65535; anything else (empty,
//! `+80`, `3_141`, `http`, 70000) is refused, never replaced by a default.
//! SONNY-6569: an unbracketed host is a host name or IPv4 address: ASCII
//! letters, digits, `-`, `.`, `_` and `~` only. An `@` (a credential:
//! `--server pw@host:3141` dialled a host named `pw@host`), a path, a query,
//! whitespace, control bytes and anything else are refused, so none of it
//! reaches the resolver or the TLS server name.
//! The module depends only on std so every build module can compile it.

const std = @import("std");

pub const HostPort = struct {
    /// Without brackets; empty for `:port`.
    host: []const u8,
    port: u16,
    /// The host as written, brackets included (`[::1]`): what a
    /// `"{host}:{port}"` formatter needs to produce a parseable address.
    host_literal: []const u8,
};

pub const Error = error{
    /// Empty input, unterminated or misplaced brackets, a bracketed host that
    /// is not an IPv6 literal, a bare IPv6 literal, or an unbracketed host
    /// with a byte a host name cannot hold (`isHostName`).
    InvalidAddress,
    /// The port is missing, not 1-5 digits, or above 65535.
    InvalidPort,
};

/// Split `addr`. With `default_port` null the port is required; otherwise a
/// host without `:port` takes `default_port`.
pub fn split(addr: []const u8, default_port: ?u16) Error!HostPort {
    if (addr.len == 0) return error.InvalidAddress;
    if (addr[0] == '[') {
        const close = std.mem.indexOfScalar(u8, addr, ']') orelse return error.InvalidAddress;
        const host = addr[1..close];
        if (!isIpv6Literal(host)) return error.InvalidAddress;
        const rest = addr[close + 1 ..];
        const port = if (rest.len == 0)
            default_port orelse return error.InvalidPort
        else if (rest[0] != ':')
            return error.InvalidAddress
        else
            try parsePort(rest[1..]);
        return .{ .host = host, .port = port, .host_literal = addr[0 .. close + 1] };
    }
    if (std.mem.indexOfScalar(u8, addr, ']') != null) return error.InvalidAddress;
    const colon = std.mem.indexOfScalar(u8, addr, ':') orelse {
        if (!isHostName(addr)) return error.InvalidAddress;
        return .{ .host = addr, .port = default_port orelse return error.InvalidPort, .host_literal = addr };
    };
    if (std.mem.indexOfScalarPos(u8, addr, colon + 1, ':') != null) return error.InvalidAddress;
    const host = addr[0..colon];
    if (!isHostName(host)) return error.InvalidAddress;
    return .{ .host = host, .port = try parsePort(addr[colon + 1 ..]), .host_literal = host };
}

/// SONNY-6569: an unbracketed host (a name or an IPv4 address, or empty
/// for `:port`): ASCII letters, digits, `-`, `.`, `_` and `~` (RFC 3986
/// unreserved characters).
pub fn isHostName(host: []const u8) bool {
    for (host) |c| {
        if (!(std.ascii.isAlphanumeric(c) or c == '-' or c == '.' or c == '_' or c == '~')) return false;
    }
    return true;
}

/// A port: 1-5 ASCII digits whose value fits in u16. `std.fmt.parseInt`
/// alone also accepts a sign and `_` separators.
pub fn parsePort(text: []const u8) Error!u16 {
    if (text.len == 0 or text.len > 5) return error.InvalidPort;
    for (text) |c| if (!std.ascii.isDigit(c)) return error.InvalidPort;
    return std.fmt.parseInt(u16, text, 10) catch error.InvalidPort;
}

/// An IPv6 address, optionally with a `%zone` suffix (no brackets).
pub fn isIpv6Literal(text: []const u8) bool {
    return switch (std.Io.net.Ip6Address.Unresolved.parse(text)) {
        .success => true,
        else => false,
    };
}

/// `host:port`, with the host bracketed when it is an IPv6 literal, so that
/// `split` (and the QUIC library's address parser) reads it back.
pub fn formatAlloc(allocator: std.mem.Allocator, host: []const u8, port: u16) ![]u8 {
    if (std.mem.indexOfScalar(u8, host, ':') != null)
        return std.fmt.allocPrint(allocator, "[{s}]:{d}", .{ host, port });
    return std.fmt.allocPrint(allocator, "{s}:{d}", .{ host, port });
}
