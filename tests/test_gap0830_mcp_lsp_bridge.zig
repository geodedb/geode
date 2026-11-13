// GAP-0830: MCP/LSP bridge contract governance test.
//
// src/mcp/lsp.zig is the bridge between the MCP server's `tools/call`
// dispatch and Geode's GQL language services. Four MCP tool names
// (validate / complete / hover / diagnostics) route through tools.zig
// to the four public entry points exercised here. This test pins the
// bridge contract documented in docs/MCP_LSP_BRIDGE.md so the
// REQ-MCP-LSP-BRIDGE-001 CANARY in src/mcp/lsp.zig is genuinely TESTED:
//
//   - each entry point returns a non-empty JSON document the caller owns;
//   - validate/diagnostics report parse errors as diagnostics;
//   - the GAP-0819 input chokepoint rejects oversize/empty/NUL input
//     uniformly (no crash, structured rejection);
//   - hover resolves known keywords and yields a null-contents response
//     (`{"contents":null}`) for unknown words;
//   - complete on an empty document offers the clause keywords (SONNY-6484);
//   - the contract entry points are pure (no global mutation) — verified
//     implicitly by the std.testing.allocator leak checker.

const std = @import("std");
const bridge = @import("mcp_bridge");
const lsp = bridge.lsp;

test "GAP-0830: validate returns a JSON ValidationResponse for a valid query" {
    const allocator = std.testing.allocator;
    const resp = try lsp.validateQuery(allocator, "MATCH (n) RETURN n");
    defer allocator.free(resp);

    try std.testing.expect(resp.len > 0);
    // ValidationResponse shape: {"isValid":..., "diagnostics":[...]}.
    try std.testing.expect(std.mem.indexOf(u8, resp, "isValid") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "diagnostics") != null);
}

test "GAP-0830: validate surfaces parse errors as diagnostics for an invalid query" {
    const allocator = std.testing.allocator;
    const resp = try lsp.validateQuery(allocator, "MATCH ( RETURN");
    defer allocator.free(resp);

    try std.testing.expect(resp.len > 0);
    // An invalid query must not claim validity.
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"isValid\":false") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "diagnostics") != null);
}

test "GAP-0830: getDiagnostics is a behavioural alias of validateQuery" {
    const allocator = std.testing.allocator;
    const query = "MATCH (n) RETURN n";

    const via_validate = try lsp.validateQuery(allocator, query);
    defer allocator.free(via_validate);
    const via_diagnostics = try lsp.getDiagnostics(allocator, query);
    defer allocator.free(via_diagnostics);

    try std.testing.expectEqualStrings(via_validate, via_diagnostics);
}

test "GAP-0830: complete returns a JSON CompletionResponse" {
    const allocator = std.testing.allocator;
    // A non-empty query (empty input is rejected by the GAP-0819 chokepoint).
    // Cursor at the start of the statement should offer completions.
    const resp = try lsp.getCompletions(allocator, "MATCH", 1, 1);
    defer allocator.free(resp);

    try std.testing.expect(resp.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, resp, "completions") != null);
}

test "GAP-0830: hover resolves a known keyword" {
    const allocator = std.testing.allocator;
    // Cursor inside the MATCH keyword (line 1, column 2).
    const resp = try lsp.getHover(allocator, "MATCH (n) RETURN n", 1, 2);
    defer allocator.free(resp);

    try std.testing.expect(resp.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, resp, "contents") != null);
    // Known keyword => non-null contents documenting it.
    try std.testing.expect(std.mem.indexOf(u8, resp, "MATCH") != null);
}

test "GAP-0830: hover returns empty contents for an unknown word" {
    const allocator = std.testing.allocator;
    // An identifier with no language-metadata entry => a HoverResponse whose
    // `contents` is null (docs/MCP_LSP_BRIDGE.md). SONNY-6484: the field is
    // emitted as `null`; the JSON library's default dropped it (`{}`).
    const resp = try lsp.getHover(allocator, "RETURN xyz123", 1, 9);
    defer allocator.free(resp);

    try std.testing.expectEqualStrings("{\"contents\":null}", resp);
}

test "SONNY-6484: complete on an empty document offers the clause keywords" {
    const allocator = std.testing.allocator;
    const resp = try lsp.getCompletions(allocator, "", 1, 1);
    defer allocator.free(resp);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"completions\":[") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"label\":\"MATCH\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, resp, "isValid") == null);
}

test "GAP-0830: input chokepoint rejects empty input on validate and diagnostics" {
    const allocator = std.testing.allocator;

    // GAP-0819 / LSP-SEC-007: empty query is rejected structurally and
    // surfaced as a diagnostic-shaped rejection, not a crash.
    const v = try lsp.validateQuery(allocator, "");
    defer allocator.free(v);
    try std.testing.expect(v.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, v, "\"isValid\":false") != null);

    const d = try lsp.getDiagnostics(allocator, "");
    defer allocator.free(d);
    try std.testing.expect(std.mem.indexOf(u8, d, "\"isValid\":false") != null);
}

test "GAP-0830: input chokepoint rejects an embedded NUL byte" {
    const allocator = std.testing.allocator;
    const malicious = "MATCH (n)\x00 RETURN n";

    // Must not crash; must return a structured rejection document.
    const resp = try lsp.validateQuery(allocator, malicious);
    defer allocator.free(resp);
    try std.testing.expect(resp.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"isValid\":false") != null);
}

test "GAP-0830: input chokepoint rejects oversize input (> MAX_GQL_TEXT)" {
    const allocator = std.testing.allocator;

    // One byte past the documented 1 MiB cap.
    const big = try allocator.alloc(u8, lsp.MAX_GQL_TEXT + 1);
    defer allocator.free(big);
    @memset(big, 'a');

    const resp = try lsp.validateQuery(allocator, big);
    defer allocator.free(resp);
    try std.testing.expect(resp.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, resp, "\"isValid\":false") != null);
}
