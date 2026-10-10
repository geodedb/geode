// SONNY-3133 regression: every recursive entry of the GQL parser has a depth
// guard, so deeply nested input gets a clean parse error, never a stack
// overflow.
//
// The parser recurses on nested input, and only `parseOrExpr` counted the
// depth (`Parser.enterRecursion`, GAP-0333). PROFILE and EXPLAIN parse the
// statement they wrap with `parseStatement`, and so do a START TRANSACTION
// body, a parenthesized statement, EXPLAIN POLICY FOR and VALUES; WITH chains,
// CALL { } subqueries and FOR bodies recurse through `parseQuery`; NOT, unary
// minus and plus, and shortestPath() recurse on themselves. None of them
// counted. Parsing runs before authorization, so any authenticated principal
// could crash the server: a 408-byte `PROFILE EXPLAIN PROFILE ...` overflowed a
// 16 MiB worker stack at depth 50 in a Debug build (review probe R12-X11).
//
// Each shape below is parsed at depths up to 20000, in a child process on a
// 16 MiB thread (the QUIC workers' stack, GAP-0333) and on an 8 MiB one (the
// gRPC connection threads'), so a crash is reported as one rather than ending
// the test run. Operator and member-access chains, which the parser builds
// with loops, are as deep as the input is long; the parser's own walks of them
// (the ORDER BY checks) recursed once per operator. Run the step in Debug and
// in ReleaseSafe (`-Doptimize=ReleaseSafe`): the frames differ several-fold.
//
// CANARY: REQ=REQ-SONNY-3133-PARSER-NESTING; FEATURE="GQLParser"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny3133_parser_nesting.zig; OWNER=parser; UPDATED=2026-09-27

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const fx = @import("sonny738_r12_grpc_fixture.zig");

/// The stack sizes the server parses on: the QUIC workers' (GAP-0333) and
/// the gRPC connection threads' (grpc_zig's default).
const worker_stack = 16 * 1024 * 1024;
const grpc_conn_stack = 8 * 1024 * 1024;
const stacks = [_]usize{ worker_stack, grpc_conn_stack };

const Shape = struct {
    name: []const u8,
    /// Before the nested part, repeated `depth` times, after it.
    head: []const u8 = "",
    open: []const u8,
    core: []const u8,
    close: []const u8 = "",
    tail: []const u8 = "",
};

const shapes = [_]Shape{
    // R12-X11: the wrappers.
    .{ .name = "PROFILE/EXPLAIN", .open = "PROFILE EXPLAIN ", .core = "RETURN 1" },
    .{ .name = "EXPLAIN POLICY FOR", .open = "EXPLAIN POLICY FOR ", .core = "MATCH (n) RETURN n" },
    .{ .name = "START TRANSACTION body", .open = "START TRANSACTION { ", .core = "RETURN 1", .close = " }" },
    .{ .name = "parenthesized statement", .open = "(", .core = "MATCH (n) RETURN n", .close = ")" },
    .{ .name = "VALUES continuation", .open = "VALUES (1) AS (a) ", .core = "RETURN 1" },
    // parseQuery.
    .{ .name = "WITH chain", .open = "WITH 1 AS a ", .core = "RETURN a" },
    .{ .name = "CALL subquery", .open = "CALL { ", .core = "RETURN 1 AS x", .close = " } RETURN x" },
    .{ .name = "FOR body", .head = "WITH 1 AS a ", .open = "FOR x IN [1] MATCH (n) WITH n ", .core = "RETURN 1" },
    // Self-recursive expressions and patterns.
    .{ .name = "NOT chain", .head = "RETURN ", .open = "NOT ", .core = "true" },
    .{ .name = "unary minus chain", .head = "RETURN ", .open = "- ", .core = "1" },
    .{ .name = "unary plus chain", .head = "RETURN ", .open = "+ ", .core = "1" },
    .{ .name = "shortestPath", .head = "MATCH ", .open = "p = shortestPath(", .core = "(a)-[*]-(b)", .close = ")", .tail = " RETURN p" },
    // Guarded by parseOrExpr (GAP-0333) and kept so.
    .{ .name = "parenthesized expression", .head = "RETURN ", .open = "(", .core = "1", .close = ")" },
    .{ .name = "list literal", .head = "RETURN ", .open = "[", .core = "1", .close = "]" },
    .{ .name = "map literal", .head = "RETURN ", .open = "{a: ", .core = "1", .close = "}" },
    .{ .name = "CASE", .head = "RETURN ", .open = "CASE WHEN true THEN ", .core = "1", .close = " END" },
    .{ .name = "EXISTS subquery", .head = "MATCH (n) WHERE ", .open = "EXISTS { MATCH (m) WHERE ", .core = "true", .close = " }", .tail = " RETURN n" },
    .{ .name = "COUNT subquery", .head = "RETURN ", .open = "COUNT { MATCH (m) WHERE ", .core = "true", .close = " }" },
    .{ .name = "list comprehension", .head = "RETURN ", .open = "[x IN ", .core = "[1]", .close = " | x]" },
    .{ .name = "node property map", .head = "MATCH (n {a: ", .open = "{a: ", .core = "1", .close = "}", .tail = "}) RETURN n" },
};

