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
// And no traversal applied RLS to an EDGE: a label-deny policy on a
// relationship type, or an expression policy on one, hid nothing (review of
// fadaedd1, probe P1).
//
// The fixture is the same for every session, with one node the session may not
// see (`leak`) and one edge it may not walk (the SECRET edge):
//
//     g1:G --R--> ok --R--> ok2
//      | \
//      |  +--R--> leak --R--> far --R--> far2
//      |
//      +--SECRET {x: 'topsecret'}--> viaSecret --R--> beyond
//
//   * label policy: `:Hidden` (leak's label) and the SECRET type are denied;
//   * expression policy: a `:Doc` row needs `cls <> 'secret'` (leak is secret)
//     and a SECRET edge needs `x <> 'topsecret'`;
//   * tenant scope: the reader is tenant_a; leak is tenant_b's, reached through
//     edges carrying the READER's own tag (so only the node check can stop the
//     walk); the SECRET edge is tagged tenant_b although both its endpoints are
//     tenant_a's (a foreign edge between two visible nodes);
//   * tenant hierarchy: the reader is t_parent; ok and ok2 (and the edge
//     between them) belong to its child t_child and stay visible; leak and the
//     SECRET edge belong to its sibling t_sibling.
//
// A restricted session must see g1 -> ok -> ok2, far, far2, viaSecret and
// beyond as nodes, but not `leak`, not the SECRET edge, and not what is
// reachable only through them: a denied node or edge breaks every path through
// it. The control session has no policy and no tenant scope, and must still
// see the whole fixture: the fix changes nothing for it.
//
// SONNY-2693: a tenant-scoped session still walks the foreign SECRET edge where
// the path admits an edge whose two endpoints are visible (the multi-chain
// executor's first hop, and the expression path). Those expectations are
// pinned as `bridged` below, so the rule SONNY-2693 settles on must update
// them on purpose.
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
    /// Label-deny policies on `:Hidden` and on the SECRET relationship type.
    label_policy,
    /// Expression policies: a `:Doc` row needs `cls <> 'secret'`, a SECRET
    /// edge needs `x <> 'topsecret'`.
    expr_policy,
    /// Session tenant `tenant_a`; `leak` and the SECRET edge are `tenant_b`'s.
    tenant_scoped,
    /// Session tenant `t_parent`; `ok`/`ok2` are its child's, `leak` and the
    /// SECRET edge its sibling's.
    tenant_hierarchy,

    fn tenantScoped(mode: Mode) bool {
        return mode == .tenant_scoped or mode == .tenant_hierarchy;
    }
};

/// Who owns the fixture's nodes, and which tenant tag its edges carry.
const Owners = struct {
    /// g1, far, far2, viaSecret, beyond, and every reader-owned edge.
    reader: ?[]const u8,
    /// ok and ok2, and the edge between them.
    child: ?[]const u8,
    /// leak, and the SECRET edge.
    foreign: ?[]const u8,

    fn of(mode: Mode) Owners {
        return switch (mode) {
            .no_policy, .label_policy, .expr_policy => .{ .reader = null, .child = null, .foreign = null },
            .tenant_scoped => .{ .reader = "tenant_a", .child = "tenant_a", .foreign = "tenant_b" },
            .tenant_hierarchy => .{ .reader = "t_parent", .child = "t_child", .foreign = "t_sibling" },
        };
    }

    fn tag(owner: ?[]const u8) []const u8 {
        return owner orelse graph_store.DEFAULT_TENANT_ID;
    }
};

const session_user = "bob";

// The expression policies' bytecode: load_row 0; push_const 1; neq; ret
const neq_bytecode = [_]u8{ 0x10, 0x00, 0x01, 0x01, 0x21, 0xFF };
// `:Doc` rows: `row.cls <> 'secret'`.
const doc_constants = [_]rls.Value{ .{ .string = "cls" }, .{ .string = "secret" } };
// SECRET edges: `row.x <> 'topsecret'`.
const secret_constants = [_]rls.Value{ .{ .string = "x" }, .{ .string = "topsecret" } };

