// SONNY-6589 (3): the LSP listener `geode serve` co-hosts authenticated no
// one. Its AuthProvider started empty and nothing populated it (no API keys
// or session tokens exist on the server, SONNY-6554), so every `initialize`
// got JSON-RPC -32002 and schema-aware completion over TCP could not work.
//
// The listener now authenticates an `initialize` with the user name and
// password the QUIC HELLO takes (`initializationOptions.geode.username` /
// `.password`, checked by `user_management.authenticate`), and the session's
// completions are filtered for that user: the labels and properties of the
// session's graph only (they were the union over every graph), and nothing
// from a graph the user may not bind and read.
//
// Drives a real `geode serve` with its embedded LSP listener over TCP; the
// users, graphs, grants and data are made over QUIC by the admin.
//
// CANARY: REQ=REQ-SONNY-6589-LSP-PASSWORD-AUTH; FEATURE="Embedded LSP"; ASPECT=PasswordAuthAndPerUserSchema; STATUS=TESTED; TEST=tests/test_sonny6589_lsp_auth.zig; OWNER=lsp; UPDATED=2026-11-15
const std = @import("std");
const builtin = @import("builtin");
const geode_test_bin = @import("geode_test_bin");
const util = @import("proto_test_util.zig");
const test_ports = @import("test_ports.zig");
const scratch = @import("test_scratch.zig");

const testing = std.testing;

const graph_a = "ga6589";
const graph_b = "gb6589";
const alice = "alice6589";
const alice_pw = "Alice Lsp Sonny Passphrase 6589";
const bob = "bob6589";
const bob_pw = "Bob Lsp Sonny Passphrase 6589";

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

fn sleepMs(ms: u64) void {
    io().sleep(.fromNanoseconds(@as(i96, ms) * std.time.ns_per_ms), .awake) catch {};
}

fn monoMs() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * 1000 + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

/// A blocking TCP connection to 127.0.0.1:`port`.
fn connectTcp(port: u16) !std.c.fd_t {
    const fd = std.c.socket(std.posix.AF.INET, std.posix.SOCK.STREAM, 0);
    if (fd < 0) return error.SocketFailed;
    errdefer _ = std.c.close(fd);
    const sa = std.posix.sockaddr.in{
        .family = std.posix.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7F000001),
        .zero = .{0} ** 8,
    };
    if (std.posix.errno(std.c.connect(fd, @ptrCast(&sa), @sizeOf(std.posix.sockaddr.in))) != .SUCCESS)
        return error.ConnectFailed;
    return fd;
}

/// Connect to the LSP port, retrying until the listener is up.
fn connectLsp(port: u16, ms: u64) !std.c.fd_t {
    const deadline = monoMs() + ms;
    while (true) {
        if (connectTcp(port)) |fd| return fd else |err| {
            if (monoMs() >= deadline) return err;
            sleepMs(100);
        }
    }
}

fn writeAll(fd: std.c.fd_t, bytes: []const u8) !void {
    var off: usize = 0;
    while (off < bytes.len) {
        const rc = std.c.write(fd, bytes[off..].ptr, bytes.len - off);
        if (rc <= 0) return error.WriteFailed;
        off += @intCast(rc);
    }
}

fn sendFrame(allocator: std.mem.Allocator, fd: std.c.fd_t, body: []const u8) !void {
    const header = try std.fmt.allocPrint(allocator, "Content-Length: {d}\r\n\r\n", .{body.len});
    defer allocator.free(header);
    try writeAll(fd, header);
    try writeAll(fd, body);
}

