const std = @import("std");

// CANARY: REQ=REQ-GQL-010; FEATURE="Governance Dry Run Wrapper"; ASPECT=DryRunWrapper; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_010_GovernanceDryRunWrapper; OWNER=tooling; UPDATED=2026-11-14

pub fn main() !void {}

test "TestCANARY_REQ_GQL_010_GovernanceDryRunWrapper" {
    const allocator = std.testing.allocator;
    var child = std.ChildProcess.init(&[_][]const u8{ "bash", "scripts/governance-dry-run.sh" }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();
    if (child.stdout) |*out| try stdout_buf.writer().writeAll(try out.reader().readAllAlloc(allocator, 16 * 1024));
    const term = try child.wait();
    // Script always exits 0 (by design) so assert that.
    switch (term) {
        .Exited => |code| try std.testing.expect(code == 0),
        else => return error.UnexpectedExit,
    }
    const out = stdout_buf.items;
    try std.testing.expect(std.mem.indexOf(u8, out, "\"dry_run\":true") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"original_exit\":") != null);
    // Must include ok field
    try std.testing.expect(std.mem.indexOf(u8, out, "\"ok\":") != null);
}