const Session = struct {
    mode: Mode,
    arena: std.heap.ArenaAllocator,
    tmp: ?std.testing.TmpDir,
    data_dir: ?[]u8,
    ctx: execution.ExecutionContext,
    label_engine: ?*rls_types.RLSFilterEngine = null,
    expr_engine: ?*rls.RLSEngine = null,
    doc_compiled: rls.RLSEngine.CompiledExpression = .{ .bytecode = &neq_bytecode, .constants = &doc_constants, .jump_table = &.{} },
    secret_compiled: rls.RLSEngine.CompiledExpression = .{ .bytecode = &neq_bytecode, .constants = &secret_constants, .jump_table = &.{} },

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

    /// Run a statement in the (restricted) session.
    fn exec(self: *Session, query: []const u8) !void {
        return self.execAs(self.ctx.tenant_id, query);
    }

    fn edge(self: *Session, from: []const u8, to: []const u8, rel: []const u8, owner: ?[]const u8) !u64 {
        _ = self;
        const store = graph_store.getGlobalStore(testing.allocator);
        return store.createEdgeWithGraphAndTenant(try idOf(from), try idOf(to), rel, graph_store.DEFAULT_GRAPH_NAME, Owners.tag(owner));
    }

    /// Seed the fixture in the file header, then restrict the session.
    fn seed(self: *Session) !void {
        const o = Owners.of(self.mode);
        try self.execAs(o.reader, "CREATE (:G {s: 'g1'})");
        try self.execAs(o.child, "CREATE (:Doc {s: 'ok', cls: 'public'})");
        try self.execAs(o.child, "CREATE (:Doc {s: 'ok2', cls: 'public'})");
        for ([_][]const u8{ "far", "far2", "viaSecret", "beyond" }) |s| {
            try self.execAs(o.reader, try std.fmt.allocPrint(self.arena.allocator(), "CREATE (:Doc {{s: '{s}', cls: 'public'}})", .{s}));
        }
        const create_leak: []const u8 = switch (self.mode) {
            .no_policy, .label_policy => "CREATE (:Hidden {s: 'leak', cls: 'secret'})",
            else => "CREATE (:Doc {s: 'leak', cls: 'secret'})",
        };
        try self.execAs(o.foreign, create_leak);

        _ = try self.edge("g1", "ok", "R", o.reader);
        _ = try self.edge("ok", "ok2", "R", o.child);
        // Both edges touching `leak` carry the READER's tag, so only the node
        // check can keep a tenant-scoped reader out.
        _ = try self.edge("g1", "leak", "R", o.reader);
        _ = try self.edge("leak", "far", "R", o.reader);
        _ = try self.edge("far", "far2", "R", o.reader);
        const secret = try self.edge("g1", "viaSecret", "SECRET", o.foreign);
        _ = try self.edge("viaSecret", "beyond", "R", o.reader);
        const store = graph_store.getGlobalStore(testing.allocator);
        try store.setEdgeProperty(secret, "x", .{ .String = "topsecret" });
        if (o.foreign) |foreign| {
            const leak_node = store.nodes.get(try idOf("leak")) orelse return error.NodeNotFound;
            if (!std.mem.eql(u8, leak_node.tenant_id, foreign)) return error.WriteDidNotCarryTenantTag;
        }

        switch (self.mode) {
            .no_policy => {},
            .label_policy => {
                const engine = try testing.allocator.create(rls_types.RLSFilterEngine);
                engine.* = rls_types.RLSFilterEngine.init(testing.allocator);
                self.label_engine = engine;
                try engine.addDenyPolicy(graph_store.DEFAULT_GRAPH_NAME, "Hidden", session_user);
                try engine.addDenyPolicy(graph_store.DEFAULT_GRAPH_NAME, "SECRET", session_user);
                rls_types.setGlobalRLSFilterEngine(engine);
                self.ctx.user = session_user;
            },
            .expr_policy => {
                const engine = try self.createExprEngine();
                try engine.createPolicy(policy(2679, "doc_not_secret", "Doc", "cls <> 'secret'", &self.doc_compiled));
                try engine.createPolicy(policy(2680, "secret_edge_not_topsecret", "SECRET", "x <> 'topsecret'", &self.secret_compiled));
                self.ctx.user = session_user;
            },
            .tenant_scoped => self.ctx.tenant_id = o.reader,
            .tenant_hierarchy => {
                // No policy: the engine carries the tenant hierarchy only.
                const engine = try self.createExprEngine();
                try engine.hierarchy_manager.addTenant("t_parent", null);
                try engine.hierarchy_manager.addTenant("t_child", "t_parent");
                try engine.hierarchy_manager.addTenant("t_sibling", null);
                self.ctx.tenant_id = o.reader;
            },
        }
    }

    fn createExprEngine(self: *Session) !*rls.RLSEngine {
        const engine = try testing.allocator.create(rls.RLSEngine);
        engine.* = rls.RLSEngine.init(testing.allocator) catch |err| {
            testing.allocator.destroy(engine);
            return err;
        };
        self.expr_engine = engine;
        rls_types.setGlobalExprRLSEngine(@ptrCast(engine));
        return engine;
    }
};

