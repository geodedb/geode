const std = @import("std");

// CANARY: REQ=REQ-GQL-010; FEATURE="Governance"; ASPECT=NextPlanFreshnessGuard; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_NextPlanFreshnessGuard; OWNER=tooling; UPDATED=2025-09-22
// TestCANARY_REQ_GQL_010_NextPlanFreshnessGuard
// Verifies that the NEXT.md Generated date is considered fresh by the freshness checker script.
// Exits non-zero (test fail) if freshness script reports stale.

fn runFreshnessCheck(allocator: std.mem.Allocator) !void {
    var child = std.process.Child.init(&[_][]const u8{ "zig", "run", "scripts/next_freshness_check.zig" }, allocator);
    child.stdin_behavior = .Ignore;
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();

    var stdout_stream = child.stdout.?.reader();
    var stderr_stream = child.stderr.?.reader();
    var buf: [512]u8 = undefined;
    var out_builder = std.ArrayList(u8).init(allocator);
    defer out_builder.deinit();

    while (true) {
        const line = try stdout_stream.readUntilDelimiterOrEof(&buf, '\n');
        if (line == null) break;
        try out_builder.appendSlice(line.?);
    }

    const term = try child.wait();
    if (term.Exited != 0) {
        // collect stderr
        var err_builder = std.ArrayList(u8).init(allocator);
        defer err_builder.deinit();
        while (true) {
            const line = try stderr_stream.readUntilDelimiterOrEof(&buf, '\n');
            if (line == null) break;
            try err_builder.appendSlice(line.?);
        }
        std.debug.print("Freshness check failed. Stderr: {s}\n", .{err_builder.items});
        return error.FreshnessGuardFailed;
    }

    const output = out_builder.items;
    if (std.mem.indexOf(u8, output, "NEXT freshness OK") == null) {
        std.debug.print("Unexpected freshness output: {s}\n", .{output});
        return error.UnexpectedOutput;
    }
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const allocator = gpa.allocator();
    try runFreshnessCheck(allocator);
}
