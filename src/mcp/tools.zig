const std = @import("std");

// CANARY: REQ=REQ-LIB-MIGRATION-MCP-002; FEATURE="External Library Migration"; ASPECT=MCPTools; STATUS=TESTED; OWNER=core; UPDATED=2026-01-24
// MCP Tools for Geode - GQL query execution, schema introspection, graph operations, and LSP features
const mcp = @import("mcp");
const error_detail = @import("error_detail.zig");

// CANARY: REQ=REQ-LIB-MIGRATION-JSON-038; FEATURE="JSON Library Migration"; ASPECT=MCPTools; STATUS=TESTED; OWNER=mcp; UPDATED=2026-01-24
const json_lib = @import("json");

const mcp_client = @import("client.zig");
const GeodeClient = mcp_client.GeodeClient;
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

// CANARY: REQ=REQ-MCP-READ-ONLY-001; FEATURE="MCPReadOnly"; ASPECT=ClassifierImport; STATUS=TESTED; TEST=tests/test_mcp_read_only.zig; OWNER=mcp; UPDATED=2026-08-28
// Task 6 (hybrid-RAG audit spec): the same real parser + state-change
// classifier the QUIC/gRPC transports' read-only floor uses
// (query_traits.changesStoredState), reused here as an MCP-layer
// defense-in-depth gate. Sibling import to the `validate` tool's parser
// entry point (lsp.zig -> gql_parser/gql_lexer).
const geode_gql = @import("geode").gql;
const geode_query_traits = @import("geode").query_traits;

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

/// List available Geode MCP tools: a ListToolsResult `{"tools":[...]}`.
/// Static text: the server.zig handler hands the mcp server a copy
/// (SONNY-6531, the server frees every handler result).
/// SONNY-6552: the list is one page and geode never issues a cursor, so a
/// cursor is invalid: `error.InvalidParams` (-32602, MCP pagination).
pub fn listTools(cursor: ?[]const u8) error{InvalidParams}![]const u8 {
    if (cursor != null) return error.InvalidParams;
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
    read_only: bool,
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
        return executeQuery(allocator, geode_endpoint, read_only, args_json);
    } else if (std.mem.eql(u8, name, "schema")) {
        return getSchema(allocator, geode_endpoint);
    } else if (std.mem.eql(u8, name, "explain")) {
        return explainQuery(allocator, geode_endpoint, args_json);
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
        // SONNY-6552: an unknown tool is a protocol error, -32602 in MCP
        // 2025-11-25 (tools "Error Handling"). SONNY-6585: mcp v0.1.23 maps
        // `error.ToolNotFound` to -32602 (it was -32002), and the message
        // names the tool (it was the error's name).
        try error_detail.setFmt(allocator, "Unknown tool: {s}", .{name}, .{ .name = name });
        return error.ToolNotFound;
    }
}

