// CANARY: REQ=REQ-BUG731-MATCH-SCOPING; FEATURE="MultiChainRelationshipMatch"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_bug731_match_scoping.zig:1; OWNER=execution; UPDATED=2026-07-31
//
// Reproductions for docs/@BUGS_731.md bugs #5 and #7 (blog-post validation,
// geode v0.8.4). All of these are SILENT WRONG ANSWER bugs — every query below
// "succeeds" today and returns a plausible-looking but incorrect result set.
//
//   BUG 5 — chained `MATCH` clauses silently lose scope.
//     `executeMultiChainRelationshipMatch` (src/execution/match_operations.zig)
//     honors labels, edge types, edge props, tenant and RLS, but never
//     evaluates inline node property predicates (`NodePattern.props`). The
//     head-only first-chain seeding site (:5300-5335) applies labels at :5303
//     and never looks at `node_pattern.props`, so
//     `MATCH (me:User {username:'alice'}) MATCH (me)-[:FRIENDS_WITH]-(friend)`
//     binds `me` to EVERY :User node and traverses the whole graph.
//     Dispatch: src/execution/pattern_helpers.zig:135-174 (from
//     match_operations.zig:8282-8287); the planner declines
//     (planned_read_runtime.zig:3714) so this legacy executor runs.
//
//   BUG 5c — the same function silently ignores `rel.min_len`/`rel.max_len`,
//     so a var-length hop chained with a further hop in ONE clause
//     (`(me)-[:FRIENDS_WITH*0..1]-(friend)-[:POSTED]->(post)`) degrades to a
//     single fixed hop. Routed there by pattern_helpers.zig:151-153 when
//     `chains.len == 1 and hops[0].hops.len > 1`.
//
//   BUG 5d — node identity `=`/`<>` compares POINTERS, not ids.
//     src/value_types.zig:297 `.Node => |an| b == .Node and an == b.Node`,
//     reached because the generic same-tag `eqVals` branch at src/eval.zig:658
//     runs BEFORE the correct id-based branch at src/eval.zig:670-674 (making
//     that branch dead). Node pointers are unstable — graph_store.zig:2731
//     (`getNodePtrForScan`) mints a fresh `*Node` per call — so `a = b` is
//     never true, even for the same node.
//
//   BUG 7 — `length(path)` through a `WITH` projection always returns 0.
//     The var-length executor materializes the `.Path` into the row
//     (match_operations.zig:7471-7496) and, for the WITH case, emits raw env
//     values in order `left, right, rel, path` (:7565-7569) — but the column
//     name builder at :10910-10916 emits only
//     `left_node_var, rel_var, right_node_var` with NO chain_path_var. Env.get
//     (value_types.zig:170-175) resolves by name, so `path` becomes Null and
//     `length(Null)` hits the catch-all `else => Int 0` at eval.zig:2593-2601.
//
//   BUG 7 sibling — on the same lines, the row order is `left, right, rel`
//     while the column order is `left, rel, right`, so whenever the pattern
//     names a relationship variable the rel and right-node values are
//     TRANSPOSED into each other's columns. The bug-7 repro used an anonymous
//     relationship, so it never surfaced.
//
// Tests marked "(control)" must pass BOTH before and after the fix — they pin
// that a fix does not over-reach into shapes that are already correct.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const Value = geode.value_types.Value;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const Harness = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    session: execution.SessionState,
    ctx: execution.ExecutionContext,

    pub fn init(allocator: std.mem.Allocator) !Harness {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);

        graph_store.setDataDirOverride(allocator, data_dir);
        _ = graph_store.getGlobalStore(allocator);

        const catalog = try execution.ensureCatalogInstance(allocator);

        return .{
            .allocator = allocator,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .tmp = tmp,
            .data_dir = data_dir,
            .session = execution.SessionState.init(allocator),
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    pub fn deinit(self: *Harness) void {
        self.session.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.arena.deinit();
        self.tmp.cleanup();
    }

    pub fn exec(self: *Harness, query: []const u8) !execution.ExecutionResult {
        self.ctx.session_state = &self.session;
        const aa = self.arena.allocator();
        var parsed = try geode.parseGqlOptions(query, aa, .{});
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }
};

// ---------------------------------------------------------------------------
// Order-insensitive assertion helpers. The legacy executor emits rows in
// storage-iteration order, so every assertion compares sorted multisets.
// ---------------------------------------------------------------------------

