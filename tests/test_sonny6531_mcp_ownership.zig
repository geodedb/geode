// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6531 item 1: every MCP handler result is freed exactly once.
//
// The mcp library dispatched every handler result except `tools/call` as
// not owned, so each heap-allocated `resources/read` response (and the JSON
// it stringified for `prompts/get` arguments and `completion/complete`
// params) leaked for the life of `geode mcp`. mcp v0.1.22 frees the result
// of every handler callback with the allocator given to `Server.init`, so
// geode's handlers must return bytes from that allocator, never a literal.
//
// Each method geode implements is driven through the real
// mcp.Server.processMessage dispatch under std.testing.allocator, which
// fails on a leak and panics on an invalid free: with no backend, with an
// endpoint DSN that cannot be dialled, with an endpoint nothing listens on,
// and against a real `geode serve`. Then a real `geode mcp --stdio` session
// (this build's Debug binary, whose DebugAllocator panics on an invalid or
// double free) answers every list/read/get/complete request and exits 0.
// SONNY-6552 (7): `geode mcp` now returns through main instead of ending
// with std.process.exit, so main's DebugAllocator.deinit runs and reports
// a leak of the session on stderr, which the session test refuses.
//
// SONNY-6552 changed what several requests answer (MCP 2025-11-25): an
// unknown prompt, a prompt missing a required argument, an unknown tool and
// a list cursor are -32602 errors, an unknown resource URI -32002; the
// lists are result objects on one line. Those requests hand nothing over.
//
// CANARY: REQ=REQ-SONNY-6531-MCP-OWNERSHIP; FEATURE="MCPResultOwnership"; ASPECT=EveryHandlerResultFreed; STATUS=TESTED; TEST=tests/test_sonny6531_mcp_ownership.zig; OWNER=mcp; UPDATED=2026-11-14

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const mcp_server = @import("mcp_server");
const util = @import("proto_test_util.zig");
const geode_test_bin = @import("geode_test_bin");
const test_scratch = @import("test_scratch.zig");

const GeodeMcpServer = mcp_server.GeodeMcpServer;
const linux = std.os.linux;

/// Each prompt with its required arguments (SONNY-6552: a prompt missing
/// one is a -32602 error).
const prompt_calls = [_]struct { name: []const u8, args: []const u8 }{
    .{ .name = "find_nodes", .args = "{\"label\":\"Person\"}" },
    .{ .name = "find_relationships", .args = "{\"type\":\"KNOWS\",\"direction\":\"both\"}" },
    .{ .name = "create_node", .args = "{\"label\":\"Person\",\"properties\":\"{}\"}" },
    .{ .name = "create_relationship", .args = "{\"from_label\":\"A\",\"to_label\":\"B\",\"type\":\"R\"}" },
    .{ .name = "shortest_path", .args = "{\"from_label\":\"A\",\"to_label\":\"B\"}" },
    .{ .name = "graph_analysis", .args = "{\"metric\":\"degree\"}" },
    .{ .name = "pattern_match", .args = "{\"pattern\":\"a triangle\"}" },
};

const resource_uris = [_][]const u8{
    "geode://default/default/schema",
    "geode://default/default/stats",
    "geode://config",
};

/// What a response must carry.
const Want = union(enum) {
    /// A `result`; when `needle` is set, the response holds it.
    result: ?[]const u8,
    /// An `error` with this JSON-RPC code.
    err: i64,
};

fn dispatch(server: *GeodeMcpServer, msg: []const u8) !?[]const u8 {
    return server.server.processMessage(msg);
}

