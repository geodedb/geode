// RLS row conditions: a policy USING condition that compares a row property
// with a function of the session, such as `owner = current_user()`.
//
// Before this change the policy predicate compiler accepted only a session
// function compared with a literal (`current_user() = 'alice'`). Since
// b5130bf4 a row comparison is refused at DDL time with 42000; before that it
// was stored uncompiled and denied everything. So a per-user policy had to be
// written once per user, and "each user sees the rows they own" could not be
// written at all.
//
// Now a row condition compiles, and a READ / MATCH policy that has one filters
// the rows a read returns:
//
//   row_prop (= | <>) session_fn    or    session_fn (= | <>) row_prop
//   session_fn ::= current_user() | current_tenant() | current_graph()
//
// The session function is evaluated for the reading session when the row is
// read. A missing or null property, a property that is not a string, or a
// session function with no value denies the row (for `<>` too). The verdict
// is never put in the GPS decision cache.
//
// Every test below fails before the change: the policies cannot be created,
// and the decision-cache key ignored the session's tenant and active graph.
//
// CANARY: REQ=REQ-RLS-SESSION-ROW-CONDITIONS; FEATURE="GPS Row Conditions"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_rls_session_row_conditions.zig; OWNER=security; UPDATED=2026-10-11

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const harness = @import("node_scan_stream_harness.zig");
const auth_graph_manager_mod = @import("auth_graph_manager");
const policy_persistence = @import("policy_persistence");

const execution = geode.execution;
const graph_store = geode.graph_store;
const planned_read_runtime = geode.planned_read_runtime;
const policy_catalog = geode.security.policy_catalog;
const policy_expression = geode.security.policy_expression;
const gps = geode.security.gps;
const decision_cache = geode.security.decision_cache;
const principal_mod = geode.security.principal;
const Value = geode.value_types.Value;

// ---------------------------------------------------------------------------
// Helpers
// ---------------------------------------------------------------------------

const read_actions = [_]policy_catalog.Action{.read};

fn spec(name: []const u8, expr: []const u8) policy_catalog.PolicySpec {
    return .{
        .name = name,
        .scope_graph = "*",
        .actions = &read_actions,
        .effect = .allow,
        .expression_source = expr,
        .enabled = true,
    };
}

/// A row for the unit tests: property name -> value.
const TestRow = struct {
    entries: []const struct { []const u8, policy_expression.RowValue },

    fn get(ctx: *const anyopaque, name: []const u8) policy_expression.RowValue {
        const self: *const TestRow = @ptrCast(@alignCast(ctx));
        for (self.entries) |e| {
            if (std.mem.eql(u8, e[0], name)) return e[1];
        }
        return .missing;
    }

    fn accessor(self: *const TestRow) policy_expression.RowAccessor {
        return .{ .ctx = self, .getFn = get };
    }
};

fn evalFor(source: []const u8, user: ?[]const u8, row: *const TestRow) !bool {
    var compiled = try policy_expression.compileExpression(testing.allocator, source);
    defer compiled.deinit();
    return policy_expression.evaluate(&compiled, .{
        .current_user = user,
        .current_tenant = "acme",
        .current_graph = "sales",
        .resource_label = null,
        .row = row.accessor(),
    });
}

fn makePrincipal(username: []const u8, roles: []const []const u8, tenant: ?[]const u8, graph: ?[]const u8) principal_mod.Principal {
    return .{
        .user_id = 7,
        .username = username,
        .session_id = null,
        .tenant_id = tenant,
        .active_graph = graph,
        .roles = roles,
        .custom_roles = &.{},
        .auth_method = .password,
        .auth_version = 1,
        .mfa_state = .none,
        .elevation_until = null,
        .api_key_id = null,
        .certificate_subject = null,
        .risk_context = principal_mod.RiskContext.unknown,
        .attributes = principal_mod.AttributeMap.emptySentinel(),
        .source = .test_harness,
    };
}

// ---------------------------------------------------------------------------
// Grammar
// ---------------------------------------------------------------------------

