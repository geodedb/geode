const std = @import("std");
const geode = @import("geode");
const pag = geode.pagination_calibration;

// CANARY: REQ=REQ-GQL-004; FEATURE="Pagination"; ASPECT=PaginationAutoCalibration; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_004_PaginationAutoCalibratePageSize; OWNER=planner; UPDATED=2025-09-26

test "TestCANARY_REQ_GQL_004_PaginationAutoCalibratePageSize" {
    var size: usize = 128; // Start size
    // Stable -> growth (mutate)
    const grown = pag.nextPageSize(size, 0.12, 32, 512);
    size = grown;
    try std.testing.expect(grown > size);
    // High variance -> shrink
    const shrunk = pag.nextPageSize(size, 0.70, 32, 512);
    try std.testing.expect(shrunk < grown);
}
