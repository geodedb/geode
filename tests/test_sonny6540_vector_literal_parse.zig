// SONNY-6540 item 8: a 65,535-dimension vector literal (the documented
// vector cap) must parse inside the parser's 64 MiB budget, and a request
// past the budget must still be refused with 54000.
//
// Two defects kept the maximum-dimension literal from parsing:
//   1. every decimal literal (`1.0`) built its digit string in a fresh
//      ArrayList on the parser arena and never released it, so a float
//      element cost more than twice an integer element; on an arena whose
//      child grows in place (an arena over an arena, as the in-process
//      executors use) the 65,536-element ENG-3922 (c) literal crossed 64 MiB
//      and answered ParseMemoryLimit before the dimension check could run;
//   2. a negative element (`-0.25`) counted one operator link against the
//      4096-link expression cap (SONNY-3181), so a literal with more than
//      4096 negative components answered 42000. ISO/IEC 39075:2024 21.2
//      <literal>: `<signed numeric literal> ::= [ <sign> ]
//      <unsigned numeric literal>` - a sign on a numeric literal is part of
//      the literal, not an operator chain.
//
// Driven through the real parser (`geode.parseGqlOutcome`) and, for the
// accepted side, the real statement executor.

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

const execution = geode.execution;
const graph_store = geode.graph_store;
const index_manager = geode.index_manager;

const DIM_CAP: usize = 65535;

fn vectorQuery(allocator: std.mem.Allocator, head: []const u8, n: usize, positive: []const u8, negative: ?[]const u8, tail: []const u8) ![]u8 {
    var buf: std.ArrayList(u8) = .empty;
    errdefer buf.deinit(allocator);
    try buf.appendSlice(allocator, head);
    for (0..n) |i| {
        if (i > 0) try buf.appendSlice(allocator, ", ");
        const el = if (negative != null and i % 2 == 1) negative.? else positive;
        try buf.appendSlice(allocator, el);
    }
    try buf.appendSlice(allocator, tail);
    return buf.toOwnedSlice(allocator);
}

/// Parse `src` with a parser arena over `child`; answer the refusal code, or
/// null when it parsed.
fn parseCode(child: std.mem.Allocator, src: []const u8) !?[]const u8 {
    var outcome = try geode.parseGqlOutcome(src, child, .{});
    defer outcome.deinit();
    return switch (outcome) {
        .Ok => null,
        .Err => |e| blk: {
            std.debug.print("refused {s}: {s}\n", .{ e.code, e.msg });
            break :blk e.code;
        },
    };
}

/// The parser arena's capacity after parsing `src` over the page allocator.
fn parseCapacity(src: []const u8) !usize {
    var arena = std.heap.ArenaAllocator.init(std.heap.page_allocator);
    defer arena.deinit();
    var lx = geode.gql.lexer.Lexer{ .src = src };
    var p = geode.gql.parser.Parser{ .lx = &lx, .arena = &arena, .cur = lx.next() };
    _ = try p.parseProgram();
    return arena.queryCapacity();
}

test "SONNY-6540 item 8: a 65,535-dimension float vector literal parses over every parser-arena child" {
    const ta = testing.allocator;
    const src = try vectorQuery(ta, "RETURN size(vectorf32([", DIM_CAP, "1.0", null, "])) AS d");
    defer ta.free(src);

    try testing.expectEqual(@as(?[]const u8, null), try parseCode(std.heap.page_allocator, src));
    try testing.expectEqual(@as(?[]const u8, null), try parseCode(ta, src));
    // An arena over an arena (the in-process executors' shape): the child
    // grows the parser's block in place.
    var outer = std.heap.ArenaAllocator.init(ta);
    defer outer.deinit();
    const again = try vectorQuery(outer.allocator(), "RETURN size(vectorf32([", DIM_CAP + 1, "1.0", null, "])) AS d");
    try testing.expectEqual(@as(?[]const u8, null), try parseCode(outer.allocator(), again));
}

test "SONNY-6540 item 8: a decimal literal costs the parser no more than an integer literal" {
    const ta = testing.allocator;
    const ints = try vectorQuery(ta, "RETURN [", DIM_CAP, "1", null, "] AS l");
    defer ta.free(ints);
    const decimals = try vectorQuery(ta, "RETURN [", DIM_CAP, "1.0", null, "] AS l");
    defer ta.free(decimals);
    const int_cap = try parseCapacity(ints);
    const dec_cap = try parseCapacity(decimals);
    std.debug.print("parser arena: {d} integers {d} B ({d} B each), {d} decimals {d} B ({d} B each)\n", .{ DIM_CAP, int_cap, int_cap / DIM_CAP, DIM_CAP, dec_cap, dec_cap / DIM_CAP });
    // Both are one Expr node and one element pointer each; the arena's block
    // growth gives some slack either way.
    try testing.expect(dec_cap * 4 <= int_cap * 5);
}

