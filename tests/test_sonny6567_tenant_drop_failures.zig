// SONNY-6567 (4): a tenant DROP that fails part-way says so, and leaves a
// state that is consistent in memory and on disk and can be dropped again.
//
// `geode.tenant.drop(t, true)` drops `t`'s child tenants bottom-up, deletes
// its rows, removes it from the tenant hierarchy, then removes its registry
// record. Failures were swallowed: the registry's own write of the file
// (`TenantRegistry.drop` / `create` / `setQuota` logged a failed persist and
// returned success), the hierarchy removal (`removeTenant` logged, or
// `catch {}` for a child) and the registry lookup for a child
// (`resolveRegistry() catch null`). A tenant could be reported dropped while
// its registry row stayed on disk (it came back at the next restart, its rows
// gone) or while the hierarchy kept it.
//
// The order is now: mark the tenant as being dropped (`active = false`,
// written to disk; no child tenant can be created under it), drop each child
// the same way, delete the tenant's rows, remove it from the hierarchy,
// remove its registry record (written to disk, or the record is restored and
// the drop fails). A failure at any step fails the drop; the tenant stays
// registered, marked, and a retry finishes it, also after a restart.
//
// The registry is durable (a data directory), the executor, parser, store and
// RLS hierarchy are real. The drop runs with the registry's allocations, and
// separately the statement's, failing from the k-th one on, for every k up to
// the first run that needs none. After each run, and after a "restart" (the
// registry reopened from its file and the hierarchy rebuilt from it as the
// server does), the in-memory and on-disk registries must agree; a failed
// drop must leave the tenant registered and, once anything of it was
// removed, marked; a retry must finish it; a dropped tenant has no rows.
//
// CANARY: REQ=REQ-SONNY-6567-TENANT-DROP-FAILURES; FEATURE="TenantLifecycle"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6567_tenant_drop_failures.zig; OWNER=security; UPDATED=2026-11-14

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const logging = @import("logging");
const rls = @import("rls");
const rls_types = @import("rls_types");

const execution = geode.execution;
const graph_store = geode.graph_store;
const tenant_registry = geode.tenant_registry;
const user_mgmt = geode.user_management;
const TenantRegistry = tenant_registry.TenantRegistry;

const MAX_SWEEP: usize = 2_000;
const TENANTS = [_][]const u8{ "acme", "acme-bu1", "acme-bu2" };

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const Which = enum { registry, statement };

