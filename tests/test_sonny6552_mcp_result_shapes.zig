// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6552: every geode MCP response has the shape the MCP specification
// gives it, on the in-process dispatch and on a real `geode mcp --stdio`.
//
// The pinned mcp library (v0.1.22) implements MCP revision 2025-11-25
// (`mcp.ProtocolVersion`, negotiated in `initialize`). That revision's
// schema (schema/2025-11-25/schema.ts) gives the results checked here:
//
//   ListToolsResult             { tools: Tool[], nextCursor? }
//   ListResourcesResult         { resources: Resource[], nextCursor? }
//   ListResourceTemplatesResult { resourceTemplates: ResourceTemplate[], nextCursor? }
//   ReadResourceResult          { contents: (TextResourceContents | BlobResourceContents)[] }
//   ListPromptsResult           { prompts: Prompt[], nextCursor? }
//   GetPromptResult             { description?, messages: PromptMessage[] }
//   CallToolResult              { content: ContentBlock[], structuredContent?, isError? }
//   CompleteResult              { completion: { values: string[], total?, hasMore? } }
//
// and its error rules: an unknown tool is a protocol error (-32602, the
// spec's own example); an invalid prompt name or a missing required prompt
// argument is -32602; an unknown resource is -32002; an invalid cursor is
// -32602 (pagination utility). The stdio transport delimits messages by
// newlines, and a message "MUST NOT contain embedded newlines".
//
// geode answered resources/list, resources/templates/list and prompts/list
// with bare arrays, resources/read with a bare {uri,mimeType,text}, an
// unknown prompt or URI with a success carrying {"error":...}, an unknown
// tool with -32603, and spread those results over many lines, so a stdio
// client reading one message per line could not decode them.
//
// Each response is parsed and checked field by field against the schema
// (the library ships no MCP client to decode them independently). The same
// request table is driven through the real mcp.Server.processMessage and
// through a real `geode mcp --stdio` child (this build's binary) talking to
// a real `geode serve`, whose stdout must hold exactly one JSON-RPC message
// per line and whose stderr must hold no Debug leak report.
//
// CANARY: REQ=REQ-SONNY-6552-MCP-RESULT-SHAPES; FEATURE="MCPResultShapes"; ASPECT=SpecResultObjects; STATUS=TESTED; TEST=tests/test_sonny6552_mcp_result_shapes.zig; OWNER=mcp; UPDATED=2026-11-14

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const mcp_server = @import("mcp_server");
const util = @import("proto_test_util.zig");
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");

const GeodeMcpServer = mcp_server.GeodeMcpServer;
const Value = std.json.Value;
const linux = std.os.linux;

const invalid_params: i64 = -32602;
const resource_not_found: i64 = -32002;
const method_not_found: i64 = -32601;

/// The result type a successful response must carry.
const Kind = enum {
    initialize,
    empty,
    list_tools,
    call_tool,
    list_resources,
    list_templates,
    read_resource,
    list_prompts,
    get_prompt,
    complete,
};

/// What a response must be.
const Expect = union(enum) {
    /// A result of this kind; `needle` (if set) is in its decoded text.
    ok: struct { kind: Kind, needle: ?[]const u8 = null },
    /// A CallToolResult whose isError is `is_error`; `needle` as above.
    tool: struct { is_error: bool, needle: ?[]const u8 = null },
    /// A JSON-RPC error with this code.
    err: i64,
};

const Req = struct { id: i64, msg: []const u8, expect: Expect };

// ---------------------------------------------------------------------------
// Schema checks (MCP 2025-11-25)
// ---------------------------------------------------------------------------

fn fail(comptime what: []const u8, args: anytype) error{ShapeMismatch} {
    std.debug.print("MCP shape: " ++ what ++ "\n", args);
    return error.ShapeMismatch;
}

fn object(v: Value, comptime what: []const u8) !std.json.ObjectMap {
    if (v != .object) return fail("{s} is not an object", .{what});
    return v.object;
}

fn array(v: Value, comptime what: []const u8) ![]Value {
    if (v != .array) return fail("{s} is not an array", .{what});
    return v.array.items;
}

fn reqField(o: std.json.ObjectMap, comptime key: []const u8) !Value {
    return o.get(key) orelse fail("missing required field '{s}'", .{key});
}

fn reqString(o: std.json.ObjectMap, comptime key: []const u8) ![]const u8 {
    const v = try reqField(o, key);
    if (v != .string) return fail("'{s}' is not a string", .{key});
    return v.string;
}

fn optString(o: std.json.ObjectMap, comptime key: []const u8) !?[]const u8 {
    const v = o.get(key) orelse return null;
    if (v != .string) return fail("'{s}' is not a string", .{key});
    return v.string;
}

fn optBool(o: std.json.ObjectMap, comptime key: []const u8) !?bool {
    const v = o.get(key) orelse return null;
    if (v != .bool) return fail("'{s}' is not a boolean", .{key});
    return v.bool;
}

fn optNumber(o: std.json.ObjectMap, comptime key: []const u8) !void {
    const v = o.get(key) orelse return;
    if (v != .integer and v != .float) return fail("'{s}' is not a number", .{key});
}

