// GAP-0494: Security test — random() GQL function must use CSPRNG not LCG
const std = @import("std");

test "random(): uses CSPRNG not LCG (GAP-0494)" {
    const src = @embedFile("types/evaluator_functions.zig");
    // Must NOT contain LCG constants or timestamp seeding
    try std.testing.expect(std.mem.indexOf(u8, src, "milliTimestamp") == null);
    try std.testing.expect(std.mem.indexOf(u8, src, "1103515245") == null);
}
