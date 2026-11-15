// SONNY-6529 regression: a rolled-back or failed write leaves nothing behind,
// in memory, after a clean restart (shutdown checkpoint) and after a SIGKILL.
//
// graph-storage 0.4.16 `abortTxn` undoes the transaction's writes (it used to
// drop only their WAL records, leaving the pages modified and the next
// checkpoint making them durable). geode keeps its own record of a statement's
// and a transaction's changes (`statement_undo`, `txn_undo_log`) and replays
// it on ROLLBACK and on a failed statement; part of that replay used to run
// after the engine transaction had been aborted. Once the engine undoes the
// aborted transaction itself, a replay that undoes the same write a second
// time (delete a node the engine already emptied, re-create a node the engine
// already restored) must not happen, and an abort the engine cannot undo
// (`error.AbortNotUndone`) must not brick the graph silently.
//
// Every shape runs against a real `geode serve` with the periodic checkpoint
// disabled, in two modes:
//   * `program`: START TRANSACTION; <writes>; ROLLBACK in ONE request, so the
//     session's engine transaction is still open when the rollback runs;
//   * `requests`: BEGIN, the writes and ROLLBACK as separate requests (the
//     engine transaction of each request has committed by the rollback);
// plus statements that fail on their last row, in a transaction and in
// auto-commit. After every shape the test checks the shape's nodes, edges and
// properties over a second connection, then that a committed write still
// works (the graph is not refusing writes). The server is then stopped
// (SIGTERM: the shutdown checkpoint) or killed (SIGKILL: recovery from the
// WAL), restarted on the same data directory, and the same checks run again.
//
// CANARY: REQ=REQ-SONNY-6529-ABORT-UNDO; FEATURE="TransactionManagement"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6529_abort_undo.zig; OWNER=storage; UPDATED=2026-11-15

const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const util = @import("proto_test_util.zig");

/// Nodes per shape: more than the 16 shards, so a shape's writes land on
/// every shard (and on the statement transaction's shard).
const n = 20;

const QuicServer = struct {
    handle: util.ServerHandle,
    addr: []u8,

    fn start(allocator: std.mem.Allocator, data_dir: []const u8) !QuicServer {
        const port = try util.getRandomPort();
        const addr = try util.formatAddr(allocator, port);
        errdefer allocator.free(addr);
        // No periodic checkpoint: what a SIGKILL restart sees comes from the
        // WAL, and what a clean restart sees from the shutdown checkpoint.
        var handle = try util.spawnServer(
            allocator,
            &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--data-dir", data_dir },
            &.{ "GEODE_CHECKPOINT_INTERVAL_MS=86400000", "GEODE_CHECKPOINT_OPS=1000000000" },
        );
        errdefer handle.deinit();
        try util.waitForServerReady(allocator, addr, 30000);
        return .{ .handle = handle, .addr = addr };
    }

    /// SIGKILL: no clean shutdown, no checkpoint.
    fn kill(self: *QuicServer, allocator: std.mem.Allocator) void {
        self.handle.deinit();
        allocator.free(self.addr);
    }

    /// SIGTERM and wait for the server's own clean shutdown (checkpoint).
    fn stop(self: *QuicServer, allocator: std.mem.Allocator) void {
        if (self.handle.child.id) |pid| {
            std.posix.kill(pid, std.posix.SIG.TERM) catch {};
            _ = self.handle.child.wait(self.handle.threaded.io()) catch {};
            self.handle.child.id = null;
        }
        self.kill(allocator);
    }

    fn connect(self: *QuicServer, allocator: std.mem.Allocator) !util.QuicProtoClient {
        var client = try util.QuicProtoClient.connect(allocator, self.addr);
        errdefer client.deinit();
        client.watchServerLiveness(self.handle.child.id orelse return error.NoServerPid);
        var h = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
        defer h.deinit(allocator);
        if (!h.success) return error.HelloFailed;
        return client;
    }
};