/// PaginatedResult: `nextCursor` is optional; geode lists fit in one page.
fn paginated(o: std.json.ObjectMap) !void {
    if (o.get("nextCursor") != null) return fail("a single-page list carries nextCursor", .{});
}

/// A Result never carries an `error` member: a failure is a JSON-RPC error.
fn noErrorMember(o: std.json.ObjectMap) !void {
    if (o.get("error") != null) return fail("a success result carries an 'error' member", .{});
}

/// ContentBlock; returns the text of a TextContent.
fn contentBlock(v: Value) !?[]const u8 {
    const o = try object(v, "content block");
    const t = try reqString(o, "type");
    if (std.mem.eql(u8, t, "text")) return try reqString(o, "text");
    if (std.mem.eql(u8, t, "image") or std.mem.eql(u8, t, "audio")) {
        _ = try reqString(o, "data");
        _ = try reqString(o, "mimeType");
        return null;
    }
    if (std.mem.eql(u8, t, "resource_link")) {
        _ = try reqString(o, "uri");
        _ = try reqString(o, "name");
        return null;
    }
    if (std.mem.eql(u8, t, "resource")) {
        _ = try object(try reqField(o, "resource"), "embedded resource");
        return null;
    }
    return fail("unknown content block type '{s}'", .{t});
}

/// The input-schema properties each tool advertises, exactly: a property a
/// tool ignores must not be advertised.
const tool_properties = [_]struct { name: []const u8, props: []const []const u8 }{
    .{ .name = "query", .props = &.{ "query", "parameters" } },
    .{ .name = "schema", .props = &.{} },
    .{ .name = "explain", .props = &.{"query"} },
    .{ .name = "graphs", .props = &.{} },
    .{ .name = "validate", .props = &.{"query"} },
    .{ .name = "complete", .props = &.{ "query", "line", "column" } },
    .{ .name = "hover", .props = &.{ "query", "line", "column" } },
    .{ .name = "diagnostics", .props = &.{"query"} },
};

fn checkListTools(o: std.json.ObjectMap) !void {
    try paginated(o);
    const tools = try array(try reqField(o, "tools"), "tools");
    if (tools.len != tool_properties.len) return fail("{d} tools, expected {d}", .{ tools.len, tool_properties.len });
    for (tools) |tv| {
        const t = try object(tv, "Tool");
        const name = try reqString(t, "name");
        _ = try optString(t, "title");
        _ = try optString(t, "description");
        const schema = try object(try reqField(t, "inputSchema"), "inputSchema");
        if (!std.mem.eql(u8, try reqString(schema, "type"), "object")) return fail("tool {s}: inputSchema.type is not \"object\"", .{name});
        const props: ?std.json.ObjectMap = if (schema.get("properties")) |p| try object(p, "inputSchema.properties") else null;
        if (schema.get("required")) |r| for (try array(r, "inputSchema.required")) |rv| {
            if (rv != .string) return fail("tool {s}: a required entry is not a string", .{name});
            if (props == null or props.?.get(rv.string) == null) return fail("tool {s}: required '{s}' is not a property", .{ name, rv.string });
        };
        const want = for (tool_properties) |tp| {
            if (std.mem.eql(u8, tp.name, name)) break tp.props;
        } else return fail("unexpected tool '{s}'", .{name});
        const got = if (props) |p| p.count() else 0;
        if (got != want.len) return fail("tool {s}: {d} input properties advertised, expected {d}", .{ name, got, want.len });
        for (want) |w| if (props == null or props.?.get(w) == null) return fail("tool {s}: property '{s}' not advertised", .{ name, w });
    }
}

fn checkCallTool(o: std.json.ObjectMap, is_error: bool, needle: ?[]const u8) !void {
    const content = try array(try reqField(o, "content"), "content");
    if (content.len == 0) return fail("CallToolResult.content is empty", .{});
    var found = needle == null;
    for (content) |c| if (try contentBlock(c)) |text| {
        if (needle) |n| if (std.mem.indexOf(u8, text, n) != null) {
            found = true;
        };
    };
    if (o.get("structuredContent")) |sc| _ = try object(sc, "structuredContent");
    const got = (try optBool(o, "isError")) orelse false;
    if (got != is_error) return fail("CallToolResult.isError is {}, expected {}", .{ got, is_error });
    if (!found) return fail("no tool content text holds '{s}'", .{needle.?});
}

fn checkListResources(o: std.json.ObjectMap) !void {
    try paginated(o);
    const list = try array(try reqField(o, "resources"), "resources");
    if (list.len == 0) return fail("no resources", .{});
    for (list) |rv| {
        const r = try object(rv, "Resource");
        _ = try reqString(r, "uri");
        _ = try reqString(r, "name");
        _ = try optString(r, "title");
        _ = try optString(r, "description");
        _ = try optString(r, "mimeType");
        try optNumber(r, "size");
    }
}

fn checkListTemplates(o: std.json.ObjectMap) !void {
    try paginated(o);
    const list = try array(try reqField(o, "resourceTemplates"), "resourceTemplates");
    if (list.len == 0) return fail("no resource templates", .{});
    for (list) |tv| {
        const t = try object(tv, "ResourceTemplate");
        _ = try reqString(t, "uriTemplate");
        _ = try reqString(t, "name");
        _ = try optString(t, "title");
        _ = try optString(t, "description");
        _ = try optString(t, "mimeType");
    }
}

