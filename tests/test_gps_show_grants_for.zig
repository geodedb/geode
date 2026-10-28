// GPS Phase 7 (Task 7-3) — SHOW GRANTS FOR <user>: parser + executor tests.
//
// Grammar: SHOW GRANTS FOR <identifier> ;
//
// Filtering rules (Phase 7 text-match approach):
//   - expression_source == "true"  → universally applicable (included for all users)
//   - expression_source contains "current_user() = '<username>'" → user-specific
//   - anything else → excluded from the result
//
// Columns: policy_name, graph, actions, effect, enabled
//
// CANARY: REQ=REQ-GPS-DDL-004; FEATURE="GPS SHOW GRANTS FOR"; ASPECT=TestSuite; STATUS=TESTED; TEST=self; OWNER=security; UPDATED=2026-05-21

const std = @import("std");
const geode = @import("geode");
const execution = geode.execution;
const policy_catalog_mod = geode.security.policy_catalog;
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
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
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

    /// Seed the catalog directly with a policy carrying a custom expression_source.
    pub fn addPolicyRaw(
        self: *Harness,
        name: []const u8,
        scope_graph: []const u8,
        actions: []const policy_catalog_mod.Action,
        expression_source: []const u8,
    ) !void {
        try self.catalog.addPolicy(.{
            .name = name,
            .scope_graph = scope_graph,
            .actions = actions,
            .effect = .allow,
            .expression_source = expression_source,
            .enabled = true,
        });
    }
};

// ---------------------------------------------------------------------------
// Parser tests
// ---------------------------------------------------------------------------

// CANARY: REQ=REQ-GPS-DDL-004; FEATURE="GPS SHOW GRANTS FOR"; ASPECT=ParserBasic; STATUS=TESTED; OWNER=security; UPDATED=2026-05-21
test "parser: SHOW GRANTS FOR alice" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const st = try parseOne("SHOW GRANTS FOR alice;", &arena);
    try std.testing.expect(st == .Show);
    try std.testing.expectEqual(ast.ShowType.grants_for, st.Show.show_type);
    try std.testing.expect(st.Show.target != null);
    try std.testing.expectEqualStrings("alice", st.Show.target.?);
}

// CANARY: REQ=REQ-GPS-DDL-004; FEATURE="GPS SHOW GRANTS FOR"; ASPECT=ParserGRANT; STATUS=TESTED; OWNER=security; UPDATED=2026-05-21
test "parser: SHOW GRANT FOR bob (singular)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const st = try parseOne("SHOW GRANT FOR bob;", &arena);
    try std.testing.expect(st == .Show);
    try std.testing.expectEqual(ast.ShowType.grants_for, st.Show.show_type);
    try std.testing.expectEqualStrings("bob", st.Show.target.?);
}

// ---------------------------------------------------------------------------
// Executor integration tests
// ---------------------------------------------------------------------------

// CANARY: REQ=REQ-GPS-DDL-004; FEATURE="GPS SHOW GRANTS FOR"; ASPECT=UniversalPolicyIncluded; STATUS=TESTED; OWNER=security; UPDATED=2026-05-21
test "E2E: SHOW GRANTS FOR includes universal (true) policies" {
    test_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    const allocator = std.testing.allocator;
    var cat = policy_catalog_mod.PolicyCatalog.init(allocator);
    defer cat.deinit();

    var h = try Harness.init(allocator, &cat);
    defer h.deinit();

    // Policy with expression_source "true" is universally applicable.
    try h.addPolicyRaw("universal_pol", "*", &.{.read}, "true");

    var res = try h.exec("SHOW GRANTS FOR alice;");
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 5), res.columns.len);
    try std.testing.expectEqualStrings("policy_name", res.columns[0]);
    try std.testing.expectEqualStrings("graph", res.columns[1]);
    try std.testing.expectEqualStrings("actions", res.columns[2]);
    try std.testing.expectEqualStrings("effect", res.columns[3]);
    try std.testing.expectEqualStrings("enabled", res.columns[4]);

    try std.testing.expectEqual(@as(usize, 1), res.rows.len);
    try std.testing.expectEqualStrings("universal_pol", res.rows[0][0].Str);
}

// CANARY: REQ=REQ-GPS-DDL-004; FEATURE="GPS SHOW GRANTS FOR"; ASPECT=UserSpecificPolicyIncluded; STATUS=TESTED; OWNER=security; UPDATED=2026-05-21
test "E2E: SHOW GRANTS FOR includes current_user() policies for that user" {
    test_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    const allocator = std.testing.allocator;
    var cat = policy_catalog_mod.PolicyCatalog.init(allocator);
    defer cat.deinit();

    var h = try Harness.init(allocator, &cat);
    defer h.deinit();

    try h.addPolicyRaw("alice_pol", "hr", &.{.read}, "current_user() = 'alice'");
    try h.addPolicyRaw("bob_pol", "hr", &.{.write}, "current_user() = 'bob'");

    var alice_res = try h.exec("SHOW GRANTS FOR alice;");
    defer alice_res.deinit(allocator);

    // alice_pol only
    try std.testing.expectEqual(@as(usize, 1), alice_res.rows.len);
    try std.testing.expectEqualStrings("alice_pol", alice_res.rows[0][0].Str);
}

