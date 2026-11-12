// SONNY-2846 / SONNY-3358 regression over the wire: the server's write fast
// paths cannot make a UNIQUE duplicate, and concurrent writers of one value
// over QUIC end with exactly one node.
//
// The QUIC handler serves simple CREATEs, bulk MERGEs, `/*+BATCH*/` MERGE
// programs and `USE GRAPH g; MERGE` straight through the storage adapter,
// skipping the executor (and so, before SONNY-2846, any constraint check).
// Each of those shapes is sent here against a UNIQUE-constrained label,
// with group commit on (the default) and off with GEODE_BULK_INGEST=1, and
// must answer 23505 and leave one node per value. A MATCH ... CREATE edge
// fast path writes no node and keeps working. Eight clients then create the
// same value at once, 10 rounds: one 00000 and seven 23505 each round.
//
// CANARY: REQ=REQ-SONNY-2846-UNIQUE-ENFORCEMENT; FEATURE="ConstraintEnforcement"; ASPECT=WireRegression; STATUS=TESTED; TEST=tests/test_sonny2846_unique_fast_paths_wire.zig; OWNER=transport; UPDATED=2026-11-11

const std = @import("std");
const testing = std.testing;
const util = @import("proto_test_util.zig");

/// The status `query` answered with ("00000" on success); caller frees.
fn status(client: *util.QuicProtoClient, query: []const u8) ![]u8 {
    var r = try client.executeAndCollect(testing.allocator, query, util.emptyParams(), 1000);
    defer r.deinit(testing.allocator);
    const code = r.error_code orelse "00000";
    if (!std.mem.eql(u8, code, "00000") and !std.mem.eql(u8, code, "23505")) {
        std.debug.print("  [{s}] -> {s} {s}\n", .{ query, code, r.error_message orelse "" });
    }
    return testing.allocator.dupe(u8, code);
}

fn expectStatus(client: *util.QuicProtoClient, query: []const u8, want: []const u8) !void {
    const got = try status(client, query);
    defer testing.allocator.free(got);
    if (!std.mem.eql(u8, got, want)) {
        std.debug.print("{s}: {s}, expected {s}\n", .{ query, got, want });
        return error.UnexpectedStatus;
    }
}

fn count(client: *util.QuicProtoClient, query: []const u8) !i64 {
    var r = try client.executeAndCollect(testing.allocator, query, util.emptyParams(), 1000);
    defer r.deinit(testing.allocator);
    if (r.error_code) |code| {
        if (!std.mem.eql(u8, code, "00000")) {
            std.debug.print("{s}: {s} {s}\n", .{ query, code, r.error_message orelse "" });
            return error.QueryFailed;
        }
    }
    if (r.rows.len != 1) return error.UnexpectedRows;
    return switch (r.rows[0][0]) {
        .int => |v| v,
        else => error.UnexpectedValue,
    };
}

fn login(server_pid: std.posix.pid_t, addr: []const u8) !util.QuicProtoClient {
    var client = try util.QuicProtoClient.connect(testing.allocator, addr);
    errdefer client.deinit();
    client.watchServerLiveness(server_pid);
    var h = try client.hello(testing.allocator, util.defaultUsername(), util.defaultPassword());
    defer h.deinit(testing.allocator);
    if (!h.success) return error.HelloRefused;
    return client;
}

const Racer = struct {
    addr: []const u8,
    pid: std.posix.pid_t,
    query: []const u8 = "",
    ready: *std.atomic.Value(u32),
    go: *std.atomic.Value(u32),
    client: ?util.QuicProtoClient = null,
    code: ?[]u8 = null,
    failed: ?anyerror = null,

    fn connect(self: *Racer) void {
        self.client = login(self.pid, self.addr) catch |err| {
            self.failed = err;
            return;
        };
    }

    fn run(self: *Racer, round: u32) void {
        _ = self.ready.fetchAdd(1, .acq_rel);
        while (self.go.load(.acquire) != round) std.atomic.spinLoopHint();
        if (self.client) |*c| {
            self.code = status(c, self.query) catch |err| blk: {
                self.failed = err;
                break :blk null;
            };
        }
    }
};

