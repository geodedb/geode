const std = @import("std");
const build_options = @import("build_options");

// CANARY: REQ=REQ-LIB-MIGRATION-MCP-003; FEATURE="External Library Migration"; ASPECT=MCPResources; STATUS=TESTED; OWNER=core; UPDATED=2026-01-24
// MCP Resources for Geode - expose graph data, schemas, and query results as resources

// CANARY: REQ=REQ-LIB-MIGRATION-JSON-042; FEATURE="JSON Library Migration"; ASPECT=MCPResources; STATUS=TESTED; OWNER=mcp; UPDATED=2026-01-24
const json_lib = @import("json");

const mcp_client = @import("client.zig");
const GeodeClient = mcp_client.GeodeClient;

// CANARY: REQ=REQ-SONNY-6552-MCP-RESULT-SHAPES; FEATURE="MCPResultShapes"; ASPECT=ResourceResults; STATUS=TESTED; TEST=tests/test_sonny6552_mcp_result_shapes.zig; OWNER=mcp; UPDATED=2026-11-14
// SONNY-6552: the results are the MCP 2025-11-25 objects (the revision the
// pinned mcp library negotiates), encoded on one line by the JSON library:
//   resources/list           -> ListResourcesResult { resources: Resource[], nextCursor? }
//   resources/templates/list -> ListResourceTemplatesResult { resourceTemplates: ResourceTemplate[], nextCursor? }
//   resources/read           -> ReadResourceResult { contents: TextResourceContents[] }
// They used to be a bare array, a bare {uri,mimeType,text}, and pretty-
// printed over many lines, which the newline-delimited stdio transport
// cannot carry. An unknown URI is `error.ResourceNotFound`, which the
// library answers with -32002 (resources "Error Handling"); it used to be a
// success carrying {"error": ...}. A cursor is `error.InvalidParams`
// (-32602): the list is one page and geode never issues one.

// MCP Resource Response Types for JSON Library encoding
const McpResourceResponse = struct {
    uri: []const u8,
    mimeType: []const u8,
    text: []const u8,
};

const McpReadResourceResult = struct {
    contents: []const McpResourceResponse,
};

const Resource = struct {
    uri: []const u8,
    name: []const u8,
    description: []const u8,
    mimeType: []const u8,
};

const ResourceTemplate = struct {
    uriTemplate: []const u8,
    name: []const u8,
    description: []const u8,
};

/// List available resources: a ListResourcesResult allocated with
/// `allocator` (the caller owns it; SONNY-6531: the mcp server frees it).
pub fn listResources(allocator: std.mem.Allocator, cursor: ?[]const u8) ![]const u8 {
    if (cursor != null) return error.InvalidParams;
    return try json_lib.encode(allocator, struct { resources: []const Resource }{ .resources = &resource_list }, .{});
}

/// Read a resource by URI: a ReadResourceResult allocated with `allocator`
/// (the caller owns it; SONNY-6531: the mcp server frees it). An unknown
/// URI is `error.ResourceNotFound`.
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

    return error.ResourceNotFound;
}

const schema_uri = "geode://default/default/schema";
const stats_uri = "geode://default/default/stats";
const config_uri = "geode://config";

/// Read schema resource from Geode server
fn readSchemaResource(allocator: std.mem.Allocator, endpoint: []const u8) ![]const u8 {
    const client = GeodeClient.init(allocator, endpoint) catch |err| {
        return try formatResourceError(allocator, schema_uri, mcp_client.initErrorMessage(err, "Failed to connect to Geode server"));
    };
    defer client.deinit();

    const schema_data = client.getSchema() catch {
        // Return fallback on connection error
        return try formatContents(allocator, schema_uri, "application/json", default_schema_text);
    };

    // Format as MCP resource response
    return try formatResourceResponse(allocator, schema_uri, "application/json", schema_data);
}

