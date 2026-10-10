// SONNY-2724 (the one gap the SONNY-2686 review found in the fast-path gate):
// a behavioural test, over the real QUIC handler, that the key-resolved write
// fast paths never serve a session a tenant scope or an RLS policy restricts.
//
// The QUIC handler's key-resolved fast paths (executeBulkSimpleMerge, its
// graph-selector form, executeBatchSimpleMerge, executeBulkMatchMergeEdge and
// executeBulkMatchCreateEdge) find existing nodes by merge key alone: no
// tenant check and no row-level security. SONNY-2686 (366f96bf) gated all of
// them on `key_resolved_writes_ok` (bulk_ingest.sessionAllowsKeyResolvedWrites
// plus the server-side label engine), but only the decision helper had a
// test. Here every fast-path shape is sent over QUIC by:
//   * a tenant-scoped session, while another tenant holds rows with the same
//     keys: the fast path would bind and rewrite that tenant's rows;
//   * an unscoped session on a strict-tenancy server: the fast path would
//     write; the executor refuses (42501);
//   * a user while an RLS policy is installed, against a row the policy
//     hides: the fast path would rewrite it; the executor refuses (42501).
// Each must take the general executor and give its correct answer.
//
// Spawns the real ./zig-out/bin/geode (the step installs it first) and
// speaks the real protobuf protocol. The ticket stays open: making the fast
// paths themselves tenant- and RLS-correct is future work.
//
// CANARY: REQ=REQ-SONNY-2724-QUIC-FAST-PATH-GATE; FEATURE="MergeRowVisibility"; ASPECT=QuicFastPathGateBehaviour; STATUS=TESTED; TEST=tests/test_sonny2724_quic_fast_path_gate.zig; OWNER=security; UPDATED=2026-09-26

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const util = @import("proto_test_util.zig");

/// One statement per fast path, each the exact shape its detector takes
/// (pinned by the first test).
const node_merge = "MERGE (n:K2724 {k: 1}) SET n.v = 'written'";
const selector_merge = "USE GRAPH default; MERGE (n:K2724 {k: 1}) SET n.v = 'written'";
const batch_merge = "/*+BATCH*/MERGE (n:K2724 {k: 1}) SET n.v = 'written'; MERGE (n:K2724 {k: 2}) SET n.v = 'written'";
const edge_merge = "MATCH (a:K2724 {k: 1}), (b:K2724 {k: 2}) MERGE (a)-[:M2724]->(b)";
const edge_create = "MATCH (a:K2724 {k: 1}), (b:K2724 {k: 2}) CREATE (a)-[:E2724]->(b)";
const fast_path_shapes = [_][]const u8{ node_merge, selector_merge, batch_merge, edge_merge, edge_create };

test "SONNY-2724: each statement is the shape of a key-resolved fast path" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const bulk = geode.bulk_ingest;
    {
        var p = try geode.parseGql(node_merge, aa);
        defer p.deinit();
        try testing.expectEqual(bulk.BulkPattern.simple_node_merge, bulk.matchSingleStatement(&p.program));
    }
    {
        var p = try geode.parseGql(selector_merge, aa);
        defer p.deinit();
        try testing.expect(bulk.matchGraphSelectorThenMerge(&p.program) != null);
    }
    {
        // The batch path takes a program of simple node MERGEs (the sentinel is
        // a comment the lexer drops).
        var p = try geode.parseGql(batch_merge, aa);
        defer p.deinit();
        try testing.expectEqual(@as(usize, 2), p.program.statements.len);
        for (p.program.statements) |*stmt| try testing.expect(bulk.matchSimpleNodeMergeSpecStmt(stmt) != null);
    }
    {
        var p = try geode.parseGql(edge_merge, aa);
        defer p.deinit();
        try testing.expectEqual(bulk.BulkPattern.match_merge_edge, bulk.matchSingleStatement(&p.program));
    }
    {
        var p = try geode.parseGql(edge_create, aa);
        defer p.deinit();
        try testing.expectEqual(bulk.BulkPattern.match_create_edge, bulk.matchSingleStatement(&p.program));
    }
}

