// SONNY-2679 regression: a relationship pattern reached rows that the session's
// RLS policy or tenant scope hides.
//
// Every RLS session, and every session with a concrete tenant, is served by the
// legacy executor (the planned read and the node-scan fast path both decline
// it). That executor checks the START node of a pattern for tenant and RLS, but
// most of its traversals never checked the node an edge leads to:
//   * single hop (executeSingleHopEdgeTraversal): tenant, but no RLS;
//   * the aggregation loop (`count(h)`, `collect(h)`), the legacy grouping,
//     OPTIONAL MATCH and a required chain after an OPTIONAL MATCH: neither;
//   * variable length (PathIterator and its two callers): no check at all on
//     edges, the nodes a path passes through, or the node it ends at;
//   * a quantified hop inside a longer pattern (expandVarLengthHop): the end
//     node, but not the nodes in between;
//   * pattern comprehensions, COUNT {}, EXISTS {} and shortestPath()
//     (graph_algorithms.zig): tenant, but no RLS.
// So a denied node's properties (`RETURN h.s`), its count, the whole node
// inside `collect(h)`, and a path through it were all returned; an expression
// policy was never applied to a hop target at all, even for `RETURN h`; and a
// cross-tenant edge was followed by the aggregation, grouping, OPTIONAL MATCH
// and variable-length paths. (The multi-chain executor, which serves a
// fixed-length multi-hop pattern, already checked every node it bound.)
//
// The fixture is the same for every session, with one node the session may not
// see (`leak`): a label-policy session is denied its label, an expression-
// policy session is denied it by a `cls <> 'secret'` policy, and a tenant-
// scoped session finds it in another tenant, reached through edges that carry
// the reader's OWN tenant tag (so only the node check can stop the walk):
//
//     g1:G --R--> ok --R--> ok2
//      |
//      +---R--> leak --R--> far --R--> far2
//
// A session that may not see `leak` must see g1 -> ok -> ok2 and nothing else:
// not `leak`, and not `far` or `far2`, which are reachable only through it (a
// denied or foreign middle node breaks the path). The control session has no
// policy and no tenant scope, and must still see the whole fixture: the fix
// changes nothing for it.
//
// CANARY: REQ=REQ-SONNY-2679-RLS-HOP-TARGETS; FEATURE="TraversalRowVisibility"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2679_rls_hop_targets.zig; OWNER=security; UPDATED=2026-09-25

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const rls = @import("rls");
const rls_types = @import("rls_types");
const harness = @import("node_scan_stream_harness.zig");

const execution = geode.execution;
const graph_store = geode.graph_store;
const planned_read_runtime = geode.planned_read_runtime;
const Value = geode.value_types.Value;

/// How the session is restricted.
const Mode = enum {
    /// No policy, no tenant scope, in-memory store: the legacy executor, and
    /// the whole fixture is visible.
    no_policy,
    /// A label-deny policy on `:Hidden` for the session user.
    label_policy,
    /// An expression policy on `:Doc`: a row is visible iff `cls <> 'secret'`.
    expr_policy,
    /// Session tenant `tenant_a`; `leak` belongs to `tenant_b`.
    tenant_scoped,
};

const tenant_a = "tenant_a";
const tenant_b = "tenant_b";
const session_user = "bob";

// The expression policy's bytecode: `row.cls <> 'secret'`.
//   load_row 0; push_const 1; neq; ret
const expr_constants = [_]rls.Value{ .{ .string = "cls" }, .{ .string = "secret" } };
const expr_bytecode = [_]u8{ 0x10, 0x00, 0x01, 0x01, 0x21, 0xFF };

