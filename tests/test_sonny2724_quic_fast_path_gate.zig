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
// Spawns the real geode this build emitted (SONNY-2697) and
// speaks the real protobuf protocol.
//
// SONNY-2976 then made the node MERGE primitives match only within the
// request's tenant, as the executor's MERGE does, and the node MERGE shapes
// (node, graph-selector and /*+BATCH*/ MERGE) serve a tenant-scoped session
// again, under strict tenancy too. The last two tests pin that they are
// TAKEN for such a session (the server's merge tuple-lock counter, which only
// the bulk MERGE primitives move, scraped from /metrics) and give the
// executor's rows, while an RLS session still declines. The relationship
// MERGE and MATCH ... CREATE edge shapes keep the stricter gate.
//
// CANARY: REQ=REQ-SONNY-2724-QUIC-FAST-PATH-GATE; FEATURE="MergeRowVisibility"; ASPECT=QuicFastPathGateBehaviour; STATUS=TESTED; TEST=tests/test_sonny2724_quic_fast_path_gate.zig; OWNER=security; UPDATED=2026-09-26

const std = @import("std");
const builtin = @import("builtin");
const geode_test_bin = @import("geode_test_bin");
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
        var handle = try util.spawnServer(allocator, &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--data-dir", data_dir }, extra_env);
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
        // SONNY-2394: reply waits follow the server's liveness, not a fixed
        // 5 s deadline. On a loaded CI shard a live server can take longer
        // than 5 s to answer (HELLO hashes with Argon2id); a server that
        // exits still fails at once, and a hang fails at the 60 s cap.
        client.watchServerLiveness(self.handle.child.id.?);
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

// ---------------------------------------------------------------------------
// SONNY-2724 / SONNY-2976: the node MERGE fast paths serve tenant sessions.
// ---------------------------------------------------------------------------

fn writeAll(fd: i32, bytes: []const u8) !void {
    var offset: usize = 0;
    while (offset < bytes.len) {
        const rc = std.os.linux.write(fd, bytes[offset..].ptr, bytes.len - offset);
        const signed: isize = @bitCast(rc);
        if (signed <= 0) return error.WriteFailed;
        offset += @intCast(signed);
    }
}

/// GET /metrics from the server's loopback metrics port (HTTP/1.1,
/// `Connection: close`, read to EOF).
fn scrapeMetrics(aa: std.mem.Allocator, port: u16) ![]const u8 {
    const linux = std.os.linux;
    const fd_raw = linux.socket(linux.AF.INET, linux.SOCK.STREAM | linux.SOCK.CLOEXEC, linux.IPPROTO.TCP);
    if (linux.errno(fd_raw) != .SUCCESS) return error.SocketCreateFailed;
    const fd: i32 = @intCast(fd_raw);
    defer _ = linux.close(fd);
    const sa = linux.sockaddr.in{
        .family = linux.AF.INET,
        .port = std.mem.nativeToBig(u16, port),
        .addr = std.mem.nativeToBig(u32, 0x7F000001),
        .zero = .{0} ** 8,
    };
    if (@as(isize, @bitCast(linux.connect(fd, @ptrCast(&sa), @sizeOf(linux.sockaddr.in)))) < 0) return error.ConnectFailed;
    try writeAll(fd, try std.fmt.allocPrint(aa, "GET /metrics HTTP/1.1\r\nHost: 127.0.0.1:{d}\r\nConnection: close\r\n\r\n", .{port}));
    var out: std.ArrayList(u8) = .empty;
    var chunk: [8192]u8 = undefined;
    while (out.items.len < 4 * 1024 * 1024) {
        const signed: isize = @bitCast(linux.read(fd, &chunk, chunk.len));
        if (signed < 0) return error.ReadFailed;
        if (signed == 0) break;
        try out.appendSlice(aa, chunk[0..@intCast(signed)]);
    }
    return out.items;
}

/// The bulk MERGE primitives' tuple-lock acquisitions, summed over graphs.
/// The general executor's MERGE takes no tuple lock (CLAUDE.md, tier 0.5),
/// so this counter moves only when a node MERGE fast path served a request.
fn tupleLocks(aa: std.mem.Allocator, port: u16) !u64 {
    const name = "mg_merge_tuple_lock_acquired_total";
    const metrics = try scrapeMetrics(aa, port);
    var total: u64 = 0;
    var seen = false;
    var lines = std.mem.splitScalar(u8, metrics, '\n');
    while (lines.next()) |raw| {
        const line = std.mem.trim(u8, raw, "\r");
        if (!std.mem.startsWith(u8, line, name) or line.len <= name.len or !std.ascii.isWhitespace(line[name.len])) continue;
        const rest = std.mem.trim(u8, line[name.len..], " \t");
        const end = std.mem.indexOfAny(u8, rest, " \t") orelse rest.len;
        total += std.fmt.parseUnsigned(u64, rest[0..end], 10) catch continue;
        seen = true;
    }
    if (!seen) return error.MetricMissing;
    return total;
}

/// Run `stmt` and record whether a node MERGE fast path served it (`want_fast`)
/// and that it answered `want`.
fn expectRoute(aa: std.mem.Allocator, failures: *std.ArrayList([]const u8), client: *util.QuicProtoClient, metrics_port: u16, label: []const u8, stmt: []const u8, want: []const u8, want_fast: bool) !void {
    const before = try tupleLocks(aa, metrics_port);
    try expectRows(aa, failures, client, label, stmt, want);
    const after = try tupleLocks(aa, metrics_port);
    if ((after > before) != want_fast) {
        try failures.append(aa, try std.fmt.allocPrint(aa, "[{s}] {s}: expected the {s}, but the tuple-lock counter went {d} -> {d}", .{ label, stmt, if (want_fast) "fast path" else "executor", before, after }));
    }
}

test "SONNY-2724: a tenant-scoped session's node MERGEs take the fast path and write only its own rows" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var failures: std.ArrayList([]const u8) = .empty;
    var dir_buf: [64]u8 = undefined;
    const metrics_port = try util.getRandomPort();
    const metrics_env = try std.fmt.allocPrint(aa, "GEODE_METRICS_PORT={d}", .{metrics_port});
    var server = try Server.start(&dir_buf, &.{ metrics_env, "GEODE_METRICS_BIND=127.0.0.1" });
    defer server.stop();

    var b = try server.connect("t2724b");
    defer b.deinit();
    try expectRows(aa, &failures, &b, "tenant_b", "CREATE (:K2724 {k: 1, v: 'b'})", "");
    try expectRows(aa, &failures, &b, "tenant_b", "CREATE (:K2724 {k: 2, v: 'b'})", "");

    var a = try server.connect("t2724a");
    defer a.deinit();
    // Served by the fast paths, each creating tenant_a's own node.
    try expectRoute(aa, &failures, &a, metrics_port, "tenant_a", node_merge, "", true);
    try expectRoute(aa, &failures, &a, metrics_port, "tenant_a", selector_merge, "", true);
    try expectRoute(aa, &failures, &a, metrics_port, "tenant_a", batch_merge, "", true);
    // Repeats match tenant_a's nodes (idempotent), again on the fast path.
    for (0..3) |_| try expectRoute(aa, &failures, &a, metrics_port, "tenant_a, repeat", node_merge, "", true);
    try expectRoute(aa, &failures, &a, metrics_port, "tenant_a, repeat", batch_merge, "", true);
    // tenant_b merges a key both tenants hold: its own row, never tenant_a's.
    try expectRoute(aa, &failures, &b, metrics_port, "tenant_b", "MERGE (n:K2724 {k: 2}) SET n.v = 'b2'", "", true);
    // The edge shapes still take the executor (no tuple lock either way);
    // tenant_a's MATCH joins its own two nodes.
    const edge_rows = try rowsOf(aa, &a, edge_create);
    if (std.mem.startsWith(u8, edge_rows, "error:")) try failures.append(aa, try std.fmt.allocPrint(aa, "[tenant_a] {s}: {s}", .{ edge_create, edge_rows }));

    try expectRows(aa, &failures, &b, "tenant_b", "MATCH (n:K2724) RETURN n.k, n.v ORDER BY n.k", "1|b;2|b2");
    try expectRows(aa, &failures, &b, "tenant_b", "MATCH (x)-[r]->(y) RETURN count(r)", "0");
    try expectRows(aa, &failures, &a, "tenant_a", "MATCH (n:K2724) RETURN n.k, n.v ORDER BY n.k", "1|written;2|written");
    try expectRows(aa, &failures, &a, "tenant_a", "MATCH (x)-[r]->(y) RETURN count(r)", "1");
    var admin = try server.connect(null);
    defer admin.deinit();
    try expectRows(aa, &failures, &admin, "unscoped", "MATCH (n:K2724) RETURN count(n)", "4");

    // While an RLS policy is installed, the admin's node MERGE takes the
    // executor (which applies the policy), on a label the policy leaves
    // visible.
    const deny = try std.fmt.allocPrint(aa, "CALL geode.rls.add_deny_policy('default', 'H2724', '{s}')", .{util.defaultUsername()});
    _ = try rowsOf(aa, &admin, deny);
    try expectRoute(aa, &failures, &admin, metrics_port, "unscoped, policy", "MERGE (n:V2724 {k: 5}) SET n.v = 'written'", "", false);
    try expectRows(aa, &failures, &admin, "unscoped, policy", "MATCH (n:V2724) RETURN n.v", "written");
    try finish(failures.items, "tenant-scoped node MERGE fast path");
}

