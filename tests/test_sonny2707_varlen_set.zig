// SONNY-2707 part (1) regression: a SET or REMOVE through a variable-length
// pattern was silently ignored.
//
// `MATCH (a)-[*1..2]->(b) SET b.x = 1` matched its paths and wrote nothing:
// the variable-length traversal (executeVariableLengthPathTraversal) built the
// rows and never applied the statement's SET or REMOVE clauses, which only the
// single-hop traversal and the multi-chain executor applied. Behind an
// aggregating RETURN the write reaches the same traversal (SONNY-2694 reads
// the bindings there), so it was lost there too.
//
// Each write is checked against an oracle: the test walks its own copy of the
// seeded edge list (every walk of the pattern's length, in its direction,
// through nodes the session may read) and derives the nodes the write must
// reach. The written set is read back as an unrestricted session, so a write
// that reached a node the session cannot read shows up. Modes: in-memory, a
// persisted session with a label-deny RLS policy (one node on the paths is
// hidden: a path may neither end at it nor pass through it), and a
// tenant-scoped persisted session whose other tenant holds the same graph.
// On a persisted store the effect is also read back after a checkpoint and a
// reload from the engine.
//
// The SONNY-738 Task W fix round widened the oracle: a WHERE on the end node
// with and without a WITH (SONNY-3039: a WITH made the traversal write every
// path), an undirected pattern, `*0..` (a zero-length path ends at its start;
// no upper bound), a multi-hop pattern ending in a variable-length hop, and a
// SET that reads what it writes (`SET b.c = coalesce(b.c, 0) + 1`), which
// must run once per path, so each node's c is the number of paths that reach
// it, at the end of the pattern and at its start. A write on the relationship
// list or the path of a multi-hop pattern is refused too (SONNY-3045).
//
// Parts (2) and (3) of the ticket (COUNT {} over an unbound relationship, and
// a variable-length COUNT {} that ignores the pattern's direction) are v0.8.24.
//
// CANARY: REQ=REQ-SONNY-2707-VARLEN-WRITE; FEATURE="VariableLengthPaths"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2707_varlen_set.zig; OWNER=engine; UPDATED=2026-09-27

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const rls_types = @import("rls_types");
const harness = @import("node_scan_stream_harness.zig");

const execution = geode.execution;
const graph_store = geode.graph_store;
const query_traits = geode.query_traits;
const Value = geode.value_types.Value;

// ---------------------------------------------------------------------------
// The graph, and the oracle over it.

const node_count = 10;
/// The node the RLS policy hides (it is `:V:Hidden` in every mode; only the
/// RLS mode has a policy on the label).
const hidden_k = 5;

const Edge = struct { from: u8, to: u8, rel: []const u8 = "R" };

/// 0->1->2->3->4, 0->5->6->2, 7->0, 1-[:S]->7, and the cycle 8<->9.
const edges = [_]Edge{
    .{ .from = 0, .to = 1 }, .{ .from = 1, .to = 2 }, .{ .from = 2, .to = 3 },
    .{ .from = 3, .to = 4 }, .{ .from = 0, .to = 5 }, .{ .from = 5, .to = 6 },
    .{ .from = 6, .to = 2 }, .{ .from = 7, .to = 0 }, .{ .from = 1, .to = 7, .rel = "S" },
    .{ .from = 9, .to = 8 }, .{ .from = 8, .to = 9 },
};

const Direction = enum { out, in, both };

/// A walk with no upper bound (`*k..`).
const unbounded: u8 = std.math.maxInt(u8);

const Walk = struct {
    /// The start nodes (null: every node).
    start: ?u8,
    min: u8,
    max: u8,
    dir: Direction = .out,
    /// Only edges of this type (null: any).
    rel: ?[]const u8 = null,
    /// Only paths whose end node's k is at least this (a WHERE on the end).
    end_min_k: u8 = 0,
};

