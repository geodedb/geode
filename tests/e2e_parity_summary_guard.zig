const std = @import("std");

// Guard test: ensure each transport parity test file has an entry in parity-summary.jsonl
// when the summary file is present (nightly workflow). Skips locally if file missing.
// CANARY: REQ=REQ-GQL-018; FEATURE="Transport Parity Summary Guard"; ASPECT=GovernanceTest; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_018_ParitySummaryGuard; OWNER=tooling; UPDATED=2026-11-14
test "governance: parity summary guard (optional)" {
    const allocator = std.testing.allocator;
    // If summary file not present, skip (developer local context)
    if (std.fs.cwd().openFile("parity-summary.jsonl", .{ .mode = .read_only })) |file| {
        defer file.close();
        // Collect hashes by test name
        var summary_map = std.StringHashMap(bool).init(allocator);
        defer summary_map.deinit();
        var buf_reader = std.Io.bufferedReader(file.reader());
        var in_stream = buf_reader.reader();
        while (true) {
            var line = std.ArrayList(u8).init(allocator);
            defer line.deinit();
            const read_ok = in_stream.streamUntilDelimiter(line.writer(), '\n', 1 << 16) catch |e| switch (e) {
                error.EndOfStream => break,
                else => return e,
            };
            if (!read_ok) break;
            const slice = line.items;
            if (slice.len == 0) continue;
            if (std.mem.indexOf(u8, slice, "\"test\":") != null) {
                // crude extract between "test":" and next "
                if (std.mem.indexOf(u8, slice, "\"test\":\"")) |pos| {
                    const start = pos + 8;
                    if (std.mem.indexOfPos(u8, slice, start, "\"")) |end| {
                        const name = slice[start..end];
                        try summary_map.put(name, true);
                    }
                }
            }
        }
        // Enumerate parity test files
        var dir = try std.fs.cwd().openDir("tests", .{ .iterate = true });
        defer dir.close();
        var it = dir.iterate();
        var missing = std.ArrayList([]const u8).init(allocator);
        defer missing.deinit();
        while (try it.next()) |entry| {
            if (entry.kind != .file) continue;
            if (std.mem.startsWith(u8, entry.name, "e2e_protocol_transport_parity_")) {
                if (!summary_map.contains(entry.name)) {
                    try missing.append(entry.name);
                }
            }
        }
        if (missing.items.len > 0) {
            std.debug.print("Missing parity summary entries for {d} tests:\n", .{missing.items.len});
            for (missing.items) |m| std.debug.print(" - {s}\n", .{m});
            return error.MissingParitySummaryEntries;
        }
    } else |_| {
        return error.SkipZigTest; // optional
    }
}
