// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6554 item 5, SONNY-6569 items 5 and 6: one strict DSN parser for the
// CLI's --dsn and the MCP endpoint.
//
// `geode query` / `geode shell --dsn` read the credentials of a DSN's query
// string and ignored every other parameter, including `insecure=true`, which
// the documented and test-harness DSNs pass
// (`localhost:3141?insecure=true&user=...&pass=...`): a security-relevant
// parameter silently had no effect, and so did `ca=`. An unknown or
// malformed parameter (`bogus=1`, `page_size=50%`) was accepted. `geode mcp
// --endpoint` used geode-client-zig's lenient `parseDSN`, so an out-of-range
// `connect_timeout` or a malformed `page_size` silently became the default,
// and an unknown parameter or `insecure=maybe` was accepted.
//
// Now both paths parse with `geode.dsn_params.parse` (geode-client-zig's
// `parseDSNStrict` plus the known-parameter and boolean checks of
// docs/DSN.md): an unknown parameter, a parameter without `=`, a boolean
// that is not one of the documented spellings and a malformed or
// out-of-range number are refused with what is wrong. The CLI honours
// `insecure=true` exactly like --insecure-tls-skip-verify (same warning,
// same production-posture refusal) and `ca=`.
//
// Real `geode serve` (self-signed certificate), real `geode query` binary;
// the MCP endpoint through the real `geode_mcp.client` code.
//
// CANARY: REQ=REQ-SONNY-6554-DSN-PARAMS; FEATURE="DSN parameters"; ASPECT=OneStrictParser; STATUS=TESTED; TEST=tests/test_sonny6554_dsn_params.zig; OWNER=cli; UPDATED=2026-11-15

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const util = @import("proto_test_util.zig");
const geode_test_bin = @import("geode_test_bin");
const geode_mcp = @import("geode_mcp");
const test_scratch = @import("test_scratch.zig");

const linux = std.os.linux;

const password = "Sierra6554 Tango6554 Uniform6554 Victor6554";
const password_encoded = "Sierra6554%20Tango6554%20Uniform6554%20Victor6554";
const creds = "user=geode&pass=" ++ password_encoded;

const dsn_error = "Invalid Geode endpoint DSN";

/// The answer to the test query (6554 * 7). A product, not 42: "42" appears in
/// a version banner such as `v0.8.25-942-...` and in random ports, which
/// made a refused run look answered.
const answer = "45878";

fn fsIo() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

const Run = struct {
    code: ?u8,
    output: []u8,

    fn deinit(self: Run) void {
        testing.allocator.free(self.output);
    }

    fn has(self: Run, needle: []const u8) bool {
        return std.mem.indexOf(u8, self.output, needle) != null;
    }

    fn dump(self: Run, label: []const u8) void {
        std.debug.print("\nSONNY-6554 {s}: exit={?d}\n--- output ---\n{s}\n--- end ---\n", .{ label, self.code, self.output });
    }
};

const Env = struct { name: []const u8, value: []const u8 };

fn runGeode(argv: []const []const u8, extra: []const Env) !Run {
    const a = testing.allocator;
    var threaded = std.Io.Threaded.init(std.heap.smp_allocator, .{});
    defer threaded.deinit();
    var dir = try test_scratch.ScratchDir.create("sonny6554-dsn");
    defer dir.remove();
    var env = std.process.Environ.Map.init(a);
    defer env.deinit();
    inline for (.{ "PATH", "LD_LIBRARY_PATH" }) |name| {
        if (std.c.getenv(name)) |v| try env.put(name, std.mem.span(v));
    }
    try env.put("HOME", dir.path());
    try env.put("GEODE_LSP_PORT", "0");
    for (extra) |e| try env.put(e.name, e.value);

    const out_path = try std.fmt.allocPrint(a, "{s}/run.out", .{dir.path()});
    defer a.free(out_path);
    const out = try std.Io.Dir.cwd().createFile(fsIo(), out_path, .{ .read = true, .truncate = true });
    defer out.close(fsIo());
    const child = try std.process.spawn(threaded.io(), .{
        .argv = argv,
        .environ_map = &env,
        .stdin = .ignore,
        .stdout = .{ .file = out },
        .stderr = .{ .file = out },
    });
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
        if (waited_ms >= 60_000) {
            std.posix.kill(pid, .KILL) catch {};
            _ = linux.waitpid(pid, &status, 0);
            break;
        }
        fsIo().sleep(.fromNanoseconds(100 * std.time.ns_per_ms), .awake) catch {};
        waited_ms += 100;
    }
    const code: ?u8 = if (exited and linux.W.IFEXITED(status)) linux.W.EXITSTATUS(status) else null;
    return .{ .code = code, .output = try std.Io.Dir.cwd().readFileAlloc(fsIo(), out_path, a, .limited(16 << 20)) };
}

