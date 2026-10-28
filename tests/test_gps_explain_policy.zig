// GPS Phase 7 (Task 7-4) — EXPLAIN POLICY FOR <inner_query>: parser + executor tests.
//
// Grammar: EXPLAIN POLICY FOR <inner_query> ;
//
// Behaviour (Phase 7):
//   - Classifies the top-level action of the inner query.
//   - Calls gps.decide() once with the context's Principal.
//   - Returns one result row: step | action | resource | decision | reason_code
//
// CANARY: REQ=REQ-GPS-EXPLAIN-001; FEATURE="GPS EXPLAIN POLICY"; ASPECT=TestSuite; STATUS=TESTED; TEST=self; OWNER=security; UPDATED=2026-05-21

const std = @import("std");
const geode = @import("geode");
const execution = geode.execution;
const policy_catalog_mod = geode.security.policy_catalog;
const principal_mod = geode.security.principal;
const graph_store = geode.graph_store;
const parser_mod = geode.gql.parser;
const lexer_mod = geode.gql.lexer;
const ast = geode.gql.ast;

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

/// Build a Principal for use in tests.  Pass roles like &.{"Admin"} or &.{"ReadOnly"}.
fn makePrincipal(username: []const u8, roles: []const []const u8, auth_version: u64) principal_mod.Principal {
    return .{
        .user_id = auth_version,
        .username = username,
        .session_id = null,
        .tenant_id = null,
        .active_graph = null,
        .roles = roles,
        .custom_roles = &.{},
        .auth_method = .password,
        .auth_version = auth_version,
        .mfa_state = .none,
        .elevation_until = null,
        .api_key_id = null,
        .certificate_subject = null,
        .risk_context = .unknown,
        .source = .test_harness,
        .attributes = principal_mod.AttributeMap.emptySentinel(),
    };
}

var test_mutex: std.Io.Mutex = .init;

const Harness = struct {
    allocator: std.mem.Allocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    /// Base context WITHOUT a principal set — callers wire ctx.principal themselves
    /// so the pointer is always into a caller-owned Principal (avoids dangling ptr
    /// when the Harness is returned by value from init).
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

    pub fn execWithCtx(self: *Harness, query: []const u8, ctx: execution.ExecutionContext) !execution.ExecutionResult {
        var parsed = try geode.parseGql(query, self.allocator);
        defer parsed.deinit();
        return execution.executeStatementWithContext(
            self.allocator,
            parsed.program.statements[0],
            ctx,
        );
    }
};

// ---------------------------------------------------------------------------
// Parser tests
// ---------------------------------------------------------------------------

// CANARY: REQ=REQ-GPS-EXPLAIN-001; FEATURE="GPS EXPLAIN POLICY"; ASPECT=ParserMatchQuery; STATUS=TESTED; OWNER=security; UPDATED=2026-05-21
test "parser: EXPLAIN POLICY FOR MATCH (n) RETURN n" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const st = try parseOne("EXPLAIN POLICY FOR MATCH (n) RETURN n;", &arena);
    try std.testing.expect(st == .ExplainPolicy);
    try std.testing.expect(st.ExplainPolicy.inner.* == .Query);
}

// CANARY: REQ=REQ-GPS-EXPLAIN-001; FEATURE="GPS EXPLAIN POLICY"; ASPECT=ParserCreateQuery; STATUS=TESTED; OWNER=security; UPDATED=2026-05-21
test "parser: EXPLAIN POLICY FOR CREATE (n:Person)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const st = try parseOne("EXPLAIN POLICY FOR CREATE (n:Person);", &arena);
    try std.testing.expect(st == .ExplainPolicy);
    try std.testing.expect(st.ExplainPolicy.inner.* == .Create);
}

// CANARY: REQ=REQ-GPS-EXPLAIN-001; FEATURE="GPS EXPLAIN POLICY"; ASPECT=ParserShowQuery; STATUS=TESTED; OWNER=security; UPDATED=2026-05-21
test "parser: EXPLAIN POLICY FOR SHOW POLICIES" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const st = try parseOne("EXPLAIN POLICY FOR SHOW POLICIES;", &arena);
    try std.testing.expect(st == .ExplainPolicy);
    try std.testing.expect(st.ExplainPolicy.inner.* == .Show);
}

