//! Shared network bind-policy helpers (std-only, no geode dependencies).
//!
//! LSP-SEC-008: loopback classification is a security control — the LSP
//! standalone listener (src/cli/lsp/server.zig) and the MCP HTTP transport
//! (src/mcp/server.zig) both refuse unauthenticated non-loopback binds based
//! on this predicate. It lives here as the single implementation so the two
//! enforcement sites cannot drift; both re-export it under their historical
//! names (`isLoopbackHost` / `isLoopbackBind`).

const std = @import("std");

/// LSP-SEC-008: classify a bind host string as loopback. Accepts the
/// IPv4 loopback block (127.0.0.0/8), IPv6 `::1` (bracketed or bare), and
/// the literal `localhost`. Anything else — including the wildcard binds
/// `0.0.0.0` / `::` and any routable address — is non-loopback.
pub fn isLoopbackHost(host: []const u8) bool {
    if (std.mem.eql(u8, host, "localhost")) return true;
    const h = std.mem.trim(u8, host, "[]");
    if (std.mem.eql(u8, h, "::1")) return true;
    if (std.mem.startsWith(u8, h, "127.")) {
        // Require the remainder to look like an IPv4 tail (digits/dots only)
        // so e.g. "127.evil.example" does not classify as loopback.
        for (h["127.".len..]) |c| {
            if (!(std.ascii.isDigit(c) or c == '.')) return false;
        }
        return h.len > "127.".len;
    }
    return false;
}

test "isLoopbackHost classification" {
    try std.testing.expect(isLoopbackHost("127.0.0.1"));
    try std.testing.expect(isLoopbackHost("127.9.8.7"));
    try std.testing.expect(isLoopbackHost("127.255.0.42"));
    try std.testing.expect(isLoopbackHost("::1"));
    try std.testing.expect(isLoopbackHost("[::1]"));
    try std.testing.expect(isLoopbackHost("localhost"));
    try std.testing.expect(!isLoopbackHost("0.0.0.0"));
    try std.testing.expect(!isLoopbackHost("::"));
    try std.testing.expect(!isLoopbackHost("192.168.1.5"));
    try std.testing.expect(!isLoopbackHost("10.0.0.7"));
    try std.testing.expect(!isLoopbackHost("example.com"));
    try std.testing.expect(!isLoopbackHost("1270.0.0.1"));
    try std.testing.expect(!isLoopbackHost("127.evil.example"));
    try std.testing.expect(!isLoopbackHost("127."));
}
