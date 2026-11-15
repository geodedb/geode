// CANARY: REQ=REQ-SONNY-6559-MCP-BACKEND; FEATURE="MCPBackendTools"; ASPECT=EveryToolAndResourceSucceeds; STATUS=TESTED; TEST=tests/test_sonny6559_mcp_backend.zig; OWNER=mcp; UPDATED=2026-11-14
//
// SONNY-6559 items 5, 6 and 10 (geode's MCP server, src/mcp):
//
//   5. The `catalogs` tool sent SHOW CATALOGS, which geode's parser rejects:
//      the tool could not succeed. geode has no catalog object of its own
//      (ISO/IEC 39075 catalogs hold schemas holding graphs; geode keeps one
//      flat set of graphs), so the tool is gone. Every other backend tool and
//      resource statement is run here against a real server: the schema
//      tool/resource returned `labels(n)` lists as null (the MCP client
//      decoded rows with geode-client-zig's Value, which carries scalars only),
//      and the query tool returned a node as null.
//   6. The node/{label} and relationship/{type} resource templates were
//      advertised and answered -32002; {catalog}/{graph} in the schema and
//      stats templates was ignored (every graph read the session's); any URI
//      holding "config" or "/schema" matched.
//  10. The explain tool answered {"columns":[],"rows":[]} for EXPLAIN MATCH
//      (n) RETURN n: the plan arrives as an explain payload, which the client
//      library's decoder drops. `geode query "EXPLAIN ..." --format json`
//      shows the plan; the tool now returns the same plan.
//
// The contract: every tool geode advertises can succeed against a real
// server; every resource template it advertises reads (bounded, through the
// normal client path, so the connection's permissions apply); a resource URI
// is parsed strictly: geode://config, or geode://default/<graph>/schema|stats,
// /node/<label>, /relationship/<type> with identifier names; anything else is
// -32002.
//
// A real `geode mcp --stdio` session against a real `geode serve`.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");
const util = @import("proto_test_util.zig");

const linux = std.os.linux;
const Value = std.json.Value;
const exe = geode_test_bin.geode_exe;
const password = "Geode Test Admin Passphrase";

/// Names each run's output files apart.
var run_seq = std.atomic.Value(u64).init(0);

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

const Run = struct {
    code: ?u8,
    out: []u8,
    err: []u8,

    fn deinit(self: Run) void {
        testing.allocator.free(self.out);
        testing.allocator.free(self.err);
    }

    fn dump(self: Run, what: []const u8) void {
        std.debug.print("\n{s}: exit={?d}\n--- stdout ---\n{s}\n--- stderr ---\n{s}\n--- end ---\n", .{ what, self.code, self.out, self.err });
    }
};

