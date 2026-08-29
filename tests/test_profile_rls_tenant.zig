// CANARY: REQ=REQ-PROFILE-RLS-TENANT-001; FEATURE="PROFILE"; ASPECT=TenantScopedProfile; STATUS=TESTED; TEST=tests/test_profile_rls_tenant.zig; OWNER=security; UPDATED=2026-08-29
//
// `planned_read_runtime.executeProfiledIfSupported` is the single choke point
// for `PROFILE <Query>` on QUIC/gRPC/CLI. It never pushed the thread-local
// active `ExecutionContext` that `passesRLSFilter`/`passesRLSExprFilter` AND
// `getSessionTenantFilter` (src/execution/match_operations.zig) read — so
// under PROFILE, RLS and tenant isolation both failed open (a null active
// context means "allow all tenants"). Normal execution pushes it in
// `executeQueryWithContext` (src/execution/query_execution.zig); PROFILE of a
// Query shape bypassed that entirely by calling
// `planned_read_runtime.executeProfiledIfSupported` directly.
//
// These tests drive the real store + real parser + real executor (no mocks),
// mirroring tests/test_fts_authorization.zig for the store/context bootstrap
// pattern and tests/test_rls_expr_engine_wiring.zig for the RLS label-deny
// engine wiring pattern.
//
// PROFILE never surfaces the underlying data rows themselves — both PROFILE
// result shapes (the storage-native `planned_query_profile` and the fallback
// `query_profile`; see src/execution/statement_handlers.zig
// buildPlannedProfileResult / executeProfile) are 2-column metric/value
// tables that report the wrapped query's ROW COUNT as the `rows` metric (an
// `.Int`). That is exactly the observable a fail-open tenant/RLS filter would
// corrupt (an over-count leaking other tenants'/denied rows), so these tests
// read the `rows` metric the same way tests/test_gap0868_profile_timing.zig
// does, and cross-check it against the row count a plain (non-PROFILE)
// MATCH returns through the same context.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const rls_types = @import("rls_types");

const execution = geode.execution;
const graph_store = geode.graph_store;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

/// Harness mirrors tests/test_fts_authorization.zig.
const Harness = struct {
    allocator: std.mem.Allocator,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
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
            .ctx = execution.ExecutionContext{ .catalog = catalog },
        };
    }

    pub fn deinit(self: *Harness) void {
        self.arena.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    pub fn runQuery(self: *Harness, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }
};

/// Find the integer value of a `metric`/`value` row whose metric name equals
/// `name` (mirrors tests/test_gap0868_profile_timing.zig's findMetricInt).
/// Both PROFILE result shapes (planned_query_profile and the query_profile
/// fallback) report a `rows` metric carrying the wrapped query's actual row
/// count.
fn findMetricInt(result: execution.ExecutionResult, name: []const u8) ?i64 {
    for (result.rows) |row| {
        if (row.len < 2) continue;
        const metric = switch (row[0]) {
            .Str => |s| s,
            else => continue,
        };
        if (!std.mem.eql(u8, metric, name)) continue;
        return switch (row[1]) {
            .Int => |v| v,
            else => null,
        };
    }
    return null;
}

fn profileRowCount(result: execution.ExecutionResult) !i64 {
    return findMetricInt(result, "rows") orelse error.MissingRowsMetric;
}

