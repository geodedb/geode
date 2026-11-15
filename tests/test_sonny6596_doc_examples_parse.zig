// SONNY-6596 item 6: the GQL examples in Geode's docs parse.
//
// docs/GRAPH_ALGORITHMS_USAGE_GUIDE.md showed five examples Geode refused
// (`CALL ... YIELD ... RETURN ... GROUP BY ...`), and nothing checked the
// examples. Every ```gql code block of the docs listed below is split into
// its queries (a run of non-blank lines; lines that are only a comment are
// dropped) and each query goes through the real parser
// (`geode.parseGql`), as a client's query does. A doc example that does not
// parse fails here, so the docs cannot rot again.
//
// SONNY-6613 item 8: every Markdown doc under docs/, at any depth, not a
// list (149 examples in 22 docs did not parse). A syntax template (with
// `[...]` or `<...>` placeholders) is a ```text block, not a ```gql one.
//
// CANARY: REQ=REQ-SONNY-6596-DOC-EXAMPLES-PARSE; FEATURE="Documentation"; ASPECT=GqlExamplesParse; STATUS=TESTED; TEST=tests/test_sonny6596_doc_examples_parse.zig; OWNER=docs; UPDATED=2026-11-15

const std = @import("std");
const testing = std.testing;
const geode = @import("geode");

/// The directory whose every Markdown doc's ```gql blocks are checked.
const docs_root = "docs";

/// The docs checked must include these (the walk reads them all; this
/// guards against a walk that silently reads nothing).
const must_check = [_][]const u8{
    "GRAPH_ALGORITHMS_USAGE_GUIDE.md",
    "TYPE_QUICK_REFERENCE.md",
    "GQL_COMPLIANCE.md",
    "API_REFERENCE.md",
};

fn isCommentOnly(line: []const u8) bool {
    const t = std.mem.trim(u8, line, " \t\r");
    return std.mem.startsWith(u8, t, "--") or std.mem.startsWith(u8, t, "//");
}

/// Parses `query`; prints and counts it when it does not parse.
fn check(doc: []const u8, line_no: usize, query: []const u8) !usize {
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const trimmed = std.mem.trimEnd(u8, std.mem.trim(u8, query, " \t\r\n"), ";");
    if (trimmed.len == 0) return 0;
    var parsed = geode.parseGql(trimmed, arena.allocator()) catch |err| {
        std.debug.print("{s}:{d}: {s}\n    {s}\n", .{ doc, line_no, @errorName(err), trimmed });
        return 1;
    };
    parsed.deinit();
    return 0;
}

fn checkDoc(a: std.mem.Allocator, io: std.Io, dir: std.Io.Dir, doc: []const u8) !usize {
    const text = try dir.readFileAlloc(io, doc, a, .limited(8 << 20));
    defer a.free(text);
    var failures: usize = 0;
    var in_gql = false;
    var query: std.ArrayList(u8) = .empty;
    defer query.deinit(a);
    var query_line: usize = 0;
    var line_no: usize = 0;
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |raw| {
        line_no += 1;
        const line = std.mem.trimEnd(u8, raw, "\r");
        const t = std.mem.trim(u8, line, " \t");
        if (std.mem.startsWith(u8, t, "```")) {
            if (in_gql) {
                failures += try check(doc, query_line, query.items);
                query.clearRetainingCapacity();
                in_gql = false;
            } else {
                in_gql = std.mem.eql(u8, std.mem.trim(u8, t[3..], " "), "gql");
            }
            continue;
        }
        if (!in_gql) continue;
        if (t.len == 0) {
            failures += try check(doc, query_line, query.items);
            query.clearRetainingCapacity();
            continue;
        }
        if (isCommentOnly(line)) continue;
        if (query.items.len == 0) query_line = line_no;
        try query.appendSlice(a, line);
        try query.append(a, '\n');
    }
    return failures;
}

test "SONNY-6596 / SONNY-6613: every GQL example in every doc under docs/ parses" {
    const a = testing.allocator;
    const io = std.Io.Threaded.global_single_threaded.io();
    var dir = try std.Io.Dir.cwd().openDir(io, docs_root, .{ .iterate = true });
    defer dir.close(io);
    var walker = try dir.walk(a);
    defer walker.deinit();
    var failures: usize = 0;
    var seen = [_]bool{false} ** must_check.len;
    var checked: usize = 0;
    while (try walker.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.basename, ".md")) continue;
        for (must_check, &seen) |name, *s| {
            if (std.mem.eql(u8, entry.path, name)) s.* = true;
        }
        checked += 1;
        failures += try checkDoc(a, io, dir, entry.path);
    }
    for (must_check, seen) |name, s| {
        if (!s) std.debug.print("{s}/{s} was not checked\n", .{ docs_root, name });
        try testing.expect(s);
    }
    try testing.expect(checked > must_check.len);
    try testing.expectEqual(@as(usize, 0), failures);
}

const vs = @import("value_semantics_harness.zig");

// ISO/IEC 39075:2024 14.11: a <group by clause> is part of the <return
// statement body>, after a procedure call's RETURN too; the guide's
// community and component examples use it. It was a syntax error after
// `CALL proc() YIELD ...`.
fn checkCallGroupBy(s: *vs.Session, f: *vs.Failures) !void {
    try s.exec("CREATE (:Cg6596 {k: 1})-[:R]->(:Cg6596 {k: 2})-[:R]->(:Cg6596 {k: 3})", &.{});
    try s.exec("CREATE (:Cg6596 {k: 4})-[:R]->(:Cg6596 {k: 5})", &.{});
    try s.exec("CREATE (:Cg6596 {k: 6})", &.{});
    try vs.expectOrdered(s, f, "CALL algo.unionFind.stream() YIELD nodeId, setId RETURN size(collect(nodeId)) AS members, count(*) AS n GROUP BY setId ORDER BY n DESC", &.{}, &.{ "3, 3", "2, 2", "1, 1" });
    try vs.expectOrdered(s, f, "CALL algo.unionFind.stream() YIELD nodeId, setId RETURN count(*) AS n GROUP BY setId HAVING count(*) > 1 ORDER BY n", &.{}, &.{ "2", "3" });
    try vs.expectOrdered(s, f, "CALL algo.unionFind.stream() YIELD nodeId, setId RETURN count(*) AS n GROUP BY setId ORDER BY n", &.{}, &.{ "1", "2", "3" });
}

test "SONNY-6596: a procedure call's RETURN takes a GROUP BY (ISO/IEC 39075 14.11)" {
    try vs.inModes("call group by", &.{.in_memory}, checkCallGroupBy);
}
