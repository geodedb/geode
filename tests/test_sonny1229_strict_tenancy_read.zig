// SONNY-1229 (GEO-UP-002) reproduction / regression: cross-tenant READ leak on
// the engine-direct node-scan fast path.
//
// DEFECT (found by the Go driver lane against the 0.8.15 image, task-8-report
// §5): with `GEODE_STRICT_TENANCY=1` and two registered tenants bound to the
// SAME graph, `MATCH (n:P) RETURN n.who` issued as tenant-b returned tenant-a's
// rows, and a session bound to a tenant that was never registered read EVERY
// row. Writes were tagged correctly (a cross-tenant `MATCH … DELETE` matched
// zero rows, because `crud_operations` applies `passesTenantFilterSlice`) and an
// UNSCOPED session was correctly refused with 42501 — so the executor path
// filtered and only the engine-direct READ path did not.
//
// ROOT CAUSE: `src/server/node_scan_stream.zig` is the engine-direct streaming
// fast path both transports try FIRST for a single-node-pattern MATCH whose
// RETURN list is bare variable / property references (and for `count(n)`). It
// reads slot ids + properties straight from the storage adapter and has NO
// tenant logic at all — it never consults `context.tenant_id`, never calls
// `passesTenantFilterSlice`, and never consults the GAP-0846 hierarchy. The
// transports gated it only on `rls_active` (`readServedEngineDirect` /
// `readWillStreamEngineSide`, `quic_connection_handler.zig` and the gRPC twin),
// never on tenant scope. Every row of the scanned label was therefore returned
// to whatever session asked, regardless of its tenant binding.
//
// FIX (fail closed): one shared predicate — `canServeEngineDirect` /
// `tenantScopePermitsEngineDirect` in `node_scan_stream.zig`, the same shape as
// SONNY-1218's `adapterCanServeEngineDirect` — consulted by `prepare` (every
// projection mode) AND by `isEligible` (so the transports' snapshot-clone-skip
// decision can never claim a shape `prepare` will refuse). It DECLINES to the
// executor whenever the session has a concrete tenant scope, or strict tenancy
// is effective and the session has none (the executor then raises the 42501 the
// driver already sees). The executor applies the hierarchy-aware
// `passesTenantFilter` at every read site, so declining restores correctness.
//
// These tests drive the REAL transport decision sequence via `transportRows`
// (try `node_scan_stream.prepare`, fall back to the executor) so they fail RED
// against the pre-fix engine exactly the way the wire did, and the last test
// asserts that with NO tenant scope and strict tenancy OFF the fast path STILL
// engages — so the fix cannot be "achieved" by disabling the fast path.
//
// CANARY: REQ=REQ-SONNY-1229-ENGINE-DIRECT-TENANCY; FEATURE="EngineDirectTenantScope"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny1229_strict_tenancy_read.zig; OWNER=security; UPDATED=2026-09-13

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const rls = @import("rls");
const rls_types = @import("rls_types");

const execution = geode.execution;
const graph_store = geode.graph_store;
const node_scan_stream = geode.node_scan_stream;
const tenancy = geode.tenancy;
const query_arena = geode.query_arena;

const tenant_a = "tenant-a";
const tenant_b = "tenant-b";
/// A tenant that is NOT registered and participates in no hierarchy. It can
/// satisfy neither the exact-match arm nor `canAccessTenantSafe`, so it must
/// see NOTHING. This is the probe that proved the filter was not consulted at
/// all (driver report §5, narrowing probe 2).
const tenant_ghost = "t-never-registered";

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

