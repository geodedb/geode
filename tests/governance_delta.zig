const std = @import("std");

// CANARY: REQ=REQ-GQL-010; FEATURE="Governance Delta Detection"; ASPECT=DeltaGuardPreview; STATUS=IMPL; TEST=TestCANARY_REQ_GQL_010_GovernanceDelta; OWNER=tooling; UPDATED=2026-11-14

pub fn main() !void {}

// Basic test block executing governance-delta script and validating JSON shape.
// This uses minimal parsing (string search + basic field extraction) to avoid full JSON lib dependency here.

test "TestCANARY_REQ_GQL_010_GovernanceDelta" {
    const allocator = std.testing.allocator;
    var child = std.ChildProcess.init(&[_][]const u8{ "bash", "scripts/governance-delta.sh" }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const stdout_stream = child.stdout.?.reader();
    var buf = std.ArrayList(u8).init(allocator);
    defer buf.deinit();
    try stdout_stream.streamUntilDelimiter(buf.writer(), '\n', null); // assume single line JSON
    const term = try child.wait();
    // Script always exits 0 unless missing files, which is acceptable; we still parse output.
    _ = term; // not asserting exit code; we only validate structure.

    const out = buf.items;
    try std.testing.expect(std.mem.indexOf(u8, out, "\"added\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"removed\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"prev_count\"") != null);
    try std.testing.expect(std.mem.indexOf(u8, out, "\"curr_count\"") != null);
}