fn checkReadResource(o: std.json.ObjectMap, needle: ?[]const u8) !void {
    const contents = try array(try reqField(o, "contents"), "contents");
    if (contents.len == 0) return fail("ReadResourceResult.contents is empty", .{});
    var found = needle == null;
    for (contents) |cv| {
        const c = try object(cv, "ResourceContents");
        _ = try reqString(c, "uri");
        _ = try optString(c, "mimeType");
        const text = try optString(c, "text");
        const blob = try optString(c, "blob");
        if ((text == null) == (blob == null)) return fail("resource contents must carry exactly one of text / blob", .{});
        if (needle) |n| if (text) |t| if (std.mem.indexOf(u8, t, n) != null) {
            found = true;
        };
    }
    if (!found) return fail("no resource contents text holds '{s}'", .{needle.?});
}

fn checkListPrompts(o: std.json.ObjectMap) !void {
    try paginated(o);
    const list = try array(try reqField(o, "prompts"), "prompts");
    if (list.len == 0) return fail("no prompts", .{});
    for (list) |pv| {
        const p = try object(pv, "Prompt");
        _ = try reqString(p, "name");
        _ = try optString(p, "title");
        _ = try optString(p, "description");
        if (p.get("arguments")) |args| for (try array(args, "Prompt.arguments")) |av| {
            const a = try object(av, "PromptArgument");
            _ = try reqString(a, "name");
            _ = try optString(a, "description");
            _ = try optBool(a, "required");
        };
    }
}

fn checkGetPrompt(o: std.json.ObjectMap, needle: ?[]const u8) !void {
    _ = try optString(o, "description");
    const messages = try array(try reqField(o, "messages"), "messages");
    if (messages.len == 0) return fail("GetPromptResult.messages is empty", .{});
    var found = needle == null;
    for (messages) |mv| {
        const m = try object(mv, "PromptMessage");
        const role = try reqString(m, "role");
        if (!std.mem.eql(u8, role, "user") and !std.mem.eql(u8, role, "assistant")) return fail("PromptMessage.role '{s}'", .{role});
        if (try contentBlock(try reqField(m, "content"))) |text| if (needle) |n| if (std.mem.indexOf(u8, text, n) != null) {
            found = true;
        };
    }
    if (!found) return fail("no prompt message text holds '{s}'", .{needle.?});
}

fn checkComplete(o: std.json.ObjectMap) !void {
    const c = try object(try reqField(o, "completion"), "completion");
    const values = try array(try reqField(c, "values"), "completion.values");
    if (values.len > 100) return fail("more than 100 completion values", .{});
    for (values) |v| if (v != .string) return fail("a completion value is not a string", .{});
    try optNumber(c, "total");
    _ = try optBool(c, "hasMore");
}

fn checkInitialize(o: std.json.ObjectMap) !void {
    if (!std.mem.eql(u8, try reqString(o, "protocolVersion"), "2025-11-25")) return fail("protocolVersion is not 2025-11-25", .{});
    const caps = try object(try reqField(o, "capabilities"), "capabilities");
    inline for (.{ "tools", "resources", "prompts" }) |cap| _ = try object(try reqField(caps, cap), cap);
    const info = try object(try reqField(o, "serverInfo"), "serverInfo");
    _ = try reqString(info, "name");
    _ = try reqString(info, "version");
    _ = try optString(o, "instructions");
}

/// One JSON-RPC response object against `want`.
fn checkResponse(v: Value, id: i64, want: Expect) !void {
    const env = try object(v, "response");
    if (!std.mem.eql(u8, try reqString(env, "jsonrpc"), "2.0")) return fail("jsonrpc is not \"2.0\"", .{});
    const got_id = try reqField(env, "id");
    if (got_id != .integer or got_id.integer != id) return fail("id mismatch (expected {d})", .{id});
    const result = env.get("result");
    const err = env.get("error");
    if ((result == null) == (err == null)) return fail("a response carries exactly one of result / error", .{});
    switch (want) {
        .err => |code| {
            if (err == null) return fail("expected JSON-RPC error {d}, got a result", .{code});
            const e = try object(err.?, "error");
            const c = try reqField(e, "code");
            if (c != .integer or c.integer != code) return fail("error code is not {d}", .{code});
            _ = try reqString(e, "message");
        },
        .tool => |t| {
            if (result == null) return fail("expected a CallToolResult, got an error", .{});
            const o = try object(result.?, "result");
            try noErrorMember(o);
            try checkCallTool(o, t.is_error, t.needle);
        },
        .ok => |ok| {
            if (result == null) return fail("expected a {s} result, got an error", .{@tagName(ok.kind)});
            const o = try object(result.?, "result");
            try noErrorMember(o);
            switch (ok.kind) {
                .initialize => try checkInitialize(o),
                .empty => {},
                .list_tools => try checkListTools(o),
                .call_tool => try checkCallTool(o, false, ok.needle),
                .list_resources => try checkListResources(o),
                .list_templates => try checkListTemplates(o),
                .read_resource => try checkReadResource(o, ok.needle),
                .list_prompts => try checkListPrompts(o),
                .get_prompt => try checkGetPrompt(o, ok.needle),
                .complete => try checkComplete(o),
            }
        },
    }
}