test "row conditions compile, in either order, with = and <>, alone and combined; anything else is still refused" {
    const ok = [_][]const u8{
        "owner = current_user()",
        "current_user() = owner",
        "owner <> current_user()",
        "tenant = current_tenant()",
        "graph_tag = current_graph()",
        "owner = current_user() OR current_user() = 'auditor'",
        "(owner = current_user() AND tenant = current_tenant()) OR current_user() = 'auditor'",
        "owner=current_user()",
    };
    for (ok) |src| {
        var compiled = policy_expression.compileExpression(testing.allocator, src) catch |err| {
            std.debug.print("refused: {s} ({s})\n", .{ src, @errorName(err) });
            return err;
        };
        defer compiled.deinit();
        try testing.expect(compiled.reads_row);
    }

    // The literal subset is unchanged and reads no row.
    var lit = try policy_expression.compileExpression(testing.allocator, "current_user() = 'alice'");
    defer lit.deinit();
    try testing.expect(!lit.reads_row);

    // Conditions outside the grammar are still refused.
    const bad = [_][]const u8{
        "owner = 'alice'", // a row property against a literal
        "owner = current_user", // no call parentheses
        "n.owner = current_user()", // a variable-qualified property
        "owner == current_user()", // not an operator of the grammar
        "owner != current_user()", // not an operator of the grammar
        "current_user() <> 'alice'", // <> is for row conditions only
        "owner = banana()", // not a session function
        "current_user() = current_tenant()", // no row property
        "owner = current_user() AND", // trailing connective
        "AND = current_user()", // a connective is not a property
        "user_id = current_user_id()", // geode has no current_user_id()
    };
    for (bad) |src| {
        if (policy_expression.compileExpression(testing.allocator, src)) |compiled_ok| {
            var c = compiled_ok;
            c.deinit();
            std.debug.print("accepted: {s}\n", .{src});
            return error.ExpectedRefusal;
        } else |err| try testing.expectEqual(error.InvalidExpression, err);
    }
}

test "DDL refuses a row condition on a policy for a write action" {
    var cat = policy_catalog.PolicyCatalog.init(testing.allocator);
    defer cat.deinit();
    const write_actions = [_]policy_catalog.Action{ .read, .write };
    var s = spec("own_rows_write", "owner = current_user()");
    s.actions = &write_actions;
    try testing.expectError(error.RowConditionRequiresReadPolicy, cat.addPolicyStrict(s));
    try testing.expectEqual(@as(usize, 0), cat.listPolicies().len);

    try cat.addPolicyStrict(spec("own_rows", "owner = current_user()"));
    try testing.expectEqual(@as(usize, 1), cat.listPolicies().len);
    try testing.expect(cat.listPolicies()[0].compiled.?.reads_row);
}

// ---------------------------------------------------------------------------
// Evaluation (fail-closed)
// ---------------------------------------------------------------------------

test "a row condition compares the session's value with the row's, and fails closed" {
    const alice_row = TestRow{ .entries = &.{.{ "owner", .{ .string = "alice" } }} };
    const null_row = TestRow{ .entries = &.{.{ "owner", .null_ }} };
    const missing_row = TestRow{ .entries = &.{.{ "other", .{ .string = "alice" } }} };
    const int_row = TestRow{ .entries = &.{.{ "owner", .other }} };
    const empty_row = TestRow{ .entries = &.{.{ "owner", .{ .string = "" } }} };
    const tenant_row = TestRow{ .entries = &.{ .{ "tenant", .{ .string = "acme" } }, .{ "graph_tag", .{ .string = "sales" } } } };

    try testing.expect(try evalFor("owner = current_user()", "alice", &alice_row));
    try testing.expect(try evalFor("current_user() = owner", "alice", &alice_row));
    try testing.expect(!try evalFor("owner = current_user()", "bob", &alice_row));
    try testing.expect(try evalFor("owner <> current_user()", "bob", &alice_row));
    try testing.expect(!try evalFor("owner <> current_user()", "alice", &alice_row));
    try testing.expect(try evalFor("tenant = current_tenant() AND graph_tag = current_graph()", "x", &tenant_row));

    // Missing, null and non-string properties deny, for = and for <>.
    for ([_]*const TestRow{ &null_row, &missing_row, &int_row }) |row| {
        try testing.expect(!try evalFor("owner = current_user()", "alice", row));
        try testing.expect(!try evalFor("owner <> current_user()", "alice", row));
    }
    // A session with no value for the function denies, even against an empty
    // property.
    try testing.expect(!try evalFor("owner = current_user()", null, &alice_row));
    try testing.expect(!try evalFor("owner <> current_user()", null, &alice_row));
    try testing.expect(!try evalFor("owner = current_user()", "", &empty_row));

    // With no row at all (a statement-level decision) a row condition is false.
    var compiled = try policy_expression.compileExpression(testing.allocator, "owner = current_user()");
    defer compiled.deinit();
    try testing.expect(!policy_expression.evaluate(&compiled, .{ .current_user = "alice", .current_tenant = null, .current_graph = null, .resource_label = null }));
}