const Server = struct {
    handle: util.ServerHandle,
    data_dir: []const u8,
    addr: []const u8,

    fn start(data_dir_buf: []u8, extra_env: []const []const u8) !Server {
        const allocator = testing.allocator;
        const port = try util.getRandomPort();
        const io = std.Io.Threaded.global_single_threaded.io();
        const data_dir = try std.fmt.bufPrint(data_dir_buf, "/tmp/geode-sonny2724-{d}", .{port});
        std.Io.Dir.cwd().deleteTree(io, data_dir) catch {};
        try std.Io.Dir.cwd().createDirPath(io, data_dir);
        const addr = try util.formatAddr(allocator, port);
        errdefer allocator.free(addr);
        var handle = try util.spawnServer(allocator, &.{ "./zig-out/bin/geode", "serve", "--listen", addr, "--data-dir", data_dir }, extra_env);
        errdefer handle.deinit();
        try util.waitForServerReady(allocator, addr, 30000);
        return .{ .handle = handle, .data_dir = data_dir, .addr = addr };
    }

    fn stop(self: *Server) void {
        self.handle.deinit();
        testing.allocator.free(self.addr);
        const io = std.Io.Threaded.global_single_threaded.io();
        std.Io.Dir.cwd().deleteTree(io, self.data_dir) catch {};
    }

    /// A session as the fixture's admin user, in `tenant` (null: unscoped).
    fn connect(self: *Server, tenant: ?[]const u8) !util.QuicProtoClient {
        var client = try util.QuicProtoClient.connect(testing.allocator, self.addr);
        errdefer client.deinit();
        var hello = try client.helloWith(testing.allocator, util.defaultUsername(), util.defaultPassword(), null, tenant);
        defer hello.deinit(testing.allocator);
        if (!hello.success) {
            std.debug.print("HELLO refused: {s}\n", .{hello.error_message});
            return error.HelloRefused;
        }
        return client;
    }
};

/// The rows of `query` as `a|b` strings (in the server's order), or
/// `error:<code>`.
fn rowsOf(aa: std.mem.Allocator, client: *util.QuicProtoClient, query: []const u8) ![]const u8 {
    var res = try client.executeAndCollect(testing.allocator, query, util.emptyParams(), 100);
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

fn expectRows(aa: std.mem.Allocator, failures: *std.ArrayList([]const u8), client: *util.QuicProtoClient, label: []const u8, query: []const u8, want: []const u8) !void {
    const got = try rowsOf(aa, client, query);
    if (!std.mem.eql(u8, got, want)) {
        try failures.append(aa, try std.fmt.allocPrint(aa, "[{s}] {s}: expected {s}, got {s}", .{ label, query, want, got }));
    }
}

fn finish(failures: []const []const u8, title: []const u8) !void {
    if (failures.len == 0) return;
    std.debug.print("\n{s}: {d} failed check(s):\n", .{ title, failures.len });
    for (failures) |msg| std.debug.print("  {s}\n", .{msg});
    return error.FastPathServedRestrictedSession;
}

test "SONNY-2724: a tenant-scoped session's fast-path shapes take the executor, and never touch another tenant's rows" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var failures: std.ArrayList([]const u8) = .empty;
    var dir_buf: [64]u8 = undefined;
    var server = try Server.start(&dir_buf, &.{});
    defer server.stop();

    // tenant_b owns the keys the statements name.
    var b = try server.connect("t2724b");
    defer b.deinit();
    try expectRows(aa, &failures, &b, "tenant_b", "CREATE (:K2724 {k: 1, v: 'b'})", "");
    try expectRows(aa, &failures, &b, "tenant_b", "CREATE (:K2724 {k: 2, v: 'b'})", "");

    var a = try server.connect("t2724a");
    defer a.deinit();
    // Each fast path would bind tenant_b's rows by key; the executor writes
    // tenant_a's own. The edge statements run while tenant_a has no k: 2, so
    // the executor's MATCH finds nothing to join.
    try expectRows(aa, &failures, &a, "tenant_a", node_merge, "");
    try expectRows(aa, &failures, &a, "tenant_a", edge_merge, "");
    try expectRows(aa, &failures, &a, "tenant_a", edge_create, "");
    try expectRows(aa, &failures, &a, "tenant_a", selector_merge, "");
    try expectRows(aa, &failures, &a, "tenant_a", batch_merge, "");

    try expectRows(aa, &failures, &b, "tenant_b", "MATCH (n:K2724) RETURN n.k, n.v ORDER BY n.k", "1|b;2|b");
    try expectRows(aa, &failures, &b, "tenant_b", "MATCH (x)-[r]->(y) RETURN count(r)", "0");
    try expectRows(aa, &failures, &a, "tenant_a", "MATCH (n:K2724) RETURN n.k, n.v ORDER BY n.k", "1|written;2|written");
    try expectRows(aa, &failures, &a, "tenant_a", "MATCH (x)-[r]->(y) RETURN count(r)", "0");
    try finish(failures.items, "tenant-scoped");
}

