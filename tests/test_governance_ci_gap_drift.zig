const std = @import("std");

// Negative drift test: create a temp copy of GAP_ANALYSIS.md with altered total to force failure.
// We run governance pointing at modified file by temporarily overwriting then restoring.
// CANARY: REQ=REQ-GQL-010; FEATURE="Governance"; ASPECT=GovernanceGapDriftDetection; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_GovernanceGapDriftDetection; OWNER=tooling; UPDATED=2025-09-22

test "TestCANARY_REQ_GQL_010_GovernanceGapDriftDetection" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();
    // Read original
    var cwd = std.fs.cwd();
    const path = "docs/GAP_ANALYSIS.md";
    const original = try cwd.readFileAlloc(alloc, path, 4 * 1024 * 1024);
    defer alloc.free(original);
    // Create drifted copy by locating the Total aspects table row and summary line.
    var modified = try alloc.dupe(u8, original);
    const table_marker = "| Total aspects (rows) | ";
    const summary_marker = "-- Total aspect rows (status.csv): ";
    if (std.mem.indexOf(u8, modified, table_marker)) |pos| {
        const i: usize = pos + table_marker.len;
        if (i + 3 <= modified.len) @memcpy(modified[i .. i + 3], "999") else return error.TotalRowPatternNotFound;
    } else return error.TotalRowPatternNotFound;
    if (std.mem.indexOf(u8, modified, summary_marker)) |pos| {
        const i: usize = pos + summary_marker.len;
        if (i + 3 <= modified.len) @memcpy(modified[i .. i + 3], "999") else return error.SummaryPatternNotFound;
    } else return error.SummaryPatternNotFound;
    // Write modified back
    try cwd.writeFile(.{ .sub_path = path, .data = modified });
    defer {
        // Restore original
        cwd.writeFile(.{ .sub_path = path, .data = original }) catch {};
    }
    defer alloc.free(modified);
    var child = std.process.Child.init(&[_][]const u8{ "zig", "run", "scripts/governance_ci.zig" }, alloc);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const term = try child.wait();
    // Expect governance failure exit code 2
    try std.testing.expectEqual(@as(u8, 2), term.Exited);
}