/// Server-shaped harness: a PERSISTED deployment (`--data-dir`, so
/// `getGlobalAdapter() != null` and the engine-direct fast path is live — the
/// SONNY-1218 adapter guard must not be what declines here), a live globally
/// published expr-RLS engine whose `HierarchyManager` holds the registered
/// tenants (the same seam `CALL geode.tenant.create` populates), and the
/// process-wide strict-tenancy flag under test.
const Harness = struct {
    allocator: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    engine: *rls.RLSEngine,
    ctx: execution.ExecutionContext,

    pub fn init(allocator: std.mem.Allocator, strict: bool) !Harness {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, null);
        tenancy.setStrictTenancy(strict);
        tenancy.resetWarnState();

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);

        graph_store.setDataDirOverride(allocator, data_dir);
        _ = graph_store.getGlobalStore(allocator);

        // Fail LOUD rather than silently proving nothing: without the adapter
        // the SONNY-1218 guard would decline every shape and each assertion
        // below would pass for the wrong reason.
        if (graph_store.getGlobalAdapter() == null) return error.ExpectedPersistedAdapter;

        const catalog = try execution.ensureCatalogInstance(allocator);

        const engine = try allocator.create(rls.RLSEngine);
        errdefer allocator.destroy(engine);
        engine.* = try rls.RLSEngine.init(allocator);
        rls_types.setGlobalExprRLSEngine(@ptrCast(engine));

        return .{
            .allocator = allocator,
            .tmp = tmp,
            .data_dir = data_dir,
            .engine = engine,
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    pub fn deinit(self: *Harness) void {
        rls_types.setGlobalExprRLSEngine(null);
        self.engine.deinit();
        self.allocator.destroy(self.engine);
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
        tenancy.setStrictTenancy(false);
        tenancy.resetWarnState();
    }

    /// Register a tenant. This is the same `HierarchyManager` seam
    /// `CALL geode.tenant.create(<id>[, <parent>])` drives in production
    /// (`src/execution/tenant_dispatch.zig`).
    fn createTenant(self: *Harness, tenant_id: []const u8, parent: ?[]const u8) !void {
        try self.engine.hierarchy_manager.addTenant(tenant_id, parent);
    }

    fn ctxForTenant(self: *const Harness, tenant_id: ?[]const u8) execution.ExecutionContext {
        var c = self.ctx;
        c.tenant_id = tenant_id;
        return c;
    }

    /// Write one node through the REAL CRUD path under `tenant`'s context, so
    /// the node carries that tenant's tag exactly as a wire CREATE would
    /// (`graph_store.createNodeWithGraph` →
    /// `fle_integration.tenantPreferringActiveContext`).
    ///
    /// The per-thread FLE tenant is set for the duration of the write the same
    /// way the transports do on HELLO (`quic_connection_handler.zig:6042`,
    /// `grpc_server.zig:275`) — `tenantPreferringActiveContext` prefers the
    /// active ExecutionContext and falls back to that per-thread map, and the
    /// CREATE dispatch does not itself push a context. Setting BOTH mirrors the
    /// server exactly and makes the write tag independent of which of the two
    /// seams the create path happens to read.
    fn createNodeAs(self: *Harness, allocator: std.mem.Allocator, tenant: []const u8, who: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        const aa = arena.allocator();

        const src = try std.fmt.allocPrint(aa, "CREATE (:P {{who: '{s}'}})", .{who});
        var parsed = try geode.parseGql(src, aa);
        defer parsed.deinit();

        const prev_scratch = query_arena.pushScratchAllocator(aa);
        defer query_arena.popScratchAllocator(prev_scratch);

        geode.fle_integration.setCurrentTenantId(tenant);
        defer geode.fle_integration.setCurrentTenantId(null);

        const ctx = self.ctxForTenant(tenant);
        const prev_ctx = execution.pushActiveContext(&ctx);
        defer execution.popActiveContext(prev_ctx);

        var res = try execution.executeStatementWithContext(aa, parsed.program.statements[0], ctx);
        res.deinit(aa);

        // Prove the write really carried the tenant tag — otherwise every read
        // assertion below would pass vacuously against mis-tagged rows.
        const store = graph_store.getGlobalStore(allocator);
        var it = store.nodes.iterator();
        var tagged = false;
        while (it.next()) |entry| {
            const node = entry.value_ptr.*;
            if (node.properties.get("who")) |v| {
                switch (v) {
                    .String => |s| if (std.mem.eql(u8, s, who)) {
                        tagged = std.mem.eql(u8, node.tenant_id, tenant);
                    },
                    else => {},
                }
            }
        }
        if (!tagged) return error.WriteDidNotCarryTenantTag;
    }
};

fn parseQuery(arena: *std.heap.ArenaAllocator, src: []const u8) !*const geode.gql.ast.Query {
    var lx = geode.gql.lexer.Lexer{ .src = src };
    var p = geode.gql.parser.Parser{ .lx = &lx, .arena = arena, .cur = lx.next() };
    const program = try p.parseProgram();
    return &program.statements[0].Query;
}

