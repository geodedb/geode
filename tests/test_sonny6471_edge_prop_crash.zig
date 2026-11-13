// SONNY-6471 regression: a relationship property write survives a SIGKILL.
//
// A relationship's properties hang off a property chain whose head is held in
// the edge's adjacency entries (the source's outgoing entry and the incoming
// entry co-located on the source's shard) and in the edge index. Writing the
// first property, or growing the chain, moves that head. The adapter's
// `setEdgeProperty` and `setEdgePropertiesBatch` rewrote the heads in the
// adjacency pages without logging those pages in the engine transaction, so
// the WAL held the new property pages but nothing that pointed at them: after
// a crash the relationship came back without its properties. graph-storage's
// own `setEdgeProperty` logs the outgoing adjacency page, the source node page
// and the incoming adjacency page in the same transaction; the adapter's
// in-transaction copy of it did not, and it rewrote the legacy `adj_in` chain
// of the target's shard instead of the co-located incoming chain.
//
// Every write shape that sets, adds or removes a relationship property runs
// against a real `geode serve`, outside and inside an explicit transaction,
// for relationships whose endpoints are on the same shard and on different
// shards, with and without page encryption (GEODE_TDE_KEY). The server is then
// killed (SIGKILL: no shutdown, no checkpoint) and restarted on the same data
// directory, and each case's relationships are counted through an outgoing
// match, an incoming match and an unlabeled relationship scan.
//
// Shards: the engine allocates node slots round-robin over its 16 shards, so
// the 32 endpoint nodes of a case, created by ONE statement, take consecutive
// slots: `<T>s {i: k}` and `<T>d {i: k}` are 16 slots apart (same shard) and
// `<T>s {i: k}` -> `<T>d {i: k+1}` crosses shards. A `CREATE (a)-[...]->(b)`
// that creates both endpoints puts them on neighbouring (different) shards;
// its self-loop form is same-shard.
//
// CANARY: REQ=REQ-SONNY-6471-EDGE-PROP-CRASH; FEATURE="TransactionManagement"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6471_edge_prop_crash.zig; OWNER=storage; UPDATED=2026-11-13

const std = @import("std");
const geode_test_bin = @import("geode_test_bin");
const testing = std.testing;
const util = @import("proto_test_util.zig");

/// Endpoint pairs per side: 16 so `{i: k}` source and target share a shard.
const n_pairs = 16;
/// Relationships per case: (k -> k) same-shard and (k -> k+1) cross-shard.
const n_edges = 2 * n_pairs;

const tde_key_hex = "6471" ** 16;

