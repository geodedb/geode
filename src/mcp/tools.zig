const std = @import("std");

// CANARY: REQ=REQ-LIB-MIGRATION-MCP-002; FEATURE="External Library Migration"; ASPECT=MCPTools; STATUS=TESTED; OWNER=core; UPDATED=2026-01-24
// MCP Tools for Geode - GQL query execution, schema introspection, graph operations, and LSP features
const mcp = @import("mcp");

// CANARY: REQ=REQ-LIB-MIGRATION-JSON-038; FEATURE="JSON Library Migration"; ASPECT=MCPTools; STATUS=TESTED; OWNER=mcp; UPDATED=2026-01-24
const json_lib = @import("json");

const GeodeClient = @import("client.zig").GeodeClient;
const lsp = @import("lsp.zig");

// CANARY: REQ=REQ-GPS-MCP-001; FEATURE="GPS MCP Principal"; ASPECT=ToolsThreading; STATUS=TESTED; TEST=tests/test_gps_mcp_principal.zig; OWNER=security; UPDATED=2026-05-21
// GPS Phase 5: callTool now receives the per-server MCP Principal so each tool
// dispatch can forward it to any downstream execution context.  The Principal is
// available to every tool function through the `caller` parameter.
//
// GPS Phase 6 — local-closure assessment (Task 6-5):
// The MCP tools route ALL queries through GeodeClient → QUIC → remote executor.
// There is no safe in-process local-executor path: executeProgramWithContext()
// requires the full server globals (catalog singleton, WAL, store handles, etc.)
// that are only initialised in the QUIC server binary; calling it from the MCP
// context without those globals would panic or corrupt state.
//
// "Option A" (thread Principal into a local ExecutionContext) is therefore not
// feasible in Phase 6.  The authoritative fix ("Option B" / Phase 7) is to add
// a `principal_envelope_bytes` field to the QUIC ExecuteRequest frame so the
// remote executor can reconstruct an ExecutionContext.principal from the
// wire-forwarded identity.
//
// GPS Phase 7 (Task 7-5) — schema extension done, send-side blocked:
// The server-side schema (src/proto/schema.zig ExecuteRequest field 4) and
// the server-side unpack (quic_connection_handler.zig) are now in place.
// The SEND side is blocked on the external geode-client-zig package (used by
// GeodeClient.query in src/mcp/client.zig) not yet emitting field 4.  Until
// a new geode-client-zig release tags the field, the Principal is available
// only for local pre-flight decide() calls at the MCP boundary (server.zig)
// and is NOT forwarded to the executor.  Site #8 remains PARTIAL (schema
// extended, receive wired; send-side requires geode-client-zig update).
const geode_security = @import("geode").security;
pub const Principal = geode_security.principal.Principal;

// MCP Tool Response Types for JSON Library encoding
// CANARY: REQ=REQ-LIB-MIGRATION-JSON-039; FEATURE="JSON Library Migration"; ASPECT=MCPResponseTypes; STATUS=TESTED; OWNER=mcp; UPDATED=2026-01-24
const McpToolContent = struct {
    type: []const u8 = "text",
    text: []const u8,
};

const McpToolResult = struct {
    content: []const McpToolContent,
    isError: bool = false,
};

const McpErrorResult = struct {
    content: []const McpToolContent,
    isError: bool = true,
};

/// List available Geode MCP tools
/// Returns JSON array of tool definitions
pub fn listTools(cursor: ?[]const u8) []const u8 {
    _ = cursor; // Pagination not needed for small tool list
    return tools_json;
}

