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
