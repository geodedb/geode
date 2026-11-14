// SONNY-3241 regression over the wire: the server's write fast paths either
// write exactly what the executor writes or decline to it.
//
// The QUIC handler serves simple MERGEs (also as `/*+BATCH*/` programs and
// `USE GRAPH g; MERGE`), MATCH ... CREATE edges and MATCH ... MERGE edges
// straight through the storage adapter, skipping the executor. Each shape
// below is sent with group commit on (the default) and off with
// GEODE_BULK_INGEST=1, and must leave the graph as the executor would:
//   * a node MERGE with ON CREATE / ON MATCH SET beside a bare SET on an
//     existing node runs only the ON MATCH and bare SET (round 4a);
//   * a MATCH ... CREATE edge whose endpoint key two nodes hold makes an
//     edge per matched pair, and one whose key MERGE's index cannot hold
//     (a non-integer number) finds its endpoints, not none;
//   * a MATCH ... MERGE edge with ON CREATE SET (alone or beside a bare
//     SET) runs it only on the edge it creates, never on a matched one;
//   * a MATCH ... MERGE edge whose relationship has properties matches on
//     them (SONNY-3357).
//
// CANARY: REQ=REQ-SONNY-3241-FAST-PATH-PARITY; FEATURE="WriteFastPathParity"; ASPECT=WireRegression; STATUS=TESTED; TEST=tests/test_sonny3241_fast_path_parity_wire.zig; OWNER=transport; UPDATED=2026-11-12

const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const util = @import("proto_test_util.zig");

fn run(client: *util.QuicProtoClient, query: []const u8) !void {
    var r = try client.executeAndCollect(testing.allocator, query, util.emptyParams(), 1000);
    defer r.deinit(testing.allocator);
    if (r.error_code) |code| {
        if (!std.mem.eql(u8, code, "00000")) {
            std.debug.print("{s}: {s} {s}\n", .{ query, code, r.error_message orelse "" });
            return error.QueryFailed;
        }
    }
}

/// The single cell `query` returns, rendered (12, 'text', null); caller frees.
fn cell(client: *util.QuicProtoClient, query: []const u8) ![]u8 {
    var r = try client.executeAndCollect(testing.allocator, query, util.emptyParams(), 1000);
    defer r.deinit(testing.allocator);
    if (r.error_code) |code| {
        if (!std.mem.eql(u8, code, "00000")) {
            std.debug.print("{s}: {s} {s}\n", .{ query, code, r.error_message orelse "" });
            return error.QueryFailed;
        }
    }
    if (r.rows.len != 1) {
        std.debug.print("{s}: {d} rows\n", .{ query, r.rows.len });
        return error.UnexpectedRows;
    }
    return switch (r.rows[0][0]) {
        .int => |v| std.fmt.allocPrint(testing.allocator, "{d}", .{v}),
        .string => |s| std.fmt.allocPrint(testing.allocator, "'{s}'", .{s}),
        .null => testing.allocator.dupe(u8, "null"),
        else => testing.allocator.dupe(u8, "<other>"),
    };
}

fn expectCell(client: *util.QuicProtoClient, query: []const u8, want: []const u8) !void {
    const got = try cell(client, query);
    defer testing.allocator.free(got);
    if (!std.mem.eql(u8, got, want)) {
        std.debug.print("{s}: {s}, expected {s}\n", .{ query, got, want });
        return error.WrongAnswer;
    }
}