/// Execute a Geode MCP tool.
/// SEC-08: All tool calls are gated by the MCP server's auth layer (bearer token
/// by default). The server refuses to start without a configured token unless
/// auth_mode is explicitly set to .none. See server.zig GeodeMcpServer.init.
///
/// GPS Phase 5: `caller` is the per-server MCP Principal derived at init time.
/// It carries `.source = .mcp_handler` and is available for local decide() calls.
/// GPS Phase 7 Task 7-5 status: schema + server unpack are wired; the send-side
/// in GeodeClient is blocked on the external geode-client-zig package not yet
/// emitting ExecuteRequest field 4.  The `caller` argument is retained so the
/// call site (server.zig) need not change when the external package is updated.
pub fn callTool(
    allocator: std.mem.Allocator,
    geode_endpoint: ?[]const u8,
    caller: *const Principal,
    name: []const u8,
    args_json: []const u8,
    cancel: *const mcp.CancelToken,
) ![]const u8 {
    // GAP-0875: honour the MCP cancellation token. The transport layer flips
    // the token on `notifications/cancelled`; a request that is already
    // cancelled must short-circuit BEFORE any tool work (in particular the
    // blocking QUIC round-trips below) begins. The QUIC client call itself
    // is synchronous, so the pre-flight check is the honest propagation
    // boundary today; mid-flight abort requires a cancellable client API.
    if (cancel.isCancelled()) return error.Cancelled;
    // GPS Phase 7 Task 7-5: caller Principal is available for local pre-flight
    // decide() calls at the MCP boundary (wired in server.zig).  Wire-level
    // forwarding to the remote executor requires the external geode-client-zig
    // package to emit ExecuteRequest field 4 — see header block comment.
    // Suppress unused-var warning; the field stays on the signature so the
    // Phase 7 send-side closure only needs a library update, not a signature change.
    _ = caller;

    if (std.mem.eql(u8, name, "query")) {
        return executeQuery(allocator, geode_endpoint, args_json);
    } else if (std.mem.eql(u8, name, "schema")) {
        return getSchema(allocator, geode_endpoint);
    } else if (std.mem.eql(u8, name, "explain")) {
        return explainQuery(allocator, geode_endpoint, args_json);
    } else if (std.mem.eql(u8, name, "catalogs")) {
        return listCatalogs(allocator, geode_endpoint);
    } else if (std.mem.eql(u8, name, "graphs")) {
        return listGraphs(allocator, geode_endpoint, args_json);
    } else if (std.mem.eql(u8, name, "validate")) {
        return validateGql(allocator, args_json);
    } else if (std.mem.eql(u8, name, "complete")) {
        return getCompletions(allocator, args_json);
    } else if (std.mem.eql(u8, name, "hover")) {
        return getHoverInfo(allocator, args_json);
    } else if (std.mem.eql(u8, name, "diagnostics")) {
        return getDiagnostics(allocator, args_json);
    } else {
        return error.UnknownTool;
    }
}

/// Execute a GQL query against Geode
fn executeQuery(allocator: std.mem.Allocator, endpoint: ?[]const u8, args_json: []const u8) ![]const u8 {
    // GAP-0345: argument-validation failures MUST be returned as MCP
    // tool results with `isError: true` so MCP clients see a structured
    // error rather than a raw JSON blob that the framework cannot
    // interpret. Returning the literal `{"error": "..."}` string here
    // caused MCP clients to receive `result: {"error": "..."}` without
    // any `isError` flag — clients then had no machine-readable way to
    // distinguish a successful call from a malformed argument set.
    const parsed = std.json.parseFromSlice(QueryArgs, allocator, args_json, .{}) catch {
        return try formatErrorResponse(allocator, "Invalid query arguments");
    };
    defer parsed.deinit();

    const query = parsed.value.query;
    const endpoint_str = endpoint orelse "localhost:3141";

    // Create client and execute query
    const client = GeodeClient.init(allocator, endpoint_str) catch {
        return try formatErrorResponse(allocator, "Failed to initialize client");
    };
    defer client.deinit();

    // Build params JSON if provided
    var params_json: ?[]const u8 = null;
    if (parsed.value.parameters) |p| {
        params_json = std.fmt.allocPrint(allocator, "{any}", .{std.json.fmt(p, .{})}) catch null;
    }
    defer if (params_json) |pj| allocator.free(pj);

    const result = client.query(query, params_json) catch |err| {
        return try formatErrorResponse(allocator, @errorName(err));
    };

    // GAP-0345: the QUIC server reports query-execution failures (parse
    // errors, type mismatches, runtime errors) by setting the
    // `status_class` field of the result envelope to something other
    // than the GQLSTATE success class `00000` and by carrying the
    // diagnostic in additional_statuses. The MCP client needs an
    // `isError: true` signal to distinguish these from successful
    // empty result sets — otherwise a client cannot tell whether the
    // query ran successfully or blew up. Detect a non-success status
    // class and convert it to an MCP error result; pass-through on
    // success.
    if (looksLikeQueryError(result)) {
        defer allocator.free(result);
        return try formatErrorResponse(allocator, result);
    }

    return try formatToolResult(allocator, result);
}

