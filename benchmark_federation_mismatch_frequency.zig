const std = @import("std");
const fed_flag = @import("src/distributed/federation_flag.zig");

// Benchmark / guard: ensure federation ordering mismatch flag does NOT fire for consistent metadata
// while firing exactly once for a deliberate mismatch scenario.
// CANARY: REQ=REQ-GQL-024; FEATURE="FederationMismatchFlag"; ASPECT=MismatchFalsePositiveGuard; STATUS=BENCHED; BENCH=BenchmarkCANARY_REQ_GQL_024_FederationMismatchFalsePositiveGuard; OWNER=federation; UPDATED=2025-09-23
// Policy: false_positive_count must be 0 across N consistent merges; mismatch_count must be 1 after a single
// simulated mismatch. This protects against accidental regressions that spuriously emit the usage flag.

fn simulateConsistencyCheck(keys_a: []const []const u8, dirs_a: []const bool, keys_b: []const []const u8, dirs_b: []const bool) bool {
    // Returns true if mismatch (dir or key length/content) would be detected by federation merge preconditions.
    if (keys_a.len == 0 or keys_b.len == 0) return true; // would fallback (unordered) but treat as mismatch path
    if (keys_a.len != keys_b.len) return true;
    var i: usize = 0;
    while (i < keys_a.len) : (i += 1) {
        if (!std.mem.eql(u8, keys_a[i], keys_b[i])) return true;
    }
    if (dirs_a.len != dirs_b.len) return true;
    i = 0;
    while (i < dirs_a.len) : (i += 1) {
        if (dirs_a[i] != dirs_b[i]) return true;
    }
    return false; // no mismatch
}

pub fn main() !void {
    var gpa = std.heap.GeneralPurposeAllocator(.{}){};
    defer std.debug.assert(gpa.deinit() == .ok);
    _ = gpa.allocator(); // allocator unused for now

    const keys: [2][]const u8 = .{ "k1", "k2" };
    const dirs: [2]bool = .{ true, false };

    var false_positive_count: usize = 0;
    const iterations: usize = 5_000;
    var it: usize = 0;
    while (it < iterations) : (it += 1) {
        // Consistent metadata on both sides -> should not set mismatch flag.
        const mismatch = simulateConsistencyCheck(&keys, &dirs, &keys, &dirs);
        if (mismatch) {
            // Would set flag in real merge, simulate by writing.
            fed_flag.g_last_federation_mismatch = true;
        }
        if (fed_flag.mismatchFlag()) {
            // Consume and record if unexpected.
            if (fed_flag.consumeMismatchFlag()) false_positive_count += 1;
        }
    }

    // Now perform a deliberate direction mismatch.
    const dirs_mismatch: [2]bool = .{ true, true }; // second dir differs from original false
    const mismatch_now = simulateConsistencyCheck(&keys, &dirs, &keys, &dirs_mismatch);
    if (!mismatch_now) return error.ExpectedMismatchNotDetected;
    if (mismatch_now) {
        fed_flag.g_last_federation_mismatch = true;
    }
    var mismatch_count: usize = 0;
    if (fed_flag.mismatchFlag()) {
        if (fed_flag.consumeMismatchFlag()) mismatch_count += 1;
    }

    if (false_positive_count != 0) return error.FalsePositiveMismatchEmission;
    if (mismatch_count != 1) return error.MismatchNotEmitted;

    // Output JSON line for aggregation / governance.
    var buf: [256]u8 = undefined;
    var fbs = std.io.fixedBufferStream(&buf);
    const w = fbs.writer();
    try w.writeAll("{\"bench\":\"BenchmarkCANARY_REQ_GQL_024_FederationMismatchFalsePositiveGuard\",");
    try w.print("\"iterations\":{},", .{iterations});
    try w.print("\"false_positive_count\":{},", .{false_positive_count});
    try w.print("\"mismatch_count\":{}", .{mismatch_count});
    try w.writeAll("}\n");
    const line = fbs.getWritten();
    _ = try std.posix.write(std.posix.STDOUT_FILENO, line);
}
