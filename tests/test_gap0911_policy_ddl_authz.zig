// CANARY: REQ=REQ-GAP-0911-POLICY-DDL-AUTHZ; FEATURE="GPS Policy DDL"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_gap0911_policy_ddl_authz.zig:1; OWNER=security; UPDATED=2026-07-10
//
// Regression tests for GAP-0911: "non-admin can CREATE POLICY (authorization
// bypass)".
//
// Root cause: the .CreatePolicy / .DropPolicy / .AlterPolicy dispatch arms in
// src/execution.zig called the policy catalog with only a cluster-replication
// gate — no authorization check at all — so a zero-grant readonly user could
// inject, drop, or alter GPS policies (a privilege-escalation vector).
//
// Expected behavior after the fix: policy DDL is admin-only under the same
// RBAC bar as the mutating geode.auth.* procedures — non-admin denied with
// error.Unauthorized (SQLSTATE 42501), unauthenticated denied with
// error.Unauthenticated, admin succeeds, and the auth-disabled single-tenant
// default is unchanged.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const policy_catalog_mod = geode.security.policy_catalog;
const user_mgmt = geode.user_management;
const graph_store = geode.graph_store;

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

// Serialise tests: global PolicyCatalog singleton + auth-enabled flag.
var test_mutex: std.Io.Mutex = .init;

const Harness = struct {
    allocator: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    ctx: execution.ExecutionContext,

    pub fn init(allocator: std.mem.Allocator, cat: *policy_catalog_mod.PolicyCatalog) !Harness {
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();

        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();

        const data_dir = try tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);

        graph_store.setDataDirOverride(allocator, data_dir);
        _ = graph_store.getGlobalStore(allocator);

        const exec_catalog = try execution.ensureCatalogInstance(allocator);
        policy_catalog_mod.setGlobalCatalog(cat);

        return .{
            .allocator = allocator,
            .tmp = tmp,
            .data_dir = data_dir,
            .ctx = execution.ExecutionContext{ .catalog = exec_catalog },
        };
    }

    pub fn deinit(self: *Harness) void {
        policy_catalog_mod.setGlobalCatalog(undefined);
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(self.allocator, null);
        self.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    pub fn exec(self: *Harness, query: []const u8) !execution.ExecutionResult {
        var parsed = try geode.parseGql(query, self.allocator);
        defer parsed.deinit();
        return execution.executeStatementWithContext(self.allocator, parsed.program.statements[0], self.ctx);
    }
};

test "GAP-0911: readonly user is denied CREATE/DROP/ALTER POLICY" {
    test_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    const allocator = testing.allocator;
    var cat = policy_catalog_mod.PolicyCatalog.init(allocator);
    defer cat.deinit();

    var h = try Harness.init(allocator, &cat);
    defer h.deinit();

    user_mgmt.setAuthEnabled(true);
    defer user_mgmt.setAuthEnabled(false);

    h.ctx.role = .ReadOnly;
    h.ctx.user = "intruder";

    try testing.expectError(error.Unauthorized, h.exec("CREATE POLICY p_evil ON GRAPH * FOR READ;"));
    try testing.expectEqual(@as(usize, 0), cat.listPolicies().len);

    try testing.expectError(error.Unauthorized, h.exec("DROP POLICY nosuch;"));
    try testing.expectError(error.Unauthorized, h.exec("ALTER POLICY nosuch SET ENABLED false;"));
}

test "GAP-0911: non-admin write roles are denied too" {
    test_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    const allocator = testing.allocator;
    var cat = policy_catalog_mod.PolicyCatalog.init(allocator);
    defer cat.deinit();

    var h = try Harness.init(allocator, &cat);
    defer h.deinit();

    user_mgmt.setAuthEnabled(true);
    defer user_mgmt.setAuthEnabled(false);

    h.ctx.role = .ReadWrite;
    h.ctx.user = "writer";
    try testing.expectError(error.Unauthorized, h.exec("CREATE POLICY p_rw ON GRAPH * FOR READ;"));

    h.ctx.role = .User;
    h.ctx.user = "plain";
    try testing.expectError(error.Unauthorized, h.exec("CREATE POLICY p_user ON GRAPH * FOR READ;"));

    try testing.expectEqual(@as(usize, 0), cat.listPolicies().len);
}

test "GAP-0911: unauthenticated caller is rejected with Unauthenticated" {
    test_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    const allocator = testing.allocator;
    var cat = policy_catalog_mod.PolicyCatalog.init(allocator);
    defer cat.deinit();

    var h = try Harness.init(allocator, &cat);
    defer h.deinit();

    user_mgmt.setAuthEnabled(true);
    defer user_mgmt.setAuthEnabled(false);

    h.ctx.role = null;
    try testing.expectError(error.Unauthenticated, h.exec("CREATE POLICY p_anon ON GRAPH * FOR READ;"));
    try testing.expectEqual(@as(usize, 0), cat.listPolicies().len);
}

test "GAP-0911: admin can still run the full policy DDL lifecycle" {
    test_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    const allocator = testing.allocator;
    var cat = policy_catalog_mod.PolicyCatalog.init(allocator);
    defer cat.deinit();

    var h = try Harness.init(allocator, &cat);
    defer h.deinit();

    user_mgmt.setAuthEnabled(true);
    defer user_mgmt.setAuthEnabled(false);

    h.ctx.role = .Admin;
    h.ctx.user = "root";

    var create_res = try h.exec("CREATE POLICY p_ok ON GRAPH * FOR READ;");
    defer create_res.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), cat.listPolicies().len);

    var alter_res = try h.exec("ALTER POLICY p_ok SET ENABLED false;");
    defer alter_res.deinit(allocator);

    var drop_res = try h.exec("DROP POLICY p_ok;");
    defer drop_res.deinit(allocator);
    try testing.expectEqual(@as(usize, 0), cat.listPolicies().len);
}

test "GAP-0911: auth-disabled single-tenant default is unchanged" {
    test_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    const allocator = testing.allocator;
    var cat = policy_catalog_mod.PolicyCatalog.init(allocator);
    defer cat.deinit();

    var h = try Harness.init(allocator, &cat);
    defer h.deinit();

    user_mgmt.setAuthEnabled(false);

    var create_res = try h.exec("CREATE POLICY p_open ON GRAPH * FOR READ;");
    defer create_res.deinit(allocator);
    try testing.expectEqual(@as(usize, 1), cat.listPolicies().len);

    var drop_res = try h.exec("DROP POLICY p_open;");
    defer drop_res.deinit(allocator);
}