/// `geode query --dsn <dsn>` with no TLS flag of its own.
fn query(dsn: []const u8, extra: []const Env) !Run {
    return runGeode(&.{
        geode_test_bin.geode_exe, "query", "--dsn",                dsn, "--no-saved-session",
        "--timeout",              "10",    "RETURN 6554 * 7 AS x",
    }, extra);
}

const Server = struct {
    handle: util.ServerHandle,
    data: test_scratch.ScratchDir,

    fn addr(self: *const Server) []const u8 {
        return self.handle.getAddr();
    }

    fn stop(self: *Server) void {
        self.handle.deinit();
        self.data.remove();
    }
};

fn startServer() !Server {
    var data = try test_scratch.ScratchDir.create("sonny6554-dsn-data");
    errdefer data.remove();
    var data_env_buf: [256]u8 = undefined;
    const data_env = try std.fmt.bufPrint(&data_env_buf, "GEODE_DATA_DIR={s}", .{data.path()});
    const handle = try util.spawnServerRandom(testing.allocator, &.{
        "GEODE_ADMIN_USERNAME=geode",
        "GEODE_ADMIN_PASSWORD=" ++ password,
        "GEODE_DEFAULT_PASSWORD=" ++ password,
        data_env,
    });
    return .{ .handle = handle, .data = data };
}

test "SONNY-6554 (5): geode query honours DSN insecure=true like --insecure-tls-skip-verify, and refuses it under production posture" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var server = try startServer();
    defer server.stop();
    const a = testing.allocator;

    // Self-signed dev server: the DSN alone turns verification off, with the
    // flag's warning.
    inline for (.{ "insecure=true", "insecure_tls_skip_verify=1", "skip_verify=yes" }) |flag| {
        const dsn = try std.fmt.allocPrint(a, "{s}?" ++ flag ++ "&" ++ creds, .{server.addr()});
        defer a.free(dsn);
        const r = try query(dsn, &.{});
        defer r.deinit();
        if (r.code == null or r.code.? != 0 or !r.has(answer) or !r.has("TLS certificate verification DISABLED")) {
            r.dump("query --dsn " ++ flag);
            return error.TestUnexpectedResult;
        }
    }
    // Production posture: refused exactly like the flag (exit 1).
    {
        const dsn = try std.fmt.allocPrint(a, "{s}?insecure=true&" ++ creds, .{server.addr()});
        defer a.free(dsn);
        const r = try query(dsn, &.{.{ .name = "GEODE_ENV", .value = "production" }});
        defer r.deinit();
        if (r.code == null or r.code.? != 1 or r.has(answer) or !r.has("SECURITY: refusing --insecure-tls-skip-verify")) {
            r.dump("query --dsn insecure=true, GEODE_ENV=production");
            return error.TestUnexpectedResult;
        }
    }
    // ...unless the operator accepts the risk.
    {
        const dsn = try std.fmt.allocPrint(a, "{s}?insecure=true&" ++ creds, .{server.addr()});
        defer a.free(dsn);
        const r = try query(dsn, &.{ .{ .name = "GEODE_ENV", .value = "production" }, .{ .name = "GEODE_ALLOW_INSECURE_TLS", .value = "1" } });
        defer r.deinit();
        if (r.code == null or r.code.? != 0 or !r.has(answer)) {
            r.dump("query --dsn insecure=true, production + override");
            return error.TestUnexpectedResult;
        }
    }
}

test "SONNY-6554 (5): geode query honours a DSN ca= bundle" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var server = try startServer();
    defer server.stop();
    const a = testing.allocator;
    // A CA bundle that does not exist cannot verify the server: the query
    // fails instead of connecting unverified as if ca= were not there.
    const dsn = try std.fmt.allocPrint(a, "{s}?ca=/nonexistent/sonny6554-ca.pem&" ++ creds, .{server.addr()});
    defer a.free(dsn);
    const r = try query(dsn, &.{});
    defer r.deinit();
    if (r.code == null or r.code.? == 0 or r.has(answer)) {
        r.dump("query --dsn ca=/nonexistent");
        return error.TestUnexpectedResult;
    }
}

const Bad = struct { query: []const u8, expect: []const u8 };