/// Read stats resource from Geode server
fn readStatsResource(allocator: std.mem.Allocator, endpoint: []const u8) ![]const u8 {
    const client = GeodeClient.init(allocator, endpoint) catch |err| {
        return try formatResourceError(allocator, stats_uri, mcp_client.initErrorMessage(err, "Failed to connect to Geode server"));
    };
    defer client.deinit();

    const stats_data = client.getStats() catch {
        return try formatContents(allocator, stats_uri, "application/json", default_stats_text);
    };

    return try formatResourceResponse(allocator, stats_uri, "application/json", stats_data);
}

/// Read config resource from Geode server
fn readConfigResource(allocator: std.mem.Allocator, endpoint: []const u8) ![]const u8 {
    const client = GeodeClient.init(allocator, endpoint) catch |err| {
        return try formatResourceError(allocator, config_uri, mcp_client.initErrorMessage(err, "Failed to connect to Geode server"));
    };
    defer client.deinit();

    const config_data = client.getConfig() catch {
        return try formatContents(allocator, config_uri, "application/json", default_config_text);
    };

    return try formatResourceResponse(allocator, config_uri, "application/json", config_data);
}

/// A ReadResourceResult holding one text resource. Does not take `text`.
fn formatContents(allocator: std.mem.Allocator, uri: []const u8, mime_type: []const u8, text: []const u8) ![]const u8 {
    const contents = [_]McpResourceResponse{.{ .uri = uri, .mimeType = mime_type, .text = text }};
    return try json_lib.encode(allocator, McpReadResourceResult{ .contents = &contents }, .{});
}

/// Format a successful resource response for MCP. Takes ownership of `content`.
/// CANARY: REQ=REQ-LIB-MIGRATION-JSON-043; FEATURE="JSON Library Migration"; ASPECT=ResourceResponse; STATUS=TESTED; OWNER=mcp; UPDATED=2026-01-24
fn formatResourceResponse(allocator: std.mem.Allocator, uri: []const u8, mime_type: []const u8, content: []const u8) ![]const u8 {
    defer allocator.free(content);

    // Build MCP resource response using JSON library (handles escaping automatically)
    return try formatContents(allocator, uri, mime_type, content);
}

/// The resource as a document naming why it could not be read (the
/// endpoint DSN is unusable, SONNY-6494). The MCP library can only answer
/// an error with the Zig error's name, which would lose the reason, so the
/// reason is the resource's text, like the offline fallback documents.
/// CANARY: REQ=REQ-LIB-MIGRATION-JSON-044; FEATURE="JSON Library Migration"; ASPECT=ResourceError; STATUS=TESTED; OWNER=mcp; UPDATED=2026-01-24
fn formatResourceError(allocator: std.mem.Allocator, uri: []const u8, error_msg: []const u8) ![]const u8 {
    const text = try json_lib.encode(allocator, struct { @"error": []const u8 }{ .@"error" = error_msg }, .{});
    defer allocator.free(text);
    return try formatContents(allocator, uri, "application/json", text);
}

/// List resource templates: a ListResourceTemplatesResult allocated with
/// `allocator` (the caller owns it).
pub fn listResourceTemplates(allocator: std.mem.Allocator) ![]const u8 {
    return try json_lib.encode(allocator, struct { resourceTemplates: []const ResourceTemplate }{ .resourceTemplates = &resource_template_list }, .{});
}

// Fallback resource text when the server is unavailable
const default_schema_text = "{\"node_labels\": [], \"relationship_types\": [], \"note\": \"Server unavailable\"}";

const default_stats_text = "{\"node_count\": 0, \"relationship_count\": 0, \"index_count\": 0, \"note\": \"Server unavailable\"}";

const default_config_text = "{\"version\": \"" ++ build_options.version ++ "\", \"gql_compliance\": \"ISO/IEC 39075:2024\", \"status\": \"disconnected\"}";

