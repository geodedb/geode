// SONNY-3181 / SONNY-3189 regression: a long operator chain is refused by the
// parser or evaluated correctly; it never overflows a server thread.
//
// The expression grammar builds operator and member chains with loops, so
// `RETURN 1 + 1 + ... + 1` with N terms is an AST N deep, and the walkers over
// it recursed once per link:
// - before authorization, `query_traits.analyzeRequest` (containsEq on every
//   WHERE, isStoreFreeScalarExpr on RETURN items): an EXPLAIN RETURN chain of
//   100,000 terms (400 KB) and an OR chain of 400,000 crashed an 8 MiB thread
//   in ReleaseSafe, 20,000 terms one in Debug (SONNY-3189, review probe S1);
// - `gql.print.printExprWith` on each ORDER BY key (`buildOrderKeys`);
// - `eval.evalExpr`, whose Debug frame is tens of KiB: `RETURN 1 + ... + 1`
//   with 1,000 terms crashed a 16 MiB thread over gRPC, `RETURN - - ... 1`
//   120 deep an 8 MiB one (SONNY-3181).
//
// Now the parser counts the links of an expression and refuses more than
// `max_expr_links` (4096) with 42000, the walkers above follow chains with
// loops, and the evaluator guards its stack (54001 instead of an overflow).
//
// Each shape runs at 1,000 terms, just under the cap, 10,000, 100,000 and
// 1,000,000 terms, in RETURN, WHERE, ORDER BY, a property map, a UNION arm,
// an aggregate and under EXPLAIN, on an 8 MiB thread (the gRPC connection
// threads') and a 16 MiB one (the QUIC workers'), through the real gRPC
// handler in process, and over QUIC against a spawned server. Run the step in
// Debug and in ReleaseSafe (`-Doptimize=ReleaseSafe`): the frames differ
// several-fold.
//
// CANARY: REQ=REQ-SONNY-3181-EXPR-CHAIN-CAP; FEATURE="GQLParser"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3181_expr_chain_cap.zig; OWNER=parser; UPDATED=2026-09-27

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const geode = @import("geode");
const schema = @import("schema");
const grpc = @import("grpc_impl").impl;
const util = @import("proto_test_util.zig");
const fx = @import("sonny738_r12_grpc_fixture.zig");

const limit: usize = geode.gql.parser.max_expr_links;

const grpc_conn_stack = 8 * 1024 * 1024;
/// The largest request the QUIC part sends (see the probe in that test).
const quic_request_bytes_max = 512 * 1024;
const worker_stack = 16 * 1024 * 1024;
const stacks = [_]usize{ grpc_conn_stack, worker_stack };

/// What a shape's result is when it runs.
const Want = union(enum) {
    /// An integer: `int_base + int_per_rep * reps`.
    int: struct { base: i64, per_rep: i64 = 0 },
    boolean: bool,
    null_value,
    /// A string of `base + per_rep * reps` bytes.
    str_len: struct { base: usize, per_rep: usize },
    /// Ran; the value is not checked (EXPLAIN).
    ran,
    /// The value the same query with one repetition answers (`x + 0`).
    same_as_one_rep,
};

const Shape = struct {
    name: []const u8,
    head: []const u8,
    rep: []const u8,
    tail: []const u8 = "",
    /// Links the head and tail hold, and links per repetition.
    base_links: usize,
    links_per_rep: usize,
    want: Want,
};