fn strLess(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.order(u8, a, b) == .lt;
}

fn intLess(_: void, a: i64, b: i64) bool {
    return a < b;
}

fn sortedStrCol(allocator: std.mem.Allocator, res: execution.ExecutionResult, col: usize) ![][]const u8 {
    const out = try allocator.alloc([]const u8, res.rows.len);
    for (res.rows, 0..) |row, i| {
        out[i] = switch (row[col]) {
            .Str => |s| s,
            .Text => |s| s,
            else => return error.ExpectedStringColumn,
        };
    }
    std.mem.sort([]const u8, out, {}, strLess);
    return out;
}

fn sortedIntCol(allocator: std.mem.Allocator, res: execution.ExecutionResult, col: usize) ![]i64 {
    const out = try allocator.alloc(i64, res.rows.len);
    for (res.rows, 0..) |row, i| {
        out[i] = switch (row[col]) {
            .Int => |v| v,
            .BigInt => |v| v,
            else => return error.ExpectedIntColumn,
        };
    }
    std.mem.sort(i64, out, {}, intLess);
    return out;
}

fn expectStrCol(h: *Harness, res: execution.ExecutionResult, col: usize, expected: []const []const u8) !void {
    const actual = try sortedStrCol(h.arena.allocator(), res, col);
    try testing.expectEqual(expected.len, actual.len);
    for (expected, actual) |e, a| try testing.expectEqualStrings(e, a);
}

fn firstInt(res: execution.ExecutionResult) !i64 {
    try testing.expectEqual(@as(usize, 1), res.rows.len);
    return switch (res.rows[0][0]) {
        .Int => |i| i,
        .BigInt => |i| i,
        else => error.ExpectedInt,
    };
}

// ---------------------------------------------------------------------------
// BUG 5 — chained MATCH loses the first clause's inline property scoping
// ---------------------------------------------------------------------------

// alice has exactly ONE friendship (alice-bob). carol/dave/erin have their own
// FRIENDS_WITH edges that alice must never see. This mirrors the reported
// repro's shape ("one real friendship for alice plus many unrelated users").
fn seedSocial(h: *Harness, graph: []const u8) !void {
    var buf: [128]u8 = undefined;
    _ = try h.exec(try std.fmt.bufPrint(&buf, "CREATE GRAPH {s}", .{graph}));
    _ = try h.exec(try std.fmt.bufPrint(&buf, "USE GRAPH {s}", .{graph}));
    _ = try h.exec("CREATE (:User {username: 'alice'})");
    _ = try h.exec("CREATE (:User {username: 'bob'})");
    _ = try h.exec("CREATE (:User {username: 'carol'})");
    _ = try h.exec("CREATE (:User {username: 'dave'})");
    _ = try h.exec("CREATE (:User {username: 'erin'})");
    _ = try h.exec("MATCH (a:User {username:'alice'}), (b:User {username:'bob'}) CREATE (a)-[:FRIENDS_WITH]->(b)");
    _ = try h.exec("MATCH (a:User {username:'carol'}), (b:User {username:'dave'}) CREATE (a)-[:FRIENDS_WITH]->(b)");
    _ = try h.exec("MATCH (a:User {username:'dave'}), (b:User {username:'erin'}) CREATE (a)-[:FRIENDS_WITH]->(b)");
    _ = try h.exec("MATCH (a:User {username:'carol'}), (b:User {username:'erin'}) CREATE (a)-[:FRIENDS_WITH]->(b)");
}

const SINGLE_CLAUSE_FRIENDS =
    "MATCH (me:User {username: 'alice'})-[:FRIENDS_WITH]-(friend) RETURN friend.username AS username";
const TWO_CLAUSE_FRIENDS =
    "MATCH (me:User {username: 'alice'}) MATCH (me)-[:FRIENDS_WITH]-(friend) RETURN friend.username AS username";

test "bug5 regression: two-clause MATCH re-referencing an anchored var is scoped like the single-clause form" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try seedSocial(&h, "bug5a");

    // Oracle: the semantically identical single-clause form is correct today.
    const single = try h.exec(SINGLE_CLAUSE_FRIENDS);
    try expectStrCol(&h, single, 0, &.{"bob"});

    // Regression: splitting the same traversal across two MATCH clauses must
    // not widen `me` from alice to every :User node.
    const chained = try h.exec(TWO_CLAUSE_FRIENDS);
    try expectStrCol(&h, chained, 0, &.{"bob"});
}

