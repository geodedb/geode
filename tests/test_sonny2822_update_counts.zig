// SONNY-2822: a client can tell how many rows a write statement changed.
//
// The report: drivers' RowsAffected() was always 0 for `MATCH ... SET`,
// DELETE and a CREATE with no RETURN, although the write was applied. The
// wire protocol had no field for a statement's update counts
// (`ExecutionMetrics` carries durations only): a CREATE or DELETE with no
// RETURN answers no row, a MATCH ... SET answers the matched nodes, and only
// MATCH ... CREATE answered an ad-hoc `nodes_created` /
// `relationships_created` summary row.
//
// The contract: the final DataPage of a statement's result carries
// `update_counts` (nodes_created, nodes_deleted, relationships_created,
// relationships_deleted, properties_set, labels_added, labels_removed),
// counted where the writes are made (the statement undo record's write hooks,
// and the QUIC write fast paths that skip it), never inferred from rows:
//   * `MATCH ... SET` over N rows sets N x (properties assigned);
//   * a statement that matches no row, and a pure read, report all zeros
//     (and still report them, so a client can tell a new server from an old);
//   * a failed statement, and a transaction body a ROLLBACK undid, report
//     nothing they did not commit;
//   * MATCH ... CREATE keeps its summary row for old clients.
//
// A real `geode serve` with a QUIC and a plaintext gRPC listener. Every case
// runs on both transports, on its own labels: QUIC serves the no-RETURN
// CREATE, MERGE, `/*+BATCH*/` MERGE and the key-resolved edge writes by its
// write fast paths (`quic_connection_handler.zig`), gRPC by the executor, so
// the two must agree. The point-write fast path (`pointWriteFastPath`, an
// exact-index `MATCH ... WHERE n.k = 'lit' SET`) is inside the executor, on
// both.
//
// CANARY: REQ=REQ-SONNY-2822-UPDATE-COUNTS; FEATURE="WireProtocol"; ASPECT=UpdateCountsWireMatrix; STATUS=TESTED; TEST=tests/test_sonny2822_update_counts.zig; OWNER=transport; UPDATED=2026-11-22

const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const util = @import("proto_test_util.zig");

fn io() std.Io {
    return std.Io.Threaded.global_single_threaded.io();
}

const Transport = enum { quic, grpc };

/// The counts a statement must report.
const Counts = struct {
    nodes_created: u64 = 0,
    nodes_deleted: u64 = 0,
    relationships_created: u64 = 0,
    relationships_deleted: u64 = 0,
    properties_set: u64 = 0,
    labels_added: u64 = 0,
    labels_removed: u64 = 0,
};

/// The counts `r` carries; error.UpdateCountsNotOnWire when the client cannot
/// decode any (the protocol has no such field), error.NoUpdateCounts when the
/// server sent none.
fn countsOf(r: *const util.ExecResult) !Counts {
    if (comptime @hasField(util.ExecResult, "update_counts")) {
        const got = r.update_counts orelse return error.NoUpdateCounts;
        var out: Counts = .{};
        inline for (@typeInfo(Counts).@"struct".fields) |f| @field(out, f.name) = @field(got, f.name);
        return out;
    } else {
        return error.UpdateCountsNotOnWire;
    }
}

const Server = struct {
    handle: util.ServerHandle,
    quic_addr: []u8,
    grpc_addr: []u8,

    fn start(allocator: std.mem.Allocator, data_dir: []const u8, log_path: []const u8) !Server {
        const quic_port = try util.getRandomPort();
        var grpc_port = try util.getRandomTcpPort();
        while (grpc_port == quic_port) grpc_port = try util.getRandomTcpPort();
        const quic_addr = try util.formatAddr(allocator, quic_port);
        errdefer allocator.free(quic_addr);
        const grpc_addr = try util.formatAddr(allocator, grpc_port);
        errdefer allocator.free(grpc_addr);
        const cmd = try std.fmt.allocPrint(allocator, "exec '{s}' serve --listen {s} --listen-grpc {s} --data-dir '{s}' 2>>'{s}'", .{ geode_test_bin.geode_exe, quic_addr, grpc_addr, data_dir, log_path });
        defer allocator.free(cmd);
        var handle = try util.spawnServer(allocator, &.{ "/bin/sh", "-c", cmd, "--data-dir" }, util.TestEnv.grpcPlaintext());
        errdefer handle.deinit();
        try util.waitForServerReady(allocator, quic_addr, 30000);
        return .{ .handle = handle, .quic_addr = quic_addr, .grpc_addr = grpc_addr };
    }

    fn deinit(self: *Server, allocator: std.mem.Allocator) void {
        self.handle.deinit();
        allocator.free(self.quic_addr);
        allocator.free(self.grpc_addr);
    }
};

