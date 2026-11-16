// SONNY-6637 item 3: one comptime table of every function's operand count
// (src/eval/function_arity.zig), read by the statement check every
// transport runs after parsing and by the evaluator before it dispatches.
//
// Before: each function's dispatch checked its own count (SONNY-6555), so a
// call no row reached was never refused (`MATCH (n) WHERE false RETURN
// sqrt(1, 2)` answered no rows) and an aggregate, which the projection
// evaluates, never checked at all (`RETURN sum(1, 2)` answered 3). ISO/IEC
// 39075:2024 4.7.3 step 4 e): a wrong operand count violates a Syntax Rule,
// 42000, before anything runs.
//
// THE SWEEP: every entry, called with NULL operands at its least and its
// greatest count, is a call of that function (no WrongArgumentCount, no
// UnknownFunction, no syntax error); one operand more than its greatest
// count, and one fewer than its least, is WrongArgumentCount (the parser's
// own syntax error for the functions it checks) in a statement where no row
// reaches the call. And every function docs/TYPE_QUICK_REFERENCE.md shows
// is in the table.
//
// CANARY: REQ=REQ-SONNY-6637-ARITY-TABLE; FEATURE="BuiltinFunctions"; ASPECT=SharedArityTable; STATUS=TESTED; TEST=tests/test_sonny6637_function_arity.zig; OWNER=eval; UPDATED=2026-11-15

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");
const vs = @import("value_semantics_harness.zig");

const arity = geode.function_arity;

fn call(buf: *std.ArrayList(u8), prefix: []const u8, name: []const u8, n: usize) ![]const u8 {
    buf.clearRetainingCapacity();
    try buf.appendSlice(testing.allocator, prefix);
    try buf.appendSlice(testing.allocator, name);
    try buf.append(testing.allocator, '(');
    for (0..n) |i| {
        if (i > 0) try buf.appendSlice(testing.allocator, ", ");
        try buf.appendSlice(testing.allocator, "NULL");
    }
    try buf.appendSlice(testing.allocator, ") AS x");
    return buf.items;
}

fn checkSweep(s: *vs.Session, f: *vs.Failures) !void {
    var buf: std.ArrayList(u8) = .empty;
    defer buf.deinit(testing.allocator);
    const unreached = "MATCH (n:NoRow6637) WHERE false RETURN ";
    for (arity.entries) |e| {
        // At the least and the greatest count: a call of the function.
        if (e.form != .literal_operand) {
            const top: usize = e.max orelse e.min + 3;
            for ([_]usize{ e.min, top }) |n| {
                const q = try call(&buf, "RETURN ", e.name, n);
                if (s.run(q, &.{})) |ok| {
                    var r = ok;
                    r.deinit(s.arena.allocator());
                } else |err| switch (err) {
                    error.WrongArgumentCount, error.UnknownFunction, error.UnexpectedToken => try f.add("[{s}] {s}: {s}", .{ @tagName(s.mode), q, @errorName(err) }),
                    else => {},
                }
            }
        }
        // One more than the greatest, one fewer than the least: refused
        // before anything runs.
        const want: anyerror = if (e.form == .parser_checked) error.UnexpectedToken else error.WrongArgumentCount;
        if (e.form != .literal_operand) {
            if (e.max) |m| try vs.expectFail(s, f, try call(&buf, unreached, e.name, m + 1), &.{}, want);
            if (e.min > 0) try vs.expectFail(s, f, try call(&buf, unreached, e.name, e.min - 1), &.{}, want);
        }
    }
    // An aggregate is checked too: the projection evaluates it, not the
    // function dispatch, and it took any count.
    try s.exec("CREATE (:Ag6637 {k: 1}), (:Ag6637 {k: 2})", &.{});
    try vs.expectFail(s, f, "MATCH (n:Ag6637) RETURN sum(n.k, 1) AS s", &.{}, error.WrongArgumentCount);
    try vs.expectFail(s, f, "MATCH (n:Ag6637) RETURN count() AS c", &.{}, error.WrongArgumentCount);
    try vs.expectFail(s, f, "MATCH (n:Ag6637) RETURN max(n.k, 3) AS m", &.{}, error.WrongArgumentCount);
    try vs.expectFail(s, f, "MATCH (n:Ag6637) RETURN log10(n.k, 3) AS m", &.{}, error.WrongArgumentCount);
    try vs.expectFail(s, f, "MATCH (n:Ag6637) WITH n WHERE false RETURN timeseries.value(1, 'm') AS v", &.{}, error.WrongArgumentCount);
    // In a subquery, a WHERE, an ORDER BY, a SET value, a CALL's operands.
    try vs.expectFail(s, f, "MATCH (n:Ag6637) WHERE EXISTS { MATCH (m:Ag6637) WHERE upper(m.k, 1) = 'x' } RETURN n.k", &.{}, error.WrongArgumentCount);
    try vs.expectFail(s, f, "MATCH (n:Ag6637) RETURN n.k AS k ORDER BY abs(n.k) + sqrt(1, 2)", &.{}, error.WrongArgumentCount);
    try vs.expectFail(s, f, "MATCH (n:Ag6637) WHERE false SET n.v = upper()", &.{}, error.WrongArgumentCount);
    // The counts the functions take still evaluate, and the aggregates
    // aggregate.
    try vs.expectValue(s, f, "MATCH (n:Ag6637) RETURN sum(n.k) AS s", &.{}, "3");
    try vs.expectValue(s, f, "MATCH (n:Ag6637) RETURN count(*) AS c", &.{}, "2");
    try vs.expectValue(s, f, "RETURN substring('abc', 2) AS x", &.{}, "'bc'");
    try vs.expectValue(s, f, "RETURN coalesce(NULL, NULL, NULL, NULL, NULL, 7) AS x", &.{}, "7");
}