test "bug5 regression: two-clause MATCH returns the same row count as the single-clause form" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try seedSocial(&h, "bug5b");

    const single = try h.exec(SINGLE_CLAUSE_FRIENDS);
    const chained = try h.exec(TWO_CLAUSE_FRIENDS);
    try testing.expectEqual(single.rows.len, chained.rows.len);
}

test "bug5 unit: chained MATCH whose anchor matches no node returns zero rows" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try seedSocial(&h, "bug5c");

    // Edge case: an unsatisfiable inline predicate. The single-clause form is
    // already correct (0 rows); the chained form must agree.
    const single = try h.exec("MATCH (me:User {username: 'nosuch'})-[:FRIENDS_WITH]-(friend) RETURN friend.username AS u");
    try testing.expectEqual(@as(usize, 0), single.rows.len);

    const chained = try h.exec("MATCH (me:User {username: 'nosuch'}) MATCH (me)-[:FRIENDS_WITH]-(friend) RETURN friend.username AS u");
    try testing.expectEqual(@as(usize, 0), chained.rows.len);
}

// NOTE on write amplification: the triage flagged that this executor is also
// reachable for write-carrying queries. Verified on HEAD — the query below DOES
// route here and reports the amplified match count (2 rows, one per :Doc in the
// graph), but the SET is silently DROPPED: neither doc is mutated. So the
// mutation does not amplify today; the observable defect is a no-op SET on the
// chained form. This test pins BOTH directions of the correct behavior, so it
// fails now (alice's doc is not updated) and also guards a fix from turning the
// amplified match set into an amplified WRITE (carol's doc must stay 'no').
test "bug5 regression: chained MATCH + SET mutates only the anchored node's neighbour" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    _ = try h.exec("CREATE GRAPH bug5w");
    _ = try h.exec("USE GRAPH bug5w");
    _ = try h.exec("CREATE (:User {username: 'alice'})");
    _ = try h.exec("CREATE (:User {username: 'carol'})");
    _ = try h.exec("CREATE (:Doc {title: 'aliceDoc', flag: 'no'})");
    _ = try h.exec("CREATE (:Doc {title: 'carolDoc', flag: 'no'})");
    _ = try h.exec("MATCH (a:User {username:'alice'}), (d:Doc {title:'aliceDoc'}) CREATE (a)-[:OWNS]->(d)");
    _ = try h.exec("MATCH (a:User {username:'carol'}), (d:Doc {title:'carolDoc'}) CREATE (a)-[:OWNS]->(d)");

    _ = try h.exec("MATCH (a:User {username:'alice'}) MATCH (a)-[:OWNS]->(x) SET x.flag = 'touched'");

    const after = try h.exec("MATCH (d:Doc) RETURN d.title AS t, d.flag AS f");
    try testing.expectEqual(@as(usize, 2), after.rows.len);
    for (after.rows) |row| {
        const title = row[0].Str;
        const flag = switch (row[1]) {
            .Str => |s| s,
            .Text => |s| s,
            else => return error.ExpectedStringFlag,
        };
        if (std.mem.eql(u8, title, "aliceDoc")) {
            try testing.expectEqualStrings("touched", flag);
        } else {
            // Anti-amplification guard: carol's doc is not reachable from alice.
            try testing.expectEqualStrings("no", flag);
        }
    }
}

test "bug5 control: two independent property lookups in separate MATCH clauses" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try seedSocial(&h, "bug5ctl1");

    // add_friend's shape: no variable re-referenced as a traversal anchor.
    // Correct today; must stay correct.
    const res = try h.exec("MATCH (u1:User {username: 'alice'}) MATCH (u2:User {username: 'bob'}) RETURN u1.username AS a, u2.username AS b");
    try testing.expectEqual(@as(usize, 1), res.rows.len);
    try testing.expectEqualStrings("alice", res.rows[0][0].Str);
    try testing.expectEqualStrings("bob", res.rows[0][1].Str);
}