/// The gRPC test client sends every Execute on HTTP/2 stream 3, so it runs
/// one Execute per connection; the session outlives the connection.
const Client = union(Transport) {
    quic: util.QuicProtoClient,
    grpc: struct { allocator: std.mem.Allocator, addr: []const u8, session_id: []u8 },

    fn connect(allocator: std.mem.Allocator, server: *Server, t: Transport) !Client {
        switch (t) {
            .quic => {
                var c = try util.QuicProtoClient.connect(allocator, server.quic_addr);
                errdefer c.deinit();
                c.watchServerLiveness(server.handle.child.id orelse return error.NoServerPid);
                var h = try c.hello(allocator, util.defaultUsername(), util.defaultPassword());
                defer h.deinit(allocator);
                if (!h.success) return error.HelloFailed;
                return .{ .quic = c };
            },
            .grpc => {
                var c = try util.GrpcProtoClient.connect(allocator, server.grpc_addr);
                defer c.deinit();
                var h = try c.hello(allocator, util.defaultUsername(), util.defaultPassword());
                defer h.deinit(allocator);
                if (!h.success) return error.HelloFailed;
                return .{ .grpc = .{ .allocator = allocator, .addr = server.grpc_addr, .session_id = try allocator.dupe(u8, c.session_id) } };
            },
        }
    }

    fn deinit(self: *Client) void {
        switch (self.*) {
            .quic => |*c| c.deinit(),
            .grpc => |*s| s.allocator.free(s.session_id),
        }
    }

    fn exec(self: *Client, allocator: std.mem.Allocator, q: []const u8) !util.ExecResult {
        switch (self.*) {
            .quic => |*c| return c.executeAndCollect(allocator, q, util.emptyParams(), 1000),
            .grpc => |*s| {
                var c = try util.GrpcProtoClient.connect(allocator, s.addr);
                defer c.deinit();
                c.session_id = try allocator.dupe(u8, s.session_id);
                return c.executeAndCollect(allocator, q, util.emptyParams(), 1000);
            },
        }
    }
};

/// One statement and the counts it must report. "{s}" in `query` is the
/// transport's label suffix. `rows` is the number of result rows it must
/// answer (null: not checked). `fails`: it must be refused, with no counts.
const Step = struct {
    query: []const u8,
    want: Counts = .{},
    rows: ?usize = null,
    fails: bool = false,
};

const Case = struct {
    name: []const u8,
    steps: []const Step,
};

