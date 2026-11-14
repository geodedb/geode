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
    // CANARY: REQ=REQ-MCP-READ-ONLY-001; FEATURE="MCPReadOnly"; ASPECT=OptionStorage; STATUS=TESTED; TEST=tests/test_mcp_read_only.zig; OWNER=mcp; UPDATED=2026-08-28
    // Task 6 (hybrid-RAG audit spec): MCP-layer defense-in-depth gate above
    // the Task 5 engine-side ExecuteRequest.read_only hard floor. When true,
    // the `query` tool refuses mutating (or unparseable) programs before
    // any round-trip to the geode backend. Threaded the same way as
    // `geode_endpoint`: captured from Options at init, read by
    // callToolHandler, forwarded into tools.callTool.
    read_only: bool,
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
        /// LSP-SEC-008: auth_mode .none hard-asserts a loopback http_bind.
        /// An unauthenticated MCP HTTP listener must never be reachable
        /// beyond the local host. Use .bearer (with a token) for any
        /// non-loopback bind.
        InsecureNoAuthBind,
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
        // LSP-SEC-008: hard-assert loopback when auth_mode is .none. The
        // stdio transport never binds, but http_bind still flows into the
        // vendored mcp.Server at init time — refusing the insecure
        // combination here (construction time) means neither transport can
        // later expose an unauthenticated HTTP listener on a public
        // interface. Authenticated modes may bind non-loopback.
        if (options.auth_mode == .none and !isLoopbackBind(options.http_bind)) {
            // Silent under `zig test`: the regression suite intentionally hits
            // this guard, and stderr output fails the build-runner test step.
            if (!@import("builtin").is_test) {
                std.debug.print("ERROR: MCP auth_mode 'none' requires a loopback http_bind (got '{s}'). " ++
                    "Bind 127.0.0.1/::1/localhost, or configure bearer auth for non-loopback binds.\n", .{options.http_bind});
            }
            return McpAuthError.InsecureNoAuthBind;
        }

        // SEC-08: Refuse to start MCP server without bearer token when auth is required
        if (options.auth_mode == .bearer and options.bearer_token == null) {
            if (!@import("builtin").is_test) {
                std.debug.print("ERROR: MCP server requires a bearer token when auth_mode is 'bearer' (the default). " ++
                    "Set --mcp-token or pass bearer_token in Options. " ++
                    "To disable auth (NOT recommended), explicitly set auth_mode to .none.\n", .{});
            }
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
            .read_only = options.read_only,
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
        // LSP-SEC-002 (documented residual): the pinned `mcp` library
        // compares this token against the HTTP `Authorization: Bearer ...`
        // header with `std.mem.eql` (mcp.zig checkAuth) — NOT constant-time
        // — and exposes no auth callback to override it. Geode cannot patch
        // the vendored package in-tree; the upstream fix is a fork-pin /
        // version bump (issue #785). Boundary posture until then:
        //   - http_bind defaults to loopback below and the geode CLI never
        //     exposes it, so the timing oracle is reachable only by local
        //     processes (pinned by tests/test_gap0885_lsp_hardening.zig);
        //   - the stdio transport never reaches checkAuth at all;
        //   - geode-owned token comparisons on the LSP/auth path are already
        //     constant-time (auth_lib api_keys: SHA-256 digest +
        //     std.crypto.timing_safe.eql; src/security/authn.zig:526
        //     session-token compare).
        bearer_token: ?[]const u8 = null,
        // GPS Phase 5: the username mapped from the bearer token.  Default "mcp".
        // Multi-user MCP (per-token user lookup) is deferred to Phase 6+.
        mcp_username: []const u8 = "mcp",
        // CANARY: REQ=REQ-MCP-READ-ONLY-001; FEATURE="MCPReadOnly"; ASPECT=OptionDefinition; STATUS=TESTED; TEST=tests/test_mcp_read_only.zig; OWNER=mcp; UPDATED=2026-08-28
        // Task 6 (hybrid-RAG audit spec): defense-in-depth read-only mode.
        // When true, the `query` tool classifies each statement in-process
        // (real parser + query_traits.changesStoredState) and refuses
        // mutating or unparseable programs before they reach the wire.
        // Defaults to false to preserve existing behavior.
        read_only: bool = false,
    };
};

