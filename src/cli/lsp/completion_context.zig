const std = @import("std");

pub const Kind = enum { keyword, label, edge_type, property, variable, parameter };

pub const Pos = struct { line: u32, character: u32 };

pub const Result = struct {
    kind: Kind,
    prefix: []const u8,
    var_name: ?[]const u8 = null,
};

pub fn analyze(text: []const u8, pos: Pos) Result {
    const offset = lineColToOffset(text, pos) orelse return .{ .kind = .keyword, .prefix = "" };
    const prefix_text = text[0..offset];

    var i: usize = prefix_text.len;
    while (i > 0 and (std.ascii.isAlphanumeric(prefix_text[i - 1]) or prefix_text[i - 1] == '_')) : (i -= 1) {}
    const prefix = prefix_text[i..];
    const head = prefix_text[0..i];

    var j: usize = head.len;
    while (j > 0 and std.ascii.isWhitespace(head[j - 1])) : (j -= 1) {}
    if (j == 0) return .{ .kind = .keyword, .prefix = prefix };

    const trig = head[j - 1];

    if (trig == ':') {
        var k: usize = j - 1;
        while (k > 0 and std.ascii.isWhitespace(head[k - 1])) : (k -= 1) {}
        while (k > 0 and (std.ascii.isAlphanumeric(head[k - 1]) or head[k - 1] == '_')) : (k -= 1) {}
        while (k > 0 and std.ascii.isWhitespace(head[k - 1])) : (k -= 1) {}
        if (k > 0) {
            const opener = head[k - 1];
            if (opener == '(') return .{ .kind = .label, .prefix = prefix };
            if (opener == '[') return .{ .kind = .edge_type, .prefix = prefix };
        }
        return .{ .kind = .label, .prefix = prefix };
    }

    if (trig == '.') {
        var k: usize = j - 1;
        while (k > 0 and (std.ascii.isAlphanumeric(head[k - 1]) or head[k - 1] == '_')) : (k -= 1) {}
        const var_name = head[k .. j - 1];
        return .{ .kind = .property, .prefix = prefix, .var_name = var_name };
    }

    if (trig == '$') return .{ .kind = .parameter, .prefix = prefix };

    return .{ .kind = .keyword, .prefix = prefix };
}

pub fn resolveVarLabel(text: []const u8, var_name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        if (text[i] != '(') continue;
        var j = i + 1;
        while (j < text.len and std.ascii.isWhitespace(text[j])) : (j += 1) {}
        const var_start = j;
        while (j < text.len and (std.ascii.isAlphanumeric(text[j]) or text[j] == '_')) : (j += 1) {}
        const found_var = text[var_start..j];
        if (!std.mem.eql(u8, found_var, var_name)) continue;
        while (j < text.len and std.ascii.isWhitespace(text[j])) : (j += 1) {}
        if (j >= text.len or text[j] != ':') continue;
        j += 1;
        while (j < text.len and std.ascii.isWhitespace(text[j])) : (j += 1) {}
        const lbl_start = j;
        while (j < text.len and (std.ascii.isAlphanumeric(text[j]) or text[j] == '_')) : (j += 1) {}
        return text[lbl_start..j];
    }
    return null;
}

/// Extract every variable bound in a node `(var…)` or edge `[var…]` pattern.
///
/// The returned slice is owned by `allocator` and must be freed by the caller
/// with `allocator.free(result)`. **The element strings are NOT owned**: each
/// `[]const u8` is a subslice of the input `text`. The caller frees only the
/// outer slice; the strings remain valid for the lifetime of `text`. If a
/// caller needs names that outlive `text`, they must dupe each element.
///
/// Names are deduplicated (each variable appears at most once in the result).
/// Iteration order matches `StringHashMap` insertion order and is not stable.
pub fn scopedVariables(allocator: std.mem.Allocator, text: []const u8) ![][]const u8 {
    var set = std.StringHashMap(void).init(allocator);
    defer set.deinit();
    var i: usize = 0;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        if (c != '(' and c != '[') continue;
        var j = i + 1;
        while (j < text.len and std.ascii.isWhitespace(text[j])) : (j += 1) {}
        const start = j;
        while (j < text.len and (std.ascii.isAlphanumeric(text[j]) or text[j] == '_')) : (j += 1) {}
        if (j == start) continue;
        try set.put(text[start..j], {});
    }
    var out = try std.ArrayList([]const u8).initCapacity(allocator, set.count());
    var it = set.keyIterator();
    while (it.next()) |k| try out.append(allocator, k.*);
    return out.toOwnedSlice(allocator);
}

fn lineColToOffset(text: []const u8, pos: Pos) ?usize {
    var line: u32 = 0;
    var col: u32 = 0;
    for (text, 0..) |c, i| {
        if (line == pos.line and col == pos.character) return i;
        if (c == '\n') {
            line += 1;
            col = 0;
        } else col += 1;
    }
    if (line == pos.line and col == pos.character) return text.len;
    return null;
}
