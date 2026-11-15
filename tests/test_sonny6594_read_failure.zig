// SONNY-6594 (4): a read statement that cannot read a body fails; it never
// answers with fewer rows (or another path, distance or score).
//
// The MATCH executor (`match_operations.zig`, the variable-length expansion
// in `execution.zig`), the BFS / DFS / Dijkstra procedures
// (`recursion_handler.zig`), the path and centrality algorithms
// (`graph_algorithms.zig`: shortest path, `COUNT { }`, pattern
// comprehensions; `centrality_algorithms.zig`) and the tenant / algorithm scope predicates read each edge
// body with the hydrated getters and took a body that could not be READ
// (the getter's error: out of memory, an engine read error) for an absent
// edge (`orelse continue`): the edge, and every row through it, silently
// left the answer.
//
// A real store with a data directory, the real gRPC handlers in process
// (`sonny738_r12_grpc_fixture.zig`) and `BodyFault` (the caches' body
// rebuilds fail on demand; `sonny6594_body_fault.zig`). Each statement is
// run healthy, then with every edge body evicted and the rebuilds failing,
// top level and inside an explicit transaction (which reads the live store,
// not a read snapshot). Under the fault it must fail or answer exactly the
// healthy answer.
//
// CANARY: REQ=REQ-SONNY-6594-READ-FAILURE; FEATURE="StorageIntegrity"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6594_read_failure.zig; OWNER=execution; UPDATED=2026-11-15

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const grpc = @import("grpc_impl").impl;
const fx = @import("sonny738_r12_grpc_fixture.zig");
const BodyFault = @import("sonny6594_body_fault.zig").BodyFault;

/// The answer as text, or null when the statement failed (its code in `code`).
const Answer = struct { text: ?[]const u8, code: []const u8 = "" };

fn appendValue(ga: std.mem.Allocator, out: *std.ArrayList(u8), v: schema.Value) !void {
    const k = v.kind orelse return out.appendSlice(ga, "null");
    switch (k) {
        .null_val => try out.appendSlice(ga, "null"),
        .int_val => |i| try out.print(ga, "{d}", .{i.value}),
        .double_val => |d| try out.print(ga, "{d:.6}", .{d.value}),
        .bool_val => |b| try out.print(ga, "{}", .{b}),
        .string_val => |s| try out.appendSlice(ga, s.value),
        .node_val => |n| try out.print(ga, "node({d})", .{n.id}),
        .edge_val => |e| try out.print(ga, "edge({d}:{d}->{d})", .{ e.id, e.from_id, e.to_id }),
        .path_val => |p| try out.print(ga, "path({d},{d})", .{ p.nodes.items.len, p.edges.items.len }),
        else => try out.appendSlice(ga, "?"),
    }
}

fn answer(ga: std.mem.Allocator, s: []const u8, query: []const u8) !Answer {
    const resp = try fx.execute(ga, s, query);
    switch (resp.payload orelse return error.MissingPayload) {
        .@"error" => |e| return .{ .text = null, .code = e.code },
        else => {},
    }
    var out: std.ArrayList(u8) = .empty;
    while (true) {
        const req = try fx.encodeProto(ga, schema.PullRequest{ .session_id = s, .page_size = 256 });
        const pull = try fx.decodeProto(schema.PullResponse, ga, try grpc.handlePull(req, ga));
        const presp = pull.response orelse return error.MissingPayload;
        switch (presp.payload orelse return error.MissingPayload) {
            .page => |p| {
                for (p.rows.items) |row| {
                    for (row.values.items) |v| {
                        try appendValue(ga, &out, v);
                        try out.append(ga, ',');
                    }
                    try out.append(ga, ';');
                }
                if (p.final) return .{ .text = out.items };
            },
            .@"error" => |e| return .{ .text = null, .code = e.code },
            else => return error.UnexpectedPayload,
        }
    }
}

