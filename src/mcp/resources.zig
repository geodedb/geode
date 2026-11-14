const std = @import("std");
const build_options = @import("build_options");

// CANARY: REQ=REQ-LIB-MIGRATION-MCP-003; FEATURE="External Library Migration"; ASPECT=MCPResources; STATUS=TESTED; OWNER=core; UPDATED=2026-01-24
// MCP Resources for Geode - expose graph data, schemas, and query results as resources

// CANARY: REQ=REQ-LIB-MIGRATION-JSON-042; FEATURE="JSON Library Migration"; ASPECT=MCPResources; STATUS=TESTED; OWNER=mcp; UPDATED=2026-01-24
const json_lib = @import("json");

const mcp_client = @import("client.zig");
const GeodeClient = mcp_client.GeodeClient;

// MCP Resource Response Types for JSON Library encoding
const McpResourceResponse = struct {
    uri: []const u8,
    mimeType: []const u8,
    text: []const u8,
};

const McpResourceError = struct {
    @"error": []const u8,
};

/// List available resources
/// Returns JSON array of resource definitions
pub fn listResources(cursor: ?[]const u8) []const u8 {
    _ = cursor; // Pagination not needed for small resource list
    return resources_json;
}

/// Read a resource by URI
pub fn readResource(allocator: std.mem.Allocator, endpoint: ?[]const u8, uri: []const u8) ![]const u8 {
    const endpoint_str = endpoint orelse "localhost:3141";

    // Parse resource URI: geode://catalog/graph/resource_type
    if (std.mem.startsWith(u8, uri, "geode://")) {
        const path = uri[8..]; // Skip "geode://"

        if (std.mem.indexOf(u8, path, "/schema")) |_| {
            return try readSchemaResource(allocator, endpoint_str);
        } else if (std.mem.indexOf(u8, path, "/stats")) |_| {
            return try readStatsResource(allocator, endpoint_str);
        } else if (std.mem.eql(u8, path, "config") or std.mem.indexOf(u8, path, "config") != null) {
            return try readConfigResource(allocator, endpoint_str);
        }
    }

    return "{\"error\": \"Unknown resource URI\"}";
}

/// Read schema resource from Geode server
fn readSchemaResource(allocator: std.mem.Allocator, endpoint: []const u8) ![]const u8 {
    const client = GeodeClient.init(allocator, endpoint) catch |err| {
        return try formatResourceError(allocator, mcp_client.initErrorMessage(err, "Failed to connect to Geode server"));
    };
    defer client.deinit();

    const schema_data = client.getSchema() catch {
        // Return fallback on connection error
        return try allocator.dupe(u8, default_schema_resource);
    };

    // Format as MCP resource response
    return try formatResourceResponse(allocator, "geode://default/default/schema", "application/json", schema_data);
}

/// Read stats resource from Geode server
fn readStatsResource(allocator: std.mem.Allocator, endpoint: []const u8) ![]const u8 {
    const client = GeodeClient.init(allocator, endpoint) catch |err| {
        return try formatResourceError(allocator, mcp_client.initErrorMessage(err, "Failed to connect to Geode server"));
    };
    defer client.deinit();

    const stats_data = client.getStats() catch {
        return try allocator.dupe(u8, default_stats_resource);
    };

    return try formatResourceResponse(allocator, "geode://default/default/stats", "application/json", stats_data);
}

/// Read config resource from Geode server
fn readConfigResource(allocator: std.mem.Allocator, endpoint: []const u8) ![]const u8 {
    const client = GeodeClient.init(allocator, endpoint) catch |err| {
        return try formatResourceError(allocator, mcp_client.initErrorMessage(err, "Failed to connect to Geode server"));
    };
    defer client.deinit();

    const config_data = client.getConfig() catch {
        return try allocator.dupe(u8, default_config_resource);
    };

    return try formatResourceResponse(allocator, "geode://config", "application/json", config_data);
}

/// Format a successful resource response for MCP
/// CANARY: REQ=REQ-LIB-MIGRATION-JSON-043; FEATURE="JSON Library Migration"; ASPECT=ResourceResponse; STATUS=TESTED; OWNER=mcp; UPDATED=2026-01-24
fn formatResourceResponse(allocator: std.mem.Allocator, uri: []const u8, mime_type: []const u8, content: []const u8) ![]const u8 {
    defer allocator.free(content);

    // Build MCP resource response using JSON library (handles escaping automatically)
    const response = McpResourceResponse{
        .uri = uri,
        .mimeType = mime_type,
        .text = content,
    };
    return try json_lib.encode(allocator, response, .{});
}

/// Format an error response for MCP resource read
/// CANARY: REQ=REQ-LIB-MIGRATION-JSON-044; FEATURE="JSON Library Migration"; ASPECT=ResourceError; STATUS=TESTED; OWNER=mcp; UPDATED=2026-01-24
fn formatResourceError(allocator: std.mem.Allocator, error_msg: []const u8) ![]const u8 {
    const response = McpResourceError{ .@"error" = error_msg };
    return try json_lib.encode(allocator, response, .{});
}

/// List resource templates
pub fn listResourceTemplates() []const u8 {
    return resource_templates_json;
}

// Fallback responses when server is unavailable
const default_schema_resource =
    \\{
    \\  "uri": "geode://default/default/schema",
    \\  "mimeType": "application/json",
    \\  "text": "{\"node_labels\": [], \"relationship_types\": [], \"note\": \"Server unavailable\"}"
    \\}
