// SONNY-2693 regression: one tenant rule for every edge a session reads.
//
// A tenant-scoped session sees an edge only when the edge's OWN tenant tag
// passes its (hierarchy-aware) filter AND both endpoints are visible to it
// (`tenant_visibility.edgeTraversable`). Before this, two read paths used the
// GAP-0891 endpoint-derived rule instead (visible when both endpoints are,
// whatever the tag): the multi-chain executor's first hop and the expression
// path (pattern comprehensions, COUNT {}, EXISTS {}, shortestPath()). Probe P8
// showed what that let through: a tenant_a session read the property of an
// edge tagged tenant_b between two tenant_a nodes (`b-secret`), through the
// multi-chain first hop in both its chained and comma forms, a comprehension
// and `relationships(shortestPath(..))`, and learned the edge exists through
// COUNT {} (1), EXISTS {} (true) and shortestPath().
//
// The same bridge showed legacy `default`-tagged edges (the pre-GAP-0891
// worker bug) to the tenant whose nodes they join. There is no bridge for
// `default` either: unscoped and admin writes and follower replication write
// `default`, and a `default` node is already hidden from every tenant. Those
// edges are re-tagged by `CALL geode.tenant.backfill_edge_tags()`, which also
// reports the edges whose tags disagree in any other way ("mixed").
//
// CANARY: REQ=REQ-SONNY-2693-EDGE-TENANT-RULE; FEATURE="PerTenantIsolation"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2693_edge_tenant_rule.zig; OWNER=security; UPDATED=2026-09-25

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const harness = @import("node_scan_stream_harness.zig");

const execution = geode.execution;
const graph_store = geode.graph_store;
const user_mgmt = geode.user_management;
const Value = geode.value_types.Value;
const GraphStore = graph_store.GraphStore;

const tenant_a = "tenant_a";
const tenant_b = "tenant_b";
const default_tenant = graph_store.DEFAULT_TENANT_ID;

// ---------------------------------------------------------------------------
// The backfill itself, on an in-memory store.
// ---------------------------------------------------------------------------

fn entryFor(entries: []const GraphStore.EdgeTagBackfillEntry, edge_id: u64) ?GraphStore.EdgeTagBackfillEntry {
    for (entries) |entry| {
        const id = entry.edge_id orelse continue;
        if (id == edge_id) return entry;
    }
    return null;
}

fn expectEntry(
    entries: []const GraphStore.EdgeTagBackfillEntry,
    edge_id: u64,
    action: GraphStore.EdgeTagBackfillAction,
    edge_tenant: []const u8,
    from_tenant: []const u8,
    to_tenant: []const u8,
) !void {
    const entry = entryFor(entries, edge_id) orelse return error.EdgeNotReported;
    try testing.expectEqual(action, entry.action);
    try testing.expectEqualStrings(edge_tenant, entry.edge_tenant orelse return error.MissingEdgeTenant);
    try testing.expectEqualStrings(from_tenant, entry.from_tenant orelse return error.MissingFromTenant);
    try testing.expectEqualStrings(to_tenant, entry.to_tenant orelse return error.MissingToTenant);
}

fn tagOf(store: *GraphStore, edge_id: u64) ![]const u8 {
    const edge = (try store.getEdgeHydratedChecked(edge_id)) orelse return error.EdgeNotFound;
    return edge.tenant_id;
}

fn hasType(types: []const []const u8, name: []const u8) bool {
    for (types) |t| {
        if (std.mem.eql(u8, t, name)) return true;
    }
    return false;
}

fn edgeTypesOf(store: *GraphStore, tenant: []const u8) ![][]const u8 {
    return store.listEdgeTypes(testing.allocator, tenant);
}

fn freeTypes(types: [][]const u8) void {
    for (types) |t| testing.allocator.free(t);
    testing.allocator.free(types);
}

