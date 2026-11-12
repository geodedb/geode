// SONNY-2976 (with SONNY-2724): the server's bulk MERGE matches a node only in
// the merging session's tenant.
//
// MERGE's property index (graph_store.merge_prop_index) is keyed by
// (graph, label, key, value) and names ONE node, the lowest id holding the
// key, whatever its tenant. The storage adapter's bulk MERGE primitives
// (`bulkMergeNodeWithReservedIdForTenant`, the multi-property variant and the
// direct `bulkMergeNode`) took that node as the match without looking at its
// tenant tag, so a MERGE run for tenant B matched tenant A's node, rewrote its
// properties (ON MATCH / bare SET) and answered A's node id to B, and B got
// no node of its own. On v0.8.22 any tenant-scoped QUIC client reached this
// through a simple MERGE; v0.8.23 gated the QUIC dispatcher (SONNY-2686,
// 366f96bf), but the adapter stayed wrong for any caller that reaches it.
//
// The rule now is the general executor's (`crud_operations.findMergeMatch`):
// a session with a concrete tenant matches only a node tagged with exactly
// that tenant (the lowest such id) and otherwise creates its own node tagged
// with it; a session without one (`default`) matches the lowest holder in any
// tenant, as the executor's unscoped MERGE does.
//
// Driven through the real storage adapter and graph store, persisted, with a
// bounded node cache, an unbounded one, and lean indexing
// (GEODE_INDEX_MERGE_KEYS_ONLY), and again after a clean reopen; the per-
// tenant MATCH of the general executor is the independent oracle.
//
// CANARY: REQ=REQ-SONNY-2976-MERGE-TENANT-SCOPE; FEATURE="MergeRowVisibility"; ASPECT=AdapterRegression; STATUS=TESTED; TEST=tests/test_sonny2976_merge_fast_path_tenant_scope.zig; OWNER=security; UPDATED=2026-11-11

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const harness = @import("node_scan_stream_harness.zig");

const execution = geode.execution;
const graph_store = geode.graph_store;
const index_manager = geode.index_manager;
const gsa = geode.graph_storage_adapter;
const Value = geode.value_types.Value;
const PropertyValue = graph_store.PropertyValue;
const PropKV = gsa.StorageAdapter.PropKV;
const G = graph_store.DEFAULT_GRAPH_NAME;

const TA = "t2976a";
const TB = "t2976b";
const UNSCOPED = graph_store.DEFAULT_TENANT_ID;

const Mode = enum {
    /// Persisted, the node cache bounded.
    persisted,
    /// Persisted, the node cache unbounded (`GEODE_NODE_CACHE_ENTRIES=0`).
    unbounded_cache,
    /// Persisted, lean indexing (`GEODE_INDEX_MERGE_KEYS_ONLY`).
    lean,
};

const modes = [_]Mode{ .persisted, .unbounded_cache, .lean };

extern "c" fn setenv(name: [*:0]const u8, value: [*:0]const u8, overwrite: c_int) c_int;
extern "c" fn unsetenv(name: [*:0]const u8) c_int;

const Session = struct {
    mode: Mode,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    catalog: @FieldType(execution.ExecutionContext, "catalog"),

    fn init(mode: Mode) !Session {
        const allocator = testing.allocator;
        if (mode == .unbounded_cache) {
            if (setenv("GEODE_NODE_CACHE_ENTRIES", "0", 1) != 0) return error.SetEnvFailed;
        }
        errdefer _ = unsetenv("GEODE_NODE_CACHE_ENTRIES");
        graph_store.setLeanIndexingForTest(mode == .lean);
        errdefer graph_store.setLeanIndexingForTest(false);
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const data_dir = try harness.tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);
        graph_store.setDataDirOverride(allocator, data_dir);
        const catalog = try execution.ensureCatalogInstance(allocator);
        errdefer execution.cleanupCatalogInstance();
        _ = graph_store.getGlobalStore(allocator);
        if (graph_store.getGlobalAdapter() == null) return error.WrongDeployment;
        return .{
            .mode = mode,
            .arena = std.heap.ArenaAllocator.init(allocator),
            .tmp = tmp,
            .data_dir = data_dir,
            .catalog = catalog,
        };
    }

    fn deinit(self: *Session) void {
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        self.arena.deinit();
        graph_store.setDataDirOverride(testing.allocator, null);
        testing.allocator.free(self.data_dir);
        self.tmp.cleanup();
        _ = unsetenv("GEODE_NODE_CACHE_ENTRIES");
        graph_store.setLeanIndexingForTest(false);
    }

    /// Close the store cleanly and open it again on the same directory.
    fn reopen(self: *Session) !void {
        const allocator = testing.allocator;
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        graph_store.resetLazyHydrateCounters();
        graph_store.setDataDirOverride(allocator, self.data_dir);
        _ = graph_store.getGlobalStore(allocator);
        self.catalog = try execution.ensureCatalogInstance(allocator);
    }

    fn ctxFor(self: *Session, tenant: ?[]const u8) execution.ExecutionContext {
        return .{ .catalog = self.catalog, .tenant_id = tenant };
    }

    /// Run `query` through the general executor as a session of `tenant`
    /// (null: unscoped), with its context active as the transports do.
    fn run(self: *Session, tenant: ?[]const u8, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        var ctx = self.ctxFor(tenant);
        const prev = execution.pushActiveContext(&ctx);
        defer execution.popActiveContext(prev);
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], ctx);
    }

    fn exec(self: *Session, tenant: ?[]const u8, query: []const u8) !void {
        var r = try self.run(tenant, query);
        r.deinit(self.arena.allocator());
    }
};

