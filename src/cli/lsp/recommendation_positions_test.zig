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

/// One provideDiagnostics run of a query with a recommendation. Anything but
/// the recommendation and no error diagnostic is an error of its own.
fn diagnoseOnce(allocator: std.mem.Allocator) !void {
    var srv = try server.Server.init(allocator);
    defer srv.deinit();
    try srv.documents.open("file:///oom.gql", "MATCH (n:Person) WHERE n.age = 30 RETURN n", 1);
    const diags = try features.provideDiagnostics(allocator, srv.documents.get("file:///oom.gql").?, null, features.LspContext.stdio);
    defer freeDiagnostics(allocator, diags);
    for (diags) |d| {
        if (d.severity == .Error) return error.ErrorDiagnostic;
    }
    if (findDiag(diags, "CREATE INDEX ON :Person(age)", 0) == null) return error.MissingRecommendation;
}

test "SONNY-6511: an allocation failure in LSP diagnostics is an error, never a missing recommendation" {
    // SONNY-6517 item 1: every allocation failing in turn must end the
    // request with error.OutOfMemory and leak nothing; a run that answers
    // anyway (an error diagnostic, as a parse that ran out of memory did,
    // or no recommendation) fails. It allowed the error diagnostic while
    // the parse path reported an allocation failure as a syntax error.
    try testing.checkAllAllocationFailures(testing.allocator, diagnoseOnce, .{});
}