/// Nodes (:C {v: 0}), (:C {v: 1}), (:C {v: 2}) in the session's graph.
const shapes = [_]Shape{
    .{ .name = "RETURN + chain", .head = "RETURN 1", .rep = " + 1", .tail = " AS x", .base_links = 0, .links_per_rep = 1, .want = .{ .int = .{ .base = 1, .per_rep = 1 } } },
    .{ .name = "RETURN AND chain", .head = "RETURN true", .rep = " AND true", .tail = " AS x", .base_links = 0, .links_per_rep = 1, .want = .{ .boolean = true } },
    .{ .name = "RETURN OR chain", .head = "RETURN false", .rep = " OR false", .tail = " OR true AS x", .base_links = 1, .links_per_rep = 1, .want = .{ .boolean = true } },
    .{ .name = "RETURN || chain", .head = "RETURN 'a'", .rep = " || 'a'", .tail = " AS x", .base_links = 0, .links_per_rep = 1, .want = .{ .str_len = .{ .base = 1, .per_rep = 1 } } },
    .{ .name = "RETURN member chain", .head = "WITH {a: 1} AS m RETURN m", .rep = ".a", .tail = " AS x", .base_links = 0, .links_per_rep = 1, .want = .null_value },
    .{ .name = "WHERE OR chain", .head = "MATCH (n:C) WHERE n.v = 0", .rep = " OR n.v = 1", .tail = " RETURN count(n) AS c", .base_links = 2, .links_per_rep = 3, .want = .{ .int = .{ .base = 2 } } },
    .{ .name = "WHERE AND chain", .head = "MATCH (n:C) WHERE n.v >= 0", .rep = " AND n.v >= 0", .tail = " RETURN count(n) AS c", .base_links = 2, .links_per_rep = 3, .want = .{ .int = .{ .base = 3 } } },
    .{ .name = "WHERE + chain", .head = "MATCH (n:C) WHERE n.v", .rep = " + 0", .tail = " = 1 RETURN count(n) AS c", .base_links = 2, .links_per_rep = 1, .want = .{ .int = .{ .base = 1 } } },
    .{ .name = "ORDER BY + chain", .head = "MATCH (n:C) RETURN n.v AS v ORDER BY n.v", .rep = " + 0", .base_links = 1, .links_per_rep = 1, .want = .{ .int = .{ .base = 0 } } },
    .{ .name = "aggregate + chain", .head = "MATCH (n:C) RETURN count(n)", .rep = " + 0", .tail = " AS c", .base_links = 1, .links_per_rep = 1, .want = .same_as_one_rep },
    .{ .name = "property map + chain", .head = "MATCH (n:C {v: 0", .rep = " + 0", .tail = "}) RETURN count(n) AS c", .base_links = 0, .links_per_rep = 1, .want = .{ .int = .{ .base = 1 } } },
    .{ .name = "UNION arm + chain", .head = "RETURN 1 AS x UNION RETURN 1", .rep = " + 0", .tail = " AS x", .base_links = 0, .links_per_rep = 1, .want = .{ .int = .{ .base = 1 } } },
    .{ .name = "HAVING + chain", .head = "MATCH (n:C) RETURN n.v AS v, count(n) AS c GROUP BY v HAVING c", .rep = " + 0", .tail = " > 0", .base_links = 2, .links_per_rep = 1, .want = .ran },
    .{ .name = "RETURN WHERE + chain", .head = "MATCH (n:C) RETURN n.v AS v WHERE v", .rep = " + 0", .tail = " = 1", .base_links = 2, .links_per_rep = 1, .want = .{ .int = .{ .base = 1 } } },
    .{ .name = "EXPLAIN RETURN + chain", .head = "EXPLAIN RETURN 1", .rep = " + 1", .base_links = 0, .links_per_rep = 1, .want = .ran },
    .{ .name = "EXPLAIN WHERE OR chain", .head = "EXPLAIN MATCH (n) WHERE n.v = 0", .rep = " OR n.v = 1", .tail = " RETURN n", .base_links = 2, .links_per_rep = 3, .want = .ran },
};

/// Repetitions to run a shape at: about 1,000 terms, just under the cap, and
/// 10,000, 100,000 and 1,000,000 terms. The larger sizes run for the first
/// shapes only: every run keeps its request in the fixture's arena.
fn repsFor(shape: Shape, which: usize) usize {
    return switch (which) {
        0 => 1000,
        1 => (limit - 8 - shape.base_links) / shape.links_per_rep,
        2 => 10_000,
        3 => 100_000,
        else => 1_000_000,
    };
}

fn monoMs() u64 {
    var ts: std.os.linux.timespec = undefined;
    _ = std.os.linux.clock_gettime(.MONOTONIC, &ts);
    return @as(u64, @intCast(ts.sec)) * std.time.ms_per_s + @as(u64, @intCast(ts.nsec)) / std.time.ns_per_ms;
}

