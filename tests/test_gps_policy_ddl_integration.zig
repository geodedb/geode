// GPS Phase 4 (Task 4-4) — Integration tests for CREATE POLICY / DROP POLICY / SHOW POLICIES
// execution dispatch wired through policy_catalog.
//
// These tests exercise the full path:
//   parse GQL -> executeStatementWithContext -> PolicyCatalog add/remove/list
//
// The global catalog is bootstrapped inline (mirroring the server startup
// introduced in Task 4-4) and torn down after each test via defer.
//
// CANARY: REQ=REQ-GPS-DDL-001; FEATURE="GPS Policy DDL"; ASPECT=IntegrationTests; STATUS=TESTED; TEST=self; OWNER=security; UPDATED=2026-05-20

const std = @import("std");
const geode = @import("geode");
const execution = geode.execution;
const policy_catalog_mod = geode.security.policy_catalog;
const graph_store = geode.graph_store;

// Zig 0.16 compat: build an absolute tmp path without realpathAlloc.
fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

// Serialise tests so that the global PolicyCatalog singleton is not shared.
var test_mutex: std.Io.Mutex = .init;

const Harness = struct {
    allocator: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    ctx: execution.ExecutionContext,
    catalog: *policy_catalog_mod.PolicyCatalog,

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
            // GAP-0911: policy DDL is admin-only. These tests exercise the
            // CREATE/DROP/SHOW POLICY execution mechanics (catalog wiring), not
            // authorization, so authenticate as an admin to pass the gate.
            .ctx = execution.ExecutionContext{ .catalog = exec_catalog, .role = .Admin, .user = "admin" },
            .catalog = cat,
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
        return execution.executeStatementWithContext(
            self.allocator,
            parsed.program.statements[0],
            self.ctx,
        );
    }
};

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-DDL-001; FEATURE="GPS Policy DDL"; ASPECT=CreatePolicyExecution; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------

test "E2E: CREATE POLICY then SHOW POLICIES returns it; DROP removes it" {
    test_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    const allocator = std.testing.allocator;
    var cat = policy_catalog_mod.PolicyCatalog.init(allocator);
    defer cat.deinit();

    var h = try Harness.init(allocator, &cat);
    defer h.deinit();

    // CREATE POLICY
    var create_res = try h.exec("CREATE POLICY p1 ON GRAPH * FOR READ;");
    defer create_res.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 1), create_res.rows.len);
    try std.testing.expectEqual(@as(usize, 1), create_res.columns.len);
    try std.testing.expectEqualStrings("status", create_res.columns[0]);
    try std.testing.expectEqualStrings("Policy created", create_res.rows[0][0].Str);

    // The catalog should have exactly one policy.
    try std.testing.expectEqual(@as(usize, 1), cat.listPolicies().len);
    try std.testing.expectEqualStrings("p1", cat.listPolicies()[0].name);
    try std.testing.expectEqualStrings("*", cat.listPolicies()[0].scope_graph);

    // SHOW POLICIES -- should list p1
    var show_res = try h.exec("SHOW POLICIES;");
    defer show_res.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 5), show_res.columns.len);
    try std.testing.expectEqual(@as(usize, 1), show_res.rows.len);
    try std.testing.expectEqualStrings("name", show_res.columns[0]);
    try std.testing.expectEqualStrings("graph", show_res.columns[1]);
    try std.testing.expectEqualStrings("actions", show_res.columns[2]);
    try std.testing.expectEqualStrings("enabled", show_res.columns[3]);
    try std.testing.expectEqualStrings("p1", show_res.rows[0][0].Str);
    try std.testing.expectEqualStrings("*", show_res.rows[0][1].Str);
    try std.testing.expectEqualStrings("read", show_res.rows[0][2].Str);
    try std.testing.expect(show_res.rows[0][3].Bool);
    // SONNY-2732: a policy that compiled is valid.
    try std.testing.expectEqualStrings("valid", show_res.columns[4]);
    try std.testing.expect(show_res.rows[0][4].Bool);

    // DROP POLICY
    var drop_res = try h.exec("DROP POLICY p1;");
    defer drop_res.deinit(allocator);
    try std.testing.expectEqualStrings("Policy dropped", drop_res.rows[0][0].Str);

    // SHOW POLICIES -- now empty
    var show_res2 = try h.exec("SHOW POLICIES;");
    defer show_res2.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 0), show_res2.rows.len);
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-DDL-001; FEATURE="GPS Policy DDL"; ASPECT=CreateMultiActionPolicy; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------

test "CREATE POLICY with multiple actions stores all in catalog" {
    test_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    const allocator = std.testing.allocator;
    var cat = policy_catalog_mod.PolicyCatalog.init(allocator);
    defer cat.deinit();

    var h = try Harness.init(allocator, &cat);
    defer h.deinit();

    var res = try h.exec("CREATE POLICY multi ON GRAPH hr FOR READ, WRITE, MATCH;");
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), cat.listPolicies().len);
    const pol = cat.listPolicies()[0];
    try std.testing.expectEqualStrings("multi", pol.name);
    try std.testing.expectEqualStrings("hr", pol.scope_graph);
    try std.testing.expectEqual(@as(usize, 3), pol.actions.len);
    try std.testing.expectEqual(policy_catalog_mod.Action.read, pol.actions[0]);
    try std.testing.expectEqual(policy_catalog_mod.Action.write, pol.actions[1]);
    try std.testing.expectEqual(policy_catalog_mod.Action.match_, pol.actions[2]);
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-DDL-002; FEATURE="GPS Policy DDL"; ASPECT=DropPolicyNotFound; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------

test "DROP POLICY for nonexistent name returns error.PolicyNotFound" {
    test_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    const allocator = std.testing.allocator;
    var cat = policy_catalog_mod.PolicyCatalog.init(allocator);
    defer cat.deinit();

    var h = try Harness.init(allocator, &cat);
    defer h.deinit();

    const err = h.exec("DROP POLICY ghost;");
    try std.testing.expectError(error.PolicyNotFound, err);
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-DDL-002; FEATURE="GPS Policy DDL"; ASPECT=DropPolicyIfExists; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------

test "DROP POLICY IF EXISTS for nonexistent name succeeds silently" {
    test_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    const allocator = std.testing.allocator;
    var cat = policy_catalog_mod.PolicyCatalog.init(allocator);
    defer cat.deinit();

    var h = try Harness.init(allocator, &cat);
    defer h.deinit();

    var res = try h.exec("DROP POLICY IF EXISTS ghost;");
    defer res.deinit(allocator);
    try std.testing.expectEqualStrings("Policy dropped", res.rows[0][0].Str);
    try std.testing.expectEqual(@as(usize, 0), cat.listPolicies().len);
}

// ---------------------------------------------------------------------------
// CANARY: REQ=REQ-GPS-DDL-003; FEATURE="GPS Policy DDL"; ASPECT=ShowPoliciesEmpty; STATUS=TESTED; OWNER=security; UPDATED=2026-05-20
// ---------------------------------------------------------------------------

test "SHOW POLICIES on empty catalog returns no rows" {
    test_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    const allocator = std.testing.allocator;
    var cat = policy_catalog_mod.PolicyCatalog.init(allocator);
    defer cat.deinit();

    var h = try Harness.init(allocator, &cat);
    defer h.deinit();

    var res = try h.exec("SHOW POLICIES;");
    defer res.deinit(allocator);
    try std.testing.expectEqual(@as(usize, 5), res.columns.len);
    try std.testing.expectEqual(@as(usize, 0), res.rows.len);
}
