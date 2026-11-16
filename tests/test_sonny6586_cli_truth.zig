// CANARY: REQ=REQ-SONNY-6586-CLI-TRUTH; FEATURE="CliOptions"; ASPECT=NoFalseClaims; STATUS=TESTED; TEST=tests/test_sonny6586_cli_truth.zig; OWNER=cli; UPDATED=2026-11-15
//
// SONNY-6586 (the real `geode` binary; a real `geode serve` where a server
// is needed):
//
//   1. `geode authn stepup-check` answered from an `admin:` prefix and
//      `stepup-mark` printed "elevated" and did nothing. Both are refused
//      (SONNY-6554); pinned here for this ticket.
//   2. An offline auth command (user, role, policy, grant, revoke, auth
//      reseal) given a data directory that does not exist failed with
//      "DataDirLockUnavailable" (the lock file could not be created in it).
//      It now says the directory does not exist, and creates nothing.
//   3. `geode grant` and `geode revoke` opened the auth store (taking the
//      data directory's lock) before they looked at --help or their
//      arguments, so --help failed while a server held the directory, or
//      when the directory did not exist.
//   4. `geode query --log-level` was accepted and ignored (geode query
//      writes no log), and so was `geode shell --log-level`; `geode tenant`
//      forwards it to query. They are refused (exit 2).
//   5. With the server unreachable, the MCP schema and stats resources
//      answered `"node_labels": []` / `"node_count": 0`, which read as an
//      empty graph. They now answer an error document and no data.
//   6. The MCP query tool refused a list or map parameter
//      (UnsupportedParamType) although geode's wire schema carries both.
//   7. docs/NIX_DEPLOYMENT.md told operators to run
//      `geode --config=... --validate-config`; there is no such option.
const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode_test_bin = @import("geode_test_bin");
const options = @import("sonny6586_options");
const test_scratch = @import("test_scratch.zig");
const util = @import("proto_test_util.zig");

const linux = std.os.linux;
const Value = std.json.Value;
const exe = geode_test_bin.geode_exe;

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

/// Run `geode <argv...>` with stdin `input`, HOME and the working
/// directory `home`, killed after `timeout_s`.
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
        fsIo().sleep(.fromNanoseconds(50 * std.time.ns_per_ms), .awake) catch {};
        waited_ms += 50;
    }
    const code: ?u8 = if (exited and linux.W.IFEXITED(status)) linux.W.EXITSTATUS(status) else null;
    const stdout = try std.Io.Dir.cwd().readFileAlloc(fsIo(), out_path, a, .limited(16 << 20));
    errdefer a.free(stdout);
    const stderr = try std.Io.Dir.cwd().readFileAlloc(fsIo(), err_path, a, .limited(16 << 20));
    return .{ .code = code, .out = stdout, .err = stderr };
}

fn contains(hay: []const u8, needle: []const u8) bool {
    return std.mem.indexOf(u8, hay, needle) != null;
}

fn exists(path: []const u8) bool {
    std.Io.Dir.cwd().access(fsIo(), path, .{}) catch return false;
    return true;
}

fn fail(comptime fmt: []const u8, args: anytype) error{Sonny6586} {
    std.debug.print("SONNY-6586: " ++ fmt ++ "\n", args);
    return error.Sonny6586;
}

test "SONNY-6586 (1): authn stepup-check and stepup-mark are refused, not answered" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var home = try test_scratch.ScratchDir.create("sonny6586-authn");
    defer home.remove();
    for ([_][]const []const u8{
        &.{ "authn", "stepup-check", "--action", "admin:drop" },
        &.{ "authn", "stepup-check", "--action", "read:data" },
        &.{ "authn", "stepup-mark" },
    }) |argv| {
        const r = try runGeode(home.path(), argv, "", 30);
        defer r.deinit();
        errdefer r.dump("geode authn");
        try testing.expectEqual(@as(?u8, 1), r.code);
        if (!contains(r.err, "not supported by this server")) return fail("geode {s} {s}: no refusal", .{ argv[0], argv[1] });
        // What the commands printed before SONNY-6554 (the refusal itself
        // says "nothing was elevated").
        for ([_][]const u8{ "Session elevated", "elevated successfully", "No step-up required", "Step-up required for" }) |claim| {
            if (contains(r.out, claim) or contains(r.err, claim)) return fail("geode {s} {s} claims '{s}'", .{ argv[0], argv[1], claim });
        }
    }
}