/// What a read produced, copied out as scalars before the per-query arena is
/// torn down (the legacy executor's row interiors are arena-backed — the same
/// contract `test_gap0846_tenant_hierarchy_reads.zig` documents).
const Outcome = struct {
    row_count: usize,
    /// Distinct `who` values observed, sorted. Empty when the rows are not
    /// string-projected (`RETURN n` / `count(n)`).
    who: [][]const u8,
    /// First integer cell, for `count(n)`.
    first_int: ?i64,
    /// true when the engine-direct stream served the rows, false when it
    /// DECLINED and the executor did.
    via_stream: bool,
};

/// Mirrors the `.rows` dispatch both transports run
/// (`quic_connection_handler.zig` ~:7484, `grpc_server.zig` ~:2604): try
/// `node_scan_stream.prepare` FIRST and serve its page when it returns a
/// stream; otherwise fall through to the executor. Everything runs under the
/// session's `ExecutionContext`, exactly as the handlers do.
fn transportRows(
    h: *Harness,
    allocator: std.mem.Allocator,
    tenant: ?[]const u8,
    src: []const u8,
) !Outcome {
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    const aa = arena.allocator();

    const ctx = h.ctxForTenant(tenant);

    var qa = std.heap.ArenaAllocator.init(allocator);
    defer qa.deinit();
    const q = try parseQuery(&qa, src);

    var via_stream = false;
    var result: execution.ExecutionResult = blk: {
        if (try node_scan_stream.prepare(aa, q, ctx, &.{}, &.{}, &.{})) |prepared| {
            var stream = prepared;
            defer stream.deinit();
            via_stream = true;
            const page = try stream.buildNextPage(aa, 128);
            break :blk page.result;
        }

        var parsed = try geode.parseGql(src, aa);
        defer parsed.deinit();
        const prev_scratch = query_arena.pushScratchAllocator(aa);
        defer query_arena.popScratchAllocator(prev_scratch);
        break :blk try execution.executeStatementWithContext(aa, parsed.program.statements[0], ctx);
    };
    defer result.deinit(aa);

    var who = std.ArrayList([]const u8).empty;
    errdefer {
        for (who.items) |w| allocator.free(w);
        who.deinit(allocator);
    }
    for (result.rows) |row| {
        if (row.len == 0) continue;
        if (row[0] == .Str) try who.append(allocator, try allocator.dupe(u8, row[0].Str));
    }
    std.mem.sort([]const u8, who.items, {}, struct {
        fn lt(_: void, a: []const u8, b: []const u8) bool {
            return std.mem.lessThan(u8, a, b);
        }
    }.lt);

    const first_int: ?i64 = if (result.rows.len > 0 and result.rows[0].len > 0)
        switch (result.rows[0][0]) {
            .Int => |i| i,
            else => null,
        }
    else
        null;

    return .{
        .row_count = result.rows.len,
        .who = try who.toOwnedSlice(allocator),
        .first_int = first_int,
        .via_stream = via_stream,
    };
}

fn freeOutcome(allocator: std.mem.Allocator, o: *Outcome) void {
    for (o.who) |w| allocator.free(w);
    allocator.free(o.who);
}

/// Two registered tenants, one node each, SAME graph — the driver's setup.
fn seedTwoTenants(h: *Harness, allocator: std.mem.Allocator) !void {
    try h.createTenant(tenant_a, null);
    try h.createTenant(tenant_b, null);
    try h.createNodeAs(allocator, tenant_a, "a");
    try h.createNodeAs(allocator, tenant_b, "b");
}

// -------------------------------------------------------------------
// Test 1 — THE DEFECT: bare property projection, the exact shape the Go
// driver issued. Each tenant must see ONLY its own row.
// -------------------------------------------------------------------
test "SONNY-1229: MATCH (n:P) RETURN n.who is tenant-scoped on the engine-direct path" {
    const allocator = testing.allocator;
    var h = try Harness.init(allocator, true);
    defer h.deinit();
    try seedTwoTenants(&h, allocator);

    var a = try transportRows(&h, allocator, tenant_a, "MATCH (n:P) RETURN n.who");
    defer freeOutcome(allocator, &a);
    // The engine-direct stream cannot apply the tenant filter, so it MUST
    // decline to the executor rather than serve every tenant's rows.
    try testing.expect(!a.via_stream);
    try testing.expectEqual(@as(usize, 1), a.row_count);
    try testing.expectEqualStrings("a", a.who[0]);

    var b = try transportRows(&h, allocator, tenant_b, "MATCH (n:P) RETURN n.who");
    defer freeOutcome(allocator, &b);
    try testing.expect(!b.via_stream);
    try testing.expectEqual(@as(usize, 1), b.row_count);
    try testing.expectEqualStrings("b", b.who[0]);
}

