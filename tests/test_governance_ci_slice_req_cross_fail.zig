const std = @import("std");

// Negative test: remove REQ-GQL-### token from first slice header in NEXT.md to trigger slice_req_crosscheck failure.
// CANARY: REQ=REQ-GQL-010; FEATURE="Governance"; ASPECT=GovernanceSliceReqCrosscheckNegative; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_GovernanceSliceReqCrosscheckNegative; OWNER=tooling; UPDATED=2025-09-22

test "TestCANARY_REQ_GQL_010_GovernanceSliceReqCrosscheckNegative" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer _ = gpa.deinit();
    const alloc = gpa.allocator();

    const path = "docs/NEXT.md";
    const original = try std.fs.cwd().readFileAlloc(alloc, path, 2 * 1024 * 1024);
    defer alloc.free(original);

    // Locate first slice header line containing "### Slice S-" then the REQ-GQL token.
    if (std.mem.indexOf(u8, original, "### Slice S-")) |hpos| {
        // Find end of line
        var end = hpos;
        while (end < original.len and original[end] != '\n') : (end += 1) {}
        const header_line = original[hpos..end];
        if (std.mem.indexOf(u8, header_line, "REQ-GQL-")) |rpos_rel| {
            const rpos = hpos + rpos_rel;
            var r_end = rpos + 8; // after REQ-GQL-
            while (r_end < original.len and original[r_end] >= '0' and original[r_end] <= '9') : (r_end += 1) {}
            // Remove the REQ-GQL-### substring
            const remove_len = r_end - rpos;
            var modified = try alloc.alloc(u8, original.len - remove_len);
            defer alloc.free(modified);
            @memcpy(modified[0..rpos], original[0..rpos]);
            @memcpy(modified[rpos..], original[r_end..]);
            // Write temp, swap, run governance
            const tmp_path = "docs/NEXT.md.tmp";
            try std.fs.cwd().writeFile(.{ .sub_path = tmp_path, .data = modified });
            defer std.fs.cwd().deleteFile(tmp_path) catch {};
            const bak_path = "docs/NEXT.md.bak";
            try std.fs.cwd().rename(path, bak_path);
            defer {
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
            // Expect governance failure exit code 2
            try std.testing.expectEqual(@as(u8, 2), term.Exited);
            return;
        } else {
            return error.ReqTokenNotFound;
        }
    } else {
        return error.SliceHeaderNotFound;
    }
}
