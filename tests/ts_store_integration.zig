const std = @import("std");
const timeseries = @import("timeseries_wrapper");

fn makeStore() timeseries.Store {
    return timeseries.Store.init(std.testing.allocator);
}

test "ts store: last_value/value_before/sample_by integration" {
    var st = makeStore();
    defer st.deinit();

    const key = timeseries.SeriesKey{ .device_id = 42, .metric = "temp" };
    try st.insertMany(key, &.{ .{ .ts = 0, .value = 10 }, .{ .ts = 5, .value = 20 }, .{ .ts = 10, .value = 30 } });
    const last = st.last(key).?;
    try std.testing.expect(last.ts == 10 and last.value == 30);
    const vb = st.valueBefore(key, 7).?;
    try std.testing.expect(vb.ts == 5 and vb.value == 20);
    const buckets = try st.timeBucketAvg(key, 10, 0, 20, std.testing.allocator);
    defer std.testing.allocator.free(buckets);
    try std.testing.expect(buckets.len == 2);
    try std.testing.expect(buckets[0].avg.? == 15);
    try std.testing.expect(buckets[1].avg.? == 30);
}
