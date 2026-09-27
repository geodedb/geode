// SONNY-2710 regression: RLS policies combine as PostgreSQL's do.
//
// The expression engine combined the policies on a table as
// `any_permissive_allows or all_restrictive_allow` (rls_core.zig,
// checkRowAccess and checkRowAccessByUsername). So a table with permissive
// policies only never denied a row, and one passing permissive policy
// overrode a failing restrictive one. Now, per table (a node label, or an
// edge type):
//
//     visible  iff  (a permissive policy passes, or none applies and the
//                    default allows)
//                   AND every restrictive policy passes.
//
// The label-deny engines hold the same kinds of policy for a label: a deny
// entry is a restrictive policy that fails for its user, an allow entry a
// permissive one that passes (`rls_types.LabelPolicy`). The executor
// (rls_types) combines them with the expression policies of the same table;
// the transport post-filter (rls_filter) sees labels only, so there an allow
// entry hides nothing and cannot undo a deny.
//
// Covered: permissive-only deny, a restrictive veto over a passing
// permissive, mixed, restrictive-only and no policies; in the engine
// (both row checks) and through MATCH, for node rows and edge rows.
//
// CANARY: REQ=REQ-SONNY-2710-PG-POLICY-COMBINATION; FEATURE="RLS Expression Wiring"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2710_policy_combination.zig; OWNER=security; UPDATED=2026-09-26

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const rls = @import("rls");
const rls_types = @import("rls_types");
const auth = @import("geode_auth");
const rls_filter = @import("grpc_impl").rls_filter;
const harness = @import("node_scan_stream_harness.zig");

const execution = geode.execution;
const graph_store = geode.graph_store;
const Value = geode.value_types.Value;

const RLSEngine = rls.RLSEngine;

const session_user = "bob";

const PolicyDef = struct { permissive: bool, expr: []const u8 };

fn policyFor(id: u64, graph: []const u8, table: []const u8, def: PolicyDef, roles: []const auth.RoleId) RLSEngine.Policy {
    return .{
        .id = id,
        .name = "p",
        .description = "SONNY-2710",
        .graph = graph,
        .table = table,
        .operation = .all,
        .permissive = def.permissive,
        .roles = roles,
        .using_expr = .{ .raw = def.expr, .parsed = null, .compiled = null, .parameters = &.{} },
        .check_expr = null,
        .enabled = true,
        .created_at = 0,
        .updated_at = 0,
        .created_by = 0,
        .temporal = null,
        .data_classification = null,
        .audit_level = .none,
    };
}

/// Free the code `createPolicy` compiled; the engine's `deinit` leaves a
/// policy's expressions to its owner.
fn deinitEngine(engine: *RLSEngine) void {
    var it = engine.policies.iterator();
    while (it.next()) |entry| {
        for (entry.value_ptr.items) |policy| {
            if (policy.using_expr) |e| {
                if (e.compiled) |c| {
                    engine.allocator.free(c.bytecode);
                    engine.allocator.free(c.constants);
                    engine.allocator.free(c.jump_table);
                    engine.allocator.destroy(c);
                }
            }
        }
    }
    engine.deinit();
}

const role_user: auth.RoleId = 7;

fn engineWith(defs: []const PolicyDef) !RLSEngine {
    var engine = try RLSEngine.init(testing.allocator);
    errdefer deinitEngine(&engine);
    for (defs, 0..) |def, i| try engine.createPolicy(policyFor(2710 + i, "g", "Doc", def, &.{role_user}));
    return engine;
}

const Row = struct { team: []const u8, level: i64 };

fn rowOf(r: Row) !std.StringHashMap(rls.Value) {
    var row = std.StringHashMap(rls.Value).init(testing.allocator);
    errdefer row.deinit();
    try row.put("team", .{ .string = r.team });
    try row.put("level", .{ .integer = r.level });
    return row;
}

/// `checkRowAccessByUsername` (the executor's check).
fn seesByUsername(engine: *RLSEngine, r: Row) !bool {
    var row = try rowOf(r);
    defer row.deinit();
    return engine.checkRowAccessByUsername(&row, .select, session_user, "g", "Doc");
}