/// Send `msg` (a request with id `id`) and check the response.
fn expectResponse(server: *GeodeMcpServer, id: i64, msg: []const u8, want: Want) !void {
    const a = testing.allocator;
    const resp = (try dispatch(server, msg)) orelse {
        std.debug.print("no response to: {s}\n", .{msg});
        return error.UnexpectedNullResponse;
    };
    defer a.free(resp);
    errdefer std.debug.print("request: {s}\nresponse: {s}\n", .{ msg, resp });
    const parsed = try std.json.parseFromSlice(std.json.Value, a, resp, .{});
    defer parsed.deinit();
    const root = parsed.value.object;
    const got_id = root.get("id") orelse return error.NoId;
    try testing.expect(got_id == .integer and got_id.integer == id);
    switch (want) {
        .result => |needle| {
            try testing.expect(root.get("error") == null);
            try testing.expect(root.get("result") != null);
            if (needle) |n| try testing.expect(std.mem.indexOf(u8, resp, n) != null);
        },
        .err => |code| {
            const e = root.get("error") orelse return error.NoError;
            const c = e.object.get("code") orelse return error.NoErrorCode;
            try testing.expectEqual(code, c.integer);
        },
    }
}

fn handshake(server: *GeodeMcpServer) !void {
    try expectResponse(server, 1,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"sonny6531-test","version":"1.0"}}}
    , .{ .result = "\"serverInfo\"" });
    try testing.expect((try dispatch(server,
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    )) == null);
    try expectResponse(server, 2,
        \\{"jsonrpc":"2.0","id":2,"method":"ping"}
    , .{ .result = null });
}

fn fmtMsg(buf: []u8, comptime fmt: []const u8, args: anytype) ![]const u8 {
    return std.fmt.bufPrint(buf, fmt, args);
}