/// LSP-SEC-008: classify an MCP `http_bind` host as loopback. Thin alias to
/// the shared single-source implementation in `src/net_policy.zig` (exported
/// via the `geode` module) so this security control cannot drift from the
/// LSP side's `isLoopbackHost` (src/cli/lsp/server.zig).
pub const isLoopbackBind = @import("geode").net_policy.isLoopbackHost;

// =============================================================================
// MCP Handler Implementations
// =============================================================================
//
// SONNY-6531 result ownership (mcp v0.1.22, Handler "Result Ownership"):
// every callback that returns `[]const u8` hands the slice to the server,
// which frees it with the allocator passed to `mcp.Server.init`, after the
// response is built, for a notification, and when building the response
// fails. `GeodeMcpServer.init` passes `self.allocator` there, so every
// handler below returns bytes from `self.allocator`: fixed text goes through
// `ownedCopy`, never a literal (an invalid free). A callback that returns an
// error hands nothing over.
// CANARY: REQ=REQ-SONNY-6531-MCP-OWNERSHIP; FEATURE="MCPResultOwnership"; ASPECT=AllocatorOwnedHandlerResults; STATUS=TESTED; TEST=tests/test_sonny6531_mcp_ownership.zig; OWNER=mcp; UPDATED=2026-11-14

/// A copy of `text` from the allocator the mcp server frees results with.
fn ownedCopy(ctx: ?*anyopaque, text: []const u8) ![]const u8 {
    const self: *GeodeMcpServer = @ptrCast(@alignCast(ctx.?));
    return self.allocator.dupe(u8, text);
}

fn listToolsHandler(ctx: ?*anyopaque, cursor: ?[]const u8) anyerror![]const u8 {
    return ownedCopy(ctx, tools.listTools(cursor));
}

fn callToolHandler(ctx: ?*anyopaque, name: []const u8, args_json: []const u8, cancel: *const mcp.CancelToken) anyerror![]const u8 {
    const self: *GeodeMcpServer = @ptrCast(@alignCast(ctx.?));
    // CANARY: REQ=REQ-GPS-MCP-001; FEATURE="GPS MCP Principal"; ASPECT=ToolDispatch; STATUS=TESTED; TEST=tests/test_gps_mcp_principal.zig; OWNER=security; UPDATED=2026-05-20
    // Pass the per-server Principal to tool dispatch so each tool can forward it
    // to any downstream execution context.  Phase 5: single MCP user per server;
    // multi-user per-connection threading is Phase 6+.
    return tools.callTool(self.allocator, self.geode_endpoint, self.read_only, &self.mcp_principal, name, args_json, cancel);
}

fn listResourcesHandler(ctx: ?*anyopaque, cursor: ?[]const u8) anyerror![]const u8 {
    return ownedCopy(ctx, resources.listResources(cursor));
}

fn readResourceHandler(ctx: ?*anyopaque, uri: []const u8) anyerror![]const u8 {
    const self: *GeodeMcpServer = @ptrCast(@alignCast(ctx.?));
    return resources.readResource(self.allocator, self.geode_endpoint, uri);
}

