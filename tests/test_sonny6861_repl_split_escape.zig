// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6861: `geode shell` misread an escape sequence split across two
// terminal reads.
//
// src/client/repl/repl_loop.zig processInput parsed each read on its own. The
// bracketed-paste end marker ESC[201~ was recognised only when all six bytes
// were in one read: split, the shell stayed in paste mode and took the Enter
// after it as pasted text. Any other sequence (arrows, Ctrl+arrows, Alt+key)
// split across reads was parsed as ESC and then literal characters.
//
// The real `geode shell` through a pseudo-terminal against a real `geode
// serve`. Each sequence is written in two parts; the second is written only
// once the shell has read the first (it made a read(2) and nothing is left
// unread), so the two parts always arrive in two reads.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const repl = @import("repl_pty_session.zig");

fn typeKeys(s: *repl.Session, text: []const u8) !void {
    for (0..text.len) |i| try s.writeAndWaitRead(text[i..][0..1]);
}

test "SONNY-6861: geode shell ends a bracketed paste whose end marker is split across reads" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var shell: repl.Shell = undefined;
    try shell.start(testing.allocator, .{});
    defer shell.stop();
    const s = &shell.session;

    const from = s.transcript.items.len;
    try s.writeAndWaitRead("\x1b[200~RETURN 68610 + 1 AS pasted");
    try s.writeAndWaitRead("\x1b[20");
    try s.writeAndWaitRead("1~");
    try s.writeAndWaitRead("\r");
    const ok = s.waitFor("68611", from, 15_000) and std.mem.indexOfPos(u8, s.transcript.items, from, "Error") == null;
    if (!ok) {
        s.dumpFrom("SONNY-6861 paste end marker split as ESC[20 | 1~", from);
        return error.PasteEndMarkerSplitMisread;
    }
}

test "SONNY-6861: geode shell reads Left, Ctrl+Left and Alt+B split across reads as the key" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var shell: repl.Shell = undefined;
    try shell.start(testing.allocator, .{});
    defer shell.stop();
    const s = &shell.session;

    const Case = struct { line: []const u8, first: []const u8, rest: []const u8, want: []const u8, result: []const u8 };
    const cases = [_]Case{
        // Left as ESC | [D: the cursor goes back over 'b', 'x' lands before it.
        .{ .line = "RETURN 68610 + 2 AS ab", .first = "\x1b", .rest = "[D", .want = "axb", .result = "68612" },
        // Left as ESC[ | D.
        .{ .line = "RETURN 68610 + 3 AS cd", .first = "\x1b[", .rest = "D", .want = "cxd", .result = "68613" },
        // Ctrl+Left as ESC[1;5 | D: back one word, 'x' lands before "ef".
        .{ .line = "RETURN 68610 + 4 AS ef", .first = "\x1b[1;5", .rest = "D", .want = "xef", .result = "68614" },
        // Alt+B as ESC | b: back one word.
        .{ .line = "RETURN 68610 + 5 AS gh", .first = "\x1b", .rest = "b", .want = "xgh", .result = "68615" },
    };
    for (cases) |c| {
        const from = s.transcript.items.len;
        try typeKeys(s, c.line);
        try s.writeAndWaitRead(c.first);
        try s.writeAndWaitRead(c.rest);
        try s.writeAndWaitRead("x");
        try s.writeAndWaitRead("\r");
        const ok = s.waitFor(c.result, from + c.line.len, 15_000) and std.mem.indexOfPos(u8, s.transcript.items, from, c.want) != null and std.mem.indexOfPos(u8, s.transcript.items, from, "Error") == null;
        if (!ok) {
            std.debug.print("\ncase: '{s}' then {any} | {any}, want column '{s}'\n", .{ c.line, c.first, c.rest, c.want });
            s.dumpFrom("SONNY-6861 key split across reads", from);
            return error.SplitEscapeSequenceMisread;
        }
        s.waitQuiet(100, 5_000);
    }
}

test "SONNY-6861: a bare ESC with nothing after it is still ESC, and the line goes on" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var shell: repl.Shell = undefined;
    try shell.start(testing.allocator, .{});
    defer shell.stop();
    const s = &shell.session;

    const from = s.transcript.items.len;
    try typeKeys(s, "RETURN 68610 + 6 AS ");
    try s.writeAndWaitRead("\x1b");
    // Longer than the shell waits for the rest of a sequence: a lone ESC.
    repl.sleepMs(1_000);
    try typeKeys(s, "bare");
    try s.writeAndWaitRead("\r");
    const ok = s.waitFor("68616", from, 15_000) and
        std.mem.indexOfPos(u8, s.transcript.items, from, "Error") == null;
    if (!ok) {
        s.dumpFrom("SONNY-6861 bare ESC", from);
        return error.BareEscBroken;
    }
}
