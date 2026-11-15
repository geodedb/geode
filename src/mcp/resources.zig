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
    const target = parseUri(uri) orelse return error.ResourceNotFound;
    return switch (target) {
        .config => readConfigResource(allocator, endpoint_str),
        else => readGraphResource(allocator, endpoint_str, uri, target),
    };
}

// CANARY: REQ=REQ-SONNY-6559-MCP-RESOURCE-URIS; FEATURE="MCPBackendTools"; ASPECT=StrictUrisAndTemplates; STATUS=TESTED; TEST=tests/test_sonny6559_mcp_backend.zig; OWNER=mcp; UPDATED=2026-11-14
// SONNY-6559 (6): a resource URI is one of
//   geode://config
//   geode://default/<graph>/schema | stats
//   geode://default/<graph>/node/<label> | relationship/<type>
// with <graph>, <label> and <type> GQL identifiers ([A-Za-z_][A-Za-z0-9_]*,
// written into the statement only after this check). Anything else is
// -32002. The URI used to match on a substring (any path holding "config"
// or "/schema"), {catalog}/{graph} were ignored (every graph read the
// session's), and the node/relationship templates were advertised and
// never read. `{catalog}` is `default`: geode keeps its graphs in one
// namespace and has no catalog object (ISO/IEC 39075 catalogs hold schemas
// holding graphs), so there is no other catalog to name.

/// The one catalog name a resource URI may carry.
pub const default_catalog = "default";

pub const Target = union(enum) {
    config,
    schema: []const u8,
    stats: []const u8,
    node: struct { graph: []const u8, label: []const u8 },
    relationship: struct { graph: []const u8, type: []const u8 },
};

fn isIdentifier(s: []const u8) bool {
    if (s.len == 0 or s.len > 128) return false;
    if (!std.ascii.isAlphabetic(s[0]) and s[0] != '_') return false;
    for (s[1..]) |c| {
        if (!std.ascii.isAlphanumeric(c) and c != '_') return false;
    }
    return true;
}

/// The resource `uri` names, or null (not one geode serves).
pub fn parseUri(uri: []const u8) ?Target {
    const scheme = "geode://";
    if (!std.mem.startsWith(u8, uri, scheme)) return null;
    const rest = uri[scheme.len..];
    if (std.mem.eql(u8, rest, "config")) return .config;

    var parts: [4][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, rest, '/');
    while (it.next()) |part| {
        if (n == parts.len) return null;
        parts[n] = part;
        n += 1;
    }
    if (n < 3) return null;
    if (!std.mem.eql(u8, parts[0], default_catalog) or !isIdentifier(parts[1])) return null;
    const graph = parts[1];
    if (n == 3) {
        if (std.mem.eql(u8, parts[2], "schema")) return .{ .schema = graph };
        if (std.mem.eql(u8, parts[2], "stats")) return .{ .stats = graph };
        return null;
    }
    if (!isIdentifier(parts[3])) return null;
    if (std.mem.eql(u8, parts[2], "node")) return .{ .node = .{ .graph = graph, .label = parts[3] } };
    if (std.mem.eql(u8, parts[2], "relationship")) return .{ .relationship = .{ .graph = graph, .type = parts[3] } };
    return null;
}

/// How many nodes or relationships a node/relationship resource samples.
const sample_limit = 25;

