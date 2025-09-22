const std = @import("std");
// slice_delta_guard.zig
// Stub implementation: compares current slice count in docs/NEXT.md with previous snapshot recorded in slices_prev.count (if exists).
// If difference > 25% (arbitrary placeholder threshold) without override env SLICES_ALLOW_DELTA, returns policy failure.
// Exit codes: 0 success, 2 policy violation, 1 usage/internal.
// CANARY: REQ=REQ-GQL-010; FEATURE="Governance"; ASPECT=SliceDeltaGuardStub; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_SliceDeltaGuardStub; OWNER=tooling; UPDATED=2025-09-22

fn countSlices(data: []const u8) usize {
    var count: usize = 0;
    var it = std.mem.splitSequence(u8, data, "\n### Slice S-");
    _ = it.next(); // preamble
    while (it.next()) |_| count += 1;
    return count;
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const a = gpa.allocator();
    const next_data = std.fs.cwd().readFileAlloc(a, "docs/NEXT.md", 2 * 1024 * 1024) catch {
        std.debug.print("{s}\n", .{"slice_delta_guard: read NEXT fail"});
        std.process.exit(2);
    };
    defer a.free(next_data);
    const cur = countSlices(next_data);
    var prev: usize = cur;
    if (std.fs.cwd().readFileAlloc(a, "slices_prev.count", 64)) |prev_bytes| {
        defer a.free(prev_bytes);
        var it = std.mem.splitScalar(u8, prev_bytes, '\n');
        if (it.next()) |line| {
            prev = std.fmt.parseUnsigned(usize, line, 10) catch cur;
        }
    } else |_| {}
    const allow_env = std.process.getEnvVarOwned(a, "SLICES_ALLOW_DELTA") catch null;
    defer if (allow_env) |v| a.free(v);
    const threshold: f64 = 0.25;
    const diff = if (cur > prev) cur - prev else prev - cur;
    const pct = if (prev == 0) 0 else @as(f64, @floatFromInt(diff)) / @as(f64, @floatFromInt(prev));
    var stdout = std.io.getStdOut().writer();
    if (pct > threshold and allow_env == null) {
        try stdout.print("{\"type\":\"slice_delta_guard\",\"status\":\"failure\",\"prev\":{d},\"cur\":{d},\"pct\":{d:.4}}\n", .{ prev, cur, pct });
        std.process.exit(2);
    }
    try stdout.print("{\"type\":\"slice_delta_guard\",\"status\":\"success\",\"prev\":{d},\"cur\":{d},\"pct\":{d:.4}}\n", .{ prev, cur, pct });
    // Update snapshot (best-effort)
    var file = std.fs.cwd().createFile("slices_prev.count", .{}) catch return;
    defer file.close();
    _ = file.writeAll(@constCast(std.fmt.allocPrint(a, "{d}\n", .{cur}) catch return));
}