fn build(allocator: std.mem.Allocator, head: []const u8, rep: []const u8, n: usize, tail: []const u8) ![]u8 {
    var q = std.ArrayList(u8).empty;
    errdefer q.deinit(allocator);
    try q.ensureTotalCapacity(allocator, head.len + rep.len * n + tail.len);
    q.appendSliceAssumeCapacity(head);
    var i: usize = 0;
    while (i < n) : (i += 1) q.appendSliceAssumeCapacity(rep);
    q.appendSliceAssumeCapacity(tail);
    return q.toOwnedSlice(allocator);
}

// ---------------------------------------------------------------------------
// The parser: the cap, exactly, and chains of every kind at every length,
// each parsed in a child process so a crash is reported as one.
// ---------------------------------------------------------------------------

const Outcome = enum { parsed, refused, crashed, failed };

const ParseJob = struct {
    query: []const u8,
    outcome: Outcome = .failed,

    fn run(self: *ParseJob) void {
        var out = geode.parseGqlOutcome(self.query, std.heap.smp_allocator, .{}) catch {
            self.outcome = .failed;
            return;
        };
        defer out.deinit();
        self.outcome = switch (out) {
            .Ok => .parsed,
            .Err => .refused,
        };
    }
};

fn parseInChild(query: []const u8, stack: usize) Outcome {
    const pid = std.c.fork();
    if (pid < 0) return .failed;
    if (pid == 0) {
        std.posix.setrlimit(.CORE, .{ .cur = 0, .max = 0 }) catch {};
        var job: ParseJob = .{ .query = query };
        const t = std.Thread.spawn(.{ .stack_size = stack }, ParseJob.run, .{&job}) catch std.c._exit(3);
        t.join();
        std.c._exit(switch (job.outcome) {
            .parsed => 0,
            .refused => 1,
            .crashed, .failed => 3,
        });
    }
    var status: c_int = 0;
    if (std.c.waitpid(pid, &status, 0) != pid) return .failed;
    const s: u32 = @bitCast(status);
    if (std.os.linux.W.IFSIGNALED(s)) return .crashed;
    return switch (std.os.linux.W.EXITSTATUS(s)) {
        0 => .parsed,
        1 => .refused,
        else => .failed,
    };
}

const ParserChain = struct { name: []const u8, head: []const u8, rep: []const u8, tail: []const u8 = "", base_links: usize = 0, links_per_rep: usize = 1 };

const parser_chains = [_]ParserChain{
    .{ .name = "+", .head = "RETURN 1", .rep = " + 1" },
    .{ .name = "OR", .head = "MATCH (n) WHERE n.v = 0", .rep = " OR n.v = 1", .tail = " RETURN n", .base_links = 2, .links_per_rep = 3 },
    .{ .name = "AND", .head = "RETURN true", .rep = " AND true" },
    .{ .name = "comparison", .head = "RETURN 1", .rep = " < 2", .links_per_rep = 2 },
    .{ .name = "^", .head = "RETURN 2", .rep = " ^ 1" },
    .{ .name = "||", .head = "RETURN 'a'", .rep = " || 'a'" },
    .{ .name = "member", .head = "RETURN x", .rep = ".a" },
    .{ .name = "index", .head = "RETURN x", .rep = "[0]" },
    .{ .name = "ORDER BY +", .head = "RETURN 1 AS x ORDER BY x", .rep = " + 1" },
    .{ .name = "EXPLAIN +", .head = "EXPLAIN RETURN 1", .rep = " + 1" },
};