const Oracle = struct {
    /// The nodes some path ends at.
    ends: [node_count]bool = @splat(false),
    /// How many paths end at each node.
    per_end: [node_count]usize = @splat(0),
    /// How many paths there are.
    paths: usize = 0,
};

/// Every path `w` describes through nodes `visible` admits (the start, every
/// node it passes and the end), with no node twice: the engine's default path
/// mode is ACYCLIC.
fn oracle(w: Walk, visible: [node_count]bool) Oracle {
    var o: Oracle = .{};
    for (0..node_count) |s| {
        if (w.start) |start| if (s != start) continue;
        if (!visible[s]) continue;
        var on_path: [node_count]bool = @splat(false);
        on_path[s] = true;
        walkFrom(w, visible, &on_path, @intCast(s), 0, &o);
    }
    return o;
}

fn walkFrom(w: Walk, visible: [node_count]bool, on_path: *[node_count]bool, at: u8, depth: u8, o: *Oracle) void {
    // A zero-length path (`*0..`) ends at its start.
    if (depth >= w.min and at >= w.end_min_k) {
        o.ends[at] = true;
        o.per_end[at] += 1;
        o.paths += 1;
    }
    if (depth == w.max) return;
    for (edges) |e| {
        if (w.rel) |rel| if (!std.mem.eql(u8, rel, e.rel)) continue;
        // Each edge once per direction it may be walked in: an undirected
        // pattern walks every edge either way.
        for ([_]Direction{ .out, .in }) |way| {
            if (w.dir != .both and w.dir != way) continue;
            const from, const to = switch (way) {
                .out => .{ e.from, e.to },
                .in, .both => .{ e.to, e.from },
            };
            if (from != at or !visible[to] or on_path[to]) continue;
            on_path[to] = true;
            walkFrom(w, visible, on_path, to, depth + 1, o);
            on_path[to] = false;
        }
    }
}

fn keysOf(aa: std.mem.Allocator, set: [node_count]bool) ![]const []const u8 {
    var out: std.ArrayList([]const u8) = .empty;
    for (set, 0..) |in, k| if (in) try out.append(aa, try std.fmt.allocPrint(aa, "{d}", .{k}));
    return out.toOwnedSlice(aa);
}

// ---------------------------------------------------------------------------
// Sessions.

const Mode = enum {
    in_memory,
    /// Persisted; `bob` may not read `:Hidden`.
    rls_policy,
    /// Persisted, tenant `tenant_a`; `tenant_b` holds the same graph.
    tenant_scoped,
};