/// Operator and member-access chains: built by loops, they parse at any
/// length; nothing may overflow on them.
const chains = [_]Shape{
    .{ .name = "ORDER BY operator chain", .head = "RETURN 1 AS x ORDER BY 1", .open = " + 1", .core = "" },
    .{ .name = "ORDER BY member chain", .head = "RETURN 1 AS x ORDER BY x", .open = ".a", .core = "" },
    .{ .name = "WHERE OR chain", .head = "MATCH (n) WHERE n.v = 0", .open = " OR n.v = 1", .core = "", .tail = " RETURN n" },
    .{ .name = "RETURN power chain", .head = "RETURN 2", .open = " ^ 1", .core = "", .tail = " AS x" },
};

/// Statement nesting at its limit around 128 nested parentheses.
const combined = Shape{ .name = "8 statements around 128 parentheses", .open = "(", .core = "RETURN 1", .close = ")" };

fn build(allocator: std.mem.Allocator, shape: Shape, depth: usize) ![]u8 {
    var q = std.ArrayList(u8).empty;
    errdefer q.deinit(allocator);
    try q.appendSlice(allocator, shape.head);
    var i: usize = 0;
    while (i < depth) : (i += 1) try q.appendSlice(allocator, shape.open);
    try q.appendSlice(allocator, shape.core);
    i = 0;
    while (i < depth) : (i += 1) try q.appendSlice(allocator, shape.close);
    try q.appendSlice(allocator, shape.tail);
    return q.toOwnedSlice(allocator);
}

const Outcome = enum { parsed, refused, crashed, failed };

