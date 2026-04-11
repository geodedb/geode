const std = @import("std");
const build_options = @import("build_options");

// CANARY: REQ=REQ-LIB-MIGRATION-MCP-001; FEATURE="External Library Migration"; ASPECT=MCPIntegration; STATUS=TESTED; OWNER=core; UPDATED=2026-01-24
// Model Context Protocol (MCP) server for Geode - enables AI/LLM integration
// The MCP server connects to the Geode database via QUIC transport for real query execution
const mcp = @import("mcp");

const tools = @import("tools.zig");
const resources = @import("resources.zig");
const prompts = @import("prompts.zig");

/// Geode MCP Server - provides AI/LLM access to graph database operations
pub const GeodeMcpServer = struct {
    allocator: std.mem.Allocator,
    server: mcp.Server,
    geode_endpoint: ?[]const u8,

    pub const McpAuthError = error{
        /// SEC-08: MCP server requires bearer token authentication by default.
        /// Set auth_mode to .bearer and provide a bearer_token, or explicitly
        /// set auth_mode to .none if running in a trusted environment.
        MissingBearerToken,
    };

    pub fn init(allocator: std.mem.Allocator, options: Options) !*GeodeMcpServer {
        // SEC-08: Refuse to start MCP server without bearer token when auth is required
        if (options.auth_mode == .bearer and options.bearer_token == null) {
            std.debug.print("ERROR: MCP server requires a bearer token when auth_mode is 'bearer' (the default). " ++
                "Set --mcp-token or pass bearer_token in Options. " ++
                "To disable auth (NOT recommended), explicitly set auth_mode to .none.\n", .{});
            return error.MissingBearerToken;
        }

        const self = try allocator.create(GeodeMcpServer);
        errdefer allocator.destroy(self);

        self.* = GeodeMcpServer{
            .allocator = allocator,
            .server = undefined,
            .geode_endpoint = if (options.geode_endpoint) |ep|
                try allocator.dupe(u8, ep)
            else
                null,
        };

        const handler = mcp.Handler{
            .ctx = self,
            .listTools = listToolsHandler,
            .callTool = callToolHandler,
            .listResources = listResourcesHandler,
            .readResource = readResourceHandler,
            .listResourceTemplates = listResourceTemplatesHandler,
            .subscribeResource = subscribeResourceHandler,
            .unsubscribeResource = unsubscribeResourceHandler,
            .listPrompts = listPromptsHandler,
            .getPrompt = getPromptHandler,
            .complete = completeHandler,
            .setLogLevel = setLogLevelHandler,
        };

        self.server = try mcp.Server.init(allocator, .{
            .name = "geode-mcp",
            .version = build_options.version,
            .instructions = "Geode Graph Database MCP Server - Execute GQL queries and explore graph data",
            .worker_threads = options.worker_threads,
            .http_bind = options.http_bind,
            .http_port = options.http_port,
            .auth_mode = options.auth_mode,
            .bearer_token = options.bearer_token,
        }, handler);

        return self;
    }

    pub fn deinit(self: *GeodeMcpServer) void {
        self.server.deinit();
        if (self.geode_endpoint) |ep| {
            self.allocator.free(ep);
        }
        self.allocator.destroy(self);
    }

    /// Start MCP server on HTTP transport
    /// Returns the port number the server is listening on
    pub fn serveHttp(self: *GeodeMcpServer) !u16 {
        return try self.server.serveHttp();
    }

    /// Start MCP server on stdio transport (stdin/stdout for JSONRPC)
    /// This is the standard transport for MCP clients like Claude Desktop.
    /// IMPORTANT: stdout is reserved exclusively for JSONRPC messages.
    /// All logging MUST go to stderr (std.debug.print is safe - it uses stderr).
    pub fn serveStdio(self: *GeodeMcpServer) !void {
        return try self.server.serveStdio();
    }

    /// Stop the server
    pub fn stop(self: *GeodeMcpServer) void {
        self.server.stop();
    }

    pub const Options = struct {
        geode_endpoint: ?[]const u8 = null,
        worker_threads: u16 = 4,
        http_bind: []const u8 = "127.0.0.1",
        http_port: u16 = 0,
        // SEC-08: Default to bearer token auth; refuse to start without a token configured
        auth_mode: mcp.AuthMode = .bearer,
        bearer_token: ?[]const u8 = null,
    };
};

