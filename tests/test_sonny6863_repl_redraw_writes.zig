// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6863: `geode shell` redrew its input line one byte per write(2).
//
// src/client/repl/repl_loop.zig renderPrompt wrote the input buffer a byte
// at a time: a 4 KiB line cost about 4,096 syscalls per redraw, every key,
// and on a loaded CI runner it widened the window in which keys pile up
// behind a redraw (SONNY-6846).
//
// The real `geode shell` through a pseudo-terminal against a real `geode
// serve`. A 4,200-byte line is pasted; then one key (Ctrl+A) makes the shell
// redraw it once, and the shell's own write(2) count (/proc/<pid>/io syscw)
// is read before and after.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const repl = @import("repl_pty_session.zig");

/// One redraw is the prompt, the line and a few cursor moves: a handful of
/// writes, not one per byte of the line.
const max_writes_per_redraw = 16;

test "SONNY-6863: geode shell redraws a 4 KiB line in a few writes, not one per byte" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    const allocator = testing.allocator;
    var shell: repl.Shell = undefined;
    try shell.start(allocator, .{});
    defer shell.stop();
    const s = &shell.session;

    var long_buf: [4200]u8 = undefined;
    @memset(&long_buf, 'a');
    const line = try std.fmt.allocPrint(allocator, "RETURN size('{s}') AS n", .{long_buf[0..]});
    defer allocator.free(line);

    const before_paste = s.transcript.items.len;
    s.write("\x1b[200~");
    var i: usize = 0;
    while (i < line.len) {
        const n = @min(512, line.len - i);
        s.write(line[i..][0..n]);
        i += n;
        repl.sleepMs(10);
        s.pump();
    }
    s.write("\x1b[201~");
    if (!s.waitFor("') AS n", before_paste, 30_000)) {
        s.dumpFrom("SONNY-6863 paste not drawn", before_paste);
        return error.PasteNotDrawn;
    }
    s.waitQuiet(300, 10_000);

    const writes_before = try s.procIo("syscw");
    const before_redraw = s.transcript.items.len;
    try s.writeAndWaitRead("\x01"); // Ctrl+A: cursor to the start, one full redraw
    if (!s.waitFor("') AS n", before_redraw, 30_000)) {
        s.dumpFrom("SONNY-6863 no redraw after Ctrl+A", before_redraw);
        return error.NoRedraw;
    }
    s.waitQuiet(300, 10_000);
    const writes = (try s.procIo("syscw")) - writes_before;
    std.debug.print("\nSONNY-6863: one redraw of a {d}-byte line took {d} write syscalls\n", .{ line.len, writes });
    if (writes > max_writes_per_redraw) return error.RedrawWritesPerByte;
}