// CANARY: REQ=REQ-PROFILE-RLS-TENANT-001; FEATURE="PROFILE"; ASPECT=TenantScopedProfile; STATUS=TESTED; TEST=tests/test_profile_rls_tenant.zig; OWNER=security; UPDATED=2026-08-29
test "PROFILE respects tenant scope like plain MATCH" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aa = h.arena.allocator();

    {
        h.ctx.tenant_id = "tenant_a";
        const prev = execution.pushActiveContext(&h.ctx);
        defer execution.popActiveContext(prev);
        var r = try h.runQuery("CREATE (:ProfDoc {body: 'x'})");
        r.deinit(aa);
    }
    {
        h.ctx.tenant_id = "tenant_b";
        const prev = execution.pushActiveContext(&h.ctx);
        defer execution.popActiveContext(prev);
        var r = try h.runQuery("CREATE (:ProfDoc {body: 'x'})");
        r.deinit(aa);
    }

    h.ctx.tenant_id = "tenant_a";

    // Control: plain MATCH scoped to tenant_a through executeStatementWithContext
    // returns exactly 1 row (tenant_a's node only). Do NOT push the context
    // manually — executeStatementWithContext installs it itself.
    {
        var res = try h.runQuery("MATCH (n:ProfDoc) RETURN id(n)");
        defer res.deinit(aa);
        try testing.expectEqual(@as(usize, 1), res.rows.len);
    }

    // PROFILE MATCH scoped to tenant_a must ALSO report exactly 1 row (the
    // `rows` metric reflects the wrapped query's actual row count). Pre-fix,
    // the PROFILE execution path never pushes the active context that
    // tenant/RLS filtering reads, so this leaks tenant_b's row too (rows=2).
    {
        var res = try h.runQuery("PROFILE MATCH (n:ProfDoc) RETURN id(n)");
        defer res.deinit(aa);
        try testing.expectEqual(@as(i64, 1), try profileRowCount(res));
    }
}

// CANARY: REQ=REQ-PROFILE-RLS-TENANT-001; FEATURE="PROFILE"; ASPECT=TenantScopedProfile; STATUS=TESTED; TEST=tests/test_profile_rls_tenant.zig; OWNER=security; UPDATED=2026-08-29
test "PROFILE respects RLS label deny like plain MATCH" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aa = h.arena.allocator();

    {
        var r = try h.runQuery("CREATE (:ProfDoc {body: 'x'})");
        r.deinit(aa);
    }

    // Install the label-deny RLS engine for :ProfDoc for user "bob", exactly
    // as tests/test_rls_expr_engine_wiring.zig / test_fts_authorization.zig do.
    var label_engine = rls_types.RLSFilterEngine.init(testing.allocator);
    defer label_engine.deinit();
    try label_engine.addDenyPolicy(graph_store.DEFAULT_GRAPH_NAME, "ProfDoc", "bob");
    rls_types.setGlobalRLSFilterEngine(&label_engine);
    defer rls_types.setGlobalRLSFilterEngine(null);

    h.ctx.user = "bob";
    const prev = execution.pushActiveContext(&h.ctx);
    defer execution.popActiveContext(prev);

    {
        var res = try h.runQuery("PROFILE MATCH (n:ProfDoc) RETURN id(n)");
        defer res.deinit(aa);
        try testing.expectEqual(@as(i64, 0), try profileRowCount(res));
    }

    // Clear the engine — the previously-denied row must now return.
    rls_types.setGlobalRLSFilterEngine(null);
    {
        var res = try h.runQuery("PROFILE MATCH (n:ProfDoc) RETURN id(n)");
        defer res.deinit(aa);
        try testing.expectEqual(@as(i64, 1), try profileRowCount(res));
    }
}

// CANARY: REQ=REQ-PROFILE-RLS-TENANT-001; FEATURE="PROFILE"; ASPECT=TenantScopedProfile; STATUS=TESTED; TEST=tests/test_profile_rls_tenant.zig; OWNER=security; UPDATED=2026-08-29
test "PROFILE with null tenant still returns all rows (admin scope)" {
    var h = try Harness.init(testing.allocator);
    defer h.deinit();
    const aa = h.arena.allocator();

    {
        h.ctx.tenant_id = "tenant_a";
        const prev = execution.pushActiveContext(&h.ctx);
        defer execution.popActiveContext(prev);
        var r = try h.runQuery("CREATE (:ProfDoc {body: 'x'})");
        r.deinit(aa);
    }
    {
        h.ctx.tenant_id = "tenant_b";
        const prev = execution.pushActiveContext(&h.ctx);
        defer execution.popActiveContext(prev);
        var r = try h.runQuery("CREATE (:ProfDoc {body: 'x'})");
        r.deinit(aa);
    }

    // No tenant scope (admin / all-tenants): both nodes must be counted.
    h.ctx.tenant_id = null;
    {
        var res = try h.runQuery("PROFILE MATCH (n:ProfDoc) RETURN id(n)");
        defer res.deinit(aa);
        try testing.expectEqual(@as(i64, 2), try profileRowCount(res));
    }
}
