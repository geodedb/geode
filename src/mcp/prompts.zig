const std = @import("std");

// CANARY: REQ=REQ-LIB-MIGRATION-MCP-004; FEATURE="External Library Migration"; ASPECT=MCPPrompts; STATUS=TESTED; OWNER=core; UPDATED=2026-01-24
// MCP Prompts for Geode - GQL query templates and examples

/// List available prompts
/// Returns JSON array of prompt definitions
/// Static text: the server.zig handler hands the mcp server a copy
/// (SONNY-6531, the server frees every handler result).
pub fn listPrompts(cursor: ?[]const u8) []const u8 {
    _ = cursor; // Pagination not needed for small prompt list
    return prompts_json;
}

/// Get a specific prompt by name
/// Static text: the server.zig handler hands the mcp server a copy
/// (SONNY-6531, the server frees every handler result).
pub fn getPrompt(name: []const u8, args_json: ?[]const u8) []const u8 {
    _ = args_json; // Some prompts may use arguments

    if (std.mem.eql(u8, name, "find_nodes")) {
        return find_nodes_prompt;
    } else if (std.mem.eql(u8, name, "find_relationships")) {
        return find_relationships_prompt;
    } else if (std.mem.eql(u8, name, "create_node")) {
        return create_node_prompt;
    } else if (std.mem.eql(u8, name, "create_relationship")) {
        return create_relationship_prompt;
    } else if (std.mem.eql(u8, name, "shortest_path")) {
        return shortest_path_prompt;
    } else if (std.mem.eql(u8, name, "graph_analysis")) {
        return graph_analysis_prompt;
    } else if (std.mem.eql(u8, name, "pattern_match")) {
        return pattern_match_prompt;
    } else {
        return "{\"error\": \"Unknown prompt\"}";
    }
}

/// Static JSON definition of available prompts
const prompts_json =
    \\[
    \\  {
    \\    "name": "find_nodes",
    \\    "description": "Generate a GQL query to find nodes by label and optional property filters",
    \\    "arguments": [
    \\      {"name": "label", "description": "Node label to search for", "required": true},
    \\      {"name": "properties", "description": "Property filters as key=value pairs", "required": false}
    \\    ]
    \\  },
    \\  {
    \\    "name": "find_relationships",
    \\    "description": "Generate a GQL query to find relationships by type",
    \\    "arguments": [
    \\      {"name": "type", "description": "Relationship type to search for", "required": true},
    \\      {"name": "direction", "description": "Direction: 'outgoing', 'incoming', or 'both'", "required": false}
    \\    ]
    \\  },
    \\  {
    \\    "name": "create_node",
    \\    "description": "Generate a GQL query to create a new node",
    \\    "arguments": [
    \\      {"name": "label", "description": "Node label", "required": true},
    \\      {"name": "properties", "description": "Node properties as JSON object", "required": false}
    \\    ]
    \\  },
    \\  {
    \\    "name": "create_relationship",
    \\    "description": "Generate a GQL query to create a relationship between nodes",
    \\    "arguments": [
    \\      {"name": "from_label", "description": "Source node label", "required": true},
    \\      {"name": "to_label", "description": "Target node label", "required": true},
    \\      {"name": "type", "description": "Relationship type", "required": true}
    \\    ]
    \\  },
    \\  {
    \\    "name": "shortest_path",
    \\    "description": "Generate a GQL query to find the shortest path between two nodes",
    \\    "arguments": [
    \\      {"name": "from_label", "description": "Starting node label", "required": true},
    \\      {"name": "to_label", "description": "Ending node label", "required": true}
    \\    ]
    \\  },
    \\  {
    \\    "name": "graph_analysis",
    \\    "description": "Generate a GQL query for graph analytics (degree, centrality, etc.)",
    \\    "arguments": [
    \\      {"name": "metric", "description": "Metric: 'degree', 'centrality', 'clustering'", "required": true}
    \\    ]
    \\  },
    \\  {
    \\    "name": "pattern_match",
    \\    "description": "Generate a GQL pattern matching query",
    \\    "arguments": [
    \\      {"name": "pattern", "description": "Graph pattern description", "required": true}
    \\    ]
    \\  }
    \\]