test "SONNY-6540 item 8: a 65,535-dimension literal with negative components parses (ISO 21.2 signed numeric literal)" {
    const ta = testing.allocator;
    const src = try vectorQuery(ta, "RETURN size(vectorf32([", DIM_CAP, "0.5", "-0.0483", "])) AS d");
    defer ta.free(src);
    try testing.expectEqual(@as(?[]const u8, null), try parseCode(ta, src));
    const ints = try vectorQuery(ta, "RETURN size(vectori32([", DIM_CAP, "1", "-1", "])) AS d");
    defer ta.free(ints);
    try testing.expectEqual(@as(?[]const u8, null), try parseCode(ta, ints));
    // A sign on anything but a numeric literal is still an operator link,
    // and the 4096-link cap still holds: 5,000 `-x` elements, and a 5,000
    // link `0 - x - x ...` chain, are refused.
    const neg_vars = try vectorQuery(ta, "WITH 1 AS x RETURN [", 5000, "-x", null, "] AS l");
    defer ta.free(neg_vars);
    try testing.expectEqualStrings("42000", (try parseCode(ta, neg_vars)) orelse return error.ChainNotCapped);
    var long: std.ArrayList(u8) = .empty;
    defer long.deinit(ta);
    try long.appendSlice(ta, "WITH 1 AS x RETURN 0");
    for (0..5000) |_| try long.appendSlice(ta, " - x");
    const code = (try parseCode(ta, long.items)) orelse return error.ChainNotCapped;
    try testing.expectEqualStrings("42000", code);
}

test "SONNY-6540 item 8: a literal past the 64 MiB parser budget is still refused with 54000" {
    const ta = testing.allocator;
    const src = try vectorQuery(ta, "RETURN vectorf32([", 1_000_000, "1.0", "-1.0", "]) AS v");
    defer ta.free(src);
    const code = (try parseCode(std.heap.page_allocator, src)) orelse return error.BudgetMissing;
    try testing.expectEqualStrings("54000", code);
}

fn tmpDirRealpathAlloc(allocator: std.mem.Allocator, tmp_sub_path: []const u8) ![]u8 {
    var cwd_buf: [std.fs.max_path_bytes]u8 = undefined;
    const cwd_len = std.process.currentPath(std.Io.Threaded.global_single_threaded.io(), &cwd_buf) catch return error.GetCwdFailed;
    return std.fs.path.join(allocator, &.{ cwd_buf[0..cwd_len], ".zig-cache", "tmp", tmp_sub_path });
}

test "SONNY-6540 item 8: the executor constructs a 65,535-dimension vector with negative components" {
    const ta = testing.allocator;
    execution.cleanupCatalogInstance();
    index_manager.cleanupGlobalIndexManager();
    graph_store.deinitGlobalStore();
    var tmp = testing.tmpDir(.{});
    defer tmp.cleanup();
    const data_dir = try tmpDirRealpathAlloc(ta, &tmp.sub_path);
    defer ta.free(data_dir);
    graph_store.setDataDirOverride(ta, data_dir);
    defer graph_store.setDataDirOverride(ta, null);
    _ = graph_store.getGlobalStore(ta);
    const catalog = try execution.ensureCatalogInstance(ta);
    var session = execution.SessionState.init(ta);
    defer {
        session.deinit();
        execution.cleanupCatalogInstance();
        index_manager.cleanupGlobalIndexManager();
        graph_store.deinitGlobalStore();
    }
    var ctx = execution.ExecutionContext{ .catalog = catalog };
    ctx.session_state = &session;
    var arena = std.heap.ArenaAllocator.init(ta);
    defer arena.deinit();
    const aa = arena.allocator();

    const src = try vectorQuery(aa, "RETURN size(vectorf32([", DIM_CAP, "0.5", "-0.0483", "])) AS d");
    var parsed = try geode.parseGqlOptions(src, aa, .{});
    defer parsed.deinit();
    const res = try execution.executeStatementWithContext(aa, parsed.program.statements[0], ctx);
    try testing.expectEqual(@as(usize, 1), res.rows.len);
    try testing.expectEqual(@as(i64, @intCast(DIM_CAP)), res.rows[0][0].Int);
}