/// Parse one response and check it.
fn checkResponseText(text: []const u8, id: i64, want: Expect) !void {
    errdefer std.debug.print("response (id {d}): {s}\n", .{ id, text });
    if (std.mem.indexOfScalar(u8, text, '\n') != null) return fail("the response holds a raw newline", .{});
    const parsed = std.json.parseFromSlice(Value, testing.allocator, text, .{}) catch return fail("the response is not JSON", .{});
    defer parsed.deinit();
    try checkResponse(parsed.value, id, want);
}

// ---------------------------------------------------------------------------
// The request table
// ---------------------------------------------------------------------------

const handshake_reqs = [_]Req{
    .{ .id = 1, .msg =
    \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"sonny6552-test","version":"1.0"}}}
    , .expect = .{ .ok = .{ .kind = .initialize } } },
};

const initialized_note =
    \\{"jsonrpc":"2.0","method":"notifications/initialized"}
;

/// Methods that need no backend, with their expected shapes and errors.
const local_reqs = [_]Req{
    .{ .id = 2, .msg =
    \\{"jsonrpc":"2.0","id":2,"method":"ping"}
    , .expect = .{ .ok = .{ .kind = .empty } } },
    .{ .id = 3, .msg =
    \\{"jsonrpc":"2.0","id":3,"method":"tools/list"}
    , .expect = .{ .ok = .{ .kind = .list_tools } } },
    .{ .id = 4, .msg =
    \\{"jsonrpc":"2.0","id":4,"method":"tools/list","params":{"cursor":"not-a-cursor-geode-issued"}}
    , .expect = .{ .err = invalid_params } },
    .{ .id = 5, .msg =
    \\{"jsonrpc":"2.0","id":5,"method":"resources/list"}
    , .expect = .{ .ok = .{ .kind = .list_resources } } },
    .{ .id = 6, .msg =
    \\{"jsonrpc":"2.0","id":6,"method":"resources/list","params":{"cursor":"x"}}
    , .expect = .{ .err = invalid_params } },
    .{ .id = 7, .msg =
    \\{"jsonrpc":"2.0","id":7,"method":"resources/templates/list"}
    , .expect = .{ .ok = .{ .kind = .list_templates } } },
    .{ .id = 8, .msg =
    \\{"jsonrpc":"2.0","id":8,"method":"prompts/list"}
    , .expect = .{ .ok = .{ .kind = .list_prompts } } },
    .{ .id = 9, .msg =
    \\{"jsonrpc":"2.0","id":9,"method":"prompts/list","params":{"cursor":"x"}}
    , .expect = .{ .err = invalid_params } },
    // resources/read: geode://config is answered locally by the client.
    .{ .id = 10, .msg =
    \\{"jsonrpc":"2.0","id":10,"method":"resources/read","params":{"uri":"geode://config"}}
    , .expect = .{ .ok = .{ .kind = .read_resource, .needle = "gql_compliance" } } },
    .{ .id = 11, .msg =
    \\{"jsonrpc":"2.0","id":11,"method":"resources/read","params":{"uri":"geode://default/default/nothing"}}
    , .expect = .{ .err = resource_not_found } },
    .{ .id = 12, .msg =
    \\{"jsonrpc":"2.0","id":12,"method":"resources/read","params":{"uri":"unknown://resource"}}
    , .expect = .{ .err = resource_not_found } },
    // prompts/get: every advertised argument reaches the prompt text.
    .{ .id = 13, .msg =
    \\{"jsonrpc":"2.0","id":13,"method":"prompts/get","params":{"name":"find_nodes","arguments":{"label":"Person6552","properties":"age=42"}}}
    , .expect = .{ .ok = .{ .kind = .get_prompt, .needle = "Person6552" } } },
    .{ .id = 14, .msg =
    \\{"jsonrpc":"2.0","id":14,"method":"prompts/get","params":{"name":"find_nodes","arguments":{"label":"Person6552","properties":"age=42"}}}
    , .expect = .{ .ok = .{ .kind = .get_prompt, .needle = "age=42" } } },
    .{ .id = 15, .msg =
    \\{"jsonrpc":"2.0","id":15,"method":"prompts/get","params":{"name":"create_relationship","arguments":{"from_label":"A","to_label":"B","type":"KNOWS6552"}}}
    , .expect = .{ .ok = .{ .kind = .get_prompt, .needle = "KNOWS6552" } } },
    .{ .id = 16, .msg =
    \\{"jsonrpc":"2.0","id":16,"method":"prompts/get","params":{"name":"no_such_prompt"}}
    , .expect = .{ .err = invalid_params } },
    // A required argument missing, an argument the prompt does not take,
    // and an argument that is not a string (GetPromptRequest arguments
    // are {[key: string]: string}).
    .{ .id = 17, .msg =
    \\{"jsonrpc":"2.0","id":17,"method":"prompts/get","params":{"name":"find_nodes"}}
    , .expect = .{ .err = invalid_params } },
    .{ .id = 18, .msg =
    \\{"jsonrpc":"2.0","id":18,"method":"prompts/get","params":{"name":"find_nodes","arguments":{"label":"P","lable":"typo"}}}
    , .expect = .{ .err = invalid_params } },
    .{ .id = 19, .msg =
    \\{"jsonrpc":"2.0","id":19,"method":"prompts/get","params":{"name":"find_nodes","arguments":{"label":7}}}
    , .expect = .{ .err = invalid_params } },
    // tools/call: the in-process tools, a tool execution error (isError),
    // arguments a tool does not take, and an unknown tool (-32602).
    .{ .id = 20, .msg =
    \\{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"validate","arguments":{"query":"MATCH (n:Person) RETURN n"}}}
    , .expect = .{ .tool = .{ .is_error = false } } },
    .{ .id = 21, .msg =
    \\{"jsonrpc":"2.0","id":21,"method":"tools/call","params":{"name":"complete","arguments":{"query":"MAT","line":1,"column":4}}}
    , .expect = .{ .tool = .{ .is_error = false } } },
    .{ .id = 22, .msg =
    \\{"jsonrpc":"2.0","id":22,"method":"tools/call","params":{"name":"hover","arguments":{"query":"MATCH (n) RETURN count(n)","line":1,"column":2}}}
    , .expect = .{ .tool = .{ .is_error = false } } },
    .{ .id = 23, .msg =
    \\{"jsonrpc":"2.0","id":23,"method":"tools/call","params":{"name":"diagnostics","arguments":{"query":"RETURN 1"}}}
    , .expect = .{ .tool = .{ .is_error = false } } },
    .{ .id = 24, .msg =
    \\{"jsonrpc":"2.0","id":24,"method":"tools/call","params":{"name":"validate","arguments":{"wrong":1}}}
    , .expect = .{ .tool = .{ .is_error = true } } },
    .{ .id = 25, .msg =
    \\{"jsonrpc":"2.0","id":25,"method":"tools/call","params":{"name":"graphs","arguments":{"catalog":"default"}}}
    , .expect = .{ .tool = .{ .is_error = true, .needle = "catalog" } } },
    .{ .id = 26, .msg =
    \\{"jsonrpc":"2.0","id":26,"method":"tools/call","params":{"name":"query","arguments":{"query":"RETURN 1","graph":"g"}}}
    , .expect = .{ .tool = .{ .is_error = true, .needle = "graph" } } },
    .{ .id = 27, .msg =
    \\{"jsonrpc":"2.0","id":27,"method":"tools/call","params":{"name":"no_such_tool","arguments":{}}}
    , .expect = .{ .err = invalid_params } },
    .{ .id = 28, .msg =
    \\{"jsonrpc":"2.0","id":28,"method":"completion/complete","params":{"ref":{"type":"ref/prompt","name":"find_nodes"},"argument":{"name":"label","value":"P"}}}
    , .expect = .{ .ok = .{ .kind = .complete } } },
    .{ .id = 29, .msg =
    \\{"jsonrpc":"2.0","id":29,"method":"logging/setLevel","params":{"level":"info"}}
    , .expect = .{ .ok = .{ .kind = .empty } } },
    .{ .id = 30, .msg =
    \\{"jsonrpc":"2.0","id":30,"method":"resources/subscribe","params":{"uri":"geode://config"}}
    , .expect = .{ .err = method_not_found } },
};