test "SONNY-2724: under strict tenancy a tenant-scoped session's node MERGE takes the fast path; an unscoped one is still refused" {
    // SONNY-6770: raw Linux syscalls (SIGSYS on macOS).
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var failures: std.ArrayList([]const u8) = .empty;
    var dir_buf: [64]u8 = undefined;
    const metrics_port = try util.getRandomPort();
    const metrics_env = try std.fmt.allocPrint(aa, "GEODE_METRICS_PORT={d}", .{metrics_port});
    var server = try Server.start(&dir_buf, &.{ "GEODE_STRICT_TENANCY=1", metrics_env, "GEODE_METRICS_BIND=127.0.0.1" });
    defer server.stop();

    var b = try server.connect("t2724b");
    defer b.deinit();
    try expectRows(aa, &failures, &b, "strict, tenant_b", "CREATE (:K2724 {k: 1, v: 'b'})", "");
    var a = try server.connect("t2724a");
    defer a.deinit();
    try expectRoute(aa, &failures, &a, metrics_port, "strict, tenant_a", node_merge, "", true);
    try expectRoute(aa, &failures, &a, metrics_port, "strict, tenant_a", batch_merge, "", true);
    var c = try server.connect(null);
    defer c.deinit();
    try expectRoute(aa, &failures, &c, metrics_port, "strict, unscoped", node_merge, "error:42501", false);
    try expectRows(aa, &failures, &a, "strict, tenant_a", "MATCH (n:K2724) RETURN n.k, n.v ORDER BY n.k", "1|written;2|written");
    try expectRows(aa, &failures, &b, "strict, tenant_b", "MATCH (n:K2724) RETURN n.k, n.v ORDER BY n.k", "1|b");
    try finish(failures.items, "strict tenancy, tenant-scoped node MERGE");
}