test "SONNY-3189: the parser takes an expression of max_expr_links links and refuses one more (42000)" {
    const allocator = testing.allocator;
    // `1 + 1 ... + 1` with `limit` operators parses; one more does not.
    const at = try build(allocator, "RETURN 1", " + 1", limit, " AS x");
    defer allocator.free(at);
    try testing.expectEqual(Outcome.parsed, parseInChild(at, grpc_conn_stack));
    const over = try build(allocator, "RETURN 1", " + 1", limit + 1, " AS x");
    defer allocator.free(over);
    try testing.expectEqual(Outcome.refused, parseInChild(over, grpc_conn_stack));
    var out = try geode.parseGqlOutcome(over, allocator, .{});
    defer out.deinit();
    switch (out) {
        .Ok => return error.ExpectedRefusal,
        .Err => |e| {
            std.debug.print("{d} links: {s}\n", .{ limit + 1, e.msg });
            try testing.expect(std.mem.indexOf(u8, e.msg, "expression too long") != null);
        },
    }
    // A wide expression of short chains counts its links as one expression:
    // an IN list of literals has none.
    var in_list = std.ArrayList(u8).empty;
    defer in_list.deinit(allocator);
    try in_list.appendSlice(allocator, "MATCH (n) WHERE n.v IN [0");
    var i: usize = 0;
    while (i < 20_000) : (i += 1) try in_list.appendSlice(allocator, ", 1");
    try in_list.appendSlice(allocator, "] RETURN n");
    try testing.expectEqual(Outcome.parsed, parseInChild(in_list.items, grpc_conn_stack));
    // A WHERE that later MATCH clauses extend counts as one expression.
    var merged = std.ArrayList(u8).empty;
    defer merged.deinit(allocator);
    try merged.appendSlice(allocator, "MATCH (a) WHERE true");
    i = 0;
    while (i < limit + 8) : (i += 1) try merged.appendSlice(allocator, " MATCH (c) WHERE true");
    try merged.appendSlice(allocator, " RETURN a");
    try testing.expectEqual(Outcome.refused, parseInChild(merged.items, grpc_conn_stack));
}

test "SONNY-3189: chains of every operator and postfix kind parse up to the cap and are refused past it, never overflowing an 8 MiB or a 16 MiB thread" {
    const allocator = testing.allocator;
    var crashes: usize = 0;
    var wrong: usize = 0;
    for (stacks) |stack| {
        for (parser_chains) |c| {
            var line = std.ArrayList(u8).empty;
            defer line.deinit(allocator);
            const near = (limit - 8 - c.base_links) / c.links_per_rep;
            for ([_]usize{ 1000 / c.links_per_rep, near, 10_000, 100_000, 1_000_000 }) |n| {
                const q = try build(allocator, c.head, c.rep, n, c.tail);
                defer allocator.free(q);
                const o = parseInChild(q, stack);
                const links = c.base_links + c.links_per_rep * n;
                const want: Outcome = if (links <= limit) .parsed else .refused;
                if (o == .crashed) crashes += 1 else if (o != want) wrong += 1;
                try line.print(allocator, " {d}:{s}", .{ n, @tagName(o) });
            }
            std.debug.print("{d} MiB {s}:{s}\n", .{ stack >> 20, c.name, line.items });
        }
        // Unary chains are bounded by the nesting limit (SONNY-3133) as well.
        for ([_][]const u8{ "- ", "NOT ", "+ " }) |op| {
            for ([_]usize{ 120, 10_000 }) |n| {
                const q = try build(allocator, "RETURN ", op, n, "1");
                defer allocator.free(q);
                const o = parseInChild(q, stack);
                const want: Outcome = if (n <= 128) .parsed else .refused;
                if (o == .crashed) crashes += 1 else if (o != want) wrong += 1;
                std.debug.print("{d} MiB unary '{s}' x{d}: {s}\n", .{ stack >> 20, op, n, @tagName(o) });
            }
        }
    }
    try testing.expectEqual(@as(usize, 0), crashes);
    try testing.expectEqual(@as(usize, 0), wrong);
}

// ---------------------------------------------------------------------------
// The gRPC handler, in process, on the server's thread sizes.
// ---------------------------------------------------------------------------