// CANARY: REQ=REQ-GPS-EXPLAIN-001; FEATURE="GPS EXPLAIN POLICY"; ASPECT=ParserNoConflict; STATUS=TESTED; OWNER=security; UPDATED=2026-05-21
test "parser: bare EXPLAIN still parses as Explain (no regression)" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const st = try parseOne("EXPLAIN MATCH (n) RETURN n;", &arena);
    try std.testing.expect(st == .Explain);
}

// ---------------------------------------------------------------------------
// Executor integration tests
// ---------------------------------------------------------------------------

// CANARY: REQ=REQ-GPS-EXPLAIN-001; FEATURE="GPS EXPLAIN POLICY"; ASPECT=MatchClassifiedAsMatch; STATUS=TESTED; OWNER=security; UPDATED=2026-05-21
test "E2E: EXPLAIN POLICY FOR MATCH classifies as match_ and Admin gets allow" {
    test_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    const allocator = std.testing.allocator;
    var cat = policy_catalog_mod.PolicyCatalog.init(allocator);
    defer cat.deinit();

    var h = try Harness.init(allocator, &cat);
    defer h.deinit();

    // Principal lives in this test frame (safe stack pointer).
    const admin_roles: []const []const u8 = &.{"Admin"};
    var admin = makePrincipal("admin", admin_roles, 1);
    var ctx = h.ctx;
    ctx.principal = &admin;

    var res = try h.execWithCtx("EXPLAIN POLICY FOR MATCH (n) RETURN n;", ctx);
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), res.rows.len);
    try std.testing.expectEqual(@as(usize, 5), res.columns.len);
    try std.testing.expectEqualStrings("step", res.columns[0]);
    try std.testing.expectEqualStrings("action", res.columns[1]);
    try std.testing.expectEqualStrings("resource", res.columns[2]);
    try std.testing.expectEqualStrings("decision", res.columns[3]);
    try std.testing.expectEqualStrings("reason_code", res.columns[4]);

    const row = res.rows[0];
    try std.testing.expectEqual(@as(i64, 1), row[0].Int);
    try std.testing.expectEqualStrings("match_", row[1].Str);
    try std.testing.expectEqualStrings("database", row[2].Str);
    try std.testing.expectEqualStrings("allow", row[3].Str);
}

// CANARY: REQ=REQ-GPS-EXPLAIN-001; FEATURE="GPS EXPLAIN POLICY"; ASPECT=CreateClassifiedAsCreate; STATUS=TESTED; OWNER=security; UPDATED=2026-05-21
test "E2E: EXPLAIN POLICY FOR CREATE classifies as create and ReadOnly gets unauthorized" {
    test_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    const allocator = std.testing.allocator;
    var cat = policy_catalog_mod.PolicyCatalog.init(allocator);
    defer cat.deinit();

    var h = try Harness.init(allocator, &cat);
    defer h.deinit();

    const ro_roles: []const []const u8 = &.{"ReadOnly"};
    var ro = makePrincipal("reader", ro_roles, 2);
    var ctx = h.ctx;
    ctx.principal = &ro;

    var res = try h.execWithCtx("EXPLAIN POLICY FOR CREATE (n:Person);", ctx);
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), res.rows.len);
    const row = res.rows[0];
    try std.testing.expectEqualStrings("create", row[1].Str);
    try std.testing.expectEqualStrings("unauthorized", row[3].Str);
}