// -------------------------------------------------------------------
// Test 2 — the unregistered tenant sees NOTHING. Pre-fix it read every
// row, which is what proved the filter was not consulted at all: an
// unregistered concrete tenant can satisfy neither the exact-match arm
// nor `canAccessTenantSafe`.
// -------------------------------------------------------------------
test "SONNY-1229: an unregistered tenant reads no rows" {
    const allocator = testing.allocator;
    var h = try Harness.init(allocator, true);
    defer h.deinit();
    try seedTwoTenants(&h, allocator);

    var ghost = try transportRows(&h, allocator, tenant_ghost, "MATCH (n:P) RETURN n.who");
    defer freeOutcome(allocator, &ghost);
    try testing.expect(!ghost.via_stream);
    try testing.expectEqual(@as(usize, 0), ghost.row_count);
}

// -------------------------------------------------------------------
// Test 3 — `RETURN n` (the `.node` projection mode) is tenant-scoped too.
// -------------------------------------------------------------------
test "SONNY-1229: MATCH (n:P) RETURN n is tenant-scoped on the engine-direct path" {
    const allocator = testing.allocator;
    var h = try Harness.init(allocator, true);
    defer h.deinit();
    try seedTwoTenants(&h, allocator);

    var a = try transportRows(&h, allocator, tenant_a, "MATCH (n:P) RETURN n");
    defer freeOutcome(allocator, &a);
    try testing.expect(!a.via_stream);
    try testing.expectEqual(@as(usize, 1), a.row_count);

    var b = try transportRows(&h, allocator, tenant_b, "MATCH (n:P) RETURN n");
    defer freeOutcome(allocator, &b);
    try testing.expect(!b.via_stream);
    try testing.expectEqual(@as(usize, 1), b.row_count);

    var ghost = try transportRows(&h, allocator, tenant_ghost, "MATCH (n:P) RETURN n");
    defer freeOutcome(allocator, &ghost);
    try testing.expect(!ghost.via_stream);
    try testing.expectEqual(@as(usize, 0), ghost.row_count);
}

// -------------------------------------------------------------------
// Test 4 — the `.count` arm. Pre-fix the stream answered the ALL-TENANT
// cardinality (2) for every session, including the unregistered one.
// -------------------------------------------------------------------
test "SONNY-1229: count(n) is tenant-scoped on the engine-direct path" {
    const allocator = testing.allocator;
    var h = try Harness.init(allocator, true);
    defer h.deinit();
    try seedTwoTenants(&h, allocator);

    var a = try transportRows(&h, allocator, tenant_a, "MATCH (n:P) RETURN count(n) AS c");
    defer freeOutcome(allocator, &a);
    try testing.expect(!a.via_stream);
    try testing.expectEqual(@as(i64, 1), a.first_int.?);

    var b = try transportRows(&h, allocator, tenant_b, "MATCH (n:P) RETURN count(n) AS c");
    defer freeOutcome(allocator, &b);
    try testing.expect(!b.via_stream);
    try testing.expectEqual(@as(i64, 1), b.first_int.?);

    var ghost = try transportRows(&h, allocator, tenant_ghost, "MATCH (n:P) RETURN count(n) AS c");
    defer freeOutcome(allocator, &ghost);
    try testing.expect(!ghost.via_stream);
    try testing.expectEqual(@as(i64, 0), ghost.first_int.?);
}