fn policy(id: u64, name: []const u8, table: []const u8, raw: []const u8, compiled: *rls.RLSEngine.CompiledExpression) rls.RLSEngine.Policy {
    return .{
        .id = id,
        .name = name,
        .description = name,
        .graph = graph_store.DEFAULT_GRAPH_NAME,
        .table = table,
        .operation = .all,
        .permissive = false,
        .roles = &.{},
        .using_expr = .{ .raw = raw, .parsed = null, .compiled = compiled, .parameters = &.{} },
        .check_expr = null,
        .enabled = true,
        .created_at = 0,
        .updated_at = 0,
        .created_by = 0,
        .temporal = null,
        .data_classification = null,
        .audit_level = .none,
    };
}

fn idOf(s: []const u8) !u64 {
    const store = graph_store.getGlobalStore(testing.allocator);
    var it = store.nodes.iterator();
    while (it.next()) |entry| {
        if (entry.value_ptr.*.properties.get("s")) |pv| {
            if (pv == .String and std.mem.eql(u8, pv.String, s)) return entry.key_ptr.*;
        }
    }
    return error.NodeNotFound;
}

fn nodeName(n: *const graph_store.Node) []const u8 {
    if (n.properties.get("s")) |pv| {
        if (pv == .String) return pv.String;
    }
    return "?";
}

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// A cell as text: a node as `(s)`, an edge as `[TYPE]`, a path as
/// `p(s>s>...)`, a list as its items sorted (a traversal's order is not part
/// of the contract).
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
    /// What a restricted session gets: g1 -> ok -> ok2, and nothing reached
    /// through `leak` or the SECRET edge.
    secure: []const []const u8,
    /// What the control session (no policy, no tenant scope) gets: the whole
    /// fixture, as before the fix.
    open: []const []const u8,
    /// SONNY-2693: what a tenant-scoped session gets where the path admits the
    /// foreign SECRET edge because both its endpoints are visible. Null: the
    /// same as `secure`.
    bridged: ?[]const []const u8 = null,

    fn expected(self: Case, mode: Mode) []const []const u8 {
        if (mode == .no_policy) return self.open;
        if (mode.tenantScoped()) return self.bridged orelse self.secure;
        return self.secure;
    }
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
    // Incoming and undirected variable length (PathIterator's incoming gate).
    .{ .q = "MATCH (h)<-[:R*1..3]-(g:G) RETURN h.s", .secure = &.{ "ok", "ok2" }, .open = &.{ "far", "far2", "leak", "ok", "ok2" } },
    .{ .q = "MATCH (g:G)-[:R*1..3]-(h) RETURN h.s", .secure = &.{ "ok", "ok2" }, .open = &.{ "far", "far2", "leak", "ok", "ok2" } },
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
    // shortestPath with endpoints bound by the MATCH, and assigned to a path.
    .{ .q = "MATCH (a:G {s: 'g1'}), (b {s: 'far'}) RETURN shortestPath((a)-[*]-(b)) AS p", .secure = &.{"null"}, .open = &.{"p(g1>leak>far)"} },
    .{ .q = "MATCH p = shortestPath((a:G {s: 'g1'})-[*]-(b {s: 'far'})) RETURN p", .secure = &.{"null"}, .open = &.{"p(g1>leak>far)"} },

    // An edge the session may not walk (the SECRET edge): denied by an
    // edge-type policy (label and expression sessions) or foreign-tagged
    // between two visible nodes (tenant sessions).
    .{ .q = "MATCH (g:G)-[r:SECRET]->(h) RETURN r.x", .secure = &.{}, .open = &.{"topsecret"} },
    .{ .q = "MATCH (g:G)-[r:SECRET]->(h) RETURN h.s", .secure = &.{}, .open = &.{"viaSecret"} },
    .{ .q = "MATCH (g:G)-[r:SECRET]->(h) RETURN r", .secure = &.{}, .open = &.{"[SECRET]"} },
    .{ .q = "MATCH (g:G)-[r]->(h) RETURN type(r), h.s", .secure = &.{"R|ok"}, .open = &.{ "R|leak", "R|ok", "SECRET|viaSecret" } },
    .{ .q = "MATCH (g:G)-[r:SECRET]->(h) RETURN count(r)", .secure = &.{"0"}, .open = &.{"1"} },
    .{ .q = "MATCH (g:G)-[r]->(h) RETURN collect(r)", .secure = &.{"[[R]]"}, .open = &.{"[[R],[R],[SECRET]]"} },
    .{ .q = "MATCH ()-[r]->() RETURN count(r)", .secure = &.{"4"}, .open = &.{"7"} },
    .{ .q = "MATCH (g:G)-[:SECRET*1..2]->(h) RETURN h.s", .secure = &.{}, .open = &.{"viaSecret"} },
    .{ .q = "MATCH (g:G)-[*1..3]->(h) RETURN h.s", .secure = &.{ "ok", "ok2" }, .open = &.{ "beyond", "far", "far2", "leak", "ok", "ok2", "viaSecret" } },
    .{ .q = "MATCH (g:G) OPTIONAL MATCH (g)-[r:SECRET]->(h) RETURN h.s", .secure = &.{"null"}, .open = &.{"viaSecret"} },
    .{ .q = "MATCH (a)-[:SECRET]->(b), (b)-[:R]->(c) RETURN c.s", .secure = &.{}, .open = &.{"beyond"} },
    .{ .q = "MATCH (g:G)-[:SECRET]->(m)-[:R]->(h) RETURN h.s", .secure = &.{}, .open = &.{"beyond"}, .bridged = &.{"beyond"} },
    .{ .q = "MATCH (g:G) RETURN COUNT { (g)-[:SECRET]->() } AS c", .secure = &.{"0"}, .open = &.{"1"}, .bridged = &.{"1"} },
    .{ .q = "MATCH (g:G) RETURN [(g)-[r:SECRET]->(h) | r.x] AS xs", .secure = &.{"[]"}, .open = &.{"[topsecret]"}, .bridged = &.{"[topsecret]"} },
    .{ .q = "MATCH (g:G) RETURN COUNT { (g)-[*1..3]->() } AS c", .secure = &.{"2"}, .open = &.{"7"}, .bridged = &.{"4"} },
    .{ .q = "RETURN shortestPath((a:G {s: 'g1'})-[*]-(b {s: 'beyond'})) AS p", .secure = &.{"null"}, .open = &.{"p(g1>viaSecret>beyond)"}, .bridged = &.{"p(g1>viaSecret>beyond)"} },
};