/// Backend methods when the backend is reachable (a real geode serve).
const live_backend_reqs = [_]Req{
    .{ .id = 40, .msg =
    \\{"jsonrpc":"2.0","id":40,"method":"tools/call","params":{"name":"query","arguments":{"query":"RETURN 6552 AS x"}}}
    , .expect = .{ .tool = .{ .is_error = false, .needle = "6552" } } },
    .{ .id = 41, .msg =
    \\{"jsonrpc":"2.0","id":41,"method":"tools/call","params":{"name":"query","arguments":{"query":"RETURN $p AS x","parameters":{"p":65520}}}}
    , .expect = .{ .tool = .{ .is_error = false, .needle = "65520" } } },
    .{ .id = 42, .msg =
    \\{"jsonrpc":"2.0","id":42,"method":"tools/call","params":{"name":"query","arguments":{"query":"MATCH (n RETURN"}}}
    , .expect = .{ .tool = .{ .is_error = true } } },
    .{ .id = 43, .msg =
    \\{"jsonrpc":"2.0","id":43,"method":"tools/call","params":{"name":"schema","arguments":{}}}
    , .expect = .{ .tool = .{ .is_error = false } } },
    .{ .id = 44, .msg =
    \\{"jsonrpc":"2.0","id":44,"method":"tools/call","params":{"name":"explain","arguments":{"query":"MATCH (n) RETURN n"}}}
    , .expect = .{ .tool = .{ .is_error = false } } },
    // SONNY-6559 (5): there is no catalogs tool (geode has no SHOW
    // CATALOGS and no catalog to list): an unknown tool, -32602.
    .{ .id = 45, .msg =
    \\{"jsonrpc":"2.0","id":45,"method":"tools/call","params":{"name":"catalogs"}}
    , .expect = .{ .err = invalid_params } },
    .{ .id = 46, .msg =
    \\{"jsonrpc":"2.0","id":46,"method":"tools/call","params":{"name":"graphs","arguments":{}}}
    , .expect = .{ .tool = .{ .is_error = false } } },
    .{ .id = 47, .msg =
    \\{"jsonrpc":"2.0","id":47,"method":"resources/read","params":{"uri":"geode://default/default/schema"}}
    , .expect = .{ .ok = .{ .kind = .read_resource } } },
    .{ .id = 48, .msg =
    \\{"jsonrpc":"2.0","id":48,"method":"resources/read","params":{"uri":"geode://default/default/stats"}}
    , .expect = .{ .ok = .{ .kind = .read_resource, .needle = "node_count" } } },
};

