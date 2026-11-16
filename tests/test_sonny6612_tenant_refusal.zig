// SONNY-6612 (2): once tenants are administered (the durable registry
// holds a tenant), a session scoped to a tenant the registry does not know
// is refused (fail closed); it read and wrote under any tenant id a client
// asserted. The refusal is checked at statement entry, and by the QUIC
// handler before its fast paths (bulk MERGE, the count fast paths), which
// bypass the executor.
//
// A durable tenant registry, a real RLS engine and the real executor in
// process.
//
// CANARY: REQ=REQ-SONNY-6612-TENANT-REFUSAL; FEATURE="TenantLifecycle"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6612_tenant_refusal.zig; OWNER=security; UPDATED=2026-11-15

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
        try self.run(null, "CALL geode.tenant.create('acme12')");
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

test "SONNY-6612 (2): with tenants registered, a statement of an unregistered tenant is refused and writes nothing" {
    quiet();
    user_mgmt.setAuthEnabled(false);
    defer user_mgmt.setAuthEnabled(true);
    var w: World = undefined;
    try w.init();
    defer w.deinit();
    // A registered tenant runs.
    try w.run("acme12", "CREATE (:R6612 {k: 1})");
    const before = try w.store.getAllNodes(testing.allocator);
    defer testing.allocator.free(before);
    try testing.expectError(error.TenantNotRegistered, w.run("ghost12", "MATCH (n:R6612) RETURN count(n)"));
    try testing.expectError(error.TenantNotRegistered, w.run("ghost12", "CREATE (:R6612 {k: 2})"));
    const after = try w.store.getAllNodes(testing.allocator);
    defer testing.allocator.free(after);
    try testing.expectEqual(before.len, after.len);
    // An unscoped (admin) session is not a tenant session.
    try w.run(null, "MATCH (n:R6612) RETURN count(n)");
}
