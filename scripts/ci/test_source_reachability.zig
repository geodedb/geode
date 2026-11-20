//! SONNY-6542: the source analysis behind build.zig's
//! `checkTestSourcesReachable` guard. A `tests/*.zig` file runs only when a
//! build step compiles it: it is the root source of a test artifact, or a
//! file such a root reaches through a relative `@import("x.zig")` that the
//! compiler analyzes. Zig analyzes only referenced declarations, so a
//! container-level `const _x = @import("x.zig");` whose name nothing uses
//! never compiles `x.zig` and none of its tests run (tests/all_tests.zig
//! carried fourteen such imports). `analyzedImports` returns the relative
//! `.zig` imports of a source that do reach the compiler.
//!
//! The analysis is lexical and errs towards "analyzed": a `pub` binding may
//! be used by an importer, and a file that calls
//! `std.testing.refAllDecls(@This())` references every declaration.
// CANARY: REQ=REQ-SONNY-6542-TEST-SOURCE-REACHABILITY; FEATURE="TestSourceReachabilityGuard"; ASPECT=TestInfra; STATUS=TESTED; TEST=scripts/ci/test_source_reachability.zig; OWNER=ci; UPDATED=2026-11-14
const std = @import("std");

/// Returns `src` with every `//` comment and the contents of every string,
/// character and multiline string literal blanked out (the quotes stay), so
/// a commented-out import, or a name inside a string, is not mistaken for
/// code. The result has the same length as `src`, so offsets carry over.
pub fn stripComments(gpa: std.mem.Allocator, src: []const u8) ![]u8 {
    const out = try gpa.dupe(u8, src);
    var i: usize = 0;
    while (i < out.len) {
        const c = out[i];
        if (c == '"' or c == '\'') {
            i += 1;
            while (i < out.len and out[i] != c and out[i] != '\n') : (i += 1) {
                if (out[i] == '\\' and i + 1 < out.len) {
                    out[i] = ' ';
                    i += 1;
                }
                out[i] = ' ';
            }
            i += 1;
        } else if (c == '\\' and i + 1 < out.len and out[i + 1] == '\\') {
            i += 2;
            while (i < out.len and out[i] != '\n') : (i += 1) out[i] = ' ';
        } else if (c == '/' and i + 1 < out.len and out[i + 1] == '/') {
            while (i < out.len and out[i] != '\n') : (i += 1) out[i] = ' ';
        } else {
            i += 1;
        }
    }
    return out;
}

fn isIdentChar(c: u8) bool {
    return std.ascii.isAlphanumeric(c) or c == '_';
}

/// True when identifier `name` occurs in `code` outside `skip_start..skip_end`
/// as a whole word that is not a field access (`x.name`).
fn identifierUsed(code: []const u8, name: []const u8, skip_start: usize, skip_end: usize) bool {
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, code, from, name)) |at| {
        from = at + name.len;
        if (at >= skip_start and at < skip_end) continue;
        if (at > 0 and (isIdentChar(code[at - 1]) or code[at - 1] == '.' or code[at - 1] == '@')) continue;
        if (from < code.len and isIdentChar(code[from])) continue;
        return true;
    }
    return false;
}

fn skipSpaceBack(code: []const u8, end: usize) usize {
    var i = end;
    while (i > 0 and std.ascii.isWhitespace(code[i - 1])) i -= 1;
    return i;
}

/// The word that ends at `end` (exclusive), or "" when none does.
fn wordBefore(code: []const u8, end: usize) []const u8 {
    var start = end;
    while (start > 0 and isIdentChar(code[start - 1])) start -= 1;
    return code[start..end];
}

/// Appends to `out` the relative `.zig` paths that `src` imports and the
/// compiler analyzes (see the file comment). The slices point into `src`.
pub fn analyzedImports(gpa: std.mem.Allocator, src: []const u8, out: *std.ArrayList([]const u8)) !void {
    const code = try stripComments(gpa, src);
    defer gpa.free(code);
    const refs_all = std.mem.indexOf(u8, code, "refAllDecls(@This())") != null or
        std.mem.indexOf(u8, code, "refAllDeclsRecursive(@This())") != null;
    const marker = "@import(\"";
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, code, from, marker)) |at| {
        const name_start = at + marker.len;
        const name_end = std.mem.indexOfScalarPos(u8, code, name_start, '"') orelse break;
        from = name_end;
        const path = src[name_start..name_end];
        if (!std.mem.endsWith(u8, path, ".zig")) continue;
        if (refs_all or bindingIsUsed(code, at)) try out.append(gpa, path);
    }
}