/// The resources geode serves
const resource_list = [_]Resource{
    .{
        .uri = schema_uri,
        .name = "Graph Schema",
        .description = "Current graph schema including node labels, relationship types, and properties",
        .mimeType = "application/json",
    },
    .{
        .uri = stats_uri,
        .name = "Database Statistics",
        .description = "Database statistics including node count, relationship count, and index information",
        .mimeType = "application/json",
    },
    .{
        .uri = config_uri,
        .name = "Server Configuration",
        .description = "Current server configuration and version information",
        .mimeType = "application/json",
    },
};

/// The resource templates
const resource_template_list = [_]ResourceTemplate{
    .{ .uriTemplate = "geode://{catalog}/{graph}/schema", .name = "Graph Schema Template", .description = "Schema for a specific catalog and graph" },
    .{ .uriTemplate = "geode://{catalog}/{graph}/stats", .name = "Statistics Template", .description = "Statistics for a specific catalog and graph" },
    .{ .uriTemplate = "geode://{catalog}/{graph}/node/{label}", .name = "Node Label Template", .description = "Information about a specific node label" },
    .{ .uriTemplate = "geode://{catalog}/{graph}/relationship/{type}", .name = "Relationship Type Template", .description = "Information about a specific relationship type" },
};

// =============================================================================
// Tests
// =============================================================================

fn parseResult(allocator: std.mem.Allocator, result: []const u8) !std.json.Parsed(std.json.Value) {
    try std.testing.expect(std.mem.indexOfScalar(u8, result, '\n') == null);
    return std.json.parseFromSlice(std.json.Value, allocator, result, .{});
}

test "listResources returns a ListResourcesResult on one line" {
    const allocator = std.testing.allocator;
    const result = try listResources(allocator, null);
    defer allocator.free(result);
    const parsed = try parseResult(allocator, result);
    defer parsed.deinit();
    const list = parsed.value.object.get("resources").?.array.items;
    try std.testing.expectEqual(@as(usize, 3), list.len);
    try std.testing.expectEqualStrings(schema_uri, list[0].object.get("uri").?.string);
    try std.testing.expectEqualStrings(stats_uri, list[1].object.get("uri").?.string);
    try std.testing.expectEqualStrings(config_uri, list[2].object.get("uri").?.string);
}

test "listResources refuses a cursor geode never issued" {
    try std.testing.expectError(error.InvalidParams, listResources(std.testing.allocator, "some_cursor"));
}

test "listResourceTemplates returns a ListResourceTemplatesResult on one line" {
    const allocator = std.testing.allocator;
    const result = try listResourceTemplates(allocator);
    defer allocator.free(result);
    const parsed = try parseResult(allocator, result);
    defer parsed.deinit();
    const list = parsed.value.object.get("resourceTemplates").?.array.items;
    try std.testing.expectEqual(@as(usize, 4), list.len);
    try std.testing.expectEqualStrings("geode://{catalog}/{graph}/schema", list[0].object.get("uriTemplate").?.string);
    try std.testing.expectEqualStrings("geode://{catalog}/{graph}/relationship/{type}", list[3].object.get("uriTemplate").?.string);
}

test "formatResourceError is a ReadResourceResult whose text names the error" {
    const allocator = std.testing.allocator;
    const result = try formatResourceError(allocator, config_uri, "Error with \"quotes\"");
    defer allocator.free(result);
    const parsed = try parseResult(allocator, result);
    defer parsed.deinit();
    const c = parsed.value.object.get("contents").?.array.items[0].object;
    try std.testing.expectEqualStrings(config_uri, c.get("uri").?.string);
    try std.testing.expect(std.mem.indexOf(u8, c.get("text").?.string, "Error with \\\"quotes\\\"") != null);
}

test "readResource answers an unknown URI with ResourceNotFound" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.ResourceNotFound, readResource(allocator, null, "unknown://resource"));
    try std.testing.expectError(error.ResourceNotFound, readResource(allocator, null, "geode://default/default/nothing"));
}