const cases = [_]Case{
    .{ .name = "executor CREATE with RETURN", .steps = &.{
        .{ .query = "CREATE (n:Ca{s} {a: 1, b: 2}) RETURN n.a AS a", .want = .{ .nodes_created = 1, .labels_added = 1, .properties_set = 2 }, .rows = 1 },
    } },
    .{ .name = "CREATE with no RETURN (QUIC: simple-create fast path)", .steps = &.{
        .{ .query = "CREATE (:Cb{s} {a: 1, b: 'x'})", .want = .{ .nodes_created = 1, .labels_added = 1, .properties_set = 2 }, .rows = 0 },
    } },
    .{ .name = "CREATE of two nodes and a relationship, no RETURN", .steps = &.{
        .{ .query = "CREATE (:Cc{s} {k: 1})-[:Tc{s} {w: 5}]->(:Cc{s}:Xc{s} {k: 2})", .want = .{ .nodes_created = 2, .relationships_created = 1, .labels_added = 3, .properties_set = 3 }, .rows = 0 },
    } },
    .{ .name = "MATCH ... SET over 3 rows, 2 properties each", .steps = &.{
        .{ .query = "CREATE (:S{s} {g: 1}), (:S{s} {g: 1}), (:S{s} {g: 1}), (:S{s} {g: 2})", .want = .{ .nodes_created = 4, .labels_added = 4, .properties_set = 4 } },
        .{ .query = "MATCH (n:S{s}) WHERE n.g = 1 SET n.x = 1, n.y = 2", .want = .{ .properties_set = 6 } },
        .{ .query = "MATCH (n:S{s}) WHERE n.g = 1 SET n:Lab{s}", .want = .{ .labels_added = 3 } },
        .{ .query = "MATCH (n:S{s}) WHERE n.g = 1 REMOVE n:Lab{s}, n.y", .want = .{ .labels_removed = 3, .properties_set = 3 } },
    } },
    .{ .name = "MATCH ... SET matching no row", .steps = &.{
        .{ .query = "CREATE (:Z{s} {g: 1})", .want = .{ .nodes_created = 1, .labels_added = 1, .properties_set = 1 } },
        .{ .query = "MATCH (n:Z{s}) WHERE n.g = 999 SET n.x = 1", .want = .{}, .rows = 0 },
    } },
    .{ .name = "point-write fast path (exact-index MATCH ... SET)", .steps = &.{
        .{ .query = "CREATE (:P{s} {key: 'p1'}), (:P{s} {key: 'p2'})", .want = .{ .nodes_created = 2, .labels_added = 2, .properties_set = 2 } },
        .{ .query = "MATCH (n:P{s}) WHERE n.key = 'p1' SET n.v = 'one', n.w = 'two'", .want = .{ .properties_set = 2 }, .rows = 1 },
        .{ .query = "MATCH (n:P{s}) WHERE n.key = 'nope' SET n.v = 'one'", .want = .{}, .rows = 0 },
    } },
    .{ .name = "DETACH DELETE", .steps = &.{
        .{ .query = "CREATE (a:D{s} {i: 1})-[:Td{s}]->(b:D{s} {i: 2})-[:Td{s}]->(c:D{s} {i: 3})", .want = .{ .nodes_created = 3, .relationships_created = 2, .labels_added = 3, .properties_set = 3 } },
        .{ .query = "MATCH (n:D{s}) DETACH DELETE n", .want = .{ .nodes_deleted = 3, .relationships_deleted = 2 }, .rows = 0 },
        .{ .query = "MATCH (n:D{s}) RETURN n", .want = .{}, .rows = 0 },
    } },
    .{ .name = "DELETE of a relationship", .steps = &.{
        .{ .query = "CREATE (:Dr{s})-[:Tr{s}]->(:Dr{s})", .want = .{ .nodes_created = 2, .relationships_created = 1, .labels_added = 2 } },
        .{ .query = "MATCH (:Dr{s})-[r:Tr{s}]->(:Dr{s}) DELETE r", .want = .{ .relationships_deleted = 1 }, .rows = 0 },
    } },
    .{ .name = "executor MERGE: create, then match", .steps = &.{
        .{ .query = "MERGE (n:Me{s} {k: 1}) RETURN n.k AS k", .want = .{ .nodes_created = 1, .labels_added = 1, .properties_set = 1 }, .rows = 1 },
        .{ .query = "MERGE (n:Me{s} {k: 1}) RETURN n.k AS k", .want = .{}, .rows = 1 },
    } },
    .{ .name = "MERGE with no RETURN (QUIC: bulk MERGE fast path): create, then match", .steps = &.{
        .{ .query = "MERGE (:Mf{s} {k: 1})", .want = .{ .nodes_created = 1, .labels_added = 1, .properties_set = 1 }, .rows = 0 },
        .{ .query = "MERGE (:Mf{s} {k: 1})", .want = .{}, .rows = 0 },
        .{ .query = "MERGE (n:Mf{s} {k: 2}) ON CREATE SET n.a = 5", .want = .{ .nodes_created = 1, .labels_added = 1, .properties_set = 2 }, .rows = 0 },
        .{ .query = "MERGE (n:Mf{s} {k: 2}) ON CREATE SET n.a = 5", .want = .{}, .rows = 0 },
        .{ .query = "MATCH (n:Mf{s}) RETURN n.k AS k", .rows = 2 },
    } },
    .{ .name = "MERGE ... SET with no RETURN (QUIC: bulk MERGE upsert): create, then match", .steps = &.{
        .{ .query = "MERGE (n:Ms{s} {k: 1}) SET n.a = 1", .want = .{ .nodes_created = 1, .labels_added = 1, .properties_set = 2 }, .rows = 0 },
        .{ .query = "MERGE (n:Ms{s} {k: 1}) SET n.a = 2", .want = .{ .properties_set = 1 }, .rows = 0 },
        .{ .query = "MATCH (n:Ms{s}) WHERE n.a = 2 RETURN n.k AS k", .rows = 1 },
    } },
    .{ .name = "/*+BATCH*/ MERGE (QUIC: batch MERGE fast path): create, then match", .steps = &.{
        .{ .query = "/*+BATCH*/ MERGE (:B{s} {k: 1}); MERGE (:B{s} {k: 2}); MERGE (:B{s} {k: 3})", .want = .{ .nodes_created = 3, .labels_added = 3, .properties_set = 3 }, .rows = 0 },
        .{ .query = "/*+BATCH*/ MERGE (:B{s} {k: 1}); MERGE (:B{s} {k: 4})", .want = .{ .nodes_created = 1, .labels_added = 1, .properties_set = 1 }, .rows = 0 },
        .{ .query = "MATCH (n:B{s}) RETURN n.k AS k", .rows = 4 },
    } },
    .{
        .name = "MATCH ... CREATE / MERGE a relationship between keyed nodes (QUIC: edge fast paths)",
        .steps = &.{
            .{ .query = "CREATE (:E{s} {node_id: 1}), (:E{s} {node_id: 2})", .want = .{ .nodes_created = 2, .labels_added = 2, .properties_set = 2 } },
            // The summary row old clients read stays.
            .{ .query = "MATCH (a:E{s} {node_id: 1}), (b:E{s} {node_id: 2}) CREATE (a)-[:Te{s} {w: 1}]->(b)", .want = .{ .relationships_created = 1, .properties_set = 1 }, .rows = 1 },
            .{ .query = "MATCH (a:E{s} {node_id: 1}), (b:E{s} {node_id: 2}) MERGE (a)-[:Tm{s}]->(b)", .want = .{ .relationships_created = 1 }, .rows = 0 },
            .{ .query = "MATCH (a:E{s} {node_id: 1}), (b:E{s} {node_id: 2}) MERGE (a)-[:Tm{s}]->(b)", .want = .{}, .rows = 0 },
            .{ .query = "MATCH (a:E{s} {node_id: 1}), (b:E{s} {node_id: 99}) CREATE (a)-[:Te{s}]->(b)", .want = .{} },
            .{ .query = "MATCH (:E{s})-[r]->(:E{s}) RETURN r", .rows = 2 },
        },
    },
    .{ .name = "pure reads", .steps = &.{
        .{ .query = "RETURN 1 AS x", .want = .{}, .rows = 1 },
        .{ .query = "MATCH (n:S{s}) RETURN n.g AS g", .want = .{}, .rows = 4 },
        .{ .query = "MATCH (n:S{s}) RETURN count(n) AS c", .want = .{}, .rows = 1 },
    } },
    .{ .name = "a failed statement reports nothing and is undone", .steps = &.{
        .{ .query = "CREATE (:F{s} {a: 1})", .want = .{ .nodes_created = 1, .labels_added = 1, .properties_set = 1 } },
        .{ .query = "MATCH (n:F{s}) SET n.b = 2 RETURN n.a IN 5 AS bad", .fails = true },
        .{ .query = "MATCH (n:F{s}) WHERE n.b = 2 RETURN n", .want = .{}, .rows = 0 },
    } },
    .{ .name = "a program whose transaction is rolled back reports nothing", .steps = &.{
        .{ .query = "START TRANSACTION; CREATE (:Tx{s} {a: 1}); ROLLBACK", .want = .{} },
        .{ .query = "MATCH (n:Tx{s}) RETURN n", .want = .{}, .rows = 0 },
        .{ .query = "START TRANSACTION; CREATE (:Tx{s} {a: 1}); CREATE (:Tx{s} {a: 2}); COMMIT", .want = .{ .nodes_created = 2, .labels_added = 2, .properties_set = 2 } },
        .{ .query = "MATCH (n:Tx{s}) RETURN n", .want = .{}, .rows = 2 },
    } },
};

