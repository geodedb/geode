//! GAP-0885b — LSP/MCP hardening batch (LSP-SEC-002 / LSP-SEC-005 / LSP-SEC-008).
//!
//! Three independent assertions, one per tracker row:
//!
//!   - LSP-SEC-005: `textDocument/publishDiagnostics` must emit RFC-3986
//!     percent-encoded URIs. File paths with spaces, `#`, non-ASCII bytes,
//!     or JSON-breaking bytes (`"`, `\`, control chars) must be escaped.
//!     Pinned via the exported `lsp_server.percentEncodeUri` helper that
//!     `Server.sendDiagnostics` routes every outgoing URI through.
//!
//!   - LSP-SEC-008 (LSP side): a non-loopback TCP bind is only legal for
//!     authenticated listeners. `lsp_server.validateBindPolicy` is the
//!     single source of truth, called by both bind sites
//!     (src/server/main.zig:runLspListener and src/cli/main.zig --listen).
//!     The legitimate authenticated `--lsp-bind-all` path (verifier
//!     present, allow_unauth=false) must keep working (SEC-LSP-BIND-01).
//!
//!   - LSP-SEC-008 (MCP side): constructing `GeodeMcpServer` with
//!     `auth_mode = .none` and a non-loopback `http_bind` must fail at
//!     init with `error.InsecureNoAuthBind`.
//!
//!   - LSP-SEC-002 (boundary pins): the vendored `mcp` library's bearer
//!     compare (mcp.zig checkAuth, `std.mem.eql`) is NOT constant-time and
//!     cannot be edited in the pinned package. Geode's boundary posture is
//!     pinned instead: the HTTP transport's default bind is loopback (the
//!     CLI never exposes `http_bind`), so the timing oracle is reachable
//!     only by local processes. Geode-owned token comparisons are already
//!     constant-time (auth_lib api_keys: SHA-256 + timing_safe.eql;
//!     src/security/authn.zig:526 session tokens: timing_safe.eql).
//!
//! Build step: `zig build test-gap0885-lsp`

const std = @import("std");
const lsp_server = @import("lsp_server");
const mcp_server = @import("mcp_server");

// ---------------------------------------------------------------------------
// LSP-SEC-005 — publishDiagnostics URI percent-encoding
// ---------------------------------------------------------------------------

test "LSP-SEC-005: percentEncodeUri encodes spaces, '#', and non-ASCII (RFC 3986)" {
    const a = std.testing.allocator;
    // "my doc#1ü.gql" — space, fragment delimiter, and a 2-byte UTF-8 char.
    const out = try lsp_server.percentEncodeUri(a, "file:///tmp/my doc#1\xc3\xbc.gql");
    defer a.free(out);
    try std.testing.expectEqualStrings("file:///tmp/my%20doc%231%C3%BC.gql", out);
}

test "LSP-SEC-005: percentEncodeUri passes a valid already-encoded URI through unchanged" {
    const a = std.testing.allocator;
    const valid = "file:///home/benji/queries/match%20all.gql";
    const out = try lsp_server.percentEncodeUri(a, valid);
    defer a.free(out);
    try std.testing.expectEqualStrings(valid, out);
}

test "LSP-SEC-005: percentEncodeUri encodes JSON-breaking bytes (quote, backslash, control)" {
    const a = std.testing.allocator;
    const out = try lsp_server.percentEncodeUri(a, "file:///a\"b\\c\nd.gql");
    defer a.free(out);
    // Every byte that could break out of the JSON string literal is
    // percent-encoded, so the manually-built publishDiagnostics envelope
    // stays well-formed for any URI the client handed us.
    try std.testing.expectEqualStrings("file:///a%22b%5Cc%0Ad.gql", out);
}

test "LSP-SEC-005: percentEncodeUri keeps RFC-3986 reserved/unreserved bytes intact" {
    const a = std.testing.allocator;
    const uri = "untitled:Untitled-1?x=1&y=(2);z='3'";
    const out = try lsp_server.percentEncodeUri(a, uri);
    defer a.free(out);
    try std.testing.expectEqualStrings(uri, out);
}

// ---------------------------------------------------------------------------
// LSP-SEC-008 (LSP) — non-loopback bind requires authentication
// ---------------------------------------------------------------------------

test "LSP-SEC-008: loopback binds are always allowed" {
    try lsp_server.validateBindPolicy(.{ .loopback_only = true, .allow_unauth = false, .has_verifier = false });
    try lsp_server.validateBindPolicy(.{ .loopback_only = true, .allow_unauth = true, .has_verifier = false });
    try lsp_server.validateBindPolicy(.{ .loopback_only = true, .allow_unauth = false, .has_verifier = true });
}

test "LSP-SEC-008: non-loopback bind with allow_unauth (.none auth) is refused" {
    try std.testing.expectError(
        error.InsecureNonLoopbackBind,
        lsp_server.validateBindPolicy(.{ .loopback_only = false, .allow_unauth = true, .has_verifier = true }),
    );
    try std.testing.expectError(
        error.InsecureNonLoopbackBind,
        lsp_server.validateBindPolicy(.{ .loopback_only = false, .allow_unauth = true, .has_verifier = false }),
    );
}

