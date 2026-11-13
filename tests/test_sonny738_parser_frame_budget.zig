// SONNY-738 (item 0b): what one level of query nesting costs the parser's
// stack, pinned.
//
// The parser refuses a query nested more than `max_query_nesting` (10) deep
// with 54001, and its stack guard refuses any nesting once less than
// `stack_reserve_bytes` (2 MiB in a Debug build) of the thread's stack is
// left. The deepest nesting the limit allows must therefore fit an 8 MiB gRPC
// connection thread with the guard's reserve and the handler's own frames to
// spare (test-sonny-write-allowlist-r4-transport, round 4a over gRPC). After
// SONNY-6267 and SONNY-6467 grew the parser's recursive frames, nine nested
// FOR bodies hit the guard first (`FOR body x9: 54001`); that test spawns a
// server and forks per depth, so a frame that grows is found late.
//
// This test parses each nesting shape of that transport test at the deepest
// depth it must take, with the parser's frame probe
// (`parser.test_frame_probe`) recording the frame address of `parseQuery` at
// every depth and the lowest frame the stack guard was asked about, and pins:
//
//   * the bytes one more level of nesting costs (the largest step between
//     two consecutive depths), per shape;
//   * the bytes the whole parse of the deepest nesting takes below the
//     outermost `parseQuery`.
//
// The budgets are this build mode's measured cost with a small margin. A
// parser change that grows a frame on the recursive path (a large local, an
// AST value held by value instead of by pointer, a new temporary in
// `parseQuery`) fails here in seconds: move the new state off the recursive
// path (box it, or compute it in a helper that is not on the path) rather
// than raising the budget. The transport test is the end-to-end check.
//
// CANARY: REQ=REQ-SONNY-738-PARSER-FRAME-BUDGET; FEATURE="GQLParser"; ASPECT=FrameBudget; STATUS=TESTED; TEST=tests/test_sonny738_parser_frame_budget.zig; OWNER=parser; UPDATED=2026-11-13

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const parser = geode.gql.parser;

const Shape = struct {
    name: []const u8,
    head: []const u8 = "",
    open: []const u8,
    core: []const u8,
    close: []const u8 = "",
    tail: []const u8 = "",
    /// The deepest nesting the transport test runs (`ok` there).
    depth: usize,
};

// The shapes of test-sonny-write-allowlist-r4-transport's round 4a.
const shapes = [_]Shape{
    .{ .name = "WITH chain", .open = "WITH 1 AS a ", .core = "RETURN a", .depth = 10 },
    .{ .name = "CALL subquery", .open = "CALL { ", .core = "RETURN 1 AS x", .close = " } RETURN x", .depth = 10 },
    .{ .name = "IN subquery", .head = "MATCH (m) WHERE m.i IN (", .open = "MATCH (m) WHERE m.i IN (", .core = "RETURN 1", .close = ") RETURN m.i", .tail = ") RETURN m.i", .depth = 8 },
    .{ .name = "FOR body", .head = "WITH 1 AS a ", .open = "FOR x IN [1] MATCH (n) WITH n ", .core = "RETURN 1", .depth = 9 },
};

const Measured = struct {
    /// The largest step between two consecutive depths' `parseQuery` frames.
    per_level: usize = 0,
    /// From the outermost `parseQuery` frame to the lowest frame seen.
    total: usize = 0,
    levels: usize = 0,
    parsed: bool = false,
};

const Job = struct {
    query: []const u8,
    out: Measured = .{},

    fn run(job: *Job) void {
        var probe: parser.FrameProbe = .{};
        parser.test_frame_probe = &probe;
        defer parser.test_frame_probe = null;
        var result = geode.parseGqlOptions(job.query, std.heap.page_allocator, .{}) catch return;
        result.deinit();
        job.out.parsed = true;
        const frames = probe.query_frames;
        var d: usize = 1;
        while (d + 1 < frames.len and frames[d + 1] != 0) : (d += 1) {
            job.out.per_level = @max(job.out.per_level, frames[d] - frames[d + 1]);
        }
        job.out.levels = d;
        if (frames[1] != 0 and probe.lowest < frames[1]) job.out.total = frames[1] - probe.lowest;
    }
};

fn measure(allocator: std.mem.Allocator, shape: Shape) !Measured {
    var text: std.ArrayList(u8) = .empty;
    defer text.deinit(allocator);
    try text.appendSlice(allocator, shape.head);
    for (0..shape.depth) |_| try text.appendSlice(allocator, shape.open);
    try text.appendSlice(allocator, shape.core);
    for (0..shape.depth) |_| try text.appendSlice(allocator, shape.close);
    try text.appendSlice(allocator, shape.tail);
    var job: Job = .{ .query = text.items };
    // Room to measure in: the budget, not this thread, is what is checked.
    const t = try std.Thread.spawn(.{ .stack_size = 64 << 20 }, Job.run, .{&job});
    t.join();
    return job.out;
}

/// The budgets, in KiB.
///
/// Total: the deepest nesting of every shape must take at most 3 MiB below
/// the outermost `parseQuery`. That is the requirement, not a measurement:
/// before this fix the WITH chain's 3388 KiB fitted the gRPC thread (8 MiB,
/// less the guard's 2 MiB reserve and the handler's frames) and the FOR
/// body's 4566 KiB did not.
///
/// Per level: the Debug build's measured cost after the fix (WITH chain and
/// CALL { } 121 KiB, IN (subquery) 140 KiB, FOR body 181 KiB; they were 338,
/// 338, 358 and 472 KiB) with about 25% to spare, so a frame that grows
/// fails here long before the total does. A release build's frames are
/// smaller; the same numbers hold it.
const Budget = struct { per_level_kib: usize, total_kib: usize };

const total_budget_kib = 3 * 1024;

fn budget(shape_name: []const u8) Budget {
    const per_level: usize = if (std.mem.eql(u8, shape_name, "FOR body"))
        225
    else if (std.mem.eql(u8, shape_name, "IN subquery"))
        175
    else
        150;
    return .{ .per_level_kib = per_level, .total_kib = total_budget_kib };
}

test "SONNY-738: one level of query nesting costs the parser's stack no more than its budget" {
    var failed = false;
    for (shapes) |shape| {
        const m = try measure(testing.allocator, shape);
        const b = budget(shape.name);
        std.debug.print("{s} x{d}: parsed={} levels={d} per_level={d} KiB total={d} KiB (budget {d} / {d} KiB)\n", .{ shape.name, shape.depth, m.parsed, m.levels, m.per_level >> 10, m.total >> 10, b.per_level_kib, b.total_kib });
        if (!m.parsed or m.per_level > b.per_level_kib << 10 or m.total > b.total_kib << 10) failed = true;
    }
    try testing.expect(!failed);
}