;

const find_nodes_prompt =
    \\{
    \\  "description": "Find nodes by label with optional property filters",
    \\  "messages": [
    \\    {
    \\      "role": "user",
    \\      "content": {
    \\        "type": "text",
    \\        "text": "Generate a GQL query to find all nodes with the specified label. Use MATCH (n:Label) RETURN n syntax. If property filters are provided, add WHERE clauses."
    \\      }
    \\    }
    \\  ]
    \\}
;

const find_relationships_prompt =
    \\{
    \\  "description": "Find relationships by type",
    \\  "messages": [
    \\    {
    \\      "role": "user",
    \\      "content": {
    \\        "type": "text",
    \\        "text": "Generate a GQL query to find relationships of the specified type. Use MATCH (a)-[r:TYPE]->(b) RETURN a, r, b syntax."
    \\      }
    \\    }
    \\  ]
    \\}
;

const create_node_prompt =
    \\{
    \\  "description": "Create a new node with properties",
    \\  "messages": [
    \\    {
    \\      "role": "user",
    \\      "content": {
    \\        "type": "text",
    \\        "text": "Generate a GQL query to create a new node. Use CREATE (n:Label {prop1: value1, prop2: value2}) RETURN n syntax."
    \\      }
    \\    }
    \\  ]
    \\}
;

const create_relationship_prompt =
    \\{
    \\  "description": "Create a relationship between nodes",
    \\  "messages": [
    \\    {
    \\      "role": "user",
    \\      "content": {
    \\        "type": "text",
    \\        "text": "Generate a GQL query to create a relationship. Use MATCH (a:FromLabel), (b:ToLabel) CREATE (a)-[r:TYPE]->(b) RETURN r syntax."
    \\      }
    \\    }
    \\  ]
    \\}
;

const shortest_path_prompt =
    \\{
    \\  "description": "Find shortest path between nodes",
    \\  "messages": [
    \\    {
    \\      "role": "user",
    \\      "content": {
    \\        "type": "text",
    \\        "text": "Generate a GQL query to find the shortest path between two nodes. Use MATCH path = SHORTEST (a:FromLabel)-[*]-(b:ToLabel) RETURN path syntax."
    \\      }
    \\    }
    \\  ]
    \\}
;

const graph_analysis_prompt =
    \\{
    \\  "description": "Graph analytics queries",
    \\  "messages": [
    \\    {
    \\      "role": "user",
    \\      "content": {
    \\        "type": "text",
    \\        "text": "Generate a GQL query for graph analysis. For degree: MATCH (n) RETURN n, count{(n)--} AS degree. For centrality and clustering, use appropriate aggregations."
    \\      }
    \\    }
    \\  ]
    \\}
;

const pattern_match_prompt =
    \\{
    \\  "description": "Pattern matching in graphs",
    \\  "messages": [
    \\    {
    \\      "role": "user",
    \\      "content": {
    \\        "type": "text",
    \\        "text": "Generate a GQL pattern matching query based on the described pattern. Use MATCH with appropriate node labels, relationship types, and path patterns."
    \\      }
    \\    }
    \\  ]
    \\}
;

// =============================================================================
// Tests
// =============================================================================

test "listPrompts returns valid JSON" {
    const result = listPrompts(null);
    try std.testing.expect(result.len > 0);
    try std.testing.expect(std.mem.startsWith(u8, result, "["));
}

test "getPrompt returns prompt for known name" {
    const result = getPrompt("find_nodes", null);
    try std.testing.expect(result.len > 0);
    try std.testing.expect(std.mem.indexOf(u8, result, "description") != null);
}

test "getPrompt returns error for unknown name" {
    const result = getPrompt("unknown_prompt", null);
    try std.testing.expect(std.mem.indexOf(u8, result, "error") != null);
}
