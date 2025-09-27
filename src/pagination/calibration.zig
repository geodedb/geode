const std = @import("std");

// CANARY: REQ=REQ-GQL-004; FEATURE="Pagination"; ASPECT=PaginationAutoCalibration; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_004_PaginationAutoCalibratePageSize; OWNER=planner; UPDATED=2025-09-26
// Simple adaptive page size selection based on observed coefficient of variation (cv) of prior page fetch latencies
// or row materialization times. High variance -> smaller pages for smoother tail; very low variance -> opportunistic growth.

pub fn nextPageSize(prev: usize, cv: f64, min: usize, max: usize) usize {
    var size = prev;
    if (cv > 0.55) {
        // Volatile workload: shrink aggressively (halve but not below min)
        size = if (size / 2 < min) min else size / 2;
    } else if (cv < 0.18) {
        // Stable workload: grow moderately (+25%) bounded by max
        const inc = size + (size / 4);
        size = if (inc > max) max else inc;
    } else if (cv > 0.35) {
        // Mild volatility: small decrease (-15%)
        const dec = size - (size / 6);
        size = if (dec < min) min else dec;
    }
    return size;
}

test "pagination auto calibration adjusts size up and down" {
    var s: usize = 100;
    s = nextPageSize(s, 0.10, 25, 400); // low cv -> grow
    try std.testing.expect(s > 100);
    const grown = s;
    s = nextPageSize(s, 0.60, 25, 400); // high cv -> shrink
    try std.testing.expect(s < grown);
    s = nextPageSize(s, 0.30, 25, 400); // moderate cv -> near unchanged
}
