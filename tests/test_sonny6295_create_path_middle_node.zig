// SONNY-6295: a CREATE path with more than one hop created the node between
// two hops once PER HOP.
//
// The parser gives every hop its own copy of its endpoints: in
// `(a)-[:R]->(b)-[:S]->(c)` the second hop's left endpoint is a copy of the
// first hop's right endpoint. Every CREATE walker (`executeCreate`,
// `executeCreateQuery`, `executeInsert`, the per-row CREATE of MATCH ...
// CREATE and the cluster leader's GNC2 spec builder) resolved each hop's
// endpoints afresh, so an UNNAMED node between two hops was created twice
// and the two relationships attached to different nodes: after
// `CREATE (:P {k: K})-[:R]->(:Q {k: K})-[:S]->(:T {k: K})` for K = 0..3,
// `MATCH (b:Q)` found 8 nodes and the two-hop MATCH found no path. A named
// node between two hops was created once but its property map was written
// twice; a backward hop after the first (`(a)<-[:R]-(q)`) of MATCH ...
// CREATE and of a CREATE with a WITH, SET or ORDER BY stored the
// relationship forward.
//
// The oracle never relies on a multi-hop MATCH alone: every label's nodes
// are listed with their `k` (four nodes, each `k` once, so a duplicate shows
// as an extra row), and every relationship type is read as a single hop
// between labelled endpoints, which with unique `k` per label pins each
// relationship to its node. The multi-hop MATCH is checked as well.
//
// Every shape runs in the in-memory, persisted (warm and after a reload),
// tenant-scoped (another tenant writing the same shapes) and RLS-policy
// sessions, every statement on its own leak-checked allocator.
//
// CANARY: REQ=REQ-SONNY-6295-CREATE-PATH-MIDDLE-NODE; FEATURE="CreatePath"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6295_create_path_middle_node.zig; OWNER=engine; UPDATED=2026-11-11

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const rls_types = @import("rls_types");
const harness = @import("node_scan_stream_harness.zig");

const execution = geode.execution;
const graph_store = geode.graph_store;
const query_arena = geode.query_arena;
const Value = geode.value_types.Value;

const Mode = enum {
    /// No storage adapter: the legacy executor.
    in_memory,
    /// Persisted, no tenant, no policy; checked warm and after a reload.
    persisted,
    /// Persisted, session tenant `tenant_a`; `tenant_b` writes every shape too.
    tenant_scoped,
    /// Persisted, the user may not read `:Hidden`.
    rls_policy,
};

const modes = [_]Mode{ .in_memory, .persisted, .tenant_scoped, .rls_policy };

/// The value of K another tenant writes every shape with.
const other_tenant_k = "9";

const Params = struct { names: []const []const u8 = &.{}, values: []const Value = &.{} };

