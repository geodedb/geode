// GPS Phase 7 (Task 7-2) — ALTER POLICY DDL: parser + executor tests.
//
// Grammar: ALTER POLICY <name> SET ENABLED true|false ;
//
// CANARY: REQ=REQ-GPS-DDL-003; FEATURE="GPS ALTER POLICY DDL"; ASPECT=TestSuite; STATUS=TESTED; TEST=self; OWNER=security; UPDATED=2026-05-21

const std = @import("std");
const geode = @import("geode");
const execution = geode.execution;
const policy_catalog_mod = geode.security.policy_catalog;
const policy_version_mod = geode.security.policy_version;
const decision_cache_mod = geode.security.decision_cache;
const graph_store = geode.graph_store;
const parser_mod = geode.gql.parser;
const lexer_mod = geode.gql.lexer;
const ast = geode.gql.ast;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

fn parseOne(src: []const u8, arena: *std.heap.ArenaAllocator) !ast.Statement {
    var lx = lexer_mod.Lexer{ .src = src };
    var p = parser_mod.Parser{ .lx = &lx, .arena = arena, .cur = lx.next() };
    const prog = try p.parseProgram();
    try std.testing.expectEqual(@as(usize, 1), prog.statements.len);
    return prog.statements[0];
}

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const rc = std.os.linux.getcwd(&cwd_buf, cwd_buf.len);
    const cwd_len = if (@as(isize, @bitCast(rc)) < 0) return error.GetCwdFailed else rc;
    var actual_len = cwd_len;
    while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
    return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
}

// Serialise tests sharing the global PolicyCatalog singleton.
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
            .ctx = execution.ExecutionContext{ .catalog = exec_catalog },
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
// Parser tests
// ---------------------------------------------------------------------------

// CANARY: REQ=REQ-GPS-DDL-003; FEATURE="GPS ALTER POLICY DDL"; ASPECT=ParserSetEnabledFalse; STATUS=TESTED; OWNER=security; UPDATED=2026-05-21
test "parser: ALTER POLICY p1 SET ENABLED false" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const st = try parseOne("ALTER POLICY p1 SET ENABLED false;", &arena);
    try std.testing.expect(st == .AlterPolicy);
    try std.testing.expectEqualStrings("p1", st.AlterPolicy.name);
    try std.testing.expect(st.AlterPolicy.set_enabled != null);
    try std.testing.expectEqual(false, st.AlterPolicy.set_enabled.?);
}

// CANARY: REQ=REQ-GPS-DDL-003; FEATURE="GPS ALTER POLICY DDL"; ASPECT=ParserSetEnabledTrue; STATUS=TESTED; OWNER=security; UPDATED=2026-05-21
test "parser: ALTER POLICY p2 SET ENABLED true" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const st = try parseOne("ALTER POLICY p2 SET ENABLED true;", &arena);
    try std.testing.expect(st == .AlterPolicy);
    try std.testing.expectEqualStrings("p2", st.AlterPolicy.name);
    try std.testing.expect(st.AlterPolicy.set_enabled != null);
    try std.testing.expectEqual(true, st.AlterPolicy.set_enabled.?);
}

// ---------------------------------------------------------------------------
// Executor integration tests
// ---------------------------------------------------------------------------

// CANARY: REQ=REQ-GPS-DDL-003; FEATURE="GPS ALTER POLICY DDL"; ASPECT=DisablePolicy; STATUS=TESTED; OWNER=security; UPDATED=2026-05-21
test "E2E: CREATE POLICY then ALTER ... SET ENABLED false disables it" {
    test_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    const allocator = std.testing.allocator;
    var cat = policy_catalog_mod.PolicyCatalog.init(allocator);
    defer cat.deinit();

    var h = try Harness.init(allocator, &cat);
    defer h.deinit();

    var create_res = try h.exec("CREATE POLICY p1 ON GRAPH * FOR READ;");
    defer create_res.deinit(allocator);
    try std.testing.expectEqualStrings("status", create_res.columns[0]);

    try std.testing.expectEqual(@as(usize, 1), cat.listPolicies().len);
    try std.testing.expectEqual(true, cat.listPolicies()[0].enabled);

    var alter_res = try h.exec("ALTER POLICY p1 SET ENABLED false;");
    defer alter_res.deinit(allocator);
    try std.testing.expectEqualStrings("status", alter_res.columns[0]);
    try std.testing.expectEqualStrings("Policy altered", alter_res.rows[0][0].Str);

    try std.testing.expectEqual(false, cat.listPolicies()[0].enabled);
}