const Run = struct {
    ga: std.mem.Allocator,
    session: []const u8,
    query: []const u8,
    /// The error code it was refused with, or null when it ran.
    code: ?[]const u8 = null,
    message: []const u8 = "",
    /// The first value of its first row, when it ran and returned rows.
    value: ?schema.Value = null,
    err: ?anyerror = null,

    fn go(self: *Run) void {
        self.run() catch |e| {
            self.err = e;
        };
    }

    fn run(self: *Run) !void {
        const resp = try fx.execute(self.ga, self.session, self.query);
        switch (resp.payload orelse return error.MissingPayload) {
            .@"error" => |e| {
                self.code = e.code;
                self.message = e.message;
                return;
            },
            .schema => {},
            else => return,
        }
        const req = try fx.encodeProto(self.ga, schema.PullRequest{ .session_id = self.session, .page_size = 8 });
        const pull = try fx.decodeProto(schema.PullResponse, self.ga, try grpc.handlePull(req, self.ga));
        const presp = pull.response orelse return error.MissingPayload;
        switch (presp.payload orelse return error.MissingPayload) {
            .page => |p| {
                if (p.rows.items.len > 0 and p.rows.items[0].values.items.len > 0) self.value = p.rows.items[0].values.items[0];
            },
            .@"error" => |e| {
                self.code = e.code;
                self.message = e.message;
            },
            else => return error.UnexpectedPayload,
        }
    }
};

/// Run `query` on a thread with a `stack`-byte stack. A Zig error out of the
/// handler (it answers errors as responses) is reported in `code` as
/// "zig:<name>", so the case fails with its name instead of ending the test.
fn runOn(stack: usize, ga: std.mem.Allocator, session: []const u8, query: []const u8) !Run {
    var r: Run = .{ .ga = ga, .session = session, .query = query };
    const t = try std.Thread.spawn(.{ .stack_size = stack }, Run.go, .{&r});
    t.join();
    if (r.err) |e| {
        r.code = try std.fmt.allocPrint(ga, "zig:{s}", .{@errorName(e)});
        r.err = null;
    }
    return r;
}

fn valueMatches(want: Want, reps: usize, v: ?schema.Value) bool {
    const kind = if (v) |val| val.kind else null;
    return switch (want) {
        .ran, .same_as_one_rep => true,
        .null_value => kind == null or kind.? == .null_val,
        .boolean => |b| if (kind) |k| (k == .bool_val and k.bool_val == b) else false,
        .int => |w| if (kind) |k| (k == .int_val and k.int_val.value == w.base + w.per_rep * @as(i64, @intCast(reps))) else false,
        .str_len => |w| if (kind) |k| (k == .string_val and k.string_val.value.len == w.base + w.per_rep * reps) else false,
    };
}

fn sameValue(a: ?schema.Value, b: ?schema.Value) bool {
    const ka = if (a) |v| v.kind else null;
    const kb = if (b) |v| v.kind else null;
    if (ka == null or kb == null) return ka == null and kb == null;
    if (std.meta.activeTag(ka.?) != std.meta.activeTag(kb.?)) return false;
    return switch (ka.?) {
        .null_val => true,
        .int_val => |x| x.value == kb.?.int_val.value,
        .bool_val => |x| x == kb.?.bool_val,
        else => false,
    };
}

fn seed(ga: std.mem.Allocator, s: []const u8) !void {
    try fx.expectRuns(ga, s, "CREATE (:C {v: 0})");
    try fx.expectRuns(ga, s, "CREATE (:C {v: 1})");
    try fx.expectRuns(ga, s, "CREATE (:C {v: 2})");
}