// ---------------------------------------------------------------------------
// End-to-end: reads through the executor
// ---------------------------------------------------------------------------

const Session = struct {
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    ctx: execution.ExecutionContext,
    cat: policy_catalog.PolicyCatalog,

    /// A persisted store, so a read is served by the legacy executor only
    /// because the planned read declines it.
    fn init(self: *Session) !void {
        const allocator = testing.allocator;
        execution.initEvaluator();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, null);
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const data_dir = try harness.tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);
        graph_store.setDataDirOverride(allocator, data_dir);
        _ = graph_store.getGlobalStore(allocator);
        if (graph_store.getGlobalAdapter() == null) return error.WrongDeployment;
        const catalog = try execution.ensureCatalogInstance(allocator);
        self.* = .{
            .arena = std.heap.ArenaAllocator.init(allocator),
            .tmp = tmp,
            .data_dir = data_dir,
            .ctx = .{ .catalog = catalog, .role = .Admin, .user = "admin" },
            .cat = policy_catalog.PolicyCatalog.init(allocator),
        };
        policy_catalog.setGlobalCatalog(&self.cat);
    }

    fn deinit(self: *Session) void {
        policy_catalog.clearGlobalCatalog();
        self.cat.deinit();
        self.arena.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(testing.allocator, null);
        testing.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    fn run(self: *Session, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        const prev = execution.pushActiveContext(&self.ctx);
        defer execution.popActiveContext(prev);
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    fn exec(self: *Session, query: []const u8) !void {
        var r = try self.run(query);
        r.deinit(self.arena.allocator());
    }

    /// Become `user` (a ReadWrite session), or the admin.
    fn as(self: *Session, user: []const u8) void {
        self.ctx.user = user;
        self.ctx.role = if (std.mem.eql(u8, user, "admin")) .Admin else .ReadWrite;
        self.ctx.principal = null;
    }

    fn seed(self: *Session) !void {
        self.as("admin");
        const nodes = [_][]const u8{
            "CREATE (:Doc {s: 'a1', owner: 'alice'})",
            "CREATE (:Doc {s: 'a2', owner: 'alice'})",
            "CREATE (:Doc {s: 'b1', owner: 'bob'})",
            "CREATE (:Doc {s: 'nul', owner: null})",
            "CREATE (:Doc {s: 'miss'})",
            "CREATE (:Doc {s: 'int', owner: 42})",
            "CREATE (:Doc {s: 'empty', owner: ''})",
            "CREATE (:G {s: 'ga', owner: 'alice'})",
        };
        for (nodes) |q| try self.exec(q);
        const targets = [_][]const u8{ "a1", "a2", "b1", "nul", "miss", "int", "empty" };
        const aa = self.arena.allocator();
        for (targets) |t| {
            try self.exec(try std.fmt.allocPrint(aa, "MATCH (g:G {{s: 'ga'}}), (h {{s: '{s}'}}) CREATE (g)-[:R]->(h)", .{t}));
        }
        // The policy, through the DDL a user writes.
        try self.exec("CREATE POLICY own_rows ON GRAPH * FOR READ USING owner = current_user();");
    }
};

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn render(aa: std.mem.Allocator, v: Value) ![]const u8 {
    return switch (v) {
        .Str, .Text => |s| s,
        .Int => |n| try std.fmt.allocPrint(aa, "{d}", .{n}),
        .Null => "null",
        else => try std.fmt.allocPrint(aa, "<{s}>", .{@tagName(v)}),
    };
}

const Failures = struct {
    items: std.ArrayList([]const u8) = .empty,

    fn add(self: *Failures, aa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
        try self.items.append(aa, try std.fmt.allocPrint(aa, fmt, args));
    }

    fn check(self: *const Failures) !void {
        if (self.items.items.len == 0) return;
        std.debug.print("\n{d} failed check(s):\n", .{self.items.items.len});
        for (self.items.items) |msg| std.debug.print("  {s}\n", .{msg});
        return error.RowConditionChecksFailed;
    }
};

/// `query`, run as the session's current user, returns exactly `want` (any
/// order), and was not served by the planned read (which applies no RLS).
fn expectRows(s: *Session, f: *Failures, query: []const u8, want: []const []const u8) !void {
    const aa = s.arena.allocator();
    planned_read_runtime.resetPathRowsMaterialized();
    var result = s.run(query) catch |err| {
        try f.add(aa, "[{s}] {s}: error {s}", .{ s.ctx.user.?, query, @errorName(err) });
        return;
    };
    defer result.deinit(aa);
    const planned = planned_read_runtime.getPathRowsMaterialized();
    if (planned != 0) try f.add(aa, "[{s}] {s}: served by the planned read ({d} materialized)", .{ s.ctx.user.?, query, planned });

    const got = try aa.alloc([]const u8, result.rows.len);
    for (result.rows, got) |row, *g| {
        const cells = try aa.alloc([]const u8, row.len);
        for (row, cells) |cell, *c| c.* = try render(aa, cell);
        g.* = try std.mem.join(aa, "|", cells);
    }
    std.mem.sort([]const u8, got, {}, lessThan);
    const exp = try aa.dupe([]const u8, want);
    std.mem.sort([]const u8, exp, {}, lessThan);
    const same = got.len == exp.len and for (got, exp) |g, w| {
        if (!std.mem.eql(u8, g, w)) break false;
    } else true;
    if (!same) {
        try f.add(aa, "[{s}] {s}: expected {{{s}}}, got {{{s}}}", .{ s.ctx.user.?, query, try std.mem.join(aa, ",", exp), try std.mem.join(aa, ",", got) });
    }
}

fn expectAliceView(s: *Session, f: *Failures) !void {
    s.as("alice");
    try expectRows(s, f, "MATCH (n:Doc) RETURN n.s", &.{ "a1", "a2" });
    try expectRows(s, f, "MATCH (n) RETURN n.s", &.{ "a1", "a2", "ga" });
    try expectRows(s, f, "MATCH (n:Doc) RETURN count(n)", &.{"2"});
    try expectRows(s, f, "MATCH (n:Doc) WHERE n.owner IS NULL RETURN n.s", &.{});
    try expectRows(s, f, "MATCH (g:G)-[:R]->(h) RETURN h.s", &.{ "a1", "a2" });
}

fn expectBobView(s: *Session, f: *Failures) !void {
    s.as("bob");
    try expectRows(s, f, "MATCH (n:Doc) RETURN n.s", &.{"b1"});
    try expectRows(s, f, "MATCH (n) RETURN n.s", &.{"b1"});
    try expectRows(s, f, "MATCH (n:Doc) RETURN count(n)", &.{"1"});
    // The hub is alice's: bob cannot start a hop from it.
    try expectRows(s, f, "MATCH (g:G)-[:R]->(h) RETURN h.s", &.{});
}

test "owner = current_user(): alice sees only alice's rows, bob only bob's; null, missing and non-string owners are denied" {
    harness.silenceEngineLogs();
    var s: Session = undefined;
    try s.init();
    defer s.deinit();
    try s.seed();
    var f: Failures = .{};

    try expectAliceView(&s, &f);
    try expectBobView(&s, &f);

    // A user who owns nothing sees nothing.
    s.as("carol");
    try expectRows(&s, &f, "MATCH (n) RETURN n.s", &.{});

    // An admin session bypasses row conditions, as it bypasses every
    // expression RLS policy.
    s.as("admin");
    try expectRows(&s, &f, "MATCH (n:Doc) RETURN count(n)", &.{"7"});

    try f.check();
}

test "owner <> current_user(): every other user's string-owned rows; null and missing owners stay denied" {
    harness.silenceEngineLogs();
    var s: Session = undefined;
    try s.init();
    defer s.deinit();
    s.as("admin");
    try s.exec("CREATE (:Doc {s: 'a1', owner: 'alice'})");
    try s.exec("CREATE (:Doc {s: 'b1', owner: 'bob'})");
    try s.exec("CREATE (:Doc {s: 'nul', owner: null})");
    try s.exec("CREATE (:Doc {s: 'miss'})");
    try s.exec("CREATE POLICY others_rows ON GRAPH * FOR READ USING owner <> current_user();");
    var f: Failures = .{};

    s.as("alice");
    try expectRows(&s, &f, "MATCH (n:Doc) RETURN n.s", &.{"b1"});
    s.as("bob");
    try expectRows(&s, &f, "MATCH (n:Doc) RETURN n.s", &.{"a1"});
    try f.check();
}

test "a row policy scoped to another graph does not filter this one" {
    harness.silenceEngineLogs();
    var s: Session = undefined;
    try s.init();
    defer s.deinit();
    s.as("admin");
    try s.exec("CREATE (:Doc {s: 'a1', owner: 'alice'})");
    try s.exec("CREATE (:Doc {s: 'b1', owner: 'bob'})");
    try s.exec("CREATE POLICY own_rows_elsewhere ON GRAPH elsewhere FOR READ USING owner = current_user();");
    var f: Failures = .{};
    s.as("alice");
    try expectRows(&s, &f, "MATCH (n:Doc) RETURN n.s", &.{ "a1", "b1" });
    try f.check();
}

// ---------------------------------------------------------------------------
// No cross-user leak through the GPS decision cache
// ---------------------------------------------------------------------------

test "the same query as alice, then bob, then alice gives each their own rows, with the decision cache on" {
    harness.silenceEngineLogs();
    var s: Session = undefined;
    try s.init();
    defer s.deinit();
    try s.seed();

    var cache = decision_cache.DecisionCache.init(testing.allocator, decision_cache.DEFAULT_CAPACITY);
    defer cache.deinit();
    decision_cache.setGlobalCache(&cache);
    defer decision_cache.clearGlobalCache();

    const rw_roles = [_][]const u8{"ReadWrite"};
    var alice = makePrincipal("alice", &rw_roles, null, null);
    var bob = makePrincipal("bob", &rw_roles, null, null);
    var f: Failures = .{};
    const aa = s.arena.allocator();

    var cached_after_both: usize = 0;
    for ([_]*principal_mod.Principal{ &alice, &bob, &alice, &bob, &alice }, 0..) |p, i| {
        if (i == 2) cached_after_both = cache.count();
        s.as(p.username.?);
        s.ctx.principal = p;
        // The statement-level read decision is cached per principal.
        const decision = try gps.decide(aa, &gps.DecisionRequest{ .principal = p, .action = .read, .resource = .{ .graph = graph_store.DEFAULT_GRAPH_NAME } });
        if (decision.kind != .allow) try f.add(aa, "[{s}] read decision {s}", .{ p.username.?, @tagName(decision.kind) });
        const query = "MATCH (n:Doc) RETURN n.s";
        if (p == &alice) {
            try expectRows(&s, &f, query, &.{ "a1", "a2" });
        } else {
            try expectRows(&s, &f, query, &.{"b1"});
        }
    }
    // The statement decisions were cached per principal and served again ...
    try testing.expect(cache.getHits() > 0);
    // ... and no row verdict was cached: repeating the reads added nothing.
    try testing.expect(cached_after_both > 0);
    try testing.expectEqual(cached_after_both, cache.count());
    try f.check();
}

test "row verdicts are decided per session, never served from an earlier session's verdict" {
    var cat = policy_catalog.PolicyCatalog.init(testing.allocator);
    defer cat.deinit();
    try cat.addPolicyStrict(spec("own_rows", "owner = current_user()"));
    policy_catalog.setGlobalCatalog(&cat);
    defer policy_catalog.clearGlobalCatalog();
    try testing.expect(gps.rowPoliciesConfigured());

    const alice_row = TestRow{ .entries = &.{.{ "owner", .{ .string = "alice" } }} };
    const alice: gps.RowSession = .{ .username = "alice", .tenant_id = null, .active_graph = null };
    const bob: gps.RowSession = .{ .username = "bob", .tenant_id = null, .active_graph = null };
    for (0..3) |_| {
        try testing.expect(gps.rowPoliciesAllow(testing.allocator, alice, "g", alice_row.accessor()));
        try testing.expect(!gps.rowPoliciesAllow(testing.allocator, bob, "g", alice_row.accessor()));
    }
}

test "the decision cache keys on the session's tenant and active graph, which policy expressions read" {
    var cat = policy_catalog.PolicyCatalog.init(testing.allocator);
    defer cat.deinit();
    try cat.addPolicyStrict(spec("sales_only", "current_graph() = 'sales'"));
    policy_catalog.setGlobalCatalog(&cat);
    defer policy_catalog.clearGlobalCatalog();

    var cache = decision_cache.DecisionCache.init(testing.allocator, decision_cache.DEFAULT_CAPACITY);
    defer cache.deinit();
    decision_cache.setGlobalCache(&cache);
    defer decision_cache.clearGlobalCache();

    // No builtin role: only the policy can allow.
    var in_sales = makePrincipal("dana", &.{}, null, "sales");
    var in_hr = makePrincipal("dana", &.{}, null, "hr");
    const first = try gps.decide(testing.allocator, &gps.DecisionRequest{ .principal = &in_sales, .action = .read, .resource = .{ .database = {} } });
    try testing.expectEqual(gps.PolicyDecisionKind.allow, first.kind);
    // Same user, same versions, same action and resource, another graph: the
    // cached allow for 'sales' must not be served.
    const second = try gps.decide(testing.allocator, &gps.DecisionRequest{ .principal = &in_hr, .action = .read, .resource = .{ .database = {} } });
    try testing.expectEqual(gps.PolicyDecisionKind.unauthorized, second.kind);

    try cat.addPolicyStrict(spec("acme_only", "current_tenant() = 'acme'"));
    var acme = makePrincipal("erin", &.{}, "acme", null);
    var globex = makePrincipal("erin", &.{}, "globex", null);
    try testing.expectEqual(gps.PolicyDecisionKind.allow, (try gps.decide(testing.allocator, &gps.DecisionRequest{ .principal = &acme, .action = .read, .resource = .{ .database = {} } })).kind);
    try testing.expectEqual(gps.PolicyDecisionKind.unauthorized, (try gps.decide(testing.allocator, &gps.DecisionRequest{ .principal = &globex, .action = .read, .resource = .{ .database = {} } })).kind);
}

// ---------------------------------------------------------------------------
// Restart: the stored policy comes back compiled, as a row filter
// ---------------------------------------------------------------------------

const HMAC_KEY = [_]u8{0x5a} ** 32;

test "a row-condition policy survives a restart and still filters rows" {
    const allocator = testing.allocator;
    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    var mgr = try auth_graph_manager_mod.AuthGraphManager.init(allocator, &store);
    defer mgr.deinit();

    try policy_persistence.persistPolicy(&mgr, &HMAC_KEY, spec("own_rows", "owner = current_user()"));
    try mgr.verifyChain(&HMAC_KEY);

    // A fresh catalog, as at the next startup.
    var cat = policy_catalog.PolicyCatalog.init(allocator);
    defer cat.deinit();
    try policy_persistence.hydrateCatalog(allocator, &mgr, &cat);
    const loaded = cat.listPolicies();
    try testing.expectEqual(@as(usize, 1), loaded.len);
    try testing.expectEqualStrings("owner = current_user()", loaded[0].expression_source);
    // Before this change the stored policy hydrated fail-closed (uncompiled).
    try testing.expect(policy_catalog.PolicyCatalog.policyIsValid(&loaded[0]));
    try testing.expect(loaded[0].compiled.?.reads_row);

    policy_catalog.setGlobalCatalog(&cat);
    defer policy_catalog.clearGlobalCatalog();
    const bob_row = TestRow{ .entries = &.{.{ "owner", .{ .string = "bob" } }} };
    try testing.expect(gps.rowPoliciesAllow(allocator, .{ .username = "bob", .tenant_id = null, .active_graph = null }, "g", bob_row.accessor()));
    try testing.expect(!gps.rowPoliciesAllow(allocator, .{ .username = "alice", .tenant_id = null, .active_graph = null }, "g", bob_row.accessor()));
}

// ---------------------------------------------------------------------------
// Listing shows the condition text
// ---------------------------------------------------------------------------

test "geode.auth.policy_create takes a row condition; policy_list and SHOW POLICIES show its text" {
    harness.silenceEngineLogs();
    var s: Session = undefined;
    try s.init();
    defer s.deinit();
    s.as("admin");
    const aa = s.arena.allocator();

    try s.exec("CALL geode.auth.policy_create('user_data_access', 'user_data', 'owner = current_user()')");
    try testing.expectError(
        error.UnsupportedPolicyExpression,
        s.exec("CALL geode.auth.policy_create('user_data_bad', 'user_data', 'owner = current_user_id()')"),
    );

    var listed = try s.run("CALL geode.auth.policy_list()");
    defer listed.deinit(aa);
    try testing.expectEqual(@as(usize, 1), listed.rows.len);
    try testing.expectEqualStrings("condition", listed.columns[3]);
    try testing.expectEqualStrings("user_data_access", listed.rows[0][0].Str);
    try testing.expectEqualStrings("user_data", listed.rows[0][1].Str);
    try testing.expect(listed.rows[0][2].Bool);
    try testing.expectEqualStrings("owner = current_user()", listed.rows[0][3].Str);

    var shown = try s.run("SHOW POLICIES");
    defer shown.deinit(aa);
    try testing.expectEqualStrings("using", shown.columns[5]);
    try testing.expectEqualStrings("owner = current_user()", shown.rows[0][5].Str);
}
