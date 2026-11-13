// SONNY-6460 item 2: the ISO/IEC 39075:2024 FILTER statement.
//
// 14.6 <filter statement> ::= FILTER { <where clause> | <search condition> }
// (SR 2: `FILTER SC` is `FILTER WHERE SC`). It is a <primitive query
// statement> (14.3), so it may follow any simple query statement in a linear
// query: a MATCH, and a call query statement (14.5). Its result is the
// current working table filtered by the <where clause> (14.6 GR 1), which
// keeps a record only when the condition is True (16.13 GR 2.b); a search
// condition is satisfied only when True (19.1 GR 2), so False and Unknown
// (NULL) drop the record.
//
// Before: `CALL ... YIELD ... FILTER` was a syntax error (a WHERE after the
// YIELD, the Cypher form, is refused with 42000 since SONNY-6437 and named
// FILTER as the standard form Geode did not accept), and a MATCH took one
// FILTER only.
//
// The real parser and executor. No mocks.
//
// CANARY: REQ=REQ-SONNY-6460-FILTER-STATEMENT; FEATURE="FilterStatement"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6460_filter_statement.zig; OWNER=parser; UPDATED=2026-11-13

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const logging = @import("logging");

const graph_store = geode.graph_store;
const execution = geode.execution;
const index_manager = geode.index_manager;
const Value = geode.value_types.Value;

const Session = struct {
    arena: std.heap.ArenaAllocator,
    session: execution.SessionState,
    ctx: execution.ExecutionContext,

    fn init(self: *Session) !void {
        logging.init(.{ .level = .fatal });
        logging.setLevel(.fatal);
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(testing.allocator, null);
        _ = graph_store.getGlobalStore(testing.allocator);
        self.arena = std.heap.ArenaAllocator.init(testing.allocator);
        self.session = execution.SessionState.init(testing.allocator);
        self.ctx = .{ .catalog = try execution.ensureCatalogInstance(testing.allocator) };
        self.ctx.session_state = &self.session;
        // Labels A, B, C, D; D's node has no `v`.
        var r = try self.run("CREATE (:A {v: 1}), (:B {v: 2}), (:C {v: 3}), (:D)");
        r.deinit(self.arena.allocator());
    }

    fn deinit(self: *Session) void {
        self.session.deinit();
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
        self.arena.deinit();
    }

    fn run(self: *Session, query: []const u8) !execution.ExecutionResult {
        var parsed = try geode.parseGqlOptions(query, self.arena.allocator(), .{});
        defer parsed.deinit();
        return execution.executeStatementWithContext(self.arena.allocator(), parsed.program.statements[0], self.ctx);
    }

    /// `query`'s rows, each rendered as `a, b`, in order.
    fn rows(self: *Session, query: []const u8) ![]const []const u8 {
        const aa = self.arena.allocator();
        const res = self.run(query) catch |err| {
            std.debug.print("{s}: {s}\n", .{ query, @errorName(err) });
            return err;
        };
        const out = try aa.alloc([]const u8, res.rows.len);
        for (res.rows, out) |row, *o| {
            var line: std.ArrayList(u8) = .empty;
            for (row, 0..) |cell, i| {
                if (i > 0) try line.appendSlice(aa, ", ");
                switch (cell) {
                    .Str => |x| try line.appendSlice(aa, x),
                    .Int => |n| try line.print(aa, "{d}", .{n}),
                    .Null => try line.appendSlice(aa, "null"),
                    else => try line.print(aa, "<{s}>", .{@tagName(cell)}),
                }
            }
            o.* = line.items;
        }
        return out;
    }
};

fn expectRows(s: *Session, query: []const u8, want: []const []const u8) !void {
    const got = try s.rows(query);
    var ok = want.len == got.len;
    if (ok) for (want, got) |w, g| {
        if (!std.mem.eql(u8, w, g)) ok = false;
    };
    if (!ok) {
        std.debug.print("{s}\n  got", .{query});
        for (got) |g| std.debug.print(" [{s}]", .{g});
        std.debug.print("\n  expected", .{});
        for (want) |w| std.debug.print(" [{s}]", .{w});
        std.debug.print("\n", .{});
        return error.WrongRows;
    }
}

test "SONNY-6460 (2): FILTER after CALL ... YIELD keeps the rows whose condition is True" {
    var s: Session = undefined;
    try s.init();
    defer s.deinit();
    // FILTER <search condition> and FILTER WHERE <search condition> (14.6 SR 2).
    try expectRows(&s, "CALL db.labels() YIELD label FILTER label <> 'B' RETURN label ORDER BY label", &.{ "A", "C", "D" });
    try expectRows(&s, "CALL db.labels() YIELD label FILTER WHERE label = 'C' RETURN label", &.{"C"});
    // The YIELD's alias is the column's name.
    try expectRows(&s, "CALL db.labels() YIELD label AS l FILTER l = 'D' RETURN l", &.{"D"});
    // Consecutive filter statements: each filters the previous one's table.
    try expectRows(&s, "CALL db.labels() YIELD label FILTER label <> 'A' FILTER WHERE label <> 'D' RETURN label ORDER BY label", &.{ "B", "C" });
    // With no RETURN the filtered rows are the result.
    try expectRows(&s, "CALL db.labels() YIELD label FILTER label = 'A'", &.{"A"});
    // ORDER BY and the window apply after the filter.
    try expectRows(&s, "CALL db.labels() YIELD label FILTER label <> 'A' RETURN label ORDER BY label DESC LIMIT 2", &.{ "D", "C" });
}

