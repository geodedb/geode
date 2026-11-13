// SONNY-6511 item 4: LSP diagnostics place each recommendation on the token
// it is about, and an error of the recommendation engine reaches the caller.
//
// src/cli/lsp/features/diagnostics.zig reported every recommendation of
// src/gql/recommendations.zig at 0:0-0:0 (the AST carries no positions) and
// turned any error of the engine, out-of-memory included, into "no
// recommendations". Ranges here are 0-based, as LSP's are.

const std = @import("std");
const testing = std.testing;
const protocol = @import("protocol.zig");
const features = @import("features.zig");
const server = @import("server.zig");

fn freeDiagnostics(allocator: std.mem.Allocator, diags: []protocol.Diagnostic) void {
    for (diags) |d| allocator.free(d.message);
    allocator.free(diags);
}

/// The text a one-line range covers in `text`.
fn rangeText(text: []const u8, range: protocol.Range) []const u8 {
    var line: u32 = 0;
    var start: usize = 0;
    while (line < range.start.line) : (line += 1) {
        start = (std.mem.indexOfScalarPos(u8, text, start, '\n') orelse return "") + 1;
    }
    const a = start + range.start.character;
    const b = start + range.end.character;
    if (range.end.line != range.start.line or b > text.len or a > b) return "";
    return text[a..b];
}

fn findDiag(diags: []const protocol.Diagnostic, needle: []const u8, nth: usize) ?protocol.Diagnostic {
    var seen: usize = 0;
    for (diags) |d| {
        if (std.mem.indexOf(u8, d.message, needle) == null) continue;
        if (seen == nth) return d;
        seen += 1;
    }
    return null;
}

test "SONNY-6511: LSP recommendation diagnostics carry the range of their token" {
    const allocator = testing.allocator;
    var srv = try server.Server.init(allocator);
    defer srv.deinit();

    const text = "MATCH (n:Person)\nWHERE n.age = 30 AND n.nick IS NULL\nRETURN n ORDER BY n.age";
    try srv.documents.open("file:///rec.gql", text, 1);
    const diags = try features.provideDiagnostics(allocator, srv.documents.get("file:///rec.gql").?, null, features.LspContext.stdio);
    defer freeDiagnostics(allocator, diags);

    const where_idx = findDiag(diags, "faster lookups: CREATE INDEX ON :Person(age)", 0) orelse return error.RecommendationMissing;
    try testing.expectEqual(@as(u32, 1), where_idx.range.start.line);
    try testing.expectEqual(@as(u32, 8), where_idx.range.start.character);
    try testing.expectEqual(@as(u32, 11), where_idx.range.end.character);
    try testing.expectEqualStrings("age", rangeText(text, where_idx.range));

    const coalesce = findDiag(diags, "coalesce(n.nick", 0) orelse return error.RecommendationMissing;
    try testing.expectEqualStrings("nick", rangeText(text, coalesce.range));
    try testing.expectEqual(@as(u32, 1), coalesce.range.start.line);

    // ORDER BY n.age: the second occurrence of `age`, on the third line.
    const order = findDiag(diags, "ORDER BY: CREATE INDEX ON :Person(age)", 0) orelse return error.RecommendationMissing;
    try testing.expectEqual(@as(u32, 2), order.range.start.line);
    try testing.expectEqualStrings("age", rangeText(text, order.range));
}

test "SONNY-6511: LSP graph-type field recommendations point at the field" {
    const allocator = testing.allocator;
    var srv = try server.Server.init(allocator);
    defer srv.deinit();

    const text = "CREATE GRAPH TYPE T AS {\n  name text,\n  ssn text\n}";
    try srv.documents.open("file:///gt.gql", text, 1);
    const diags = try features.provideDiagnostics(allocator, srv.documents.get("file:///gt.gql").?, null, features.LspContext.stdio);
    defer freeDiagnostics(allocator, diags);

    const d = findDiag(diags, "Field 'ssn'", 0) orelse return error.RecommendationMissing;
    try testing.expectEqual(@as(u32, 2), d.range.start.line);
    try testing.expectEqual(@as(u32, 2), d.range.start.character);
    try testing.expectEqualStrings("ssn", rangeText(text, d.range));
}

/// One provideDiagnostics run of a query with a recommendation, the
/// `fail_index`-th allocation failing. Returns null on error.OutOfMemory.
fn diagnoseFailingAt(fail_index: usize, allocations: *usize) !?struct { recommended: bool, errored: bool } {
    var failing = std.testing.FailingAllocator.init(testing.allocator, .{ .fail_index = fail_index });
    const allocator = failing.allocator();
    defer allocations.* = failing.alloc_index;
    var srv = server.Server.init(allocator) catch |err| {
        const e: anyerror = err;
        if (e == error.OutOfMemory) return null;
        return e;
    };
    defer srv.deinit();
    srv.documents.open("file:///oom.gql", "MATCH (n:Person) WHERE n.age = 30 RETURN n", 1) catch |err| {
        const e: anyerror = err;
        if (e == error.OutOfMemory) return null;
        return e;
    };
    const diags = features.provideDiagnostics(allocator, srv.documents.get("file:///oom.gql").?, null, features.LspContext.stdio) catch |err| {
        const e: anyerror = err;
        if (e == error.OutOfMemory) return null;
        return e;
    };
    defer freeDiagnostics(allocator, diags);
    var errored = false;
    for (diags) |d| {
        if (d.severity == .Error) errored = true;
    }
    return .{ .recommended = findDiag(diags, "CREATE INDEX ON :Person(age)", 0) != null, .errored = errored };
}

test "SONNY-6511: an allocation failure in LSP diagnostics is an error, never a missing recommendation" {
    // A clean run, to count its allocations.
    var total: usize = 0;
    const clean = (try diagnoseFailingAt(std.math.maxInt(usize), &total)).?;
    try testing.expect(clean.recommended and !clean.errored);
    // Fail each allocation in turn. A run may end in error.OutOfMemory, or
    // still produce the recommendation. A run that answers with no error
    // and no recommendation has swallowed the failure. (A run whose parse
    // reports an error diagnostic is the parse path's own handling, outside
    // this test.)
    var i: usize = 0;
    while (i < total) : (i += 1) {
        var n: usize = 0;
        const r = (try diagnoseFailingAt(i, &n)) orelse continue;
        if (!r.recommended and !r.errored) {
            std.debug.print("allocation {d} of {d} failed and the diagnostics answered with no recommendation and no error\n", .{ i, total });
            return error.SwallowedOutOfMemory;
        }
    }
}
