const std = @import("std");

// CANARY: REQ=REQ-GQL-010; FEATURE="Freshness Pre-Warn"; ASPECT=FreshnessPreWarn; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_010_FreshnessPreWarn; OWNER=tooling; UPDATED=2026-11-14

pub fn main() !void {}

test "TestCANARY_REQ_GQL_010_FreshnessPreWarn" {
    const allocator = std.testing.allocator;
    var child = std.ChildProcess.init(&[_][]const u8{ "bash", "scripts/nightly_freshness_guard.sh", "--threshold=120" }, allocator); // large threshold to force ok=true
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();
    if (child.stdout) |*out| try stdout_buf.writer().writeAll(try out.reader().readAllAlloc(allocator, 16 * 1024));
    const term = try child.wait();
    switch (term) {
        .Exited => |code| try std.testing.expect(code == 0),
        else => return error.UnexpectedExit,
    }
    const out = stdout_buf.items;
    try std.testing.expect(std.mem.indexOf(u8, out, "\"threshold_days\":120") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"stale_candidates\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"scanned\":") != null);
}
