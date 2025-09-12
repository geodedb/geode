const std = @import("std");
const testing = std.testing;

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

fn structuralSignature(ally: std.mem.Allocator, line: []const u8) ![]u8 {
    var buf = std.ArrayList(u8).initCapacity(ally, line.len) catch return error.OutOfMemory;
    var i: usize = 0;
    while (i < line.len) : (i += 1) {
        const c = line[i];
        if (c >= '0' and c <= '9') {
            // collapse number sequences to single placeholder '0'
            if (buf.items.len == 0 or buf.items[buf.items.len - 1] != '0')
                buf.append(ally, '0') catch return error.OutOfMemory;
            // skip rest of digits (and optional decimal fraction)
            var j = i + 1;
            while (j < line.len) : (j += 1) {
                const d = line[j];
                if (!((d >= '0' and d <= '9') or d == '.')) break;
            }
            i = j - 1;
            continue;
        }
        switch (c) {
            ' ', '\t', '\n', '\r' => continue,
            else => {
                buf.appendAssumeCapacity(c);
            },
        }
    }
    return buf.toOwnedSlice(ally) catch error.OutOfMemory;
}

// Initial snapshot test: builds a structural signature independent of numeric jitter.
// On first failure it will print the computed signature; update EXPECTED_SIGNATURE accordingly.

const EXPECTED_SIGNATURE = "{\"status_class\":\"0\",\"result\":{\"type\":\"PROFILE\",\"json\":{\"profile_version\":0,\"ops\":[{\"op\":\"NodeScan\",\"phase\":\"SCAN\",\"id\":0,\"op_index\":0,\"input_rows\":0,\"rows\":0,\"time_ns\":0,\"cpu_time_ns\":0,\"bytes_out\":0,\"bytes_alloc\":0,\"estimate_bytes\":0,\"estimate_vs_actual\":0,\"percent_peak\":0,\"percent_net\":0,\"cumulative_time_ns\":0,\"freed_bytes\":0,\"net_after_op\":0,\"error_bytes\":0,\"error_abs_pct\":0},{\"op\":\"Expand\",\"phase\":\"EXPAND\",\"id\":0,\"op_index\":0,\"input_rows\":0,\"rows\":0,\"time_ns\":0,\"cpu_time_ns\":0,\"bytes_out\":0,\"bytes_alloc\":0,\"estimate_bytes\":0,\"estimate_vs_actual\":0,\"percent_peak\":0,\"percent_net\":0,\"cumulative_time_ns\":0,\"freed_bytes\":0,\"net_after_op\":0,\"error_bytes\":0,\"error_abs_pct\":0},{\"op\":\"Project\",\"phase\":\"PROJECT\",\"id\":0,\"op_index\":0,\"input_rows\":0,\"rows\":0,\"time_ns\":0,\"cpu_time_ns\":0,\"bytes_out\":0,\"bytes_alloc\":0,\"estimate_bytes\":0,\"estimate_vs_actual\":0,\"percent_peak\":0,\"percent_net\":0,\"cumulative_time_ns\":0,\"freed_bytes\":0,\"net_after_op\":0,\"error_bytes\":0,\"error_abs_pct\":0},{\"op\":\"Limit\",\"phase\":\"PAGE\",\"id\":0,\"op_index\":0,\"input_rows\":0,\"rows\":0,\"time_ns\":0,\"cpu_time_ns\":0,\"bytes_out\":0,\"bytes_alloc\":0,\"estimate_bytes\":0,\"estimate_vs_actual\":0,\"percent_peak\":0,\"percent_net\":0,\"cumulative_time_ns\":0,\"freed_bytes\":0,\"net_after_op\":0,\"error_bytes\":0,\"error_abs_pct\":0},\"peak_contributors\":[{\"op\":\"Project\",\"bytes_alloc\":0},{\"op\":\"Limit\",\"bytes_alloc\":0}],\"totals\":{\"time_ns\":0,\"peak_bytes\":0},\"total_time_ns\":0,\"spills\":{\"sort_spills\":0,\"distinct_spills\":0,\"union_spills\":0},\"memory\":{\"net_bytes\":0,\"peak_bytes\":0,\"total_alloc_bytes\":0},\"planner_estimates\":{\"sum_estimate_bytes\":0,\"sum_actual_bytes\":0,\"count_estimated_ops\":0,\"min_error_abs_pct\":0,\"max_error_abs_pct\":0,\"mean_error_abs_pct\":0,\"median_error_abs_pct\":0,\"adjusted_estimate_factor\":0},\"flagger_findings\":[\"I:IllegalOrderKeyPolicy=ident-only\",\"U:NullsFirstPolicy\"]}}"; // locked snapshot signature

test "protocol: PROFILE structural snapshot" {
    // Use client CLI which already manages PULL sequence for deferred PROFILE.
    const exe = "./zig-out/bin/geodec";
    const out = try run(&.{ exe, "PROFILE RETURN 1 AS x LIMIT 1" });
    defer testing.allocator.free(out);
    // Second line should be PROFILE
    var it = std.mem.splitScalar(u8, out, '\n');
    var prof_opt: ?[]const u8 = null;
    while (it.next()) |line| {
        if (std.mem.indexOf(u8, line, "\"type\":\"PROFILE\"") != null) {
            prof_opt = line;
            break;
        }
    }
    const prof = prof_opt orelse return error.MissingProfile;
    try testing.expect(std.mem.indexOf(u8, prof, "\"type\":\"PROFILE\"") != null);
    var arena = std.heap.ArenaAllocator.init(testing.allocator);
    defer arena.deinit();
    const sig = try structuralSignature(arena.allocator(), prof);
    if (std.mem.eql(u8, EXPECTED_SIGNATURE, "FILLME")) {
        std.debug.print("SNAPSHOT_SIGNATURE={s}\n", .{sig});
        return; // allow first run to report signature without failing
    }
    if (!std.mem.eql(u8, sig, EXPECTED_SIGNATURE)) {
        std.debug.print("SNAPSHOT_SIGNATURE={s}\n", .{sig});
        return error.SnapshotMismatch;
    }
}