const Lsp = struct {
    fd: std.c.fd_t,
    buf: std.ArrayList(u8) = .empty,

    fn close(self: *Lsp, allocator: std.mem.Allocator) void {
        self.buf.deinit(allocator);
        _ = std.c.close(self.fd);
    }

    /// The next whole JSON-RPC frame body (caller frees), or null when the
    /// peer closed or `ms` passed.
    fn nextFrame(self: *Lsp, allocator: std.mem.Allocator, ms: u64) !?[]u8 {
        const deadline = monoMs() + ms;
        while (true) {
            if (std.mem.indexOf(u8, self.buf.items, "\r\n\r\n")) |hdr_end| {
                const header = self.buf.items[0..hdr_end];
                const key = "Content-Length: ";
                const at = std.mem.indexOf(u8, header, key) orelse return error.BadFrame;
                var end = at + key.len;
                while (end < header.len and std.ascii.isDigit(header[end])) end += 1;
                const len = try std.fmt.parseUnsigned(usize, header[at + key.len .. end], 10);
                const total = hdr_end + 4 + len;
                if (self.buf.items.len >= total) {
                    const body = try allocator.dupe(u8, self.buf.items[hdr_end + 4 .. total]);
                    const rest = self.buf.items.len - total;
                    std.mem.copyForwards(u8, self.buf.items[0..rest], self.buf.items[total..]);
                    self.buf.items.len = rest;
                    return body;
                }
            }
            const now = monoMs();
            if (now >= deadline) return null;
            var pfd = [_]std.posix.pollfd{.{ .fd = self.fd, .events = std.posix.POLL.IN, .revents = 0 }};
            const ready = try std.posix.poll(&pfd, @intCast(@min(deadline - now, 1000)));
            if (ready == 0) continue;
            var chunk: [8192]u8 = undefined;
            const n = std.c.read(self.fd, &chunk, chunk.len);
            if (n <= 0) return null;
            try self.buf.appendSlice(allocator, chunk[0..@intCast(n)]);
        }
    }

    /// The response to request `id` (notifications are skipped).
    fn response(self: *Lsp, allocator: std.mem.Allocator, id: u32) ![]u8 {
        var needle_buf: [32]u8 = undefined;
        const needle = try std.fmt.bufPrint(&needle_buf, "\"id\":{d}", .{id});
        while (try self.nextFrame(allocator, 30_000)) |body| {
            if (std.mem.indexOf(u8, body, needle) != null and std.mem.indexOf(u8, body, "\"method\"") == null) return body;
            allocator.free(body);
        }
        std.debug.print("SONNY-6589: no response to LSP request {d}\n", .{id});
        return error.NoResponse;
    }
};

/// `initialize` with `geode` as the `initializationOptions.geode` object.
fn initialize(allocator: std.mem.Allocator, lsp: *Lsp, geode_opts: []const u8) ![]u8 {
    const body = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":1,"method":"initialize","params":{{"processId":null,"rootUri":null,"capabilities":{{}},"initializationOptions":{{"geode":{s}}}}}}}
    , .{geode_opts});
    defer allocator.free(body);
    try sendFrame(allocator, lsp.fd, body);
    return lsp.response(allocator, 1);
}

fn credentials(allocator: std.mem.Allocator, user: []const u8, password: []const u8, graph: []const u8) ![]u8 {
    return std.fmt.allocPrint(allocator, "{{\"username\":\"{s}\",\"password\":\"{s}\",\"graph\":\"{s}\"}}", .{ user, password, graph });
}

/// Open `text` as a document and ask for completions at its end; the
/// response body.
fn completeAtEnd(allocator: std.mem.Allocator, lsp: *Lsp, id: u32, text: []const u8) ![]u8 {
    var uri_buf: [64]u8 = undefined;
    const uri = try std.fmt.bufPrint(&uri_buf, "file:///sonny6589-{d}.gql", .{id});
    const open = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","method":"textDocument/didOpen","params":{{"textDocument":{{"uri":"{s}","languageId":"gql","version":1,"text":"{s}"}}}}}}
    , .{ uri, text });
    defer allocator.free(open);
    try sendFrame(allocator, lsp.fd, open);
    const req = try std.fmt.allocPrint(allocator,
        \\{{"jsonrpc":"2.0","id":{d},"method":"textDocument/completion","params":{{"textDocument":{{"uri":"{s}"}},"position":{{"line":0,"character":{d}}}}}}}
    , .{ id, uri, text.len });
    defer allocator.free(req);
    try sendFrame(allocator, lsp.fd, req);
    return lsp.response(allocator, id);
}

/// An authenticated session: `initialize` must succeed.
fn openSession(allocator: std.mem.Allocator, port: u16, user: []const u8, password: []const u8, graph: []const u8) !Lsp {
    var lsp = Lsp{ .fd = try connectLsp(port, 30_000) };
    errdefer lsp.close(allocator);
    const opts = try credentials(allocator, user, password, graph);
    defer allocator.free(opts);
    const resp = try initialize(allocator, &lsp, opts);
    defer allocator.free(resp);
    if (std.mem.indexOf(u8, resp, "\"capabilities\"") == null or std.mem.indexOf(u8, resp, "\"error\"") != null) {
        std.debug.print("SONNY-6589: initialize as {s} on graph {s} was refused: {s}\n", .{ user, graph, resp });
        return error.InitializeRefused;
    }
    const inited = "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}";
    try sendFrame(allocator, lsp.fd, inited);
    return lsp;
}

