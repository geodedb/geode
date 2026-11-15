// SONNY-6607 (4): a tenant create whose hierarchy add fails is undone; a
// session of a tenant being dropped is refused.
//
// `geode.tenant.create` wrote the durable registry, then added the tenant to
// the RLS tenant hierarchy and only logged a failure of that add: the create
// reported success with a tenant the hierarchy did not know (its parent did
// not see its rows; a cascade drop of the parent missed it). A tenant DROP
// that fails part-way leaves the tenant registered and marked as being
// dropped (SONNY-6567 (4)), but a session scoped to that tenant went on
// reading and writing it.
//
// A durable tenant registry, a real RLS engine (its hierarchy) on an
// allocator made to fail from each allocation on, and the real executor in
// process. Each create either succeeds with the tenant in both the registry
// and the hierarchy, or fails with it in neither. A statement whose session
// tenant is being dropped fails with `TenantDropping` and writes nothing.
//
// CANARY: REQ=REQ-SONNY-6607-TENANT-LIFECYCLE; FEATURE="TenantLifecycle"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6607_tenant_lifecycle.zig; OWNER=security; UPDATED=2026-11-15

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

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

const World = struct {
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    reg: *TenantRegistry,
    engine_failing: std.testing.FailingAllocator,
    engine: *rls.RLSEngine,
    store: *graph_store.GraphStore,
    catalog: @typeInfo(@typeInfo(@TypeOf(execution.ensureCatalogInstance)).@"fn".return_type.?).error_union.payload,

    fn init(self: *World) !void {
        self.tmp = std.testing.tmpDir(.{});
        self.data_dir = try tmpDirRealpathAlloc(testing.allocator, &self.tmp.sub_path);
        self.reg = try testing.allocator.create(TenantRegistry);
        self.reg.* = try TenantRegistry.initWithDataDir(testing.allocator, self.data_dir);
        tenant_registry.setGlobalRegistry(self.reg);
        self.engine_failing = std.testing.FailingAllocator.init(testing.allocator, .{});
        self.engine = try testing.allocator.create(rls.RLSEngine);
        self.engine.* = try rls.RLSEngine.init(self.engine_failing.allocator());
        rls_types.setGlobalExprRLSEngine(@ptrCast(self.engine));
        self.catalog = try execution.ensureCatalogInstance(testing.allocator);
        self.store = graph_store.getGlobalStore(testing.allocator);
        try self.run(null, "CALL geode.tenant.create('acme7')");
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

    fn run(self: *World, tenant: ?[]const u8, query: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena.deinit();
        var parsed = try geode.parseGql(query, arena.allocator());
        defer parsed.deinit();
        var ctx = execution.ExecutionContext{ .catalog = self.catalog };
        ctx.role = null;
        ctx.user = null;
        ctx.tenant_id = tenant;
        var r = try execution.executeStatementWithContext(arena.allocator(), parsed.program.statements[0], ctx);
        r.deinit(arena.allocator());
    }
};

fn quiet() void {
    logging.init(.{ .level = .fatal });
    logging.setLevel(.fatal);
}

test "SONNY-6607 (4): a tenant create whose hierarchy add fails is undone, never registered without the hierarchy" {
    quiet();
    user_mgmt.setAuthEnabled(false);
    defer user_mgmt.setAuthEnabled(true);
    var broken: usize = 0;
    var runs: usize = 0;
    var failed: usize = 0;
    var k: usize = 0;
    while (k < MAX_SWEEP) : (k += 1) {
        var w: World = undefined;
        try w.init();
        defer w.deinit();
        const fa = &w.engine_failing;
        fa.has_induced_failure = false;
        fa.fail_index = fa.alloc_index + k;
        const outcome = w.run(null, "CALL geode.tenant.create('acme7-bu', 'acme7')");
        fa.fail_index = std.math.maxInt(usize);
        const induced = fa.has_induced_failure;
        runs += 1;
        const in_reg = w.reg.contains("acme7-bu");
        const in_hier = w.engine.hierarchy_manager.contains("acme7-bu");
        if (outcome) |_| {
            if (!in_reg or !in_hier) {
                broken += 1;
                std.debug.print("SONNY-6607 (4) hierarchy allocation {d} failing: create succeeded, registry {}, hierarchy {}\n", .{ k, in_reg, in_hier });
            }
        } else |err| {
            failed += 1;
            if (in_reg or in_hier) {
                broken += 1;
                std.debug.print("SONNY-6607 (4) hierarchy allocation {d} failing: create failed ({s}), registry {}, hierarchy {}\n", .{ k, @errorName(err), in_reg, in_hier });
            }
        }
        if (!induced) break;
    }
    std.debug.print("SONNY-6607 (4) create: {d} runs, {d} failed, {d} broken\n", .{ runs, failed, broken });
    try testing.expectEqual(@as(usize, 0), broken);
}

test "SONNY-6607 (4): a statement whose session tenant is being dropped is refused and writes nothing" {
    quiet();
    user_mgmt.setAuthEnabled(false);
    defer user_mgmt.setAuthEnabled(true);
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    try w.run("acme7", "CREATE (:L6607 {k: 1})");
    try w.reg.markDropping("acme7");
    const before = try w.store.getAllNodes(testing.allocator);
    defer testing.allocator.free(before);
    try testing.expectError(error.TenantDropping, w.run("acme7", "MATCH (n:L6607) RETURN count(n)"));
    try testing.expectError(error.TenantDropping, w.run("acme7", "CREATE (:L6607 {k: 2})"));
    const after = try w.store.getAllNodes(testing.allocator);
    defer testing.allocator.free(after);
    try testing.expectEqual(before.len, after.len);
    // Another tenant is unaffected.
    try w.run("other7", "CREATE (:L6607 {k: 3})");
}