/// `checkRowAccess` (the SecurityContext check). Its per-user cache keeps a
/// denial for the table, so each row gets a fresh engine.
fn seesByContext(defs: []const PolicyDef, r: Row) !bool {
    var engine = try engineWith(defs);
    defer deinitEngine(&engine);
    var row = try rowOf(r);
    defer row.deinit();
    var user = auth.User{
        .id = 9,
        .username = session_user,
        .email = "bob@example.com",
        .password_hash = undefined,
        .created_at = 0,
        .updated_at = 0,
        .last_login = null,
        .is_active = true,
        .is_superuser = false,
        .mfa_enabled = false,
        .mfa_secret = null,
        .attributes = std.StringHashMap([]const u8).init(testing.allocator),
    };
    defer user.attributes.deinit();
    var permissions = std.ArrayList(auth.PermissionId).empty;
    defer permissions.deinit(testing.allocator);
    const role = auth.Role{
        .id = role_user,
        .name = "user",
        .description = "",
        .permissions = permissions,
        .created_at = 0,
        .is_system = false,
        .priority = 1,
        .parent_role = null,
    };
    var context = auth.SecurityContext{
        .user = &user,
        .roles = &[_]auth.Role{role},
        .session_attributes = std.StringHashMap([]const u8).init(testing.allocator),
        .request_attributes = std.StringHashMap([]const u8).init(testing.allocator),
        .environment = .{ .timestamp = 0, .ip_address = "127.0.0.1", .user_agent = "test", .location = null, .device_id = null },
    };
    defer {
        context.session_attributes.deinit();
        context.request_attributes.deinit();
    }
    return engine.checkRowAccess(&row, .select, &context, "g", "Doc");
}

const Case = struct { name: []const u8, policies: []const PolicyDef, row: Row, visible: bool };

const team_a = PolicyDef{ .permissive = true, .expr = "row.team = 'a'" };
const team_b = PolicyDef{ .permissive = true, .expr = "row.team = 'b'" };
const low_level = PolicyDef{ .permissive = false, .expr = "row.level < 3" };

const cases = [_]Case{
    // No policies: the default allows.
    .{ .name = "no policies", .policies = &.{}, .row = .{ .team = "c", .level = 9 }, .visible = true },
    // Permissive only: a row no permissive policy passes is hidden.
    .{ .name = "permissive only, none passes", .policies = &.{ team_a, team_b }, .row = .{ .team = "c", .level = 1 }, .visible = false },
    .{ .name = "permissive only, one passes", .policies = &.{ team_a, team_b }, .row = .{ .team = "b", .level = 9 }, .visible = true },
    // A failing restrictive policy vetoes a passing permissive one.
    .{ .name = "restrictive veto over a passing permissive", .policies = &.{ team_a, low_level }, .row = .{ .team = "a", .level = 5 }, .visible = false },
    // Mixed.
    .{ .name = "mixed, both pass", .policies = &.{ team_a, low_level }, .row = .{ .team = "a", .level = 1 }, .visible = true },
    .{ .name = "mixed, permissive fails", .policies = &.{ team_a, low_level }, .row = .{ .team = "c", .level = 1 }, .visible = false },
    // Restrictive only: every one must pass.
    .{ .name = "restrictive only, passes", .policies = &.{low_level}, .row = .{ .team = "c", .level = 1 }, .visible = true },
    .{ .name = "restrictive only, fails", .policies = &.{low_level}, .row = .{ .team = "c", .level = 5 }, .visible = false },
};