/// A graph resource read through the normal client path (the endpoint's
/// credentials, so its permissions and row-level security apply).
fn readGraphResource(allocator: std.mem.Allocator, endpoint: []const u8, uri: []const u8, target: Target) ![]const u8 {
    const client = GeodeClient.init(allocator, endpoint) catch |err| {
        return try formatResourceError(allocator, uri, mcp_client.initErrorMessage(err, "Failed to connect to Geode server"));
    };
    defer client.deinit();

    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const doc = graphDocument(arena.allocator(), client, target) catch |err| switch (err) {
        error.ResourceNotFound => return err,
        error.OutOfMemory => return err,
        else => {
            // SONNY-6617 (3): an endpoint that cannot work as configured
            // (a gRPC endpoint with TLS on) says why, whatever the resource.
            if (mcp_client.endpointErrorMessage(err)) |why| return try formatResourceError(allocator, uri, why);
            // The server could not be reached: schema and stats answer
            // their offline documents (as before); the others say why.
            return switch (target) {
                .schema => try formatContents(allocator, uri, "application/json", default_schema_text),
                .stats => try formatContents(allocator, uri, "application/json", default_stats_text),
                else => try formatResourceError(allocator, uri, @errorName(err)),
            };
        },
    };
    const text = try std.json.Stringify.valueAlloc(allocator, doc, .{});
    defer allocator.free(text);
    return try formatContents(allocator, uri, "application/json", text);
}

const QueryOutcome = union(enum) {
    ok: std.json.ObjectMap,
    /// The server's error document ({"code","message"}).
    failed: std.json.Value,
};

/// Run `gql` on `graph`; a graph that does not exist (3F000) is
/// error.ResourceNotFound.
fn runOn(a: std.mem.Allocator, client: *GeodeClient, graph: []const u8, gql: []const u8) !QueryOutcome {
    const text = try client.queryIn(graph, gql);
    defer client.allocator.free(text);
    const value = try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{ .allocate = .alloc_always });
    if (value != .object) return error.InvalidResponse;
    if (value.object.get("error")) |e| {
        if (e == .object) {
            if (e.object.get("code")) |code| {
                if (code == .string and std.mem.eql(u8, code.string, "3F000")) return error.ResourceNotFound;
            }
        }
        return .{ .failed = e };
    }
    return .{ .ok = value.object };
}

/// The rows of a successful outcome, or the error document.
fn rowsOf(outcome: QueryOutcome) std.json.Value {
    return switch (outcome) {
        .ok => |o| o.get("rows") orelse .null,
        .failed => |e| e,
    };
}

/// The first row's first value (a count), or the error document.
fn scalarOf(outcome: QueryOutcome) std.json.Value {
    return switch (outcome) {
        .ok => |o| blk: {
            const rows = o.get("rows") orelse break :blk .null;
            if (rows != .array or rows.array.items.len == 0) break :blk .null;
            const row = rows.array.items[0];
            if (row != .object) break :blk .null;
            var it = row.object.iterator();
            break :blk if (it.next()) |e| e.value_ptr.* else .null;
        },
        .failed => |e| e,
    };
}

/// The values of the first column of every row.
fn columnOf(a: std.mem.Allocator, outcome: QueryOutcome) !std.json.Value {
    const rows = rowsOf(outcome);
    if (rows != .array) return rows;
    var out = std.json.Array.init(a);
    for (rows.array.items) |row| {
        if (row != .object) continue;
        var it = row.object.iterator();
        if (it.next()) |e| try out.append(e.value_ptr.*);
    }
    return .{ .array = out };
}

