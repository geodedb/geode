const std = @import("std");

// Guard test: ensure parity-summary-diff.jsonl (when present) contains no REMOVED entries and
// enforces CHANGED entry threshold (default 0) unless explicitly allowed via env
//   GEODE_PARITY_CHANGED_MAX (integer)
// Skips locally if diff file not present (developing outside nightly context).
// CANARY: REQ=REQ-GQL-018; FEATURE="Transport Parity Summary Diff Guard"; ASPECT=GovernanceTest; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_018_ParitySummaryDiffGuard; OWNER=tooling; UPDATED=2025-09-24
// NOTE: This complements e2e_parity_summary_guard.zig (coverage). This file focuses on regressions.

test "governance: parity summary diff guard (optional)" {
    const allocator = std.testing.allocator;
    const diff_file_name = "parity-summary-diff.jsonl";
    var changed_allowed: usize = 0;
    if (std.process.getEnvVarOwned(allocator, "GEODE_PARITY_CHANGED_MAX")) |val| {
        defer allocator.free(val);
        changed_allowed = std.fmt.parseInt(usize, val, 10) catch 0;
    } else |_| {}

    // If diff file missing, skip (not a nightly run)
    if (std.fs.cwd().openFile(diff_file_name, .{ .mode = .read_only })) |file| {
        defer file.close();
        var buf_reader = std.Io.bufferedReader(file.reader());
        var in_stream = buf_reader.reader();
        var removed_count: usize = 0;
        var changed_count: usize = 0;
        while (true) {
            var line = std.ArrayList(u8).init(allocator);
            defer line.deinit();
            const read_ok = in_stream.streamUntilDelimiter(line.writer(), '\n', 1 << 16) catch |e| switch (e) {
                error.EndOfStream => break,
                else => return e,
            };
            if (!read_ok) break;
            const s = line.items;
            if (s.len == 0) continue;
            if (std.mem.indexOf(u8, s, "\"type\":\"REMOVED\"")) |_| {
                removed_count += 1;
            } else if (std.mem.indexOf(u8, s, "\"type\":\"CHANGED\"")) |_| {
                changed_count += 1;
            }
        }
        if (removed_count > 0) {
            std.debug.print("Parity diff guard failure: {d} REMOVED entries present (threshold 0).\n", .{removed_count});
            return error.RemovedParityTests;
        }
        if (changed_count > changed_allowed) {
            std.debug.print("Parity diff guard failure: {d} CHANGED entries > allowed {d}.\n", .{ changed_count, changed_allowed });
            return error.TooManyChangedParityTests;
        }
    } else |_| {
        return error.SkipZigTest; // optional guard
    }
}