test "LSP-SEC-008: non-loopback bind without a verifier is refused (fail-closed, not bound)" {
    try std.testing.expectError(
        error.InsecureNonLoopbackBind,
        lsp_server.validateBindPolicy(.{ .loopback_only = false, .allow_unauth = false, .has_verifier = false }),
    );
}

test "SEC-LSP-BIND-01: authenticated --lsp-bind-all path stays legal (verifier present)" {
    // The embedded `geode serve --lsp-bind-all` listener always carries a
    // verifier built from the live AuthProvider; the hardening guard must
    // not break it.
    try lsp_server.validateBindPolicy(.{ .loopback_only = false, .allow_unauth = false, .has_verifier = true });
}

test "LSP-SEC-008: isLoopbackHost classification" {
    try std.testing.expect(lsp_server.isLoopbackHost("127.0.0.1"));
    try std.testing.expect(lsp_server.isLoopbackHost("127.9.8.7"));
    try std.testing.expect(lsp_server.isLoopbackHost("::1"));
    try std.testing.expect(lsp_server.isLoopbackHost("[::1]"));
    try std.testing.expect(lsp_server.isLoopbackHost("localhost"));
    try std.testing.expect(!lsp_server.isLoopbackHost("0.0.0.0"));
    try std.testing.expect(!lsp_server.isLoopbackHost("::"));
    try std.testing.expect(!lsp_server.isLoopbackHost("192.168.1.5"));
    try std.testing.expect(!lsp_server.isLoopbackHost("example.com"));
    try std.testing.expect(!lsp_server.isLoopbackHost("1270.0.0.1"));
}

// ---------------------------------------------------------------------------
// LSP-SEC-008 (MCP) — auth_mode=.none hard-asserts a loopback http_bind
// ---------------------------------------------------------------------------

test "LSP-SEC-008: GeodeMcpServer.init refuses .none auth with non-loopback http_bind" {
    const a = std.testing.allocator;
    const result = mcp_server.GeodeMcpServer.init(a, .{
        .geode_endpoint = "localhost:3141",
        .auth_mode = .none,
        .http_bind = "0.0.0.0",
    });
    try std.testing.expectError(error.InsecureNoAuthBind, result);
}

test "LSP-SEC-008: GeodeMcpServer.init allows .none auth on loopback binds" {
    const a = std.testing.allocator;
    inline for (.{ "127.0.0.1", "::1", "localhost" }) |bind| {
        const server = try mcp_server.GeodeMcpServer.init(a, .{
            .geode_endpoint = "localhost:3141",
            .auth_mode = .none,
            .http_bind = bind,
        });
        server.deinit();
    }
}

test "LSP-SEC-008: GeodeMcpServer.init allows authenticated (.bearer) non-loopback bind" {
    const a = std.testing.allocator;
    const server = try mcp_server.GeodeMcpServer.init(a, .{
        .geode_endpoint = "localhost:3141",
        .auth_mode = .bearer,
        .bearer_token = "test-token-gap0885",
        .http_bind = "0.0.0.0",
    });
    server.deinit();
}

// ---------------------------------------------------------------------------
// LSP-SEC-002 — boundary posture pins for the vendored timing-unsafe compare
// ---------------------------------------------------------------------------

test "LSP-SEC-002: MCP Options default http_bind is loopback (vendored bearer compare stays local-only)" {
    // The vendored mcp library compares the HTTP bearer token with
    // std.mem.eql (NOT constant-time) inside its private checkAuth — geode
    // cannot edit the pinned package. The boundary mitigation is that the
    // HTTP transport's bind defaults to loopback and the geode CLI never
    // exposes http_bind, so the timing oracle is reachable only from the
    // local host. This pin trips if anyone widens the default.
    const opts = mcp_server.GeodeMcpServer.Options{};
    try std.testing.expect(mcp_server.isLoopbackBind(opts.http_bind));
}

test "LSP-SEC-002: isLoopbackBind classification" {
    try std.testing.expect(mcp_server.isLoopbackBind("127.0.0.1"));
    try std.testing.expect(mcp_server.isLoopbackBind("127.255.0.42"));
    try std.testing.expect(mcp_server.isLoopbackBind("::1"));
    try std.testing.expect(mcp_server.isLoopbackBind("[::1]"));
    try std.testing.expect(mcp_server.isLoopbackBind("localhost"));
    try std.testing.expect(!mcp_server.isLoopbackBind("0.0.0.0"));
    try std.testing.expect(!mcp_server.isLoopbackBind("::"));
    try std.testing.expect(!mcp_server.isLoopbackBind("10.0.0.7"));
    try std.testing.expect(!mcp_server.isLoopbackBind("1270.0.0.1"));
}
