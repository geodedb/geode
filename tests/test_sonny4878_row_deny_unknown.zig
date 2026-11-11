// SONNY-4878: a row DENY policy let a row through when the row comparison it
// makes was unknown.
//
// A row condition (`owner <> current_user()`) is unknown when the row property
// is missing, null or not a string, or when the session function has no value.
// The evaluator collapsed unknown to false before `gps.rowPoliciesAllow` saw
// it, so for a DENY policy "unknown" read as "the deny does not apply" and the
// row was returned: fail-open, and also beside an ALLOW policy that matched.
//
// Required (and pinned here): an unknown row comparison makes a DENY apply
// (the row is withheld) and makes an ALLOW not match; AND/OR propagate unknown
// with three-valued logic, so `unknown AND false` is false (the deny does not
// apply) while `unknown AND true` and `unknown OR false` stay unknown (the deny
// applies). Known `=` / `<>` comparisons decide as before.
//
// CANARY: REQ=REQ-SONNY-4878-ROW-DENY-UNKNOWN; FEATURE="GPS Row Conditions"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny4878_row_deny_unknown.zig; OWNER=security; UPDATED=2026-11-11

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const harness = @import("node_scan_stream_harness.zig");

const execution = geode.execution;
const graph_store = geode.graph_store;
const planned_read_runtime = geode.planned_read_runtime;
const policy_catalog = geode.security.policy_catalog;
const policy_expression = geode.security.policy_expression;
const gps = geode.security.gps;
const Value = geode.value_types.Value;

const read_actions = [_]policy_catalog.Action{.read};