const Client = util.QuicProtoClient;

fn quicOk(client: *Client, allocator: std.mem.Allocator, query: []const u8) !void {
    var r = try client.executeAndCollect(allocator, query, util.emptyParams(), 1000);
    defer r.deinit(allocator);
    if (r.error_code) |code| {
        std.debug.print("SONNY-6529 unexpected error: {s}: {s} {s}\n", .{ query, code, r.error_message orelse "" });
        return error.QueryFailed;
    }
}

/// Runs `query`, which must fail; returns its code (copied into `buf`).
fn quicFails(client: *Client, allocator: std.mem.Allocator, query: []const u8, buf: []u8) ![]const u8 {
    var r = try client.executeAndCollect(allocator, query, util.emptyParams(), 1000);
    defer r.deinit(allocator);
    const code = r.error_code orelse {
        std.debug.print("SONNY-6529 expected an error: {s}\n", .{query});
        return error.QueryDidNotFail;
    };
    const len = @min(code.len, buf.len);
    @memcpy(buf[0..len], code[0..len]);
    return buf[0..len];
}

/// One integer, or the error's code printed and `null`.
fn quicCount(client: *Client, allocator: std.mem.Allocator, query: []const u8) !?i64 {
    var r = try client.executeAndCollect(allocator, query, util.emptyParams(), 1000);
    defer r.deinit(allocator);
    if (r.error_code) |code| {
        std.debug.print("SONNY-6529 count failed: {s}: {s} {s}\n", .{ query, code, r.error_message orelse "" });
        return null;
    }
    if (r.rows.len != 1) return error.UnexpectedRows;
    return switch (r.rows[0][0]) {
        .int => |v| v,
        else => error.UnexpectedValue,
    };
}

const Shape = enum {
    /// CREATE n nodes, ROLLBACK: none.
    create,
    /// SET two properties (one existing, one new) on n nodes, ROLLBACK.
    set_prop,
    /// DETACH DELETE n nodes with a relationship each, ROLLBACK: all back.
    delete,
    /// MERGE matching n nodes (ON MATCH SET) and creating n more, ROLLBACK.
    merge,
    /// MATCH ... CREATE n relationships (with a property), ROLLBACK.
    edge_create,
    /// SET a relationship property: an existing one and the first one, ROLLBACK.
    edge_set,
    /// Add a label and remove one, ROLLBACK.
    labels,
    /// In a transaction: a SET that fails on its last row, then ROLLBACK.
    fail_set_txn,
    /// In a transaction: a MATCH ... CREATE that fails on its last row, then
    /// COMMIT (refused: the transaction failed), then ROLLBACK.
    fail_create_txn,
    /// In a transaction: one request whose first statement (CREATE and SET)
    /// succeeds and whose second fails on its last row, then ROLLBACK: the
    /// handler rolls the first back after the request's program ended.
    fail_second_txn,
    /// Auto-commit: a SET that fails on its last row.
    fail_set_auto,
    /// Auto-commit: a MATCH ... CREATE (nodes and relationships) that fails on
    /// its last row.
    fail_create_auto,
    /// Auto-commit: a relationship SET that fails on its last row.
    fail_edge_set_auto,
};

const Mode = enum { program, requests };

const Case = struct {
    shape: Shape,
    mode: Mode,

    fn prefix(self: Case, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "P{s}_{s}", .{ @tagName(self.shape), @tagName(self.mode) }) catch unreachable;
    }

    /// Auto-commit shapes have no transaction: one mode is enough.
    fn applicable(self: Case) bool {
        return switch (self.shape) {
            .fail_set_auto, .fail_create_auto, .fail_edge_set_auto => self.mode == .program,
            else => true,
        };
    }
};