test "bug5 control: OPTIONAL MATCH referencing a var from a single preceding MATCH" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try seedSocial(&h, "bug5ctl2");

    // Correct today; must stay correct.
    const res = try h.exec("MATCH (me:User {username: 'alice'}) OPTIONAL MATCH (me)-[:FRIENDS_WITH]-(friend) RETURN me.username AS m, friend.username AS f");
    try testing.expectEqual(@as(usize, 1), res.rows.len);
    try testing.expectEqualStrings("alice", res.rows[0][0].Str);
    try testing.expectEqualStrings("bob", res.rows[0][1].Str);
}

// ---------------------------------------------------------------------------
// BUG 5c — var-length hop chained with a further hop in ONE clause
// ---------------------------------------------------------------------------

// Friendship chain alice - bob - carol - dave, each user POSTED exactly one
// post. Distances from alice: alice=0, bob=1, carol=2, dave=3, so every
// quantifier below selects a DIFFERENT post set — honoring vs ignoring
// min_len/max_len is observable, and so is losing the anchor.
fn seedChainWithPosts(h: *Harness, graph: []const u8) !void {
    var buf: [128]u8 = undefined;
    _ = try h.exec(try std.fmt.bufPrint(&buf, "CREATE GRAPH {s}", .{graph}));
    _ = try h.exec(try std.fmt.bufPrint(&buf, "USE GRAPH {s}", .{graph}));
    inline for (.{ "alice", "bob", "carol", "dave" }) |u| {
        _ = try h.exec("CREATE (:User {username: '" ++ u ++ "'})");
        _ = try h.exec("CREATE (:Post {title: '" ++ u ++ "P'})");
        _ = try h.exec("MATCH (a:User {username:'" ++ u ++ "'}), (p:Post {title:'" ++ u ++ "P'}) CREATE (a)-[:POSTED]->(p)");
    }
    _ = try h.exec("MATCH (a:User {username:'alice'}), (b:User {username:'bob'}) CREATE (a)-[:FRIENDS_WITH]->(b)");
    _ = try h.exec("MATCH (a:User {username:'bob'}), (b:User {username:'carol'}) CREATE (a)-[:FRIENDS_WITH]->(b)");
    _ = try h.exec("MATCH (a:User {username:'carol'}), (b:User {username:'dave'}) CREATE (a)-[:FRIENDS_WITH]->(b)");
}

test "bug5c regression: var-length hop plus a fixed hop honors the anchor and the *0..1 quantifier" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try seedChainWithPosts(&h, "bug5c1");

    // *0..1 from alice reaches {alice, bob}; their posts are {aliceP, bobP}.
    // Losing the anchor pulls in carolP/daveP; ignoring min_len drops aliceP.
    const res = try h.exec("MATCH (me:User {username:'alice'})-[:FRIENDS_WITH*0..1]-(friend)-[:POSTED]->(post) RETURN post.title AS t");
    try expectStrCol(&h, res, 0, &.{ "aliceP", "bobP" });
}

test "bug5c regression: var-length hop plus a fixed hop honors the *1..2 quantifier" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try seedChainWithPosts(&h, "bug5c2");

    // *1..2 from alice reaches {bob, carol}.
    const res = try h.exec("MATCH (me:User {username:'alice'})-[:FRIENDS_WITH*1..2]-(friend)-[:POSTED]->(post) RETURN post.title AS t");
    try expectStrCol(&h, res, 0, &.{ "bobP", "carolP" });
}

test "bug5c regression: var-length hop plus a fixed hop honors the exact *2..2 quantifier" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try seedChainWithPosts(&h, "bug5c3");

    // *2..2 from alice reaches exactly {carol}.
    const res = try h.exec("MATCH (me:User {username:'alice'})-[:FRIENDS_WITH*2..2]-(friend)-[:POSTED]->(post) RETURN post.title AS t");
    try expectStrCol(&h, res, 0, &.{"carolP"});
}

test "bug5c unit: distinct quantifiers over the same chained pattern give distinct results" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try seedChainWithPosts(&h, "bug5c4");

    // Direct evidence that min_len/max_len are consulted at all: on HEAD all
    // three of these return the identical 6-row set.
    const a = try h.exec("MATCH (me:User {username:'alice'})-[:FRIENDS_WITH*0..1]-(friend)-[:POSTED]->(post) RETURN post.title AS t");
    const b = try h.exec("MATCH (me:User {username:'alice'})-[:FRIENDS_WITH*2..2]-(friend)-[:POSTED]->(post) RETURN post.title AS t");
    const sa = try sortedStrCol(h.arena.allocator(), a, 0);
    const sb = try sortedStrCol(h.arena.allocator(), b, 0);
    try testing.expect(sa.len != sb.len or !std.mem.eql(u8, sa[0], sb[0]));
}