/// The value of integer property `key` on node `s`, read straight from the
/// store (the restricted session may not read it).
fn intProp(s: []const u8, key: []const u8) !?i64 {
    const store = graph_store.getGlobalStore(testing.allocator);
    const node = store.nodes.get(try idOf(s)) orelse return error.NodeNotFound;
    const pv = node.properties.get(key) orelse return null;
    return if (pv == .Int) pv.Int else null;
}

fn hasEdge(from: []const u8, to: []const u8, rel: []const u8) !bool {
    const store = graph_store.getGlobalStore(testing.allocator);
    const to_id = try idOf(to);
    const ids = store.getOutgoingEdgeIds(try idOf(from)) orelse return false;
    for (ids) |eid| {
        const e = store.getEdgeHydrated(eid) orelse continue;
        if (e.to_id == to_id and std.mem.eql(u8, e.label, rel)) return true;
    }
    return false;
}

fn nodeExists(s: []const u8) bool {
    _ = idOf(s) catch return false;
    return true;
}

fn yesNo(b: bool) []const u8 {
    return if (b) "yes" else "no";
}

fn writeOrReport(s: *Session, f: *Failures, query: []const u8) !void {
    s.exec(query) catch |err| try f.add(s.arena.allocator(), "[{s}] {s}: error {s}", .{ @tagName(s.mode), query, @errorName(err) });
}