/// False only for an import bound by a non-`pub` `const NAME = @import(...)`
/// whose NAME the rest of the file never mentions.
fn bindingIsUsed(code: []const u8, import_at: usize) bool {
    const eq = skipSpaceBack(code, import_at);
    if (eq == 0 or code[eq - 1] != '=') return true;
    if (eq >= 2 and std.mem.indexOfScalar(u8, "=!<>+-*/%|&^", code[eq - 2]) != null) return true;
    const name_end = skipSpaceBack(code, eq - 1);
    const name = wordBefore(code, name_end);
    if (name.len == 0 or std.mem.eql(u8, name, "_")) return true;
    const name_start = name_end - name.len;
    const kw_end = skipSpaceBack(code, name_start);
    const kw = wordBefore(code, kw_end);
    if (!std.mem.eql(u8, kw, "const") and !std.mem.eql(u8, kw, "var")) return true;
    const pub_end = skipSpaceBack(code, kw_end - kw.len);
    if (std.mem.eql(u8, wordBefore(code, pub_end), "pub")) return true;
    return identifierUsed(code, name, name_start, name_end);
}

fn expectImports(src: []const u8, expected: []const []const u8) !void {
    const gpa = std.testing.allocator;
    var got: std.ArrayList([]const u8) = .empty;
    defer got.deinit(gpa);
    try analyzedImports(gpa, src, &got);
    try std.testing.expectEqual(expected.len, got.items.len);
    for (expected, got.items) |want, have| try std.testing.expectEqualStrings(want, have);
}

test "an unreferenced const import is not analyzed" {
    try expectImports(
        \\const std = @import("std");
        \\const _e2e = @import("e2e_quic_basic.zig");
        \\test "x" {}
    , &.{});
}

test "a const import whose name is used is analyzed" {
    try expectImports(
        \\const helper = @import("helper.zig");
        \\test "x" { helper.run(); }
    , &.{"helper.zig"});
}

test "a discarded import inside a test block is analyzed" {
    try expectImports(
        \\test { _ = @import("a.zig"); _ = @import("sub/b.zig"); }
    , &.{ "a.zig", "sub/b.zig" });
}

test "a pub import is analyzed: an importer may use it" {
    try expectImports("pub const shared = @import(\"shared.zig\");\n", &.{"shared.zig"});
}

test "refAllDecls(@This()) references every import" {
    try expectImports(
        \\const _a = @import("a.zig");
        \\test { std.testing.refAllDecls(@This()); }
    , &.{"a.zig"});
}

test "an import used as an expression is analyzed" {
    try expectImports(
        \\test { std.testing.refAllDecls(@import("a.zig")); const T = @import("b.zig").T; _ = T; }
    , &.{ "a.zig", "b.zig" });
}

test "commented-out imports and names are ignored" {
    try expectImports(
        \\// const gone = @import("gone.zig");
        \\const kept = @import("kept.zig"); // kept is unused
        \\test {}
    , &.{});
}

test "a name used only as a field of another value does not count" {
    try expectImports(
        \\const proto = @import("proto.zig");
        \\test { _ = other.proto; }
    , &.{});
}

test "a name that is a prefix of another identifier does not count" {
    try expectImports(
        \\const util = @import("util.zig");
        \\test { _ = util_extra; }
    , &.{});
}

test "string literals that look like comments do not hide code" {
    try expectImports(
        \\const url = "http://x";
        \\const h = @import("h.zig");
        \\test { _ = url; _ = h; }
    , &.{"h.zig"});
}

test "non-zig imports are not file edges" {
    try expectImports("const std = @import(\"std\");\nconst g = @import(\"geode\");\ntest { _ = g; }\n", &.{});
}