// -------------------------------------------------------------------
// Test 5 — `isEligible` MUST agree with `prepare`. The transports use it
// to decide whether to skip the O(graph) snapshot clone AND (in
// `readWillStreamEngineSide`) whether the stream will serve the read; if
// it said "yes" for a tenant-scoped session while `prepare` declines, the
// two halves of the decision would diverge again.
// -------------------------------------------------------------------
test "SONNY-1229: isEligible declines every shape for a concrete tenant scope" {
    const allocator = testing.allocator;
    var h = try Harness.init(allocator, true);
    defer h.deinit();
    try seedTwoTenants(&h, allocator);

    var qa = std.heap.ArenaAllocator.init(allocator);
    defer qa.deinit();

    const shapes = [_][]const u8{
        "MATCH (n:P) RETURN n.who",
        "MATCH (n:P) RETURN n",
        "MATCH (n:P) RETURN count(n)",
        "MATCH (n:P {who: 'a'}) RETURN n.who",
        "MATCH (n:P) WHERE n.who = 'a' RETURN n.who",
    };
    for (shapes) |src| {
        const q = try parseQuery(&qa, src);
        try testing.expect(!node_scan_stream.isEligible(q, tenant_a));
        try testing.expect(!node_scan_stream.isEligible(q, tenant_ghost));

        // ... and `prepare` agrees (the other half of the shared predicate).
        var arena = std.heap.ArenaAllocator.init(allocator);
        defer arena.deinit();
        try testing.expect((try node_scan_stream.prepare(arena.allocator(), q, h.ctxForTenant(tenant_a), &.{}, &.{}, &.{})) == null);
    }
}

// -------------------------------------------------------------------
// Test 6 — strict tenancy with NO concrete scope must still be refused by
// the executor (GQLSTATE 42501 / `error.TenantScopeRequired`), NOT served
// a full row set by the fast path. This is the refusal the driver already
// observes; the fix must not route around it.
// -------------------------------------------------------------------
test "SONNY-1229: an unscoped session under strict tenancy is refused, not served" {
    const allocator = testing.allocator;
    var h = try Harness.init(allocator, true);
    defer h.deinit();
    try seedTwoTenants(&h, allocator);

    var qa = std.heap.ArenaAllocator.init(allocator);
    defer qa.deinit();
    const q = try parseQuery(&qa, "MATCH (n:P) RETURN n.who");

    // The fast path must not claim this read...
    try testing.expect(!node_scan_stream.isEligible(q, null));
    var arena = std.heap.ArenaAllocator.init(allocator);
    defer arena.deinit();
    try testing.expect((try node_scan_stream.prepare(arena.allocator(), q, h.ctxForTenant(null), &.{}, &.{}, &.{})) == null);

    // ... and the executor refuses it.
    try testing.expectError(error.TenantScopeRequired, transportRows(&h, allocator, null, "MATCH (n:P) RETURN n.who"));
}

// -------------------------------------------------------------------
// Test 7 — the fast path STILL ENGAGES with NO tenant scope and strict
// tenancy OFF (the single-tenant deployment that is the whole point of
// the optimization). Without this, "always decline" would pass tests 1-6
// while silently deleting the engine-direct read path.
//
// Observable proof that the stream (not the executor) produced the rows:
// `via_stream`, plus the path's own `getNodesMaterializedTotal` counter —
// the lazy per-page `materializeNode` the executor never calls.
// -------------------------------------------------------------------
test "SONNY-1229: unscoped + non-strict keeps the engine-direct fast path" {
    const allocator = testing.allocator;
    var h = try Harness.init(allocator, false);
    defer h.deinit();
    // No tenants registered, no tenant scope: the legacy single-tenant shape.
    try h.createNodeAs(allocator, graph_store.DEFAULT_TENANT_ID, "a");
    try h.createNodeAs(allocator, graph_store.DEFAULT_TENANT_ID, "b");

    var qa = std.heap.ArenaAllocator.init(allocator);
    defer qa.deinit();
    try testing.expect(node_scan_stream.isEligible(try parseQuery(&qa, "MATCH (n:P) RETURN n.who"), null));

    node_scan_stream.resetNodesMaterializedTotal();
    var out = try transportRows(&h, allocator, null, "MATCH (n:P) RETURN n.who");
    defer freeOutcome(allocator, &out);

    try testing.expect(out.via_stream);
    try testing.expect(node_scan_stream.getNodesMaterializedTotal() > 0);
    try testing.expectEqual(@as(usize, 2), out.row_count);
    try testing.expectEqualStrings("a", out.who[0]);
    try testing.expectEqualStrings("b", out.who[1]);
}
