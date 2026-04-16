const std = @import("std");

// Negative test: remove ACCEPTANCE token from first slice to trigger next_slices failure.
// CANARY: REQ=REQ-GQL-010; FEATURE="Governance"; ASPECT=GovernanceNextSlicesNegative; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_GovernanceNextSlicesNegative; OWNER=tooling; UPDATED=2025-09-22

test "TestCANARY_REQ_GQL_010_GovernanceNextSlicesNegative" {
    var gpa = std.heap.DebugAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    // Read NEXT.md
    const path = "docs/NEXT.md";
    const original = try std.fs.cwd().readFileAlloc(alloc, path, 2 * 1024 * 1024);
    defer alloc.free(original);

    // Find first occurrence of "ACCEPTANCE:" and remove it (just the token) to cause validation failure.
    if (std.mem.indexOf(u8, original, "ACCEPTANCE:")) |pos| {
        var modified = try alloc.alloc(u8, original.len - "ACCEPTANCE:".len);
        defer alloc.free(modified);
        // Copy up to pos
        @memcpy(modified[0..pos], original[0..pos]);
        // Skip token, copy rest
        const rest_src_start = pos + "ACCEPTANCE:".len;
        @memcpy(modified[pos..], original[rest_src_start..]);
        // Write temp file
        const tmp_path = "docs/NEXT.md.tmp";
        try std.fs.cwd().writeFile(.{ .sub_path = tmp_path, .data = modified });
        defer std.fs.cwd().deleteFile(tmp_path) catch {};
        // Run governance with temp substituted (rename dance)
        const bak_path = "docs/NEXT.md.bak";
        try std.fs.cwd().rename(path, bak_path);
        defer {
            // Restore original NEXT.md
            std.fs.cwd().deleteFile(path) catch {};
            std.fs.cwd().rename(bak_path, path) catch {};
        }
        try std.fs.cwd().rename(tmp_path, path);

        var child = std.process.Child.init(&[_][]const u8{ "zig", "run", "scripts/governance_ci.zig" }, alloc);
        child.stdin_behavior = .Ignore;
        child.stdout_behavior = .Pipe;
        child.stderr_behavior = .Pipe;
        try child.spawn();
        const term = try child.wait();
        // Expect failure exit code 2
        try std.testing.expectEqual(@as(u8, 2), term.Exited);
    } else {
        // If token not found, fail test (unexpected)
        return error.MissingToken;
    }
}
