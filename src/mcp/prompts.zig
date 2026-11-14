const std = @import("std");

// CANARY: REQ=REQ-LIB-MIGRATION-MCP-004; FEATURE="External Library Migration"; ASPECT=MCPPrompts; STATUS=TESTED; OWNER=core; UPDATED=2026-01-24
// MCP Prompts for Geode - GQL query templates and examples

// CANARY: REQ=REQ-SONNY-6552-MCP-RESULT-SHAPES; FEATURE="MCPResultShapes"; ASPECT=PromptResults; STATUS=TESTED; TEST=tests/test_sonny6552_mcp_result_shapes.zig; OWNER=mcp; UPDATED=2026-11-14
// SONNY-6552: the results are the MCP 2025-11-25 objects (the revision the
// pinned mcp library negotiates), serialized by std.json on one line:
//   prompts/list -> ListPromptsResult { prompts: Prompt[], nextCursor? }
//   prompts/get  -> GetPromptResult { description?, messages: PromptMessage[] }
// An unknown prompt name, a missing required argument, an argument the
// prompt does not take and a non-string argument value are
// `error.InvalidParams` (the library answers -32602, the code the spec's
// prompts "Error Handling" section gives); so is a cursor, since geode's
// list is one page and never issues one (pagination utility). The
// argument values are written into the prompt text: an advertised argument
// is never ignored.

pub const Argument = struct {
    name: []const u8,
    description: []const u8,
    required: bool,
};

const Def = struct {
    name: []const u8,
    description: []const u8,
    arguments: []const Argument,
    /// GetPromptResult.description
    summary: []const u8,
    /// The user message text, before the argument values.
    text: []const u8,
};

const defs = [_]Def{
    .{
        .name = "find_nodes",
        .description = "Generate a GQL query to find nodes by label and optional property filters",
        .arguments = &.{
            .{ .name = "label", .description = "Node label to search for", .required = true },
            .{ .name = "properties", .description = "Property filters as key=value pairs", .required = false },
        },
        .summary = "Find nodes by label with optional property filters",
        .text = "Generate a GQL query to find all nodes with the specified label. Use MATCH (n:Label) RETURN n syntax. If property filters are provided, add WHERE clauses.",
    },
    .{
        .name = "find_relationships",
        .description = "Generate a GQL query to find relationships by type",
        .arguments = &.{
            .{ .name = "type", .description = "Relationship type to search for", .required = true },
            .{ .name = "direction", .description = "Direction: 'outgoing', 'incoming', or 'both'", .required = false },
        },
        .summary = "Find relationships by type",
        .text = "Generate a GQL query to find relationships of the specified type. Use MATCH (a)-[r:TYPE]->(b) RETURN a, r, b syntax.",
    },
    .{
        .name = "create_node",
        .description = "Generate a GQL query to create a new node",
        .arguments = &.{
            .{ .name = "label", .description = "Node label", .required = true },
            .{ .name = "properties", .description = "Node properties as JSON object", .required = false },
        },
        .summary = "Create a new node with properties",
        .text = "Generate a GQL query to create a new node. Use CREATE (n:Label {prop1: value1, prop2: value2}) RETURN n syntax.",
    },
    .{
        .name = "create_relationship",
        .description = "Generate a GQL query to create a relationship between nodes",
        .arguments = &.{
            .{ .name = "from_label", .description = "Source node label", .required = true },
            .{ .name = "to_label", .description = "Target node label", .required = true },
            .{ .name = "type", .description = "Relationship type", .required = true },
        },
        .summary = "Create a relationship between nodes",
        .text = "Generate a GQL query to create a relationship. Use MATCH (a:FromLabel), (b:ToLabel) CREATE (a)-[r:TYPE]->(b) RETURN r syntax.",
    },
    .{
        .name = "shortest_path",
        .description = "Generate a GQL query to find the shortest path between two nodes",
        .arguments = &.{
            .{ .name = "from_label", .description = "Starting node label", .required = true },
            .{ .name = "to_label", .description = "Ending node label", .required = true },
        },
        .summary = "Find shortest path between nodes",
        .text = "Generate a GQL query to find the shortest path between two nodes. Use MATCH path = SHORTEST (a:FromLabel)-[*]-(b:ToLabel) RETURN path syntax.",
    },
    .{
        .name = "graph_analysis",
        .description = "Generate a GQL query for graph analytics (degree, centrality, etc.)",
        .arguments = &.{
            .{ .name = "metric", .description = "Metric: 'degree', 'centrality', 'clustering'", .required = true },
        },
        .summary = "Graph analytics queries",
        .text = "Generate a GQL query for graph analysis. For degree: MATCH (n) RETURN n, count{(n)--} AS degree. For centrality and clustering, use appropriate aggregations.",
    },
    .{
        .name = "pattern_match",
        .description = "Generate a GQL pattern matching query",
        .arguments = &.{
            .{ .name = "pattern", .description = "Graph pattern description", .required = true },
        },
        .summary = "Pattern matching in graphs",
        .text = "Generate a GQL pattern matching query based on the described pattern. Use MATCH with appropriate node labels, relationship types, and path patterns.",
    },
};