/// Every method that needs no backend: the listings, every prompt, the
/// local (LSP) tools, completion, logging, subscriptions, notifications
/// and a batch.
fn driveLocalMethods(server: *GeodeMcpServer) !void {
    var buf: [1024]u8 = undefined;

    try expectResponse(server, 10,
        \\{"jsonrpc":"2.0","id":10,"method":"tools/list"}
    , .{ .result = "\"name\":\"query\"" });
    // SONNY-6552: the list is one page; a cursor geode never issued is -32602.
    try expectResponse(server, 11,
        \\{"jsonrpc":"2.0","id":11,"method":"tools/list","params":{"cursor":"next"}}
    , .{ .err = -32602 });
    try expectResponse(server, 12,
        \\{"jsonrpc":"2.0","id":12,"method":"resources/list"}
    , .{ .result = "geode://config" });
    try expectResponse(server, 13,
        \\{"jsonrpc":"2.0","id":13,"method":"resources/templates/list"}
    , .{ .result = "uriTemplate" });
    try expectResponse(server, 14,
        \\{"jsonrpc":"2.0","id":14,"method":"prompts/list"}
    , .{ .result = "\"name\":\"pattern_match\"" });

    for (prompt_calls, 0..) |call, i| {
        const id: i64 = 100 + @as(i64, @intCast(i));
        // Without arguments: every prompt has a required one (-32602).
        try expectResponse(server, id, try fmtMsg(&buf,
            \\{{"jsonrpc":"2.0","id":{d},"method":"prompts/get","params":{{"name":"{s}"}}}}
        , .{ id, call.name }), .{ .err = -32602 });
        // With arguments: the library stringifies them for the handler.
        try expectResponse(server, id + 50, try fmtMsg(&buf,
            \\{{"jsonrpc":"2.0","id":{d},"method":"prompts/get","params":{{"name":"{s}","arguments":{s}}}}}
        , .{ id + 50, call.name, call.args }), .{ .result = "\"messages\"" });
    }
    try expectResponse(server, 199,
        \\{"jsonrpc":"2.0","id":199,"method":"prompts/get","params":{"name":"no_such_prompt"}}
    , .{ .err = -32602 });

    // The tools that run in-process (no backend).
    try expectResponse(server, 20,
        \\{"jsonrpc":"2.0","id":20,"method":"tools/call","params":{"name":"validate","arguments":{"query":"MATCH (n:Person) RETURN n"}}}
    , .{ .result = "\"isError\":false" });
    try expectResponse(server, 21,
        \\{"jsonrpc":"2.0","id":21,"method":"tools/call","params":{"name":"validate","arguments":{"query":"MATCH (n RETURN"}}}
    , .{ .result = "\"isError\":false" });
    try expectResponse(server, 22,
        \\{"jsonrpc":"2.0","id":22,"method":"tools/call","params":{"name":"complete","arguments":{"query":"MAT","line":1,"column":4}}}
    , .{ .result = "\"isError\":false" });
    try expectResponse(server, 23,
        \\{"jsonrpc":"2.0","id":23,"method":"tools/call","params":{"name":"hover","arguments":{"query":"MATCH (n) RETURN count(n)","line":1,"column":2}}}
    , .{ .result = "\"isError\":false" });
    try expectResponse(server, 24,
        \\{"jsonrpc":"2.0","id":24,"method":"tools/call","params":{"name":"diagnostics","arguments":{"query":"RETURN 1"}}}
    , .{ .result = "\"isError\":false" });
    // Tool error results (isError: true) and a tool that does not exist
    // (the handler returns an error: nothing is handed over; SONNY-6552:
    // -32602, the spec's protocol error for an unknown tool).
    for ([_][]const u8{ "validate", "complete", "hover", "diagnostics", "query", "explain" }, 0..) |tool, i| {
        const id: i64 = 30 + @as(i64, @intCast(i));
        try expectResponse(server, id, try fmtMsg(&buf,
            \\{{"jsonrpc":"2.0","id":{d},"method":"tools/call","params":{{"name":"{s}","arguments":{{"wrong":1}}}}}}
        , .{ id, tool }), .{ .result = "\"isError\":true" });
    }
    try expectResponse(server, 39,
        \\{"jsonrpc":"2.0","id":39,"method":"tools/call","params":{"name":"no_such_tool","arguments":{}}}
    , .{ .err = -32602 });

    // A resource URI geode does not serve, with and without the scheme
    // (SONNY-6552: -32002 resource not found).
    try expectResponse(server, 40,
        \\{"jsonrpc":"2.0","id":40,"method":"resources/read","params":{"uri":"geode://default/default/nothing"}}
    , .{ .err = -32002 });
    try expectResponse(server, 41,
        \\{"jsonrpc":"2.0","id":41,"method":"resources/read","params":{"uri":"unknown://resource"}}
    , .{ .err = -32002 });

    // completion/complete, without and with params (the library
    // stringifies params for the handler).
    try expectResponse(server, 50,
        \\{"jsonrpc":"2.0","id":50,"method":"completion/complete"}
    , .{ .result = "\"completion\"" });
    try expectResponse(server, 51,
        \\{"jsonrpc":"2.0","id":51,"method":"completion/complete","params":{"ref":{"type":"ref/prompt","name":"find_nodes"},"argument":{"name":"label","value":"Pe"}}}
    , .{ .result = "\"completion\"" });

    try expectResponse(server, 60,
        \\{"jsonrpc":"2.0","id":60,"method":"logging/setLevel","params":{"level":"debug"}}
    , .{ .result = null });
    try expectResponse(server, 61,
        \\{"jsonrpc":"2.0","id":61,"method":"resources/subscribe","params":{"uri":"geode://config"}}
    , .{ .err = -32601 });
    try expectResponse(server, 62,
        \\{"jsonrpc":"2.0","id":62,"method":"resources/unsubscribe","params":{"uri":"geode://config"}}
    , .{ .err = -32601 });

    // Notifications (no id): the handlers run and their results are freed
    // with no response built. (A notification whose handler fails gets an
    // error response from the mcp library, so these all succeed.)
    for ([_][]const u8{
        \\{"jsonrpc":"2.0","method":"tools/list"}
        ,
        \\{"jsonrpc":"2.0","method":"resources/read","params":{"uri":"geode://config"}}
        ,
        \\{"jsonrpc":"2.0","method":"prompts/get","params":{"name":"find_nodes","arguments":{"label":"X"}}}
        ,
        \\{"jsonrpc":"2.0","method":"completion/complete","params":{"argument":{"name":"x","value":""}}}
        ,
        \\{"jsonrpc":"2.0","method":"tools/call","params":{"name":"validate","arguments":{"query":"RETURN 1"}}}
        ,
    }) |note| {
        try testing.expect((try dispatch(server, note)) == null);
    }

    // A batch: every item's result is freed once.
    const batch =
        \\[{"jsonrpc":"2.0","id":70,"method":"tools/list"},{"jsonrpc":"2.0","id":71,"method":"resources/templates/list"},{"jsonrpc":"2.0","id":72,"method":"prompts/get","params":{"name":"shortest_path","arguments":{"from_label":"A","to_label":"B"}}},{"jsonrpc":"2.0","id":73,"method":"completion/complete","params":{"argument":{"name":"x","value":""}}},{"jsonrpc":"2.0","id":74,"method":"resources/read","params":{"uri":"geode://config"}},{"jsonrpc":"2.0","id":75,"method":"tools/call","params":{"name":"diagnostics","arguments":{"query":"RETURN 1"}}},{"jsonrpc":"2.0","method":"prompts/list"}]
    ;
    const resp = (try dispatch(server, batch)) orelse return error.UnexpectedNullResponse;
    defer testing.allocator.free(resp);
    const parsed = try std.json.parseFromSlice(std.json.Value, testing.allocator, resp, .{});
    defer parsed.deinit();
    errdefer std.debug.print("batch response: {s}\n", .{resp});
    try testing.expect(parsed.value == .array);
    try testing.expectEqual(@as(usize, 6), parsed.value.array.items.len);
    for (parsed.value.array.items) |item| try testing.expect(item.object.get("result") != null);
}