fn expand(allocator: std.mem.Allocator, template: []const u8, suffix: []const u8) ![]u8 {
    return std.mem.replaceOwned(u8, allocator, template, "{s}", suffix);
}

/// Runs every case on `t`; the number of steps that failed.
fn runTransport(allocator: std.mem.Allocator, server: *Server, t: Transport) !usize {
    var client = try Client.connect(allocator, server, t);
    defer client.deinit();
    const suffix = switch (t) {
        .quic => "q",
        .grpc => "g",
    };
    var failed: usize = 0;
    for (cases) |case| {
        for (case.steps) |step| {
            const q = try expand(allocator, step.query, suffix);
            defer allocator.free(q);
            var r = try client.exec(allocator, q);
            defer r.deinit(allocator);
            if (step.fails) {
                if (r.error_code == null) {
                    std.debug.print("SONNY-2822 | {s:<4} | {s}: `{s}` was not refused\n", .{ @tagName(t), case.name, q });
                    failed += 1;
                    continue;
                }
                if (countsOf(&r)) |c| {
                    std.debug.print("SONNY-2822 | {s:<4} | {s}: `{s}` was refused ({s}) but reported counts {any}\n", .{ @tagName(t), case.name, q, r.error_code.?, c });
                    failed += 1;
                } else |_| {}
                continue;
            }
            if (r.error_code) |code| {
                std.debug.print("SONNY-2822 | {s:<4} | {s}: `{s}` failed: {s} {s}\n", .{ @tagName(t), case.name, q, code, r.error_message orelse "" });
                failed += 1;
                continue;
            }
            if (step.rows) |want_rows| {
                if (r.rows.len != want_rows) {
                    std.debug.print("SONNY-2822 | {s:<4} | {s}: `{s}` answered {d} row(s), want {d}\n", .{ @tagName(t), case.name, q, r.rows.len, want_rows });
                    failed += 1;
                    continue;
                }
            }
            const got = countsOf(&r) catch |err| {
                std.debug.print("SONNY-2822 | {s:<4} | {s}: `{s}`: {s}\n", .{ @tagName(t), case.name, q, @errorName(err) });
                failed += 1;
                continue;
            };
            if (!std.meta.eql(got, step.want)) {
                std.debug.print("SONNY-2822 | {s:<4} | {s}: `{s}`\n    got  {any}\n    want {any}\n", .{ @tagName(t), case.name, q, got, step.want });
                failed += 1;
            }
        }
    }
    return failed;
}