/// Execute a GQL query against Geode
fn executeQuery(allocator: std.mem.Allocator, endpoint: ?[]const u8, read_only: bool, args_json: []const u8) ![]const u8 {
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

    // SONNY-6552: the query runs on the session's graph; the tool selects
    // no catalog or graph, so it does not advertise either, and refuses
    // them rather than run the query somewhere the caller did not ask for.
    if (parsed.value.catalog != null or parsed.value.graph != null) {
        return try formatErrorResponse(allocator, "the query tool takes no 'catalog' or 'graph' argument; name the graph in the GQL text");
    }

    // Spec geode-vectorization-and-reranking: instruction boundary — retrieved
    // text must not be able to mutate through the single query tool. Fail
    // closed: unparseable input is unclassifiable and is rejected in
    // read-only mode. Engine-side ExecuteRequest.read_only (field 6) is the
    // hard floor once geode-client-zig emits it; this gate is the MCP-layer
    // belt over those suspenders.
    // CANARY: REQ=REQ-MCP-READ-ONLY-001; FEATURE="MCPReadOnly"; ASPECT=QueryToolGate; STATUS=TESTED; TEST=tests/test_mcp_read_only.zig; OWNER=mcp; UPDATED=2026-08-28
    if (read_only) {
        const verdict = classifyForReadOnly(allocator, query);
        if (verdict != .read_ok) {
            return try formatErrorResponse(allocator, "read-only MCP server: data modification rejected");
        }
    }

    const endpoint_str = endpoint orelse "localhost:3141";

    // Create client and execute query
    const client = GeodeClient.init(allocator, endpoint_str) catch |err| {
        return try formatErrorResponse(allocator, mcp_client.initErrorMessage(err, "Failed to initialize client"));
    };
    defer client.deinit();

    // Build params JSON if provided. SONNY-6552: serialized with
    // std.json; the old "{any}" format printed the formatter struct, not
    // JSON, so every call with parameters failed with InvalidParams.
    var params_json: ?[]const u8 = null;
    if (parsed.value.parameters) |p| {
        params_json = try std.json.Stringify.valueAlloc(allocator, p, .{});
    }
    defer if (params_json) |pj| allocator.free(pj);

    const result = client.query(query, params_json) catch |err| {
        return try formatErrorResponse(allocator, mcp_client.initErrorMessage(err, @errorName(err)));
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
    return try formatBackendResult(allocator, result);
}

/// A backend result as a CallToolResult: `isError: true` when the server
/// reported a failure (GAP-0345), a tool execution error per MCP
/// 2025-11-25; the plain result otherwise. Takes ownership of `result`.
fn formatBackendResult(allocator: std.mem.Allocator, result: []u8) ![]const u8 {
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

    const client = GeodeClient.init(allocator, endpoint_str) catch |err| {
        return try formatErrorResponse(allocator, mcp_client.initErrorMessage(err, "Failed to initialize client"));
    };
    defer client.deinit();

    const result = client.getSchema() catch |err| {
        return try formatErrorResponse(allocator, mcp_client.initErrorMessage(err, @errorName(err)));
    };

    return try formatBackendResult(allocator, result);
}

/// Explain a GQL query plan
fn explainQuery(allocator: std.mem.Allocator, endpoint: ?[]const u8, args_json: []const u8) ![]const u8 {
    // GAP-0345: same fix as executeQuery — wrap argument parse failure
    // as a structured MCP error result rather than a raw error JSON.
    // SONNY-6552: only the advertised `query`; anything else is refused.
    const parsed = std.json.parseFromSlice(LspQueryArgs, allocator, args_json, .{}) catch {
        return try formatErrorResponse(allocator, "Invalid query arguments");
    };
    defer parsed.deinit();

    const endpoint_str = endpoint orelse "localhost:3141";

    const client = GeodeClient.init(allocator, endpoint_str) catch |err| {
        return try formatErrorResponse(allocator, mcp_client.initErrorMessage(err, "Failed to initialize client"));
    };
    defer client.deinit();

    const result = client.explain(parsed.value.query) catch |err| {
        return try formatErrorResponse(allocator, mcp_client.initErrorMessage(err, @errorName(err)));
    };

    return try formatBackendResult(allocator, result);
}

/// List the graphs the caller can see (SHOW GRAPHS).
/// SONNY-6552: the tool used to advertise a `catalog` argument, parse it
/// into a slice that its block-scoped `defer p.deinit()` freed at once,
/// and hand that dangling slice to a client call that ignored it. geode
/// has no per-catalog graph listing, so the tool takes no arguments and
/// refuses any (an execution error, not a silently ignored filter).
fn listGraphs(allocator: std.mem.Allocator, endpoint: ?[]const u8, args_json: []const u8) ![]const u8 {
    const parsed = std.json.parseFromSlice(struct {}, allocator, args_json, .{}) catch {
        return try formatErrorResponse(allocator, "Invalid arguments: the graphs tool takes no arguments (no 'catalog': geode lists the graphs the caller can see)");
    };
    parsed.deinit();

    const endpoint_str = endpoint orelse "localhost:3141";

    const client = GeodeClient.init(allocator, endpoint_str) catch |err| {
        return try formatErrorResponse(allocator, mcp_client.initErrorMessage(err, "Failed to initialize client"));
    };
    defer client.deinit();

    const result = client.listGraphs() catch |err| {
        return try formatErrorResponse(allocator, mcp_client.initErrorMessage(err, @errorName(err)));
    };

    return try formatBackendResult(allocator, result);
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
        return try formatErrorResponse(allocator, mcp_client.initErrorMessage(err, @errorName(err)));
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
        return try formatErrorResponse(allocator, mcp_client.initErrorMessage(err, @errorName(err)));
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
        return try formatErrorResponse(allocator, mcp_client.initErrorMessage(err, @errorName(err)));
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
        return try formatErrorResponse(allocator, mcp_client.initErrorMessage(err, @errorName(err)));
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

/// Verdict of the in-process read-only pre-flight classifier.
const ReadOnlyVerdict = enum { read_ok, refused };

/// CANARY: REQ=REQ-MCP-READ-ONLY-001; FEATURE="MCPReadOnly"; ASPECT=Classifier; STATUS=TESTED; TEST=tests/test_mcp_read_only.zig; OWNER=mcp; UPDATED=2026-08-28
/// Classify a GQL statement for the read-only gate using the same parser
/// entry the `validate` tool uses (see lsp.zig validateQuery) plus the
/// real query_traits.changesStoredState classifier — the identical
/// classifier the QUIC/gRPC transports' read-only floor consults
/// (`StatementPlan.changes_state`).
///
/// Fail-closed contract: a statement is `.read_ok` only when it (a)
/// passes the GAP-0819 input chokepoint, (b) parses successfully, AND
/// (c) does not classify as mutating. Anything else — chokepoint
/// rejection, parse failure, or a positive mutation classification — is
/// `.refused`. Unparseable input is unclassifiable and is therefore
/// refused, not passed through.
///
/// SONNY-2751: the question is `query_traits.changesStoredState`, the one
/// the transports' read-only floor asks: a change of graph data or schema,
/// a procedure not on the read-only list, BACKUP / RESTORE, or the security
/// DDL (CREATE / ALTER / DROP USER, CREATE / DROP ROLE, GRANT, REVOKE,
/// CREATE / ALTER / DROP POLICY). The security DDL used to classify as a
/// read here, so a read-only MCP server forwarded CREATE USER or GRANT to
/// the engine. SHOW and the read-only auth procedures still pass.
fn classifyForReadOnly(allocator: std.mem.Allocator, query: []const u8) ReadOnlyVerdict {
    _ = lsp.validateAndSanitizeGqlInput(query) catch return .refused;

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();

    var lexer = geode_gql.lexer.Lexer{
        .src = query,
        .idx = 0,
        .line = 1,
        .col = 1,
        .has_double_solidus_comment = false,
    };

    var parser = geode_gql.parser.Parser{
        .lx = &lexer,
        .arena = &arena,
        .cur = lexer.next(),
        .has_ordinal_sort_key = false,
    };

    const program = parser.parseProgram() catch return .refused;

    if (geode_query_traits.changesStoredState(&program)) return .refused;
    return .read_ok;
}

const QueryArgs = struct {
    query: []const u8,
    parameters: ?std.json.Value = null,
    // Not advertised; parsed only to refuse them (SONNY-6552).
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
    "{\"name\":\"query\",\"description\":\"Execute a GQL (Graph Query Language) query against the Geode database. Returns query results as JSON.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\",\"description\":\"The GQL query to execute (ISO/IEC 39075:2024 compliant)\"},\"parameters\":{\"type\":\"object\",\"description\":\"Optional query parameters as key-value pairs\"}},\"required\":[\"query\"]}}," ++
    "{\"name\":\"schema\",\"description\":\"Get the node label sets of the session's graph (up to 100 distinct sets); the geode://default/{graph}/schema resource adds the relationship types.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}," ++
    "{\"name\":\"explain\",\"description\":\"Get the execution plan for a GQL query without running it. Useful for query optimization.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\",\"description\":\"The GQL query to explain\"}},\"required\":[\"query\"]}}," ++
    "{\"name\":\"graphs\",\"description\":\"List the graphs the caller can see.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{}}}," ++
    "{\"name\":\"validate\",\"description\":\"Validate GQL syntax and return diagnostics including Geode extensions (FLE, BACKUP/RESTORE, SESSION, double-dash comments). Does not require a running Geode server.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\",\"description\":\"The GQL query to validate\"}},\"required\":[\"query\"]}}," ++
    "{\"name\":\"complete\",\"description\":\"Get GQL completions at a cursor position. Returns keywords, functions, types, and procedures including Geode extensions (BACKUP, RESTORE, SESSION, FLE annotations).\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\",\"description\":\"The GQL query text\"},\"line\":{\"type\":\"integer\",\"description\":\"Cursor line number (1-indexed)\"},\"column\":{\"type\":\"integer\",\"description\":\"Cursor column number (1-indexed)\"}},\"required\":[\"query\",\"line\",\"column\"]}}," ++
    "{\"name\":\"hover\",\"description\":\"Get hover information (documentation) for the GQL element at a position.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\",\"description\":\"The GQL query text\"},\"line\":{\"type\":\"integer\",\"description\":\"Cursor line number (1-indexed)\"},\"column\":{\"type\":\"integer\",\"description\":\"Cursor column number (1-indexed)\"}},\"required\":[\"query\",\"line\",\"column\"]}}," ++
    "{\"name\":\"diagnostics\",\"description\":\"Get all diagnostics (errors, warnings, information) for a GQL document including Geode extension notices. Alias for validate.\",\"inputSchema\":{\"type\":\"object\",\"properties\":{\"query\":{\"type\":\"string\",\"description\":\"The GQL query to analyze\"}},\"required\":[\"query\"]}}" ++
    "]}";

// =============================================================================
// Tests
// =============================================================================

test "listTools returns valid JSON" {
    const result = try listTools(null);
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
    const result = try listTools(null);

    // Verify all 8 tools are present (4 database + 4 LSP). SONNY-6559 (5):
    // no catalogs tool: geode has no catalog to list (SHOW CATALOGS does
    // not parse), so the tool could not succeed.
    try std.testing.expect(std.mem.indexOf(u8, result, "\"name\":\"query\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"name\":\"schema\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"name\":\"explain\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"name\":\"catalogs\"") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"name\":\"graphs\"") != null);
    // LSP tools
    try std.testing.expect(std.mem.indexOf(u8, result, "\"name\":\"validate\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"name\":\"complete\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"name\":\"hover\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"name\":\"diagnostics\"") != null);
}

test "listTools contains valid JSON structure" {
    const allocator = std.testing.allocator;
    const result = try listTools(null);

    // Parse to verify it's valid JSON
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, result, .{}) catch {
        try std.testing.expect(false); // Should not fail to parse
        return;
    };
    defer parsed.deinit();

    // Verify it's an object with `tools` array of length 8 (4 database +
    // 4 LSP; SONNY-6559 removed `catalogs`, and this count was not updated).
    try std.testing.expect(parsed.value == .object);
    const tools_field = parsed.value.object.get("tools") orelse {
        try std.testing.expect(false);
        return;
    };
    try std.testing.expect(tools_field == .array);
    try std.testing.expectEqual(@as(usize, 8), tools_field.array.items.len);
}

test "listTools refuses a cursor it never issued (SONNY-6552)" {
    // The list is one page; MCP pagination: an invalid cursor is -32602.
    try std.testing.expectError(error.InvalidParams, listTools("some_cursor"));
}

test "listTools advertises no input property a tool ignores (SONNY-6552)" {
    const result = try listTools(null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"catalog\":{") == null);
    try std.testing.expect(std.mem.indexOf(u8, result, "\"graph\":{") == null);
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