/// Run `geode <argv...>` with stdin `input`, HOME under `home`.
fn runGeode(home: []const u8, argv: []const []const u8, input: []const u8, timeout_s: u64) !Run {
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    const io = threaded.io();

    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    inline for (.{ "PATH", "LD_LIBRARY_PATH" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    try env.put("HOME", home);
    try env.put("GEODE_LSP_PORT", "0");

    var full: std.ArrayList([]const u8) = .empty;
    defer full.deinit(a);
    try full.append(a, exe);
    try full.appendSlice(a, argv);

    const tag = run_seq.fetchAdd(1, .monotonic);
    const out_path = try std.fmt.allocPrint(a, "{s}/out-{x}", .{ home, tag });
    defer a.free(out_path);
    const err_path = try std.fmt.allocPrint(a, "{s}/err-{x}", .{ home, tag });
    defer a.free(err_path);
    const out = try std.Io.Dir.cwd().createFile(fsIo(), out_path, .{ .read = true, .truncate = true });
    defer out.close(fsIo());
    const errf = try std.Io.Dir.cwd().createFile(fsIo(), err_path, .{ .read = true, .truncate = true });
    defer errf.close(fsIo());

    var child = try std.process.spawn(io, .{
        .argv = full.items,
        .environ_map = &env,
        .cwd = .{ .path = home },
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
    var waited_ms: u64 = 0;
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
    return .{ .code = code, .out = stdout, .err = stderr };
}

fn cliQuery(home: []const u8, addr: []const u8, extra: []const []const u8) !Run {
    var argv: std.ArrayList([]const u8) = .empty;
    defer argv.deinit(testing.allocator);
    try argv.append(testing.allocator, "query");
    try argv.appendSlice(testing.allocator, extra);
    try argv.appendSlice(testing.allocator, &.{ "--server", addr, "--insecure-tls-skip-verify", "-U", util.defaultUsername(), "-P", password });
    return runGeode(home, argv.items, "", 60);
}

fn seed(home: []const u8, addr: []const u8, args: []const []const u8) !void {
    const r = try cliQuery(home, addr, args);
    defer r.deinit();
    if (r.code != 0) {
        r.dump("seed");
        return error.SeedFailed;
    }
}

const Responses = struct {
    parsed: std.ArrayList(std.json.Parsed(Value)) = .empty,

    fn deinit(self: *Responses) void {
        for (self.parsed.items) |*p| p.deinit();
        self.parsed.deinit(testing.allocator);
    }

    fn byId(self: *const Responses, id: i64) ?std.json.ObjectMap {
        for (self.parsed.items) |p| {
            if (p.value != .object) continue;
            const v = p.value.object.get("id") orelse continue;
            if (v == .integer and v.integer == id) return p.value.object;
        }
        return null;
    }
};

fn parseLines(stdout: []const u8) !Responses {
    var r: Responses = .{};
    errdefer r.deinit();
    var lines = std.mem.splitScalar(u8, stdout, '\n');
    while (lines.next()) |line| {
        if (line.len == 0) continue;
        const p = try std.json.parseFromSlice(Value, testing.allocator, line, .{});
        try r.parsed.append(testing.allocator, p);
    }
    return r;
}

fn fail(comptime fmt: []const u8, args: anytype) error{Sonny6559} {
    std.debug.print("SONNY-6559: " ++ fmt ++ "\n", args);
    return error.Sonny6559;
}

/// The JSON text of a successful tools/call (content[0].text).
fn toolText(responses: *const Responses, id: i64) ![]const u8 {
    const o = responses.byId(id) orelse return fail("no response to id {d}", .{id});
    if (o.get("error")) |e| return fail("id {d} answered an error: {f}", .{ id, std.json.fmt(e, .{}) });
    const result = o.get("result").?.object;
    if (result.get("isError")) |ie| {
        if (ie == .bool and ie.bool) return fail("id {d} is a tool error: {f}", .{ id, std.json.fmt(Value{ .object = result }, .{}) });
    }
    return result.get("content").?.array.items[0].object.get("text").?.string;
}

/// The text of a successful resources/read (contents[0].text).
fn resourceText(responses: *const Responses, id: i64) ![]const u8 {
    const o = responses.byId(id) orelse return fail("no response to id {d}", .{id});
    if (o.get("error")) |e| return fail("id {d} answered an error: {f}", .{ id, std.json.fmt(e, .{}) });
    return o.get("result").?.object.get("contents").?.array.items[0].object.get("text").?.string;
}

fn errorCode(responses: *const Responses, id: i64) !i64 {
    const o = responses.byId(id) orelse return fail("no response to id {d}", .{id});
    const e = o.get("error") orelse return fail("id {d} succeeded: {f}", .{ id, std.json.fmt(Value{ .object = o }, .{}) });
    return e.object.get("code").?.integer;
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

const bad_uris = [_][]const u8{
    "geode://config/extra",
    "geode://xconfig",
    "geode://configuration",
    "geode://default/default/schemax",
    "geode://default/default/schema/extra",
    "geode://default/default/statsx",
    "geode://other/default/schema",
    "geode://default/bad-graph/schema",
    "geode://default/default/node/",
    "geode://default/default/node/Bad%20Label",
    "geode://default/default/relationship/a/b",
    "geode://default/default/edge/KNOWS",
    "geode://default//schema",
    "geode:/config",
    "geode://config?x=1",
    "http://default/default/schema",
};

test "SONNY-6559 (5, 6, 10) every MCP backend tool and advertised resource works against a real server" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = testing.allocator;
    var home = try test_scratch.ScratchDir.create("sonny6559-mcp");
    defer home.remove();
    var server = try util.spawnServerRandom(a, util.TestEnv.standard());
    defer server.deinit();
    const addr = server.getAddr();

    try seed(home.path(), addr, &.{"CREATE (:Sonny6559 {name: 'a'})-[:KNOWS6559]->(:Sonny6559 {name: 'b'})"});
    try seed(home.path(), addr, &.{"CREATE GRAPH sonny6559g"});
    try seed(home.path(), addr, &.{ "-g", "sonny6559g", "CREATE (:Only6559G {k: 1})" });

    // What the CLI prints for the plan.
    const cli_plan = blk: {
        const r = try cliQuery(home.path(), addr, &.{ "EXPLAIN MATCH (n:Sonny6559) RETURN n", "--format", "json" });
        defer r.deinit();
        errdefer r.dump("geode query EXPLAIN");
        try testing.expectEqual(@as(?u8, 0), r.code);
        const parsed = try std.json.parseFromSlice(Value, a, std.mem.trim(u8, r.out, " \r\n"), .{});
        defer parsed.deinit();
        const plan = parsed.value.object.get("explain") orelse return fail("geode query EXPLAIN printed no plan: {s}", .{r.out});
        break :blk try std.json.Stringify.valueAlloc(a, plan, .{});
    };
    defer a.free(cli_plan);

    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(a);
    try input.appendSlice(a,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"sonny6559-test","version":"1.0"}}}
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
        \\{"jsonrpc":"2.0","id":2,"method":"tools/list"}
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"schema","arguments":{}}}
        \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"graphs","arguments":{}}}
        \\{"jsonrpc":"2.0","id":5,"method":"tools/call","params":{"name":"explain","arguments":{"query":"MATCH (n:Sonny6559) RETURN n"}}}
        \\{"jsonrpc":"2.0","id":6,"method":"tools/call","params":{"name":"query","arguments":{"query":"MATCH (n:Sonny6559) RETURN n, labels(n) AS l ORDER BY n.name"}}}
        \\{"jsonrpc":"2.0","id":7,"method":"tools/call","params":{"name":"catalogs","arguments":{}}}
        \\{"jsonrpc":"2.0","id":8,"method":"resources/read","params":{"uri":"geode://default/default/schema"}}
        \\{"jsonrpc":"2.0","id":9,"method":"resources/read","params":{"uri":"geode://default/default/stats"}}
        \\{"jsonrpc":"2.0","id":10,"method":"resources/read","params":{"uri":"geode://default/sonny6559g/schema"}}
        \\{"jsonrpc":"2.0","id":11,"method":"resources/read","params":{"uri":"geode://default/sonny6559g/stats"}}
        \\{"jsonrpc":"2.0","id":12,"method":"resources/read","params":{"uri":"geode://default/default/node/Sonny6559"}}
        \\{"jsonrpc":"2.0","id":13,"method":"resources/read","params":{"uri":"geode://default/default/relationship/KNOWS6559"}}
        \\{"jsonrpc":"2.0","id":14,"method":"resources/read","params":{"uri":"geode://config"}}
        \\{"jsonrpc":"2.0","id":15,"method":"resources/templates/list"}
        \\{"jsonrpc":"2.0","id":16,"method":"resources/read","params":{"uri":"geode://default/nosuchgraph6559/schema"}}
        \\
    );
    for (bad_uris, 0..) |uri, i| {
        try input.print(a, "{{\"jsonrpc\":\"2.0\",\"id\":{d},\"method\":\"resources/read\",\"params\":{{\"uri\":\"{s}\"}}}}\n", .{ 100 + i, uri });
    }

    const endpoint = try std.fmt.allocPrint(a, "quic://{s}?insecure=true&user={s}&pass=Geode%20Test%20Admin%20Passphrase", .{ addr, util.defaultUsername() });
    defer a.free(endpoint);
    const s = try runGeode(home.path(), &.{ "mcp", "--stdio", "--no-auth", "--endpoint", endpoint }, input.items, 180);
    defer s.deinit();
    errdefer s.dump("geode mcp --stdio");
    try testing.expectEqual(@as(?u8, 0), s.code);

    var responses = try parseLines(s.out);
    defer responses.deinit();

    // (5) No tool that cannot succeed: catalogs is gone (unknown tool).
    {
        const tools = responses.byId(2).?.get("result").?.object.get("tools").?.array.items;
        for (tools) |t| {
            if (std.mem.eql(u8, t.object.get("name").?.string, "catalogs")) return fail("tools/list still advertises catalogs", .{});
        }
        try testing.expectEqual(@as(i64, -32602), try errorCode(&responses, 7));
    }
    // (5) schema: the labels are lists, not null.
    {
        const text = try toolText(&responses, 3);
        if (!contains(text, "\"Sonny6559\"")) return fail("schema tool: {s}", .{text});
        if (contains(text, "null")) return fail("schema tool holds null: {s}", .{text});
    }
    {
        const text = try toolText(&responses, 4);
        if (!contains(text, "\"sonny6559g\"") or !contains(text, "\"default\"")) return fail("graphs tool: {s}", .{text});
    }
    // (10) explain returns the plan geode query prints.
    {
        const text = try toolText(&responses, 5);
        const parsed = try std.json.parseFromSlice(Value, a, text, .{});
        defer parsed.deinit();
        const plan = parsed.value.object.get("explain") orelse return fail("explain tool returned no plan: {s}", .{text});
        const got = try std.json.Stringify.valueAlloc(a, plan, .{});
        defer a.free(got);
        if (!std.mem.eql(u8, got, cli_plan)) return fail("explain tool plan differs from geode query's:\n  mcp: {s}\n  cli: {s}", .{ got, cli_plan });
    }
    // The query tool returns nodes and lists, not null.
    {
        const text = try toolText(&responses, 6);
        if (contains(text, "null")) return fail("query tool holds null: {s}", .{text});
        if (!contains(text, "\"labels\"") or !contains(text, "\"name\":\"a\"")) return fail("query tool lost the node: {s}", .{text});
    }
    // (6) schema/stats honour {graph}.
    {
        const default_schema = try resourceText(&responses, 8);
        if (!contains(default_schema, "Sonny6559") or contains(default_schema, "Only6559G")) return fail("default schema: {s}", .{default_schema});
        const stats = try resourceText(&responses, 9);
        if (!contains(stats, "node_count")) return fail("default stats: {s}", .{stats});
        const g_schema = try resourceText(&responses, 10);
        if (!contains(g_schema, "Only6559G") or contains(g_schema, "\"Sonny6559\"")) return fail("graph schema ignores {{graph}}: {s}", .{g_schema});
        const g_stats = try resourceText(&responses, 11);
        if (!contains(g_stats, "\"node_count\":1")) return fail("graph stats ignore {{graph}}: {s}", .{g_stats});
    }
    // (6) node/{label} and relationship/{type} read.
    {
        const node = try resourceText(&responses, 12);
        if (!contains(node, "\"count\":2") or !contains(node, "\"name\":\"a\"")) return fail("node template: {s}", .{node});
        const rel = try resourceText(&responses, 13);
        if (!contains(rel, "\"count\":1") or !contains(rel, "KNOWS6559")) return fail("relationship template: {s}", .{rel});
        const config = try resourceText(&responses, 14);
        if (!contains(config, "gql_compliance")) return fail("config: {s}", .{config});
    }
    // Every advertised template is one this server reads.
    {
        const templates = responses.byId(15).?.get("result").?.object.get("resourceTemplates").?.array.items;
        try testing.expect(templates.len >= 4);
        for (templates) |t| {
            const tmpl = t.object.get("uriTemplate").?.string;
            const known = [_][]const u8{
                "geode://{catalog}/{graph}/schema",
                "geode://{catalog}/{graph}/stats",
                "geode://{catalog}/{graph}/node/{label}",
                "geode://{catalog}/{graph}/relationship/{type}",
            };
            var found = false;
            for (known) |k| found = found or std.mem.eql(u8, k, tmpl);
            if (!found) return fail("unexpected template {s}", .{tmpl});
        }
    }
    // A graph that does not exist is not found, not an empty schema of another graph.
    try testing.expectEqual(@as(i64, -32002), try errorCode(&responses, 16));
    // (6) strict URI grammar.
    var loose: usize = 0;
    for (bad_uris, 0..) |uri, i| {
        const code = errorCode(&responses, @intCast(100 + i)) catch {
            std.debug.print("SONNY-6559 (6): {s} was read\n", .{uri});
            loose += 1;
            continue;
        };
        if (code != -32002) {
            std.debug.print("SONNY-6559 (6): {s} answered {d}, not -32002\n", .{ uri, code });
            loose += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), loose);

    for ([_][]const u8{ "leaked", "Invalid free", "Double free", "panic" }) |bad| {
        if (contains(s.err, bad)) return fail("geode mcp stderr holds '{s}'", .{bad});
    }
}