// CANARY: REQ=REQ-GPS-DDL-004; FEATURE="GPS SHOW GRANTS FOR"; ASPECT=WrongUserExcluded; STATUS=TESTED; OWNER=security; UPDATED=2026-05-21
test "E2E: SHOW GRANTS FOR does not include other users policies" {
    test_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    const allocator = std.testing.allocator;
    var cat = policy_catalog_mod.PolicyCatalog.init(allocator);
    defer cat.deinit();

    var h = try Harness.init(allocator, &cat);
    defer h.deinit();

    try h.addPolicyRaw("bob_pol", "hr", &.{.write}, "current_user() = 'bob'");

    var alice_res = try h.exec("SHOW GRANTS FOR alice;");
    defer alice_res.deinit(allocator);

    // bob_pol must not appear for alice
    try std.testing.expectEqual(@as(usize, 0), alice_res.rows.len);
}

// CANARY: REQ=REQ-GPS-DDL-004; FEATURE="GPS SHOW GRANTS FOR"; ASPECT=UniversalAndUserSpecificMixed; STATUS=TESTED; OWNER=security; UPDATED=2026-05-21
test "E2E: SHOW GRANTS FOR alice returns universal + alice-specific, not bob-specific" {
    test_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    const allocator = std.testing.allocator;
    var cat = policy_catalog_mod.PolicyCatalog.init(allocator);
    defer cat.deinit();

    var h = try Harness.init(allocator, &cat);
    defer h.deinit();

    // Policy 1: alice-specific
    try h.addPolicyRaw("alice_pol", "hr", &.{.read}, "current_user() = 'alice'");
    // Policy 2: bob-specific
    try h.addPolicyRaw("bob_pol", "finance", &.{.write}, "current_user() = 'bob'");
    // Policy 3: universal
    try h.addPolicyRaw("global_pol", "*", &.{.read}, "true");

    var res = try h.exec("SHOW GRANTS FOR alice;");
    defer res.deinit(allocator);

    // Should return alice_pol + global_pol (2 rows), not bob_pol
    try std.testing.expectEqual(@as(usize, 2), res.rows.len);

    // Collect returned policy names
    var found_alice = false;
    var found_global = false;
    for (res.rows) |row| {
        if (std.mem.eql(u8, row[0].Str, "alice_pol")) found_alice = true;
        if (std.mem.eql(u8, row[0].Str, "global_pol")) found_global = true;
        // bob_pol must not appear
        try std.testing.expect(!std.mem.eql(u8, row[0].Str, "bob_pol"));
    }
    try std.testing.expect(found_alice);
    try std.testing.expect(found_global);
}

// CANARY: REQ=REQ-GPS-DDL-004; FEATURE="GPS SHOW GRANTS FOR"; ASPECT=EmptyWithoutCatalog; STATUS=TESTED; OWNER=security; UPDATED=2026-05-21
test "E2E: SHOW GRANTS FOR returns empty when catalog not initialised" {
    test_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    const allocator = std.testing.allocator;
    var cat = policy_catalog_mod.PolicyCatalog.init(allocator);
    defer cat.deinit();

    var h = try Harness.init(allocator, &cat);
    defer h.deinit();

    // Clear the global catalog to simulate pre-startup state.
    policy_catalog_mod.clearGlobalCatalog();
    defer policy_catalog_mod.setGlobalCatalog(&cat);

    var res = try h.exec("SHOW GRANTS FOR alice;");
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 0), res.rows.len);
}

// CANARY: REQ=REQ-GPS-DDL-004; FEATURE="GPS SHOW GRANTS FOR"; ASPECT=ColumnSchema; STATUS=TESTED; OWNER=security; UPDATED=2026-05-21
test "E2E: SHOW GRANTS FOR column order: policy_name, graph, actions, effect, enabled" {
    test_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    const allocator = std.testing.allocator;
    var cat = policy_catalog_mod.PolicyCatalog.init(allocator);
    defer cat.deinit();

    var h = try Harness.init(allocator, &cat);
    defer h.deinit();

    try h.addPolicyRaw("p1", "mydb", &.{ .read, .write }, "true");

    var res = try h.exec("SHOW GRANTS FOR anyone;");
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), res.rows.len);
    const row = res.rows[0];
    try std.testing.expectEqualStrings("p1", row[0].Str); // policy_name
    try std.testing.expectEqualStrings("mydb", row[1].Str); // graph
    try std.testing.expectEqualStrings("read, write", row[2].Str); // actions
    try std.testing.expectEqualStrings("allow", row[3].Str); // effect
    try std.testing.expectEqual(true, row[4].Bool); // enabled
}