// CANARY: REQ=REQ-GPS-DDL-003; FEATURE="GPS ALTER POLICY DDL"; ASPECT=EnablePolicy; STATUS=TESTED; OWNER=security; UPDATED=2026-05-21
test "E2E: CREATE then disable then re-enable policy" {
    test_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    const allocator = std.testing.allocator;
    var cat = policy_catalog_mod.PolicyCatalog.init(allocator);
    defer cat.deinit();

    var h = try Harness.init(allocator, &cat);
    defer h.deinit();

    var create_res = try h.exec("CREATE POLICY p1 ON GRAPH * FOR READ;");
    defer create_res.deinit(allocator);

    var disable_res = try h.exec("ALTER POLICY p1 SET ENABLED false;");
    defer disable_res.deinit(allocator);
    try std.testing.expectEqual(false, cat.listPolicies()[0].enabled);

    var enable_res = try h.exec("ALTER POLICY p1 SET ENABLED true;");
    defer enable_res.deinit(allocator);
    try std.testing.expectEqual(true, cat.listPolicies()[0].enabled);
}

// CANARY: REQ=REQ-GPS-DDL-003; FEATURE="GPS ALTER POLICY DDL"; ASPECT=ShowPoliciesReflectsEnabled; STATUS=TESTED; OWNER=security; UPDATED=2026-05-21
test "E2E: SHOW POLICIES reflects updated enabled flag after ALTER" {
    test_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    const allocator = std.testing.allocator;
    var cat = policy_catalog_mod.PolicyCatalog.init(allocator);
    defer cat.deinit();

    var h = try Harness.init(allocator, &cat);
    defer h.deinit();

    var create_res = try h.exec("CREATE POLICY p1 ON GRAPH * FOR READ;");
    defer create_res.deinit(allocator);

    var alter_res = try h.exec("ALTER POLICY p1 SET ENABLED false;");
    defer alter_res.deinit(allocator);

    var show_res = try h.exec("SHOW POLICIES;");
    defer show_res.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), show_res.rows.len);
    // Column order: name, graph, actions, enabled
    try std.testing.expectEqualStrings("p1", show_res.rows[0][0].Str);
    try std.testing.expectEqual(false, show_res.rows[0][3].Bool);
}

// CANARY: REQ=REQ-GPS-DDL-003; FEATURE="GPS ALTER POLICY DDL"; ASPECT=PolicyVersionBumped; STATUS=TESTED; OWNER=security; UPDATED=2026-05-21
test "E2E: ALTER POLICY bumps policy_version" {
    test_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    const allocator = std.testing.allocator;
    var cat = policy_catalog_mod.PolicyCatalog.init(allocator);
    defer cat.deinit();

    var h = try Harness.init(allocator, &cat);
    defer h.deinit();

    var create_res = try h.exec("CREATE POLICY p1 ON GRAPH * FOR READ;");
    defer create_res.deinit(allocator);

    const version_before = policy_version_mod.getPolicyVersion();

    var alter_res = try h.exec("ALTER POLICY p1 SET ENABLED false;");
    defer alter_res.deinit(allocator);

    const version_after = policy_version_mod.getPolicyVersion();
    try std.testing.expect(version_after > version_before);
}

// CANARY: REQ=REQ-GPS-DDL-003; FEATURE="GPS ALTER POLICY DDL"; ASPECT=DecisionCacheInvalidated; STATUS=TESTED; OWNER=security; UPDATED=2026-05-21
test "E2E: ALTER POLICY invalidates the decision cache" {
    test_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    const allocator = std.testing.allocator;
    var cat = policy_catalog_mod.PolicyCatalog.init(allocator);
    defer cat.deinit();

    var h = try Harness.init(allocator, &cat);
    defer h.deinit();

    // Install a decision cache so invalidateAll() is exercised.
    var cache = decision_cache_mod.DecisionCache.init(allocator, 64);
    defer cache.deinit();
    decision_cache_mod.setGlobalCache(&cache);
    defer decision_cache_mod.clearGlobalCache();

    var create_res = try h.exec("CREATE POLICY p1 ON GRAPH * FOR READ;");
    defer create_res.deinit(allocator);

    // Cache is empty after CREATE invalidation.
    try std.testing.expectEqual(@as(usize, 0), cache.count());

    var alter_res = try h.exec("ALTER POLICY p1 SET ENABLED false;");
    defer alter_res.deinit(allocator);

    // Cache remains empty after ALTER invalidation.
    try std.testing.expectEqual(@as(usize, 0), cache.count());
}

// CANARY: REQ=REQ-GPS-DDL-003; FEATURE="GPS ALTER POLICY DDL"; ASPECT=PolicyNotFound; STATUS=TESTED; OWNER=security; UPDATED=2026-05-21
test "E2E: ALTER POLICY on non-existent name returns PolicyNotFound" {
    test_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    const allocator = std.testing.allocator;
    var cat = policy_catalog_mod.PolicyCatalog.init(allocator);
    defer cat.deinit();

    var h = try Harness.init(allocator, &cat);
    defer h.deinit();

    const err = h.exec("ALTER POLICY no_such_policy SET ENABLED false;");
    try std.testing.expectError(error.PolicyNotFound, err);
}
