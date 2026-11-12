// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6383 items 2-8: query residuals found during SONNY-2698/2699/6351.
//
//   2. `CALL { } WITH ... RETURN` takes GROUP BY, ORDER BY, SKIP / OFFSET
//      and LIMIT after the RETURN (the mini-parser accepted none).
//   3. A RETURN mixing aggregates and plain items is refused (42000) when
//      the only GROUP BY is the WITH's.
//   4. An aggregate call inside a list comprehension's map or WHERE is the
//      scalar function, not an aggregate of the projection; the
//      comprehension's source is still the projection's. (sum([1.5, 2]) is
//      3: the list sum floors a decimal, as test-sonny2739 pins.)
//   5. (Not reproduced: both RETURN loops it names are out of reach of a
//      parsed query; see the SONNY-6383 fix commit.)
//   6. The WITH stage's ORDER BY evaluates each key once per row and frees
//      what it computed.
//   7. (tests/test_sonny6383_call_return_flags.zig)
//   8. VALUES ... MATCH frees what its rows computed with no scratch arena
//      installed (an embedded caller).
//
// Result semantics run through the SONNY-2672 batch harness (in-memory,
// persisted, tenant-scoped and RLS sessions, leak-checked, scratch arena
// installed as the server does). The leak cases for embedded callers run on
// an in-memory session with NO scratch arena, each statement on its own
// leak-checked allocator.
//
// CANARY: REQ=REQ-SONNY-6383-QUERY-RESIDUALS; FEATURE="ReadSemanticsBatch"; ASPECT=Regression; STATUS=TESTED; TEST=tests/test_sonny6383_query_residuals.zig; OWNER=engine; UPDATED=2026-11-12

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const batch = @import("test_sonny2672_read_semantics_batch.zig");
const harness = @import("node_scan_stream_harness.zig");

const Case = batch.Case;
const overflow = batch.overflow;
const execution = geode.execution;
const graph_store = geode.graph_store;
const Value = geode.value_types.Value;

// Item 2: the RETURN after `CALL { } WITH ...` is a full RETURN.
const item2 = [_]Case{
    .{ .q = "CALL { MATCH (z:Z) RETURN z.k AS k } WITH k RETURN k ORDER BY k DESC LIMIT 2", .want = &.{ "7", "6" }, .ordered = true },
    .{ .q = "CALL { MATCH (z:Z) RETURN z.k AS k } WITH k RETURN k ORDER BY k SKIP 6", .want = &.{ "6", "7" }, .ordered = true },
    .{ .q = "CALL { MATCH (z:Z) RETURN z.k AS k } WITH k WHERE k > 4 RETURN k ORDER BY k OFFSET 1 LIMIT 1", .want = &.{"6"}, .ordered = true },
    .{ .q = "CALL { MATCH (z:Z) RETURN z.g AS g, z.k AS k } WITH g, k RETURN g, count(k) AS c GROUP BY g ORDER BY g DESC", .want = &.{ "1, 4", "0, 4" }, .ordered = true },
    .{ .q = "CALL { MATCH (z:Z) RETURN z.k AS k } WITH k RETURN DISTINCT k % 2 AS m ORDER BY m", .want = &.{ "0", "1" }, .ordered = true },
};

// Item 3: the WITH's GROUP BY does not group the RETURN.
const item3 = [_]Case{
    .{ .q = "MATCH (z:Z) WITH z.g AS g, count(*) AS c GROUP BY g RETURN g, sum(c) AS s", .err = error.GroupingError },
    .{ .q = "MATCH (z:Z) WITH z.g AS g, count(*) AS c GROUP BY g RETURN g, c", .want = &.{ "0, 4", "1, 4" } },
    .{ .q = "MATCH (z:Z) WITH z.g AS g, count(*) AS c GROUP BY g RETURN sum(c) AS s", .want = &.{"8"} },
};

// Item 4: the comprehension's source is outside it: an aggregate there is
// one (leak-checked here; the per-element cases are in the item 4 test
// below, which does not check leaks: evaluating a list comprehension leaks
// its lists on every session, a separate defect reported with SONNY-6383).
const item4 = [_]Case{
    .{ .q = "MATCH (z:Z) WHERE z.k < 3 RETURN count(z) AS n", .want = &.{"3"} },
};

test "SONNY-6383 item 2: CALL { } WITH ... RETURN takes GROUP BY, ORDER BY and paging" {
    try batch.inEveryMode("SONNY-6383 item 2", &item2);
}

test "SONNY-6383 item 3: a RETURN mixing aggregates and plain items needs its own GROUP BY" {
    try batch.inEveryMode("SONNY-6383 item 3", &item3);
}

test "SONNY-6383 item 4: an aggregate name inside a comprehension is the scalar function" {
    try batch.inEveryMode("SONNY-6383 item 4", &item4);
    var s = try Embedded.init();
    defer s.deinit();
    // sum(list) in the map or WHERE is the list function, per element.
    try testing.expectEqualStrings("[3]", try s.render("RETURN [x IN [1] | sum([1, 2])] AS s"));
    try testing.expectEqualStrings("[3]", try s.render("MATCH (z:Z {k: 2}) RETURN [x IN [1] | sum([z.k, x])] AS s"));
    try testing.expectEqualStrings("0 []|1 [10]", try s.render("MATCH (z:Z) WHERE z.k < 2 RETURN z.k AS k, [x IN [10] WHERE sum([x, z.k]) > 10 | x] AS s ORDER BY k"));
    try testing.expectEqualStrings("[3]", try s.render("RETURN [x IN [1] | sum([1.5, 2])] AS s"));
    // The source is the projection's: collect() aggregates the rows.
    try testing.expectEqualStrings("3", try s.render("MATCH (z:Z) WHERE z.k < 3 RETURN size([x IN collect(z.k) | x]) AS n"));
    try testing.expectEqualStrings("[1, 2, 3]", try s.render("MATCH (z:Z) WHERE z.k < 3 WITH z.k AS k ORDER BY k RETURN [x IN collect(k) | x + 1] AS l"));
}

