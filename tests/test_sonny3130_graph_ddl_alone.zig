// SONNY-3130 regression: a program that creates, replaces or drops a graph
// carries no statement on graph data.
//
// The handlers take the lock of the graph a program runs on before they run
// it (SONNY-2749), and CREATE and DROP GRAPH count as statements on the graph
// they name (SONNY-3028). So `CREATE OR REPLACE GRAPH g; USE GRAPH g;
// CREATE (:R)` and `DROP GRAPH g; CREATE GRAPH g; USE GRAPH g; CREATE (:R)`
// were one program on g: the handler held the OLD graph's write lock, the
// executor dropped and re-created g, and the write landed in the NEW graph
// without its lock, beside that graph's own writers (review probe R12-V6: the
// write finished while another thread held the new graph's exclusive lock).
// From a session on g, `DROP GRAPH g; CREATE (:R2)` answered ok and re-created
// g (R12-V6b).
//
// Now the handlers refuse (0A000) a program that creates, replaces or drops a
// graph and also has a statement on graph data, on any graph, before or
// after the graph DDL. Graph DDL runs with other graph DDL, graph selection,
// session statements and transaction control only, so the idiom
// `DROP GRAPH IF EXISTS g; CREATE GRAPH g` still runs. gRPC in process, and
// QUIC against a spawned server.
//
// CANARY: REQ=REQ-SONNY-3130-GRAPH-DDL-ALONE; FEATURE="MultiGraphIsolation"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3130_graph_ddl_alone.zig; OWNER=storage; UPDATED=2026-09-27

const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const geode = @import("geode");
const util = @import("proto_test_util.zig");
const fx = @import("sonny738_r12_grpc_fixture.zig");

const graph_store = geode.graph_store;

/// The programs that mix graph DDL with a statement on graph data. Each is
/// run from a session on `g6`, which exists.
const mixed = [_][]const u8{
    // R12-V6: replace, or drop and create, then write the new graph.
    "CREATE OR REPLACE GRAPH g6; USE GRAPH g6; CREATE (:R {v: 1})",
    "DROP GRAPH g6; CREATE GRAPH g6; USE GRAPH g6; CREATE (:R {v: 1})",
    // R12-V6b: the session's own graph, named by the DDL only.
    "DROP GRAPH g6; CREATE (:R {v: 1})",
    "CREATE OR REPLACE GRAPH g6; CREATE (:R {v: 1})",
    "CREATE OR REPLACE GRAPH g6; MATCH (n) RETURN n",
    // Data first, then the DDL.
    "CREATE (:R {v: 1}); DROP GRAPH g6",
    "MATCH (n) RETURN n; CREATE OR REPLACE GRAPH g6",
    // Another graph's data.
    "DROP GRAPH g6; USE GRAPH g1; CREATE (:R {v: 1})",
    "CREATE GRAPH g9; USE GRAPH g9; CREATE (:R {v: 1})",
    // A START TRANSACTION body is data; a transaction ending is not enough.
    "DROP GRAPH g6; START TRANSACTION { CREATE (:R {v: 1}) }",
    "START TRANSACTION; CREATE (:R {v: 1}); DROP GRAPH g6; COMMIT",
};

/// Programs of graph DDL, graph selection and session statements only.
const alone = [_][]const u8{
    "DROP GRAPH IF EXISTS g5; CREATE GRAPH g5",
    "CREATE GRAPH g8; USE GRAPH g8",
    "USE GRAPH g6; CREATE OR REPLACE GRAPH g5",
    "DROP GRAPH g5; DROP GRAPH IF EXISTS g5",
};

fn sameGraph(graph: []const u8, uuid: [16]u8) bool {
    const ad = graph_store.getGlobalAdapter() orelse return false;
    const mg = ad.lookupManagedGraph(graph) catch return false;
    return std.mem.eql(u8, &mg.uuid, &uuid);
}

test "SONNY-3130: over gRPC a program that creates, replaces or drops a graph and has a statement on graph data is refused (0A000), and nothing changes (R12-V6, V6b)" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    try f.st.createGraph("g6");
    const s = try f.session("v6");
    try fx.expectRuns(ga, s, "USE GRAPH g6; CREATE (:Keep {v: 1})");
    const ad = graph_store.getGlobalAdapter() orelse return error.NoAdapter;
    const uuid = (try ad.lookupManagedGraph("g6")).uuid;

    var ran: usize = 0;
    for (mixed) |q| {
        const code = try fx.outcome(ga, s, q);
        if (code) |c| {
            if (!std.mem.eql(u8, c, "0A000")) {
                std.debug.print("{s}: refused with {s}, expected 0A000\n", .{ q, c });
                ran += 1;
            }
        } else {
            std.debug.print("{s}: ran\n", .{q});
            ran += 1;
        }
        // Whatever ran, the next program starts from a session on g6, which
        // exists with its data.
        if (!f.st.graphExists("g6")) try f.st.createGraph("g6");
        _ = try fx.outcome(ga, s, "USE GRAPH g6");
    }
    try testing.expectEqual(@as(usize, 0), ran);
    // g6 is the graph it was: same UUID, its node, no R.
    try testing.expect(sameGraph("g6", uuid));
    try testing.expectEqual(@as(usize, 1), fx.countLabel(f.st, "g6", "Keep"));
    try testing.expectEqual(@as(usize, 0), fx.countLabel(f.st, "g6", "R"));
    try testing.expectEqual(@as(usize, 0), fx.countLabel(f.st, "g1", "R"));
    try testing.expect(!f.st.graphExists("g9"));

    // Graph DDL with graph selection and other graph DDL runs.
    for (alone) |q| try fx.expectRuns(ga, s, q);
    try testing.expect(f.st.graphExists("g8"));
    try testing.expect(!f.st.graphExists("g5"));
    // The statements on the graph run in a request of their own.
    try fx.expectRuns(ga, s, "CREATE OR REPLACE GRAPH g6");
    try fx.expectRuns(ga, s, "USE GRAPH g6; CREATE (:R {v: 1})");
    try testing.expectEqual(@as(usize, 1), fx.countLabel(f.st, "g6", "R"));
    try testing.expectEqual(@as(usize, 0), fx.countLabel(f.st, "g6", "Keep"));
}