/// Every backend tool and every resource against `server`'s endpoint; each
/// response must hold `needle`.
fn driveBackendMethods(server: *GeodeMcpServer, tool_needle: []const u8, resource_needle: []const u8) !void {
    var buf: [1024]u8 = undefined;
    for ([_][]const u8{
        \\"query","arguments":{"query":"RETURN 1 AS x"}
        ,
        \\"schema","arguments":{}
        ,
        \\"explain","arguments":{"query":"MATCH (n) RETURN n"}
        ,
        \\"graphs"
        ,
        \\"graphs","arguments":{}
        ,
    }, 0..) |call, i| {
        const id: i64 = 300 + @as(i64, @intCast(i));
        try expectResponse(server, id, try fmtMsg(&buf,
            \\{{"jsonrpc":"2.0","id":{d},"method":"tools/call","params":{{"name":{s}}}}}
        , .{ id, call }), .{ .result = tool_needle });
    }
    for (resource_uris, 0..) |uri, i| {
        const id: i64 = 400 + @as(i64, @intCast(i));
        try expectResponse(server, id, try fmtMsg(&buf,
            \\{{"jsonrpc":"2.0","id":{d},"method":"resources/read","params":{{"uri":"{s}"}}}}
        , .{ id, uri }), .{ .result = resource_needle });
    }
}

test "SONNY-6531: every MCP method with no backend frees its handler result once" {
    const server = try GeodeMcpServer.init(testing.allocator, .{ .auth_mode = .none });
    defer server.deinit();
    try handshake(server);
    try driveLocalMethods(server);
}

test "SONNY-6531: backend tools and resources answer an undialable endpoint DSN without leaking" {
    // Port 0 parses but cannot be dialled: every backend tool and resource
    // fails at client init and answers an allocated error result.
    const server = try GeodeMcpServer.init(testing.allocator, .{ .auth_mode = .none, .geode_endpoint = "quic://127.0.0.1:0" });
    defer server.deinit();
    try handshake(server);
    try driveBackendMethods(server, "the port must be 1-65535", "the port must be 1-65535");
}

