//! GAP-0875c: MCP tool dispatch honours the cancellation token.
//!
//! Before GAP-0875 `tools.callTool` discarded the `mcp.CancelToken`
//! (`_ = cancel; // TODO`), so a request cancelled via
//! `notifications/cancelled` still ran its (potentially blocking) QUIC
//! round-trip. The smallest honest propagation is the pre-flight check:
//! a token that is already cancelled must short-circuit before any tool
//! work (or network connection) starts.
//
// CANARY: REQ=GAP-0875; FEATURE="ResidualStubsBatch"; ASPECT=McpCancellation; STATUS=TESTED; TEST=tests/test_gap0875_stubs_mcp.zig; OWNER=mcp; UPDATED=2026-06-11

const std = @import("std");
const mcp = @import("mcp");
const tools = @import("mcp_tools");
const geode = @import("geode");

const principal_mod = geode.security.principal;

fn testPrincipal() tools.Principal {
    const role_names = [_][]const u8{"User"};
    return .{
        .user_id = null,
        .username = "mcp-user",
        .session_id = null,
        .tenant_id = null,
        .active_graph = null,
        .roles = &role_names,
        .custom_roles = &.{},
        .auth_method = .api_key,
        .auth_version = 0,
        .mfa_state = .none,
        .elevation_until = null,
        .api_key_id = null,
        .certificate_subject = null,
        .risk_context = principal_mod.RiskContext.unknown,
        .attributes = principal_mod.AttributeMap.emptySentinel(),
        .source = .mcp_handler,
    };
}

test "GAP-0875c: pre-cancelled token short-circuits callTool with error.Cancelled" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var token = mcp.CancelToken{};
    token.cancel();

    const p = testPrincipal();
    // "query" would normally attempt a QUIC connection; a cancelled token
    // must return before any client work begins.
    const result = tools.callTool(allocator, null, false, &p, "query", "{\"query\":\"RETURN 1\"}", &token);
    try std.testing.expectError(error.Cancelled, result);
}

test "GAP-0875c: non-cancelled token still dispatches (unknown tool control)" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();

    var token = mcp.CancelToken{};
    const p = testPrincipal();
    const result = tools.callTool(allocator, null, false, &p, "no-such-tool", "{}", &token);
    // SONNY-6552: an unknown tool is error.InvalidParams (the library's
    // -32602, MCP 2025-11-25's protocol error for an unknown tool).
    try std.testing.expectError(error.InvalidParams, result);
}
