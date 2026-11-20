// SPDX-License-Identifier: Apache-2.0
// Copyright (c) 2024-2026 CodePros
//
// SONNY-6862: keys read in the same read as Ctrl+R bypassed the reverse
// history search.
//
// src/client/repl/repl_loop.zig processInput ran Ctrl+R's .search action,
// whose handleSearch reads the terminal itself, while the keys after Ctrl+R
// were still in processInput's read buffer: the search waited for keys that
// had already been read, and once it ended they were handled as line-editing
// input. Keys read with the Enter that ends the search were dropped.
//
// The real `geode shell` through a pseudo-terminal against a real `geode
// serve`, stopped while Ctrl+R, the search term and two Enters are written
// one write each, so all of them wait at one read.

const std = @import("std");
const builtin = @import("builtin");
const testing = std.testing;
const repl = @import("repl_pty_session.zig");

test "SONNY-6862: geode shell feeds the keys read with Ctrl+R to the history search" {
    if (builtin.os.tag != .linux) return error.SkipZigTest;
    var shell: repl.Shell = undefined;
    try shell.start(testing.allocator, .{ .history = true });
    defer shell.stop();
    const s = &shell.session;

    const first = s.transcript.items.len;
    for ("RETURN 68620 + 1 AS first\r") |c| try s.writeAndWaitRead(&.{c});
    if (!s.waitFor("68621", first, 30_000)) {
        s.dumpFrom("SONNY-6862 first statement", first);
        return error.FirstStatementFailed;
    }
    s.waitQuiet(200, 5_000);

    // Ctrl+R, the term "+ 1 AS f", Enter (take the match) and Enter (run
    // it), all in one read.
    const from = s.transcript.items.len;
    try s.typeWhileBusy(&.{ "\x12", "+", " ", "1", " ", "A", "S", " ", "f", "\r", "\r" });
    const ok = s.waitFor("68621", from, 15_000) and
        std.mem.indexOfPos(u8, s.transcript.items, from, "(reverse-i-search)`+ 1 AS f'") != null and
        std.mem.indexOfPos(u8, s.transcript.items, from, "Error") == null;
    if (!ok) {
        s.dumpFrom("SONNY-6862 Ctrl+R and the search keys in one read", from);
        return error.SearchKeysBypassedSearch;
    }
}