/// The MATCH ... CREATE summary row is still sent beside the counts.
fn checkSummaryRow(allocator: std.mem.Allocator, server: *Server, t: Transport) !void {
    var client = try Client.connect(allocator, server, t);
    defer client.deinit();
    const suffix = switch (t) {
        .quic => "q",
        .grpc => "g",
    };
    const q = try expand(allocator, "MATCH (a:E{s} {node_id: 1}), (b:E{s} {node_id: 2}) CREATE (a)-[:Tsum{s}]->(b)", suffix);
    defer allocator.free(q);
    var r = try client.exec(allocator, q);
    defer r.deinit(allocator);
    if (r.error_code) |code| {
        std.debug.print("SONNY-2822 | {s:<4} | summary row: {s} {s}\n", .{ @tagName(t), code, r.error_message orelse "" });
        return error.QueryFailed;
    }
    try testing.expectEqual(@as(usize, 2), r.columns.len);
    try testing.expectEqualStrings("nodes_created", r.columns[0]);
    try testing.expectEqualStrings("relationships_created", r.columns[1]);
    try testing.expectEqual(@as(usize, 1), r.rows.len);
    try testing.expect(util.testValueEqual(r.rows[0][0], .{ .int = 0 }));
    try testing.expect(util.testValueEqual(r.rows[0][1], .{ .int = 1 }));
}

test "SONNY-2822: every write path reports its update counts on QUIC and gRPC" {
    const allocator = testing.allocator;
    const port = try util.getRandomPort();
    const data_dir = try std.fmt.allocPrint(allocator, "/tmp/geode-sonny2822-{d}", .{port});
    defer allocator.free(data_dir);
    const log_path = try std.fmt.allocPrint(allocator, "{s}.server.log", .{data_dir});
    defer allocator.free(log_path);
    try std.Io.Dir.cwd().createDirPath(io(), data_dir);
    defer std.Io.Dir.cwd().deleteTree(io(), data_dir) catch {};
    var keep_log = false;
    defer if (!keep_log) std.Io.Dir.cwd().deleteFile(io(), log_path) catch {};
    errdefer {
        keep_log = true;
        std.debug.print("SONNY-2822: server log kept: {s}\n", .{log_path});
    }

    var server = try Server.start(allocator, data_dir, log_path);
    defer server.deinit(allocator);

    var failed: usize = 0;
    for ([_]Transport{ .quic, .grpc }) |t| {
        if (t == .grpc and !util.grpc_plaintext_served) {
            std.debug.print("SONNY-2822: gRPC skipped (plaintext gRPC is served by Debug builds only)\n", .{});
            continue;
        }
        const n = try runTransport(allocator, &server, t);
        std.debug.print("SONNY-2822 | {s:<4} | {d} step(s) failed\n", .{ @tagName(t), n });
        failed += n;
        try checkSummaryRow(allocator, &server, t);
    }
    try testing.expectEqual(@as(usize, 0), failed);
}
