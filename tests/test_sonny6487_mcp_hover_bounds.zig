// SONNY-6487 item 1: the MCP hover text for a function's parameter list and
// a procedure's YIELD column list was built in fixed 1024- and 2048-byte
// stack buffers with unchecked index writes (src/mcp/lsp.zig getHover). A
// signature longer than the buffer panicked with "index out of bounds" in
// Debug and ReleaseSafe (the release mode, Makefile ZIG_RELEASE_FLAGS) and
// wrote past the stack buffer in ReleaseFast. The shipped metadata is a
// comptime table well under both limits, so the overflow was latent; these
// tests pin that the signature text is allocated to its real length and that
// every shipped function and procedure hovers through the real entry point.

const std = @import("std");
const bridge = @import("mcp_bridge");
const lsp = bridge.lsp;
const md = bridge.language_metadata;

test "SONNY-6487: a function parameter list longer than 1024 bytes is formatted in full" {
    const allocator = std.testing.allocator;
    const long_name = "p" ** 300;
    const params = [_]md.FunctionParam{.{ .name = long_name, .type_name = "STRING" }} ** 5;

    const text = try lsp.formatHoverParams(allocator, &params);
    defer allocator.free(text);

    const one = long_name ++ ": STRING";
    try std.testing.expectEqual(one.len * 5 + 2 * 4, text.len);
    try std.testing.expect(text.len > 1024);
    try std.testing.expect(std.mem.startsWith(u8, text, one ++ ", " ++ one));
    try std.testing.expect(std.mem.endsWith(u8, text, ", " ++ one));
    try std.testing.expectEqual(@as(usize, 4), std.mem.count(u8, text, ", "));
}

test "SONNY-6487: a procedure column list longer than 2048 bytes is formatted in full" {
    const allocator = std.testing.allocator;
    const long_col = "c" ** 700;
    const cols = [_]md.ProcedureColumn{.{ .name = long_col, .type_name = "STRING", .doc = "d" }} ** 4;

    const text = try lsp.formatHoverColumns(allocator, &cols);
    defer allocator.free(text);

    try std.testing.expectEqual(long_col.len * 4 + 2 * 3, text.len);
    try std.testing.expect(text.len > 2048);
    try std.testing.expectEqualStrings(long_col ++ ", " ++ long_col ++ ", " ++ long_col ++ ", " ++ long_col, text);
}

test "SONNY-6487: empty parameter and column lists format as empty text" {
    const allocator = std.testing.allocator;
    const p = try lsp.formatHoverParams(allocator, &.{});
    defer allocator.free(p);
    try std.testing.expectEqualStrings("", p);
    const c = try lsp.formatHoverColumns(allocator, &.{});
    defer allocator.free(c);
    try std.testing.expectEqualStrings("", c);
}

test "SONNY-6487: every shipped function and procedure hovers with its full signature" {
    const allocator = std.testing.allocator;

    var functions_checked: usize = 0;
    for (md.functions) |entry| {
        // getHover resolves keyword -> function -> type -> procedure; a name
        // that is also a keyword hovers as the keyword.
        if (md.findKeyword(entry.name) != null) continue;
        const f = md.findFunction(entry.name).?;
        functions_checked += 1;
        const resp = try lsp.getHover(allocator, f.name, 1, 1);
        defer allocator.free(resp);
        const params = try lsp.formatHoverParams(allocator, f.params);
        defer allocator.free(params);
        const sig = try std.fmt.allocPrint(allocator, "({s}) ", .{params});
        defer allocator.free(sig);
        // The JSON string escapes nothing in a signature of identifiers,
        // type names, commas and colons, so the signature appears verbatim.
        if (std.mem.indexOf(u8, resp, sig) == null) {
            std.debug.print("hover for {s} lacks signature {s}: {s}\n", .{ f.name, sig, resp });
            return error.TestUnexpectedResult;
        }
    }

    try std.testing.expect(functions_checked > 0);

    var procedures_checked: usize = 0;
    for (md.procedures) |entry| {
        if (md.findKeyword(entry.name) != null or md.findFunction(entry.name) != null or md.findType(entry.name) != null) continue;
        const p = md.findProcedure(entry.name).?;
        procedures_checked += 1;
        const resp = try lsp.getHover(allocator, p.name, 1, 1);
        defer allocator.free(resp);
        try std.testing.expect(std.mem.indexOf(u8, resp, "\"contents\":null") == null);
        const cols = try lsp.formatHoverColumns(allocator, p.columns);
        defer allocator.free(cols);
        const yield_line = try std.fmt.allocPrint(allocator, "YIELD: {s}", .{cols});
        defer allocator.free(yield_line);
        if (std.mem.indexOf(u8, resp, yield_line) == null) {
            std.debug.print("hover for {s} lacks {s}: {s}\n", .{ p.name, yield_line, resp });
            return error.TestUnexpectedResult;
        }
    }
    try std.testing.expect(procedures_checked > 0);
}