const cases = blk: {
    const shapes = std.enums.values(Shape);
    var out: [shapes.len * 2]Case = undefined;
    for (shapes, 0..) |s, i| {
        out[2 * i] = .{ .shape = s, .mode = .program };
        out[2 * i + 1] = .{ .shape = s, .mode = .requests };
    }
    break :blk out;
};

fn fmt(buf: []u8, comptime f: []const u8, args: anytype) []const u8 {
    return std.fmt.bufPrint(buf, f, args) catch unreachable;
}

/// The committed state every shape starts from (and must end in):
///   n `<P>` nodes {k: i, v: 1, x: 1} labelled `<P>:<P>Old`, each with a
///   `<P>R` relationship {p: 1} to a `<P>d` node {k: i}, and a second,
///   property-less `<P>Q` relationship to the same node.
fn setup(client: *Client, allocator: std.mem.Allocator, c: Case) !void {
    var pb: [64]u8 = undefined;
    const p = c.prefix(&pb);
    var s: std.ArrayList(u8) = .empty;
    defer s.deinit(allocator);
    try s.appendSlice(allocator, "CREATE ");
    for (0..n) |i| {
        if (i > 0) try s.appendSlice(allocator, ", ");
        try s.print(allocator, "(a{d}:{s}:{s}Old {{k: {d}, v: 1, x: 1}})-[:{s}R {{p: 1}}]->(b{d}:{s}d {{k: {d}}}), (a{d})-[:{s}Q]->(b{d})", .{ i, p, p, i, p, i, p, i, i, p, i });
    }
    try quicOk(client, allocator, s.items);
}

/// The writes a shape rolls back, one statement each.
fn writes(buf: *[4][512]u8, c: Case) []const []const u8 {
    var pb: [64]u8 = undefined;
    const p = c.prefix(&pb);
    const S = struct {
        var out: [4][]const u8 = undefined;
    };
    var len: usize = 0;
    switch (c.shape) {
        .create => {
            S.out[0] = fmt(&buf[0], "FOR i IN [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19, 20] CREATE (:{s} {{k: 100 + i, v: 2}})-[:{s}R {{p: 9}}]->(:{s}d {{k: 100 + i}})", .{ p, p, p });
            len = 1;
        },
        .set_prop => {
            S.out[0] = fmt(&buf[0], "MATCH (a:{s}) SET a.v = 2, a.w = 3", .{p});
            S.out[1] = fmt(&buf[1], "MATCH (a:{s}) REMOVE a.x", .{p});
            len = 2;
        },
        .delete => {
            S.out[0] = fmt(&buf[0], "MATCH (a:{s}) DETACH DELETE a", .{p});
            len = 1;
        },
        .merge => {
            S.out[0] = fmt(&buf[0], "FOR i IN [0, 1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17, 18, 19] MERGE (a:{s} {{k: i}}) ON MATCH SET a.m = 1", .{p});
            S.out[1] = fmt(&buf[1], "FOR i IN [20, 21, 22, 23, 24, 25, 26, 27, 28, 29, 30, 31, 32, 33, 34, 35, 36, 37, 38, 39] MERGE (a:{s} {{k: i}}) ON CREATE SET a.v = 1", .{p});
            len = 2;
        },
        .edge_create => {
            S.out[0] = fmt(&buf[0], "MATCH (a:{s}), (b:{s}d) WHERE a.k = b.k CREATE (a)-[:{s}N {{p: 1}}]->(b)", .{ p, p, p });
            len = 1;
        },
        .edge_set => {
            S.out[0] = fmt(&buf[0], "MATCH (:{s})-[e:{s}R]->() SET e.p = 2, e.q = 3", .{ p, p });
            S.out[1] = fmt(&buf[1], "MATCH (:{s})-[e:{s}Q]->() SET e.p = 7", .{ p, p });
            len = 2;
        },
        .labels => {
            S.out[0] = fmt(&buf[0], "MATCH (a:{s}) SET a:{s}New", .{ p, p });
            S.out[1] = fmt(&buf[1], "MATCH (a:{s}) REMOVE a:{s}Old", .{ p, p });
            len = 2;
        },
        .fail_set_txn, .fail_set_auto => {
            S.out[0] = fmt(&buf[0], "MATCH (a:{s}) SET a.v = 2, a.w = CASE WHEN a.k = {d} THEN 1 / 0 ELSE 1 END", .{ p, n - 1 });
            len = 1;
        },
        .fail_create_txn, .fail_create_auto => {
            S.out[0] = fmt(&buf[0], "MATCH (a:{s}) CREATE (a)-[:{s}N {{p: 1}}]->(:{s}x {{k: a.k, w: CASE WHEN a.k = {d} THEN 1 / 0 ELSE 1 END}})", .{ p, p, p, n - 1 });
            len = 1;
        },
        .fail_edge_set_auto => {
            S.out[0] = fmt(&buf[0], "MATCH (a:{s})-[e:{s}R]->() SET e.p = 2, e.q = CASE WHEN a.k = {d} THEN 1 / 0 ELSE 1 END", .{ p, p, n - 1 });
            len = 1;
        },
        .fail_second_txn => {
            S.out[0] = fmt(&buf[0], "MATCH (a:{s}) SET a.v = 2 CREATE (a)-[:{s}N {{p: 1}}]->(:{s}x {{k: a.k}})", .{ p, p, p });
            S.out[1] = fmt(&buf[1], "MATCH (a:{s}) SET a.w = CASE WHEN a.k = {d} THEN 1 / 0 ELSE 1 END", .{ p, n - 1 });
            len = 2;
        },
    }
    return S.out[0..len];
}