test "SONNY-6531: resources fall back to their offline documents without leaking" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    // Nothing listens on the port: the client is built, the request fails,
    // and schema/stats answer their "Server unavailable" documents (config
    // is answered locally by the client).
    // SONNY-6589 (2): no timeout parameter: geode mcp refuses one (the
    // client library cannot apply it; it never shortened these waits).
    const port = try util.getRandomPort();
    var ep_buf: [64]u8 = undefined;
    const endpoint = try std.fmt.bufPrint(&ep_buf, "quic://127.0.0.1:{d}?insecure=true", .{port});
    const server = try GeodeMcpServer.init(testing.allocator, .{ .auth_mode = .none, .geode_endpoint = endpoint });
    defer server.deinit();
    try handshake(server);
    try expectResponse(server, 500,
        \\{"jsonrpc":"2.0","id":500,"method":"resources/read","params":{"uri":"geode://default/default/schema"}}
    , .{ .result = "Server unavailable" });
    try expectResponse(server, 501,
        \\{"jsonrpc":"2.0","id":501,"method":"resources/read","params":{"uri":"geode://default/default/stats"}}
    , .{ .result = "Server unavailable" });
    try expectResponse(server, 502,
        \\{"jsonrpc":"2.0","id":502,"method":"resources/read","params":{"uri":"geode://config"}}
    , .{ .result = "gql_compliance" });
}

const Server = struct {
    handle: util.ServerHandle,
    data: test_scratch.ScratchDir,
    dsn_buf: [256]u8 = undefined,
    dsn_len: usize = 0,

    fn dsn(self: *const Server) []const u8 {
        return self.dsn_buf[0..self.dsn_len];
    }

    fn stop(self: *Server) void {
        self.handle.deinit();
        self.data.remove();
    }
};

/// A fresh `geode serve` (own data dir) and a DSN that logs in to it.
fn startServer(server: *Server) !void {
    server.data = try test_scratch.ScratchDir.create("sonny6531-data");
    errdefer server.data.remove();
    var data_env_buf: [256]u8 = undefined;
    const data_env = try std.fmt.bufPrint(&data_env_buf, "GEODE_DATA_DIR={s}", .{server.data.path()});
    server.handle = try util.spawnServerRandom(testing.allocator, &.{data_env});
    const d = try std.fmt.bufPrint(&server.dsn_buf, "quic://{s}?insecure=true&user={s}&pass=Geode%20Test%20Admin%20Passphrase", .{ server.handle.getAddr(), util.defaultUsername() });
    server.dsn_len = d.len;
}

test "SONNY-6531: against a real geode serve, every tool and resource result is freed once" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var backend: Server = .{ .handle = undefined, .data = undefined };
    try startServer(&backend);
    defer backend.stop();

    const server = try GeodeMcpServer.init(testing.allocator, .{ .auth_mode = .none, .geode_endpoint = backend.dsn() });
    defer server.deinit();
    try handshake(server);
    try driveLocalMethods(server);
    try driveBackendMethods(server, "\"content\"", "\"uri\"");
    // The query result reached the client and back.
    try expectResponse(server, 600,
        \\{"jsonrpc":"2.0","id":600,"method":"tools/call","params":{"name":"query","arguments":{"query":"RETURN 6531 AS x"}}}
    , .{ .result = "6531" });
    // A query the server rejects is an isError result.
    try expectResponse(server, 601,
        \\{"jsonrpc":"2.0","id":601,"method":"tools/call","params":{"name":"query","arguments":{"query":"MATCH (n RETURN"}}}
    , .{ .result = "\"isError\":true" });
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

    var dir = try test_scratch.ScratchDir.create("sonny6531-mcp");
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

