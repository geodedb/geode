const std = @import("std");
const geode = @import("geode");
const eval = geode.eval;
const types = geode.value_types;
const datetime = geode.types.datetime;
const uuid = geode.types.uuid;

test "Advanced Types Ordering" {
    const allocator = std.testing.allocator;

    // Date
    const d1 = types.Value{ .Date = .{ .days_since_epoch = 100 } };
    const d2 = types.Value{ .Date = .{ .days_since_epoch = 200 } };

    // Eq/Ne (Should pass)
    var res = try eval.evalBinary(allocator, .Eq, d1, d1);
    try std.testing.expect(res.Bool == true);
    res = try eval.evalBinary(allocator, .Ne, d1, d2);
    try std.testing.expect(res.Bool == true);

    // Lt (Might fail if not implemented)
    res = try eval.evalBinary(allocator, .Lt, d1, d2);
    try std.testing.expect(res.Bool == true);

    // UUID
    // ...
}
