// CANARY: REQ=REQ-SONNY-1562-COLD-SUBQUERY-SCAN; FEATURE="ExpressionPathColdScan"; ASPECT=ResidencyIndependentCounts; STATUS=TESTED; TEST=tests/test_sonny1562_cold_subquery_scan.zig; OWNER=execution; UPDATED=2026-11-11
//
// SONNY-1562 — `COUNT { }`, `EXISTS { }` and pattern comprehensions must not
// depend on which nodes happen to be RESIDENT in the bounded node cache.
//
// The expression path (`graph_algorithms.countPatternMatches` /
// `executePatternComprehension`, reached from `eval.zig` `.PatternCount` /
// `.Exists` / `.PatternComp`) found its uncorrelated start nodes by walking
// `store.nodes.iterator()`, which yields only the cache's RESIDENT subset. On a
// persisted store reopened cold (or after eviction under a bounded cache)
// `RETURN COUNT { (a:A)-[:R]->(:B) }` answered 0 and `EXISTS { … }` false,
// while the equivalent `MATCH … RETURN count(*)` — whose scans go through the
// authoritative id sets and `getNodePtrForScan` — returned every row.
//
// Harness: the PRODUCTION `initGlobalStore` path against a real data dir, the
// real parser and the real executor — no mocks. The build step pins the node,
// edge and adjacency caches to 64 entries so the seeded rows genuinely fall out
// of residency (the `test-sonny1330-parallel-union` fixture's approach); the
// test asserts that precondition instead of assuming it.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const Value = geode.value_types.Value;

// The NAMED `logging` module the engine logs through (see the SONNY-1330
// suite): the production store open path emits adapter INFO lines that the
// build runner would echo under the step banner as a spurious failure.
const logging = @import("logging");

fn silenceEngineLogs() void {
    logging.init(.{ .level = .fatal });
    logging.setLevel(.fatal);
}

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

