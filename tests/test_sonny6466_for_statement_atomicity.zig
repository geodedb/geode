// SONNY-6466 item 2: a FOR statement whose body writes is one statement — if
// element N fails, the elements before it leave nothing behind.
//
// ISO/IEC 39075:2024 4.9.3 ("Conditions"): an exception condition causes the
// execution of the GQL-request to have no effect other than raising it —
// "Execution of the GQL-request is to have no effect on GQL-data or the
// GQL-catalog". 14.8 (<for statement>) expands the working table by every
// element of the list; the write that follows is part of the same request. So
// a failure at any element must leave the graph as it was before the
// statement, although Geode runs the body once per element and each element's
// write commits an engine transaction of its own.
//
// Drives the real `geode serve` over real QUIC: a FOR that creates a node per
// element and divides by zero at the third; a FOR whose MATCH ... SET body
// fails at the third; and a server restart on the same data directory, so the
// assertion covers what is durable, not only the in-memory store.
//
// CANARY: REQ=REQ-SONNY-6466-FOR-ATOMICITY; FEATURE="ForStatement"; ASPECT=StatementAtomicityOnElementFailure; STATUS=TESTED; TEST=tests/test_sonny6466_for_statement_atomicity.zig; OWNER=engine; UPDATED=2026-11-13

const std = @import("std");
const builtin = @import("builtin");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const util = @import("proto_test_util.zig");

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

/// The rows of `query` as `a|b;c|d`, or `error:<code>`.
fn rowsOf(aa: std.mem.Allocator, client: *util.QuicProtoClient, query: []const u8) ![]const u8 {
    var res = try client.executeAndCollectWithTimeout(testing.allocator, query, util.emptyParams(), 100, 60);
    defer res.deinit(testing.allocator);
    if (res.error_code) |code| return std.fmt.allocPrint(aa, "error:{s}", .{code});
    var out: std.ArrayList(u8) = .empty;
    for (res.rows, 0..) |row, i| {
        if (i > 0) try out.append(aa, ';');
        for (row, 0..) |cell, j| {
            if (j > 0) try out.append(aa, '|');
            switch (cell) {
                .int => |v| try out.print(aa, "{d}", .{v}),
                .string => |v| try out.appendSlice(aa, v),
                .null => try out.appendSlice(aa, "null"),
                else => try out.appendSlice(aa, "?"),
            }
        }
    }
    return out.toOwnedSlice(aa);
}

const Server = struct {
    handle: util.ServerHandle,
    addr: []const u8,

    fn start(aa: std.mem.Allocator, data_dir: []const u8) !Server {
        const port = try util.getRandomPort();
        const addr = try util.formatAddr(aa, port);
        var handle = try util.spawnServer(testing.allocator, &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--data-dir", data_dir }, &.{});
        errdefer handle.deinit();
        try util.waitForServerReady(testing.allocator, addr, 30000);
        return .{ .handle = handle, .addr = addr };
    }

    fn client(self: *Server) !util.QuicProtoClient {
        var c = try util.QuicProtoClient.connect(testing.allocator, self.addr);
        errdefer c.deinit();
        c.watchServerLiveness(self.handle.child.id.?);
        var hello = try c.hello(testing.allocator, util.defaultUsername(), util.defaultPassword());
        defer hello.deinit(testing.allocator);
        if (!hello.success) return error.HelloRejected;
        return c;
    }
};

test "SONNY-6466: a FOR whose body fails at an element leaves nothing of the earlier elements, durably" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = try std.process.currentPath(io(), &cwd_buf);
    const data_dir = try std.fmt.allocPrint(aa, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..cwd_len], &tmp.sub_path });

    var failures: std.ArrayList([]const u8) = .empty;
    {
        var server = try Server.start(aa, data_dir);
        defer server.handle.deinit();
        var c = try server.client();
        defer c.deinit();

        // Control: the same FOR with no failing element writes every element.
        const ok = try rowsOf(aa, &c, "FOR i IN [1, 2, 5] CREATE (:F6466Ok {v: 10 / i})");
        if (std.mem.startsWith(u8, ok, "error:")) try failures.append(aa, try std.fmt.allocPrint(aa, "control FOR failed: {s}", .{ok}));
        const ok_count = try rowsOf(aa, &c, "MATCH (n:F6466Ok) RETURN count(n)");
        if (!std.mem.eql(u8, ok_count, "3")) try failures.append(aa, try std.fmt.allocPrint(aa, "control FOR wrote {s} nodes, expected 3", .{ok_count}));

        // CREATE body: elements 1 and 2 succeed, element 3 divides by zero.
        const created = try rowsOf(aa, &c, "FOR i IN [1, 2, 0, 4] CREATE (:F6466 {v: 10 / i})");
        if (!std.mem.startsWith(u8, created, "error:")) try failures.append(aa, try std.fmt.allocPrint(aa, "FOR ... CREATE with a zero divisor answered '{s}', expected an error", .{created}));
        const count = try rowsOf(aa, &c, "MATCH (n:F6466) RETURN count(n)");
        if (!std.mem.eql(u8, count, "0")) try failures.append(aa, try std.fmt.allocPrint(aa, "after the failed FOR ... CREATE: {s} :F6466 nodes, expected 0", .{count}));

        // MATCH ... SET body: the first two elements' SETs must be undone.
        _ = try rowsOf(aa, &c, "CREATE (:F6466Set {k: 1, v: 100})");
        const set = try rowsOf(aa, &c, "FOR i IN [1, 2, 0] MATCH (n:F6466Set {k: 1}) SET n.v = n.v + 10 / i");
        if (!std.mem.startsWith(u8, set, "error:")) try failures.append(aa, try std.fmt.allocPrint(aa, "FOR ... SET with a zero divisor answered '{s}', expected an error", .{set}));
        const v = try rowsOf(aa, &c, "MATCH (n:F6466Set {k: 1}) RETURN n.v");
        if (!std.mem.eql(u8, v, "100")) try failures.append(aa, try std.fmt.allocPrint(aa, "after the failed FOR ... SET: n.v = {s}, expected 100", .{v}));
    }
    {
        // What is durable: the same answers after a restart.
        var server = try Server.start(aa, data_dir);
        defer server.handle.deinit();
        var c = try server.client();
        defer c.deinit();
        const count = try rowsOf(aa, &c, "MATCH (n:F6466) RETURN count(n)");
        if (!std.mem.eql(u8, count, "0")) try failures.append(aa, try std.fmt.allocPrint(aa, "after a restart: {s} :F6466 nodes, expected 0", .{count}));
        const v = try rowsOf(aa, &c, "MATCH (n:F6466Set {k: 1}) RETURN n.v");
        if (!std.mem.eql(u8, v, "100")) try failures.append(aa, try std.fmt.allocPrint(aa, "after a restart: n.v = {s}, expected 100", .{v}));
        const ok_count = try rowsOf(aa, &c, "MATCH (n:F6466Ok) RETURN count(n)");
        if (!std.mem.eql(u8, ok_count, "3")) try failures.append(aa, try std.fmt.allocPrint(aa, "after a restart: {s} :F6466Ok nodes, expected 3", .{ok_count}));
    }

    if (failures.items.len != 0) {
        for (failures.items) |f| std.debug.print("  {s}\n", .{f});
        return error.ForStatementNotAtomic;
    }
}