test "SONNY-6586 (2): offline auth commands name a missing data directory and create nothing" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = testing.allocator;
    var home = try test_scratch.ScratchDir.create("sonny6586-nodir");
    defer home.remove();
    const missing = try std.fmt.allocPrint(a, "{s}/no-such-data-dir", .{home.path()});
    defer a.free(missing);

    var wrong: usize = 0;
    for ([_][]const []const u8{
        &.{ "user", "list" },
        &.{ "role", "list" },
        &.{ "policy", "list" },
        &.{ "grant", "READ", "--to", "bob", "--graph", "g6586" },
        &.{ "revoke", "READ", "--from", "bob", "--graph", "g6586" },
        &.{ "auth", "reseal" },
    }) |cmd| {
        var argv: std.ArrayList([]const u8) = .empty;
        defer argv.deinit(a);
        try argv.appendSlice(a, cmd);
        try argv.appendSlice(a, &.{ "--data-dir", missing });
        const r = try runGeode(home.path(), argv.items, "", 60);
        defer r.deinit();
        const named = contains(r.err, "does not exist") and contains(r.err, missing);
        if (r.code != 1 or !named or contains(r.err, "DataDirLockUnavailable")) {
            r.dump(cmd[0]);
            std.debug.print("SONNY-6586 (2): geode {s} {s}: exit {?d}, want 1 and a message that {s} does not exist\n", .{ cmd[0], cmd[1], r.code, missing });
            wrong += 1;
        }
        if (exists(missing)) {
            std.debug.print("SONNY-6586 (2): geode {s} {s} created {s}\n", .{ cmd[0], cmd[1], missing });
            wrong += 1;
            std.Io.Dir.cwd().deleteTree(fsIo(), missing) catch {};
        }
    }
    try testing.expectEqual(@as(usize, 0), wrong);
}

test "SONNY-6586 (3): grant and revoke answer --help and usage errors without opening the auth store" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = testing.allocator;
    var home = try test_scratch.ScratchDir.create("sonny6586-help");
    defer home.remove();

    // A data directory whose lock another process holds (as a running
    // server does), and one that does not exist.
    const locked = try std.fmt.allocPrint(a, "{s}/locked", .{home.path()});
    defer a.free(locked);
    try std.Io.Dir.cwd().createDirPath(fsIo(), locked);
    const lock_path = try std.fmt.allocPrint(a, "{s}/.geode.lock", .{locked});
    defer a.free(lock_path);
    const lock_file = try std.Io.Dir.cwd().createFile(fsIo(), lock_path, .{ .read = true, .truncate = false });
    defer lock_file.close(fsIo());
    try testing.expect(try lock_file.tryLock(fsIo(), .exclusive));
    const missing = try std.fmt.allocPrint(a, "{s}/missing", .{home.path()});
    defer a.free(missing);

    const Case = struct { argv: []const []const u8, code: u8, out: ?[]const u8 = null, err: ?[]const u8 = null };
    const cases = [_]Case{
        .{ .argv = &.{ "grant", "--help" }, .code = 0, .out = "Usage: geode grant" },
        .{ .argv = &.{ "grant", "read:data", "--help" }, .code = 0, .out = "Usage: geode grant" },
        .{ .argv = &.{ "grant", "-h" }, .code = 0, .out = "Usage: geode grant" },
        .{ .argv = &.{"grant"}, .code = 2, .err = "missing permission to grant" },
        .{ .argv = &.{ "grant", "read:data" }, .code = 2, .err = "target user or role required" },
        .{ .argv = &.{ "revoke", "--help" }, .code = 0, .out = "Usage: geode revoke" },
        .{ .argv = &.{ "revoke", "read:data", "-h" }, .code = 0, .out = "Usage: geode revoke" },
        .{ .argv = &.{"revoke"}, .code = 2, .err = "missing permission to revoke" },
        .{ .argv = &.{ "revoke", "read:data" }, .code = 2, .err = "--from flag is required" },
    };
    var wrong: usize = 0;
    for ([_][]const u8{ locked, missing }) |dir| {
        for (cases) |c| {
            var argv: std.ArrayList([]const u8) = .empty;
            defer argv.deinit(a);
            try argv.appendSlice(a, c.argv);
            try argv.appendSlice(a, &.{ "--data-dir", dir });
            const r = try runGeode(home.path(), argv.items, "", 60);
            defer r.deinit();
            const out_ok = if (c.out) |o| contains(r.out, o) else true;
            const err_ok = if (c.err) |e| contains(r.err, e) else true;
            if (r.code != c.code or !out_ok or !err_ok) {
                r.dump(c.argv[0]);
                std.debug.print("SONNY-6586 (3): geode {s} ... --data-dir {s}: exit {?d}, want {d}\n", .{ c.argv[0], dir, r.code, c.code });
                wrong += 1;
            }
        }
    }
    try testing.expect(!exists(missing));
    try testing.expectEqual(@as(usize, 0), wrong);
}