// ---------------------------------------------------------------------------
// Embedded callers: no scratch arena installed.
// ---------------------------------------------------------------------------

const Embedded = struct {
    arena: std.heap.ArenaAllocator,
    ctx: execution.ExecutionContext,

    fn init() !Embedded {
        harness.silenceEngineLogs();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
        graph_store.setDataDirOverride(testing.allocator, null);
        _ = graph_store.getGlobalStore(testing.allocator);
        if (graph_store.getGlobalAdapter() != null) return error.WrongDeployment;
        const catalog = try execution.ensureCatalogInstance(testing.allocator);
        execution.initEvaluator();
        var self: Embedded = .{ .arena = std.heap.ArenaAllocator.init(testing.allocator), .ctx = .{ .catalog = catalog } };
        for (0..8) |k| {
            var r = try self.run(self.arena.allocator(), try std.fmt.allocPrint(self.arena.allocator(), "CREATE (:Z {{k: {d}, r: {d}}})", .{ k, 7 - k }));
            r.deinit(self.arena.allocator());
        }
        return self;
    }

    fn deinit(self: *Embedded) void {
        self.arena.deinit();
        execution.cleanupCatalogInstance();
        graph_store.deinitGlobalStore();
    }

    fn run(self: *Embedded, allocator: std.mem.Allocator, query: []const u8) !execution.ExecutionResult {
        var parsed = try geode.parseGqlOptions(query, self.arena.allocator(), .{});
        defer parsed.deinit();
        var ctx = self.ctx;
        const prev = execution.pushActiveContext(&ctx);
        defer execution.popActiveContext(prev);
        return execution.executeProgramWithContext(allocator, &parsed.program, ctx);
    }

    /// Runs `query` on the session arena (no leak check) and renders the
    /// rows: cells joined by a space, rows by `|`; integers, and lists of
    /// integers as `[a, b]`.
    fn render(self: *Embedded, query: []const u8) ![]const u8 {
        const a = self.arena.allocator();
        var result = try self.run(a, query);
        var out: std.Io.Writer.Allocating = .init(a);
        for (result.rows, 0..) |row, r| {
            if (r != 0) try out.writer.writeByte('|');
            for (row[0..result.columns.len], 0..) |cell, c| {
                if (c != 0) try out.writer.writeByte(' ');
                switch (cell) {
                    .Int => |n| try out.writer.print("{d}", .{n}),
                    .List => |items| {
                        try out.writer.writeByte('[');
                        for (items, 0..) |item, i| {
                            if (i != 0) try out.writer.writeAll(", ");
                            switch (item) {
                                .Int => |n| try out.writer.print("{d}", .{n}),
                                else => try out.writer.print("<{s}>", .{@tagName(item)}),
                            }
                        }
                        try out.writer.writeByte(']');
                    },
                    else => try out.writer.print("<{s}>", .{@tagName(cell)}),
                }
            }
        }
        _ = &result;
        return out.written();
    }

    /// Runs `query` on its own leak-checked allocator; returns the first
    /// column of each row as an integer, in order.
    fn ints(self: *Embedded, query: []const u8) ![]i64 {
        var gpa: std.heap.DebugAllocator(.{}) = .init;
        const out = blk: {
            const a = gpa.allocator();
            var result = try self.run(a, query);
            defer result.deinit(a);
            const out = try self.arena.allocator().alloc(i64, result.rows.len);
            for (result.rows, out) |row, *o| o.* = row[0].Int;
            break :blk out;
        };
        if (gpa.deinit() == .leak) {
            std.debug.print("SONNY-6383: leaked memory: {s}\n", .{query});
            return error.LeakedMemory;
        }
        return out;
    }
};

test "SONNY-6383 item 6: a WITH ORDER BY key is computed once per row and freed" {
    var s = try Embedded.init();
    defer s.deinit();
    // upper() and a list literal allocate their key; z.r (7 - k) orders.
    try testing.expectEqualSlices(i64, &.{ 7, 6, 5, 4, 3, 2, 1, 0 }, try s.ints("MATCH (z:Z) WITH z ORDER BY upper('k'), z.r RETURN z.k AS k"));
    try testing.expectEqualSlices(i64, &.{ 0, 1, 2 }, try s.ints("MATCH (z:Z) WITH z ORDER BY lower('K'), z.k LIMIT 3 RETURN z.k AS k"));
    try testing.expectEqualSlices(i64, &.{8}, try s.ints("MATCH (z:Z) WITH z ORDER BY [z.r, z.k] RETURN count(z) AS c"));
}

test "SONNY-6383 item 8: VALUES ... MATCH frees what its rows computed without a scratch arena" {
    var s = try Embedded.init();
    defer s.deinit();
    try testing.expectEqualSlices(i64, &.{ 1, 2 }, try s.ints("VALUES (upper('a'), 1), (lower('B'), 2) AS (t, n) MATCH (z:Z) WHERE z.k = n RETURN z.k AS k ORDER BY k"));
    try testing.expectEqualSlices(i64, &.{1}, try s.ints("VALUES ('a' || 'b', 1) AS (t, n) MATCH (z:Z {k: 1}) RETURN size(t) - 1 AS k"));
}