test "SONNY-6460 (2): FILTER drops False and Unknown (19.1 GR 2)" {
    var s: Session = undefined;
    try s.init();
    defer s.deinit();
    try expectRows(&s, "CALL db.labels() YIELD label FILTER NULL RETURN label", &.{});
    try expectRows(&s, "CALL db.labels() YIELD label FILTER label = NULL RETURN label", &.{});
    // NOT Unknown is Unknown. (Unparenthesized: `NOT (ident = ...)` is
    // parsed as a graph pattern, a parser defect of its own.)
    try expectRows(&s, "CALL db.labels() YIELD label FILTER NOT label = NULL RETURN label", &.{});
    try expectRows(&s, "CALL db.labels() YIELD label FILTER false RETURN label", &.{});
    // Unknown OR True is True.
    try expectRows(&s, "CALL db.labels() YIELD label FILTER label = NULL OR label = 'B' RETURN label", &.{"B"});
    // Over MATCH: D's n.v is NULL, so n.v > 1 is Unknown for it.
    try expectRows(&s, "MATCH (n) FILTER n.v > 1 RETURN n.v ORDER BY n.v", &.{ "2", "3" });
    try expectRows(&s, "MATCH (n) FILTER NOT (n.v > 1) RETURN n.v", &.{"1"});
    try expectRows(&s, "MATCH (n) FILTER n.v IS NULL RETURN labels(n)[0]", &.{"D"});
}

test "SONNY-6460 (2): FILTER after MATCH, after a WHERE, and repeated" {
    var s: Session = undefined;
    try s.init();
    defer s.deinit();
    try expectRows(&s, "MATCH (n) FILTER WHERE n.v >= 2 RETURN n.v ORDER BY n.v", &.{ "2", "3" });
    try expectRows(&s, "MATCH (n) WHERE n.v IS NOT NULL FILTER n.v < 3 RETURN n.v ORDER BY n.v", &.{ "1", "2" });
    try expectRows(&s, "MATCH (n) FILTER n.v IS NOT NULL FILTER n.v <> 2 RETURN n.v ORDER BY n.v", &.{ "1", "3" });
}

test "SONNY-6460 (2): FILTER after MATCH ... CALL ... YIELD sees the MATCH variables and the yielded columns" {
    var s: Session = undefined;
    try s.init();
    defer s.deinit();
    try expectRows(&s, "MATCH (n:A) CALL db.labels() YIELD label FILTER label <> 'A' RETURN n.v, label ORDER BY label", &.{ "1, B", "1, C", "1, D" });
    try expectRows(&s, "MATCH (n) CALL db.labels() YIELD label FILTER n.v = 2 AND label = 'C' RETURN n.v, label", &.{"2, C"});
    // Unknown (n.v of D is NULL) drops the row.
    try expectRows(&s, "MATCH (n) CALL db.labels() YIELD label FILTER n.v > 2 AND label = 'A' RETURN n.v, label", &.{"3, A"});
}

test "SONNY-6460 (2): FILTER conditions read the statement's parameters" {
    var s: Session = undefined;
    try s.init();
    defer s.deinit();
    const names = [_][]const u8{"want"};
    const values = [_]Value{.{ .Str = "B" }};
    s.ctx.query_param_names = &names;
    s.ctx.query_param_values = &values;
    try expectRows(&s, "CALL db.labels() YIELD label FILTER label = $want RETURN label", &.{"B"});
}

test "SONNY-6460 (2): a WHERE after YIELD is still refused (42000), naming the FILTER form" {
    const queries = [_][]const u8{
        "CALL db.labels() YIELD label WHERE label <> 'X' RETURN label",
        "MATCH (n) CALL db.labels() YIELD label WHERE label <> 'X' RETURN n, label",
    };
    for (queries) |q| {
        var outcome = try geode.parseGqlOutcome(q, testing.allocator, .{});
        defer outcome.deinit();
        switch (outcome) {
            .Ok => return error.WhereAfterYieldParsed,
            .Err => |e| {
                try testing.expectEqualStrings("42000", e.code);
                try testing.expect(std.mem.indexOf(u8, e.msg, "FILTER [WHERE]") != null);
            },
        }
    }
}

test "SONNY-6460 (2): the FILTER statement forms parse (14.6)" {
    const accepted = [_][]const u8{
        "CALL db.labels() YIELD label FILTER label = 'A' RETURN label",
        "CALL db.labels() YIELD label FILTER WHERE label = 'A' RETURN label",
        "CALL db.labels() FILTER label = 'A' RETURN label",
        "CALL db.labels() YIELD label FILTER label <> 'A' FILTER label <> 'B'",
        "MATCH (n) CALL db.labels() YIELD label FILTER WHERE label = 'A' RETURN n, label",
        "MATCH (n) FILTER n.v = 1 FILTER WHERE n.v > 0 RETURN n",
    };
    for (accepted) |q| {
        var outcome = try geode.parseGqlOutcome(q, testing.allocator, .{});
        defer outcome.deinit();
        switch (outcome) {
            .Ok => {},
            .Err => |e| {
                std.debug.print("{s}: {s} '{s}'\n", .{ q, e.code, e.msg });
                return error.FilterFormRefused;
            },
        }
    }
}