const Session = struct {
    mode: Mode,
    arena: std.heap.ArenaAllocator,
    tmp: std.testing.TmpDir,
    data_dir: []u8,
    ctx: execution.ExecutionContext,
    rls: ?*rls_types.RLSFilterEngine = null,

    fn init(mode: Mode) !Session {
        const allocator = testing.allocator;
        harness.silenceEngineLogs();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, null);
        var tmp = std.testing.tmpDir(.{});
        errdefer tmp.cleanup();
        const data_dir = try harness.tmpDirRealpathAlloc(allocator, &tmp.sub_path);
        errdefer allocator.free(data_dir);
        errdefer {
            execution.cleanupCatalogInstance();
            graph_store.deinitGlobalStore();
            graph_store.setDataDirOverride(allocator, null);
        }
        const persisted = mode != .in_memory;
        if (persisted) graph_store.setDataDirOverride(allocator, data_dir);
        _ = graph_store.getGlobalStore(allocator);
        if (persisted != (graph_store.getGlobalAdapter() != null)) return error.WrongDeployment;
        graph_store.setDataDirOverride(allocator, data_dir);
        defer if (!persisted) graph_store.setDataDirOverride(allocator, null);
        const catalog = try execution.ensureCatalogInstance(allocator);
        var s: Session = .{ .mode = mode, .arena = std.heap.ArenaAllocator.init(allocator), .tmp = tmp, .data_dir = data_dir, .ctx = .{ .catalog = catalog } };
        if (mode == .tenant_scoped) s.ctx.tenant_id = "tenant_a";
        if (mode == .rls_policy) {
            const engine = try allocator.create(rls_types.RLSFilterEngine);
            engine.* = rls_types.RLSFilterEngine.init(allocator);
            s.rls = engine;
            try engine.addDenyPolicy(graph_store.DEFAULT_GRAPH_NAME, "Hidden", "bob");
            rls_types.setGlobalRLSFilterEngine(engine);
            s.ctx.user = "bob";
        }
        return s;
    }

    fn deinit(self: *Session) void {
        if (self.rls) |engine| {
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

    /// Close the persisted store and open it again from disk.
    fn reload(self: *Session) !void {
        const allocator = testing.allocator;
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(allocator, self.data_dir);
        _ = graph_store.getGlobalStore(allocator);
        if (graph_store.getGlobalAdapter() == null) return error.WrongDeployment;
        self.ctx.catalog = try execution.ensureCatalogInstance(allocator);
    }

    /// One statement as the server runs it: the context installed, a query
    /// scratch arena on the thread, the result on `allocator`.
    fn runWith(self: *Session, allocator: std.mem.Allocator, tenant: ?[]const u8, query: []const u8, params: Params) !execution.ExecutionResult {
        var parsed = try geode.parseGql(query, self.arena.allocator());
        defer parsed.deinit();
        var ctx = self.ctx;
        ctx.tenant_id = tenant;
        ctx.query_param_names = params.names;
        ctx.query_param_values = params.values;
        const prev = execution.pushActiveContext(&ctx);
        defer execution.popActiveContext(prev);
        return execution.executeStatementWithContext(allocator, parsed.program.statements[0], ctx);
    }
};

fn lessThan(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

fn renderCell(aa: std.mem.Allocator, cell: Value) ![]const u8 {
    return switch (cell) {
        .Str, .Text => |s| try std.fmt.allocPrint(aa, "'{s}'", .{s}),
        .Int => |n| try std.fmt.allocPrint(aa, "{d}", .{n}),
        .Null => "null",
        else => try std.fmt.allocPrint(aa, "<{s}>", .{@tagName(cell)}),
    };
}

/// Every failed check, reported together.
const Failures = struct {
    items: std.ArrayList([]const u8) = .empty,

    fn add(self: *Failures, comptime fmt: []const u8, args: anytype) !void {
        try self.items.append(testing.allocator, try std.fmt.allocPrint(testing.allocator, fmt, args));
    }

    fn deinit(self: *Failures) void {
        for (self.items.items) |msg| testing.allocator.free(msg);
        self.items.deinit(testing.allocator);
    }

    fn check(self: *Failures, name: []const u8) !void {
        if (self.items.items.len == 0) return;
        std.debug.print("\n{s}: {d} failed check(s):\n", .{ name, self.items.items.len });
        for (self.items.items) |msg| std.debug.print("  {s}\n", .{msg});
        return error.CreatePathWrong;
    }
};

/// Run `query` on its own leak-checked allocator; the rows rendered, or null
/// (and a failure recorded) when it errs or leaks.
/// `refused` is the error the statement must fail with instead.
fn run(s: *Session, f: *Failures, phase: []const u8, tenant: ?[]const u8, query: []const u8, params: Params, refused: ?anyerror) !?[]const []const u8 {
    const aa = s.arena.allocator();
    var gpa: std.heap.DebugAllocator(.{}) = .init;
    var scratch = std.heap.ArenaAllocator.init(testing.allocator);
    defer scratch.deinit();
    const got: ?[]const []const u8 = blk: {
        const prev = query_arena.pushScratchAllocator(scratch.allocator());
        defer query_arena.popScratchAllocator(prev);
        var result = s.runWith(gpa.allocator(), tenant, query, params) catch |err| {
            const expected = if (refused) |want| want == err else false;
            if (!expected) try f.add("[{s} {s}] {s}: error {s}", .{ @tagName(s.mode), phase, query, @errorName(err) });
            break :blk null;
        };
        defer result.deinit(gpa.allocator());
        if (refused) |want| try f.add("[{s} {s}] {s}: expected error {s}, got a result", .{ @tagName(s.mode), phase, query, @errorName(want) });
        const rows = try aa.alloc([]const u8, result.rows.len);
        for (result.rows, rows) |row, *r| {
            const n = @min(row.len, result.columns.len);
            const cells = try aa.alloc([]const u8, n);
            for (row[0..n], cells) |cell, *t| t.* = try renderCell(aa, cell);
            r.* = try std.mem.join(aa, ", ", cells);
        }
        break :blk rows;
    };
    if (gpa.deinit() == .leak) try f.add("[{s} {s}] {s}: leaked memory", .{ @tagName(s.mode), phase, query });
    return got;
}

/// A read and the rows it must return, in any order.
const Check = struct { q: []const u8, want: []const []const u8 };

/// A CREATE shape: `writes` run in order for K = 0..3 (`#` is K), then every
/// check must hold.
const Shape = struct {
    name: []const u8,
    writes: []const []const u8,
    checks: []const Check,
    /// Every write must be refused with this error, writing nothing.
    refused: ?anyerror = null,
    /// The writes get `$ks`, the list `[K]`.
    list_param: bool = false,
};

const ks: []const []const u8 = &.{ "0", "1", "2", "3" };
const kk: []const []const u8 = &.{ "0, 0", "1, 1", "2, 2", "3, 3" };
const four: []const []const u8 = &.{"4"};

fn nodes(comptime label: []const u8) Check {
    return .{ .q = "MATCH (n:" ++ label ++ ") RETURN n.k", .want = ks };
}

/// The relationships of `rel` from `from` to `to`, by the endpoints' `k`.
fn hop(comptime from: []const u8, comptime rel: []const u8, comptime to: []const u8) Check {
    return .{ .q = "MATCH (a:" ++ from ++ ")-[:" ++ rel ++ "]->(b:" ++ to ++ ") RETURN a.k, b.k", .want = kk };
}

/// Every relationship of `rel`, whatever its endpoints.
fn rels(comptime rel: []const u8) Check {
    return .{ .q = "MATCH (x)-[r:" ++ rel ++ "]->(y) RETURN count(*)", .want = four };
}

const shapes = [_]Shape{
    .{
        .name = "one hop (control)",
        .writes = &.{"CREATE (:A1 {k: #})-[:R1]->(:B1 {k: #})"},
        .checks = &.{ nodes("A1"), nodes("B1"), hop("A1", "R1", "B1"), rels("R1") },
    },
    .{
        .name = "two hops, every node anonymous",
        .writes = &.{"CREATE (:P2 {k: #})-[:R2]->(:Q2 {k: #})-[:S2]->(:T2 {k: #})"},
        .checks = &.{
            nodes("P2"),
            nodes("Q2"),
            nodes("T2"),
            hop("P2", "R2", "Q2"),
            hop("Q2", "S2", "T2"),
            rels("R2"),
            rels("S2"),
            .{ .q = "MATCH (a:P2)-[:R2]->(b:Q2)-[:S2]->(c:T2) RETURN a.k, c.k", .want = kk },
        },
    },
    .{
        .name = "three hops, every node anonymous",
        .writes = &.{"CREATE (:P3 {k: #})-[:R3]->(:Q3 {k: #})-[:S3]->(:T3 {k: #})-[:U3]->(:V3 {k: #})"},
        .checks = &.{
            nodes("P3"),
            nodes("Q3"),
            nodes("T3"),
            nodes("V3"),
            hop("P3", "R3", "Q3"),
            hop("Q3", "S3", "T3"),
            hop("T3", "U3", "V3"),
            rels("R3"),
            rels("S3"),
            rels("U3"),
        },
    },
    .{
        .name = "two hops, the middle node named",
        .writes = &.{"CREATE (:P4 {k: #})-[:R4]->(q:Q4 {k: #})-[:S4]->(:T4 {k: #})"},
        .checks = &.{ nodes("P4"), nodes("Q4"), nodes("T4"), hop("P4", "R4", "Q4"), hop("Q4", "S4", "T4") },
    },
    .{
        .name = "the named middle node reused by a second path",
        .writes = &.{"CREATE (:P5 {k: #})-[:R5]->(q:Q5 {k: #})-[:S5]->(:T5 {k: #}), (q)-[:U5]->(:V5 {k: #})"},
        .checks = &.{ nodes("P5"), nodes("Q5"), nodes("T5"), nodes("V5"), hop("P5", "R5", "Q5"), hop("Q5", "S5", "T5"), hop("Q5", "U5", "V5") },
    },
    .{
        .name = "mixed directions",
        .writes = &.{"CREATE (:P6 {k: #})<-[:R6]-(:Q6 {k: #})-[:S6]->(:T6 {k: #})<-[:U6]-(:V6 {k: #})"},
        .checks = &.{
            nodes("P6"),
            nodes("Q6"),
            nodes("T6"),
            nodes("V6"),
            hop("Q6", "R6", "P6"),
            hop("Q6", "S6", "T6"),
            hop("V6", "U6", "T6"),
            .{ .q = "MATCH (a:P6)-[:R6]->(b) RETURN count(*)", .want = &.{"0"} },
        },
    },
    .{
        .name = "a node bound by MATCH in the middle",
        .writes = &.{ "CREATE (:Q7 {k: #})", "MATCH (q:Q7 {k: #}) CREATE (:P7 {k: #})-[:R7]->(q)-[:S7]->(:T7 {k: #})" },
        .checks = &.{ nodes("P7"), nodes("Q7"), nodes("T7"), hop("P7", "R7", "Q7"), hop("Q7", "S7", "T7") },
    },
    .{
        .name = "MATCH ... CREATE: an anonymous node between a bound start and a bound end",
        .writes = &.{ "CREATE (:P8 {k: #}), (:T8 {k: #})", "MATCH (p:P8 {k: #}), (t:T8 {k: #}) CREATE (p)-[:R8]->(:Q8 {k: #})-[:S8]->(t)" },
        .checks = &.{ nodes("P8"), nodes("Q8"), nodes("T8"), hop("P8", "R8", "Q8"), hop("Q8", "S8", "T8"), rels("R8"), rels("S8") },
    },
    .{
        .name = "MATCH ... CREATE: a fresh two-hop path from a bound node, a backward hop second",
        .writes = &.{ "CREATE (:P9 {k: #})", "MATCH (p:P9 {k: #}) CREATE (p)-[:R9]->(:Q9 {k: #})<-[:S9]-(:T9 {k: #})" },
        .checks = &.{ nodes("P9"), nodes("Q9"), nodes("T9"), hop("P9", "R9", "Q9"), hop("T9", "S9", "Q9"), rels("R9"), rels("S9") },
    },
    .{
        .name = "a cycle back to the first node",
        .writes = &.{"CREATE (a:P10 {k: #})-[:R10]->(:Q10 {k: #})-[:S10]->(a)"},
        .checks = &.{ nodes("P10"), nodes("Q10"), hop("P10", "R10", "Q10"), hop("Q10", "S10", "P10"), rels("S10") },
    },
    .{
        .name = "comma-separated paths sharing a variable",
        .writes = &.{"CREATE (a:P11 {k: #})-[:R11]->(:Q11 {k: #}), (a)-[:S11]->(:T11 {k: #})-[:U11]->(:V11 {k: #})"},
        .checks = &.{ nodes("P11"), nodes("Q11"), nodes("T11"), nodes("V11"), hop("P11", "R11", "Q11"), hop("P11", "S11", "T11"), hop("T11", "U11", "V11") },
    },
    .{
        .name = "inline properties, two labels on the middle node, relationship properties",
        .writes = &.{"CREATE (:P12 {k: #})-[:R12 {w: #}]->(:Q12:M12 {k: #, name: 'm'})-[:S12 {w: #}]->(:T12 {k: #})"},
        .checks = &.{
            nodes("P12"),
            nodes("Q12"),
            nodes("M12"),
            nodes("T12"),
            .{ .q = "MATCH (q:Q12:M12) RETURN q.k, q.name", .want = &.{ "0, 'm'", "1, 'm'", "2, 'm'", "3, 'm'" } },
            .{ .q = "MATCH (a:P12)-[r:R12]->(b:M12) RETURN r.w, b.k", .want = kk },
            .{ .q = "MATCH (b:Q12)-[r:S12]->(c:T12) RETURN r.w, c.k", .want = kk },
        },
    },
    .{
        .name = "CREATE ... SET (the query executor), a backward hop second",
        .writes = &.{"CREATE (a:P13 {k: #})-[:R13]->(:Q13 {k: #})<-[:S13]-(:T13 {k: #}) SET a.seen = 1"},
        .checks = &.{ .{ .q = "MATCH (n:P13) RETURN n.k, n.seen", .want = &.{ "0, 1", "1, 1", "2, 1", "3, 1" } }, nodes("Q13"), nodes("T13"), hop("P13", "R13", "Q13"), hop("T13", "S13", "Q13"), rels("R13"), rels("S13") },
    },
    .{
        .name = "INSERT",
        .writes = &.{"INSERT (:P14 {k: #})-[:R14]->(:Q14 {k: #})-[:S14]->(:T14 {k: #})"},
        .checks = &.{ nodes("P14"), nodes("Q14"), nodes("T14"), hop("P14", "R14", "Q14"), hop("Q14", "S14", "T14") },
    },
    .{
        .name = "MERGE of a two-hop path: refused before anything is written (SONNY-3111 allowlist)",
        .writes = &.{
            "MERGE (:P15 {k: #})-[:R15]->(:Q15 {k: #})-[:S15]->(:T15 {k: #})",
            "MERGE (:P15 {k: #})-[:R15]->(:Q15 {k: #})-[:S15]->(:T15 {k: #})",
        },
        .checks = &.{
            .{ .q = "MATCH (n:P15) RETURN count(*)", .want = &.{"0"} },
            .{ .q = "MATCH (n:Q15) RETURN count(*)", .want = &.{"0"} },
            .{ .q = "MATCH (n:T15) RETURN count(*)", .want = &.{"0"} },
        },
        .refused = error.WriteClauseNotApplied,
    },
    .{
        // The collection is a parameter: a literal list collection leaks
        // (`executeFor`, reported separately).
        .name = "FOR ... CREATE",
        .writes = &.{"FOR k IN $ks CREATE (:P16 {k: k})-[:R16]->(:Q16 {k: k})-[:S16]->(:T16 {k: k})"},
        .list_param = true,
        .checks = &.{ nodes("P16"), nodes("Q16"), nodes("T16"), hop("P16", "R16", "Q16"), hop("Q16", "S16", "T16") },
    },
    .{
        .name = "MATCH ... CREATE: a backward single hop",
        .writes = &.{ "CREATE (:P18 {k: #}), (:T18 {k: #})", "MATCH (p:P18 {k: #}), (t:T18 {k: #}) CREATE (p)<-[:R18]-(t)" },
        .checks = &.{
            hop("T18", "R18", "P18"),
            .{ .q = "MATCH (a:P18)-[:R18]->(b) RETURN count(*)", .want = &.{"0"} },
        },
    },
    .{
        .name = "CREATE ... SET (the query executor): a backward single hop",
        .writes = &.{"CREATE (a:P19 {k: #})<-[:R19]-(:T19 {k: #}) SET a.seen = 1"},
        .checks = &.{
            hop("T19", "R19", "P19"),
            .{ .q = "MATCH (a:P19)-[:R19]->(b) RETURN count(*)", .want = &.{"0"} },
        },
    },
    .{
        .name = "PROFILE CREATE",
        .writes = &.{"PROFILE CREATE (:P17 {k: #})-[:R17]->(:Q17 {k: #})-[:S17]->(:T17 {k: #})"},
        .checks = &.{ nodes("P17"), nodes("Q17"), nodes("T17"), hop("P17", "R17", "Q17"), hop("Q17", "S17", "T17") },
    },
};

fn writeParams(aa: std.mem.Allocator, shape: Shape, k: []const u8) !Params {
    if (!shape.list_param) return .{};
    const list = try aa.alloc(Value, 1);
    list[0] = .{ .Int = try std.fmt.parseInt(i64, k, 10) };
    const names = try aa.alloc([]const u8, 1);
    names[0] = "ks";
    const values = try aa.alloc(Value, 1);
    values[0] = .{ .List = list };
    return .{ .names = names, .values = values };
}

fn substitute(aa: std.mem.Allocator, template: []const u8, k: []const u8) ![]const u8 {
    return std.mem.replaceOwned(u8, aa, template, "#", k);
}

fn checkAll(s: *Session, f: *Failures, phase: []const u8, checks: []const Check) !void {
    const aa = s.arena.allocator();
    for (checks) |c| {
        const rows = (try run(s, f, phase, s.ctx.tenant_id, c.q, .{}, null)) orelse continue;
        const exp = try aa.dupe([]const u8, c.want);
        const got = try aa.dupe([]const u8, rows);
        std.mem.sort([]const u8, exp, {}, lessThan);
        std.mem.sort([]const u8, got, {}, lessThan);
        const same = exp.len == got.len and for (exp, got) |w, g| {
            if (!std.mem.eql(u8, w, g)) break false;
        } else true;
        if (!same) try f.add("[{s} {s}] {s}: expected {{{s}}}, got {{{s}}}", .{ @tagName(s.mode), phase, c.q, try std.mem.join(aa, " | ", exp), try std.mem.join(aa, " | ", got) });
    }
}

/// Every shape in a fresh session of every mode.
fn inEveryMode(name: []const u8, list: []const Shape) !void {
    var f: Failures = .{};
    defer f.deinit();
    for (modes) |mode| {
        var s = try Session.init(mode);
        defer s.deinit();
        const aa = s.arena.allocator();
        for (list) |shape| {
            if (mode == .tenant_scoped) {
                for (shape.writes) |w| _ = try run(&s, &f, "write tenant_b", "tenant_b", try substitute(aa, w, other_tenant_k), try writeParams(aa, shape, other_tenant_k), shape.refused);
            }
            for (ks) |k| {
                for (shape.writes) |w| _ = try run(&s, &f, "write", s.ctx.tenant_id, try substitute(aa, w, k), try writeParams(aa, shape, k), shape.refused);
            }
        }
        for (list) |shape| try checkAll(&s, &f, try std.fmt.allocPrint(aa, "{s}, warm", .{shape.name}), shape.checks);
        if (mode != .in_memory) {
            try s.reload();
            for (list) |shape| try checkAll(&s, &f, try std.fmt.allocPrint(aa, "{s}, reloaded", .{shape.name}), shape.checks);
        }
    }
    try f.check(name);
}

test "SONNY-6295: each node of a CREATE path is created once and every hop joins it" {
    try inEveryMode("create path shapes", &shapes);
}

test "SONNY-6295: the QUIC fast paths decline every multi-hop CREATE" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    for ([_][]const u8{
        "CREATE (:P {k: 1})-[:R]->(:Q {k: 1})-[:S]->(:T {k: 1})",
        "CREATE (:P {k: 1})-[:R]->(q:Q {k: 1})-[:S]->(:T {k: 1})",
        "MATCH (a:P {k: 1}), (b:T {k: 1}) CREATE (a)-[:R]->(:Q {k: 1})-[:S]->(b)",
        "MERGE (:P {k: 1})-[:R]->(:Q {k: 1})-[:S]->(:T {k: 1})",
    }) |q| {
        var parsed = try geode.parseGql(q, arena.allocator());
        defer parsed.deinit();
        try testing.expectEqual(geode.bulk_ingest.BulkPattern.none, geode.bulk_ingest.matchSingleStatement(&parsed.program));
    }
}

test "SONNY-6295: the cluster leader replicates one node between two hops" {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const aa = arena.allocator();
    const Expect = struct { q: []const u8, nodes: usize, edges: []const [2]u32 };
    for ([_]Expect{
        .{ .q = "CREATE (:P {k: 1})-[:R]->(:Q {k: 1})-[:S]->(:T {k: 1})", .nodes = 3, .edges = &.{ .{ 0, 1 }, .{ 1, 2 } } },
        .{ .q = "CREATE (:P {k: 1})-[:R]->(:Q {k: 1})-[:S]->(:T {k: 1})-[:U]->(:V {k: 1})", .nodes = 4, .edges = &.{ .{ 0, 1 }, .{ 1, 2 }, .{ 2, 3 } } },
        .{ .q = "CREATE (:P {k: 1})<-[:R]-(:Q {k: 1})-[:S]->(:T {k: 1})", .nodes = 3, .edges = &.{ .{ 1, 0 }, .{ 1, 2 } } },
        .{ .q = "CREATE (a:P {k: 1})-[:R]->(:Q {k: 1})-[:S]->(a)", .nodes = 2, .edges = &.{ .{ 0, 1 }, .{ 1, 0 } } },
    }) |e| {
        var parsed = try geode.parseGql(e.q, aa);
        defer parsed.deinit();
        const chain = parsed.program.statements[0].Create.pattern.chains[0];
        var node_specs: std.ArrayList(geode.distributed.cluster_replication.NodeSpec) = .empty;
        var edge_specs: std.ArrayList(geode.distributed.cluster_replication.EdgeSpec) = .empty;
        try execution.buildEdgeCreateSpecs(aa, chain, .{ .names = &.{}, .values = &.{}, .allocator = aa }, &node_specs, &edge_specs);
        testing.expectEqual(e.nodes, node_specs.items.len) catch |err| {
            std.debug.print("SONNY-6295 cluster spec `{s}`: {d} node specs\n", .{ e.q, node_specs.items.len });
            return err;
        };
        try testing.expectEqual(e.edges.len, edge_specs.items.len);
        for (e.edges, edge_specs.items) |want, got| {
            try testing.expectEqual(want[0], got.from.position);
            try testing.expectEqual(want[1], got.to.position);
        }
    }
}
