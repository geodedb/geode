// SONNY-2757 regression: RLS/GPS policy hygiene (round-5 re-review P21, P25,
// P26, P29).
//
// (P21) The RLS compiler bounded parenthesis and NOT nesting (SONNY-2730) but
//       not the VM stack. Every pending left operand of a right-nested
//       operator holds a stack slot, so a right-nested OR 63 levels deep, or
//       `x OR row.b = (...)` from 32 levels, compiled and then overflowed the
//       64-slot VM on every row: every row denied, silently. The compiler now
//       simulates the stack and refuses such an expression.
// (P25) ALTER and DROP POLICY changed the catalog and only logged a failed
//       write-through, so a revocation came back at the next restart. They
//       now fail and leave the catalog as it was (`policy_ddl`).
// (P26) geode.auth.policy_create used the tolerant `addPolicy`: no length
//       limits, a condition that does not compile installed, nothing
//       persisted. It now makes the checks and the write-through of CREATE
//       POLICY; policy_delete persists its drop too.
// (P29) The security graph's loaders `@intCast` a stored operation and audit
//       level (and a permission's or grant's action, a role's priority, a
//       user's failed-login count) into narrow fields: a stored value out of
//       range aborted a safe build at startup, before the signature check. A
//       value out of range now marks the record tampered.
//
// CANARY: REQ=REQ-SONNY-2757-POLICY-HYGIENE; FEATURE="GPS Policy Persistence"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2757_policy_hygiene.zig; OWNER=security; UPDATED=2026-09-26

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const rls = @import("rls");
const auth_graph_manager = @import("auth_graph_manager");
const policy_persistence = @import("policy_persistence");

const execution = geode.execution;
const graph_store = geode.graph_store;
const policy_catalog = geode.security.policy_catalog;
const user_mgmt = geode.user_management;
const RLSEngine = rls.RLSEngine;
const AuthGraphManager = auth_graph_manager.AuthGraphManager;

// ---------------------------------------------------------------------------
// P21: the compiler bounds the VM stack.
// ---------------------------------------------------------------------------