const Session = struct {
    mode: Mode,
    arena: std.heap.ArenaAllocator,
    tmp: ?std.testing.TmpDir,
    data_dir: ?[]u8,
    ctx: execution.ExecutionContext,
    label_engine: ?*rls_types.RLSFilterEngine = null,
    expr_engine: ?*rls.RLSEngine = null,
    compiled: rls.RLSEngine.CompiledExpression = .{ .bytecode = &expr_bytecode, .constants = &expr_constants, .jump_table = &.{} },

    fn init(mode: Mode) !Session {
        const allocator = testing.allocator;
        // shortestPath(), COUNT {}, EXISTS {} and pattern comprehensions reach
        // graph_algorithms.zig through the evaluator callbacks the server
        // installs at startup.
        execution.initEvaluator();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, null);
        var tmp: ?std.testing.TmpDir = null;
        var data_dir: ?[]u8 = null;
        errdefer {
            if (data_dir) |d| allocator.free(d);
            if (tmp) |*t| t.cleanup();
        }
        // A restricted session runs on a persisted store, so the planned read
        // would serve these reads if it did not decline them.
        const persisted = mode != .no_policy;
        if (persisted) {
            tmp = std.testing.tmpDir(.{});
            data_dir = try harness.tmpDirRealpathAlloc(allocator, &tmp.?.sub_path);
            graph_store.setDataDirOverride(allocator, data_dir.?);
        }
        _ = graph_store.getGlobalStore(allocator);
        if (persisted != (graph_store.getGlobalAdapter() != null)) return error.WrongDeployment;
        const catalog = try execution.ensureCatalogInstance(allocator);
        return .{ .mode = mode, .arena = std.heap.ArenaAllocator.init(allocator), .tmp = tmp, .data_dir = data_dir, .ctx = .{ .catalog = catalog } };
    }

    fn deinit(self: *Session) void {
        if (self.label_engine) |engine| {
            rls_types.setGlobalRLSFilterEngine(null);
            engine.deinit();
            testing.allocator.destroy(engine);
        }
        if (self.expr_engine) |engine| {
            rls_types.setGlobalExprRLSEngine(null);
            engine.deinit();
            testing.allocator.destroy(engine);
        }
        self.arena.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(testing.allocator, null);
        if (self.data_dir) |d| testing.allocator.free(d);
        if (self.tmp) |*t| t.cleanup();
    }

    fn run(self: *Session, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    /// Run a write as `tenant` (null: unscoped).
    fn execAs(self: *Session, tenant: ?[]const u8, query: []const u8) !void {
        const saved = self.ctx.tenant_id;
        defer self.ctx.tenant_id = saved;
        self.ctx.tenant_id = tenant;
        const prev = execution.pushActiveContext(&self.ctx);
        defer execution.popActiveContext(prev);
        var r = try self.run(query);
        r.deinit(self.arena.allocator());
    }

    fn idOf(self: *Session, s: []const u8) !u64 {
        _ = self;
        const store = graph_store.getGlobalStore(testing.allocator);
        var it = store.nodes.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.properties.get("s")) |pv| {
                if (pv == .String and std.mem.eql(u8, pv.String, s)) return entry.key_ptr.*;
            }
        }
        return error.NodeNotFound;
    }

    /// Seed the fixture in the file header, then restrict the session.
    fn seed(self: *Session) !void {
        const owner: ?[]const u8 = if (self.mode == .tenant_scoped) tenant_a else null;
        try self.execAs(owner, "CREATE (:G {s: 'g1'})");
        try self.execAs(owner, "MATCH (g:G {s: 'g1'}) CREATE (g)-[:R]->(:Doc {s: 'ok', cls: 'public'})");
        try self.execAs(owner, "MATCH (o:Doc {s: 'ok'}) CREATE (o)-[:R]->(:Doc {s: 'ok2', cls: 'public'})");
        try self.execAs(owner, "CREATE (:Doc {s: 'far', cls: 'public'})");
        try self.execAs(owner, "CREATE (:Doc {s: 'far2', cls: 'public'})");
        try self.execAs(owner, "MATCH (f:Doc {s: 'far'}), (f2:Doc {s: 'far2'}) CREATE (f)-[:R]->(f2)");

        switch (self.mode) {
            .no_policy, .label_policy => {
                try self.execAs(null, "CREATE (:Hidden {s: 'leak', cls: 'secret'})");
                try self.execAs(null, "MATCH (g:G {s: 'g1'}), (b:Hidden {s: 'leak'}) CREATE (g)-[:R]->(b)");
                try self.execAs(null, "MATCH (b:Hidden {s: 'leak'}), (f:Doc {s: 'far'}) CREATE (b)-[:R]->(f)");
            },
            .expr_policy => {
                try self.execAs(null, "CREATE (:Doc {s: 'leak', cls: 'secret'})");
                try self.execAs(null, "MATCH (g:G {s: 'g1'}), (b:Doc {s: 'leak'}) CREATE (g)-[:R]->(b)");
                try self.execAs(null, "MATCH (b:Doc {s: 'leak'}), (f:Doc {s: 'far'}) CREATE (b)-[:R]->(f)");
            },
            .tenant_scoped => {
                // `leak` is tenant B's; both edges touching it carry tenant A's
                // own tag, so they pass the edge-tag check and only the node
                // check can keep A out.
                try self.execAs(tenant_b, "CREATE (:Doc {s: 'leak', cls: 'secret'})");
                const store = graph_store.getGlobalStore(testing.allocator);
                const g1 = try self.idOf("g1");
                const leak = try self.idOf("leak");
                const far = try self.idOf("far");
                _ = try store.createEdgeWithGraphAndTenant(g1, leak, "R", graph_store.DEFAULT_GRAPH_NAME, tenant_a);
                _ = try store.createEdgeWithGraphAndTenant(leak, far, "R", graph_store.DEFAULT_GRAPH_NAME, tenant_a);
                const leak_node = store.nodes.get(leak) orelse return error.NodeNotFound;
                if (!std.mem.eql(u8, leak_node.tenant_id, tenant_b)) return error.WriteDidNotCarryTenantTag;
            },
        }

        switch (self.mode) {
            .no_policy => {},
            .label_policy => {
                const engine = try testing.allocator.create(rls_types.RLSFilterEngine);
                engine.* = rls_types.RLSFilterEngine.init(testing.allocator);
                self.label_engine = engine;
                try engine.addDenyPolicy(graph_store.DEFAULT_GRAPH_NAME, "Hidden", session_user);
                rls_types.setGlobalRLSFilterEngine(engine);
                self.ctx.user = session_user;
            },
            .expr_policy => {
                const engine = try testing.allocator.create(rls.RLSEngine);
                engine.* = rls.RLSEngine.init(testing.allocator) catch |err| {
                    testing.allocator.destroy(engine);
                    return err;
                };
                self.expr_engine = engine;
                try engine.createPolicy(.{
                    .id = 2679,
                    .name = "doc_not_secret",
                    .description = "a :Doc row is visible iff cls <> 'secret'",
                    .graph = graph_store.DEFAULT_GRAPH_NAME,
                    .table = "Doc",
                    .operation = .all,
                    .permissive = false,
                    .roles = &.{},
                    .using_expr = .{ .raw = "cls <> 'secret'", .parsed = null, .compiled = &self.compiled, .parameters = &.{} },
                    .check_expr = null,
                    .enabled = true,
                    .created_at = 0,
                    .updated_at = 0,
                    .created_by = 0,
                    .temporal = null,
                    .data_classification = null,
                    .audit_level = .none,
                });
                rls_types.setGlobalExprRLSEngine(@ptrCast(engine));
                self.ctx.user = session_user;
            },
            .tenant_scoped => self.ctx.tenant_id = tenant_a,
        }
    }
};