// CANARY: REQ=REQ-GPS-EXPLAIN-001; FEATURE="GPS EXPLAIN POLICY"; ASPECT=ShowClassifiedAsShowMetadata; STATUS=TESTED; OWNER=security; UPDATED=2026-05-21
test "E2E: EXPLAIN POLICY FOR SHOW POLICIES classifies as show_metadata and is allowed" {
    test_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    const allocator = std.testing.allocator;
    var cat = policy_catalog_mod.PolicyCatalog.init(allocator);
    defer cat.deinit();

    var h = try Harness.init(allocator, &cat);
    defer h.deinit();

    const admin_roles: []const []const u8 = &.{"Admin"};
    var admin = makePrincipal("admin", admin_roles, 1);
    var ctx = h.ctx;
    ctx.principal = &admin;

    var res = try h.execWithCtx("EXPLAIN POLICY FOR SHOW POLICIES;", ctx);
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), res.rows.len);
    try std.testing.expectEqualStrings("show_metadata", res.rows[0][1].Str);
    try std.testing.expectEqualStrings("allow", res.rows[0][3].Str);
}

// CANARY: REQ=REQ-GPS-EXPLAIN-001; FEATURE="GPS EXPLAIN POLICY"; ASPECT=NoPrincipalUnauthenticated; STATUS=TESTED; OWNER=security; UPDATED=2026-05-21
test "E2E: EXPLAIN POLICY FOR without Principal returns unauthenticated decision" {
    test_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    const allocator = std.testing.allocator;
    var cat = policy_catalog_mod.PolicyCatalog.init(allocator);
    defer cat.deinit();

    var h = try Harness.init(allocator, &cat);
    defer h.deinit();

    // ctx.principal is already null from Harness.init.
    var res = try h.execWithCtx("EXPLAIN POLICY FOR MATCH (n) RETURN n;", h.ctx);
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), res.rows.len);
    try std.testing.expectEqualStrings("unauthenticated", res.rows[0][3].Str);
    try std.testing.expectEqualStrings("no_principal", res.rows[0][4].Str);
}

// CANARY: REQ=REQ-GPS-EXPLAIN-001; FEATURE="GPS EXPLAIN POLICY"; ASPECT=ReadOnlyAllowsMatch; STATUS=TESTED; OWNER=security; UPDATED=2026-05-21
test "E2E: ReadOnly principal is allowed for MATCH via builtin_role" {
    test_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    const allocator = std.testing.allocator;
    var cat = policy_catalog_mod.PolicyCatalog.init(allocator);
    defer cat.deinit();

    var h = try Harness.init(allocator, &cat);
    defer h.deinit();

    const ro_roles: []const []const u8 = &.{"ReadOnly"};
    var ro = makePrincipal("reader2", ro_roles, 3);
    var ctx = h.ctx;
    ctx.principal = &ro;

    var res = try h.execWithCtx("EXPLAIN POLICY FOR MATCH (n) RETURN n;", ctx);
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), res.rows.len);
    try std.testing.expectEqualStrings("match_", res.rows[0][1].Str);
    try std.testing.expectEqualStrings("allow", res.rows[0][3].Str);
    try std.testing.expectEqualStrings("builtin_role", res.rows[0][4].Str);
}

// CANARY: REQ=REQ-GPS-EXPLAIN-001; FEATURE="GPS EXPLAIN POLICY"; ASPECT=ReasonCodePresent; STATUS=TESTED; OWNER=security; UPDATED=2026-05-21
test "E2E: EXPLAIN POLICY result row has non-empty reason_code" {
    test_mutex.lockUncancelable(std.Io.Threaded.global_single_threaded.io());
    defer test_mutex.unlock(std.Io.Threaded.global_single_threaded.io());

    const allocator = std.testing.allocator;
    var cat = policy_catalog_mod.PolicyCatalog.init(allocator);
    defer cat.deinit();

    var h = try Harness.init(allocator, &cat);
    defer h.deinit();

    const admin_roles: []const []const u8 = &.{"Admin"};
    var admin = makePrincipal("admin", admin_roles, 1);
    var ctx = h.ctx;
    ctx.principal = &admin;

    var res = try h.execWithCtx("EXPLAIN POLICY FOR MATCH (n) RETURN n;", ctx);
    defer res.deinit(allocator);

    try std.testing.expectEqual(@as(usize, 1), res.rows.len);
    const reason_code = res.rows[0][4].Str;
    try std.testing.expect(reason_code.len > 0);
}