test "SONNY-6586 (4): query, shell and tenant refuse --log-level instead of ignoring it" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = testing.allocator;
    var home = try test_scratch.ScratchDir.create("sonny6586-loglevel");
    defer home.remove();
    // Nothing listens here: a command that got past its options would fail
    // to connect (exit 1), not refuse the option (exit 2).
    const port = try util.getRandomPort();
    const addr = try util.formatAddr(a, port);
    defer a.free(addr);

    var wrong: usize = 0;
    for ([_][]const []const u8{
        &.{ "query", "RETURN 1", "--log-level", "debug", "--server", addr, "--insecure-tls-skip-verify" },
        &.{ "query", "--log-level", "error", "RETURN 1", "--server", addr, "--insecure-tls-skip-verify" },
        &.{ "shell", "--log-level", "debug", "--server", addr, "--insecure-tls-skip-verify" },
        &.{ "tenant", "list", "--log-level", "debug", "--server", addr, "--insecure-tls-skip-verify" },
    }) |argv| {
        const r = try runGeode(home.path(), argv, "", 60);
        defer r.deinit();
        if (r.code != 2 or !contains(r.err, "--log-level")) {
            r.dump(argv[0]);
            std.debug.print("SONNY-6586 (4): geode {s} --log-level: exit {?d}, want 2 naming --log-level\n", .{ argv[0], r.code });
            wrong += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), wrong);
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

fn resourceText(responses: *const Responses, id: i64) ![]const u8 {
    const o = responses.byId(id) orelse return fail("no response to id {d}", .{id});
    if (o.get("error")) |e| return fail("id {d} answered an error: {f}", .{ id, std.json.fmt(e, .{}) });
    return o.get("result").?.object.get("contents").?.array.items[0].object.get("text").?.string;
}

/// content[0].text of a tools/call, and whether it is a tool error.
fn toolResult(responses: *const Responses, id: i64) !struct { text: []const u8, is_error: bool } {
    const o = responses.byId(id) orelse return fail("no response to id {d}", .{id});
    if (o.get("error")) |e| return fail("id {d} answered an error: {f}", .{ id, std.json.fmt(e, .{}) });
    const result = o.get("result").?.object;
    const is_error = if (result.get("isError")) |ie| ie == .bool and ie.bool else false;
    return .{ .text = result.get("content").?.array.items[0].object.get("text").?.string, .is_error = is_error };
}

const mcp_handshake =
    \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"protocolVersion":"2025-11-25","capabilities":{},"clientInfo":{"name":"sonny6586-test","version":"1.0"}}}
    \\{"jsonrpc":"2.0","method":"notifications/initialized"}
    \\
;

test "SONNY-6586 (5): with the server unreachable, the MCP schema and stats resources report no data" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = testing.allocator;
    var home = try test_scratch.ScratchDir.create("sonny6586-mcp-offline");
    defer home.remove();
    const port = try util.getRandomPort();
    const endpoint = try std.fmt.allocPrint(a, "quic://127.0.0.1:{d}?insecure=true&timeout_ms=1500", .{port});
    defer a.free(endpoint);
    const input = mcp_handshake ++
        \\{"jsonrpc":"2.0","id":2,"method":"resources/read","params":{"uri":"geode://default/default/schema"}}
        \\{"jsonrpc":"2.0","id":3,"method":"resources/read","params":{"uri":"geode://default/default/stats"}}
        \\
    ;
    const s = try runGeode(home.path(), &.{ "mcp", "--stdio", "--no-auth", "--endpoint", endpoint }, input, 120);
    defer s.deinit();
    errdefer s.dump("geode mcp --stdio (offline)");
    try testing.expectEqual(@as(?u8, 0), s.code);
    var responses = try parseLines(s.out);
    defer responses.deinit();
    for ([_]i64{ 2, 3 }) |id| {
        const text = try resourceText(&responses, id);
        const parsed = try std.json.parseFromSlice(Value, a, text, .{});
        defer parsed.deinit();
        if (parsed.value != .object or parsed.value.object.get("error") == null) return fail("id {d}: no error document: {s}", .{ id, text });
        for ([_][]const u8{ "node_labels", "relationship_types", "node_count", "relationship_count", "index_count" }) |key| {
            if (parsed.value.object.get(key) != null) return fail("id {d}: an unreachable server reported '{s}': {s}", .{ id, key, text });
        }
    }
}