/// A store session bound to a caller-owned data dir, so the test can close the
/// store (persisting it) and reopen it with the bounded caches cold.
const Session = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    ctx: execution.ExecutionContext,

    fn open(allocator: std.mem.Allocator, data_dir: []const u8) !Session {
        silenceEngineLogs();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        _ = try graph_store.initGlobalStore(allocator, data_dir);
        // COUNT{} / EXISTS{} / pattern comprehensions reach the executor
        // through the evaluator's injected callbacks.
        execution.initEvaluator();
        const catalog = try execution.ensureCatalogInstance(allocator);
        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    fn close(self: *Session) void {
        self.arena.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
    }

    fn runQuery(self: *Session, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    /// Run a single-row, single-column query and return that value.
    fn scalar(self: *Session, query: []const u8) !Value {
        const aa = self.arena.allocator();
        var r = try self.runQuery(query);
        defer r.deinit(aa);
        if (r.rows.len != 1 or r.rows[0].len < 1) {
            std.debug.print("SONNY-1562: `{s}` returned {d} rows\n", .{ query, r.rows.len });
            return error.UnexpectedRowShape;
        }
        return r.rows[0][0];
    }

    fn int(self: *Session, query: []const u8) !i64 {
        const v = try self.scalar(query);
        return switch (v) {
            .Int => |i| @intCast(i),
            else => {
                std.debug.print("SONNY-1562: `{s}` returned {s}, not an Int\n", .{ query, @tagName(v) });
                return error.UnexpectedValueKind;
            },
        };
    }

    fn boolean(self: *Session, query: []const u8) !bool {
        const v = try self.scalar(query);
        return switch (v) {
            .Bool => |b| b,
            else => {
                std.debug.print("SONNY-1562: `{s}` returned {s}, not a Bool\n", .{ query, @tagName(v) });
                return error.UnexpectedValueKind;
            },
        };
    }
};

/// Pairs `(:S1562A {k})-[:S1562R]->(:S1562B {k})`, plus `LONE` `:S1562A` nodes
/// with no relationship, so a count that ignored the hop would be wrong too.
const PAIRS: usize = 300;
const LONE: usize = 40;

fn seed(s: *Session) !void {
    const aa = s.arena.allocator();
    var i: usize = 0;
    while (i < PAIRS) : (i += 1) {
        const q = try std.fmt.allocPrint(aa, "CREATE (:S1562A {{k: {d}}})-[:S1562R]->(:S1562B {{k: {d}}})", .{ i, i });
        var r = try s.runQuery(q);
        r.deinit(aa);
    }
    i = 0;
    while (i < LONE) : (i += 1) {
        const q = try std.fmt.allocPrint(aa, "CREATE (:S1562A {{k: {d}}})", .{PAIRS + i});
        var r = try s.runQuery(q);
        r.deinit(aa);
    }
}

/// The harness precondition: the caches are bounded and the reopen is COLD.
/// Without it every row would be resident and the test would pass for the
/// wrong reason.
fn expectColdStore(allocator: std.mem.Allocator) !void {
    const st = graph_store.getGlobalStore(allocator);
    try testing.expectEqual(@as(usize, 64), st.nodes.effectiveCap());
    try testing.expect(st.nodes.residentCount() < PAIRS);
}

const Q_COUNT_HOP = "RETURN COUNT { (a:S1562A)-[:S1562R]->(:S1562B) } AS c";
const Q_MATCH_HOP = "MATCH (a:S1562A)-[:S1562R]->(:S1562B) RETURN count(*) AS c";
const Q_COUNT_NODE = "RETURN COUNT { (a:S1562A) } AS c";
const Q_MATCH_NODE = "MATCH (a:S1562A) RETURN count(*) AS c";
const Q_COUNT_ANY = "RETURN COUNT { (n) } AS c";
const Q_MATCH_ANY = "MATCH (n) RETURN count(*) AS c";
const Q_EXISTS_NODE = "RETURN EXISTS { (b:S1562B {k: 7}) } AS e";
const Q_EXISTS_HOP = "RETURN EXISTS { (a:S1562A)-[:S1562R]->(:S1562B {k: 7}) } AS e";
const Q_EXISTS_ABSENT = "RETURN EXISTS { (b:S1562B {k: 100000}) } AS e";
const Q_COMP_HOP = "RETURN size([(a:S1562A)-[:S1562R]->(b:S1562B) | b.k]) AS n";
const Q_COMP_NODE = "RETURN size([(b:S1562B) | b.k]) AS n";

test "SONNY-1562: COUNT {}, EXISTS {} and pattern comprehensions see every node of a cold store" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    // Phase 1: seed, then CLOSE (persist) the store.
    {
        var s = try Session.open(allocator, data_dir);
        defer s.close();
        try seed(&s);
    }

    // Phase 2: reopen COLD. Every subquery runs BEFORE any MATCH oracle, so no
    // earlier scan can have touched the nodes it must find.
    {
        var s = try Session.open(allocator, data_dir);
        defer s.close();
        try expectColdStore(allocator);

        const count_hop = try s.int(Q_COUNT_HOP);
        const count_node = try s.int(Q_COUNT_NODE);
        const count_any = try s.int(Q_COUNT_ANY);
        const exists_node = try s.boolean(Q_EXISTS_NODE);
        const exists_hop = try s.boolean(Q_EXISTS_HOP);
        const exists_absent = try s.boolean(Q_EXISTS_ABSENT);
        const comp_hop = try s.int(Q_COMP_HOP);
        const comp_node = try s.int(Q_COMP_NODE);

        // The MATCH oracles, which are residency-independent.
        const match_hop = try s.int(Q_MATCH_HOP);
        const match_node = try s.int(Q_MATCH_NODE);
        const match_any = try s.int(Q_MATCH_ANY);

        // Still cold after all of the above.
        try expectColdStore(allocator);

        // On any mismatch, report every observation at once (a green run
        // prints nothing, so the build runner shows no stderr banner).
        const agree = count_hop == match_hop and count_node == match_node and count_any == match_any and
            exists_node and exists_hop and !exists_absent and comp_hop == PAIRS and comp_node == PAIRS;
        if (!agree) std.debug.print(
            "SONNY-1562 cold store: COUNT hop={d} (MATCH {d}), COUNT node={d} (MATCH {d}), COUNT any={d} (MATCH {d}), " ++
                "EXISTS node={}, EXISTS hop={}, EXISTS absent={}, comprehension hop={d}, comprehension node={d}\n",
            .{ count_hop, match_hop, count_node, match_node, count_any, match_any, exists_node, exists_hop, exists_absent, comp_hop, comp_node },
        );

        // The oracles answer from the full store.
        try testing.expectEqual(@as(i64, PAIRS), match_hop);
        try testing.expectEqual(@as(i64, PAIRS + LONE), match_node);
        try testing.expectEqual(@as(i64, 2 * PAIRS + LONE), match_any);

        // The expression path must agree with them.
        try testing.expectEqual(match_hop, count_hop);
        try testing.expectEqual(match_node, count_node);
        try testing.expectEqual(match_any, count_any);
        try testing.expect(exists_node);
        try testing.expect(exists_hop);
        try testing.expect(!exists_absent);
        try testing.expectEqual(@as(i64, PAIRS), comp_hop);
        try testing.expectEqual(@as(i64, PAIRS), comp_node);
    }
}

test "SONNY-1562: a correlated EXISTS {} gate keeps every anchor of a cold store" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    {
        var s = try Session.open(allocator, data_dir);
        defer s.close();
        try seed(&s);
    }

    {
        var s = try Session.open(allocator, data_dir);
        defer s.close();
        try expectColdStore(allocator);
        const aa = s.arena.allocator();

        var gated = try s.runQuery("MATCH (a:S1562A) WHERE EXISTS { (a)-[:S1562R]->(:S1562B) } RETURN a.k");
        defer gated.deinit(aa);
        try testing.expectEqual(PAIRS, gated.rows.len);

        try testing.expectEqual(@as(i64, PAIRS), try s.int("MATCH (a:S1562A) RETURN sum(COUNT { (a)-[:S1562R]->(:S1562B) }) AS c"));
    }
}
