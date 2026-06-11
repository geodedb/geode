// Signature-help provider for the GQL/Geode LSP.
// Split out of features.zig (#806, QUALITY_GAP_ANALYSIS) — features.zig
// remains the public facade re-exporting `provideSignatureHelp`.

const std = @import("std");
const Allocator = std.mem.Allocator;
const protocol = @import("../protocol.zig");
const Document = @import("../document.zig").Document;
const geode = @import("geode");
const language_metadata = geode.language_metadata;

// ============================================================================
// Signature Help Provider
// CANARY: REQ=REQ-LSP-SIGHEP-001; FEATURE="SignatureHelp"; ASPECT=FunctionParams; STATUS=IMPL; OWNER=lsp; UPDATED=2026-01-27
// ============================================================================

/// Provide signature help for function calls
pub fn provideSignatureHelp(allocator: Allocator, doc: *const Document, line: u32, character: u32) !?protocol.SignatureHelp {
    const offset = doc.getOffset(line, character) orelse return null;

    // Find the opening parenthesis and function name
    var paren_depth: i32 = 0;
    var comma_count: u32 = 0;
    var paren_pos: ?usize = null;
    var i: usize = offset;
    var in_string = false;
    var string_char: u8 = 0;

    // Scan backwards to find the opening paren
    while (i > 0) {
        i -= 1;
        const c = doc.text[i];

        // Handle strings (scanning backwards)
        if (!in_string and (c == '\'' or c == '"')) {
            // Check if this is the end of a string
            var quote_count: usize = 0;
            var j = i;
            while (j > 0 and doc.text[j] == c) {
                quote_count += 1;
                j -= 1;
            }
            if (quote_count % 2 == 1) {
                in_string = true;
                string_char = c;
            }
            continue;
        }
        if (in_string and c == string_char) {
            in_string = false;
            continue;
        }
        if (in_string) continue;

        if (c == ')') {
            paren_depth += 1;
        } else if (c == '(') {
            if (paren_depth == 0) {
                paren_pos = i;
                break;
            }
            paren_depth -= 1;
        } else if (c == ',' and paren_depth == 0) {
            comma_count += 1;
        }
    }

    const open_paren = paren_pos orelse return null;

    // Find function name before the paren
    var name_end = open_paren;
    while (name_end > 0 and (doc.text[name_end - 1] == ' ' or doc.text[name_end - 1] == '\t')) {
        name_end -= 1;
    }

    var name_start = name_end;
    while (name_start > 0 and (std.ascii.isAlphanumeric(doc.text[name_start - 1]) or doc.text[name_start - 1] == '_')) {
        name_start -= 1;
    }

    if (name_start == name_end) return null;

    const func_name = doc.text[name_start..name_end];

    // Look up function in metadata
    const fn_info = language_metadata.findFunction(func_name) orelse return null;

    // Build parameter list
    var params = std.ArrayList(protocol.ParameterInformation).initCapacity(allocator, 8) catch return error.OutOfMemory;
    defer params.deinit(allocator);

    for (fn_info.params) |param| {
        var param_label = std.ArrayList(u8).initCapacity(allocator, 64) catch return error.OutOfMemory;
        defer param_label.deinit(allocator);

        try param_label.appendSlice(allocator, param.name);
        try param_label.appendSlice(allocator, ": ");
        try param_label.appendSlice(allocator, param.type_name);
        if (param.optional) {
            try param_label.append(allocator, '?');
        }

        try params.append(allocator, .{
            .label = try allocator.dupe(u8, param_label.items),
            .documentation = null,
        });
    }

    // Build signature label
    var sig_label = std.ArrayList(u8).initCapacity(allocator, 128) catch return error.OutOfMemory;
    defer sig_label.deinit(allocator);

    try sig_label.appendSlice(allocator, fn_info.name);
    try sig_label.append(allocator, '(');
    for (fn_info.params, 0..) |param, idx| {
        if (idx > 0) try sig_label.appendSlice(allocator, ", ");
        try sig_label.appendSlice(allocator, param.name);
        try sig_label.appendSlice(allocator, ": ");
        try sig_label.appendSlice(allocator, param.type_name);
        if (param.optional) try sig_label.append(allocator, '?');
    }
    try sig_label.appendSlice(allocator, ") → ");
    try sig_label.appendSlice(allocator, fn_info.return_type);

    // Create signature
    const signatures = try allocator.alloc(protocol.SignatureInformation, 1);
    signatures[0] = .{
        .label = try allocator.dupe(u8, sig_label.items),
        .documentation = .{
            .kind = .plaintext,
            .value = fn_info.doc,
        },
        .parameters = try allocator.dupe(protocol.ParameterInformation, params.items),
        .activeParameter = if (comma_count < fn_info.params.len) comma_count else null,
    };

    return protocol.SignatureHelp{
        .signatures = signatures,
        .activeSignature = 0,
        .activeParameter = if (comma_count < fn_info.params.len) comma_count else null,
    };
}
// ============================================================================
// Unit Tests for Signature Help
// ============================================================================

test "provideSignatureHelp - function with params" {
    const allocator = std.testing.allocator;
    const doc = try Document.init(allocator, "file:///test.gql", "RETURN count(", 1);
    defer doc.deinit();

    const sig = try provideSignatureHelp(allocator, doc, 0, 13);

    if (sig) |s| {
        defer {
            for (s.signatures) |si| {
                allocator.free(si.label);
                if (si.parameters) |ps| {
                    for (ps) |p| allocator.free(p.label);
                    allocator.free(ps);
                }
            }
            allocator.free(s.signatures);
        }

        try std.testing.expect(s.signatures.len == 1);
        try std.testing.expect(std.mem.startsWith(u8, s.signatures[0].label, "count("));
    } else {
        try std.testing.expect(false); // Should have returned signature
    }
}

test "provideSignatureHelp - returns null for non-function" {
    const allocator = std.testing.allocator;
    const doc = try Document.init(allocator, "file:///test.gql", "RETURN n", 1);
    defer doc.deinit();

    const sig = try provideSignatureHelp(allocator, doc, 0, 7);
    try std.testing.expect(sig == null);
}
