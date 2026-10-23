// SONNY-3033 regression: the `/*+BATCH*/` route never creates a graph.
//
// The QUIC `/*+BATCH*/` route (a program of simple MERGEs submitted to the
// group-commit coordinator concurrently) ran before the graph-existence
// check, and the coordinator created whatever graph it was given
// (`getOrCreateGraph`). A session left on a graph that another session
// dropped recreated it with its next batch, without the schema permission
// CREATE GRAPH needs.
//
// Now the route applies the session-graph gate (internal, bind, existence)
// and the coordinator creates no graph but the default one: a batch against a
// dropped graph is refused (3F000), and the graph stays dropped.
//
// CANARY: REQ=REQ-SONNY-3033-BATCH-GRAPH-GATE; FEATURE="MultiGraphIsolation"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3033_batch_graph_gate.zig; OWNER=security; UPDATED=2026-09-27

const std = @import("std");
const testing = std.testing;
const util = @import("proto_test_util.zig");

fn run(client: *util.QuicProtoClient, query: []const u8) !?[]const u8 {
    var r = try client.executeAndCollect(testing.allocator, query, util.emptyParams(), 1000);
    defer r.deinit(testing.allocator);
    if (r.error_code) |code| {
        if (std.mem.eql(u8, code, "00000")) return null;
        std.debug.print("  [{s}] -> {s} {s}\n", .{ query, code, r.error_message orelse "" });
        if (std.mem.eql(u8, code, "3F000")) return "3F000";
        if (std.mem.eql(u8, code, "42P07")) return "42P07";
        if (std.mem.eql(u8, code, "42501")) return "42501";
        return "other";
    }
    return null;
}

fn expectOk(client: *util.QuicProtoClient, query: []const u8) !void {
    if (try run(client, query)) |code| {
        std.debug.print("{s}: {s}\n", .{ query, code });
        return error.QueryFailed;
    }
}

fn count(client: *util.QuicProtoClient, query: []const u8) !i64 {
    var r = try client.executeAndCollect(testing.allocator, query, util.emptyParams(), 1000);
    defer r.deinit(testing.allocator);
    if (r.error_code) |code| {
        std.debug.print("{s}: {s} {s}\n", .{ query, code, r.error_message orelse "" });
        return error.QueryFailed;
    }
    if (r.rows.len != 1) return error.UnexpectedRows;
    return switch (r.rows[0][0]) {
        .int => |v| v,
        else => error.UnexpectedValue,
    };
}

fn login(server_pid: std.posix.pid_t, addr: []const u8, user: []const u8, password: []const u8) !util.QuicProtoClient {
    var client = try util.QuicProtoClient.connect(testing.allocator, addr);
    errdefer client.deinit();
    // SONNY-2394: reply waits follow the server's liveness, not a fixed
    // 5 s deadline (a live server on a loaded CI shard can take longer);
    // a server that exits still fails at once, a hang at the 60 s cap.
    client.watchServerLiveness(server_pid);
    var h = try client.hello(testing.allocator, user, password);
    defer h.deinit(testing.allocator);
    if (!h.success) return error.HelloRefused;
    return client;
}

test "SONNY-3033: over QUIC a /*+BATCH*/ against a graph another session dropped is refused (3F000) and does not create it again, for a ReadWrite user and for an Admin" {
    const allocator = testing.allocator;
    const port = try util.getRandomPort();
    const io_fs = std.Io.Threaded.global_single_threaded.io();
    var dir_buf: [96]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&dir_buf, "/tmp/geode-sonny3033-{d}", .{port});
    std.Io.Dir.cwd().createDirPath(io_fs, data_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io_fs, data_dir) catch {};
    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);
    var server = try util.spawnServer(
        allocator,
        &.{ "./zig-out/bin/geode", "serve", "--listen", addr, "--data-dir", data_dir },
        util.TestEnv.standard(),
    );
    defer server.deinit();
    try util.waitForServerReady(allocator, addr, 30000);

    var admin = try login(server.child.id.?, addr, util.defaultUsername(), util.defaultPassword());
    defer admin.deinit();
    try expectOk(&admin, "CREATE USER rw3033 SET PASSWORD 'Rw3033pass1' ROLE readwrite");
    try expectOk(&admin, "CREATE GRAPH gb3033");
    try expectOk(&admin, "CREATE GRAPH ga3033");

    // A ReadWrite user (no schema permission) batches into gb3033.
    var rw = try login(server.child.id.?, addr, "rw3033", "Rw3033pass1");
    defer rw.deinit();
    try expectOk(&rw, "USE GRAPH gb3033");
    try expectOk(&rw, "/*+BATCH*/MERGE (n:B {k: 1}); MERGE (n:B {k: 2})");
    try testing.expectEqual(@as(i64, 2), try count(&rw, "MATCH (n:B) RETURN count(n) AS c"));

    // Another session drops it; the ReadWrite user's next batch is refused.
    try expectOk(&admin, "DROP GRAPH gb3033");
    try testing.expectEqualStrings("3F000", (try run(&rw, "/*+BATCH*/MERGE (n:B {k: 3}); MERGE (n:B {k: 4})")) orelse "ran");
    // Nothing brought it back: dropping it again finds no graph, and it can
    // be created afresh.
    try testing.expectEqualStrings("3F000", (try run(&admin, "DROP GRAPH gb3033")) orelse "ran");
    try expectOk(&admin, "CREATE GRAPH gb3033");
    try expectOk(&admin, "USE GRAPH gb3033");
    try testing.expectEqual(@as(i64, 0), try count(&admin, "MATCH (n:B) RETURN count(n) AS c"));
    try expectOk(&admin, "USE GRAPH default");

    // The same for an Admin: a batch never creates a graph.
    var admin2 = try login(server.child.id.?, addr, util.defaultUsername(), util.defaultPassword());
    defer admin2.deinit();
    try expectOk(&admin2, "USE GRAPH ga3033");
    try expectOk(&admin, "DROP GRAPH ga3033");
    try testing.expectEqualStrings("3F000", (try run(&admin2, "/*+BATCH*/MERGE (n:A {k: 1}); MERGE (n:A {k: 2})")) orelse "ran");
    try testing.expectEqualStrings("3F000", (try run(&admin, "DROP GRAPH ga3033")) orelse "ran");
}