const ParseJob = struct {
    query: []const u8,
    outcome: Outcome = .failed,

    fn run(self: *ParseJob) void {
        var out = geode.parseGqlOutcome(self.query, std.heap.page_allocator, .{}) catch {
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

/// Parse `query` in a child process, on a thread with a `stack`-byte stack.
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

const depths = [_]usize{ 2, 8, 32, 64, 100, 128, 129, 200, 1000, 20000 };

test "SONNY-3133: no nesting of a statement, query, expression or pattern overflows a 16 MiB worker stack or an 8 MiB gRPC one: the parser refuses it cleanly; chains parse (R12-X11)" {
    const allocator = testing.allocator;
    var crashes: usize = 0;
    var failures: usize = 0;
    var deep_parsed: usize = 0;
    for (stacks) |stack| {
        for (shapes) |shape| {
            var line = std.ArrayList(u8).empty;
            defer line.deinit(allocator);
            for (depths) |d| {
                const q = try build(allocator, shape, d);
                defer allocator.free(q);
                const o = parseInChild(q, stack);
                switch (o) {
                    .crashed => crashes += 1,
                    .failed => failures += 1,
                    // Past the expression limit nothing parses.
                    .parsed => if (d > 129) {
                        deep_parsed += 1;
                    },
                    .refused => {},
                }
                const mark: []const u8 = switch (o) {
                    .parsed => "ok",
                    .refused => "err",
                    .crashed => "CRASH",
                    .failed => "FAIL",
                };
                try line.print(allocator, " {d}:{s}", .{ d, mark });
            }
            std.debug.print("{d} MiB {s}:{s}\n", .{ stack >> 20, shape.name, line.items });
        }
    }
    // Chains parse at any length; the combined nesting is refused.
    for (stacks) |stack| {
        for (chains) |shape| {
            var line = std.ArrayList(u8).empty;
            defer line.deinit(allocator);
            for ([_]usize{ 1000, 20000, 200000 }) |n| {
                const q = try build(allocator, shape, n);
                defer allocator.free(q);
                const o = parseInChild(q, stack);
                switch (o) {
                    .crashed => crashes += 1,
                    .failed => failures += 1,
                    .parsed, .refused => {},
                }
                try line.print(allocator, " {d}:{s}", .{ n, @tagName(o) });
            }
            std.debug.print("{d} MiB {s}:{s}\n", .{ stack >> 20, shape.name, line.items });
        }
        var q = std.ArrayList(u8).empty;
        defer q.deinit(allocator);
        var i: usize = 0;
        while (i < 3) : (i += 1) try q.appendSlice(allocator, "PROFILE EXPLAIN ");
        try q.appendSlice(allocator, "START TRANSACTION { (");
        const inner = try build(allocator, .{ .name = "", .head = "RETURN ", .open = "(", .core = "1", .close = ")" }, 128);
        defer allocator.free(inner);
        try q.appendSlice(allocator, inner);
        try q.appendSlice(allocator, ") }");
        const o = parseInChild(q.items, stack);
        std.debug.print("{d} MiB {s}: {s}\n", .{ stack >> 20, combined.name, @tagName(o) });
        switch (o) {
            .crashed => crashes += 1,
            .failed => failures += 1,
            .parsed, .refused => {},
        }
    }
    std.debug.print("crashes={d} failures={d} parsed past depth 129={d}\n", .{ crashes, failures, deep_parsed });
    try testing.expectEqual(@as(usize, 0), crashes);
    try testing.expectEqual(@as(usize, 0), failures);
    try testing.expectEqual(@as(usize, 0), deep_parsed);
}

test "SONNY-3133: ordinary nesting still parses: 128 parentheses (GAP-0333), a WITH chain, NOT and minus chains, PROFILE of a query and inside a transaction body, parenthesized set operations" {
    const allocator = testing.allocator;
    const Legit = struct { shape: Shape, depth: usize };
    const legit = [_]Legit{
        .{ .shape = shapes[12], .depth = 128 }, // parenthesized expression
        .{ .shape = shapes[13], .depth = 64 }, // list literal
        // SONNY-3244 (v0823 line): queries nest at most 10 deep
        // (`Parser.max_query_nesting`), so a WITH chain of 10 parts.
        .{ .shape = shapes[5], .depth = 10 }, // WITH chain
        .{ .shape = shapes[8], .depth = 32 }, // NOT chain
        .{ .shape = shapes[9], .depth = 32 }, // unary minus
        .{ .shape = shapes[0], .depth = 1 }, // PROFILE EXPLAIN
        .{ .shape = shapes[3], .depth = 4 }, // parenthesized statement
    };
    var refused: usize = 0;
    for (legit) |l| {
        const q = try build(allocator, l.shape, l.depth);
        defer allocator.free(q);
        const o = parseInChild(q, worker_stack);
        if (o != .parsed) {
            std.debug.print("{s} at depth {d}: {s}\n", .{ l.shape.name, l.depth, @tagName(o) });
            refused += 1;
        }
    }
    const plain = [_][]const u8{
        "PROFILE MATCH (n) RETURN n",
        "EXPLAIN MATCH (n) RETURN n",
        "START TRANSACTION { PROFILE CREATE (:X) }",
        "(RETURN 1 AS x UNION ALL RETURN 2 AS x) EXCEPT RETURN 2 AS x",
        "VALUES (1), (2) AS (a) RETURN a",
        "EXPLAIN POLICY FOR MATCH (n) RETURN n",
    };
    for (plain) |q| {
        const o = parseInChild(q, grpc_conn_stack);
        if (o != .parsed) {
            std.debug.print("{s}: {s}\n", .{ q, @tagName(o) });
            refused += 1;
        }
    }
    try testing.expectEqual(@as(usize, 0), refused);
}

// ---------------------------------------------------------------------------
// The gRPC handler, in process: R12-X11 as the review ran it.
// ---------------------------------------------------------------------------

const DeepRpc = struct {
    ga: std.mem.Allocator,
    session: []const u8,
    query: []const u8,
    code: ?[]const u8 = null,
    err: ?anyerror = null,

    fn run(self: *DeepRpc) void {
        self.code = fx.outcome(self.ga, self.session, self.query) catch |e| {
            self.err = e;
            return;
        };
    }
};

test "SONNY-3133: over gRPC a nested PROFILE/EXPLAIN bomb on a 16 MiB worker stack gets a clean error (42000) at every depth (R12-X11)" {
    var f: fx.Fixture = undefined;
    try f.init();
    defer f.deinit();
    const ga = f.ga();
    const s = try f.session("x11");
    const wrapper_depths = [_]usize{ 10, 25, 50, 100, 200, 400, 1000 };
    for (wrapper_depths) |d| {
        const q = try build(testing.allocator, shapes[0], d);
        defer testing.allocator.free(q);
        var rpc: DeepRpc = .{ .ga = ga, .session = s, .query = q };
        const t = try std.Thread.spawn(.{ .stack_size = worker_stack }, DeepRpc.run, .{&rpc});
        t.join();
        if (rpc.err) |e| return e;
        std.debug.print("PROFILE/EXPLAIN depth {d} -> {s}\n", .{ d, rpc.code orelse "ran" });
        try testing.expectEqualStrings("42000", rpc.code orelse "ran");
    }
    // The server still serves the session.
    try fx.expectRuns(ga, s, "PROFILE MATCH (n) RETURN n");
}