const QuicServer = struct {
    handle: util.ServerHandle,
    addr: []u8,

    fn start(allocator: std.mem.Allocator, data_dir: []const u8, env: []const []const u8) !QuicServer {
        const port = try util.getRandomPort();
        const addr = try util.formatAddr(allocator, port);
        errdefer allocator.free(addr);
        var handle = try util.spawnServer(
            allocator,
            &.{ geode_test_bin.geode_exe, "serve", "--listen", addr, "--data-dir", data_dir },
            env,
        );
        errdefer handle.deinit();
        try util.waitForServerReady(allocator, addr, 30000);
        return .{ .handle = handle, .addr = addr };
    }

    /// SIGKILL (the harness's teardown): no clean shutdown, no checkpoint.
    fn kill(self: *QuicServer, allocator: std.mem.Allocator) void {
        self.handle.deinit();
        allocator.free(self.addr);
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

fn quicOk(client: *util.QuicProtoClient, allocator: std.mem.Allocator, query: []const u8) !void {
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

/// How a case writes its relationships' properties.
const Shape = enum {
    /// `MATCH (a {i}), (b {i}) CREATE (a)-[:T {p: 1}]->(b)`: the QUIC
    /// match-create-edge fast path.
    create_fast,
    /// The same CREATE with the endpoints filtered in WHERE: the executor.
    create_exec,
    /// `CREATE (:Ts)-[:T {p: 1}]->(:Td)` (cross-shard) and a self-loop
    /// `CREATE (a:Ts:Td)-[:T {p: 1}]->(a)` (same-shard): edge and endpoints in
    /// one statement.
    create_new_nodes,
    /// `MATCH (a {i}), (b {i}) MERGE (a)-[:T {p: 1}]->(b)`: the QUIC
    /// match-merge-edge fast path (group commit).
    merge_fast,
    /// The same MERGE with the endpoints filtered in WHERE: the executor.
    merge_exec,
    /// A `/*+BATCH*/` program of the fast-path MERGEs.
    merge_batch,
    /// `SET e.p = 1` on property-less relationships.
    set_prop,
    /// `SET e = {p: 1, q: 2}` (all properties) on property-less relationships.
    set_map,
    /// `REMOVE e.p` on relationships created with `{p: 5, q: 1}`.
    remove_prop,
};

const Case = struct {
    shape: Shape,
    in_txn: bool,

    fn relType(self: Case, buf: []u8) []const u8 {
        return std.fmt.bufPrint(buf, "R{s}{s}", .{ @tagName(self.shape), if (self.in_txn) "_tx" else "" }) catch unreachable;
    }

    /// What every relationship of the case must satisfy afterwards.
    fn predicate(self: Case) []const u8 {
        return switch (self.shape) {
            .remove_prop => "e.p IS NULL AND e.q = 1",
            .set_map => "e.p = 1 AND e.q = 2",
            else => "e.p = 1",
        };
    }
};

const cases = blk: {
    const shapes = std.enums.values(Shape);
    var out: [shapes.len * 2]Case = undefined;
    for (shapes, 0..) |s, i| {
        out[2 * i] = .{ .shape = s, .in_txn = false };
        out[2 * i + 1] = .{ .shape = s, .in_txn = true };
    }
    break :blk out;
};

fn pairTarget(k: usize, which: usize) usize {
    return if (which == 0) k else (k + 1) % n_pairs;
}

/// One statement creating the case's 32 endpoint nodes on consecutive slots.
fn endpointsStatement(allocator: std.mem.Allocator, t: []const u8) ![]u8 {
    var s: std.ArrayList(u8) = .empty;
    errdefer s.deinit(allocator);
    try s.appendSlice(allocator, "CREATE ");
    for (0..n_pairs) |k| try s.print(allocator, "(:{s}s {{i: {d}}}), ", .{ t, k });
    for (0..n_pairs) |k| {
        try s.print(allocator, "(:{s}d {{i: {d}}})", .{ t, k });
        if (k + 1 < n_pairs) try s.appendSlice(allocator, ", ");
    }
    return s.toOwnedSlice(allocator);
}

/// The case's setup (not measured): endpoints, and for the property-only
/// shapes the relationships they change.
fn setup(client: *util.QuicProtoClient, allocator: std.mem.Allocator, c: Case) !void {
    var tb: [64]u8 = undefined;
    const t = c.relType(&tb);
    if (c.shape == .create_new_nodes) return;
    const ep = try endpointsStatement(allocator, t);
    defer allocator.free(ep);
    try quicOk(client, allocator, ep);
    const props: []const u8 = switch (c.shape) {
        .set_prop, .set_map => "",
        .remove_prop => " {p: 5, q: 1}",
        else => return,
    };
    for (0..n_pairs) |k| for (0..2) |w| {
        var qb: [256]u8 = undefined;
        const q = try std.fmt.bufPrint(&qb, "MATCH (a:{s}s {{i: {d}}}), (b:{s}d {{i: {d}}}) CREATE (a)-[:{s}{s}]->(b)", .{ t, k, t, pairTarget(k, w), t, props });
        try quicOk(client, allocator, q);
    };
}

/// The measured writes, one statement each.
fn writes(allocator: std.mem.Allocator, c: Case) !std.ArrayList([]u8) {
    var tb: [64]u8 = undefined;
    const t = c.relType(&tb);
    var out: std.ArrayList([]u8) = .empty;
    errdefer {
        for (out.items) |s| allocator.free(s);
        out.deinit(allocator);
    }
    switch (c.shape) {
        .create_fast, .merge_fast, .merge_batch, .create_exec, .merge_exec => {
            const verb = switch (c.shape) {
                .create_fast, .create_exec => "CREATE",
                else => "MERGE",
            };
            for (0..n_pairs) |k| for (0..2) |w| {
                const j = pairTarget(k, w);
                const s = switch (c.shape) {
                    .create_exec, .merge_exec => try std.fmt.allocPrint(allocator, "MATCH (a:{s}s), (b:{s}d) WHERE a.i = {d} AND b.i = {d} {s} (a)-[:{s} {{p: 1}}]->(b)", .{ t, t, k, j, verb, t }),
                    else => try std.fmt.allocPrint(allocator, "MATCH (a:{s}s {{i: {d}}}), (b:{s}d {{i: {d}}}) {s} (a)-[:{s} {{p: 1}}]->(b)", .{ t, k, t, j, verb, t }),
                };
                try out.append(allocator, s);
            };
        },
        .create_new_nodes => for (0..n_pairs) |k| {
            try out.append(allocator, try std.fmt.allocPrint(allocator, "CREATE (:{s}s {{i: {d}}})-[:{s} {{p: 1}}]->(:{s}d {{i: {d}}})", .{ t, k, t, t, k }));
            try out.append(allocator, try std.fmt.allocPrint(allocator, "CREATE (a:{s}s:{s}d {{i: {d}}})-[:{s} {{p: 1}}]->(a)", .{ t, t, 100 + k, t }));
        },
        .set_prop => try out.append(allocator, try std.fmt.allocPrint(allocator, "MATCH (:{s}s)-[e:{s}]->() SET e.p = 1", .{ t, t })),
        .set_map => try out.append(allocator, try std.fmt.allocPrint(allocator, "MATCH (:{s}s)-[e:{s}]->() SET e = {{p: 1, q: 2}}", .{ t, t })),
        .remove_prop => try out.append(allocator, try std.fmt.allocPrint(allocator, "MATCH (:{s}s)-[e:{s}]->() REMOVE e.p", .{ t, t })),
    }
    return out;
}

fn run(client: *util.QuicProtoClient, allocator: std.mem.Allocator, c: Case) !void {
    var stmts = try writes(allocator, c);
    defer {
        for (stmts.items) |s| allocator.free(s);
        stmts.deinit(allocator);
    }
    if (!c.in_txn and c.shape != .merge_batch) {
        for (stmts.items) |s| try quicOk(client, allocator, s);
        return;
    }
    var prog: std.ArrayList(u8) = .empty;
    defer prog.deinit(allocator);
    if (c.shape == .merge_batch) try prog.appendSlice(allocator, "/*+BATCH*/ ");
    if (c.in_txn) try prog.appendSlice(allocator, "START TRANSACTION; ");
    for (stmts.items) |s| try prog.print(allocator, "{s}; ", .{s});
    if (c.in_txn) try prog.appendSlice(allocator, "COMMIT") else prog.shrinkRetainingCapacity(prog.items.len - 2);
    try quicOk(client, allocator, prog.items);
}

const View = enum { outgoing, incoming, unlabeled };

fn countView(client: *util.QuicProtoClient, allocator: std.mem.Allocator, c: Case, v: View) !i64 {
    var tb: [64]u8 = undefined;
    const t = c.relType(&tb);
    var qb: [320]u8 = undefined;
    const q = switch (v) {
        .outgoing => try std.fmt.bufPrint(&qb, "MATCH (:{s}s)-[e:{s}]->() WHERE {s} RETURN count(e) AS c", .{ t, t, c.predicate() }),
        .incoming => try std.fmt.bufPrint(&qb, "MATCH (:{s}d)<-[e:{s}]-() WHERE {s} RETURN count(e) AS c", .{ t, t, c.predicate() }),
        .unlabeled => try std.fmt.bufPrint(&qb, "MATCH ()-[e]->() WHERE type(e) = '{s}' AND {s} RETURN count(e) AS c", .{ t, c.predicate() }),
    };
    return quicCount(client, allocator, q);
}

const views = std.enums.values(View);

/// Runs every case, kills the server, restarts it and counts. Returns the
/// number of (case, view) counts that are wrong, before or after the kill.
fn matrix(allocator: std.mem.Allocator, tde: bool) !usize {
    const io_fs = std.Io.Threaded.global_single_threaded.io();
    var dir_buf: [96]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&dir_buf, "/tmp/geode-sonny6471-{d}", .{try util.getRandomPort()});
    std.Io.Dir.cwd().createDirPath(io_fs, data_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io_fs, data_dir) catch {};
    // No checkpoint before the kill: everything the restart sees comes from
    // the WAL, which is what this regression is about (a checkpoint flushes
    // the in-memory pages and hides a missing page image).
    const no_checkpoint = .{ "GEODE_CHECKPOINT_INTERVAL_MS=86400000", "GEODE_CHECKPOINT_OPS=1000000000" };
    const env: []const []const u8 = if (tde) &(no_checkpoint ++ .{"GEODE_TDE_KEY=" ++ tde_key_hex}) else &no_checkpoint;

    var before: [cases.len][views.len]i64 = undefined;
    {
        var server = try QuicServer.start(allocator, data_dir, env);
        defer server.kill(allocator);
        var client = try server.connect(allocator);
        defer client.deinit();
        try quicOk(&client, allocator, "CREATE GRAPH s6471");
        try quicOk(&client, allocator, "USE GRAPH s6471");
        for (cases) |c| try setup(&client, allocator, c);
        for (cases) |c| try run(&client, allocator, c);
        for (cases, 0..) |c, ci| for (views, 0..) |v, vi| {
            before[ci][vi] = try countView(&client, allocator, c, v);
        };
    }

    // Killed (SIGKILL); restarted on the same data directory.
    var server = try QuicServer.start(allocator, data_dir, env);
    defer server.kill(allocator);
    var client = try server.connect(allocator);
    defer client.deinit();
    try quicOk(&client, allocator, "USE GRAPH s6471");
    var wrong: usize = 0;
    for (cases, 0..) |c, ci| for (views, 0..) |v, vi| {
        const after = try countView(&client, allocator, c, v);
        const ok = before[ci][vi] == n_edges and after == n_edges;
        std.debug.print("SONNY-6471 tde={} {s:<16} txn={} {s:<9}: {d} before the kill, {d} after it; want {d}{s}\n", .{ tde, @tagName(c.shape), c.in_txn, @tagName(v), before[ci][vi], after, n_edges, if (ok) "" else "  <-- WRONG" });
        if (!ok) wrong += 1;
    };
    return wrong;
}

test "SONNY-6471: every relationship property write survives a kill (no TDE)" {
    if (try matrix(testing.allocator, false) > 0) return error.RelationshipPropertyLostByTheKill;
}

test "SONNY-6471: every relationship property write survives a kill (TDE)" {
    if (try matrix(testing.allocator, true) > 0) return error.RelationshipPropertyLostByTheKill;
}