/// Backend methods when nothing listens on the endpoint: tools answer an
/// isError result, schema/stats their offline documents.
const dead_backend_reqs = [_]Req{
    .{ .id = 40, .msg =
    \\{"jsonrpc":"2.0","id":40,"method":"tools/call","params":{"name":"query","arguments":{"query":"RETURN 1"}}}
    , .expect = .{ .tool = .{ .is_error = true } } },
    .{ .id = 43, .msg =
    \\{"jsonrpc":"2.0","id":43,"method":"tools/call","params":{"name":"schema","arguments":{}}}
    , .expect = .{ .tool = .{ .is_error = true } } },
    .{ .id = 46, .msg =
    \\{"jsonrpc":"2.0","id":46,"method":"tools/call","params":{"name":"graphs","arguments":{}}}
    , .expect = .{ .tool = .{ .is_error = true } } },
    .{ .id = 47, .msg =
    \\{"jsonrpc":"2.0","id":47,"method":"resources/read","params":{"uri":"geode://default/default/schema"}}
    , .expect = .{ .ok = .{ .kind = .read_resource, .needle = "Server unavailable" } } },
    .{ .id = 48, .msg =
    \\{"jsonrpc":"2.0","id":48,"method":"resources/read","params":{"uri":"geode://default/default/stats"}}
    , .expect = .{ .ok = .{ .kind = .read_resource, .needle = "Server unavailable" } } },
};

/// A batch (one line, one JSON array of responses on stdio).
const batch_msg =
    \\[{"jsonrpc":"2.0","id":60,"method":"resources/list"},{"jsonrpc":"2.0","id":61,"method":"prompts/list"},{"jsonrpc":"2.0","id":62,"method":"resources/templates/list"},{"jsonrpc":"2.0","id":63,"method":"prompts/get","params":{"name":"no_such_prompt"}},{"jsonrpc":"2.0","method":"tools/list"}]
;
const batch_reqs = [_]Req{
    .{ .id = 60, .msg = "", .expect = .{ .ok = .{ .kind = .list_resources } } },
    .{ .id = 61, .msg = "", .expect = .{ .ok = .{ .kind = .list_prompts } } },
    .{ .id = 62, .msg = "", .expect = .{ .ok = .{ .kind = .list_templates } } },
    .{ .id = 63, .msg = "", .expect = .{ .err = invalid_params } },
};

// ---------------------------------------------------------------------------
// In-process: the real mcp.Server.processMessage
// ---------------------------------------------------------------------------

fn drive(server: *GeodeMcpServer, reqs: []const Req) !void {
    for (reqs) |r| {
        const resp = (try server.server.processMessage(r.msg)) orelse {
            std.debug.print("no response to: {s}\n", .{r.msg});
            return error.UnexpectedNullResponse;
        };
        defer testing.allocator.free(resp);
        errdefer std.debug.print("request: {s}\n", .{r.msg});
        try checkResponseText(resp, r.id, r.expect);
    }
}

fn driveBatch(server: *GeodeMcpServer) !void {
    const resp = (try server.server.processMessage(batch_msg)) orelse return error.UnexpectedNullResponse;
    defer testing.allocator.free(resp);
    errdefer std.debug.print("batch response: {s}\n", .{resp});
    try testing.expect(std.mem.indexOfScalar(u8, resp, '\n') == null);
    const parsed = try std.json.parseFromSlice(Value, testing.allocator, resp, .{});
    defer parsed.deinit();
    const items = try array(parsed.value, "batch response");
    try testing.expectEqual(batch_reqs.len, items.len);
    for (batch_reqs) |r| {
        const item = for (items) |it| {
            if (it == .object) if (it.object.get("id")) |id| if (id == .integer and id.integer == r.id) break it;
        } else return fail("batch: id {d} not answered", .{r.id});
        try checkResponse(item, r.id, r.expect);
    }
}

fn handshake(server: *GeodeMcpServer) !void {
    try drive(server, &handshake_reqs);
    try testing.expect((try server.server.processMessage(initialized_note)) == null);
}