test "SONNY-6586 (6): the MCP query tool passes list and map parameters to a real server" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = testing.allocator;
    var home = try test_scratch.ScratchDir.create("sonny6586-mcp-params");
    defer home.remove();
    var server = try util.spawnServerRandom(a, util.TestEnv.standard());
    defer server.deinit();

    var pass: std.ArrayList(u8) = .empty;
    defer pass.deinit(a);
    for (util.defaultPassword()) |c| {
        if (c == ' ') try pass.appendSlice(a, "%20") else try pass.append(a, c);
    }
    const endpoint = try std.fmt.allocPrint(a, "quic://{s}?insecure=true&user={s}&pass={s}", .{ server.getAddr(), util.defaultUsername(), pass.items });
    defer a.free(endpoint);
    const input = mcp_handshake ++
        \\{"jsonrpc":"2.0","id":2,"method":"tools/call","params":{"name":"query","arguments":{"query":"RETURN $xs AS xs, size($xs) AS n","parameters":{"xs":[1,2,3]}}}}
        \\{"jsonrpc":"2.0","id":3,"method":"tools/call","params":{"name":"query","arguments":{"query":"RETURN $m.k AS k, $m.inner.deep AS deep","parameters":{"m":{"k":"v6586","inner":{"deep":[true,null,"x"]}}}}}}
        \\{"jsonrpc":"2.0","id":4,"method":"tools/call","params":{"name":"query","arguments":{"query":"RETURN $s AS s","parameters":{"s":"scalar6586"}}}}
        \\
    ;
    const s = try runGeode(home.path(), &.{ "mcp", "--stdio", "--no-auth", "--endpoint", endpoint }, input, 120);
    defer s.deinit();
    errdefer s.dump("geode mcp --stdio (params)");
    try testing.expectEqual(@as(?u8, 0), s.code);
    var responses = try parseLines(s.out);
    defer responses.deinit();

    const list = try toolResult(&responses, 2);
    if (list.is_error or !contains(list.text, "[1,2,3]") or !contains(list.text, "\"n\":3")) return fail("list parameter: {s}", .{list.text});
    const map = try toolResult(&responses, 3);
    if (map.is_error or !contains(map.text, "\"k\":\"v6586\"") or !contains(map.text, "[true,null,\"x\"]")) return fail("map parameter: {s}", .{map.text});
    const scalar = try toolResult(&responses, 4);
    if (scalar.is_error or !contains(scalar.text, "scalar6586")) return fail("scalar parameter: {s}", .{scalar.text});
    for ([_][]const u8{ "leaked", "Invalid free", "Double free", "panic" }) |bad| {
        if (contains(s.err, bad)) return fail("geode mcp stderr holds '{s}'", .{bad});
    }
}

test "SONNY-6586 (7): no document names a --validate-config option, and geode serve refuses it" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const a = testing.allocator;
    const docs = try std.fs.path.join(a, &.{ options.repo_root, "docs" });
    defer a.free(docs);
    var dir = try std.Io.Dir.cwd().openDir(fsIo(), docs, .{ .iterate = true });
    defer dir.close(fsIo());
    var walker = try dir.walk(a);
    defer walker.deinit();
    var found: usize = 0;
    while (try walker.next(fsIo())) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.path, ".md")) continue;
        // The changelog records the claim's removal.
        if (std.mem.eql(u8, entry.path, "CHANGELOG.md")) continue;
        const text = try dir.readFileAlloc(fsIo(), entry.path, a, .limited(64 << 20));
        defer a.free(text);
        if (contains(text, "--validate-config")) {
            std.debug.print("SONNY-6586 (7): docs/{s} names --validate-config\n", .{entry.path});
            found += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), found);

    var home = try test_scratch.ScratchDir.create("sonny6586-validate");
    defer home.remove();
    const r = try runGeode(home.path(), &.{ "serve", "--validate-config" }, "", 60);
    defer r.deinit();
    errdefer r.dump("geode serve --validate-config");
    try testing.expectEqual(@as(?u8, 2), r.code);
    try testing.expect(contains(r.err, "--validate-config"));
}