test "SONNY-2710: both engine row checks combine permissive and restrictive policies as PostgreSQL does" {
    var failures: usize = 0;
    for (cases) |c| {
        var engine = try engineWith(c.policies);
        defer deinitEngine(&engine);
        const by_username = try seesByUsername(&engine, c.row);
        const by_context = try seesByContext(c.policies, c.row);
        if (by_username != c.visible or by_context != c.visible) {
            std.debug.print("{s}: expected visible={}, checkRowAccessByUsername={}, checkRowAccess={}\n", .{ c.name, c.visible, by_username, by_context });
            failures += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

test "SONNY-2710: the transport post-filter's label entries: an allow entry hides nothing and cannot undo a deny" {
    var engine = rls_filter.RLSFilterEngine.init(testing.allocator);
    defer engine.deinit();
    try engine.addAllowPolicy("default", "Doc", session_user);
    try engine.addAllowPolicy("default", "Secret", session_user);
    try engine.addDenyPolicy("default", "Secret", session_user);

    var denied = try engine.snapshotDeniedLabels(testing.allocator, "default", session_user);
    defer rls_filter.RLSFilterEngine.freeDeniedLabels(&denied);
    try testing.expect(denied.contains("Secret"));
    try testing.expect(!denied.contains("Doc"));
    try testing.expectEqual(@as(usize, 1), denied.count());

    // Removing the deny leaves the allows, and they hide nothing.
    engine.removeDenyPolicy("default", "Secret", session_user);
    try testing.expectEqual(@as(usize, 2), engine.policyCount());
    try testing.expect(!engine.hasPoliciesForGraph("default"));
    engine.removeAllowPolicy("default", "Secret", session_user);
    engine.removeAllowPolicy("default", "Doc", session_user);
    try testing.expectEqual(@as(usize, 0), engine.policyCount());
}

test "SONNY-2710: the executor's label entries: a deny vetoes, an allow passes, and neither leaks across users" {
    var engine = rls_types.RLSFilterEngine.init(testing.allocator);
    defer engine.deinit();
    try engine.addAllowPolicy("default", "Doc", session_user);
    try engine.addDenyPolicy("default", "Secret", "");
    try engine.addAllowPolicy("default", "Secret", session_user);

    const doc = engine.labelEntries("default", "Doc", session_user);
    try testing.expect(doc.allowed and !doc.denied);
    const secret = engine.labelEntries("default", "Secret", session_user);
    try testing.expect(secret.allowed and secret.denied);
    const other = engine.labelEntries("default", "Doc", "alice");
    try testing.expect(!other.allowed and !other.denied);
    try testing.expect(engine.isLabelDenied("default", "Secret", "alice"));
    try testing.expect(!engine.isLabelDenied("default", "Doc", session_user));

    var snapshot = try engine.snapshotLabelPolicies(testing.allocator, "default", session_user);
    defer snapshot.deinit();
    try testing.expect(snapshot.entries("Doc").allowed);
    try testing.expect(snapshot.entries("Secret").denied);

    // `removeDenyPolicy` removes deny entries only.
    engine.removeDenyPolicy("default", "Doc", session_user);
    try testing.expect(engine.labelEntries("default", "Doc", session_user).allowed);
}

// ---------------------------------------------------------------------------
// Through MATCH: node rows and edge rows.
// ---------------------------------------------------------------------------

const Session = struct {
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    ctx: execution.ExecutionContext,
    expr_engine: ?*RLSEngine = null,
    label_engine: ?*rls_types.RLSFilterEngine = null,

    fn init() !Session {
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
        const catalog = try execution.ensureCatalogInstance(allocator);
        return .{ .arena = std.heap.ArenaAllocator.init(allocator), .tmp = tmp, .data_dir = data_dir, .ctx = .{ .catalog = catalog } };
    }

    fn deinit(self: *Session) void {
        if (self.expr_engine) |engine| {
            rls_types.setGlobalExprRLSEngine(null);
            deinitEngine(engine);
            testing.allocator.destroy(engine);
        }
        if (self.label_engine) |engine| {
            rls_types.setGlobalRLSFilterEngine(null);
            engine.deinit();
            testing.allocator.destroy(engine);
        }
        self.arena.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(testing.allocator, null);
        testing.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    fn run(self: *Session, query: []const u8) !execution.ExecutionResult {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        const prev = execution.pushActiveContext(&self.ctx);
        defer execution.popActiveContext(prev);
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    fn exec(self: *Session, query: []const u8) !void {
        var r = try self.run(query);
        r.deinit(self.arena.allocator());
    }

    /// Nodes :Doc (team, level), a :Plain node, and :SEES edges (w, k) from
    /// a :G node to each; then the session becomes bob with the policies.
    fn seed(self: *Session, label_entries: bool) !void {
        const writes = [_][]const u8{
            "CREATE (:G {s: 'g'})",
            "CREATE (:Doc {s: 'a1', team: 'a', level: 1})",
            "CREATE (:Doc {s: 'a5', team: 'a', level: 5})",
            "CREATE (:Doc {s: 'b2', team: 'b', level: 2})",
            "CREATE (:Doc {s: 'c1', team: 'c', level: 1})",
            "CREATE (:Plain {s: 'plain'})",
            "MATCH (g:G), (h {s: 'plain'}) CREATE (g)-[:SEES {s: 'e_w1_ky', w: 1, k: 'y'}]->(h)",
            "MATCH (g:G), (h {s: 'plain'}) CREATE (g)-[:SEES {s: 'e_w2_ky', w: 2, k: 'y'}]->(h)",
            "MATCH (g:G), (h {s: 'plain'}) CREATE (g)-[:SEES {s: 'e_w1_kx', w: 1, k: 'x'}]->(h)",
            "MATCH (g:G), (h {s: 'plain'}) CREATE (g)-[:OTHER {s: 'o1'}]->(h)",
        };
        for (writes) |q| try self.exec(q);

        const engine = try testing.allocator.create(RLSEngine);
        engine.* = RLSEngine.init(testing.allocator) catch |err| {
            testing.allocator.destroy(engine);
            return err;
        };
        self.expr_engine = engine;
        const d = graph_store.DEFAULT_GRAPH_NAME;
        // Node table :Doc: permissive team a, permissive team b, restrictive level < 3.
        try engine.createPolicy(policyFor(1, d, "Doc", team_a, &.{}));
        try engine.createPolicy(policyFor(2, d, "Doc", team_b, &.{}));
        try engine.createPolicy(policyFor(3, d, "Doc", low_level, &.{}));
        // Edge table :SEES: permissive w = 1, restrictive k <> 'x'.
        try engine.createPolicy(policyFor(4, d, "SEES", .{ .permissive = true, .expr = "row.w = 1" }, &.{}));
        try engine.createPolicy(policyFor(5, d, "SEES", .{ .permissive = false, .expr = "row.k <> 'x'" }, &.{}));
        rls_types.setGlobalExprRLSEngine(@ptrCast(engine));

        if (label_entries) {
            const labels = try testing.allocator.create(rls_types.RLSFilterEngine);
            labels.* = rls_types.RLSFilterEngine.init(testing.allocator);
            self.label_engine = labels;
            // An allow entry on :Doc passes for bob: a permissive policy.
            try labels.addAllowPolicy(d, "Doc", session_user);
            // An allow entry on :SEES, and a deny: the deny vetoes.
            try labels.addAllowPolicy(d, "SEES", session_user);
            try labels.addDenyPolicy(d, "OTHER", session_user);
            rls_types.setGlobalRLSFilterEngine(labels);
        }
        self.ctx.user = session_user;
    }
};

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// `query` returns exactly `want` (first column, any order); a mismatch is
/// printed and counted.
fn expectRows(s: *Session, failures: *usize, query: []const u8, want: []const []const u8) !void {
    const aa = s.arena.allocator();
    var result = s.run(query) catch |err| {
        std.debug.print("{s}: error {s}\n", .{ query, @errorName(err) });
        failures.* += 1;
        return;
    };
    defer result.deinit(aa);
    const got = try aa.alloc([]const u8, result.rows.len);
    for (result.rows, got) |row, *g| g.* = switch (row[0]) {
        .Str, .Text => |t| t,
        else => "<?>",
    };
    std.mem.sort([]const u8, got, {}, lessThan);
    const exp = try aa.dupe([]const u8, want);
    std.mem.sort([]const u8, exp, {}, lessThan);
    const same = got.len == exp.len and for (got, exp) |g, w| {
        if (!std.mem.eql(u8, g, w)) break false;
    } else true;
    if (!same) {
        std.debug.print("{s}: expected {{{s}}}, got {{{s}}}\n", .{ query, try std.mem.join(aa, ",", exp), try std.mem.join(aa, ",", got) });
        failures.* += 1;
    }
}

test "SONNY-2710: through MATCH, node rows and edge rows combine their policies as PostgreSQL does" {
    harness.silenceEngineLogs();
    var s = try Session.init();
    defer s.deinit();
    try s.seed(false);
    var failures: usize = 0;

    // :Doc: a1 (team a, level 1) and b2 (team b, level 2) pass a permissive
    // and the restrictive policy. a5 fails the restrictive one (a passing
    // permissive no longer overrides it). c1 passes no permissive policy.
    try expectRows(&s, &failures, "MATCH (d:Doc) RETURN d.s", &.{ "a1", "b2" });
    try expectRows(&s, &failures, "MATCH (d:Doc) WHERE d.level < 9 RETURN d.s", &.{ "a1", "b2" });
    // A table without policies is visible.
    try expectRows(&s, &failures, "MATCH (p:Plain) RETURN p.s", &.{"plain"});
    // :SEES: only w = 1 AND k <> 'x' passes. :OTHER has no policy.
    try expectRows(&s, &failures, "MATCH (:G)-[e:SEES]->() RETURN e.s", &.{"e_w1_ky"});
    try expectRows(&s, &failures, "MATCH (:G)-[e]->() RETURN e.s", &.{ "e_w1_ky", "o1" });
    try testing.expectEqual(@as(usize, 0), failures);
}

test "SONNY-2710: through MATCH, the executor's label entries join the table's policies" {
    harness.silenceEngineLogs();
    var s = try Session.init();
    defer s.deinit();
    try s.seed(true);
    var failures: usize = 0;

    // bob's allow entry on :Doc is a permissive policy that passes: c1 (no
    // permissive expression passes) is admitted, but a5 still fails the
    // restrictive policy.
    try expectRows(&s, &failures, "MATCH (d:Doc) RETURN d.s", &.{ "a1", "b2", "c1" });
    // On :SEES the allow entry admits e_w2_ky; the restrictive policy still
    // hides e_w1_kx. The deny entry on :OTHER hides o1.
    try expectRows(&s, &failures, "MATCH (:G)-[e]->() RETURN e.s", &.{ "e_w1_ky", "e_w2_ky" });
    try testing.expectEqual(@as(usize, 0), failures);
}