fn listResourceTemplatesHandler(ctx: ?*anyopaque) anyerror![]const u8 {
    return ownedCopy(ctx, resources.listResourceTemplates());
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
// bug rather than a missing capability. See mcp.zig:2950–2962 in v0.1.22.)
//
// Clients that need change tracking should poll via `readResource`.
// When Geode gains a graph-topology event producer, swap these
// handlers to a real implementation.
//
// KNOWN ADVERTISEMENT CAVEAT (documented, tested in
// tests/test_gap0516_mcp_capabilities.zig and docs/MCP_SERVER.md):
// the pinned `mcp` library (v0.1.22) hardcodes
// `"resources":{"subscribe":true,...}` in its `initialize` response
// (mcp.zig handleInitialize ~3193) and exposes no ServerOptions field
// to override it. Geode therefore cannot make the advertised
// capability string match the handler behaviour without forking the
// dependency. The authoritative, runtime-truthful contract is the
// handler response itself: `resources/subscribe` and
// `resources/unsubscribe` answer -32601 MethodNotFound. The
// regression test pins BOTH facts (the stale advertisement and the
// honest handler), so a future library version that drops the
// advertisement will trip the test and prompt a doc update.
// CANARY: REQ=REQ-MCP-RESOURCE-SUBSCRIBE-001; FEATURE="MCPResourceSubscribe"; ASPECT=UnsupportedSignal; STATUS=TESTED; TEST=tests/test_gap0516_mcp_capabilities.zig; OWNER=mcp; UPDATED=2026-06-10
fn subscribeResourceHandler(ctx: ?*anyopaque, uri: []const u8) anyerror!void {
    _ = ctx;
    _ = uri;
    return error.MethodNotFound;
}

// GAP-0516: paired with subscribeResourceHandler. See the note above.
// CANARY: REQ=REQ-MCP-RESOURCE-SUBSCRIBE-002; FEATURE="MCPResourceUnsubscribe"; ASPECT=UnsupportedSignal; STATUS=TESTED; TEST=tests/test_gap0516_mcp_capabilities.zig; OWNER=mcp; UPDATED=2026-06-10
fn unsubscribeResourceHandler(ctx: ?*anyopaque, uri: []const u8) anyerror!void {
    _ = ctx;
    _ = uri;
    return error.MethodNotFound;
}

fn listPromptsHandler(ctx: ?*anyopaque, cursor: ?[]const u8) anyerror![]const u8 {
    return ownedCopy(ctx, prompts.listPrompts(cursor));
}

fn getPromptHandler(ctx: ?*anyopaque, name: []const u8, args_json: ?[]const u8) anyerror![]const u8 {
    return ownedCopy(ctx, prompts.getPrompt(name, args_json));
}

// GAP-0516: completion/complete is optional per MCP spec §4.4.
//
// MCP "completion" is argument-completion for tools and resources
// (autocomplete parameter values while the user is typing), not
// general text completion. Geode does not yet maintain a per-tool
// argument suggestion index, so we answer a CompleteResult with no
// values — a valid "no suggestions available" response. Clients
// receive a successful response with zero items and fall back to
// showing their own suggestions or plain text input.
// SONNY-6544: the result is the protocol's CompleteResult object
// (2025-11-25, the pinned library's version:
// {"completion":{"values":[...],"total"?,"hasMore"?}}); it used to be a
// bare `[]`, which has no `completion` for a client to read.
// CANARY: REQ=REQ-MCP-COMPLETE-001; FEATURE="MCPCompletion"; ASPECT=EmptyProvider; STATUS=TESTED; TEST=tests/test_sonny6544_mcp_completion.zig; OWNER=mcp; UPDATED=2026-11-14
pub const empty_completion = "{\"completion\":{\"values\":[],\"total\":0,\"hasMore\":false}}";

fn completeHandler(ctx: ?*anyopaque, params_json: []const u8) anyerror![]const u8 {
    _ = params_json;
    return ownedCopy(ctx, empty_completion);
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

test "GAP-0516: completeHandler returns an empty CompleteResult (SONNY-6544)" {
    const allocator = std.testing.allocator;
    const server = try GeodeMcpServer.init(allocator, .{ .auth_mode = .none });
    defer server.deinit();
    // SONNY-6531: the result is the caller's (the mcp server frees it).
    const result = try completeHandler(server, "{\"ref\":{\"type\":\"ref/prompt\",\"name\":\"explore_graph\"},\"argument\":{\"name\":\"graph\",\"value\":\"\"}}");
    defer allocator.free(result);
    // A CompleteResult object, not a bare array (the dispatch-level
    // contract is tests/test_sonny6544_mcp_completion.zig).
    try std.testing.expectEqualStrings("{\"completion\":{\"values\":[],\"total\":0,\"hasMore\":false}}", result);
}

test "SONNY-6531: every handler returns a result from the server's allocator" {
    const allocator = std.testing.allocator;
    const server = try GeodeMcpServer.init(allocator, .{ .auth_mode = .none });
    defer server.deinit();
    // std.testing.allocator panics on freeing a literal and fails on a leak.
    const results = [_][]const u8{
        try listToolsHandler(server, null),
        try listResourcesHandler(server, null),
        try listResourceTemplatesHandler(server),
        try listPromptsHandler(server, null),
        try getPromptHandler(server, "find_nodes", null),
        try getPromptHandler(server, "no_such_prompt", "{}"),
        try readResourceHandler(server, "unknown://resource"),
        try completeHandler(server, "{}"),
    };
    for (results) |r| {
        try std.testing.expect(r.len > 0);
        allocator.free(r);
    }
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