test "bug5c control: the *0..1 segment alone is scoped correctly" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try seedChainWithPosts(&h, "bug5c5");

    // Correct today (no further hop chained on); must stay correct.
    const res = try h.exec("MATCH (me:User {username:'alice'})-[:FRIENDS_WITH*0..1]-(friend) RETURN friend.username AS u");
    try expectStrCol(&h, res, 0, &.{ "alice", "bob" });
}

test "bug5c control: a fixed two-hop chain from a property-anchored head is scoped correctly" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try seedChainWithPosts(&h, "bug5c6");

    // Correct today; pins that the fix does not regress the non-var-length
    // multi-hop shape.
    const res = try h.exec("MATCH (me:User {username:'alice'})-[:FRIENDS_WITH]-(friend)-[:POSTED]->(post) RETURN post.title AS t");
    try expectStrCol(&h, res, 0, &.{"bobP"});
}

// ---------------------------------------------------------------------------
// BUG 5d — node identity =/<> compares pointers, not ids
// ---------------------------------------------------------------------------

fn seedThreeT(h: *Harness, graph: []const u8) !void {
    var buf: [128]u8 = undefined;
    _ = try h.exec(try std.fmt.bufPrint(&buf, "CREATE GRAPH {s}", .{graph}));
    _ = try h.exec(try std.fmt.bufPrint(&buf, "USE GRAPH {s}", .{graph}));
    _ = try h.exec("CREATE (:T {k: 1})");
    _ = try h.exec("CREATE (:T {k: 2})");
    _ = try h.exec("CREATE (:T {k: 3})");
}

test "bug5d regression: node identity = matches the diagonal of a self cross product" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try seedThreeT(&h, "bug5d1");

    // Oracle: 3 x 3 = 9 pairs.
    const total = try h.exec("MATCH (a:T), (b:T) RETURN count(*) AS c");
    try testing.expectEqual(@as(i64, 9), try firstInt(total));

    // The 3 diagonal pairs must satisfy a = b. Pointer comparison returns 0.
    const eq = try h.exec("MATCH (a:T), (b:T) WHERE a = b RETURN count(*) AS c");
    try testing.expectEqual(@as(i64, 3), try firstInt(eq));
}

test "bug5d regression: node identity <> excludes the diagonal" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try seedThreeT(&h, "bug5d2");

    // 9 pairs minus the 3 diagonal pairs. Pointer comparison returns 9.
    const ne = try h.exec("MATCH (a:T), (b:T) WHERE a <> b RETURN count(*) AS c");
    try testing.expectEqual(@as(i64, 6), try firstInt(ne));
}

test "bug5d regression: <> across a traversal excludes the anchor node itself" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try seedSocial(&h, "bug5d3");

    // The reported shape. alice's only friend-of-friend through bob is alice
    // herself, so `me <> suggestion` must filter every row out.
    const identity = try h.exec("MATCH (me:User {username:'alice'})-[:FRIENDS_WITH]-(friend)-[:FRIENDS_WITH]-(suggestion) WHERE me <> suggestion RETURN suggestion.username AS s");
    try testing.expectEqual(@as(usize, 0), identity.rows.len);
}

test "bug5d control: the property-comparison workaround filters correctly" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try seedSocial(&h, "bug5d4");

    // Correct today (the reported workaround); must stay correct.
    const byprop = try h.exec("MATCH (me:User {username:'alice'})-[:FRIENDS_WITH]-(friend)-[:FRIENDS_WITH]-(suggestion) WHERE me.username <> suggestion.username RETURN suggestion.username AS s");
    try testing.expectEqual(@as(usize, 0), byprop.rows.len);

    // ...and the unfiltered form really does produce the row being filtered,
    // so the assertion above is not vacuous.
    const unfiltered = try h.exec("MATCH (me:User {username:'alice'})-[:FRIENDS_WITH]-(friend)-[:FRIENDS_WITH]-(suggestion) RETURN suggestion.username AS s");
    try expectStrCol(&h, unfiltered, 0, &.{"alice"});
}