const queries = [_][]const u8{
    // match_operations: a one-hop pattern, a two-hop chain, a path variable.
    "MATCH (a:P6594)-[r:N6594]->(b:P6594) RETURN a.i, r.w, b.i ORDER BY a.i",
    "MATCH (a:P6594)-[:N6594]->(b:P6594)-[:N6594]->(c:P6594) RETURN a.i, c.i ORDER BY a.i",
    "MATCH p = (a:P6594 {i: 0})-[:N6594]->(b:P6594) RETURN length(p), b.i",
    // The variable-length expansion and its relationship list.
    "MATCH (a:P6594 {i: 0})-[:N6594*1..4]->(b:P6594) RETURN b.i ORDER BY b.i",
    "MATCH (a:P6594 {i: 0})-[rs:N6594*1..4]->(b:P6594) RETURN b.i, size(rs) ORDER BY b.i",
    "MATCH p = (a:P6594 {i: 0})-[:N6594*1..4]->(b:P6594) RETURN b.i, length(p) ORDER BY b.i",
    // COUNT { } and a pattern comprehension (graph_algorithms PatternWalk).
    "MATCH (a:P6594) RETURN a.i, COUNT { (a)-[:N6594*1..4]->(b:P6594) } AS c ORDER BY a.i",
    "MATCH (a:P6594) RETURN a.i, size([(a)-[r:N6594]->(b) | r.w]) AS c ORDER BY a.i",
    // Shortest path.
    "MATCH p = shortestPath((a:P6594 {i: 0})-[:N6594*]->(b:P6594 {i: 4})) RETURN length(p)",
    // BFS / DFS (recursion_handler).
    "MATCH (s:P6594 {i: 0}) CALL algo.bfs.stream(s, {maxDepth: 4}) YIELD path RETURN length(path) AS d ORDER BY d",
    // Centrality (centrality_algorithms).
    "MATCH (s:P6594 {i: 0}) CALL algo.dfs.stream(s, {maxDepth: 4}) YIELD path RETURN length(path) AS d ORDER BY d",
    "CALL algo.betweenness.stream() YIELD node, score RETURN count(node) AS c, sum(score) AS s",
    "CALL algo.closeness.stream() YIELD node, score RETURN count(node) AS c, sum(score) AS s",
    "CALL algo.pagerank.stream() YIELD node, score RETURN count(node) AS c, sum(score) AS s",
    "CALL algo.unionfind.stream() YIELD node, component RETURN count(DISTINCT component) AS c",
};

fn seed(ga: std.mem.Allocator, s: []const u8) !void {
    try fx.expectRuns(ga, s, "CREATE (:P6594 {i: 0})-[:N6594 {w: 1}]->(:P6594 {i: 1})-[:N6594 {w: 2}]->(:P6594 {i: 2})-[:N6594 {w: 3}]->(:P6594 {i: 3})-[:N6594 {w: 4}]->(:P6594 {i: 4})");
}

fn sweep(f: *fx.Fixture, fault: *BodyFault, s: []const u8, in_txn: bool) !usize {
    const ga = f.ga();
    var wrong: usize = 0;
    for (queries) |q| {
        try fault.evictEdges();
        const healthy = try answer(ga, s, q);
        const want = healthy.text orelse {
            std.debug.print("SONNY-6594 (4) healthy run failed ({s}): {s}\n", .{ healthy.code, q });
            return error.HealthyRunFailed;
        };
        if (in_txn) try fx.begin(ga, s);
        try fault.evictEdges();
        fault.on();
        const got = try answer(ga, s, q);
        const induced = fault.off();
        if (in_txn) _ = try fx.rollback(ga, s);
        if (got.text) |t| {
            if (!std.mem.eql(u8, t, want)) {
                wrong += 1;
                std.debug.print("SONNY-6594 (4) WRONG{s} (body read failed: {}): {s}\n    got  '{s}'\n    want '{s}'\n", .{ if (in_txn) " in a transaction" else "", induced, q, t, want });
            }
        } else std.debug.print("SONNY-6594 (4) failed {s}{s}: {s}\n", .{ got.code, if (in_txn) " in a transaction" else "", q });
        if (got.text != null and induced) std.debug.print("SONNY-6594 (4) answered{s} though a body read failed: {s}\n", .{ if (in_txn) " in a transaction" else "", q });
    }
    return wrong;
}

test "SONNY-6594 (4): a read whose edge body cannot be read fails, never answers short" {
    var f: fx.Fixture = undefined;
    try f.initWith(.{ .bounded_caches = true });
    defer f.deinit();
    var fault: BodyFault = undefined;
    fault.init(f.st);
    const s = try f.session("r6594");
    try seed(f.ga(), s);
    var wrong: usize = 0;
    wrong += try sweep(&f, &fault, s, false);
    wrong += try sweep(&f, &fault, s, true);
    try testing.expectEqual(@as(usize, 0), wrong);
}