// ---------------------------------------------------------------------------
// The QUIC handler, against a spawned server.
// ---------------------------------------------------------------------------

/// The SQLSTATE a request was refused with, or null when it ran.
fn quicOutcome(client: *util.QuicProtoClient, allocator: std.mem.Allocator, query: []const u8) !?[]const u8 {
    var r = try client.executeAndCollect(allocator, query, util.emptyParams(), 1000);
    defer r.deinit(allocator);
    if (r.error_code) |code| {
        if (std.mem.eql(u8, code, "0A000")) return "0A000";
        std.debug.print("{s}: {s} {s}\n", .{ query, code, r.error_message orelse "" });
        return "other";
    }
    return null;
}

fn quicExpectOk(client: *util.QuicProtoClient, allocator: std.mem.Allocator, query: []const u8) !void {
    var r = try client.executeAndCollect(allocator, query, util.emptyParams(), 1000);
    defer r.deinit(allocator);
    if (r.error_code) |code| {
        std.debug.print("{s}: {s} {s}\n", .{ query, code, r.error_message orelse "" });
        return error.QueryFailed;
    }
}

fn quicCount(client: *util.QuicProtoClient, allocator: std.mem.Allocator, query: []const u8) !i64 {
    var r = try client.executeAndCollect(allocator, query, util.emptyParams(), 1000);
    defer r.deinit(allocator);
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

test "SONNY-3130: over QUIC a program that creates, replaces or drops a graph and has a statement on graph data is refused (0A000); graph DDL alone runs" {
    const allocator = testing.allocator;
    const port = try util.getRandomPort();
    const io_fs = std.Io.Threaded.global_single_threaded.io();
    var dir_buf: [96]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&dir_buf, "/tmp/geode-sonny3130-{d}", .{port});
    std.Io.Dir.cwd().createDirPath(io_fs, data_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io_fs, data_dir) catch {};
    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);
    var server = try util.spawnServer(
        allocator,
        &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--data-dir", data_dir },
        util.TestEnv.standard(),
    );
    defer server.deinit();
    try util.waitForServerReady(allocator, addr, 30000);

    var client = try util.QuicProtoClient.connect(allocator, addr);
    defer client.deinit();
    var h = try client.hello(allocator, util.defaultUsername(), util.defaultPassword());
    h.deinit(allocator);
    try quicExpectOk(&client, allocator, "CREATE GRAPH g1");
    try quicExpectOk(&client, allocator, "CREATE GRAPH g6");
    try quicExpectOk(&client, allocator, "USE GRAPH g6");
    try quicExpectOk(&client, allocator, "CREATE (:Keep {v: 1})");

    var ran: usize = 0;
    for (mixed) |q| {
        const code = try quicOutcome(&client, allocator, q);
        if (code == null or !std.mem.eql(u8, code.?, "0A000")) {
            std.debug.print("QUIC {s}: {s}\n", .{ q, code orelse "ran" });
            ran += 1;
            // Put the session back on an existing g6.
            _ = quicOutcome(&client, allocator, "CREATE GRAPH IF NOT EXISTS g6") catch {};
        }
        _ = quicOutcome(&client, allocator, "USE GRAPH g6") catch {};
    }
    try testing.expectEqual(@as(usize, 0), ran);
    try testing.expectEqual(@as(i64, 1), try quicCount(&client, allocator, "MATCH (n:Keep) RETURN count(n) AS c"));
    try testing.expectEqual(@as(i64, 0), try quicCount(&client, allocator, "MATCH (n:R) RETURN count(n) AS c"));

    for (alone) |q| try quicExpectOk(&client, allocator, q);
    try quicExpectOk(&client, allocator, "CREATE OR REPLACE GRAPH g6");
    try quicExpectOk(&client, allocator, "USE GRAPH g6");
    try quicExpectOk(&client, allocator, "CREATE (:R {v: 1})");
    try testing.expectEqual(@as(i64, 1), try quicCount(&client, allocator, "MATCH (n:R) RETURN count(n) AS c"));
    try testing.expectEqual(@as(i64, 0), try quicCount(&client, allocator, "MATCH (n:Keep) RETURN count(n) AS c"));
}