test "SONNY-2724: under strict tenancy an unscoped session's fast-path shapes are refused by the executor" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var failures: std.ArrayList([]const u8) = .empty;
    var dir_buf: [64]u8 = undefined;
    var server = try Server.start(&dir_buf, &.{"GEODE_STRICT_TENANCY=1"});
    defer server.stop();

    var c = try server.connect(null);
    defer c.deinit();
    // A fast path would write; the executor refuses an unscoped request.
    for (fast_path_shapes) |stmt| try expectRows(aa, &failures, &c, "strict, unscoped", stmt, "error:42501");
    // A tenant-scoped session on the same server sees nothing written.
    var t = try server.connect("t2724a");
    defer t.deinit();
    try expectRows(aa, &failures, &t, "strict, tenant_a", "MATCH (n:K2724) RETURN count(n)", "0");
    try finish(failures.items, "strict tenancy");
}

test "SONNY-2724: while an RLS policy is installed a user's fast-path shapes take the executor, which refuses a hidden row" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var failures: std.ArrayList([]const u8) = .empty;
    var dir_buf: [64]u8 = undefined;
    var server = try Server.start(&dir_buf, &.{});
    defer server.stop();

    var c = try server.connect(null);
    defer c.deinit();
    try expectRows(aa, &failures, &c, "setup", "CREATE (:K2724 {k: 1, v: 'orig'})", "");
    try expectRows(aa, &failures, &c, "setup", "CREATE (:K2724 {k: 2, v: 'orig'})", "");
    try expectRows(aa, &failures, &c, "setup", "CREATE (:V2724 {k: 5})", "");
    // The policy hides :K2724 from this very user.
    const deny = try std.fmt.allocPrint(aa, "CALL geode.rls.add_deny_policy('default', 'K2724', '{s}')", .{util.defaultUsername()});
    _ = try rowsOf(aa, &c, deny);

    // Every fast path would bind the hidden rows by key; the executor
    // refuses the MERGEs, and its MATCH finds nothing to join.
    try expectRows(aa, &failures, &c, "policy", node_merge, "error:42501");
    try expectRows(aa, &failures, &c, "policy", selector_merge, "error:42501");
    try expectRows(aa, &failures, &c, "policy", batch_merge, "error:42501");
    try expectRows(aa, &failures, &c, "policy", edge_merge, "");
    try expectRows(aa, &failures, &c, "policy", edge_create, "");
    // A row the policy does not hide is still merged, by the executor.
    try expectRows(aa, &failures, &c, "policy", "MERGE (n:V2724 {k: 5}) SET n.v = 'written'", "");
    try expectRows(aa, &failures, &c, "policy", "MATCH (n:V2724) RETURN n.v", "written");

    // With the policy gone, the hidden rows are as they were.
    const undeny = try std.fmt.allocPrint(aa, "CALL geode.rls.remove_deny_policy('default', 'K2724', '{s}')", .{util.defaultUsername()});
    _ = try rowsOf(aa, &c, undeny);
    try expectRows(aa, &failures, &c, "after", "MATCH (n:K2724) RETURN n.k, n.v ORDER BY n.k", "1|orig;2|orig");
    try expectRows(aa, &failures, &c, "after", "MATCH (x)-[r]->(y) RETURN count(r)", "0");
    try finish(failures.items, "RLS policy");
}