fn expectHas(what: []const u8, body: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, body, needle) == null) {
        std.debug.print("SONNY-6589: {s}: '{s}' missing from:\n{s}\n", .{ what, needle, body });
        return error.TestUnexpectedResult;
    }
}

fn expectLacks(what: []const u8, body: []const u8, needle: []const u8) !void {
    if (std.mem.indexOf(u8, body, needle) != null) {
        std.debug.print("SONNY-6589: {s}: '{s}' leaked in:\n{s}\n", .{ what, needle, body });
        return error.TestUnexpectedResult;
    }
}

fn adminRun(allocator: std.mem.Allocator, client: *util.QuicProtoClient, q: []const u8) !void {
    var r = try client.executeAndCollect(allocator, q, util.emptyParams(), 10);
    defer r.deinit(allocator);
    if (r.error_code != null) {
        std.debug.print("SONNY-6589: setup '{s}' failed: {s} {s}\n", .{ q, r.error_code.?, r.error_message orelse "" });
        return error.SetupFailed;
    }
}

test "SONNY-6589 (3): the embedded LSP authenticates with the HELLO credentials and filters completions per user" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;

    var dir = try scratch.ScratchDir.create("sonny6589-lsp");
    defer dir.remove();
    const data_dir = try std.fs.path.join(allocator, &.{ dir.path(), "data" });
    defer allocator.free(data_dir);
    try std.Io.Dir.cwd().createDirPath(io(), data_dir);

    const lsp_port = try test_ports.freeTcpPort();
    const quic_port = try test_ports.freeUdpPortExcept(&.{lsp_port});
    const addr = try util.formatAddr(allocator, quic_port);
    defer allocator.free(addr);
    var lsp_env_buf: [32]u8 = undefined;
    const lsp_env = try std.fmt.bufPrint(&lsp_env_buf, "GEODE_LSP_PORT={d}", .{lsp_port});

    var server = try util.spawnServer(allocator, &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--data-dir", data_dir }, &.{lsp_env});
    defer server.deinit();
    try util.waitForServerReady(allocator, addr, 60_000);

    {
        var admin = try util.QuicProtoClient.connect(allocator, addr);
        defer admin.deinit();
        var h = try admin.hello(allocator, util.defaultUsername(), util.defaultPassword());
        defer h.deinit(allocator);
        try testing.expect(h.success);
        for ([_][]const u8{
            "CREATE GRAPH " ++ graph_a,
            "CREATE GRAPH " ++ graph_b,
            "USE GRAPH " ++ graph_a,
            "CREATE (:Visible6589 {visible_prop6589: 1})",
            "USE GRAPH " ++ graph_b,
            "CREATE (:Secret6589 {secret_ssn6589: 'x'})",
            "CREATE USER " ++ alice ++ " SET PASSWORD '" ++ alice_pw ++ "' ROLE readonly",
            "GRANT READ ON GRAPH " ++ graph_a ++ " TO " ++ alice,
            "CREATE USER " ++ bob ++ " SET PASSWORD '" ++ bob_pw ++ "' ROLE admin",
        }) |q| try adminRun(allocator, &admin, q);
    }

    const label_doc = "MATCH (n:";
    const secret_prop_doc = "MATCH (n:Secret6589) RETURN n.";
    const visible_prop_doc = "MATCH (n:Visible6589) RETURN n.";

    // The admin, by the HELLO's credentials: the session's graph only.
    {
        var lsp = try openSession(allocator, lsp_port, util.defaultUsername(), util.defaultPassword(), graph_a);
        defer lsp.close(allocator);
        const labels = try completeAtEnd(allocator, &lsp, 2, label_doc);
        defer allocator.free(labels);
        try expectHas("admin on " ++ graph_a, labels, "Visible6589");
        try expectLacks("admin on " ++ graph_a ++ " (another graph's label)", labels, "Secret6589");
    }

    // alice (readonly, READ granted on graph_a only).
    {
        var lsp = try openSession(allocator, lsp_port, alice, alice_pw, graph_a);
        defer lsp.close(allocator);
        const labels = try completeAtEnd(allocator, &lsp, 2, label_doc);
        defer allocator.free(labels);
        try expectHas("alice on " ++ graph_a, labels, "Visible6589");
        try expectLacks("alice on " ++ graph_a, labels, "Secret6589");
        // SONNY-6606 (2): the write fast path now counts the keys it
        // writes, so property completion lists them.
        const own = try completeAtEnd(allocator, &lsp, 3, visible_prop_doc);
        defer allocator.free(own);
        try expectHas("alice on " ++ graph_a ++ " properties", own, "visible_prop6589");
        try expectLacks("alice on " ++ graph_a ++ " properties of her graph's label", own, "secret_ssn6589");
        const other = try completeAtEnd(allocator, &lsp, 4, secret_prop_doc);
        defer allocator.free(other);
        try expectLacks("alice on " ++ graph_a ++ " properties of a label of " ++ graph_b, other, "secret_ssn6589");
    }
    // alice asking for the graph she may not bind: no schema of it.
    {
        var lsp = Lsp{ .fd = try connectLsp(lsp_port, 30_000) };
        defer lsp.close(allocator);
        const opts = try credentials(allocator, alice, alice_pw, graph_b);
        defer allocator.free(opts);
        const resp = try initialize(allocator, &lsp, opts);
        defer allocator.free(resp);
        if (std.mem.indexOf(u8, resp, "\"capabilities\"") != null) {
            try sendFrame(allocator, lsp.fd, "{\"jsonrpc\":\"2.0\",\"method\":\"initialized\",\"params\":{}}");
            const labels = try completeAtEnd(allocator, &lsp, 2, label_doc);
            defer allocator.free(labels);
            try expectLacks("alice on " ++ graph_b, labels, "Secret6589");
            const props = try completeAtEnd(allocator, &lsp, 3, secret_prop_doc);
            defer allocator.free(props);
            try expectLacks("alice on " ++ graph_b ++ " properties", props, "secret_ssn6589");
        }
    }

    // bob (admin role) sees graph_b's schema: the filter is per user.
    {
        var lsp = try openSession(allocator, lsp_port, bob, bob_pw, graph_b);
        defer lsp.close(allocator);
        const labels = try completeAtEnd(allocator, &lsp, 2, label_doc);
        defer allocator.free(labels);
        try expectHas("bob on " ++ graph_b, labels, "Secret6589");
        try expectLacks("bob on " ++ graph_b, labels, "Visible6589");
        const props = try completeAtEnd(allocator, &lsp, 3, secret_prop_doc);
        defer allocator.free(props);
        try expectHas("bob on " ++ graph_b ++ " properties", props, "secret_ssn6589");
        const other = try completeAtEnd(allocator, &lsp, 4, visible_prop_doc);
        defer allocator.free(other);
        try expectLacks("bob on " ++ graph_b ++ " properties of a label of " ++ graph_a, other, "visible_prop6589");
    }

    // Fail closed: a wrong password, no credentials, a token nothing issued.
    for ([_][]const u8{
        "{\"username\":\"" ++ alice ++ "\",\"password\":\"not her password\",\"graph\":\"" ++ graph_a ++ "\"}",
        "{\"username\":\"" ++ alice ++ "\",\"graph\":\"" ++ graph_a ++ "\"}",
        "{\"graph\":\"" ++ graph_a ++ "\"}",
        "{\"authToken\":\"sonny6589-not-an-issued-token\",\"graph\":\"" ++ graph_a ++ "\"}",
    }, 0..) |opts, i| {
        var lsp = Lsp{ .fd = try connectLsp(lsp_port, 30_000) };
        defer lsp.close(allocator);
        const resp = try initialize(allocator, &lsp, opts);
        defer allocator.free(resp);
        if (std.mem.indexOf(u8, resp, "-32002") == null or std.mem.indexOf(u8, resp, "\"capabilities\"") != null) {
            std.debug.print("SONNY-6589: unauthenticated initialize {d} was not refused: {s}\n", .{ i, resp });
            return error.TestUnexpectedResult;
        }
        try expectLacks("refused initialize", resp, "not her password");
        const labels = try completeAtEnd(allocator, &lsp, 2, label_doc);
        defer allocator.free(labels);
        // Refused by the lifecycle gate (-32002 "server not initialized").
        try expectHas("completion after a refused initialize", labels, "-32002");
        try expectLacks("completion after a refused initialize", labels, "Visible6589");
    }
}
