// CANARY: REQ=REQ-LIB-MIGRATION-MCP-005; FEATURE="External Library Migration"; ASPECT=MCPModule; STATUS=TESTED; OWNER=core; UPDATED=2026-01-24
// Geode MCP Module - Model Context Protocol integration for AI/LLM access

// Re-export transport module for use by client.zig
pub const quic_transport = @import("transport/quic");

// Re-export GQL modules for use by lsp.zig (accessed through geode module)
const geode = @import("geode");
pub const gql_parser = geode.gql.parser;
pub const gql_lexer = geode.gql.lexer;
pub const language_metadata = geode.language_metadata;

pub const server = @import("server.zig");
pub const client = @import("client.zig");
pub const tools = @import("tools.zig");
pub const resources = @import("resources.zig");
pub const prompts = @import("prompts.zig");
pub const lsp = @import("lsp.zig");

pub const GeodeMcpServer = server.GeodeMcpServer;
pub const GeodeClient = client.GeodeClient;