fn exercise(env: []const []const u8, concurrency: bool) !void {
    const allocator = testing.allocator;
    const port = try util.getRandomPort();
    const io_fs = std.Io.Threaded.global_single_threaded.io();
    var dir_buf: [96]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&dir_buf, "/tmp/geode-sonny2846-{d}", .{port});
    std.Io.Dir.cwd().createDirPath(io_fs, data_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io_fs, data_dir) catch {};
    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);
    var server = try util.spawnServer(
        allocator,
        &.{ "./zig-out/bin/geode", "serve", "--listen", addr, "--data-dir", data_dir },
        env,
    );
    defer server.deinit();
    try util.waitForServerReady(allocator, addr, 30000);
    const pid = server.child.id.?;

    var admin = try login(pid, addr);
    defer admin.deinit();
    try expectStatus(&admin, "CREATE CONSTRAINT w_id FOR (n:W) REQUIRE n.id IS UNIQUE", "00000");

    // Simple CREATE (the simple-create fast path's shape).
    try expectStatus(&admin, "CREATE (:W {id: 1})", "00000");
    try expectStatus(&admin, "CREATE (:W {id: 1})", "23505");
    try expectStatus(&admin, "CREATE (:W {id: 1.0, tag: 'x'})", "23505");
    try testing.expectEqual(@as(i64, 1), try count(&admin, "MATCH (n:W {id: 1}) RETURN count(n) AS c"));

    // Bulk MERGE: matching the holder is fine; creating a duplicate is not.
    try expectStatus(&admin, "MERGE (n:W {id: 1})", "00000");
    try expectStatus(&admin, "MERGE (n:W {id: 2})", "00000");
    try expectStatus(&admin, "MERGE (n:W {code: 'a'}) ON CREATE SET n.id = 1", "23505");
    try expectStatus(&admin, "MERGE (n:W {code: 'a', id: 2})", "23505");
    try testing.expectEqual(@as(i64, 0), try count(&admin, "MATCH (n:W {code: 'a'}) RETURN count(n) AS c"));

    // /*+BATCH*/ MERGE program.
    try expectStatus(&admin, "/*+BATCH*/MERGE (n:W {id: 1}); MERGE (n:W {id: 3})", "00000");
    try expectStatus(&admin, "/*+BATCH*/MERGE (n:W {code: 'b'}) ON CREATE SET n.id = 3; MERGE (n:W {code: 'c'})", "23505");
    try testing.expectEqual(@as(i64, 0), try count(&admin, "MATCH (n:W {code: 'b'}) RETURN count(n) AS c"));

    // `USE GRAPH g; MERGE` (the pooled-driver shape).
    try expectStatus(&admin, "USE GRAPH default; MERGE (n:W {code: 'd'}) ON CREATE SET n.id = 2", "23505");
    try testing.expectEqual(@as(i64, 0), try count(&admin, "MATCH (n:W {code: 'd'}) RETURN count(n) AS c"));

    // MATCH ... CREATE edge: no node is written; it still works.
    try expectStatus(&admin, "MATCH (a:W {id: 1}), (b:W {id: 2}) CREATE (a)-[:WR]->(b)", "00000");
    try testing.expectEqual(@as(i64, 3), try count(&admin, "MATCH (n:W) RETURN count(n) AS c"));
    try testing.expectEqual(@as(i64, 1), try count(&admin, "MATCH (:W)-[r:WR]->(:W) RETURN count(r) AS c"));

    // An unconstrained label keeps the fast paths' results.
    try expectStatus(&admin, "CREATE (:Free {id: 1})", "00000");
    try expectStatus(&admin, "CREATE (:Free {id: 1})", "00000");
    try testing.expectEqual(@as(i64, 2), try count(&admin, "MATCH (n:Free {id: 1}) RETURN count(n) AS c"));

    if (!concurrency) return;

    // Eight clients create one value at once: exactly one wins, every round.
    try expectStatus(&admin, "CREATE CONSTRAINT w2_id FOR (n:W2) REQUIRE n.id IS UNIQUE", "00000");
    const writers = 8;
    var ready = std.atomic.Value(u32).init(0);
    var go = std.atomic.Value(u32).init(0);
    var racers: [writers]Racer = undefined;
    for (&racers) |*r| {
        r.* = .{ .addr = addr, .pid = pid, .ready = &ready, .go = &go };
        r.connect();
        if (r.failed) |err| return err;
    }
    defer for (&racers) |*r| {
        if (r.client) |*c| c.deinit();
    };
    var round: u32 = 1;
    while (round <= 10) : (round += 1) {
        var qbuf: [64]u8 = undefined;
        const query = try std.fmt.bufPrint(&qbuf, "CREATE (:W2 {{id: {d}}})", .{round});
        ready.store(0, .release);
        var threads: [writers]std.Thread = undefined;
        for (&racers, &threads) |*r, *t| {
            r.query = query;
            r.code = null;
            t.* = try std.Thread.spawn(.{}, Racer.run, .{ r, round });
        }
        while (ready.load(.acquire) < writers) std.atomic.spinLoopHint();
        go.store(round, .release);
        for (threads) |t| t.join();

        var wins: usize = 0;
        var refused: usize = 0;
        for (&racers) |*r| {
            if (r.failed) |err| return err;
            const code = r.code orelse return error.NoStatus;
            defer testing.allocator.free(code);
            if (std.mem.eql(u8, code, "00000")) wins += 1 else if (std.mem.eql(u8, code, "23505")) refused += 1;
        }
        try testing.expectEqual(@as(usize, 1), wins);
        try testing.expectEqual(@as(usize, writers - 1), refused);
        var cbuf: [96]u8 = undefined;
        try testing.expectEqual(@as(i64, 1), try count(&admin, try std.fmt.bufPrint(&cbuf, "MATCH (n:W2 {{id: {d}}}) RETURN count(n) AS c", .{round})));
    }
}

test "SONNY-2846: over QUIC the write fast paths cannot create a UNIQUE duplicate (group commit on); 8 concurrent writers of one value: one wins" {
    try exercise(util.TestEnv.standard(), true);
}

test "SONNY-2846: over QUIC the write fast paths cannot create a UNIQUE duplicate (group commit off, GEODE_BULK_INGEST=1)" {
    try exercise(&.{ "GEODE_GROUP_COMMIT=0", "GEODE_BULK_INGEST=1" }, false);
}