fn graphDocument(a: std.mem.Allocator, client: *GeodeClient, target: Target) !std.json.Value {
    var doc: std.json.ObjectMap = .empty;
    switch (target) {
        .config => unreachable,
        .schema => |graph| {
            try doc.put(a, "graph", .{ .string = graph });
            try doc.put(a, "node_labels", try columnOf(a, try runOn(a, client, graph, mcp_client.schema_labels_query)));
            try doc.put(a, "relationship_types", try columnOf(a, try runOn(a, client, graph, "MATCH ()-[r]->() RETURN DISTINCT type(r) AS type LIMIT 100")));
        },
        .stats => |graph| {
            try doc.put(a, "graph", .{ .string = graph });
            try doc.put(a, "node_count", scalarOf(try runOn(a, client, graph, "MATCH (n) RETURN count(n) AS node_count")));
            try doc.put(a, "relationship_count", scalarOf(try runOn(a, client, graph, "MATCH ()-[r]->() RETURN count(r) AS relationship_count")));
        },
        .node => |t| {
            try doc.put(a, "graph", .{ .string = t.graph });
            try doc.put(a, "label", .{ .string = t.label });
            const count_q = try std.fmt.allocPrint(a, "MATCH (n:{s}) RETURN count(n) AS count", .{t.label});
            const sample_q = try std.fmt.allocPrint(a, "MATCH (n:{s}) RETURN n LIMIT {d}", .{ t.label, sample_limit });
            try doc.put(a, "count", scalarOf(try runOn(a, client, t.graph, count_q)));
            try doc.put(a, "sample", try columnOf(a, try runOn(a, client, t.graph, sample_q)));
        },
        .relationship => |t| {
            try doc.put(a, "graph", .{ .string = t.graph });
            try doc.put(a, "type", .{ .string = t.type });
            const count_q = try std.fmt.allocPrint(a, "MATCH ()-[r:{s}]->() RETURN count(r) AS count", .{t.type});
            const sample_q = try std.fmt.allocPrint(a, "MATCH ()-[r:{s}]->() RETURN r LIMIT {d}", .{ t.type, sample_limit });
            try doc.put(a, "count", scalarOf(try runOn(a, client, t.graph, count_q)));
            try doc.put(a, "sample", try columnOf(a, try runOn(a, client, t.graph, sample_q)));
        },
    }
    return .{ .object = doc };
}

const schema_uri = "geode://default/default/schema";
const stats_uri = "geode://default/default/stats";
const config_uri = "geode://config";

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
        .description = "The node label sets and relationship types of the graph named default (up to 100 of each)",
        .mimeType = "application/json",
    },
    .{
        .uri = stats_uri,
        .name = "Graph Statistics",
        .description = "The node and relationship counts of the graph named default",
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
    .{ .uriTemplate = "geode://{catalog}/{graph}/schema", .name = "Graph Schema Template", .description = "The node label sets and relationship types of {graph} (a graph name); {catalog} is default, geode's one catalog" },
    .{ .uriTemplate = "geode://{catalog}/{graph}/stats", .name = "Statistics Template", .description = "The node and relationship counts of {graph}; {catalog} is default" },
    .{ .uriTemplate = "geode://{catalog}/{graph}/node/{label}", .name = "Node Label Template", .description = "The number of {label} nodes in {graph} and up to 25 of them; {catalog} is default" },
    .{ .uriTemplate = "geode://{catalog}/{graph}/relationship/{type}", .name = "Relationship Type Template", .description = "The number of {type} relationships in {graph} and up to 25 of them; {catalog} is default" },
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

test "parseUri accepts the served grammar and nothing else" {
    try std.testing.expect(parseUri("geode://config").? == .config);
    try std.testing.expectEqualStrings("g1", parseUri("geode://default/g1/schema").?.schema);
    try std.testing.expectEqualStrings("default", parseUri("geode://default/default/stats").?.stats);
    try std.testing.expectEqualStrings("Person", parseUri("geode://default/g/node/Person").?.node.label);
    try std.testing.expectEqualStrings("KNOWS", parseUri("geode://default/g/relationship/KNOWS").?.relationship.type);
    for ([_][]const u8{
        "geode://config/x",                 "geode://xconfig",                  "geode://configuration",
        "geode://default/default/schemax",  "geode://default/default/schema/x", "geode://other/default/schema",
        "geode://default/bad-graph/schema", "geode://default/g/node/",          "geode://default/g/node/a b",
        "geode://default/g/node/a/b",       "geode://default//schema",          "geode:/config",
        "geode://config?x=1",               "http://default/default/schema",    "geode://default/g/edge/KNOWS",
        "geode://default/g/node/`x`",
    }) |uri| {
        if (parseUri(uri) != null) {
            std.debug.print("parseUri accepted {s}\n", .{uri});
            return error.TestUnexpectedResult;
        }
    }
}
