// SONNY-2709 regression: RLS range policies fail closed, on nodes and edges.
//
// The expression VM's `<`, `<=`, `>`, `>=` compared through `compareValues`,
// which answered 0 ("equal") for a null or for two values of different types,
// so `<=` and `>=` held. Probe P10: under `level <= 3` on a node label and on a
// relationship type, rows whose `level` was missing or a string were returned
// with the level-1 row. A principal attribute is always a string (or null), so
// `level <= principal.attribute.clearance` over an integer `level` passed every
// row, for every user, with or without the attribute.
//
// Now a comparison of values that have no order (null, NaN, a boolean, a
// string against a number, ...) is UNKNOWN, which denies the row and stays
// UNKNOWN under NOT, AND and OR. A principal attribute compared with a number
// is parsed strictly as that number's type (an integer column needs an
// optional '-' and digits; a float column also accepts one '.' fraction);
// anything else, or no attribute at all, denies.
//
// CANARY: REQ=REQ-SONNY-2709-RLS-RANGE-FAIL-CLOSED; FEATURE="RLS Expression Wiring"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2709_rls_range_fail_closed.zig; OWNER=security; UPDATED=2026-09-25

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const rls = @import("rls");
const rls_types = @import("rls_types");
const user_attr_store = @import("user_attr_store");
const harness = @import("node_scan_stream_harness.zig");

const execution = geode.execution;
const graph_store = geode.graph_store;
const Value = geode.value_types.Value;