fn failing(c: Case) bool {
    return switch (c.shape) {
        .fail_set_txn, .fail_create_txn, .fail_second_txn, .fail_set_auto, .fail_create_auto, .fail_edge_set_auto => true,
        else => false,
    };
}

fn autocommit(c: Case) bool {
    return switch (c.shape) {
        .fail_set_auto, .fail_create_auto, .fail_edge_set_auto => true,
        else => false,
    };
}

/// Run a shape's writes and roll them back (or let them fail).
fn run(client: *Client, allocator: std.mem.Allocator, c: Case) !void {
    var bufs: [4][512]u8 = undefined;
    const stmts = writes(&bufs, c);
    var code_buf: [16]u8 = undefined;
    if (autocommit(c)) {
        for (stmts) |s| _ = try quicFails(client, allocator, s, &code_buf);
        return;
    }
    switch (c.mode) {
        .program => {
            // geode refuses BEGIN ... ROLLBACK with mutations in one batch
            // (25001), so the batch ends with a statement that fails on its
            // last row instead: the executor rolls the transaction back in
            // the same request, with the session's engine transaction open.
            var pb: [64]u8 = undefined;
            const p = c.prefix(&pb);
            var prog: std.ArrayList(u8) = .empty;
            defer prog.deinit(allocator);
            try prog.appendSlice(allocator, "START TRANSACTION; ");
            for (stmts) |s| try prog.print(allocator, "{s}; ", .{s});
            try prog.print(allocator, "MATCH (z:{s}d) SET z.zz = CASE WHEN z.k = {d} THEN 1 / 0 ELSE 1 END", .{ p, n - 1 });
            _ = try quicFails(client, allocator, prog.items, &code_buf);
            // End the failed transaction (a no-op when the server ended it).
            _ = client.rollback(allocator) catch false;
        },
        .requests => {
            var b = try client.begin(allocator);
            b.deinit(allocator);
            if (c.shape == .fail_second_txn) {
                var prog: std.ArrayList(u8) = .empty;
                defer prog.deinit(allocator);
                try prog.print(allocator, "{s}; {s}", .{ stmts[0], stmts[1] });
                _ = try quicFails(client, allocator, prog.items, &code_buf);
                _ = client.rollback(allocator) catch false;
                return;
            }
            for (stmts) |s| {
                if (failing(c)) {
                    _ = try quicFails(client, allocator, s, &code_buf);
                } else try quicOk(client, allocator, s);
            }
            if (c.shape == .fail_create_txn) {
                // COMMIT of a failed transaction is refused; the rollback
                // then ends it.
                _ = client.commit(allocator) catch false;
            }
            _ = try client.rollback(allocator);
        },
    }
}