/// GAP-0345: lightweight detector for QUIC query-failure responses.
/// Two on-the-wire shapes carry execution failures:
///   • GQLSTATE envelope with `"status_class":"<class>"` whose class
///     is not the success class `00000`.
///   • Error object form: `"error":{"code":"<gqlstate>","message":...}`
///     attached to an otherwise empty result document.
/// Either signal means the QUIC server reported failure for the
/// query and the MCP tool result must be flagged `isError: true` so
/// MCP clients can distinguish from an empty success.  We deliberately
/// stay textual rather than re-parsing the JSON to keep the cost on
/// the happy path negligible.
fn looksLikeQueryError(payload: []const u8) bool {
    // Error-object form takes precedence — the QUIC client surfaces
    // parse / planner / runtime failures via this shape.
    if (std.mem.indexOf(u8, payload, "\"error\":{\"code\":")) |_| return true;

    const needle = "\"status_class\":\"";
    const idx = std.mem.indexOf(u8, payload, needle) orelse return false;
    const start = idx + needle.len;
    if (start + 5 > payload.len) return false;
    const class = payload[start .. start + 5];
    return !std.mem.eql(u8, class, "00000");
}

/// Get database schema information
fn getSchema(allocator: std.mem.Allocator, endpoint: ?[]const u8) ![]const u8 {
    const endpoint_str = endpoint orelse "localhost:3141";

    const client = GeodeClient.init(allocator, endpoint_str) catch {
        return try formatErrorResponse(allocator, "Failed to initialize client");
    };
    defer client.deinit();

    const result = client.getSchema() catch |err| {
        return try formatErrorResponse(allocator, @errorName(err));
    };

    return try formatToolResult(allocator, result);
}

/// Explain a GQL query plan
fn explainQuery(allocator: std.mem.Allocator, endpoint: ?[]const u8, args_json: []const u8) ![]const u8 {
    // GAP-0345: same fix as executeQuery — wrap argument parse failure
    // as a structured MCP error result rather than a raw error JSON.
    const parsed = std.json.parseFromSlice(QueryArgs, allocator, args_json, .{}) catch {
        return try formatErrorResponse(allocator, "Invalid query arguments");
    };
    defer parsed.deinit();

    const endpoint_str = endpoint orelse "localhost:3141";

    const client = GeodeClient.init(allocator, endpoint_str) catch {
        return try formatErrorResponse(allocator, "Failed to initialize client");
    };
    defer client.deinit();

    const result = client.explain(parsed.value.query) catch |err| {
        return try formatErrorResponse(allocator, @errorName(err));
    };

    return try formatToolResult(allocator, result);
}

/// List available catalogs
fn listCatalogs(allocator: std.mem.Allocator, endpoint: ?[]const u8) ![]const u8 {
    const endpoint_str = endpoint orelse "localhost:3141";

    const client = GeodeClient.init(allocator, endpoint_str) catch {
        return try formatErrorResponse(allocator, "Failed to initialize client");
    };
    defer client.deinit();

    const result = client.listCatalogs() catch |err| {
        return try formatErrorResponse(allocator, @errorName(err));
    };

    return try formatToolResult(allocator, result);
}