/// One drop attempt's world: a fresh durable registry, store and hierarchy.
const World = struct {
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    reg_failing: std.testing.FailingAllocator,
    reg: *TenantRegistry,
    engine: *rls.RLSEngine,
    store: *graph_store.GraphStore,
    catalog: @typeInfo(@typeInfo(@TypeOf(execution.ensureCatalogInstance)).@"fn".return_type.?).error_union.payload,

    fn init(self: *World) !void {
        self.tmp = std.testing.tmpDir(.{});
        self.data_dir = try tmpDirRealpathAlloc(testing.allocator, &self.tmp.sub_path);
        self.reg_failing = std.testing.FailingAllocator.init(testing.allocator, .{});
        self.reg = try testing.allocator.create(TenantRegistry);
        self.reg.* = try TenantRegistry.initWithDataDir(self.reg_failing.allocator(), self.data_dir);
        tenant_registry.setGlobalRegistry(self.reg);
        self.engine = try testing.allocator.create(rls.RLSEngine);
        self.engine.* = try rls.RLSEngine.init(testing.allocator);
        rls_types.setGlobalExprRLSEngine(@ptrCast(self.engine));
        self.catalog = try execution.ensureCatalogInstance(testing.allocator);
        self.store = graph_store.getGlobalStore(testing.allocator);

        try self.ok(testing.allocator, "CALL geode.tenant.create('acme')");
        try self.ok(testing.allocator, "CALL geode.tenant.create('acme-bu1', 'acme')");
        try self.ok(testing.allocator, "CALL geode.tenant.create('acme-bu2', 'acme')");
        for (TENANTS) |t| try seed(self.store, t, 3);
    }

    fn deinit(self: *World) void {
        rls_types.setGlobalExprRLSEngine(null);
        self.engine.deinit();
        testing.allocator.destroy(self.engine);
        tenant_registry.setGlobalRegistry(null);
        self.reg.deinit();
        testing.allocator.destroy(self.reg);
        graph_store.deinitGlobalStore();
        execution.cleanupCatalogInstance();
        testing.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    fn run(self: *World, allocator: std.mem.Allocator, query: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var parsed = try geode.parseGql(query, arena.allocator());
        defer parsed.deinit();
        var ctx = execution.ExecutionContext{ .catalog = self.catalog };
        ctx.role = null;
        ctx.user = null;
        var r = try execution.executeStatementWithContext(allocator, parsed.program.statements[0], ctx);
        r.deinit(allocator);
    }

    fn ok(self: *World, allocator: std.mem.Allocator, query: []const u8) !void {
        self.run(allocator, query) catch |err| {
            std.debug.print("SONNY-6567 (4) '{s}' failed: {s}\n", .{ query, @errorName(err) });
            return err;
        };
    }

    /// The server's restart: the registry reopened from its file, the
    /// hierarchy rebuilt from its records, parents first (`main.zig`
    /// `rehydrateTenantDerivedState`).
    fn restart(self: *World) !void {
        tenant_registry.setGlobalRegistry(null);
        self.reg.deinit();
        self.reg_failing = std.testing.FailingAllocator.init(testing.allocator, .{});
        self.reg.* = try TenantRegistry.initWithDataDir(self.reg_failing.allocator(), self.data_dir);
        tenant_registry.setGlobalRegistry(self.reg);
        rls_types.setGlobalExprRLSEngine(null);
        self.engine.deinit();
        self.engine.* = try rls.RLSEngine.init(testing.allocator);
        rls_types.setGlobalExprRLSEngine(@ptrCast(self.engine));
        const recs = try self.reg.list(testing.allocator);
        defer TenantRegistry.freeRecordSlice(testing.allocator, recs);
        var added: usize = 0;
        while (added < recs.len) {
            const before = added;
            for (recs) |rec| {
                if (self.engine.hierarchy_manager.contains(rec.tenant_id)) continue;
                if (rec.parent) |p| if (!self.engine.hierarchy_manager.contains(p)) continue;
                try self.engine.hierarchy_manager.addTenant(rec.tenant_id, rec.parent);
                added += 1;
            }
            if (added == before) return error.OrphanTenant;
        }
    }

    fn rows(self: *World, tenant: []const u8) !usize {
        const n = try self.store.getAllNodesForTenant(testing.allocator, tenant);
        defer testing.allocator.free(n);
        const e = try self.store.getAllEdgesForTenant(testing.allocator, tenant);
        defer testing.allocator.free(e);
        return n.len + e.len;
    }
};

fn seed(store: *graph_store.GraphStore, tid: []const u8, count: usize) !void {
    const labels = [_][]const u8{"W6567"};
    var prev: ?u64 = null;
    for (0..count) |_| {
        const nid = try store.createNodeWithGraphAndTenant(&labels, graph_store.DEFAULT_GRAPH_NAME, tid);
        if (prev) |p| _ = try store.createEdgeWithGraphAndTenant(p, nid, "L6567", graph_store.DEFAULT_GRAPH_NAME, tid);
        prev = nid;
    }
}

/// What the registry file says about `tenant`: null when absent, else its
/// `active` flag.
fn onDisk(data_dir: []const u8, tenant: []const u8) !?bool {
    var reg = try TenantRegistry.initWithDataDir(testing.allocator, data_dir);
    defer reg.deinit();
    const rec = reg.get(testing.allocator, tenant) catch |err| switch (err) {
        error.TenantNotFound => return null,
        else => return err,
    };
    defer {
        testing.allocator.free(rec.tenant_id);
        if (rec.parent) |p| testing.allocator.free(p);
    }
    return rec.active;
}

fn inMemory(reg: *TenantRegistry, tenant: []const u8) !?bool {
    const rec = reg.get(testing.allocator, tenant) catch |err| switch (err) {
        error.TenantNotFound => return null,
        else => return err,
    };
    defer {
        testing.allocator.free(rec.tenant_id);
        if (rec.parent) |p| testing.allocator.free(p);
    }
    return rec.active;
}

/// The invariants after a drop attempt; returns how many it broke.
fn check(w: *World, k: usize, which: Which, dropped: bool) !usize {
    var broken: usize = 0;
    var any_removed = false;
    for (TENANTS) |t| {
        const mem = try inMemory(w.reg, t);
        const disk = try onDisk(w.data_dir, t);
        if (!std.meta.eql(mem, disk)) {
            broken += 1;
            std.debug.print("SONNY-6567 (4) {t} allocation {d}: '{s}' in memory {?} but on disk {?}\n", .{ which, k, t, mem, disk });
        }
        if (mem == null) {
            if (try w.rows(t) != 0) {
                broken += 1;
                std.debug.print("SONNY-6567 (4) {t} allocation {d}: '{s}' is dropped but has rows\n", .{ which, k, t });
            }
            if (w.engine.hierarchy_manager.contains(t)) {
                broken += 1;
                std.debug.print("SONNY-6567 (4) {t} allocation {d}: '{s}' is dropped but still in the hierarchy\n", .{ which, k, t });
            }
        }
        if (mem == null or try w.rows(t) < 5) any_removed = true;
    }
    const acme = try inMemory(w.reg, "acme");
    if (dropped and acme != null) {
        broken += 1;
        std.debug.print("SONNY-6567 (4) {t} allocation {d}: the drop succeeded and 'acme' is still registered\n", .{ which, k });
    }
    if (!dropped) {
        if (acme == null) {
            broken += 1;
            std.debug.print("SONNY-6567 (4) {t} allocation {d}: the drop failed and 'acme' is gone\n", .{ which, k });
        } else if (any_removed and acme.? != false) {
            broken += 1;
            std.debug.print("SONNY-6567 (4) {t} allocation {d}: the drop failed part-way and 'acme' is not marked as being dropped\n", .{ which, k });
        }
    }
    return broken;
}

fn sweep(which: Which) !usize {
    var stmt_failing = std.testing.FailingAllocator.init(testing.allocator, .{});
    var broken: usize = 0;
    var failed: usize = 0;
    var runs: usize = 0;
    var k: usize = 0;
    while (k < MAX_SWEEP) : (k += 1) {
        var w: World = undefined;
        try w.init();
        defer w.deinit();
        const fa: *std.testing.FailingAllocator = switch (which) {
            .registry => &w.reg_failing,
            .statement => &stmt_failing,
        };
        fa.has_induced_failure = false;
        fa.fail_index = fa.alloc_index + k;
        const outcome = w.run(stmt_failing.allocator(), "CALL geode.tenant.drop('acme', true)");
        fa.fail_index = std.math.maxInt(usize);
        const induced = fa.has_induced_failure;
        runs += 1;
        const dropped = if (outcome) |_| true else |_| false;
        if (!dropped) failed += 1;
        broken += try check(&w, k, which, dropped);

        // A restart, then (after a failure) the drop again, then a restart.
        try w.restart();
        broken += try check(&w, k, which, dropped);
        if (!dropped) {
            try w.ok(testing.allocator, "CALL geode.tenant.drop('acme', true)");
            try w.restart();
            broken += try check(&w, k, which, true);
        }
        if (!induced) break;
    }
    std.debug.print("SONNY-6567 (4) {t} allocations failing: {d} runs, {d} drops failed, {d} broken invariants\n", .{ which, runs, failed, broken });
    return broken;
}

test "SONNY-6567 (4): a tenant drop whose registry write fails fails, consistently, and can be retried after a restart" {
    logging.init(.{ .level = .fatal });
    logging.setLevel(.fatal);
    user_mgmt.setAuthEnabled(false);
    defer user_mgmt.setAuthEnabled(true);
    try testing.expectEqual(@as(usize, 0), try sweep(.registry));
}

test "SONNY-6567 (4): a tenant drop whose statement allocations fail fails, consistently, and can be retried after a restart" {
    logging.init(.{ .level = .fatal });
    logging.setLevel(.fatal);
    user_mgmt.setAuthEnabled(false);
    defer user_mgmt.setAuthEnabled(true);
    try testing.expectEqual(@as(usize, 0), try sweep(.statement));
}