const Check = struct {
    what: []const u8,
    query: []const u8,
    want: i64,
};

/// What every shape's namespace must hold: exactly the setup state.
fn checks(bufs: *[12][320]u8, c: Case) [12]Check {
    var pb: [64]u8 = undefined;
    const p = c.prefix(&pb);
    return .{
        .{ .what = "nodes", .query = fmt(&bufs[0], "MATCH (a:{s}) RETURN count(a) AS c", .{p}), .want = n },
        .{ .what = "targets", .query = fmt(&bufs[1], "MATCH (b:{s}d) WHERE b.zz IS NULL RETURN count(b) AS c", .{p}), .want = n },
        .{ .what = "v=1,x=1,no w/m", .query = fmt(&bufs[2], "MATCH (a:{s}) WHERE a.v = 1 AND a.x = 1 AND a.w IS NULL AND a.m IS NULL RETURN count(a) AS c", .{p}), .want = n },
        .{ .what = "old label", .query = fmt(&bufs[3], "MATCH (a:{s}Old) RETURN count(a) AS c", .{p}), .want = n },
        .{ .what = "new label", .query = fmt(&bufs[4], "MATCH (a:{s}New) RETURN count(a) AS c", .{p}), .want = 0 },
        .{ .what = "R p=1 out", .query = fmt(&bufs[5], "MATCH (:{s})-[e:{s}R]->(:{s}d) WHERE e.p = 1 AND e.q IS NULL RETURN count(e) AS c", .{ p, p, p }), .want = n },
        .{ .what = "R p=1 in", .query = fmt(&bufs[6], "MATCH (:{s}d)<-[e:{s}R]-(:{s}) WHERE e.p = 1 AND e.q IS NULL RETURN count(e) AS c", .{ p, p, p }), .want = n },
        .{ .what = "Q no props", .query = fmt(&bufs[7], "MATCH (:{s})-[e:{s}Q]->() WHERE e.p IS NULL RETURN count(e) AS c", .{ p, p }), .want = n },
        .{ .what = "rels of type", .query = fmt(&bufs[8], "MATCH ()-[e]->() WHERE type(e) IN ['{s}R', '{s}Q', '{s}N'] RETURN count(e) AS c", .{ p, p, p }), .want = 2 * n },
        .{ .what = "created x", .query = fmt(&bufs[9], "MATCH (x:{s}x) RETURN count(x) AS c", .{p}), .want = 0 },
        .{ .what = "k range", .query = fmt(&bufs[10], "MATCH (a:{s}) WHERE a.k >= 0 AND a.k < {d} RETURN count(a) AS c", .{ p, n }), .want = n },
        .{ .what = "unlabeled k", .query = fmt(&bufs[11], "MATCH (a) WHERE a.k >= 100 AND a.k < 200 AND (a:{s} OR a:{s}d) RETURN count(a) AS c", .{ p, p }), .want = 0 },
    };
}

