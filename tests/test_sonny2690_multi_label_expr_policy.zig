// SONNY-2690 regression: an expression RLS policy was applied to a node's
// FIRST label only.
//
// `passesRLSExprFilter` looked up the policies of `node.labels[0]` and nothing
// else, and a label with no policy allows the row (rls_core.zig). So a node
// whose policed label was not its first label escaped the policy: under a
// `:Doc` policy `cls <> 'secret'`, `(:Other:Doc {cls: 'secret'})` was
// returned by a scan of `:Doc`, of `:Other`, of every node, and by a hop.
//
// Now the policies of EVERY label on the node apply, and the node is visible
// only if none of them denies it. The fixture carries a policy on each of two
// labels, `:Doc` (`cls <> 'secret'`) and `:Other` (`tier <> 'x'`), and nodes
// with one or both labels in both orders:
//
//   denied by :Doc   : (:Other:Doc) od_secret, (:Doc:Other) do_secret, (:Doc) d_secret
//   denied by :Other : (:Other:Doc) od_tierx,  (:Doc:Other) do_tierx,  (:Other) o_x
//   visible          : (:Other:Doc) od_ok, (:Doc:Other) do_ok, (:Doc) d_ok,
//                      (:Other) o_ok, (:Plain) plain (no policy), (:G) g1
//
// Before the fix `od_secret` (first label `:Other`) and `do_tierx` (first
// label `:Doc`) leaked on every read. Each is checked under a label scan, an
// unlabeled scan, a hop, an aggregate, a variable-length hop and a pattern
// comprehension.
//
// CANARY: REQ=REQ-SONNY-2690-ALL-LABELS; FEATURE="RLS Expression Wiring"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny2690_multi_label_expr_policy.zig; OWNER=security; UPDATED=2026-09-25

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const rls = @import("rls");
const rls_types = @import("rls_types");
const harness = @import("node_scan_stream_harness.zig");

const execution = geode.execution;
const graph_store = geode.graph_store;
const planned_read_runtime = geode.planned_read_runtime;
const Value = geode.value_types.Value;

const session_user = "bob";

// `row.cls <> 'secret'`, the `:Doc` policy: load_row 0; push_const 1; neq; ret
const doc_constants = [_]rls.Value{ .{ .string = "cls" }, .{ .string = "secret" } };
// `row.tier <> 'x'`, the `:Other` policy.
const other_constants = [_]rls.Value{ .{ .string = "tier" }, .{ .string = "x" } };
const neq_bytecode = [_]u8{ 0x10, 0x00, 0x01, 0x01, 0x21, 0xFF };

const Session = struct {
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    ctx: execution.ExecutionContext,
    engine: ?*rls.RLSEngine = null,
    doc_compiled: rls.RLSEngine.CompiledExpression = .{ .bytecode = &neq_bytecode, .constants = &doc_constants, .jump_table = &.{} },
    other_compiled: rls.RLSEngine.CompiledExpression = .{ .bytecode = &neq_bytecode, .constants = &other_constants, .jump_table = &.{} },

    /// A persisted store, so an RLS read is served by the legacy executor
    /// only because the planned read declines it.
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
        if (graph_store.getGlobalAdapter() == null) return error.WrongDeployment;
        const catalog = try execution.ensureCatalogInstance(allocator);
        return .{ .arena = std.heap.ArenaAllocator.init(allocator), .tmp = tmp, .data_dir = data_dir, .ctx = .{ .catalog = catalog } };
    }

    fn deinit(self: *Session) void {
        if (self.engine) |engine| {
            rls_types.setGlobalExprRLSEngine(null);
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
        return execution.executeStatementWithContext(aa, parsed.program.statements[0], self.ctx);
    }

    fn exec(self: *Session, query: []const u8) !void {
        const prev = execution.pushActiveContext(&self.ctx);
        defer execution.popActiveContext(prev);
        var r = try self.run(query);
        r.deinit(self.arena.allocator());
    }

    fn seed(self: *Session) !void {
        try self.exec("CREATE (:G {s: 'g1'})");
        const nodes = [_][]const u8{
            "CREATE (:Other:Doc {s: 'od_secret', cls: 'secret', tier: 'y'})",
            "CREATE (:Doc:Other {s: 'do_secret', cls: 'secret', tier: 'y'})",
            "CREATE (:Doc {s: 'd_secret', cls: 'secret'})",
            "CREATE (:Other:Doc {s: 'od_tierx', cls: 'public', tier: 'x'})",
            "CREATE (:Doc:Other {s: 'do_tierx', cls: 'public', tier: 'x'})",
            "CREATE (:Other {s: 'o_x', tier: 'x'})",
            "CREATE (:Other:Doc {s: 'od_ok', cls: 'public', tier: 'y'})",
            "CREATE (:Doc:Other {s: 'do_ok', cls: 'public', tier: 'y'})",
            "CREATE (:Doc {s: 'd_ok', cls: 'public'})",
            "CREATE (:Other {s: 'o_ok', tier: 'y'})",
            "CREATE (:Plain {s: 'plain'})",
        };
        for (nodes) |q| try self.exec(q);
        const targets = [_][]const u8{ "od_secret", "do_secret", "d_secret", "od_tierx", "do_tierx", "o_x", "od_ok", "do_ok", "d_ok", "o_ok", "plain" };
        const aa = self.arena.allocator();
        for (targets) |t| {
            try self.exec(try std.fmt.allocPrint(aa, "MATCH (g:G {{s: 'g1'}}), (h {{s: '{s}'}}) CREATE (g)-[:R]->(h)", .{t}));
        }

        // Restrict the session: one expression policy per label.
        const engine = try testing.allocator.create(rls.RLSEngine);
        engine.* = rls.RLSEngine.init(testing.allocator) catch |err| {
            testing.allocator.destroy(engine);
            return err;
        };
        self.engine = engine;
        try engine.createPolicy(policy(2690, "doc_not_secret", "Doc", "cls <> 'secret'", &self.doc_compiled));
        try engine.createPolicy(policy(2691, "other_not_tier_x", "Other", "tier <> 'x'", &self.other_compiled));
        rls_types.setGlobalExprRLSEngine(@ptrCast(engine));
        self.ctx.user = session_user;
    }
};