// =============================================================================
// MCP Handler Implementations
// =============================================================================

fn listToolsHandler(ctx: ?*anyopaque, cursor: ?[]const u8) anyerror![]const u8 {
    _ = ctx;
    return tools.listTools(cursor);
}

fn callToolHandler(ctx: ?*anyopaque, name: []const u8, args_json: []const u8, cancel: *const mcp.CancelToken) anyerror![]const u8 {
    const self: *GeodeMcpServer = @ptrCast(@alignCast(ctx.?));
    return tools.callTool(self.allocator, self.geode_endpoint, name, args_json, cancel);
}

fn listResourcesHandler(ctx: ?*anyopaque, cursor: ?[]const u8) anyerror![]const u8 {
    _ = ctx;
    return resources.listResources(cursor);
}

fn readResourceHandler(ctx: ?*anyopaque, uri: []const u8) anyerror![]const u8 {
    const self: *GeodeMcpServer = @ptrCast(@alignCast(ctx.?));
    return resources.readResource(self.allocator, self.geode_endpoint, uri);
}

fn listResourceTemplatesHandler(ctx: ?*anyopaque) anyerror![]const u8 {
    _ = ctx;
    return resources.listResourceTemplates();
}

// GAP-0516: Resource subscriptions are intentionally unsupported.
//
// MCP spec §6.2 describes resource subscriptions as optional: servers
// that do not implement them should surface the fact clearly rather
// than accept the subscription and never fire notifications. Geode
// does not yet produce streaming resource-change notifications — the
// query engine is synchronous request/response and graph topology
// changes are not wired to a background event producer. Returning
// `error.MethodNotFound` makes the MCP library emit JSON-RPC error
// -32601 ("Method not found") per spec §4.5, which is the canonical
// "this server does not implement this method" signal. (Previously
// we returned `error.NotImplemented`, which the MCP library maps to
// -32603 InternalError — misleading, because it suggests a server
// bug rather than a missing capability. See mcp.zig:2795–2807.)
//
// Clients that need change tracking should poll via `readResource`.
// When Geode gains a graph-topology event producer, swap these
// handlers to a real implementation.
// CANARY: REQ=REQ-MCP-RESOURCE-SUBSCRIBE-001; FEATURE="MCPResourceSubscribe"; ASPECT=UnsupportedSignal; STATUS=EXEMPT; OWNER=mcp; UPDATED=2026-04-11
fn subscribeResourceHandler(ctx: ?*anyopaque, uri: []const u8) anyerror!void {
    _ = ctx;
    _ = uri;
    return error.MethodNotFound;
}

// GAP-0516: paired with subscribeResourceHandler. See the note above.
// CANARY: REQ=REQ-MCP-RESOURCE-SUBSCRIBE-002; FEATURE="MCPResourceUnsubscribe"; ASPECT=UnsupportedSignal; STATUS=EXEMPT; OWNER=mcp; UPDATED=2026-04-11
fn unsubscribeResourceHandler(ctx: ?*anyopaque, uri: []const u8) anyerror!void {
    _ = ctx;
    _ = uri;
    return error.MethodNotFound;
}

fn listPromptsHandler(ctx: ?*anyopaque, cursor: ?[]const u8) anyerror![]const u8 {
    _ = ctx;
    return prompts.listPrompts(cursor);
}

fn getPromptHandler(ctx: ?*anyopaque, name: []const u8, args_json: ?[]const u8) anyerror![]const u8 {
    _ = ctx;
    return prompts.getPrompt(name, args_json);
}

// GAP-0516: completion/complete is optional per MCP spec §4.4.
//
// MCP "completion" is argument-completion for tools and resources
// (autocomplete parameter values while the user is typing), not
// general text completion. Geode does not yet maintain a per-tool
// argument suggestion index, so we return an empty JSON array — a
// valid "no suggestions available" response. Clients receive a
// successful response with zero items and fall back to showing
// their own suggestions or plain text input. This is the spec-
// compliant way to handle an unimplemented completion provider.
// CANARY: REQ=REQ-MCP-COMPLETE-001; FEATURE="MCPCompletion"; ASPECT=EmptyProvider; STATUS=EXEMPT; OWNER=mcp; UPDATED=2026-04-11
fn completeHandler(ctx: ?*anyopaque, params_json: []const u8) anyerror![]const u8 {
    _ = ctx;
    _ = params_json;
    return "[]";
}