/// Counts every wrong (case, check); `when` names the phase in the output.
fn verify(client: *Client, allocator: std.mem.Allocator, when: []const u8) !usize {
    var wrong: usize = 0;
    for (cases) |c| {
        if (!c.applicable()) continue;
        var bufs: [12][320]u8 = undefined;
        for (checks(&bufs, c)) |ck| {
            const got = try quicCount(client, allocator, ck.query);
            const ok = got != null and got.? == ck.want;
            if (!ok) {
                wrong += 1;
                std.debug.print("SONNY-6529 {s:<14} {s:<18} {s:<8} {s:<15}: got {?d}, want {d}  <-- WRONG\n", .{ when, @tagName(c.shape), @tagName(c.mode), ck.what, got, ck.want });
            }
        }
    }
    // The graph still takes (and keeps) committed writes.
    const alive = try quicCount(client, allocator, "MATCH (z:Alive) RETURN count(z) AS c");
    std.debug.print("SONNY-6529 {s:<14} {d} wrong check(s); Alive nodes: {?d}\n", .{ when, wrong, alive });
    return wrong;
}

const End = enum { checkpoint, sigkill };

/// Every shape, then the end (`checkpoint`: SIGTERM, `sigkill`), then a
/// restart. Returns the number of wrong checks over the three phases.
fn matrix(allocator: std.mem.Allocator, end: End) !usize {
    const io_fs = std.Io.Threaded.global_single_threaded.io();
    var dir_buf: [96]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&dir_buf, "/tmp/geode-sonny6529-{d}", .{try util.getRandomPort()});
    std.Io.Dir.cwd().createDirPath(io_fs, data_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io_fs, data_dir) catch {};

    var wrong: usize = 0;
    {
        var server = try QuicServer.start(allocator, data_dir);
        var stopped = false;
        defer if (!stopped) server.kill(allocator);
        {
            var client = try server.connect(allocator);
            defer client.deinit();
            try quicOk(&client, allocator, "CREATE GRAPH s6529");
            try quicOk(&client, allocator, "USE GRAPH s6529");
            for (cases) |c| if (c.applicable()) try setup(&client, allocator, c);
            for (cases) |c| if (c.applicable()) try run(&client, allocator, c);

            // Another connection sees exactly the setup state.
            var other = try server.connect(allocator);
            defer other.deinit();
            try quicOk(&other, allocator, "USE GRAPH s6529");
            wrong += try verify(&other, allocator, "in memory");
            // The graph still takes committed writes on every shard.
            var cb: [512]u8 = undefined;
            const alive = fmt(&cb, "FOR i IN [1, 2, 3, 4, 5, 6, 7, 8, 9, 10, 11, 12, 13, 14, 15, 16, 17] CREATE (:Alive {{i: i}})", .{});
            var r = try client.executeAndCollect(allocator, alive, util.emptyParams(), 1000);
            defer r.deinit(allocator);
            if (r.error_code) |code| {
                std.debug.print("SONNY-6529 a committed write after the aborts failed: {s} {s}  <-- WRONG\n", .{ code, r.error_message orelse "" });
                wrong += 1;
            }
        }
        switch (end) {
            .checkpoint => {
                server.stop(allocator);
                stopped = true;
            },
            .sigkill => {},
        }
    }

    var server = try QuicServer.start(allocator, data_dir);
    defer server.kill(allocator);
    var client = try server.connect(allocator);
    defer client.deinit();
    try quicOk(&client, allocator, "USE GRAPH s6529");
    wrong += try verify(&client, allocator, if (end == .checkpoint) "after restart" else "after SIGKILL");
    const alive = try quicCount(&client, allocator, "MATCH (z:Alive) RETURN count(z) AS c");
    if (alive == null or alive.? != 17) {
        std.debug.print("SONNY-6529 the committed write after the aborts: {?d} Alive nodes after the restart, want 17  <-- WRONG\n", .{alive});
        wrong += 1;
    }
    return wrong;
}

test "SONNY-6529: rolled-back and failed writes leave nothing, in memory and after a clean restart" {
    if (try matrix(testing.allocator, .checkpoint) > 0) return error.AbortedWritesLeftResidue;
}

test "SONNY-6529: rolled-back and failed writes leave nothing after a SIGKILL restart" {
    if (try matrix(testing.allocator, .sigkill) > 0) return error.AbortedWritesLeftResidue;
}