fn spec(name: []const u8, effect: policy_catalog.Effect, expr: []const u8) policy_catalog.PolicySpec {
    return .{
        .name = name,
        .scope_graph = "*",
        .actions = &read_actions,
        .effect = effect,
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

const alice_row = TestRow{ .entries = &.{ .{ "owner", .{ .string = "alice" } }, .{ "tenant", .{ .string = "acme" } } } };
const null_row = TestRow{ .entries = &.{ .{ "owner", .null_ }, .{ "tenant", .{ .string = "acme" } } } };
const missing_row = TestRow{ .entries = &.{.{ "tenant", .{ .string = "acme" } }} };
const int_row = TestRow{ .entries = &.{ .{ "owner", .other }, .{ "tenant", .{ .string = "acme" } } } };
const unknown_rows = [_]*const TestRow{ &null_row, &missing_row, &int_row };

fn session(user: ?[]const u8, tenant: ?[]const u8) gps.RowSession {
    return .{ .username = user, .tenant_id = tenant, .active_graph = null };
}

/// Install exactly `specs` as the global catalog, then decide `row` for `s`.
fn decide(specs: []const policy_catalog.PolicySpec, s: gps.RowSession, row: *const TestRow) !bool {
    var cat = policy_catalog.PolicyCatalog.init(testing.allocator);
    defer cat.deinit();
    for (specs) |sp| try cat.addPolicyStrict(sp);
    policy_catalog.setGlobalCatalog(&cat);
    defer policy_catalog.clearGlobalCatalog();
    return gps.rowPoliciesAllow(testing.allocator, s, "g", row.accessor());
}

const Failures = struct {
    count: usize = 0,

    fn expect(self: *Failures, ok: bool, comptime what: []const u8, args: anytype) void {
        if (ok) return;
        self.count += 1;
        std.debug.print("  FAILED: " ++ what ++ "\n", args);
    }

    fn check(self: *const Failures) !void {
        if (self.count != 0) {
            std.debug.print("{d} failed check(s)\n", .{self.count});
            return error.RowDenyUnknownChecksFailed;
        }
    }
};

// ---------------------------------------------------------------------------
// gps.rowPoliciesAllow: the row verdict every node read path takes
// ---------------------------------------------------------------------------

test "a DENY row policy withholds a row whose owner is missing, null or not a string, in either operand order" {
    var f: Failures = .{};
    for ([_][]const u8{ "owner <> current_user()", "current_user() <> owner", "owner = current_user()", "current_user() = owner" }) |src| {
        const deny = [_]policy_catalog.PolicySpec{spec("d", .deny, src)};
        for (unknown_rows, [_][]const u8{ "null", "missing", "non-string" }) |row, kind| {
            f.expect(!try decide(&deny, session("alice", "acme"), row), "DENY `{s}`: {s} owner was returned", .{ src, kind });
        }
    }
    // Known comparisons are unchanged.
    const deny_ne = [_]policy_catalog.PolicySpec{spec("d", .deny, "owner <> current_user()")};
    f.expect(try decide(&deny_ne, session("alice", null), &alice_row), "DENY owner <> current_user(): owner alice withheld from alice", .{});
    f.expect(!try decide(&deny_ne, session("bob", null), &alice_row), "DENY owner <> current_user(): owner alice returned to bob", .{});
    const deny_eq = [_]policy_catalog.PolicySpec{spec("d", .deny, "owner = current_user()")};
    f.expect(!try decide(&deny_eq, session("alice", null), &alice_row), "DENY owner = current_user(): owner alice returned to alice", .{});
    f.expect(try decide(&deny_eq, session("bob", null), &alice_row), "DENY owner = current_user(): owner alice withheld from bob", .{});
    try f.check();
}

test "a DENY row policy withholds every row from a session with no user or no tenant" {
    var f: Failures = .{};
    const deny_user = [_]policy_catalog.PolicySpec{spec("d", .deny, "owner <> current_user()")};
    f.expect(!try decide(&deny_user, session(null, "acme"), &alice_row), "DENY owner <> current_user(): returned to a session with no user", .{});
    f.expect(!try decide(&deny_user, session("", "acme"), &alice_row), "DENY owner <> current_user(): returned to a session with an empty user", .{});

    for ([_][]const u8{ "tenant <> current_tenant()", "current_tenant() <> tenant" }) |src| {
        const deny_tenant = [_]policy_catalog.PolicySpec{spec("d", .deny, src)};
        f.expect(!try decide(&deny_tenant, session("alice", null), &alice_row), "DENY `{s}`: returned to a session with no tenant", .{src});
        f.expect(!try decide(&deny_tenant, session("alice", "acme"), &missing_row_tenant), "DENY `{s}`: row with no tenant returned", .{src});
        f.expect(try decide(&deny_tenant, session("alice", "acme"), &alice_row), "DENY `{s}`: same-tenant row withheld", .{src});
        f.expect(!try decide(&deny_tenant, session("alice", "globex"), &alice_row), "DENY `{s}`: other-tenant row returned", .{src});
    }
    try f.check();
}

const missing_row_tenant = TestRow{ .entries = &.{.{ "owner", .{ .string = "alice" } }} };

test "an unknown DENY still wins over a matching ALLOW; an unknown ALLOW does not match" {
    var f: Failures = .{};
    const both = [_]policy_catalog.PolicySpec{
        spec("a", .allow, "tenant = current_tenant()"),
        spec("d", .deny, "owner <> current_user()"),
    };
    for (unknown_rows, [_][]const u8{ "null", "missing", "non-string" }) |row, kind| {
        f.expect(!try decide(&both, session("alice", "acme"), row), "ALLOW tenant matched + DENY unknown ({s} owner): row returned", .{kind});
    }
    f.expect(try decide(&both, session("alice", "acme"), &alice_row), "ALLOW tenant matched + DENY known false: row withheld", .{});
    f.expect(!try decide(&both, session("bob", "acme"), &alice_row), "ALLOW tenant matched + DENY known true: row returned", .{});

    // ALLOW behaviour is unchanged: unknown does not match.
    const allow_only = [_]policy_catalog.PolicySpec{spec("a", .allow, "owner = current_user()")};
    for (unknown_rows) |row| {
        f.expect(!try decide(&allow_only, session("alice", "acme"), row), "ALLOW owner = current_user(): unknown owner returned", .{});
    }
    const allow_ne = [_]policy_catalog.PolicySpec{spec("a", .allow, "owner <> current_user()")};
    for (unknown_rows) |row| {
        f.expect(!try decide(&allow_ne, session("alice", "acme"), row), "ALLOW owner <> current_user(): unknown owner returned", .{});
    }
    f.expect(!try decide(&allow_only, session(null, "acme"), &alice_row), "ALLOW owner = current_user(): returned to a session with no user", .{});
    try f.check();
}

test "AND / OR propagate unknown with three-valued logic before the DENY decision" {
    var f: Failures = .{};
    // unknown AND true = unknown: the deny applies.
    const and_deny = [_]policy_catalog.PolicySpec{spec("d", .deny, "owner <> current_user() AND tenant = current_tenant()")};
    f.expect(!try decide(&and_deny, session("alice", "acme"), &missing_row), "DENY unknown AND true: row returned", .{});
    // unknown AND false = false: the deny does not apply.
    f.expect(try decide(&and_deny, session("alice", "globex"), &missing_row), "DENY unknown AND false: row withheld", .{});
    // Order does not matter.
    const and_deny_rev = [_]policy_catalog.PolicySpec{spec("d", .deny, "tenant = current_tenant() AND owner <> current_user()")};
    f.expect(!try decide(&and_deny_rev, session("alice", "acme"), &missing_row), "DENY true AND unknown: row returned", .{});
    f.expect(try decide(&and_deny_rev, session("alice", "globex"), &missing_row), "DENY false AND unknown: row withheld", .{});

    // unknown OR false = unknown: the deny applies; unknown OR true = true.
    const or_deny = [_]policy_catalog.PolicySpec{spec("d", .deny, "owner <> current_user() OR tenant <> current_tenant()")};
    f.expect(!try decide(&or_deny, session("alice", "acme"), &missing_row), "DENY unknown OR false: row returned", .{});
    f.expect(!try decide(&or_deny, session("alice", "globex"), &missing_row), "DENY unknown OR true: row returned", .{});
    f.expect(try decide(&or_deny, session("alice", "acme"), &alice_row), "DENY false OR false: row withheld", .{});
    // Parenthesised, mixed with a literal session predicate.
    const nested = [_]policy_catalog.PolicySpec{spec("d", .deny, "(owner <> current_user() AND current_user() = 'alice') OR tenant <> current_tenant()")};
    f.expect(!try decide(&nested, session("alice", "acme"), &null_row), "DENY (unknown AND true) OR false: row returned", .{});
    f.expect(try decide(&nested, session("bob", "acme"), &null_row), "DENY (unknown AND false) OR false: row withheld", .{});

    // ALLOW with OR: unknown OR true = true matches; unknown OR false does not.
    const or_allow = [_]policy_catalog.PolicySpec{spec("a", .allow, "owner = current_user() OR tenant = current_tenant()")};
    f.expect(try decide(&or_allow, session("alice", "acme"), &missing_row), "ALLOW unknown OR true: row withheld", .{});
    f.expect(!try decide(&or_allow, session("alice", "globex"), &missing_row), "ALLOW unknown OR false: row returned", .{});

    // The grammar has no NOT, so NOT(unknown) cannot turn into true.
    for ([_][]const u8{ "NOT owner = current_user()", "NOT (owner = current_user())" }) |src| {
        if (policy_expression.compileExpression(testing.allocator, src)) |ok| {
            var c = ok;
            c.deinit();
            f.expect(false, "`{s}` compiled", .{src});
        } else |_| {}
    }
    try f.check();
}

test "a statement-level decision (no row) still treats a row condition as not holding" {
    var compiled = try policy_expression.compileExpression(testing.allocator, "owner <> current_user()");
    defer compiled.deinit();
    try testing.expect(!policy_expression.evaluate(&compiled, .{ .current_user = "alice", .current_tenant = null, .current_graph = null, .resource_label = null }));
    try testing.expect(!policy_expression.evaluate(&compiled, .{ .current_user = "alice", .current_tenant = null, .current_graph = null, .resource_label = null, .row = missing_row.accessor() }));
}

// ---------------------------------------------------------------------------
// End-to-end: reads through the executor (scans, aggregates, hops)
// ---------------------------------------------------------------------------

const Session = struct {
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    ctx: execution.ExecutionContext,
    cat: policy_catalog.PolicyCatalog,

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

    fn as(self: *Session, user: []const u8) void {
        self.ctx.user = user;
        self.ctx.role = if (std.mem.eql(u8, user, "admin")) .Admin else .ReadWrite;
        self.ctx.principal = null;
    }

    fn seed(self: *Session) !void {
        self.as("admin");
        const nodes = [_][]const u8{
            "CREATE (:Doc {s: 'a1', owner: 'alice', tenant: 'acme'})",
            "CREATE (:Doc {s: 'b1', owner: 'bob', tenant: 'acme'})",
            "CREATE (:Doc {s: 'nul', owner: null, tenant: 'acme'})",
            "CREATE (:Doc {s: 'miss', tenant: 'acme'})",
            "CREATE (:Doc {s: 'int', owner: 42, tenant: 'acme'})",
            "CREATE (:G {s: 'ga', owner: 'alice', tenant: 'acme'})",
        };
        for (nodes) |q| try self.exec(q);
        const aa = self.arena.allocator();
        for ([_][]const u8{ "a1", "b1", "nul", "miss", "int" }) |t| {
            try self.exec(try std.fmt.allocPrint(aa, "MATCH (g:G {{s: 'ga'}}), (h {{s: '{s}'}}) CREATE (g)-[:R]->(h)", .{t}));
        }
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

/// `query`, run as the session's current user, returns exactly `want` (any
/// order), and was not served by the planned read (which applies no RLS).
fn expectRows(s: *Session, f: *Failures, query: []const u8, want: []const []const u8) !void {
    const aa = s.arena.allocator();
    planned_read_runtime.resetPathRowsMaterialized();
    var result = s.run(query) catch |err| {
        f.expect(false, "[{s}] {s}: error {s}", .{ s.ctx.user.?, query, @errorName(err) });
        return;
    };
    defer result.deinit(aa);
    const planned = planned_read_runtime.getPathRowsMaterialized();
    f.expect(planned == 0, "[{s}] {s}: served by the planned read ({d} materialized)", .{ s.ctx.user.?, query, planned });

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
    f.expect(same, "[{s}] {s}: expected {{{s}}}, got {{{s}}}", .{ s.ctx.user.?, query, try std.mem.join(aa, ",", exp), try std.mem.join(aa, ",", got) });
}

test "end to end: DENY owner <> current_user() withholds unknown-owner rows from scans, aggregates and hops" {
    harness.silenceEngineLogs();
    var s: Session = undefined;
    try s.init();
    defer s.deinit();
    try s.seed();
    try s.cat.addPolicyStrict(spec("not_mine", .deny, "owner <> current_user()"));
    var f: Failures = .{};

    s.as("alice");
    try expectRows(&s, &f, "MATCH (n:Doc) RETURN n.s", &.{"a1"});
    try expectRows(&s, &f, "MATCH (n) RETURN n.s", &.{ "a1", "ga" });
    try expectRows(&s, &f, "MATCH (n:Doc) RETURN count(n)", &.{"1"});
    try expectRows(&s, &f, "MATCH (n:Doc) WHERE n.owner IS NULL RETURN n.s", &.{});
    try expectRows(&s, &f, "MATCH (g:G)-[:R]->(h) RETURN h.s", &.{"a1"});

    s.as("bob");
    try expectRows(&s, &f, "MATCH (n:Doc) RETURN n.s", &.{"b1"});
    try expectRows(&s, &f, "MATCH (n:Doc) RETURN count(n)", &.{"1"});
    // The hub is alice's: the deny hides it from bob, and every hop from it.
    try expectRows(&s, &f, "MATCH (g:G)-[:R]->(h) RETURN h.s", &.{});

    // An admin session bypasses row conditions.
    s.as("admin");
    try expectRows(&s, &f, "MATCH (n:Doc) RETURN count(n)", &.{"5"});
    try f.check();
}

test "end to end: an unknown DENY beside a matching ALLOW still withholds the row; a session with no tenant sees nothing under a tenant DENY" {
    harness.silenceEngineLogs();
    var s: Session = undefined;
    try s.init();
    defer s.deinit();
    try s.seed();
    // An ALLOW that every seeded row matches for alice (no row's tenant is
    // named 'alice'), beside the DENY. A tenant-scoped session is not used
    // here: it would also engage the tenant filter, which is not under test.
    try s.cat.addPolicyStrict(spec("any_tenant", .allow, "tenant <> current_user()"));
    try s.cat.addPolicyStrict(spec("not_mine", .deny, "owner <> current_user()"));
    var f: Failures = .{};

    s.as("alice");
    try expectRows(&s, &f, "MATCH (n:Doc) RETURN n.s", &.{"a1"});
    try expectRows(&s, &f, "MATCH (n:Doc) RETURN count(n)", &.{"1"});
    try expectRows(&s, &f, "MATCH (g:G)-[:R]->(h) RETURN h.s", &.{"a1"});

    // Replace the policies with a tenant DENY: a session with no tenant has
    // an unknown comparison on every row, so every row is withheld.
    try s.cat.removePolicy("any_tenant");
    try s.cat.removePolicy("not_mine");
    try s.cat.addPolicyStrict(spec("other_tenant", .deny, "current_tenant() <> tenant"));
    try expectRows(&s, &f, "MATCH (n) RETURN n.s", &.{});
    try expectRows(&s, &f, "MATCH (n:Doc) RETURN count(n)", &.{"0"});
    try expectRows(&s, &f, "MATCH (g:G)-[:R]->(h) RETURN h.s", &.{});
    try f.check();
}