test "SONNY-6637 item 3: every function in the arity table, at its least and greatest count and one past each" {
    try vs.inModes("function arity table", &vs.eval_modes, checkSweep);
}

test "SONNY-6637 item 3: the table is lowercase, sorted and unique, and its lookup ignores case" {
    for (arity.entries, 0..) |e, i| {
        for (e.name) |c| try testing.expect(!std.ascii.isUpper(c));
        if (i > 0) try testing.expect(std.mem.lessThan(u8, arity.entries[i - 1].name, e.name));
        if (e.max) |m| try testing.expect(e.min <= m);
    }
    try testing.expect(arity.lookup("Upper").?.accepts(1));
    try testing.expect(!arity.lookup("UPPER").?.accepts(2));
    try testing.expectEqual(@as(?arity.Arity, null), arity.lookup("no_such_function"));
}

// Every `name(` in a code block of docs/TYPE_QUICK_REFERENCE.md, outside a
// string literal, is a function of the table (the reference listed
// functions no dispatch answers: now(), age(), bit_or(), jsonb_set() ...).
test "SONNY-6637 item 3: every function docs/TYPE_QUICK_REFERENCE.md shows is in the arity table" {
    const a = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    const text = try std.Io.Dir.cwd().readFileAlloc(io, "docs/TYPE_QUICK_REFERENCE.md", a, .limited(1 << 20));
    defer a.free(text);
    var missing: usize = 0;
    var seen: usize = 0;
    var in_code = false;
    var lines = std.mem.splitScalar(u8, text, '\n');
    var line_no: usize = 0;
    while (lines.next()) |line| {
        line_no += 1;
        if (std.mem.startsWith(u8, std.mem.trim(u8, line, " \t"), "```")) {
            in_code = !in_code;
            continue;
        }
        if (!in_code) continue;
        // The code before a `--` comment, outside quotes.
        const code = if (std.mem.indexOf(u8, line, "--")) |c| line[0..c] else line;
        var quote: ?u8 = null;
        var i: usize = 0;
        while (i < code.len) : (i += 1) {
            const ch = code[i];
            if (quote) |q| {
                if (ch == q) quote = null;
                continue;
            }
            if (ch == '\'' or ch == '"') {
                quote = ch;
                continue;
            }
            if (ch != '(') continue;
            var start = i;
            while (start > 0 and (std.ascii.isAlphanumeric(code[start - 1]) or code[start - 1] == '_' or code[start - 1] == '.')) start -= 1;
            const name = code[start..i];
            if (name.len == 0 or !std.ascii.isAlphabetic(name[0])) continue;
            // Keywords that take a parenthesis.
            const keywords = [_][]const u8{ "AS", "IN", "AND", "OR", "NOT", "RETURN", "WHERE", "VALUES", "VECTOR", "DECIMAL", "VARCHAR", "CHAR", "BIT", "VARBIT", "INTERVAL", "TIMESTAMP", "CREATE", "MATCH", "INDEX", "ON", "FOR" };
            const is_keyword = for (keywords) |k| {
                if (std.mem.eql(u8, name, k)) break true;
            } else false;
            if (is_keyword) continue;
            seen += 1;
            if (arity.lookup(name) == null) {
                missing += 1;
                std.debug.print("docs/TYPE_QUICK_REFERENCE.md:{d}: {s}() is no function of the arity table\n", .{ line_no, name });
            }
        }
    }
    try testing.expect(seen > 50);
    try testing.expectEqual(@as(usize, 0), missing);
}
