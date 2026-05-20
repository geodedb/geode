const std = @import("std");
const build_options = @import("build_options");

// CANARY: REQ=REQ-LIB-MIGRATION-MCP-001; FEATURE="External Library Migration"; ASPECT=MCPIntegration; STATUS=TESTED; OWNER=core; UPDATED=2026-01-24
// Model Context Protocol (MCP) server for Geode - enables AI/LLM integration
// The MCP server connects to the Geode database via QUIC transport for real query execution
const mcp = @import("mcp");

const tools = @import("tools.zig");
const resources = @import("resources.zig");
const prompts = @import("prompts.zig");

// CANARY: REQ=REQ-GPS-MCP-001; FEATURE="GPS MCP Principal"; ASPECT=PrincipalDerivation; STATUS=TESTED; TEST=tests/test_gps_mcp_principal.zig; OWNER=security; UPDATED=2026-05-20
// GPS Phase 5: derive a per-server Principal from the bearer token at init time.
// The MCP library validates the bearer token at the transport layer but does not
// surface per-connection caller identity to handler callbacks — the callTool /
// readResource / etc. signatures only carry ctx (our GeodeMcpServer pointer) and
// no caller token.  Phase 5 keeps it simple: one MCP user (mapped from the
// bearer token to the configured username, default "mcp") for the lifetime of
// the server.  Multi-user MCP is deferred to Phase 6+.
//
// The Principal is derived once in init() and stored on GeodeMcpServer.  Every
// tool dispatch reads it from self.mcp_principal and can forward it to
// ExecutionContext (Phase 5 threading: pass to tools.callTool so it is
// available at the tool boundary; the downstream GeodeClient path over QUIC
// does not yet carry an in-band principal — that is Phase 6 work tracked in
// the gps-fail-open-sites #8 DONE_WITH_CONCERNS note).
const geode_security = @import("geode").security;
const principal_mod = geode_security.principal;
const principal_derive = geode_security.principal_derive;

/// Geode MCP Server - provides AI/LLM access to graph database operations
pub const GeodeMcpServer = struct {
    allocator: std.mem.Allocator,
    server: mcp.Server,
    geode_endpoint: ?[]const u8,
    // CANARY: REQ=REQ-GPS-MCP-001; FEATURE="GPS MCP Principal"; ASPECT=PrincipalStorage; STATUS=TESTED; TEST=tests/test_gps_mcp_principal.zig; OWNER=security; UPDATED=2026-05-20
    // Per-server Principal derived from the bearer token (or anonymous when
    // auth_mode = .none). Stored by value; lifetime tied to this server.
    mcp_principal: principal_mod.Principal,
    // Storage for the mcp_username string that the Principal references.
    mcp_username_storage: []u8,

    pub const McpAuthError = error{
        /// SEC-08: MCP server requires bearer token authentication by default.
        /// Set auth_mode to .bearer and provide a bearer_token, or explicitly
        /// set auth_mode to .none if running in a trusted environment.
        MissingBearerToken,
    };

    /// Derive the MCP Principal for a given username.  Called once at init.
    /// The returned Principal borrows `username_slice` — the caller owns the
    /// storage and must ensure it outlives the Principal.
    fn deriveMcpPrincipal(username_slice: []const u8, auth_mode: mcp.AuthMode) principal_mod.Principal {
        const user_roles: []const []const u8 = if (auth_mode == .none) &.{} else &.{"User"};
        return principal_derive.derivePrincipal(.{
            .username = username_slice,
            .role_names = user_roles,
            .tenant_id = null,
            .active_graph = null,
            .auth_version = 0,
            .auth_method = .api_key,
            .source = .mcp_handler,
        });
    }

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

        // Derive the MCP Principal.  Phase 5: username is the configured mcp_username
        // option (default "mcp").  We dupe the string so the Principal's lifetime is
        // fully owned by this server struct.
        const username_storage = try allocator.dupe(u8, options.mcp_username);
        errdefer allocator.free(username_storage);

        const mcp_principal = deriveMcpPrincipal(username_storage, options.auth_mode);

        self.* = GeodeMcpServer{
            .allocator = allocator,
            .server = undefined,
            .geode_endpoint = if (options.geode_endpoint) |ep|
                try allocator.dupe(u8, ep)
            else
                null,
            .mcp_principal = mcp_principal,
            .mcp_username_storage = username_storage,
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
        self.allocator.free(self.mcp_username_storage);
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
        // GPS Phase 5: the username mapped from the bearer token.  Default "mcp".
        // Multi-user MCP (per-token user lookup) is deferred to Phase 6+.
        mcp_username: []const u8 = "mcp",
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
    // CANARY: REQ=REQ-GPS-MCP-001; FEATURE="GPS MCP Principal"; ASPECT=ToolDispatch; STATUS=TESTED; TEST=tests/test_gps_mcp_principal.zig; OWNER=security; UPDATED=2026-05-20
    // Pass the per-server Principal to tool dispatch so each tool can forward it
    // to any downstream execution context.  Phase 5: single MCP user per server;
    // multi-user per-connection threading is Phase 6+.
    return tools.callTool(self.allocator, self.geode_endpoint, &self.mcp_principal, name, args_json, cancel);
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

// CANARY: REQ=REQ-GPS-MCP-001; FEATURE="GPS MCP Principal"; ASPECT=PrincipalDerivation; STATUS=TESTED; TEST=tests/test_gps_mcp_principal.zig; OWNER=security; UPDATED=2026-05-20
test "GeodeMcpServer derives Principal with source=.mcp_handler on init" {
    const allocator = std.testing.allocator;

    const server = try GeodeMcpServer.init(allocator, .{
        .geode_endpoint = "localhost:3141",
        .bearer_token = "test-token",
    });
    defer server.deinit();

    try std.testing.expectEqual(principal_mod.PrincipalSource.mcp_handler, server.mcp_principal.source);
    try std.testing.expect(server.mcp_principal.username != null);
    try std.testing.expectEqualStrings("mcp", server.mcp_principal.username.?);
}

test "GeodeMcpServer derives Principal with configured mcp_username" {
    const allocator = std.testing.allocator;

    const server = try GeodeMcpServer.init(allocator, .{
        .geode_endpoint = "localhost:3141",
        .bearer_token = "test-token",
        .mcp_username = "mcp-service-account",
    });
    defer server.deinit();

    try std.testing.expectEqual(principal_mod.PrincipalSource.mcp_handler, server.mcp_principal.source);
    try std.testing.expectEqualStrings("mcp-service-account", server.mcp_principal.username.?);
}

test "GeodeMcpServer derives Principal with auth_mode=.none (anonymous roles)" {
    const allocator = std.testing.allocator;

    const server = try GeodeMcpServer.init(allocator, .{
        .geode_endpoint = "localhost:3141",
        .auth_mode = .none,
    });
    defer server.deinit();

    try std.testing.expectEqual(principal_mod.PrincipalSource.mcp_handler, server.mcp_principal.source);
    // No roles for anonymous / no-auth mode
    try std.testing.expectEqual(@as(usize, 0), server.mcp_principal.roles.len);
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