test "SONNY-2693: the backfill re-tags only a default edge between two nodes of one tenant, and reports every other disagreement" {
    const allocator = testing.allocator;
    // An in-memory store: no storage adapter may be left over from another test.
    graph_store.deinitGlobalStore();

    var store = try GraphStore.init(allocator);
    defer store.deinit();
    const g = "g2693";
    try store.createGraph(g);

    const labels = [_][]const u8{"N"};
    const a1 = try store.createNodeWithGraphAndTenant(&labels, g, tenant_a);
    const a2 = try store.createNodeWithGraphAndTenant(&labels, g, tenant_a);
    const b1 = try store.createNodeWithGraphAndTenant(&labels, g, tenant_b);
    const d1 = try store.createNodeWithGraphAndTenant(&labels, g, default_tenant);
    const d2 = try store.createNodeWithGraphAndTenant(&labels, g, default_tenant);

    // Consistent edges: never changed, never listed.
    const same = try store.createEdgeWithGraphAndTenant(a1, a2, "SAME", g, tenant_a);
    const plain = try store.createEdgeWithGraphAndTenant(d1, d2, "PLAIN", g, default_tenant);
    // The one shape the backfill changes: `default` between two tenant_a nodes.
    const legacy = try store.createEdgeWithGraphAndTenant(a1, a2, "LEGACY", g, default_tenant);
    try store.setEdgeProperty(legacy, "w", .{ .Int = 7 });
    // Mixed: another tenant's tag between tenant_a nodes (probe P8's edge),
    // `default` across two tenants, and tenant_a's own tag across two tenants.
    const foreign = try store.createEdgeWithGraphAndTenant(a1, a2, "FOREIGN", g, tenant_b);
    const cross = try store.createEdgeWithGraphAndTenant(a1, b1, "CROSS", g, default_tenant);
    const own_cross = try store.createEdgeWithGraphAndTenant(a1, b1, "OWNCROSS", g, tenant_a);

    // Before: the legacy edge's type is counted under `default`, not tenant_a.
    {
        const a_types = try edgeTypesOf(&store, tenant_a);
        defer freeTypes(a_types);
        try testing.expect(!hasType(a_types, "LEGACY"));
        const d_types = try edgeTypesOf(&store, default_tenant);
        defer freeTypes(d_types);
        try testing.expect(hasType(d_types, "LEGACY"));
    }

    // A dry run reports and changes nothing.
    {
        const dry = try store.backfillEdgeTenantTags(allocator, true);
        defer GraphStore.freeEdgeTagBackfillEntries(allocator, dry);
        try testing.expectEqual(@as(usize, 4), dry.len);
        try expectEntry(dry, legacy, .would_retag, default_tenant, tenant_a, tenant_a);
        try expectEntry(dry, foreign, .mixed, tenant_b, tenant_a, tenant_a);
        try expectEntry(dry, cross, .mixed, default_tenant, tenant_a, tenant_b);
        try expectEntry(dry, own_cross, .mixed, tenant_a, tenant_a, tenant_b);
        try testing.expect(entryFor(dry, same) == null);
        try testing.expect(entryFor(dry, plain) == null);
        try testing.expectEqualStrings(default_tenant, try tagOf(&store, legacy));
    }

    // The real run re-tags the legacy edge, and only it.
    {
        const run = try store.backfillEdgeTenantTags(allocator, false);
        defer GraphStore.freeEdgeTagBackfillEntries(allocator, run);
        try testing.expectEqual(@as(usize, 4), run.len);
        try expectEntry(run, legacy, .retagged, default_tenant, tenant_a, tenant_a);
        try expectEntry(run, foreign, .mixed, tenant_b, tenant_a, tenant_a);
        try expectEntry(run, cross, .mixed, default_tenant, tenant_a, tenant_b);
        try expectEntry(run, own_cross, .mixed, tenant_a, tenant_a, tenant_b);
        const report = entryFor(run, legacy).?;
        try testing.expectEqualStrings(g, report.graph_name);
        try testing.expectEqualStrings("LEGACY", report.edge_type orelse return error.MissingEdgeType);
        try testing.expect(report.reason == null);
    }
    try testing.expectEqualStrings(tenant_a, try tagOf(&store, legacy));
    try testing.expectEqualStrings(tenant_b, try tagOf(&store, foreign));
    try testing.expectEqualStrings(default_tenant, try tagOf(&store, cross));
    try testing.expectEqualStrings(tenant_a, try tagOf(&store, own_cross));
    try testing.expectEqualStrings(tenant_a, try tagOf(&store, same));
    try testing.expectEqualStrings(default_tenant, try tagOf(&store, plain));

    // The re-tagged edge keeps its endpoints, type and properties.
    {
        const edge = (try store.getEdgeHydratedChecked(legacy)) orelse return error.EdgeNotFound;
        try testing.expectEqual(a1, edge.from_id);
        try testing.expectEqual(a2, edge.to_id);
        try testing.expectEqualStrings("LEGACY", edge.label);
        const w = edge.properties.get("w") orelse return error.PropertyLost;
        try testing.expectEqual(@as(i64, 7), w.Int);
    }

    // The tenant-keyed type counter moved with the tag.
    {
        const a_types = try edgeTypesOf(&store, tenant_a);
        defer freeTypes(a_types);
        try testing.expect(hasType(a_types, "LEGACY"));
        const d_types = try edgeTypesOf(&store, default_tenant);
        defer freeTypes(d_types);
        try testing.expect(!hasType(d_types, "LEGACY"));
        try testing.expect(hasType(d_types, "CROSS"));
    }

    // Running it again changes nothing and lists only the mixed edges.
    {
        const again = try store.backfillEdgeTenantTags(allocator, false);
        defer GraphStore.freeEdgeTagBackfillEntries(allocator, again);
        try testing.expectEqual(@as(usize, 3), again.len);
        try testing.expect(entryFor(again, legacy) == null);
        for (again) |entry| try testing.expectEqual(GraphStore.EdgeTagBackfillAction.mixed, entry.action);
    }
}