test "bug5d regression: node identity = works on a cold (hydrated-from-disk) store" {
    const allocator = testing.allocator;

    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
    defer allocator.free(data_dir);

    // Phase A: seed, then abandon the store without a clean close so nothing
    // resident survives into phase B.
    var seed_arena = std.heap.ArenaAllocator.init(allocator);
    defer seed_arena.deinit();
    {
        const sa = seed_arena.allocator();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, data_dir);
        _ = try graph_store.initGlobalStore(sa, data_dir);
        const catalog = try execution.ensureCatalogInstance(sa);
        var session = execution.SessionState.init(sa);
        var ctx = execution.ExecutionContext{ .catalog = catalog };
        ctx.session_state = &session;
        const stmts = [_][]const u8{
            "CREATE GRAPH coldid",
            "USE GRAPH coldid",
            "CREATE (:T {k: 1})",
            "CREATE (:T {k: 2})",
            "CREATE (:T {k: 3})",
        };
        for (stmts) |q| {
            var parsed = try geode.parseGqlOptions(q, sa, .{});
            defer parsed.deinit();
            _ = try execution.executeStatementWithContext(sa, parsed.program.statements[0], ctx);
        }
        graph_store.abandonGlobalStoreForCrashSim();
        execution.cleanupCatalogInstance();
    }

    // Phase B: reopen from disk. Every node pointer now comes from a fresh
    // per-call hydration (`getNodePtrForScan`), which is the unstable-pointer
    // path the id comparison must be immune to.
    var open_arena = std.heap.ArenaAllocator.init(allocator);
    defer open_arena.deinit();
    const ra = open_arena.allocator();
    _ = try graph_store.initGlobalStore(ra, data_dir);
    defer {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, null);
    }

    const catalog = try execution.ensureCatalogInstance(ra);
    var session = execution.SessionState.init(ra);
    var ctx = execution.ExecutionContext{ .catalog = catalog };
    ctx.session_state = &session;

    const runQ = struct {
        fn call(alloc: std.mem.Allocator, c: execution.ExecutionContext, q: []const u8) !execution.ExecutionResult {
            var parsed = try geode.parseGqlOptions(q, alloc, .{});
            defer parsed.deinit();
            return execution.executeStatementWithContext(alloc, parsed.program.statements[0], c);
        }
    }.call;

    _ = try runQ(ra, ctx, "USE GRAPH coldid");
    graph_store.getGlobalStore(ra).ensureGraphHydrated("coldid");

    const total = try runQ(ra, ctx, "MATCH (a:T), (b:T) RETURN count(*) AS c");
    try testing.expectEqual(@as(i64, 9), try firstInt(total));

    const eq = try runQ(ra, ctx, "MATCH (a:T), (b:T) WHERE a = b RETURN count(*) AS c");
    try testing.expectEqual(@as(i64, 3), try firstInt(eq));

    const ne = try runQ(ra, ctx, "MATCH (a:T), (b:T) WHERE a <> b RETURN count(*) AS c");
    try testing.expectEqual(@as(i64, 6), try firstInt(ne));
}

// ---------------------------------------------------------------------------
// BUG 7 — length(path) through a WITH projection
// ---------------------------------------------------------------------------

// KNOWS chain p1 -> p2 -> p3 -> p4 so undirected *1..3 yields path lengths
// 1, 2 and 3.
fn seedKnowsChain(h: *Harness, graph: []const u8) !void {
    var buf: [128]u8 = undefined;
    _ = try h.exec(try std.fmt.bufPrint(&buf, "CREATE GRAPH {s}", .{graph}));
    _ = try h.exec(try std.fmt.bufPrint(&buf, "USE GRAPH {s}", .{graph}));
    _ = try h.exec("CREATE (:Person {name: 'p1'})-[:KNOWS]->(:Person {name: 'p2'})");
    _ = try h.exec("MATCH (a:Person {name:'p2'}) CREATE (a)-[:KNOWS]->(:Person {name: 'p3'})");
    _ = try h.exec("MATCH (a:Person {name:'p3'}) CREATE (a)-[:KNOWS]->(:Person {name: 'p4'})");
}

const BARE_LENGTH =
    "MATCH path = (p:Person)-[:KNOWS*1..3]-(friend) RETURN p.name AS n, length(path) AS L";
