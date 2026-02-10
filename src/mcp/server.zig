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

    pub fn init(allocator: std.mem.Allocator, options: Options) !*GeodeMcpServer {
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
        auth_mode: mcp.AuthMode = .none,
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

fn subscribeResourceHandler(ctx: ?*anyopaque, uri: []const u8) anyerror!void {
    _ = ctx;
    _ = uri;
    // Resource subscriptions not yet implemented
    return error.NotImplemented;
}

fn unsubscribeResourceHandler(ctx: ?*anyopaque, uri: []const u8) anyerror!void {
    _ = ctx;
    _ = uri;
    // Resource unsubscriptions not yet implemented
    return error.NotImplemented;
}

fn listPromptsHandler(ctx: ?*anyopaque, cursor: ?[]const u8) anyerror![]const u8 {
    _ = ctx;
    return prompts.listPrompts(cursor);
}

fn getPromptHandler(ctx: ?*anyopaque, name: []const u8, args_json: ?[]const u8) anyerror![]const u8 {
    _ = ctx;
    return prompts.getPrompt(name, args_json);
}

fn completeHandler(ctx: ?*anyopaque, params_json: []const u8) anyerror![]const u8 {
    _ = ctx;
    _ = params_json;
    // Completion suggestions not yet implemented
    return "[]";
}

fn setLogLevelHandler(ctx: ?*anyopaque, level: []const u8) anyerror!void {
    _ = ctx;
    _ = level;
    // Log level adjustment - could integrate with slog
}

// =============================================================================
// Tests
// =============================================================================

test "GeodeMcpServer initialization" {
    const allocator = std.testing.allocator;

    const server = try GeodeMcpServer.init(allocator, .{
        .geode_endpoint = "localhost:3141",
    });
    defer server.deinit();

    try std.testing.expect(server.geode_endpoint != null);
}