;

const default_stats_resource =
    \\{
    \\  "uri": "geode://default/default/stats",
    \\  "mimeType": "application/json",
    \\  "text": "{\"node_count\": 0, \"relationship_count\": 0, \"index_count\": 0, \"note\": \"Server unavailable\"}"
    \\}
;

const default_config_resource = std.fmt.comptimePrint(
    \\{{
    \\  "uri": "geode://config",
    \\  "mimeType": "application/json",
    \\  "text": "{{\\"version\\": \\"{s}\\", \\"gql_compliance\\": \\"ISO/IEC 39075:2024\\", \\"status\\": \\"disconnected\\"}}"
    \\}}
, .{build_options.version});

/// Static JSON definition of available resources
const resources_json =
    \\[
    \\  {
    \\    "uri": "geode://default/default/schema",
    \\    "name": "Graph Schema",
    \\    "description": "Current graph schema including node labels, relationship types, and properties",
    \\    "mimeType": "application/json"
    \\  },
    \\  {
    \\    "uri": "geode://default/default/stats",
    \\    "name": "Database Statistics",
    \\    "description": "Database statistics including node count, relationship count, and index information",
    \\    "mimeType": "application/json"
    \\  },
    \\  {
    \\    "uri": "geode://config",
    \\    "name": "Server Configuration",
    \\    "description": "Current server configuration and version information",
    \\    "mimeType": "application/json"
    \\  }
    \\]
;

/// Static JSON definition of resource templates
const resource_templates_json =
    \\[
    \\  {
    \\    "uriTemplate": "geode://{catalog}/{graph}/schema",
    \\    "name": "Graph Schema Template",
    \\    "description": "Schema for a specific catalog and graph"
    \\  },
    \\  {
    \\    "uriTemplate": "geode://{catalog}/{graph}/stats",
    \\    "name": "Statistics Template",
    \\    "description": "Statistics for a specific catalog and graph"
    \\  },
    \\  {
    \\    "uriTemplate": "geode://{catalog}/{graph}/node/{label}",
    \\    "name": "Node Label Template",
    \\    "description": "Information about a specific node label"
    \\  },
    \\  {
    \\    "uriTemplate": "geode://{catalog}/{graph}/relationship/{type}",
    \\    "name": "Relationship Type Template",
    \\    "description": "Information about a specific relationship type"
    \\  }
    \\]
;

// =============================================================================
// Tests
// =============================================================================

test "listResources returns valid JSON" {
    const result = listResources(null);
    try std.testing.expect(result.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, result, "["));
}

test "listResourceTemplates returns valid JSON" {
    const result = listResourceTemplates();
    try std.testing.expect(result.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, result, "["));
}

test "JSON library handles escaping in resources" {
    const allocator = std.testing.allocator;

    // Verify JSON library properly escapes special characters in resources
    const result = try formatResourceError(allocator, "Error with \"quotes\"");
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "\\\"quotes\\\"") != null);
}

test "formatResourceError formats correctly" {
    const allocator = std.testing.allocator;

    const result = try formatResourceError(allocator, "Connection failed");
    defer allocator.free(result);

    try std.testing.expect(std.mem.indexOf(u8, result, "error") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Connection failed") != null);
}

test "listResources contains all resource URIs" {
    const result = listResources(null);

    // Verify all 3 resources are present
    try std.testing.expect(std.mem.indexOf(u8, result, "geode://default/default/schema") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "geode://default/default/stats") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "geode://config") != null);
}

test "listResources contains valid JSON structure" {
    const allocator = std.testing.allocator;
    const result = listResources(null);

    // Parse to verify it's valid JSON
    const parsed = std.json.parseFromSlice(std.json.Value, allocator, result, .{}) catch {
        try std.testing.expect(false); // Should not fail to parse
        return;
    };
    defer parsed.deinit();

    // Verify it's an array
    try std.testing.expect(parsed.value == .array);
    try std.testing.expectEqual(@as(usize, 3), parsed.value.array.items.len);
}

test "listResourceTemplates contains all templates" {
    const result = listResourceTemplates();

    // Verify all 4 templates are present
    try std.testing.expect(std.mem.indexOf(u8, result, "geode://{catalog}/{graph}/schema") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "geode://{catalog}/{graph}/stats") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "geode://{catalog}/{graph}/node/{label}") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "geode://{catalog}/{graph}/relationship/{type}") != null);
}

test "listResourceTemplates valid JSON structure" {
    const allocator = std.testing.allocator;
    const result = listResourceTemplates();

    const parsed = std.json.parseFromSlice(std.json.Value, allocator, result, .{}) catch {
        try std.testing.expect(false);
        return;
    };
    defer parsed.deinit();

    try std.testing.expect(parsed.value == .array);
    try std.testing.expectEqual(@as(usize, 4), parsed.value.array.items.len);
}

test "readResource returns error for unknown URI" {
    const allocator = std.testing.allocator;

    const result = try readResource(allocator, null, "unknown://resource");

    try std.testing.expect(std.mem.indexOf(u8, result, "error") != null);
    try std.testing.expect(std.mem.indexOf(u8, result, "Unknown resource URI") != null);
}

test "listResources cursor is ignored" {
    const result1 = listResources(null);
    const result2 = listResources("some_cursor");

    try std.testing.expectEqualStrings(result1, result2);
}
