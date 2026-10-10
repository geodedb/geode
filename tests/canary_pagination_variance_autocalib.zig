const std = @import("std");
const geode = @import("geode");
const pag = geode.pagination_calibration;

// CANARY: REQ=REQ-GQL-004; FEATURE="Pagination"; ASPECT=PaginationAutoCalibration; STATUS=TESTED; TEST=TestCANARY_REQ_GQL_004_PaginationAutoCalibratePageSize; OWNER=planner; UPDATED=2025-09-26

test "TestCANARY_REQ_GQL_004_PaginationAutoCalibratePageSize" {
    const start: usize = 128;
    // Stable -> growth. SONNY-2394: this used to assign `size = grown` and
    // then assert `grown > size` (a self-comparison that can never hold);
    // growth is relative to the starting size.
    const grown = pag.nextPageSize(start, 0.12, 32, 512);
    try std.testing.expect(grown > start);
    const size = grown;
    // High variance -> shrink
    const shrunk = pag.nextPageSize(size, 0.70, 32, 512);
    try std.testing.expect(shrunk < grown);
}