/// prompts/get for every prompt prompts/list advertises, with every
/// advertised argument set: each value reaches the prompt text.
fn driveEveryListedPrompt(server: *GeodeMcpServer) !void {
    const a = testing.allocator;
    const list_resp = (try server.server.processMessage(
        \\{"jsonrpc":"2.0","id":90,"method":"prompts/list"}
    )) orelse return error.UnexpectedNullResponse;
    defer a.free(list_resp);
    const parsed = try std.json.parseFromSlice(Value, a, list_resp, .{});
    defer parsed.deinit();
    const prompts = try array(try reqField(try object(try reqField(parsed.value.object, "result"), "result"), "prompts"), "prompts");
    try testing.expectEqual(@as(usize, 7), prompts.len);
    for (prompts, 0..) |pv, i| {
        const name = try reqString(pv.object, "name");
        var args: std.ArrayList(u8) = .empty;
        defer args.deinit(a);
        var values: std.ArrayList([]u8) = .empty;
        defer {
            for (values.items) |v| a.free(v);
            values.deinit(a);
        }
        if (pv.object.get("arguments")) |argv| for (argv.array.items, 0..) |av, j| {
            const arg = try reqString(av.object, "name");
            const value = try std.fmt.allocPrint(a, "v6552_{d}_{d}", .{ i, j });
            try values.append(a, value);
            if (args.items.len > 0) try args.append(a, ',');
            try args.print(a, "\"{s}\":\"{s}\"", .{ arg, value });
        };
        const id: i64 = 900 + @as(i64, @intCast(i));
        const msg = try std.fmt.allocPrint(a,
            \\{{"jsonrpc":"2.0","id":{d},"method":"prompts/get","params":{{"name":"{s}","arguments":{{{s}}}}}}}
        , .{ id, name, args.items });
        defer a.free(msg);
        for (values.items) |v| try drive(server, &.{.{ .id = id, .msg = msg, .expect = .{ .ok = .{ .kind = .get_prompt, .needle = v } } }});
        if (values.items.len == 0) try drive(server, &.{.{ .id = id, .msg = msg, .expect = .{ .ok = .{ .kind = .get_prompt } } }});
    }
}

test "SONNY-6552: every MCP result has its 2025-11-25 shape through processMessage" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    // Nothing listens on the endpoint: the backend tools and resources take
    // their failure / offline paths.
    const port = try util.getRandomPort();
    var ep_buf: [96]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&ep_buf, "quic://127.0.0.1:{d}?insecure=true&timeout=2000", .{port});
    const server = try GeodeMcpServer.init(testing.allocator, .{ .auth_mode = .none, .geode_endpoint = endpoint });
    defer server.deinit();
    try handshake(server);
    try drive(server, &local_reqs);
    try drive(server, &dead_backend_reqs);
    try driveBatch(server);
    try driveEveryListedPrompt(server);
}

// ---------------------------------------------------------------------------
// A real `geode mcp --stdio` session against a real `geode serve`
// ---------------------------------------------------------------------------

const Backend = struct {
    handle: util.ServerHandle,
    data: test_scratch.ScratchDir,
    dsn_buf: [256]u8 = undefined,
    dsn_len: usize = 0,

    fn dsn(self: *const Backend) []const u8 {
        return self.dsn_buf[0..self.dsn_len];
    }

    fn stop(self: *Backend) void {
        self.handle.deinit();
        self.data.remove();
    }
};

fn startBackend(b: *Backend) !void {
    b.data = try test_scratch.ScratchDir.create("sonny6552-data");
    errdefer b.data.remove();
    var data_env_buf: [256]u8 = undefined;
    const data_env = try std.fmt.bufPrint(&data_env_buf, "GEODE_DATA_DIR={s}", .{b.data.path()});
    b.handle = try util.spawnServerRandom(testing.allocator, &.{data_env});
    const d = try std.fmt.bufPrint(&b.dsn_buf, "quic://{s}?insecure=true&user={s}&pass=Geode%20Test%20Admin%20Passphrase", .{ b.handle.getAddr(), util.defaultUsername() });
    b.dsn_len = d.len;
}

