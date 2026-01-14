const std = @import("std");

// CANARY: REQ=REQ-GQL-010; FEATURE="Status JSON Hash Integrity"; ASPECT=StatusJsonHashIntegrity; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_010_StatusJsonHashIntegrity; OWNER=tooling; UPDATED=2025-09-22

test "TestCANARY_REQ_GQL_010_StatusJsonHashIntegrity" {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(!gpa.deinit());
    const alloc = gpa.allocator();

    // Read status.json
    const status_data = try std.fs.cwd().readFileAlloc(alloc, "status.json", 1024 * 1024);
    defer alloc.free(status_data);

    // Compute sha256
    var h = std.crypto.hash.sha2.Sha256.init(.{});
    h.update(status_data);
    var digest: [32]u8 = undefined;
    h.final(&digest);
    const hex_buf = std.fmt.bytesToHex(digest, .lower);

    // Read GAP_ANALYSIS.md first 200 lines to find marker
    var gap_file = try std.fs.cwd().openFile("docs/GAP_ANALYSIS.md", .{ .read = true });
    defer gap_file.close();
    const gap_data = try gap_file.readToEndAlloc(alloc, 32 * 1024);
    defer alloc.free(gap_data);

    const marker_prefix = "<!-- STATUS_JSON_SHA256: ";
    const idx = std.mem.indexOfPos(u8, gap_data, 0, marker_prefix) orelse return error.MarkerNotFound;
    const after = gap_data[idx + marker_prefix.len ..];
    // Slice until the closing sequence ' -->'
    const close_seq = " -->";
    const close_pos = std.mem.indexOfPos(u8, after, 0, close_seq) orelse return error.BadMarkerFormat;
    const hash_in_file = after[0..close_pos];

    try std.testing.expectEqualStrings(&hex_buf, hash_in_file);
}