fn exercise(env: []const []const u8) !void {
    const allocator = testing.allocator;
    const port = try util.getRandomPort();
    const io_fs = std.Io.Threaded.global_single_threaded.io();
    var dir_buf: [96]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&dir_buf, "/tmp/geode-sonny3241-{d}", .{port});
    std.Io.Dir.cwd().createDirPath(io_fs, data_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io_fs, data_dir) catch {};
    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);
    var server = try util.spawnServer(
        allocator,
        &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--data-dir", data_dir },
        env,
    );
    defer server.deinit();
    try util.waitForServerReady(allocator, addr, 30000);

    var c = try util.QuicProtoClient.connect(allocator, addr);
    defer c.deinit();
    c.watchServerLiveness(server.child.id.?);
    var h = try c.hello(allocator, util.defaultUsername(), util.defaultPassword());
    defer h.deinit(allocator);
    if (!h.success) return error.HelloRefused;

    // ---- node MERGE: ON CREATE / ON MATCH SET beside a bare SET ----
    try run(&c, "MERGE (z:Z {k: 1}) ON CREATE SET z.c = 0");
    try run(&c, "MERGE (z:Z {k: 1}) ON CREATE SET z.c = 1 SET z.b = 2");
    try expectCell(&c, "MATCH (z:Z {k: 1}) RETURN z.c AS c", "0");
    try expectCell(&c, "MATCH (z:Z {k: 1}) RETURN z.b AS b", "2");
    try run(&c, "MERGE (z:Z {k: 1}) ON MATCH SET z.m = 1 SET z.b = 3");
    try expectCell(&c, "MATCH (z:Z {k: 1}) RETURN z.m AS m", "1");
    try run(&c, "/*+BATCH*/MERGE (z:Z {k: 1}) ON CREATE SET z.c = 5 SET z.b = 4; MERGE (z:Z {k: 2})");
    try expectCell(&c, "MATCH (z:Z {k: 1}) RETURN z.c AS c", "0");
    try run(&c, "USE GRAPH default; MERGE (z:Z {k: 1}) ON CREATE SET z.c = 6 SET z.b = 5");
    try expectCell(&c, "MATCH (z:Z {k: 1}) RETURN z.c AS c", "0");
    try expectCell(&c, "MATCH (z:Z) RETURN count(z) AS n", "2");

    // ---- MATCH ... CREATE edge: an endpoint key two nodes hold ----
    try run(&c, "CREATE (:P {k: 1, t: 'p1'})");
    try run(&c, "CREATE (:P {k: 1, t: 'p2'})");
    try run(&c, "CREATE (:Q {k: 9})");
    try run(&c, "MATCH (a:P {k: 1}), (b:Q {k: 9}) CREATE (a)-[:E]->(b)");
    try expectCell(&c, "MATCH (:P)-[r:E]->(:Q) RETURN count(r) AS n", "2");
    try run(&c, "MATCH (a:Q {k: 9}), (b:P {k: 1}) CREATE (a)-[:F]->(b)");
    try expectCell(&c, "MATCH (:Q)-[r:F]->(:P) RETURN count(r) AS n", "2");
    // A key MERGE's index cannot hold (not an integer): found by the match.
    try run(&c, "CREATE (:R {k: 1.5}), (:S {k: 2.5})");
    try run(&c, "MATCH (a:R {k: 1.5}), (b:S {k: 2.5}) CREATE (a)-[:G]->(b)");
    try expectCell(&c, "MATCH (:R)-[r:G]->(:S) RETURN count(r) AS n", "1");
    // A key no node holds: nothing, as the executor.
    try run(&c, "MATCH (a:P {k: 404}), (b:Q {k: 9}) CREATE (a)-[:H]->(b)");
    try expectCell(&c, "MATCH ()-[r:H]->() RETURN count(r) AS n", "0");

    // ---- MATCH ... MERGE edge: ON CREATE SET runs on a created edge only ----
    try run(&c, "CREATE (:A {k: 1}), (:B {k: 2})");
    try run(&c, "MATCH (a:A {k: 1}), (b:B {k: 2}) MERGE (a)-[r:T]->(b) ON CREATE SET r.c = 0");
    try expectCell(&c, "MATCH (:A)-[r:T]->(:B) RETURN r.c AS c", "0");
    try run(&c, "MATCH (a:A {k: 1}), (b:B {k: 2}) MERGE (a)-[r:T]->(b) ON CREATE SET r.c = 1");
    try expectCell(&c, "MATCH (:A)-[r:T]->(:B) RETURN r.c AS c", "0");
    try run(&c, "MATCH (a:A {k: 1}), (b:B {k: 2}) MERGE (a)-[r:T]->(b) ON CREATE SET r.c = 2 SET r.b = 7");
    try expectCell(&c, "MATCH (:A)-[r:T]->(:B) RETURN r.c AS c", "0");
    try expectCell(&c, "MATCH (:A)-[r:T]->(:B) RETURN r.b AS b", "7");
    // A bare SET runs on the matched edge (the fast path's own shape).
    try run(&c, "MATCH (a:A {k: 1}), (b:B {k: 2}) MERGE (a)-[r:T]->(b) SET r.run = 'x'");
    try expectCell(&c, "MATCH (:A)-[r:T]->(:B) RETURN r.run AS run", "'x'");
    try expectCell(&c, "MATCH (:A)-[r:T]->(:B) RETURN count(r) AS n", "1");

    // ---- MATCH ... MERGE edge with relationship properties (SONNY-3357) ----
    try run(&c, "MATCH (a:A {k: 1}), (b:B {k: 2}) MERGE (a)-[r:W {w: 1}]->(b)");
    try run(&c, "MATCH (a:A {k: 1}), (b:B {k: 2}) MERGE (a)-[r:W {w: 2}]->(b)");
    try expectCell(&c, "MATCH (:A)-[r:W]->(:B) RETURN count(r) AS n", "2");
    try run(&c, "MATCH (a:A {k: 1}), (b:B {k: 2}) MERGE (a)-[r:W {w: 2}]->(b)");
    try expectCell(&c, "MATCH (:A)-[r:W]->(:B) RETURN count(r) AS n", "2");
}

test "SONNY-3241: over QUIC the write fast paths match the executor (group commit on)" {
    try exercise(util.TestEnv.standard());
}

test "SONNY-3241: over QUIC the write fast paths match the executor (group commit off, GEODE_BULK_INGEST=1)" {
    try exercise(&.{ "GEODE_GROUP_COMMIT=0", "GEODE_BULK_INGEST=1" });
}