fn policy(id: u64, name: []const u8, table: []const u8, raw: []const u8, compiled: *rls.RLSEngine.CompiledExpression) rls.RLSEngine.Policy {
    return .{
        .id = id,
        .name = name,
        .description = name,
        .graph = graph_store.DEFAULT_GRAPH_NAME,
        .table = table,
        .operation = .all,
        .permissive = false,
        .roles = &.{},
        .using_expr = .{ .raw = raw, .parsed = null, .compiled = compiled, .parameters = &.{} },
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

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn render(aa: std.mem.Allocator, v: Value) anyerror![]const u8 {
    return switch (v) {
        .Str, .Text => |s| s,
        .Int => |n| try std.fmt.allocPrint(aa, "{d}", .{n}),
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

const Failures = struct {
    items: std.ArrayList([]const u8) = .empty,

    fn add(self: *Failures, aa: std.mem.Allocator, comptime fmt: []const u8, args: anytype) !void {
        try self.items.append(aa, try std.fmt.allocPrint(aa, fmt, args));
    }
};

/// `query` returns exactly `want`, in any order, served by the legacy executor.
fn expectRows(s: *Session, f: *Failures, query: []const u8, want: []const []const u8) !void {
    const aa = s.arena.allocator();
    planned_read_runtime.resetPathRowsMaterialized();
    var result = s.run(query) catch |err| {
        try f.add(aa, "{s}: error {s}", .{ query, @errorName(err) });
        return;
    };
    defer result.deinit(aa);
    const planned = planned_read_runtime.getPathRowsMaterialized();
    if (planned != 0) try f.add(aa, "{s}: served by the planned read ({d} materialized)", .{ query, planned });

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
        const want_text = try std.mem.join(aa, ",", exp);
        const got_text = try std.mem.join(aa, ",", got);
        try f.add(aa, "{s}: expected {d} rows {{{s}}}, got {d} {{{s}}}", .{ query, exp.len, want_text, got.len, got_text });
    }
}

test "SONNY-2690: every label's expression policy applies, under a scan and under a hop, in both label orders" {
    harness.silenceEngineLogs();
    var s = try Session.init();
    defer s.deinit();
    try s.seed();
    var f: Failures = .{};

    // Scans.
    try expectRows(&s, &f, "MATCH (h:Doc) RETURN h.s", &.{ "d_ok", "do_ok", "od_ok" });
    try expectRows(&s, &f, "MATCH (h:Other) RETURN h.s", &.{ "do_ok", "o_ok", "od_ok" });
    try expectRows(&s, &f, "MATCH (h) RETURN h.s", &.{ "d_ok", "do_ok", "g1", "o_ok", "od_ok", "plain" });
    try expectRows(&s, &f, "MATCH (h:Doc) RETURN count(h)", &.{"3"});

    // Hops.
    try expectRows(&s, &f, "MATCH (g:G)-[:R]->(h) RETURN h.s", &.{ "d_ok", "do_ok", "o_ok", "od_ok", "plain" });
    try expectRows(&s, &f, "MATCH (g:G)-[:R]->(h) RETURN count(h)", &.{"5"});
    try expectRows(&s, &f, "MATCH (g:G)-[:R]->(h:Doc) RETURN h.s", &.{ "d_ok", "do_ok", "od_ok" });
    try expectRows(&s, &f, "MATCH (g:G)-[:R*1..1]->(h) RETURN h.s", &.{ "d_ok", "do_ok", "o_ok", "od_ok", "plain" });
    try expectRows(&s, &f, "MATCH (g:G) RETURN [(g)-[:R]->(h) | h.s] AS xs", &.{"[d_ok,do_ok,o_ok,od_ok,plain]"});

    if (f.items.items.len != 0) {
        std.debug.print("\n{d} failed check(s):\n", .{f.items.items.len});
        for (f.items.items) |msg| std.debug.print("  {s}\n", .{msg});
        return error.FirstLabelOnlyPolicy;
    }
}