const WITH_LENGTH =
    "MATCH path = (p:Person)-[:KNOWS*1..3]-(friend) WITH p, friend, length(path) AS L RETURN p.name AS n, L";

test "bug7 regression: length(path) carried through WITH equals the bare RETURN form" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try seedKnowsChain(&h, "bug7a");

    const bare = try h.exec(BARE_LENGTH);
    const bare_lens = try sortedIntCol(h.arena.allocator(), bare, 1);

    // Guard: the oracle must actually contain non-trivial lengths, otherwise
    // the comparison below could pass vacuously.
    try testing.expect(bare_lens.len > 0);
    try testing.expectEqual(@as(i64, 1), bare_lens[0]);
    try testing.expectEqual(@as(i64, 3), bare_lens[bare_lens.len - 1]);

    const withp = try h.exec(WITH_LENGTH);
    const with_lens = try sortedIntCol(h.arena.allocator(), withp, 1);

    try testing.expectEqualSlices(i64, bare_lens, with_lens);
}

test "bug7 regression: a WHERE threshold on a WITH-bound path length keeps its rows" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try seedKnowsChain(&h, "bug7b");

    // Oracle: the un-WITH'd form proves length-3 paths exist.
    const bare = try h.exec("MATCH path = (p:Person)-[:KNOWS*1..3]-(friend) WHERE length(path) > 2 RETURN p.name AS n, length(path) AS L");
    try testing.expectEqual(@as(usize, 2), bare.rows.len);

    // The blog post's Tip 6 pattern: compute once via WITH, then filter.
    // Because L is constantly 0 today, this silently returns 0 rows.
    const withp = try h.exec("MATCH path = (p:Person)-[:KNOWS*1..3]-(friend) WITH p, friend, length(path) AS L WHERE L > 2 RETURN p.name AS n, L");
    try testing.expectEqual(@as(usize, 2), withp.rows.len);
    for (withp.rows) |row| {
        try testing.expectEqual(@as(i64, 3), row[1].Int);
    }
}

test "bug7 control: length(path) in a top-level RETURN is correct" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try seedKnowsChain(&h, "bug7c");

    // Correct today; must stay correct.
    const bare = try h.exec(BARE_LENGTH);
    try testing.expectEqual(@as(usize, 12), bare.rows.len);
    for (bare.rows) |row| {
        try testing.expect(row[1].Int >= 1 and row[1].Int <= 3);
    }
}

test "bug7 sibling regression: naming the relationship variable does not transpose WITH columns" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try seedKnowsChain(&h, "bug7d");

    // Oracle from the same pattern without WITH: p and friend are Nodes and
    // the var-length relationship variable is a List.
    const bare = try h.exec("MATCH path = (p:Person)-[r:KNOWS*1..3]-(friend) RETURN p, friend, r, length(path) AS L");
    try testing.expect(bare.rows.len > 0);
    for (bare.rows) |row| {
        try testing.expect(row[0] == .Node);
        try testing.expect(row[1] == .Node);
        try testing.expect(row[2] == .List);
    }

    // Routing the same bindings through WITH must not swap `friend` and `r`.
    const withp = try h.exec("MATCH path = (p:Person)-[r:KNOWS*1..3]-(friend) WITH p, friend, r, length(path) AS L RETURN p, friend, r, L");
    try testing.expectEqual(bare.rows.len, withp.rows.len);
    for (withp.rows) |row| {
        try testing.expect(row[0] == .Node);
        try testing.expect(row[1] == .Node); // friend must be the right node
        try testing.expect(row[2] == .List); // r must be the relationship list
        try testing.expect(row[3].Int >= 1);
    }
}

test "bug7 sibling regression: friend.name resolves through a WITH with a named relationship" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    try seedKnowsChain(&h, "bug7e");

    // The transposition makes `friend` hold the relationship list, so
    // friend.name evaluates to NULL on every row today.
    const res = try h.exec("MATCH path = (p:Person)-[r:KNOWS*1..3]-(friend) WITH p, friend, r, length(path) AS L RETURN p.name AS n, friend.name AS fn, L");
    try testing.expect(res.rows.len > 0);
    for (res.rows) |row| {
        try testing.expect(row[1] != .Null);
        try testing.expect(std.mem.startsWith(u8, row[1].Str, "p"));
    }
}