/// SET and DELETE through a hop act only on what the session can read: the
/// hidden node is not written and its edge not deleted. The control session
/// writes everything.
fn checkWrites(s: *Session, f: *Failures) !void {
    const aa = s.arena.allocator();
    const restricted = s.mode != .no_policy;
    const mode = @tagName(s.mode);

    try writeOrReport(s, f, "MATCH (g:G)-[:R]->(h) SET h.touched = 1");
    if (try intProp("ok", "touched") == null) try f.add(aa, "[{s}] SET through a hop did not write ok", .{mode});
    const leak_written = (try intProp("leak", "touched")) != null;
    if (leak_written == restricted) try f.add(aa, "[{s}] SET through a hop: leak written = {s}", .{ mode, yesNo(leak_written) });

    try writeOrReport(s, f, "MATCH (g:G)-[:R]->(m)-[:R]->(h) SET h.touched2 = 1");
    if (try intProp("ok2", "touched2") == null) try f.add(aa, "[{s}] SET through two hops did not write ok2", .{mode});
    const far_written = (try intProp("far", "touched2")) != null;
    if (far_written == restricted) try f.add(aa, "[{s}] SET through two hops: far written = {s}", .{ mode, yesNo(far_written) });

    try writeOrReport(s, f, "MATCH (g:G)-[r:R]->(h) DELETE r");
    if (try hasEdge("g1", "ok", "R")) try f.add(aa, "[{s}] DELETE through a hop kept g1->ok", .{mode});
    const leak_edge_kept = try hasEdge("g1", "leak", "R");
    if (leak_edge_kept != restricted) try f.add(aa, "[{s}] DELETE through a hop: g1->leak kept = {s}", .{ mode, yesNo(leak_edge_kept) });

    try writeOrReport(s, f, "MATCH (g:G)-[:SECRET]->(h) DETACH DELETE h");
    const via_secret_kept = nodeExists("viaSecret");
    if (via_secret_kept != restricted) try f.add(aa, "[{s}] DETACH DELETE over SECRET: viaSecret kept = {s}", .{ mode, yesNo(via_secret_kept) });
}

fn checkMode(mode: Mode) !void {
    harness.silenceEngineLogs();
    var s = try Session.init(mode);
    defer s.deinit();
    try s.seed();
    var f: Failures = .{};

    for (cases) |c| try expectRows(&s, &f, c.q, c.expected(mode));
    try checkWrites(&s, &f);

    if (f.items.items.len != 0) {
        std.debug.print("\n[{s}] {d} failed check(s):\n", .{ @tagName(mode), f.items.items.len });
        for (f.items.items) |msg| std.debug.print("  {s}\n", .{msg});
        return error.HopTargetVisibilityWrong;
    }
}

test "SONNY-2679: with no policy and no tenant scope, a traversal still sees the whole graph" {
    try checkMode(.no_policy);
}

test "SONNY-2679: a label-deny policy hides a hop target, a denied edge type, and a path through either" {
    try checkMode(.label_policy);
}

test "SONNY-2679: an expression policy hides a hop target, a denied edge, and a path through either" {
    try checkMode(.expr_policy);
}

test "SONNY-2679: a tenant-scoped session does not follow an edge into another tenant on any traversal" {
    try checkMode(.tenant_scoped);
}

test "SONNY-2679: a parent tenant reads its child's rows through a hop, and not its sibling's" {
    try checkMode(.tenant_hierarchy);
}