// ---------------------------------------------------------------------------
// The read paths, through the executor, on an engine-backed store.
// ---------------------------------------------------------------------------

const Session = struct {
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    ctx: execution.ExecutionContext,

    fn init() !Session {
        const allocator = testing.allocator;
        execution.initEvaluator();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const data_dir = try harness.tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);
        // The server's own path: engine-backed, with the caches' hydrate hooks
        // installed, so an evicted edge body is re-read from storage.
        _ = try graph_store.initGlobalStore(allocator, data_dir);
        const catalog = try execution.ensureCatalogInstance(allocator);
        return .{ .arena = std.heap.ArenaAllocator.init(allocator), .tmp = tmp, .data_dir = data_dir, .ctx = .{ .catalog = catalog } };
    }

    fn deinit(self: *Session) void {
        self.arena.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(testing.allocator, null);
        testing.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    fn store(self: *Session) *GraphStore {
        _ = self;
        return graph_store.getGlobalStore(testing.allocator);
    }

    /// Run `query` as `tenant` (null: unscoped).
    fn runAs(self: *Session, tenant: ?[]const u8, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        const saved = self.ctx.tenant_id;
        defer self.ctx.tenant_id = saved;
        self.ctx.tenant_id = tenant;
        const prev = execution.pushActiveContext(&self.ctx);
        defer execution.popActiveContext(prev);
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    fn execAs(self: *Session, tenant: ?[]const u8, query: []const u8) !void {
        var r = try self.runAs(tenant, query);
        r.deinit(self.arena.allocator());
    }

    fn idOf(self: *Session, s: []const u8) !u64 {
        var it = self.store().nodes.iterator();
        while (it.next()) |entry| {
            if (entry.value_ptr.*.properties.get("s")) |pv| {
                if (pv == .String and std.mem.eql(u8, pv.String, s)) return entry.key_ptr.*;
            }
        }
        return error.NodeNotFound;
    }

    /// `query`'s rows as `tenant`, each rendered `a|b|…`, sorted.
    fn rowsAs(self: *Session, tenant: ?[]const u8, query: []const u8) ![]const []const u8 {
        const aa = self.arena.allocator();
        var result = try self.runAs(tenant, query);
        defer result.deinit(aa);
        const got = try aa.alloc([]const u8, result.rows.len);
        for (result.rows, got) |row, *g| {
            const cells = try aa.alloc([]const u8, row.len);
            for (row, cells) |cell, *c| c.* = try render(aa, cell);
            g.* = try std.mem.join(aa, "|", cells);
        }
        std.mem.sort([]const u8, got, {}, lessThan);
        return got;
    }
};

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn nodeName(n: *const graph_store.Node) []const u8 {
    if (n.properties.get("s")) |pv| {
        if (pv == .String) return pv.String;
    }
    return "?";
}

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

/// Collects every mismatch, so one run reports all of them.
const Failures = struct {
    lines: std.ArrayList([]const u8) = .empty,

    fn expectRows(self: *Failures, s: *Session, tenant: ?[]const u8, query: []const u8, want: []const []const u8) !void {
        const aa = s.arena.allocator();
        const got = s.rowsAs(tenant, query) catch |err| {
            try self.lines.append(aa, try std.fmt.allocPrint(aa, "{s}: error {s}", .{ query, @errorName(err) }));
            return;
        };
        const sorted = try aa.dupe([]const u8, want);
        std.mem.sort([]const u8, sorted, {}, lessThan);
        const same = got.len == sorted.len and for (got, sorted) |g, w| {
            if (!std.mem.eql(u8, g, w)) break false;
        } else true;
        if (!same) try self.lines.append(aa, try std.fmt.allocPrint(aa, "{s}: expected {{{s}}}, got {{{s}}}", .{
            query,
            try std.mem.join(aa, ",", sorted),
            try std.mem.join(aa, ",", got),
        }));
    }

    fn check(self: *Failures) !void {
        if (self.lines.items.len == 0) return;
        for (self.lines.items) |l| std.debug.print("  {s}\n", .{l});
        return error.TestUnexpectedResult;
    }
};

/// tenant_a owns a1, a2 and c1. Between a1 and a2: `R`, tagged tenant_b
/// (probe P8's foreign edge), and `L`, tagged `default` (a legacy edge). `S`
/// (a2 -> c1) is tenant_a's own, so every chain has a visible second hop.
/// `M` (a1 -> b1) is `default` across two tenants.
const Fixture = struct { a1: u64, a2: u64, b1: u64, foreign: u64, legacy: u64, cross: u64 };

fn seed(s: *Session) !Fixture {
    try s.execAs(tenant_a, "CREATE (:A {s: 'a1'})");
    try s.execAs(tenant_a, "CREATE (:A {s: 'a2'})");
    try s.execAs(tenant_a, "CREATE (:C {s: 'c1'})");
    try s.execAs(tenant_b, "CREATE (:B {s: 'b1'})");
    const st = s.store();
    const a1 = try s.idOf("a1");
    const a2 = try s.idOf("a2");
    const b1 = try s.idOf("b1");
    const c1 = try s.idOf("c1");
    // Every write carried its tenant, or the assertions below prove nothing.
    for ([_]u64{ a1, a2, c1 }) |id| {
        const tag = st.dupeNodeTenantForRead(testing.allocator, id) orelse return error.NodeNotFound;
        defer testing.allocator.free(tag);
        try testing.expectEqualStrings(tenant_a, tag);
    }
    const foreign = try st.createEdgeWithGraphAndTenant(a1, a2, "R", graph_store.DEFAULT_GRAPH_NAME, tenant_b);
    try st.setEdgeProperty(foreign, "secret", .{ .String = "b-secret" });
    const legacy = try st.createEdgeWithGraphAndTenant(a1, a2, "L", graph_store.DEFAULT_GRAPH_NAME, default_tenant);
    try st.setEdgeProperty(legacy, "secret", .{ .String = "default-secret" });
    _ = try st.createEdgeWithGraphAndTenant(a2, c1, "S", graph_store.DEFAULT_GRAPH_NAME, tenant_a);
    const cross = try st.createEdgeWithGraphAndTenant(a1, b1, "M", graph_store.DEFAULT_GRAPH_NAME, default_tenant);
    return .{ .a1 = a1, .a2 = a2, .b1 = b1, .foreign = foreign, .legacy = legacy, .cross = cross };
}

/// Every read path probe P8 found, for an edge of type `t` between a1 and a2
/// that tenant_a must not see.
fn expectHidden(f: *Failures, s: *Session, comptime t: []const u8) !void {
    // The strict single hop and variable length, as controls.
    try f.expectRows(s, tenant_a, "MATCH (a:A)-[r:" ++ t ++ "]->(b) RETURN r.secret", &.{});
    try f.expectRows(s, tenant_a, "MATCH (a:A)-[:" ++ t ++ "*1..1]->(b) RETURN b.s", &.{});
    // The multi-chain executor's first hop, chained and comma forms.
    try f.expectRows(s, tenant_a, "MATCH (a:A)-[r:" ++ t ++ "]->(b)-[:S]->(c) RETURN r.secret", &.{});
    try f.expectRows(s, tenant_a, "MATCH (a:A)-[r:" ++ t ++ "]->(b), (b)-[:S]->(c) RETURN r.secret", &.{});
    // The expression path.
    try f.expectRows(s, tenant_a, "MATCH (a:A {s: 'a1'}) RETURN [(a)-[r:" ++ t ++ "]->(b) | r.secret] AS xs", &.{"[]"});
    try f.expectRows(s, tenant_a, "MATCH (a:A {s: 'a1'}) RETURN COUNT { (a)-[:" ++ t ++ "]->() } AS c", &.{"0"});
    try f.expectRows(s, tenant_a, "MATCH (a:A {s: 'a1'}) RETURN EXISTS { (a)-[:" ++ t ++ "]->() } AS e", &.{"false"});
}

test "SONNY-2693: a tenant never reads another tenant's edge between its own nodes, nor a default one" {
    harness.silenceEngineLogs();
    var s = try Session.init();
    defer s.deinit();
    _ = try seed(&s);

    var f: Failures = .{};
    try expectHidden(&f, &s, "R");
    try expectHidden(&f, &s, "L");
    // With R and L hidden, a1 and a2 are not connected for tenant_a.
    try f.expectRows(&s, tenant_a, "RETURN shortestPath((a:A {s: 'a1'})-[*]-(b:A {s: 'a2'})) AS p", &.{"null"});
    // `MATCH p = shortestPath(..)` always yields one row; p is null here.
    try f.expectRows(&s, tenant_a, "MATCH p = shortestPath((a:A {s: 'a1'})-[*]-(b:A {s: 'a2'})) RETURN p", &.{"null"});
    try f.expectRows(&s, tenant_a, "MATCH p = shortestPath((a:A {s: 'a1'})-[*]-(b:A {s: 'a2'})) RETURN [x IN relationships(p) | x.secret] AS xs", &.{"[]"});
    // tenant_a's own edge, and the unscoped (admin) session, are unchanged.
    try f.expectRows(&s, tenant_a, "MATCH (a:A)-[r:S]->(c) RETURN a.s, c.s", &.{"a2|c1"});
    try f.expectRows(&s, null, "MATCH (a:A)-[r]->(b:A) RETURN type(r), r.secret", &.{ "L|default-secret", "R|b-secret" });
    try f.expectRows(&s, null, "MATCH (a:A {s: 'a1'}) RETURN COUNT { (a)-[:R]->() } AS c", &.{"1"});
    try f.check();
}

test "SONNY-2693: CALL geode.tenant.backfill_edge_tags re-tags the legacy edge, durably, and reports the mixed ones" {
    harness.silenceEngineLogs();
    var s = try Session.init();
    defer s.deinit();
    const fx = try seed(&s);

    user_mgmt.setAuthEnabled(false);
    defer user_mgmt.setAuthEnabled(true);

    // Rows render as edge_type|edge_tenant|from_tenant|to_tenant|action.
    const query_dry = "CALL geode.tenant.backfill_edge_tags(true) YIELD edge_type, edge_tenant, from_tenant, to_tenant, action";
    const query_run = "CALL geode.tenant.backfill_edge_tags() YIELD edge_type, edge_tenant, from_tenant, to_tenant, action";

    var f: Failures = .{};
    // A dry run reports and changes nothing: L stays hidden.
    try f.expectRows(&s, null, query_dry, &.{
        "L|default|tenant_a|tenant_a|would_retag",
        "M|default|tenant_a|tenant_b|mixed",
        "R|tenant_b|tenant_a|tenant_a|mixed",
    });
    try f.expectRows(&s, tenant_a, "MATCH (a:A)-[r:L]->(b) RETURN r.secret", &.{});

    try f.expectRows(&s, null, query_run, &.{
        "L|default|tenant_a|tenant_a|retagged",
        "M|default|tenant_a|tenant_b|mixed",
        "R|tenant_b|tenant_a|tenant_a|mixed",
    });
    // A second run lists only the edges it cannot place.
    try f.expectRows(&s, null, query_run, &.{
        "M|default|tenant_a|tenant_b|mixed",
        "R|tenant_b|tenant_a|tenant_a|mixed",
    });

    // The re-tagged edge is tenant_a's on every path; R is still hidden.
    try f.expectRows(&s, tenant_a, "MATCH (a:A)-[r:L]->(b) RETURN r.secret", &.{"default-secret"});
    try f.expectRows(&s, tenant_a, "MATCH (a:A)-[r:L]->(b)-[:S]->(c) RETURN r.secret", &.{"default-secret"});
    try f.expectRows(&s, tenant_a, "MATCH (a:A {s: 'a1'}) RETURN [(a)-[r:L]->(b) | r.secret] AS xs", &.{"[default-secret]"});
    try f.expectRows(&s, tenant_a, "MATCH (a:A {s: 'a1'}) RETURN COUNT { (a)-[:L]->() } AS c", &.{"1"});
    try f.expectRows(&s, tenant_a, "RETURN shortestPath((a:A {s: 'a1'})-[*]-(b:A {s: 'a2'})) AS p", &.{"p(a1>a2)"});
    try f.expectRows(&s, tenant_a, "MATCH p = shortestPath((a:A {s: 'a1'})-[*]-(b:A {s: 'a2'})) RETURN [x IN relationships(p) | x.secret] AS xs", &.{"[default-secret]"});
    try expectHidden(&f, &s, "R");
    try f.check();

    // The new tag is in the engine, not only in the cache: drop the cached
    // body and read it back from storage.
    const st = s.store();
    try testing.expect(graph_store.getGlobalAdapter() != null);
    st.edges.remove(fx.legacy);
    const reread = (try st.getEdgeHydratedChecked(fx.legacy)) orelse return error.EdgeNotRehydrated;
    try testing.expectEqualStrings(tenant_a, reread.tenant_id);
    const cross = (try st.getEdgeHydratedChecked(fx.cross)) orelse return error.EdgeNotFound;
    try testing.expectEqualStrings(default_tenant, cross.tenant_id);
}

test "SONNY-2693: backfill_edge_tags is admin-only and takes one optional boolean" {
    harness.silenceEngineLogs();
    var s = try Session.init();
    defer s.deinit();
    const fx = try seed(&s);

    // A non-admin session is refused before anything is read or written.
    user_mgmt.setAuthEnabled(true);
    s.ctx.role = .ReadOnly;
    s.ctx.user = "bob";
    try testing.expectError(error.Unauthorized, s.runAs(null, "CALL geode.tenant.backfill_edge_tags()"));
    try testing.expectError(error.Unauthorized, s.runAs(null, "CALL geode.tenant.backfill_edge_tags(true)"));
    s.ctx.role = null;
    s.ctx.user = null;
    const legacy = (try s.store().getEdgeHydratedChecked(fx.legacy)) orelse return error.EdgeNotFound;
    try testing.expectEqualStrings(default_tenant, legacy.tenant_id);

    user_mgmt.setAuthEnabled(false);
    defer user_mgmt.setAuthEnabled(true);
    try testing.expectError(error.TypeMismatch, s.runAs(null, "CALL geode.tenant.backfill_edge_tags('yes')"));
    try testing.expectError(error.InvalidArgs, s.runAs(null, "CALL geode.tenant.backfill_edge_tags(true, true)"));
}

// ---------------------------------------------------------------------------
// SONNY-2733: who may run the backfill, what it leaves alone, and how it
// reports an edge it cannot re-tag. (Its locking is covered by
// tests/test_sonny2733_backfill_locking.zig.)
// ---------------------------------------------------------------------------

test "SONNY-2733: backfill_edge_tags refuses a tenant-scoped session, and a real run inside a transaction" {
    harness.silenceEngineLogs();
    var s = try Session.init();
    defer s.deinit();
    const fx = try seed(&s);

    user_mgmt.setAuthEnabled(false);
    defer user_mgmt.setAuthEnabled(true);

    // It changes every tenant's edges, so a session scoped to one tenant may
    // not run it, not even as a dry run.
    try testing.expectError(error.TenantScopedSession, s.runAs(tenant_a, "CALL geode.tenant.backfill_edge_tags()"));
    try testing.expectError(error.TenantScopedSession, s.runAs(tenant_b, "CALL geode.tenant.backfill_edge_tags(true)"));
    try testing.expectEqualStrings(default_tenant, try tagOf(s.store(), fx.legacy));
    // An unset, empty or `default` scope is no tenant's.
    try s.execAs(default_tenant, "CALL geode.tenant.backfill_edge_tags(true)");
    try s.execAs("", "CALL geode.tenant.backfill_edge_tags(true)");

    // A ROLLBACK could not undo its re-tags, so a real run is refused inside a
    // transaction. A dry run changes nothing and is not.
    s.ctx.transaction_state = .Active;
    defer s.ctx.transaction_state = .None;
    try testing.expectError(error.BackfillInTransaction, s.runAs(null, "CALL geode.tenant.backfill_edge_tags()"));
    try s.execAs(null, "CALL geode.tenant.backfill_edge_tags(true)");
    try testing.expectEqualStrings(default_tenant, try tagOf(s.store(), fx.legacy));
}

test "SONNY-2733: the backfill leaves the engine's own graphs alone" {
    harness.silenceEngineLogs();
    var s = try Session.init();
    defer s.deinit();
    const st = s.store();
    const node_labels = [_][]const u8{"N"};

    // A legacy-shaped edge in the security graph, and the same shape in a
    // user graph.
    const internal = graph_store.SECURITY_GRAPH_NAME;
    try st.createGraph(internal);
    const n1 = try st.createNodeWithGraphAndTenant(&node_labels, internal, tenant_a);
    const n2 = try st.createNodeWithGraphAndTenant(&node_labels, internal, tenant_a);
    const kept = try st.createEdgeWithGraphAndTenant(n1, n2, "K", internal, default_tenant);
    const user_graph = "g2733";
    try st.createGraph(user_graph);
    const m1 = try st.createNodeWithGraphAndTenant(&node_labels, user_graph, tenant_a);
    const m2 = try st.createNodeWithGraphAndTenant(&node_labels, user_graph, tenant_a);
    const fixed = try st.createEdgeWithGraphAndTenant(m1, m2, "K", user_graph, default_tenant);

    const run = try st.backfillEdgeTenantTags(testing.allocator, false);
    defer GraphStore.freeEdgeTagBackfillEntries(testing.allocator, run);
    try testing.expect(entryFor(run, kept) == null);
    try expectEntry(run, fixed, .retagged, default_tenant, tenant_a, tenant_a);
    try testing.expectEqualStrings(default_tenant, try tagOf(st, kept));
    try testing.expectEqualStrings(tenant_a, try tagOf(st, fixed));

    // `__geode_…` is the engine's namespace; nothing else is.
    try testing.expect(graph_store.isInternalGraphName(internal));
    try testing.expect(graph_store.isInternalGraphName("__geode_other"));
    try testing.expect(!graph_store.isInternalGraphName("geode_security"));
    try testing.expect(!graph_store.isInternalGraphName("__staging"));
}

test "SONNY-2733: an edge the backfill cannot re-tag is listed as failed and left as it was, and the run goes on" {
    harness.silenceEngineLogs();
    var s = try Session.init();
    defer s.deinit();
    const fx = try seed(&s);
    const st = s.store();
    const node_labels = [_][]const u8{"N"};
    const g = graph_store.DEFAULT_GRAPH_NAME;

    // A second legacy edge, which the run must still re-tag.
    const a3 = try st.createNodeWithGraphAndTenant(&node_labels, g, tenant_a);
    const a4 = try st.createNodeWithGraphAndTenant(&node_labels, g, tenant_a);
    const other = try st.createEdgeWithGraphAndTenant(a3, a4, "L2", g, default_tenant);

    // Break the first legacy edge's re-tag: its source node loses its engine
    // slot mapping, so the re-tag cannot address the edge in storage. The
    // node's tenant still reads from the cache, so the backfill still decides
    // to re-tag it.
    const id_map = st.getIdMap(g) orelse return error.IdMapMissing;
    const a1_slot = id_map.nodeSlot(fx.a1) orelse return error.NodeSlotMissing;
    try testing.expect(id_map.removeNode(fx.a1));
    var restored = false;
    defer if (!restored) id_map.insertNodeWithSlot(fx.a1, a1_slot) catch {};

    {
        const run = try st.backfillEdgeTenantTags(testing.allocator, false);
        defer GraphStore.freeEdgeTagBackfillEntries(testing.allocator, run);
        try expectEntry(run, fx.legacy, .failed, default_tenant, tenant_a, tenant_a);
        const failed = entryFor(run, fx.legacy).?;
        try testing.expectEqualStrings("NodeSlotMappingMissing", failed.reason orelse return error.MissingReason);
        try expectEntry(run, other, .retagged, default_tenant, tenant_a, tenant_a);
        try testing.expect(entryFor(run, other).?.reason == null);
        try expectEntry(run, fx.foreign, .mixed, tenant_b, tenant_a, tenant_a);
    }
    try testing.expectEqualStrings(default_tenant, try tagOf(st, fx.legacy));
    try testing.expectEqualStrings(tenant_a, try tagOf(st, other));

    // Nothing reached storage either: with the mapping back, drop the cached
    // body and read the edge back from the engine.
    try id_map.insertNodeWithSlot(fx.a1, a1_slot);
    restored = true;
    st.edges.remove(fx.legacy);
    try testing.expectEqualStrings(default_tenant, try tagOf(st, fx.legacy));

    // The next run re-tags it, and lists nothing it re-tagged before.
    {
        const run = try st.backfillEdgeTenantTags(testing.allocator, false);
        defer GraphStore.freeEdgeTagBackfillEntries(testing.allocator, run);
        try expectEntry(run, fx.legacy, .retagged, default_tenant, tenant_a, tenant_a);
        try testing.expect(entryFor(run, other) == null);
    }
    try testing.expectEqualStrings(tenant_a, try tagOf(st, fx.legacy));
}

test "SONNY-2733: CALL geode.tenant.backfill_edge_tags reports a failed edge's reason" {
    harness.silenceEngineLogs();
    var s = try Session.init();
    defer s.deinit();
    const fx = try seed(&s);
    const st = s.store();

    user_mgmt.setAuthEnabled(false);
    defer user_mgmt.setAuthEnabled(true);

    const id_map = st.getIdMap(graph_store.DEFAULT_GRAPH_NAME) orelse return error.IdMapMissing;
    const a1_slot = id_map.nodeSlot(fx.a1) orelse return error.NodeSlotMissing;
    try testing.expect(id_map.removeNode(fx.a1));
    defer id_map.insertNodeWithSlot(fx.a1, a1_slot) catch {};

    // Rows render as edge_type|edge_tenant|action|reason.
    var f: Failures = .{};
    try f.expectRows(&s, null, "CALL geode.tenant.backfill_edge_tags() YIELD edge_type, edge_tenant, action, reason", &.{
        "L|default|failed|NodeSlotMappingMissing",
        "M|default|mixed|null",
        "R|tenant_b|mixed|null",
    });
    try f.check();
}