/// Every failed check, reported together.
const Failures = struct {
    items: std.ArrayList([]const u8) = .empty,

    fn add(self: *Failures, comptime fmt: []const u8, args: anytype) !void {
        try self.items.append(testing.allocator, try std.fmt.allocPrint(testing.allocator, fmt, args));
    }

    fn deinit(self: *Failures) void {
        for (self.items.items) |msg| testing.allocator.free(msg);
        self.items.deinit(testing.allocator);
    }

    fn check(self: *Failures, name: []const u8) !void {
        if (self.items.items.len == 0) return;
        std.debug.print("\n{s}: {d} failed check(s):\n", .{ name, self.items.items.len });
        for (self.items.items) |msg| std.debug.print("  {s}\n", .{msg});
        return error.MergeMatchedAcrossTenants;
    }
};

fn renderCell(aa: std.mem.Allocator, cell: Value) ![]const u8 {
    return switch (cell) {
        .Str => |s| try std.fmt.allocPrint(aa, "'{s}'", .{s}),
        .Int => |n| try std.fmt.allocPrint(aa, "{d}", .{n}),
        .Null => "null",
        else => try std.fmt.allocPrint(aa, "<{s}>", .{@tagName(cell)}),
    };
}

/// The executor's rows for `query` as a session of `tenant`, each row's cells
/// joined by '|', the rows sorted and joined by ';'.
fn rowsOf(s: *Session, tenant: ?[]const u8, query: []const u8) ![]const u8 {
    const aa = s.arena.allocator();
    var result = s.run(tenant, query) catch |err| return std.fmt.allocPrint(aa, "error:{s}", .{@errorName(err)});
    defer result.deinit(aa);
    const rows = try aa.alloc([]const u8, result.rows.len);
    for (result.rows, rows) |row, *out| {
        var cells: std.ArrayList(u8) = .empty;
        for (row, 0..) |cell, i| {
            if (i > 0) try cells.append(aa, '|');
            try cells.appendSlice(aa, try renderCell(aa, cell));
        }
        out.* = try cells.toOwnedSlice(aa);
    }
    std.mem.sort([]const u8, rows, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);
    return std.mem.join(aa, ";", rows);
}

fn expectRows(s: *Session, f: *Failures, what: []const u8, tenant: ?[]const u8, query: []const u8, want: []const u8) !void {
    const got = try rowsOf(s, tenant, query);
    if (!std.mem.eql(u8, got, want)) try f.add("[{s}] {s}: as {s}, {s}: expected {s}, got {s}", .{ @tagName(s.mode), what, tenant orelse "unscoped", query, want, got });
}

/// Node `id`'s tenant tag and its `v` property as "tenant/v".
fn describe(aa: std.mem.Allocator, id: u64) ![]const u8 {
    const store = graph_store.getGlobalStore(testing.allocator);
    const node = (try store.nodes.getOrHydratePtr(id)) orelse return "missing";
    const v = node.properties.get("v") orelse return std.fmt.allocPrint(aa, "{s}/-", .{node.tenant_id});
    return switch (v) {
        .String => |t| std.fmt.allocPrint(aa, "{s}/{s}", .{ node.tenant_id, t }),
        else => std.fmt.allocPrint(aa, "{s}/?", .{node.tenant_id}),
    };
}

fn expectNode(s: *Session, f: *Failures, what: []const u8, id: u64, want: []const u8) !void {
    const got = try describe(s.arena.allocator(), id);
    if (!std.mem.eql(u8, got, want)) try f.add("[{s}] {s}: node {d} expected {s}, got {s}", .{ @tagName(s.mode), what, id, want, got });
}