/// Query strings every DSN path refuses, and what the message says.
const bad_params = [_]Bad{
    .{ .query = "bogus=1", .expect = "unknown query parameter" },
    .{ .query = "insecure", .expect = "name=value" },
    .{ .query = "page_size=50%", .expect = "page_size" },
    .{ .query = "page_size=0", .expect = "page_size" },
    .{ .query = "page_size=abc", .expect = "page_size" },
    .{ .query = "insecure=maybe", .expect = "boolean" },
    .{ .query = "tls=sometimes", .expect = "boolean" },
    .{ .query = "connect_timeout=999999", .expect = "timeout" },
    .{ .query = "connect_timeout=0", .expect = "timeout" },
    .{ .query = "timeout_ms=x", .expect = "timeout" },
};

test "SONNY-6569 (6): geode query refuses an unknown or malformed DSN parameter with what is wrong" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var server = try startServer();
    defer server.stop();
    const a = testing.allocator;
    var failures: usize = 0;
    for (bad_params) |c| {
        const dsn = try std.fmt.allocPrint(a, "{s}?{s}&insecure_tls_skip_verify=true&" ++ creds, .{ server.addr(), c.query });
        defer a.free(dsn);
        const r = try query(dsn, &.{});
        defer r.deinit();
        if (r.code == null or r.code.? != 2 or r.has(answer) or !r.has(dsn_error) or !r.has(c.expect) or r.has("Sierra6554")) {
            r.dump(c.query);
            failures += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

test "SONNY-6554 (5): geode query refuses a DSN parameter it cannot honour and names one that has no effect" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var server = try startServer();
    defer server.stop();
    const a = testing.allocator;
    // Security-relevant parameters the CLI cannot apply: refused (exit 2).
    for ([_][]const u8{ "tenant=acme", "server_name=db.example.com", "tls=false" }) |p| {
        const dsn = try std.fmt.allocPrint(a, "{s}?{s}&insecure=true&" ++ creds, .{ server.addr(), p });
        defer a.free(dsn);
        const r = try query(dsn, &.{});
        defer r.deinit();
        if (r.code == null or r.code.? != 2 or r.has(answer) or !r.has("is not supported by geode query")) {
            r.dump(p);
            return error.TestUnexpectedResult;
        }
    }
    // A valid parameter the CLI does not use: the query runs, and says so.
    {
        const dsn = try std.fmt.allocPrint(a, "{s}?hello_name=my-app&insecure=true&" ++ creds, .{server.addr()});
        defer a.free(dsn);
        const r = try query(dsn, &.{});
        defer r.deinit();
        if (r.code == null or r.code.? != 0 or !r.has(answer) or !r.has("'hello_name' has no effect")) {
            r.dump("hello_name");
            return error.TestUnexpectedResult;
        }
    }
}

test "SONNY-6569 (5): the MCP endpoint parses strictly, with the CLI's rules" {
    const a = testing.allocator;
    var failures: usize = 0;
    for (bad_params) |c| {
        const dsn = try std.fmt.allocPrint(a, "quic://127.0.0.1:3141?{s}", .{c.query});
        defer a.free(dsn);
        if (geode_mcp.client.checkEndpoint(a, dsn)) |_| {
            std.debug.print("MCP endpoint {s}: accepted\n", .{dsn});
            failures += 1;
        } else |err| {
            const msg = geode_mcp.client.initErrorMessage(err, "");
            if (!std.mem.startsWith(u8, msg, dsn_error) or std.mem.indexOf(u8, msg, c.expect) == null) {
                std.debug.print("MCP endpoint {s}: {s} -> '{s}'\n", .{ dsn, @errorName(err), msg });
                failures += 1;
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

test "SONNY-6569 (5): the MCP endpoint still takes every documented DSN form" {
    const a = testing.allocator;
    for ([_][]const u8{
        "quic://localhost:3141",
        "localhost:3141?insecure=true&user=geode&pass=x",
        "quic://admin:secret@geode.example.com:3141?page_size=500&hello_name=my-app&hello_ver=1.0.0&conformance=min",
        "grpc://localhost:50051?tls=0&insecure_tls_skip_verify=true",
        "grpc://localhost:50051/my-graph?ca=/path/to/ca.crt&cert=/path/to/client.crt&key=/path/to/client.key",
        "quic://admin:secret@[2001:db8::1]:3141?insecure_tls_skip_verify=true",
        "quic://localhost:3141?connect_timeout=30&timeout_ms=30000&server_name=db.example.com",
        "quic://localhost:3141?graph=social&tenant=acme&role=analyst",
        "quic://localhost:3141?username=admin&password=secret",
        "quic://localhost:3141?",
    }) |dsn| {
        geode_mcp.client.checkEndpoint(a, dsn) catch |err| {
            std.debug.print("MCP endpoint {s}: {s}\n", .{ dsn, @errorName(err) });
            return err;
        };
    }
}