test "SONNY-3181: over gRPC every chain shape is evaluated correctly up to the cap and refused (42000) past it, on 8 MiB and 16 MiB threads; the session serves on" {
    const allocator = testing.allocator;
    const flag_was = geode.server_flags.getOrderKeysExpr();
    geode.server_flags.setOrderKeysExpr(true);
    defer geode.server_flags.setOrderKeysExpr(flag_was);
    var failures: usize = 0;
    for (shapes, 0..) |shape, si| {
        // A fixture per shape: every request stays in its arena.
        var f: fx.Fixture = undefined;
        try f.init();
        defer f.deinit();
        const ga = f.ga();
        const s = try f.session("chains");
        try seed(ga, s);
        const sizes: usize = if (si < 2) 5 else 4;
        // What the shape answers with one repetition, for `same_as_one_rep`.
        const one_q = try build(allocator, shape.head, shape.rep, 1, shape.tail);
        defer allocator.free(one_q);
        const one = try runOn(worker_stack, ga, s, one_q);
        std.debug.print("{s} reps=1 -> {s} value={any}\n", .{ shape.name, one.code orelse "ran", if (one.value) |v| v.kind else null });
        var which: usize = 0;
        while (which < sizes) : (which += 1) {
            const reps = repsFor(shape, which);
            const links = shape.base_links + shape.links_per_rep * reps;
            const q = try build(allocator, shape.head, shape.rep, reps, shape.tail);
            defer allocator.free(q);
            for (stacks) |stack| {
                const r = try runOn(stack, ga, s, q);
                const ok = if (links <= limit)
                    (r.code == null and valueMatches(shape.want, reps, r.value) and
                        (shape.want != .same_as_one_rep or sameValue(one.value, r.value))) or
                        // The grouped HAVING rewrite recurses per level; a
                        // Debug build may refuse the longest chains at its
                        // stack guard (54001) instead of overflowing.
                        (builtin.mode == .Debug and r.code != null and std.mem.eql(u8, r.code.?, "54001"))
                else
                    r.code != null and std.mem.eql(u8, r.code.?, "42000");
                const kind = if (r.value) |v| v.kind else null;
                const mark: []const u8 = if (ok) "" else "  <-- UNEXPECTED";
                std.debug.print("{s} reps={d} links={d} {d} MiB -> {s} {s} value={any}{s}\n", .{ shape.name, reps, links, stack >> 20, r.code orelse "ran", r.message[0..@min(r.message.len, 80)], kind, mark });
                if (!ok) failures += 1;
            }
        }
        // The session still serves.
        try fx.expectRuns(ga, s, "MATCH (n:C) RETURN count(n) AS c");
    }
    try testing.expectEqual(@as(usize, 0), failures);
}

test "SONNY-3181: over gRPC unary chains at the nesting limit evaluate, and nested lists and CASE are evaluated or refused cleanly (54001, 42000), never overflowing" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("unary");
    const allocator = testing.allocator;
    var failures: usize = 0;
    const Case = struct { head: []const u8, rep: []const u8, tail: []const u8, n: usize, want: ?Want };
    const cases = [_]Case{
        .{ .head = "RETURN ", .rep = "- ", .tail = "1 AS x", .n = 120, .want = .{ .int = .{ .base = 1 } } },
        .{ .head = "RETURN ", .rep = "- ", .tail = "1 AS x", .n = 121, .want = .{ .int = .{ .base = -1 } } },
        .{ .head = "RETURN ", .rep = "NOT ", .tail = "true AS x", .n = 120, .want = .{ .boolean = true } },
        .{ .head = "RETURN ", .rep = "- ", .tail = "1 AS x", .n = 10_000, .want = null },
        .{ .head = "RETURN ", .rep = "NOT ", .tail = "true AS x", .n = 10_000, .want = null },
    };
    for (cases) |c| {
        const q = try build(allocator, c.head, c.rep, c.n, c.tail);
        defer allocator.free(q);
        for (stacks) |stack| {
            const r = try runOn(stack, ga, s, q);
            const ok = if (c.want) |w| r.code == null and valueMatches(w, 0, r.value) else r.code != null and std.mem.eql(u8, r.code.?, "42000");
            std.debug.print("'{s}' x{d} {d} MiB -> {s} value={any}{s}\n", .{ c.rep, c.n, stack >> 20, r.code orelse "ran", if (r.value) |v| v.kind else null, if (ok) "" else "  <-- UNEXPECTED" });
            if (!ok) failures += 1;
        }
    }
    // Nesting the parser allows (128 levels) that is not a chain: a Debug
    // build may refuse it at the evaluator's stack guard (54001) or the
    // parser's (42000); nothing overflows.
    const Nest = struct { name: []const u8, open: []const u8, core: []const u8, close: []const u8 };
    const nests = [_]Nest{
        .{ .name = "list", .open = "[", .core = "1", .close = "]" },
        .{ .name = "CASE", .open = "CASE WHEN true THEN ", .core = "1", .close = " END" },
        .{ .name = "call", .open = "abs(", .core = "1", .close = ")" },
    };
    for (nests) |n| {
        for ([_]usize{ 60, 120 }) |d| {
            var q = std.ArrayList(u8).empty;
            defer q.deinit(allocator);
            try q.appendSlice(allocator, "RETURN ");
            var i: usize = 0;
            while (i < d) : (i += 1) try q.appendSlice(allocator, n.open);
            try q.appendSlice(allocator, n.core);
            i = 0;
            while (i < d) : (i += 1) try q.appendSlice(allocator, n.close);
            try q.appendSlice(allocator, " AS x");
            for (stacks) |stack| {
                const r = try runOn(stack, ga, s, q.items);
                const code = r.code orelse "ran";
                // A list nested this deep answers; this test's protobuf
                // decoder refuses a response nested past its depth limit
                // (InvalidInput). No overflow either way.
                const ok = std.mem.eql(u8, code, "ran") or std.mem.eql(u8, code, "54001") or std.mem.eql(u8, code, "42000") or
                    (std.mem.eql(u8, n.name, "list") and std.mem.eql(u8, code, "zig:InvalidInput"));
                std.debug.print("{s} nested {d} {d} MiB -> {s}{s}\n", .{ n.name, d, stack >> 20, code, if (ok) "" else "  <-- UNEXPECTED" });
                if (!ok) failures += 1;
            }
        }
    }
    try fx.expectRuns(ga, s, "RETURN 1 AS x");
    try testing.expectEqual(@as(usize, 0), failures);
}