/// List available graphs in a catalog
fn listGraphs(allocator: std.mem.Allocator, endpoint: ?[]const u8, args_json: []const u8) ![]const u8 {
    // Parse catalog argument if provided
    var catalog: ?[]const u8 = null;
    if (args_json.len > 2) { // More than just "{}"
        const parsed = std.json.parseFromSlice(struct { catalog: ?[]const u8 = null }, allocator, args_json, .{}) catch null;
        if (parsed) |p| {
            catalog = p.value.catalog;
            defer p.deinit();
        }
    }

    const endpoint_str = endpoint orelse "localhost:3141";

    const client = GeodeClient.init(allocator, endpoint_str) catch {
        return try formatErrorResponse(allocator, "Failed to initialize client");
    };
    defer client.deinit();

    const result = client.listGraphs(catalog) catch |err| {
        return try formatErrorResponse(allocator, @errorName(err));
    };

    return try formatToolResult(allocator, result);
}

// =============================================================================
// LSP Tools - GQL validation, completions, and hover information
// =============================================================================

/// Validate a GQL query and return diagnostics
fn validateGql(allocator: std.mem.Allocator, args_json: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSlice(LspQueryArgs, allocator, args_json, .{}) catch {
        return try formatErrorResponse(allocator, "Invalid arguments: expected {\"query\": \"...\"}");
    };
    defer parsed.deinit();

    const result = lsp.validateQuery(allocator, parsed.value.query) catch |err| {
        return try formatErrorResponse(allocator, @errorName(err));
    };

    return try formatToolResult(allocator, result);
}

/// Get completions at a cursor position
fn getCompletions(allocator: std.mem.Allocator, args_json: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSlice(LspPositionArgs, allocator, args_json, .{}) catch {
        return try formatErrorResponse(allocator, "Invalid arguments: expected {\"query\": \"...\", \"line\": N, \"column\": N}");
    };
    defer parsed.deinit();

    const result = lsp.getCompletions(allocator, parsed.value.query, parsed.value.line, parsed.value.column) catch |err| {
        return try formatErrorResponse(allocator, @errorName(err));
    };

    return try formatToolResult(allocator, result);
}

/// Get hover information at a cursor position
fn getHoverInfo(allocator: std.mem.Allocator, args_json: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSlice(LspPositionArgs, allocator, args_json, .{}) catch {
        return try formatErrorResponse(allocator, "Invalid arguments: expected {\"query\": \"...\", \"line\": N, \"column\": N}");
    };
    defer parsed.deinit();

    const result = lsp.getHover(allocator, parsed.value.query, parsed.value.line, parsed.value.column) catch |err| {
        return try formatErrorResponse(allocator, @errorName(err));
    };

    return try formatToolResult(allocator, result);
}

/// Get all diagnostics for a GQL document
fn getDiagnostics(allocator: std.mem.Allocator, args_json: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSlice(LspQueryArgs, allocator, args_json, .{}) catch {
        return try formatErrorResponse(allocator, "Invalid arguments: expected {\"query\": \"...\"}");
    };
    defer parsed.deinit();

    const result = lsp.getDiagnostics(allocator, parsed.value.query) catch |err| {
        return try formatErrorResponse(allocator, @errorName(err));
    };

    return try formatToolResult(allocator, result);
}

const LspQueryArgs = struct {
    query: []const u8,
};

const LspPositionArgs = struct {
    query: []const u8,
    line: u32,
    column: u32,
};