fn nowNs() u64 {
    var ts: std.posix.timespec = .{ .sec = 0, .nsec = 0 };
    _ = std.c.clock_gettime(std.c.CLOCK.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ns_per_s + @as(u64, @intCast(ts.nsec));
}

fn adapter() !*gsa.StorageAdapter {
    return graph_store.getGlobalAdapter() orelse error.NoAdapter;
}

fn reserve() u64 {
    return graph_store.getGlobalStore(testing.allocator).reserveNodeId();
}

const Shape = enum { single, multi, direct };

/// One bulk MERGE of `(:label {k: 1[, j: 'x']}) SET n.v = v` for `tenant`
/// through the adapter primitive the server calls for `shape`.
fn bulkMerge(shape: Shape, label: []const u8, tenant: []const u8, v: []const u8, apply_on_match: bool) !gsa.StorageAdapter.MergeResult {
    const a = try adapter();
    const set = [_]PropKV{.{ .key = "v", .value = .{ .String = v } }};
    switch (shape) {
        .single => return a.bulkMergeNodeWithReservedIdForTenant(G, reserve(), label, "k", .{ .Int = 1 }, &set, apply_on_match, tenant),
        .multi => {
            const keys = [_]PropKV{ .{ .key = "k", .value = .{ .Int = 1 } }, .{ .key = "j", .value = .{ .String = "x" } } };
            return a.bulkMergeNodeWithReservedIdMultiPropForTenant(G, reserve(), label, &keys, &set, apply_on_match, tenant);
        },
        .direct => {
            // The group-commit-off path resolves its tenant from the active
            // context, as on the QUIC handler thread.
            var ctx: execution.ExecutionContext = .{ .catalog = try execution.ensureCatalogInstance(testing.allocator), .tenant_id = if (std.mem.eql(u8, tenant, UNSCOPED)) null else tenant };
            const prev = execution.pushActiveContext(&ctx);
            defer execution.popActiveContext(prev);
            return a.bulkMergeNode(G, label, "k", .{ .Int = 1 }, &set, null, apply_on_match);
        },
    }
}

fn keyPattern(shape: Shape) []const u8 {
    return if (shape == .multi) "{k: 1, j: 'x'}" else "{k: 1}";
}

/// The reporter's reproduction for one primitive, then the rest of the
/// contract: a cross-tenant hit is a miss, a same-tenant hit still matches,
/// an unscoped MERGE matches the lowest holder in any tenant, and all of it
/// survives a reopen.
fn checkShape(s: *Session, f: *Failures, shape: Shape) !void {
    const aa = s.arena.allocator();
    const label = try std.fmt.allocPrint(aa, "L2976{s}", .{@tagName(shape)});
    const what = @tagName(shape);
    const by_v = try std.fmt.allocPrint(aa, "MATCH (n:{s}) RETURN n.v", .{label});
    const count_q = try std.fmt.allocPrint(aa, "MATCH (n:{s}) RETURN count(n)", .{label});

    const a1 = try bulkMerge(shape, label, TA, "a", true);
    try expectNode(s, f, what, a1.id, TA ++ "/a");

    // Tenant B merges the same key: it must get its own node, and A's must
    // be left exactly as it was.
    const b1 = try bulkMerge(shape, label, TB, "b", true);
    if (b1.id == a1.id) try f.add("[{s}] {s}: tenant B's MERGE answered tenant A's node {d}", .{ @tagName(s.mode), what, a1.id });
    if (!b1.wrote) try f.add("[{s}] {s}: tenant B's MERGE reported no write", .{ @tagName(s.mode), what });
    try expectNode(s, f, what, a1.id, TA ++ "/a");
    try expectNode(s, f, what, b1.id, TB ++ "/b");

    // Same-tenant repeats match their own node (idempotent).
    for (0..3) |_| {
        const a2 = try bulkMerge(shape, label, TA, "a2", true);
        if (a2.id != a1.id) try f.add("[{s}] {s}: tenant A's repeat MERGE answered {d}, want its node {d}", .{ @tagName(s.mode), what, a2.id, a1.id });
        const b2 = try bulkMerge(shape, label, TB, "b2", false);
        if (b2.id != b1.id) try f.add("[{s}] {s}: tenant B's repeat MERGE answered {d}, want its node {d}", .{ @tagName(s.mode), what, b2.id, b1.id });
        if (b2.wrote) try f.add("[{s}] {s}: tenant B's ON CREATE-only repeat reported a write", .{ @tagName(s.mode), what });
    }
    try expectNode(s, f, what, a1.id, TA ++ "/a2");
    try expectNode(s, f, what, b1.id, TB ++ "/b");

    // The executor's MATCH, per tenant, is the oracle.
    try expectRows(s, f, what, TA, by_v, "'a2'");
    try expectRows(s, f, what, TB, by_v, "'b'");
    try expectRows(s, f, what, null, count_q, "2");
    // A point read through the exact index agrees.
    try expectRows(s, f, what, TB, try std.fmt.allocPrint(aa, "MATCH (n:{s} {{v: 'b'}}) RETURN count(n)", .{label}), "1");
    try expectRows(s, f, what, TA, try std.fmt.allocPrint(aa, "MATCH (n:{s} {{v: 'b'}}) RETURN count(n)", .{label}), "0");

    // An unscoped MERGE matches the lowest holder in any tenant (the
    // executor's unscoped MERGE does the same) and creates nothing.
    const u = try bulkMerge(shape, label, UNSCOPED, "u", false);
    if (u.id != @min(a1.id, b1.id)) try f.add("[{s}] {s}: an unscoped MERGE answered {d}, want the lowest holder {d}", .{ @tagName(s.mode), what, u.id, @min(a1.id, b1.id) });
    try expectRows(s, f, what, null, count_q, "2");

    // After a clean reopen the store answers the same.
    try s.reopen();
    const b3 = try bulkMerge(shape, label, TB, "b3", true);
    if (b3.id != b1.id) try f.add("[{s}] {s}: after a reopen tenant B's MERGE answered {d}, want its node {d}", .{ @tagName(s.mode), what, b3.id, b1.id });
    try expectNode(s, f, what, a1.id, TA ++ "/a2");
    try expectNode(s, f, what, b1.id, TB ++ "/b3");
    try expectRows(s, f, what, TA, by_v, "'a2'");
    try expectRows(s, f, what, TB, by_v, "'b3'");
    try expectRows(s, f, what, null, count_q, "2");
}

test "SONNY-2976: the server's bulk MERGE never matches or rewrites another tenant's node" {
    harness.silenceEngineLogs();
    var f: Failures = .{};
    defer f.deinit();
    for (modes) |mode| {
        for ([_]Shape{ .single, .multi, .direct }) |shape| {
            var s = try Session.init(mode);
            defer s.deinit();
            try checkShape(&s, &f, shape);
        }
    }
    try f.check("bulk MERGE tenant scope");
}

test "SONNY-2976: tenant B's own node is found when tenant A holds the lower id (bounded cache, cold store)" {
    // A's node is the lowest holder and so the one the merge index names; B's
    // node must still be found (no duplicate), also once evicted and after a
    // reopen, when it is resolved from the engine.
    harness.silenceEngineLogs();
    var f: Failures = .{};
    defer f.deinit();
    for (modes) |mode| {
        var s = try Session.init(mode);
        defer s.deinit();
        try s.exec(TA, "CREATE (:C2976 {k: 1, v: 'a'})");
        try s.exec(TB, "CREATE (:C2976 {k: 1, v: 'b'})");
        try s.reopen();
        for (0..3) |_| _ = try bulkMerge(.single, "C2976", TB, "b", false);
        _ = try bulkMerge(.multi, "C2976", TB, "b", false); // {k:1, j:'x'} is a new key for B
        try expectRows(&s, &f, "cold", TB, "MATCH (n:C2976) RETURN n.k, n.v", "1|'b';1|'b'");
        try expectRows(&s, &f, "cold", TA, "MATCH (n:C2976) RETURN n.k, n.v", "1|'a'");
        try expectRows(&s, &f, "cold", null, "MATCH (n:C2976) RETURN count(n)", "3");
    }
    try f.check("cold store");
}

test "SONNY-2976: the executor and the bulk MERGE write the same rows for the same statements" {
    harness.silenceEngineLogs();
    var f: Failures = .{};
    defer f.deinit();
    for (modes) |mode| {
        var s = try Session.init(mode);
        defer s.deinit();
        // The same sequence through the executor (label P) and the adapter
        // (label Q): A, B, A again, unscoped (matches, writes nothing).
        const steps = [_]struct { tenant: []const u8, v: []const u8 }{
            .{ .tenant = TA, .v = "a" }, .{ .tenant = TB, .v = "b" }, .{ .tenant = TA, .v = "a2" },
        };
        for (steps) |st| {
            const q = try std.fmt.allocPrint(s.arena.allocator(), "MERGE (n:P2976 {{k: 1}}) SET n.v = '{s}'", .{st.v});
            try s.exec(st.tenant, q);
            _ = try bulkMerge(.single, "Q2976", st.tenant, st.v, true);
        }
        try s.exec(null, "MERGE (n:P2976 {k: 1})");
        _ = try bulkMerge(.single, "Q2976", UNSCOPED, "-", false);
        for ([_]?[]const u8{ TA, TB, null }) |t| {
            const p = try rowsOf(&s, t, "MATCH (n:P2976) RETURN n.k, n.v");
            const q = try rowsOf(&s, t, "MATCH (n:Q2976) RETURN n.k, n.v");
            if (!std.mem.eql(u8, p, q)) try f.add("[{s}] parity as {s}: executor {s}, bulk MERGE {s}", .{ @tagName(mode), t orelse "unscoped", p, q });
        }
    }
    try f.check("executor parity");
}

const RaceCtx = struct {
    tenant: []const u8,
    label: []const u8,
    err: ?anyerror = null,

    fn run(c: *RaceCtx) void {
        for (0..8) |_| {
            _ = bulkMerge(.single, c.label, c.tenant, c.tenant, true) catch |e| {
                c.err = e;
                return;
            };
        }
    }
};

test "SONNY-2976: concurrent same-key MERGEs make exactly one node per tenant" {
    harness.silenceEngineLogs();
    var f: Failures = .{};
    defer f.deinit();
    var s = try Session.init(.persisted);
    defer s.deinit();
    // Prime the graph and its exact index outside the race.
    _ = try bulkMerge(.single, "Prime2976", UNSCOPED, "p", false);

    var ctxs: [8]RaceCtx = undefined;
    var threads: [8]std.Thread = undefined;
    // One tenant: eight writers, one key.
    for (&ctxs, 0..) |*c, i| {
        c.* = .{ .tenant = TA, .label = "R2976one" };
        threads[i] = try std.Thread.spawn(.{}, RaceCtx.run, .{c});
    }
    for (threads) |t| t.join();
    for (ctxs) |c| if (c.err) |e| try f.add("one tenant: writer failed: {s}", .{@errorName(e)});
    try expectRows(&s, &f, "race, one tenant", null, "MATCH (n:R2976one) RETURN count(n)", "1");

    // Two tenants: four writers each, one key.
    for (&ctxs, 0..) |*c, i| {
        c.* = .{ .tenant = if (i % 2 == 0) TA else TB, .label = "R2976two" };
        threads[i] = try std.Thread.spawn(.{}, RaceCtx.run, .{c});
    }
    for (threads) |t| t.join();
    for (ctxs) |c| if (c.err) |e| try f.add("two tenants: writer failed: {s}", .{@errorName(e)});
    try expectRows(&s, &f, "race, two tenants", null, "MATCH (n:R2976two) RETURN count(n)", "2");
    try expectRows(&s, &f, "race, two tenants", TA, "MATCH (n:R2976two) RETURN n.v", "'" ++ TA ++ "'");
    try expectRows(&s, &f, "race, two tenants", TB, "MATCH (n:R2976two) RETURN n.v", "'" ++ TB ++ "'");
    try f.check("concurrent MERGE");
}

test "SONNY-2976: timing of unscoped single-key bulk MERGE (SONNY2976_TIMING=N to run)" {
    // Not an assertion: prints the wall time of N distinct-key unscoped bulk
    // MERGEs through the group-commit primitive, the single-tenant ingest hot
    // path the fix must not slow down. Skipped unless SONNY2976_TIMING is set.
    const raw = std.c.getenv("SONNY2976_TIMING") orelse return;
    const n = std.fmt.parseUnsigned(usize, std.mem.span(raw), 10) catch 100_000;
    harness.silenceEngineLogs();
    var s = try Session.init(.persisted);
    defer s.deinit();
    const a = try adapter();
    const t0 = nowNs();
    for (0..n) |i| {
        const set = [_]PropKV{.{ .key = "v", .value = .{ .Int = @intCast(i) } }};
        _ = try a.bulkMergeNodeWithReservedIdForTenant(G, reserve(), "T2976", "k", .{ .Int = @intCast(i) }, &set, false, UNSCOPED);
    }
    const t1 = nowNs();
    const create_ns = t1 - t0;
    for (0..n) |i| {
        _ = try a.bulkMergeNodeWithReservedIdForTenant(G, reserve(), "T2976", "k", .{ .Int = @intCast(i) }, &.{}, false, UNSCOPED);
    }
    const hit_ns = nowNs() - t1;
    std.debug.print("\nSONNY2976_TIMING n={d} create_ms={d} hit_ms={d}\n", .{ n, create_ns / std.time.ns_per_ms, hit_ns / std.time.ns_per_ms });
}