const Session = struct {
    arena: std.heap.ArenaAllocator,
    ctx: execution.ExecutionContext,
    engine: ?*rls.RLSEngine = null,
    next_policy_id: u64 = 27090,

    fn init() !Session {
        const allocator = testing.allocator;
        execution.initEvaluator();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        _ = graph_store.getGlobalStore(allocator);
        const catalog = try execution.ensureCatalogInstance(allocator);
        return .{ .arena = std.heap.ArenaAllocator.init(allocator), .ctx = .{ .catalog = catalog } };
    }

    fn deinit(self: *Session) void {
        if (self.engine) |engine| {
            rls_types.setGlobalExprRLSEngine(null);
            // `createPolicy` compiled every policy; the engine's deinit
            // leaves a policy's expressions to their owner.
            var it = engine.policies.iterator();
            while (it.next()) |entry| {
                for (entry.value_ptr.items) |policy| {
                    const e = policy.using_expr orelse continue;
                    const c = e.compiled orelse continue;
                    engine.allocator.free(c.bytecode);
                    engine.allocator.free(c.constants);
                    engine.allocator.free(c.jump_table);
                    engine.allocator.destroy(c);
                }
            }
            engine.deinit();
            testing.allocator.destroy(engine);
        }
        self.arena.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
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

    /// A restrictive expression policy `expr` on `table` (a node label or a
    /// relationship type), compiled by the engine from its text.
    fn addPolicy(self: *Session, table: []const u8, expr: []const u8) !void {
        const engine = self.engine orelse blk: {
            const e = try testing.allocator.create(rls.RLSEngine);
            e.* = rls.RLSEngine.init(testing.allocator) catch |err| {
                testing.allocator.destroy(e);
                return err;
            };
            self.engine = e;
            rls_types.setGlobalExprRLSEngine(@ptrCast(e));
            break :blk e;
        };
        self.next_policy_id += 1;
        try engine.createPolicy(.{
            .id = self.next_policy_id,
            .name = "sonny2709",
            .description = expr,
            .graph = graph_store.DEFAULT_GRAPH_NAME,
            .table = table,
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
        });
    }

    /// `query`'s rows as `user`, each rendered `a|b|…`, sorted.
    fn rowsAs(self: *Session, user: []const u8, query: []const u8) ![]const []const u8 {
        const aa = self.arena.allocator();
        const saved = self.ctx.user;
        defer self.ctx.user = saved;
        self.ctx.user = user;
        var result = try self.run(query);
        defer result.deinit(aa);
        const got = try aa.alloc([]const u8, result.rows.len);
        for (result.rows, got) |row, *g| {
            const cells = try aa.alloc([]const u8, row.len);
            for (row, cells) |cell, *c| c.* = try render(aa, cell);
            g.* = try std.mem.join(aa, "|", cells);
        }
        std.mem.sort([]const u8, got, {}, lessThan);
        return got;
    }
};

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn render(aa: std.mem.Allocator, v: Value) anyerror![]const u8 {
    return switch (v) {
        .Str, .Text => |s| s,
        .Int => |n| try std.fmt.allocPrint(aa, "{d}", .{n}),
        .Bool => |b| if (b) "true" else "false",
        .Null => "null",
        .List => |items| blk: {
            const parts = try aa.alloc([]const u8, items.len);
            for (items, parts) |item, *part| part.* = try render(aa, item);
            std.mem.sort([]const u8, parts, {}, lessThan);
            break :blk try std.fmt.allocPrint(aa, "[{s}]", .{try std.mem.join(aa, ",", parts)});
        },
        else => try std.fmt.allocPrint(aa, "<{s}>", .{@tagName(v)}),
    };
}

/// Collects every mismatch, so one run reports all of them.
const Failures = struct {
    lines: std.ArrayList([]const u8) = .empty,

    fn expectRows(self: *Failures, s: *Session, user: []const u8, query: []const u8, want: []const []const u8) !void {
        const aa = s.arena.allocator();
        const got = s.rowsAs(user, query) catch |err| {
            try self.lines.append(aa, try std.fmt.allocPrint(aa, "[{s}] {s}: error {s}", .{ user, query, @errorName(err) }));
            return;
        };
        const sorted = try aa.dupe([]const u8, want);
        std.mem.sort([]const u8, sorted, {}, lessThan);
        const same = got.len == sorted.len and for (got, sorted) |g, w| {
            if (!std.mem.eql(u8, g, w)) break false;
        } else true;
        if (!same) try self.lines.append(aa, try std.fmt.allocPrint(aa, "[{s}] {s}: expected {{{s}}}, got {{{s}}}", .{
            user,
            query,
            try std.mem.join(aa, ",", sorted),
            try std.mem.join(aa, ",", got),
        }));
    }

    fn check(self: *Failures) !void {
        if (self.lines.items.len == 0) return;
        for (self.lines.items) |l| std.debug.print("  {s}\n", .{l});
        return error.TestUnexpectedResult;
    }
};

/// g1 links, by `HOP`, to one `:Lv` node per shape of `level` (1, 9, missing,
/// a string, a boolean) and, by `LVL`, to a `:T` node over an edge of each
/// shape. The `:Cl` nodes and `CLR` edges repeat it for the attribute policy.
fn seed(s: *Session) !void {
    try s.exec("CREATE (:G {s: 'g1'})");
    const shapes = [_][]const u8{ "l1', level: 1", "l9', level: 9", "none'", "str', level: 'top'", "bool', level: true", "l2f', level: 2.5" };
    const aa = s.arena.allocator();
    for (shapes) |shape| {
        try s.exec(try std.fmt.allocPrint(aa, "MATCH (g:G {{s: 'g1'}}) CREATE (g)-[:HOP]->(:Lv {{s: 'n_{s}}})", .{shape}));
        try s.exec(try std.fmt.allocPrint(aa, "MATCH (g:G {{s: 'g1'}}) CREATE (g)-[:LVL {{x: 'e_{s}}}]->(:T)", .{shape}));
        try s.exec(try std.fmt.allocPrint(aa, "MATCH (g:G {{s: 'g1'}}) CREATE (g)-[:HOP]->(:Cl {{s: 'c_{s}}})", .{shape}));
        try s.exec(try std.fmt.allocPrint(aa, "MATCH (g:G {{s: 'g1'}}) CREATE (g)-[:CLR {{x: 'f_{s}}}]->(:T)", .{shape}));
    }
}

test "SONNY-2709: a range policy on a label and on a relationship type denies missing and mistyped values" {
    harness.silenceEngineLogs();
    var s = try Session.init();
    defer s.deinit();
    try seed(&s);
    try s.addPolicy("Lv", "row.level <= 3");
    try s.addPolicy("LVL", "row.level <= 3");

    var f: Failures = .{};
    const u = "alice2709";
    try f.expectRows(&s, u, "MATCH (n:Lv) RETURN n.s", &.{ "n_l1", "n_l2f" });
    try f.expectRows(&s, u, "MATCH (n:Lv) RETURN count(n)", &.{"2"});
    try f.expectRows(&s, u, "MATCH (g:G)-[:HOP]->(n:Lv) RETURN n.s", &.{ "n_l1", "n_l2f" });
    try f.expectRows(&s, u, "MATCH (g:G)-[r:LVL]->(t) RETURN r.x", &.{ "e_l1", "e_l2f" });
    try f.expectRows(&s, u, "MATCH (g:G)-[:LVL*1..1]->(t) RETURN count(t)", &.{"2"});
    try f.expectRows(&s, u, "MATCH (g:G) RETURN COUNT { (g)-[:LVL]->() } AS c", &.{"2"});
    try f.expectRows(&s, u, "MATCH (g:G) RETURN [(g)-[r:LVL]->(t) | r.x] AS xs", &.{"[e_l1,e_l2f]"});
    try f.check();
}

test "SONNY-2709: a range policy against a principal attribute admits only a strictly numeric attribute" {
    harness.silenceEngineLogs();
    var s = try Session.init();
    defer s.deinit();
    try seed(&s);
    try s.addPolicy("Cl", "row.level <= principal.attribute.clearance");
    try s.addPolicy("CLR", "row.level <= principal.attribute.clearance");
    try s.addPolicy("Lv", "NOT (row.level > principal.attribute.clearance)");

    const alloc = testing.allocator;
    try user_attr_store.setAttribute(alloc, "three2709", "clearance", "3");
    defer _ = user_attr_store.removeAttribute("three2709", "clearance", alloc);
    try user_attr_store.setAttribute(alloc, "word2709", "clearance", "high");
    defer _ = user_attr_store.removeAttribute("word2709", "clearance", alloc);
    try user_attr_store.setAttribute(alloc, "decimal2709", "clearance", "3.0");
    defer _ = user_attr_store.removeAttribute("decimal2709", "clearance", alloc);

    var f: Failures = .{};
    // "3" is 3: level 1 and 2.5 pass; 9, missing, a string and a boolean do not.
    try f.expectRows(&s, "three2709", "MATCH (n:Cl) RETURN n.s", &.{ "c_l1", "c_l2f" });
    try f.expectRows(&s, "three2709", "MATCH (g:G)-[r:CLR]->(t) RETURN r.x", &.{ "f_l1", "f_l2f" });
    try f.expectRows(&s, "three2709", "MATCH (g:G)-[:HOP]->(n:Cl) RETURN n.s", &.{ "c_l1", "c_l2f" });
    // Negating the comparison does not admit what it could not compare.
    try f.expectRows(&s, "three2709", "MATCH (n:Lv) RETURN n.s", &.{ "n_l1", "n_l2f" });
    // No attribute, or one that is not a number: nothing.
    for ([_][]const u8{ "nobody2709", "word2709" }) |user| {
        try f.expectRows(&s, user, "MATCH (n:Cl) RETURN n.s", &.{});
        try f.expectRows(&s, user, "MATCH (g:G)-[r:CLR]->(t) RETURN r.x", &.{});
        try f.expectRows(&s, user, "MATCH (g:G) RETURN COUNT { (g)-[:CLR]->() } AS c", &.{"0"});
        try f.expectRows(&s, user, "MATCH (n:Lv) RETURN n.s", &.{});
    }
    // "3.0" is not an integer: only the float row compares.
    try f.expectRows(&s, "decimal2709", "MATCH (n:Cl) RETURN n.s", &.{"c_l2f"});
    try f.expectRows(&s, "decimal2709", "MATCH (g:G)-[r:CLR]->(t) RETURN r.x", &.{"f_l2f"});
    try f.check();
}