// ---------------------------------------------------------------------------
// The QUIC handler, against a spawned server.
// ---------------------------------------------------------------------------

test "SONNY-3181: over QUIC chains are evaluated up to the cap and refused (42000) past it, and the server serves on" {
    const allocator = testing.allocator;
    const port = try util.getRandomPort();
    const io_fs = std.Io.Threaded.global_single_threaded.io();
    var dir_buf: [96]u8 = undefined;
    const data_dir = try std.fmt.bufPrint(&dir_buf, "/tmp/geode-sonny3181-{d}", .{port});
    std.Io.Dir.cwd().createDirPath(io_fs, data_dir) catch {};
    defer std.Io.Dir.cwd().deleteTree(io_fs, data_dir) catch {};
    const addr = try util.formatAddr(allocator, port);
    defer allocator.free(addr);
    var server = try util.spawnServer(
        allocator,
        &.{ "./zig-out/bin/geode", "serve", "--listen", addr, "--data-dir", data_dir },
        util.TestEnv.standard(),
    );
    defer server.deinit();
    try util.waitForServerReady(allocator, addr, 30000);

    var c = try util.QuicProtoClient.connect(allocator, addr);
    defer c.deinit();
    var h = try c.hello(allocator, util.defaultUsername(), util.defaultPassword());
    h.deinit(allocator);
    for ([_][]const u8{ "CREATE (:C {v: 0})", "CREATE (:C {v: 1})", "CREATE (:C {v: 2})" }) |q| {
        var r = try c.executeAndCollectWithTimeout(allocator, q, util.emptyParams(), 1000, 30);
        defer r.deinit(allocator);
        if (r.error_code) |code| {
            std.debug.print("{s}: {s}\n", .{ q, code });
            return error.QueryFailed;
        }
    }
    // Not asserted: how the transport takes a large request that parses to
    // a small AST (a string literal), for the report.
    for ([_]usize{ 256 * 1024, 1024 * 1024, 4 * 1024 * 1024 }) |n| {
        var q = std.ArrayList(u8).empty;
        defer q.deinit(allocator);
        try q.appendSlice(allocator, "RETURN '");
        try q.appendNTimes(allocator, 'a', n);
        try q.appendSlice(allocator, "' AS x");
        var pc = try util.QuicProtoClient.connect(allocator, addr);
        defer pc.deinit();
        var ph = try pc.hello(allocator, util.defaultUsername(), util.defaultPassword());
        ph.deinit(allocator);
        const t0 = monoMs();
        if (pc.executeAndCollectWithTimeout(allocator, q.items, util.emptyParams(), 10, 20)) |r0| {
            var r = r0;
            defer r.deinit(allocator);
            std.debug.print("QUIC probe: a {d}-byte string literal -> {s} in {d} ms\n", .{ n, r.error_code orelse "ran", monoMs() - t0 });
        } else |err| {
            std.debug.print("QUIC probe: a {d}-byte string literal -> {s} after {d} ms; server alive={}\n", .{ n, @errorName(err), monoMs() - t0, util.processAlive(server.child.id.?) });
        }
    }
    var failures: usize = 0;
    const picked = [_]usize{ 0, 2, 5, 8, 12, 13, 14, 15 };
    for (picked) |si| {
        const shape = shapes[si];
        var which: usize = 0;
        while (which < 5) : (which += 1) {
            if (which == 4 and si != 0) continue;
            const reps = repsFor(shape, which);
            const links = shape.base_links + shape.links_per_rep * reps;
            const q = try build(allocator, shape.head, shape.rep, reps, shape.tail);
            defer allocator.free(q);
            // A request of more than about 1 MB stalls in the QUIC transport
            // (the server stays up; see the probe above): those sizes run
            // through the gRPC handler only.
            if (q.len > quic_request_bytes_max) {
                std.debug.print("QUIC {s} reps={d} bytes={d}: skipped (request over {d} bytes)\n", .{ shape.name, reps, q.len, quic_request_bytes_max });
                continue;
            }
            // A connection per query: a transport stall on one cannot hide the
            // server's answer to the next.
            var qc = try util.QuicProtoClient.connect(allocator, addr);
            defer qc.deinit();
            var qh = try qc.hello(allocator, util.defaultUsername(), util.defaultPassword());
            qh.deinit(allocator);
            const t0 = monoMs();
            var r = qc.executeAndCollectWithTimeout(allocator, q, util.emptyParams(), 1000, 120) catch |err| {
                std.debug.print("QUIC {s} reps={d} bytes={d}: {s} after {d} ms; server alive={}  <-- UNEXPECTED\n", .{ shape.name, reps, q.len, @errorName(err), monoMs() - t0, util.processAlive(server.child.id.?) });
                return err;
            };
            defer r.deinit(allocator);
            const ok = if (links <= limit)
                r.error_code == null or (builtin.mode == .Debug and std.mem.eql(u8, r.error_code.?, "54001"))
            else
                r.error_code != null and std.mem.eql(u8, r.error_code.?, "42000");
            const msg: []const u8 = r.error_message orelse "";
            std.debug.print("QUIC {s} reps={d} links={d} bytes={d} -> {s} {s} in {d} ms{s}\n", .{ shape.name, reps, links, q.len, r.error_code orelse "ran", msg[0..@min(msg.len, 60)], monoMs() - t0, if (ok) "" else "  <-- UNEXPECTED" });
            if (!ok) failures += 1;
        }
    }
    for ([_]usize{ 120, 10_000 }) |n| {
        const q = try build(allocator, "RETURN ", "- ", n, "1 AS x");
        defer allocator.free(q);
        var r = try c.executeAndCollectWithTimeout(allocator, q, util.emptyParams(), 1000, 60);
        defer r.deinit(allocator);
        const ok = if (n <= 128) r.error_code == null else r.error_code != null;
        std.debug.print("QUIC unary minus x{d} -> {s}{s}\n", .{ n, r.error_code orelse "ran", if (ok) "" else "  <-- UNEXPECTED" });
        if (!ok) failures += 1;
    }
    // The server is alive and serves.
    var alive = try c.executeAndCollectWithTimeout(allocator, "MATCH (n:C) RETURN count(n) AS c", util.emptyParams(), 1000, 30);
    defer alive.deinit(allocator);
    try testing.expect(alive.error_code == null);
    try testing.expect(util.processAlive(server.child.id.?));
    try testing.expectEqual(@as(usize, 0), failures);
}