const Session = struct {
    mode: Mode,
    arena: std.heap.ArenaAllocator,
    tmp: ?std.testing.TmpDir,
    data_dir: ?[]u8,
    ctx: execution.ExecutionContext,
    rls: ?*rls_types.RLSFilterEngine = null,

    fn init(mode: Mode) !Session {
        const allocator = testing.allocator;
        harness.silenceEngineLogs();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, null);
        var tmp: ?std.testing.TmpDir = null;
        var data_dir: ?[]u8 = null;
        errdefer {
            if (data_dir) |d| allocator.free(d);
            if (tmp) |*t| t.cleanup();
        }
        const persisted = mode != .in_memory;
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
        if (self.rls) |engine| {
            rls_types.setGlobalRLSFilterEngine(null);
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

    /// Run one statement as the server does: with the context installed.
    fn run(self: *Session, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        const prev = execution.pushActiveContext(&self.ctx);
        defer execution.popActiveContext(prev);
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    fn exec(self: *Session, query: []const u8) !void {
        var r = try self.run(query);
        r.deinit(self.arena.allocator());
    }

    /// Run as `tenant` and `user`, restoring the session's own after.
    fn execAs(self: *Session, tenant: ?[]const u8, user: ?[]const u8, query: []const u8) !void {
        const saved_tenant = self.ctx.tenant_id;
        const saved_user = self.ctx.user;
        defer {
            self.ctx.tenant_id = saved_tenant;
            self.ctx.user = saved_user;
        }
        self.ctx.tenant_id = tenant;
        self.ctx.user = user;
        try self.exec(query);
    }

    /// `(:V {k, t: 1})` for k = 0..9 (k = 5 also `:Hidden`) and `edges`. A
    /// tenant-scoped session's graph is `tenant_a`'s and `tenant_b` holds a
    /// copy; the RLS session installs its policy after seeding.
    fn seed(self: *Session) !void {
        const own: ?[]const u8 = if (self.mode == .tenant_scoped) "tenant_a" else null;
        if (self.mode == .tenant_scoped) try self.seedGraph("tenant_b");
        try self.seedGraph(own);
        self.ctx.tenant_id = own;
        if (self.mode == .rls_policy) {
            const engine = try testing.allocator.create(rls_types.RLSFilterEngine);
            engine.* = rls_types.RLSFilterEngine.init(testing.allocator);
            self.rls = engine;
            try engine.addDenyPolicy(graph_store.DEFAULT_GRAPH_NAME, "Hidden", "bob");
            rls_types.setGlobalRLSFilterEngine(engine);
            self.ctx.user = "bob";
        }
    }

    fn seedGraph(self: *Session, tenant: ?[]const u8) !void {
        const aa = self.arena.allocator();
        for (0..node_count) |k| {
            const labels: []const u8 = if (k == hidden_k) "V:Hidden" else "V";
            try self.execAs(tenant, null, try std.fmt.allocPrint(aa, "CREATE (:{s} {{k: {d}, t: 1}})", .{ labels, k }));
        }
        for (edges) |e| {
            try self.execAs(tenant, null, try std.fmt.allocPrint(aa, "MATCH (a:V {{k: {d}}}), (b:V {{k: {d}}}) CREATE (a)-[:{s}]->(b)", .{ e.from, e.to, e.rel }));
        }
    }

    /// The nodes the session may read.
    fn visible(self: *const Session) [node_count]bool {
        var v: [node_count]bool = @splat(true);
        if (self.mode == .rls_policy) v[hidden_k] = false;
        return v;
    }

    fn reopen(self: *Session) !void {
        if (self.mode == .in_memory) return;
        const adapter = graph_store.getGlobalAdapter() orelse return error.AdapterNotInitialized;
        try adapter.checkpointAll();
        try graph_store.getGlobalStore(testing.allocator).loadFromFile();
    }
};

// ---------------------------------------------------------------------------
// Checks.

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn render(aa: std.mem.Allocator, v: Value) ![]const u8 {
    return switch (v) {
        // Copied: the value may be freed with its result before it is compared.
        .Str, .Text => |s| try aa.dupe(u8, s),
        .Int => |n| try std.fmt.allocPrint(aa, "{d}", .{n}),
        .Null => "null",
        else => try std.fmt.allocPrint(aa, "<{s}>", .{@tagName(v)}),
    };
}

const Failures = struct {
    arena: std.mem.Allocator,
    items: std.ArrayList([]const u8) = .empty,

    fn add(self: *Failures, comptime fmt: []const u8, args: anytype) !void {
        try self.items.append(self.arena, try std.fmt.allocPrint(self.arena, fmt, args));
    }

    fn finish(self: *Failures, title: []const u8) !void {
        if (self.items.items.len == 0) return;
        std.debug.print("\n{s}: {d} failed check(s):\n", .{ title, self.items.items.len });
        for (self.items.items) |msg| std.debug.print("  {s}\n", .{msg});
        return error.VariableLengthWriteWrong;
    }
};

/// `query`'s single-column rows, sorted, as `tenant` with no user.
fn rowsAs(s: *Session, tenant: ?[]const u8, query: []const u8) ![]const []const u8 {
    const aa = s.arena.allocator();
    const saved_tenant = s.ctx.tenant_id;
    const saved_user = s.ctx.user;
    defer {
        s.ctx.tenant_id = saved_tenant;
        s.ctx.user = saved_user;
    }
    s.ctx.tenant_id = tenant;
    s.ctx.user = null;
    var result = try s.run(query);
    defer result.deinit(aa);
    const got = try aa.alloc([]const u8, result.rows.len);
    for (result.rows, got) |row, *g| g.* = try render(aa, row[0]);
    std.mem.sort([]const u8, got, {}, lessThan);
    return got;
}

fn sameSet(got: []const []const u8, want: []const []const u8) bool {
    if (got.len != want.len) return false;
    for (got, want) |g, w| if (!std.mem.eql(u8, g, w)) return false;
    return true;
}

fn expectSet(s: *Session, f: *Failures, stage: []const u8, case: []const u8, tenant: ?[]const u8, query: []const u8, want: []const []const u8) !void {
    const aa = s.arena.allocator();
    const got = rowsAs(s, tenant, query) catch |err| {
        try f.add("[{s}] {s} | {s}: {s}: error {s}", .{ @tagName(s.mode), case, stage, query, @errorName(err) });
        return;
    };
    const exp = try aa.dupe([]const u8, want);
    std.mem.sort([]const u8, exp, {}, lessThan);
    if (!sameSet(got, exp)) {
        try f.add("[{s}] {s} | {s}: {s}: expected {{{s}}}, got {{{s}}}", .{ @tagName(s.mode), case, stage, query, try std.mem.join(aa, ",", exp), try std.mem.join(aa, ",", got) });
    }
}

/// What a case writes, and where the oracle says it lands.
const Effect = enum {
    /// `SET x.x = 1`: the written nodes have x = 1.
    set_x,
    /// `REMOVE x.t`: the written nodes lost t.
    remove_t,
    /// `SET x:Hit`: the written nodes have the label.
    set_label,
    /// `SET x.c = coalesce(x.c, 0) + 1`: once per path, so each written node's
    /// c is the number of paths that reach it.
    count_c,
};

const Case = struct {
    write: []const u8,
    /// The paths whose end nodes the write reaches (for a write to the
    /// pattern's start node, the reversed pattern from its end).
    walk: Walk,
    effect: Effect = .set_x,
    /// The RETURN, when the write has one: the path count, or the written
    /// nodes' keys.
    returns: enum { nothing, path_count, written_keys } = .nothing,
};

/// The keys of the nodes the effect shows, read as `tenant` without a user
/// (the policy does not hide what was written from the check).
fn effectQuery(effect: Effect) []const u8 {
    return switch (effect) {
        .set_x => "MATCH (n:V) WHERE n.x = 1 RETURN n.k",
        .remove_t => "MATCH (n:V) WHERE n.t IS NULL RETURN n.k",
        .set_label => "MATCH (n:Hit) RETURN n.k",
        .count_c => "MATCH (n:V) WHERE n.c IS NOT NULL RETURN toString(n.k) + ':' + toString(n.c)",
    };
}

/// The effect the oracle predicts: the written nodes' keys, or for `count_c`
/// each one's `k:paths`.
fn expectedEffect(aa: std.mem.Allocator, effect: Effect, o: Oracle) ![]const []const u8 {
    if (effect != .count_c) return keysOf(aa, o.ends);
    var out: std.ArrayList([]const u8) = .empty;
    for (o.per_end, 0..) |n, k| if (n != 0) try out.append(aa, try std.fmt.allocPrint(aa, "{d}:{d}", .{ k, n }));
    return out.toOwnedSlice(aa);
}

fn runCase(mode: Mode, c: Case, f: *Failures) !void {
    var s = try Session.init(mode);
    defer s.deinit();
    try s.seed();
    const aa = s.arena.allocator();

    const o = oracle(c.walk, s.visible());
    const written = try keysOf(aa, o.ends);
    const effect = try expectedEffect(aa, c.effect, o);

    // The write itself, as the session.
    var result = s.run(c.write) catch |err| {
        try f.add("[{s}] {s}: error {s}", .{ @tagName(mode), c.write, @errorName(err) });
        return;
    };
    defer result.deinit(aa);
    switch (c.returns) {
        .nothing => {},
        .path_count => {
            const got = if (result.rows.len == 1) try render(aa, result.rows[0][0]) else "<rows>";
            const want = try std.fmt.allocPrint(aa, "{d}", .{o.paths});
            if (!std.mem.eql(u8, got, want)) try f.add("[{s}] {s} | returns: expected {s}, got {s}", .{ @tagName(mode), c.write, want, got });
        },
        .written_keys => {
            const got = try aa.alloc([]const u8, result.rows.len);
            for (result.rows, got) |row, *g| g.* = try render(aa, row[0]);
            std.mem.sort([]const u8, got, {}, lessThan);
            if (!sameSet(got, written)) try f.add("[{s}] {s} | returns: expected {{{s}}}, got {{{s}}}", .{ @tagName(mode), c.write, try std.mem.join(aa, ",", written), try std.mem.join(aa, ",", got) });
        },
    }

    const own = s.ctx.tenant_id;
    try expectSet(&s, f, "effect", c.write, own, effectQuery(c.effect), effect);
    if (mode == .tenant_scoped) try expectSet(&s, f, "other tenant", c.write, "tenant_b", effectQuery(c.effect), &.{});
    if (mode != .in_memory) {
        s.reopen() catch |err| {
            try f.add("[{s}] {s}: reload failed: {s}", .{ @tagName(mode), c.write, @errorName(err) });
            return;
        };
        try expectSet(&s, f, "effect after reload", c.write, own, effectQuery(c.effect), effect);
        if (mode == .tenant_scoped) try expectSet(&s, f, "other tenant after reload", c.write, "tenant_b", effectQuery(c.effect), &.{});
    }
}

const cases = [_]Case{
    // The ticket's statement, from one start and from every start.
    .{ .write = "MATCH (a:V {k: 0})-[*1..2]->(b) SET b.x = 1", .walk = .{ .start = 0, .min = 1, .max = 2 } },
    .{ .write = "MATCH (a:V)-[*1..2]->(b:V) SET b.x = 1", .walk = .{ .start = null, .min = 1, .max = 2 } },
    // Longer, typed, exact-length and incoming.
    .{ .write = "MATCH (a:V {k: 0})-[*1..3]->(b) SET b.x = 1", .walk = .{ .start = 0, .min = 1, .max = 3 } },
    .{ .write = "MATCH (a:V {k: 0})-[:R*1..3]->(b) SET b.x = 1", .walk = .{ .start = 0, .min = 1, .max = 3, .rel = "R" } },
    .{ .write = "MATCH (a:V {k: 0})-[*2..2]->(b) SET b.x = 1", .walk = .{ .start = 0, .min = 2, .max = 2 } },
    .{ .write = "MATCH (a:V {k: 2})<-[*1..2]-(b) SET b.x = 1", .walk = .{ .start = 2, .min = 1, .max = 2, .dir = .in } },
    // The start node written: the nodes 2 reaches backwards.
    .{ .write = "MATCH (a:V)-[*1..2]->(b:V {k: 2}) SET a.x = 1", .walk = .{ .start = 2, .min = 1, .max = 2, .dir = .in } },
    // REMOVE and a label.
    .{ .write = "MATCH (a:V {k: 0})-[*1..2]->(b) REMOVE b.t", .walk = .{ .start = 0, .min = 1, .max = 2 }, .effect = .remove_t },
    .{ .write = "MATCH (a:V {k: 0})-[*1..2]->(b) SET b:Hit", .walk = .{ .start = 0, .min = 1, .max = 2 }, .effect = .set_label },
    // Behind a RETURN: an aggregate and DISTINCT (SONNY-2694).
    .{ .write = "MATCH (a:V {k: 0})-[*1..2]->(b) SET b.x = 1 RETURN count(*) AS c", .walk = .{ .start = 0, .min = 1, .max = 2 }, .returns = .path_count },
    .{ .write = "MATCH (a:V {k: 0})-[*1..2]->(b) SET b.x = 1 RETURN DISTINCT b.k", .walk = .{ .start = 0, .min = 1, .max = 2 }, .returns = .written_keys },
    .{ .write = "MATCH (a:V {k: 0})-[*1..2]->(b) SET b.x = 1 RETURN b.k", .walk = .{ .start = 0, .min = 1, .max = 2 }, .returns = .written_keys },
    // SONNY-3039: a WHERE on the end, with and without a WITH (a WITH defers
    // the WHERE past the traversal, which wrote every path).
    .{ .write = "MATCH (a:V {k: 0})-[*1..3]->(b) WHERE b.k >= 3 SET b.x = 1", .walk = .{ .start = 0, .min = 1, .max = 3, .end_min_k = 3 } },
    .{ .write = "MATCH (a:V {k: 0})-[*1..3]->(b) WITH b WHERE b.k >= 3 SET b.x = 1", .walk = .{ .start = 0, .min = 1, .max = 3, .end_min_k = 3 } },
    .{ .write = "MATCH (a:V {k: 0})-[*1..3]->(b) WHERE b.k >= 3 WITH b SET b.x = 1 RETURN count(*) AS c", .walk = .{ .start = 0, .min = 1, .max = 3, .end_min_k = 3 }, .returns = .path_count },
    // Undirected.
    .{ .write = "MATCH (a:V {k: 0})-[*1..2]-(b) SET b.x = 1", .walk = .{ .start = 0, .min = 1, .max = 2, .dir = .both } },
    .{ .write = "MATCH (a:V {k: 8})-[*1..3]-(b) SET b.x = 1", .walk = .{ .start = 8, .min = 1, .max = 3, .dir = .both } },
    // A zero-length path ends at its start; `*0..` has no upper bound.
    .{ .write = "MATCH (a:V {k: 0})-[*0..2]->(b) SET b.x = 1", .walk = .{ .start = 0, .min = 0, .max = 2 } },
    .{ .write = "MATCH (a:V {k: 0})-[*0..]->(b) SET b.x = 1", .walk = .{ .start = 0, .min = 0, .max = unbounded } },
    .{ .write = "MATCH (a:V {k: 1})-[:R*0..]->(b) SET b.x = 1 RETURN count(*) AS c", .walk = .{ .start = 1, .min = 0, .max = unbounded, .rel = "R" }, .returns = .path_count },
    // Multi-hop: a fixed hop then a variable-length one. 7's one R edge
    // reaches 0, so the ends are the typed walk from 0.
    .{ .write = "MATCH (a:V {k: 7})-[:R]->(m)-[:R*1..2]->(b) SET b.x = 1", .walk = .{ .start = 0, .min = 1, .max = 2, .rel = "R" } },
    .{ .write = "MATCH (a:V {k: 7})-[:R]->(m)-[:R*1..2]->(b) SET b.x = 1 RETURN count(*) AS c", .walk = .{ .start = 0, .min = 1, .max = 2, .rel = "R" }, .returns = .path_count },
    // Once per path: a SET that reads what it writes counts the paths that
    // reach each node (2 reaches from 0 through 1 and through 5-6), at the
    // end and at the start.
    .{ .write = "MATCH (a:V {k: 0})-[*1..3]->(b) SET b.c = coalesce(b.c, 0) + 1", .walk = .{ .start = 0, .min = 1, .max = 3 }, .effect = .count_c },
    .{ .write = "MATCH (a:V)-[*1..3]->(b:V {k: 2}) SET a.c = coalesce(a.c, 0) + 1", .walk = .{ .start = 2, .min = 1, .max = 3, .dir = .in }, .effect = .count_c },
    .{ .write = "MATCH (a:V {k: 0})-[*1..3]-(b) SET b.c = coalesce(b.c, 0) + 1", .walk = .{ .start = 0, .min = 1, .max = 3, .dir = .both }, .effect = .count_c },
};

test "SONNY-2707: a SET or REMOVE through a variable-length pattern writes every node the oracle reaches, and none the session cannot read" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    var f: Failures = .{ .arena = arena.allocator() };
    for ([_]Mode{ .in_memory, .rls_policy, .tenant_scoped }) |mode| {
        for (cases) |c| runCase(mode, c, &f) catch |err| {
            try f.add("[{s}] {s}: the case aborted: {s}", .{ @tagName(mode), c.write, @errorName(err) });
        };
    }
    try f.finish("variable-length writes");
}

test "SONNY-2707: a SET or REMOVE on a variable-length relationship or its path is refused, not ignored" {
    var s = try Session.init(.in_memory);
    defer s.deinit();
    try s.seed();
    const refused = [_][]const u8{
        "MATCH (a:V {k: 0})-[r*1..2]->(b) SET r.x = 1",
        "MATCH (a:V {k: 0})-[r*1..2]->(b) REMOVE r.x",
        "MATCH p = (a:V {k: 0})-[*1..2]->(b) SET p.x = 1",
        // SONNY-3045: in a multi-hop pattern too (it was ignored there).
        "MATCH (a:V {k: 7})-[:R]->(m)-[r:R*1..2]->(b) SET r.x = 1",
        "MATCH (a:V {k: 7})-[:R]->(m)-[r:R*1..2]->(b) REMOVE r.x RETURN count(*)",
        "MATCH p = (a:V {k: 7})-[:R]->(m)-[:R*1..2]->(b) SET p.x = 1",
        // And after a WITH (the write step).
        "MATCH (a:V {k: 0})-[r*1..2]->(b) WITH r SET r.x = 1",
    };
    for (refused) |stmt| {
        if (s.run(stmt)) |r| {
            var result = r;
            result.deinit(s.arena.allocator());
            std.debug.print("expected a refusal: {s}\n", .{stmt});
            return error.WriteNotRefused;
        } else |err| try testing.expectEqual(error.VariableLengthPathWrite, err);
    }
    // Nothing was written before the refusal.
    try testing.expectEqual(@as(usize, 0), (try rowsAs(&s, null, "MATCH (n:V) WHERE n.x = 1 RETURN n.k")).len);
    try testing.expectEqual(@as(usize, 0), (try rowsAs(&s, null, "MATCH ()-[r]->() WHERE r.x = 1 RETURN r.x")).len);
}

test "SONNY-2707: a program that writes through a variable-length pattern, or behind an aggregate, on two graphs is refused" {
    // Round 7 (SONNY-2749): a program that changes data on more than one graph
    // is refused with 0A000. Each of these changes data on both graphs.
    const programs = [_][]const u8{
        "MATCH (a:V)-[*1..2]->(b) SET b.x = 1; USE GRAPH g2; MATCH (a:V)-[*1..2]->(b) SET b.x = 1",
        "MATCH (a:V)-[*1..2]->(b) SET b.x = 1 RETURN count(*); USE GRAPH g2; MATCH (n:V) RETURN count(*); MATCH (n:V) REMOVE n.t RETURN count(*)",
        "MATCH (n:V) CREATE (n)-[:T]->(:Z) RETURN count(*); USE GRAPH g2; MATCH (n:V) MERGE (m:M {k: n.k}) RETURN count(*)",
        "USE GRAPH g2; MATCH (n:V) SET n.x = 1 RETURN DISTINCT n.k; USE GRAPH g3; MATCH (q:V) SET q.y = 1 DELETE q RETURN count(*)",
    };
    for (programs) |src| {
        var parsed = try geode.parseGql(src, testing.allocator);
        defer parsed.deinit();
        const analysis = query_traits.analyzeProgram(&parsed.program);
        const plan = query_traits.statementPlan(&parsed.program, &analysis, graph_store.DEFAULT_GRAPH_NAME, graph_store.DEFAULT_GRAPH_NAME, .quic);
        if (!plan.spans_graphs) {
            std.debug.print("a program that writes two graphs was not refused: {s}\n", .{src});
            return error.SpansGraphsNotRefused;
        }
    }
}