/// The ListPromptsResult view of `defs`.
const Prompt = struct {
    name: []const u8,
    description: []const u8,
    arguments: []const Argument,
};

const prompt_list = blk: {
    var list: [defs.len]Prompt = undefined;
    for (defs, 0..) |d, i| list[i] = .{ .name = d.name, .description = d.description, .arguments = d.arguments };
    const final = list;
    break :blk final;
};

/// `prompts/list`: a ListPromptsResult, allocated with `allocator` (the
/// caller owns it). geode's list is one page: any cursor is invalid.
pub fn listPrompts(allocator: std.mem.Allocator, cursor: ?[]const u8) ![]const u8 {
    if (cursor != null) return error.InvalidParams;
    return std.json.Stringify.valueAlloc(allocator, .{ .prompts = @as([]const Prompt, &prompt_list) }, .{});
}

fn find(name: []const u8) ?*const Def {
    for (&defs) |*d| if (std.mem.eql(u8, d.name, name)) return d;
    return null;
}

const TextContent = struct { type: []const u8 = "text", text: []const u8 };
const PromptMessage = struct { role: []const u8 = "user", content: TextContent };

/// `prompts/get`: a GetPromptResult, allocated with `allocator` (the caller
/// owns it). `args_json` is the request's `arguments` object, or null.
pub fn getPrompt(allocator: std.mem.Allocator, name: []const u8, args_json: ?[]const u8) ![]const u8 {
    const def = find(name) orelse return error.InvalidParams;

    var parsed: ?std.json.Parsed(std.json.Value) = null;
    defer if (parsed) |*p| p.deinit();
    var args: ?std.json.ObjectMap = null;
    if (args_json) |a| {
        parsed = std.json.parseFromSlice(std.json.Value, allocator, a, .{}) catch return error.InvalidParams;
        if (parsed.?.value != .object) return error.InvalidParams;
        args = parsed.?.value.object;
    }

    // GetPromptRequest.arguments is {[key: string]: string}, and only the
    // arguments the prompt advertises.
    if (args) |obj| {
        var it = obj.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.* != .string) return error.InvalidParams;
            for (def.arguments) |arg| {
                if (std.mem.eql(u8, arg.name, entry.key_ptr.*)) break;
            } else return error.InvalidParams;
        }
    }
    for (def.arguments) |arg| {
        if (arg.required and (args == null or args.?.get(arg.name) == null)) return error.InvalidParams;
    }

    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    try text.appendSlice(allocator, def.text);
    if (args) |obj| if (obj.count() > 0) {
        try text.appendSlice(allocator, "\n\nArguments:");
        for (def.arguments) |arg| if (obj.get(arg.name)) |v| {
            try text.print(allocator, "\n- {s}: {s}", .{ arg.name, v.string });
        };
    };

    const messages = [_]PromptMessage{.{ .content = .{ .text = text.items } }};
    return std.json.Stringify.valueAlloc(allocator, .{
        .description = def.summary,
        .messages = @as([]const PromptMessage, &messages),
    }, .{});
}

// =============================================================================
// Tests
// =============================================================================

test "listPrompts returns a ListPromptsResult on one line" {
    const allocator = std.testing.allocator;
    const result = try listPrompts(allocator, null);
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOfScalar(u8, result, '\n') == null);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result, .{});
    defer parsed.deinit();
    const prompts = parsed.value.object.get("prompts").?.array.items;
    try std.testing.expectEqual(defs.len, prompts.len);
    try std.testing.expectEqualStrings("find_nodes", prompts[0].object.get("name").?.string);
}

test "listPrompts refuses a cursor geode never issued" {
    try std.testing.expectError(error.InvalidParams, listPrompts(std.testing.allocator, "next"));
}

test "getPrompt returns a GetPromptResult with the argument values" {
    const allocator = std.testing.allocator;
    const result = try getPrompt(allocator, "find_nodes", "{\"label\":\"Person\"}");
    defer allocator.free(result);
    try std.testing.expect(std.mem.indexOfScalar(u8, result, '\n') == null);
    const parsed = try std.json.parseFromSlice(std.json.Value, allocator, result, .{});
    defer parsed.deinit();
    try std.testing.expect(parsed.value.object.get("description") != null);
    const msg = parsed.value.object.get("messages").?.array.items[0].object;
    try std.testing.expectEqualStrings("user", msg.get("role").?.string);
    const text = msg.get("content").?.object.get("text").?.string;
    try std.testing.expect(std.mem.indexOf(u8, text, "- label: Person") != null);
}

test "getPrompt refuses an unknown name and bad arguments" {
    const allocator = std.testing.allocator;
    try std.testing.expectError(error.InvalidParams, getPrompt(allocator, "unknown_prompt", null));
    try std.testing.expectError(error.InvalidParams, getPrompt(allocator, "find_nodes", null));
    try std.testing.expectError(error.InvalidParams, getPrompt(allocator, "find_nodes", "{}"));
    try std.testing.expectError(error.InvalidParams, getPrompt(allocator, "find_nodes", "{\"label\":1}"));
    try std.testing.expectError(error.InvalidParams, getPrompt(allocator, "find_nodes", "{\"label\":\"A\",\"x\":\"y\"}"));
}