/// Format a successful tool result for MCP response
/// CANARY: REQ=REQ-LIB-MIGRATION-JSON-040; FEATURE="JSON Library Migration"; ASPECT=ToolResult; STATUS=TESTED; OWNER=mcp; UPDATED=2026-01-24
fn formatToolResult(allocator: std.mem.Allocator, content: []const u8) ![]const u8 {
    defer allocator.free(content);

    // Build MCP tool result using JSON library (handles escaping automatically)
    const content_items = [_]McpToolContent{.{ .text = content }};
    const result = McpToolResult{
        .content = &content_items,
        .isError = false,
    };
    return try json_lib.encode(allocator, result, .{});
}

/// Format an error response for MCP
/// CANARY: REQ=REQ-LIB-MIGRATION-JSON-041; FEATURE="JSON Library Migration"; ASPECT=ErrorResult; STATUS=TESTED; OWNER=mcp; UPDATED=2026-01-24
fn formatErrorResponse(allocator: std.mem.Allocator, error_msg: []const u8) ![]const u8 {
    // Build error message with "Error: " prefix
    const error_text = try std.fmt.allocPrint(allocator, "Error: {s}", .{error_msg});
    defer allocator.free(error_text);

    const content_items = [_]McpToolContent{.{ .text = error_text }};
    const result = McpErrorResult{
        .content = &content_items,
    };
    return try json_lib.encode(allocator, result, .{});
}

const QueryArgs = struct {
    query: []const u8,
    parameters: ?std.json.Value = null,
    catalog: ?[]const u8 = null,
    graph: ?[]const u8 = null,
};

/// Static JSON definition of available tools.
/// MCP spec / framework contract (vendor/devnw/zig/mcp src/mcp.zig:1186-1188):
///   "result": {"tools": [ { name, description, inputSchema }, ... ]}
/// The framework treats this string as the literal result payload and
/// embeds it directly into the JSONRPC response on a single line. The
/// outer "tools" wrapper and single-line framing live here. Newlines are
/// avoided so newline-delimited stdio MCP transports work.
const tools_json = "{\"tools\":[" ++
    "{\"name\":\"query\",\"description\":\"Execute a GQL (Graph Query Language) query against the Geode database. Returns query results as JSON.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\",\"description\":\"The GQL query to execute (ISO/IEC 39075:2024 compliant)\"},\"parameters\":{\"type\":\"object\",\"description\":\"Optional query parameters as key-value pairs\"},\"catalog\":{\"type\":\"string\",\"description\":\"Target catalog name (default: 'default')\"},\"graph\":{\"type\":\"string\",\"description\":\"Target graph name (default: 'default')\"}},\"required\":[\"query\"]}}," ++
    "{\"name\":\"schema\",\"description\":\"Get the database schema including node labels, relationship types, and property definitions.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}," ++
    "{\"name\":\"explain\",\"description\":\"Get the execution plan for a GQL query without running it. Useful for query optimization.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\",\"description\":\"The GQL query to explain\"}},\"required\":[\"query\"]}}," ++
    "{\"name\":\"catalogs\",\"description\":\"List all available catalogs in the database.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}," ++
    "{\"name\":\"graphs\",\"description\":\"List all available graphs in the current or specified catalog.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"catalog\":{\"type\":\"string\",\"description\":\"Catalog name (default: 'default')\"}}}}," ++
    "{\"name\":\"validate\",\"description\":\"Validate GQL syntax and return diagnostics including Geode extensions (FLE, BACKUP/RESTORE, SESSION, double-dash comments). Does not require a running Geode server.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\",\"description\":\"The GQL query to validate\"}},\"required\":[\"query\"]}}," ++
    "{\"name\":\"complete\",\"description\":\"Get GQL completions at a cursor position. Returns keywords, functions, types, and procedures including Geode extensions (BACKUP, RESTORE, SESSION, FLE annotations).\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\",\"description\":\"The GQL query text\"},\"line\":{\"type\":\"integer\",\"description\":\"Cursor line number (1-indexed)\"},\"column\":{\"type\":\"integer\",\"description\":\"Cursor column number (1-indexed)\"}},\"required\":[\"query\",\"line\",\"column\"]}}," ++
    "{\"name\":\"hover\",\"description\":\"Get hover information (documentation) for the GQL element at a position.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\",\"description\":\"The GQL query text\"},\"line\":{\"type\":\"integer\",\"description\":\"Cursor line number (1-indexed)\"},\"column\":{\"type\":\"integer\",\"description\":\"Cursor column number (1-indexed)\"}},\"required\":[\"query\",\"line\",\"column\"]}}," ++
    "{\"name\":\"diagnostics\",\"description\":\"Get all diagnostics (errors, warnings, information) for a GQL document including Geode extension notices. Alias for validate.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\",\"description\":\"The GQL query to analyze\"}},\"required\":[\"query\"]}}" ++
    "]}";

