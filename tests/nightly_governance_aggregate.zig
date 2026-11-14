const std = @import("std");

// CANARY: REQ=REQ-GQL-010; FEATURE="Governance Aggregate Nightly"; ASPECT=GovernanceAggregate; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_010_GovernanceAggregate; OWNER=tooling; UPDATED=2026-11-14

pub fn main() !void {}

test "TestCANARY_REQ_GQL_010_GovernanceAggregate" {
    const allocator = std.testing.allocator;
    var child = std.ChildProcess.init(&[_][]const u8{ "bash", "scripts/nightly_governance_aggregate.sh" }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    var stdout_buf = std.ArrayList(u8).init(allocator);
    defer stdout_buf.deinit();
    if (child.stdout) |*out| try stdout_buf.writer().writeAll(try out.reader().readAllAlloc(allocator, 32 * 1024));
    const term = try child.wait();
    switch (term) {
        .Exited => |code| try std.testing.expect(code == 0),
        else => return error.UnexpectedExit,
    }
    const out = stdout_buf.items;
    try std.testing.expect(std.mem.indexOf(u8, out, "\"delta\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"freshness\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"governance\":") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"timestamp\":") != null);
}