test "SONNY-6531: a real geode mcp --stdio session answers every request and exits cleanly" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    // The Debug binary's DebugAllocator (src/cli/main.zig) panics on an
    // invalid or double free, which kills the session, and (SONNY-6552:
    // `geode mcp` returns through main) reports every leaked allocation
    // ("error(gpa): memory address ... leaked") when the session ends.
    if (builtin.mode != .Debug) return error.SkipZigTest;
    var backend: Server = .{ .handle = undefined, .data = undefined };
    try startServer(&backend);
    defer backend.stop();

    const a = testing.allocator;
    var input: std.ArrayList(u8) = .empty;
    defer input.deinit(a);
    try input.appendSlice(a,
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"sonny6531-stdio","version":"1.0"}}}
        \\{"jsonrpc":"2.0","method":"notifications/initialized"}
        \\{"jsonrpc":"2.0","id":2,"method":"ping"}
        \\{"jsonrpc":"2.0","id":3,"method":"tools/list"}
        \\{"jsonrpc":"2.0","id":4,"method":"resources/list"}
        \\{"jsonrpc":"2.0","id":5,"method":"resources/templates/list"}
        \\{"jsonrpc":"2.0","id":6,"method":"prompts/list"}
        \\{"jsonrpc":"2.0","id":7,"method":"resources/read","params":{"uri":"geode://default/default/schema"}}
        \\{"jsonrpc":"2.0","id":8,"method":"resources/read","params":{"uri":"geode://default/default/stats"}}
        \\{"jsonrpc":"2.0","id":9,"method":"resources/read","params":{"uri":"geode://config"}}
        \\{"jsonrpc":"2.0","id":10,"method":"resources/read","params":{"uri":"unknown://resource"}}
        \\{"jsonrpc":"2.0","id":11,"method":"prompts/get","params":{"name":"find_nodes","arguments":{"label":"Person"}}}
        \\{"jsonrpc":"2.0","id":12,"method":"prompts/get","params":{"name":"no_such_prompt"}}
        \\{"jsonrpc":"2.0","id":13,"method":"completion/complete","params":{"ref":{"type":"ref/prompt","name":"find_nodes"},"argument":{"name":"label","value":"P"}}}
        \\{"jsonrpc":"2.0","id":14,"method":"tools/call","params":{"name":"query","arguments":{"query":"RETURN 6531 AS x"}}}
        \\{"jsonrpc":"2.0","id":15,"method":"tools/call","params":{"name":"validate","arguments":{"query":"RETURN 1"}}}
        \\{"jsonrpc":"2.0","id":16,"method":"logging/setLevel","params":{"level":"info"}}
        \\{"jsonrpc":"2.0","id":17,"method":"resources/subscribe","params":{"uri":"geode://config"}}
        \\[{"jsonrpc":"2.0","id":18,"method":"tools/list"},{"jsonrpc":"2.0","id":19,"method":"prompts/get","params":{"name":"pattern_match"}}]
        \\
    );
    const s = try runMcpSession(backend.dsn(), input.items, 120);
    defer s.deinit();
    errdefer s.dump();

    try testing.expectEqual(@as(?u8, 0), s.code);
    for ([_][]const u8{ "leaked", "Invalid free", "Double free", "panic" }) |bad| {
        if (std.mem.indexOf(u8, s.stderr, bad) != null) {
            std.debug.print("geode mcp stderr holds '{s}'\n", .{bad});
            return error.MemoryErrorReported;
        }
    }
    // Every request is answered (the one-message-per-line shape check is
    // tests/test_sonny6552_mcp_result_shapes.zig).
    var id: usize = 1;
    while (id < 20) : (id += 1) {
        var needle_buf: [64]u8 = undefined;
        const needle = try std.fmt.bufPrint(&needle_buf, "{{\"jsonrpc\":\"2.0\",\"id\":{d},", .{id});
        if (std.mem.indexOf(u8, s.stdout, needle) == null) {
            std.debug.print("request id {d} was not answered\n", .{id});
            return error.RequestNotAnswered;
        }
    }
    try testing.expect(std.mem.indexOf(u8, s.stdout, "6531") != null);
}