// =============================================================================
// Tests
// =============================================================================

test "listTools returns valid JSON" {
    const result = listTools(null);
    try std.testing.expect(result.len > 0);
    // MCP framework contract: tools/list result must be an object
    // {"tools":[...]}.  See vendor/devnw/zig/mcp/src/mcp.zig:1186-1188.
    try std.testing.expect(std.mem.startsWith(u8, result, "{\"tools\":["));
}

test "formatToolResult escapes content correctly" {
    const allocator = std.testing.allocator;

    const content = try allocator.dupe(u8, "{\"test\": \"value\"}");
    const result = try formatToolResult(allocator, content);
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "content") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "text") != null);
}

test "formatErrorResponse formats correctly" {
    const allocator = std.testing.allocator;

    const result = try formatErrorResponse(allocator, "ConnectionFailed");
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "isError") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "ConnectionFailed") != null);
}

test "listTools contains all required tools" {
    const result = listTools(null);

    // Verify all 9 tools are present (5 database + 4 LSP)
    try std.testing.expect(std.mem.indexOf(u8, result, "\"name\":\"query\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"name\":\"schema\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"name\":\"explain\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"name\":\"catalogs\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"name\":\"graphs\"") != null);
    // LSP tools
    try std.testing.expect(std.mem.indexOf(u8, result, "\"name\":\"validate\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"name\":\"complete\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"name\":\"hover\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"name\":\"diagnostics\"") != null);
}

test "listTools contains valid JSON structure" {
    const allocator = std.testing.allocator;
    const result = listTools(null);

    // Parse to verify it's valid JSON
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, result, .{}) catch {
        try std.testing.expect(false); // Should not fail to parse
        return;
    };
    defer parsed.deinit();

    // Verify it's an object with `tools` array of length 9 (5 database + 4 LSP).
    try std.testing.expect(parsed.value == .object);
    const tools_field = parsed.value.object.get("tools") orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expect(tools_field == .array);
    try std.testing.expectEqual(@as(usize, 9), tools_field.array.items.len);
}

test "listTools cursor is ignored" {
    const result1 = listTools(null);
    const result2 = listTools("some_cursor");

    // Both should return the same result (cursor is ignored)
    try std.testing.expectEqualStrings(result1, result2);
}

test "formatToolResult with special characters" {
    const allocator = std.testing.allocator;

    const content = try allocator.dupe(u8, "{\"message\": \"Hello\\nWorld\"}");
    const result = try formatToolResult(allocator, content);
    defer allocator.free(result);

    // Should contain escaped content
    try std.testing.expect(std.mem.indexOf(u8, result, "content") != null);
}

test "formatErrorResponse with various error types" {
    const allocator = std.testing.allocator;

    const errors = [_][]const u8{
        "ConnectionFailed",
        "QueryFailed",
        "InvalidResponse",
        "Timeout",
    };

    for (errors) |err| {
        const result = try formatErrorResponse(allocator, err);
        defer allocator.free(result);

        try std.testing.expect(std.mem.indexOf(u8, result, "isError") != null);
        try std.testing.expect(std.mem.indexOf(u8, result, err) != null);
    }
}