const Session = struct {
    code: ?u8,
    stdout: []u8,
    stderr: []u8,

    fn deinit(self: Session) void {
        testing.allocator.free(self.stdout);
        testing.allocator.free(self.stderr);
    }

    fn dump(self: Session) void {
        std.debug.print("\ngeode mcp --stdio: exit={?d}\n--- stdout ---\n{s}\n--- stderr ---\n{s}\n--- end ---\n", .{ self.code, self.stdout, self.stderr });
    }
};

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// Run `geode mcp --stdio --no-auth --endpoint <endpoint>` with `input` on
/// its stdin (closed afterwards, which ends the session).
fn runMcpSession(endpoint: []const u8, input: []const u8, timeout_s: i64) !Session {
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var dir = try test_scratch.ScratchDir.create("sonny6552-mcp");
    defer dir.remove();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    inline for (.{ "PATH", "LD_LIBRARY_PATH" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    try env.put("HOME", dir.path());
    try env.put("GEODE_LSP_PORT", "0");

    const out_path = try std.fmt.allocPrint(a, "{s}/stdout", .{dir.path()});
    defer a.free(out_path);
    const err_path = try std.fmt.allocPrint(a, "{s}/stderr", .{dir.path()});
    defer a.free(err_path);
    const out = try std.Io.Dir.cwd().createFile(fsIo(), out_path, .{ .read = true, .truncate = true });
    defer out.close(fsIo());
    const errf = try std.Io.Dir.cwd().createFile(fsIo(), err_path, .{ .read = true, .truncate = true });
    defer errf.close(fsIo());

    var child = try std.process.spawn(io, .{
        .argv = &.{ geode_test_bin.geode_exe, "mcp", "--stdio", "--no-auth", "--endpoint", endpoint },
        .environ_map = &env,
        .stdin = .pipe,
        .stdout = .{ .file = out },
        .stderr = .{ .file = errf },
    });
    if (child.stdin) |stdin| {
        stdin.writeStreamingAll(io, input) catch {};
        stdin.close(io);
        child.stdin = null;
    }
    const pid = child.id.?;
    var status: u32 = 0;
    var exited = false;
    var waited_ms: i64 = 0;
    while (true) {
        const rc = linux.waitpid(pid, &status, linux.W.NOHANG);
        if (rc == @as(usize, @intCast(pid))) {
            exited = true;
            break;
        }
        if (waited_ms >= timeout_s * 1000) {
            std.posix.kill(pid, .KILL) catch {};
            _ = linux.waitpid(pid, &status, 0);
            break;
        }
        fsIo().sleep(.fromNanoseconds(100 * std.time.ns_per_ms), .awake) catch {};
        waited_ms += 100;
    }
    const code: ?u8 = if (exited and linux.W.IFEXITED(status)) linux.W.EXITSTATUS(status) else null;
    const stdout = try std.Io.Dir.cwd().readFileAlloc(fsIo(), out_path, a, .limited(16 << 20));
    errdefer a.free(stdout);
    const stderr = try std.Io.Dir.cwd().readFileAlloc(fsIo(), err_path, a, .limited(16 << 20));
    return .{ .code = code, .stdout = stdout, .stderr = stderr };
}

fn findReq(id: i64, tables: []const []const Req) ?Req {
    for (tables) |t| for (t) |r| if (r.id == id) return r;
    return null;
}

test "SONNY-6552: a real geode mcp --stdio session writes one spec-shaped message per line" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var backend: Backend = .{ .handle = undefined, .data = undefined };
    try startBackend(&backend);
    defer backend.stop();

    const a = testing.allocator;
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(a);
    const tables = [_][]const Req{ &handshake_reqs, &local_reqs, &live_backend_reqs };
    try input.appendSlice(a, handshake_reqs[0].msg);
    try input.append(a, '\n');
    try input.appendSlice(a, initialized_note ++ "\n");
    for (tables[1..]) |t| for (t) |r| {
        try input.appendSlice(a, r.msg);
        try input.append(a, '\n');
    };
    try input.appendSlice(a, batch_msg ++ "\n");

    const s = try runMcpSession(backend.dsn(), input.items, 180);
    defer s.deinit();
    errdefer s.dump();

    try testing.expectEqual(@as(?u8, 0), s.code);
    // SONNY-6552 (7): `geode mcp` returns through main, so the Debug
    // binary's DebugAllocator reports any leak (and panics on a bad free).
    for ([_][]const u8{ "leaked", "Invalid free", "Double free", "panic" }) |bad| {
        if (std.mem.indexOf(u8, s.stderr, bad) != null) return fail("geode mcp stderr holds '{s}'", .{bad});
    }

    // Newline-delimited: every line is exactly one JSON-RPC message.
    var answered: std.AutoHashMapUnmanaged(i64, void) = .empty;
    defer answered.deinit(a);
    var lines = std.mem.splitScalar(u8, s.stdout, '\n');
    var line_count: usize = 0;
    var batch_lines: usize = 0;
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        line_count += 1;
        const parsed = std.json.parseFromSlice(Value, a, line, .{}) catch
            return fail("stdout line {d} is not one JSON message: {s}", .{ line_count, line });
        defer parsed.deinit();
        if (parsed.value == .array) {
            batch_lines += 1;
            for (parsed.value.array.items) |item| {
                const id = (try reqField(try object(item, "batch item"), "id")).integer;
                const r = findReq(id, &.{&batch_reqs}) orelse return fail("unexpected batch id {d}", .{id});
                try checkResponse(item, id, r.expect);
                if ((try answered.fetchPut(a, id, {})) != null) return fail("id {d} answered twice", .{id});
            }
            continue;
        }
        const id_v = try reqField(try object(parsed.value, "response"), "id");
        if (id_v != .integer) return fail("a response id is not an integer: {s}", .{line});
        const r = findReq(id_v.integer, &tables) orelse return fail("unexpected id {d}", .{id_v.integer});
        errdefer std.debug.print("line: {s}\n", .{line});
        try checkResponse(parsed.value, r.id, r.expect);
        if ((try answered.fetchPut(a, r.id, {})) != null) return fail("id {d} answered twice", .{r.id});
    }
    var expected: usize = batch_reqs.len;
    for (tables) |t| expected += t.len;
    try testing.expectEqual(expected, answered.count());
    try testing.expectEqual(@as(usize, 1), batch_lines);
    // One line per response, one for the batch: no response spans lines.
    try testing.expectEqual(expected - batch_reqs.len + 1, line_count);
}
