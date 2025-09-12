const std = @import("std");
const testing = std.testing;
const util = @import("profile_test_util.zig");

fn run(args: []const []const u8) ![]u8 {
    var child = std.process.Child.init(args, testing.allocator);
    child.stdout_behavior = .Pipe;
    child.stderr_behavior = .Pipe;
    try child.spawn();
    const out = try child.stdout.?.readToEndAlloc(testing.allocator, 1 << 18);
    _ = try child.stderr.?.readToEndAlloc(testing.allocator, 1 << 16);
    const term = try child.wait();
    try testing.expectEqual(std.process.Child.Term{ .Exited = 0 }, term);
    return out;
}

// structuralSignature now delegates to util.normalizeNumbers (which also strips whitespace)
fn structuralSignature(ally: std.mem.Allocator, line: []const u8) ![]u8 {
    return util.normalizeNumbers(ally, line);
}

// Initial snapshot test: builds a structural signature independent of numeric jitter.
// On first failure it will print the computed signature; update EXPECTED_SIGNATURE accordingly.
// TODO(profile_version-bump): When GROUP BY operator lands and profile_version increments, update EXPECTED_SIGNATURE and add new op ordering expectations.

const EXPECTED_SIGNATURE = "{\"status_class\":\"0\",\"result\":{\"type\":\"PROFILE\",\"json\":{\"profile_version\":1,\"ops\":[{\"op\":\"NodeScan\",\"phase\":\"SCAN\",\"id\":0,\"op_index\":0,\"input_rows\":0,\"rows\":0,\"time_ns\":0,\"cpu_time_ns\":0,\"bytes_out\":0,\"bytes_alloc\":0,\"estimate_bytes\":0,\"estimate_vs_actual\":0,\"percent_peak\":0,\"percent_net\":0,\"cumulative_time_ns\":0,\"freed_bytes\":0,\"net_after_op\":0,\"error_bytes\":0,\"error_abs_pct\":0},{\"op\":\"Expand\",\"phase\":\"EXPAND\",\"id\":0,\"op_index\":0,\"input_rows\":0,\"rows\":0,\"time_ns\":0,\"cpu_time_ns\":0,\"bytes_out\":0,\"bytes_alloc\":0,\"estimate_bytes\":0,\"estimate_vs_actual\":0,\"percent_peak\":0,\"percent_net\":0,\"cumulative_time_ns\":0,\"freed_bytes\":0,\"net_after_op\":0,\"error_bytes\":0,\"error_abs_pct\":0},{\"op\":\"Project\",\"phase\":\"PROJECT\",\"id\":0,\"op_index\":0,\"input_rows\":0,\"rows\":0,\"time_ns\":0,\"cpu_time_ns\":0,\"bytes_out\":0,\"bytes_alloc\":0,\"estimate_bytes\":0,\"estimate_vs_actual\":0,\"percent_peak\":0,\"percent_net\":0,\"cumulative_time_ns\":0,\"freed_bytes\":0,\"net_after_op\":0,\"error_bytes\":0,\"error_abs_pct\":0},{\"op\":\"Limit\",\"phase\":\"PAGE\",\"id\":0,\"op_index\":0,\"input_rows\":0,\"rows\":0,\"time_ns\":0,\"cpu_time_ns\":0,\"bytes_out\":0,\"bytes_alloc\":0,\"estimate_bytes\":0,\"estimate_vs_actual\":0,\"percent_peak\":0,\"percent_net\":0,\"cumulative_time_ns\":0,\"freed_bytes\":0,\"net_after_op\":0,\"error_bytes\":0,\"error_abs_pct\":0},\"peak_contributors\":[{\"op\":\"Project\",\"bytes_alloc\":0},{\"op\":\"Limit\",\"bytes_alloc\":0}],\"totals\":{\"time_ns\":0,\"peak_bytes\":0},\"total_time_ns\":0,\"spills\":{\"sort_spills\":0,\"distinct_spills\":0,\"union_spills\":0},\"memory\":{\"net_bytes\":0,\"peak_bytes\":0,\"total_alloc_bytes\":0},\"planner_estimates\":{\"sum_estimate_bytes\":0,\"sum_actual_bytes\":0,\"count_estimated_ops\":0,\"min_error_abs_pct\":0,\"max_error_abs_pct\":0,\"mean_error_abs_pct\":0,\"median_error_abs_pct\":0,\"stddev_error_abs_pct\":0,\"adjusted_estimate_factor\":0},\"flagger_findings\":[\"I:IllegalOrderKeyPolicy=ident-only\",\"U:NullsFirstPolicy\"]}}"; // locked snapshot signature (profile_version=1)

test "protocol: PROFILE structural snapshot" {
    // Use client CLI which already manages PULL sequence for deferred PROFILE.
    const exe = "./zig-out/bin/geodec";
    const out = try run(&.{ exe, "PROFILE RETURN 1 AS x LIMIT 1" });
    defer testing.allocator.free(out);
    const prof = util.findProfileLine(out) orelse return error.MissingProfile;
    // Ensure profile_version matches snapshot expectation before signature compare (fast fail for version bump)
    if (std.mem.indexOf(u8, prof, "\"profile_version\":1") == null) return error.ProfileVersionMismatch;
    // Op order subset sanity (stabilizes semantics around structural signature)
    try util.assertOpOrder(prof, &.{ "NodeScan", "Expand", "Project", "Limit" });
    try testing.expect(std.mem.indexOf(u8, prof, "\"type\":\"PROFILE\"") != null);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const sig = try structuralSignature(arena.allocator(), prof);
    if (std.mem.eql(u8, EXPECTED_SIGNATURE, "FILLME")) {
        std.debug.print("SNAPSHOT_SIGNATURE={s}\n", .{sig});
        return; // allow first run to report signature without failing
    }
    if (!std.mem.eql(u8, sig, EXPECTED_SIGNATURE)) {
        var arena2 = std.heap.ArenaAllocator.init(testing.allocator);
        defer arena2.deinit();
        const diff = util.signatureDiff(arena2.allocator(), EXPECTED_SIGNATURE, sig) catch "<diff-error>";
        std.debug.print("SNAPSHOT_SIGNATURE_MISMATCH\n{s}\n", .{diff});
        return error.SnapshotMismatch;
    }
}