fn policyWith(expr: []const u8) RLSEngine.Policy {
    return .{
        .id = 2757,
        .name = "deep",
        .description = "SONNY-2757",
        .graph = "g",
        .table = "T",
        .operation = .all,
        .permissive = false,
        .roles = &.{},
        .using_expr = .{ .raw = expr, .parsed = null, .compiled = null, .parameters = &.{} },
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

/// `row.a = 1 OR (row.a = 1 OR (... row.a = 1 ...))`, `levels` parentheses.
fn rightNestedOr(aa: std.mem.Allocator, levels: usize) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (0..levels) |_| try buf.appendSlice(aa, "row.a = 1 OR (");
    try buf.appendSlice(aa, "row.a = 1");
    for (0..levels) |_| try buf.append(aa, ')');
    return buf.toOwnedSlice(aa);
}

/// `row.a = 1 OR row.b = (row.a = 1 OR row.b = (... true ...))`.
fn nestedCompare(aa: std.mem.Allocator, levels: usize) ![]const u8 {
    var buf: std.ArrayList(u8) = .empty;
    for (0..levels) |_| try buf.appendSlice(aa, "row.a = 1 OR row.b = (");
    try buf.appendSlice(aa, "true");
    for (0..levels) |_| try buf.append(aa, ')');
    return buf.toOwnedSlice(aa);
}

const Outcome = enum { refused, evaluates, vm_error };

/// Install `expr` as a policy and evaluate it on one row.
fn outcomeOf(expr: []const u8) !Outcome {
    var engine = try RLSEngine.init(testing.allocator);
    // SONNY-2773: deinit frees the code createPolicy compiled.
    defer engine.deinit();
    engine.createPolicy(policyWith(expr)) catch |err| switch (err) {
        error.InvalidRlsExpression => return .refused,
        else => return err,
    };
    var row = std.StringHashMap(rls.Value).init(testing.allocator);
    defer row.deinit();
    try row.put("a", .{ .integer = 2 });
    try row.put("b", .{ .boolean = true });
    _ = engine.checkRowAccessByUsername(&row, .select, "bob", "g", "T") catch return .vm_error;
    return .evaluates;
}

test "SONNY-2757 (P21): no expression that compiles overflows the VM stack; deeper ones are refused" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    var failures: usize = 0;
    const Shape = struct { name: []const u8, make: *const fn (std.mem.Allocator, usize) anyerror![]const u8, max_levels: usize, deep: usize };
    const shapes = [_]Shape{
        .{ .name = "right-nested OR", .make = rightNestedOr, .max_levels = 64, .deep = 63 },
        .{ .name = "x OR row.b = (...)", .make = nestedCompare, .max_levels = 40, .deep = 32 },
    };
    for (shapes) |shape| {
        var refused_at: ?usize = null;
        for (1..shape.max_levels + 1) |levels| {
            const expr = try shape.make(aa, levels);
            switch (try outcomeOf(expr)) {
                .evaluates => {},
                .refused => if (refused_at == null) {
                    refused_at = levels;
                },
                .vm_error => {
                    std.debug.print("{s}, {d} levels: compiled, then the VM failed on the row\n", .{ shape.name, levels });
                    failures += 1;
                },
            }
        }
        // The shapes the review named are refused.
        if (try outcomeOf(try shape.make(aa, shape.deep)) != .refused) {
            std.debug.print("{s}, {d} levels: not refused at compile time\n", .{ shape.name, shape.deep });
            failures += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

// ---------------------------------------------------------------------------
// P25 / P26: policy DDL and the geode.auth.policy_* procedures are durable.
// ---------------------------------------------------------------------------

/// Write-through hooks that record what they were asked, and fail the kinds
/// of change named in `fail`.
const Hooks = struct {
    fail_persist: bool = false,
    fail_drop: bool = false,
    fail_alter: bool = false,
    persisted: usize = 0,
    dropped: usize = 0,
    altered: usize = 0,

    fn persist(ctx: *anyopaque, _: policy_catalog.PolicySpec) anyerror!void {
        const self: *Hooks = @ptrCast(@alignCast(ctx));
        if (self.fail_persist) return error.DiskFull;
        self.persisted += 1;
    }
    fn drop(ctx: *anyopaque, _: []const u8) anyerror!void {
        const self: *Hooks = @ptrCast(@alignCast(ctx));
        if (self.fail_drop) return error.DiskFull;
        self.dropped += 1;
    }
    fn alter(ctx: *anyopaque, _: []const u8, _: ?bool, _: ?[]const u8) anyerror!void {
        const self: *Hooks = @ptrCast(@alignCast(ctx));
        if (self.fail_alter) return error.DiskFull;
        self.altered += 1;
    }
    fn install(self: *Hooks) void {
        policy_catalog.setWriteThroughHooks(.{ .ctx = self, .persist = persist, .drop = drop, .alter = alter });
    }
};

const Session = struct {
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    ctx: execution.ExecutionContext,
    catalog: policy_catalog.PolicyCatalog,
    arena: std.heap.ArenaAllocator,
    auth_was: bool,

    fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
        var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
        const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
        var actual_len = cwd_len;
        while (actual_len > 0 and cwd_buf[actual_len - 1] == 0) : (actual_len -= 1) {}
        return std.fmt.allocPrint(allocator, "{s}/.zig-cache/tmp/{s}", .{ cwd_buf[0..actual_len], tmp_sub_path });
    }

    fn init(self: *Session) !void {
        const allocator = testing.allocator;
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        self.tmp = std.testing.tmpDir(.{});
        self.data_dir = try tmpDirRealpathAlloc(allocator, &self.tmp.sub_path);
        graph_store.setDataDirOverride(allocator, self.data_dir);
        _ = graph_store.getGlobalStore(allocator);
        const exec_catalog = try execution.ensureCatalogInstance(allocator);
        self.catalog = policy_catalog.PolicyCatalog.init(allocator);
        policy_catalog.setGlobalCatalog(&self.catalog);
        self.arena = std.heap.ArenaAllocator.init(allocator);
        self.ctx = .{ .catalog = exec_catalog, .role = .Admin, .user = "admin" };
        self.auth_was = user_mgmt.isAuthEnabled();
        user_mgmt.setAuthEnabled(false);
    }

    fn deinit(self: *Session) void {
        user_mgmt.setAuthEnabled(self.auth_was);
        policy_catalog.setWriteThroughHooks(null);
        policy_catalog.clearGlobalCatalog();
        self.catalog.deinit();
        self.arena.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(testing.allocator, null);
        testing.allocator.free(self.data_dir);
        self.tmp.cleanup();
    }

    fn exec(self: *Session, query: []const u8) !void {
        const aa = self.arena.allocator();
        var parsed = try geode.parseGql(query, aa);
        defer parsed.deinit();
        var r = try execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
        r.deinit(aa);
    }

    fn policy(self: *Session, name: []const u8) ?*const policy_catalog.Policy {
        for (self.catalog.listPolicies()) |*p| {
            if (std.mem.eql(u8, p.name, name)) return p;
        }
        return null;
    }
};

test "SONNY-2757 (P25): ALTER and DROP POLICY fail, and change nothing, when the write-through fails" {
    var s: Session = undefined;
    try s.init();
    defer s.deinit();
    var hooks: Hooks = .{};
    hooks.install();
    try s.exec("CREATE POLICY p1 ON GRAPH hr FOR READ");
    try testing.expectEqual(@as(usize, 1), hooks.persisted);

    hooks.fail_drop = true;
    hooks.fail_alter = true;
    try testing.expectError(error.DiskFull, s.exec("DROP POLICY p1"));
    try testing.expect(s.policy("p1") != null);
    try testing.expectError(error.DiskFull, s.exec("DROP POLICY IF EXISTS p1"));
    try testing.expect(s.policy("p1") != null);

    // A revocation that could not be stored is not in effect either.
    try testing.expectError(error.DiskFull, s.exec("ALTER POLICY p1 SET ENABLED false"));
    try testing.expect(s.policy("p1").?.enabled);
    try testing.expectError(error.DiskFull, s.exec("ALTER POLICY p1 RENAME TO p2"));
    try testing.expect(s.policy("p1") != null);
    try testing.expect(s.policy("p2") == null);
    // A rename and a disable together (the change the DDL parser does not
    // spell in one statement) are undone together.
    try testing.expectError(error.DiskFull, execution.policy_ddl.alter(&s.catalog, "p1", false, "p3"));
    try testing.expect(s.policy("p1").?.enabled);
    try testing.expect(s.policy("p3") == null);

    // The procedure's delete is as durable as DROP POLICY.
    try testing.expectError(error.DiskFull, s.exec("CALL geode.auth.policy_delete('p1')"));
    try testing.expect(s.policy("p1") != null);

    // When the write-through works, so do they.
    hooks.fail_drop = false;
    hooks.fail_alter = false;
    try s.exec("ALTER POLICY p1 SET ENABLED false");
    try testing.expect(!s.policy("p1").?.enabled);
    try s.exec("DROP POLICY p1");
    try testing.expect(s.policy("p1") == null);
    try testing.expectEqual(@as(usize, 1), hooks.altered);
    try testing.expectEqual(@as(usize, 1), hooks.dropped);
}

test "SONNY-2757 (P26): geode.auth.policy_create makes the checks and the write-through of CREATE POLICY" {
    var s: Session = undefined;
    try s.init();
    defer s.deinit();
    var hooks: Hooks = .{};
    hooks.install();

    // A name longer than __geode_security stores.
    const long_name = "n" ** 64;
    try testing.expectError(error.PolicyFieldTooLong, s.exec("CALL geode.auth.policy_create('" ++ long_name ++ "', 'hr', 'true')"));
    try testing.expect(s.policy(long_name) == null);
    // A condition that does not compile (it passes the character filter).
    try testing.expectError(error.UnsupportedPolicyExpression, s.exec("CALL geode.auth.policy_create('bad', 'hr', 'current_user() = ')"));
    try testing.expect(s.policy("bad") == null);

    // A good one is persisted.
    try s.exec("CALL geode.auth.policy_create('good', 'hr', 'true')");
    try testing.expect(s.policy("good") != null);
    try testing.expectEqual(@as(usize, 1), hooks.persisted);
    // A second one of the same name is refused.
    try testing.expectError(error.PolicyAlreadyExists, s.exec("CALL geode.auth.policy_create('good', 'hr', 'true')"));

    // One whose write-through fails is not created.
    hooks.fail_persist = true;
    try testing.expectError(error.DiskFull, s.exec("CALL geode.auth.policy_create('lost', 'hr', 'true')"));
    try testing.expect(s.policy("lost") == null);

    // policy_delete persists its drop.
    hooks.fail_persist = false;
    try s.exec("CALL geode.auth.policy_delete('good')");
    try testing.expect(s.policy("good") == null);
    try testing.expectEqual(@as(usize, 1), hooks.dropped);
    // Deleting a missing policy is still not an error.
    try s.exec("CALL geode.auth.policy_delete('never')");
}

// ---------------------------------------------------------------------------
// P29: a stored value out of range marks the record tampered.
// ---------------------------------------------------------------------------

const Prop = struct { key: []const u8, value: graph_store.PropertyValue };

fn plant(store: *graph_store.GraphStore, label: []const u8, props: []const Prop) !u64 {
    const labels = [_][]const u8{label};
    const node = try store.createNodeWithGraph(@constCast(&labels), graph_store.SECURITY_GRAPH_NAME);
    for (props) |p| try store.setNodeProperty(node, p.key, p.value);
    return node;
}

test "SONNY-2757 (P29): the security loaders treat an out-of-range stored value as tampering, not a crash" {
    const allocator = testing.allocator;
    var store = try graph_store.GraphStore.init(allocator);
    defer store.deinit();
    {
        var agm = try AuthGraphManager.init(allocator, &store);
        defer agm.deinit();
    }
    // A GPS policy with operation 300 and audit level 1000.
    _ = try plant(&store, "Policy", &.{
        .{ .key = "id", .value = .{ .Int = 91 } },
        .{ .key = "name", .value = .{ .String = "wide" } },
        .{ .key = "description", .value = .{ .String = "" } },
        .{ .key = "graph", .value = .{ .String = "*" } },
        .{ .key = "table", .value = .{ .String = "" } },
        .{ .key = "operation", .value = .{ .Int = 300 } },
        .{ .key = "permissive", .value = .{ .Bool = true } },
        .{ .key = "enabled", .value = .{ .Bool = true } },
        .{ .key = "using_clause", .value = .{ .String = "true" } },
        .{ .key = "audit_level", .value = .{ .Int = 1000 } },
        .{ .key = "created_by", .value = .{ .Int = 0 } },
        .{ .key = "kind", .value = .{ .String = "gps" } },
    });
    // A permission with action 999, a role with a priority past u32, a user
    // with 70000 failed logins, and a grant with action 300.
    _ = try plant(&store, "Permission", &.{
        .{ .key = "id", .value = .{ .Int = 92 } },
        .{ .key = "name", .value = .{ .String = "wide" } },
        .{ .key = "action", .value = .{ .Int = 999 } },
    });
    _ = try plant(&store, "Role", &.{
        .{ .key = "id", .value = .{ .Int = 93 } },
        .{ .key = "name", .value = .{ .String = "wide" } },
        .{ .key = "priority", .value = .{ .Int = 1 << 40 } },
    });
    _ = try plant(&store, "User", &.{
        .{ .key = "id", .value = .{ .Int = 94 } },
        .{ .key = "username", .value = .{ .String = "wide" } },
        .{ .key = "failed_login_attempts", .value = .{ .Int = 70000 } },
    });
    _ = try plant(&store, "GraphGrant", &.{
        .{ .key = "id", .value = .{ .Int = 95 } },
        .{ .key = "user_id", .value = .{ .Int = 94 } },
        .{ .key = "graph_name", .value = .{ .String = "hr" } },
        .{ .key = "action", .value = .{ .Int = 300 } },
    });

    // Loading the security graph used to abort here.
    var agm = try AuthGraphManager.init(allocator, &store);
    defer agm.deinit();

    // The policy is malformed: GPS loads nothing from it.
    const record = agm.storage.getPolicy(91) orelse return error.PolicyNotLoaded;
    try testing.expect(record.malformed);
    var cat = policy_catalog.PolicyCatalog.init(allocator);
    defer cat.deinit();
    try policy_persistence.hydrateCatalog(allocator, &agm, &cat);
    try testing.expectEqual(@as(usize, 0), cat.listPolicies().len);

    // The other records are not loaded.
    try testing.expect(agm.storage.permission_cache.get(92) == null);
    try testing.expect(agm.storage.getRole(93) == null);
    try testing.expect(agm.storage.getUser(94) == null);
    const grants = try agm.storage.listGraphGrants(allocator);
    defer allocator.free(grants);
    try testing.expectEqual(@as(usize, 0), grants.len);
    try testing.expect(!try agm.storage.revokeGraphGrant(94, "hr", 44));
}