// GAP-0516: logging/setLevel is optional per MCP spec §7.2.
//
// Per spec §7.2, servers that do not support dynamic log-level
// changes MUST still respond successfully to the request — silently
// ignoring the level string is the correct behaviour. Geode uses
// slog scoped loggers whose levels are set at startup from
// `--log-level`; changing them at runtime requires rewiring every
// scoped logger and is not currently supported. Returning success
// here means MCP clients that send `logging/setLevel` notifications
// do not see errors in their logs.
// CANARY: REQ=REQ-MCP-SETLOGLEVEL-001; FEATURE="MCPSetLogLevel"; ASPECT=SilentSuccess; STATUS=EXEMPT; OWNER=mcp; UPDATED=2026-04-11
fn setLogLevelHandler(ctx: ?*anyopaque, level: []const u8) anyerror!void {
    _ = ctx;
    _ = level;
}

// =============================================================================
// Tests
// =============================================================================

test "GeodeMcpServer initialization with bearer token" {
    const allocator = std.testing.allocator;

    const server = try GeodeMcpServer.init(allocator, .{
        .geode_endpoint = "localhost:3141",
        .bearer_token = "test-token-for-unit-test",
    });
    defer server.deinit();

    try std.testing.expect(server.geode_endpoint != null);
}

test "GeodeMcpServer rejects init without bearer token" {
    const allocator = std.testing.allocator;

    // SEC-08: Default auth_mode is .bearer, so omitting bearer_token must fail
    const result = GeodeMcpServer.init(allocator, .{
        .geode_endpoint = "localhost:3141",
    });
    try std.testing.expectError(error.MissingBearerToken, result);
}

test "GeodeMcpServer allows no-auth when explicitly set" {
    const allocator = std.testing.allocator;

    const server = try GeodeMcpServer.init(allocator, .{
        .geode_endpoint = "localhost:3141",
        .auth_mode = .none,
    });
    defer server.deinit();

    try std.testing.expect(server.geode_endpoint != null);
}

// GAP-0516: lock in the handler behaviour documented above. These
// tests exercise the handlers directly (not through the full MCP
// JSON-RPC pipeline) so we can assert the exact error type the
// server library will see, independent of transport wiring.

test "GAP-0516: subscribeResourceHandler returns MethodNotFound (spec §6.2 unsupported)" {
    try std.testing.expectError(
        error.MethodNotFound,
        subscribeResourceHandler(null, "geode://graph/default"),
    );
}

test "GAP-0516: unsubscribeResourceHandler returns MethodNotFound (paired with subscribe)" {
    try std.testing.expectError(
        error.MethodNotFound,
        unsubscribeResourceHandler(null, "geode://graph/default"),
    );
}

test "GAP-0516: completeHandler returns empty JSON array (spec §4.4 optional)" {
    const result = try completeHandler(null, "{\"ref\":{\"type\":\"ref/tool\",\"name\":\"query\"}}");
    // Must be a valid JSON array literal the MCP client can parse.
    // "[]" is 2 bytes; anything else (including null-terminated or
    // object form) would break the response contract.
    try std.testing.expectEqualStrings("[]", result);
}

test "GAP-0516: setLogLevelHandler silently accepts any level (spec §7.2)" {
    // Spec §7.2: servers that don't support dynamic log-level changes
    // MUST still respond successfully. Silent no-op is compliant.
    try setLogLevelHandler(null, "debug");
    try setLogLevelHandler(null, "info");
    try setLogLevelHandler(null, "warning");
    try setLogLevelHandler(null, "error");
    // Also tolerate unknown levels — the server must not crash on a
    // client that sends a level string it doesn't recognise.
    try setLogLevelHandler(null, "chatter");
    try setLogLevelHandler(null, "");
}