fn nodeName(n: *const graph_store.Node) []const u8 {
    if (n.properties.get("s")) |pv| {
        if (pv == .String) return pv.String;
    }
    return "?";
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// A cell as text: a node as `(s)`, a path as `p(s>s>...)`, a list as its
/// items sorted (a traversal's order is not part of the contract).
fn render(aa: std.mem.Allocator, v: Value) anyerror![]const u8 {
    return switch (v) {
        .Str, .Text => |s| s,
        .Int => |n| try std.fmt.allocPrint(aa, "{d}", .{n}),
        .Bool => |b| if (b) "true" else "false",
        .Null => "null",
        .Node => |n| try std.fmt.allocPrint(aa, "({s})", .{nodeName(n)}),
        .Edge => |e| try std.fmt.allocPrint(aa, "[{s}]", .{e.label}),
        .Path => |p| blk: {
            var out: std.ArrayList(u8) = .empty;
            try out.appendSlice(aa, "p(");
            for (p.nodes, 0..) |n, i| {
                if (i > 0) try out.append(aa, '>');
                try out.appendSlice(aa, nodeName(n));
            }
            try out.append(aa, ')');
            break :blk try out.toOwnedSlice(aa);
        },
        .List => |items| blk: {
            const parts = try aa.alloc([]const u8, items.len);
            for (items, parts) |item, *part| part.* = try render(aa, item);
            std.mem.sort([]const u8, parts, {}, lessThan);
            break :blk try std.fmt.allocPrint(aa, "[{s}]", .{try std.mem.join(aa, ",", parts)});
        },
        else => try std.fmt.allocPrint(aa, "<{s}>", .{@tagName(v)}),
    };
}

/// Every failed check, reported together.
const Failures = struct {
    items: std.ArrayList([]const u8) = .empty,

    fn add(self: *Failures, aa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
        try self.items.append(aa, try std.fmt.allocPrint(aa, fmt, args));
    }
};

/// `query` returns exactly `want`, in any order. A restricted session's MATCH
/// must also be served by the legacy executor (the planned read declined it).
fn expectRows(s: *Session, f: *Failures, query: []const u8, want: []const []const u8) !void {
    const aa = s.arena.allocator();
    planned_read_runtime.resetPathRowsMaterialized();
    var result = s.run(query) catch |err| {
        try f.add(aa, "[{s}] {s}: error {s}", .{ @tagName(s.mode), query, @errorName(err) });
        return;
    };
    defer result.deinit(aa);
    const planned = planned_read_runtime.getPathRowsMaterialized();
    if (s.mode != .no_policy and planned != 0 and std.mem.startsWith(u8, query, "MATCH")) {
        try f.add(aa, "[{s}] {s}: served by the planned read ({d} materialized)", .{ @tagName(s.mode), query, planned });
    }

    const got = try aa.alloc([]const u8, result.rows.len);
    for (result.rows, got) |row, *g| {
        const cells = try aa.alloc([]const u8, row.len);
        for (row, cells) |cell, *c| c.* = try render(aa, cell);
        g.* = try std.mem.join(aa, "|", cells);
    }
    std.mem.sort([]const u8, got, {}, lessThan);
    const exp = try aa.dupe([]const u8, want);
    std.mem.sort([]const u8, exp, {}, lessThan);
    const same = got.len == exp.len and for (got, exp) |g, w| {
        if (!std.mem.eql(u8, g, w)) break false;
    } else true;
    if (!same) {
        const want_text = try std.mem.join(aa, ",", exp);
        const got_text = try std.mem.join(aa, ",", got);
        try f.add(aa, "[{s}] {s}: expected {d} rows {{{s}}}, got {d} {{{s}}}", .{ @tagName(s.mode), query, exp.len, want_text, got.len, got_text });
    }
}

const Case = struct {
    q: []const u8,
    /// What a session that may see only g1 -> ok -> ok2 gets.
    secure: []const []const u8,
    /// What the control session (no policy, no tenant scope) gets: the whole
    /// fixture, as before the fix.
    open: []const []const u8,
};

const cases = [_]Case{
    // Single hop: executeSingleHopEdgeTraversal, and the aggregation loop for
    // count/collect (both edge directions).
    .{ .q = "MATCH (g:G)-[:R]->(h) RETURN h.s", .secure = &.{"ok"}, .open = &.{ "leak", "ok" } },
    .{ .q = "MATCH (g:G)-[:R]->(h) RETURN count(h)", .secure = &.{"1"}, .open = &.{"2"} },
    .{ .q = "MATCH (g:G)-[:R]->(h) RETURN collect(h)", .secure = &.{"[(ok)]"}, .open = &.{"[(leak),(ok)]"} },
    .{ .q = "MATCH (g:G)-[:R]->(h) RETURN h", .secure = &.{"(ok)"}, .open = &.{ "(leak)", "(ok)" } },
    .{ .q = "MATCH (g:G)-[:R]-(h) RETURN h.s", .secure = &.{"ok"}, .open = &.{ "leak", "ok" } },
    // (A WHERE, not an inline `{s: 'far'}`: the aggregation loop ignores the
    // left node's inline properties, a separate pre-existing defect.)
    .{ .q = "MATCH (f)<-[:R]-(h) WHERE f.s = 'far' RETURN h.s", .secure = &.{}, .open = &.{"leak"} },
    .{ .q = "MATCH (f)<-[:R]-(h) WHERE f.s = 'far' RETURN count(h)", .secure = &.{"0"}, .open = &.{"1"} },
    // GROUP BY over the targets: a RETURN-level GROUP BY (the shared
    // projection over the single-hop bindings), a WITH-stage GROUP BY, and a
    // RETURN GROUP BY after a WITH (the legacy grouping loop).
    .{ .q = "MATCH (g:G)-[:R]->(h) RETURN h.s, count(*) AS c GROUP BY h.s", .secure = &.{"ok|1"}, .open = &.{ "leak|1", "ok|1" } },
    .{ .q = "MATCH (g:G)-[:R]->(h) WITH h.s AS k, count(*) AS c GROUP BY h.s RETURN k, c", .secure = &.{"ok|1"}, .open = &.{ "leak|1", "ok|1" } },
    .{ .q = "MATCH (g:G)-[:R]->(h) WITH g, h RETURN h.s, count(*) AS c GROUP BY h.s", .secure = &.{"ok|1"}, .open = &.{ "leak|1", "ok|1" } },

    // Multi-hop: executeMultiChainRelationshipMatch. A denied middle node
    // breaks the path.
    .{ .q = "MATCH (g:G)-[:R]->(m)-[:R]->(h) RETURN h.s", .secure = &.{"ok2"}, .open = &.{ "far", "ok2" } },
    .{ .q = "MATCH (g:G)-[:R]->(m)-[:R]->(h) RETURN m.s, h.s", .secure = &.{"ok|ok2"}, .open = &.{ "leak|far", "ok|ok2" } },
    // (Grouped by the start node: this executor evaluates an UNGROUPED
    // aggregate once per binding, a separate pre-existing defect.)
    .{ .q = "MATCH (g:G)-[:R]->(m)-[:R]->(h) RETURN g.s, count(h) AS c GROUP BY g.s", .secure = &.{"g1|1"}, .open = &.{"g1|2"} },
    .{ .q = "MATCH (g:G)-[:R]->(m)-[:R]->(h) RETURN g.s, collect(h) AS hs GROUP BY g.s", .secure = &.{"g1|[(ok2)]"}, .open = &.{"g1|[(far),(ok2)]"} },
    .{ .q = "MATCH (g:G)-[:R]->(m)-[:R]->(h) RETURN h", .secure = &.{"(ok2)"}, .open = &.{ "(far)", "(ok2)" } },
    .{ .q = "MATCH (g:G)-[:R]->(m)-[:R]->(h) RETURN h.s, count(*) AS c GROUP BY h.s", .secure = &.{"ok2|1"}, .open = &.{ "far|1", "ok2|1" } },
    .{ .q = "MATCH (g:G)-[:R]->(a)-[:R]->(b)-[:R]->(c) RETURN c.s", .secure = &.{}, .open = &.{"far2"} },

    // Variable length: executeVariableLengthPathTraversal and the aggregation
    // path, both over PathIterator. A denied middle node breaks the path.
    .{ .q = "MATCH (g:G)-[:R*1..3]->(h) RETURN h.s", .secure = &.{ "ok", "ok2" }, .open = &.{ "far", "far2", "leak", "ok", "ok2" } },
    .{ .q = "MATCH (g:G)-[:R*1..3]->(h) RETURN count(h)", .secure = &.{"2"}, .open = &.{"5"} },
    .{ .q = "MATCH (g:G)-[:R*1..3]->(h) RETURN collect(h)", .secure = &.{"[(ok),(ok2)]"}, .open = &.{"[(far),(far2),(leak),(ok),(ok2)]"} },
    .{ .q = "MATCH (g:G)-[:R*1..3]->(h) RETURN h", .secure = &.{ "(ok)", "(ok2)" }, .open = &.{ "(far)", "(far2)", "(leak)", "(ok)", "(ok2)" } },
    .{ .q = "MATCH (g:G)-[:R*1..3]->(h) RETURN h.s, count(*) AS c GROUP BY h.s", .secure = &.{ "ok|1", "ok2|1" }, .open = &.{ "far|1", "far2|1", "leak|1", "ok|1", "ok2|1" } },
    .{ .q = "MATCH p = (g:G)-[:R*1..3]->(h) RETURN p", .secure = &.{ "p(g1>ok)", "p(g1>ok>ok2)" }, .open = &.{ "p(g1>leak)", "p(g1>leak>far)", "p(g1>leak>far>far2)", "p(g1>ok)", "p(g1>ok>ok2)" } },
    .{ .q = "MATCH (g:G)-[:R*2..3]->(h) RETURN h.s", .secure = &.{"ok2"}, .open = &.{ "far", "far2", "ok2" } },
    .{ .q = "MATCH (g:G)-[:R*2..3]->(h) RETURN count(h)", .secure = &.{"1"}, .open = &.{"3"} },
    // A quantified hop inside a longer pattern: expandVarLengthHop.
    .{ .q = "MATCH (g:G)-[:R*1..2]->(m)-[:R]->(h) RETURN m.s, h.s", .secure = &.{"ok|ok2"}, .open = &.{ "far|far2", "leak|far", "ok|ok2" } },

    // OPTIONAL MATCH, and a required chain after an OPTIONAL MATCH.
    .{ .q = "MATCH (g:G) OPTIONAL MATCH (g)-[:R]->(h) RETURN h.s", .secure = &.{"ok"}, .open = &.{ "leak", "ok" } },
    .{ .q = "MATCH (g:G) OPTIONAL MATCH (g)-[:Q]->(z) MATCH (g)-[:R]->(h) RETURN h.s", .secure = &.{"ok"}, .open = &.{ "leak", "ok" } },

    // The expression path (graph_algorithms.zig).
    .{ .q = "MATCH (g:G) RETURN [(g)-[:R]->(h) | h.s] AS xs", .secure = &.{"[ok]"}, .open = &.{"[leak,ok]"} },
    .{ .q = "MATCH (g:G) RETURN COUNT { (g)-[:R]->(h) } AS c", .secure = &.{"1"}, .open = &.{"2"} },
    .{ .q = "MATCH (g:G) RETURN COUNT { (g)-[:R*1..3]->(h) } AS c", .secure = &.{"2"}, .open = &.{"5"} },
    .{ .q = "MATCH (g:G) RETURN EXISTS { (g)-[:R]->(h {s: 'leak'}) } AS e", .secure = &.{"false"}, .open = &.{"true"} },
    .{ .q = "RETURN [(h {s: 'leak'}) | h.s] AS xs", .secure = &.{"[]"}, .open = &.{"[leak]"} },
    .{ .q = "RETURN shortestPath((a:G {s: 'g1'})-[*]-(b {s: 'far'})) AS p", .secure = &.{"null"}, .open = &.{"p(g1>leak>far)"} },
};

fn checkMode(mode: Mode) !void {
    harness.silenceEngineLogs();
    var s = try Session.init(mode);
    defer s.deinit();
    try s.seed();
    var f: Failures = .{};

    for (cases) |c| try expectRows(&s, &f, c.q, if (mode == .no_policy) c.open else c.secure);

    if (f.items.items.len != 0) {
        std.debug.print("\n[{s}] {d} failed check(s):\n", .{ @tagName(mode), f.items.items.len });
        for (f.items.items) |msg| std.debug.print("  {s}\n", .{msg});
        return error.HopTargetVisibilityWrong;
    }
}

test "SONNY-2679: with no policy and no tenant scope, a traversal still sees the whole graph" {
    try checkMode(.no_policy);
}

test "SONNY-2679: a label-deny policy hides a hop target, and a path through it, on every traversal" {
    try checkMode(.label_policy);
}

test "SONNY-2679: an expression policy hides a hop target, and a path through it, on every traversal" {
    try checkMode(.expr_policy);
}

test "SONNY-2679: a tenant-scoped session does not follow an edge into another tenant on any traversal" {
    try checkMode(.tenant_scoped);
}
